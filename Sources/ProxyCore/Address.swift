import Foundation
import Network

/// Where a connection goes: a host and a port, written the way Shadowsocks takes it, as a SOCKS5
/// address.
public struct Address: Hashable, Sendable, CustomStringConvertible {
    public enum Host: Hashable, Sendable {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
        case name(String)
    }

    public var host: Host
    public var port: UInt16

    public init(host: Host, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// A name that is an IP address becomes that address.
    public init(name: String, port: UInt16) {
        if let ipv4 = IPv4Address(name) {
            host = .ipv4(ipv4)
        } else if let ipv6 = IPv6Address(name) {
            host = .ipv6(ipv6)
        } else {
            host = .name(name)
        }
        self.port = port
    }

    public init?(_ endpoint: NWEndpoint) {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        switch host {
        case let .ipv4(address): self.host = .ipv4(address)
        case let .ipv6(address): self.host = .ipv6(address)
        case let .name(name, _): self.host = .name(name)
        @unknown default: return nil
        }
        self.port = port.rawValue
    }

    public var endpoint: NWEndpoint {
        let port = NWEndpoint.Port(rawValue: port) ?? .any
        switch host {
        case let .ipv4(address): return .hostPort(host: .ipv4(address), port: port)
        case let .ipv6(address): return .hostPort(host: .ipv6(address), port: port)
        case let .name(name): return .hostPort(host: .name(name, nil), port: port)
        }
    }

    public var isName: Bool {
        guard case .name = host else { return false }
        return true
    }

    public var description: String {
        switch host {
        case let .ipv4(address): return "\(address):\(port)"
        case let .ipv6(address): return "[\(address)]:\(port)"
        case let .name(name): return "\(name):\(port)"
        }
    }

    /// The SOCKS5 address: its type, the address, then the port.
    public var socks: Data {
        var data = Data()
        switch host {
        case let .ipv4(address):
            data.append(1)
            data.append(address.rawValue)
        case let .name(name):
            let bytes = Data(name.utf8.prefix(255))
            data.append(3)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        case let .ipv6(address):
            data.append(4)
            data.append(address.rawValue)
        }
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        return data
    }

    /// Reads a SOCKS5 address at `index` and moves past it.
    public static func read(from data: Data, at index: inout Int) -> Address? {
        guard index < data.endIndex else { return nil }
        let type = data[index]
        var cursor = index + 1
        let host: Host
        switch type {
        case 1:
            guard cursor + 4 <= data.endIndex, let address = IPv4Address(data[cursor..<cursor + 4]) else { return nil }
            host = .ipv4(address)
            cursor += 4
        case 3:
            guard cursor < data.endIndex else { return nil }
            let length = Int(data[cursor])
            cursor += 1
            guard cursor + length <= data.endIndex, let name = String(data: data[cursor..<cursor + length], encoding: .utf8) else { return nil }
            host = .name(name)
            cursor += length
        case 4:
            guard cursor + 16 <= data.endIndex, let address = IPv6Address(data[cursor..<cursor + 16]) else { return nil }
            host = .ipv6(address)
            cursor += 16
        default:
            return nil
        }
        guard cursor + 2 <= data.endIndex else { return nil }
        let port = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
        index = cursor + 2
        return Address(host: host, port: port)
    }

    /// Whether this is this Mac or the network it is on, which a proxy far away can't reach.
    public var isLocal: Bool {
        switch host {
        case let .ipv4(address):
            let bytes = [UInt8](address.rawValue)
            switch (bytes[0], bytes[1]) {
            case (0, _), (10, _), (127, _), (224..., _), (100, 64...127), (169, 254), (172, 16...31), (192, 168):
                return true
            default:
                return false
            }
        case let .ipv6(address):
            if let mapped = address.asIPv4 {
                return Address(host: .ipv4(mapped), port: port).isLocal
            }
            guard address != .loopback, address != .any else { return true }
            let bytes = [UInt8](address.rawValue)
            switch (bytes[0], bytes[1]) {
            case (0xFF, _), (0xFC...0xFD, _), (0xFE, 0x80...0xBF):
                return true
            default:
                return false
            }
        case let .name(name):
            let name = name.lowercased()
            return name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local")
        }
    }
}
