// MWB Mac Host — app da barra menu (fase 5 della roadmap). Nessuna finestra principale:
// un NSStatusItem con lo stato e una finestra Impostazioni in SwiftUI.

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.updateIcon(status) }
            .store(in: &subscriptions)
        updateIcon(model.status)
        model.start()

        // Al primo avvio, o quando manca qualcosa, si aprono subito le impostazioni.
        switch model.status {
        case .missingHost, .missingKey: showSettings()
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Riporta l'input al Mac e saluta il PC prima di uscire.
        model.stop()
        Thread.sleep(forTimeInterval: 0.3)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Icona

    private func updateIcon(_ status: AppModel.Status) {
        let symbol: String
        switch status {
        case .remote: symbol = "cursorarrow.rays"
        case .connected: symbol = "cursorarrow"
        case .connecting: symbol = "cursorarrow.motionlines"
        case .disabled: symbol = "cursorarrow.slash"
        case .missingHost, .missingKey, .missingPermissions, .invalidKey: symbol = "exclamationmark.triangle"
        }
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.text) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "MWB"
        }
        button.toolTip = "MWB Mac Host — \(status.text)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: model.status.text, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if model.status == .missingPermissions {
            if !model.hasAccessibility {
                menu.addItem(item("Concedi Accessibilità…", #selector(openAccessibility)))
            }
            if !model.hasInputMonitoring {
                menu.addItem(item("Concedi Monitoraggio input…", #selector(openInputMonitoring)))
            }
        }
        menu.addItem(.separator())

        let toggle = item(model.isRemote ? "Torna al Mac" : "Passa al PC", #selector(toggleRemote))
        toggle.isEnabled = model.canSwitchManually
        toggle.toolTip = "Scorciatoia: \(model.settings.hotkey.description)"
        menu.addItem(toggle)
        let hint = NSMenuItem(title: "Scorciatoia di emergenza: \(model.settings.hotkey.description)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let active = item("Attivo", #selector(toggleEnabled))
        active.state = model.enabled ? .on : .off
        menu.addItem(active)
        let login = item("Avvia al login", #selector(toggleLogin))
        login.state = model.launchesAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Impostazioni…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Esci da MWB Mac Host", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleRemote() { model.toggleRemote() }
    @objc private func toggleEnabled() { model.setEnabled(!model.enabled) }
    @objc private func toggleLogin() { model.setLaunchesAtLogin(!model.launchesAtLogin) }
    @objc private func openAccessibility() { model.openPrivacySettings("Privacy_Accessibility") }
    @objc private func openInputMonitoring() { model.openPrivacySettings("Privacy_ListenEvent") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, state: SettingsDraft(settings: model.settings))))
            window.title = "MWB Mac Host — Impostazioni"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// App "agente": niente icona nel Dock né menu principale (anche LSUIElement nell'Info.plist).
application.setActivationPolicy(.accessory)
application.run()
