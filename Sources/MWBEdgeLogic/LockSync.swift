// Blocco schermo sincronizzato, sulla funzione documentata di Mouse Without Borders
// "Shortcut to lock all machines": Ctrl+Alt+<lettera> premuta due volte sulla macchina
// che ha tastiera e mouse blocca tutte le macchine che hanno la stessa impostazione.
// Fonte: PowerToys `InputHook.ProcessHotKeys` (chi invia) e
// `InputSimulation.InputProcessKeyEx` (chi riceve); learn.microsoft.com, Mouse Without Borders.
//
// Sul filo non esiste un pacchetto "blocca": chi invia trasmette a tutte le macchine
// (destinazione ALL) la pressione e il rilascio dei tasti della scorciatoia, e chi li
// riceve, riconosciuta la propria scorciatoia, chiama `LockWorkStation`. Inoltre il PC
// che riceve Win+L si blocca sempre (ramo `'L'` di `InputProcessKeyEx`).
//
// Logica pura, senza dipendenze da AppKit, per poterla testare.

import Foundation
import MWBInputCapture
import MWBProtocol

public struct LockSync: Sendable {
    /// Lettera della scorciatoia "blocca tutte le macchine" (Ctrl+Alt+lettera), uguale a
    /// quella impostata nel Mouse Without Borders del PC.
    public let letter: Character
    /// Virtual-key Windows della lettera (A–Z coincidono con il codice ASCII maiuscolo).
    public let letterVK: Int32

    private var ctrlDown = false
    private var altDown = false
    private var lastIncoming: Double = -1_000

    /// Oltre questa pausa fra due tasti ricevuti i modificatori tracciati si azzerano:
    /// un rilascio perso non deve lasciare "premuti" Ctrl e Alt per sempre.
    static let modifierTimeout = 3.0

    /// Accetta una sola lettera A–Z (maiuscola o minuscola); qualunque altro valore
    /// ripiega sulla L, il valore predefinito di Mouse Without Borders.
    public init(letter: String) {
        // Si controlla prima che sia una lettera ASCII: `uppercased()` di "ß" dà "SS",
        // che non entra in un `Character`.
        let trimmed = letter.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 1, let first = trimmed.first, first.isASCII, first.isLetter {
            self.letter = Character(first.uppercased())
        } else {
            self.letter = "L"
        }
        self.letterVK = Int32(self.letter.asciiValue ?? UInt8(ascii: "L"))
    }

    /// Tasti da inviare a tutte le macchine: Ctrl, Alt e lettera premuti, poi rilasciati
    /// in ordine inverso. Si usano i codici "sinistri" (VK_LCONTROL, VK_LMENU) perché sono
    /// quelli che `InputProcessKeyEx` traccia per riconoscere la scorciatoia.
    public func lockAllSequence() -> [KeyboardData] {
        let keys: [Int32] = [VK.lControl, VK.lMenu, letterVK]
        return keys.map { KeyboardData(vk: $0, flags: 0) }
            + keys.reversed().map { KeyboardData(vk: $0, flags: LLKHF.up) }
    }

    /// Vero se il tasto che sta per essere inviato al PC lo bloccherà: Win+L (sempre, sul
    /// PC) oppure Ctrl+Alt+lettera. `pressed` sono i tasti Windows già premuti.
    public func locksPC(sending vk: Int32, pressed: [WindowsKey]) -> Bool {
        let codes = Set(pressed.map(\.vk))
        let win = codes.contains(VK.lWin) || codes.contains(VK.rWin)
        let ctrl = codes.contains(VK.lControl) || codes.contains(VK.rControl)
        let alt = codes.contains(VK.lMenu) || codes.contains(VK.rMenu)
        return (vk == Int32(UInt8(ascii: "L")) && win) || (vk == letterVK && ctrl && alt)
    }

    /// Da chiamare per ogni tasto ricevuto da un'altra macchina e destinato al Mac.
    /// Restituisce `true` quando arriva la scorciatoia "blocca tutte le macchine".
    /// Il PC che la invia usa i codici generici (VK_CONTROL, VK_MENU): si accettano anche
    /// quelli destri e sinistri.
    public mutating func observeIncoming(vk: Int32, flags: Int32, now: Double) -> Bool {
        if now - lastIncoming > LockSync.modifierTimeout {
            ctrlDown = false
            altDown = false
        }
        lastIncoming = now
        let isUp = flags & LLKHF.up != 0
        switch vk {
        case 0x11, VK.lControl, VK.rControl:
            ctrlDown = !isUp
        case 0x12, VK.lMenu, VK.rMenu:
            altDown = !isUp
        case letterVK:
            if !isUp, ctrlDown, altDown {
                ctrlDown = false
                altDown = false
                return true
            }
        default:
            break
        }
        return false
    }
}
