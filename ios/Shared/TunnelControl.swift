import Foundation
import NetworkExtension
import ProxyCore
import WidgetKit

/// Where the VPN stands, as the app, the widgets and the control show it.
enum TunnelState: Equatable {
    case notSetUp
    case off
    case connecting
    case connected(since: Date?)
    case disconnecting

    var isOn: Bool {
        switch self {
        case .connecting, .connected: return true
        case .notSetUp, .off, .disconnecting: return false
        }
    }
}

enum TunnelError: Error, CustomLocalizedStringResourceConvertible {
    case notSetUp
    case notAllowed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp: return "Open Routey and paste your server's link first."
        case .notAllowed: return "Routey needs to add a VPN configuration. Turn it on again and choose Allow."
        }
    }
}

/// The config, kept in the app group so the widgets can read it too.
enum ConfigStore {
    private static let defaults = UserDefaults(suiteName: "group.org.routey.routey")
    private static let key = "config"

    static var config: ProxyConfig {
        get { defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(ProxyConfig.self, from: $0) } ?? ProxyConfig() }
        set { defaults?.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static var server: VLESSServer? {
        try? VLESSServer(link: config.vless.server)
    }
}

/// The one VPN configuration: made the first time it connects, kept connected on demand until it
/// is turned off. Used by the app and, from the widgets' process, by the intents.
enum TunnelControl {
    static let providerBundleIdentifier = "org.routey.routey.tunnel"

    static func state() async -> TunnelState {
        state(of: try? await loadManager())
    }

    static func state(of manager: NETunnelProviderManager?) -> TunnelState {
        guard ConfigStore.server != nil else { return .notSetUp }
        guard let manager else { return .off }
        switch manager.connection.status {
        case .connecting, .reasserting: return .connecting
        case .connected: return .connected(since: manager.connection.connectedDate)
        case .disconnecting: return .disconnecting
        default: return .off
        }
    }

    static func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first
    }

    /// Enables the configuration (another VPN may have been the enabled one), turns on demand on,
    /// and starts it.
    static func connect() async throws {
        let config = ConfigStore.config
        guard let server = ConfigStore.server else { throw TunnelError.notSetUp }
        let manager = try await loadManager() ?? NETunnelProviderManager()
        try await save(manager) { manager in
            try configure(manager, config: config, server: server)
            manager.isEnabled = true
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.isOnDemandEnabled = true
        }
        // A manager is stale right after it is saved.
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    /// Turns on demand off first; otherwise iOS connects again at once.
    static func disconnect() async throws {
        guard let manager = try await loadManager() else { return }
        try await save(manager) { $0.isOnDemandEnabled = false }
        manager.connection.stopVPNTunnel()
    }

    /// Saves a new config into the VPN configuration, if there is one, and restarts the VPN if it
    /// is on, so it takes the new server.
    static func apply(_ config: ProxyConfig) async throws {
        ConfigStore.config = config
        guard let server = try? VLESSServer(link: config.vless.server), let manager = try await loadManager() else { return }
        try await save(manager) { try configure($0, config: config, server: server) }
        guard [.connected, .connecting, .reasserting].contains(manager.connection.status) else { return }
        manager.connection.stopVPNTunnel()
        _ = await settledState()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    /// Waits up to ten seconds for the VPN to finish connecting or disconnecting.
    static func settledState() async -> TunnelState {
        var current = await state()
        for _ in 0..<40 {
            guard current == .connecting || current == .disconnecting else { break }
            try? await Task.sleep(for: .milliseconds(250))
            current = await state()
        }
        return current
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    private static func configure(_ manager: NETunnelProviderManager, config: ProxyConfig, server: VLESSServer) throws {
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = server.host
        configuration.providerConfiguration = ["config": try JSONEncoder().encode(config)]
        manager.protocolConfiguration = configuration
        manager.localizedDescription = server.name ?? "Routey"
    }

    /// Saves after `change`, once more if another process saved in between.
    private static func save(_ manager: NETunnelProviderManager, _ change: (NETunnelProviderManager) throws -> Void) async throws {
        do {
            try change(manager)
            try await manager.saveToPreferences()
        } catch let error as NEVPNError where error.code == .configurationStale {
            try await manager.loadFromPreferences()
            try change(manager)
            try await manager.saveToPreferences()
        } catch let error as NEVPNError where error.code == .configurationReadWriteFailed {
            throw TunnelError.notAllowed
        }
    }
}
