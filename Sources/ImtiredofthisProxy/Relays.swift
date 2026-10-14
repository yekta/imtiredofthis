import Foundation
import Network
import NetworkExtension
import ProxyCore

/// One app's TCP connection, carried through the server. Its first data goes out with the
/// request; when the app speaks first with TLS, the server name in its hello becomes the target,
/// so the server looks the name up itself, past any local DNS tampering.
final class TCPRelay: Closable {
    /// How long to wait for the app to speak first before connecting without its data.
    private static let firstDataWait: DispatchTimeInterval = .milliseconds(150)
    /// How long one side may stay open after the other has finished.
    private static let halfCloseTimeout: DispatchTimeInterval = .seconds(60)

    private let flow: NEAppProxyTCPFlow
    private var target: Address
    private let server: Server
    private weak var events: RelayEvents?
    private let queue = DispatchQueue(label: "tcp-relay")
    private var tunnel: TunnelConnection?
    private var appDone = false
    private var serverDone = false
    private var closed = false

    init(flow: NEAppProxyTCPFlow, target: Address, server: Server, events: RelayEvents) {
        self.flow = flow
        self.server = server
        self.events = events
        if let name = flow.remoteHostname, !name.isEmpty {
            self.target = Address(name: name, port: target.port)
        } else {
            self.target = target
        }
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { [self] error in
            queue.async { [self] in
                if let error {
                    return close(error)
                }
                readFromApp()
                queue.asyncAfter(deadline: .now() + Self.firstDataWait) { [self] in
                    connect(sending: Data())
                }
            }
        }
    }

    private func connect(sending data: Data) {
        guard tunnel == nil, !closed else { return }
        if !target.isName, let name = TLS.serverName(in: data) {
            target = Address(name: name, port: target.port)
        }
        let tunnel = TunnelConnection(server: server, target: target, queue: queue)
        tunnel.onFailure = { [weak self] error in
            guard let self, !self.closed else { return }
            self.events?.relayFailed(error)
            self.close(error)
        }
        self.tunnel = tunnel
        tunnel.start(sending: data)
        events?.relayed(sent: data.count, received: 0)
        readFromServer()
    }

    private func readFromApp() {
        flow.readData { [self] data, error in
            queue.async { [self] in
                guard !closed else { return }
                if let error {
                    return close(error)
                }
                guard let data, !data.isEmpty else {
                    appDone = true
                    if tunnel == nil {
                        connect(sending: Data())
                    }
                    tunnel?.finishSending()
                    return closeIfDone()
                }
                guard let tunnel else {
                    connect(sending: data)
                    return readFromApp()
                }
                tunnel.send(data) { [self] error in
                    if let error {
                        return close(error)
                    }
                    events?.relayed(sent: data.count, received: 0)
                    readFromApp()
                }
            }
        }
    }

    private func readFromServer() {
        tunnel?.receive { [self] result in
            guard !closed else { return }
            switch result {
            case let .failure(error):
                events?.relayFailed(error)
                close(error)
            case .success(nil):
                serverDone = true
                flow.closeWriteWithError(nil)
                closeIfDone()
            case let .success(data?):
                flow.write(data) { [self] error in
                    queue.async { [self] in
                        if let error {
                            return close(error)
                        }
                        events?.relayed(sent: 0, received: data.count)
                        readFromServer()
                    }
                }
            }
        }
    }

    private func closeIfDone() {
        guard appDone, serverDone else {
            queue.asyncAfter(deadline: .now() + Self.halfCloseTimeout) { [self] in close(nil) }
            return
        }
        close(nil)
    }

    func close() {
        queue.async { [self] in close(nil) }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        tunnel?.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        events?.relayClosed(self)
    }
}

/// One app's UDP socket, its packets carried through the server to wherever each one goes. Ends
/// when the app closes it, or after a while without packets.
final class UDPRelay: Closable {
    private static let idleTimeout: TimeInterval = 120

    private let flow: NEAppProxyUDPFlow
    private weak var events: RelayEvents?
    private let queue = DispatchQueue(label: "udp-relay")
    private let server: Server
    private let tunnel: PacketTunnel
    private var lookups: [ObjectIdentifier: DNSLookup] = [:]
    private var directConnections: [Address: NWConnection] = [:]
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var closed = false

    init(flow: NEAppProxyUDPFlow, server: Server, events: RelayEvents) {
        self.flow = flow
        self.events = events
        self.server = server
        tunnel = PacketTunnel(server: server, queue: queue)
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { [self] error in
            queue.async { [self] in
                guard !closed else { return }
                if let error {
                    return close(error)
                }
                tunnel.onReceive = { [weak self] payload, source in
                    self?.deliver(payload, from: source)
                }
                tunnel.onFailure = { [weak self] error in
                    guard let self, !self.closed else { return }
                    self.events?.relayFailed(error)
                    self.close(error)
                }
                tunnel.start()
                startIdleTimer()
                readFromApp()
            }
        }
    }

    private func readFromApp() {
        flow.readDatagrams { [self] datagrams, error in
            queue.async { [self] in
                guard !closed else { return }
                guard error == nil, let datagrams, !datagrams.isEmpty else {
                    return close(error)
                }
                lastActivity = Date()
                var sent = 0
                for (payload, endpoint) in datagrams {
                    guard let target = Address(endpoint) else { continue }
                    guard target.port != 53 else {
                        resolve(payload, askedOf: target)
                        sent += payload.count
                        continue
                    }
                    guard !target.isLocal else {
                        sendDirectly(payload, to: target)
                        continue
                    }
                    tunnel.send(payload, to: target)
                    sent += payload.count
                }
                events?.relayed(sent: sent, received: 0)
                readFromApp()
            }
        }
    }

    private func deliver(_ payload: Data, from source: Address, throughServer: Bool = true) {
        guard !closed else { return }
        lastActivity = Date()
        if throughServer {
            events?.relayed(sent: 0, received: payload.count)
        }
        flow.writeDatagrams([(payload, source.endpoint)]) { _ in }
    }

    /// DNS goes through the server to a public resolver, whatever the app asked (often the router,
    /// whose answers for blocked names may be false). The answer comes back as if from the one asked.
    private func resolve(_ query: Data, askedOf origin: Address) {
        let lookup = DNSLookup(server: server, queue: queue)
        let id = ObjectIdentifier(lookup)
        lookups[id] = lookup
        lookup.resolve(query) { [weak self] answer in
            guard let self else { return }
            self.lookups[id] = nil
            guard let answer else { return }
            self.deliver(answer, from: origin)
        }
    }

    /// The local network can't be reached from the server, so its packets (LAN discovery,
    /// multicast, a call's local candidates) go straight there, each target on its own socket.
    private func sendDirectly(_ payload: Data, to target: Address) {
        if let connection = directConnections[target] {
            connection.send(content: payload, completion: .idempotent)
            return
        }
        let connection = NWConnection(to: target.endpoint, using: .udp)
        directConnections[target] = connection
        connection.start(queue: queue)
        connection.send(content: payload, completion: .idempotent)
        receiveDirectly(connection, from: target)
    }

    private func receiveDirectly(_ connection: NWConnection, from source: Address) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, !self.closed, error == nil else { return }
            if let content {
                self.deliver(content, from: source, throughServer: false)
            }
            self.receiveDirectly(connection, from: source)
        }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout else { return }
            self.close(nil)
        }
        timer.resume()
        idleTimer = timer
    }

    func close() {
        queue.async { [self] in close(nil) }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        tunnel.cancel()
        for connection in directConnections.values {
            connection.cancel()
        }
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        events?.relayClosed(self)
    }
}
