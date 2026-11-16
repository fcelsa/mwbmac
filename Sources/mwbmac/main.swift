// mwbmac — client macOS per Mouse Without Borders (PowerToys), riga di comando.
//
//   mwbmac set-key              salva la security key nel Keychain (letta senza eco)
//   mwbmac config               mostra il file delle preferenze e i valori correnti
//   mwbmac probe                solo trasporto: connessione, handshake, heartbeat
//   mwbmac run                  controllo completo con cattura dell'input
//
// Il bundle .app con barra menu arriva nella fase 5 della roadmap.

import Darwin
import Foundation
import MWBEdgeLogic
import MWBInputCapture
import MWBProtocol
import MWBTransport

struct Options {
    var command = "help"
    var host: String?
    var name: String?
    var edge: ScreenEdge?
    var logProtocol = false
    var verbose = false
    var noListen = false
    var duration: TimeInterval?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mwbmac: \(message)\n".utf8))
    exit(1)
}

func printUsage() {
    print("""
    Uso: mwbmac <comando> [opzioni]

    Comandi:
      set-key        Salva nel Keychain la security key di Mouse Without Borders
      delete-key     Rimuove la security key dal Keychain
      config         Mostra percorso e contenuto delle preferenze
      probe          Solo trasporto: si connette al PC, completa l'handshake e resta nel
                     machine pool inviando heartbeat (nessuna cattura dell'input)
      run            Controllo completo: bordo dello schermo, mouse e tastiera verso il PC

    Opzioni:
      --host <nome>      Nome o indirizzo del PC (salvato nelle preferenze)
      --name <nome>      Nome con cui il Mac si presenta (salvato nelle preferenze)
      --edge <bordo>     left | right | top | bottom (salvato nelle preferenze)
      --log-protocol     Stampa in chiaro ogni pacchetto inviato e ricevuto
      --verbose          Messaggi di diagnosi
      --no-listen        Non apre il listener sulla porta messaggi (base+1)
      --duration <s>     Termina da solo dopo i secondi indicati (per le prove)

    In stato remoto l'input del Mac è soppresso: la scorciatoia di emergenza
    (predefinita ⌃⌥⌘Esc) riporta sempre il controllo al Mac.
    """)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let first = arguments.first, !first.hasPrefix("-") {
        options.command = first
        arguments.removeFirst()
    }
    var index = 0
    func value(for flag: String) -> String {
        index += 1
        guard index < arguments.count else { fail("manca il valore di \(flag)") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--host": options.host = value(for: argument)
        case "--name": options.name = value(for: argument)
        case "--edge":
            let raw = value(for: argument)
            guard let edge = ScreenEdge(rawValue: raw) else { fail("bordo non valido: \(raw)") }
            options.edge = edge
        case "--log-protocol": options.logProtocol = true
        case "--verbose": options.verbose = true
        case "--no-listen": options.noListen = true
        case "--duration":
            guard let seconds = TimeInterval(value(for: argument)) else { fail("durata non valida") }
            options.duration = seconds
        case "-h", "--help": options.command = "help"
        default: fail("opzione sconosciuta: \(argument)")
        }
        index += 1
    }
    return options
}

func loadSettings(applying options: Options) -> Settings {
    var settings: Settings
    do {
        settings = try Settings.load()
    } catch {
        fail("preferenze illeggibili (\(Settings.defaultURL.path)): \(error)")
    }
    let original = settings
    if let host = options.host { settings.remoteHost = host }
    if let name = options.name { settings.localName = name }
    if let edge = options.edge { settings.edge = edge }
    if settings != original {
        do { try settings.save() } catch { fail("impossibile salvare le preferenze: \(error)") }
    }
    return settings
}

/// La chiave vive nel Keychain. `MWB_SECURITY_KEY` nell'ambiente la sostituisce solo
/// per diagnosi e prove automatiche.
func loadSecurityKey() -> String {
    if let key = ProcessInfo.processInfo.environment["MWB_SECURITY_KEY"], !key.isEmpty {
        return KeyDerivation.normalize(securityKey: key)
    }
    do {
        guard let key = try KeychainStore.readSecurityKey(), !key.isEmpty else {
            fail("security key assente: eseguire prima `mwbmac set-key`")
        }
        return key
    } catch {
        fail("\(error)")
    }
}

