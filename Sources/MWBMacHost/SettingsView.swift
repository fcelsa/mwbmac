// Finestra Impostazioni: barra laterale con le sezioni, a destra il modulo della sezione
// scelta. Le modifiche restano in una bozza finché non si preme "Applica": applicarle
// riavvia la sessione con il PC. Tutti i testi passano da `L(...)` (vedi Localization.swift).

import MWBEdgeLogic
import MWBInputCapture
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case connection, edge, keyboard, sharing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return L("Connection")
        case .edge: return L("Screen Edge")
        case .keyboard: return L("Keyboard & Mouse")
        case .sharing: return L("Sharing & Lock")
        }
    }

    var symbol: String {
        switch self {
        case .connection: return "network"
        case .edge: return "rectangle.righthalf.inset.filled.arrow.right"
        case .keyboard: return "keyboard"
        case .sharing: return "lock.rectangle.stack"
        }
    }
}

/// Bozza delle impostazioni in modifica. È un oggetto osservabile e non `@State` perché
/// nell'SDK corrente `@State` è una macro il cui plugin manca nei Command Line Tools.
final class SettingsDraft: ObservableObject {
    @Published var settings: MWBEdgeLogic.Settings
    @Published var basePortText: String
    @Published var newKey = ""
    @Published var message = ""
    @Published var messageIsError = false
    @Published var pane: SettingsPane? = .connection

    init(settings: MWBEdgeLogic.Settings) {
        self.settings = settings
        self.basePortText = String(settings.basePort)
    }

