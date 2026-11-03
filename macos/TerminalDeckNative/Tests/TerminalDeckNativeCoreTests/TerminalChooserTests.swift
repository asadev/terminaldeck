import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// 28 Oct (Asad: "On the Mac, if I'm on another session and click that session, it comes to the Mac"; Reviewer: a
/// one-second click window let a Hoot tab switch count as his). A session comes to this Mac only when it is selected
/// while he is choosing in the session list, the tab strip or with ⌘-number; never from a selection made anywhere
/// else, however soon after one of his clicks.
@Suite("Terminal handoff: where a session is chosen on the Mac")
@MainActor
struct TerminalChooserTests {
    /// What `NativeTerminalSessions.chosenHere` asks when a session is selected.
    private func chosen(_ chooser: TerminalChooser) -> TerminalChoosePlace? { chooser.place }

    @Test func aSelectionInsideTheTabStripsActionIsHisChoice() {
        let chooser = TerminalChooser()
        var seen: TerminalChoosePlace?
        chooser.choosing(in: .tabStrip) { seen = chosen(chooser) }
        #expect(seen == .tabStrip)
        #expect(chosen(chooser) == nil, "over once the tab strip's action returns")
    }

    @Test func eachPlaceIsNamed() {
        let chooser = TerminalChooser()
        var seen: [TerminalChoosePlace?] = []
        for place in [TerminalChoosePlace.sessionList, .tabStrip, .commandNumber] {
            chooser.choosing(in: place) { seen.append(chosen(chooser)) }
        }
        #expect(seen == [.sessionList, .tabStrip, .commandNumber])
    }

    /// Hoot's tab switch (or a restored tab, a tool) selects a session outside those places: not his choice, even
    /// immediately after he clicked something.
    @Test func aSelectionMadeElsewhereRightAfterHisClickIsNot() {
        let chooser = TerminalChooser()
        chooser.choosing(in: .sessionList) {}
        #expect(chosen(chooser) == nil)
    }

    /// What the place's action leaves for later (a page answering, an animation) runs outside it.
    @Test func whatTheActionLeavesForLaterIsNotHisChoice() async {
        let chooser = TerminalChooser()
        var later: Task<TerminalChoosePlace?, Never>?
        chooser.choosing(in: .commandNumber) {
            later = Task { @MainActor in await Task.yield(); return chosen(chooser) }
        }
        guard let later else { Issue.record("the action did not run"); return }
        #expect(await later.value == nil)
    }

    /// A choice made inside another (the session list's action selecting through the tab strip's path) keeps the
    /// outer one when it ends.
    @Test func aNestedChoiceRestoresTheOuterOne() {
        let chooser = TerminalChooser()
        var inner: TerminalChoosePlace?, after: TerminalChoosePlace?
        chooser.choosing(in: .sessionList) {
            chooser.choosing(in: .tabStrip) { inner = chosen(chooser) }
            after = chosen(chooser)
        }
        #expect(inner == .tabStrip)
        #expect(after == .sessionList)
        #expect(chosen(chooser) == nil)
    }
}
