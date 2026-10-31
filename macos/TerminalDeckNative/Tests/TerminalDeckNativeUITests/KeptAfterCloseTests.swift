import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U143: what the app keeps in memory after it is closed or gone is let go.
@MainActor final class KeptAfterCloseTests: XCTestCase {
    final class Owner: NativeUIGSimulatorOwner {
        let sessionId: String
        var ended = false, removed = false
        init(_ id: String) { sessionId = id }
    }
    @MainActor final class Alive { var ids: Set<String>? = nil }

    private func scratch() throws -> (UserDefaults, String) {
        let suite = "td-u143-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// #177: a seat's memory is kept while a screen shows it and let go when the last one goes.
    func testMemoryStoreIsLetGoWhenItsLastScreenGoes() {
        let owner = DeckMemoryOwner.lead("u143test")
        let store = NativeMemoryStore.of(owner)
        store.start(); store.start()
        store.stop()
        XCTAssertTrue(NativeMemoryStore.of(owner) === store, "One screen still shows it.")
        store.stop()
        XCTAssertFalse(NativeMemoryStore.of(owner) === store, "No screen shows it: it is let go.")
    }

    /// #195: a closed phone panel takes its device view, recorder and tools with it, and a gone session's
    /// panel is let go by the store.
    func testClosedPhonePanelLetsItsDeviceViewRecorderAndToolsGo() throws {
        let (defaults, suite) = try scratch(); defer { defaults.removePersistentDomain(forName: suite) }
        weak var model: NativeSimulatorModel?
        weak var recorder: NativeSimRecorder?
        do {
            let panel = NativeUIGSessionSimulatorController(session: Owner("gone"), defaults: defaults, lifecycleEnabled: false)
            model = panel.model; recorder = NativeSimRecorder.of(panel.model)
            XCTAssertNotNil(recorder); XCTAssertNotNil(NativeSimPanelTools.of(panel.model))
        }
        XCTAssertNil(model); XCTAssertNil(recorder)

        let store = NativeUIGSessionSimulatorStore(defaults: defaults, lifecycleEnabled: false)
        let ended = Owner("ended"), live = Owner("live")
        weak var endedPanel = store.entry(ended)
        let livePanel = store.entry(live)
        ended.ended = true
        _ = store.entry(Owner("next"))
        XCTAssertNil(endedPanel, "An ended session's panel not on screen is let go.")
        XCTAssertTrue(store.entry(live) === livePanel)
    }

    /// #469: where feedback goes is kept in one list of the latest tabs and panels; the old one-key-per-tab
    /// entries are folded in and removed.
    func testFeedbackTargetsKeepOneShortList() throws {
        let (defaults, suite) = try scratch(); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-target", forKey: "td.feedback.target.tab-1")
        let targets = NativeHOOTSIMTargets(defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["td.feedback.target.tab-1"])
        XCTAssertEqual(targets.target(scope: "tab-1", originatingSession: nil), "old-target")
        let count = NativeHOOTSIMTargets.kept + 5
        for n in 0..<count { targets.remember("s\(n)", scope: "phone:\(n)") }
        XCTAssertEqual((defaults.array(forKey: NativeHOOTSIMTargets.key) as? [[String]])?.count, NativeHOOTSIMTargets.kept)
        XCTAssertEqual(targets.target(scope: "phone:0", originatingSession: "origin"), "origin")
        XCTAssertEqual(targets.target(scope: "phone:\(count - 1)", originatingSession: "origin"), "s\(count - 1)")
    }

    /// #645: rows and phone sides of sessions that are gone are dropped when the arrangement is saved.
    func testPaneArrangementDropsSessionsThatAreGone() throws {
        let (defaults, suite) = try scratch(); defer { defaults.removePersistentDomain(forName: suite) }
        let alive = Alive(); alive.ids = ["a", "b", "c"]
        let arrangement = NativePaneArrangement(defaults: defaults, known: { alive.ids })
        arrangement.move("a", relativeTo: "b", after: true, current: ["a", "b"])
        arrangement.setSimulatorLeading("c", slot: 1, true)
        XCTAssertEqual(arrangement.arranged(["a", "b"]), ["b", "a"])
        alive.ids = ["b", "z"]
        arrangement.move("z", relativeTo: "b", after: false, current: ["b", "z"])
        XCTAssertEqual(Array(arrangement.orders.keys), ["b,z"])
        XCTAssertFalse(arrangement.isSimulatorLeading("c", slot: 1))
        XCTAssertEqual(Array(NativePaneArrangement(defaults: defaults, known: { nil }).orders.keys), ["b,z"])
    }

    /// #647: a new look for the same agent replaces its small menu picture instead of adding one.
    func testRowPictureIsReplacedWhenItsLookChanges() {
        let pink = DeckRowIcon.agent(id: "u143-agent", icon: "sf:star@pink")
        let blue = DeckRowIcon.agent(id: "u143-agent", icon: "sf:star@blue")
        XCTAssertFalse(pink === blue)
        XCTAssertEqual(DeckRowIcon.cache.keys.filter { $0.contains("u143-agent") }.count, 1)
        XCTAssertTrue(DeckRowIcon.agent(id: "u143-agent", icon: "sf:star@blue") === blue)
    }
}
