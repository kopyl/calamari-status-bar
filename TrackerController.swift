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

    struct Project: Equatable, Hashable {
        let id: Int
        let name: String
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
    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private let networkClient = NetworkClient()
    private let tokensStore = TokenStore()
    private var pollTimer: Timer?
    private var stateListeners: [UUID: (TrackerState) -> Void] = [:]
    private var logListeners: [UUID: ([String]) -> Void] = [:]
    private var authListeners: [UUID: (Bool) -> Void] = [:]
    private var projectListeners: [UUID: ([Project]) -> Void] = [:]
    private var timeListeners: [UUID: (Int) -> Void] = [:]
    private var logs: [String] = []
    private var projects: [Project] = []
    private var state: TrackerState = .loading
    private var lastStableState: TrackerState = .stopped
    private var totalSecondsToday: Int = 0
    private var credentials: Credentials
    private var authTokens: AuthTokens?
    private var isLoginEnabled: Bool
    private var selectedProjectId: Int?
    private var isBusy = false
    private var pendingStatusRefresh = false
    private var authFailureDetected = false
    private var isTapInFlight = false
    private var pendingTap = false
    private var statusRequestGeneration = 0

    init() {
        credentials = tokensStore.load()
        authTokens = tokensStore.loadAuthTokens()
        isLoginEnabled = tokensStore.loadLoginEnabled()
        selectedProjectId = tokensStore.loadProjectId()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func start() {
        if isLoginEnabled == false || credentials.isValid == false {
            updateState(.stopped)
            notifyAuthListeners()
            notifyProjectListeners()
            return
        }
        notifyStateListeners(state)
        notifyAuthListeners()
        notifyProjectListeners()
        startPolling()
        refreshStatus(showLoading: true)
    }

    func handleStatusItemTap() {
        guard isLoginEnabled else {
            appendLog("Signed out. Sign in to control tracker.")
            updateState(.stopped)
            return
        }
        guard credentials.isValid else {
            appendLog("Credentials missing. Update email/password to control tracker.")
            updateState(.stopped)
            return
        }
        guard !isBusy else {
            pendingTap = true
            appendLog("Tap queued while another request is running.")
            return
        }
        isBusy = true
        isTapInFlight = true
        updateState(.loading)
        Task.detached { [weak self] in
            await self?.performToggleAction()
        }
    }

    func refreshStatus(showLoading: Bool = false) {
        guard isLoginEnabled else {
            updateState(.stopped)
            return
        }
        guard credentials.isValid else {
            updateState(.stopped)
            return
        }
        guard authFailureDetected == false else {
            return
        }
        if isBusy {
            if isTapInFlight {
                return
            }
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
        tokensStore.saveAuthTokens(nil)
        updateLoginEnabled(true)
        appendLog("Credentials updated.")
        notifyAuthListeners()
        startPolling()
        refreshStatus(showLoading: true)
    }

    func currentCredentials() -> Credentials {
        credentials
    }

    func currentLogs() -> [String] {
        logs
    }

    func currentProjects() -> [Project] {
        projects
    }

    func currentProjectId() -> Int? {
        selectedProjectId
    }

    func isAuthenticated() -> Bool {
        isLoginEnabled && authTokens?.isValid == true && authFailureDetected == false
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

    @discardableResult
    func addProjectListener(_ listener: @escaping ([Project]) -> Void) -> UUID {
        let id = UUID()
        projectListeners[id] = listener
        DispatchQueue.main.async { [projects] in
            listener(projects)
        }
        return id
    }

    func removeProjectListener(_ id: UUID) {
        projectListeners.removeValue(forKey: id)
    }

    @discardableResult
    func addTimeListener(_ listener: @escaping (Int) -> Void) -> UUID {
        let id = UUID()
        timeListeners[id] = listener
        DispatchQueue.main.async { [totalSecondsToday] in
            listener(totalSecondsToday)
        }
        return id
    }

    func removeTimeListener(_ id: UUID) {
        timeListeners.removeValue(forKey: id)
    }

    @discardableResult
    func addAuthListener(_ listener: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        authListeners[id] = listener
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            listener(self.isAuthenticated())
        }
        return id
    }

    func removeAuthListener(_ id: UUID) {
        authListeners.removeValue(forKey: id)
    }

    func updateSelectedProjectId(_ id: Int?) {
        selectedProjectId = id
        tokensStore.saveProjectId(id)
    }

    func signOut() {
        statusRequestGeneration += 1
        isBusy = false
        isTapInFlight = false
        pendingTap = false
        pendingStatusRefresh = false
        updateLoginEnabled(false)
        authTokens = nil
        tokensStore.saveAuthTokens(nil)
        authFailureDetected = false
        pollTimer?.invalidate()
        updateState(.stopped)
        appendLog("Signed out locally.")
    }

    private func updateLoginEnabled(_ enabled: Bool) {
        if isLoginEnabled == enabled {
            return
        }
        isLoginEnabled = enabled
        tokensStore.saveLoginEnabled(enabled)
        notifyAuthListeners()
    }

    private func updateSelectedProjectFromStatus(_ id: Int?) {
        if selectedProjectId == id {
            return
        }
        selectedProjectId = id
        tokensStore.saveProjectId(id)
        notifyProjectListeners()
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
                self.isTapInFlight = false
                self.isBusy = false
                self.handlePendingActions()
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.isTapInFlight = false
                self?.handleError(error, context: "Toggle action failed")
            }
        }
    }

    private func performStatusFetch() async {
        let generation = statusRequestGeneration
        do {
            let response = try await sendRequest(for: .status)
            let newState = try parseStatus(from: response.data)
            let fetchedProjects = parseProjects(from: response.data)
            let trackedProject = parseTrackedProject(from: response.data)
            let totalSeconds = parseTotalSeconds(from: response.data)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.pendingStatusRefresh = false
                guard self.statusRequestGeneration == generation else { return }
                guard self.isLoginEnabled else { return }
                self.updateState(newState)
                self.updateTotalSeconds(totalSeconds)
                self.updateProjects(fetchedProjects)
                if trackedProject.hasActiveShift {
                    self.updateSelectedProjectFromStatus(trackedProject.projectId)
                }
                self.handlePendingActions()
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.handleError(error, context: "Failed to fetch status")
            }
        }
    }

    private func runStartSequence() async throws {
        let startResponse = try await sendRequest(for: .start)
        appendLog("Start tracker succeeded (HTTP \(startResponse.statusCode)).")

        if let projectId = selectedProjectId {
            let specifyResponse = try await sendRequest(for: .specifyProject(projectId: projectId))
            appendLog("Project specified (HTTP \(specifyResponse.statusCode)).")
        } else {
            appendLog("No project selected; skipping project selection.")
        }
    }

    public func runStop() async throws {
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

    private func parseProjects(from data: Data) -> [Project] {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let root = jsonObject as? [String: Any],
              let projects = root["activeProjects"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<Int>()
        var results: [Project] = []
        for item in projects {
            guard let id = item["id"] as? Int,
                  let name = item["name"] as? String else { continue }
            if seen.insert(id).inserted {
                results.append(Project(id: id, name: name))
            }
        }
        return results
    }

    private func parseTrackedProject(from data: Data) -> (hasActiveShift: Bool, projectId: Int?) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let root = jsonObject as? [String: Any],
              let dayShifts = root["dayShifts"] as? [[String: Any]] else {
            return (false, nil)
        }
        for shift in dayShifts {
            let finishedTime = shift["finishedTime"]
            let isActive = finishedTime == nil || finishedTime is NSNull
            guard isActive else { continue }
            guard let projects = shift["projects"] as? [[String: Any]] else {
                return (true, nil)
            }
            if let firstProject = projects.first {
                let projectId = firstProject["projectId"] as? Int
                return (true, projectId)
            }
            return (true, nil)
        }
        return (false, nil)
    }

    private func parseTotalSeconds(from data: Data) -> Int {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let root = jsonObject as? [String: Any],
              let dayShifts = root["dayShifts"] as? [[String: Any]] else {
            return 0
        }
        let nowString = root["now"] as? String
        let nowDate = nowString.flatMap { Self.apiDateFormatter.date(from: $0) } ?? Date()
        let timezoneId = root["timezone"] as? String
        let timezone = timezoneId.flatMap(TimeZone.init(identifier:)) ?? TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let dayStart = calendar.startOfDay(for: nowDate)
        var total = 0
        for shift in dayShifts {
            if let shiftSeconds = shiftDurationSeconds(shift: shift, dayStart: dayStart, now: nowDate) {
                total += shiftSeconds
                continue
            }
            if let projects = shift["projects"] as? [[String: Any]] {
                for project in projects {
                    if let seconds = intValue(project["secondsDuration"]) {
                        total += seconds
                        continue
                    }
                    let isActive = (project["projectFinished"] == nil || project["projectFinished"] is NSNull)
                    guard isActive,
                          let startedString = project["projectStarted"] as? String,
                          let startedDate = Self.apiDateFormatter.date(from: startedString) else {
                        continue
                    }
                    let clampedStart = max(startedDate, dayStart)
                    let interval = Int(nowDate.timeIntervalSince(clampedStart))
                    if interval > 0 {
                        total += interval
                    }
                }
            }
        }
        return total
    }

    private func shiftDurationSeconds(shift: [String: Any], dayStart: Date, now: Date) -> Int? {
        guard let startedString = shift["startedTime"] as? String,
              let startedDate = Self.apiDateFormatter.date(from: startedString) else {
            return nil
        }
        if let finishedString = shift["finishedTime"] as? String,
           let finishedDate = Self.apiDateFormatter.date(from: finishedString) {
            let clampedStart = max(startedDate, dayStart)
            let clampedEnd = min(finishedDate, now)
            let interval = Int(clampedEnd.timeIntervalSince(clampedStart))
            return interval > 0 ? interval : 0
        }
        let isActive = (shift["finishedTime"] == nil || shift["finishedTime"] is NSNull)
        if isActive {
            let clampedStart = max(startedDate, dayStart)
            let interval = Int(now.timeIntervalSince(clampedStart))
            return interval > 0 ? interval : 0
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let intValue as Int:
            return intValue
        case let doubleValue as Double:
            return Int(doubleValue)
        case let stringValue as String:
            return Int(stringValue)
        default:
            return nil
        }
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
        let nextState: TrackerState
        switch error {
        case TrackerError.credentialsMissing:
            message = "Credentials missing"
            nextState = .stopped
        case TrackerError.authenticationFailed(let reason):
            message = "Auth failed: \(reason)"
            authFailureDetected = true
            authTokens = nil
            tokensStore.saveAuthTokens(nil)
            pendingStatusRefresh = false
            pollTimer?.invalidate()
            notifyAuthListeners()
            nextState = .error(message)
        case TrackerError.requestFailed(let label, let underlying):
            message = "\(label) request failed: \(underlying.localizedDescription)"
            nextState = .error(message)
        case TrackerError.unexpectedStatusCode(let label, let code, let body):
            message = "\(label) HTTP \(code)"
            appendLog("\(label) response body: \(body)")
            nextState = .error(message)
        case TrackerError.statusParsingFailed(let raw):
            message = "Unable to parse status"
            appendLog("Status response: \(raw)")
            nextState = .error(message)
        default:
            message = error.localizedDescription
            nextState = .error(message)
        }
        appendLog("\(context): \(message)")
        updateState(nextState)
        if pendingStatusRefresh {
            pendingStatusRefresh = false
            refreshStatus(showLoading: false)
        }
        handlePendingActions()
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
                self?.tokensStore.saveAuthTokens(newTokens)
                self?.appendLog("Authenticated successfully.")
                self?.notifyAuthListeners()
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

    private func updateProjects(_ newProjects: [Project]) {
        if newProjects == projects {
            return
        }
        projects = newProjects
        if let currentId = selectedProjectId, projects.contains(where: { $0.id == currentId }) == false {
            selectedProjectId = nil
            tokensStore.saveProjectId(nil)
        }
        notifyProjectListeners()
    }

    private func updateTotalSeconds(_ newTotalSeconds: Int) {
        if newTotalSeconds == totalSecondsToday {
            return
        }
        totalSecondsToday = newTotalSeconds
        notifyTimeListeners()
    }

    private func notifyAuthListeners() {
        let snapshot = isAuthenticated()
        DispatchQueue.main.async {
            for handler in self.authListeners.values {
                handler(snapshot)
            }
        }
    }

    private func notifyProjectListeners() {
        let snapshot = projects
        DispatchQueue.main.async {
            for handler in self.projectListeners.values {
                handler(snapshot)
            }
        }
    }

    private func notifyTimeListeners() {
        let snapshot = totalSecondsToday
        DispatchQueue.main.async {
            for handler in self.timeListeners.values {
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

    private func handlePendingActions() {
        if pendingTap {
            pendingTap = false
            handleStatusItemTap()
            return
        }
        if pendingStatusRefresh {
            pendingStatusRefresh = false
            refreshStatus(showLoading: false)
        }
    }
}

private final class TokenStore {
    private let emailKey = "CalamariTrackerEmail"
    private let passwordKey = "CalamariTrackerPassword"
    private let projectIdKey = "CalamariTrackerProjectId"
    private let loginEnabledKey = "CalamariTrackerLoginEnabled"
    private let csrfTokenKey = "CalamariTrackerCSRFToken"
    private let sessionTokenKey = "CalamariTrackerSessionToken"

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

    func loadLoginEnabled() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: loginEnabledKey)
    }

    func saveLoginEnabled(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: loginEnabledKey)
    }

    func loadProjectId() -> Int? {
        let defaults = UserDefaults.standard
        let value = defaults.object(forKey: projectIdKey) as? NSNumber
        return value?.intValue
    }

    func saveProjectId(_ projectId: Int?) {
        let defaults = UserDefaults.standard
        if let projectId {
            defaults.set(projectId, forKey: projectIdKey)
        } else {
            defaults.removeObject(forKey: projectIdKey)
        }
    }

    func loadAuthTokens() -> TrackerController.AuthTokens? {
        let defaults = UserDefaults.standard
        guard let csrf = defaults.string(forKey: csrfTokenKey),
              let session = defaults.string(forKey: sessionTokenKey),
              csrf.isEmpty == false,
              session.isEmpty == false else {
            return nil
        }
        return TrackerController.AuthTokens(csrfToken: csrf, session: session)
    }

    func saveAuthTokens(_ tokens: TrackerController.AuthTokens?) {
        let defaults = UserDefaults.standard
        if let tokens, tokens.isValid {
            defaults.set(tokens.sanitizedCSRF, forKey: csrfTokenKey)
            defaults.set(tokens.sanitizedSession, forKey: sessionTokenKey)
        } else {
            defaults.removeObject(forKey: csrfTokenKey)
            defaults.removeObject(forKey: sessionTokenKey)
        }
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
    private let authSession: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.authSession = URLSession(configuration: config)
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
            let (_, response) = try await authSession.data(for: request)
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
            let (_, response) = try await authSession.data(for: request)
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
        var headerFields: [String: String] = [:]
        for (rawKey, rawValue) in headers {
            guard let key = rawKey as? String else { continue }
            if let value = rawValue as? String {
                headerFields[key] = value
            } else if let values = rawValue as? [String] {
                headerFields[key] = values.joined(separator: ",")
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        return cookies.first { $0.name == name }
    }
}
