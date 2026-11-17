import Testing
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import MWBInputCapture
import MWBProtocol
@testable import MWBEdgeLogic

struct EdgeDetectorTests {
    let single = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

    /// Spinge contro il bordo destro a intervalli di 10 ms; restituisce l'istante del cambio.
    private func push(_ detector: inout EdgeDetector, at point: CGPoint, dx: Double, dy: Double = 0,
                      displays: [CGRect], from start: TimeInterval = 0, steps: Int = 100) -> (time: TimeInterval, fraction: Double)? {
        for step in 0..<steps {
            let now = start + Double(step) * 0.01
            if let fraction = detector.update(position: point, deltaX: dx, deltaY: dy, displays: displays, now: now) {
                return (now, fraction)
            }
        }
        return nil
    }

    @Test func testSwitchRequiresDelayAndResistance() {
        var detector = EdgeDetector(edge: .right, delay: 0.15, resistance: 30)
        let result = push(&detector, at: CGPoint(x: 1919, y: 540), dx: 5, displays: single)
        // 30 px a 5 px per evento = 6 eventi (50 ms), ma il ritardo di 150 ms prevale.
        #expect(abs((result?.time ?? -1) - (0.15)) <= 0.001)
        #expect(abs((result?.fraction ?? -1) - (0.5)) <= 0.01)

        var stiff = EdgeDetector(edge: .right, delay: 0, resistance: 200)
        let slow = push(&stiff, at: CGPoint(x: 1919, y: 540), dx: 5, displays: single)
        #expect(abs((slow?.time ?? -1) - (0.39)) <= 0.001) // 40 eventi da 5 px
    }

