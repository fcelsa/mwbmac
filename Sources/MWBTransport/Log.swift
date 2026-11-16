// Log su stderr. Il log del protocollo in chiaro si attiva da flag (vedi CLAUDE.md,
// convenzioni) e serve per la diagnosi contro PowerToys reale.

import Foundation
import MWBProtocol

public final class Log: @unchecked Sendable {
    public var protocolEnabled: Bool
    public var debugEnabled: Bool
    /// Sostituibile dai test o da una futura interfaccia grafica.
    public var sink: (String) -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(protocolEnabled: Bool = false, debugEnabled: Bool = false) {
        self.protocolEnabled = protocolEnabled
        self.debugEnabled = debugEnabled
        self.sink = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    public func info(_ message: @autoclosure () -> String) {
        sink("\(Log.formatter.string(from: Date())) \(message())")
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled || protocolEnabled else { return }
        sink("\(Log.formatter.string(from: Date())) [debug] \(message())")
    }

    func packet(_ direction: String, _ label: String, _ packet: Packet) {
        sink("\(Log.formatter.string(from: Date())) [\(direction)] \(label) \(packet)")
    }
}
