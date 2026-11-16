# Analisi di fattibilità: client macOS nativo per Mouse Without Borders (PowerToys)

Versione 2 — 9 settembre 2026. Sostituisce la prima stesura, che confrontava MWB con Sidecar per un fraintendimento: il termine di paragone Apple corretto è **Universal Control**. Sidecar (iPad come display esterno del Mac) non c'entra con la condivisione di tastiera e mouse fra computer e non viene più considerato.

Fonti primarie: codice sorgente PowerToys (commit `071c25e`, 8 set 2026, `src/modules/MouseWithoutBorders/`), documentazione Microsoft Learn e Apple Support, sorgenti dei client di terze parti `bketelsen/mwb` e `lucky-verma/mwb-linux`, repository Deskflow e Lan Mouse.

## 1. Inquadramento

L'obiettivo è usare tastiera e mouse fisici del Mac per controllare un PC Windows su cui gira PowerToys con Mouse Without Borders attivo, senza installare nulla di aggiuntivo sul PC e senza toccare nulla di non documentato lato Apple. Il Mac è quindi la macchina "host" (dove nasce l'input) e il PC la macchina "controllata".

Universal Control fa esattamente questo fra Mac e iPad, ma è chiuso: nessuna API pubblica, nessun protocollo documentato, e per giunta ignora gli eventi generati via software (confermato dagli utenti Synergy e dallo sviluppatore di BetterTouchTool). È dunque corretto lasciarlo fuori dal progetto. L'unico punto in cui Universal Control rientra è la *convivenza*: se sul Mac è attivo, occupa alcuni bordi dello schermo per passare all'iPad o a un altro Mac, e il client dovrà usarne uno diverso (vedi §5.4).

Mouse Without Borders è invece integrato in PowerToys dalla 0.70 (2023), licenza MIT, C#/.NET. Microsoft non prevede client per altri sistemi (issue #26630 e #38046 chiuse), ma il protocollo è interamente ricostruibile dal codice e due implementazioni indipendenti in Go hanno già dimostrato l'interoperabilità con il server ufficiale. Il progetto proposto è quindi fattibile con API pubbliche su entrambi i lati; il lavoro è tutto sul Mac.

## 2. Come funziona davvero MWB (dal codice)

Questa sezione è il cuore dell'analisi, perché il modello di MWB è meno "client/server" di quanto il termine "macchina in ascolto" faccia pensare.

### 2.1 Modello peer-to-peer, non master/slave

Ogni istanza MWB è contemporaneamente server e client. Ogni macchina apre due listener TCP (`SocketStuff.cs` r. 479-480): sulla porta base (default 15100) il canale appunti/file, sulla porta base+1 (15101) il canale messaggi con gli eventi di input. In più ogni macchina apre una connessione uscente verso la porta 15101 di ciascuna macchina elencata nella sua *matrice* (`StartNewTcpClient`), risolvendo il nome via DNS (`Dns.GetHostEntry`). Non esiste discovery via broadcast.

Conseguenza pratica per il client Mac: non basta connettersi a Windows. Il PC, avendo il Mac nella sua matrice, tenterà a sua volta di connettersi al Mac sulla 15101 e invierà `Hello`. Il client Mac deve quindi (a) esporre un listener sulla 15101 (e sulla 15100 se si vuole la clipboard), (b) aprire la propria connessione verso Windows, (c) rispondere a Hello/Heartbeat in modo da comparire nel *machine pool* di Windows. Il nome del Mac deve essere risolvibile dal PC (DNS locale, voce in `hosts`, oppure mDNS `.local`, che Windows 10/11 risolve nativamente) e l'opzione "Reverse DNS lookup" di MWB deve restare disattivata, altrimenti Windows valida l'IP del peer con una risoluzione inversa.

Sul PC l'utente inserisce il nome del Mac nella matrice di MWB e ne definisce la posizione (sinistra/destra/sopra/sotto). La matrice è per nome, non per ID.

### 2.2 Identità e cifratura

Ogni macchina ha un `MachineId` casuale a 32 bit generato alla prima esecuzione (`Setting.cs` r. 1058) e un nome di 32 caratteri (ASCII, riempito con spazi). `ID.ALL = 255` è il broadcast.

