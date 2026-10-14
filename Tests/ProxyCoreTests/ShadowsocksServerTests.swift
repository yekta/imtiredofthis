import Foundation
import Network
import Testing
@testable import ProxyCore

/// shadowsocks-rust's server, which these tests talk to (`brew install shadowsocks-rust`). They
/// are skipped without it.
private let ssserver = ["/opt/homebrew/bin/ssserver", "/usr/local/bin/ssserver"].first { FileManager.default.isExecutableFile(atPath: $0) }

private func freePort() -> UInt16 {
    UInt16.random(in: 20000...60000)
}

/// Echoes back whatever comes in, over TCP and UDP, on one port.
private final class EchoServer {
    let port: UInt16
    private let tcp: NWListener
    private let udp: NWListener
    private let queue = DispatchQueue(label: "echo")

    init() throws {
        port = freePort()
        tcp = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        udp = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        tcp.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.echoStream(connection)
        }
        udp.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.echoPackets(connection)
        }
        tcp.start(queue: queue)
        udp.start(queue: queue)
    }

    deinit {
        tcp.cancel()
        udp.cancel()
    }

    private static func echoStream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
            if let content {
                connection.send(content: content, completion: .idempotent)
            }
            guard !isComplete, error == nil else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            echoStream(connection)
        }
    }

    private static func echoPackets(_ connection: NWConnection) {
        connection.receiveMessage { content, _, _, error in
            if let content {
                connection.send(content: content, completion: .idempotent)
            }
            guard error == nil else { return }
            echoPackets(connection)
        }
    }
}

private final class ServerProcess {
    let server: Server
    private let process = Process()

    init(method: EncryptionMethod, password: String) throws {
        let port = freePort()
        process.executableURL = URL(fileURLWithPath: ssserver!)
        process.arguments = ["-s", "127.0.0.1:\(port)", "-m", method.rawValue, "-k", password, "-U"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = try Server(method: method, password: password, host: "127.0.0.1", port: port)
        Thread.sleep(forTimeInterval: 0.3)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
    }
}

private func password(for method: EncryptionMethod) -> String {
    method.is2022 ? randomBytes(method.keySize).base64EncodedString() : "correct horse battery staple"
}

private func readAll(_ tunnel: TunnelConnection, on queue: DispatchQueue, count: Int) async throws -> Data {
    var received = Data()
    while received.count < count {
        let next: Data? = try await withCheckedThrowingContinuation { continuation in
            queue.async { tunnel.receive { continuation.resume(with: $0) } }
        }
        guard let next else { break }
        received.append(next)
    }
    return received
}

@Suite(.enabled(if: ssserver != nil, "needs ssserver"), .serialized)
struct ShadowsocksServerTests {
    @Test(arguments: EncryptionMethod.allCases)
    func tcp(method: EncryptionMethod) async throws {
        let echo = try EchoServer()
        let process = try ServerProcess(method: method, password: password(for: method))
        let queue = DispatchQueue(label: "tunnel")
        let tunnel = TunnelConnection(server: process.server, target: Address(name: "127.0.0.1", port: echo.port), queue: queue)
        let first = Data("hello".utf8)
        // Over two of the largest chunks, so data spans chunks of both sizes.
        let rest = randomBytes(150_000)
        queue.sync { tunnel.start(sending: first) }
        let error: Error? = await withCheckedContinuation { continuation in
            queue.async { tunnel.send(rest) { continuation.resume(returning: $0) } }
        }
        #expect(error == nil)
        let echoed = try await readAll(tunnel, on: queue, count: first.count + rest.count)
        #expect(echoed == first + rest)
        queue.sync { tunnel.cancel() }
    }

    @Test(arguments: EncryptionMethod.allCases)
    func tcpWithoutInitialData(method: EncryptionMethod) async throws {
        let echo = try EchoServer()
        let process = try ServerProcess(method: method, password: password(for: method))
        let queue = DispatchQueue(label: "tunnel")
        let tunnel = TunnelConnection(server: process.server, target: Address(name: "localhost", port: echo.port), queue: queue)
        queue.sync { tunnel.start(sending: Data()) }
        queue.sync { tunnel.send(Data("ping".utf8)) { _ in } }
        let echoed = try await readAll(tunnel, on: queue, count: 4)
        #expect(echoed == Data("ping".utf8))
        queue.sync { tunnel.cancel() }
    }

    @Test(arguments: EncryptionMethod.allCases)
    func udp(method: EncryptionMethod) async throws {
        let echo = try EchoServer()
        let process = try ServerProcess(method: method, password: password(for: method))
        let queue = DispatchQueue(label: "packets")
        let tunnel = PacketTunnel(server: process.server, queue: queue)
        let target = Address(name: "127.0.0.1", port: echo.port)
        let packets = (0..<3).map { _ in randomBytes(1200) }
        let received: [(Data, Address)] = await withCheckedContinuation { continuation in
            var received: [(Data, Address)] = []
            tunnel.onReceive = { payload, source in
                received.append((payload, source))
                if received.count == packets.count {
                    continuation.resume(returning: received)
                }
            }
            queue.async {
                tunnel.start()
                for packet in packets {
                    tunnel.send(packet, to: target)
                }
            }
        }
        #expect(Set(received.map(\.0)) == Set(packets))
        #expect(received.allSatisfy { $0.1 == target })
        queue.sync { tunnel.cancel() }
    }
}
