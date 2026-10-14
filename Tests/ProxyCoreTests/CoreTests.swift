import Foundation
import Network
import Testing
@testable import ProxyCore

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// The official test vectors' input: 0, 1, …, 250, 0, 1, …
private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}

@Suite struct BLAKE3Tests {
    @Test(arguments: [
        (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
        (1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
        (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"),
        (65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"),
        (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
        (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
        (2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"),
        (5000, "ee78d92070de3df1c57c37002abf0a6b1a6589acdeef4d8ffac7cf3d9e8f2836"),
    ])
    func hash(length: Int, expected: String) {
        #expect(hex(BLAKE3.hash(pattern(length))) == expected)
    }

    @Test func longerOutput() {
        #expect(hex(BLAKE3.hash(pattern(64), count: 100)) == "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98fc9cc56cb831ffe33ea8e7e1d1df09b26efd2767670066aa82d023b1dfe8ab1b2b7fbb5b97592d46ffe3e05a6a9b592e2949c74160e4674301bc3f97e04903f8c6cf95b8")
    }

    @Test func deriveKey() {
        let context = "shadowsocks 2022 session subkey"
        #expect(hex(BLAKE3.deriveKey(context: context, material: pattern(64), count: 32)) == "374fca03e4dae7f998fd7e59c1edfcc8e3197f4db1c19ca1671be3b66a92ddda")
        #expect(hex(BLAKE3.deriveKey(context: context, material: pattern(64), count: 16)) == "374fca03e4dae7f998fd7e59c1edfcc8")
    }
}

@Suite struct ServerLinkTests {
    @Test func sip002() throws {
        let userInfo = Data("aes-256-gcm:hunter2".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let server = try Server(link: "ss://\(userInfo)@1.2.3.4:8388/?#My%20Server")
        #expect(server.method == .aes256GCM)
        #expect(server.host == "1.2.3.4")
        #expect(server.port == 8388)
        #expect(server.name == "My Server")
        #expect(server.key == Server.bytesToKey(Data("hunter2".utf8), count: 32))
    }

    @Test func shadowsocks2022() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let password = key.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let server = try Server(link: "ss://2022-blake3-aes-256-gcm:\(password)@[2001:db8::1]:443")
        #expect(server.method == .blake3AES256GCM)
        #expect(server.host == "2001:db8::1")
        #expect(server.key == key)
        #expect(server.name == nil)
    }

    @Test func legacy() throws {
        let encoded = Data("chacha20-ietf-poly1305:pass@example.com:8000".utf8).base64EncodedString()
        let server = try Server(link: "ss://\(encoded)#home")
        #expect(server.method == .chacha20Poly1305)
        #expect(server.host == "example.com")
        #expect(server.port == 8000)
        #expect(server.name == "home")
    }

    @Test func rejected() {
        let userInfo = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        #expect(throws: ServerError.plugin) { try Server(link: "ss://\(userInfo)@host:1?plugin=obfs-local%3Bobfs%3Dhttp") }
        #expect(throws: ServerError.unknownMethod("rc4-md5")) {
            try Server(link: "ss://\(Data("rc4-md5:pw".utf8).base64EncodedString())@host:1")
        }
        #expect(throws: ServerError.badKey(.blake3AES128GCM)) {
            try Server(link: "ss://2022-blake3-aes-128-gcm:\(Data(count: 32).base64EncodedString())@host:1")
        }
        #expect(throws: ServerError.notALink) { try Server(link: "https://example.com") }
        #expect(throws: ServerError.badAddress) { try Server(link: "ss://\(userInfo)@host") }
    }
}

@Suite struct AddressTests {
    @Test(arguments: [
        Address(name: "93.184.216.34", port: 443),
        Address(name: "2606:2800:220:1::1", port: 80),
        Address(name: "discord.com", port: 443),
    ])
    func socksRoundTrip(address: Address) {
        let data = Data([9]) + address.socks + Data([7])
        var index = 1
        #expect(Address.read(from: data, at: &index) == address)
        #expect(data[index] == 7)
    }

    @Test func truncated() {
        var index = 0
        #expect(Address.read(from: Address(name: "discord.com", port: 443).socks.dropLast(), at: &index) == nil)
    }

    @Test(arguments: ["127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.1", "169.254.3.4", "100.100.1.1", "224.0.0.251", "::1", "fe80::1", "fd00::1", "::ffff:192.168.0.1", "printer.local", "localhost"])
    func local(name: String) {
        #expect(Address(name: name, port: 80).isLocal)
    }

    @Test(arguments: ["162.159.128.233", "172.32.0.1", "100.128.0.1", "2606:4700::1", "discord.com"])
    func remote(name: String) {
        #expect(!Address(name: name, port: 80).isLocal)
    }
}

@Suite struct TLSTests {
    private func clientHello(serverName: String?) -> Data {
        func u16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        var extensions = Data([0x00, 0x2B, 0x00, 0x03, 0x02, 0x03, 0x04])
        if let serverName {
            let name = Data(serverName.utf8)
            var list = u16(name.count + 3)
            list.append(0)
            list.append(u16(name.count))
            list.append(name)
            extensions.append(u16(0))
            extensions.append(u16(list.count))
            extensions.append(list)
        }
        var body = Data([0x03, 0x03])
        body.append(Data(repeating: 7, count: 32))
        body.append(Data([0, 0, 2, 0x13, 0x01, 1, 0]))
        body.append(u16(extensions.count))
        body.append(extensions)
        var record = Data([0x16, 0x03, 0x01])
        record.append(u16(body.count + 4))
        record.append(Data([0x01, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]))
        record.append(body)
        return record
    }

    @Test func serverName() {
        #expect(TLS.serverName(in: clientHello(serverName: "Gateway.Discord.gg") + Data("more".utf8)) == "gateway.discord.gg")
    }

    @Test func noServerName() {
        #expect(TLS.serverName(in: clientHello(serverName: nil)) == nil)
        #expect(TLS.serverName(in: Data("GET / HTTP/1.1\r\n".utf8)) == nil)
        #expect(TLS.serverName(in: clientHello(serverName: "discord.com").prefix(40)) == nil)
    }
}

@Suite struct ProxyConfigTests {
    @Test func routesAppsAndTheirHelpers() {
        let config = ProxyConfig(apps: ["com.hnc.Discord"])
        #expect(config.routes("com.hnc.Discord"))
        #expect(config.routes("com.hnc.Discord.helper.Renderer"))
        #expect(!config.routes("com.hnc.DiscordPTB"))
        #expect(!config.routes("com.apple.Safari"))
    }

    @Test func decodesPartialFiles() throws {
        let config = try JSONDecoder().decode(ProxyConfig.self, from: Data(#"{"apps": ["com.hnc.Discord"]}"#.utf8))
        #expect(config == ProxyConfig(server: "", apps: ["com.hnc.Discord"]))
    }
}

@Suite struct StreamTests {
    @Test func rejectsTamperedReplies() throws {
        let server = try Server(method: .aes256GCM, password: "pw", host: "host", port: 1)
        var decoder = ResponseDecoder(server: server, requestSalt: Data())
        // A reply from a server with another password: a salt, then a chunk it can't open.
        let other = try Server(method: .aes256GCM, password: "other", host: "host", port: 1)
        var encoder = RequestEncoder(server: other, target: Address(name: "1.1.1.1", port: 53))
        #expect(throws: StreamError.self) { try decoder.decode(encoder.encode(Data("hello".utf8))) }
    }

    @Test func waitsForWholeChunks() throws {
        let server = try Server(method: .chacha20Poly1305, password: "pw", host: "host", port: 1)
        var decoder = ResponseDecoder(server: server, requestSalt: Data())
        #expect(try decoder.decode(Data(count: 10)).isEmpty)
    }
}
