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
            if appliesChanges {
                Task { await proxy.apply() }
            }
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
    /// Off while a switch turns the proxy itself on or off, which saves the config as it goes.
    @ObservationIgnored private var appliesChanges = true

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

    /// The Shadowsocks server the config's link describes, or why it doesn't.
    var shadowsocksServer: Result<Server, Error>? {
        guard !config.shadowsocks.server.isEmpty else { return nil }
        return Result { try Server(link: config.shadowsocks.server) }
    }

    /// The VLESS server the config's link describes, or why it doesn't.
    var vlessServer: Result<VLESSServer, Error>? {
        guard !config.vless.server.isEmpty else { return nil }
        return Result { try VLESSServer(link: config.vless.server) }
    }

    /// The servers whose speeds and latency the panel shows.
    var servers: [UpstreamKind: Address] {
        var servers: [UpstreamKind: Address] = [:]
        servers[.shadowsocks] = (try? shadowsocksServer?.get())?.address
        servers[.vless] = (try? vlessServer?.get())?.address
        return servers
    }

    func canTurnOn(_ kind: UpstreamKind) -> Bool {
        switch kind {
        case .shadowsocks: return (try? shadowsocksServer?.get()) != nil && !config.shadowsocks.apps.isEmpty
        case .vless: return (try? vlessServer?.get()) != nil
        }
    }

    func isOn(_ kind: UpstreamKind) -> Bool {
        proxy.isEnabled && config.isOn(kind)
    }

    func isTurningOn(_ kind: UpstreamKind) -> Bool {
        proxy.isTurningOn && config.isOn(kind)
    }

    /// Turns Shadowsocks or VLESS on or off. The proxy runs while either is on.
    func setOn(_ kind: UpstreamKind, _ on: Bool) {
        var updated = config
        if on, !proxy.isEnabled {
            updated.shadowsocks.isOn = false
            updated.vless.isOn = false
        }
        switch kind {
        case .shadowsocks: updated.shadowsocks.isOn = on
        case .vless: updated.vless.isOn = on
        }
        let runsProxy = updated.shadowsocks.isOn || updated.vless.isOn
        guard runsProxy != proxy.isEnabled else {
            config = updated
            return
        }
        appliesChanges = false
        config = updated
        appliesChanges = true
        Task { await proxy.setEnabled(runsProxy) }
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
        config.shadowsocks.apps.contains(bundleID)
    }

    func add(_ bundleID: String) {
        guard !routes(bundleID) else { return }
        config.shadowsocks.apps.append(bundleID)
        config.shadowsocks.apps.sort { AppEntry(bundleID: $0).name.localizedStandardCompare(AppEntry(bundleID: $1).name) == .orderedAscending }
    }

    func remove(_ bundleID: String) {
        config.shadowsocks.apps.removeAll { $0 == bundleID }
    }

    // MARK: The config file

    func importConfig(from url: URL) throws {
        var imported = try JSONDecoder().decode(ProxyConfig.self, from: Data(contentsOf: url))
        if !imported.shadowsocks.server.isEmpty {
            _ = try Server(link: imported.shadowsocks.server)
        }
        if !imported.vless.server.isEmpty {
            _ = try VLESSServer(link: imported.vless.server)
        }
        // What is on stays as it is; the file only brings the servers and apps.
        imported.shadowsocks.isOn = config.shadowsocks.isOn
        imported.vless.isOn = config.vless.isOn
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

extension ProxyConfig {
    func isOn(_ kind: UpstreamKind) -> Bool {
        kind == .shadowsocks ? shadowsocks.isOn : vless.isOn
    }
}

extension UpstreamKind {
    var title: String {
        switch self {
        case .shadowsocks: return "Shadowsocks"
        case .vless: return "VLESS"
        }
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
