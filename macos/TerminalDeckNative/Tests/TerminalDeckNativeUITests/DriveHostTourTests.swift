import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U105: guided tours. Two tours started almost at once never end each other's panel (#476), and
/// the talk-to-Hoot box follows Hoot's live session after a restart (#499). Fake Hoot state, no AI.
@MainActor final class DriveHostTourTests: XCTestCase {
    private func tour(_ id: String) -> [String: Any] {
        let stops: [[String: Any]] = [0, 1].map { ["index": $0, "sessionId": "s\($0)", "sessionTitle": "S\($0)", "kind": "screen", "quote": "q\($0)"] }
        return ["record": ["v": 1, "id": id, "startedAt": 0, "question": "q", "headline": "h", "dropped": [], "stops": stops],
                "stops": [0, 1].map { ["sessionId": "s\($0)", "note": "n\($0)", "why": "failed", "kind": "screen", "quote": "q\($0)"] }]
    }
    /// Long enough for the session-list read the tour makes first (the bridge is down here and asks again twice).
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<500 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private final class FakeHoot {
        var live: String? = "hoot-1"
        var written: [(String, String)] = []
    }
    /// The window a tour moves (the app's own needs the whole app running).
    private final class FakeWindow: DriveNavigating {
        var tabs: [String] = []
        func selectTab(_ sessionId: String) { tabs.append(sessionId) }
        func showPanel(_ id: String, focus: String?) {}
        func cwdOf(_ sessionId: String) -> String? { "/work" }
    }
    func testASecondTourEndsTheFirstAndKeepsItsPanelAndTalkGoesToHootsLiveSession() async {
        let host = DriveHost(), hoot = FakeHoot(), window = FakeWindow()
        host.navigator = window
        host.readHootState = { hoot.live.map { ["sessionId": $0] as [String: Any] } ?? [:] }
        host.writeToSession = { hoot.written.append(($0, $1)) }

        // #476: both arrive before either reads the session list.
        host.play(tour("first")); host.play(tour("second"))
        await settle { host.view?.record.id == "second" }
        XCTAssertEqual(host.view?.record.id, "second")
        XCTAssertFalse(host.view?.ended ?? true, "the first tour ending must not take the second one's panel")
        XCTAssertTrue(host.canSay)

        // #499: Hoot restarted since the tour began; what is said goes to its new session.
        hoot.live = "hoot-2"
        host.say("look at this")
        await settle { hoot.written.count == 2 }
        XCTAssertEqual(hoot.written.map(\.0), ["hoot-2", "hoot-2"])
        XCTAssertEqual(hoot.written.map(\.1), ["look at this", "\r"])

        // Hoot is off: nothing is written to a closed session and the box goes away.
        hoot.live = nil
        host.say("anyone there?")
        await settle { !host.canSay }
        XCTAssertFalse(host.canSay)
        XCTAssertEqual(hoot.written.count, 2)

        host.command(.stop)
        XCTAssertNil(host.view)
        XCTAssertFalse(host.playing)
        XCTAssertTrue(window.tabs.contains("s0"), "the tour moved the window to its first stop")
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
