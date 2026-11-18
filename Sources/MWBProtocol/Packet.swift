// Framing dei pacchetti MWB a 32/64 byte.
// Fonte: PowerToys `Core/DATA.cs` (layout), `Class/SocketStuff.cs` (`TcpSendData`,
// `ProcessReceivedDataEx`: magic e checksum).
//
// Layout little-endian:
//   0      tipo            1      checksum (somma a 8 bit dei byte 2..31)
//   2–3    16 bit alti del magic number
//   4–7    Id              8–11   Src            12–15  Des
//   16–31  payload (MOUSEDATA | DateTime+KEYBDDATA | Machine1..4)
//   32–63  nome macchina ASCII riempito con spazi (solo pacchetti da 64 byte)

public enum PacketError: Error, Equatable {
    case truncated
    case badMagic
    case badChecksum
}

public struct MouseData: Equatable, Sendable {
    public var x: Int32
    public var y: Int32
    public var wheelDelta: Int32
    public var flags: Int32

    public init(x: Int32, y: Int32, wheelDelta: Int32 = 0, flags: Int32) {
        self.x = x
        self.y = y
        self.wheelDelta = wheelDelta
        self.flags = flags
    }
}

public struct KeyboardData: Equatable, Sendable {
    public var dateTime: Int64
    public var vk: Int32
    public var flags: Int32

    public init(dateTime: Int64 = 0, vk: Int32, flags: Int32) {
        self.dateTime = dateTime
        self.vk = vk
        self.flags = flags
    }
}

public struct Packet: Equatable, Sendable {
    public static let size = 32
    public static let sizeEx = 64
    public static let payloadSize = 16
    public static let nameSize = 32
    public static let clipboardChunkSize = 48

    /// Primo byte così com'è sul filo (può contenere i flag di `Matrix`).
    public var rawType: UInt8
    public var id: Int32 = 0
    public var src: UInt32 = MachineID.none
    public var des: UInt32 = MachineID.none
    /// 16 byte agli offset 16..31.
    public var payload: [UInt8] = [UInt8](repeating: 0, count: Packet.payloadSize)
    /// Byte 32..63, presenti sul filo solo nei pacchetti da 64 byte. Di norma contengono il
    /// nome macchina; nei pacchetti `ClipboardText`/`ClipboardImage` sono dati.
    public var tail: [UInt8] = Packet.encodeName("")

    /// Nome macchina senza spazi di riempimento (vista su `tail`).
    public var machineName: String {
        get { Packet.decodeName(tail) }
        set { tail = Packet.encodeName(newValue) }
    }

    /// I 48 byte di dati (offset 16..63) dei pacchetti degli appunti inviati in linea.
    public var clipboardChunk: [UInt8] {
        get { payload + tail }
        set {
            precondition(newValue.count == Packet.clipboardChunkSize)
            payload = Array(newValue[0..<Packet.payloadSize])
            tail = Array(newValue[Packet.payloadSize...])
        }
    }

    public init(type: PackageType, des: UInt32 = MachineID.none, machineName: String = "") {
        self.rawType = type.rawValue
        self.des = des
        self.machineName = machineName
    }

    public init(rawType: UInt8) {
        self.rawType = rawType
    }

    public var type: PackageType? {
        if rawType & PackageType.matrix.rawValue != 0, rawType < PackageType.error.rawValue { return .matrix }
        return PackageType(rawValue: rawType)
    }

    public var isBig: Bool { PackageType.isBig(rawType: rawType) }

    // MARK: Viste sul payload

    public var mouse: MouseData {
        get {
            MouseData(x: payload.int32(at: 0), y: payload.int32(at: 4),
                      wheelDelta: payload.int32(at: 8), flags: payload.int32(at: 12))
        }
        set {
            payload.setInt32(newValue.x, at: 0)
            payload.setInt32(newValue.y, at: 4)
            payload.setInt32(newValue.wheelDelta, at: 8)
            payload.setInt32(newValue.flags, at: 12)
        }
    }

    public var keyboard: KeyboardData {
        get {
            let low = UInt64(UInt32(bitPattern: payload.int32(at: 0)))
            let high = UInt64(UInt32(bitPattern: payload.int32(at: 4)))
            return KeyboardData(dateTime: Int64(bitPattern: low | (high << 32)),
                                vk: payload.int32(at: 8), flags: payload.int32(at: 12))
        }
        set {
            let bits = UInt64(bitPattern: newValue.dateTime)
            payload.setInt32(Int32(bitPattern: UInt32(bits & 0xFFFF_FFFF)), at: 0)
            payload.setInt32(Int32(bitPattern: UInt32(bits >> 32)), at: 4)
            payload.setInt32(newValue.vk, at: 8)
            payload.setInt32(newValue.flags, at: 12)
        }
    }

    /// Campi `Machine1..4` (usati dall'handshake e dalla matrice).
    public var machines: [UInt32] {
        get { (0..<4).map { UInt32(bitPattern: payload.int32(at: $0 * 4)) } }
        set {
            precondition(newValue.count == 4)
            for (index, value) in newValue.enumerated() {
                payload.setInt32(Int32(bitPattern: value), at: index * 4)
            }
        }
    }

    // MARK: Serializzazione

