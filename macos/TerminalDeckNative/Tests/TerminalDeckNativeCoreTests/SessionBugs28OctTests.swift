import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// 28 Oct, Asad's three session bugs (Sessions seat). The core rules behind bug A (the app gave up reconnecting to
/// the session helper after one cancelled try) and bug B (typing meant for Deck Dev went into the phone beside it).
@Suite("Session bugs 28 Oct: reconnect retries and where typing goes")
struct SessionBugs28OctTests {
    // MARK: Bug A — a lost session helper is reconnected until one answers

    @Test func quickRetriesThenEveryThirtySeconds() {
        #expect((1...4).map { NativeHOSTReconnectPlan.pause(after: $0) } == [1, 2, 3, 4])
        #expect(NativeHOSTReconnectPlan.pause(after: 5) == 30)
        #expect(NativeHOSTReconnectPlan.pause(after: 500) == 30, "never gives up while the app runs")
    }

    @Test func aDeliberateRestartIsNotOneTry() {
        // The 27 Oct 23:11 log: "attempt 1 failed … CancellationError" then "gave up after 1 attempt(s)".
        var plan = NativeHOSTReconnectPlan()
        let first = plan.failed(attempt: 1, "The operation couldn’t be completed. (Swift.CancellationError error 1.)")
        #expect(first?.contains("attempt 1 failed") == true)
        #expect(first?.contains("gave up") == false)
        #expect(NativeHOSTReconnectPlan.pause(after: 1) > 0, "a second attempt follows")
    }

    @Test func slowRetriesDoNotFillTheLog() {
        var plan = NativeHOSTReconnectPlan()
        for attempt in 1...4 { #expect(plan.failed(attempt: attempt, "no helper") != nil) }
        #expect(plan.failed(attempt: 5, "no helper")?.contains("every 30 s") == true)
        #expect(plan.failed(attempt: 6, "no helper") == nil, "the same failure again is not written every 30 s")
        #expect(plan.failed(attempt: 7, "launchd refused") != nil, "a new reason is written")
    }

    // MARK: Bug B — typing goes only where he can see it going

    @Test func theTerminalSaysWhenThePhoneBesideItHasTheKeyboard() {
        #expect(TerminalKeyboardNotice.phoneHasTheKeyboard(terminalOnScreen: true, sessionLive: true, holderIsPhoneInSameWindow: true))
        #expect(!TerminalKeyboardNotice.phoneHasTheKeyboard(terminalOnScreen: true, sessionLive: true, holderIsPhoneInSameWindow: false),
                "the terminal itself (or nothing of the phone's) holds it: no notice")
        #expect(!TerminalKeyboardNotice.phoneHasTheKeyboard(terminalOnScreen: false, sessionLive: true, holderIsPhoneInSameWindow: true),
                "a terminal that is not on screen draws nothing")
        #expect(!TerminalKeyboardNotice.phoneHasTheKeyboard(terminalOnScreen: true, sessionLive: false, holderIsPhoneInSameWindow: true),
                "an ended session has no prompt to type into")
    }

    @Test func choosingASessionMovesTheKeyboardForAMomentOnly() {
        var choice = TerminalKeyboardChoice()
        #expect(!choice.moves(now: 100), "nothing chosen: a terminal asking never takes it from a phone")
        choice.chose(at: 100)
        #expect(choice.moves(now: 100.2), "its terminal lands in the window a moment after his click")
        #expect(choice.moves(now: 100 + TerminalKeyboardChoice.lasts))
        #expect(!choice.moves(now: 100 + TerminalKeyboardChoice.lasts + 0.01), "later, a terminal re-showing is not his choice")
        #expect(!choice.moves(now: 99), "a clock read before the choice is not after it")
    }
}
