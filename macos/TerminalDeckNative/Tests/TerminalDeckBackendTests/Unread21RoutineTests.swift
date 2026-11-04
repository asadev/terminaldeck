import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Unread21RoutineTests: XCTestCase, @unchecked Sendable {
    func testRoutineReadKeepsHistoryWithoutUnreadStateOrMarkerWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unread21-routine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows: [NativeRPCValue] = [("r1", "report"), ("q1", "question"), ("a1", "answer")].map { id, kind in
            .object([.init("id", .string(id)), .init("kind", .string(kind)), .init("text", .string("Words")), .init("at", .number(1000))])
        }
        try NativeRPCValue.array(rows).encodedJSON().write(to: directory.appendingPathComponent("daily-reports.json"))
        let delivery = BackendRoutines21Delivery(secrets: BackendConnectedTasksMemorySecrets())
        let reports = BackendRoutines21Reports(directory: directory, delivery: delivery)
        let routine = BackendRoutinesRoutine(id: "daily", name: "Daily", triggers: [.manual], folder: "/tmp", prompt: "Read changes")
        let initial = try await reports.invoke("routines:reports-chat", arguments: [.string("daily")], routine: routine)
        XCTAssertEqual(initial["unread"]["count"].number, 0)
        XCTAssertEqual(initial["unread"]["firstMessageId"], .null)
        let entries = try XCTUnwrap(initial["entries"].elements)
        XCTAssertEqual(entries[2]["sequence"].number, 3)
        _ = try await reports.invoke("routines:reports-chat", arguments: [.string("daily"), .number(1)], routine: routine)
        let restored = BackendRoutines21Reports(directory: directory, delivery: delivery)
        let reopened = try await restored.readChat("daily")
        XCTAssertEqual(reopened["unread"]["seenSequence"].number, 3)
        XCTAssertEqual(reopened["unread"]["firstMessageId"], .null)
        XCTAssertEqual(reopened["unread"]["count"].number, 0)
        _ = try await restored.readChat("daily", seen: 3)
        let otherWindow = try await reports.readChat("daily")
        XCTAssertEqual(otherWindow["unread"]["count"].number, 0)
        do { _ = try await reports.readChat("daily", seen: 4); XCTFail("Future marker was accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report-chat-seen.json").path))
        let older = try await reports.readChat("daily", seen: 1)
        XCTAssertEqual(older["unread"]["seenSequence"].number, 3)
    }
}
