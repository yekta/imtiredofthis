import Foundation
import ProxyCore

protocol Closable: AnyObject {
    func close()
}

/// What relays report back: bytes moved, failures, and when they are done.
protocol RelayEvents: AnyObject {
    func relayed(sent: Int, received: Int)
    func relayFailed(_ error: Error)
    func relayClosed(_ relay: AnyObject)
}

/// One app's TCP connection, carried through the server. Its first data goes out with the
/// request; when the app speaks first with TLS, the server name in its hello becomes the target,
/// so the server looks the name up itself, past any local DNS tampering.
final class TCPRelay: Closable {
    /// How long to wait for the app to speak first before connecting without its data.
    private static let firstDataWait: DispatchTimeInterval = .milliseconds(150)
    /// How long one side may stay open after the other has finished.
    private static let halfCloseTimeout: DispatchTimeInterval = .seconds(60)

    private let connection: StackTCPConnection
    private var target: Address
    private let upstream: Upstream
    private weak var events: RelayEvents?
    private let queue = DispatchQueue(label: "tcp-relay")
    private var tunnel: StreamTunnel?
    private var appDone = false
    private var serverDone = false
    private var closed = false

    init(connection: StackTCPConnection, target: Address, upstream: Upstream, events: RelayEvents) {
        self.connection = connection
        self.target = target
        self.upstream = upstream
        self.events = events
    }

    func start() {
        queue.async { [self] in
            readFromApp()
            queue.asyncAfter(deadline: .now() + Self.firstDataWait) { [self] in
                connect(sending: Data())
            }
        }
    }

    private func connect(sending data: Data) {
        guard tunnel == nil, !closed else { return }
        if !target.isName, let name = TLS.serverName(in: data) {
            target = Address(name: name, port: target.port)
        }
        let tunnel = upstream.stream(to: target, queue: queue)
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
        connection.read { [self] result in
            queue.async { [self] in
                guard !closed else { return }
                switch result {
                case let .failure(error):
                    close(error)
                case .success(nil):
                    appDone = true
                    if tunnel == nil {
                        connect(sending: Data())
                    }
                    tunnel?.finishSending()
                    closeIfDone()
                case let .success(data?):
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
                connection.finishSending()
                closeIfDone()
            case let .success(data?):
                connection.write(data) { [self] error in
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
        connection.close()
        events?.relayClosed(self)
    }
}

/// One app's UDP socket, its datagrams carried through the server to wherever each one goes, and
/// DNS asked of a public resolver through the server. Ends after a while without datagrams.
final class UDPRelay: Closable {
    private static let idleTimeout: TimeInterval = 120

    let source: Address
    private let stack: PacketStack
    private let upstream: Upstream
    private weak var events: RelayEvents?
    private let queue = DispatchQueue(label: "udp-relay")
    private var tunnel: DatagramTunnel?
    private var lookups: [ObjectIdentifier: DNSLookup] = [:]
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var closed = false

    init(source: Address, stack: PacketStack, upstream: Upstream, events: RelayEvents) {
        self.source = source
        self.stack = stack
        self.upstream = upstream
        self.events = events
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in
                guard let self, Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout else { return }
                self.close(nil)
            }
            timer.resume()
            idleTimer = timer
        }
    }

    func send(_ datagram: UDPDatagram) {
        queue.async { [self] in
            guard !closed else { return }
            lastActivity = Date()
            events?.relayed(sent: datagram.payload.count, received: 0)
            guard datagram.destination.port != 53 else {
                return resolve(datagram.payload, askedOf: datagram.destination)
            }
            packets().send(datagram.payload, to: datagram.destination)
        }
    }

    /// The tunnel, opened with the first datagram that isn't DNS.
    private func packets() -> DatagramTunnel {
        if let tunnel {
            return tunnel
        }
        let tunnel = upstream.packets(queue: queue)
        tunnel.onReceive = { [weak self] payload, origin in
            self?.deliver(payload, from: origin)
        }
        tunnel.onFailure = { [weak self] error in
            guard let self, !self.closed else { return }
            self.events?.relayFailed(error)
            self.close(error)
        }
        tunnel.start()
        self.tunnel = tunnel
        return tunnel
    }

    private func deliver(_ payload: Data, from origin: Address) {
        guard !closed else { return }
        lastActivity = Date()
        events?.relayed(sent: 0, received: payload.count)
        stack.send(UDPDatagram(source: origin, destination: source, payload: payload))
    }

    /// The answer comes back as if from the server the app asked.
    private func resolve(_ query: Data, askedOf origin: Address) {
        let lookup = DNSLookup(upstream: upstream, queue: queue)
        let id = ObjectIdentifier(lookup)
        lookups[id] = lookup
        lookup.resolve(query) { [weak self] answer in
            guard let self else { return }
            self.lookups[id] = nil
            guard let answer else { return }
            self.deliver(answer, from: origin)
        }
    }

    func close() {
        queue.async { [self] in close(nil) }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        tunnel?.cancel()
        events?.relayClosed(self)
    }
}
