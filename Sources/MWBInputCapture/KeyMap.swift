// Mappa keycode macOS (kVK_*) → virtual-key Windows.
//
// PowerToys inietta il tasto con `SendInput(wVk)` e ricava lo scan code con
// `MapVirtualKey` sul layout attivo del PC (`InputSimulation.SendKey`). Per i tasti
// alfanumerici i VK non dipendono dal layout; per i tasti di punteggiatura (VK_OEM_*)
// sì: lo stesso tasto fisico ha VK diversi su layout italiano e americano. La mappa
// passa quindi per la *posizione fisica* (scan code set 1 del PC) e la traduce nel VK
// che il layout Windows configurato assegna a quella posizione, così che a tasto fisico
// uguale corrisponda carattere uguale a quello stampato sulla tastiera PC equivalente.

/// Tasto Windows da inviare: VK e flag `LLKHF_EXTENDED`.
public struct WindowsKey: Equatable, Sendable {
    public let vk: Int32
    public let extended: Bool

    public init(_ vk: Int32, extended: Bool = false) {
        self.vk = vk
        self.extended = extended
    }
}

/// Layout di tastiera attivo sul PC.
public enum WindowsLayout: String, Codable, Sendable, CaseIterable {
    case italian = "it"
    case us = "us"
}

/// Cosa diventa un modificatore del Mac sul PC.
public enum ModifierTarget: String, Codable, Sendable, CaseIterable {
    case control = "ctrl"
    case windows = "win"
    case alt = "alt"
}

public enum VK {
    public static let back: Int32 = 0x08
    public static let tab: Int32 = 0x09
    public static let `return`: Int32 = 0x0D
    public static let capital: Int32 = 0x14
    public static let escape: Int32 = 0x1B
    public static let space: Int32 = 0x20
    public static let prior: Int32 = 0x21
    public static let next: Int32 = 0x22
    public static let end: Int32 = 0x23
    public static let home: Int32 = 0x24
    public static let left: Int32 = 0x25
    public static let up: Int32 = 0x26
    public static let right: Int32 = 0x27
    public static let down: Int32 = 0x28
    public static let insert: Int32 = 0x2D
    public static let delete: Int32 = 0x2E
    public static let lWin: Int32 = 0x5B
    public static let rWin: Int32 = 0x5C
    public static let numpad0: Int32 = 0x60
    public static let multiply: Int32 = 0x6A
    public static let add: Int32 = 0x6B
    public static let subtract: Int32 = 0x6D
    public static let decimal: Int32 = 0x6E
    public static let divide: Int32 = 0x6F
    public static let f1: Int32 = 0x70
    public static let f13: Int32 = 0x7C
    public static let numLock: Int32 = 0x90
    public static let lShift: Int32 = 0xA0
    public static let rShift: Int32 = 0xA1
    public static let lControl: Int32 = 0xA2
    public static let rControl: Int32 = 0xA3
    public static let lMenu: Int32 = 0xA4
    public static let rMenu: Int32 = 0xA5
    public static let volumeMute: Int32 = 0xAD
    public static let volumeDown: Int32 = 0xAE
    public static let volumeUp: Int32 = 0xAF
    public static let oem1: Int32 = 0xBA
    public static let oemPlus: Int32 = 0xBB
    public static let oemComma: Int32 = 0xBC
    public static let oemMinus: Int32 = 0xBD
    public static let oemPeriod: Int32 = 0xBE
    public static let oem2: Int32 = 0xBF
    public static let oem3: Int32 = 0xC0
    public static let oem4: Int32 = 0xDB
    public static let oem5: Int32 = 0xDC
    public static let oem6: Int32 = 0xDD
    public static let oem7: Int32 = 0xDE
    public static let oem102: Int32 = 0xE2
}

/// Keycode macOS dei modificatori (arrivano come eventi `flagsChanged`).
public enum MacKey {
    public static let rightCommand: UInt16 = 0x36
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let rightShift: UInt16 = 0x3C
    public static let rightOption: UInt16 = 0x3D
    public static let rightControl: UInt16 = 0x3E
    public static let function: UInt16 = 0x3F
    public static let escape: UInt16 = 0x35
    public static let isoSection: UInt16 = 0x0A
    public static let grave: UInt16 = 0x32
}

