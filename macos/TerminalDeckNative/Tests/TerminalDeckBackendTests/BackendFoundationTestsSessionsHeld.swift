import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: sessions held until a start or explicit release")
struct BackendFoundationTestsSessionsHeld {
    private func saved(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        NativeRPCValue.object([.init("cwd", .string("/home/asad/ClaudeKiwi")), .init("provider", .string("claude")), .init("profileId", .null), .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1700000000000))]).merging(patch)
    }
    // TS session-held.test.ts:32
    @Test func holdsRequestedAgent() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "it could not be started again", at: 1)
        #expect(entry.wireValue["provider"].string == "claude"); #expect(held.snapshot()[0]["provider"].string == "claude")
    }
    // TS session-held.test.ts:43
    @Test func savedShapeExcludesFailure() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let wanted = saved(.object([.init("profileId", .string("work"))]))
        let entry = try held.hold(wanted, reason: "the folder is not on this machine", at: 1)
        #expect(entry.saved == wanted); #expect(entry.saved["reason"] == .missing); #expect(entry.saved["at"] == .missing)
        #expect(held.snapshot() == [wanted])
    }
    // TS session-held.test.ts:55
    @Test func stableTabKeyKept() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(.object([.init("tabKey", .string("k-left"))])), reason: "the folder is not on this machine", at: 1)
        #expect(entry.wireValue["tabKey"].string == "k-left"); #expect(entry.saved["tabKey"].string == "k-left")
    }
    // TS session-held.test.ts:69
    @Test func oldEntryHasNoTabKeyProperty() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "it could not be started again", at: 1)
        #expect(!entry.wireValue.has("tabKey")); #expect(!entry.saved.has("tabKey"))
    }
    // TS session-held.test.ts:77
    @Test func confinementDeviceKept() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(.object([.init("confineDeviceId", .string("phone-7"))])), reason: "the boundary could not be set", at: 1)
        #expect(entry.wireValue["confineDeviceId"].string == "phone-7"); #expect(entry.saved["confineDeviceId"].string == "phone-7")
    }
    // TS session-held.test.ts:91
    @Test func keyboardTabHasNoDeviceProperty() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "it could not be started again", at: 1)
        #expect(!entry.wireValue.has("confineDeviceId")); #expect(!entry.saved.has("confineDeviceId"))
    }
    // TS session-held.test.ts:97
    @Test func identicalTabsStaySeparate() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let first = try held.hold(saved(), reason: "no", at: 1), second = try held.hold(saved(), reason: "no", at: 1)
        #expect(first.key != second.key); #expect(held.heldSessions().count == 2)
    }
    // TS session-held.test.ts:113
    @Test func oldestFirstTabOrderKept() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        for cwd in ["/a", "/b", "/c"] { try held.hold(saved(.object([.init("cwd", .string(cwd))])), reason: "no", at: 1) }
        #expect(held.heldSessions().compactMap { $0.wireValue["cwd"].string } == ["/a", "/b", "/c"])
    }
    // TS session-held.test.ts:122
    @Test func reasonVerbatim() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        #expect(try held.hold(saved(), reason: "it could not be started again: File not found", at: 1).reason == "it could not be started again: File not found")
    }
    // TS session-held.test.ts:133
    @Test func failedRetryKeepsEntryAndUpdatesReason() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "first reason", at: 1)
        held.failHeld(entry.key, reason: "second reason", at: 2)
        #expect(held.heldSessions().count == 1); #expect(held.heldSession(entry.key)?.reason == "second reason")
    }
    // TS session-held.test.ts:147
    @Test func retryTimeMovesForward() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "first", at: 1)
        held.failHeld(entry.key, reason: "second", at: 2); #expect(held.heldSession(entry.key)!.at >= entry.at)
    }
    // TS session-held.test.ts:156
    @Test func unknownRetryAndReleaseAreNoOps() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        held.failHeld("held-99", reason: "no", at: 1); #expect(held.releaseHeld("held-99") == false)
    }
    // TS session-held.test.ts:165
    @Test func releaseOnlyOnce() throws {
        var held = try NativeOpenSessionLedger(saved: [])
        let entry = try held.hold(saved(), reason: "no", at: 1)
        let released = held.releaseHeld(entry.key), releasedAgain = held.releaseHeld(entry.key)
        #expect(released); #expect(!releasedAgain); #expect(held.heldEmpty)
    }
    // TS session-held.test.ts:200
    @Test func noChangeHookNeeded() throws {
        var held = try NativeOpenSessionLedger(saved: []); _ = try held.hold(saved(), reason: "no", at: 1)
    }
}

