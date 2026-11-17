import Testing
import Foundation
@testable import MWBProtocol

// I valori attesi di PBKDF2, AES e magic sono stati calcolati con implementazioni
// indipendenti (hashlib di Python e OpenSSL) sulla chiave di `EncryptionTests.cs`
// di PowerToys, riproducendo gli algoritmi di `Core/Encryption.cs`.
struct CryptoTests {
    /// Stessa chiave di `EncryptionTests.TestKey`.
    static let testKey = "MwbEncryptionTestKey1234"
    static let salt = [UInt8](0..<16)
    static let iv = [UInt8](16..<32)

    @Test func testPBKDF2MatchesReferenceVector() throws {
        let key = try KeyDerivation.deriveKey(securityKey: Self.testKey, salt: Self.salt)
        #expect(hex(key) == "9ec1e292f2a92a2d2dd62b1a74420dc6f9927ca44acea96359cd9010e8cbbf95")
    }

    @Test func testPBKDF2MatchesPublishedSHA512Vector() throws {
        // Vettore noto PBKDF2-HMAC-SHA512 "password"/"salt", 1 iterazione.
        let key = try KeyDerivation.deriveKey(securityKey: "password", salt: Array("salt".utf8), iterations: 1)
        #expect(hex(key) == "867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252")
    }

    @Test func testMagicNumber() {
        #expect(KeyDerivation.magicNumber(securityKey: Self.testKey) == 0x2f30262c)
        #expect(KeyDerivation.magicNumber(securityKey: "abcdEFGH1234~!@#") == 0x1ce25fa5)
        #expect(KeyDerivation.magicNumber(securityKey: "") == 0)
    }

    @Test func testKeyNormalizationDiscardsWhitespace() {
        #expect(KeyDerivation.normalize(securityKey: "1234 5678\t9012\r\n3456") == "1234567890123456")
    }

    @Test func testAESCBCMatchesOpenSSL() throws {
        let key = try KeyDerivation.deriveKey(securityKey: Self.testKey, salt: Self.salt)
        let plain = [UInt8](1...48)
        let stream = try CipherStream(key: key, iv: Self.iv, direction: .encrypt)
        let cipher = try stream.process(plain)
        #expect(hex(cipher) == "41c50037ac05adb83dd478467f9bca52f544f509a6b9430b3194cc157adc6de7"
            + "67df5fb434a86b50d2f9618c494d6dfa")
    }

    /// Equivalente di `EncryptThenDecryptShouldRoundTripPlainText`, ma a pezzi:
    /// la concatenazione CBC deve proseguire fra scritture successive.
    @Test func testStreamingRoundTripAcrossChunks() throws {
        let key = try KeyDerivation.deriveKey(securityKey: Self.testKey, salt: Self.salt, iterations: 10)
        let plain = [UInt8](1...48) + [UInt8](repeating: 7, count: 64)
        let encryptor = try CipherStream(key: key, iv: Self.iv, direction: .encrypt)
        let whole = try CipherStream(key: key, iv: Self.iv, direction: .encrypt).process(plain)
        var chunked: [UInt8] = []
        chunked += try encryptor.process(Array(plain[0..<16]))
        chunked += try encryptor.process(Array(plain[16..<48]))
        chunked += try encryptor.process(Array(plain[48...]))
        #expect(chunked == whole)

        // In ricezione i frammenti TCP non rispettano i confini di blocco.
        let decryptor = try CipherStream(key: key, iv: Self.iv, direction: .decrypt)
        var decrypted: [UInt8] = []
        decrypted += try decryptor.process(Array(whole[0..<5]))
        decrypted += try decryptor.process(Array(whole[5..<37]))
        decrypted += try decryptor.process(Array(whole[37...]))
        #expect(decrypted == plain)
    }

    /// Schema storico: salt fisso "18446744073709551615" in UTF-16LE, 50000 iterazioni.
    @Test func testLegacyKeyAndIV() throws {
        let key = try KeyDerivation.legacyKey(securityKey: Self.testKey)
        #expect(hex(key) == "49d5cef88a62dabd3076c13d3b483cf4f6893b2cbf089beefda7542671d70b0d")
        #expect(String(decoding: KeyDerivation.legacyIV, as: UTF8.self) == "1844674407370955")
    }

    @Test func testDifferentSaltGivesDifferentKey() throws {
        let a = try KeyDerivation.deriveKey(securityKey: Self.testKey, salt: Self.salt, iterations: 10)
        let b = try KeyDerivation.deriveKey(securityKey: Self.testKey, salt: Self.iv, iterations: 10)
        #expect(a != b)
    }
}

