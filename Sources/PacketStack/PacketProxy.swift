import Foundation
import os
import ProxyCore

/// Every app's traffic from the tun, through one server: each TCP connection and each app's UDP
/// socket gets a relay. DNS sent to the tunnel's own address goes to a public resolver through
/// the server.
public final class PacketProxy {
    /// The tunnel's DNS server, an address that only exists inside the tunnel.
    public static let dnsServer = "198.18.0.2"

    /// Packets for the tun, with their protocols (`AF_INET` or `AF_INET6`).
    public var onOutput: (([Data], [NSNumber]) -> Void)? {
        get { stack.onOutput }
        set { stack.onOutput = newValue }
    }

    private let stack = PacketStack()
    private let upstream: Upstream
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var relays: [ObjectIdentifier: Closable] = [:]
        var datagramRelays: [Address: UDPRelay] = [:]
        var totals = ProxyStats.Totals()
    }

    public init(upstream: Upstream) {
        self.upstream = upstream
        stack.onAccept = { [weak self] connection in self?.relay(connection) }
        stack.onDatagram = { [weak self] datagram in self?.relay(datagram) }
    }

    public func start() {
        stack.start()
    }

    public func stop() {
        let relays = state.withLock { state in
            defer {
                state.relays.removeAll()
                state.datagramRelays.removeAll()
            }
            return Array(state.relays.values)
        }
        for relay in relays {
            relay.close()
        }
        stack.stop()
    }

    /// Packets read from the tun.
    public func input(_ packets: [Data]) {
        stack.input(packets)
    }

    public var totals: ProxyStats.Totals {
        state.withLock { $0.totals }
    }

    private func relay(_ connection: StackTCPConnection) {
        var target = connection.destination
        if target.port == 53, target == Address(name: Self.dnsServer, port: 53) {
            target = DNSLookup.resolver
        }
        guard !target.isLocal else { return connection.close() }
        let relay = TCPRelay(connection: connection, target: target, upstream: upstream, events: self)
        retain(relay)
        relay.start()
    }

    private func relay(_ datagram: UDPDatagram) {
        guard !datagram.destination.isLocal || datagram.destination.port == 53 else { return }
        let relay = state.withLock { state -> UDPRelay? in
            if let relay = state.datagramRelays[datagram.source] {
                return relay
            }
            let relay = UDPRelay(source: datagram.source, stack: stack, upstream: upstream, events: self)
            state.datagramRelays[datagram.source] = relay
            state.relays[ObjectIdentifier(relay)] = relay
            state.totals.connections += 1
            relay.start()
            return relay
        }
        relay?.send(datagram)
    }

    private func retain(_ relay: Closable) {
        state.withLock { state in
            state.relays[ObjectIdentifier(relay)] = relay
            state.totals.connections += 1
        }
    }
}

extension PacketProxy: RelayEvents {
    func relayed(sent: Int, received: Int) {
        state.withLock { state in
            state.totals.sent += UInt64(sent)
            state.totals.received += UInt64(received)
            if received > 0 {
                state.totals.lastError = nil
            }
        }
    }

    func relayFailed(_ error: Error) {
        state.withLock { $0.totals.lastError = error.localizedDescription }
    }

    func relayClosed(_ relay: AnyObject) {
        state.withLock { state in
            guard state.relays.removeValue(forKey: ObjectIdentifier(relay)) != nil else { return }
            state.totals.connections -= 1
            if let relay = relay as? UDPRelay, state.datagramRelays[relay.source] === relay {
                state.datagramRelays[relay.source] = nil
            }
        }
    }
}