    func reset(to settings: MWBEdgeLogic.Settings) {
        self.settings = settings
        basePortText = String(settings.basePort)
        message = ""
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SettingsDraft

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $state.pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            VStack(spacing: 0) {
                Group {
                    switch state.pane ?? .connection {
                    case .connection: connectionPane
                    case .edge: edgePane
                    case .keyboard: keyboardPane
                    case .sharing: sharingPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                footer
            }
        }
        .frame(width: 740, height: 580)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(model.status.text).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !state.message.isEmpty {
                Text(state.message)
                    .foregroundStyle(state.messageIsError ? .red : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Button(L("Revert")) { state.reset(to: model.settings) }
                .disabled(!hasChanges)
            Button(L("Apply")) { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Connessione

    private var connectionPane: some View {
        Form {
            Section {
                TextField(L("PC name or address"), text: $state.settings.remoteHost, prompt: Text(L("e.g. MYPC or 192.168.1.20")))
                TextField(L("This Mac's name"), text: $state.settings.localName)
                TextField(L("Base port"), text: $state.basePortText)
            } header: {
                Text(L("PC with Mouse Without Borders"))
            } footer: {
                note(L("In PowerToys, add this Mac's name to the device layout; the PC must be able to resolve it on the network. Mouse Without Borders uses the base port for the clipboard and the next one for messages (default 15100)."))
            }

            Section {
                LabeledContent(L("Keychain")) {
                    if model.hasSecurityKey {
                        Label(L("Stored"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(L("Missing"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                HStack {
                    SecureField(L("New security key"), text: $state.newKey)
                    Button(L("Save")) { saveKey() }.disabled(state.newKey.isEmpty)
                }
            } header: {
                Text(L("Security key"))
            } footer: {
                note(L("The key shown in PowerToys → Mouse Without Borders on the PC. It is stored only in the Keychain."))
            }

            Section {
                permissionRow(L("Accessibility"), granted: model.hasAccessibility, pane: "Privacy_Accessibility")
                permissionRow(L("Input Monitoring"), granted: model.hasInputMonitoring, pane: "Privacy_ListenEvent")
            } header: {
                Text(L("Permissions"))
            } footer: {
                note(L("Needed to read the keyboard and mouse and send them to the PC."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bordo dello schermo

    private var edgePane: some View {
        Form {
            Section {
                EdgeDiagram(edge: state.settings.edge, range: state.settings.activeRange,
                            blockCorners: state.settings.blockCorners)
                    .padding(.vertical, 4)
                Picker(L("The PC is on the"), selection: $state.settings.edge) {
                    Text(L("Left")).tag(ScreenEdge.left)
                    Text(L("Right")).tag(ScreenEdge.right)
                    Text(L("Top")).tag(ScreenEdge.top)
                    Text(L("Bottom")).tag(ScreenEdge.bottom)
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L("Position of the PC"))
            } footer: {
                note(L("In the PowerToys device layout, place the Mac on the opposite side of the PC, otherwise the cursor can't come back."))
            }

            Section {
                LabeledContent(L("From %ld%%", percent(state.settings.edgeStart))) {
                    Slider(value: rangeStart, in: 0...0.95, step: 0.05)
                }
                LabeledContent(L("To %ld%%", percent(state.settings.edgeEnd))) {
                    Slider(value: rangeEnd, in: 0.05...1, step: 0.05)
                }
                optionToggle(L("Ignore screen corners"),
                             detail: L("Pushing into a corner doesn't switch to the PC, so hot corners and Notification Center keep working."),
                             isOn: $state.settings.blockCorners)
            } header: {
                Text(L("Part of the edge that leads to the PC"))
            } footer: {
                note(state.settings.edge == .left || state.settings.edge == .right
                     ? L("0% is the top of the screen, 100% the bottom. Narrow it when the PC screen is smaller or not aligned with the Mac, so the cursor crosses only where the two screens meet.")
                     : L("0% is the left end of the screen, 100% the right end. Narrow it when the PC screen is smaller or not aligned with the Mac, so the cursor crosses only where the two screens meet."))
            }

            Section {
                Stepper(L("Delay: %ld ms", state.settings.switchDelayMs),
                        value: $state.settings.switchDelayMs, in: 0...2000, step: 50)
                Stepper(L("Resistance: %ld px", state.settings.edgeResistancePx),
                        value: $state.settings.edgeResistancePx, in: 0...1000, step: 10)
                Picker(L("Only while holding"), selection: $state.settings.edgeSwitchModifier) {
                    Text(L("No key")).tag(EdgeModifier.none)
                    Text(L("⌃ Control")).tag(EdgeModifier.control)
                    Text(L("⌥ Option")).tag(EdgeModifier.option)
                    Text(L("⌘ Command")).tag(EdgeModifier.command)
                    Text(L("⇧ Shift")).tag(EdgeModifier.shift)
                }
                optionToggle(L("Not while an app is full screen"),
                             detail: L("Games, presentations and videos keep the cursor on the Mac. The emergency shortcut still switches."),
                             isOn: $state.settings.disableInFullScreen)
            } header: {
                Text(L("Switching to the PC"))
            } footer: {
                note(L("The cursor moves to the PC after pushing against the edge for the delay time and for the resistance distance; both avoid accidental switches."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Tastiera e mouse

    private var keyboardPane: some View {
        Form {
            Section {
                Picker(L("Windows keyboard layout"), selection: $state.settings.windowsLayout) {
                    Text(L("Italian")).tag(WindowsLayout.italian)
                    Text(L("US")).tag(WindowsLayout.us)
                }
                modifierPicker(L("⌘ Command becomes"), $state.settings.commandKey)
                modifierPicker(L("⌃ Control becomes"), $state.settings.controlKey)
                modifierPicker(L("⌥ Option becomes"), $state.settings.optionKey)
                optionToggle(L("Right ⌥ Option is AltGr"),
                             detail: L("Types characters such as @ # [ ] { } on the Italian layout."),
                             isOn: $state.settings.rightOptionIsAltGr)
            } header: {
                Text(L("Keyboard on the PC"))
            }

            Section {
                Toggle(L("Invert scroll direction"), isOn: $state.settings.invertScroll)
            } header: {
                Text(L("Mouse"))
            }

            Section {
                HStack {
                    Toggle("⌃", isOn: $state.settings.hotkey.control)
                    Toggle("⌥", isOn: $state.settings.hotkey.option)
                    Toggle("⇧", isOn: $state.settings.hotkey.shift)
                    Toggle("⌘", isOn: $state.settings.hotkey.command)
                    Picker("", selection: $state.settings.hotkey.keyCode) {
                        ForEach(Hotkey.keyNames, id: \.keyCode) { key in
                            Text(L(key.name)).tag(key.keyCode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    Spacer()
                    Text(hotkeyText(state.settings.hotkey)).font(.title3.monospaced()).foregroundStyle(.secondary)
                }
                .toggleStyle(.button)
            } header: {
                Text(L("Emergency shortcut"))
            } footer: {
                note(L("Always brings the input back to the Mac; on the Mac it switches to the PC manually."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Condivisione e blocco

    private var sharingPane: some View {
        Form {
            Section {
                optionToggle(L("Share the clipboard with the PC"),
                             detail: L("Text and images, in both directions. Requires “Share clipboard” in Mouse Without Borders on the PC."),
                             isOn: $state.settings.shareClipboard)
            } header: {
                Text(L("Clipboard"))
            }

            Section {
                optionToggle(L("Keep the other computers awake"),
                             detail: L("While you use the Mac, the PC doesn't start the screen saver or go to sleep. Activity on the PC keeps the Mac awake when the PC has the same option on."),
                             isOn: $state.settings.keepOthersAwake)
            } header: {
                Text(L("Sleep"))
            } footer: {
                note(L("When the Mac goes to sleep the PC is told right away; on wake the connection resumes as soon as the network is back."))
            }

            Section {
                Toggle(L("Lock the Mac and the PC together"), isOn: $state.settings.syncLock)
                TextField(L("PC shortcut"), text: $state.settings.lockAllShortcut, prompt: Text("Win+Ctrl+Alt+L"))
                    .disabled(!state.settings.syncLock)
            } header: {
                Text(L("Screen lock"))
            } footer: {
                note(L("⌃⌘Q on the Mac also locks the PC; Win+L sent to the PC, or the shortcut pressed twice on the PC, also locks the Mac. The PC shortcut is the “lock all machines” one set in PowerToys → Mouse Without Borders, written like Win+Ctrl+Alt+L."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Componenti

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Interruttore con una riga di spiegazione sotto il titolo.
    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modifierPicker(_ title: String, _ selection: Binding<ModifierTarget>) -> some View {
        Picker(title, selection: selection) {
            Text(verbatim: "Ctrl").tag(ModifierTarget.control)
            Text(verbatim: "Win").tag(ModifierTarget.windows)
            Text(verbatim: "Alt").tag(ModifierTarget.alt)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        LabeledContent(title) {
            if granted {
                Label(L("Granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("Open System Settings…")) { model.openPrivacySettings(pane) }
            }
        }
    }

    private func hotkeyText(_ hotkey: Hotkey) -> String {
        hotkey.description(keyName: { L($0) })
    }

    private func percent(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    /// Inizio e fine del tratto attivo restano distanti almeno il 5%.
    private var rangeStart: Binding<Double> {
        Binding(get: { state.settings.edgeStart },
                set: { state.settings.edgeStart = min($0, state.settings.edgeEnd - 0.05) })
    }

    private var rangeEnd: Binding<Double> {
        Binding(get: { state.settings.edgeEnd },
                set: { state.settings.edgeEnd = max($0, state.settings.edgeStart + 0.05) })
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
            show(L("The base port is not valid."), error: true)
            return
        }
        guard state.settings.hotkey.control || state.settings.hotkey.option || state.settings.hotkey.command else {
            show(L("The emergency shortcut needs at least ⌃, ⌥ or ⌘."), error: true)
            return
        }
        state.settings.basePort = port
        state.settings.remoteHost = state.settings.remoteHost.trimmingCharacters(in: .whitespaces)
        state.settings.localName = String(state.settings.localName.trimmingCharacters(in: .whitespaces).prefix(32))
        guard let lockShortcut = LockShortcut(parsing: state.settings.lockAllShortcut) else {
            show(L("Invalid lock shortcut: use modifiers (Win, Ctrl, Alt, Shift) and a key A–Z or 0–9, e.g. Win+Ctrl+Alt+L."), error: true)
            return
        }
        state.settings.lockAllShortcut = lockShortcut.description
        guard !state.settings.localName.isEmpty else {
            show(L("The Mac's name can't be empty."), error: true)
            return
        }
        do {
            try model.apply(state.settings)
            show(L("Settings applied."), error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func saveKey() {
        let key = String(state.newKey.unicodeScalars.filter { !$0.properties.isWhitespace })
        // Stessa regola di PowerToys: almeno 16 caratteri, spazi esclusi.
        guard key.count >= 16 else {
            show(L("The key must be at least 16 characters long."), error: true)
            return
        }
        do {
            try model.saveSecurityKey(key)
            state.newKey = ""
            show(L("Key saved in the Keychain."), error: false)
        } catch {
            show("\(error)", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        state.message = text
        state.messageIsError = error
    }
}
