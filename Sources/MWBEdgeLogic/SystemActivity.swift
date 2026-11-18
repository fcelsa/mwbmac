// Interazioni con lo stato del sistema che non riguardano l'input: app a tutto schermo
// e attività dell'utente segnalata dalle altre macchine.

import AppKit
import CoreGraphics
import IOKit.pwr_mgt

enum FullScreenApp {
    /// Vero se l'app in primo piano (non questa) ha una finestra che copre tutto `display`.
    /// Limiti e proprietario delle finestre non richiedono il permesso Registrazione schermo.
    static func covers(_ display: CGRect) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return bounds.insetBy(dx: -1, dy: -1).contains(display)
        }
    }
}

/// Attività dell'utente su un'altra macchina (`Awake`): tiene sveglio il Mac come se
/// l'utente lo stesse usando, ma non accende uno schermo spento e non tocca la
/// schermata di blocco (come `Common.HumanBeingDetected`, che agisce solo sul desktop attivo).
final class UserActivity {
    private var assertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    func declare() {
        guard !UserActivity.isScreenLockedOrAsleep else { return }
        IOPMAssertionDeclareUserActivity("mwbmac: activity on another machine" as CFString,
                                         kIOPMUserActiveLocal, &assertion)
    }

    func release() {
        if assertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    deinit { release() }

    static var isScreenLockedOrAsleep: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}