    /// Produce i 32 o 64 byte da cifrare e inviare, con magic e checksum calcolati
    /// come in `SocketStuff.TcpSendData`.
    public func serialized(magic: UInt32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: isBig ? Packet.sizeEx : Packet.size)
        buffer[0] = rawType
        buffer[2] = UInt8((magic >> 16) & 0xFF)
        buffer[3] = UInt8((magic >> 24) & 0xFF)
        buffer.setInt32(id, at: 4)
        buffer.setInt32(Int32(bitPattern: src), at: 8)
        buffer.setInt32(Int32(bitPattern: des), at: 12)
        buffer.replaceSubrange(16..<32, with: payload)
        if isBig {
            buffer.replaceSubrange(32..<64, with: tail)
        }
        buffer[1] = Packet.checksum(of: buffer)
        return buffer
    }

    /// Controlla magic e checksum dei primi 32 byte (`ProcessReceivedDataEx`).
    public static func validate(header: [UInt8], magic: UInt32) throws {
        guard header.count >= Packet.size else { throw PacketError.truncated }
        guard header[2] == UInt8((magic >> 16) & 0xFF), header[3] == UInt8((magic >> 24) & 0xFF) else {
            throw PacketError.badMagic
        }
        guard header[1] == checksum(of: header) else { throw PacketError.badChecksum }
    }

    /// Lunghezza totale del pacchetto dati i primi 32 byte. Un'intestazione non valida
    /// viene trattata come `invalid` (0xFF), che è un tipo "grande": 64 byte.
    public static func expectedSize(header: [UInt8], magic: UInt32) -> Int {
        guard (try? validate(header: header, magic: magic)) != nil else { return Packet.sizeEx }
        return PackageType.isBig(rawType: header[0]) ? Packet.sizeEx : Packet.size
    }

    /// Ricostruisce un pacchetto da 32 o 64 byte in chiaro.
    public init(bytes: [UInt8], magic: UInt32) throws {
        try Packet.validate(header: bytes, magic: magic)
        rawType = bytes[0]
        id = bytes.int32(at: 4)
        src = UInt32(bitPattern: bytes.int32(at: 8))
        des = UInt32(bitPattern: bytes.int32(at: 12))
        payload = Array(bytes[16..<32])
        if PackageType.isBig(rawType: rawType) {
            guard bytes.count >= Packet.sizeEx else { throw PacketError.truncated }
            tail = Array(bytes[32..<64])
        }
    }

    static func checksum(of buffer: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for index in 2..<Packet.size { sum = sum &+ buffer[index] }
        return sum
    }

    /// Nome ASCII a 32 caratteri riempito con spazi (`DATA.MachineName`).
    static func encodeName(_ name: String) -> [UInt8] {
        var bytes = name.unicodeScalars.prefix(Packet.nameSize).map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }
        bytes.append(contentsOf: [UInt8](repeating: UInt8(ascii: " "), count: Packet.nameSize - bytes.count))
        return bytes
    }

    static func decodeName(_ bytes: [UInt8]) -> String {
        let scalars = bytes.map { $0 < 0x80 ? Character(UnicodeScalar($0)) : Character("?") }
        return String(scalars).trimmingCharacters(in: [" ", "\0", "\t", "\r", "\n"])
    }
}

extension Packet: CustomStringConvertible {
    /// Forma leggibile per il log del protocollo in chiaro.
    public var description: String {
        let typeName = type.map { "\($0)" } ?? "unknown"
        var text = "\(typeName)(\(rawType)) id=\(id) src=\(src) des=\(des)"
        switch type {
        case .mouse, .nextMachine:
            let m = mouse
            text += " x=\(m.x) y=\(m.y) wheel=\(m.wheelDelta) flags=0x\(String(m.flags, radix: 16))"
        case .keyboard:
            // Il log del protocollo non deve diventare un keylogger (password digitate sul
            // PC): si mostrano solo i modificatori, gli altri tasti restano anonimi.
            let k = keyboard
            let modifiers: Set<Int32> = [0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]
            let vk = modifiers.contains(k.vk) ? "0x\(String(k.vk, radix: 16))" : "•"
            text += " vk=\(vk) flags=0x\(String(k.flags, radix: 16))"
        default:
            break
        }
        switch type {
        case .clipboardText, .clipboardImage, .clipboardDataEnd: break
        default: if isBig { text += " name=\"\(machineName)\"" }
        }
        return text
    }
}

// MARK: - Accesso little-endian

extension Array where Element == UInt8 {
    func int32(at offset: Int) -> Int32 {
        let value = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        return Int32(bitPattern: value)
    }

    mutating func setInt32(_ value: Int32, at offset: Int) {
        let bits = UInt32(bitPattern: value)
        self[offset] = UInt8(bits & 0xFF)
        self[offset + 1] = UInt8((bits >> 8) & 0xFF)
        self[offset + 2] = UInt8((bits >> 16) & 0xFF)
        self[offset + 3] = UInt8((bits >> 24) & 0xFF)
    }
}

private extension String {
    func trimmingCharacters(in set: Set<Character>) -> String {
        var slice = Substring(self)
        while let first = slice.first, set.contains(first) { slice.removeFirst() }
        while let last = slice.last, set.contains(last) { slice.removeLast() }
        return String(slice)
    }
}
