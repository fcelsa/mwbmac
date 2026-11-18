// Localizzazione dell'interfaccia.
//
// Regole:
// - la chiave è il testo inglese, che è anche la lingua di ripiego: una traduzione
//   mancante mostra l'inglese, mai una chiave tecnica;
// - le traduzioni stanno in `Resources/<lingua>.lproj/Localizable.strings`, che
//   `scripts/build-app.sh` copia nel bundle; macOS sceglie la lingua dalle preferenze di
//   sistema fra quelle elencate in `CFBundleLocalizations`, altrimenti usa l'inglese
//   (`CFBundleDevelopmentRegion`);
// - testi con valori variabili: formato con `%@` (testo) e `%ld` (interi), mai stringhe
//   composte a pezzi, perché l'ordine delle parole cambia da lingua a lingua;
// - nelle viste SwiftUI si passa sempre il risultato di `L(...)`, una `String` mostrata
//   così com'è, per non mescolare due meccanismi di traduzione;
// - `scripts/check-localization.sh` segnala le chiavi senza traduzione.
// I messaggi di log e lo strumento da riga di comando sono solo in inglese: sono diagnosi.

import Foundation

/// Testo dell'interfaccia nella lingua del sistema. `key` è il testo inglese, letterale.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}
