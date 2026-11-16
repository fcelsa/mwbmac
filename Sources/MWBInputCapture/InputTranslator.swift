// Traduzione degli eventi di input macOS nei payload MWB (mouse relativo, click,
// rotella, tasti). Logica pura, senza dipendenze da CoreGraphics, per poterla testare.

import MWBProtocol

/// Pulsanti del mouse come li numera CoreGraphics (0 sinistro, 1 destro, 2 centrale, 3+ extra).
public enum MouseButtonAction: Sendable {
    case down, up
}

public struct InputTranslator: Sendable {
    public var keyMap: KeyMap
    public var invertScroll: Bool
    /// Pixel di scorrimento continuo (trackpad, Magic Mouse) equivalenti a una tacca.
    public var pixelsPerNotch: Double

    private var verticalRemainder = 0.0
    private var horizontalRemainder = 0.0
    /// Tasti Windows attualmente premuti sul PC (per rilasciarli al ritorno).
    public private(set) var pressedKeys: [WindowsKey] = []
    public private(set) var pressedButtons: Set<Int> = []

    public init(keyMap: KeyMap = KeyMap(), invertScroll: Bool = false, pixelsPerNotch: Double = 10) {
        self.keyMap = keyMap
        self.invertScroll = invertScroll
        self.pixelsPerNotch = pixelsPerNotch
    }

    // MARK: Mouse

    /// Movimento relativo: delta sommato al marcatore ±100000.
    public func mouseMove(dx: Int, dy: Int) -> MouseData {
        MouseData(x: RelativeMouse.encode(Int32(clamping: dx)), y: RelativeMouse.encode(Int32(clamping: dy)),
                  flags: WM.mouseMove)
    }

    /// Posizionamento assoluto (0…65535 sullo schermo primario del PC), usato all'ingresso.
    public func mouseMoveAbsolute(x: Int32, y: Int32) -> MouseData {
        MouseData(x: min(max(x, 0), 65535), y: min(max(y, 0), 65535), flags: WM.mouseMove)
    }

    /// Click. X/Y portano il marcatore relativo con delta zero: il ricevente usa la
    /// posizione corrente del proprio cursore (`Receiver.cs`, ramo `Mouse`).
    public mutating func mouseButton(_ button: Int, _ action: MouseButtonAction) -> MouseData? {
        let flags: Int32
        var data: Int32 = 0
        switch (button, action) {
        case (0, .down): flags = WM.lButtonDown
        case (0, .up): flags = WM.lButtonUp
        case (1, .down): flags = WM.rButtonDown
        case (1, .up): flags = WM.rButtonUp
        case (2, .down): flags = WM.mButtonDown
        case (2, .up): flags = WM.mButtonUp
        case (3...4, _):
            flags = action == .down ? WM.xButtonDown : WM.xButtonUp
            data = Int32(button - 2) // XBUTTON1 = 1, XBUTTON2 = 2 in `mouseData`
        default:
            return nil
        }
        if action == .down {
            pressedButtons.insert(button)
        } else {
            // Un rilascio senza pressione (iniziata prima del cambio macchina) non va inoltrato.
            guard pressedButtons.remove(button) != nil else { return nil }
        }
        return MouseData(x: RelativeMouse.marker, y: RelativeMouse.marker, wheelDelta: data, flags: flags)
    }

    /// Rotella. `lines` sono le tacche di un mouse tradizionale, `pixels` lo scorrimento
    /// continuo; positivo = verso l'alto (verticale) o verso sinistra (orizzontale), come
    /// li riporta macOS. Windows vuole multipli di 120, positivo = su / destra.
    public mutating func scroll(verticalLines: Int, horizontalLines: Int,
                                verticalPixels: Double, horizontalPixels: Double,
                                isContinuous: Bool) -> [MouseData] {
        var vertical: Int32
        var horizontal: Int32
        if isContinuous {
            verticalRemainder += verticalPixels / pixelsPerNotch
            horizontalRemainder += horizontalPixels / pixelsPerNotch
            let wholeV = verticalRemainder.rounded(.towardZero)
            let wholeH = horizontalRemainder.rounded(.towardZero)
            verticalRemainder -= wholeV
            horizontalRemainder -= wholeH
            vertical = Int32(wholeV)
            horizontal = Int32(wholeH)
        } else {
            vertical = Int32(clamping: verticalLines)
            horizontal = Int32(clamping: horizontalLines)
        }
        if invertScroll {
            vertical = -vertical
            horizontal = -horizontal
        }
        var result: [MouseData] = []
        if vertical != 0 {
            result.append(MouseData(x: RelativeMouse.marker, y: RelativeMouse.marker,
                                    wheelDelta: vertical * WM.wheelDelta, flags: WM.mouseWheel))
        }
        if horizontal != 0 {
            result.append(MouseData(x: RelativeMouse.marker, y: RelativeMouse.marker,
                                    wheelDelta: -horizontal * WM.wheelDelta, flags: WM.mouseHWheel))
        }
        return result
    }

    // MARK: Tastiera

    /// Tasto normale. I rilasci di tasti mai premuti sul PC vengono scartati.
    public mutating func key(macKeyCode: UInt16, isDown: Bool) -> KeyboardData? {
        guard let key = keyMap.windowsKey(forMacKeyCode: macKeyCode) else { return nil }
        if isDown {
            if !pressedKeys.contains(key) { pressedKeys.append(key) }
        } else {
            guard let index = pressedKeys.firstIndex(of: key) else { return nil }
            pressedKeys.remove(at: index)
        }
        return InputTranslator.keyboardData(key, isDown: isDown)
    }

    /// Bloc Maiusc: macOS notifica solo il cambio di stato, Windows vuole pressione e rilascio.
    public func capsLockTap() -> [KeyboardData] {
        let key = WindowsKey(VK.capital)
        return [InputTranslator.keyboardData(key, isDown: true), InputTranslator.keyboardData(key, isDown: false)]
    }

    /// Rilasci da inviare quando si lascia il PC, per non lasciare tasti o pulsanti incastrati.
    public mutating func releaseAll() -> (keys: [KeyboardData], buttons: [MouseData]) {
        let keys = pressedKeys.reversed().map { InputTranslator.keyboardData($0, isDown: false) }
        pressedKeys.removeAll()
        var buttons: [MouseData] = []
        for button in pressedButtons.sorted() {
            if let data = mouseButton(button, .up) { buttons.append(data) }
        }
        verticalRemainder = 0
        horizontalRemainder = 0
        return (keys, buttons)
    }

    static func keyboardData(_ key: WindowsKey, isDown: Bool) -> KeyboardData {
        var flags: Int32 = isDown ? 0 : LLKHF.up
        if key.extended { flags |= LLKHF.extended }
        return KeyboardData(vk: key.vk, flags: flags)
    }
}
