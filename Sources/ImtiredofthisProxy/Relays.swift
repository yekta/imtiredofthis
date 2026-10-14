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
            self?.events?.relayFailed(error)
            self?.close(error)
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
        guard appDone, serverDone else { return }
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
    private let tunnel: PacketTunnel
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    private var closed = false

    init(flow: NEAppProxyUDPFlow, server: Server, events: RelayEvents) {
        self.flow = flow
        self.events = events
        tunnel = PacketTunnel(server: server, queue: queue)
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { [self] error in
            queue.async { [self] in
                if let error {
                    return close(error)
                }
                tunnel.onReceive = { [weak self] payload, source in
                    self?.deliver(payload, from: source)
                }
                tunnel.onFailure = { [weak self] error in
                    self?.events?.relayFailed(error)
                    self?.close(error)
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
                    guard let target = Address(endpoint), !target.isLocal else { continue }
                    tunnel.send(payload, to: target)
                    sent += payload.count
                }
                events?.relayed(sent: sent, received: 0)
                readFromApp()
            }
        }
    }

    private func deliver(_ payload: Data, from source: Address) {
        guard !closed else { return }
        lastActivity = Date()
        events?.relayed(sent: 0, received: payload.count)
        flow.writeDatagrams([(payload, source.endpoint)]) { _ in }
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
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        events?.relayClosed(self)
    }
}
