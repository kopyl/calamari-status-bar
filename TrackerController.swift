import Foundation

final class TrackerController {
    struct Tokens: Equatable {
        var csrfToken: String
        var session: String

        var sanitizedCSRF: String { Self.normalize(csrfToken) }
        var sanitizedSession: String { Self.normalize(session) }
        var isValid: Bool { !sanitizedCSRF.isEmpty && !sanitizedSession.isEmpty }
        var cookieHeaderValue: String {
            "_csrf_token=\(sanitizedCSRF); calamari.cloud.session=\(sanitizedSession)"
        }

        private static func normalize(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            guard trimmed.contains("\\") else { return trimmed }
            let mutable = NSMutableString(string: trimmed)
            let transform = "Any-Hex/Java" as NSString
            if CFStringTransform(mutable, nil, transform, true) {
                return String(mutable)
            }
            return trimmed
        }
    }

    enum TrackerState: Equatable {
        case loading
        case started
        case stopped
        case error(String)

        var displayDescription: String {
            switch self {
            case .loading: return "Loading…"
            case .started: return "Timer started"
            case .stopped: return "Timer stopped"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    enum TrackerError: Error {
        case tokensMissing
        case requestFailed(label: String, error: Error)
        case unexpectedStatusCode(label: String, code: Int, body: String)
        case statusParsingFailed(String)
    }

    private enum Route {
        case status
        case start
        case specifyProject(projectId: Int)
        case stop

        var descriptor: NetworkClient.RequestDescriptor {
            switch self {
            case .status:
                return NetworkClient.RequestDescriptor(
                    label: "status",
                    path: "/webapi/clock-screen/get",
                    method: .post,
                    body: NetworkClient.Body.json([:])
                )
            case .start:
                return NetworkClient.RequestDescriptor(
                    label: "start tracker",
                    path: "/webapi/clock-screen/clock-in",
                    method: .post,
                    body: NetworkClient.Body.json([:])
                )
            case .specifyProject(let projectId):
                return NetworkClient.RequestDescriptor(
                    label: "specify project",
                    path: "/webapi/clockin/workloging/from-beginning",
                    method: .post,
                    body: NetworkClient.Body.json(["projectId": projectId])
                )
            case .stop:
                return NetworkClient.RequestDescriptor(
                    label: "stop tracker",
                    path: "/webapi/clock-screen/clock-out",
                    method: .post,
                    body: NetworkClient.Body.json([:])
                )
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private let networkClient = NetworkClient()
    private let tokensStore = TokenStore()
    private var pollTimer: Timer?
    private var stateListeners: [UUID: (TrackerState) -> Void] = [:]
    private var logListeners: [UUID: ([String]) -> Void] = [:]
    private var logs: [String] = []
    private var state: TrackerState = .loading
    private var lastStableState: TrackerState = .stopped
    private var tokens: Tokens
    private var isBusy = false
    private var pendingStatusRefresh = false
    private let projectId = 10

    init() {
        tokens = tokensStore.load()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func start() {
        notifyStateListeners(state)
        startPolling()
        refreshStatus(showLoading: true)
    }

    func handleStatusItemTap() {
        guard tokens.isValid else {
            appendLog("Tokens missing. Update tokens to control tracker.")
            updateState(.error("Tokens missing"))
            return
        }
        guard !isBusy else {
            appendLog("Ignoring tap while another request is running.")
            return
        }
        isBusy = true
        updateState(.loading)
        Task.detached { [weak self] in
            await self?.performToggleAction()
        }
    }

    func refreshStatus(showLoading: Bool = false) {
        guard tokens.isValid else {
            updateState(.error("Tokens missing"))
            return
        }
        if isBusy {
            if showLoading {
                pendingStatusRefresh = true
            }
            return
        }
        isBusy = true
        if showLoading {
            updateState(.loading)
        }
        Task.detached { [weak self] in
            await self?.performStatusFetch()
        }
    }

    func updateTokens(csrfToken: String, session: String) {
        let newTokens = Tokens(csrfToken: csrfToken, session: session)
        tokens = newTokens
        tokensStore.save(tokens)
        appendLog("Tokens updated.")
        refreshStatus(showLoading: true)
    }

    func currentTokens() -> Tokens {
        tokens
    }

    func currentLogs() -> [String] {
        logs
    }

    func clearLogs() {
        logs.removeAll()
        notifyLogListeners()
    }

    @discardableResult
    func addStateListener(_ listener: @escaping (TrackerState) -> Void) -> UUID {
        let id = UUID()
        stateListeners[id] = listener
        DispatchQueue.main.async { [state] in
            listener(state)
        }
        return id
    }

    func removeStateListener(_ id: UUID) {
        stateListeners.removeValue(forKey: id)
    }

    @discardableResult
    func addLogListener(_ listener: @escaping ([String]) -> Void) -> UUID {
        let id = UUID()
        logListeners[id] = listener
        DispatchQueue.main.async { [logs] in
            listener(logs)
        }
        return id
    }

    func removeLogListener(_ id: UUID) {
        logListeners.removeValue(forKey: id)
    }

    private func performToggleAction() async {
        let actionState = lastStableState
        do {
            if actionState == .started {
                try await runStop()
            } else {
                try await runStartSequence()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.refreshStatus(showLoading: true)
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.handleError(error, context: "Toggle action failed")
            }
        }
    }

    private func performStatusFetch() async {
        var responseBody: String?
        do {
            let response = try await sendRequest(for: .status)
            responseBody = String(data: response.data, encoding: .utf8) ?? "<non-utf8>"
            let newState = try parseStatus(from: response.data)
            let bodyForLog = responseBody
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.pendingStatusRefresh = false
                self.appendLog("Status fetched (HTTP \(response.statusCode)): \(newState.displayDescription)")
                self.updateState(newState)
            }
        } catch {
            if let body = responseBody {
                print("[CalamariStatus] Response body before error: \(body)")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.handleError(error, context: "Failed to fetch status")
            }
        }
    }

    private func runStartSequence() async throws {
        let startResponse = try await sendRequest(for: .start)
        appendLog("Start tracker succeeded (HTTP \(startResponse.statusCode)).")

        let specifyResponse = try await sendRequest(for: .specifyProject(projectId: projectId))
        appendLog("Project specified (HTTP \(specifyResponse.statusCode)).")
    }

    private func runStop() async throws {
        let response = try await sendRequest(for: .stop)
        appendLog("Stop tracker succeeded (HTTP \(response.statusCode)).")
    }

    private func sendRequest(for route: Route) async throws -> NetworkClient.Response {
        let currentTokens = tokens
        guard currentTokens.isValid else {
            throw TrackerError.tokensMissing
        }
        do {
            return try await networkClient.send(route.descriptor, tokens: currentTokens)
        } catch let error as NetworkClient.Error {
            switch error {
            case .transport(let label, let underlying):
                throw TrackerError.requestFailed(label: label, error: underlying)
            case .unexpectedStatusCode(let label, let code, let body):
                throw TrackerError.unexpectedStatusCode(label: label, code: code, body: body)
            }
        } catch {
            throw TrackerError.requestFailed(label: route.descriptor.label, error: error)
        }
    }

    private func parseStatus(from data: Data) throws -> TrackerState {
        if let stringState = extractStateString(from: data) ?? extractStateFromStringHeuristics(data) {
            switch stringState.uppercased() {
            case "STARTED":
                return .started
            case "STOPPED":
                return .stopped
            default:
                break
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        throw TrackerError.statusParsingFailed(raw)
    }

    private func extractStateString(from data: Data) -> String? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return findStateString(in: jsonObject)
    }

    private func findStateString(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let state = dictionary["currentState"] as? String ?? dictionary["state"] as? String {
                return state
            }
            for child in dictionary.values {
                if let found = findStateString(in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = findStateString(in: element) {
                    return found
                }
            }
        }
        return nil
    }

    private func extractStateFromStringHeuristics(_ data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8)?.uppercased() else {
            return nil
        }
        if body.contains("\"STARTED\"") {
            return "STARTED"
        }
        if body.contains("\"STOPPED\"") {
            return "STOPPED"
        }
        return nil
    }

    private func handleError(_ error: Error, context: String) {
        isBusy = false
        let message: String
        switch error {
        case TrackerError.tokensMissing:
            message = "Tokens missing"
        case TrackerError.requestFailed(let label, let underlying):
            message = "\(label) request failed: \(underlying.localizedDescription)"
        case TrackerError.unexpectedStatusCode(let label, let code, let body):
            message = "\(label) HTTP \(code)"
            appendLog("\(label) response body: \(body)")
        case TrackerError.statusParsingFailed(let raw):
            message = "Unable to parse status"
            appendLog("Status response: \(raw)")
        default:
            message = error.localizedDescription
        }
        appendLog("\(context): \(message)")
        updateState(.error(message))
        if pendingStatusRefresh {
            pendingStatusRefresh = false
            refreshStatus(showLoading: false)
        }
    }

    private func updateState(_ newState: TrackerState) {
        state = newState
        if newState == .started || newState == .stopped {
            lastStableState = newState
        }
        notifyStateListeners(newState)
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logs.append(entry)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
        notifyLogListeners()
    }

    private func notifyStateListeners(_ state: TrackerState) {
        DispatchQueue.main.async {
            for handler in self.stateListeners.values {
                handler(state)
            }
        }
    }

    private func notifyLogListeners() {
        let snapshot = logs
        DispatchQueue.main.async {
            for handler in self.logListeners.values {
                handler(snapshot)
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

private final class TokenStore {
    private let csrfKey = "CalamariTrackerCSRFToken"
    private let sessionKey = "CalamariTrackerSessionToken"

    func load() -> TrackerController.Tokens {
        let defaults = UserDefaults.standard
        let csrf = defaults.string(forKey: csrfKey) ?? ""
        let session = defaults.string(forKey: sessionKey) ?? ""
        return TrackerController.Tokens(csrfToken: csrf, session: session)
    }

    func save(_ tokens: TrackerController.Tokens) {
        let defaults = UserDefaults.standard
        defaults.set(tokens.sanitizedCSRF, forKey: csrfKey)
        defaults.set(tokens.sanitizedSession, forKey: sessionKey)
    }
}

private final class NetworkClient {
    enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    enum Body {
        case none
        case json([String: Any])

        func data() throws -> Data? {
            switch self {
            case .none:
                return nil
            case .json(let object):
                return try JSONSerialization.data(withJSONObject: object, options: [])
            }
        }
    }

    struct RequestDescriptor {
        let label: String
        let path: String
        let method: Method
        let body: Body
    }

    struct Response {
        let statusCode: Int
        let data: Data
        let urlResponse: HTTPURLResponse
    }

    enum Error: Swift.Error {
        case transport(label: String, underlying: Swift.Error)
        case unexpectedStatusCode(label: String, code: Int, body: String)
    }

    private let baseURL = URL(string: "https://xxx.calamari.io")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ descriptor: RequestDescriptor, tokens: TrackerController.Tokens) async throws -> Response {
        let url = baseURL.appendingPathComponent(descriptor.path)
        var request = URLRequest(url: url)
        request.httpMethod = descriptor.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(tokens.sanitizedCSRF, forHTTPHeaderField: "x-csrf-token")
        request.setValue(tokens.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        request.httpBody = try descriptor.body.data()
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Error.transport(label: descriptor.label, underlying: URLError(.badServerResponse))
            }
            let statusCode = httpResponse.statusCode
            if (200...299).contains(statusCode) == false {
                let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                throw Error.unexpectedStatusCode(label: descriptor.label, code: statusCode, body: bodyString)
            }
            return Response(statusCode: statusCode, data: data, urlResponse: httpResponse)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport(label: descriptor.label, underlying: error)
        }
    }
}
