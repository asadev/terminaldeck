import XCTest
@testable import TerminalDeckNativeCore

final class AWAgentsWatchTests: XCTestCase {
    private func object(_ json: String) throws -> NativeRPCValue { try .parseJSON(Data(json.utf8)) }
    func testRemoteIdentityNeverCollidesWithLocalOrAnotherMachine() {
        let ids = ["", "remote-a", "remote-b"].map { AWWatchAgent.identity(machine: $0, kind: "session", source: "same-id") }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertNotEqual(AWWatchAgent.identity(machine: "a", kind: "b:c", source: "d"), AWWatchAgent.identity(machine: "a:b", kind: "c", source: "d"))
    }
    func testTaskSessionMergedHootNotDoubleCountedAndShellExcluded() throws {
        let sessions = try object(#"[{"id":"one","provider":"claude","attention":"working","cwd":"/project","statusSince":50},{"id":"hoot-id","provider":"claude","attention":"idle"},{"id":"shell","provider":"shell"}]"#).elements!
        let tasks = try object(#"[{"id":"local:t","sessionId":"one","agent":"Builder","title":"Fix the build","process":"working"}]"#).elements!
        let rows = AWWatchProjection.inventory(sessions: sessions, tasks: tasks, hoot: try object(#"{"sessionId":"hoot-id"}"#))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.name, "Builder")
        XCTAssertEqual(rows.first?.taskID, "local:t")
        XCTAssertEqual(rows.last?.kind, "hoot")
        XCTAssertEqual(rows.first?.since, 50)
    }
    func testUnknownStateDoesNotClaimWorkAndDisconnectedNeverLooksIdle() throws {
        let session = try object(#"{"id":"one","provider":"codex"}"#)
        XCTAssertEqual(AWWatchProjection.inventory(sessions: [session], tasks: []).first?.state, .unknown)
        XCTAssertEqual(AWWatchProjection.inventory(sessions: [session], tasks: [], connected: false).first?.state, .offline)
        XCTAssertEqual(AWWatchState.observed("queued"), .queued)
        XCTAssertEqual(AWWatchState.observed("input"), .waiting)
    }
    func testPeopleAreNotAgentsAndDoNotRenameARealSession() throws {
        let sessions = try object(#"[{"id":"one","title":"Claude session","provider":"claude","attention":"working"}]"#).elements!
        let tasks = try object(#"[{"id":"local:me","assignee":"me","agent":"Me","sessionId":"one","process":"idle"},{"id":"local:person","assignee":{"kind":"human","agentId":"person-2"},"agent":"Person"},{"id":"local:bot","assignee":"builder","agent":"Builder","process":"working"}]"#).elements!
        let rows = AWWatchProjection.inventory(sessions: sessions, tasks: tasks)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.sessionID == "one" })?.name, "Claude session")
        XCTAssertEqual(rows.filter { $0.kind == "task" }.map(\.name), ["Builder"])
    }
    func testFiltersMatchCountAndMachineProjectScope() throws {
        let sessions = try object(#"[{"id":"a","provider":"claude","attention":"working","cwd":"/one"},{"id":"b","provider":"gemini","attention":"input","cwd":"/two"}]"#).elements!
        let rows = AWWatchProjection.inventory(sessions: sessions, tasks: [], machineID: "mac")
        XCTAssertEqual(AWWatchProjection.filtered(rows, state: "working", project: "/one", machine: "mac").count, 1)
        XCTAssertEqual(AWWatchProjection.filtered(rows, project: "/two", query: "gemini").count, 1)
        XCTAssertEqual(AWWatchProjection.filtered(rows, machine: "elsewhere").count, 0)
    }
    func testCursorResetsWhenHistoryRotatesAndBoundsResponse() {
        let entries = (0..<300).map { AWWatchEntry(id: "\($0)", kind: .message, speaker: "Agent", title: "", text: String(repeating: "💬", count: 8000), at: Double($0)) }
        let initial = AWWatchProjection.page(entries, after: nil, limit: 200)
        XCTAssertLessThanOrEqual(initial["entries"].elements!.count, 200)
        XCTAssertLessThan(initial.compact.utf8.count, 132 * 1024)
        let missing = AWWatchProjection.page(entries, after: "old", limit: 2)
        XCTAssertEqual(missing["reset"].bool, true)
        let next = AWWatchProjection.page(entries, after: "295", limit: 2)
        XCTAssertEqual(next["entries"].elements?.first?["id"].string, "296")
        XCTAssertEqual(next["hasMore"].bool, true)
    }
    func testStreamingChangeBeforeCursorResetsButAppendDoesNot() {
        let first = AWWatchEntry(id: "message", kind: .message, speaker: "Hoot", title: "", text: "Hello", at: 1)
        let cursor = AWWatchProjection.page([first], after: nil, limit: 100)["cursor"].string!
        let updated = AWWatchEntry(id: "message", kind: .message, speaker: "Hoot", title: "", text: "Hello there", at: 1)
        XCTAssertEqual(AWWatchProjection.page([updated], after: cursor, limit: 100)["reset"].bool, true)
        let next = AWWatchEntry(id: "next", kind: .message, speaker: "Hoot", title: "", text: "Next", at: 2)
        let appended = AWWatchProjection.page([first, next], after: cursor, limit: 100)
        XCTAssertEqual(appended["reset"].bool, false)
        XCTAssertEqual(appended["entries"].elements?.first?["id"].string, "next")
    }
}
