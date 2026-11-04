import CryptoKit
import Foundation

/// REALITY's TLS 1.3 handshake, as the client. The ClientHello is Safari's, and its session ID
/// carries, sealed under a key only the server can also derive, our version, the time and the
/// short ID. The server proves it has that key with the HMAC in its certificate's signature; a
/// server without it hands us to the real site, whose certificate fails that check.
@available(macOS 26.0, *)
struct REALITYHandshake {
    struct Established {
        var records: TLSRecordLayer
        /// Our ChangeCipherSpec and Finished, to send before any data.
        let finished: Data
    }

    /// The ClientHello, in its record.
    let clientHello: Data
    private let x25519: Curve25519.KeyAgreement.PrivateKey
    private let mlkem: MLKEM768.PrivateKey
    private let authKey: SymmetricKey
    private var transcript: Data
    private var records = RecordReader()
    private var messages = Data()
    private var suite: TLSCipherSuite?
    private var handshakeSecret = Data()
    private var clientSecret = Data()
    private var serverSecret = Data()
    private var serverProtection: RecordProtection?
    private var certificateKey: Curve25519.Signing.PublicKey?
    private var hasVerifiedCertificate = false

    /// Xray's version, which the server may require a minimum of.
    static let version: [UInt8] = [26, 10, 31]
    private static let helloRetryRandom = Data(SHA256.hash(data: Data("HelloRetryRequest".utf8)))

