import Cocoa

private enum WindowConfig {
    static let defaultSize = NSSize(width: 300, height: 420)
    static let minimumSize = NSSize(width: 300, height: 320)
    static let loginSize = NSSize(width: 300, height: 260)
    static let loginMinimumSize = NSSize(width: 300, height: 260)
}

final class MainWindowViewController: NSViewController {
    private let trackerController: TrackerController
    private var authListenerID: UUID?
    private var currentChild: NSViewController?

    init(trackerController: TrackerController) {
        self.trackerController = trackerController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let authListenerID {
            trackerController.removeAuthListener(authListenerID)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showContent(isAuthenticated: trackerController.isAuthenticated())
        authListenerID = trackerController.addAuthListener { [weak self] isAuthenticated in
            self?.showContent(isAuthenticated: isAuthenticated)
        }
    }

    private func showContent(isAuthenticated: Bool) {
        let nextController: NSViewController
        if isAuthenticated {
            nextController = TrackerViewController(trackerController: trackerController)
        } else {
            nextController = LoginViewController(trackerController: trackerController)
        }

        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(nextController)
        nextController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextController.view)
        NSLayoutConstraint.activate([
            nextController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextController.view.topAnchor.constraint(equalTo: view.topAnchor),
            nextController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        currentChild = nextController
        updateWindowSize(isAuthenticated: isAuthenticated)
    }

    private func updateWindowSize(isAuthenticated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            let targetSize = isAuthenticated ? WindowConfig.defaultSize : WindowConfig.loginSize
            let targetMinSize = isAuthenticated ? WindowConfig.minimumSize : WindowConfig.loginMinimumSize
            window.minSize = targetMinSize

            let targetContentRect = NSRect(origin: .zero, size: targetSize)
            let targetWindowFrame = window.frameRect(forContentRect: targetContentRect)
            var newFrame = window.frame
            let deltaHeight = newFrame.size.height - targetWindowFrame.size.height
            newFrame.size = targetWindowFrame.size
            newFrame.origin.y += deltaHeight
            window.setFrame(newFrame, display: true, animate: true)
        }
    }
}

final class LoginViewController: NSViewController {
    private let trackerController: TrackerController
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let saveButton = NSButton(title: "Sign in", target: nil, action: nil)
    private var stateListenerID: UUID?

    init(trackerController: TrackerController) {
        self.trackerController = trackerController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let stateListenerID {
            trackerController.removeStateListener(stateListenerID)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        applyInitialData()
        subscribeToController()
    }

    private func configureUI() {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.spacing = 20
        container.alignment = .leading
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            container.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])

        emailField.placeholderString = "email"
        passwordField.placeholderString = "password"
        [emailField, passwordField].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }

        let tokenStack = NSStackView()
        tokenStack.orientation = .vertical
        tokenStack.alignment = .leading
        tokenStack.spacing = 8
        tokenStack.translatesAutoresizingMaskIntoConstraints = false
        let emailColumn = makeInputColumn(label: "Email", field: emailField)
        let passwordColumn = makeInputColumn(label: "Password", field: passwordField)
        tokenStack.addArrangedSubview(emailColumn)
        tokenStack.addArrangedSubview(passwordColumn)
        container.addArrangedSubview(tokenStack)
        tokenStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        emailColumn.widthAnchor.constraint(equalTo: tokenStack.widthAnchor).isActive = true
        passwordColumn.widthAnchor.constraint(equalTo: tokenStack.widthAnchor).isActive = true

        view.addSubview(saveButton)
        saveButton.target = self
        saveButton.action = #selector(saveCredentials)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20).isActive = true
        saveButton.leadingAnchor.constraint(equalTo: tokenStack.leadingAnchor).isActive = true
        saveButton.trailingAnchor.constraint(equalTo: tokenStack.trailingAnchor).isActive = true
    }

    private func makeInputColumn(label: String, field: NSTextField) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        labelField.alignment = .left
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(labelField)
        column.addArrangedSubview(field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func applyInitialData() {
        let credentials = trackerController.currentCredentials()
        emailField.stringValue = credentials.sanitizedEmail
        passwordField.stringValue = credentials.sanitizedPassword
    }

    private func subscribeToController() {
        stateListenerID = trackerController.addStateListener { [weak self] state in
            self?.updateButtonEnabled(for: state)
        }
    }

    private func updateButtonEnabled(for state: TrackerController.TrackerState) {
        saveButton.isEnabled = state != .loading
    }

    @objc private func saveCredentials() {
        trackerController.updateCredentials(email: emailField.stringValue, password: passwordField.stringValue)
    }
}

