// Finestra Impostazioni. Le modifiche restano in una bozza finché non si preme "Applica":
// applicarle riavvia la sessione con il PC.

import MWBEdgeLogic
import MWBInputCapture
import SwiftUI

/// Bozza delle impostazioni in modifica. È un oggetto osservabile e non `@State` perché
/// nell'SDK corrente `@State` è una macro il cui plugin manca nei Command Line Tools.
final class SettingsDraft: ObservableObject {
    @Published var settings: MWBEdgeLogic.Settings
    @Published var basePortText: String
    @Published var newKey = ""
    @Published var message = ""
    @Published var messageIsError = false

    init(settings: MWBEdgeLogic.Settings) {
        self.settings = settings
        self.basePortText = String(settings.basePort)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SettingsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                connectionTab.tabItem { Label("Connessione", systemImage: "network") }
                edgeTab.tabItem { Label("Bordo", systemImage: "rectangle.righthalf.inset.filled.arrow.right") }
                keyboardTab.tabItem { Label("Tastiera", systemImage: "keyboard") }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider().padding(.top, 12)
            HStack {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(model.status.text).foregroundStyle(.secondary)
                Spacer()
                if !state.message.isEmpty {
                    Text(state.message).foregroundStyle(state.messageIsError ? .red : .secondary).lineLimit(2)
                }
                Button("Applica") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
            .padding(16)
        }
        .frame(width: 520, height: 470)
    }

    // MARK: Schede