    @Test func testNoSwitchAwayFromEdgeOrWithoutPush() {
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 0)
        #expect(push(&detector, at: CGPoint(x: 900, y: 540), dx: 50, displays: single) == nil)
        // Sul bordo ma scorrendo solo in verticale: nessuna spinta.
        #expect(push(&detector, at: CGPoint(x: 1919, y: 540), dx: 0, dy: 8, displays: single) == nil)
        // Basta un pixel di spinta quando ritardo e resistenza sono zero.
        #expect(detector.update(position: CGPoint(x: 1919, y: 540), deltaX: 1, deltaY: 0, displays: single, now: 5) != nil)
    }

    @Test func testMovingAwayResetsAccumulatedPush() {
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 30)
        let edge = CGPoint(x: 1919, y: 100)
        #expect(detector.update(position: edge, deltaX: 20, deltaY: 0, displays: single, now: 0) == nil)
        #expect(detector.update(position: edge, deltaX: -1, deltaY: 0, displays: single, now: 0.01) == nil)
        #expect(detector.update(position: edge, deltaX: 20, deltaY: 0, displays: single, now: 0.02) == nil)
        #expect(detector.update(position: edge, deltaX: 20, deltaY: 0, displays: single, now: 0.03) != nil)
    }

    @Test func testPauseOnTheEdgeRestartsTheDelay() {
        var detector = EdgeDetector(edge: .right, delay: 0.2, resistance: 0)
        let edge = CGPoint(x: 1919, y: 100)
        #expect(detector.update(position: edge, deltaX: 3, deltaY: 0, displays: single, now: 0) == nil)
        // Cursore lasciato fermo sul bordo per due secondi: il ritardo non è "già scontato".
        #expect(detector.update(position: edge, deltaX: 3, deltaY: 0, displays: single, now: 2) == nil)
        #expect(detector.update(position: edge, deltaX: 3, deltaY: 0, displays: single, now: 2.21) != nil)
    }

    @Test func testDisarmedUntilCursorLeavesTheEdge() {
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 0)
        detector.disarm()
        #expect(push(&detector, at: CGPoint(x: 1919, y: 500), dx: 10, displays: single, steps: 3) == nil)
        // Rientra nello schermo, poi torna al bordo: ora è armato.
        #expect(detector.update(position: CGPoint(x: 1500, y: 500), deltaX: -10, deltaY: 0, displays: single, now: 1) == nil)
        #expect(detector.update(position: CGPoint(x: 1919, y: 500), deltaX: 10, deltaY: 0, displays: single, now: 1.1) != nil)
    }

    @Test func testAllFourEdges() {
        let cases: [(ScreenEdge, CGPoint, Double, Double)] = [
            (.left, CGPoint(x: 0, y: 540), -5, 0),
            (.right, CGPoint(x: 1919.5, y: 540), 5, 0),
            (.top, CGPoint(x: 960, y: 0), 0, -5),
            (.bottom, CGPoint(x: 960, y: 1079), 0, 5),
        ]
        for (edge, point, dx, dy) in cases {
            var detector = EdgeDetector(edge: edge, delay: 0, resistance: 0)
            let fraction = detector.update(position: point, deltaX: dx, deltaY: dy, displays: single, now: 0)
            #expect(abs((fraction ?? -1) - (0.5)) <= 0.01, "\(edge)")
        }
    }

    @Test func testInnerEdgeBetweenDisplaysIsIgnored() {
        // Secondo display a destra, più basso: il bordo destro del primo è "interno"
        // solo dove i due si toccano.
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        CGRect(x: 1920, y: 0, width: 1280, height: 720)]
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 0)
        #expect(detector.update(position: CGPoint(x: 1919, y: 300), deltaX: 9, deltaY: 0, displays: displays, now: 0) == nil)
        #expect(detector.update(position: CGPoint(x: 1919, y: 900), deltaX: 9, deltaY: 0, displays: displays, now: 1) != nil)
        #expect(detector.update(position: CGPoint(x: 3199, y: 300), deltaX: 9, deltaY: 0, displays: displays, now: 2) != nil)
    }

    @Test func testActiveRangeLimitsAndRescales() {
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 0, activeRange: 0.5...1)
        #expect(detector.update(position: CGPoint(x: 1919, y: 200), deltaX: 9, deltaY: 0, displays: single, now: 0) == nil)
        let fraction = detector.update(position: CGPoint(x: 1919, y: 810), deltaX: 9, deltaY: 0, displays: single, now: 1)
        #expect(abs((fraction ?? -1) - (0.5)) <= 0.01)
        let back = detector.returnPoint(fraction: 0.5, on: single[0])
        #expect(abs((back.y) - (0.75 * 1079)) <= 1)
    }

    @Test func cornersAreExcludedWhenRequested() {
        var detector = EdgeDetector(edge: .right, delay: 0, resistance: 0, cornerSize: 100)
        // Entro 100 punti dagli angoli il bordo non porta al PC, altrove sì.
        #expect(detector.update(position: CGPoint(x: 1919, y: 40), deltaX: 9, deltaY: 0, displays: single, now: 0) == nil)
        #expect(detector.update(position: CGPoint(x: 1919, y: 1030), deltaX: 9, deltaY: 0, displays: single, now: 1) == nil)
        #expect(detector.update(position: CGPoint(x: 1919, y: 540), deltaX: 9, deltaY: 0, displays: single, now: 2) != nil)
        var top = EdgeDetector(edge: .top, delay: 0, resistance: 0, cornerSize: 100)
        #expect(top.update(position: CGPoint(x: 1850, y: 0), deltaX: 0, deltaY: -9, displays: single, now: 0) == nil)
        #expect(top.update(position: CGPoint(x: 960, y: 0), deltaX: 0, deltaY: -9, displays: single, now: 1) != nil)
    }

    @Test func edgeModifierChecksFlags() {
        #expect(EdgeModifier.none.isSatisfied(by: []))
        #expect(!EdgeModifier.control.isSatisfied(by: []))
        #expect(EdgeModifier.control.isSatisfied(by: [.maskControl, .maskShift]))
        #expect(!EdgeModifier.command.isSatisfied(by: .maskAlternate))
        #expect(EdgeModifier.shift.isSatisfied(by: .maskShift))
    }

    @Test func testEntryAndReturnGeometry() {
        let right = EdgeDetector(edge: .right)
        #expect(right.entryPoint(fraction: 0.5).y == 32768)
        #expect(right.entryPoint(fraction: 0.5).x < 1000) // appena dentro il bordo sinistro del PC
        #expect(EdgeDetector(edge: .left).entryPoint(fraction: 0).x > 64000)

        #expect(abs((right.returnFraction(x: 65535, y: 16384)) - (0.25)) <= 0.001)
        let point = right.returnPoint(fraction: 0.25, on: single[0])
        #expect(abs((point.x) - (1915)) <= 0.01)
        #expect(abs((point.y) - (0.25 * 1079)) <= 0.01)
        // Il punto di ritorno non deve far ripartire subito il cambio.
        #expect(point.x < single[0].maxX - 2)

        let displays = [single[0], CGRect(x: 1920, y: 0, width: 1280, height: 720)]
        #expect(right.outermostDisplay(in: displays) == displays[1])
        #expect(EdgeDetector(edge: .left).outermostDisplay(in: displays) == displays[0])
    }
}

