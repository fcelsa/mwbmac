// Log su stderr, in inglese (è uno strumento di diagnosi). Livelli:
// - error:  sempre; qualcosa non funziona (porta occupata, chiave sbagliata…);
// - notice: sempre; avvio e prima connessione con ciascuna macchina;
// - info:   solo in modo verboso; cambi di macchina, appunti, stop, riconnessioni;
// - debug:  solo in modo verboso; dettagli di connessione e cifratura.
// Il log del protocollo in chiaro si attiva a parte (vedi CLAUDE.md, convenzioni) e serve
// per la diagnosi contro PowerToys reale.

import Foundation
import MWBProtocol

public final class Log: @unchecked Sendable {
    public enum Level: Int, Comparable, Sendable {
        case error, notice, info, debug

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Livello massimo registrato: `.notice` normalmente, `.debug` in modo verboso.
    public var level: Level
    public var protocolEnabled: Bool
    /// Sostituibile dai test o dall'app, che scrive anche su file.
    public var sink: (String) -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(verbose: Bool = false, protocolEnabled: Bool = false) {
        self.level = verbose ? .debug : .notice
        self.protocolEnabled = protocolEnabled
        self.sink = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    public func error(_ message: @autoclosure () -> String) {
        write(.error, "[error] \(message())")
    }

    public func notice(_ message: @autoclosure () -> String) {
        write(.notice, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        write(.info, message())
    }

    public func debug(_ message: @autoclosure () -> String) {
        write(.debug, "[debug] \(message())")
    }

    private func write(_ messageLevel: Level, _ message: @autoclosure () -> String) {
        guard messageLevel <= level else { return }
        sink("\(Log.formatter.string(from: Date())) \(message())")
    }

    func packet(_ direction: String, _ label: String, _ packet: Packet) {
        sink("\(Log.formatter.string(from: Date())) [\(direction)] \(label) \(packet)")
    }
}