Il canale è cifrato con AES-256-CBC (`Encryption.cs`): la chiave è derivata dalla *security key* condivisa con PBKDF2-HMAC-SHA512, 100.000 iterazioni, salt di 16 byte, output 32 byte. All'apertura di ogni connessione le parti si scambiano in chiaro un header di 32 byte (16 salt + 16 IV), poi tutto il flusso è un `CryptoStream`. Dalla stessa security key deriva anche un *magic number* a 24 bit (`Get24BitHash`), di cui i 16 bit alti finiscono in ogni pacchetto.

Subito dopo lo stream cifrato c'è un handshake a sfida (`Handshake` → `HandshakeAck`): il mittente manda 16 byte casuali nei campi `Machine1..4`, il ricevente risponde con il complemento bit a bit (`~`). Entrambe le direzioni lo eseguono.

### 2.3 Formato dei pacchetti

Pacchetti a lunghezza fissa: 32 byte (`PACKAGE_SIZE`) oppure 64 byte (`PACKAGE_SIZE_EX`) per i tipi "grandi" (Hello, Awake, Heartbeat, Handshake/Ack, Clipboard*, Matrix). Little-endian, layout esplicito (`DATA.cs`):

| Offset | Campo | Note |
|---|---|---|
| 0 | tipo (1 byte) | enum `PackageType` |
| 1 | checksum | somma a 8 bit dei byte 2..31 |
| 2–3 | magic | 16 bit alti del magic number derivato dalla key |
| 4–7 | Id | contatore progressivo |
| 8–11 | Src | MachineId sorgente |
| 12–15 | Des | MachineId destinazione (o 255) |
| 16–31 | payload | unione: `MOUSEDATA`, `KEYBDDATA`, `Machine1..4`, ecc. |
| 32–63 | nome macchina | solo pacchetti da 64 byte |

Payload mouse (`MOUSEDATA`): `X`, `Y`, `WheelDelta`, `dwFlags` (4 × int32). `dwFlags` porta il messaggio Windows `WM_*` (`WM_MOUSEMOVE 0x200`, `WM_LBUTTONDOWN 0x201`, `WM_MOUSEWHEEL 0x20A`, `WM_MOUSEHWHEEL 0x20E`, ecc., `WM.cs`). Le coordinate hanno due modi: **assoluto**, normalizzato 0–65535 sullo *schermo primario* della macchina di destinazione (`Common.screenWidth = Screen.PrimaryScreen.Bounds.Width`, `WinAPI.cs` r. 142), oppure **relativo**, con dx/dy sommati a ±100.000 (`Event.MOVE_MOUSE_RELATIVE`) come marcatore; il ricevente riconosce il modo dal valore assoluto ≥ 100.000 (`Receiver.cs` r. 139). Per un host Mac il modo relativo è il più naturale, perché il cursore locale viene "bloccato" e si trasmettono i delta.

Payload tastiera (`KEYBDDATA`): `DateTime` (int64, offset 16), `wVk` (virtual-key code Windows, offset 24), `dwFlags` (flag `LLKHF`: `UP = 0x80`, `EXTENDED = 0x01`, offset 28). Windows li passa a `SendInput` così come sono (`InputSimulation.SendKey`).

### 2.4 Sequenza di cambio macchina

Quando l'host porta il cursore sul bordo verso il PC (`Event.PrepareToSwitchToMachine`): invia `HideMouse` alla macchina che sta lasciando (se non è se stesso), imposta la nuova destinazione, invia `MachineSwitched` al PC, e da lì in poi tutti i `Mouse`/`Keyboard` hanno `Des` = MachineId del PC. L'host intanto sopprime l'input locale.

Il ritorno funziona nella direzione opposta: quando Windows, muovendo il cursore iniettato, rileva che ha superato il proprio bordo (`MoveToMyNeighbourIfNeeded` nel ramo `Mouse` di `Receiver.cs`), risponde all'host con `NextMachine` (in `WheelDelta` l'ID della macchina successiva, in `X`/`Y` la posizione richiesta). Il client Mac deve gestire `NextMachine` per riprendere il controllo locale e riposizionare il cursore. Questo significa che la matrice del PC deve avere il Mac nella posizione coerente (se il Mac è a sinistra del PC, il PC deve avere il Mac a sinistra), altrimenti il ritorno non scatta.

Manutenzione della sessione: `Hello` all'avvio (broadcast), `Heartbeat`/`Heartbeat_ex` periodici (i client Go usano 5 s), `Awake`, `ByeBye` alla chiusura. Il PC può inviare `Matrix` (con flag `MatrixSwapFlag`/`MatrixTwoRowFlag`) per propagare la propria matrice; il client Mac può ignorarlo, tenendo la propria configurazione locale.

