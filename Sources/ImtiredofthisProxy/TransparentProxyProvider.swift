import Foundation
import Network
import NetworkExtension
import os
import ProxyCore

let log = Logger(subsystem: "com.yekta.imtiredofthis.proxy", category: "proxy")

/// macOS hands this every new outgoing connection. Those of the chosen apps go through the
/// server; everything else is handed straight back and never passes through here.
@objc(TransparentProxyProvider)
final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var config = ProxyConfig()
        var server: Server?
        var relays: [ObjectIdentifier: AnyObject] = [:]
        var stats = ProxyStats()
    }

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let saved = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? Data
        apply(saved.flatMap { try? JSONDecoder().decode(ProxyConfig.self, from: $0) } ?? ProxyConfig())

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
        ]
        setTunnelNetworkSettings(settings) { error in
            if let error {
                log.error("Couldn't apply the proxy settings: \(error.localizedDescription, privacy: .public)")
            }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let relays = state.withLock { state in
            defer { state.relays.removeAll() }
            return Array(state.relays.values)
        }
        for relay in relays {
            (relay as? Closable)?.close()
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let message = try? JSONDecoder().decode(ProviderMessage.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch message {
        case .stats:
            completionHandler?(try? JSONEncoder().encode(state.withLock { $0.stats }))
        case let .config(config):
            apply(config)
            completionHandler?(nil)
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let server = server(for: flow) else { return false }
        if let udp = flow as? NEAppProxyUDPFlow {
            return relay(udp, server: server)
        }
        guard let tcp = flow as? NEAppProxyTCPFlow,
              let target = Address(tcp.remoteFlowEndpoint), !target.isLocal else { return false }
        let relay = TCPRelay(flow: tcp, target: target, server: server, events: self)
        retain(relay)
        relay.start()
        return true
    }

    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        guard let server = server(for: flow),
              let target = Address(remoteEndpoint), !target.isLocal else { return false }
        return relay(flow, server: server)
    }

    private func relay(_ flow: NEAppProxyUDPFlow, server: Server) -> Bool {
        let relay = UDPRelay(flow: flow, server: server, events: self)
        retain(relay)
        relay.start()
        return true
    }

    private func server(for flow: NEAppProxyFlow) -> Server? {
        let identifier = flow.metaData.sourceAppSigningIdentifier
        return state.withLock { state in
            guard let server = state.server, state.config.routes(identifier) else { return nil }
            return server
        }
    }

    private func apply(_ config: ProxyConfig) {
        let server: Server?
        do {
            server = try Server(link: config.server)
        } catch {
            server = nil
            log.error("No server: \(error.localizedDescription, privacy: .public)")
        }
        state.withLock { state in
            state.config = config
            state.server = server
        }
        log.info("Routing \(config.apps.count) apps through \(server?.address.description ?? "nothing", privacy: .public)")
    }

    private func retain(_ relay: AnyObject) {
        state.withLock { state in
            state.relays[ObjectIdentifier(relay)] = relay
            state.stats.connections += 1
        }
    }
}

protocol Closable: AnyObject {
    func close()
}

/// What relays report back: bytes moved, failures, and when they are done.
protocol RelayEvents: AnyObject {
    func relayed(sent: Int, received: Int)
    func relayFailed(_ error: Error)
    func relayClosed(_ relay: AnyObject)
}

extension TransparentProxyProvider: RelayEvents {
    func relayed(sent: Int, received: Int) {
        state.withLock { state in
            state.stats.sent += UInt64(sent)
            state.stats.received += UInt64(received)
            if received > 0 {
                state.stats.lastError = nil
            }
        }
    }

    func relayFailed(_ error: Error) {
        log.error("Through the server: \(error.localizedDescription, privacy: .public)")
        state.withLock { $0.stats.lastError = error.localizedDescription }
    }

    func relayClosed(_ relay: AnyObject) {
        state.withLock { state in
            guard state.relays.removeValue(forKey: ObjectIdentifier(relay)) != nil else { return }
            state.stats.connections -= 1
        }
    }
}