final class TrackerViewController: NSViewController {
    private let trackerController: TrackerController
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private let projectPopup = NSPopUpButton()
    private let logTextView = NSTextView()
    private var stateListenerID: UUID?
    private var logListenerID: UUID?
    private var projectListenerID: UUID?
    private var currentState: TrackerController.TrackerState = .loading

    init(trackerController: TrackerController) {
        self.trackerController = trackerController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let stateListenerID {
            trackerController.removeStateListener(stateListenerID)
        }
        if let logListenerID {
            trackerController.removeLogListener(logListenerID)
        }
        if let projectListenerID {
            trackerController.removeProjectListener(projectListenerID)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        applyInitialData()
        subscribeToController()
    }

    private func configureUI() {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.spacing = 20
        container.alignment = .leading
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byWordWrapping
        container.addArrangedSubview(statusLabel)

        projectPopup.target = self
        projectPopup.action = #selector(projectSelectionChanged)
        projectPopup.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(projectPopup)
        projectPopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 20).isActive = true
        projectPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20).isActive = true

        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.backgroundColor = NSColor.textBackgroundColor
        logTextView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = logTextView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        container.addArrangedSubview(scrollView)
    }

    private func applyInitialData() {
        updateLogView(with: trackerController.currentLogs())
        updateProjectOptions(trackerController.currentProjects())
    }

    private func subscribeToController() {
        stateListenerID = trackerController.addStateListener { [weak self] state in
            self?.updateStatusLabel(for: state)
        }
        logListenerID = trackerController.addLogListener { [weak self] logs in
            self?.updateLogView(with: logs)
        }
        projectListenerID = trackerController.addProjectListener { [weak self] projects in
            self?.updateProjectOptions(projects)
        }
    }

    private func updateStatusLabel(for state: TrackerController.TrackerState) {
        statusLabel.stringValue = state.displayDescription
        currentState = state
        switch state {
        case .error:
            statusLabel.textColor = NSColor.systemRed
        default:
            statusLabel.textColor = NSColor.labelColor
        }
        updateProjectEnabledState()
    }

    private func updateLogView(with logs: [String]) {
        logTextView.string = logs.joined(separator: "\n")
        if let textLength = logTextView.textStorage?.length, textLength > 0 {
            logTextView.scrollRangeToVisible(NSRange(location: textLength - 1, length: 1))
        }
    }

    private func updateProjectOptions(_ projects: [TrackerController.Project]) {
        projectPopup.removeAllItems()
        guard projects.isEmpty == false else {
            projectPopup.addItem(withTitle: "No projects")
            projectPopup.isEnabled = false
            return
        }
        projectPopup.isEnabled = true
        let noneItem = NSMenuItem(title: "No project", action: nil, keyEquivalent: "")
        noneItem.representedObject = NSNull()
        projectPopup.menu?.addItem(noneItem)
        for project in projects {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.representedObject = project.id
            item.toolTip = "Project ID: \(project.id)"
            projectPopup.menu?.addItem(item)
        }
        let selectedId = trackerController.currentProjectId()
        if let selectedId,
           let item = projectPopup.itemArray.first(where: { ($0.representedObject as? Int) == selectedId }) {
            projectPopup.select(item)
        } else {
            projectPopup.select(noneItem)
            trackerController.updateSelectedProjectId(nil)
        }
        updateProjectEnabledState()
    }

    private func makePopupRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(popup)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func updateProjectEnabledState() {
        if currentState == .started {
            projectPopup.isEnabled = false
        } else if projectPopup.itemArray.first?.title == "No projects" {
            projectPopup.isEnabled = false
        } else {
            projectPopup.isEnabled = true
        }
    }

    @objc private func projectSelectionChanged() {
        guard let selectedItem = projectPopup.selectedItem else {
            trackerController.updateSelectedProjectId(nil)
            return
        }
        if selectedItem.representedObject is NSNull {
            trackerController.updateSelectedProjectId(nil)
            return
        }
        if let projectId = selectedItem.representedObject as? Int {
            trackerController.updateSelectedProjectId(projectId)
        } else {
            trackerController.updateSelectedProjectId(nil)
        }
    }
}

private final class StatusIconProvider {
    private enum StatusKind: Hashable {
        case loading
        case started
        case stopped
        case error
    }

    private var cache: [StatusKind: NSImage] = [:]

