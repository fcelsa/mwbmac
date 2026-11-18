// CGEventTap a livello HID (`kCGHIDEventTap`) in modalità attiva: in stato locale
// osserva soltanto, in stato remoto il gestore restituisce `.suppress` e l'evento non
// raggiunge il window server. Richiede il permesso Accessibilità (TCC).

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

public enum InputTapError: Error, CustomStringConvertible {
    case creationFailed

    public var description: String {
        "cannot create the event tap: the Accessibility permission is missing "
            + "(System Settings → Privacy & Security → Accessibility) for the app that launches mwbmac"
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

/// Cursore locale durante il controllo remoto.
///
/// Sopprimere gli eventi nel tap non ferma il cursore: il window server lo muove comunque.
/// Le funzioni documentate per bloccarlo e nasconderlo
/// (`CGAssociateMouseAndMouseCursorPosition`, `CGDisplayHideCursor`) valgono solo per
/// l'applicazione in primo piano, quindi per la durata del controllo remoto l'app si porta
/// in primo piano (non ha finestre: a schermo non cambia nulla) e al ritorno restituisce
/// il primo piano all'applicazione che lo aveva. È lo stesso meccanismo dei giochi in
/// "modo relativo": cursore fermo e invisibile, delta degli eventi intatti.
/// Riportare il cursore in un punto a ogni evento (alla Synergy) è stato provato e scartato:
/// il riposizionamento arriva in ritardo rispetto agli eventi e ne falsa i delta.
/// Tutto sul thread principale.
public enum LocalCursor {
    private static var isCaptured = false
    private static var isHidden = false
    private static var previousApplication: NSRunningApplication?
    private static var observers: [NSObjectProtocol] = []

    /// Nasconde e blocca il cursore. `completion` riceve `true` se l'app è davvero passata
    /// in primo piano (senza, il cursore resta visibile e libero, ma il controllo funziona).
    public static func capture(completion: ((Bool) -> Void)? = nil) {
        guard !isCaptured else { return }
        isCaptured = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        installObservers()
        NSApplication.shared.activate(ignoringOtherApps: true)
        apply()
        // L'attivazione è asincrona: si riapplica quando arriva e si verifica l'esito.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard isCaptured else { return }
            apply()
            completion?(NSApplication.shared.isActive)
        }
    }

    /// Ripristina cursore e applicazione in primo piano; `point` è dove far riapparire il cursore.
    public static func release(at point: CGPoint? = nil) {
        guard isCaptured else {
            if let point { CGWarpMouseCursorPosition(point) }
            return
        }
        isCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        if let point { CGWarpMouseCursorPosition(point) }
        // Dopo un riposizionamento il sistema congela il mouse per 250 ms: lo si riaggancia subito.
        CGAssociateMouseAndMouseCursorPosition(1)
        if isHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            isHidden = false
        }
        previousApplication?.activate(options: [])
        previousApplication = nil
    }

    private static func apply() {
        CGAssociateMouseAndMouseCursorPosition(0)
        if !isHidden {
            CGDisplayHideCursor(CGMainDisplayID())
            isHidden = true
        }
    }

    private static func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if isCaptured { apply() }
        })
        // Se un'altra app si prende il primo piano durante il controllo remoto, lo si riprende.
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            guard isCaptured else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if isCaptured { NSApplication.shared.activate(ignoringOtherApps: true) }
            }
        })
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

/// Blocco dello schermo del Mac. Non esiste un'API pubblica per bloccare lo schermo:
/// si invia la scorciatoia di sistema ⌃⌘Q come evento sintetico (lo stesso che fa
/// "System Events" con `keystroke "q" using {control down, command down}`). Gli eventi
/// sono marcati, così il tap dell'app li lascia passare senza interpretarli.
public enum SystemLock {
    /// Valore di `eventSourceUserData` degli eventi generati qui ("MWBL").
    public static let eventMarker: Int64 = 0x4D57_424C
    /// Keycode macOS del tasto Q.
    public static let qKeyCode: UInt16 = 0x0C

    /// Vero se l'evento è la scorciatoia di blocco del Mac (⌃⌘Q, senza ⌥ né ⇧).
    public static func isLockShortcut(_ event: CGEvent) -> Bool {
        guard UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) == qKeyCode else {
            return false
        }
        let flags = event.flags
        return flags.contains(.maskControl) && flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
    }

    public static func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == eventMarker
    }

    /// Blocca lo schermo del Mac.
    public static func lockScreen() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: isDown) else { continue }
            event.flags = [.maskControl, .maskCommand]
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
