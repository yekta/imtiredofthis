import AppKit
import ProxyCore
import SwiftUI

/// The menu bar item. A click drops the panel down from it; a right click shows a short menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let model: AppModel
    private let actions: AppActions
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = NSPopover()
    private let menu = NSMenu()

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        super.init()

        panel.behavior = .transient
        panel.animates = true
        panel.delegate = self
        let content = NSHostingController(rootView: SettingsView(model: model))
        content.sizingOptions = []
        panel.contentViewController = content
        panel.contentSize = SettingsView.size

        menu.autoenablesItems = false
        menu.delegate = self

        guard let button = item.button else { return }
        button.image = LucideRoute.image()
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func update() {
        item.button?.appearsDisabled = !model.proxy.isConnected
    }

    func showPanel() {
        guard let button = item.button, !panel.isShown else { return }
        NSApp.activate()
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Unless its window is key, the panel's controls draw in their inactive grey.
        guard let window = panel.contentViewController?.view.window else { return }
        window.makeKey()
        window.makeFirstResponder(nil)
    }

    func popoverWillShow(_ notification: Notification) {
        model.proxy.startMonitoring(model.servers)
    }

    func popoverDidClose(_ notification: Notification) {
        model.proxy.stopMonitoring()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.performClose(nil)
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
            return
        }
        if panel.isShown {
            panel.performClose(nil)
        } else {
            showPanel()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let update = model.updater.available {
            let title = model.updater.isInstalling ? "Installing \(update.version)…" : "Install \(update.version) and Restart"
            let install = actionItem(title, #selector(AppActions.installUpdate))
            install.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            install.isEnabled = !model.updater.isInstalling
            menu.addItem(install)
            menu.addItem(.separator())
        }

        for kind in [UpstreamKind.shadowsocks, .vless] {
            let item = NSMenuItem(title: kind.title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.state = model.isOn(kind) ? .on : .off
            item.isEnabled = (model.isOn(kind) || model.canTurnOn(kind)) && !model.proxy.isBusy
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", #selector(AppActions.showSettings)))
        menu.addItem(actionItem("About imtiredofthis", #selector(AppActions.showAbout)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit imtiredofthis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = actions
        return item
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let kind = (sender.representedObject as? String).flatMap(UpstreamKind.init(rawValue:)) else { return }
        model.setOn(kind, !model.isOn(kind))
    }
}
