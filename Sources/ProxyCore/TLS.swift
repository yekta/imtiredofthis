import Foundation

public enum TLS {
    /// The server name a TLS ClientHello asks for, when `data` starts with one.
    public static func serverName(in data: Data) -> String? {
        var reader = Reader(bytes: [UInt8](data.prefix(16 * 1024)))
        guard reader.byte() == 0x16, reader.skip(2), let recordLength = reader.integer(2),
              reader.byte() == 0x01, reader.skip(3) else { return nil }
        reader.limit = min(reader.limit, 5 + recordLength)
        guard reader.skip(2 + 32),
              let sessionID = reader.integer(1), reader.skip(sessionID),
              let cipherSuites = reader.integer(2), reader.skip(cipherSuites),
              let compression = reader.integer(1), reader.skip(compression),
              let extensionsLength = reader.integer(2) else { return nil }
        let extensionsEnd = min(reader.limit, reader.index + extensionsLength)
        while reader.index + 4 <= extensionsEnd {
            guard let type = reader.integer(2), let length = reader.integer(2) else { return nil }
            guard type == 0 else {
                guard reader.skip(length) else { return nil }
                continue
            }
            guard reader.skip(2), reader.byte() == 0, let nameLength = reader.integer(2),
                  let name = reader.bytes(nameLength), let host = String(bytes: name, encoding: .ascii),
                  !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
            else { return nil }
            return host.lowercased()
        }
        return nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var limit: Int

        init(bytes: [UInt8]) {
            self.bytes = bytes
            limit = bytes.count
        }

        mutating func byte() -> UInt8? {
            guard index < limit else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func integer(_ size: Int) -> Int? {
            guard index + size <= limit else { return nil }
            defer { index += size }
            return bytes[index..<index + size].reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func skip(_ count: Int) -> Bool {
            guard index + count <= limit else { return false }
            index += count
            return true
        }

        mutating func bytes(_ count: Int) -> ArraySlice<UInt8>? {
            guard index + count <= limit else { return nil }
            defer { index += count }
            return bytes[index..<index + count]
        }
    }
}
