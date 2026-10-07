import Testing
import TerminalDeckNativeCore

// Port of src/main/resident.test.ts (plannedQuit, quitAnswer, quitQuestion) and the
// index.ts before-quit / window-all-closed rules the native app follows (NativeSVResident).
@Suite struct NativeSVQuitRuleTests {
    typealias R = NativeSVQuitRule

    @Test func nothingRunningQuitsWithNoQuestionWhateverWasRemembered() {
        for behavior in [NativeStateStore.QuitBehavior.ask, .keep, .stop] {
            #expect(R.plan(liveSessions: 0, behavior: behavior, stopping: false, inBackground: false) == .stop)
        }
    }

    @Test func runningSessionsAskByDefaultAndFollowARememberedAnswer() {
        #expect(R.plan(liveSessions: 2, behavior: .ask, stopping: false, inBackground: false) == .ask)
        #expect(R.plan(liveSessions: 1, behavior: .keep, stopping: false, inBackground: false) == .keep)
        #expect(R.plan(liveSessions: 3, behavior: .stop, stopping: false, inBackground: false) == .stop)
    }

    @Test func anAlreadyDecidedQuitIsNeverAskedOrKept() {
        // Quit and Stop All, an update being installed, a signal, the Stop answer itself.
        for behavior in [NativeStateStore.QuitBehavior.ask, .keep, .stop] {
            #expect(R.plan(liveSessions: 4, behavior: behavior, stopping: true, inBackground: false) == .stop)
            #expect(R.plan(liveSessions: 4, behavior: behavior, stopping: true, inBackground: true) == .stop)
        }
    }

    @Test func aQuitWhileAlreadyInTheBackgroundIsNeverKeepSoQuitAlwaysWorks() {
        #expect(R.plan(liveSessions: 2, behavior: .keep, stopping: false, inBackground: true) == .stop)
        #expect(R.plan(liveSessions: 2, behavior: .ask, stopping: false, inBackground: true) == .ask)
    }

    @Test func buttonsAreKeepStopCancelInThatOrder() {
        #expect(R.buttons == ["Keep Them Running", "Stop Everything", "Cancel"])
        #expect(R.answer(buttonIndex: 0) == .keep)
        #expect(R.answer(buttonIndex: 1) == .stop)
        #expect(R.answer(buttonIndex: 2) == .cancel)
        #expect(R.answer(buttonIndex: -1) == .cancel) // Escape / an aborted dialog
        #expect(R.answer(buttonIndex: 7) == .cancel)
    }

    @Test func onlyTheAnswerGivenIsRememberedAndOnlyWhenTicked() {
        #expect(R.rememberLabel == "Do this from now on, and stop asking")
        #expect(R.remembered(.keep, checkbox: true) == .keep)
        #expect(R.remembered(.stop, checkbox: true) == .stop)
        #expect(R.remembered(.cancel, checkbox: true) == nil)
        #expect(R.remembered(.keep, checkbox: false) == nil)
        #expect(R.remembered(.stop, checkbox: false) == nil)
    }

    @Test func theLastWindowClosingQuitsOnlyWhenNotResidentAndNotAsking() {
        #expect(R.quitsWhenLastWindowCloses(inBackground: false, asking: false))
        #expect(!R.quitsWhenLastWindowCloses(inBackground: true, asking: false))
        #expect(!R.quitsWhenLastWindowCloses(inBackground: false, asking: true))
    }

    @Test func theQuestionNamesTheCountAndTheMenuBar() {
        #expect(R.question(liveSessions: 1).message == "One session is still running.")
        #expect(R.question(liveSessions: 3).message == "3 sessions are still running.")
        let detail = R.question(liveSessions: 2).detail
        #expect(detail.hasPrefix("Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window"))
        #expect(detail.contains("you will find Terminal Deck in the menu bar"))
        #expect(detail == BackendFreeOSResidentDetail.text)
    }
}

/// The same sentence the backend port carries (BackendOSResidentRules.quitQuestion), written out
/// once here so the Core test needs no backend import.
private enum BackendFreeOSResidentDetail {
    static let text = "Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window, and put them back — screens and all — the next time you open it.\n\nWhile they are running you will find Terminal Deck in the menu bar, which lists them and can stop any of them, or all of them, without opening a window."
}
