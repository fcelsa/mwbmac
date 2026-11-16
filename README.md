# mwbmac

Client macOS nativo (Swift, zero dipendenze) per controllare un PC Windows con
**PowerToys → Mouse Without Borders** usando tastiera e mouse del Mac. Sul PC non va
installato nulla oltre a PowerToys. Analisi e protocollo: [docs/analisi.md](docs/analisi.md).

Stato: fasi 1–4 della roadmap implementate come strumento da riga di comando
(protocollo, trasporto, input remoto, cambio macchina). L'app da barra menu è la fase 5.

## Compilazione e test

```bash
swift build
```

```bash
swift test
```

Bastano i Command Line Tools: i test usano Swift Testing, non XCTest.

## Preparazione

Sul PC: Mouse Without Borders attivo, il nome del Mac (`mwbmac config` lo mostra come
`localName`) inserito nella matrice dal lato coerente con il bordo scelto sul Mac,
"Reverse DNS lookup" disattivato, porte 15100/15101 aperte.

Sul Mac, una volta sola:

```bash
.build/debug/mwbmac set-key
```

chiede la security key di MWB (senza mostrarla) e la salva nel Keychain.

```bash
.build/debug/mwbmac config --host winpc --edge right
```

salva nome del PC e bordo in `~/Library/Application Support/mwbmac/config.json`.

## Uso

Solo trasporto (handshake, heartbeat, presenza nel machine pool; nessun permesso richiesto):

```bash
.build/debug/mwbmac probe --verbose
```

Controllo completo:

```bash
.build/debug/mwbmac run
```

`run` richiede i permessi **Accessibilità** e **Monitoraggio input** per l'applicazione
da cui viene lanciato (Terminale, iTerm…). Spingendo il cursore oltre il bordo
configurato il controllo passa al PC; torna al Mac quando il cursore del PC supera il
bordo opposto (è Windows a deciderlo, con `NextMachine`).

**Scorciatoia di emergenza: ⌃⌥⌘Esc** — riporta sempre l'input al Mac (e, dal Mac, passa
manualmente al PC). In stato remoto l'input locale è soppresso: tenerla a mente.

`--log-protocol` stampa in chiaro ogni pacchetto inviato e ricevuto.

## Preferenze

| Chiave | Significato | Predefinito |
|---|---|---|
| `remoteHost`, `basePort` | PC e porta base di MWB | —, 15100 |
| `localName` | nome con cui il Mac si presenta (quello nella matrice del PC) | nome host |
| `edge` | bordo del Mac oltre il quale sta il PC: `left` `right` `top` `bottom` | `right` |
| `switchDelayMs` | ritardo di spostamento: spinta continua minima sul bordo | 150 |
| `edgeResistancePx` | resistenza: pixel di spinta da accumulare | 30 |
| `edgeStart`, `edgeEnd` | porzione attiva del bordo (0…1) per schermi non allineati | 0, 1 |
| `windowsLayout` | layout di tastiera del PC: `it` o `us` | `it` |
| `commandKey`, `controlKey`, `optionKey` | cosa diventano ⌘ ⌃ ⌥: `ctrl` `win` `alt` | `ctrl`, `win`, `alt` |
| `rightOptionIsAltGr` | ⌥ destro come AltGr (`@ # [ ] { }` su layout italiano) | `true` |
| `invertScroll` | inverte il verso della rotella | `false` |
| `hotkey` | scorciatoia di emergenza (keycode macOS + modificatori) | ⌃⌥⌘Esc |

## Struttura

| Modulo | Contenuto |
|---|---|
| `MWBProtocol` | pacchetti 32/64 byte, checksum, magic, PBKDF2/AES, handshake |
| `MWBTransport` | listener 15101, connessione uscente con riconnessione, heartbeat, machine pool |
| `MWBInputCapture` | CGEventTap, mappa keycode → VK Windows, traduzione mouse/rotella/tasti |
| `MWBEdgeLogic` | rilevamento del bordo, preferenze, Keychain, macchina di stato locale/remoto |
| `mwbmac` | riga di comando |

Fuori perimetro per ora: appunti e trasferimento file.
