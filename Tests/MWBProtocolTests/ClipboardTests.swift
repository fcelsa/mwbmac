import Testing
import Foundation
@testable import MWBProtocol

/// PNG 4×3 RGBA generato con Python (zlib + struct), 98 byte.
let samplePNG: [UInt8] = bytes(fromHex:
    "89504e470d0a1a0a0000000d4948445200000004000000030806000000b4f4aec6"
    + "0000002949444154789c15c8310100300cc330031b9222c93950e1b77a871e01f71d45158ca1a8f3a386a26a0156e91a65cd75fd16"
    + "0000000049454e44ae426082")

func bytes(fromHex hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

struct ClipboardTextTests {
    /// "TXT…SEP RTF…SEP" in UTF-16LE compresso con zlib di Python in modo grezzo (wbits = −15),
    /// cioè come il DeflateStream di .NET.
    static let pythonDeflate = bytes(fromHex:
        "ad8e390ec2500c445f8dc41d3e3d295842d286e51f00a5a0a089d8440148408772230e4549414547c713700464c91e8fc76397cc"
        + "2819b1a5e2409bc0ceba67696ed9ddb8f3e0c94b7c0d4d1a9c58b1f8692ad9a3bb1bd185be3ed148c9cc190943268c8dc4594f7d"
        + "2a2ae472e7095d3505033a1f261745b948cdd49fa28e73ddcfac55046f7e7facff7ae90d")

    @Test func decodesReferenceDeflate() throws {
        let text = try ClipboardText(decoding: Self.pythonDeflate)
        #expect(text.plain == "Ciao, mondo! àèìòù €\r\nseconda riga")
        #expect(text.rtf == #"{\rtf1 ciao}"#)
        #expect(text.html == nil)
    }

    @Test func roundTripWithAllFormats() throws {
        let original = ClipboardText(plain: "riga 1\r\nriga 2 – 日本語 😀", rtf: #"{\rtf1\ansi ciao}"#,
                                     html: CFHTML.wrap("<b>ciao</b>"))
        #expect(try ClipboardText(decoding: original.encoded()) == original)
    }

    /// PowerToys invia il buffer con la sua capacità: dopo il flusso Deflate ci sono zeri.
    @Test func toleratesTrailingPadding() throws {
        let padded = Self.pythonDeflate + [UInt8](repeating: 0, count: 372)
        #expect(try ClipboardText(decoding: padded).plain == "Ciao, mondo! àèìòù €\r\nseconda riga")
    }

    @Test func truncatedStreamKeepsWhatCanBeRecovered() throws {
        let long = String(repeating: "abcdefghij klmnopqrst ", count: 4000)
        let encoded = ClipboardText(plain: long).encoded()
        let truncated = Array(encoded.dropLast(9))
        let recovered = try ClipboardText(decoding: truncated)
        // Si recupera quasi tutto; la coda (compreso il separatore finale) può essere rovinata.
        let plain = recovered.plain ?? ""
        #expect(plain.count > long.count * 9 / 10)
        #expect(plain.hasPrefix(String(long.prefix(long.count * 9 / 10))))
    }

    @Test func rejectsGarbageAndEmpty() {
        #expect(throws: (any Error).self) { try ClipboardText(decoding: [0xFF, 0xFE, 0x12, 0x99, 0x01, 0x02, 0x03]) }
        #expect(throws: (any Error).self) { try ClipboardText(decoding: ClipboardText().encoded()) }
    }

    @Test func unknownPrefixIsTreatedAsPlainText() throws {
        let raw = "solo testo senza prefisso".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(try ClipboardText(decoding: Deflate.compress(raw)).plain == "solo testo senza prefisso")
    }

    @Test func largeTextRoundTrip() throws {
        let long = (0..<60_000).map { "riga numero \($0) àèìòù\r\n" }.joined()
        let encoded = ClipboardText(plain: long).encoded()
        #expect(encoded.count < long.utf16.count) // compresso davvero
        #expect(try ClipboardText(decoding: encoded).plain == long)
    }

    @Test func lineEndings() {
        #expect(ClipboardText.windowsLineEndings("a\nb\r\nc\rd") == "a\r\nb\r\nc\r\nd")
        #expect(ClipboardText.macLineEndings("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }
}

struct CFHTMLTests {
    @Test func wrapProducesValidByteOffsets() {
        let wrapped = CFHTML.wrap("<i>perché</i> €")
        let bytes = Array(wrapped.utf8)
        func offset(_ key: String) -> Int {
            let range = wrapped.range(of: key + ":")!
            return Int(wrapped[range.upperBound...].prefix(10))!
        }
        #expect(wrapped.hasPrefix("Version:0.9\r\nStartHTML:"))
        let fragment = String(decoding: bytes[offset("StartFragment")..<offset("EndFragment")], as: UTF8.self)
        #expect(fragment == "<i>perché</i> €")
        let document = String(decoding: bytes[offset("StartHTML")..<offset("EndHTML")], as: UTF8.self)
        #expect(document.hasPrefix("<html><body><!--StartFragment-->"))
        #expect(document.hasSuffix("<!--EndFragment--></body></html>"))
        #expect(offset("EndHTML") == bytes.count)
    }

    @Test func wrapKeepsExistingDocumentStructure() {
        let wrapped = CFHTML.wrap("<html><head><meta charset=\"utf-8\"></head><body class=\"x\"><p>ciao</p></body></html>")
        #expect(wrapped.contains("<body class=\"x\"><!--StartFragment--><p>ciao</p><!--EndFragment--></body>"))
        #expect(wrapped.components(separatedBy: "<body").count == 2)
    }

    @Test func unwrapRoundTripAndFallbacks() {
        #expect(CFHTML.unwrap(CFHTML.wrap("<b>ciao</b>")) == "<html><body><b>ciao</b></body></html>")
        // Intestazione incoerente: dal primo tag in poi.
        #expect(CFHTML.unwrap("Version:0.9\r\nStartHTML:9999\r\nEndHTML:10\r\n<p>x</p>") == "<p>x</p>")
        #expect(CFHTML.unwrap("<p>già html</p>") == "<p>già html</p>")
    }
}

struct PNGDataTests {
    @Test func validPNGIsReturnedUnchanged() {
        #expect(PNGData.isPNG(samplePNG))
        #expect(PNGData.sanitized(samplePNG) == samplePNG)
    }

    @Test func trailingPaddingIsRemoved() {
        #expect(PNGData.sanitized(samplePNG + [UInt8](repeating: 0, count: 158)) == samplePNG)
    }

    /// PowerToys può perdere fino a 15 byte in coda (blocco AES incompleto mai inviato).
    @Test func truncatedTailIsRepaired() throws {
        for missing in 1...15 {
            let repaired = try #require(PNGData.sanitized(Array(samplePNG.dropLast(missing))), "mancano \(missing) byte")
            #expect(Array(repaired.suffix(12)) == Array(samplePNG.suffix(12)), "IEND ricostruito, mancano \(missing) byte")
            #expect(PNGData.sanitized(repaired) == repaired)
        }
        // Perso solo IEND: il file torna identico all'originale.
        #expect(PNGData.sanitized(Array(samplePNG.dropLast(12))) == samplePNG)
    }

    @Test func truncatedImageDataIsRechunkedWithValidCRC() throws {
        // Taglio in mezzo ai dati IDAT: il blocco viene richiuso con lunghezza e CRC corretti.
        let cut = Array(samplePNG.prefix(60))
        let repaired = try #require(PNGData.sanitized(cut))
        let idatStart = 33
        let length = Int(repaired[idatStart]) << 24 | Int(repaired[idatStart + 1]) << 16
            | Int(repaired[idatStart + 2]) << 8 | Int(repaired[idatStart + 3])
        #expect(length == 60 - idatStart - 8)
        let body = Array(repaired[(idatStart + 4)..<(idatStart + 8 + length)])
        let crcBytes = repaired[(idatStart + 8 + length)..<(idatStart + 12 + length)]
        let crc = crcBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(crc == PNGData.crc32(body))
    }

    @Test func nonPNGAndHopelessDataAreRejected() {
        #expect(PNGData.sanitized([1, 2, 3]) == nil)
        #expect(PNGData.sanitized(Array("GIF89a".utf8) + [UInt8](repeating: 0, count: 40)) == nil)
        #expect(PNGData.sanitized(Array(samplePNG.prefix(20))) == nil) // IHDR incompleto
        #expect(PNGData.sanitized(Array(samplePNG.prefix(33))) == nil) // nessun dato immagine
    }

    @Test func crc32MatchesKnownValue() {
        #expect(PNGData.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(PNGData.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}

struct ClipboardPayloadTests {
    let magic: UInt32 = 0x2f30262c

    @Test func inlinePacketsCarry48BytesAndSurviveTheWire() throws {
        let data = (0..<130).map { UInt8($0) }
        let packets = ClipboardPayload(kind: .image, data: data).inlinePackets()
        #expect(packets.count == 4) // 48 + 48 + 34 (riempito) + fine
        #expect(packets.last?.type == .clipboardDataEnd)

        var reassembled: [UInt8] = []
        for packet in packets.dropLast() {
            let wire = packet.serialized(magic: magic)
            #expect(wire.count == 64)
            #expect(wire[0] == PackageType.clipboardImage.rawValue)
            #expect(Array(wire[12..<16]) == [255, 0, 0, 0]) // destinazione ALL
            let parsed = try Packet(bytes: wire, magic: magic)
            #expect(Array(wire[16..<64]) == parsed.clipboardChunk)
            reassembled += parsed.clipboardChunk
        }
        #expect(Array(reassembled.prefix(130)) == data)
        #expect(reassembled.dropFirst(130).allSatisfy { $0 == 0 })
        #expect(reassembled.count == 144)
    }

    @Test func textPacketsUseTextType() {
        let packets = ClipboardPayload(kind: .text, data: [1, 2, 3]).inlinePackets()
        #expect(packets.map(\.type) == [.clipboardText, .clipboardDataEnd])
    }

    @Test func inlineThreshold() {
        #expect(ClipboardPayload(kind: .image, data: [UInt8](repeating: 1, count: 1024 * 1024)).isInline)
        #expect(!ClipboardPayload(kind: .image, data: [UInt8](repeating: 1, count: 1024 * 1024 + 1)).isInline)
    }

    @Test func transferHeaderRoundTrip() throws {
        let header = ClipboardPayload(kind: .image, data: [UInt8](repeating: 0, count: 3_456_789)).transferHeader()
        #expect(header.count == 1024)
        // "3456789*image" in UTF-16LE, poi zeri.
        #expect(Array(header[0..<4]) == [0x33, 0, 0x34, 0])
        let parsed = try #require(ClipboardPayload.parseTransferHeader(header))
        #expect(parsed.size == 3_456_789)
        #expect(ClipboardPayload.kind(forTransferName: parsed.name) == .image)
    }

    @Test func transferHeaderForFilesIsRecognized() throws {
        let header = ClipboardPayload.transferHeader(size: 42, name: #"C:\Users\x\doc*strano.txt"#)
        let parsed = try #require(ClipboardPayload.parseTransferHeader(header))
        #expect(parsed.size == 42)
        #expect(parsed.name == #"C:\Users\x\doc*strano.txt"#)
        #expect(ClipboardPayload.kind(forTransferName: parsed.name) == nil)
        #expect(ClipboardPayload.kind(forTransferName: "TEXT") == .text)
        #expect(ClipboardPayload.parseTransferHeader([UInt8](repeating: 0, count: 1024)) == nil)
        #expect(ClipboardPayload.parseTransferHeader(ClipboardPayload.transferHeader(size: -1, name: "text")) == nil)
    }

    @Test func machineNameStillWorksOnOrdinaryPackets() throws {
        let packet = Packet(type: .clipboard, des: MachineID.all, machineName: "office-macbook1")
        let parsed = try Packet(bytes: packet.serialized(magic: magic), magic: magic)
        #expect(parsed.machineName == "office-macbook1")
        #expect(parsed == packet)
    }
}
