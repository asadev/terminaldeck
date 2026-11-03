import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesLogTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRoutinesLog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testRoutineRowsUseSharedActionPathAndISOString() throws {
        let root = try scratch(), sink = BackendRoutinesActionLog(userData: root, now: { Date(timeIntervalSince1970: 0) })
        sink.logger(.init(action: "routine.run", routine: "overnight", runID: "r1", outcome: "started", detail: "Started."))
        XCTAssertEqual(sink.actions.path, root.appendingPathComponent("hoot-log/actions.jsonl").path)
        let bytes = try Data(contentsOf: sink.actions), row = try NativeRPCValue.parseJSON(bytes)
        XCTAssertEqual(row["at"].string, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(row["runId"].string, "r1")
        XCTAssertEqual(row["outcome"].string, "started")
        XCTAssertEqual(row["routine"].string, "overnight")
        XCTAssertFalse(row.has("data"))
        XCTAssertNil(sink.lastError)
    }
    func testFourMegabyteRotationKeepsExactlyOneGeneration() throws {
        let root = try scratch(), sink = BackendRoutinesActionLog(userData: root)
        try FileManager.default.createDirectory(at: sink.directory, withIntermediateDirectories: true)
        let old = Data(repeating: 120, count: BackendRoutinesActionLog.limitBytes)
        try old.write(to: sink.actions)
        try Data("discarded old generation".utf8).write(to: URL(fileURLWithPath: sink.actions.path + ".1"))
        sink.logger(.init(action: "routine.run", routine: "one", outcome: "ok"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sink.actions.path + ".1")), old)
        XCTAssertEqual(try NativeRPCValue.parseJSON(Data(contentsOf: sink.actions))["routine"].string, "one")
        XCTAssertNil(sink.lastError)
    }
    func testUnwritablePathDoesNotThrowAndReportsFailure() throws {
        let root = try scratch()
        try Data("file prevents directory creation".utf8).write(to: root.appendingPathComponent("hoot-log"))
        let sink = BackendRoutinesActionLog(userData: root)
        sink.logger(.init(action: "routine.skip", routine: "one", outcome: "refused"))
        XCTAssertNotNil(sink.lastError)
    }
    func testRunnerReportCanUseExactCopilotColumns() throws {
        let root = try scratch(), sink = BackendRoutinesActionLog(userData: root)
        sink.appendRoutineAction(.object([.init("action", .string("routine.report")), .init("detail", .string("Finding")), .init("sessionId", .string("r1"))]))
        let row = try NativeRPCValue.parseJSON(Data(contentsOf: sink.actions))
        XCTAssertEqual(row["sessionId"].string, "r1")
        XCTAssertFalse(row.has("outcome"))
    }
}
