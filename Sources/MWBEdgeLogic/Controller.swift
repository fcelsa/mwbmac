// Macchina di stato locale/remoto: decide quando passare al PC e quando tornare.
// Fonte per la sequenza: PowerToys `Event.PrepareToSwitchToMachine`, `Receiver.cs`
// (rami `Mouse` e `NextMachine`), docs/analisi.md §2.4.
//
// Stato locale: il tap osserva la posizione del cursore per il rilevamento del bordo.
// Stato remoto: il tap sopprime tutto l'input, il cursore del Mac è bloccato e gli
// eventi vengono inviati al PC (mouse relativo, click, rotella, tasti).
// Tutto lo stato è confinato al thread principale.

import CoreGraphics
import Foundation
import MWBInputCapture
import MWBProtocol
import MWBTransport

public final class Controller {
    public enum State: Equatable {
        case local
        case remote(Session.Machine)
    }

    public private(set) var state: State = .local
    /// Notifica i cambi di stato (thread principale), per log o interfaccia.
    public var onStateChange: ((State) -> Void)?

    private let settings: Settings
    private let session: Session
    private let log: Log
    private let tap = InputTap()
    private var detector: EdgeDetector
    private var translator: InputTranslator

    private var displays: [CGRect] = []
    private var displaysRefreshed: TimeInterval = 0
    /// Display e posizione da cui si è usciti verso il PC.
    private var exitDisplay: CGRect?
    private var exitPosition: CGPoint?
    private var enteredRemoteAt: TimeInterval = 0

    /// Subito dopo l'ingresso un `NextMachine` è quasi certamente un rimbalzo.
    private static let bounceGuard: TimeInterval = 0.25

    public init(settings: Settings, session: Session, log: Log) {
        self.settings = settings
        self.session = session
        self.log = log
        self.detector = settings.makeEdgeDetector()
        self.translator = InputTranslator(keyMap: settings.makeKeyMap(isISOKeyboard: PhysicalKeyboard.isISO),
                                          invertScroll: settings.invertScroll)
    }

    /// Da chiamare sul thread principale.
    public func start() throws {
        session.onPacket = { [weak self] packet in
            DispatchQueue.main.async { self?.received(packet) }
        }
        session.onMachineDisconnected = { [weak self] machine in
            DispatchQueue.main.async { self?.machineDisconnected(machine) }
        }
        tap.handler = { [weak self] type, event in
            self?.handle(type: type, event: event) ?? .pass
        }
        try tap.start()
    }

    /// Riporta l'input al Mac e smonta il tap. Da chiamare prima di uscire.
    public func stop() {
        returnToLocal(reason: "arresto", at: exitPosition)
        tap.stop()
    }

    // MARK: Eventi di input

