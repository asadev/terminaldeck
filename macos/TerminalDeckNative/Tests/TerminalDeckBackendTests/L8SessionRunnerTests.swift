import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real app, 11 Oct (row "Memory tools from an agent's own session"): a session's client can only call the
/// tools in its list, and most of a session's grant is held behind tools_describe. Without the runner the
/// agent could read the index and call none of it. The runner is plumbing: what it runs is still checked
/// against the session's own grant (BackendDeckCoreSecurityServer / Control, covered by their own suites).
final class L8SessionRunnerTests: XCTestCase {
    private func listing(granted: Set<String>) throws -> [String: String] {
        // The built-in tools, describe + run, and one HELD memory tool of the kind a session is granted.
        let held = BackendDeckCoreCatalogueMetadata(tool: try BackendMCPTool(id: "memory.note.add", wireName: "memory_note_add", description: "Add a memory note",
            inputSchema: .object([.init("type", .string("object"))]), tier: .act), title: "Add a memory note", index: "Write one short note into your seat's memory")
        let metadata = try BackendDeckCoreCatalogueLiterals.builtins().filter { $0.tool.id != held.tool.id }
            + BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata + [held]
        let session = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act, .alter])
        var rows: [String: String] = [:]
        for row in try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: session, granted: granted) {
            rows[try XCTUnwrap(row["name"].string)] = row["description"].string ?? ""
        }
        return rows
    }

    func testASessionsGrantHoldsTheRunnerBesideDescribeAndEveryMemoryTool() {
        let ordinary = BackendTAGToolPolicy.sessionNames(taskID: nil), task = BackendTAGToolPolicy.sessionNames(taskID: "local:worker")
        for names in [ordinary, task] {
            XCTAssertTrue(names.isSuperset(of: ["tools.run", "tools_run", "tools.describe", "tools_describe", "memory.search"]))
            XCTAssertTrue(names.isSuperset(of: DeckMemoryTools.sessionToolNames))
        }
        XCTAssertTrue(task.contains("tasks.comment"))
        // The runner widens nothing by itself: no session is granted a tool that starts or stops sessions.
        XCTAssertFalse(task.contains("sessions.start") || task.contains("sessions.stop"))
    }

    func testASessionIsShownTheRunnerAndToldToUseIt() throws {
        let rows = try listing(granted: BackendTAGToolPolicy.sessionNames(taskID: "local:worker"))
        XCTAssertNotNil(rows["tools_run"], "a session must be able to call what tools_describe names: \(rows.keys.sorted())")
        XCTAssertTrue(try XCTUnwrap(rows["tools_describe"]).contains("call these through tools_run"))
        XCTAssertTrue(try XCTUnwrap(rows["tools_describe"]).contains("memory_note_add"))
        XCTAssertNil(rows["memory_note_add"], "held tools stay behind the index; they are reached through the runner")
        XCTAssertTrue(BackendDeckCoreCatalogueDescribe.needsRunner(.init(kind: .session, tiers: [.read])))
    }

    func testASessionWhoseGrantHasNoRunnerIsNotShownOne() throws {
        let narrowed = BackendTAGToolPolicy.sessionNames(taskID: nil).subtracting(["tools.run", "tools_run"])
        XCTAssertNil(try listing(granted: narrowed)["tools_run"])
    }
}