    init(server: VLESSServer) throws {
        x25519 = Curve25519.KeyAgreement.PrivateKey()
        mlkem = try MLKEM768.PrivateKey()
        let random = randomBytes(32)
        var hello = Self.clientHello(
            serverName: server.serverName, random: random,
            mlkemShare: mlkem.publicKey.rawRepresentation + x25519.publicKey.rawRepresentation,
            x25519Share: x25519.publicKey.rawRepresentation
        )

        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: server.publicKey)
        authKey = try x25519.sharedSecretFromKeyAgreement(with: serverKey).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: random.prefix(20), sharedInfo: Data("REALITY".utf8), outputByteCount: 32
        )
        var sessionID = Data(Self.version + [0])
        sessionID.appendBigEndian(UInt32(Date().timeIntervalSince1970))
        sessionID.append(server.shortID)
        sessionID.append(Data(count: 8 - server.shortID.count))
        let sealed = try AES.GCM.seal(sessionID, using: authKey, nonce: AES.GCM.Nonce(data: random.suffix(12)), authenticating: hello)
        hello.replaceSubrange(39..<71, with: sealed.ciphertext + sealed.tag)

        transcript = hello
        var record = Data([TLSContentType.handshake, 3, 1])
        record.appendBigEndian(UInt16(hello.count))
        clientHello = record + hello
    }

    /// Takes the server's next bytes. Once its handshake is complete and checks out, returns the
    /// connection, with whatever came after the handshake in its records.
    mutating func receive(_ data: Data) throws -> Established? {
        records.append(data)
        while let (header, body) = records.next() {
            switch header[header.startIndex] {
            case TLSContentType.handshake:
                guard serverProtection == nil else { throw TLSError.unexpectedMessage }
                messages.append(body)
            case TLSContentType.changeCipherSpec:
                continue
            case TLSContentType.alert:
                throw TLSError.alert(body.count >= 2 ? body[body.startIndex + 1] : 0)
            case TLSContentType.applicationData:
                guard var protection = serverProtection else { throw TLSError.unexpectedMessage }
                let (type, content) = try protection.open(header: header, body: body)
                serverProtection = protection
                if type == TLSContentType.alert {
                    throw TLSError.alert(content.count >= 2 ? content[content.startIndex + 1] : 0)
                }
                guard type == TLSContentType.handshake else { throw TLSError.unexpectedMessage }
                messages.append(content)
            default:
                throw TLSError.unexpectedMessage
            }
            guard var established = try readMessages() else { continue }
            established.records.append(records.takeRest())
            return established
        }
        return nil
    }

    private mutating func readMessages() throws -> Established? {
        while messages.count >= 4 {
            let length = Int(messages.readBigEndian(UInt32.self, at: 0) & 0xFFFFFF)
            guard messages.count >= 4 + length else { return nil }
            let message = Data(messages.prefix(4 + length))
            messages = Data(messages.dropFirst(4 + length))
            if let established = try read(message) {
                return established
            }
        }
        return nil
    }

    private mutating func read(_ message: Data) throws -> Established? {
        let type = message[message.startIndex]
        var reader = ByteReader(message.dropFirst(4))
        switch type {
        case 2 where suite == nil:
            try readServerHello(&reader)
            transcript.append(message)
            deriveHandshakeSecrets()
        case 8 where suite != nil && certificateKey == nil:
            transcript.append(message)
        case 11 where suite != nil && certificateKey == nil:
            guard try reader.bytes(reader.integer(1)) != nil, try reader.integer(3) > 0,
                  let certificate = try reader.bytes(reader.integer(3)) else { throw TLSError.unexpectedMessage }
            certificateKey = try realityKey(in: certificate)
            transcript.append(message)
        case 15 where certificateKey != nil && !hasVerifiedCertificate:
            guard let suite, let certificateKey, try reader.integer(2) == 0x0807,
                  let signature = try reader.bytes(reader.integer(2)) else { throw TLSError.badSignature }
            let signed = Data(repeating: 0x20, count: 64) + Data("TLS 1.3, server CertificateVerify".utf8) + Data([0]) + suite.hash.hash(transcript)
            guard certificateKey.isValidSignature(signature, for: signed) else { throw TLSError.badSignature }
            hasVerifiedCertificate = true
            transcript.append(message)
        case 20 where hasVerifiedCertificate:
            guard let suite else { throw TLSError.unexpectedMessage }
            let expected = suite.hash.hmac(key: suite.hash.expandLabel(serverSecret, "finished"), suite.hash.hash(transcript))
            guard message.dropFirst(4) == expected else { throw TLSError.badFinished }
            transcript.append(message)
            return finish(suite)
        case 25:
            throw TLSError.notREALITY
        default:
            throw TLSError.unexpectedMessage
        }
        return nil
    }

    private mutating func readServerHello(_ reader: inout ByteReader) throws {
        guard try reader.integer(2) == 0x0303, let random = reader.bytes(32), random != Self.helloRetryRandom,
              try reader.bytes(reader.integer(1)) != nil,
              let suite = try TLSCipherSuite.with(id: UInt16(reader.integer(2))),
              try reader.integer(1) == 0 else { throw TLSError.unsupportedServerHello }
        var extensions = try ByteReader(reader.bytes(reader.integer(2)) ?? Data())
        var version = 0
        var share: (group: Int, key: Data)?
        while !extensions.isAtEnd {
            let type = try extensions.integer(2)
            guard var body = try extensions.bytes(extensions.integer(2)).map(ByteReader.init) else { throw TLSError.unexpectedMessage }
            switch type {
            case 43: version = try body.integer(2)
            case 51: share = try (body.integer(2), body.bytes(body.integer(2)) ?? Data())
            default: break
            }
        }
        guard version == 0x0304, let share else { throw TLSError.unsupportedServerHello }
        handshakeSecret = try sharedSecret(group: share.group, key: share.key)
        self.suite = suite
    }

    /// X25519's secret, or X25519MLKEM768's: ML-KEM's, then X25519's.
    private func sharedSecret(group: Int, key: Data) throws -> Data {
        switch (group, key.count) {
        case (0x001D, 32):
            return try x25519Secret(key)
        case (0x11EC, 1088 + 32):
            let mlkemSecret = try mlkem.decapsulate(key.prefix(1088)).withUnsafeBytes { Data($0) }
            return try mlkemSecret + x25519Secret(key.suffix(32))
        default:
            throw TLSError.unsupportedServerHello
        }
    }

    private func x25519Secret(_ key: Data) throws -> Data {
        let secret = try x25519.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: key))
        return secret.withUnsafeBytes { Data($0) }
    }

    private mutating func deriveHandshakeSecrets() {
        guard let suite else { return }
        let hash = suite.hash
        let early = hash.extract(salt: Data(), Data(count: hash.length))
        let secret = hash.extract(salt: hash.deriveSecret(early, "derived", transcript: Data()), handshakeSecret)
        handshakeSecret = secret
        clientSecret = hash.deriveSecret(secret, "c hs traffic", transcript: transcript)
        serverSecret = hash.deriveSecret(secret, "s hs traffic", transcript: transcript)
        serverProtection = RecordProtection(suite: suite, secret: serverSecret)
    }

    private func finish(_ suite: TLSCipherSuite) -> Established {
        let hash = suite.hash
        let master = hash.extract(salt: hash.deriveSecret(handshakeSecret, "derived", transcript: Data()), Data(count: hash.length))
        let clientTraffic = hash.deriveSecret(master, "c ap traffic", transcript: transcript)
        let serverTraffic = hash.deriveSecret(master, "s ap traffic", transcript: transcript)

        let verifyData = hash.hmac(key: hash.expandLabel(clientSecret, "finished"), hash.hash(transcript))
        var finished = Data([20, 0, 0, UInt8(verifyData.count)])
        finished.append(verifyData)
        var protection = RecordProtection(suite: suite, secret: clientSecret)
        let flight = Data([TLSContentType.changeCipherSpec, 3, 3, 0, 1, 1]) + protection.seal(finished, type: TLSContentType.handshake)
        return Established(
            records: TLSRecordLayer(writer: RecordProtection(suite: suite, secret: clientTraffic),
                                    reader: RecordProtection(suite: suite, secret: serverTraffic)),
            finished: flight
        )
    }

    /// The certificate's Ed25519 key, when its signature is REALITY's: the HMAC-SHA512 of the key
    /// under the auth key.
    private func realityKey(in certificate: Data) throws -> Curve25519.Signing.PublicKey {
        guard let parts = DER.children(of: certificate).first.flatMap({ DER.children(of: $0.content) }), parts.count == 3,
              case let tbs = DER.children(of: parts[0].content), tbs.count >= 7,
              case let keyInfo = DER.children(of: tbs[tbs[0].tag == 0xA0 ? 6 : 5].content), keyInfo.count == 2,
              DER.children(of: keyInfo[0].content).first?.content == Data([0x2B, 0x65, 0x70]),
              keyInfo[1].content.count == 33, parts[2].content.count == 65 else { throw TLSError.notREALITY }
        let key = keyInfo[1].content.dropFirst()
        let signature = parts[2].content.dropFirst()
        guard HMAC<SHA512>.isValidAuthenticationCode(signature, authenticating: key, using: authKey) else { throw TLSError.notREALITY }
        return try Curve25519.Signing.PublicKey(rawRepresentation: key)
    }

    /// Safari 26's ClientHello, with an empty session ID for REALITY's to replace.
    static func clientHello(serverName: String, random: Data, mlkemShare: Data, x25519Share: Data) -> Data {
        let cipherGrease = grease(), groupGrease = grease(), versionGrease = grease(), firstExtensionGrease = grease()
        var lastExtensionGrease = grease()
        if lastExtensionGrease == firstExtensionGrease {
            lastExtensionGrease ^= 0x1010
        }

        var body = Data([3, 3])
        body.append(random)
        body.append(32)
        body.append(Data(count: 32))
        let suites: [UInt16] = [cipherGrease, 0x1302, 0x1303, 0x1301, 0xC02C, 0xC02B, 0xCCA9, 0xC030, 0xC02F, 0xCCA8,
                                0xC00A, 0xC009, 0xC014, 0xC013, 0x009D, 0x009C, 0x0035, 0x002F, 0xC008, 0xC012, 0x000A]
        body.append(lengthPrefixed(2, list(suites)))
        body.append(contentsOf: [1, 0])

        let name = Data(serverName.utf8)
        var keyShares = Data()
        for (group, key) in [(groupGrease, Data([0])), (0x11EC, mlkemShare), (0x001D, x25519Share)] {
            keyShares.appendBigEndian(group)
            keyShares.append(lengthPrefixed(2, key))
        }
        let extensions: [(UInt16, Data)] = [
            (firstExtensionGrease, Data()),
            (0, lengthPrefixed(2, Data([0]) + lengthPrefixed(2, name))),
            (23, Data()),
            (0xFF01, Data([0])),
            (10, lengthPrefixed(2, list([groupGrease, 0x11EC, 0x001D, 0x0017, 0x0018, 0x0019]))),
            (11, Data([1, 0])),
            (16, lengthPrefixed(2, lengthPrefixed(1, Data("h2".utf8)) + lengthPrefixed(1, Data("http/1.1".utf8)))),
            (5, Data([1, 0, 0, 0, 0])),
            (13, lengthPrefixed(2, list([0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0805, 0x0501, 0x0806, 0x0601, 0x0201]))),
            (18, Data()),
            (51, lengthPrefixed(2, keyShares)),
            (45, Data([1, 1])),
            (43, lengthPrefixed(1, list([versionGrease, 0x0304, 0x0303]))),
            (27, Data([2, 0, 1])),
            (lastExtensionGrease, Data([0])),
        ]
        var encoded = Data()
        for (type, data) in extensions {
            encoded.appendBigEndian(type)
            encoded.append(lengthPrefixed(2, data))
        }
        body.append(lengthPrefixed(2, encoded))

        var message = Data([1])
        message.append(contentsOf: [UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        return message + body
    }

    /// A random GREASE value, 0x?A?A.
    private static func grease() -> UInt16 {
        let byte = UInt16(UInt8.random(in: 0...15)) << 4 | 0x0A
        return byte << 8 | byte
    }

    private static func list(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values {
            data.appendBigEndian(value)
        }
        return data
    }

    private static func lengthPrefixed(_ size: Int, _ data: Data) -> Data {
        var prefixed = size == 1 ? Data([UInt8(data.count)]) : Data([UInt8(data.count >> 8), UInt8(data.count & 0xFF)])
        prefixed.append(data)
        return prefixed
    }
}

/// Reads big-endian integers and length-prefixed bytes.
struct ByteReader {
    private let data: Data
    private var index: Int

    init(_ data: Data) {
        self.data = Data(data)
        index = 0
    }

    var isAtEnd: Bool { index >= data.count }

    mutating func integer(_ size: Int) throws -> Int {
        guard index + size <= data.count else { throw TLSError.unexpectedMessage }
        defer { index += size }
        return data[index..<index + size].reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard index + count <= data.count else { return nil }
        defer { index += count }
        return data[index..<index + count]
    }
}

/// Just enough DER to find a certificate's key and signature.
enum DER {
    static func children(of data: Data) -> [(tag: UInt8, content: Data)] {
        var children: [(UInt8, Data)] = []
        var index = data.startIndex
        while index + 2 <= data.endIndex {
            let tag = data[index]
            var length = Int(data[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 3, index + count <= data.endIndex else { return [] }
                length = data[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard index + length <= data.endIndex else { return [] }
            children.append((tag, data[index..<index + length]))
            index += length
        }
        return children
    }
}
