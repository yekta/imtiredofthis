import CryptoKit
import Foundation

public enum TLSError: LocalizedError {
    case unexpectedMessage
    case alert(UInt8)
    case unsupportedServerHello
    case notREALITY
    case badSignature
    case badFinished
    case decryptionFailed
    case cutOff

    public var errorDescription: String? {
        switch self {
        case .unexpectedMessage: return "The server's TLS handshake was malformed."
        case let .alert(code): return "The server ended the TLS connection (alert \(code))."
        case .unsupportedServerHello: return "The server answered with TLS this client doesn't speak."
        case .notREALITY: return "The server answered with a real certificate, not REALITY's. Check the link's public key, short ID and server name."
        case .badSignature: return "The server's TLS signature didn't verify."
        case .badFinished: return "The server's TLS handshake didn't verify."
        case .decryptionFailed: return "The server's TLS data couldn't be decrypted."
        case .cutOff: return "The server closed the connection in the middle of a TLS record."
        }
    }
}

enum TLSContentType {
    static let changeCipherSpec: UInt8 = 20
    static let alert: UInt8 = 21
    static let handshake: UInt8 = 22
    static let applicationData: UInt8 = 23
}

/// TLS 1.3's hash, HMAC and HKDF, with SHA-256 or SHA-384.
enum TLSHash {
    case sha256
    case sha384

    var length: Int { self == .sha256 ? 32 : 48 }

    func hash(_ data: Data) -> Data {
        switch self {
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha384: return Data(SHA384.hash(data: data))
        }
    }

    func hmac(key: Data, _ data: Data) -> Data {
        let key = SymmetricKey(data: key)
        switch self {
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha384: return Data(HMAC<SHA384>.authenticationCode(for: data, using: key))
        }
    }

    func extract(salt: Data, _ material: Data) -> Data {
        hmac(key: salt.isEmpty ? Data(count: length) : salt, material)
    }

    func expand(_ secret: Data, info: Data, count: Int) -> Data {
        var output = Data()
        var block = Data()
        var counter: UInt8 = 1
        while output.count < count {
            block = hmac(key: secret, block + info + Data([counter]))
            output.append(block)
            counter += 1
        }
        return output.prefix(count)
    }

    func expandLabel(_ secret: Data, _ label: String, context: Data = Data(), count: Int? = nil) -> Data {
        let count = count ?? length
        let label = Data("tls13 \(label)".utf8)
        var info = Data()
        info.appendBigEndian(UInt16(count))
        info.append(UInt8(label.count))
        info.append(label)
        info.append(UInt8(context.count))
        info.append(context)
        return expand(secret, info: info, count: count)
    }

    func deriveSecret(_ secret: Data, _ label: String, transcript: Data) -> Data {
        expandLabel(secret, label, context: hash(transcript))
    }
}

/// The TLS 1.3 cipher suites: AES-GCM and ChaCha20-Poly1305.
struct TLSCipherSuite {
    let id: UInt16
    let hash: TLSHash
    let keyLength: Int
    let isChaCha: Bool

    static let all = [
        TLSCipherSuite(id: 0x1301, hash: .sha256, keyLength: 16, isChaCha: false),
        TLSCipherSuite(id: 0x1302, hash: .sha384, keyLength: 32, isChaCha: false),
        TLSCipherSuite(id: 0x1303, hash: .sha256, keyLength: 32, isChaCha: true),
    ]

    static func with(id: UInt16) -> TLSCipherSuite? {
        all.first { $0.id == id }
    }
}

/// One direction's record protection: the key and IV from a traffic secret, and the sequence number.
struct RecordProtection {
    private(set) var secret: Data
    private let suite: TLSCipherSuite
    private var key: SymmetricKey
    private var iv: Data
    private var sequence: UInt64 = 0

    init(suite: TLSCipherSuite, secret: Data) {
        self.suite = suite
        self.secret = secret
        key = SymmetricKey(data: suite.hash.expandLabel(secret, "key", count: suite.keyLength))
        iv = suite.hash.expandLabel(secret, "iv", count: 12)
    }

    /// KeyUpdate's next secret.
    mutating func update() {
        self = RecordProtection(suite: suite, secret: suite.hash.expandLabel(secret, "traffic upd"))
    }