func setKey() {
    guard let raw = getpass("Security key di Mouse Without Borders (non viene mostrata): ") else {
        fail("lettura della chiave fallita")
    }
    let key = KeyDerivation.normalize(securityKey: String(cString: raw))
    // Stessa regola di `Encryption.IsKeyValid`.
    guard key.count >= 16 else { fail("la chiave deve avere almeno 16 caratteri (gli spazi non contano)") }
    do {
        try KeychainStore.writeSecurityKey(key)
        print("Chiave salvata nel Keychain (servizio \"\(KeychainStore.service)\").")
    } catch {
        fail("\(error)")
    }
}

func makeSession(settings: Settings, options: Options, log: Log) -> Session {
    guard !settings.remoteHost.isEmpty else {
        fail("nome del PC non configurato: usare --host <nome>")
    }
    let configuration = Session.Configuration(
        localName: settings.localName,
        machineID: settings.machineID,
        securityKey: loadSecurityKey(),
        remoteHost: settings.remoteHost,
        basePort: settings.basePort,
        listenPort: options.noListen ? nil : settings.basePort + 1)
    return Session(configuration: configuration, log: log)
}

/// Esegue `cleanup` su SIGINT/SIGTERM e allo scadere di `--duration`, poi esce.
func installExitHandlers(duration: TimeInterval?, cleanup: @escaping () -> Void) -> [DispatchSourceSignal] {
    let finish: () -> Void = {
        cleanup()
        // Lascia partire ByeBye e HideMouse prima di chiudere il processo.
        Thread.sleep(forTimeInterval: 0.4)
        exit(0)
    }
    let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: finish)
        source.resume()
        return source
    }
    if let duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
    }
    return sources
}

let options = parseOptions()
let log = Log(protocolEnabled: options.logProtocol, debugEnabled: options.verbose)

switch options.command {
case "set-key":
    setKey()

case "delete-key":
    do { try KeychainStore.deleteSecurityKey() } catch { fail("\(error)") }
    print("Chiave rimossa dal Keychain.")

case "config":
    let settings = loadSettings(applying: options)
    print("Preferenze: \(Settings.defaultURL.path)")
    if let text = try? String(contentsOf: Settings.defaultURL, encoding: .utf8) { print(text) }
    // Solo la forma della chiave, mai il valore: le chiavi generate da MWB hanno 16 caratteri.
    if let key = (try? KeychainStore.readSecurityKey()) ?? nil {
        let ascii = key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
        print("Security key nel Keychain: presente, \(key.count) caratteri\(ascii ? "" : ", contiene caratteri non ASCII o di controllo")")
    } else {
        print("Security key nel Keychain: assente")
    }
    print("Scorciatoia di emergenza: \(settings.hotkey.description)")

case "probe":
    let settings = loadSettings(applying: options)
    let session = makeSession(settings: settings, options: options, log: log)
    log.info("mwbmac probe: \"\(settings.localName)\" (id \(settings.machineID)) → \(settings.remoteHost):\(settings.basePort + 1)")
    session.onMachineConnected = { machine in
        log.info("Handshake completato: il Mac è nel machine pool di \"\(machine.name)\"")
    }
    session.start()
    let signals = installExitHandlers(duration: options.duration) { session.stop() }
    withExtendedLifetime(signals) { RunLoop.main.run() }

case "run":
    let settings = loadSettings(applying: options)
    // Il tap attivo richiede Accessibilità; Monitoraggio input serve a ricevere i tasti.
    let accessibility = InputPermissions.hasAccessibility(prompt: true)
    let monitoring = InputPermissions.hasInputMonitoring(prompt: true)
    guard accessibility, monitoring else {
        fail("""
        permessi mancanti (\(accessibility ? "" : "Accessibilità ")\(monitoring ? "" : "Monitoraggio input")).
        Concederli in Impostazioni di Sistema → Privacy e sicurezza all'applicazione da cui
        viene lanciato mwbmac (Terminale, iTerm, …), poi riavviarla e rilanciare il comando.
        """)
    }
    let session = makeSession(settings: settings, options: options, log: log)
    let controller = Controller(settings: settings, session: session, log: log)
    do {
        try controller.start()
    } catch {
        fail("\(error)")
    }
    log.info("mwbmac: \"\(settings.localName)\" → \(settings.remoteHost), PC oltre il bordo \(settings.edge.rawValue), "
        + "ritardo \(settings.switchDelayMs) ms, resistenza \(settings.edgeResistancePx) px")
    log.info("Scorciatoia di emergenza / cambio manuale: \(settings.hotkey.description)")
    session.start()
    let signals = installExitHandlers(duration: options.duration) {
        controller.stop()
        session.stop()
    }
    withExtendedLifetime(signals) { RunLoop.main.run() }

default:
    printUsage()
}
