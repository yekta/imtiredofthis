import Foundation
import Network

/// A TCP connection, or one UDP target's packets, through a VLESS server over REALITY.
@available(macOS 26.0, *)
public final class VLESSConnection: StreamTunnel {
    public var onFailure: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let server: VLESSServer
    private let header: Data
    private var handshake: REALITYHandshake?
    private var records: TLSRecordLayer?
    private var vision: Vision?
    private var initialData = Data()
    private var pendingSends: [(Data, (Error?) -> Void)] = []
    private var finishesAfterHandshake = false
    private var hasSentHeader = false
    private var writesDirectly = false
    private var readsDirectly = false
    /// The response header as it arrives, until it has.
    private var responseHeader: Data? = Data()
    private var received = Data()
    private var waiting: ((Result<Data?, Error>) -> Void)?
    private var isReading = false
    private var reachedEnd = false
    private var failure: Error?
    private var failed = false

    /// Whether Vision has switched both ways to raw TCP.
    var isDirect: Bool { writesDirectly && readsDirectly }

    init(server: VLESSServer, target: Address, command: VLESSCommand, queue: DispatchQueue) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        connection = NWConnection(to: server.address.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.queue = queue
        self.server = server
        header = server.requestHeader(command, to: target)
        if server.usesVision, command == .tcp {
            vision = Vision(id: server.idBytes)
        }
    }

    /// Shakes hands with the server, then sends the request with `initialData`.
    public func start(sending initialData: Data) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error), let .waiting(error):
                self?.fail(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.initialData = initialData
        do {
            let handshake = try REALITYHandshake(server: server)
            self.handshake = handshake
            connection.send(content: handshake.clientHello, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.fail(error)
            })
            readFromServer()
        } catch {
            fail(error)
        }
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !data.isEmpty else { return completion(nil) }
        guard records != nil else {
            pendingSends.append((data, completion))
            return
        }
        connection.send(content: encode(data), completion: .contentProcessed(completion))
    }

    public func finishSending() {
        guard records != nil else {
            finishesAfterHandshake = true
            return
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    public func receive(_ completion: @escaping (Result<Data?, Error>) -> Void) {
        waiting = completion
        deliver()
    }

    public func cancel() {
        failed = true
        onFailure = nil
        waiting = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    /// The request header goes with the first data; with Vision, the data goes in its blocks
    /// until it says to send it raw.
    private func encode(_ data: Data) -> Data {
        var payload = data
        var output = Data()
        if !hasSentHeader {
            hasSentHeader = true
            output = header
        }
        guard !writesDirectly else { return payload }
        var thenDirect = false
        if var vision {
            (payload, thenDirect) = vision.pad(payload)
            self.vision = vision
        }
        output.append(payload)
        let sealed = records?.seal(output) ?? Data()
        if thenDirect {
            writesDirectly = true
        }
        return sealed
    }

    private func deliver() {
        guard let waiting else { return }
        if !received.isEmpty {
            let data = received
            received = Data()
            self.waiting = nil
            return waiting(.success(data))
        }
        if let failure {
            self.waiting = nil
            return waiting(.failure(failure))
        }
        if reachedEnd {
            self.waiting = nil
            return waiting(.success(nil))
        }
        readFromServer()
    }

    /// Reads while shaking hands, and after that whenever data is wanted and none is waiting.
    private func readFromServer() {
        guard !isReading, !reachedEnd, failure == nil, !failed else { return }
        isReading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            guard let self, !self.failed else { return }
            self.isReading = false
            do {
                if let content, !content.isEmpty {
                    try self.process(content)
                }
                if isComplete {
                    self.reachedEnd = true
                    guard self.readsDirectly || self.records?.isBetweenRecords == true else { throw TLSError.cutOff }
                } else if let error {
                    throw error
                }
            } catch {
                self.failure = error
                self.fail(error)
            }
            if self.handshake != nil {
                return self.readFromServer()
            }
            self.deliver()
        }
    }

    private func process(_ content: Data) throws {
        guard !readsDirectly else { return received.append(content) }
        if var handshake {
            guard let established = try handshake.receive(content) else {
                self.handshake = handshake
                return
            }
            self.handshake = nil
            records = established.records
            connection.send(content: established.finished + encode(initialData), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.fail(error)
            })
            initialData = Data()
            for (data, completion) in pendingSends {
                connection.send(content: encode(data), completion: .contentProcessed(completion))
            }
            pendingSends = []
            if finishesAfterHandshake {
                finishSending()
            }
        } else {
            records?.append(content)
        }
        try readRecords()
    }

    private func readRecords() throws {
        while let record = try records?.next() {
            switch record {
            case .closed:
                reachedEnd = true
                return
            case let .data(data):
                try take(data)
            }
            if readsDirectly {
                received.append(records?.takeRest() ?? Data())
                return
            }
        }
    }

    /// Data from the records: first the response header, then the target's data.
    private func take(_ data: Data) throws {
        var data = data
        if var header = responseHeader {
            header.append(data)
            guard header.count >= 2 else {
                responseHeader = header
                return
            }
            guard header[header.startIndex] == 0 else { throw VLESSError.badResponse }
            let length = 2 + Int(header[header.startIndex + 1])
            guard header.count >= length else {
                responseHeader = header
                return
            }
            responseHeader = nil
            data = Data(header.dropFirst(length))
        }
        guard !data.isEmpty else { return }
        guard var vision else { return received.append(data) }
        let (output, direct) = vision.unpad(data)
        self.vision = vision
        received.append(output)
        readsDirectly = direct
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        failure = failure ?? error
        onFailure?(error)
        deliver()
    }
}

/// One UDP flow's packets through a VLESS server: each target gets a connection of its own, which
/// carries its packets after their lengths.
@available(macOS 26.0, *)
public final class VLESSPacketTunnel: DatagramTunnel {
    public var onReceive: ((Data, Address) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let server: VLESSServer
    private let queue: DispatchQueue
    private var connections: [Address: VLESSConnection] = [:]
    private var buffers: [Address: Data] = [:]

    init(server: VLESSServer, queue: DispatchQueue) {
        self.server = server
        self.queue = queue
    }

    public func start() {}

    public func send(_ payload: Data, to target: Address) {
        guard payload.count <= 0xFFFF, server.allowsUDP443 || !server.usesVision || target.port != 443 else { return }
        var framed = Data()
        framed.appendBigEndian(UInt16(payload.count))
        framed.append(payload)
        if let connection = connections[target] {
            return connection.send(framed) { _ in }
        }
        let connection = VLESSConnection(server: server, target: target, command: .udp, queue: queue)
        connections[target] = connection
        connection.onFailure = { [weak self] _ in self?.drop(target) }
        connection.start(sending: framed)
        receive(from: connection, target: target)
    }

    public func cancel() {
        onReceive = nil
        onFailure = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func receive(from connection: VLESSConnection, target: Address) {
        connection.receive { [weak self] result in
            guard let self, self.connections[target] === connection else { return }
            guard case let .success(data?) = result else { return self.drop(target) }
            var buffer = (self.buffers[target] ?? Data()) + data
            while buffer.count >= 2 {
                let length = Int(buffer.readBigEndian(UInt16.self, at: 0))
                guard buffer.count >= 2 + length else { break }
                self.onReceive?(Data(buffer.dropFirst(2).prefix(length)), target)
                buffer = Data(buffer.dropFirst(2 + length))
            }
            self.buffers[target] = buffer
            self.receive(from: connection, target: target)
        }
    }

    private func drop(_ target: Address) {
        connections.removeValue(forKey: target)?.cancel()
        buffers[target] = nil
    }
}
