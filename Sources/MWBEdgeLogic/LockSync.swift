// Blocco schermo sincronizzato, sulla funzione documentata di Mouse Without Borders
// "Shortcut to lock all machines": la scorciatoia premuta due volte sulla macchina che ha
// tastiera e mouse blocca tutte le macchine che hanno la stessa impostazione.
// In PowerToys la scorciatoia è configurabile e la predefinita è Win+Ctrl+Alt+L
// (`MouseWithoutBordersProperties.DefaultHotKeyLockMachine`); la vecchia documentazione
// del Mouse Without Borders originale parla invece di Ctrl+Alt+lettera.
// Fonte: PowerToys `InputHook.ProcessHotKeys` (chi invia) e
// `InputSimulation.InputProcessKeyEx` + `Common.HotkeyMatched` (chi riceve).
//
// Sul filo non esiste un pacchetto "blocca": chi invia trasmette a tutte le macchine
// (destinazione ALL) la pressione e il rilascio dei tasti della scorciatoia, e chi li
// riceve, riconosciuta la propria scorciatoia, chiama `LockWorkStation`. Il confronto
// richiede che i modificatori della scorciatoia siano premuti e ne tollera altri in più.
// Inoltre il PC che riceve Win+L si blocca sempre (ramo `'L'` di `InputProcessKeyEx`).
//
// Logica pura, senza dipendenze da AppKit, per poterla testare.

import Foundation
import MWBInputCapture
import MWBProtocol

/// Scorciatoia "blocca tutte le macchine": modificatori Windows più un tasto A–Z o 0–9.
public struct LockShortcut: Equatable, Sendable, CustomStringConvertible {
    public var win: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    /// Virtual-key Windows del tasto (A–Z e 0–9 coincidono con il codice ASCII).
    public var keyVK: Int32

    /// Predefinita di PowerToys: Win+Ctrl+Alt+L.
    public static let powerToysDefault = LockShortcut(win: true, ctrl: true, alt: true, shift: false,
                                                      keyVK: Int32(UInt8(ascii: "L")))

    public init(win: Bool, ctrl: Bool, alt: Bool, shift: Bool, keyVK: Int32) {
        self.win = win
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.keyVK = keyVK
    }

    /// Legge una forma come "Win+Ctrl+Alt+L" (maiuscole indifferenti, spazi ammessi).
    /// Restituisce `nil` se manca un modificatore, se il tasto non è A–Z/0–9 o se c'è
    /// qualcosa di non riconosciuto.
    public init?(parsing text: String) {
        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count >= 2, let last = parts.last, last.count == 1,
              let scalar = last.unicodeScalars.first, scalar.isASCII,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        var shortcut = LockShortcut(win: false, ctrl: false, alt: false, shift: false,
                                    keyVK: Int32(UInt8(ascii: Character(scalar).uppercased().unicodeScalars.first!)))
        for part in parts.dropLast() {
            switch part {
            case "win", "windows": shortcut.win = true
            case "ctrl", "control": shortcut.ctrl = true
            case "alt": shortcut.alt = true
            case "shift": shortcut.shift = true
            default: return nil
            }
        }
        self = shortcut
    }

    public var description: String {
        var parts: [String] = []
        if win { parts.append("Win") }
        if ctrl { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(String(UnicodeScalar(UInt8(truncatingIfNeeded: keyVK))))
        return parts.joined(separator: "+")
    }

    /// Codici dei modificatori da premere, nell'ordine di invio.
    var modifierVKs: [Int32] {
        var keys: [Int32] = []
        if win { keys.append(VK.lWin) }
        if ctrl { keys.append(VK.lControl) }
        if alt { keys.append(VK.lMenu) }
        if shift { keys.append(VK.lShift) }
        return keys
    }

    /// Come `Common.HotkeyMatched`: i modificatori richiesti devono essere premuti, quelli
    /// in più non contano.
    func matches(vk: Int32, win: Bool, ctrl: Bool, alt: Bool, shift: Bool) -> Bool {
        vk == keyVK && (!self.win || win) && (!self.ctrl || ctrl) && (!self.alt || alt) && (!self.shift || shift)
    }
}

public struct LockSync: Sendable {
    /// Scorciatoia "blocca tutte le macchine", uguale a quella impostata nel Mouse Without
    /// Borders del PC.
    public let shortcut: LockShortcut