    func icon(for state: TrackerController.TrackerState) -> NSImage {
        let kind: StatusKind
        switch state {
        case .loading:
            kind = .loading
        case .started:
            kind = .started
        case .stopped:
            kind = .stopped
        case .error:
            kind = .error
        }
        if let cached = cache[kind] {
            return cached
        }
        let imageName: String
        switch kind {
        case .loading:
            imageName = "ellipsis"
        case .started:
            imageName = "stop.fill"
        case .stopped:
            imageName = "play.fill"
        case .error:
            imageName = "exclamationmark.triangle"
        }
        let image: NSImage
        if kind == .started {
            image = makeSymbolImage(named: imageName, tintColor: .calamariRed)
        } else {
            image = makeSymbolImage(named: imageName, tintColor: nil)
        }
        cache[kind] = image
        return image
    }

    private func makeSymbolImage(named name: String, tintColor: NSColor?) -> NSImage {
        if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            var configured = symbolImage.withSymbolConfiguration(configuration) ?? symbolImage
            if let tintColor {
                configured = configured.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [tintColor])
                ) ?? configured
                configured.isTemplate = false
                return configured
            }
            configured.isTemplate = true
            return configured
        }
        let size = NSSize(width: 14, height: 14)
        let fallback = NSImage(size: size)
        fallback.isTemplate = true
        return fallback
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let trackerController = TrackerController()
    private let iconProvider = StatusIconProvider()
    private var statusItem: NSStatusItem?
    private var signOutMenuItem: NSMenuItem?
    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let openItem = NSMenuItem(title: "Open Tracker Window", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
        signOutItem.target = self
        signOutMenuItem = signOutItem
        menu.addItem(signOutItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }()
    private var mainWindow: NSWindow?
    private var mainWindowController: NSWindowController?
    private var stateListenerID: UUID?
    private var timeListenerID: UUID?
    private var authListenerID: UUID?
    private var currentState: TrackerController.TrackerState = .loading
    private var totalTimeText: String = "0:00"

    func applicationDidFinishLaunching(_ notification: Notification) {
//        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupMainWindow()
        trackerController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let stateListenerID {
            trackerController.removeStateListener(stateListenerID)
        }
        if let timeListenerID {
            trackerController.removeTimeListener(timeListenerID)
        }
        if let authListenerID {
            trackerController.removeAuthListener(authListenerID)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        _ = statusMenu
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = iconProvider.icon(for: .loading)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageLeft
        button.toolTip = "Calamari Tracker"
        stateListenerID = trackerController.addStateListener { [weak self] state in
            self?.currentState = state
            self?.updateStatusItem(for: state)
        }
        timeListenerID = trackerController.addTimeListener { [weak self] totalSeconds in
            guard let self else { return }
            self.totalTimeText = Self.formatTime(totalSeconds: totalSeconds)
            self.updateStatusItem(for: self.currentState)
        }
        updateSignOutState(isAuthenticated: trackerController.isAuthenticated())
        authListenerID = trackerController.addAuthListener { [weak self] isAuthenticated in
            self?.updateSignOutState(isAuthenticated: isAuthenticated)
        }
    }

    private func updateSignOutState(isAuthenticated: Bool) {
        signOutMenuItem?.isEnabled = isAuthenticated
    }

    private func setupMainWindow() {
        if mainWindow != nil { return }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowConfig.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = WindowConfig.minimumSize
        window.title = "Calamari Tracker"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let controller = MainWindowViewController(trackerController: trackerController)
        window.contentViewController = controller
        window.center()

        mainWindow = window
        mainWindowController = NSWindowController(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusItem(for state: TrackerController.TrackerState) {
        guard let button = statusItem?.button else { return }
        button.image = iconProvider.icon(for: state)
        let isAuthenticated = trackerController.isAuthenticated()
        if isAuthenticated, state == .started || state == .stopped {
            button.title = totalTimeText
        } else {
            button.title = ""
        }
        switch state {
        case .error(let message):
            button.toolTip = "Calamari Tracker — \(message)"
        default:
            button.toolTip = "Calamari Tracker — \(state.displayDescription)"
        }
    }

    private static func formatTime(totalSeconds: Int) -> String {
        let safeSeconds = max(0, totalSeconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            if let button = statusItem?.button {
                let origin = NSPoint(x: 0, y: button.bounds.height + 2)
                statusMenu.popUp(positioning: nil, at: origin, in: button)
            }
        } else {
            if trackerController.isAuthenticated() == false {
                openMainWindow()
                return
            }
            trackerController.handleStatusItemTap()
        }
    }

    @objc private func openMainWindow() {
        if mainWindow == nil {
            setupMainWindow()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func signOut() {
        Task { @MainActor in
            if currentState == .started {
                try await trackerController.runStop()
            }
            trackerController.signOut()
            openMainWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == mainWindow {
            mainWindow = nil
            mainWindowController = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }
}

let app = Application.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
