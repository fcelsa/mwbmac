// Formati degli appunti di Mouse Without Borders.
// Fonte: PowerToys `Core/Clipboard.cs`, `Helper/FormHelper.cs`, `Class/SocketStuff.cs`
// (`SendClipboardData`).
//
// Testo: stringa "TXT<testo>SEP[RTF<rtf>SEP][HTM<html>SEP]" in UTF-16LE, compressa con
// Deflate grezzo (RFC 1951, il `DeflateStream` di .NET). Immagine: un file PNG.
//
// Trasporto, due vie:
//   - in linea (fino a 1 MB): sul canale messaggi, pacchetti da 64 byte `ClipboardText` /
//     `ClipboardImage` con 48 byte di dati agli offset 16..63 e destinazione ALL, chiusi
//     da `ClipboardDataEnd`; l'ultimo blocco è riempito di zeri;
//   - canale appunti (porta base): un pacchetto `Clipboard` annuncia che ci sono dati
//     grandi; chi li vuole apre una connessione, scambia un pacchetto di saluto e riceve
//     un'intestazione di 1024 byte ("<dimensione>*<text|image>" in UTF-16LE) seguita dai dati.
//
// PowerToys invia i buffer con la loro capacità, non la lunghezza utile: in coda ai dati
// possono esserci zeri. Tutta la decodifica qui tollera code di riempimento e troncamenti.

import Compression
import Foundation

public enum ClipboardKind: String, Sendable {
    case text
    case image
}

public enum ClipboardError: Error, Equatable {
    case invalidData
    case tooBig
}

/// Contenuto degli appunti nella forma che viaggia sul filo.
public struct ClipboardPayload: Equatable, Sendable {
    public var kind: ClipboardKind
    /// Testo compresso oppure PNG.
    public var data: [UInt8]

    /// Sopra questa soglia PowerToys non invia in linea ma annuncia e aspetta la richiesta.
    public static let inlineLimit = 1024 * 1024
    /// Limite di PowerToys per i dati trasferiti (100 MB).
    public static let maxSize = 100 * 1024 * 1024
    public static let transferHeaderSize = 1024

    public init(kind: ClipboardKind, data: [UInt8]) {
        self.kind = kind
        self.data = data
    }

    public var isInline: Bool { data.count <= ClipboardPayload.inlineLimit }

    /// Pacchetti per l'invio in linea (`Clipboard.SendClipboardDataUsingTCP`).
    public func inlinePackets() -> [Packet] {
        let type: PackageType = kind == .image ? .clipboardImage : .clipboardText
        let size = Packet.clipboardChunkSize
        var packets: [Packet] = []
        packets.reserveCapacity(data.count / size + 2)
        var index = 0
        while index < data.count {
            var chunk = Array(data[index..<min(index + size, data.count)])
            chunk.append(contentsOf: [UInt8](repeating: 0, count: size - chunk.count))
            var packet = Packet(type: type, des: MachineID.all)
            packet.clipboardChunk = chunk
            packets.append(packet)
            index += size
        }
        packets.append(Packet(type: .clipboardDataEnd, des: MachineID.all))
        return packets
    }

    // MARK: Canale appunti

    /// Intestazione di 1024 byte che precede i dati sul canale appunti.
    public func transferHeader() -> [UInt8] {
        ClipboardPayload.transferHeader(size: data.count, name: kind.rawValue)
    }

    static func transferHeader(size: Int, name: String) -> [UInt8] {
        var bytes = "\(size)*\(name)".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        bytes = Array(bytes.prefix(transferHeaderSize))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: transferHeaderSize - bytes.count))
        return bytes
    }

    /// Interpreta l'intestazione: dimensione dichiarata e nome ("text", "image" oppure il
    /// percorso di un file, che questo client non accetta).
    public static func parseTransferHeader(_ header: [UInt8]) -> (size: Int, name: String)? {
        let text = String(utf16LE: header).replacingOccurrences(of: "\0", with: "")
        let parts = text.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let size = Int(parts[0]), size >= 0 else { return nil }
        return (size, String(parts[1]))
    }

    /// Tipo di contenuto dal nome dell'intestazione; `nil` per i file.
    public static func kind(forTransferName name: String) -> ClipboardKind? {
        let lower = name.lowercased()
        if lower.hasPrefix("image") { return .image }
        if lower.hasPrefix("text") { return .text }
        return nil
    }
}

// MARK: - Testo

