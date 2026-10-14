import Foundation
import Network

/// A TCP connection to `target` through the server. Everything runs on `queue`, and so must
/// every call into it.
public final class TunnelConnection {
    /// Called once, when the server can't be reached or the connection breaks.
    public var onFailure: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var encoder: RequestEncoder
    private var decoder: ResponseDecoder
    private var reachedEnd = false
    private var failed = false

    public init(server: Server, target: Address, queue: DispatchQueue) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        connection = NWConnection(to: server.address.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.queue = queue
        encoder = RequestEncoder(server: server, target: target)
        decoder = ResponseDecoder(server: server, requestSalt: encoder.salt)
    }

    /// Connects, sending `initialData` along with the request so it costs no extra round trip.
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
        connection.send(content: encoder.encode(initialData), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.fail(error)
        })
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: encoder.encode(data), completion: .contentProcessed(completion))
    }

    /// Tells the target we are done sending; it can still answer.
    public func finishSending() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// The target's next data, or nil once it has closed its side.
    public func receive(_ completion: @escaping (Result<Data?, Error>) -> Void) {
        guard !reachedEnd else { return completion(.success(nil)) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var data = Data()
            if let content, !content.isEmpty {
                do {
                    data = try self.decoder.decode(content)
                } catch {
                    return completion(.failure(error))
                }
            }
            if isComplete {
                self.reachedEnd = true
            }
            if !data.isEmpty {
                return completion(.success(data))
            }
            if let error {
                return completion(.failure(error))
            }
            guard !isComplete else {
                guard self.decoder.isBetweenChunks else { return completion(.failure(StreamError.cutOff)) }
                return completion(.success(nil))
            }
            self.receive(completion)
        }
    }

    public func cancel() {
        failed = true
        onFailure = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        onFailure?(error)
    }
}

/// One UDP flow's packets, to and from any number of targets through the server. Everything runs
/// on `queue`.
public final class PacketTunnel {
    /// A packet back from one of the targets.
    public var onReceive: ((Data, Address) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var codec: PacketCodec
    private var failed = false

    public init(server: Server, queue: DispatchQueue) {
        connection = NWConnection(to: server.address.endpoint, using: .udp)
        self.queue = queue
        codec = PacketCodec(server: server)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error), let .waiting(error):
                self?.fail(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    public func send(_ payload: Data, to target: Address) {
        connection.send(content: codec.encode(payload, to: target), completion: .idempotent)
    }

    public func cancel() {
        failed = true
        onFailure = nil
        onReceive = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, let (payload, source) = try? self.codec.decode(content) {
                self.onReceive?(payload, source)
            }
            if let error {
                return self.fail(error)
            }
            self.receiveNext()
        }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        onFailure?(error)
    }
}
