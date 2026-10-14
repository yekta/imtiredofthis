import Foundation

/// One DNS query, asked of a public resolver through the server over TCP, so the local network's
/// DNS (which may lie about blocked names) is never asked, and it works on servers without UDP.
public final class DNSLookup {
    public static let resolver = Address(name: "1.1.1.1", port: 53)
    private static let timeout: DispatchTimeInterval = .seconds(8)

    private let tunnel: TunnelConnection
    private let queue: DispatchQueue
    private var completion: ((Data?) -> Void)?
    private var buffer = Data()

    public init(server: Server, queue: DispatchQueue) {
        tunnel = TunnelConnection(server: server, target: Self.resolver, queue: queue)
        self.queue = queue
    }

    /// Calls `completion` once, on the queue, with the answer, or nil if there is none.
    public func resolve(_ query: Data, completion: @escaping (Data?) -> Void) {
        self.completion = completion
        tunnel.onFailure = { [weak self] _ in self?.finish(nil) }
        tunnel.start(sending: Self.framed(query))
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.finish(nil) }
        receive()
    }

    /// DNS over TCP puts each message after its length.
    static func framed(_ message: Data) -> Data {
        var data = Data([UInt8(message.count >> 8), UInt8(message.count & 0xFF)])
        data.append(message)
        return data
    }

    /// The first whole message in `data`, if it has arrived.
    static func message(in data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard data.count >= 2 + length else { return nil }
        return data.dropFirst(2).prefix(length)
    }

    private func receive() {
        tunnel.receive { [weak self] result in
            guard let self else { return }
            guard case let .success(data?) = result else { return self.finish(nil) }
            self.buffer.append(data)
            guard let answer = Self.message(in: self.buffer) else { return self.receive() }
            self.finish(Data(answer))
        }
    }

    private func finish(_ answer: Data?) {
        guard let completion else { return }
        self.completion = nil
        tunnel.cancel()
        completion(answer)
    }
}