/// Testo degli appunti nei tre formati che Mouse Without Borders trasporta.
public struct ClipboardText: Equatable, Sendable {
    /// Separatore fra i formati (`TEXT_TYPE_SEP`).
    public static let separator = "{4CFF57F7-BEDD-43d5-AE8F-27A61E886F2F}"

    public var plain: String?
    public var rtf: String?
    /// HTML nel formato degli appunti di Windows (CF_HTML, con intestazione): vedi `CFHTML`.
    public var html: String?

    public init(plain: String? = nil, rtf: String? = nil, html: String? = nil) {
        self.plain = plain
        self.rtf = rtf
        self.html = html
    }

    public var isEmpty: Bool {
        (plain ?? "").isEmpty && (rtf ?? "").isEmpty && (html ?? "").isEmpty
    }

    /// Forma da inviare: come `FormHelper.GetClipboardText` + `CheckClipboardEx`.
    public func encoded() -> [UInt8] {
        var text = ""
        if let plain, !plain.isEmpty { text += "TXT" + plain + ClipboardText.separator }
        if let rtf, !rtf.isEmpty { text += "RTF" + rtf + ClipboardText.separator }
        if let html, !html.isEmpty { text += "HTM" + html + ClipboardText.separator }
        let raw = text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return Deflate.compress(raw)
    }

    /// Decodifica i dati ricevuti (`Clipboard.SetClipboardData`).
    public init(decoding data: [UInt8], limit: Int = 4 * ClipboardPayload.maxSize) throws {
        let raw = try Deflate.decompress(data, limit: limit)
        // PowerToys decodifica a blocchi con il riempimento di zeri: i NUL non fanno parte del testo.
        let text = String(utf16LE: raw).replacingOccurrences(of: "\0", with: "")
        self.init()
        var count = 0
        for part in text.components(separatedBy: ClipboardText.separator) where !part.isEmpty {
            let prefix = part.prefix(3).uppercased()
            let body = String(part.dropFirst(3))
            switch prefix {
            case "TXT": plain = body
            case "RTF": rtf = body
            case "HTM": html = body
            default:
                // Formato sconosciuto: PowerToys tratta la prima parte come testo semplice.
                if count == 0 { plain = part }
            }
            count += 1
        }
        guard !isEmpty else { throw ClipboardError.invalidData }
    }

