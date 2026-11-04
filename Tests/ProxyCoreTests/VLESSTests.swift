import Foundation
import Network
import Testing
@testable import ProxyCore

@Suite struct VLESSLinkTests {
    static let link = "vless://92682d6d-92cc-46ca-a40f-8d5d2180fa0b@203.0.113.7:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.samsung.com&fp=chrome&pbk=BLOnn-PVGqcXM1JMABMeht82lEUUR_dr0gsyGtNEEwI&sid=0123abcd&spx=%2F&type=tcp#Hetzner%20Box"

    @Test func reality() throws {
        let server = try VLESSServer(link: Self.link)
        #expect(server.id == UUID(uuidString: "92682d6d-92cc-46ca-a40f-8d5d2180fa0b"))
        #expect(server.host == "203.0.113.7")
        #expect(server.port == 443)
        #expect(server.name == "Hetzner Box")
        #expect(server.serverName == "www.samsung.com")
        #expect(server.publicKey.count == 32)
        #expect(server.shortID == Data([0x01, 0x23, 0xAB, 0xCD]))
        #expect(server.usesVision)
        #expect(!server.allowsUDP443)
    }

    @Test func withoutFlowOrShortID() throws {
        let server = try VLESSServer(link: "vless://92682d6d-92cc-46ca-a40f-8d5d2180fa0b@[2001:db8::1]:8443/?security=reality&sni=example.com&pbk=BLOnn-PVGqcXM1JMABMeht82lEUUR_dr0gsyGtNEEwI")
        #expect(server.host == "2001:db8::1")
        #expect(server.port == 8443)
        #expect(server.shortID.isEmpty)
        #expect(!server.usesVision)
        #expect(server.name == nil)
    }

    @Test func rejected() {
        let link = Self.link
        #expect(throws: VLESSError.notALink) { try VLESSServer(link: "ss://abc@host:1") }
        #expect(throws: VLESSError.notREALITY) { try VLESSServer(link: link.replacingOccurrences(of: "security=reality", with: "security=tls")) }
        #expect(throws: VLESSError.transport("ws")) { try VLESSServer(link: link.replacingOccurrences(of: "type=tcp", with: "type=ws")) }
        #expect(throws: VLESSError.badPublicKey) { try VLESSServer(link: link.replacingOccurrences(of: "pbk=BLOnn", with: "pbk=BL")) }
        #expect(throws: VLESSError.badShortID) { try VLESSServer(link: link.replacingOccurrences(of: "sid=0123abcd", with: "sid=0123456789abcdef01")) }
        #expect(throws: VLESSError.badID) { try VLESSServer(link: link.replacingOccurrences(of: "92682d6d-", with: "")) }
        #expect(throws: VLESSError.noServerName) { try VLESSServer(link: link.replacingOccurrences(of: "sni=www.samsung.com&", with: "")) }
    }

    @Test func requestHeader() throws {
        let server = try VLESSServer(link: Self.link)
        let header = server.requestHeader(.tcp, to: Address(name: "discord.com", port: 443))
        let flow = Data("xtls-rprx-vision".utf8)
        let expected = Data([0]) + server.idBytes + Data([18, 0x0A, 16]) + flow + Data([1, 0x01, 0xBB, 2, 11]) + Data("discord.com".utf8)
        #expect(header == expected)
        let udp = server.requestHeader(.udp, to: Address(name: "1.1.1.1", port: 53))
        #expect(udp == Data([0]) + server.idBytes + Data([0, 2, 0, 53, 1, 1, 1, 1, 1]))
    }
}

@Suite struct VisionTests {
    private let id = Data((0..<16).map { UInt8($0) })

    @Test func padsAndUnpads() {
        var writer = Vision(id: id)
        var reader = Vision(id: id)
        let first = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        let (padded, direct) = writer.pad(first)
        #expect(!direct)
        #expect(padded.prefix(16) == id)
        #expect(reader.unpad(padded).data == first)
    }

    /// With no data yet, the request header still goes out hidden in a long padding.
    @Test func padsLongWithoutData() {
        var writer = Vision(id: id)
        #expect(writer.pad(Data()).bytes.count >= 16 + 5 + 900)
    }

    @Test func unpadsAcrossPieces() {
        var writer = Vision(id: id)
        var reader = Vision(id: id)
        let data = Data((0..<3000).map { UInt8($0 % 256) })
        let padded = writer.pad(data).bytes
        var unpadded = Data()
        var index = padded.startIndex
        while index < padded.endIndex {
            let end = min(index + (index == padded.startIndex ? 30 : 7), padded.endIndex)
            unpadded.append(reader.unpad(padded[index..<end]).data)
            index = end
        }
        #expect(unpadded == data)
    }

    @Test func switchesToRawOnceTLS13CarriesData() {
        var client = Vision(id: id)
        var server = Vision(id: id)
        let hello = fakeServerHello()
        #expect(server.unpad(client.pad(hello).bytes).data == hello)
        let record = Data([0x17, 3, 3, 0, 4, 1, 2, 3, 4])
        let (padded, direct) = client.pad(record)
        #expect(direct)
        let (unpadded, serverDirect) = server.unpad(padded)
        #expect(unpadded == record)
        #expect(serverDirect)
        #expect(client.pad(Data([9, 9])).bytes == Data([9, 9]))
    }

    @Test func reshapesIntoBlocks() {
        let data = Data(repeating: 1, count: 30000)
        let pieces = Vision.reshape(data)
        #expect(pieces.allSatisfy { $0.count <= 8192 - 21 })
        #expect(pieces.reduce(Data(), +) == data)
    }

    @Test func completeRecords() {
        #expect(Vision.isCompleteRecords(Data([0x17, 3, 3, 0, 1, 9, 0x17, 3, 3, 0, 2, 8, 8])))
        #expect(!Vision.isCompleteRecords(Data([0x17, 3, 3, 0, 2, 9])))
        #expect(!Vision.isCompleteRecords(Data([0x16, 3, 3, 0, 1, 9])))
    }
}

/// A TLS 1.3 ServerHello's start, enough for Vision to see TLS 1.3 with TLS_AES_128_GCM_SHA256.
func fakeServerHello() -> Data {
    var body = Data([3, 3]) + Data(repeating: 7, count: 32) + Data([32]) + Data(repeating: 1, count: 32)
    body += Data([0x13, 0x01, 0, 0, 6, 0x00, 0x2B, 0x00, 0x02, 0x03, 0x04])
    let message = Data([2, 0, 0, UInt8(body.count)]) + body
    return Data([0x16, 3, 3, 0, UInt8(message.count)]) + message
}

@Suite struct REALITYHelloTests {
    @Test func clientHelloIsSafarisShape() throws {
        guard #available(macOS 26.0, *) else { return }
        let hello = REALITYHandshake.clientHello(
            serverName: "www.samsung.com", random: Data(repeating: 5, count: 32),
            mlkemShare: Data(count: 1216), x25519Share: Data(count: 32)
        )
        #expect(hello[0] == 1)
        #expect(Int(hello.readBigEndian(UInt32.self, at: 0) & 0xFFFFFF) == hello.count - 4)
        #expect(hello[38] == 32)
        #expect(hello[39..<71] == Data(count: 32))
        #expect(TLS.serverName(in: Data([0x16, 3, 1, UInt8(hello.count >> 8), UInt8(hello.count & 0xFF)]) + hello) == "www.samsung.com")
    }
}