struct ClipboardImageTests {
    /// Immagine di prova nello spazio colore indicato, restituita come TIFF (ciò che
    /// molte applicazioni Mac mettono negli appunti).
    private func makeTIFF(width: Int, height: Int, space: CFString, bits: Int = 8) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: space))
        let info = bits == 16
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                             bytesPerRow: 0, space: colorSpace, bitmapInfo: info))
        context.setFillColor(red: 1, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    }

    private func decode(_ png: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func tiffBecomesAnEightBitSRGBPNG() throws {
        let tiff = try makeTIFF(width: 320, height: 200, space: CGColorSpace.displayP3, bits: 16)
        let png = try #require(ClipboardBridge.normalizedPNG(from: tiff))
        #expect(PNGData.isPNG([UInt8](png)))
        #expect(PNGData.sanitized([UInt8](png)) == [UInt8](png))
        let image = try decode(png)
        #expect(image.width == 320 && image.height == 200)
        #expect(image.bitsPerComponent == 8)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    /// Ciò che arriva dal PC: un PNG seguito da zeri, oppure con la coda mancante.
    @Test func receivedPNGWithPaddingOrMissingTailStillDecodes() throws {
        let tiff = try makeTIFF(width: 640, height: 480, space: CGColorSpace.sRGB)
        let original = [UInt8](try #require(ClipboardBridge.normalizedPNG(from: tiff)))

        let padded = original + [UInt8](repeating: 0, count: 4096 - original.count % 4096)
        let cleaned = try #require(PNGData.sanitized(padded))
        #expect(cleaned == original)

        for missing in [1, 7, 12, 15] {
            let repaired = try #require(PNGData.sanitized(Array(original.dropLast(missing))))
            let png = try #require(ClipboardBridge.normalizedPNG(from: Data(repaired), convertToSRGB: false),
                                   "mancano \(missing) byte")
            let image = try decode(png)
            #expect(image.width == 640 && image.height == 480)
        }
    }

    @Test func otherFormatsAndGarbage() throws {
        // JPEG (o qualunque formato noto al sistema) viene ricodificato in PNG.
        let tiff = try makeTIFF(width: 64, height: 64, space: CGColorSpace.sRGB)
        let jpeg = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        let png = try #require(ClipboardBridge.normalizedPNG(from: jpeg))
        #expect(PNGData.isPNG([UInt8](png)))

        #expect(ClipboardBridge.normalizedPNG(from: Data([1, 2, 3, 4, 5])) == nil)
        #expect(ClipboardBridge.normalizedPNG(from: Data()) == nil)
        #expect(ClipboardBridge.normalizedPNG(from: Data(repeating: 0, count: 5000)) == nil)
    }
}

struct SettingsTests {
    @Test func testDefaultsAndRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwbmac-test-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let created = try Settings.load(from: url)
        #expect(created.basePort == 15100)
        #expect(created.edge == .right)
        #expect(!(created.localName.isEmpty))
        #expect(!(created.localName.contains(".")))
        #expect(created.machineID != 0)
        #expect(created.machineID != 255)

        // Il MachineId resta stabile fra un avvio e l'altro.
        #expect(try Settings.load(from: url) == created)

        var changed = created
        changed.remoteHost = "winpc"
        changed.edge = .left
        changed.hotkey = Hotkey(keyCode: 0x7A, control: true, option: false, command: false, shift: true)
        try changed.save(to: url)
        #expect(try Settings.load(from: url) == changed)
    }

    @Test func newOptionsHaveMouseWithoutBordersDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"remoteHost": "pc"}"#.utf8))
        #expect(settings.keepOthersAwake)
        #expect(!settings.blockCorners)
        #expect(settings.disableInFullScreen)
        #expect(settings.edgeSwitchModifier == .none)
        #expect(settings.makeEdgeDetector().cornerSize == 0)
        var corners = settings
        corners.blockCorners = true
        corners.edgeSwitchModifier = .command
        #expect(corners.makeEdgeDetector().cornerSize == EdgeDetector.defaultCornerSize)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(corners))
        #expect(decoded == corners)
    }

    @Test func hotkeyNamesAreTranslatable() {
        let hotkey = Hotkey(keyCode: 0x31, control: true, option: false, command: true, shift: false)
        #expect(hotkey.description == "⌃⌘Space")
        #expect(hotkey.description(keyName: { $0 == "Space" ? "Spazio" : $0 }) == "⌃⌘Spazio")
    }

    @Test func testMissingKeysTakeDefaults() throws {
        let json = #"{"remoteHost": "pc", "machineID": 4242, "edge": "top", "edgeStart": 0.9, "edgeEnd": 0.1}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.remoteHost == "pc")
        #expect(settings.machineID == 4242)
        #expect(settings.edge == .top)
        #expect(settings.switchDelayMs == 150)
        #expect(settings.hotkey == Hotkey())
        // Porzione attiva incoerente: si usa tutto il bordo.
        #expect(settings.activeRange == 0...1)
        // La security key non fa parte delle preferenze.
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!saved.lowercased().contains("securitykey"))
    }
}

