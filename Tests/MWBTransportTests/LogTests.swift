import Foundation
import Testing
@testable import MWBTransport

struct LogTests {
    /// Raccoglie le righe del log; `@unchecked` perché i test la usano da un solo thread.
    final class Lines: @unchecked Sendable {
        var all: [String] = []
    }

    private func emitAll(verbose: Bool) -> [String] {
        let lines = Lines()
        let log = Log(verbose: verbose)
        log.sink = { lines.all.append($0) }
        log.error("e")
        log.notice("n")
        log.info("i")
        log.debug("d")
        return lines.all
    }

    @Test func defaultLogKeepsOnlyErrorsAndNotices() {
        let lines = emitAll(verbose: false)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[error] e"))
        #expect(lines[1].hasSuffix(" n"))
    }

    @Test func verboseLogKeepsEverything() {
        let lines = emitAll(verbose: true)
        #expect(lines.count == 4)
        #expect(lines[3].hasSuffix("[debug] d"))
    }

    @Test func onlyTheFirstConnectionToAMachineIsNew() {
        let name = "log-test-\(UUID().uuidString)"
        #expect(Session.firstConnection(to: name))
        #expect(!Session.firstConnection(to: name.uppercased()))
    }
}
