import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Seam S5-5 landed (lane P1); the build flag guard is gone.

private typealias Fix = S5SwitchFixture
private func refusal(meta: BackendSessionMeta?, saved: BackendSessionSaved?, target: BackendAccountProfile?) -> String? {
    BackendSessionSwitchCoordinator.refusal(meta: meta, saved: saved, target: target)
}
private func decision(_ outcome: BackendSessionRestoreDecision.Outcome = .resume, reason: String = "continuing the conversation on disk",
                      conversation: BackendSessionRestoreDecision.Conversation? = .found) throws -> BackendSessionRestoreDecision {
    BackendSessionRestoreDecision(session: try Fix.saved(profileId: "home"), outcome: outcome, reason: reason, configDirectory: "/cfg/home", conversation: conversation)
}
private func plan(target: BackendAccountProfile? = Fix.profile(), decision: BackendSessionRestoreDecision?, occupied: Bool = false, sharedStore: Bool = false) throws -> BackendSessionSwitchPlan {
    BackendSessionSwitchCoordinator.plan(sessionID: "s1", meta: Fix.meta(), saved: try Fix.saved(), target: target, decision: decision, occupied: occupied, sharedStore: sharedStore)
}

@Suite("S5 session-switch: refusals, plan, notes (TS switchRefusal, planSwitch, conversationToCarry, startFailed, switchedNote)")
struct BackendFoundationTestsS5SwitchPlan {
    // TS session-switch.test.ts:97
    @Test func refusesASessionThatIsNotRunning() throws { #expect(refusal(meta: nil, saved: try Fix.saved(), target: Fix.profile())?.contains("not running any more") == true) }
    // TS session-switch.test.ts:103
    @Test func refusesOneThatHasAlreadyEnded() throws { #expect(refusal(meta: Fix.meta(exited: true), saved: try Fix.saved(), target: Fix.profile())?.contains("already ended") == true) }
    // TS session-switch.test.ts:121
    @Test func refusesASessionTheAppStartedForItselfOrADevice() {
        let why = refusal(meta: Fix.meta(), saved: nil, target: Fix.profile()) ?? ""
        #expect(why.contains("Only a session you opened here")); #expect(why.contains("Hoot"))
    }
    // TS session-switch.test.ts:127
    @Test func refusesAPlainTerminalBySayingWhy() throws {
        let why = refusal(meta: Fix.meta(provider: "shell", profileId: nil, profileName: nil), saved: try Fix.saved("shell"), target: Fix.profile()) ?? ""
        #expect(why.contains("This tab is a plain terminal.")); #expect(why.contains("was not started by this app")); #expect(why.contains("open a new session on the account you want"))
    }
    // TS session-switch.test.ts:146
    @Test func refusesAnAccountOfADifferentAgentAndNamesBoth() throws {
        let why = refusal(meta: Fix.meta(), saved: try Fix.saved(), target: Fix.profile("chat", name: "Chat", provider: "codex")) ?? ""
        #expect(why.contains("Codex CLI")); #expect(why.contains("Claude Code"))
    }
    // TS session-switch.test.ts:159
    @Test func refusesTheAccountItIsAlreadyRunningAs() throws {
        #expect(refusal(meta: Fix.meta(profileId: "home"), saved: try Fix.saved(), target: Fix.profile("home"))?.contains("already running as that account") == true)
    }
    // TS session-switch.test.ts:168
    @Test func acceptsAnotherAccountOfTheSameAgent() throws { #expect(refusal(meta: Fix.meta(), saved: try Fix.saved(), target: Fix.profile()) == nil) }
    // TS session-switch.test.ts:172
    @Test func refusesAnAccountThatIsNoLongerOnThisMachine() throws { #expect(refusal(meta: Fix.meta(), saved: try Fix.saved(), target: nil)?.contains("not on this machine") == true) }
    // TS session-switch.test.ts:180
    @Test func aRefusalCarriesTheSentenceAndPromisesNothing() throws {
        let answer = try plan(target: nil, decision: try decision()); #expect(answer.refusal != nil); #expect(!answer.resume); #expect(answer.to == nil)
    }
    // TS session-switch.test.ts:187
    @Test func aRefusalStillNamesTheAccountTheSessionIsOn() throws {
        let from = try plan(target: nil, decision: try decision()).from; #expect(from?.id == "work"); #expect(from?.name == "Work"); #expect(from?.provider == "claude")
    }
    // TS session-switch.test.ts:193
    @Test func aRefusalIsReachedBeforeAnyDiskQuestion() throws { #expect(try plan(target: nil, decision: nil).refusal?.contains("not on this machine") == true) }
    // TS session-switch.test.ts:202
    @Test func continuesTheTargetAccountsOwnConversation() throws {
        let answer = try plan(decision: try decision()); #expect(answer.refusal == nil); #expect(answer.conversation == "theirs"); #expect(answer.resume)
    }
    // TS session-switch.test.ts:209
    @Test func startsFreshWhenTheTargetNeverWorkedInThisFolder() throws {
        let answer = try plan(decision: try decision(.fresh, reason: "no earlier conversation was found on disk for this folder", conversation: BackendSessionRestoreDecision.Conversation.none))
        #expect(answer.conversation == "stays"); #expect(!answer.resume)
    }
    // TS session-switch.test.ts:231
    @Test func saysTheStoreCouldNotBeReadRatherThanEmpty() throws {
        let answer = try plan(decision: try decision(conversation: .unknown)); #expect(answer.conversation == "unreadable"); #expect(answer.resume)
    }
    // TS session-switch.test.ts:237
    @Test func neverClaimsAContinueForAnAgentWithNoWayToContinue() throws {
        let answer = try plan(decision: try decision(.fresh, reason: "this agent has no way to continue a previous conversation", conversation: nil))
        #expect(answer.conversation == "none"); #expect(!answer.resume)
    }
    // TS session-switch.test.ts:260
    @Test func willNotJoinAConversationAnotherTabIsOn() throws {
        let answer = try plan(decision: try decision(), occupied: true); #expect(answer.conversation == "taken"); #expect(!answer.resume)
    }
    // TS session-switch.test.ts:266
    @Test func refusesOutrightWhenTheFolderHasGone() throws {
        let answer = try plan(decision: try decision(.skip, reason: "the folder it ran in is no longer on this machine", conversation: nil))
        #expect(answer.refusal?.contains("no longer on this machine") == true); #expect(!answer.resume)
    }
    // TS session-switch.test.ts:278
    @Test func refusesRatherThanGuessingWhenNothingWasDecided() throws { let answer = try plan(decision: nil); #expect(answer.refusal != nil); #expect(!answer.resume) }
    // TS session-switch.test.ts:415
    @Test func saysTheConversationFollowsWhenBothAccountsReadOneStore() throws {
        let answer = try plan(decision: try decision(), sharedStore: true); #expect(answer.conversation == "follows"); #expect(answer.resume)
    }
    // TS session-switch.test.ts:428
    @Test func stillAdmitsItCannotReadAStoreItCannotRead() throws { #expect(try plan(decision: try decision(conversation: .unknown), sharedStore: true).conversation == "unreadable") }
    // TS session-switch.test.ts:436
    @Test func doesNotClaimASharedStoreWhenAnotherTabHoldsTheConversation() throws { #expect(try plan(decision: try decision(), occupied: true, sharedStore: true).conversation == "taken") }

    // The conversation carried across a switch (TS conversationToCarry)
    private func carrying() throws -> BackendSessionSwitchPlan { try plan(decision: try decision(.resume, conversation: .found), sharedStore: true) }
    // TS session-switch.test.ts:453
    @Test func namesTheIdWhenTheTwoAccountsReadOneHistoryAndTheFileIsThere() throws {
        let p = try carrying(); #expect(p.conversation == "follows")
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: p, agentSessionID: "abc", readableInTarget: true) == "abc")
    }
    // TS session-switch.test.ts:460
    @Test func saysNothingWhenTheTranscriptIsNotReadableFromTheOtherAccount() throws {
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: try carrying(), agentSessionID: "abc", readableInTarget: false) == nil)
    }
    // TS session-switch.test.ts:469
    @Test func saysNothingWhenTheAppNeverNamedTheConversation() throws {
        let p = try carrying()
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: p, agentSessionID: nil, readableInTarget: true) == nil)
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: p, agentSessionID: "", readableInTarget: true) == nil)
    }
    // TS session-switch.test.ts:480
    @Test func saysNothingWhenThePlanIsPickingUpTheOtherAccountsOwnConversation() throws {
        let theirs = try plan(decision: try decision(.resume, conversation: .found)); #expect(theirs.conversation == "theirs")
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: theirs, agentSessionID: "abc", readableInTarget: true) == nil)
    }
    // TS session-switch.test.ts:491
    @Test func saysNothingWhenNothingIsBeingResumed() throws {
        let fresh = try plan(decision: try decision(.fresh, conversation: BackendSessionRestoreDecision.Conversation.none)); #expect(!fresh.resume)
        #expect(BackendSessionSwitchCoordinator.conversationToCarry(plan: fresh, agentSessionID: "abc", readableInTarget: true) == nil)
    }

    // What a failed switch tells the person (TS startFailed)
    // TS session-switch.test.ts:398
    @Test func failureNamesTheAccountQuotesTheAgentAndSaysNothingWasLost() {
        let message = BackendSessionSwitchCoordinator.startFailedMessage(accountName: "home@example.com", said: "No conversation found to continue")
        #expect(message.contains("home@example.com started and stopped straight away")); #expect(message.contains("“No conversation found to continue”")); #expect(message.contains("This session is still running as it was."))
    }
    // TS session-switch.test.ts:407
    @Test func failureStillSaysTheSessionIsSafeWhenTheAgentSaidNothing() {
        let message = BackendSessionSwitchCoordinator.startFailedMessage(accountName: "home@example.com", said: nil)
        #expect(!message.contains("It said")); #expect(message.contains("This session is still running as it was."))
    }

    // What the window says once a deferred switch happened (TS switchedNote)
    // TS switch-later.test.ts:523
    @Test func switchedNoteSaysWhatBecameOfTheMessage() {
        #expect(BackendSessionSwitchDeferred.switchedNote(accountName: "Work", submitted: true, line: "fix the bug").contains("sent your message"))
        #expect(BackendSessionSwitchDeferred.switchedNote(accountName: "Work", submitted: false, line: "fix the bug").contains("press Enter"))
    }
    // TS switch-later.test.ts:528
    @Test func switchedNoteDoesNotSendHimLookingForAMessageNeverCarried() {
        #expect(BackendSessionSwitchDeferred.switchedNote(accountName: "Work", submitted: false, line: "") == "Switched to Work.")
    }
}
