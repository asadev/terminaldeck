import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad: "when i do in settings its not changing on chat page". The gear popover (Settings →
/// Hoot's brain model) and the message box (composer, also the island's) share ONE observed
/// source; a write through either code path shows in the other at once. Fake backend, no AI.
@MainActor final class L6HootChoicesSyncTests: XCTestCase {
    private final class FakeBackend {
        var model = "claude:claude-sonnet-5-5", effort = "xhigh", permission = "ask", fast = false, reads = 0
        func options() -> [String: Any] {
            ["model": model, "effort": effort, "efforts": ["low", "medium", "high", "xhigh", "max"],
             "permissionMode": permission, "ready": true, "fastMode": fast,
             "catalog": ["claude": ["fastMode": ["available": true, "on": false]]],
             "models": [["id": "claude:claude-sonnet-5-5", "provider": "Claude Code", "name": "Sonnet 5.5"],
                        ["id": "claude:claude-haiku-5-5", "provider": "Claude Code", "name": "Haiku 5.5"]]]
        }
    }
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<100 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func testPopoverAndMessageBoxReadAndWriteOneSource() async throws {
        let backend = FakeBackend()
        let store = HootChatChoices(invoke: { channel, args in
            XCTAssertEqual(channel, "hoot:chat:options")
            if let patch = args.first as? [String: Any] {
                if let model = patch["model"] as? String { backend.model = model }
                if let effort = patch["effort"] as? String { backend.effort = effort }
                if let permission = patch["permissionMode"] as? String { backend.permission = permission }
                if patch["fastMode"] != nil {
                    XCTAssertNotNil(patch["fastMode"] as? Bool, "Fast mode is sent as on/off")
                    backend.fast = patch["fastMode"] as? Bool ?? backend.fast
                }
            }
            backend.reads += 1
            return backend.options()
        })
        let box = NativeHootChatModel(choices: store)          // the message box (and the island's)
        // Settings → Hoot reads the saved choices too; U91: nothing writes them beside the shared choices.
        let popover = ROUTINESHootBrainModel(invoke: { channel, _ in
            XCTAssertNotEqual(channel, "hoot:ready:save", "Fast mode and Bypass go through the shared choices only")
            guard channel == "hoot:ready:read" else { return CodingAIJSON([String: Any]()) }
            return CodingAIJSON(["provider": "claude", "catalog": ["claude": ["fastMode": ["available": true, "on": false]]],
                "choices": ["fastMode": backend.fast, "permissionMode": backend.permission == "bypass" ? "bypassPermissions" : ""]])
        }, choices: store, queue: box)
        box.observeChoices(); popover.reload()
        await settle { box.composerDraft.modelID == backend.model && popover.chatModel == backend.model }
        XCTAssertEqual(box.composerDraft.modelID, "claude:claude-sonnet-5-5")
        XCTAssertEqual(popover.chatModel, "claude:claude-sonnet-5-5")

        // 1. The popover picks Haiku: the message box shows it at once.
        popover.selectModel("claude-haiku-5-5")
        await settle { box.composerDraft.modelID == "claude:claude-haiku-5-5" }
        XCTAssertEqual(box.composerDraft.modelID, "claude:claude-haiku-5-5", "popover → message box")

        // 2. The message box picks High effort: the popover shows it at once.
        await settle { !popover.busy }
        box.changeEffort("high")
        await settle { popover.chatEffort == "high" }
        XCTAssertEqual(popover.chatEffort, "high", "message box → popover")
        XCTAssertEqual(backend.effort, "high")

        // 3. U91: the message box turns Fast mode on; Settings → Hoot shows it without a reload of its own.
        await settle { !box.changingOptions }
        box.changeFastMode(true)
        await settle { popover.fastMode == true }
        XCTAssertTrue(backend.fast)
        XCTAssertEqual(popover.fastMode, true, "message box → Settings")

        // 4. Settings turns it off: the message box shows it at once.
        await settle { !box.changingOptions }
        popover.selectFastMode(false)
        await settle { box.catalogue.sections.first(where: { $0.fastMode != nil })?.fastMode == false && !backend.fast }
        XCTAssertFalse(backend.fast)
        XCTAssertEqual(box.catalogue.sections.first(where: { $0.fastMode != nil })?.fastMode, false, "Settings → message box")

        // 5. Bypass picked in the message box is one write, and Settings shows it.
        await settle { !box.changingOptions }
        box.changePermission(.bypass)
        await settle { popover.permissionWord == "bypass" }
        XCTAssertEqual(backend.permission, "bypass")
        XCTAssertEqual(popover.permissionWord, "bypass")

        // 6. One label everywhere.
        XCTAssertEqual(HootBrainRows.effortName("xhigh"), "Extra")
        XCTAssertEqual(HootComposerModel.effortName("xhigh"), "Extra")
    }
}
