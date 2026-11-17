// Registro su file dell'app: ~/Library/Logs/mwbmac/mwbmac.log.
// Contiene gli stessi messaggi della riga di comando (mai il contenuto degli appunti né
// la security key). Oltre 2 MB il file viene ruotato in mwbmac.old.log.

import Foundation

final class LogFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "mwbmac.logfile")
    private var handle: FileHandle?
    private static let maxSize: UInt64 = 2 * 1024 * 1024
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        url = logs.appendingPathComponent("Logs/mwbmac/mwbmac.log")
    }

    func append(_ line: String) {
        let day = dayFormatter.string(from: Date())
        queue.async { [self] in
            guard let handle = open() else { return }
            handle.write(Data("\(day) \(line)\n".utf8))
        }
    }

    private func open() -> FileHandle? {
        let manager = FileManager.default
        if let handle {
            if (try? handle.offset()) ?? 0 < LogFile.maxSize { return handle }
            try? handle.close()
            self.handle = nil
            let old = url.deletingLastPathComponent().appendingPathComponent("mwbmac.old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Leggibile solo dall'utente: contiene nomi e indirizzi delle macchine.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
