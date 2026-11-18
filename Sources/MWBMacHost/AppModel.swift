// Stato dell'app: preferenze, sessione MWB e macchina di stato locale/remoto.
// Tutto sul thread principale.

import AppKit
import Combine
import Foundation
import MWBEdgeLogic
import MWBInputCapture
import MWBTransport
import ServiceManagement

final class AppModel: ObservableObject {
    enum Status: Equatable {
        case disabled
        case missingHost
        case missingKey
        case missingPermissions
        case invalidKey
        case connecting
        case connected(String)
        case remote(String)

        var text: String {
            switch self {
            case .disabled: return L("Off")
            case .missingHost: return L("PC name not set")
            case .missingKey: return L("Security key not set")
            case .missingPermissions: return L("Permissions missing")
            case .invalidKey: return L("Security key doesn't match the PC")
            case .connecting: return L("Waiting for the PC…")
            case .connected(let name): return L("Connected to %@", name)
            case .remote(let name): return L("Controlling %@", name)
            }
        }
    }

    @Published private(set) var settings: MWBEdgeLogic.Settings
    @Published private(set) var status: Status = .disabled
    @Published private(set) var hasSecurityKey = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var enabled: Bool

    private var session: Session?
    private var controller: Controller?
    private var log: Log?
    /// La sessione è stata chiusa per lo stop del Mac e va riaperta al risveglio.
    private var suspendedForSleep = false
    /// Chiave dell'ultima sessione, solo in memoria, per riaprirla al risveglio.
    private var keyForResume: String?
    private var sleepObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var promptedForPermissions = false
    private static let enabledKey = "enabled"
    /// Registro su file (~/Library/Logs/mwbmac/mwbmac.log): un'app da barra menu non ha
    /// un terminale su cui scrivere.
    static let logFile = LogFile()

    init() {
        settings = (try? Settings.load()) ?? Settings()
        UserDefaults.standard.register(defaults: [AppModel.enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: AppModel.enabledKey)
        observeSleep()
    }

    deinit {
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: Stop e risveglio

    /// Prima dello stop il controllo torna al Mac e il PC riceve `ByeBye`, così sa subito
    /// che il Mac non c'è più (`Common.ProcessByeByeMessage`) invece di accorgersene allo
    /// scadere degli heartbeat. Al risveglio la sessione riparte e si ricollega appena la
    /// rete è disponibile (la riconnessione ritenta ogni pochi secondi).
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.session != nil else { return }
            self.log?.info("The Mac is going to sleep: closing the session with the PC")
            self.suspendedForSleep = true
            self.stop()
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.suspendedForSleep else { return }
            self.suspendedForSleep = false
            self.start(resumingFromSleep: true)
            self.log?.info("The Mac woke up: reopening the session with the PC")
        })
    }

    var isRemote: Bool {
        if case .remote = status { return true }
        return false
    }

    var canSwitchManually: Bool {
        switch status {
        case .connected, .remote: return true
        default: return false
        }
    }

    // MARK: Azioni

    func setEnabled(_ value: Bool) {
        suspendedForSleep = false
        enabled = value
        UserDefaults.standard.set(value, forKey: AppModel.enabledKey)
        restart()
    }

    /// Salva le preferenze e riavvia la sessione con i nuovi valori.
    func apply(_ newSettings: MWBEdgeLogic.Settings) throws {
        try newSettings.save()
        settings = newSettings
        restart()
    }

    /// Salva la security key nel Keychain (mai nelle preferenze) e riavvia.
    func saveSecurityKey(_ key: String) throws {
        try KeychainStore.writeSecurityKey(key)
        restart()
    }

    func toggleRemote() {
        controller?.toggleManually()
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        controller?.stop()
        session?.stop()
        controller = nil
        session = nil
        log = nil
        status = .disabled
    }

    func start() {
        start(resumingFromSleep: false)
    }

    private func start(resumingFromSleep: Bool) {
        guard enabled else {
            status = .disabled
            return
        }
        guard !settings.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = .missingHost
            return
        }
        // Prima i permessi: mentre si aspetta che l'utente li conceda non si tocca il Keychain.
        guard hasPermissions(prompt: !promptedForPermissions) else {
            promptedForPermissions = true
            status = .missingPermissions
            schedulePermissionCheck()
            return
        }
        let key: String
        do {
            guard let stored = try KeychainStore.readSecurityKey(), !stored.isEmpty else {
                hasSecurityKey = false
                status = .missingKey
                return
            }
            key = stored
            hasSecurityKey = true
        } catch {
            // Con "blocca il portachiavi dopo lo stop" il Keychain può essere ancora chiuso
            // al risveglio: si riusa la chiave della sessione appena chiusa.
            guard resumingFromSleep, let previous = keyForResume else {
                lastMessage = "\(error)"
                status = .missingKey
                return
            }
            key = previous
        }
        keyForResume = key

        // Normalmente solo errori, avvio e prima connessione con ciascuna macchina;
        // `defaults write local.mwbmac.host verbose -bool true` attiva i messaggi di diagnosi.
        let log = Log(verbose: UserDefaults.standard.bool(forKey: "verbose"))
        let standardSink = log.sink
        let logFile = AppModel.logFile
        log.sink = { [weak self] line in
            standardSink(line)
            logFile.append(line)
            DispatchQueue.main.async { self?.lastMessage = line }
        }
        var configuration = Session.Configuration(localName: settings.localName, machineID: settings.machineID,
                                                  securityKey: key, remoteHost: settings.remoteHost,
                                                  basePort: settings.basePort, listenPort: settings.basePort + 1)
        if settings.shareClipboard { configuration.clipboardListenPort = settings.basePort }
        let session = Session(configuration: configuration, log: log)
        let controller = Controller(settings: settings, session: session, log: log)
        controller.onStateChange = { [weak self] _ in self?.refreshStatus() }
        controller.onMachinesChanged = { [weak self] _ in self?.refreshStatus() }
        controller.onInvalidKey = { [weak self] in self?.status = .invalidKey }
        do {
            try controller.start()
        } catch {
            // Il tap non parte se il permesso Accessibilità è stato revocato nel frattempo.
            log.error("\(error)")
            lastMessage = "\(error)"
            status = .missingPermissions
            schedulePermissionCheck()
            return
        }
        self.session = session
        self.controller = controller
        self.log = log
        status = .connecting
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log.notice("MWB Mac Host \(version) started: \"\(settings.localName)\" → \(settings.remoteHost), "
            + "PC beyond the \(settings.edge.rawValue) edge")
        session.start()
    }

    private func refreshStatus() {
        guard let controller, let session, status != .invalidKey else { return }
        if case .remote(let machine) = controller.state {
            status = .remote(machine.name)
        } else if let machine = session.connectedMachines.first {
            status = .connected(machine.name)
        } else {
            status = .connecting
        }
    }

    // MARK: Permessi

    var hasAccessibility: Bool { InputPermissions.hasAccessibility(prompt: false) }
    var hasInputMonitoring: Bool { InputPermissions.hasInputMonitoring(prompt: false) }

    private func hasPermissions(prompt: Bool) -> Bool {
        let accessibility = InputPermissions.hasAccessibility(prompt: prompt)
        let monitoring = InputPermissions.hasInputMonitoring(prompt: prompt)
        return accessibility && monitoring
    }

    /// Riprova finché l'utente non concede i permessi in Impostazioni di Sistema.
    private func schedulePermissionCheck() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.hasPermissions(prompt: false) else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.start()
        }
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Avvio al login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastMessage = L("Open at login: %@", error.localizedDescription)
        }
        objectWillChange.send()
    }
}
