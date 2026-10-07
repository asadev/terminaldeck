import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S5. Ports src/main/picked-conversation.test.ts (7 cases). Needs NIGHT-REQUESTS REQ S5-SESS-3
// (BackendPickedConversations); not compiled until `S5_PICKED_CONVERSATIONS` is defined.

final class BackendFoundationTestsS5SessionsPickedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []
    private var clock: Double = 1_000_000
    func learned(_ id: String, _ conversation: String) { lock.lock(); values.append([id, conversation]); lock.unlock() }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
    var now: Double { lock.lock(); defer { lock.unlock() }; return clock }
    func advance(_ ms: Double) { lock.lock(); clock += ms; lock.unlock() }
}

private let FRESH = "11111111-1111-4111-8111-111111111111"
private let PICKED = "22222222-2222-4222-8222-222222222222"
private let OTHER = "33333333-3333-4333-8333-333333333333"

private struct PickFixture {
    let scratch: BackendFoundationTestsSessionsScratch
    let cwd: String, configDir: String
    var watch: BackendPickWatch { BackendPickWatch(cwd: cwd, configDir: configDir) }
    init(_ name: String) throws {
        scratch = try BackendFoundationTestsSessionsScratch()
        cwd = scratch.root.appendingPathComponent(name + "/work").path
        configDir = scratch.root.appendingPathComponent(name + "/cfg").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: configDir + "/sessions", withIntermediateDirectories: true)
    }
    func transcript(_ id: String, _ body: String = "{\"type\":\"user\"}\n") throws {
        let dir = URL(fileURLWithPath: configDir).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: dir.appendingPathComponent(id + ".jsonl"))
    }
    func record(_ pid: Int, _ conversation: String, owner: Int? = nil) throws {
        let text = try BackendFoundationTestsSessionsFixtures.json(["pid": owner ?? pid, "sessionId": conversation, "cwd": cwd])
        try Data(text.utf8).write(to: URL(fileURLWithPath: configDir + "/sessions/\(pid).json"))
    }
}

private func start(_ session: String?, _ cli: String?, provider: String = "claude", event: String = "SessionStart") -> BackendPickHookNote {
    BackendPickHookNote(provider: provider, event: event, sessionID: session, cliSessionID: cli)
}