struct PacketTests {
    let magic: UInt32 = 0x2f30262c

    @Test func testMousePacketLayout() throws {
        var packet = Packet(type: .mouse, des: 0x11223344)
        packet.id = 0x01020304
        packet.src = 0xAABBCCDD
        packet.mouse = MouseData(x: RelativeMouse.encode(5), y: RelativeMouse.encode(-3),
                                 wheelDelta: 0, flags: WM.mouseMove)
        let bytes = packet.serialized(magic: magic)

        #expect(bytes.count == 32)
        #expect(bytes[0] == 123)
        #expect(bytes[2] == 0x30) // (magic >> 16) & 0xFF
        #expect(bytes[3] == 0x2f) // (magic >> 24) & 0xFF
        #expect(Array(bytes[4..<8]) == [0x04, 0x03, 0x02, 0x01])
        #expect(Array(bytes[8..<12]) == [0xDD, 0xCC, 0xBB, 0xAA])
        #expect(Array(bytes[12..<16]) == [0x44, 0x33, 0x22, 0x11])
        #expect(Array(bytes[16..<20]) == [0xA5, 0x86, 0x01, 0x00]) // 100005
        #expect(Array(bytes[20..<24]) == [0x5D, 0x79, 0xFE, 0xFF]) // -100003
        #expect(Array(bytes[28..<32]) == [0x00, 0x02, 0x00, 0x00])
        #expect(bytes[1] == bytes[2..<32].reduce(UInt8(0)) { $0 &+ $1 })

        #expect(try Packet(bytes: bytes, magic: magic) == packet)
    }

    @Test func testKeyboardPacketLayout() throws {
        var packet = Packet(type: .keyboard, des: 7)
        packet.keyboard = KeyboardData(dateTime: 0x0102030405060708, vk: 0x41, flags: LLKHF.up | LLKHF.extended)
        let bytes = packet.serialized(magic: magic)
        #expect(bytes.count == 32)
        #expect(Array(bytes[16..<24]) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(Array(bytes[24..<28]) == [0x41, 0, 0, 0])
        #expect(Array(bytes[28..<32]) == [0x81, 0, 0, 0])
        #expect(try Packet(bytes: bytes, magic: magic).keyboard == packet.keyboard)
    }

    @Test func testBigPacketCarriesPaddedName() throws {
        var packet = Packet(type: .heartbeat, des: MachineID.all, machineName: "macmini")
        packet.src = 42
        let bytes = packet.serialized(magic: magic)
        #expect(bytes.count == 64)
        #expect(String(decoding: bytes[32..<64], as: UTF8.self) == "macmini" + String(repeating: " ", count: 25))
        // Il checksum copre solo i byte 2..31: il nome ne resta fuori.
        #expect(bytes[1] == bytes[2..<32].reduce(UInt8(0)) { $0 &+ $1 })
        #expect(try Packet(bytes: bytes, magic: magic).machineName == "macmini")
    }

    @Test func testBigPackageTypesMatchPowerToys() {
        let big: Set<PackageType> = [.hello, .awake, .heartbeat, .heartbeatEx, .handshake, .handshakeAck,
                                     .clipboardPush, .clipboard, .clipboardAsk, .clipboardImage,
                                     .clipboardText, .clipboardDataEnd, .matrix, .invalid, .error]
        for type in PackageType.allCases {
            #expect(PackageType.isBig(rawType: type.rawValue) == big.contains(type), "\(type)")
        }
        // Matrix con i flag di scambio e di doppia riga.
        #expect(PackageType.isBig(rawType: 128 | 2 | 4))
        #expect(Packet(rawType: 128 | 2).type == .matrix)
    }