    private var winDown = false
    private var ctrlDown = false
    private var altDown = false
    private var shiftDown = false
    private var lastIncoming: Double = -1_000

    /// Oltre questa pausa fra due tasti ricevuti i modificatori tracciati si azzerano:
    /// un rilascio perso non deve lasciarli "premuti" per sempre.
    static let modifierTimeout = 3.0

    /// Una forma non valida ripiega sulla predefinita di PowerToys, Win+Ctrl+Alt+L.
    public init(shortcut text: String) {
        self.shortcut = LockShortcut(parsing: text) ?? .powerToysDefault
    }

    /// Tasti da inviare a tutte le macchine: modificatori e tasto premuti, poi rilasciati
    /// in ordine inverso. Si usano i codici "sinistri" (VK_LWIN, VK_LCONTROL, VK_LMENU,
    /// VK_LSHIFT) perché sono quelli che `InputProcessKeyEx` traccia.
    public func lockAllSequence() -> [KeyboardData] {
        let keys = shortcut.modifierVKs + [shortcut.keyVK]
        func flags(_ vk: Int32) -> Int32 { vk == VK.lWin ? LLKHF.extended : 0 }
        return keys.map { KeyboardData(vk: $0, flags: flags($0)) }
            + keys.reversed().map { KeyboardData(vk: $0, flags: flags($0) | LLKHF.up) }
    }

    /// Vero se il tasto che sta per essere inviato al PC lo bloccherà: Win+L (sempre, sul
    /// PC) oppure la scorciatoia "blocca tutte le macchine". `pressed` sono i tasti Windows
    /// già premuti.
    public func locksPC(sending vk: Int32, pressed: [WindowsKey]) -> Bool {
        let codes = Set(pressed.map(\.vk))
        let win = codes.contains(VK.lWin) || codes.contains(VK.rWin)
        let ctrl = codes.contains(VK.lControl) || codes.contains(VK.rControl)
        let alt = codes.contains(VK.lMenu) || codes.contains(VK.rMenu)
        let shift = codes.contains(VK.lShift) || codes.contains(VK.rShift)
        return (vk == Int32(UInt8(ascii: "L")) && win)
            || shortcut.matches(vk: vk, win: win, ctrl: ctrl, alt: alt, shift: shift)
    }

    /// Da chiamare per ogni tasto ricevuto da un'altra macchina e destinato al Mac.
    /// Restituisce `true` quando arriva la scorciatoia "blocca tutte le macchine".
    /// Il PC che la invia usa i codici generici (VK_CONTROL, VK_MENU, VK_SHIFT) e VK_LWIN:
    /// si accettano generici, destri e sinistri.
    public mutating func observeIncoming(vk: Int32, flags: Int32, now: Double) -> Bool {
        if now - lastIncoming > LockSync.modifierTimeout {
            winDown = false
            ctrlDown = false
            altDown = false
            shiftDown = false
        }
        lastIncoming = now
        let isUp = flags & LLKHF.up != 0
        switch vk {
        case VK.lWin, VK.rWin:
            winDown = !isUp
        case 0x11, VK.lControl, VK.rControl:
            ctrlDown = !isUp
        case 0x12, VK.lMenu, VK.rMenu:
            altDown = !isUp
        case 0x10, VK.lShift, VK.rShift:
            shiftDown = !isUp
        default:
            if !isUp, shortcut.matches(vk: vk, win: winDown, ctrl: ctrlDown, alt: altDown, shift: shiftDown) {
                winDown = false
                ctrlDown = false
                altDown = false
                shiftDown = false
                return true
            }
        }
        return false
    }
}
