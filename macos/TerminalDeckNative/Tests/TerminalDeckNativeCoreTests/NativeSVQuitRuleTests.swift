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

    /// 2 Nov restarts audit: every quit line names who asked, so a Dock Quit, a script and the app itself differ.
    @Test func aQuitEventNamesItsSender() {
        #expect(R.quitEventSender(bundleID: "com.apple.dock", name: "Dock", isSelf: false) == "the Dock (its Quit menu)")
        #expect(R.quitEventSender(bundleID: nil, name: "osascript", isSelf: false) == "osascript")
        #expect(R.quitEventSender(bundleID: "dev.terminaldeck.app", name: "Terminal Deck", isSelf: true) == "Terminal Deck itself")
        #expect(R.quitEventSender(bundleID: "com.example.tool", name: nil, isSelf: false) == "com.example.tool")
        #expect(R.quitEventSender(bundleID: nil, name: "", isSelf: false) == "a script")
    }

    /// install-24 final check F1: a quit AppKit refused before asking (a sheet came back) closes the windows that
    /// held a sheet and tries once more; it never loops.
    @Test func aRefusedQuitRetriesOnceAfterClosingTheSheetWindows() {
        #expect(NativeQuitRetry.next(asked: true, attempt: 1) == .done)
        #expect(NativeQuitRetry.next(asked: false, attempt: 1) == .closeSheetWindowsAndRetry)
        #expect(NativeQuitRetry.next(asked: false, attempt: 2) == .giveUp)
        #expect(NativeQuitRetry.next(asked: true, attempt: 2) == .done)
    }

    /// install-25 F1: the app's own answer finishes a refused quit (1 now, 2 later, 0 cancel), never a half-quit.
    @Test func aRefusedQuitIsFinishedByTheAppsOwnAnswer() {
        #expect(NativeQuitRetry.direct(1) == .exitNow)
        #expect(NativeQuitRetry.direct(2) == .waitForShutdown)
        #expect(NativeQuitRetry.direct(0) == .cancelled)
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

/// The quit question's explanation, written out once here so the Core test needs no backend import.
private enum BackendFreeOSResidentDetail {
    static let text = "Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window, and put them back — screens and all — the next time you open it.\n\nWhile they are running you will find Terminal Deck in the menu bar, which lists them and can stop any of them, or all of them, without opening a window."
}
