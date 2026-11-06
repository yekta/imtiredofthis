import Foundation
import Network
import Testing
@testable import PacketStack
@preconcurrency @testable import ProxyCore

/// A TCP segment as a packet from the tun, or read back from one. Checksums are left at zero:
/// the stack doesn't check them.
private struct Segment {
    static let fin: UInt8 = 0x01, syn: UInt8 = 0x02, rst: UInt8 = 0x04, psh: UInt8 = 0x08, ack: UInt8 = 0x10

    var source: Address
    var destination: Address
    var sequence: UInt32
    var acknowledgement: UInt32 = 0
    var flags: UInt8
    var payload = Data()

    var packet: Data {
        var tcp = Data()
        tcp.appendUInt16(source.port)
        tcp.appendUInt16(destination.port)
        tcp.appendUInt32(sequence)
        tcp.appendUInt32(acknowledgement)
        tcp.append(contentsOf: [0x50, flags, 0xFF, 0xFF, 0, 0, 0, 0])
        tcp.append(payload)
        switch (source.host, destination.host) {
        case let (.ipv4(from), .ipv4(to)):
            var ip = Data([0x45, 0])
            ip.appendUInt16(UInt16(20 + tcp.count))
            ip.append(contentsOf: [0, 0, 0x40, 0, 64, 6, 0, 0])
            return ip + from.rawValue + to.rawValue + tcp
        case let (.ipv6(from), .ipv6(to)):
            var ip = Data([0x60, 0, 0, 0])
            ip.appendUInt16(UInt16(tcp.count))
            ip.append(contentsOf: [6, 64])
            return ip + from.rawValue + to.rawValue + tcp
        default:
            fatalError("Mixed address families")
        }
    }

    init(source: Address, destination: Address, sequence: UInt32, acknowledgement: UInt32 = 0, flags: UInt8, payload: Data = Data()) {
        self.source = source
        self.destination = destination
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.flags = flags
        self.payload = payload
    }

    init?(packet: Data) {
        let header: Int
        switch packet.byte(0) >> 4 {
        case 4:
            header = Int(packet.byte(0) & 0x0F) * 4
            guard packet.byte(9) == 6 else { return nil }
            source = Address(host: .ipv4(IPv4Address(packet.slice(12, 4))!), port: packet.uint16(header))
            destination = Address(host: .ipv4(IPv4Address(packet.slice(16, 4))!), port: packet.uint16(header + 2))
        case 6:
            header = 40
            guard packet.byte(6) == 6 else { return nil }
            source = Address(host: .ipv6(IPv6Address(packet.slice(8, 16))!), port: packet.uint16(header))
            destination = Address(host: .ipv6(IPv6Address(packet.slice(24, 16))!), port: packet.uint16(header + 2))
        default:
            return nil
        }
        sequence = UInt32(packet.uint16(header + 4)) << 16 | UInt32(packet.uint16(header + 6))
        acknowledgement = UInt32(packet.uint16(header + 8)) << 16 | UInt32(packet.uint16(header + 10))
        flags = packet.byte(header + 13)
        let offset = header + Int(packet.byte(header + 12) >> 4) * 4
        payload = packet.slice(offset, packet.count - offset)
    }
}

