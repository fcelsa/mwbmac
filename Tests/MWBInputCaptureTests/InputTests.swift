import Testing
import Foundation
import MWBProtocol
@testable import MWBInputCapture

struct KeyMapTests {
    @Test func testLettersDigitsAndEditingKeys() {
        let map = KeyMap()
        #expect(map.windowsKey(forMacKeyCode: 0x00) == WindowsKey(0x41)) // A
        #expect(map.windowsKey(forMacKeyCode: 0x06) == WindowsKey(0x5A)) // Z
        #expect(map.windowsKey(forMacKeyCode: 0x12) == WindowsKey(0x31)) // 1
        #expect(map.windowsKey(forMacKeyCode: 0x1D) == WindowsKey(0x30)) // 0
        #expect(map.windowsKey(forMacKeyCode: 0x24) == WindowsKey(VK.return))
        #expect(map.windowsKey(forMacKeyCode: 0x33) == WindowsKey(VK.back))
        #expect(map.windowsKey(forMacKeyCode: 0x75) == WindowsKey(VK.delete, extended: true))
        #expect(map.windowsKey(forMacKeyCode: 0x7B) == WindowsKey(VK.left, extended: true))
        #expect(map.windowsKey(forMacKeyCode: 0x7A) == WindowsKey(0x70)) // F1
        #expect(map.windowsKey(forMacKeyCode: 0x6F) == WindowsKey(0x7B)) // F12
        #expect(map.windowsKey(forMacKeyCode: 0x4C) == WindowsKey(VK.return, extended: true)) // Invio tastierino
        #expect(map.windowsKey(forMacKeyCode: MacKey.function) == nil)
    }

    @Test func testEveryLetterAndDigitIsMappedOnce() {
        let map = KeyMap()
        var seen = Set<Int32>()
        for code: UInt16 in 0x00...0x2F {
            guard let key = map.windowsKey(forMacKeyCode: code) else { continue }
            if (0x30...0x39).contains(key.vk) || (0x41...0x5A).contains(key.vk) {
                #expect(seen.insert(key.vk).inserted, "VK duplicato 0x\(String(key.vk, radix: 16))")
            }
        }
        #expect(seen.count == 36)
    }

    @Test func testPunctuationFollowsWindowsLayout() {
        let italian = KeyMap(layout: .italian)
        let us = KeyMap(layout: .us)
        // Tasto a destra della L: ò su tastiera italiana, ; su americana.
        #expect(italian.windowsKey(forMacKeyCode: 0x29) == WindowsKey(VK.oem3))
        #expect(us.windowsKey(forMacKeyCode: 0x29) == WindowsKey(VK.oem1))
        // Tasto a destra della P: è / [.
        #expect(italian.windowsKey(forMacKeyCode: 0x21) == WindowsKey(VK.oem1))
        #expect(us.windowsKey(forMacKeyCode: 0x21) == WindowsKey(VK.oem4))
        // Terzo tasto dopo la M: - / slash.
        #expect(italian.windowsKey(forMacKeyCode: 0x2C) == WindowsKey(VK.oemMinus))
        #expect(us.windowsKey(forMacKeyCode: 0x2C) == WindowsKey(VK.oem2))
        // Virgola e punto coincidono.
        #expect(italian.windowsKey(forMacKeyCode: 0x2B) == us.windowsKey(forMacKeyCode: 0x2B))
    }

    @Test func testISOAndANSITopLeftKey() {
        let iso = KeyMap(layout: .italian, isISOKeyboard: true)
        let ansi = KeyMap(layout: .us, isISOKeyboard: false)
        // ISO: 0x0A è il tasto a sinistra dell'1 (\ su PC italiano), 0x32 il tasto < >.
        #expect(iso.windowsKey(forMacKeyCode: MacKey.isoSection) == WindowsKey(VK.oem5))
        #expect(iso.windowsKey(forMacKeyCode: MacKey.grave) == WindowsKey(VK.oem102))
        // ANSI: 0x32 è il tasto a sinistra dell'1.
        #expect(ansi.windowsKey(forMacKeyCode: MacKey.grave) == WindowsKey(VK.oem3))
    }

