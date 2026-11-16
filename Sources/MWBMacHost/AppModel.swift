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
            case .disabled: return "Disattivato"
            case .missingHost: return "Nome del PC non configurato"
            case .missingKey: return "Security key non impostata"
            case .missingPermissions: return "Permessi mancanti"
            case .invalidKey: return "Security key diversa da quella del PC"
            case .connecting: return "In attesa del PC…"
            case .connected(let name): return "Connesso a \(name)"
            case .remote(let name): return "Controllo su \(name)"
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
    private var permissionTimer: Timer?
    private var promptedForPermissions = false
    private static let enabledKey = "enabled"

    init() {
        settings = (try? Settings.load()) ?? Settings()
        UserDefaults.standard.register(defaults: [AppModel.enabledKey: true])
        enabled = UserDefaults.standard.bool(forKey: AppModel.enabledKey)
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
        status = .disabled
    }

    func start() {
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
            lastMessage = "\(error)"
            status = .missingKey
            return
        }

        let log = Log()
        let standardSink = log.sink
        log.sink = { [weak self] line in
            standardSink(line)
            DispatchQueue.main.async { self?.lastMessage = line }
        }
        let configuration = Session.Configuration(localName: settings.localName, machineID: settings.machineID,
                                                  securityKey: key, remoteHost: settings.remoteHost,
                                                  basePort: settings.basePort, listenPort: settings.basePort + 1)
        let session = Session(configuration: configuration, log: log)
        let controller = Controller(settings: settings, session: session, log: log)
        controller.onStateChange = { [weak self] _ in self?.refreshStatus() }
        controller.onMachinesChanged = { [weak self] _ in self?.refreshStatus() }
        controller.onInvalidKey = { [weak self] in self?.status = .invalidKey }
        do {
            try controller.start()
        } catch {
            // Il tap non parte se il permesso Accessibilità è stato revocato nel frattempo.
            lastMessage = "\(error)"
            status = .missingPermissions
            schedulePermissionCheck()
            return
        }
        self.session = session
        self.controller = controller
        status = .connecting
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
            lastMessage = "Avvio al login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}