/// The apps' side of the tun: what goes into the stack and what comes out.
private final class Tun: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var connections: [StackTCPConnection] = []
    private var datagrams: [UDPDatagram] = []

    func output(_ packets: [Data]) {
        lock.withLock { self.packets += packets }
    }

    func accepted(_ connection: StackTCPConnection) {
        lock.withLock { connections.append(connection) }
    }

    func received(_ datagram: UDPDatagram) {
        lock.withLock { datagrams.append(datagram) }
    }

    /// The next packet out that `matches`, skipping the others.
    func next<T>(_ matches: @escaping (Data) -> T?) async throws -> T {
        try await poll { [self] in
            lock.withLock {
                while !packets.isEmpty {
                    if let found = matches(packets.removeFirst()) {
                        return found
                    }
                }
                return nil
            }
        }
    }

    func segment(where condition: @escaping (Segment) -> Bool) async throws -> Segment {
        try await next { packet in Segment(packet: packet).flatMap { condition($0) ? $0 : nil } }
    }

    func connection() async throws -> StackTCPConnection {
        try await poll { [self] in lock.withLock { connections.isEmpty ? nil : connections.removeFirst() } }
    }

    func datagram() async throws -> UDPDatagram {
        try await poll { [self] in lock.withLock { datagrams.isEmpty ? nil : datagrams.removeFirst() } }
    }

    private func poll<T>(_ attempt: @escaping () -> T?) async throws -> T {
        for _ in 0..<500 {
            if let found = attempt() {
                return found
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

private func read(_ connection: StackTCPConnection) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
        connection.read { continuation.resume(with: $0) }
    }
}

private func write(_ data: Data, to connection: StackTCPConnection) async -> Error? {
    await withCheckedContinuation { continuation in
        connection.write(data) { continuation.resume(returning: $0) }
    }
}

/// lwIP is one per process, so these run one at a time.
@Suite(.serialized) struct PacketStackTests {
    @Test(arguments: [
        (Address(name: "10.0.0.2", port: 50001), Address(name: "203.0.113.5", port: 443)),
        (Address(name: "fd00::2", port: 50002), Address(name: "2001:db8::5", port: 8443)),
    ])
    func tcp(app: Address, target: Address) async throws {
        let tun = Tun()
        let stack = PacketStack()
        stack.onOutput = { packets, _ in tun.output(packets) }
        stack.onAccept = { tun.accepted($0) }
        stack.start()
        defer { stack.stop() }

        stack.input([Segment(source: app, destination: target, sequence: 1000, flags: Segment.syn).packet])
        let synAck = try await tun.segment { $0.flags & Segment.syn != 0 }
        #expect(synAck.source == target)
        #expect(synAck.destination == app)
        #expect(synAck.flags & Segment.ack != 0)
        #expect(synAck.acknowledgement == 1001)
        var serverSequence = synAck.sequence + 1

        stack.input([Segment(source: app, destination: target, sequence: 1001, acknowledgement: serverSequence, flags: Segment.ack).packet])
        let connection = try await tun.connection()
        #expect(connection.source == app)
        #expect(connection.destination == target)

        let hello = Data("hello".utf8)
        stack.input([Segment(source: app, destination: target, sequence: 1001, acknowledgement: serverSequence, flags: Segment.ack | Segment.psh, payload: hello).packet])
        #expect(try await read(connection) == hello)

        let answer = randomBytes(5000)
        #expect(await write(answer, to: connection) == nil)
        var received = Data()
        while received.count < answer.count {
            let segment = try await tun.segment { !$0.payload.isEmpty }
            #expect(segment.source == target)
            #expect(segment.sequence == serverSequence)
            received += segment.payload
            serverSequence += UInt32(segment.payload.count)
            stack.input([Segment(source: app, destination: target, sequence: 1006, acknowledgement: serverSequence, flags: Segment.ack).packet])
        }
        #expect(received == answer)

        stack.input([Segment(source: app, destination: target, sequence: 1006, acknowledgement: serverSequence, flags: Segment.ack | Segment.fin).packet])
        #expect(try await read(connection) == nil)

        connection.finishSending()
        let fin = try await tun.segment { $0.flags & Segment.fin != 0 }
        #expect(fin.destination == app)
    }

    @Test func udp() async throws {
        let tun = Tun()
        let stack = PacketStack()
        stack.onOutput = { packets, _ in tun.output(packets) }
        stack.onDatagram = { tun.received($0) }
        stack.start()
        defer { stack.stop() }

        let query = UDPDatagram(source: Address(name: "10.0.0.2", port: 5353), destination: Address(name: "198.18.0.2", port: 53), payload: Data("query".utf8))
        stack.input([try #require(query.packet)])
        #expect(try await tun.datagram() == query)

        let answer = UDPDatagram(source: query.destination, destination: query.source, payload: Data("answer".utf8))
        stack.send(answer)
        #expect(try await tun.next { UDPDatagram(packet: $0) } == answer)
    }

    /// An app's TLS connection to an IP and a DNS query to the tunnel, as packets, through the
    /// relays and Xray. The server name in the hello takes the connection to the echo server.
    @Test(.enabled(if: xray != nil, "needs xray"))
    func throughXray() async throws {
        let echo = try EchoServer()
        let xray = try XrayProcess(x25519Only: false)
        for (index, link) in [xray.plainLink, xray.visionLink].enumerated() {
            let tun = Tun()
            let proxy = PacketProxy(upstream: .vless(try VLESSServer(link: link)))
            proxy.onOutput = { packets, _ in tun.output(packets) }
            proxy.start()
            defer { proxy.stop() }

            let app = Address(name: "10.0.0.2", port: UInt16(50010 + index))
            let target = Address(name: "203.0.113.9", port: echo.port)
            proxy.input([Segment(source: app, destination: target, sequence: 1, flags: Segment.syn).packet])
            let synAck = try await tun.segment { $0.flags & Segment.syn != 0 }
            var serverSequence = synAck.sequence + 1
            let sent = clientHello(serverName: "localhost") + randomBytes(400)
            proxy.input([
                Segment(source: app, destination: target, sequence: 2, acknowledgement: serverSequence, flags: Segment.ack).packet,
                Segment(source: app, destination: target, sequence: 2, acknowledgement: serverSequence, flags: Segment.ack | Segment.psh, payload: sent).packet,
            ])
            var received = Data()
            while received.count < sent.count {
                let segment = try await tun.segment { !$0.payload.isEmpty }
                received += segment.payload
                serverSequence += UInt32(segment.payload.count)
                proxy.input([Segment(source: app, destination: target, sequence: 2 + UInt32(sent.count), acknowledgement: serverSequence, flags: Segment.ack).packet])
            }
            #expect(received == sent)

            // A query for discord.com's A record.
            let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("discord".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1])
            let dns = Address(name: PacketProxy.dnsServer, port: 53)
            proxy.input([try #require(UDPDatagram(source: app, destination: dns, payload: query).packet)])
            let answer = try await tun.next { UDPDatagram(packet: $0) }
            #expect(answer.source == dns)
            #expect(answer.destination == app)
            #expect(answer.payload.prefix(2) == Data([0x12, 0x34]))
            #expect(proxy.totals.received > 0)
        }
    }
}

@Suite struct UDPDatagramTests {
    @Test(arguments: [
        (Address(name: "10.0.0.2", port: 5353), Address(name: "1.1.1.1", port: 53)),
        (Address(name: "fd00::2", port: 5353), Address(name: "2606:4700::1111", port: 53)),
    ])
    func roundTrip(source: Address, destination: Address) throws {
        for size in [0, 1, 2, 3, 1200] {
            let datagram = UDPDatagram(source: source, destination: destination, payload: randomBytes(size))
            let packet = try #require(datagram.packet)
            #expect(UDPDatagram(packet: packet) == datagram)

            let header = packet.byte(0) >> 4 == 4 ? 20 : 40
            let udp = packet.slice(header, packet.count - header)
            var pseudo: Data
            if header == 20 {
                #expect(UDPDatagram.checksum(packet.slice(0, 20)) == 0)
                pseudo = packet.slice(12, 8) + Data([0, 17])
                pseudo.appendUInt16(UInt16(udp.count))
            } else {
                pseudo = packet.slice(8, 32) + Data([0, 0])
                pseudo.appendUInt16(UInt16(udp.count))
                pseudo += Data([0, 0, 0, 17])
            }
            #expect(UDPDatagram.checksum(pseudo + udp) == 0)
        }
    }

    @Test func readsAHandMadePacket() {
        // 192.168.1.10:12345 → 8.8.8.8:53, "abc", the IPv4 header with options.
        let packet = Data([
            0x46, 0, 0, 35, 0, 0, 0x40, 0, 64, 17, 0, 0, 192, 168, 1, 10, 8, 8, 8, 8, 1, 1, 0, 0,
            0x30, 0x39, 0, 53, 0, 11, 0, 0, 0x61, 0x62, 0x63,
        ])
        let datagram = UDPDatagram(packet: packet)
        #expect(datagram?.source == Address(name: "192.168.1.10", port: 12345))
        #expect(datagram?.destination == Address(name: "8.8.8.8", port: 53))
        #expect(datagram?.payload == Data("abc".utf8))
    }

    @Test func skipsFragmentsAndOtherProtocols() {
        let fragment = Data([0x45, 0, 0, 31, 0, 0, 0x20, 0, 64, 17, 0, 0, 10, 0, 0, 2, 1, 1, 1, 1, 0, 1, 0, 2, 0, 11, 0, 0, 1, 2, 3])
        #expect(UDPDatagram(packet: fragment) == nil)
        var tcp = fragment
        tcp[6] = 0x40
        tcp[9] = 6
        #expect(UDPDatagram(packet: tcp) == nil)
        #expect(UDPDatagram(packet: Data()) == nil)
    }
}

extension Data {
    fileprivate mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value >> 16))
        appendUInt16(UInt16(value & 0xFFFF))
    }
}