struct LockSyncTests {
    @Test func defaultSequenceMatchesPowerToysDefault() {
        let sequence = LockSync(shortcut: "Win+Ctrl+Alt+L").lockAllSequence()
        // Win, Ctrl, Alt, L giù; poi su in ordine inverso. Codici sinistri: `InputProcessKeyEx`
        // traccia VK_LWIN/VK_RWIN, VK_LCONTROL/VK_RCONTROL e VK_LMENU/VK_RMENU.
        #expect(sequence.map(\.vk) == [0x5B, 0xA2, 0xA4, 0x4C, 0x4C, 0xA4, 0xA2, 0x5B])
        #expect(sequence.map(\.flags) == [0x01, 0, 0, 0, 0x80, 0x80, 0x80, 0x81])
        #expect(LockSync(shortcut: "Ctrl+Alt+K").lockAllSequence().map(\.vk) == [0xA2, 0xA4, 0x4B, 0x4B, 0xA4, 0xA2])
    }

    @Test func shortcutIsParsedAndNormalized() {
        #expect(LockShortcut(parsing: " win + CTRL+alt+l ")?.description == "Win+Ctrl+Alt+L")
        #expect(LockShortcut(parsing: "Shift+Control+7")?.description == "Ctrl+Shift+7")
        #expect(LockShortcut(parsing: "Ctrl+Alt+k")?.keyVK == 0x4B)
        for invalid in ["", "L", "Ctrl+", "Ctrl+LL", "Ctrl+é", "Ctrl+ß", "Cmd+L", "Ctrl+Alt+€", "+L"] {
            #expect(LockShortcut(parsing: invalid) == nil, "\(invalid)")
        }
        #expect(LockSync(shortcut: "boh").shortcut == .powerToysDefault)
        #expect(Settings().lockAllShortcut == "Win+Ctrl+Alt+L")
    }

