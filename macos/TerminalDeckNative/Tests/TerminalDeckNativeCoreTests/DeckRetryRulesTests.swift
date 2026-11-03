import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// RETRY (11 Oct, Asad: "if the app is not used for long time it goes to retry page and works
/// after clicking on retry"): the rules for when the app tries again by itself. Every time here
/// is a number passed in (a fake clock); nothing sleeps and nothing is launched.
@Suite struct DeckRetryRulesTests {
    @Test func theAppTriesAgainByItselfBeforeAPersonHasTo() {
        // reads retry by themselves; changes never
        #expect(DeckRetryRules.isRead(channel: "tasks:state"), "tasks:state is a read")
        #expect(DeckRetryRules.isRead(channel: "profiles:list"), "profiles:list is a read")
        #expect(DeckRetryRules.isRead(channel: "hoot:ready:read"), "hoot:ready:read is a read")
        #expect(!DeckRetryRules.isRead(channel: "session:write"), "session:write is a change")
        #expect(!DeckRetryRules.isRead(channel: "settings:set"), "settings:set is a change")
        #expect(!DeckRetryRules.isRead(channel: "deck-control:consent-respond"), "consent-respond is a change")
        #expect(!DeckRetryRules.isRead(channel: "list"), "a bare word is not a channel")
        // the exact words from his log
        let transient = ["The session host is unavailable. Sessions won't survive updates right now.",
            "The private session host connection failed (POSIX status 60).",
            "The private session host connection failed (POSIX status 61).",
            "The private session host could not be authenticated.",
            "The persistent host service could not complete resources.configure: The session host is unavailable. Sessions won't survive updates right now."]
        for line in transient { #expect(DeckRetryRules.isTransient(line), "transient: \(line)") }
        let real = ["The operation couldn’t be completed. (Swift.CancellationError error 1.)", "That saved agent no longer exists.",
            "This transcript belongs to a different project", "Another copy is already using your data. Quit it, then try again.",
            "The persistent host service could not complete account.facade."]
        for line in real { #expect(!DeckRetryRules.isTransient(line), "not transient: \(line)") }
        #expect(DeckRetryRules.retriesByItself(channel: "usage:context", failure: transient[1]), "a read on a dropped line is asked again")
        #expect(!DeckRetryRules.retriesByItself(channel: "profiles:signin", failure: transient[1]), "a sign-in is never repeated by itself")
        #expect(DeckRetryRules.pause(beforeAutomaticTry: 0) == 0.35 && DeckRetryRules.pause(beforeAutomaticTry: 1) == 1.0 && DeckRetryRules.pause(beforeAutomaticTry: 2) == nil, "two automatic tries, then the failure is real")
        #expect(DeckRetryRules.isRetryLabel("Try Again") && DeckRetryRules.isRetryLabel("retry") && !DeckRetryRules.isRetryLabel("Check again") && !DeckRetryRules.isRetryLabel("Install Docker"), "retry labels")
        
        // a retry control never presses itself without the "lines are back" signal, and once per signal
        var press = DeckSelfPress()
        #expect(!press.mayPress(id: "a", generation: 0, signalAge: 0, onScreenBefore: true), "no signal has ever fired: never")
        #expect(press.mayPress(id: "a", generation: 1, signalAge: 400, onScreenBefore: true), "on screen when the signal fires: one press")
        press.pressed(id: "a", generation: 1)
        #expect(!press.mayPress(id: "a", generation: 1, signalAge: 1, onScreenBefore: true), "never twice for one signal")
        #expect(!press.mayPress(id: "a", generation: 1, signalAge: 3600, onScreenBefore: true), "and no timer brings it back")
        #expect(press.mayPress(id: "a", generation: 2, signalAge: 0, onScreenBefore: true), "the next signal earns one more")
        #expect(press.mayPress(id: "b", generation: 2, signalAge: 3, onScreenBefore: false), "appearing in the same moment as the signal: one press")
        #expect(!press.mayPress(id: "c", generation: 2, signalAge: 120, onScreenBefore: false), "appearing long after it: the button is the person's")
        // one line building a card per failed project: every card gets its own press per signal (#135)
        let cardOne = DeckSelfPress.id(file: "Catalog.swift", line: 53, instance: "p1"), cardTwo = DeckSelfPress.id(file: "Catalog.swift", line: 53, instance: "p2")
        #expect(cardOne != cardTwo && DeckSelfPress.id(file: "Catalog.swift", line: 53) == "Catalog.swift:53", "an item's id names it; a lone control keeps its line")
        press.pressed(id: cardOne, generation: 2)
        #expect(press.mayPress(id: cardTwo, generation: 2, signalAge: 0, onScreenBefore: true), "the first card's press leaves the second card its own")

        // a web process that ends now and then, over days, is always reloaded
        var window = DeckCrashWindow()
        var reloads = 0
        for hour in 0..<48 { if window.reloadAfterEnd(at: Double(hour) * 3600) { reloads += 1 } }
        #expect(reloads == 48, "48 ends an hour apart: 48 reloads (the old counter gave up at the third)")
        var burst = DeckCrashWindow()
        let first = burst.reloadAfterEnd(at: 0), second = burst.reloadAfterEnd(at: 5), third = burst.reloadAfterEnd(at: 10)
        #expect(first && second && !third, "three ends in ten seconds is 'keeps crashing'")
        let later = burst.reloadAfterEnd(at: 200)
        #expect(later, "and it reloads again once a quiet minute has passed")
        
        // away long enough
        #expect(!DeckIdleRule.isLongGap(awaySeconds: 120) && DeckIdleRule.isLongGap(awaySeconds: 300) && DeckIdleRule.isLongGap(awaySeconds: 38 * 60), "five minutes away is a long gap")
        
        // closing the app: the handshake is tried three times, then the close goes on; it is never cancelled
        #expect(DeckQuitDetachRule.afterFailure(1) == .tryAgain(afterSeconds: 0.3), "first failure: try again")
        #expect(DeckQuitDetachRule.afterFailure(2) == .tryAgain(afterSeconds: 0.8), "second failure: try again")
        #expect(DeckQuitDetachRule.afterFailure(3) == .closeWithoutHandshake, "third failure: close like a scripted quit")
        #expect(DeckQuitDetachRule.afterFailure(9) == .closeWithoutHandshake, "never loops")
    }
}

/// The close-time handshake loop that runs at quit, with a fake handshake and a fake clock.
@Suite struct DeckQuitDetachTests {
    struct Refused: Error, LocalizedError { var errorDescription: String? { "The session host is unavailable. Sessions won't survive updates right now." } }
    @MainActor final class Fake {
        var failuresLeft: Int
        var tries = 0, pauses: [Double] = [], lines: [String] = []
        init(failures: Int) { failuresLeft = failures }
        func run(unattended: Bool = false) async -> DeckQuitDetach.Outcome {
            await DeckQuitDetach.run(unattended: unattended,
                handshake: { self.tries += 1; if self.failuresLeft > 0 { self.failuresLeft -= 1; throw Refused() } },
                pause: { self.pauses.append($0) },
                trace: { self.lines.append($0) })
        }
    }

    @Test @MainActor func aHandshakeThatWorksClosesAtOnce() async {
        let fake = Fake(failures: 0)
        #expect(await fake.run() == .detached(afterFailures: 0))
        #expect(fake.tries == 1); #expect(fake.pauses.isEmpty); #expect(fake.lines.isEmpty)
    }
    @Test @MainActor func aHandshakeThatFailsOnceIsTriedAgainByItself() async {
        let fake = Fake(failures: 1)
        #expect(await fake.run() == .detached(afterFailures: 1))
        #expect(fake.tries == 2); #expect(fake.pauses == [0.3])
    }
    /// The case in Asad's log (every close on 10 Oct evening): it never cancels the quit.
    @Test @MainActor func aHandshakeThatKeepsFailingStillClosesLikeAScriptedQuit() async {
        let fake = Fake(failures: 99)
        #expect(await fake.run() == .closedWithoutHandshake(failures: 3))
        #expect(fake.tries == 3); #expect(fake.pauses == [0.3, 0.8])
        #expect(fake.lines.last?.contains("detaching without it") == true)
    }
    @Test @MainActor func aScriptedQuitNeverWaits() async {
        let fake = Fake(failures: 99)
        #expect(await fake.run(unattended: true) == .closedWithoutHandshake(failures: 1))
        #expect(fake.tries == 1); #expect(fake.pauses.isEmpty)
    }
}
