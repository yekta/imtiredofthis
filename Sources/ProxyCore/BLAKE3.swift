import Foundation

/// BLAKE3, for Shadowsocks 2022's session keys. Follows the reference implementation; inputs here
/// are tiny, so it is written to be clear, not fast.
public struct BLAKE3 {
    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private static let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
    private static let blockLength = 64
    private static let chunkLength = 1024

    private struct Flags {
        static let chunkStart: UInt32 = 1 << 0
        static let chunkEnd: UInt32 = 1 << 1
        static let parent: UInt32 = 1 << 2
        static let root: UInt32 = 1 << 3
        static let deriveKeyContext: UInt32 = 1 << 5
        static let deriveKeyMaterial: UInt32 = 1 << 6
    }

    private let key: [UInt32]
    private let flags: UInt32
    private var chunk: ChunkState
    private var stack: [[UInt32]] = []

    public init() {
        self.init(key: Self.iv, flags: 0)
    }

    private init(key: [UInt32], flags: UInt32) {
        self.key = key
        self.flags = flags
        chunk = ChunkState(key: key, counter: 0, flags: flags)
    }

    /// `derive_key`: a key for `context` from `material`.
    public static func deriveKey(context: String, material: Data, count: Int) -> Data {
        var contextHasher = BLAKE3(key: iv, flags: Flags.deriveKeyContext)
        contextHasher.update(Data(context.utf8))
        let contextKey = words(contextHasher.finalize(count: 32))
        var hasher = BLAKE3(key: contextKey, flags: Flags.deriveKeyMaterial)
        hasher.update(material)
        return hasher.finalize(count: count)
    }

    public static func hash(_ data: Data, count: Int = 32) -> Data {
        var hasher = BLAKE3()
        hasher.update(data)
        return hasher.finalize(count: count)
    }

    public mutating func update(_ data: Data) {
        var input = data[...]
        while !input.isEmpty {
            if chunk.length == Self.chunkLength {
                let chunkValue = chunk.output().chainingValue()
                let total = chunk.counter + 1
                addChunk(chunkValue, total: total)
                chunk = ChunkState(key: key, counter: total, flags: flags)
            }
            let take = min(Self.chunkLength - chunk.length, input.count)
            chunk.update(input.prefix(take))
            input = input.dropFirst(take)
        }
    }

    public func finalize(count: Int) -> Data {
        var output = chunk.output()
        for left in stack.reversed() {
            output = parentOutput(left: left, right: output.chainingValue())
        }
        return output.rootBytes(count: count)
    }

    private mutating func addChunk(_ value: [UInt32], total: UInt64) {
        var value = value
        var total = total
        while total & 1 == 0 {
            value = parentOutput(left: stack.removeLast(), right: value).chainingValue()
            total >>= 1
        }
        stack.append(value)
    }

    private func parentOutput(left: [UInt32], right: [UInt32]) -> Output {
        Output(input: key, block: left + right, counter: 0, blockLength: UInt32(Self.blockLength), flags: Flags.parent | flags)
    }

    private struct ChunkState {
        var chainingValue: [UInt32]
        let counter: UInt64
        var block = [UInt8]()
        var blocksCompressed = 0
        let flags: UInt32

        init(key: [UInt32], counter: UInt64, flags: UInt32) {
            chainingValue = key
            self.counter = counter
            self.flags = flags
        }

        var length: Int { blocksCompressed * BLAKE3.blockLength + block.count }

        private var startFlag: UInt32 { blocksCompressed == 0 ? Flags.chunkStart : 0 }

        mutating func update(_ data: Data.SubSequence) {
            var input = data
            while !input.isEmpty {
                if block.count == BLAKE3.blockLength {
                    let words = BLAKE3.words(Data(block))
                    chainingValue = Array(BLAKE3.compress(chainingValue, words, counter, UInt32(BLAKE3.blockLength), flags | startFlag).prefix(8))
                    blocksCompressed += 1
                    block.removeAll(keepingCapacity: true)
                }
                let take = min(BLAKE3.blockLength - block.count, input.count)
                block.append(contentsOf: input.prefix(take))
                input = input.dropFirst(take)
            }
        }

        func output() -> Output {
            let padded = block + [UInt8](repeating: 0, count: BLAKE3.blockLength - block.count)
            return Output(input: chainingValue, block: BLAKE3.words(Data(padded)), counter: counter,
                          blockLength: UInt32(block.count), flags: flags | startFlag | Flags.chunkEnd)
        }
    }

    private struct Output {
        let input: [UInt32]
        let block: [UInt32]
        let counter: UInt64
        let blockLength: UInt32
        let flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(BLAKE3.compress(input, block, counter, blockLength, flags).prefix(8))
        }

        func rootBytes(count: Int) -> Data {
            var bytes = Data(capacity: count)
            var counter: UInt64 = 0
            while bytes.count < count {
                for word in BLAKE3.compress(input, block, counter, blockLength, flags | Flags.root) {
                    withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
                }
                counter += 1
            }
            return bytes.prefix(count)
        }
    }

    private static func compress(_ chainingValue: [UInt32], _ block: [UInt32], _ counter: UInt64, _ blockLength: UInt32, _ flags: UInt32) -> [UInt32] {
        var state = chainingValue
        state.append(contentsOf: iv.prefix(4))
        state.append(contentsOf: [UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), blockLength, flags])
        var message = block
        for round in 0..<7 {
            mix(&state, 0, 4, 8, 12, message[0], message[1])
            mix(&state, 1, 5, 9, 13, message[2], message[3])
            mix(&state, 2, 6, 10, 14, message[4], message[5])
            mix(&state, 3, 7, 11, 15, message[6], message[7])
            mix(&state, 0, 5, 10, 15, message[8], message[9])
            mix(&state, 1, 6, 11, 12, message[10], message[11])
            mix(&state, 2, 7, 8, 13, message[12], message[13])
            mix(&state, 3, 4, 9, 14, message[14], message[15])
            guard round < 6 else { break }
            message = permutation.map { message[$0] }
        }
        for i in 0..<8 {
            state[i] ^= state[i + 8]
            state[i + 8] ^= chainingValue[i]
        }
        return state
    }

    private static func mix(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        s[a] = s[a] &+ s[b] &+ x
        s[d] = rotate(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]
        s[b] = rotate(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b] &+ y
        s[d] = rotate(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]
        s[b] = rotate(s[b] ^ s[c], 7)
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func words(_ data: Data) -> [UInt32] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map { (i: Int) -> UInt32 in
            var word: UInt32 = 0
            for j in (0..<4).reversed() {
                word = word << 8 | UInt32(bytes[i + j])
            }
            return word
        }
    }
}
