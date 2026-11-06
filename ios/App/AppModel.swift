import Foundation
import Network
import NetworkExtension
import Observation
import ProxyCore

/// The app's state: the config, where the VPN stands, and its live numbers while the app shows.
@MainActor
@Observable
final class AppModel {
    private(set) var config = ConfigStore.config
    private(set) var state = TunnelState.off
    private(set) var isBusy = false
    var error: String?
    private(set) var traffic = Traffic()

    struct Traffic: Equatable {
        var upload: Double = 0
        var download: Double = 0
        var connections = 0
        var latency: Duration?
        var serverError: String?
    }

    var server: Result<VLESSServer, Error>? {
        guard !config.vless.server.isEmpty else { return nil }
        return Result { try VLESSServer(link: config.vless.server) }
    }

    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var monitorTimer: Timer?
    @ObservationIgnored private var lastTotals: (totals: ProxyStats.Totals, at: Date)?

    init() {
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                TunnelControl.reloadWidgets()
            }
        }
    }

    func refresh() {
        Task {
            state = await TunnelControl.state()
        }
    }

    func setOn(_ on: Bool) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if on {
                    try await TunnelControl.connect()
                } else {
                    try await TunnelControl.disconnect()
                }
                error = nil
            } catch {
                self.error = (error as? TunnelError).map { String(localized: $0.localizedStringResource) } ?? error.localizedDescription
            }
            state = await TunnelControl.state()
            TunnelControl.reloadWidgets()
        }
    }

    /// A new vless:// link; nil if it works, the reason otherwise.
    func useLink(_ link: String) -> String? {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try VLESSServer(link: link)
        } catch {
            return error.localizedDescription
        }
        var config = config
        config.vless.server = link
        config.vless.isOn = true
        apply(config)
        return nil
    }

    // MARK: The config file

    /// Only the VLESS server is used here; the file's Shadowsocks part is kept for exporting.
    func importConfig(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var imported = try JSONDecoder().decode(ProxyConfig.self, from: Data(contentsOf: url))
        if !imported.vless.server.isEmpty {
            _ = try VLESSServer(link: imported.vless.server)
        }
        imported.vless.isOn = true
        apply(imported)
    }

    func exportedConfig() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    private func apply(_ config: ProxyConfig) {
        self.config = config
        ConfigStore.config = config
        TunnelControl.reloadWidgets()
        Task {
            do {
                try await TunnelControl.apply(config)
            } catch {
                self.error = error.localizedDescription
            }
            state = await TunnelControl.state()
        }
    }

    // MARK: Live numbers

    /// While the app shows: the speeds every second, the server's latency every five.
    func startMonitoring() {
        stopMonitoring()
        refresh()
        lastTotals = nil
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
        Task {
            guard case .connected = state,
                  let session = try? await TunnelControl.loadManager()?.connection as? NETunnelProviderSession,
                  let message = try? JSONEncoder().encode(ProviderMessage.stats) else {
                traffic.upload = 0
                traffic.download = 0
                traffic.connections = 0
                return
            }
            try? session.sendProviderMessage(message) { response in
                guard let response, let stats = try? JSONDecoder().decode(ProxyStats.self, from: response) else { return }
                DispatchQueue.main.async {
                    self.received(stats.vless)
                }
            }
        }
    }

    private func received(_ totals: ProxyStats.Totals) {
        let now = Date()
        if let last = lastTotals, totals.sent >= last.totals.sent, totals.received >= last.totals.received {
            let seconds = max(now.timeIntervalSince(last.at), 0.1)
            traffic.upload = Double(totals.sent - last.totals.sent) / seconds
            traffic.download = Double(totals.received - last.totals.received) / seconds
        }
        traffic.connections = totals.connections
        traffic.serverError = totals.lastError
        lastTotals = (totals, now)
    }

    /// How long a TCP handshake with the server takes, which is about one round trip.
    private func probeLatency() {
        guard case let .success(server) = server else {
            traffic.latency = nil
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
                self?.traffic.latency = result
            }
        }
        connection.start(queue: .global(qos: .utility))
    }
}
