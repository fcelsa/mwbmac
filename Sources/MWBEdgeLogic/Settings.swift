// Preferenze su file JSON e security key nel Keychain (mai in chiaro nelle preferenze).

import Foundation
import MWBInputCapture
import Security
import SystemConfiguration

/// Scorciatoia di emergenza: riporta l'input al Mac (o lo passa al PC) in qualsiasi stato.
public struct Hotkey: Codable, Equatable, Sendable {
    /// Keycode macOS (kVK_*); 0x35 = Esc.
    public var keyCode: UInt16
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    public init(keyCode: UInt16 = 0x35, control: Bool = true, option: Bool = true,
                command: Bool = true, shift: Bool = false) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    public var description: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(Hotkey.keyNames.first { $0.keyCode == keyCode }?.name ?? "tasto 0x" + String(keyCode, radix: 16))
        return parts.joined()
    }

    /// Tasti proposti dall'interfaccia per la scorciatoia.
    public static let keyNames: [(keyCode: UInt16, name: String)] = [
        (0x35, "Esc"), (0x31, "Spazio"), (0x24, "Invio"), (0x30, "Tab"),
        (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"), (0x60, "F5"), (0x61, "F6"),
        (0x62, "F7"), (0x64, "F8"), (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"),
    ]
}

public struct Settings: Codable, Equatable, Sendable {
    /// Nome o indirizzo del PC con PowerToys.
    public var remoteHost: String
    /// Porta base di MWB (appunti sulla base, messaggi sulla base+1).
    public var basePort: UInt16
    /// Nome con cui il Mac si presenta; deve coincidere con quello nella matrice del PC.
    public var localName: String
    public var machineID: UInt32

    /// Bordo del desktop del Mac oltre il quale si trova il PC.
    public var edge: ScreenEdge
    /// Ritardo di spostamento in millisecondi.
    public var switchDelayMs: Int
    /// Resistenza sul bordo in pixel di spinta.
    public var edgeResistancePx: Int
    /// Porzione attiva del bordo (0…1), per schermi non allineati.
    public var edgeStart: Double
    public var edgeEnd: Double

    public var windowsLayout: WindowsLayout
    public var commandKey: ModifierTarget
    public var controlKey: ModifierTarget
    public var optionKey: ModifierTarget
    public var rightOptionIsAltGr: Bool
    public var invertScroll: Bool
    public var hotkey: Hotkey
    /// Condivisione degli appunti (testo e immagini) nelle due direzioni.
    public var shareClipboard: Bool

    public init() {
        remoteHost = ""
        basePort = 15100
        localName = Settings.defaultLocalName()
        machineID = Settings.randomMachineID()
        edge = .right
        switchDelayMs = 150
        edgeResistancePx = 30
        edgeStart = 0
        edgeEnd = 1
        windowsLayout = .italian
        commandKey = .control
        controlKey = .windows
        optionKey = .alt
        rightOptionIsAltGr = true
        invertScroll = false
        hotkey = Hotkey()
        shareClipboard = true
    }

    /// Le chiavi assenti nel file prendono il valore predefinito, così le versioni
    /// future possono aggiungere preferenze senza invalidare i file esistenti.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? remoteHost
        basePort = try c.decodeIfPresent(UInt16.self, forKey: .basePort) ?? basePort
        localName = try c.decodeIfPresent(String.self, forKey: .localName) ?? localName
        machineID = try c.decodeIfPresent(UInt32.self, forKey: .machineID) ?? machineID
        edge = try c.decodeIfPresent(ScreenEdge.self, forKey: .edge) ?? edge
        switchDelayMs = try c.decodeIfPresent(Int.self, forKey: .switchDelayMs) ?? switchDelayMs
        edgeResistancePx = try c.decodeIfPresent(Int.self, forKey: .edgeResistancePx) ?? edgeResistancePx
        edgeStart = try c.decodeIfPresent(Double.self, forKey: .edgeStart) ?? edgeStart
        edgeEnd = try c.decodeIfPresent(Double.self, forKey: .edgeEnd) ?? edgeEnd
        windowsLayout = try c.decodeIfPresent(WindowsLayout.self, forKey: .windowsLayout) ?? windowsLayout
        commandKey = try c.decodeIfPresent(ModifierTarget.self, forKey: .commandKey) ?? commandKey
        controlKey = try c.decodeIfPresent(ModifierTarget.self, forKey: .controlKey) ?? controlKey
        optionKey = try c.decodeIfPresent(ModifierTarget.self, forKey: .optionKey) ?? optionKey
        rightOptionIsAltGr = try c.decodeIfPresent(Bool.self, forKey: .rightOptionIsAltGr) ?? rightOptionIsAltGr
        invertScroll = try c.decodeIfPresent(Bool.self, forKey: .invertScroll) ?? invertScroll
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? hotkey
        shareClipboard = try c.decodeIfPresent(Bool.self, forKey: .shareClipboard) ?? shareClipboard
    }

    public var activeRange: ClosedRange<Double> {
        let lower = min(max(edgeStart, 0), 1)
        let upper = min(max(edgeEnd, 0), 1)
        return lower < upper ? lower...upper : 0...1
    }

    public func makeEdgeDetector() -> EdgeDetector {
        EdgeDetector(edge: edge, delay: Double(max(switchDelayMs, 0)) / 1000,
                     resistance: Double(max(edgeResistancePx, 0)), activeRange: activeRange)
    }

    public func makeKeyMap(isISOKeyboard: Bool) -> KeyMap {
        KeyMap(layout: windowsLayout, command: commandKey, control: controlKey, option: optionKey,
               rightOptionIsAltGr: rightOptionIsAltGr, isISOKeyboard: isISOKeyboard)
    }

    // MARK: Valori predefiniti

    /// Nome host locale senza dominio (quello che il PC risolve via DNS o mDNS).
    public static func defaultLocalName() -> String {
        let name = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return String(short.prefix(32))
    }

    /// Come `Setting.cs`: intero casuale positivo; 0 e 255 sono riservati.
    public static func randomMachineID() -> UInt32 {
        UInt32.random(in: 1000...UInt32(Int32.max))
    }

    // MARK: Persistenza

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("mwbmac/config.json")
    }

    /// Carica le preferenze; se il file non esiste lo crea con i valori predefiniti
    /// (il MachineId deve restare stabile fra un avvio e l'altro).
    public static func load(from url: URL = Settings.defaultURL) throws -> Settings {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        }
        let settings = Settings()
        try settings.save(to: url)
        return settings
    }

    public func save(to url: URL = Settings.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Security key di MWB nel Keychain di login.
public enum KeychainStore {
    public static let service = "mwbmac"
    public static let account = "security-key"

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "errore sconosciuto"
            return "Keychain: \(message) (\(status))"
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func readSecurityKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func writeSecurityKey(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = "Mouse Without Borders security key (mwbmac)"
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func deleteSecurityKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
