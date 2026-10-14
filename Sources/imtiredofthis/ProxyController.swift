import AppKit
import Network
import NetworkExtension
import Observation
import ProxyCore
import SystemExtensions

/// The proxy, as macOS runs it: the system extension, which has to be installed and allowed once,
/// and the proxy configuration, which macOS keeps on through restarts and network changes.
@MainActor
@Observable
final class ProxyController: NSObject {
    static let extensionID = "com.yekta.imtiredofthis.proxy"

    enum Setup: Equatable {
        case ready
        case installing
        case needsApproval
        case needsApplicationsFolder
        case needsRestart
        case failed(String)
    }

    private(set) var setup = Setup.ready
    private(set) var status = NEVPNStatus.disconnected
    /// Whether the user has turned the proxy on; macOS keeps it connected while it is.
    private(set) var isEnabled = false
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var upload: Double = 0
    private(set) var download: Double = 0
    private(set) var connections = 0
    private(set) var latency: Duration?
    private(set) var isServerReachable = true
    private(set) var serverError: String?

    @ObservationIgnored var onChange: (() -> Void)?
    /// The config as it is now, read when it is saved, since turning on can wait on the user.
    @ObservationIgnored var config: () -> ProxyConfig = { ProxyConfig() }
    @ObservationIgnored private var manager: NETransparentProxyManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var needsApply = false
    @ObservationIgnored private var activations: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var lastStats: (stats: ProxyStats, at: Date)?
    @ObservationIgnored private var monitorTimer: Timer?
    @ObservationIgnored private var monitoredServer: Server?

    var isConnected: Bool { status == .connected }

    /// Picks up the proxy as it was left, and brings the extension up to date with this version
    /// of the app.
    func load() async {
        // Turning the proxy off in System Settings changes the configuration under us.
        configurationObserver = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy else { return }
                Task { await self.reload() }
            }
        }
        guard await reload() else { return }
        try? await activate()
    }

    @discardableResult
    private func reload() async -> Bool {
        let managers = (try? await NETransparentProxyManager.loadAllFromPreferences()) ?? []
        guard let manager = managers.first else {
            self.manager = nil
            isEnabled = false
            changed()
            return false
        }
        adopt(manager)
        return true
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        changed()
        defer {
            isBusy = false
            changed()
            if needsApply {
                needsApply = false
                Task { await apply() }
            }
        }
        do {
            if enabled {
                try await activate()
            }
            guard enabled || manager != nil else { return }
            let manager = manager ?? NETransparentProxyManager()
            try configure(manager, config: config(), enabled: enabled)
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            adopt(manager)
            if enabled {
                try manager.connection.startVPNTunnel()
            } else {
                manager.connection.stopVPNTunnel()
            }
            isEnabled = enabled
            error = nil
        } catch {
            // An extension that isn't allowed yet shows as the setup step, not as an error.
            guard setup == .ready else { return }
            self.error = Self.describe(error)
        }
    }

    /// Saves a changed config, and hands it to the running proxy without dropping connections.
    func apply() async {
        guard !isBusy else {
            needsApply = true
            return
        }
        guard let manager else { return }
        let config = config()
        do {
            try configure(manager, config: config, enabled: isEnabled)
            try await manager.saveToPreferences()
            let message = try JSONEncoder().encode(ProviderMessage.config(config))
            try? (manager.connection as? NETunnelProviderSession)?.sendProviderMessage(message)
        } catch {
            self.error = Self.describe(error)
            changed()
        }
    }

    private func configure(_ manager: NETransparentProxyManager, config: ProxyConfig, enabled: Bool) throws {
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = Self.extensionID
        configuration.serverAddress = (try? Server(link: config.server))?.address.description ?? "Not set"
        configuration.providerConfiguration = ["config": try JSONEncoder().encode(config)]
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "imtiredofthis"
        manager.isEnabled = enabled
        manager.onDemandRules = [NEOnDemandRuleConnect()]
        manager.isOnDemandEnabled = enabled
    }

    private func adopt(_ manager: NETransparentProxyManager) {
        self.manager = manager
        isEnabled = manager.isEnabled && manager.isOnDemandEnabled
        status = manager.connection.status
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let manager = self.manager else { return }
                self.status = manager.connection.status
                self.changed()
            }
        }
        changed()
    }

    // MARK: The system extension

    /// Installs or updates the extension. It finishes once the user has allowed it.
    private func activate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            activations.append(continuation)
            guard activations.count == 1 else { return }
            setup = .installing
            changed()
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finishActivation(_ setup: Setup, error: Error?) {
        self.setup = setup
        let waiting = activations
        activations.removeAll()
        for continuation in waiting {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
        changed()
    }

    func openApprovalSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Live numbers

    /// While the panel shows: the speeds every second, the server's latency every few.
    func startMonitoring(_ server: Server?) {
        monitoredServer = server
        stopMonitoring()
        lastStats = nil
        var tick = 0
        refreshStats()
        probeLatency()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                tick += 1
                self.refreshStats()
                if tick % 5 == 0 {
                    self.probeLatency()
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func refreshStats() {
        guard isConnected, let session = manager?.connection as? NETunnelProviderSession,
              let message = try? JSONEncoder().encode(ProviderMessage.stats) else {
            upload = 0
            download = 0
            connections = 0
            return
        }
        try? session.sendProviderMessage(message) { [weak self] response in
            guard let response, let stats = try? JSONDecoder().decode(ProxyStats.self, from: response) else { return }
            DispatchQueue.main.async {
                self?.received(stats)
            }
        }
    }

    private func received(_ stats: ProxyStats) {
        let now = Date()
        if let last = lastStats, stats.sent >= last.stats.sent, stats.received >= last.stats.received {
            let seconds = max(now.timeIntervalSince(last.at), 0.1)
            upload = Double(stats.sent - last.stats.sent) / seconds
            download = Double(stats.received - last.stats.received) / seconds
        }
        lastStats = (stats, now)
        connections = stats.connections
        serverError = stats.lastError
    }

    /// How long a TCP handshake with the server takes, which is about one round trip.
    private func probeLatency() {
        guard let server = monitoredServer else {
            latency = nil
            return
        }
        let started = ContinuousClock.now
        let connection = NWConnection(to: server.address.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            let result: Duration?
            switch state {
            case .ready: result = started.duration(to: .now)
            case .failed, .waiting: result = nil
            default: return
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
            DispatchQueue.main.async {
                self?.latency = result
                self?.isServerReachable = result != nil
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func changed() {
        onChange?()
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NEVPNErrorDomain, error.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "macOS didn't let imtiredofthis add its proxy. Turn it on again and choose Allow."
        }
        return error.localizedDescription
    }
}

extension ProxyController: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            setup = .needsApproval
            changed()
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            guard result == .completed else {
                return finishActivation(.needsRestart, error: CocoaError(.featureUnsupported))
            }
            finishActivation(.ready, error: nil)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let code = (error as? OSSystemExtensionError)?.code
            switch code {
            case .unsupportedParentBundleLocation:
                finishActivation(.needsApplicationsFolder, error: error)
            case .requestCanceled, .requestSuperseded:
                finishActivation(.ready, error: error)
            default:
                finishActivation(.failed(error.localizedDescription), error: error)
            }
        }
    }
}
