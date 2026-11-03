import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class WidgetSnapshotTests: XCTestCase {
    func testEmptyIsUnknownNeverZero() {
        let value = DeckWidgetSnapshot.empty
        XCTAssertNil(value.needsYouCount); XCTAssertNil(value.tasksDueCount)
        XCTAssertNil(value.cpuPercent); XCTAssertNil(value.memoryPercent); XCTAssertNil(value.weeklyLimitRemainingPercent)
        XCTAssertTrue(value.isStale()); XCTAssertNil(value.asOf)
    }
    func testFreshnessBoundaryAndDisconnectPreserveTimestamp() {
        let value = DeckWidgetSnapshot(updatedAt: 1_000_000, connected: true)
        XCTAssertFalse(value.isStale(at: Date(timeIntervalSince1970: 1899)))
        XCTAssertTrue(value.isStale(at: Date(timeIntervalSince1970: 1900)))
        var disconnected = value; disconnected.connected = false
        XCTAssertTrue(disconnected.isStale(at: Date(timeIntervalSince1970: 1001)))
        XCTAssertEqual(disconnected.updatedAt, value.updatedAt)
    }
    func testRoundtripAndThreeNamesFullCount() throws {
        let value = DeckWidgetSnapshot(updatedAt: 1000, connected: true, needsYouCount: 5,
            needsYou: (0..<5).map { .init(id: "id-\($0)", name: "Session", agent: "Codex") }, cpuPercent: 0, memoryPercent: 100)
        let decoded = try DeckWidgetSnapshot.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded.needsYou.count, 3); XCTAssertEqual(decoded.needsYouCount, 5)
        XCTAssertEqual(decoded.cpuPercent, 0); XCTAssertEqual(decoded.memoryPercent, 100)
    }
    func testInvalidWirePercentVersionAndCountRefused() throws {
        for patch in ["\"v\":2", "\"cpuPercent\":101", "\"tasksDueCount\":-1", "\"needsYouCount\":-1"] {
            let base = #"{"updatedAt":1000,"connected":true,"needsYou":[],"v":1}"#
            let json = patch.hasPrefix("\"v\"") ? base.replacingOccurrences(of: "\"v\":1", with: patch) : String(base.dropLast()) + "," + patch + "}"
            XCTAssertThrowsError(try DeckWidgetSnapshot.decode(Data(json.utf8)))
        }
    }
    func testOutOfRangeInputsBecomeUnknown() {
        let value = DeckWidgetSnapshot(cpuPercent: -1, memoryPercent: .infinity, weeklyLimitRemainingPercent: 101)
        XCTAssertNil(value.cpuPercent); XCTAssertNil(value.memoryPercent); XCTAssertNil(value.weeklyLimitRemainingPercent)
    }
    func testAtomicSharedFileAndCorruptFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.json")
        let value = DeckWidgetSnapshot(updatedAt: 2000, connected: true, machineId: "test", tasksDueCount: 0)
        try DeckWidgetStore.write(value, url: file); XCTAssertEqual(DeckWidgetStore.read(url: file), value)
        try Data("bad json".utf8).write(to: file); XCTAssertEqual(DeckWidgetStore.read(url: file), .empty)
    }
    func testTasksWidgetDestinationUsesMatchingDueFilter() {
        let tasks: [TaskRow] = [
            .init(id: "past", crmStatus: "To-Do", dueDate: "2025-01-01"),
            .init(id: "today", crmStatus: "To-Do", dueDate: "2026-01-10"),
            .init(id: "future", crmStatus: "To-Do", dueDate: "2026-01-11"),
            .init(id: "done", crmStatus: "Done", dueDate: "2025-01-01"),
            .init(id: "marked", crmStatus: "To-Do", dueDate: "2025-01-01", completedAt: 10),
            .init(id: "cancelled", crmStatus: "Cancelled", dueDate: "2025-01-01"),
            .init(id: "bad", crmStatus: "To-Do", dueDate: "2025-02-31")
        ]
        var filters = ListFilters(); filters.due = .throughToday
        XCTAssertEqual(TaskList.filter(tasks, filters, today: "2026-01-10", nowHm: nil).map(\.id), ["past", "today"])
        XCTAssertEqual(filters.due.label, "Overdue and today")
    }
    func testSessionURLRetainsSingleComponentAndMachine() throws {
        let value = DeckWidgetSnapshot(machineId: "host&a")
        let url = value.url(session: "s/a?x%#")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "session"); XCTAssertEqual(parts.percentEncodedPath, "/s%2Fa%3Fx%25%23")
        XCTAssertEqual(parts.queryItems?.first?.value, "host&a")
    }
    func testNeedsYouChangeRedrawsInsideTheBudgetAndCPUOnlyDoesNot() {
        var gate = DeckWidgetReloadGate(), now = Date(timeIntervalSince1970: 0)
        let first = DeckWidgetSnapshot(updatedAt: 1, connected: true, machineId: "mac", needsYouCount: 1,
                                       needsYou: [.init(id: "a", name: "A", agent: "Codex")], cpuPercent: 10)
        XCTAssertEqual(gate.decide(first, now: now), 0)
        now += 120; var cpu = first; cpu.cpuPercent = 90; cpu.memoryPercent = 50
        XCTAssertNil(gate.decide(cpu, now: now), "CPU/memory-only changes wait for the 15-minute budget")
        now += 10; var waiting = cpu; waiting.needsYouCount = 2
        XCTAssertEqual(gate.decide(waiting, now: now), 0, "A new session waiting for you redraws at once")
        now += 10; var task = waiting; task.tasksDueCount = 3
        XCTAssertEqual(gate.decide(task, now: now), 50, "Inside the minute one coalesced redraw follows")
        gate.reloaded(task, now: now + 50)
        XCTAssertNil(gate.decide(task, now: now + 60))
        XCTAssertEqual(gate.decide(task, now: now + 50 + 15 * 60), 0, "Idle load still refreshes every 15 minutes")
    }
}
