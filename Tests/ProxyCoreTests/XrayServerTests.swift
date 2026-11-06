import Foundation
import Network
import Testing
@preconcurrency @testable import ProxyCore

/// Xray, whose VLESS and REALITY server these tests talk to (`brew install xray`). They are
/// skipped without it.
let xray = ["/opt/homebrew/bin/xray", "/usr/local/bin/xray"].first { FileManager.default.isExecutableFile(atPath: $0) }

private func run(_ arguments: [String]) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: xray!)
    process.arguments = arguments
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return output
}

/// An Xray server with REALITY in front of VLESS, passing for a local TLS server: one user with
/// the Vision flow, one without.
final class XrayProcess {
    let visionLink: String
    let plainLink: String
    let wrongKeyLink: String
    private let process = Process()
    private let directory: URL

    /// `x25519Only` keeps the site REALITY passes for to X25519; otherwise it picks X25519MLKEM768.
    init(x25519Only: Bool) throws {
        let keys = String(decoding: try run(["x25519"]), as: UTF8.self)
        func value(_ prefix: String) -> String {
            keys.split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.split(separator: " ").last!) } ?? ""
        }
        let privateKey = value("PrivateKey:")
        let publicKey = value("Password")
        let certificate = try JSONSerialization.jsonObject(with: run(["tls", "cert", "--domain=localhost"]))

        let port = freePort()
        let sitePort = freePort()
        let vision = UUID().uuidString.lowercased()
        let plain = UUID().uuidString.lowercased()
        var site: [String: Any] = ["certificates": [certificate]]
        if x25519Only {
            site["curvePreferences"] = ["X25519"]
        }
        let config: [String: Any] = [
            "log": ["loglevel": "none"],
            "inbounds": [
                [
                    "listen": "127.0.0.1", "port": sitePort, "protocol": "vless",
                    "settings": ["clients": [], "decryption": "none"],
                    "streamSettings": ["network": "tcp", "security": "tls", "tlsSettings": site],
                ],
                [
                    "listen": "127.0.0.1", "port": port, "protocol": "vless",
                    "settings": ["clients": [["id": vision, "flow": "xtls-rprx-vision"], ["id": plain]], "decryption": "none"],
                    "streamSettings": [
                        "network": "tcp", "security": "reality",
                        "realitySettings": [
                            "target": "127.0.0.1:\(sitePort)", "serverNames": ["localhost"],
                            "privateKey": privateKey, "shortIds": ["0123abcd"],
                        ],
                    ],
                ],
            ],
            // Xray blocks connections to this Mac unless told otherwise; the echo server is here.
            "outbounds": [["protocol": "freedom", "settings": ["finalRules": [["action": "allow"]]]]],
        ]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: file)

        process.executableURL = URL(fileURLWithPath: xray!)
        process.arguments = ["run", "-c", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let query = "security=reality&sni=localhost&sid=0123abcd&type=tcp"
        visionLink = "vless://\(vision)@127.0.0.1:\(port)?\(query)&pbk=\(publicKey)&flow=xtls-rprx-vision"
        plainLink = "vless://\(plain)@127.0.0.1:\(port)?\(query)&pbk=\(publicKey)"
        let otherKeys = String(decoding: try run(["x25519"]), as: UTF8.self)
        let otherKey = otherKeys.split(separator: "\n").first { $0.hasPrefix("Password") }.map { String($0.split(separator: " ").last!) } ?? ""
        wrongKeyLink = "vless://\(plain)@127.0.0.1:\(port)?\(query)&pbk=\(otherKey)"
        Thread.sleep(forTimeInterval: 0.5)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}

