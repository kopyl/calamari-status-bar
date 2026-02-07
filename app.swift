import Cocoa

class Application: NSApplication {
    override init() {
        super.init()
        configureMenus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureMenus() {
        let mainMenu = NSMenu()

        // Application menu (Quit, Hide, etc.)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let hideItem = NSMenuItem(title: "Hide \(ProcessInfo.processInfo.processName)",
                                  action: #selector(hide(_:)),
                                  keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        hideItem.target = nil
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others",
                                        action: #selector(hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = nil
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All",
                                     action: #selector(unhideAllApplications(_:)),
                                     keyEquivalent: "")
        showAllItem.target = nil
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit \(ProcessInfo.processInfo.processName)",
                                  action: #selector(terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = nil
        appMenu.addItem(quitItem)

        // Edit menu with standard editing actions (enables Cmd+C/V, etc.)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "Undo",
                                  action: #selector(UndoManager.undo),
                                  keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo",
                                  action: #selector(UndoManager.redo),
                                  keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        let cutItem = NSMenuItem(title: "Cut",
                                 action: #selector(NSText.cut(_:)),
                                 keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy",
                                  action: #selector(NSText.copy(_:)),
                                  keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste",
                                   action: #selector(NSText.paste(_:)),
                                   keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "Select All",
                                       action: #selector(NSText.selectAll(_:)),
                                       keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)

        self.mainMenu = mainMenu
    }
}
