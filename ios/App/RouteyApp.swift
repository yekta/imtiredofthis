import AppIntents
import SwiftUI

@main
struct RouteyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return model.stopMonitoring() }
            model.startMonitoring()
            TunnelControl.reloadWidgets()
        }
    }
}

/// Siri, Shortcuts and Spotlight.
struct RouteyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectIntent(), phrases: ["Connect \(.applicationName)", "Turn on \(.applicationName)"], shortTitle: "Connect", systemImageName: "power")
        AppShortcut(intent: DisconnectIntent(), phrases: ["Disconnect \(.applicationName)", "Turn off \(.applicationName)"], shortTitle: "Disconnect", systemImageName: "power")
    }
}
