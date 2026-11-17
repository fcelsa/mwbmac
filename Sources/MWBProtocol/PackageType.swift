// Tipi di pacchetto e costanti Windows usate dal protocollo MWB.
// Fonte: PowerToys `Core/PackageType.cs`, `Core/WM.cs`, `Core/ID.cs`, `Core/Event.cs`.

/// Valori dell'enum `PackageType` di PowerToys (primo byte di ogni pacchetto).
public enum PackageType: UInt8, CaseIterable, Sendable {
    case invalid = 0xFF
    case error = 0xFE

    case hi = 2
    case hello = 3
    case byeBye = 4

    case heartbeat = 20
    case awake = 21
    case hideMouse = 50
    case heartbeatEx = 51
    case heartbeatExL2 = 52
    case heartbeatExL3 = 53

    case clipboard = 69
    case clipboardDragDrop = 70
    case clipboardDragDropEnd = 71
    case explorerDragDrop = 72
    case clipboardCapture = 73
    case captureScreenCommand = 74
    case clipboardDragDropOperation = 75
    case clipboardDataEnd = 76
    case machineSwitched = 77
    case clipboardAsk = 78
    case clipboardPush = 79

    case nextMachine = 121
    case keyboard = 122
    case mouse = 123
    case clipboardText = 124
    case clipboardImage = 125

    case handshake = 126
    case handshakeAck = 127

    /// `Matrix` è un flag (128) combinabile con `MatrixSwapFlag` (2) e `MatrixTwoRowFlag` (4).
    case matrix = 128

    /// Vero per i tipi trasmessi in 64 byte (`DATA.IsBigPackage`).
    /// Qualsiasi tipo con il bit 128 è "grande", inclusi `invalid` ed `error`:
    /// è così che il ricevitore di PowerToys consuma lo stream dopo un pacchetto non valido.
    public static func isBig(rawType: UInt8) -> Bool {
        if rawType & PackageType.matrix.rawValue != 0 { return true }
        switch PackageType(rawValue: rawType) {
        case .hello, .awake, .heartbeat, .heartbeatEx, .handshake, .handshakeAck,
             .clipboardPush, .clipboard, .clipboardAsk, .clipboardImage, .clipboardText, .clipboardDataEnd:
            return true
        default:
            return false
        }
    }
}

/// Identificativi macchina speciali (`Core/ID.cs`).
public enum MachineID {
    public static let none: UInt32 = 0
    public static let all: UInt32 = 255
}

/// Messaggi Windows trasportati in `MOUSEDATA.dwFlags` (`Core/WM.cs`).
public enum WM {
    public static let mouseMove: Int32 = 0x200
    public static let lButtonDown: Int32 = 0x201
    public static let lButtonUp: Int32 = 0x202
    public static let rButtonDown: Int32 = 0x204
    public static let rButtonUp: Int32 = 0x205
    public static let mButtonDown: Int32 = 0x207
    public static let mButtonUp: Int32 = 0x208
    public static let mouseWheel: Int32 = 0x20A
    public static let xButtonDown: Int32 = 0x20B
    public static let xButtonUp: Int32 = 0x20C
    public static let mouseHWheel: Int32 = 0x20E

    /// Una tacca di rotella su Windows.
    public static let wheelDelta: Int32 = 120
}

/// Flag `LLKHF` trasportati in `KEYBDDATA.dwFlags`.
public enum LLKHF {
    public static let extended: Int32 = 0x01
    public static let up: Int32 = 0x80
}

/// Marcatore del modo mouse relativo (`Event.MOVE_MOUSE_RELATIVE`): il delta viene
/// sommato a ±100000 e il ricevente lo riconosce dal valore assoluto ≥ 100000.
public enum RelativeMouse {
    public static let marker: Int32 = 100_000

    /// Il delta viene limitato a ±(marker − 1): oltre, la somma traboccherebbe (arresto
    /// del programma) o sarebbe ambigua per il ricevente.
    public static func encode(_ delta: Int32) -> Int32 {
        let limited = min(max(delta, -(marker - 1)), marker - 1)
        return limited < 0 ? limited - marker : limited + marker
    }

    public static func decode(_ value: Int32) -> Int32 {
        value < 0 ? value + marker : value - marker
    }

    public static func isRelative(x: Int32, y: Int32) -> Bool {
        abs(x) >= marker && abs(y) >= marker
    }
}