public struct KeyMap: Sendable {
    public var layout: WindowsLayout
    public var command: ModifierTarget
    public var control: ModifierTarget
    public var option: ModifierTarget
    /// ⌥ destro come AltGr (VK_RMENU): su layout italiano Windows dà `@ # [ ] { }`.
    public var rightOptionIsAltGr: Bool
    /// Tastiera fisica ISO (tasto in più accanto a Maiusc sinistro): sulle tastiere ISO
    /// Apple il keycode 0x0A è il tasto a sinistra dell'1 e 0x32 quello accanto a Maiusc;
    /// sulle ANSI 0x32 è il tasto a sinistra dell'1.
    public var isISOKeyboard: Bool

    public init(layout: WindowsLayout = .italian, command: ModifierTarget = .control,
                control: ModifierTarget = .windows, option: ModifierTarget = .alt,
                rightOptionIsAltGr: Bool = true, isISOKeyboard: Bool = true) {
        self.layout = layout
        self.command = command
        self.control = control
        self.option = option
        self.rightOptionIsAltGr = rightOptionIsAltGr
        self.isISOKeyboard = isISOKeyboard
    }

    /// Traduce un keycode macOS; `nil` se il tasto non ha un equivalente (es. `fn`).
    public func windowsKey(forMacKeyCode code: UInt16) -> WindowsKey? {
        if let key = modifier(code) { return key }
        if let key = KeyMap.fixed[code] { return key }
        if let scanCode = oemScanCode(code), let vk = KeyMap.oemVK(scanCode: scanCode, layout: layout) {
            return WindowsKey(vk)
        }
        return nil
    }

    public static func isModifier(_ code: UInt16) -> Bool {
        switch code {
        case MacKey.command, MacKey.rightCommand, MacKey.shift, MacKey.rightShift, MacKey.option,
             MacKey.rightOption, MacKey.control, MacKey.rightControl, MacKey.capsLock, MacKey.function:
            return true
        default:
            return false
        }
    }

    private func modifier(_ code: UInt16) -> WindowsKey? {
        switch code {
        case MacKey.shift: return WindowsKey(VK.lShift)
        case MacKey.rightShift: return WindowsKey(VK.rShift)
        case MacKey.capsLock: return WindowsKey(VK.capital)
        case MacKey.command: return KeyMap.key(for: command, right: false)
        case MacKey.rightCommand: return KeyMap.key(for: command, right: true)
        case MacKey.control: return KeyMap.key(for: control, right: false)
        case MacKey.rightControl: return KeyMap.key(for: control, right: true)
        case MacKey.option: return KeyMap.key(for: option, right: false)
        case MacKey.rightOption:
            return rightOptionIsAltGr ? WindowsKey(VK.rMenu, extended: true) : KeyMap.key(for: option, right: true)
        default: return nil
        }
    }

    private static func key(for target: ModifierTarget, right: Bool) -> WindowsKey {
        switch target {
        case .control: return right ? WindowsKey(VK.rControl, extended: true) : WindowsKey(VK.lControl)
        case .windows: return right ? WindowsKey(VK.rWin, extended: true) : WindowsKey(VK.lWin, extended: true)
        case .alt: return right ? WindowsKey(VK.rMenu, extended: true) : WindowsKey(VK.lMenu)
        }
    }

    /// Keycode macOS → scan code (set 1) della stessa posizione su una tastiera PC.
    private func oemScanCode(_ code: UInt16) -> UInt8? {
        switch code {
        case MacKey.isoSection: return 0x29
        case MacKey.grave: return isISOKeyboard ? 0x56 : 0x29
        case 0x1B: return 0x0C // primo tasto dopo lo 0
        case 0x18: return 0x0D // secondo tasto dopo lo 0
        case 0x21: return 0x1A // primo tasto dopo la P
        case 0x1E: return 0x1B // secondo tasto dopo la P
        case 0x29: return 0x27 // primo tasto dopo la L
        case 0x27: return 0x28 // secondo tasto dopo la L
        case 0x2A: return 0x2B // terzo tasto dopo la L (ISO) / sopra Invio (ANSI)
        case 0x2B: return 0x33 // primo tasto dopo la M
        case 0x2F: return 0x34 // secondo tasto dopo la M
        case 0x2C: return 0x35 // terzo tasto dopo la M
        default: return nil
        }
    }

