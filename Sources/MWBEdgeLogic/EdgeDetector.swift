// Rilevamento del bordo verso il PC, con ritardo di spostamento e resistenza.
// Logica pura sui rettangoli dei display (spazio globale CoreGraphics, origine in alto
// a sinistra), testabile senza hardware.

import CoreGraphics
import Foundation

public enum ScreenEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    var isVertical: Bool { self == .left || self == .right }
}

/// Modificatore da tenere premuto perché il bordo porti al PC.
public enum EdgeModifier: String, Codable, Sendable, CaseIterable {
    case none, control, option, command, shift

    /// Vero se i modificatori premuti soddisfano la richiesta.
    public func isSatisfied(by flags: CGEventFlags) -> Bool {
        switch self {
        case .none: return true
        case .control: return flags.contains(.maskControl)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        case .shift: return flags.contains(.maskShift)
        }
    }
}

public struct EdgeDetector: Sendable {
    public var edge: ScreenEdge
    /// Tempo minimo di spinta continua contro il bordo prima del cambio.
    public var delay: TimeInterval
    /// Pixel di spinta oltre il bordo da accumulare prima del cambio.
    public var resistance: Double
    /// Porzione attiva del bordo (0…1), per schermi non allineati.
    public var activeRange: ClosedRange<Double>
    /// Lato in punti della zona d'angolo esclusa, lungo il bordo (0 = nessuna esclusione).
    public var cornerSize: Double

    /// Come Mouse Without Borders: 100 pixel attorno a ogni angolo dei display.
    public static let defaultCornerSize = 100.0

    /// Dopo questa pausa senza eventi sul bordo la spinta riparte da zero.
    static let pushTimeout: TimeInterval = 0.3
    /// Spinta minima anche con resistenza zero: un cursore fermo sul bordo non cambia macchina.
    static let minimumPush = 1.0

    private var pushStart: TimeInterval?
    private var lastPush: TimeInterval = 0
    private var pushed = 0.0
    private var armed = true

    public init(edge: ScreenEdge, delay: TimeInterval = 0.15, resistance: Double = 30,
                activeRange: ClosedRange<Double> = 0...1, cornerSize: Double = 0) {
        self.edge = edge
        self.delay = delay
        self.resistance = resistance
        self.activeRange = activeRange
        self.cornerSize = cornerSize
    }

    /// Dopo un ritorno dal PC il cursore riappare a ridosso del bordo: finché non se ne
    /// allontana il rilevamento resta disarmato, per evitare rimbalzi.
    public mutating func disarm() {
        armed = false
        clearPush()
    }

    /// Da chiamare a ogni movimento del mouse in stato locale. Restituisce la posizione
    /// lungo il bordo (0…1 entro la porzione attiva) quando è il momento di passare al PC.
    public mutating func update(position: CGPoint, deltaX: Double, deltaY: Double,
                                displays: [CGRect], now: TimeInterval) -> Double? {
        guard let display = EdgeDetector.display(containing: position, in: displays),
              EdgeDetector.isOuterEdge(edge, of: display, at: position, in: displays),
              isAtEdge(position, of: display) else {
            armed = true
            clearPush()
            return nil
        }
        guard armed else { return nil }

        let fraction = edge.isVertical
            ? (position.y - display.minY) / max(display.height, 1)
            : (position.x - display.minX) / max(display.width, 1)
        guard activeRange.contains(fraction), !isInCorner(position, of: display) else {
            clearPush()
            return nil
        }

        let push: Double
        switch edge {
        case .left: push = -deltaX
        case .right: push = deltaX
        case .top: push = -deltaY
        case .bottom: push = deltaY
        }
        if push < 0 {
            // Movimento in allontanamento: si ricomincia.
            clearPush()
            return nil
        }
        if push == 0 { return nil }

        if pushStart == nil || now - lastPush > EdgeDetector.pushTimeout {
            pushStart = now
            pushed = 0
        }
        lastPush = now
        pushed += push

        guard let start = pushStart, now - start >= delay,
              pushed >= max(resistance, EdgeDetector.minimumPush) else { return nil }
        clearPush()
        let span = activeRange.upperBound - activeRange.lowerBound
        return span > 0 ? min(max((fraction - activeRange.lowerBound) / span, 0), 1) : 0.5
    }

