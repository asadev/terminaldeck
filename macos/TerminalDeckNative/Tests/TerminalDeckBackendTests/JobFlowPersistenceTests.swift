import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class JobFlowPersistenceTests: XCTestCase, @unchecked Sendable {
    func testFullLogAppendsUntilCompactionAndReloadKeepsLatestWindow() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/part53-test-scratch/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("flow.jsonl")
        let original = (0..<BackendJobFlowLog.limit).map {
            JobFlowEntry(id: "r\($0)", at: Double($0), session: "session", who: "Worker", seat: "Hoot", kind: .rule, title: "Rule")
        }
        let encoder = JSONEncoder()
        let lines = try original.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: file)
        let log = BackendJobFlowLog()
        await log.configure(file: file)
        for index in 0...BackendJobFlowLog.limit {
            await log.record(JobFlowEntry(id: "new\(index)", at: 3000 + Double(index), session: "session", who: "Worker", seat: "Hoot", kind: .rule, title: "Rule"))
            if index == 0 {
                let appended = try Data(contentsOf: file)
                XCTAssertTrue(appended.starts(with: Data(lines.utf8)))
                XCTAssertEqual(String(decoding: appended, as: UTF8.self).split(separator: "\n").count, BackendJobFlowLog.limit + 1)
            }
        }
        let compacted = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(compacted.count, BackendJobFlowLog.limit)
        let reloaded = BackendJobFlowLog()
        await reloaded.configure(file: file)
        let entries = await reloaded.all()
        XCTAssertEqual(entries.first?.id, "new1")
        XCTAssertEqual(entries.last?.id, "new2000")
    }

    func testTaskLinksFollowCurrentTasksAndEndedSessions() async {
        let log = BackendJobFlowLog()
        let task = NativeRPCValue.object([.init("sessionId", .string("session")), .init("id", .string("task"))])
        await log.noteTasks([task])
        let known = await log.task(forSession: "session")
        XCTAssertEqual(known?.task, "task")
        await log.sessionEnded("session")
        let ended = await log.task(forSession: "session")
        XCTAssertNil(ended)
        await log.noteTasks([task], activeSessions: [])
        let stale = await log.task(forSession: "session")
        XCTAssertNil(stale)
        await log.noteTasks([task])
        await log.noteTasks([])
        let removed = await log.task(forSession: "session")
        XCTAssertNil(removed)
    }
}
