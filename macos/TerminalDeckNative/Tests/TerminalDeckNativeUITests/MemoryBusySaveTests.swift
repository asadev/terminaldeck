import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// What a flow switch reads as saved.
@MainActor private final class SavedValue { var text: String? = "0" }

/// U15 (#20): a save pressed while another memory change runs is refused out loud, so the editor stays open.
@MainActor final class MemoryBusySaveTests: XCTestCase {
    func testSaveWhileAnotherChangeRunsIsRefusedAndSaysSo() {
        let store = NativeMemoryStore(owner: .hoot)
        store.busy = "archive"
        var ran = false
        let taken = store.act("note", done: "Note saved") { _ in ran = true; return nil }
        XCTAssertFalse(taken)
        XCTAssertFalse(ran)
        XCTAssertEqual(store.busy, "archive")
        XCTAssertEqual(store.problem, "Still saving the last change. Try again in a moment.")
    }

    /// U78 (#165, #665): the Helper / Tidy-up switch shows nothing it does not know and never moves for a save that was refused.
    func testFlowSwitchIsUnknownUntilReadAndCannotFlipWhileAnotherChangeRuns() async {
        let store = NativeMemoryStore(owner: .hoot)
        let saved = SavedValue()
        let model = NativeMemoryFlowSwitchModel(key: "flow.helper", read: { _ in saved.text })
        XCTAssertNil(model.on, "Not On before the saved value is read.")
        XCTAssertFalse(model.canFlip(store))
        model.flip(to: true, in: store)
        XCTAssertNil(store.busy, "Nothing is saved from an unknown position.")
        await model.reread()
        XCTAssertEqual(model.on, false, "It shows what is saved: off.")
        store.busy = "run-helper"                                   // "Run now" is still going
        XCTAssertFalse(model.canFlip(store))
        model.flip(to: true, in: store)
        XCTAssertEqual(model.on, false, "A save the store would refuse never moves the switch.")
        XCTAssertEqual(store.busy, "run-helper")
        store.busy = nil
        saved.text = "1"
        await model.reread()                                        // read again once the change has ended
        XCTAssertEqual(model.on, true)
        let broken = NativeMemoryFlowSwitchModel(key: "flow.tidy", read: { _ in throw NSError(domain: "memory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Memory is still starting."]) })
        await broken.reread()
        XCTAssertNil(broken.on)
        XCTAssertEqual(broken.unreadable, "Its saved value could not be read: Memory is still starting.", "The read error is shown, not swallowed.")
    }

    /// U78 (#650): Done or Escape warns about unsaved template edits, naming every tab that holds one.
    func testTemplatesNameEveryUnsavedTabBeforeClosing() {
        let saved = Dictionary(uniqueKeysWithValues: DeckMemoryCategory.allCases.map {
            ($0, DeckMemoryTemplate(category: $0, card: "card", checklist: "", parts: Set(DeckMemoryPart.allCases)))
        })
        var draft = saved
        XCTAssertEqual(NativeMemoryTemplatesView.unsaved(saved: saved, draft: draft), [])
        draft[.agent]?.card = "card, edited while the Lead tab is shown"
        XCTAssertEqual(NativeMemoryTemplatesView.unsaved(saved: saved, draft: draft), [.agent], "An edit on a tab no longer shown still counts.")
        XCTAssertEqual(NativeMemoryTemplatesView.closeWarning([.agent]), "Changes to the Agent template are not saved yet. Closing throws them away.")
        draft[.lead]?.checklist = "- new line"
        XCTAssertEqual(NativeMemoryTemplatesView.names(NativeMemoryTemplatesView.unsaved(saved: saved, draft: draft)), "Lead and Agent")
        XCTAssertEqual(NativeMemoryTemplatesView.closeWarning([.orchestrator, .lead, .agent]),
                       "Changes to the Orchestrator, Lead and Agent templates are not saved yet. Closing throws them away.")
    }
}
