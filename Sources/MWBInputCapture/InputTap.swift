// CGEventTap a livello HID (`kCGHIDEventTap`) in modalità attiva: in stato locale
// osserva soltanto, in stato remoto il gestore restituisce `.suppress` e l'evento non
// raggiunge il window server. Richiede il permesso Accessibilità (TCC).

import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public enum InputTapError: Error, CustomStringConvertible {
    case creationFailed

    public var description: String {
        "impossibile creare il tap degli eventi: manca il permesso Accessibilità "
            + "(Impostazioni di Sistema → Privacy e sicurezza → Accessibilità) per l'app che lancia mwbmac"
    }
}

public final class InputTap {
    public enum Disposition {
        case pass
        case suppress
    }

    /// Chiamato sul thread del run loop che ospita il tap (quello principale).
    public var handler: ((CGEventType, CGEvent) -> Disposition)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { port != nil }

    public func start() throws {
        guard port == nil else { return }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.dispatch(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw InputTapError.creationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disabilita il tap se il gestore è lento o su richiesta dell'utente:
        // va riattivato subito, altrimenti in stato remoto l'input tornerebbe al Mac.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        switch handler?(type, event) ?? .pass {
        case .pass: return Unmanaged.passUnretained(event)
        case .suppress: return nil
        }
    }
}

/// Permessi TCC necessari al tap e allo spostamento del cursore.
public enum InputPermissions {
    public static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public static func hasInputMonitoring(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return prompt ? CGRequestListenEventAccess() : false
    }
}

/// Stato del cursore locale durante il controllo remoto.
public enum LocalCursor {
    /// Sgancia il cursore dal mouse: gli eventi continuano a portare i delta, ma il
    /// cursore del Mac resta fermo dov'è.
    public static func lock() {
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    public static func unlock(at point: CGPoint? = nil) {
        if let point { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public static var position: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Rettangoli dei display attivi nello spazio globale di CoreGraphics
    /// (origine in alto a sinistra dello schermo principale), lo stesso di `CGEvent.location`.
    public static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// Tipo fisico della tastiera collegata (ISO/ANSI), per la mappa dei tasti.
public enum PhysicalKeyboard {
    public static var isISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }
}