    @Test func testModifierMapping() {
        let standard = KeyMap()
        #expect(standard.windowsKey(forMacKeyCode: MacKey.command) == WindowsKey(VK.lControl))
        #expect(standard.windowsKey(forMacKeyCode: MacKey.control) == WindowsKey(VK.lWin, extended: true))
        #expect(standard.windowsKey(forMacKeyCode: MacKey.option) == WindowsKey(VK.lMenu))
        #expect(standard.windowsKey(forMacKeyCode: MacKey.rightOption) == WindowsKey(VK.rMenu, extended: true))
        #expect(standard.windowsKey(forMacKeyCode: MacKey.rightShift) == WindowsKey(VK.rShift))

        let literal = KeyMap(command: .windows, control: .control)
        #expect(literal.windowsKey(forMacKeyCode: MacKey.command) == WindowsKey(VK.lWin, extended: true))
        #expect(literal.windowsKey(forMacKeyCode: MacKey.rightCommand) == WindowsKey(VK.rWin, extended: true))
        #expect(literal.windowsKey(forMacKeyCode: MacKey.rightControl) == WindowsKey(VK.rControl, extended: true))
    }
}

struct InputTranslatorTests {
    @Test func testRelativeMoveUsesMarker() {
        let translator = InputTranslator()
        let move = translator.mouseMove(dx: 4, dy: 0)
        #expect(move == MouseData(x: 100_004, y: 100_000, flags: WM.mouseMove))
        #expect(RelativeMouse.isRelative(x: move.x, y: move.y))
        #expect(translator.mouseMove(dx: -9, dy: -2).x == -100_009)
    }

    @Test func testButtons() {
        var translator = InputTranslator()
        #expect(translator.mouseButton(0, .down)?.flags == WM.lButtonDown)
        #expect(translator.mouseButton(0, .up)?.flags == WM.lButtonUp)
        #expect(translator.mouseButton(1, .down)?.flags == WM.rButtonDown)
        #expect(translator.mouseButton(2, .down)?.flags == WM.mButtonDown)
        let extra = translator.mouseButton(4, .down)
        #expect(extra?.flags == WM.xButtonDown)
        #expect(extra?.wheelDelta == 2) // XBUTTON2
        // Il click porta il marcatore relativo: il PC usa la posizione corrente del cursore.
        #expect(extra?.x == RelativeMouse.marker)
        // Rilascio di un pulsante mai premuto sul PC: scartato.
        #expect(translator.mouseButton(3, .up) == nil)
    }

    @Test func testWheelNotches() {
        var translator = InputTranslator()
        let up = translator.scroll(verticalLines: 2, horizontalLines: 0, verticalPixels: 0, horizontalPixels: 0, isContinuous: false)
        #expect(up == [MouseData(x: 100_000, y: 100_000, wheelDelta: 240, flags: WM.mouseWheel)])
        // Orizzontale: macOS positivo = sinistra, Windows positivo = destra.
        let left = translator.scroll(verticalLines: 0, horizontalLines: 1, verticalPixels: 0, horizontalPixels: 0, isContinuous: false)
        #expect(left.first?.flags == WM.mouseHWheel)
        #expect(left.first?.wheelDelta == -120)
    }

    @Test func testContinuousScrollAccumulates() {
        var translator = InputTranslator(pixelsPerNotch: 10)
        var total: Int32 = 0
        for _ in 0..<7 {
            let events = translator.scroll(verticalLines: 0, horizontalLines: 0, verticalPixels: -3, horizontalPixels: 0, isContinuous: true)
            total += events.reduce(0) { $0 + $1.wheelDelta }
        }
        #expect(total == -240) // 21 pixel = 2 tacche, il resto rimane in sospeso
    }

    @Test func testKeyTrackingAndRelease() {
        var translator = InputTranslator()
        #expect(translator.key(macKeyCode: MacKey.shift, isDown: true) == KeyboardData(vk: VK.lShift, flags: 0))
        #expect(translator.key(macKeyCode: 0x00, isDown: true) == KeyboardData(vk: 0x41, flags: 0))
        #expect(translator.key(macKeyCode: 0x7C, isDown: true) == KeyboardData(vk: VK.right, flags: LLKHF.extended))
        // Rilascio di un tasto premuto prima del cambio macchina: scartato.
        #expect(translator.key(macKeyCode: 0x01, isDown: false) == nil)
        _ = translator.mouseButton(0, .down)

        let released = translator.releaseAll()
        #expect(released.keys.map(\.vk) == [VK.right, 0x41, VK.lShift])
        #expect(released.keys.allSatisfy { $0.flags & LLKHF.up != 0 })
        #expect(released.keys.first?.flags == LLKHF.up | LLKHF.extended)
        #expect(released.buttons.map(\.flags) == [WM.lButtonUp])
        #expect(translator.pressedKeys.isEmpty)
        #expect(translator.pressedButtons.isEmpty)
    }

    @Test func testCapsLockIsATap() {
        let events = InputTranslator().capsLockTap()
        #expect(events.map(\.vk) == [VK.capital, VK.capital])
        #expect(events.map(\.flags) == [0, LLKHF.up])
    }
}
