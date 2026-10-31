import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTRunHistoryTests: XCTestCase, @unchecked Sendable {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func at(_ year: Int, _ month: Int, _ day: Int) -> Double {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970 * 1_000
    }
    private func run(start: Double) -> NativeRPCValue {
        let session = BackendSessionMeta(id: "owned-session", input: .init(cwd: "/scratch", provider: "codex"),
            spawn: .init(provider: "codex", command: "/stub", args: [], path: "/stub", profile: .init(id: "account", name: "Account"), agentSessionId: "exact-conversation"))
        return BackendAGOPTRunHistory.start(id: "actual-run", agentID: "agent", taskID: "local:task", session: session,
            accountID: "account", at: start, requestedModel: nil, requestedEffort: nil)
    }
    func testCrossMonthUsageCountsOnlyMeasuredCurrentMonthAndPlanHasNoMoney() throws {
        var value = run(start: at(2026, 9, 30))
        value = try BackendAGOPTRunHistory.addUsage(value, tokens: 100, reportedAPIUSD: nil, billingKind: "subscription", source: "owned-record", at: at(2026, 9, 30), calendar: calendar)
        value = try BackendAGOPTRunHistory.addUsage(value, tokens: 20, reportedAPIUSD: nil, billingKind: "subscription", source: "owned-record", at: at(2026, 10, 1), calendar: calendar)
        value = try BackendAGOPTRunHistory.finish(value, outcome: "completed", at: at(2026, 10, 1), summary: "Finished", verified: true)
        let month = try BackendAGOPTRunHistory.month(profileID: "agent", runs: [value], compacted: .object([]), calendar: calendar, now: at(2026, 10, 10), trackedSince: at(2026, 9, 1))
        XCTAssertEqual(month["tokens"].number, 20); XCTAssertTrue(month["cost_usd"].isNullish)
        XCTAssertThrowsError(try BackendAGOPTRunHistory.addUsage(value, tokens: nil, reportedAPIUSD: 1, billingKind: "subscription", source: "report", at: at(2026, 10, 1), calendar: calendar))
    }
    func testReportedAPIMoneySurvivesCompactionWithoutDoubleCharge() throws {
        var value = run(start: at(2026, 10, 3))
        value = try BackendAGOPTRunHistory.addUsage(value, tokens: 75, reportedAPIUSD: 0.75, billingKind: "api", source: "verified-cli-total_cost_usd", at: at(2026, 10, 3), calendar: calendar)
        value = try BackendAGOPTRunHistory.finish(value, outcome: "completed", at: at(2026, 10, 3), summary: "Finished", verified: true)
        let detailed = try BackendAGOPTRunHistory.month(profileID: "agent", runs: [value], compacted: .object([]), calendar: calendar, now: at(2026, 10, 10), trackedSince: at(2026, 10, 1))
        let rollup = try BackendAGOPTRunHistory.compact(value, into: .object([]), calendar: calendar)
        let compacted = try BackendAGOPTRunHistory.month(profileID: "agent", runs: [], compacted: rollup, calendar: calendar, now: at(2026, 10, 10), trackedSince: at(2026, 10, 1))
        XCTAssertEqual(detailed["tokens"], compacted["tokens"]); XCTAssertEqual(compacted["tokens"].number, 75)
        XCTAssertEqual(detailed["cost_usd"], compacted["cost_usd"]); XCTAssertEqual(compacted["cost_usd"].number, 0.75)
    }
    func testUnreportedAPICostIsUnavailableAndNeverZero() throws {
        var value = run(start: at(2026, 10, 3))
        value = try BackendAGOPTRunHistory.addUsage(value, tokens: 50, reportedAPIUSD: nil, billingKind: "api", source: nil, at: at(2026, 10, 3), calendar: calendar)
        value = try BackendAGOPTRunHistory.finish(value, outcome: "completed", at: at(2026, 10, 3), summary: "No cost report", verified: false)
        let month = try BackendAGOPTRunHistory.month(profileID: "agent", runs: [value], compacted: .object([]), calendar: calendar, now: at(2026, 10, 10), trackedSince: at(2026, 10, 1))
        XCTAssertEqual(month["tokens"].number, 50); XCTAssertTrue(month["cost_usd"].isNullish)
        XCTAssertEqual(month["cost_coverage"].string, "unavailable-or-partial")
    }
    func testPrunedCurrentMonthTotalsAndCountersSurviveActualStoreRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive)
        let now = at(2026, 10, 10)
        var rows: [NativeRPCValue] = []
        for index in 0..<1_001 {
            var value = run(start: now).setting("id", .string("actual-run-\(index)"))
            value = try BackendAGOPTRunHistory.addUsage(value, tokens: 1, reportedAPIUSD: nil,
                billingKind: "subscription", source: "owned-record", at: now, calendar: calendar)
            rows.append(try BackendAGOPTRunHistory.finish(value, outcome: "completed", at: now, summary: nil, verified: true))
        }
        try persistence.write("tasks.json", value: .object([.init("v", .number(1)), .init("tasks", .array([])),
            .init("agentRuns", .array(rows)), .init("agentHistorySince", .number(at(2026, 10, 1)))]))
        let original = BackendTaskStore(persistence: persistence); try await original.start(); await original.setRunCalendar(calendar)
        try await original.putAgentRun(rows[0].setting("id", .string("actual-new-run")))
        let restarted = BackendTaskStore(persistence: persistence); try await restarted.start(); await restarted.setRunCalendar(calendar)
        let details = try await restarted.agentRuns("agent", now: now), month = try await restarted.agentMonth("agent", now: now)
        let window = try await restarted.agentWindow("agent", days: 14, now: now)
        XCTAssertEqual(details.count, 1_000); XCTAssertEqual(month["tokens"].number, 1_002)
        XCTAssertEqual(window["runs"].number, 1_002)
    }
    func testConversationOnlyReportedRunSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-cli-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try BackendTaskPersistence(directory: directory, ownership: .exclusive)
        let original = BackendTaskStore(persistence: persistence); try await original.start()
        let value = run(start: at(2026, 10, 10)).setting("session_id", .null)
        try await original.putAgentRun(value)
        let restarted = BackendTaskStore(persistence: persistence); try await restarted.start()
        let saved = try await restarted.agentRun("actual-run")
        XCTAssertEqual(saved?["conversation_id"].string, "exact-conversation"); XCTAssertTrue(saved?["session_id"].isNullish == true)
    }
}