    @Test func testRejectsWrongMagicAndChecksum() {
        let bytes = Packet(type: .mouse, des: 1).serialized(magic: magic)
        #expect(throws: PacketError.badMagic) { try Packet(bytes: bytes, magic: 0x11110000) }
        var corrupted = bytes
        corrupted[20] ^= 0x01
        #expect(throws: PacketError.badChecksum) { try Packet(bytes: corrupted, magic: self.magic) }
        #expect(Packet.expectedSize(header: bytes, magic: magic) == 32)
        #expect(Packet.expectedSize(header: corrupted, magic: magic) == 64)
    }

    @Test func testOnlyHighMagicBitsMatter() throws {
        let bytes = Packet(type: .hideMouse, des: 1).serialized(magic: magic)
        #expect(throws: Never.self) { try Packet(bytes: bytes, magic: (magic & 0xFFFF0000) | 0x1234) }
    }

    @Test func relativeMouseClampsHugeDeltas() {
        // Senza limite, Int32.max + 100000 farebbe terminare il programma.
        #expect(RelativeMouse.encode(Int32.max) == 199_999)
        #expect(RelativeMouse.encode(Int32.min) == -199_999)
        #expect(RelativeMouse.decode(RelativeMouse.encode(250_000)) == 99_999)
    }

    @Test func protocolLogHidesKeystrokes() {
        var letter = Packet(type: .keyboard, des: 1)
        letter.keyboard = KeyboardData(vk: 0x41, flags: 0)
        #expect(letter.description.contains("vk=•"))
        #expect(!letter.description.contains("0x41"))
        var shift = Packet(type: .keyboard, des: 1)
        shift.keyboard = KeyboardData(vk: 0xA0, flags: 0x80)
        #expect(shift.description.contains("vk=0xa0"))
    }

    @Test func testRelativeMouseMarker() {
        #expect(RelativeMouse.encode(0) == 100_000)
        #expect(RelativeMouse.encode(-1) == -100_001)
        for delta: Int32 in [-500, -1, 0, 1, 37] {
            #expect(RelativeMouse.decode(RelativeMouse.encode(delta)) == delta)
            #expect(RelativeMouse.isRelative(x: RelativeMouse.encode(delta), y: RelativeMouse.encode(0)))
        }
        #expect(!(RelativeMouse.isRelative(x: 65535, y: 65535)))
    }
}

struct HandshakeTests {
    @Test func testAckIsBitwiseComplement() {
        let challenge = Handshake.challenge(localName: "pc", localID: 99, random: [UInt8](0..<16))
        let ack = Handshake.ack(for: challenge, localName: "mac", localID: 1234)
        #expect(ack.type == .handshakeAck)
        #expect(ack.src == 1234)
        #expect(ack.machineName == "mac")
        #expect(ack.machines == challenge.machines.map { ~$0 })
        #expect(Handshake.isValid(ack: ack, for: challenge))
    }

    @Test func testWrongAckIsRejected() {
        let challenge = Handshake.challenge(localName: "pc", localID: 99)
        var ack = Handshake.ack(for: challenge, localName: "mac", localID: 1)
        ack.payload[3] ^= 0xFF
        #expect(!(Handshake.isValid(ack: ack, for: challenge)))
        #expect(!(Handshake.isValid(ack: challenge, for: challenge)))
    }

    @Test func testAckSurvivesTheWire() throws {
        let magic = KeyDerivation.magicNumber(securityKey: CryptoTests.testKey)
        let challenge = Handshake.challenge(localName: "winpc", localID: 5)
        let received = try Packet(bytes: challenge.serialized(magic: magic), magic: magic)
        let ack = Handshake.ack(for: received, localName: "office-macbook1", localID: 77)
        let ackReceived = try Packet(bytes: ack.serialized(magic: magic), magic: magic)
        #expect(Handshake.isValid(ack: ackReceived, for: challenge))
        #expect(ackReceived.machineName == "office-macbook1")
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