    /// Tabelle scan code → VK dei layout Windows (KBDUS e KBDIT).
    static func oemVK(scanCode: UInt8, layout: WindowsLayout) -> Int32? {
        switch layout {
        case .us:
            switch scanCode {
            case 0x29: return VK.oem3
            case 0x0C: return VK.oemMinus
            case 0x0D: return VK.oemPlus
            case 0x1A: return VK.oem4
            case 0x1B: return VK.oem6
            case 0x27: return VK.oem1
            case 0x28: return VK.oem7
            case 0x2B: return VK.oem5
            case 0x33: return VK.oemComma
            case 0x34: return VK.oemPeriod
            case 0x35: return VK.oem2
            case 0x56: return VK.oem102
            default: return nil
            }
        case .italian:
            switch scanCode {
            case 0x29: return VK.oem5      // \ |
            case 0x0C: return VK.oem4      // ' ?
            case 0x0D: return VK.oem6      // ì ^
            case 0x1A: return VK.oem1      // è é [ {
            case 0x1B: return VK.oemPlus   // + * ] }
            case 0x27: return VK.oem3      // ò ç @
            case 0x28: return VK.oem7      // à ° #
            case 0x2B: return VK.oem2      // ù §
            case 0x33: return VK.oemComma  // , ;
            case 0x34: return VK.oemPeriod // . :
            case 0x35: return VK.oemMinus  // - _
            case 0x56: return VK.oem102    // < >
            default: return nil
            }
        }
    }

    /// Tasti il cui VK non dipende dal layout.
    private static let fixed: [UInt16: WindowsKey] = {
        var map: [UInt16: WindowsKey] = [:]
        // Lettere (posizioni QWERTY, comuni a layout italiano e americano).
        let letters: [(UInt16, Character)] = [
            (0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"), (0x04, "H"), (0x05, "G"), (0x06, "Z"),
            (0x07, "X"), (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"), (0x0D, "W"), (0x0E, "E"),
            (0x0F, "R"), (0x10, "Y"), (0x11, "T"), (0x1F, "O"), (0x20, "U"), (0x22, "I"), (0x23, "P"),
            (0x25, "L"), (0x26, "J"), (0x28, "K"), (0x2D, "N"), (0x2E, "M"),
        ]
        for (code, letter) in letters { map[code] = WindowsKey(Int32(letter.asciiValue!)) }
        // Cifre della fila superiore.
        let digits: [(UInt16, Character)] = [
            (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x17, "5"), (0x16, "6"), (0x1A, "7"),
            (0x1C, "8"), (0x19, "9"), (0x1D, "0"),
        ]
        for (code, digit) in digits { map[code] = WindowsKey(Int32(digit.asciiValue!)) }

        map[0x24] = WindowsKey(VK.return)
        map[0x30] = WindowsKey(VK.tab)
        map[0x31] = WindowsKey(VK.space)
        map[0x33] = WindowsKey(VK.back)
        map[0x35] = WindowsKey(VK.escape)

        // Blocco di navigazione: tasti "estesi" su Windows.
        map[0x72] = WindowsKey(VK.insert, extended: true) // Help/Ins
        map[0x73] = WindowsKey(VK.home, extended: true)
        map[0x74] = WindowsKey(VK.prior, extended: true)
        map[0x75] = WindowsKey(VK.delete, extended: true)
        map[0x77] = WindowsKey(VK.end, extended: true)
        map[0x79] = WindowsKey(VK.next, extended: true)
        map[0x7B] = WindowsKey(VK.left, extended: true)
        map[0x7C] = WindowsKey(VK.right, extended: true)
        map[0x7D] = WindowsKey(VK.down, extended: true)
        map[0x7E] = WindowsKey(VK.up, extended: true)

        // Tasti funzione F1…F20.
        let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                      0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (index, code) in functionKeys.enumerated() { map[code] = WindowsKey(VK.f1 + Int32(index)) }

        // Tastierino numerico.
        let keypadDigits: [UInt16] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (index, code) in keypadDigits.enumerated() { map[code] = WindowsKey(VK.numpad0 + Int32(index)) }
        map[0x41] = WindowsKey(VK.decimal)
        map[0x43] = WindowsKey(VK.multiply)
        map[0x45] = WindowsKey(VK.add)
        map[0x4E] = WindowsKey(VK.subtract)
        map[0x4B] = WindowsKey(VK.divide, extended: true)
        map[0x4C] = WindowsKey(VK.return, extended: true)
        map[0x47] = WindowsKey(VK.numLock, extended: true) // Clear occupa il posto di Bloc Num

        map[0x48] = WindowsKey(VK.volumeUp, extended: true)
        map[0x49] = WindowsKey(VK.volumeDown, extended: true)
        map[0x4A] = WindowsKey(VK.volumeMute, extended: true)
        return map
    }()
}