    private func handle(type: CGEventType, event: CGEvent) -> InputTap.Disposition {
        // La scorciatoia di emergenza ha la precedenza su tutto e non dipende dalla rete.
        if type == .keyDown, isHotkey(event) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { toggle() }
            return .suppress
        }
        switch state {
        case .local:
            if type == .mouseMoved { observeEdge(event) }
            return .pass
        case .remote(let machine):
            forward(type: type, event: event, to: machine)
            return .suppress
        }
    }

    private func isHotkey(_ event: CGEvent) -> Bool {
        let hotkey = settings.hotkey
        guard UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) == hotkey.keyCode else {
            return false
        }
        let flags = event.flags
        return flags.contains(.maskControl) == hotkey.control
            && flags.contains(.maskAlternate) == hotkey.option
            && flags.contains(.maskCommand) == hotkey.command
            && flags.contains(.maskShift) == hotkey.shift
    }

    private func toggle() {
        switch state {
        case .local:
            let position = LocalCursor.position
            refreshDisplays(force: true)
            exitDisplay = displays.first { $0.contains(position) }
            enterRemote(fraction: 0.5, from: position, viaHotkey: true)
        case .remote:
            // Emergenza: il cursore torna dov'era prima di passare al PC.
            returnToLocal(reason: "scorciatoia \(settings.hotkey.description)", at: exitPosition)
        }
    }

    private func observeEdge(_ event: CGEvent) {
        refreshDisplays(force: false)
        let position = event.location
        let now = ProcessInfo.processInfo.systemUptime
        guard let fraction = detector.update(position: position,
                                             deltaX: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                                             deltaY: Double(event.getIntegerValueField(.mouseEventDeltaY)),
                                             displays: displays, now: now) else { return }
        exitDisplay = displays.first { $0.insetBy(dx: -1, dy: -1).contains(position) }
        enterRemote(fraction: fraction, from: position, viaHotkey: false)
    }

    private func refreshDisplays(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || displays.isEmpty || now - displaysRefreshed > 2 else { return }
        displays = LocalCursor.displayBounds()
        displaysRefreshed = now
    }

    // MARK: Cambio macchina

    /// Il PC di destinazione: quello il cui nome corrisponde a `remoteHost`, altrimenti
    /// la prima macchina connessa.
    private func targetMachine() -> Session.Machine? {
        let machines = session.connectedMachines
        let wanted = settings.remoteHost.split(separator: ".").first.map { $0.lowercased() } ?? ""
        return machines.first { $0.name.lowercased() == wanted } ?? machines.first
    }

    private func enterRemote(fraction: Double, from position: CGPoint, viaHotkey: Bool) {
        guard case .local = state else { return }
        guard let machine = targetMachine() else {
            if viaHotkey { log.info("Nessun PC connesso: resto sul Mac") }
            return
        }
        exitPosition = position
        enteredRemoteAt = ProcessInfo.processInfo.systemUptime
        state = .remote(machine)
        LocalCursor.lock()

        // `PrepareToSwitchToMachine`: MachineSwitched alla nuova destinazione, poi il
        // cursore del PC viene portato nel punto d'ingresso con un movimento assoluto.
        session.send(Packet(type: .machineSwitched, des: machine.id))
        if !viaHotkey {
            let entry = detector.entryPoint(fraction: fraction)
            sendMouse(translator.mouseMoveAbsolute(x: entry.x, y: entry.y), to: machine)
        }
        log.info("→ controllo passato a \"\(machine.name)\" (ritorno di emergenza: \(settings.hotkey.description))")
        onStateChange?(state)
    }

    private func returnToLocal(reason: String, at point: CGPoint?) {
        guard case .remote(let machine) = state else { return }
        state = .local
        // Niente tasti o pulsanti incastrati sul PC; HideMouse fa anche rilasciare
        // tutti i tasti a PowerToys (`Receiver.cs`, ramo `HideMouse`).
        let released = translator.releaseAll()
        released.buttons.forEach { sendMouse($0, to: machine) }
        released.keys.forEach { sendKey($0, to: machine) }
        session.send(Packet(type: .hideMouse, des: machine.id))

        LocalCursor.unlock(at: point)
        detector.disarm()
        log.info("← controllo tornato al Mac (\(reason))")
        onStateChange?(state)
    }

    // MARK: Inoltro al PC

    private func forward(type: CGEventType, event: CGEvent, to machine: Session.Machine) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 { sendMouse(translator.mouseMove(dx: dx, dy: dy), to: machine) }
        case .leftMouseDown: button(0, .down, machine)
        case .leftMouseUp: button(0, .up, machine)
        case .rightMouseDown: button(1, .down, machine)
        case .rightMouseUp: button(1, .up, machine)
        case .otherMouseDown:
            button(Int(event.getIntegerValueField(.mouseEventButtonNumber)), .down, machine)
        case .otherMouseUp:
            button(Int(event.getIntegerValueField(.mouseEventButtonNumber)), .up, machine)
        case .scrollWheel:
            let packets = translator.scroll(
                verticalLines: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                horizontalLines: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                verticalPixels: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                horizontalPixels: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0)
            packets.forEach { sendMouse($0, to: machine) }
        case .keyDown, .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let data = translator.key(macKeyCode: code, isDown: type == .keyDown) { sendKey(data, to: machine) }
        case .flagsChanged:
            modifierChanged(event, machine)
        default:
            break
        }
    }

    private func button(_ number: Int, _ action: MouseButtonAction, _ machine: Session.Machine) {
        if let data = translator.mouseButton(number, action) { sendMouse(data, to: machine) }
    }

    /// I modificatori arrivano come `flagsChanged`: il keycode dice quale tasto, i bit
    /// dipendenti dal dispositivo (NX_DEVICE*KEYMASK) dicono se è premuto.
    private func modifierChanged(_ event: CGEvent, _ machine: Session.Machine) {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if code == MacKey.capsLock {
            translator.capsLockTap().forEach { sendKey($0, to: machine) }
            return
        }
        let deviceMask: UInt64
        switch code {
        case MacKey.control: deviceMask = 0x0001
        case MacKey.shift: deviceMask = 0x0002
        case MacKey.rightShift: deviceMask = 0x0004
        case MacKey.command: deviceMask = 0x0008
        case MacKey.rightCommand: deviceMask = 0x0010
        case MacKey.option: deviceMask = 0x0020
        case MacKey.rightOption: deviceMask = 0x0040
        case MacKey.rightControl: deviceMask = 0x2000
        default: return
        }
        let isDown = event.flags.rawValue & deviceMask != 0
        if let data = translator.key(macKeyCode: code, isDown: isDown) { sendKey(data, to: machine) }
    }

    private func sendMouse(_ data: MouseData, to machine: Session.Machine) {
        var packet = Packet(type: .mouse, des: machine.id)
        packet.mouse = data
        session.send(packet)
    }

    private func sendKey(_ data: KeyboardData, to machine: Session.Machine) {
        var packet = Packet(type: .keyboard, des: machine.id)
        var keyboard = data
        // `Event.KeybdEvent`: DateTime = tick in millisecondi.
        keyboard.dateTime = Int64(Date().timeIntervalSince1970 * 1000)
        packet.keyboard = keyboard
        session.send(packet)
    }

    // MARK: Pacchetti dal PC

    private func received(_ packet: Packet) {
        guard case .remote(let machine) = state, packet.src == machine.id else { return }
        switch packet.type {
        case .nextMachine:
            // È Windows a decidere il ritorno: il cursore iniettato ha superato il suo
            // bordo verso il Mac (`MoveToMyNeighbourIfNeeded`). X/Y sono 0…65535.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - enteredRemoteAt > Controller.bounceGuard else { return }
            refreshDisplays(force: true)
            let fraction = detector.returnFraction(x: packet.mouse.x, y: packet.mouse.y)
            let display = exitDisplay.flatMap { displays.contains($0) ? $0 : nil } ?? detector.outermostDisplay(in: displays)
            let point = display.map { detector.returnPoint(fraction: fraction, on: $0) } ?? exitPosition
            returnToLocal(reason: "NextMachine da \"\(machine.name)\"", at: point)
        case .byeBye:
            returnToLocal(reason: "\"\(machine.name)\" ha chiuso la sessione", at: exitPosition)
        default:
            break
        }
    }

    private func machineDisconnected(_ machine: Session.Machine) {
        guard case .remote(let current) = state, current.id == machine.id else { return }
        // Se il PC cade mentre si è in stato remoto l'input del Mac è soppresso:
        // si torna subito in locale.
        returnToLocal(reason: "connessione persa", at: exitPosition)
    }
}
