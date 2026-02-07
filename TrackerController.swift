import Foundation

final class TrackerController {
    struct Credentials: Equatable {
        var email: String
        var password: String

        var sanitizedEmail: String { Self.normalize(email) }
        var sanitizedPassword: String { Self.normalize(password) }
        var isValid: Bool { !sanitizedEmail.isEmpty && !sanitizedPassword.isEmpty }

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

    struct AuthTokens: Equatable {
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
            case .error: return "Error"
            }
        }
    }

    enum TrackerError: Error {
        case credentialsMissing
        case authenticationFailed(String)
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
    private var credentials: Credentials
    private var authTokens: AuthTokens?
    private var isBusy = false
    private var pendingStatusRefresh = false
    private var authFailureDetected = false
    private let projectId = 10

    init() {
        credentials = tokensStore.load()
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
        guard credentials.isValid else {
            appendLog("Credentials missing. Update email/password to control tracker.")
            updateState(.error("Credentials missing"))
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
        guard credentials.isValid else {
            updateState(.error("Credentials missing"))
            return
        }
        guard authFailureDetected == false else {
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

    func updateCredentials(email: String, password: String) {
        let newCredentials = Credentials(email: email, password: password)
        credentials = newCredentials
        authTokens = nil
        authFailureDetected = false
        tokensStore.save(credentials)
        appendLog("Credentials updated.")
        startPolling()
        refreshStatus(showLoading: true)
    }

    func currentCredentials() -> Credentials {
        credentials
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
        let sessionTokens = try await ensureAuthenticated()
        do {
            return try await networkClient.send(route.descriptor, tokens: sessionTokens)
        } catch let error as NetworkClient.Error {
            switch error {
            case .transport(let label, let underlying):
                throw TrackerError.requestFailed(label: label, error: underlying)
            case .unexpectedStatusCode(let label, let code, let body):
                throw TrackerError.unexpectedStatusCode(label: label, code: code, body: body)
            case .missingCookie(let label, let name):
                throw TrackerError.requestFailed(
                    label: label,
                    error: NSError(domain: "CalamariStatus", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Missing cookie: \(name)"
                    ])
                )
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
        case TrackerError.credentialsMissing:
            message = "Credentials missing"
        case TrackerError.authenticationFailed(let reason):
            message = "Auth failed: \(reason)"
            authFailureDetected = true
            pendingStatusRefresh = false
            pollTimer?.invalidate()
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

    private func ensureAuthenticated() async throws -> AuthTokens {
        if let authTokens, authTokens.isValid {
            return authTokens
        }
        let currentCredentials = credentials
        guard currentCredentials.isValid else {
            throw TrackerError.credentialsMissing
        }
        do {
            let newTokens = try await networkClient.authenticate(
                email: currentCredentials.sanitizedEmail,
                password: currentCredentials.sanitizedPassword
            )
            await MainActor.run { [weak self] in
                self?.authTokens = newTokens
                self?.appendLog("Authenticated successfully.")
            }
            return newTokens
        } catch let error as NetworkClient.Error {
            throw TrackerError.authenticationFailed(error.localizedDescription)
        } catch {
            throw TrackerError.authenticationFailed(error.localizedDescription)
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
        guard authFailureDetected == false else {
            return
        }
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
    private let emailKey = "CalamariTrackerEmail"
    private let passwordKey = "CalamariTrackerPassword"

    func load() -> TrackerController.Credentials {
        let defaults = UserDefaults.standard
        let email = defaults.string(forKey: emailKey) ?? ""
        let password = defaults.string(forKey: passwordKey) ?? ""
        return TrackerController.Credentials(email: email, password: password)
    }

    func save(_ credentials: TrackerController.Credentials) {
        let defaults = UserDefaults.standard
        defaults.set(credentials.sanitizedEmail, forKey: emailKey)
        defaults.set(credentials.sanitizedPassword, forKey: passwordKey)
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

    enum Error: Swift.Error, LocalizedError {
        case transport(label: String, underlying: Swift.Error)
        case unexpectedStatusCode(label: String, code: Int, body: String)
        case missingCookie(label: String, name: String)

        var errorDescription: String? {
            switch self {
            case .transport(let label, let underlying):
                return "\(label) request failed: \(underlying.localizedDescription)"
            case .unexpectedStatusCode(let label, let code, _):
                return "\(label) HTTP \(code)"
            case .missingCookie(let label, let name):
                return "\(label) missing cookie: \(name)"
            }
        }
    }

    private let baseURL = URL(string: "https://xxx.calamari.io")!
    private let authBaseURL = URL(string: "https://core.calamari.io")!
    private let originURL = URL(string: "https://auth.calamari.io")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ descriptor: RequestDescriptor, tokens: TrackerController.AuthTokens) async throws -> Response {
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

    func authenticate(email: String, password: String) async throws -> TrackerController.AuthTokens {
        let csrfToken = try await fetchCSRFToken()
        let sessionToken = try await signIn(email: email, password: password, csrfToken: csrfToken)
        return TrackerController.AuthTokens(csrfToken: csrfToken, session: sessionToken)
    }

    private func fetchCSRFToken() async throws -> String {
        let url = authBaseURL.appendingPathComponent("/webapi/tenant/current-tenant-info")
        var request = URLRequest(url: url)
        request.httpMethod = Method.get.rawValue
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(originURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(originURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Error.transport(label: "current-tenant-info", underlying: URLError(.badServerResponse))
            }
            guard let csrfCookie = cookie(named: "_csrf_token", response: httpResponse, url: url) else {
                throw Error.missingCookie(label: "current-tenant-info", name: "_csrf_token")
            }
            return csrfCookie.value
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport(label: "current-tenant-info", underlying: error)
        }
    }

    private func signIn(email: String, password: String, csrfToken: String) async throws -> String {
        let url = baseURL.appendingPathComponent("/sign-in.do")
        var request = URLRequest(url: url)
        request.httpMethod = Method.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(originURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(originURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue(csrfToken, forHTTPHeaderField: "x-csrf-token")
        request.setValue("_csrf_token=\(csrfToken)", forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "domain": domain,
            "login": email,
            "password": password
        ]
        request.httpBody = try Body.json(body).data()
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Error.transport(label: "sign-in", underlying: URLError(.badServerResponse))
            }
            guard let sessionCookie = cookie(named: "calamari.cloud.session", response: httpResponse, url: url) else {
                throw Error.missingCookie(label: "sign-in", name: "calamari.cloud.session")
            }
            return sessionCookie.value
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport(label: "sign-in", underlying: error)
        }
    }

    private var domain: String {
        let host = baseURL.host ?? ""
        return host.components(separatedBy: ".").first ?? ""
    }

    private func cookie(named name: String, response: HTTPURLResponse, url: URL) -> HTTPCookie? {
        let headers = response.allHeaderFields
        let headerFields = headers.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String {
                result[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        return cookies.first { $0.name == name }
    }
}
