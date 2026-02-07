import Cocoa

private enum WindowConfig {
    static let defaultSize = NSSize(width: 540, height: 420)
    static let minimumSize = NSSize(width: 480, height: 320)
}

final class MainWindowViewController: NSViewController {
    private let trackerController: TrackerController
    private let statusLabel = NSTextField(labelWithString: "Status: Loading…")
    private let loginContainer = NSStackView()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let saveButton = NSButton(title: "Save Credentials", target: nil, action: nil)
    private let logTextView = NSTextView()
    private var stateListenerID: UUID?
    private var logListenerID: UUID?
    private var authListenerID: UUID?

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
        configureUI()
        applyInitialData()
        subscribeToController()
    }

    private func configureUI() {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.spacing = 12
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

        emailField.placeholderString = "email"
        passwordField.placeholderString = "password"
        [emailField, passwordField].forEach { field in
            field.translatesAutoresizingMaskIntoConstraints = false
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }

        loginContainer.orientation = .vertical
        loginContainer.alignment = .leading
        loginContainer.spacing = 12
        loginContainer.translatesAutoresizingMaskIntoConstraints = false

        let tokenStack = NSStackView()
        tokenStack.orientation = .vertical
        tokenStack.alignment = .leading
        tokenStack.spacing = 8
        tokenStack.translatesAutoresizingMaskIntoConstraints = false
        tokenStack.addArrangedSubview(makeInputRow(label: "Email", field: emailField))
        tokenStack.addArrangedSubview(makeInputRow(label: "Password", field: passwordField))
        loginContainer.addArrangedSubview(tokenStack)

        saveButton.target = self
        saveButton.action = #selector(saveCredentials)
        saveButton.keyEquivalent = "\r"
        
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(saveButton)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)
        loginContainer.addArrangedSubview(buttonRow)
        container.addArrangedSubview(loginContainer)

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

    private func makeInputRow(label: String, field: NSTextField) -> NSStackView {
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
        row.addArrangedSubview(field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func applyInitialData() {
        let credentials = trackerController.currentCredentials()
        emailField.stringValue = credentials.sanitizedEmail
        passwordField.stringValue = credentials.sanitizedPassword
        updateLogView(with: trackerController.currentLogs())
        updateLoginVisibility(isAuthenticated: trackerController.isAuthenticated())
    }

    private func subscribeToController() {
        stateListenerID = trackerController.addStateListener { [weak self] state in
            self?.updateStatusLabel(for: state)
        }
        logListenerID = trackerController.addLogListener { [weak self] logs in
            self?.updateLogView(with: logs)
        }
        authListenerID = trackerController.addAuthListener { [weak self] isAuthenticated in
            self?.updateLoginVisibility(isAuthenticated: isAuthenticated)
        }
    }

    private func updateStatusLabel(for state: TrackerController.TrackerState) {
        statusLabel.stringValue = "Status: \(state.displayDescription)"
        switch state {
        case .error:
            statusLabel.textColor = NSColor.systemRed
        default:
            statusLabel.textColor = NSColor.labelColor
        }
    }

    private func updateLogView(with logs: [String]) {
        logTextView.string = logs.joined(separator: "\n")
        if let textLength = logTextView.textStorage?.length, textLength > 0 {
            logTextView.scrollRangeToVisible(NSRange(location: textLength - 1, length: 1))
        }
    }

    private func updateLoginVisibility(isAuthenticated: Bool) {
        loginContainer.isHidden = isAuthenticated
    }

    @objc private func saveCredentials() {
        trackerController.updateCredentials(email: emailField.stringValue, password: passwordField.stringValue)
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
            imageName = "stop"
        case .stopped:
            imageName = "play"
        case .error:
            imageName = "exclamationmark.triangle"
        }
        let image = makeSymbolImage(named: imageName)
        cache[kind] = image
        return image
    }

    private func makeSymbolImage(named name: String) -> NSImage {
        if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            symbolImage.isTemplate = true
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            return symbolImage.withSymbolConfiguration(configuration) ?? symbolImage
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
    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Tracker Window", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }()
    private var mainWindow: NSWindow?
    private var mainWindowController: NSWindowController?
    private var stateListenerID: UUID?

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
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = iconProvider.icon(for: .loading)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Calamari Tracker"
        stateListenerID = trackerController.addStateListener { [weak self] state in
            self?.updateStatusItem(for: state)
        }
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
        switch state {
        case .error(let message):
            button.toolTip = "Calamari Tracker — \(message)"
        default:
            button.toolTip = "Calamari Tracker — \(state.displayDescription)"
        }
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