    @Test func detectsOutgoingLockCombos() {
        let sync = LockSync(shortcut: "Ctrl+Alt+K")
        let win = [WindowsKey(VK.lWin, extended: true)]
        let ctrlAlt = [WindowsKey(VK.lControl), WindowsKey(VK.lMenu)]
        // Win+L blocca sempre il PC, qualunque sia la scorciatoia impostata.
        #expect(sync.locksPC(sending: 0x4C, pressed: win))
        #expect(sync.locksPC(sending: 0x4B, pressed: ctrlAlt))
        // Modificatori in più non impediscono il blocco (`HotkeyMatched`).
        #expect(sync.locksPC(sending: 0x4B, pressed: ctrlAlt + [WindowsKey(VK.lShift)]))
        #expect(!sync.locksPC(sending: 0x4C, pressed: ctrlAlt))
        #expect(!sync.locksPC(sending: 0x4B, pressed: [WindowsKey(VK.lControl)]))
        #expect(!sync.locksPC(sending: 0x4C, pressed: []))
        #expect(!sync.locksPC(sending: 0x4B, pressed: win))

        let standard = LockSync(shortcut: "Win+Ctrl+Alt+L")
        #expect(!standard.locksPC(sending: 0x4B, pressed: win + ctrlAlt))
    }

    /// Ciò che invia il PC quando si preme due volte la scorciatoia (`InputHook.ProcessHotKeys`
    /// con `GetVkCodesList`): VK_MENU, VK_LWIN, VK_CONTROL e il tasto giù, poi gli stessi su.
    @Test func recognizesTheSequenceSentByPowerToys() {
        var sync = LockSync(shortcut: "Win+Ctrl+Alt+L")
        let down: [Int32] = [0x12, 0x5B, 0x11, 0x4C]
        var fired: [Bool] = []
        for vk in down { fired.append(sync.observeIncoming(vk: vk, flags: 0, now: 10)) }
        for vk in down { fired.append(sync.observeIncoming(vk: vk, flags: 0x80, now: 10)) }
        #expect(fired == [false, false, false, true, false, false, false, false])
        // Ripetuta più tardi, scatta di nuovo.
        var again: [Bool] = []
        for vk in down { again.append(sync.observeIncoming(vk: vk, flags: 0, now: 20)) }
        #expect(again == [false, false, false, true])
    }

    @Test func doesNotFireOnPartialOrStaleModifiers() {
        var sync = LockSync(shortcut: "Win+Ctrl+Alt+L")
        // Manca Win.
        _ = sync.observeIncoming(vk: 0xA2, flags: 0, now: 0)
        _ = sync.observeIncoming(vk: 0xA4, flags: 0, now: 0)
        let fired1 = sync.observeIncoming(vk: 0x4C, flags: 0, now: 0.1)
        #expect(!fired1)
        // Win premuto e rilasciato prima del tasto.
        _ = sync.observeIncoming(vk: 0x5B, flags: 0, now: 0.2)
        _ = sync.observeIncoming(vk: 0x5B, flags: 0x80, now: 0.3)
        let fired2 = sync.observeIncoming(vk: 0x4C, flags: 0, now: 0.4)
        #expect(!fired2)
        // Modificatori premuti e rilascio perso: dopo la pausa non contano più.
        for vk: Int32 in [0x5B, 0xA2, 0xA4] { _ = sync.observeIncoming(vk: vk, flags: 0, now: 1) }
        let fired3 = sync.observeIncoming(vk: 0x4C, flags: 0, now: 10)
        #expect(!fired3)
        // Altro tasto.
        for vk: Int32 in [0x5B, 0xA2, 0xA4] { _ = sync.observeIncoming(vk: vk, flags: 0, now: 20) }
        let fired4 = sync.observeIncoming(vk: 0x4B, flags: 0, now: 20)
        #expect(!fired4)
    }
}
