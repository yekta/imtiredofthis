import Foundation

/// Encrypts and decrypts one UDP flow's packets. With the AEAD ciphers every packet stands alone,
/// under a salt of its own; with 2022's, the flow is a session whose packets are numbered.
public struct PacketCodec {
    private let server: Server
    private let sessionID: UInt64
    private var packetID: UInt64 = 0
    private let blockCipher: BlockCipher?
    private let sessionCipher: Cipher?
    private var serverCiphers: [UInt64: Cipher] = [:]

    public init(server: Server) {
        self.server = server
        sessionID = UInt64.random(in: 1...UInt64.max)
        guard server.method.is2022 else {
            blockCipher = nil
            sessionCipher = nil
            return
        }
        blockCipher = BlockCipher(key: server.key)
        var id = Data()
        id.appendBigEndian(sessionID)
        sessionCipher = Cipher(server: server, salt: id)
    }

    public mutating func encode(_ payload: Data, to target: Address) -> Data {
        guard let blockCipher, let sessionCipher else {
            let salt = randomBytes(server.method.keySize)
            let cipher = Cipher(server: server, salt: salt)
            return salt + cipher.seal(target.socks + payload, nonce: Data(count: 12))
        }
        var header = Data()
        header.appendBigEndian(sessionID)
        header.appendBigEndian(packetID)
        packetID += 1

        var body = Data([0])
        body.appendBigEndian(UInt64(Date().timeIntervalSince1970))
        body.appendBigEndian(UInt16(0))
        body.append(target.socks)
        body.append(payload)
        return blockCipher.encrypt(header) + sessionCipher.seal(body, nonce: header.suffix(12))
    }

    /// A packet from the server: what it carries, and who sent it.
    public mutating func decode(_ packet: Data) throws -> (payload: Data, source: Address) {
        let body: Data
        if let blockCipher {
            guard packet.count >= 16 + Cipher.tagSize else { throw StreamError.badResponse }
            let header = blockCipher.decrypt(packet.prefix(16))
            let serverSession = header.readBigEndian(UInt64.self, at: 0)
            let cipher = serverCipher(serverSession)
            do {
                body = try cipher.open(packet.dropFirst(16), nonce: header.suffix(12))
            } catch {
                throw StreamError.decryptionFailed
            }
            guard body.count >= 1 + 8 + 8 + 2, body[body.startIndex] == 1,
                  abs(Double(body.readBigEndian(UInt64.self, at: 1)) - Date().timeIntervalSince1970) <= 30,
                  body.readBigEndian(UInt64.self, at: 9) == sessionID else { throw StreamError.badResponse }
            let padding = Int(body.readBigEndian(UInt16.self, at: 17))
            var index = body.startIndex + 19 + padding
            guard let source = Address.read(from: body, at: &index) else { throw StreamError.badResponse }
            return (body[index...], source)
        }

        let keySize = server.method.keySize
        guard packet.count >= keySize + Cipher.tagSize else { throw StreamError.badResponse }
        let cipher = Cipher(server: server, salt: packet.prefix(keySize))
        do {
            body = try cipher.open(packet.dropFirst(keySize), nonce: Data(count: 12))
        } catch {
            throw StreamError.decryptionFailed
        }
        var index = body.startIndex
        guard let source = Address.read(from: body, at: &index) else { throw StreamError.badResponse }
        return (body[index...], source)
    }

    /// The server's sessions' keys; a server keeps one session per client session, but may
    /// start a new one.
    private mutating func serverCipher(_ session: UInt64) -> Cipher {
        if let cipher = serverCiphers[session] {
            return cipher
        }
        var id = Data()
        id.appendBigEndian(session)
        let cipher = Cipher(server: server, salt: id)
        if serverCiphers.count > 8 {
            serverCiphers.removeAll()
        }
        serverCiphers[session] = cipher
        return cipher
    }
}
