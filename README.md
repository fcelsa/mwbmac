# MWB Mac Host

**English** · [Italiano](#italiano)

A native macOS client for **PowerToys Mouse Without Borders**: use the Mac's keyboard and
mouse to control a Windows PC, moving the cursor across the screen edge as if the two
were one desk. Nothing to install on the PC besides PowerToys. Written in Swift with no
third-party dependencies.

> **Disclaimer.** This is an independent project, not affiliated with, endorsed by or
> supported by Microsoft. "PowerToys", "Mouse Without Borders" and "Windows" are
> trademarks of Microsoft Corporation. The network protocol was reconstructed from the
> open-source (MIT) PowerToys code; a future PowerToys release may change it. Use at your
> own risk.

## Features

- **Mac → PC control**: push the cursor past the configured screen edge and the mouse
  and keyboard drive the PC; Windows sends the cursor back when it leaves the PC on the
  opposite side. An emergency shortcut (default **⌃⌥⌘Esc**) always brings control back.
- **Edge options**, as in Mouse Without Borders: switch delay and resistance, the part of
  the edge that leads to the PC (for screens of different sizes), ignored corners, no
  switching while an app is full screen, switching only while holding a modifier key.
- **Keyboard mapping** for Windows: ⌘ ⌃ ⌥ can each become Ctrl, Win or Alt; right ⌥ as
  AltGr for the Italian layout (`@ # [ ] { }`).
- **Shared clipboard** in both directions: plain text, RTF, HTML and images (screenshots
  included), up to 100 MB.
- **Screen lock sync**: ⌃⌘Q on the Mac also locks the PC, and the PC's "lock all
  machines" shortcut also locks the Mac. Works on the Windows lock and sign-in screens.
- **Sleep and wake**: the PC is told when the Mac sleeps, and the connection resumes on
  wake; optionally each computer keeps the other awake while you work.
- Menu bar app with a settings window, in English and Italian (follows the system
  language); a command-line tool for diagnostics.

Not supported: controlling the Mac from the PC (planned), file transfer and drag and
drop between machines.

## Requirements

- macOS 13 Ventura or later.
- Xcode or just the Command Line Tools (`xcode-select --install`), Swift 5.9 or later.
- A Windows PC with PowerToys and Mouse Without Borders enabled, on the same local
  network.

## Build and install

No binaries are distributed: you build and sign the app on your own Mac. The signature
is a local self-signed certificate, valid only on that Mac.

```bash
git clone https://github.com/fcelsa/mwbmac.git
```

```bash
cd mwbmac
```

Create the local signing certificate (once):

```bash
scripts/create-signing-cert.sh
```

It adds a self-signed "mwbmac local signing" certificate to your login keychain. Without
it the app is signed ad hoc: it works, but macOS treats every build as a different app,
and the two permissions below must be removed and granted again after each rebuild. The
first time the certificate is used, macOS asks to allow `codesign` to use the key.

Build, sign and install in `/Applications`:

```bash
scripts/build-app.sh --install
```

Other options: `--run` launches the app at the end, `--debug` builds in debug mode.
Without `--install` the app is left in `build/MWB Mac Host.app`.

Launch **MWB Mac Host** from `/Applications`. It lives only in the menu bar. On first
launch it asks for two permissions in System Settings → Privacy & Security:
**Accessibility** and **Input Monitoring**. It starts by itself as soon as they are
granted.

## Setup

**On the PC**, in PowerToys → Mouse Without Borders:

- note the **security key**, which you will enter on the Mac;
- add the Mac's name to the device layout, on the side matching the edge chosen on the
  Mac (PC to the right of the Mac → Mac to the left of the PC);
- turn off "Reverse DNS lookup" if name resolution fails;
- let ports 15100 and 15101 through the Windows firewall.

The PC must be able to resolve the Mac's name: `name.local` (mDNS) normally works,
otherwise add an entry to the PC's `hosts` file.

**On the Mac**, open Settings… from the menu bar icon:

- **Connection**: the PC's name or address, the Mac's name (the one in the PC's device
  layout), the security key (stored only in the Keychain).
- **Screen Edge**: the side the PC is on and the part of the edge that leads to it; the
  diagram shows the result.
- **Keyboard & Mouse**, **Sharing & Lock**: key mapping, clipboard, lock sync, sleep.

The icon shows the state: off, waiting for the PC, connected, controlling the PC, or a
problem (missing permissions, missing or wrong key).

> **Never try a wrong key on purpose.** After ten invalid packets PowerToys marks the key
> as invalid and stops opening connections until it is restarted. If the key doesn't
> match, the app reports it and doesn't retry.

## Use

- Push the cursor past the edge to move to the PC; move it past the PC's opposite edge
  to come back.
- **⌃⌥⌘Esc** (configurable) always brings control back to the Mac and, on the Mac,
  switches to the PC manually. While the PC is controlled the Mac's own input is
  suppressed: keep this shortcut in mind.
- The menu also offers "Switch to the PC / Back to the Mac", "Enabled" and "Open at
  Login".

### Clipboard

Copy on one side, paste on the other. "Share clipboard" must be on in Mouse Without
Borders on the PC.

- Up to 1 MB the content travels immediately on the message channel.
- Larger content (typically screenshots) travels on the clipboard channel, port 15100:
  from the PC to the Mac it is fetched as soon as it is copied; from the Mac to the PC,
  PowerToys fetches it when control moves to the PC.
- Images reach the PC as 8-bit sRGB PNG; on the Mac they are offered as PNG and TIFF.
- Not shared: files copied in Finder or Explorer, drag and drop, and content that
  password managers mark as concealed.

### Screen lock

Based on Mouse Without Borders' "lock all machines" shortcut, which locks every machine
using the same setting when pressed twice. In PowerToys it is configurable and defaults
to **Win+Ctrl+Alt+L**; the shortcut set on the Mac must match it.

- **⌃⌘Q on the Mac** locks the Mac and sends the PC the "lock all machines" shortcut.
- **Win+L sent to the PC** while you control it (⌃L with the default mapping) locks the
  PC and the Mac.
- **The shortcut pressed twice on the PC** locks the PC and the Mac.

What Mouse Without Borders doesn't transmit is not synchronized: Win+L pressed on the PC's
own keyboard, and locking the Mac from the Apple menu, Touch ID, hot corners or sleep.

Control also works on the Windows lock and sign-in screens, so you can type the password.
When Windows switches desktop (lock, unlock, click on the lock screen) Mouse Without
Borders drops all connections and reconnects within a second: the Mac stays in control of
the PC for 3 s while it reconnects, as PowerToys does between two PCs.

### Sleep and screen saver

- **The Mac goes to sleep**: control returns to the Mac and the PC is told right away;
  on wake the session restarts and reconnects as soon as the network is back.
- **Keep the other computers awake** (like "Block screen saver on other machines" in
  Mouse Without Borders): while you work on the Mac, a message every minute keeps the PC
  from sleeping; if the PC has the same option on, activity on the PC keeps the Mac awake
  (but doesn't wake a sleeping display or touch the lock screen).

## Settings

Stored in `~/Library/Application Support/mwbmac/config.json`, shared by the app and the
command-line tool. The settings window covers all of them.

| Key | Meaning | Default |
|---|---|---|
| `remoteHost`, `basePort` | PC and Mouse Without Borders base port | —, 15100 |
| `localName` | name the Mac presents itself with (the one in the PC's device layout) | host name |
| `edge` | Mac edge beyond which the PC sits: `left` `right` `top` `bottom` | `right` |
| `switchDelayMs` | switch delay: minimum continuous push against the edge | 150 |
| `edgeResistancePx` | resistance: pixels of push to accumulate | 30 |
| `edgeStart`, `edgeEnd` | active part of the edge (0…1) for screens that don't line up | 0, 1 |
| `blockCorners` | screen corners (100 points) don't lead to the PC | `false` |
| `disableInFullScreen` | no edge switching while a full-screen app is in front | `true` |
| `edgeSwitchModifier` | key to hold to switch at the edge: `none` `control` `option` `command` `shift` | `none` |
| `keepOthersAwake` | while using the Mac the PC doesn't sleep or start the screen saver | `true` |
| `windowsLayout` | PC keyboard layout: `it` or `us` | `it` |
| `commandKey`, `controlKey`, `optionKey` | what ⌘ ⌃ ⌥ become: `ctrl` `win` `alt` | `ctrl`, `win`, `alt` |
| `rightOptionIsAltGr` | right ⌥ as AltGr (`@ # [ ] { }` on the Italian layout) | `true` |
| `invertScroll` | invert the scroll direction | `false` |
| `hotkey` | emergency shortcut (macOS keycode + modifiers) | ⌃⌥⌘Esc |
| `shareClipboard` | shared clipboard, text and images | `true` |
| `syncLock` | screen lock synchronized between Mac and PC | `true` |
| `lockAllShortcut` | "lock all machines" shortcut, same as on the PC | `Win+Ctrl+Alt+L` |

## Logs and troubleshooting

The app writes to `~/Library/Logs/mwbmac/mwbmac.log` (readable only by you; never the
clipboard content or the security key). By default only errors, startup and the first
connection with each machine are logged. For detailed diagnostics:

```bash
defaults write local.mwbmac.host verbose -bool true
```

then restart the app (`defaults delete local.mwbmac.host verbose` turns it off again).

The command-line tool travels inside the bundle and shares the app's settings and key.
Quit the app before using `probe` or `run`: they use the same port and machine id.

```bash
"/Applications/MWB Mac Host.app/Contents/MacOS/mwbmac" help
```

- `set-key` / `delete-key`: store or remove the security key in the Keychain (typed
  without echo).
- `config [--host <pc>] [--name <mac>] [--edge <edge>]`: show or change the settings.
- `probe --verbose`: transport only (connection, handshake, heartbeats; no permissions
  needed): checks that the Mac joins the PC's machine pool.
- `run`: full control from the terminal; needs Accessibility and Input Monitoring for the
  terminal app.
- `--log-protocol` prints every packet sent and received in clear text.

Common problems:

- **Waiting for the PC… forever**: check the PC name, the firewall (15100–15101) and that
  the Mac's name is in the PC's device layout and resolvable from the PC.
- **Security key doesn't match the PC**: enter it again in Settings, then restart
  PowerToys on the PC if it stopped connecting.
- **The cursor doesn't come back from the PC**: in the PC's device layout the Mac must sit
  on the side opposite to the edge chosen on the Mac.
- **Universal Control** uses the screen edges too: don't put an iPad or another Mac on the
  same edge as the PC.

## Development

```bash
swift build
```

```bash
swift test
```

The Command Line Tools are enough: tests use Swift Testing, not XCTest. With the Command
Line Tools only, `swift test` sometimes fails with "plugin for module 'TestingMacros' not
found"; load the plugin explicitly:

```bash
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

| Module | Contents |
|---|---|
| `MWBProtocol` | 32/64-byte packets, checksum, magic, PBKDF2/AES, handshake, clipboard formats |
| `MWBTransport` | listener on 15101, outgoing connection with reconnection, heartbeats, machine pool, clipboard channel on 15100 |
| `MWBInputCapture` | CGEventTap, macOS keycode → Windows VK map, mouse/wheel/key translation |
| `MWBEdgeLogic` | edge detection, settings, Keychain, local/remote state machine, NSPasteboard bridge |
| `mwbmac` | command-line tool |
| `MWBMacHost` | menu bar app (AppKit + SwiftUI settings) |

The protocol analysis (in Italian) is in [docs/analisi.md](docs/analisi.md). Interface
translations live in `Sources/MWBMacHost/Resources/<language>.lproj`, keyed by the
English text; to add a language, add a folder with `Localizable.strings` and
`InfoPlist.strings`. `scripts/check-localization.sh` (also run by `build-app.sh`) reports
missing translations. Logs and the command-line tool are English only. Code comments are
in Italian.

## Acknowledgements

- [Microsoft PowerToys](https://github.com/microsoft/PowerToys) (MIT): Mouse Without
  Borders source code, the reference for the protocol.
- [bketelsen/mwb](https://github.com/bketelsen/mwb) and
  [lucky-verma/mwb-linux](https://github.com/lucky-verma/mwb-linux): independent
  implementations that showed the protocol can be spoken outside Windows.

## License

[MIT](LICENSE).

---

<a id="italiano"></a>

# MWB Mac Host (italiano)

[English](#mwb-mac-host) · **Italiano**

Client macOS nativo per **PowerToys Mouse Without Borders**: tastiera e mouse del Mac
controllano un PC Windows, e il cursore passa da uno schermo all'altro attraverso il
bordo come se fossero un'unica scrivania. Sul PC non va installato nulla oltre a
PowerToys. Scritto in Swift, senza dipendenze esterne.

> **Avvertenza.** Progetto indipendente, non affiliato a Microsoft né da essa approvato o
> supportato. "PowerToys", "Mouse Without Borders" e "Windows" sono marchi di Microsoft
> Corporation. Il protocollo di rete è stato ricostruito dal codice open source (MIT) di
> PowerToys; una versione futura di PowerToys potrebbe cambiarlo. Uso a proprio rischio.

## Funzioni

- **Controllo Mac → PC**: spingendo il cursore oltre il bordo configurato mouse e
  tastiera passano al PC; è Windows a rimandare il cursore al Mac quando esce dal lato
  opposto. Una scorciatoia di emergenza (predefinita **⌃⌥⌘Esc**) riporta sempre il
  controllo al Mac.
- **Opzioni del bordo** come in Mouse Without Borders: ritardo e resistenza, tratto del
  bordo che porta al PC (per schermi di dimensioni diverse), angoli esclusi, nessun
  passaggio con un'app a tutto schermo, passaggio solo tenendo premuto un modificatore.
- **Mappatura della tastiera** per Windows: ⌘ ⌃ ⌥ diventano a scelta Ctrl, Win o Alt;
  ⌥ destro come AltGr per il layout italiano (`@ # [ ] { }`).
- **Appunti condivisi** nelle due direzioni: testo semplice, RTF, HTML e immagini
  (comprese le catture schermo), fino a 100 MB.
- **Blocco schermo sincronizzato**: ⌃⌘Q sul Mac blocca anche il PC, e la scorciatoia
  "blocca tutte le macchine" del PC blocca anche il Mac. Funziona anche sulle schermate
  di blocco e di accesso di Windows.
- **Stop e risveglio**: il PC sa subito quando il Mac va in stop e la connessione
  riprende al risveglio; a scelta ciascun computer tiene sveglio l'altro mentre si lavora.
- App da barra menu con finestra delle impostazioni, in italiano e inglese (segue la
  lingua di sistema); strumento da riga di comando per la diagnosi.

Non previsti: controllo del Mac dal PC (in programma), trasferimento di file e
trascinamento fra le macchine.

## Requisiti

- macOS 13 Ventura o successivo.
- Xcode oppure i soli Command Line Tools (`xcode-select --install`), Swift 5.9 o
  successivo.
- Un PC Windows con PowerToys e Mouse Without Borders attivo, sulla stessa rete locale.

## Compilazione e installazione

Non vengono distribuiti binari: l'app si compila e si firma sul proprio Mac, con un
certificato autofirmato locale valido solo su quel Mac.

```bash
git clone https://github.com/fcelsa/mwbmac.git
```

```bash
cd mwbmac
```

Creazione del certificato di firma locale (una volta sola):

```bash
scripts/create-signing-cert.sh
```

Aggiunge al portachiavi di login un certificato autofirmato "mwbmac local signing". Senza
certificato l'app viene firmata ad hoc: funziona, ma macOS considera ogni build un'app
diversa e i due permessi descritti sotto vanno tolti e riconcessi dopo ogni
ricompilazione. Al primo uso macOS chiede di autorizzare `codesign` a usare la chiave.

Compilazione, firma e installazione in `/Applications`:

```bash
scripts/build-app.sh --install
```

Altre opzioni: `--run` avvia l'app al termine, `--debug` compila in debug. Senza
`--install` l'app resta in `build/MWB Mac Host.app`.

Avviare **MWB Mac Host** da `/Applications`: vive solo nella barra menu. Al primo avvio
chiede due permessi in Impostazioni di Sistema → Privacy e sicurezza, **Accessibilità** e
**Monitoraggio input**, e parte da sola appena vengono concessi.

## Configurazione

**Sul PC**, in PowerToys → Mouse Without Borders:

- annotare la **security key**, da inserire sul Mac;
- aggiungere il nome del Mac nella disposizione dei dispositivi, dal lato coerente con il
  bordo scelto sul Mac (PC a destra del Mac → Mac a sinistra del PC);
- disattivare "Reverse DNS lookup" se la risoluzione dei nomi non funziona;
- aprire le porte 15100 e 15101 nel firewall di Windows.

Il PC deve risolvere il nome del Mac: di solito funziona `nome.local` (mDNS), altrimenti
basta una voce nel file `hosts` del PC.

**Sul Mac**, Impostazioni… dall'icona nella barra menu:

- **Connessione**: nome o indirizzo del PC, nome del Mac (quello nella disposizione del
  PC), security key (salvata solo nel Portachiavi);
- **Bordo dello schermo**: lato del PC e tratto del bordo che porta al PC, con uno schema
  che mostra il risultato;
- **Tastiera e mouse**, **Condivisione e blocco**: mappatura dei tasti, appunti, blocco
  sincronizzato, stop.

L'icona mostra lo stato: disattivato, in attesa del PC, connesso, controllo sul PC,
oppure un problema (permessi mancanti, chiave assente o sbagliata).

> **Mai provare apposta una chiave sbagliata.** Dopo dieci pacchetti non validi PowerToys
> considera la chiave non valida e smette di aprire connessioni finché non viene
> riavviato. Se la chiave non coincide l'app lo segnala e non riprova.

## Uso

- Spingendo il cursore oltre il bordo si passa al PC; superando il bordo opposto dello
  schermo del PC si torna al Mac.
- **⌃⌥⌘Esc** (configurabile) riporta sempre il controllo al Mac e, dal Mac, passa
  manualmente al PC. Mentre si controlla il PC l'input del Mac è soppresso: tenere a
  mente questa scorciatoia.
- Il menu offre anche "Passa al PC / Torna al Mac", "Attivo" e "Avvia al login".

### Appunti

Si copia da una parte e si incolla dall'altra. Sul PC deve essere attiva l'opzione
"Share clipboard" di Mouse Without Borders.

- Fino a 1 MB il contenuto parte subito, sul canale dei messaggi.
- Oltre (tipicamente le catture schermo) viaggia sul canale appunti, porta 15100: dal PC
  al Mac viene ritirato appena copiato; dal Mac al PC è PowerToys a ritirarlo nel momento
  in cui il controllo passa al PC.
- Le immagini arrivano sul PC come PNG a 8 bit in sRGB; sul Mac vengono offerte come PNG
  e TIFF.
- Restano fuori i file copiati nel Finder o in Esplora risorse, il trascinamento e i
  contenuti che i gestori di password marcano come riservati.

### Blocco schermo

Si basa sulla scorciatoia "blocca tutte le macchine" di Mouse Without Borders, che premuta
due volte blocca tutte le macchine con la stessa impostazione. In PowerToys è
configurabile e la predefinita è **Win+Ctrl+Alt+L**; quella impostata sul Mac deve
coincidere.

- **⌃⌘Q sul Mac** blocca il Mac e invia al PC la scorciatoia "blocca tutte le macchine".
- **Win+L inviato al PC** mentre lo si controlla (⌃L con la mappatura predefinita) blocca
  il PC e anche il Mac.
- **La scorciatoia premuta due volte sul PC** blocca il PC e anche il Mac.

Non si sincronizza ciò che Mouse Without Borders non trasmette: Win+L premuto sulla
tastiera del PC, e il blocco del Mac dal menu Apple, da Touch ID, dagli angoli attivi o
dallo stop.

Il controllo funziona anche sulle schermate di blocco e di accesso di Windows, e si può
digitare la password. Quando Windows cambia desktop (blocco, sblocco, click sulla
schermata di blocco) Mouse Without Borders chiude tutte le connessioni e si ricollega in
meno di un secondo: il Mac resta in controllo del PC per 3 s in attesa che si ricolleghi,
come fa PowerToys fra due PC.

### Stop e salvaschermo

- **Il Mac va in stop**: il controllo torna al Mac e il PC viene avvisato subito; al
  risveglio la sessione riparte e si ricollega appena la rete è disponibile.
- **Tenere svegli gli altri computer** (come "Block screen saver on other machines" di
  Mouse Without Borders): mentre si lavora sul Mac, un messaggio al minuto impedisce al PC
  di andare in stop; se sul PC è attiva la stessa opzione, l'attività sul PC tiene
  sveglio il Mac (ma non riaccende uno schermo spento e non tocca la schermata di blocco).

## Preferenze

Stanno in `~/Library/Application Support/mwbmac/config.json`, condivise da app e riga di
comando; la finestra delle impostazioni le copre tutte. Le chiavi sono descritte nella
[tabella della sezione inglese](#settings).

## Log e problemi

L'app scrive in `~/Library/Logs/mwbmac/mwbmac.log` (leggibile solo dall'utente; mai il
contenuto degli appunti né la security key), in inglese. Normalmente registra solo errori,
avvio e prima connessione con ciascuna macchina. Per la diagnosi dettagliata:

```bash
defaults write local.mwbmac.host verbose -bool true
```

e riavviare l'app (`defaults delete local.mwbmac.host verbose` la disattiva).

Lo strumento da riga di comando `mwbmac` viaggia nel bundle
(`MWB Mac Host.app/Contents/MacOS/mwbmac`) e condivide preferenze e chiave con l'app;
comandi e opzioni sono descritti nella sezione inglese. Prima di usare `probe` o `run`
chiudere l'app: usano la stessa porta e lo stesso MachineId.

Problemi frequenti:

- **"In attesa del PC…" senza fine**: controllare nome del PC, firewall (15100–15101) e
  che il nome del Mac sia nella disposizione del PC e risolvibile dal PC.
- **"Security key diversa da quella del PC"**: reinserirla nelle impostazioni, poi
  riavviare PowerToys sul PC se ha smesso di collegarsi.
- **Il cursore non torna dal PC**: nella disposizione del PC il Mac deve stare dal lato
  opposto al bordo scelto sul Mac.
- **Universal Control** usa anch'esso i bordi dello schermo: non mettere un iPad o un
  altro Mac sullo stesso bordo del PC.

## Sviluppo

`swift build` e `swift test` bastano, anche con i soli Command Line Tools (i test usano
Swift Testing, non XCTest); la sezione inglese riporta il rimedio per l'errore
"plugin for module 'TestingMacros' not found". Analisi del protocollo:
[docs/analisi.md](docs/analisi.md). Le traduzioni dell'interfaccia stanno in
`Sources/MWBMacHost/Resources/<lingua>.lproj`, con il testo inglese come chiave;
`scripts/check-localization.sh` segnala quelle mancanti.

## Licenza

[MIT](LICENSE).
