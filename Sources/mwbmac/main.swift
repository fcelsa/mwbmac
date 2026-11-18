// mwbmac — client macOS per Mouse Without Borders (PowerToys), riga di comando.
//
//   mwbmac set-key              salva la security key nel Keychain (letta senza eco)
//   mwbmac config               mostra il file delle preferenze e i valori correnti
//   mwbmac probe                solo trasporto: connessione, handshake, heartbeat
//   mwbmac run                  controllo completo con cattura dell'input
//
// Messaggi e log in inglese; l'app da barra menu è `MWBMacHost`.

import AppKit
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
    Usage: mwbmac <command> [options]

    Commands:
      set-key        Store the Mouse Without Borders security key in the Keychain
      delete-key     Remove the security key from the Keychain
      config         Show the settings file path and contents
      probe          Transport only: connect to the PC, complete the handshake and stay
                     in the machine pool sending heartbeats (no input capture)
      run            Full control: screen edge, mouse and keyboard to the PC

    Options:
      --host <name>      PC name or address (saved in the settings)
      --name <name>      Name the Mac presents itself with (saved in the settings)
      --edge <edge>      left | right | top | bottom (saved in the settings)
      --verbose          Detailed diagnostic messages (default: errors and startup only)
      --log-protocol     Print every packet sent and received in clear text
      --no-listen        Do not open the listener on the message port (base+1)
      --duration <s>     Exit by itself after the given seconds (for testing)

    While the PC is controlled the Mac's input is suppressed: the emergency
    shortcut (default ⌃⌥⌘Esc) always brings control back to the Mac.
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
        guard index < arguments.count else { fail("missing value for \(flag)") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--host": options.host = value(for: argument)
        case "--name": options.name = value(for: argument)
        case "--edge":
            let raw = value(for: argument)
            guard let edge = ScreenEdge(rawValue: raw) else { fail("invalid edge: \(raw)") }
            options.edge = edge
        case "--log-protocol": options.logProtocol = true
        case "--verbose": options.verbose = true
        case "--no-listen": options.noListen = true
        case "--duration":
            guard let seconds = TimeInterval(value(for: argument)) else { fail("invalid duration") }
            options.duration = seconds
        case "-h", "--help": options.command = "help"
        default: fail("unknown option: \(argument)")
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
        fail("unreadable settings (\(Settings.defaultURL.path)): \(error)")
    }
    let original = settings
    if let host = options.host { settings.remoteHost = host }
    if let name = options.name { settings.localName = name }
    if let edge = options.edge { settings.edge = edge }
    if settings != original {
        do { try settings.save() } catch { fail("cannot save the settings: \(error)") }
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
            fail("no security key: run `mwbmac set-key` first")
        }
        return key
    } catch {
        fail("\(error)")
    }
}

func setKey() {
    guard let raw = getpass("Mouse Without Borders security key (not shown): ") else {
        fail("cannot read the key")
    }
    let key = KeyDerivation.normalize(securityKey: String(cString: raw))
    // Stessa regola di `Encryption.IsKeyValid`.
    guard key.count >= 16 else { fail("the key must be at least 16 characters long (spaces do not count)") }
    do {
        try KeychainStore.writeSecurityKey(key)
        print("Key saved in the Keychain (service \"\(KeychainStore.service)\").")
    } catch {
        fail("\(error)")
    }
}

func makeSession(settings: Settings, options: Options, log: Log) -> Session {
    guard !settings.remoteHost.isEmpty else {
        fail("PC name not configured: use --host <name>")
    }
    var configuration = Session.Configuration(
        localName: settings.localName,
        machineID: settings.machineID,
        securityKey: loadSecurityKey(),
        remoteHost: settings.remoteHost,
        basePort: settings.basePort,
        listenPort: options.noListen ? nil : settings.basePort + 1)
    if settings.shareClipboard, !options.noListen { configuration.clipboardListenPort = settings.basePort }
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

/// Sessione e controller di `run`, ricreati al risveglio del Mac.
final class Runner {
    private let settings: Settings
    private let options: Options
    private let log: Log
    private var session: Session?
    private var controller: Controller?
    private var suspendedForSleep = false

    init(settings: Settings, options: Options, log: Log) {
        self.settings = settings
        self.options = options
        self.log = log
    }

    func start() throws {
        let session = makeSession(settings: settings, options: options, log: log)
        let controller = Controller(settings: settings, session: session, log: log)
        try controller.start()
        session.start()
        self.session = session
        self.controller = controller
    }

    func stop() {
        controller?.stop()
        session?.stop()
        controller = nil
        session = nil
    }

    /// Come l'app: ByeBye prima dello stop, nuova sessione al risveglio.
    func observeSleep() -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        return [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [self] _ in
                guard session != nil else { return }
                log.info("The Mac is going to sleep: closing the session with the PC")
                suspendedForSleep = true
                stop()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [self] _ in
                guard suspendedForSleep else { return }
                suspendedForSleep = false
                log.info("The Mac woke up: reopening the session with the PC")
                do { try start() } catch { log.error("Restart after wake failed: \(error)") }
            },
        ]
    }
}

let options = parseOptions()
let log = Log(verbose: options.verbose, protocolEnabled: options.logProtocol)

switch options.command {
case "set-key":
    setKey()

case "delete-key":
    do { try KeychainStore.deleteSecurityKey() } catch { fail("\(error)") }
    print("Key removed from the Keychain.")

case "config":
    let settings = loadSettings(applying: options)
    print("Settings: \(Settings.defaultURL.path)")
    if let text = try? String(contentsOf: Settings.defaultURL, encoding: .utf8) { print(text) }
    // Solo la forma della chiave, mai il valore: le chiavi generate da MWB hanno 16 caratteri.
    if let key = (try? KeychainStore.readSecurityKey()) ?? nil {
        let ascii = key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
        print("Security key in the Keychain: present, \(key.count) characters\(ascii ? "" : ", contains non-ASCII or control characters")")
    } else {
        print("Security key in the Keychain: missing")
    }
    print("Emergency shortcut: \(settings.hotkey.description)")

case "probe":
    let settings = loadSettings(applying: options)
    let session = makeSession(settings: settings, options: options, log: log)
    log.notice("mwbmac probe: \"\(settings.localName)\" (id \(settings.machineID)) → \(settings.remoteHost):\(settings.basePort + 1)")
    session.onMachineConnected = { machine in
        log.notice("Handshake completed: the Mac is in the machine pool of \"\(machine.name)\"")
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
        missing permissions (\(accessibility ? "" : "Accessibility ")\(monitoring ? "" : "Input Monitoring")).
        Grant them in System Settings → Privacy & Security to the application that launches
        mwbmac (Terminal, iTerm, …), then restart it and run the command again.
        """)
    }
    let runner = Runner(settings: settings, options: options, log: log)
    do {
        try runner.start()
    } catch {
        fail("\(error)")
    }
    log.notice("mwbmac: \"\(settings.localName)\" → \(settings.remoteHost), PC beyond the \(settings.edge.rawValue) edge, "
        + "emergency shortcut \(settings.hotkey.description)")
    log.info("Switch delay \(settings.switchDelayMs) ms, edge resistance \(settings.edgeResistancePx) px")
    let signals = installExitHandlers(duration: options.duration) { runner.stop() }
    let sleepObservers = runner.observeSleep()
    // Serve un vero ciclo di eventi AppKit: per nascondere e bloccare il cursore il
    // processo deve poter passare in primo piano (vedi `LocalCursor`).
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    withExtendedLifetime((signals, sleepObservers)) { application.run() }

default:
    printUsage()
}
