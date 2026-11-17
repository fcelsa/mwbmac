# MWB Mac Host — client macOS per Mouse Without Borders

Client nativo macOS (Swift, zero dipendenze esterne) che usa tastiera e mouse del Mac
per controllare un PC Windows con PowerToys Mouse Without Borders attivo. Il Mac è
l'host (dove nasce l'input), il PC la macchina controllata. Nulla da installare sul PC
oltre a PowerToys.

## Fonte di verità

`docs/analisi.md` contiene l'analisi di fattibilità con protocollo MWB ricostruito dal
sorgente PowerToys, architettura a quattro moduli, rischi e roadmap. Leggerla per intera
prima di scrivere codice. In caso di dubbio sul protocollo, la verità è il sorgente
PowerToys (`reference/MouseWithoutBorders/` se presente, altrimenti
https://github.com/microsoft/PowerToys/tree/main/src/modules/MouseWithoutBorders).
Implementazioni di riferimento già interoperanti: `bketelsen/mwb` (Go, macOS, direzione
opposta) e `lucky-verma/mwb-linux` (Go, bidirezionale, clipboard).

## Decisioni prese

- Linguaggio: Swift. C# scartato per il prodotto (runtime .NET da distribuire, P/Invoke
  comunque necessario). C# ammesso solo per un eventuale logger usa-e-getta su Windows
  che linka i sorgenti MIT di PowerToys per validare i pacchetti byte per byte.
- Struttura: Swift Package con target eseguibile, compilabile da riga di comando
  (`swift build`, `swift test`) senza Xcode aperto. Il bundle `.app` con `Info.plist`,
  firma, notarizzazione e barra menu arriva solo nella fase 5 della roadmap.
- Target minimo macOS 13. Niente App Sandbox (incompatibile con il tap HID).
- Modo mouse: relativo (delta ±100000 come marcatore), cursore locale bloccato con
  `CGAssociateMouseAndMouseCursorPosition(false)`.
- Crittografia con CommonCrypto (PBKDF2-HMAC-SHA512 100000 iter, AES-256-CBC streaming,
  nessun padding: i pacchetti sono 32 o 64 byte). Rete con Network.framework.
