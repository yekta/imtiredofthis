import Foundation
import Network
import NetworkExtension
import PacketStack
import ProxyCore
import WidgetKit

/// The VPN: every app's packets come here, and go through the VLESS server. The local network
/// stays outside the tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var proxy: PacketProxy?

    enum Failure: Error, LocalizedError {
        case noServer
        case unresolved(String)

        var errorDescription: String? {
            switch self {
            case .noServer: return "Routey has no server to connect to."
            case let .unresolved(host): return "Routey couldn't find \(host)."
            }
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        guard let data = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? Data,
              let config = try? JSONDecoder().decode(ProxyConfig.self, from: data),
              let server = try? VLESSServer(link: config.vless.server) else { throw Failure.noServer }
        // Looked up before the tunnel's DNS, which needs the server, is in place.
        let ip = try await Self.resolve(server.host)
        try await setTunnelNetworkSettings(Self.settings(serverIP: ip))

        let proxy = PacketProxy(upstream: .vless(server.connecting(to: ip)))
        proxy.onOutput = { [weak self] packets, protocols in
            autoreleasepool {
                _ = self?.packetFlow.writePackets(packets, withProtocols: protocols)
            }
        }
        proxy.start()
        self.proxy = proxy
        readPackets(into: proxy)
        reloadWidgets()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        proxy?.stop()
        proxy = nil
        reloadWidgets()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(ProviderMessage.self, from: messageData),
              case .stats = message, let proxy else { return nil }
        var stats = ProxyStats()
        stats.vless = proxy.totals
        return try? JSONEncoder().encode(stats)
    }

    private func readPackets(into proxy: PacketProxy) {
        packetFlow.readPackets { [weak self, weak proxy] packets, _ in
            guard let self, let proxy, self.proxy === proxy else { return }
            autoreleasepool {
                proxy.input(packets)
            }
            self.readPackets(into: proxy)
        }
    }

    /// The widgets and the control only learn the VPN changed when told.
    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    private static func settings(serverIP: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIP)

        // The same ranges Address.isLocal keeps direct.
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"])
        ipv4.includedRoutes = [.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
        ]
        let ipv6 = NEIPv6Settings(addresses: ["fd00:7969:7464::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [.default()]
        ipv6.excludedRoutes = [
            NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
            NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
            NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8),
        ]
        if IPv4Address(serverIP) != nil {
            ipv4.excludedRoutes?.append(NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255"))
        } else {
            ipv6.excludedRoutes?.append(NEIPv6Route(destinationAddress: serverIP, networkPrefixLength: 128))
        }
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [PacketProxy.dnsServer])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500
        return settings
    }

    /// The server's first address, as the system orders them.
    private static func resolve(_ host: String) async throws -> String {
        guard IPv4Address(host) == nil, IPv6Address(host) == nil else { return host }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var results: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &results) == 0, let first = results else {
                    return continuation.resume(throwing: Failure.unresolved(host))
                }
                defer { freeaddrinfo(results) }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else {
                    return continuation.resume(throwing: Failure.unresolved(host))
                }
                continuation.resume(returning: String(cString: name))
            }
        }
    }
}
