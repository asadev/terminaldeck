import Foundation
import Testing
@testable import TerminalDeckBackend

// Seam S5-7 landed (lane P1); the build flag guard is gone.

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [(session: String, data: String)] = []
    private var _sleeps: [Duration] = []
    var status: BackendSessionStatus = .waiting
    var performed: [(String, String)] = []
    func write(_ s: String, _ d: String) { lock.lock(); _writes.append((s, d)); lock.unlock() }
    func sleep(_ d: Duration) { lock.lock(); _sleeps.append(d); lock.unlock() }
    var writes: [(session: String, data: String)] { lock.lock(); defer { lock.unlock() }; return _writes }
    var sleeps: [Duration] { lock.lock(); defer { lock.unlock() }; return _sleeps }
    func data(to session: String) -> [String] { writes.filter { $0.session == session }.map(\.data) }
}

private func harness(status: BackendSessionStatus = .waiting) async -> (BackendSessionSwitchDeferred, Recorder) {
    let recorder = Recorder(); recorder.status = status
    let hooks = BackendSessionSwitchDeferred.Hooks(
        subject: { _, _ in (name: "Work", inPlace: false) },
        perform: { session, account in recorder.performed.append((session, account)); return "replacement" },
        status: { _ in recorder.status },
        write: { session, data in recorder.write(session, data) },
        sleep: { recorder.sleep($0) })
    return (BackendSessionSwitchDeferred.forTesting(hooks, emit: { _ in }), recorder)
}
private let ESC = "\u{1b}"

