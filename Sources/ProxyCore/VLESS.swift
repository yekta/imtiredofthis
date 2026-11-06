import Foundation

/// A VLESS server behind REALITY, read from a `vless://` link.
public struct VLESSServer: Hashable, Sendable {
    public let id: UUID
    public private(set) var host: String
    public let port: UInt16
    public let name: String?
    /// The site REALITY passes for, the ClientHello's server name.
    public let serverName: String
    /// The server's X25519 public key.
    let publicKey: Data
    let shortID: Data
    /// Whether TCP goes with the xtls-rprx-vision flow.
    public let usesVision: Bool
    /// Vision leaves out UDP to port 443, QUIC, so browsers fall back to TCP; `-udp443` lets it through.
    let allowsUDP443: Bool

    public var address: Address { Address(name: host, port: port) }

    /// The same server at an IP address its host resolved to. REALITY's server name stays.
    public func connecting(to ip: String) -> VLESSServer {
        var server = self
        server.host = ip
        return server
    }

    static let visionFlow = "xtls-rprx-vision"

    /// Reads `vless://uuid@host:port?security=reality&pbk=…&sni=…&sid=…&flow=…#name`.
    public init(link: String) throws {
        guard #available(macOS 26.0, *) else { throw VLESSError.needsNewerMacOS }
        var rest = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.lowercased().hasPrefix("vless://") else { throw VLESSError.notALink }
        rest.removeFirst(8)

        var name: String?
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }
        var query: [String: String] = [:]
        if let question = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: question)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""
                query[String(key).lowercased()] = value.removingPercentEncoding ?? value
            }
            rest = String(rest[..<question])
        }
        while rest.hasSuffix("/") {
            rest.removeLast()
        }

        guard let at = rest.lastIndex(of: "@"),
              let id = UUID(uuidString: String(rest[..<at]).removingPercentEncoding ?? "") else { throw VLESSError.badID }
        let hostPort = rest[rest.index(after: at)...]
        guard let colon = hostPort.lastIndex(of: ":"), let port = UInt16(hostPort[hostPort.index(after: colon)...]), port != 0 else {
            throw VLESSError.badAddress
        }
        var host = String(hostPort[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { throw VLESSError.badAddress }

        guard query["security"] == "reality" else { throw VLESSError.notREALITY }
        guard ["", "none"].contains(query["encryption"] ?? "") else { throw VLESSError.encryption }
        guard ["", "tcp", "raw"].contains(query["type"] ?? "") else { throw VLESSError.transport(query["type"] ?? "") }
        let flow = query["flow"] ?? ""
        guard ["", Self.visionFlow, Self.visionFlow + "-udp443"].contains(flow) else { throw VLESSError.flow(flow) }
        guard let serverName = query["sni"], !serverName.isEmpty else { throw VLESSError.noServerName }
        guard let publicKey = Self.base64URLDecoded(query["pbk"] ?? ""), publicKey.count == 32 else { throw VLESSError.badPublicKey }
        guard let shortID = Self.hexDecoded(query["sid"] ?? ""), shortID.count <= 8 else { throw VLESSError.badShortID }

        self.id = id
        self.host = host
        self.port = port
        self.name = name?.isEmpty == false ? name : nil
        self.serverName = serverName
        self.publicKey = publicKey
        self.shortID = shortID
        usesVision = !flow.isEmpty
        allowsUDP443 = flow.hasSuffix("-udp443")
    }

    var idBytes: Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

public enum VLESSError: LocalizedError, Equatable {
    case notALink
    case badID
    case badAddress
    case notREALITY
    case encryption
    case transport(String)
    case flow(String)
    case noServerName
    case badPublicKey
    case badShortID
    case badResponse
    case needsNewerMacOS

    public var errorDescription: String? {
        switch self {
        case .notALink: return "That isn't a VLESS link. It starts with vless://."
        case .badID: return "The link's user ID isn't a UUID."
        case .badAddress: return "The link's server address is missing or wrong."
        case .notREALITY: return "Only VLESS over REALITY (security=reality) is supported."
        case .encryption: return "VLESS encryption isn't supported. The link needs encryption=none."
        case let .transport(type): return "The \(type) transport isn't supported. Use TCP (type=tcp)."
        case let .flow(flow): return "The \(flow) flow isn't supported. Use xtls-rprx-vision or none."
        case .noServerName: return "The link has no server name (sni)."
        case .badPublicKey: return "The link's public key (pbk) is missing or wrong."
        case .badShortID: return "The link's short ID (sid) must be up to 16 hex digits."
        case .badResponse: return "The server's reply wasn't VLESS."
        case .needsNewerMacOS: return "VLESS needs macOS 26 or later."
        }
    }
}

enum VLESSCommand: UInt8 {
    case tcp = 1
    case udp = 2
}

extension VLESSServer {
    /// The request: version 0, the user ID, the flow as protobuf addons, the command, then where to.
    func requestHeader(_ command: VLESSCommand, to target: Address) -> Data {
        var header = Data([0])
        header.append(idBytes)
        if usesVision && command == .tcp {
            let flow = Data(Self.visionFlow.utf8)
            header.append(UInt8(2 + flow.count))
            header.append(contentsOf: [0x0A, UInt8(flow.count)])
            header.append(flow)
        } else {
            header.append(0)
        }
        header.append(command.rawValue)
        header.appendBigEndian(target.port)
        switch target.host {
        case let .ipv4(address):
            header.append(1)
            header.append(address.rawValue)
        case let .name(name):
            let bytes = Data(name.utf8.prefix(255))
            header.append(2)
            header.append(UInt8(bytes.count))
            header.append(bytes)
        case let .ipv6(address):
            header.append(3)
            header.append(address.rawValue)
        }
        return header
    }
}

/// XTLS Vision, Xray's flow for TCP. While the app's own TLS handshake goes on, its records go in
/// padded blocks, so their sizes don't show TLS inside TLS. Once the app's TLS 1.3 carries data,
/// both sides end the padding with a command to switch to raw TCP, and the app's records go
/// straight over the socket, without being encrypted twice.
struct Vision {
    private enum Command {
        static let paddingContinue: UInt8 = 0
        static let paddingEnd: UInt8 = 1
        static let paddingDirect: UInt8 = 2
    }

    private static let blockSize = 8192
    private static let applicationDataStart = Data([0x17, 0x03, 0x03])

    private let id: Data
    private var idToSend: Data?
    private var packetsToFilter = 8
    private var isTLS = false
    private var isTLS12OrAbove = false
    private var enablesDirect = false
    private var cipher: UInt16 = 0
    private var remainingServerHello = -1

    private var isPadding = true

    private var readsPadded = true
    private var remainingCommand = -1
    private var remainingContent = -1
    private var remainingPadding = -1
    private var currentCommand = 0

    init(id: Data) {
        self.id = id
        idToSend = id
    }

    /// What to send for `data`, and whether what comes after goes straight over the socket.
    mutating func pad(_ data: Data) -> (bytes: Data, thenDirect: Bool) {
        if packetsToFilter > 0, !data.isEmpty {
            filter(data)
        }
        guard isPadding else { return (data, false) }
        guard !data.isEmpty else {
            return (block(Data(), command: Command.paddingContinue, longPadding: true), false)
        }
        let isComplete = Self.isCompleteRecords(data)
        let pieces = Self.reshape(data)
        var longPadding = isTLS
        var thenDirect = false
        var output = Data()
        for (i, piece) in pieces.enumerated() {
            let isLast = i == pieces.count - 1
            if isTLS, piece.count >= 6, piece.starts(with: Self.applicationDataStart), isComplete {
                thenDirect = thenDirect || enablesDirect
                let command = isLast ? (enablesDirect ? Command.paddingDirect : Command.paddingEnd) : Command.paddingContinue
                output.append(block(piece, command: command, longPadding: true))
                isPadding = false
                longPadding = false
                continue
            }
            if !isTLS12OrAbove, packetsToFilter <= 1 {
                isPadding = false
                output.append(block(piece, command: Command.paddingEnd, longPadding: longPadding))
                for rest in pieces.dropFirst(i + 1) {
                    output.append(rest)
                }
                break
            }
            var command = Command.paddingContinue
            if isLast, !isPadding {
                command = enablesDirect ? Command.paddingDirect : Command.paddingEnd
            }
            output.append(block(piece, command: command, longPadding: longPadding))
        }
        return (output, thenDirect)
    }

    /// The data in what the server sent, and whether what comes after it is raw, straight off the socket.
    mutating func unpad(_ data: Data) -> (data: Data, direct: Bool) {
        var output = data
        var direct = false
        if readsPadded || packetsToFilter > 0 {
            output = unpadding(data)
            if remainingContent > 0 || remainingPadding > 0 || currentCommand == 0 {
                readsPadded = true
            } else if currentCommand == 1 {
                readsPadded = false
            } else if currentCommand == 2 {
                readsPadded = false
                direct = true
            }
        }
        if packetsToFilter > 0, !output.isEmpty {
            filter(output)
        }
        return (output, direct)
    }

    private mutating func block(_ content: Data, command: UInt8, longPadding: Bool) -> Data {
        var padding = content.count < 900 && longPadding ? Int.random(in: 0..<500) + 900 - content.count : Int.random(in: 0..<256)
        padding = min(padding, Self.blockSize - 21 - content.count)
        var output = idToSend ?? Data()
        idToSend = nil
        output.append(command)
        output.appendBigEndian(UInt16(content.count))
        output.appendBigEndian(UInt16(padding))
        output.append(content)
        output.append(Data(count: padding))
        return output
    }

    private mutating func unpadding(_ data: Data) -> Data {
        var input = data[...]
        if remainingCommand == -1, remainingContent == -1, remainingPadding == -1 {
            guard input.count >= 21, input.prefix(16) == id else { return data }
            input = input.dropFirst(16)
            remainingCommand = 5
        }
        var output = Data()
        while !input.isEmpty {
            if remainingCommand > 0 {
                let byte = Int(input.removeFirst())
                switch remainingCommand {
                case 5: currentCommand = byte
                case 4: remainingContent = byte << 8
                case 3: remainingContent |= byte
                case 2: remainingPadding = byte << 8
                default: remainingPadding |= byte
                }
                remainingCommand -= 1
            } else if remainingContent > 0 {
                let count = min(remainingContent, input.count)
                output.append(input.prefix(count))
                input = input.dropFirst(count)
                remainingContent -= count
            } else {
                let count = min(remainingPadding, input.count)
                input = input.dropFirst(count)
                remainingPadding -= count
            }
            if remainingCommand <= 0, remainingContent <= 0, remainingPadding <= 0 {
                guard currentCommand != 0 else {
                    remainingCommand = 5
                    continue
                }
                remainingCommand = -1
                remainingContent = -1
                remainingPadding = -1
                output.append(input)
                break
            }
        }
        return output
    }

    /// Watches the first packets both ways for the app's TLS: its ClientHello, then the server's
    /// ServerHello, whose version and cipher say whether the switch to raw TCP is safe.
    private mutating func filter(_ data: Data) {
        packetsToFilter -= 1
        let bytes = [UInt8](data.prefix(6))
        if bytes.count == 6 {
            if bytes[0] == 0x16, bytes[1] == 3, bytes[2] == 3, bytes[5] == 2 {
                remainingServerHello = (Int(bytes[3]) << 8 | Int(bytes[4])) + 5
                isTLS12OrAbove = true
                isTLS = true
                if data.count >= 79, remainingServerHello >= 79 {
                    let sessionIDLength = Int(data[data.startIndex + 43])
                    if data.count >= 43 + sessionIDLength + 3 {
                        cipher = UInt16(data.readBigEndian(UInt16.self, at: 43 + sessionIDLength + 1))
                    }
                }
            } else if bytes[0] == 0x16, bytes[1] == 3, bytes[5] == 1 {
                isTLS = true
            }
        }
        guard remainingServerHello > 0 else { return }
        let end = min(remainingServerHello, data.count)
        remainingServerHello -= data.count
        if data.prefix(end).range(of: Data([0x00, 0x2B, 0x00, 0x02, 0x03, 0x04])) != nil {
            enablesDirect = (0x1301...0x1304).contains(cipher)
            packetsToFilter = 0
        } else if remainingServerHello <= 0 {
            packetsToFilter = 0
        }
    }

    /// Whether `data` is whole TLS application data records and nothing else.
    static func isCompleteRecords(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex {
            guard data.endIndex - index >= 5, data[index] == 0x17, data[index + 1] == 3, data[index + 2] == 3 else { return false }
            let length = Int(data[index + 3]) << 8 | Int(data[index + 4])
            guard length > 0, data.endIndex - index - 5 >= length else { return false }
            index += 5 + length
        }
        return true
    }

    /// Pieces that fit a block: Xray's buffers, split where a record starts when they are near full.
    static func reshape(_ data: Data) -> [Data] {
        var pieces: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let piece = data[index..<min(index + blockSize, data.endIndex)]
            index += piece.count
            guard piece.count >= blockSize - 21 else {
                pieces.append(Data(piece))
                continue
            }
            var split = piece.startIndex + blockSize / 2
            if let start = piece.range(of: applicationDataStart, options: .backwards)?.lowerBound,
               start - piece.startIndex >= 21, start - piece.startIndex <= blockSize - 21 {
                split = start
            }
            pieces.append(Data(piece[..<split]))
            pieces.append(Data(piece[split...]))
        }
        return pieces
    }
}
