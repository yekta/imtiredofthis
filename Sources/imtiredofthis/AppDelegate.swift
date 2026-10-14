import AppKit

/// What the menus do, shared by the menu bar item and the main menu.
@MainActor
final class AppActions: NSObject {
    var statusItem: StatusItemController?
    var updater: Updater?

    @objc func showSettings() {
        statusItem?.showPanel()
    }

    @objc func checkForUpdates() {
        Task { await updater?.check() }
    }

    @objc func installUpdate() {
        Task { await updater?.install() }
    }

    @objc func showAbout() {
        NSApp.activate()
        let link = NSAttributedString(
            string: "github.com/yekta/imtiredofthis",
            attributes: [.link: Updater.repository, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: link])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let actions = AppActions()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(actions: actions)
        actions.updater = model.updater
        let statusItem = StatusItemController(model: model, actions: actions)
        self.statusItem = statusItem
        actions.statusItem = statusItem
        model.onChange = { [weak statusItem] in statusItem?.update() }
        model.proxy.onChange = { [weak statusItem] in statusItem?.update() }
        model.updater.onChange = { [weak statusItem] in statusItem?.update() }
        statusItem.update()
        model.start()
        model.updater.start()

        guard model.isFirstLaunch || !model.canTurnOn else { return }
        DispatchQueue.main.async { statusItem.showPanel() }
    }

    /// Opening the app again, from Finder or Spotlight, drops its settings down from the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        actions.showSettings()
        return false
    }
}

enum MainMenu {
    @MainActor
    static func make(actions: AppActions) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(item("About imtiredofthis", #selector(AppActions.showAbout), target: actions))
        app.addItem(item("Check for Updates…", #selector(AppActions.checkForUpdates), target: actions))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppActions.showSettings), key: ",", target: actions))
        app.addItem(.separator())
        app.addItem(item("Hide imtiredofthis", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(item("Quit imtiredofthis", #selector(NSApplication.terminate(_:)), key: "q"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "Z"))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))

        for (title, menu) in [("imtiredofthis", app), ("Edit", edit), ("Window", window)] {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
