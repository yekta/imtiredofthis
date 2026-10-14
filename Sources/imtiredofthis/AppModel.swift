import AppKit
import Observation
import ProxyCore
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let config = "config"
        static let hasLaunched = "hasLaunched"
    }

    var config: ProxyConfig {
        didSet {
            guard config != oldValue else { return }
            save()
            Task { await proxy.apply() }
            onChange?()
        }
    }

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginItemError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored let isFirstLaunch: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored let proxy = ProxyController()

    init() {
        config = defaults.data(forKey: Key.config).flatMap { try? JSONDecoder().decode(ProxyConfig.self, from: $0) } ?? ProxyConfig()
        isFirstLaunch = !defaults.bool(forKey: Key.hasLaunched)
        defaults.set(true, forKey: Key.hasLaunched)
        proxy.config = { [unowned self] in config }
    }

    func start() {
        if isFirstLaunch {
            setLaunchAtLogin(true)
        }
        Task { await proxy.load() }
    }

    /// The server the config's link describes, or why it doesn't.
    var server: Result<Server, Error>? {
        guard !config.server.isEmpty else { return nil }
        return Result { try Server(link: config.server) }
    }

    var validServer: Server? {
        try? server?.get()
    }

    var canTurnOn: Bool {
        validServer != nil && !config.apps.isEmpty
    }

    func setEnabled(_ enabled: Bool) {
        Task { await proxy.setEnabled(enabled) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Apps

    func routes(_ bundleID: String) -> Bool {
        config.apps.contains(bundleID)
    }

    func add(_ bundleID: String) {
        guard !routes(bundleID) else { return }
        config.apps.append(bundleID)
        config.apps.sort { AppEntry(bundleID: $0).name.localizedStandardCompare(AppEntry(bundleID: $1).name) == .orderedAscending }
    }

    func remove(_ bundleID: String) {
        config.apps.removeAll { $0 == bundleID }
    }

    // MARK: The config file

    func importConfig(from url: URL) throws {
        let imported = try JSONDecoder().decode(ProxyConfig.self, from: Data(contentsOf: url))
        if !imported.server.isEmpty {
            _ = try Server(link: imported.server)
        }
        config = imported
    }

    func exportConfig(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Key.config)
    }
}

/// An app in the list, by its bundle identifier, with its name and icon when it is installed.
struct AppEntry: Identifiable {
    let bundleID: String
    let url: URL?

    var id: String { bundleID }

    init(bundleID: String) {
        self.bundleID = bundleID
        url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    init?(url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        self.bundleID = bundleID
        self.url = url
    }

    var name: String {
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var icon: NSImage {
        guard let url else { return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
