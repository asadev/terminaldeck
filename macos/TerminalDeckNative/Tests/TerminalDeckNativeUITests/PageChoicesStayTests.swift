import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U48: choices the hidden page used to hold live in the app's settings and hold with the page
/// not loaded (review items in each test's name comment).
@MainActor
final class PageChoicesStayTests: XCTestCase {
    private var suite = ""
    private var saved = UserDefaults.standard
    private var savedEvaluate: (@MainActor (String, NativeCodingAIPages.Page, (@MainActor (String?) -> Void)?) -> Void)?
    /// The fake page's storage; nil = the page is not loaded.
    private var page: [String: String]?

    override func setUp() async throws {
        suite = "PageChoicesStayTests-" + UUID().uuidString
        saved = NativePageChoices.defaults
        savedEvaluate = NativePageChoices.evaluate
        NativePageChoices.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        page = nil
        NativePageChoices.evaluate = { [unowned self] script, _, answer in
            guard let stored = page else { answer?(nil); return }
            answer?(stored.first { script.contains("getItem(\"\($0.key)\")") }?.value)
        }
    }
    override func tearDown() async throws {
        NativePageChoices.defaults.removePersistentDomain(forName: suite)
        NativePageChoices.defaults = saved
        if let savedEvaluate { NativePageChoices.evaluate = savedEvaluate }
    }

    /// #55, #70: a value the page still holds is taken over once; after that the app's copy wins.
    func testThePagesValueIsTakenOverOnce() {
        page = [SessionEffortMemory.key: "medium"]
        var effort: String?
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { effort = $0 }
        XCTAssertEqual(effort, "medium")
        XCTAssertEqual(NativePageChoices.read(SessionEffortMemory.key), "medium", "kept in the app")
        page = nil
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { effort = $0 }
        XCTAssertEqual(effort, "medium", "still there with the page gone")
        page = [SessionEffortMemory.key: "low"]
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { effort = $0 }
        XCTAssertEqual(effort, "medium", "the app's own copy wins over an older page copy")
    }
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }

    /// #55: the remembered effort and the feature switches are read from the app, page or no page.
    func testEffortAndFeaturesHoldWithoutThePage() throws {
        var effort: String?? = .none
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { effort = $0 }
        XCTAssertEqual(effort, .some(nil), "nothing remembered and no page: answered at once with nothing")

        NativePageChoices.write(SessionEffortMemory.key, "high")
        NativePageChoices.adopting(SessionEffortMemory.key, from: .main) { effort = $0 }
        XCTAssertEqual(effort, "high")
        XCTAssertEqual(SessionEffortMemory.preferred(stored: effort ?? nil), "high")

        NativePageChoices.defaults.set(#"{"usage":"off","mcp":"off"}"#, forKey: SessionFeatures.storageKey)
        var features = SessionFeatures.defaults
        NativePageChoices.following(SessionFeatures.storageKey, from: .main) { features = SessionFeatures.decode($0) }
        XCTAssertEqual(features, SessionFeatures(usageOn: false, mcpOn: false), "the last copy holds, never the defaults")

        let controls = try source("TerminalDeckNative/NativeSessionControls.swift")
        XCTAssertFalse(controls.contains("web.origin != nil"), "no choice gives up when the page is not loaded")
        XCTAssertFalse(controls.contains("readStorage(SessionEffortMemory.key)"))
        XCTAssertFalse(controls.contains("readStorage(SessionFeatures.storageKey)"))
    }

    /// #70: dismissals live in the app; a readiness row and an agent-update row never overwrite each other.
    func testDismissalsAreKeptAndNeverOverwriteEachOther() throws {
        NativePageChoices.adopting(ReadinessDismissed.key, from: .main) { value in
            NativePageChoices.write(ReadinessDismissed.key, ReadinessDismissed.serialize(
                ReadinessDismissed.dismiss(ReadinessDismissed.parse(value), scope: "/work/one", id: "claude-md")))
        }
        NativePageChoices.adopting(ReadinessDismissed.key, from: .settings) { value in
            NativePageChoices.write(ReadinessDismissed.key, ReadinessDismissed.serialize(ReadinessDismissed.dismiss(ReadinessDismissed.parse(value), scope: ReadinessDismissed.machineScope, id: "codex-old")))
        }
        let map = ReadinessDismissed.parse(NativePageChoices.read(ReadinessDismissed.key))
        XCTAssertEqual(map["/work/one"], ["claude-md"])
        XCTAssertEqual(map[ReadinessDismissed.machineScope], ["codex-old"])

        for file in ["TerminalDeckNative/NativeReadinessScreen.swift", "TerminalDeckNative/NativeCodingAIStore.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("writeStorage(ReadinessDismissed.key"), file)
            XCTAssertFalse(text.contains("readStorage(ReadinessDismissed.key"), file)
        }
    }
}