    private mutating func clearPush() {
        pushStart = nil
        pushed = 0
    }

    /// Vero se il punto, lungo il bordo, è a meno di `cornerSize` da un angolo del display.
    private func isInCorner(_ p: CGPoint, of display: CGRect) -> Bool {
        guard cornerSize > 0 else { return false }
        let distance = edge.isVertical
            ? min(p.y - display.minY, display.maxY - 1 - p.y)
            : min(p.x - display.minX, display.maxX - 1 - p.x)
        return distance < cornerSize
    }

    private func isAtEdge(_ p: CGPoint, of display: CGRect) -> Bool {
        // Il cursore si ferma sull'ultimo pixel: maxX − 1 (anche frazionario).
        switch edge {
        case .left: return p.x <= display.minX + 1
        case .right: return p.x >= display.maxX - 2
        case .top: return p.y <= display.minY + 1
        case .bottom: return p.y >= display.maxY - 2
        }
    }

    // MARK: Geometria

    static func display(containing point: CGPoint, in displays: [CGRect]) -> CGRect? {
        if let exact = displays.first(where: { $0.contains(point) }) { return exact }
        // Sul bordo destro/inferiore il punto può cadere appena fuori dal rettangolo.
        return displays.first { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Vero se oltre quel bordo del display, all'altezza del cursore, non c'è un altro display.
    static func isOuterEdge(_ edge: ScreenEdge, of display: CGRect, at point: CGPoint, in displays: [CGRect]) -> Bool {
        let probe: CGPoint
        switch edge {
        case .left: probe = CGPoint(x: display.minX - 2, y: point.y)
        case .right: probe = CGPoint(x: display.maxX + 1, y: point.y)
        case .top: probe = CGPoint(x: point.x, y: display.minY - 2)
        case .bottom: probe = CGPoint(x: point.x, y: display.maxY + 1)
        }
        return !displays.contains { $0 != display && $0.contains(probe) }
    }

    /// Punto in cui far riapparire il cursore al ritorno dal PC: a ridosso del bordo,
    /// alla posizione `fraction` (0…1) lungo la porzione attiva.
    public func returnPoint(fraction: Double, on display: CGRect, inset: Double = 4) -> CGPoint {
        let clamped = min(max(fraction, 0), 1)
        let along = activeRange.lowerBound + clamped * (activeRange.upperBound - activeRange.lowerBound)
        switch edge {
        case .left:
            return CGPoint(x: display.minX + inset, y: display.minY + along * (display.height - 1))
        case .right:
            return CGPoint(x: display.maxX - 1 - inset, y: display.minY + along * (display.height - 1))
        case .top:
            return CGPoint(x: display.minX + along * (display.width - 1), y: display.minY + inset)
        case .bottom:
            return CGPoint(x: display.minX + along * (display.width - 1), y: display.maxY - 1 - inset)
        }
    }

    /// Display il cui bordo configurato è quello più esterno del desktop (usato quando
    /// non si sa da quale display si era usciti).
    public func outermostDisplay(in displays: [CGRect]) -> CGRect? {
        switch edge {
        case .left: return displays.min { $0.minX < $1.minX }
        case .right: return displays.max { $0.maxX < $1.maxX }
        case .top: return displays.min { $0.minY < $1.minY }
        case .bottom: return displays.max { $0.maxY < $1.maxY }
        }
    }

    /// Coordinate assolute MWB (0…65535 sul desktop del PC) del punto d'ingresso:
    /// appena dentro il bordo opposto a quello da cui si esce dal Mac.
    public func entryPoint(fraction: Double, inset: Int32 = 400) -> (x: Int32, y: Int32) {
        let along = Int32((min(max(fraction, 0), 1) * 65535).rounded())
        switch edge {
        case .right: return (inset, along)
        case .left: return (65535 - inset, along)
        case .bottom: return (along, inset)
        case .top: return (along, 65535 - inset)
        }
    }

    /// Posizione lungo il bordo (0…1) ricavata dalle coordinate universali di `NextMachine`.
    public func returnFraction(x: Int32, y: Int32) -> Double {
        let value = edge.isVertical ? y : x
        return min(max(Double(value) / 65535, 0), 1)
    }
}
