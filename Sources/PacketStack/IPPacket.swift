import Foundation
import Network
import ProxyCore

/// What an IP packet from the tun carries.
enum IPPacket {
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17

    /// The transport protocol of an IPv4 or IPv6 packet, or nil for anything else.
    static func transport(of packet: Data) -> UInt8? {
        guard let first = packet.first else { return nil }
        switch first >> 4 {
        case 4:
            guard packet.count >= 20 else { return nil }
            return packet.byte(9)
        case 6:
            guard packet.count >= 40 else { return nil }
            return packet.byte(6)
        default:
            return nil
        }
    }
}

/// One UDP datagram, from an app's socket to a target or back.
public struct UDPDatagram: Equatable, Sendable {
    public var source: Address
    public var destination: Address
    public var payload: Data

    public init(source: Address, destination: Address, payload: Data) {
        self.source = source
        self.destination = destination
        self.payload = payload
    }

    /// Reads a UDP packet; nil for anything else, and for fragments.
    init?(packet: Data) {
        guard let first = packet.first else { return nil }
        let header: Int
        let end: Int
        switch first >> 4 {
        case 4:
            header = Int(first & 0x0F) * 4
            end = min(Int(packet.uint16(2)), packet.count)
            let fragment = packet.uint16(6) & 0x3FFF
            guard header >= 20, end >= header + 8, packet.byte(9) == IPPacket.udp, fragment == 0,
                  let source = IPv4Address(packet.slice(12, 4)),
                  let destination = IPv4Address(packet.slice(16, 4)) else { return nil }
            self.source = Address(host: .ipv4(source), port: packet.uint16(header))
            self.destination = Address(host: .ipv4(destination), port: packet.uint16(header + 2))
        case 6:
            header = 40
            end = min(header + Int(packet.uint16(4)), packet.count)
            guard packet.count >= 48, end >= header + 8, packet.byte(6) == IPPacket.udp,
                  let source = IPv6Address(packet.slice(8, 16)),
                  let destination = IPv6Address(packet.slice(24, 16)) else { return nil }
            self.source = Address(host: .ipv6(source), port: packet.uint16(header))
            self.destination = Address(host: .ipv6(destination), port: packet.uint16(header + 2))
        default:
            return nil
        }
        let length = min(Int(packet.uint16(header + 4)), end - header)
        guard length >= 8 else { return nil }
        payload = packet.slice(header + 8, length - 8)
    }

    /// The datagram as an IP packet, with its checksums; nil unless both ends are IP addresses of
    /// the same family.
    var packet: Data? {
        let length = 8 + payload.count
        var udp = Data(capacity: length)
        udp.appendUInt16(source.port)
        udp.appendUInt16(destination.port)
        udp.appendUInt16(UInt16(truncatingIfNeeded: length))
        udp.appendUInt16(0)
        udp.append(payload)

        switch (source.host, destination.host) {
        case let (.ipv4(from), .ipv4(to)):
            guard 20 + length <= 0xFFFF else { return nil }
            var pseudo = from.rawValue + to.rawValue
            pseudo.append(contentsOf: [0, IPPacket.udp])
            pseudo.appendUInt16(UInt16(length))
            var sum = Self.checksum(pseudo + udp)
            if sum == 0 { sum = 0xFFFF }
            udp.setUInt16(sum, at: 6)

            var ip = Data([0x45, 0])
            ip.appendUInt16(UInt16(20 + length))
            ip.append(contentsOf: [0, 0, 0x40, 0, 64, IPPacket.udp, 0, 0])
            ip.append(from.rawValue)
            ip.append(to.rawValue)
            ip.setUInt16(Self.checksum(ip), at: 10)
            return ip + udp
        case let (.ipv6(from), .ipv6(to)):
            guard length <= 0xFFFF else { return nil }
            var pseudo = from.rawValue + to.rawValue
            pseudo.append(contentsOf: [0, 0])
            pseudo.appendUInt16(UInt16(length))
            pseudo.append(contentsOf: [0, 0, 0, IPPacket.udp])
            var sum = Self.checksum(pseudo + udp)
            if sum == 0 { sum = 0xFFFF }
            udp.setUInt16(sum, at: 6)

            var ip = Data([0x60, 0, 0, 0])
            ip.appendUInt16(UInt16(length))
            ip.append(contentsOf: [IPPacket.udp, 64])
            ip.append(from.rawValue)
            ip.append(to.rawValue)
            return ip + udp
        default:
            return nil
        }
    }

    /// The Internet checksum: the ones' complement of the ones' complement sum of 16-bit words.
    static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        data.withUnsafeBytes { bytes in
            var index = 0
            while index + 1 < bytes.count {
                sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
                index += 2
            }
            if index < bytes.count {
                sum += UInt32(bytes[index]) << 8
            }
        }
        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}

extension Data {
    func byte(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func uint16(_ offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1))
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        Data(self[(startIndex + offset)..<(startIndex + offset + length)])
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func setUInt16(_ value: UInt16, at offset: Int) {
        self[startIndex + offset] = UInt8(value >> 8)
        self[startIndex + offset + 1] = UInt8(value & 0xFF)
    }
}