@Suite("S5 sessions: picking a conversation on Claude Code's list (picked-conversation.test.ts)")
struct BackendFoundationTestsS5SessionsPickedConversation {
    // TS picked-conversation.test.ts:40
    @Test func transcriptCheckAcceptsOnlyNonEmptyTranscriptUnderThisFolder() async throws {
        let f = try PickFixture("check")
        #expect(await BackendPickedRules.hasTranscript(f.watch, conversationID: PICKED) == false)
        try f.transcript(PICKED, "")
        #expect(await BackendPickedRules.hasTranscript(f.watch, conversationID: PICKED) == false)
        try f.transcript(PICKED)
        #expect(await BackendPickedRules.hasTranscript(f.watch, conversationID: PICKED) == true)
        #expect(await BackendPickedRules.hasTranscript(f.watch, conversationID: "../../etc/passwd") == false)
    }
    // TS picked-conversation.test.ts:50
    @Test func processRecordReadOnlyWhenAboutThatProcess() async throws {
        let f = try PickFixture("record")
        try f.record(4242, PICKED)
        #expect(await BackendPickedRules.sessionFileConversation(configDir: f.configDir, pid: 4242) == PICKED)
        try f.record(4343, PICKED, owner: 9999)
        #expect(await BackendPickedRules.sessionFileConversation(configDir: f.configDir, pid: 4343) == nil)
        #expect(await BackendPickedRules.sessionFileConversation(configDir: f.configDir, pid: 5555) == nil)
    }
    // TS picked-conversation.test.ts:61
    @Test func hookIgnoresFreshIdThenLearnsPickedOnce() async throws {
        let f = try PickFixture("hook"), log = BackendFoundationTestsS5SessionsPickedLog()
        let picked = BackendPickedConversations(pidOf: { _ in nil }, learned: { log.learned($0, $1) })
        await picked.watch("tab-1", f.watch)
        await picked.noteHook(start("tab-1", FRESH))
        #expect(log.calls.isEmpty)
        try f.transcript(PICKED)
        await picked.noteHook(start("tab-1", PICKED)); await picked.noteHook(start("tab-1", PICKED))
        #expect(log.calls == [["tab-1", PICKED]])
    }
    // TS picked-conversation.test.ts:76
    @Test func hookIgnoresOtherAgentsEventsAndUnwatchedSessions() async throws {
        let f = try PickFixture("ignore"); try f.transcript(PICKED)
        let log = BackendFoundationTestsS5SessionsPickedLog()
        let picked = BackendPickedConversations(pidOf: { _ in nil }, learned: { log.learned($0, $1) })
        await picked.watch("tab-1", f.watch)
        await picked.noteHook(start("tab-1", PICKED, provider: "codex"))
        await picked.noteHook(start("tab-1", PICKED, event: "UserPromptSubmit"))
        await picked.noteHook(start("tab-2", PICKED))
        await picked.noteHook(start(nil, PICKED))
        #expect(log.calls.isEmpty)
    }
    // TS picked-conversation.test.ts:89
    @Test func learnsNothingForASessionClosedWhileTheDiskWasBeingAsked() async throws {
        let f = try PickFixture("closed"); try f.transcript(PICKED)
        let log = BackendFoundationTestsS5SessionsPickedLog()
        let picked = BackendPickedConversations(pidOf: { _ in nil }, learned: { log.learned($0, $1) })
        await picked.watch("tab-1", f.watch)
        let pending = Task { await picked.noteHook(start("tab-1", PICKED)) }
        await picked.forget("tab-1")
        await pending.value
        #expect(log.calls.isEmpty)
    }
    // TS picked-conversation.test.ts:103
    @Test func readsOnTypingAtMostOncePerGapAndFollowsALaterPick() async throws {
        let f = try PickFixture("typing"), log = BackendFoundationTestsS5SessionsPickedLog()
        let picked = BackendPickedConversations(pidOf: { _ in 777 }, learned: { log.learned($0, $1) }, now: { log.now })
        await picked.watch("tab-1", f.watch)
        try f.record(777, FRESH)
        await picked.noteTyping("tab-1")
        #expect(log.calls.isEmpty)
        try f.transcript(PICKED); try f.record(777, PICKED)
        await picked.noteTyping("tab-1")
        #expect(log.calls.isEmpty) // inside the gap: not read again
        log.advance(BackendPickedRules.typingGapMilliseconds)
        await picked.noteTyping("tab-1")
        #expect(log.calls == [["tab-1", PICKED]])
        try f.transcript(OTHER); try f.record(777, OTHER)
        log.advance(BackendPickedRules.typingGapMilliseconds)
        await picked.noteTyping("tab-1")
        #expect(log.calls.last == ["tab-1", OTHER])
    }
    // TS picked-conversation.test.ts:130
    @Test func readsNothingForAnUnwatchedSessionOrOneWithNoProcess() async throws {
        let f = try PickFixture("unwatched"); try f.transcript(PICKED); try f.record(777, PICKED)
        let log = BackendFoundationTestsS5SessionsPickedLog()
        let asked = BackendFoundationTestsS5SessionsPickedLog()
        let picked = BackendPickedConversations(pidOf: { id in asked.learned(id, ""); return nil }, learned: { log.learned($0, $1) })
        await picked.noteTyping("tab-1")
        #expect(asked.calls.isEmpty)
        await picked.watch("tab-1", f.watch)
        await picked.noteTyping("tab-1")
        #expect(log.calls.isEmpty)
    }
}
