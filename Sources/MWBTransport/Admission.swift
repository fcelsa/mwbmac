// Limite alle connessioni entranti non ancora autenticate.
//
// I listener sono aperti a chiunque raggiunga il Mac in rete. Prima dell'handshake non
// si sa se il peer conosce la security key, ma ogni connessione costa una derivazione
// PBKDF2 (100000 iterazioni SHA-512) sulla coda della sessione, la stessa che inoltra
// mouse e tastiera. Senza limiti, chiunque in rete potrebbe far scattare l'input o
// riempire la memoria aprendo connessioni a raffica.

import Foundation

struct Admission {
    /// Connessioni non ancora fidate tollerate contemporaneamente.
    let maxPending: Int
    /// Nuove connessioni accettate per finestra di tempo.
    let maxPerWindow: Int
    let window: TimeInterval

    private var recent: [TimeInterval] = []

    init(maxPending: Int, maxPerWindow: Int, window: TimeInterval) {
        self.maxPending = maxPending
        self.maxPerWindow = maxPerWindow
        self.window = window
    }

    /// Vero se una nuova connessione entrante può essere presa in carico.
    mutating func admit(pending: Int, now: TimeInterval) -> Bool {
        recent.removeAll { now - $0 > window }
        guard pending < maxPending, recent.count < maxPerWindow else { return false }
        recent.append(now)
        return true
    }
}