### 2.5 Cosa hanno già fatto gli altri

`bketelsen/mwb` (Go, MIT, v0.2.4 marzo 2026) implementa framing, cifratura, handshake e ricezione su macOS con `CGEventPost`; è però nella direzione opposta (Windows controlla il Mac), non ha listener né clipboard, e usa solo `CGMainDisplayID`. `lucky-verma/mwb-linux` (Go, MIT) è bidirezionale con clipboard e file, ma solo Linux/X11. Nessuno dei due è un host macOS: la parte "cattura input sul Mac e spedisci a Windows" è da scrivere, ma le parti di protocollo sono confermate funzionanti e servono come riferimento incrociato al codice C#. `EncryptionTests.cs` nei test unitari di PowerToys fornisce vettori utili per validare PBKDF2/AES.

## 3. Swift o C#?

**Swift.** Le ragioni sono concrete, non di gusto.

Il lavoro difficile di questo progetto non è il protocollo (poche centinaia di righe, già ricostruite da tre implementazioni) ma l'integrazione con macOS: `CGEventTap` per catturare e sopprimere l'input, `CGAssociateMouseAndMouseCursorPosition` / `CGWarpMouseCursorPosition` per bloccare il cursore e leggere i delta, `NSScreen` per i bordi, `NSStatusItem` per la barra menu, TCC per i permessi Input Monitoring e Accessibilità, `Network.framework` con il prompt "rete locale" di macOS 15+. In C# tutto questo sarebbe P/Invoke verso le stesse API, con in più il runtime .NET da distribuire (build self-contained da decine di MB, o dipendenza esterna) e la firma/notarizzazione di un bundle ibrido.

Quello che C# farebbe risparmiare è il riuso delle classi `DATA`, `PackageType`, `Encryption` di PowerToys. Sono circa 300 righe e si portano in Swift in un pomeriggio; il vantaggio non ripaga il costo del runtime. Tutte le primitive necessarie sono già nel sistema: `CommonCrypto` fornisce PBKDF2 con HMAC-SHA512 (`CCKeyDerivationPBKDF`) e AES-CBC (`CCCryptorCreate` in modalità streaming, niente padding perché i pacchetti sono multipli di 16 byte); `Network.framework` gestisce listener e connessioni TCP; `Foundation` basta per il resto. Zero dipendenze esterne, come richiesto.

Un uso sensato di C# resta possibile come *strumento di test*: un piccolo programma .NET su Windows che linka i sorgenti MIT di PowerToys e logga in chiaro i pacchetti ricevuti, per verificare byte per byte il client Swift durante lo sviluppo. Ma non fa parte del prodotto.

## 4. Architettura proposta (Swift, macOS 13+)

Un'app da barra menu con quattro moduli e nessuna finestra principale.

**Protocol** (Swift puro, testabile senza macOS): `Packet` con serializzazione/deserializzazione del layout a 32/64 byte, calcolo checksum e magic, enum `PackageType`; `KeyDerivation` (PBKDF2-SHA512) e `CipherStream` (AES-256-CBC con header salt+IV); `Handshake`. Test unitari con vettori ricavati da PowerToys.

**Transport** (`Network.framework`): `NWListener` sulla 15101 (e 15100 opzionale), `NWConnection` uscente verso il PC con riconnessione automatica, heartbeat ogni 5 s, gestione `Hello`/`Awake`/`ByeBye`, machine pool minimale (nome → ID → connessione).

**InputCapture** (CoreGraphics/AppKit): un `CGEventTap` a `kCGHIDEventTap` in modalità attiva. In stato *locale* il tap è passivo e osserva solo la posizione per il rilevamento del bordo; in stato *remoto* sopprime gli eventi (ritorna `nil`), blocca il cursore con `CGAssociateMouseAndMouseCursorPosition(false)`, legge `deltaX`/`deltaY` dagli eventi e li invia in modo relativo (±100.000), traduce click, rotella (`scrollingDeltaY` → `WheelDelta` a multipli di 120 come Windows) e tasti. La mappa tastiera è la parte più lunga: keycode macOS (`kVK_*`) → virtual-key Windows, con scelta configurabile di cosa diventa ⌘ (Win o Ctrl) e ⌥ (Alt). Attenzione ai tasti di sistema (F-keys, volume, luminosità) e a `Caps Lock`, che macOS gestisce a parte.

