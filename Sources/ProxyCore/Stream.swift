import Foundation

public enum StreamError: LocalizedError {
    case decryptionFailed
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .decryptionFailed: return "The server's reply couldn't be decrypted. Check the link's password and cipher."
        case .badResponse: return "The server's reply wasn't Shadowsocks."
        }
    }
}

/// Encrypts what goes to the server over TCP: the salt and where to connect to (2022's request
/// header), then the data in length-prefixed chunks.
public struct RequestEncoder {
    public let salt: Data
    private let method: EncryptionMethod
    private let target: Address
    private let cipher: Cipher
    private var nonce = NonceCounter()
    private var hasSentHeader = false

    public init(server: Server, target: Address) {
        method = server.method
        self.target = target
        salt = randomBytes(server.method.keySize)
        cipher = Cipher(server: server, salt: salt)
    }

    private var maxChunk: Int { method.is2022 ? 0xFFFF : 0x3FFF }

    /// The bytes to send for `payload`. The first call starts the stream; it may be empty.
    public mutating func encode(_ payload: Data) -> Data {
        var output = Data(capacity: payload.count + 64)
        var payload = payload
        if !hasSentHeader {
            hasSentHeader = true
            output.append(salt)
            if method.is2022 {
                output.append(header(taking: &payload))
            } else {
                payload = target.socks + payload
            }
        }
        while !payload.isEmpty {
            let chunk = payload.prefix(maxChunk)
            payload = payload.dropFirst(chunk.count)
            var length = Data()
            length.appendBigEndian(UInt16(chunk.count))
            output.append(cipher.seal(length, nonce: nonce.next()))
            output.append(cipher.seal(chunk, nonce: nonce.next()))
        }
        return output
    }

    /// 2022's fixed and variable headers, with as much of `payload` as fits. Without a payload
    /// the header is padded, so its length gives nothing away.
    private mutating func header(taking payload: inout Data) -> Data {
        var variable = target.socks
        let padding = payload.isEmpty ? Int.random(in: 1...900) : 0
        variable.appendBigEndian(UInt16(padding))
        variable.append(randomBytes(padding))
        let initial = payload.prefix(0xFFFF - variable.count)
        payload = payload.dropFirst(initial.count)
        variable.append(initial)

        var fixed = Data([0])
        fixed.appendBigEndian(UInt64(Date().timeIntervalSince1970))
        fixed.appendBigEndian(UInt16(variable.count))
        return cipher.seal(fixed, nonce: nonce.next()) + cipher.seal(variable, nonce: nonce.next())
    }
}

/// Decrypts what comes back from the server over TCP, as it arrives in pieces.
public struct ResponseDecoder {
    private enum State {
        case salt
        case header
        case length
        case payload(Int)
    }

    private let server: Server
    private let requestSalt: Data
    private var cipher: Cipher?
    private var nonce = NonceCounter()
    private var state = State.salt
    private var buffer = Data()
    private var offset = 0

    public init(server: Server, requestSalt: Data) {
        self.server = server
        self.requestSalt = requestSalt
    }

    /// Takes the next bytes from the server and returns the data they complete.
    public mutating func decode(_ data: Data) throws -> Data {
        buffer.append(data)
        defer { compact() }
        var output = Data()
        let keySize = server.method.keySize
        while true {
            switch state {
            case .salt:
                guard let salt = take(keySize) else { return output }
                cipher = Cipher(server: server, salt: salt)
                state = server.method.is2022 ? .header : .length
            case .header:
                guard let sealed = take(1 + 8 + keySize + 2 + Cipher.tagSize) else { return output }
                let header = try open(sealed)
                let timestamp = header.readBigEndian(UInt64.self, at: 1)
                guard header[header.startIndex] == 1,
                      abs(Double(timestamp) - Date().timeIntervalSince1970) <= 30,
                      header.dropFirst(9).prefix(keySize) == requestSalt else { throw StreamError.badResponse }
                state = .payload(Int(header.readBigEndian(UInt16.self, at: 9 + keySize)))
            case .length:
                guard let sealed = take(2 + Cipher.tagSize) else { return output }
                let length = Int(try open(sealed).readBigEndian(UInt16.self, at: 0))
                state = .payload(server.method.is2022 ? length : length & 0x3FFF)
            case let .payload(length):
                guard let sealed = take(length + Cipher.tagSize) else { return output }
                output.append(try open(sealed))
                state = .length
            }
        }
    }

    private mutating func open(_ sealed: Data) throws -> Data {
        guard let cipher else { throw StreamError.badResponse }
        do {
            return try cipher.open(sealed, nonce: nonce.next())
        } catch {
            throw StreamError.decryptionFailed
        }
    }

    private mutating func take(_ count: Int) -> Data? {
        guard buffer.count - offset >= count else { return nil }
        let start = buffer.startIndex + offset
        offset += count
        return buffer[start..<start + count]
    }

    private mutating func compact() {
        guard offset > 0 else { return }
        buffer = Data(buffer.dropFirst(offset))
        offset = 0
    }
}