@available(macOS 26.0, *)
private func readAll(_ tunnel: VLESSConnection, on queue: DispatchQueue, count: Int) async throws -> Data {
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

@available(macOS 26.0, *)
private func send(_ data: Data, through tunnel: VLESSConnection, on queue: DispatchQueue) async -> Error? {
    await withCheckedContinuation { continuation in
        queue.async { tunnel.send(data) { continuation.resume(returning: $0) } }
    }
}

@Suite(.enabled(if: xray != nil, "needs xray"), .serialized)
struct XrayServerTests {
    @Test(arguments: [false, true])
    func tcp(x25519Only: Bool) async throws {
        guard #available(macOS 26.0, *) else { return }
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: x25519Only)
        for link in [xray.plainLink, xray.visionLink] {
            let queue = DispatchQueue(label: "tunnel")
            let tunnel = try VLESSConnection(server: VLESSServer(link: link), target: Address(name: "127.0.0.1", port: echo.port), command: .tcp, queue: queue)
            let first = Data("hello".utf8)
            let rest = randomBytes(150_000)
            queue.sync { tunnel.start(sending: first) }
            #expect(await send(rest, through: tunnel, on: queue) == nil)
                let echoed = try await readAll(tunnel, on: queue, count: first.count + rest.count)
            #expect(echoed == first + rest)
            queue.sync { tunnel.cancel() }
        }
    }

    @Test func tcpWithoutInitialData() async throws {
        guard #available(macOS 26.0, *) else { return }
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: false)
        for link in [xray.plainLink, xray.visionLink] {
            let queue = DispatchQueue(label: "tunnel")
            let tunnel = try VLESSConnection(server: VLESSServer(link: link), target: Address(name: "localhost", port: echo.port), command: .tcp, queue: queue)
            queue.sync { tunnel.start(sending: Data()) }
            #expect(await send(Data("ping".utf8), through: tunnel, on: queue) == nil)
            #expect(try await readAll(tunnel, on: queue, count: 4) == Data("ping".utf8))
            queue.sync { tunnel.cancel() }
        }
    }

    /// Once the app's TLS 1.3 carries data, Vision sends it raw both ways.
    @Test func visionGoesDirect() async throws {
        guard #available(macOS 26.0, *) else { return }
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: false)
        let queue = DispatchQueue(label: "tunnel")
        let tunnel = try VLESSConnection(server: VLESSServer(link: xray.visionLink), target: Address(name: "127.0.0.1", port: echo.port), command: .tcp, queue: queue)
        let hello = fakeServerHello()
        queue.sync { tunnel.start(sending: hello) }
        #expect(try await readAll(tunnel, on: queue, count: hello.count) == hello)

        let record = Data([0x17, 3, 3, 0x01, 0x00]) + randomBytes(256)
        #expect(await send(record, through: tunnel, on: queue) == nil)
        #expect(try await readAll(tunnel, on: queue, count: record.count) == record)
        let raw = randomBytes(100_000)
        #expect(await send(raw, through: tunnel, on: queue) == nil)
        #expect(try await readAll(tunnel, on: queue, count: raw.count) == raw)
        #expect(queue.sync { tunnel.isDirect })
        queue.sync { tunnel.cancel() }
    }

    @Test func udp() async throws {
        guard #available(macOS 26.0, *) else { return }
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: false)
        for link in [xray.plainLink, xray.visionLink] {
            let queue = DispatchQueue(label: "packets")
            let tunnel = try VLESSPacketTunnel(server: VLESSServer(link: link), queue: queue)
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
            #expect(received.map(\.0) == packets)
            #expect(received.allSatisfy { $0.1 == target })
            queue.sync { tunnel.cancel() }
        }
    }

    @Test func wrongPublicKey() async throws {
        guard #available(macOS 26.0, *) else { return }
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: false)
        let queue = DispatchQueue(label: "tunnel")
        let tunnel = try VLESSConnection(server: VLESSServer(link: xray.wrongKeyLink), target: Address(name: "127.0.0.1", port: echo.port), command: .tcp, queue: queue)
        queue.sync { tunnel.start(sending: Data("hello".utf8)) }
        await #expect(throws: TLSError.self) { try await readAll(tunnel, on: queue, count: 5) }
        queue.sync { tunnel.cancel() }
    }
}
