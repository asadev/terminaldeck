import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: interrupted restart preserves exact recovery records")
struct BackendFoundationTestsSessionsRecoveryLedger {
    private func saved(_ tab: String, patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("tabKey", .string(tab)), .init("agentSessionId", .string(tab)), .init("cwd", .string("/fixture/project")), .init("provider", .string("claude")), .init("profileId", .string("login-b")), .init("homeProfileId", .string("login-a")), .init("model", .string("sonnet")), .init("cols", .number(112)), .init("rows", .number(38)), .init("lastSeenAt", .number(123))]).merging(patch)
    }
    private func disk(_ file: URL) throws -> [NativeRPCValue] { try NativeRPCValue.parseJSON(Data(contentsOf: file))["openSessions"].elements ?? [] }
    private func seed(_ scratch: BackendFoundationTestsSessionsScratch, _ records: [NativeRPCValue]) throws -> URL {
        try scratch.write("state.json", String(decoding: NativeStateStore.defaults.setting("openSessions", .array(records)).encodedJSON(), as: UTF8.self))
    }
    private func open(_ file: URL) async throws -> NativeStateStore {
        let store = try NativeStateStore(file: file, ownership: .exclusive, clock: { 1700000000000 })
        try await store.startSessionLedger(); return store
    }
    // TS session-recovery.test.ts:82 — projection/held-field half; full spawn driver remains unavailable.
    @Test func enforcedLimitsPreservedOnlyWhereTheyExist() throws {
        let limits = NativeRPCValue.object([.init("deniedTools", .array([.string("WebFetch")])), .init("noSkills", .bool(true))]), limited = saved("limited", patch: limits), plain = saved("plain")
        let first = try BackendSessionSaved(limited).input(resume: true), second = try BackendSessionSaved(plain).input(resume: true)
        #expect(first.deniedTools == ["WebFetch"]); #expect(first.noSkills == true)
        let secondWire = try NativeRPCValue.parseJSON(JSONEncoder().encode(second)); #expect(!secondWire.has("deniedTools")); #expect(!secondWire.has("noSkills"))
        var held = try NativeOpenSessionLedger(saved: []); let entry = try held.hold(limited, reason: "offline", at: 1)
        #expect(entry.saved["deniedTools"] == limits["deniedTools"]); #expect(entry.saved["noSkills"] == limits["noSkills"])
    }
    // TS session-recovery.test.ts:96
    @Test func heldConversationModelAndAccountFolderKept() throws {
        var held = try NativeOpenSessionLedger(saved: []); let original = saved("held")
        #expect(try held.hold(original, reason: "offline", at: 1).saved == original)
        let marked = try held.hold(original, reason: "no id", pick: true, at: 1)
        #expect(marked.pick); #expect(marked.saved == original)
        held.failHeld(marked.key, reason: "still no id", at: 2); #expect(held.heldSession(marked.key)?.pick == true)
    }
    // TS session-recovery.test.ts:119
    @Test func anonymousShellMigratesOnceAcrossDiskRestarts() async throws {
        let s = try BackendFoundationTestsSessionsScratch(), legacy = saved("old", patch: .object([.init("provider", .string("shell"))])).removing("tabKey").removing("agentSessionId").removing("model"), file = try seed(s, [legacy])
        var store = try await open(file)
        let migrated = try #require(disk(file).first), key = try #require(migrated["tabKey"].string)
        #expect(!key.isEmpty); try await store.ledgerNote("shell-process-1", saved: migrated.setting("lastSeenAt", .number(200))); await store.close()
        store = try await open(file); try await store.ledgerNote("shell-process-2", saved: disk(file)[0].setting("lastSeenAt", .number(300)))
        #expect(try disk(file).count == 1); #expect(try disk(file)[0]["tabKey"].string == key); #expect(try disk(file)[0]["cwd"] == legacy["cwd"])
        await store.close()
    }
    // TS session-recovery.test.ts:135
    @Test func pendingLimitsKeptOnDiskBeforeRestore() async throws {
        let s = try BackendFoundationTestsSessionsScratch(), limited = saved("limited", patch: .object([.init("deniedTools", .array([.string("Bash"), .string("mcp__deck-control")])), .init("noSkills", .bool(true))])), file = try seed(s, [limited]), store = try await open(file)
        try await store.ledgerFlush(); #expect(try disk(file)[0]["deniedTools"] == limited["deniedTools"]); #expect(try disk(file)[0]["noSkills"].bool == true); await store.close()
    }
    // TS session-recovery.test.ts:145
    @Test func droppingPendingStopsKeepingPreviousLaunch() async throws {
        let s = try BackendFoundationTestsSessionsScratch(), file = try seed(s, [saved("old-a"), saved("old-b")]), store = try await open(file)
        #expect(try disk(file).count == 2); try await store.ledgerDropPending(); try await store.ledgerNote("process-new", saved: saved("new"))
        #expect(try disk(file).compactMap { $0["tabKey"].string } == ["new"]); await store.close()
    }
    // TS session-recovery.test.ts:197
    @Test func unrestoredTabsSurvivePartialRestartFailureAndShutdown() async throws {
        let s = try BackendFoundationTestsSessionsScratch(), originals = [saved("a"), saved("b"), saved("c")], file = try seed(s, originals)
        var store = try await open(file)
        try await store.ledgerFlush(); #expect(try disk(file) == originals)
        try await store.ledgerNote("process-a-1", saved: originals[0].setting("lastSeenAt", .number(200))); #expect(try disk(file).compactMap { $0["tabKey"].string } == ["a", "b", "c"]); await store.close()
        store = try await open(file); try await store.ledgerNote("process-a-2", saved: originals[0].setting("lastSeenAt", .number(300)))
        _ = try await store.holdSession(originals[1], reason: "conversation volume offline"); try await store.ledgerNote("process-c-2", saved: originals[2])
        #expect(try disk(file).compactMap { $0["agentSessionId"].string } == ["a", "b", "c"]); #expect(try disk(file)[1] == originals[1])
        try await store.ledgerFreeze(); try await store.ledgerForget("process-a-2"); #expect(try disk(file).count == 3); await store.close()
        store = try await open(file); _ = try await store.holdSession(disk(file)[1], reason: "still offline"); try await store.ledgerFlush()
        #expect(try disk(file).compactMap { $0["tabKey"].string } == ["a", "b", "c"]); await store.close()
    }
}

private final class BackendFoundationTestsSessionsEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackendSessionEvent] = []
    func note(_ event: BackendSessionEvent) { lock.withLock { events.append(event) } }
    var empty: Bool { lock.withLock { events.isEmpty } }
}

@Suite("Foundation: inert PTY no-op removal")
struct BackendFoundationTestsSessionsRemoved {
    // TS session-removed.test.ts:135 — no process is spawned by this case.
    @Test func unknownSessionEmitsNothing() {
        let events = BackendFoundationTestsSessionsEventRecorder(), manager = BackendPTYManager(inheritedEnvironment: [:]) { events.note($0) }
        manager.kill("never-existed"); #expect(events.empty)
    }
}
