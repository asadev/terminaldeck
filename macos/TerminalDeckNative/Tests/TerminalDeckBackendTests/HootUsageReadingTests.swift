import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Item 74 (2 Nov): Hoot's own context window and plan limits, read the way a session's are, for the phones' session ring.
final class HootUsageReadingTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-usage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<150 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out")
    }
    private static let hoot = BackendUsageAccount(provider: "claude", id: "profile-hoot", name: "Work", configDirectory: "/tmp/hoot-claude")
    private static let other = BackendUsageAccount(provider: "claude", id: "profile-other", name: "Home", configDirectory: "/tmp/other-claude")
    private static func weekly(_ account: BackendUsageAccount, _ percent: Double) -> BackendUsageReading {
        .init(account: account, window: .weekly, windowMinutes: 10_080, label: "Current week (all models)", used: .percent(percent),
              resets: .at(9_000_000_000_000), observedAt: 1, reportedAt: 1, source: "claude-usage-api")
    }
    actor Moves { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }

    func testHootsChatReportsItsContextAfterEachStepAndKeepsItOnlyForItsOwnConversation() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file)
        try await store.requireContext("claude/profile-hoot")
        let usage = BackendHootUsage(now: { 5_000 }), moves = Moves()
        await usage.track(BackendHootUsage.chatID, chat: store) { Self.hoot }
        await usage.setChangeHandler { await moves.add($0) }
        await usage.bindPlans { .init(sessionID: nil, account: nil, readings: [Self.weekly(Self.hoot, 40), Self.weekly(Self.other, 90)], reason: nil, assembledAt: 1) }
        let script = "read first; printf '%s\\n' "
            + #"'{"type":"system","subtype":"init","session_id":"cli-session"}' "#
            + #"'{"type":"assistant","session_id":"cli-session","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":500}}}' "#
            + #"'{"type":"result","subtype":"success","is_error":false,"session_id":"cli-session","modelUsage":{"claude-opus-5-5":{"contextWindow":1000000}}}'; read more"#
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))

        let before = try await usage.reading(id: "hoot", want: "context")
        XCTAssertEqual(before["state"].string, "nothing-yet", "no step yet: no figure, and it says why")
        XCTAssertNotNil(before["detail"].string)

        _ = try await store.say("hello")
        try await wait {
            let busy = await store.isBusy, window = await store.contextFacts().window
            return !busy && window != nil
        }
        let reading = try await usage.reading(id: "hoot", want: "context")
        XCTAssertEqual(reading["state"].string, "ok")
        XCTAssertEqual(reading["provider"].string, "claude")
        XCTAssertEqual(reading["tokens"].number, 6_500, "every token its last step had in view")
        XCTAssertEqual(reading["window"].number, 1_000_000)
        XCTAssertEqual(reading["windowBasis"].string, "reported")
        XCTAssertEqual(reading["percent"].number ?? 0, 0.65, accuracy: 0.0001)
        XCTAssertEqual(reading["model"].string, "claude-opus-5-5")
        XCTAssertEqual(reading["source"]["sessionId"].string, "cli-session")
        XCTAssertEqual(reading["observedAt"].number, 5_000)
        try await wait { await moves.ids.contains("hoot") }

        let plan = try await usage.reading(id: "hoot", want: "plan")
        XCTAssertEqual(plan["sessionId"].string, "hoot")
        XCTAssertEqual(plan["account"]["id"].string, "profile-hoot")
        XCTAssertEqual(plan["readings"].elements?.count, 1, "never another account's limits")
        XCTAssertEqual(plan["readings"].elements?.first?["used"]["fraction"].number ?? 0, 0.4, accuracy: 0.0001)
        let refresh = try await usage.reading(id: "hoot", want: "refresh", force: true)
        XCTAssertEqual(refresh["ok"].bool, true)
        XCTAssertEqual(refresh["spawned"].bool, false)
        XCTAssertEqual(refresh["report"]["readings"].elements?.count, 1)

        await store.stop()
        // After a restart the same conversation still has its figure; another conversation never borrows it.
        let reloaded = try BackendHootChatStore(file: file)
        let kept = await reloaded.contextFacts()
        XCTAssertEqual(kept.tokens, 6_500)
        XCTAssertEqual(kept.conversation, "cli-session")
        try await reloaded.requireContext("claude/profile-other")
        let switched = await reloaded.contextFacts()
        XCTAssertNil(switched.tokens, "an account change starts another conversation: the old figure is not shown")
        let unknown = try await usage.reading(id: "hoot:task:none", want: "context")
        XCTAssertEqual(unknown["state"].string, "not-reported")
    }

    /// Post-24 relay half: `hoot` / `hoot:task:<id>` usage requests reach Hoot's reader (no session gate), its pushes
    /// read the same, and a refresh tap starts the account check (refreshAccount) before re-reading the plan.
    func testRelayRoutesHootIdsAndARefreshStartsTheAccountCheck() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        try await store.requireContext("claude/profile-hoot")
        let usage = BackendHootUsage(now: { 5_000 })
        await usage.track(BackendHootUsage.chatID, chat: store) { Self.hoot }
        await usage.bindPlans { .init(sessionID: nil, account: nil, readings: [Self.weekly(Self.hoot, 40)], reason: nil, assembledAt: 1) }
        actor Checks { var accounts: [String] = []; func add(_ a: BackendUsageAccount) { accounts.append(a.key) } }
        let checks = Checks()
        await usage.bindCheck { await checks.add($0); return "Claude Code recorded this login's limits less than an hour ago; that figure is shown." }
        let serve = BackendRemoteServeUsageService(plan: { _ in .null }, refresh: { _, _ in .null }, context: { _, _ in .null }, hoot: { usage })
        let caller = NativeRPCContext(caller: .pairedDevice, ownerID: "phone")
        let pushed = try await serve.pushedContext(sessionID: "hoot", caller: caller)
        let direct = await usage.context(id: "hoot")
        XCTAssertEqual(pushed["state"].string, direct["state"].string, "a push reads Hoot's own context")
        let task = try await serve.pushedContext(sessionID: "hoot:task:42", caller: caller)
        XCTAssertEqual(task["detail"].string, "That Hoot task is not running now, so it has no context reading.")
        _ = try await usage.reading(id: "hoot", want: "refresh")
        let checked = await checks.accounts
        XCTAssertEqual(checked, [Self.hoot.key], "the refresh tap starts Claude's usage check for Hoot's account")
        _ = try await usage.reading(id: "hoot", want: "plan")
        let afterPlan = await checks.accounts
        XCTAssertEqual(afterPlan.count, 1, "reading the plan never starts a check")
        // #26: the Mac's Limits tab ("Read limits", hoot:usage:refresh) shares the same check and says what it did.
        let limits = try await usage.refreshPlan(id: "hoot")
        let afterLimits = await checks.accounts
        XCTAssertEqual(afterLimits.count, 2, "Read limits starts the same account check")
        XCTAssertEqual(limits.detail, "Claude Code recorded this login's limits less than an hour ago; that figure is shown.")
        XCTAssertEqual(limits.report.readings.count, 1)
        XCTAssertTrue(BackendHootUsage.owns("hoot")); XCTAssertTrue(BackendHootUsage.owns("hoot:task:1")); XCTAssertFalse(BackendHootUsage.owns("hoot:task:"))
    }

    /// Post-24: the account check runs when nothing is recorded or the record is at least an hour old.
    func testTheAccountCheckIsDueAfterAnHour() {
        XCTAssertTrue(BackendUsageService.accountCheckDue(newest: 0, now: 10_000_000, maxAge: 3_600_000))
        XCTAssertFalse(BackendUsageService.accountCheckDue(newest: 9_000_000, now: 10_000_000, maxAge: 3_600_000))
        XCTAssertTrue(BackendUsageService.accountCheckDue(newest: 6_400_000, now: 10_000_000, maxAge: 3_600_000))
    }

    func testContextReadingPerProvider() {
        let claudeNoWindow = BackendHootUsage.contextReading(.init(provider: "claude", model: "claude-opus-5-5", tokens: 50_000, alive: true), now: 1)
        XCTAssertEqual(claudeNoWindow["state"].string, "ok")
        XCTAssertEqual(claudeNoWindow["window"].number, 1_000_000, "before Claude's first result: the model's known window")
        XCTAssertEqual(claudeNoWindow["windowBasis"].string, "model")
        let codex = BackendHootUsage.contextReading(.init(provider: "codex", model: "gpt-6.1", tokens: 12_000, window: 272_000, alive: true), now: 1)
        XCTAssertEqual(codex["windowBasis"].string, "reported")
        XCTAssertEqual(codex["percent"].number ?? 0, 12_000.0 / 272_000 * 100, accuracy: 0.0001)
        let codexNoWindow = BackendHootUsage.contextReading(.init(provider: "codex", tokens: 12_000, alive: true), now: 1)
        XCTAssertEqual(codexNoWindow["state"].string, "ok")
        XCTAssertTrue(codexNoWindow["window"].isNullish, "Codex's window is never guessed")
        XCTAssertTrue(codexNoWindow["percent"].isNullish)
        let gemini = BackendHootUsage.contextReading(.init(provider: "gemini", tokens: 9, alive: true), now: 1)
        XCTAssertEqual(gemini["state"].string, "not-reported")
        XCTAssertTrue(gemini["tokens"].isNullish)
        XCTAssertTrue(gemini["detail"].string?.contains("Gemini") == true)
        let resting = BackendHootUsage.contextReading(.init(provider: "claude", alive: false), now: 1)
        XCTAssertEqual(resting["state"].string, "nothing-yet")
        for key in ["provider", "state", "tokens", "window", "percent", "windowBasis", "model", "modelLabel", "source", "reportedAt", "observedAt", "detail"] {
            XCTAssertTrue(codex.has(key), "same fields as a session's context reading: \(key)")
            XCTAssertTrue(gemini.has(key), "same fields as a session's context reading: \(key)")
        }
    }

    func testPlanReportSaysWhatEachAccountKindCannotReport() {
        let all = BackendUsageReport(sessionID: nil, account: nil, readings: [Self.weekly(Self.other, 70)], reason: nil, assembledAt: 1)
        let none = BackendHootUsage.planReport(all: all, account: Self.hoot, id: "hoot", now: 2)
        XCTAssertTrue(none.readings.isEmpty)
        XCTAssertNotNil(none.reason)
        let api = BackendHootUsage.planReport(all: all, account: .init(provider: "claude", id: "api-key-0123456789abcdef01234567", name: "API", configDirectory: nil), id: "hoot", now: 2)
        XCTAssertTrue(api.reason?.contains("API billing") == true)
        let gemini = BackendHootUsage.planReport(all: all, account: .init(provider: "gemini", id: "g", name: "G", configDirectory: nil), id: "hoot", now: 2)
        XCTAssertTrue(gemini.reason?.contains("Gemini") == true)
        XCTAssertTrue(BackendHootUsage.owns("hoot"))
        XCTAssertTrue(BackendHootUsage.owns("hoot:task:t-1"))
        XCTAssertFalse(BackendHootUsage.owns("hoot:task:"))
        XCTAssertFalse(BackendHootUsage.owns("session-1"))
    }
}