**EdgeLogic + Settings**: la macchina di stato che decide quando passare al PC e quando tornare. Qui vivono le preferenze richieste:

- *posizione* del PC rispetto al desktop del Mac (bordo sinistro/destro/alto/basso, con offset se i due schermi non sono allineati in altezza);
- *ritardo di spostamento*: tempo minimo di permanenza sul bordo prima del cambio (equivalente di `lastJump` 100–500 ms in MWB);
- *resistenza sul bordo*: pixel di "spinta" oltre il bordo da accumulare prima del cambio, per evitare passaggi involontari (MWB usa `skipPixels`, la resistenza accumulata è un'aggiunta);
- nome/IP del PC, porta base, security key (nel Keychain), nome con cui il Mac si presenta;
- scorciatoia per tornare al Mac in emergenza (indispensabile: se il PC cade mentre si è in stato remoto, l'input del Mac è soppresso).

Interfaccia: `NSStatusItem` con stato (locale/remoto/disconnesso), voce "Attiva/Disattiva", e una finestra Impostazioni SwiftUI. Permessi: Input Monitoring (per il tap) e Accessibilità (per il warp del cursore), richiesti al primo avvio con `CGRequestListenEventAccess`/`AXIsProcessTrustedWithOptions`. App firmata e notarizzata, senza sandbox (il tap HID non è compatibile con App Sandbox).

## 5. Rischi e punti da verificare in un prototipo

### 5.1 Deriva del protocollo
MWB non ha una specifica: ogni release di PowerToys può cambiare enum, dimensioni o handshake (`Heartbeat_ex_l2/l3`, `MatrixSwapFlag` sono tracce di evoluzioni passate). Mitigazione: fissare nel client la versione PowerToys di riferimento, tenere i test di framing allineati al sorgente, e un canale di log in chiaro per diagnosi rapida.

### 5.2 Direzione inversa e stato del cursore su Windows
In modo relativo Windows muove il cursore con `MoveMouseRelative` e poi controlla i propri bordi per rispondere `NextMachine`. Da verificare: comportamento con più monitor sul PC (MWB normalizza sullo schermo primario ma il desktop virtuale può essere più ampio) e con DPI scaling diverso.

### 5.3 Tastiera
I virtual-key code sono neutrali rispetto al layout, quindi con layout italiano su entrambi i lati i tasti "fisici" coincidono; i problemi noti sono i tasti che macOS tratta diversamente (⌘, `fn`, `Caps Lock`, tasti media), i tasti morti e i caratteri che sul Mac richiedono ⌥ (es. `{ } [ ] @ #` su tastiera italiana Apple). Servirà una tabella di eccezioni configurabile.

### 5.4 Convivenza con Universal Control
Universal Control aggancia i bordi dove sono disposti iPad/altri Mac. Il tap a `kCGHIDEventTap` intercetta prima del window server, quindi in stato remoto (eventi soppressi, cursore bloccato) Universal Control non dovrebbe scattare; in stato locale, se il PC è assegnato a un bordo diverso da quelli usati da Universal Control, i due sistemi non si contendono nulla. Resta da verificare sperimentalmente cosa vede il tap mentre Universal Control ha già spostato il cursore sull'iPad (lo sviluppatore di BTT dichiara di non avere modo di rilevarlo). Raccomandazione: bordo destro/sinistro per il PC, bordo opposto per l'iPad, e un'opzione "sospendi quando Universal Control è attivo" come fallback manuale.

### 5.5 Rete e sicurezza
Il canale è AES-CBC con chiave condivisa e senza autenticazione dei messaggi (nessun HMAC/AEAD): accettabile su LAN domestica, da tenere presente altrove. La security key va nel Keychain, mai in chiaro nelle preferenze. Su macOS 15+ la prima connessione verso la LAN mostra il prompt "rete locale", da gestire nell'onboarding. Il firewall Windows deve permettere le porte 15100/15101 in ingresso (PowerToys ha un'opzione per la regola).

### 5.6 Clipboard e file
Fuori dal perimetro "minimale" chiesto. Il protocollo li prevede (porta 15100, `ClipboardText`/`ClipboardImage`/`ClipboardDataEnd`, limite 100 MB) e `mwb-linux` ne ha una implementazione di riferimento: si possono aggiungere in una seconda fase senza cambiare architettura.

## 6. Alternative pronte, per confronto

Vale la pena conoscerle anche solo per decidere cosa *non* replicare.

**Deskflow** (ex Synergy/Barrier/Input Leap, C++/Qt, GPL) copre Windows/macOS/Linux con modello server/client e un protocollo proprio; è maturo ma richiede il suo agente anche sul PC.

**Lan Mouse** (Rust, GPL-3.0, `feschber/lan-mouse`) è forse il riferimento di design più vicino al progetto: peer-to-peer senza ruoli, ogni dispositivo configura la posizione degli altri, UDP con DTLS (WebRTC.rs), app da barra menu su macOS, rilascio automatico del controllo quando un peer sparisce ("liveness tracking"). Anche qui però serve Lan Mouse sul PC. Alcune sue scelte (UDP per la latenza, liveness, posizionamento per-dispositivo) sono buoni spunti per il client Swift, pur restando sul protocollo TCP di MWB.

**bketelsen/mwb** e **mwb-linux** sono le uniche a parlare MWB nativo, ma nella direzione opposta o su altro OS.

Il valore del client "in casa" sta nel non installare nulla sul PC oltre a PowerToys, che l'utente ha già e che è maturo, e nell'avere una app macOS minimale, nativa, senza runtime.

## 7. Conclusione e percorso consigliato

Il client macOS nativo in Swift è fattibile con sole API pubbliche e con rischio tecnico basso sul protocollo, medio sull'integrazione di input macOS. Percorso suggerito:

1. **Protocol + test** (1–2 giorni): framing, PBKDF2/AES, handshake, validati contro PowerToys reale con un logger di test (anche C# usa-e-getta).
2. **Transport + presenza** (1–2 giorni): listener e connessione, Hello/Heartbeat; obiettivo: il Mac compare nel machine pool di PowerToys e la matrice lo accetta.
3. **Input remoto unidirezionale** (2–4 giorni): tap, blocco cursore, mouse relativo, click, rotella; poi tastiera con mappa base.
4. **Cambio macchina completo** (1–2 giorni): `MachineSwitched`, `HideMouse`, gestione `NextMachine` per il ritorno, ritardo e resistenza sul bordo, scorciatoia di emergenza.
5. **App** (2–3 giorni): barra menu, impostazioni, Keychain, permessi, firma e notarizzazione.
6. **Verifiche di campo**: multi-monitor sul PC, DPI, layout tastiera italiano, convivenza con Universal Control.

In tutto, un prototipo usabile in circa due settimane di lavoro effettivo; clipboard e file come estensione successiva.

## Fonti

- Codice sorgente PowerToys, modulo MouseWithoutBorders: https://github.com/microsoft/PowerToys/tree/main/src/modules/MouseWithoutBorders (file consultati: `Core/Package.cs`, `Core/DATA.cs`, `Core/MOUSEDATA.cs`, `Core/KEYBDDATA.cs`, `Core/PackageType.cs`, `Core/Encryption.cs`, `Core/Event.cs`, `Core/Receiver.cs`, `Core/MachineStuff.cs`, `Core/WM.cs`, `Core/WinAPI.cs`, `Core/ID.cs`, `Class/SocketStuff.cs`, `Class/TcpServer.cs`, `Class/InputHook.cs`, `Class/InputSimulation.cs`, `Class/Setting.cs`, `MouseWithoutBorders.UnitTests/Core/EncryptionTests.cs`)
- Microsoft Learn, Mouse Without Borders: https://learn.microsoft.com/en-us/windows/powertoys/mouse-without-borders
- PowerToys issue #26630 "Mouse Without Borders Multi-OS Support": https://github.com/microsoft/PowerToys/issues/26630
- PowerToys issue #38046 "Mouse Without Borders for All": https://github.com/microsoft/PowerToys/issues/38046
- bketelsen/mwb, client MWB per Wayland e macOS (Go, MIT): https://github.com/bketelsen/mwb
- lucky-verma/mwb-linux, client MWB bidirezionale per Linux (Go, MIT): https://github.com/lucky-verma/mwb-linux
- feschber/lan-mouse (Rust, GPL-3.0): https://github.com/feschber/lan-mouse
- Deskflow: https://github.com/deskflow/deskflow
- Apple Support, Universal Control: https://support.apple.com/en-us/102459
- Symless Forums, "Synergy and Universal Control on Mac": https://forums.symless.com/topic/6696-synergy-and-universal-control-on-mac/
- BetterTouchTool Community, "Support for Apple's Universal Control": https://community.folivora.ai/t/support-for-apples-universal-control/25744