    /// Windows usa CR LF; molte applicazioni non vanno a capo con il solo LF.
    public static func windowsLineEndings(_ text: String) -> String {
        macLineEndings(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    public static func macLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Formato "HTML Format" degli appunti di Windows: un'intestazione con gli offset in byte
/// (UTF-8) del documento e del frammento selezionato, seguita dall'HTML.
public enum CFHTML {
    private static let startMarker = "<!--StartFragment-->"
    private static let endMarker = "<!--EndFragment-->"

    /// Avvolge HTML generico (documento o frammento) nel formato di Windows.
    public static func wrap(_ html: String) -> String {
        var prefix = "<html><body>"
        var fragment = html
        var suffix = "</body></html>"
        // Documento completo: i marcatori vanno dentro il <body> esistente.
        if let open = html.range(of: "<body", options: .caseInsensitive),
           let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
           let close = html.range(of: "</body>", options: [.caseInsensitive, .backwards]),
           openEnd.upperBound <= close.lowerBound {
            prefix = String(html[..<openEnd.upperBound])
            fragment = String(html[openEnd.upperBound..<close.lowerBound])
            suffix = String(html[close.lowerBound...])
        }
        let headerLength = header(0, 0, 0, 0).utf8.count
        let startHTML = headerLength
        let startFragment = startHTML + prefix.utf8.count + startMarker.utf8.count
        let endFragment = startFragment + fragment.utf8.count
        let endHTML = endFragment + endMarker.utf8.count + suffix.utf8.count
        return header(startHTML, endHTML, startFragment, endFragment)
            + prefix + startMarker + fragment + endMarker + suffix
    }

    private static func header(_ startHTML: Int, _ endHTML: Int, _ startFragment: Int, _ endFragment: Int) -> String {
        func field(_ value: Int) -> String { String(format: "%010d", value) }
        return "Version:0.9\r\nStartHTML:\(field(startHTML))\r\nEndHTML:\(field(endHTML))\r\n"
            + "StartFragment:\(field(startFragment))\r\nEndFragment:\(field(endFragment))\r\n"
    }

    /// Estrae l'HTML dal formato di Windows; se l'intestazione manca o è incoerente
    /// restituisce il testo dal primo tag in poi.
    public static func unwrap(_ text: String) -> String {
        let bytes = Array(text.utf8)
        func offset(_ key: String) -> Int? {
            guard let range = text.range(of: key + ":") else { return nil }
            let digits = text[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
            return Int(digits)
        }
        func slice(_ start: Int?, _ end: Int?) -> String? {
            guard let start, let end, start >= 0, end > start, end <= bytes.count else { return nil }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }
        let result = slice(offset("StartHTML"), offset("EndHTML"))
            ?? slice(offset("StartFragment"), offset("EndFragment"))
            ?? text.firstIndex(of: "<").map { String(text[$0...]) }
            ?? text
        return result.replacingOccurrences(of: startMarker, with: "").replacingOccurrences(of: endMarker, with: "")
    }
}

// MARK: - Deflate

/// Deflate grezzo (senza intestazione zlib), come `DeflateStream` di .NET.
public enum Deflate {
    public static func compress(_ input: [UInt8]) -> [UInt8] {
        (try? run(COMPRESSION_STREAM_ENCODE, input, limit: Int.max)) ?? []
    }

    /// Decomprime fino alla fine del flusso Deflate, ignorando ciò che segue (PowerToys
    /// accoda zeri). Un flusso troncato restituisce quanto è stato possibile recuperare.
    public static func decompress(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        let output = try run(COMPRESSION_STREAM_DECODE, input, limit: limit)
        guard !output.isEmpty || input.isEmpty else { throw ClipboardError.invalidData }
        return output
    }

    private static func run(_ operation: compression_stream_operation, _ input: [UInt8], limit: Int) throws -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ClipboardError.invalidData
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var output: [UInt8] = []

        return try input.withUnsafeBufferPointer { source -> [UInt8] in
            // Con ingresso vuoto il puntatore base è nil: se ne usa uno valido qualsiasi.
            stream.pointee.src_ptr = source.baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = source.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                    guard output.count <= limit else { throw ClipboardError.tooBig }
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // Nessun progresso possibile: flusso troncato, si tiene il recuperato.
                    if produced == 0 && stream.pointee.src_size == 0 { return output }
                default:
                    // Errore a metà flusso (coda corrotta o mancante): idem.
                    if output.isEmpty { throw ClipboardError.invalidData }
                    return output
                }
            }
        }
    }
}

// MARK: - PNG

/// Controllo e riparazione di un PNG ricevuto: toglie il riempimento in coda e, se il
/// file è arrivato troncato, lo richiude in modo che resti decodificabile.
public enum PNGData {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let iend: [UInt8] = [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    public static func isPNG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= signature.count && Array(bytes[0..<signature.count]) == signature
    }

    /// Restituisce il PNG esatto contenuto in `bytes` (fino al blocco IEND incluso).
    /// `nil` se non è un PNG o se manca perfino l'intestazione dell'immagine.
    public static func sanitized(_ bytes: [UInt8]) -> [UInt8]? {
        guard isPNG(bytes) else { return nil }
        var offset = signature.count
        var sawHeader = false
        var sawData = false
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = Array(bytes[(offset + 4)..<(offset + 8)])
            let end = offset + 12 + length
            if end > bytes.count {
                // Blocco troncato. Se è di dati immagine si salva la parte arrivata.
                guard sawHeader else { return nil }
                var repaired = Array(bytes[0..<offset])
                let available = bytes.count - (offset + 8)
                if type == Array("IDAT".utf8), available > 0 {
                    let partial = Array(bytes[(offset + 8)..<min(offset + 8 + length, bytes.count)])
                    repaired.append(contentsOf: chunk(type: type, data: partial))
                    sawData = true
                }
                guard sawData else { return nil }
                return repaired + iend
            }
            if type == Array("IHDR".utf8) { sawHeader = true }
            if type == Array("IDAT".utf8) { sawData = true }
            offset = end
            if type == Array("IEND".utf8) {
                return sawHeader && sawData ? Array(bytes[0..<offset]) : nil
            }
        }
        // Finito senza IEND (coda mancante): si richiude.
        guard sawHeader, sawData else { return nil }
        return Array(bytes[0..<offset]) + iend
    }

    private static func chunk(type: [UInt8], data: [UInt8]) -> [UInt8] {
        let length = UInt32(data.count)
        let crc = crc32(type + data)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
            + type + data
            + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension String {
    /// Decodifica UTF-16LE tollerante: un byte spaiato in coda viene ignorato e le
    /// sequenze non valide diventano U+FFFD.
    init(utf16LE bytes: [UInt8]) {
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        self = String(decoding: units, as: UTF16.self)
    }
}
