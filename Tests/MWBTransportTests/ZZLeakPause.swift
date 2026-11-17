import Foundation
import Testing

/// Solo per l'analisi dei leak (`MWB_LEAK_PAUSE=1`): tiene vivo il processo qualche
/// secondo dopo gli altri test, così `leaks` vede lo stato a riposo.
@Suite(.serialized)
struct ZZLeakPause {
    @Test func pause() async {
        guard ProcessInfo.processInfo.environment["MWB_LEAK_PAUSE"] != nil else { return }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
    }
}