- Security key nel Keychain, mai in chiaro nelle preferenze.
- Scorciatoia di emergenza per tornare al Mac: obbligatoria fin dal primo prototipo
  (in stato remoto l'input locale è soppresso).
- Clipboard: testo e immagini nelle due direzioni (implementata dopo la fase 5).
  Trasferimento file e drag & drop: fuori perimetro.

## Moduli (vedi docs/analisi.md §4)

1. `Protocol` — framing 32/64 byte, checksum, magic, PackageType, PBKDF2/AES, handshake
   a sfida (`Machine1..4` → complemento bit a bit). Swift puro, testabile su qualsiasi OS.
2. `Transport` — NWListener su porta base+1 (15101) e base (15100, opzionale);
   NWConnection uscente verso il PC; Hello/Heartbeat ogni 5 s/Awake/ByeBye; machine pool.
3. `InputCapture` — CGEventTap a kCGHIDEventTap; stato locale (osserva bordo) e remoto
   (sopprime eventi, invia delta, click, rotella, tasti). Mappa keycode macOS → VK Windows.
4. `EdgeLogic + Settings` — posizione del PC (bordo + offset), ritardo di spostamento,
   resistenza sul bordo in pixel, hotkey di emergenza. Gestione di `MachineSwitched`,
   `HideMouse` in uscita e `NextMachine` in ingresso (è Windows a decidere il ritorno).

## Roadmap (ordine vincolante)

1. Protocol + test unitari con vettori dal sorgente PowerToys (`EncryptionTests.cs`).
2. Transport: il Mac compare nel machine pool di PowerToys e la matrice lo accetta.
3. Input remoto unidirezionale: mouse relativo, click, rotella, poi tastiera.
4. Cambio macchina completo con ritorno via NextMachine, ritardo e resistenza.
5. App: NSStatusItem, impostazioni SwiftUI, Keychain, permessi TCC, firma.
6. Verifiche di campo: multi-monitor e DPI sul PC, layout italiano Apple (⌥ per {}[]@#),
   convivenza con Universal Control sui bordi.

## Ambiente di test

PC Windows con PowerToys + MWB attivo, security key nota, nome del Mac nella matrice
nella posizione coerente con la configurazione del Mac, "Reverse DNS lookup" disattivato,
porte 15100/15101 aperte nel firewall. Il nome del Mac deve essere risolvibile dal PC
(mDNS `.local` o voce in `hosts`).

## Stato dell'implementazione

Fasi 1–5 implementate (vedi `README.md`): eseguibile da riga di comando `mwbmac` e app da
barra menu `MWBMacHost`, il cui bundle si costruisce e firma con `scripts/build-app.sh`.
Target SwiftPM: `MWBProtocol`, `MWBTransport`, `MWBInputCapture`, `MWBEdgeLogic`, `mwbmac`,
`MWBMacHost`.
I test usano **Swift Testing** (`import Testing`), non XCTest: sulla macchina di sviluppo
ci sono solo i Command Line Tools, senza Xcode. Per lo stesso motivo in SwiftUI non si può
usare `@State` (nell'SDK corrente è una macro e il plugin `SwiftUIMacros` manca): lo stato
delle viste sta in `ObservableObject` con `@Published`. Ogni tanto `swift test` fallisce con
"plugin for module 'TestingMacros' not found": è transitorio, basta rilanciarlo.

Il sorgente in `reference/` è più recente di quello descritto in `docs/analisi.md`:
dopo l'intestazione in chiaro salt+IV, il primo blocco cifrato di ogni direzione è un
blocco casuale da scartare (`SendOrReceiveARandomDataBlockPerInitialIV`), e il ricevente
scarta i pacchetti con `Id` già visto (coda di 50), quindi ogni pacchetto ha un Id nuovo.

Le versioni di PowerToys precedenti usano lo schema storico (nessuna intestazione, salt e
IV fissi, 50000 iterazioni). `PeerConnection` riconosce lo schema dal flusso del PC, che
trasmette per primo, e solo dopo risponde; se il flusso non si decifra chiude senza
inviare nulla e la sessione non riprova (`mwbmac probe --verbose` stampa la diagnosi).

Cursore locale in stato remoto: sopprimere gli eventi nel tap non lo ferma, e
`CGAssociateMouseAndMouseCursorPosition` / `CGDisplayHideCursor` valgono solo per l'app in
primo piano. `LocalCursor.capture()` porta quindi l'app in primo piano per la durata del
controllo remoto e `release()` lo restituisce all'app precedente (verificato sul campo).
Non tornare al riposizionamento del cursore a ogni evento (`CGWarpMouseCursorPosition`,
alla Synergy): è stato provato in tre varianti e falsa i delta degli eventi, rendendo il
cursore del PC incontrollabile. Per lo stesso motivo anche `mwbmac run` gira come app
"agente" con un ciclo di eventi AppKit.

Appunti (`Core/Clipboard.cs`): testo = "TXT…SEP[RTF…SEP][HTM…SEP]" in UTF-16LE con
Deflate grezzo; immagine = PNG. Fino a 1 MB in linea sul canale messaggi (pacchetti da 64
byte con 48 byte di dati agli offset 16..63, poi `ClipboardDataEnd`); oltre, pacchetto
`Clipboard` di annuncio e canale appunti sulla porta base. Dettagli non ovvi:
- PowerToys invia i buffer con la capacità e non la lunghezza: zeri in coda a testo e PNG;
- invia gli appunti in linea su tutti i socket verso la macchina: arrivano due volte;
- ritira i dati grandi solo al `MachineSwitched` e solo se l'annuncio ha meno di 30 s,
  quindi `Controller` lo fa ripetere subito prima del cambio macchina;
- sul canale appunti legge fino alla chiusura della connessione e vuole un multiplo di
  16 byte, altrimenti la decifratura dell'ultimo blocco fallisce;
- il pacchetto di saluto del canale appunti non porta magic né checksum.

Mai provare la connessione al PC con una chiave sbagliata: dopo dieci pacchetti non
validi PowerToys marca `InvalidKeyFound` e smette di aprire connessioni client.

## Convenzioni

- Commit piccoli, uno per passo della roadmap o sotto-passo.
- Ogni modifica a `Protocol` deve passare `swift test`.
- Log del protocollo in chiaro attivabile da flag, per diagnosi contro PowerToys reale.
- Lingua dei commenti e della documentazione: italiano; identificatori in inglese.