    private var connectionTab: some View {
        Form {
            Section("PC con Mouse Without Borders") {
                TextField("Nome o indirizzo del PC", text: $state.settings.remoteHost)
                TextField("Porta base", text: $state.basePortText)
                    .help("MWB usa la porta base per gli appunti e la successiva per i messaggi (predefinita 15100)")
                TextField("Nome di questo Mac", text: $state.settings.localName)
                    .help("Deve coincidere con il nome inserito nella matrice di PowerToys e deve essere risolvibile dal PC")
            }
            Section("Security key") {
                LabeledContent("Nel Keychain", value: model.hasSecurityKey ? "presente" : "assente")
                HStack {
                    SecureField("Nuova security key", text: $state.newKey)
                    Button("Salva") { saveKey() }.disabled(state.newKey.isEmpty)
                }
                Text("La chiave è quella mostrata da PowerToys → Mouse Without Borders. Viene conservata solo nel Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appunti") {
                Toggle("Condividi gli appunti con il PC (testo e immagini)", isOn: $state.settings.shareClipboard)
            }
            Section("Blocco schermo") {
                Toggle("Blocca insieme Mac e PC", isOn: $state.settings.syncLock)
                TextField("Scorciatoia \"blocca tutte le macchine\" del PC", text: $state.settings.lockAllShortcut)
                    .disabled(!state.settings.syncLock)
                Text("⌃⌘Q sul Mac blocca anche il PC; Win+L inviato al PC o la scorciatoia premuta due volte sul PC bloccano anche il Mac. Deve essere quella impostata in PowerToys → Mouse Without Borders sul PC, nella forma Win+Ctrl+Alt+L.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.status == .missingPermissions {
                Section("Permessi") {
                    permissionRow("Accessibilità", granted: model.hasAccessibility, pane: "Privacy_Accessibility")
                    permissionRow("Monitoraggio input", granted: model.hasInputMonitoring, pane: "Privacy_ListenEvent")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var edgeTab: some View {
        Form {
            Section("Posizione del PC") {
                Picker("Il PC si trova oltre il bordo", selection: $state.settings.edge) {
                    Text("sinistro").tag(ScreenEdge.left)
                    Text("destro").tag(ScreenEdge.right)
                    Text("superiore").tag(ScreenEdge.top)
                    Text("inferiore").tag(ScreenEdge.bottom)
                }
                Text("Nella matrice di PowerToys il Mac deve stare dal lato opposto, altrimenti il cursore non torna indietro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cambio macchina") {
                Stepper("Ritardo di spostamento: \(state.settings.switchDelayMs) ms", value: $state.settings.switchDelayMs, in: 0...2000, step: 50)
                Stepper("Resistenza sul bordo: \(state.settings.edgeResistancePx) px", value: $state.settings.edgeResistancePx, in: 0...1000, step: 10)
            }
            Section("Porzione attiva del bordo") {
                LabeledContent("Inizio: \(Int(state.settings.edgeStart * 100))%") {
                    Slider(value: $state.settings.edgeStart, in: 0...1, step: 0.05)
                }
                LabeledContent("Fine: \(Int(state.settings.edgeEnd * 100))%") {
                    Slider(value: $state.settings.edgeEnd, in: 0...1, step: 0.05)
                }
                Text("Per schermi non allineati: solo questo tratto del bordo porta al PC.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var keyboardTab: some View {
        Form {
            Section("Tastiera del PC") {
                Picker("Layout di Windows", selection: $state.settings.windowsLayout) {
                    Text("Italiano").tag(WindowsLayout.italian)
                    Text("Americano").tag(WindowsLayout.us)
                }
                modifierPicker("⌘ Comando diventa", $state.settings.commandKey)
                modifierPicker("⌃ Controllo diventa", $state.settings.controlKey)
                modifierPicker("⌥ Opzione diventa", $state.settings.optionKey)
                Toggle("⌥ destro come AltGr", isOn: $state.settings.rightOptionIsAltGr)
                Toggle("Inverti la rotella", isOn: $state.settings.invertScroll)
            }
            Section("Scorciatoia di emergenza") {
                HStack {
                    Toggle("⌃", isOn: $state.settings.hotkey.control)
                    Toggle("⌥", isOn: $state.settings.hotkey.option)
                    Toggle("⇧", isOn: $state.settings.hotkey.shift)
                    Toggle("⌘", isOn: $state.settings.hotkey.command)
                    Picker("", selection: $state.settings.hotkey.keyCode) {
                        ForEach(Hotkey.keyNames, id: \.keyCode) { key in
                            Text(key.name).tag(key.keyCode)
                        }
                    }
                    .labelsHidden()
                }
                .toggleStyle(.button)
                Text("Riporta sempre l'input al Mac; dal Mac passa manualmente al PC. Attuale: \(state.settings.hotkey.description)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Componenti

    private func modifierPicker(_ title: String, _ selection: Binding<ModifierTarget>) -> some View {
        Picker(title, selection: selection) {
            Text("Ctrl").tag(ModifierTarget.control)
            Text("Win").tag(ModifierTarget.windows)
            Text("Alt").tag(ModifierTarget.alt)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        LabeledContent(title) {
            if granted {
                Label("concesso", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Apri Impostazioni di Sistema…") { model.openPrivacySettings(pane) }
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected, .remote: return .green
        case .connecting: return .yellow
        case .disabled: return .gray
        default: return .red
        }
    }

    // MARK: Azioni

    private var parsedPort: UInt16? {
        guard let port = UInt16(state.basePortText.trimmingCharacters(in: .whitespaces)), port > 0, port < UInt16.max else { return nil }
        return port
    }

    private var hasChanges: Bool {
        state.settings != model.settings || parsedPort != model.settings.basePort
    }

    private func apply() {
        guard let port = parsedPort else {
            show("Porta base non valida", error: true)
            return
        }
        guard state.settings.hotkey.control || state.settings.hotkey.option || state.settings.hotkey.command else {
            show("La scorciatoia richiede almeno ⌃, ⌥ o ⌘", error: true)
            return
        }
        state.settings.basePort = port
        state.settings.remoteHost = state.settings.remoteHost.trimmingCharacters(in: .whitespaces)
        state.settings.localName = String(state.settings.localName.trimmingCharacters(in: .whitespaces).prefix(32))
        guard let lockShortcut = LockShortcut(parsing: state.settings.lockAllShortcut) else {
            show("Scorciatoia di blocco non valida: modificatori (Win, Ctrl, Alt, Shift) e un tasto A–Z o 0–9, per esempio Win+Ctrl+Alt+L", error: true)
            return
        }
        state.settings.lockAllShortcut = lockShortcut.description
        guard !state.settings.localName.isEmpty else {
            show("Il nome del Mac non può essere vuoto", error: true)
            return
        }
        do {
            try model.apply(state.settings)
            show("Impostazioni applicate", error: false)
        } catch {
            show("\(error.localizedDescription)", error: true)
        }
    }

    private func saveKey() {
        let key = String(state.newKey.unicodeScalars.filter { !$0.properties.isWhitespace })
        // Stessa regola di PowerToys: almeno 16 caratteri, spazi esclusi.
        guard key.count >= 16 else {
            show("La chiave deve avere almeno 16 caratteri", error: true)
            return
        }
        do {
            try model.saveSecurityKey(key)
            state.newKey = ""
            show("Chiave salvata nel Keychain", error: false)
        } catch {
            show("\(error)", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        state.message = text
        state.messageIsError = error
    }
}
