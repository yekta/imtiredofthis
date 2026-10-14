import CommonCrypto
import CryptoKit
import Foundation

enum CryptoError: Error {
    case authenticationFailed
}

/// One AEAD key, sealing and opening with AES-GCM or ChaCha20-Poly1305.
struct Cipher {
    static let tagSize = 16

    private let key: SymmetricKey
    private let isChaCha: Bool

    init(method: EncryptionMethod, key: Data) {
        self.key = SymmetricKey(data: key)
        isChaCha = method.isChaCha
    }

    /// The session key for a salt: HKDF-SHA1 for the AEAD ciphers, BLAKE3 for 2022's.
    init(server: Server, salt: Data) {
        let subkey: Data
        if server.method.is2022 {
            subkey = BLAKE3.deriveKey(context: "shadowsocks 2022 session subkey", material: server.key + salt, count: server.method.keySize)
        } else {
            let derived = HKDF<Insecure.SHA1>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: server.key), salt: salt,
                info: Data("ss-subkey".utf8), outputByteCount: server.method.keySize
            )
            subkey = derived.withUnsafeBytes { Data($0) }
        }
        self.init(method: server.method, key: subkey)
    }

    func seal(_ plaintext: Data, nonce: Data) -> Data {
        if isChaCha {
            let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce))
            return box.ciphertext + box.tag
        }
        let box = try! AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce))
        return box.ciphertext + box.tag
    }

    func open(_ sealed: Data, nonce: Data) throws -> Data {
        guard sealed.count >= Self.tagSize else { throw CryptoError.authenticationFailed }
        let ciphertext = sealed.prefix(sealed.count - Self.tagSize)
        let tag = sealed.suffix(Self.tagSize)
        do {
            if isChaCha {
                return try ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag), using: key)
            }
            return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag), using: key)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}

/// A stream's 12-byte nonce: a little-endian counter that goes up by one after each use.
struct NonceCounter {
    private var bytes = [UInt8](repeating: 0, count: 12)

    mutating func next() -> Data {
        let nonce = Data(bytes)
        for i in bytes.indices {
            bytes[i] &+= 1
            guard bytes[i] == 0 else { break }
        }
        return nonce
    }
}

/// AES on single 16-byte blocks, which Shadowsocks 2022 encrypts its UDP packets' headers with.
struct BlockCipher {
    private let key: Data

    init(key: Data) {
        self.key = key
    }

    func encrypt(_ block: Data) -> Data {
        crypt(block, CCOperation(kCCEncrypt))
    }

    func decrypt(_ block: Data) -> Data {
        crypt(block, CCOperation(kCCDecrypt))
    }

    private func crypt(_ block: Data, _ operation: CCOperation) -> Data {
        var output = Data(count: 16)
        var moved = 0
        let input = Data(block.prefix(16))
        output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    _ = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                keyBytes.baseAddress, key.count, nil,
                                inBytes.baseAddress, 16, out.baseAddress, 16, &moved)
                }
            }
        }
        return output
    }
}

func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value = value << 8 | T(self[startIndex + offset + i])
        }
        return value
    }
}
