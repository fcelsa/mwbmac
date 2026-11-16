import Testing
import Foundation
import CoreGraphics
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