@Suite("S5 switch-later: the armed register and the replay (TS PendingSwitches, replayWrites)")
struct BackendFoundationTestsS5SwitchLaterActor {
    // TS switch-later.test.ts:381
    @Test func ordinaryTypingPassesThroughWhenNothingIsArmed() async throws {
        let (owner, rec) = await harness(); try await owner.typed(sessionID: "s1", data: "hello")
        #expect(rec.data(to: "s1") == ["hello"]); #expect(rec.performed.isEmpty)
    }
    // TS switch-later.test.ts:386
    @Test func accumulatesWhileArmedStillPassingEveryKeystrokeThrough() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "fix "); try await owner.typed(sessionID: "s1", data: "the bug")
        #expect(rec.data(to: "s1") == ["fix ", "the bug"]); #expect(rec.performed.isEmpty)
    }
    // TS switch-later.test.ts:394 (+ TS replay delays: 400 ms before the line, 50 ms before the Enter)
    @Test func firesOnEnterAndReplaysAfterTheSourceDelays() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "fix the"); try await owner.typed(sessionID: "s1", data: " bug\r")
        await owner.waitForIdle(sessionID: "s1")
        #expect(rec.performed.count == 1); #expect(rec.performed.first?.0 == "s1"); #expect(rec.performed.first?.1 == "b")
        #expect(rec.data(to: "s1") == ["fix the", " bug"])               // the Enter itself is deliberately not forwarded to the old session
        #expect(rec.data(to: "replacement").count == 2)
        #expect(rec.data(to: "replacement").last == "\r")
        #expect(rec.sleeps == [.milliseconds(400), .milliseconds(50)])
    }
    // TS switch-later.test.ts:543
    @Test func lineAndEnterAreTwoSeparateWritesWithTheBareLine() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        let line = "carry on with the refactor and make sure the tests still pass"
        try await owner.typed(sessionID: "s1", data: line + "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.data(to: "replacement") == [line, "\r"])
    }
    // TS switch-later.test.ts:549
    @Test func lineMentioningAFileGetsATrailingSpace() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "read @src/main/index.ts\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.data(to: "replacement").first == "read @src/main/index.ts ")
    }
    // TS switch-later.test.ts:556
    @Test func nothingIsAddedToALineHeIsAskedToCheck() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "read @src/main/index.ts" + ESC + "[A\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.data(to: "replacement").first == "read @src/main/index.ts")
        #expect(!rec.data(to: "replacement").contains("\r"))
    }
    // TS switch-later.test.ts:409
    @Test func refusesToSendWhenNotSureItReadTheLine() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "draft" + ESC + "[A"); try await owner.typed(sessionID: "s1", data: "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(!rec.data(to: "replacement").contains("\r")); #expect(rec.sleeps == [.milliseconds(400)])
    }
    // TS switch-later.test.ts:431
    @Test func arrowKeyCarriesHisWordsOnlyAndDoesNotSend() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "run the tests"); try await owner.typed(sessionID: "s1", data: ESC + "[A"); try await owner.typed(sessionID: "s1", data: "\r")
        await owner.waitForIdle(sessionID: "s1")
        let replay = rec.data(to: "replacement").joined(); #expect(replay.contains("run the tests")); #expect(!replay.contains("[A")); #expect(!replay.contains("\r"))
    }
    // TS switch-later.test.ts:443
    @Test func reproducibleEditSendsTheLine() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "run the tesst" + ESC + "[D\u{7f}" + ESC + "[F"); try await owner.typed(sessionID: "s1", data: "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.data(to: "replacement").joined().contains("run the test")); #expect(rec.data(to: "replacement").last == "\r")
    }
    // TS switch-later.test.ts:456
    @Test func pastedBlockDoesNotFireOnItsOwnNewlineAndIsNotSent() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: ESC + "[200~first\rsecond" + ESC + "[201~"); #expect(rec.performed.isEmpty)
        try await owner.typed(sessionID: "s1", data: "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.performed.count == 1); #expect(rec.data(to: "replacement").joined().contains("first\nsecond")); #expect(!rec.data(to: "replacement").contains("\r"))
    }
    // TS switch-later.test.ts:471
    @Test func unfinishedSequenceBlocksTheSendButStillFires() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "hello" + ESC + "["); try await owner.typed(sessionID: "s1", data: "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.performed.count == 1); #expect(!rec.data(to: "replacement").contains("\r"))
    }
    // TS switch-later.test.ts:485
    @Test func aSwitchArmedIsASwitchSpent() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "one\r"); await owner.waitForIdle(sessionID: "s1")
        try await owner.typed(sessionID: "s1", data: "two\r"); #expect(rec.performed.count == 1); #expect(await owner.list().isEmpty)
        #expect(rec.data(to: "s1").last == "two\r")
    }
    // TS switch-later.test.ts:493
    @Test func sessionsAreKeptApart() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "mine"); try await owner.typed(sessionID: "s2", data: "theirs\r")
        #expect(rec.performed.isEmpty); #expect(rec.data(to: "s2") == ["theirs\r"]); #expect(await owner.list().map(\.sessionID) == ["s1"])
    }
    // TS switch-later.test.ts:502
    @Test func canBeCancelledBeforeItFires() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        await owner.cancel(sessionID: "s1"); try await owner.typed(sessionID: "s1", data: "hello\r")
        #expect(rec.performed.isEmpty); #expect(rec.data(to: "s1") == ["hello\r"])
    }
    // TS switch-later.test.ts:571
    @Test func enterWithNothingTypedPassesThroughAndStaysArmed() async throws {
        let (owner, rec) = await harness(); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "\r")
        #expect(rec.performed.isEmpty); #expect(rec.data(to: "s1") == ["\r"]); #expect(await owner.list().count == 1)
    }
    // TS switch-later.test.ts:579
    @Test func answerToAQuestionPassesThroughWhileTheAgentIsAsking() async throws {
        let (owner, rec) = await harness(status: .input); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "2"); try await owner.typed(sessionID: "s1", data: "\r")
        #expect(rec.performed.isEmpty); #expect(rec.data(to: "s1") == ["2", "\r"]); #expect(await owner.list().count == 1)
    }
    // TS switch-later.test.ts:587
    @Test func firesOnTheMessageThatComesAfterWithOnlyThatMessage() async throws {
        let (owner, rec) = await harness(status: .input); _ = try await owner.arm(sessionID: "s1", accountID: "b")
        try await owner.typed(sessionID: "s1", data: "1"); try await owner.typed(sessionID: "s1", data: "\r")
        rec.status = .waiting
        try await owner.typed(sessionID: "s1", data: "now fix the tests"); try await owner.typed(sessionID: "s1", data: "\r"); await owner.waitForIdle(sessionID: "s1")
        #expect(rec.performed.count == 1)
        let replay = rec.data(to: "replacement").joined(); #expect(replay.contains("now fix the tests")); #expect(!replay.contains("1"))
    }
}