@Suite("Foundation: Codex rollout discovery and independent carry")
struct BackendFoundationTestsSessionsCodexCarry {
    let thread = "0199a6e2-7b3c-7d10-9a1e-2f3c4d5e6f70"
    let other = "0199a6e2-7b3c-7d10-9a1e-2f3c4d5e6f71"
    private func rollout(_ scratch: BackendFoundationTestsSessionsScratch, home: String = "a", id: String, seconds: Int = 1, cwd: String = "/fixture/proj", more: String = "") throws -> URL {
        let stamp = String(format: "2026-08-12T09-00-%02d", seconds)
        let meta = try BackendFoundationTestsSessionsFixtures.json(["timestamp": stamp.replacingOccurrences(of: "-00-", with: ":00:") + "Z", "type": "session_meta", "payload": ["id": id, "cwd": cwd, "originator": "codex_cli_rs"]])
        return try scratch.write(home + "/sessions/2026/08/12/rollout-" + stamp + "-" + id + ".jsonl", meta + "\n" + more)
    }
    private var start: Double { 1786525200000 } // 2026-08-12 09:00 UTC, milliseconds.
    private var now: Date { Date(timeIntervalSince1970: 1786525260) }
    private func find(_ scratch: BackendFoundationTestsSessionsScratch, cwd: String = "/fixture/proj", claimed: Set<String> = []) throws -> BackendSessionSwitchCodexCarry.Thread? {
        try BackendSessionSwitchCodexCarry.find(home: scratch.root.appendingPathComponent("a").path, cwd: cwd, startedAt: start, claimed: claimed, now: now)
    }
    // TS codex-carry.test.ts:44
    @Test func onlyRolloutStartedHereAfterStart() throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        _ = try scratch.write("a/sessions/2026/08/12/rollout-2026-08-12T08-00-00-" + other + ".jsonl", BackendFoundationTestsSessionsFixtures.json(["type": "session_meta", "payload": ["id": other, "cwd": "/fixture/proj"]]) + "\n")
        let file = try rollout(scratch, id: thread, seconds: 5, more: "{\"type\":\"response_item\"}\n"), found = try find(scratch)
        #expect(found?.id == thread); #expect(found?.file == file); #expect(found?.relative == "2026/08/12/" + file.lastPathComponent)
    }
    // TS codex-carry.test.ts:58
    @Test func noRolloutAnswersNothing() throws { let scratch = try BackendFoundationTestsSessionsScratch(); #expect(try find(scratch) == nil) }
    // TS codex-carry.test.ts:63
    @Test func ambiguousRolloutsNeverGuessed() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(); _ = try rollout(scratch, id: thread); _ = try rollout(scratch, id: other, seconds: 2)
        #expect(try find(scratch) == nil); #expect(try find(scratch, claimed: [other])?.id == thread)
    }
    // TS codex-carry.test.ts:73
    @Test func otherFolderRolloutIgnored() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(); _ = try rollout(scratch, id: thread, cwd: "/fixture/elsewhere")
        #expect(try find(scratch) == nil)
    }
    // TS codex-carry.test.ts:82
    @Test func carryCopiesSameRelativePathWithoutLink() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), file = try rollout(scratch, id: thread, more: "{\"type\":\"response_item\"}\n")
        // TS codex-carry.ts carryCodexThread answers `string | null` (the TS test reads `placed ?? ''`).
        let found = try #require(try find(scratch)), placed = try #require(BackendSessionSwitchCodexCarry.carry(found, targetHome: scratch.root.appendingPathComponent("b").path))
        #expect(placed.path == scratch.root.appendingPathComponent("b/sessions/" + found.relative).path)
        #expect(try Data(contentsOf: placed) == Data(contentsOf: file))
        try Data("changed".utf8).write(to: file); #expect(try String(contentsOf: placed, encoding: .utf8) != "changed")
    }
    // TS codex-carry.test.ts:97
    @Test func carryReplacesOlderCopy() throws {
        let scratch = try BackendFoundationTestsSessionsScratch(); _ = try rollout(scratch, home: "b", id: thread)
        _ = try rollout(scratch, id: thread, more: "{\"type\":\"response_item\",\"n\":2}\n")
        let found = try #require(try find(scratch))
        let placed = try #require(BackendSessionSwitchCodexCarry.carry(found, targetHome: scratch.root.appendingPathComponent("b").path))
        #expect(try String(contentsOf: placed, encoding: .utf8).contains("\"n\":2"))
    }
    // TS codex-carry.test.ts:109
    @Test func disappearedSourceAnswersNothingAndCreatesNoTargetDirectory() throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        let missing = BackendSessionSwitchCodexCarry.Thread(id: thread, file: scratch.root.appendingPathComponent("nope.jsonl"), relative: "x/rollout.jsonl")
        let placed: URL? = BackendSessionSwitchCodexCarry.carry(missing, targetHome: scratch.root.appendingPathComponent("b").path)
        #expect(placed == nil); #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("b/sessions/x").path))
    }
}