    mutating func seal(_ content: Data, type: UInt8) -> Data {
        var plaintext = content
        plaintext.append(type)
        var header = Data([TLSContentType.applicationData, 3, 3])
        header.appendBigEndian(UInt16(plaintext.count + 16))
        let nonce = nextNonce()
        let sealed: Data
        if suite.isChaCha {
            let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: header)
            sealed = box.ciphertext + box.tag
        } else {
            let box = try! AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
            sealed = box.ciphertext + box.tag
        }
        return header + sealed
    }

    /// The content and its type, from a record's header and body.
    mutating func open(header: Data, body: Data) throws -> (type: UInt8, content: Data) {
        guard body.count >= 17 else { throw TLSError.decryptionFailed }
        let nonce = nextNonce()
        let ciphertext = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        var plaintext: Data
        do {
            if suite.isChaCha {
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                plaintext = try ChaChaPoly.open(box, using: key, authenticating: header)
            } else {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                plaintext = try AES.GCM.open(box, using: key, authenticating: header)
            }
        } catch {
            throw TLSError.decryptionFailed
        }
        while let last = plaintext.last, last == 0 {
            plaintext.removeLast()
        }
        guard let type = plaintext.popLast() else { throw TLSError.unexpectedMessage }
        return (type, plaintext)
    }

    private mutating func nextNonce() -> Data {
        var nonce = iv
        for i in 0..<8 {
            nonce[nonce.startIndex + 4 + i] ^= UInt8(truncatingIfNeeded: sequence >> (56 - 8 * i))
        }
        sequence += 1
        return nonce
    }
}

/// Splits what comes from the server into TLS records, as it arrives in pieces.
struct RecordReader {
    private var buffer = Data()
    private var offset = 0

    mutating func append(_ data: Data) {
        if offset > 0 {
            buffer = Data(buffer.dropFirst(offset))
            offset = 0
        }
        buffer.append(data)
    }

    /// The next whole record's header and body.
    mutating func next() -> (header: Data, body: Data)? {
        let start = buffer.startIndex + offset
        guard buffer.count - offset >= 5 else { return nil }
        let length = Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
        guard buffer.count - offset >= 5 + length else { return nil }
        offset += 5 + length
        return (Data(buffer[start..<start + 5]), Data(buffer[start + 5..<start + 5 + length]))
    }

    var isBetweenRecords: Bool { buffer.count == offset }

    /// Whatever has arrived past the records read so far.
    mutating func takeRest() -> Data {
        defer {
            buffer = Data()
            offset = 0
        }
        return Data(buffer.dropFirst(offset))
    }
}

/// An established TLS 1.3 connection's records, both ways.
struct TLSRecordLayer {
    enum Record {
        case data(Data)
        case closed
    }

    private var writer: RecordProtection
    private var reader: RecordProtection
    private var records = RecordReader()

    init(writer: RecordProtection, reader: RecordProtection) {
        self.writer = writer
        self.reader = reader
    }

    mutating func seal(_ data: Data) -> Data {
        var output = Data()
        var rest = data[...]
        repeat {
            let chunk = rest.prefix(16384)
            rest = rest.dropFirst(chunk.count)
            output.append(writer.seal(Data(chunk), type: TLSContentType.applicationData))
        } while !rest.isEmpty
        return output
    }

    mutating func append(_ data: Data) {
        records.append(data)
    }

    /// The next record's data, or nil until a whole one has arrived.
    mutating func next() throws -> Record? {
        while let (header, body) = records.next() {
            switch header[header.startIndex] {
            case TLSContentType.changeCipherSpec:
                continue
            case TLSContentType.applicationData:
                break
            default:
                throw TLSError.unexpectedMessage
            }
            let (type, content) = try reader.open(header: header, body: body)
            switch type {
            case TLSContentType.applicationData:
                return .data(content)
            case TLSContentType.alert:
                guard content.count >= 2, content[content.startIndex + 1] == 0 else {
                    throw TLSError.alert(content.count >= 2 ? content[content.startIndex + 1] : 0)
                }
                return .closed
            case TLSContentType.handshake:
                // New session tickets go unused; a key update changes the server's key.
                if content.first == 24 {
                    reader.update()
                }
            default:
                throw TLSError.unexpectedMessage
            }
        }
        return nil
    }

    var isBetweenRecords: Bool { records.isBetweenRecords }

    mutating func takeRest() -> Data {
        records.takeRest()
    }
}
