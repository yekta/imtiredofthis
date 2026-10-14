import CryptoKit
import Foundation

/// The Shadowsocks ciphers we speak: the AEAD ones, and Shadowsocks 2022's.
public enum EncryptionMethod: String, CaseIterable, Sendable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20Poly1305 = "chacha20-ietf-poly1305"
    case blake3AES128GCM = "2022-blake3-aes-128-gcm"
    case blake3AES256GCM = "2022-blake3-aes-256-gcm"

    public var keySize: Int {
        switch self {
        case .aes128GCM, .blake3AES128GCM: return 16
        case .aes256GCM, .chacha20Poly1305, .blake3AES256GCM: return 32
        }
    }

    public var is2022: Bool {
        self == .blake3AES128GCM || self == .blake3AES256GCM
    }

    var isChaCha: Bool { self == .chacha20Poly1305 }
}

/// A Shadowsocks server, read from an `ss://` link.
public struct Server: Hashable, Sendable {
    public let method: EncryptionMethod
    public let host: String
    public let port: UInt16
    public let name: String?
    /// The password's key for the AEAD ciphers; the pre-shared key for 2022's.
    let key: Data

    public var address: Address { Address(name: host, port: port) }

    public init(method: EncryptionMethod, password: String, host: String, port: UInt16, name: String? = nil) throws {
        guard !host.isEmpty, port != 0 else { throw ServerError.badAddress }
        self.method = method
        self.host = host
        self.port = port
        self.name = name
        if method.is2022 {
            guard let key = Data(base64Encoded: password), key.count == method.keySize else {
                throw ServerError.badKey(method)
            }
            self.key = key
        } else {
            guard !password.isEmpty else { throw ServerError.badKey(method) }
            key = Self.bytesToKey(Data(password.utf8), count: method.keySize)
        }
    }

    /// Reads SIP002 links (`ss://userinfo@host:port#name`, the userinfo in base64 or, for 2022's
    /// ciphers, percent-encoded) and the old ones that are all base64 (`ss://base64#name`).
    public init(link: String) throws {
        var rest = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.lowercased().hasPrefix("ss://") else { throw ServerError.notALink }
        rest.removeFirst(5)

        var name: String?
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }
        if let question = rest.firstIndex(of: "?") {
            let query = String(rest[rest.index(after: question)...])
            rest = String(rest[..<question])
            if query.split(separator: "&").contains(where: { $0.hasPrefix("plugin=") && $0.count > 7 }) {
                throw ServerError.plugin
            }
        }
        while rest.hasSuffix("/") {
            rest.removeLast()
        }

        let userInfo: String
        let hostPort: String
        if let at = rest.lastIndex(of: "@") {
            let encoded = String(rest[..<at])
            hostPort = String(rest[rest.index(after: at)...])
            if let decoded = encoded.removingPercentEncoding, decoded.contains(":") {
                userInfo = decoded
            } else {
                guard let decoded = Self.base64Decoded(encoded) else { throw ServerError.notALink }
                userInfo = decoded
            }
        } else {
            guard let decoded = Self.base64Decoded(rest), let at = decoded.lastIndex(of: "@") else { throw ServerError.notALink }
            userInfo = String(decoded[..<at])
            hostPort = String(decoded[decoded.index(after: at)...])
        }

        guard let colon = userInfo.firstIndex(of: ":") else { throw ServerError.notALink }
        let methodName = String(userInfo[..<colon]).lowercased()
        guard let method = EncryptionMethod(rawValue: methodName) else { throw ServerError.unknownMethod(methodName) }
        let password = String(userInfo[userInfo.index(after: colon)...])

        guard let portColon = hostPort.lastIndex(of: ":"), let port = UInt16(hostPort[hostPort.index(after: portColon)...]) else {
            throw ServerError.badAddress
        }
        var host = String(hostPort[..<portColon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        try self.init(method: method, password: password, host: host, port: port, name: name?.isEmpty == false ? name : nil)
    }

    /// OpenSSL's `EVP_BytesToKey` with MD5, which turns a password into the AEAD ciphers' key.
    static func bytesToKey(_ password: Data, count: Int) -> Data {
        var key = Data()
        var previous = Data()
        while key.count < count {
            previous = Data(Insecure.MD5.hash(data: previous + password))
            key.append(previous)
        }
        return key.prefix(count)
    }

    private static func base64Decoded(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.removingPercentEncoding ?? base64
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

public enum ServerError: LocalizedError, Equatable {
    case notALink
    case unknownMethod(String)
    case badKey(EncryptionMethod)
    case badAddress
    case plugin

    public var errorDescription: String? {
        switch self {
        case .notALink: return "That isn't a Shadowsocks link. It starts with ss://."
        case let .unknownMethod(name): return "The \(name) cipher isn't supported. Use aes-256-gcm, chacha20-ietf-poly1305 or a 2022-blake3 one."
        case let .badKey(method) where method.is2022: return "The key must be \(method.keySize) bytes in base64 for \(method.rawValue)."
        case .badKey: return "The link has no password."
        case .badAddress: return "The link's server address is missing or wrong."
        case .plugin: return "Servers behind plugins (like obfs or v2ray) aren't supported."
        }
    }
}
