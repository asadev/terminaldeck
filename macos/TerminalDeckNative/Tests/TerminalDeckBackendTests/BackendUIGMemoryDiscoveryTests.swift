import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendUIGMemoryDiscoveryTests: XCTestCase {
    private func row(_ id: String, aliases: [String] = [], index: String? = nil,
                     audience: String? = nil) throws -> BackendDeckCoreCatalogueMetadata {
        .init(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
            description: "Description for \(id)", inputSchema: .object([]), tier: .read),
            title: id, aliases: aliases, index: index, audience: audience)
    }

    func testInlineListingCannotRevealMemoryThroughDescribeIndex() throws {
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] })
        // The paused Memory page's own tools (memory.read, memory.graph) stay out of every listing.
        let memory = try row("memory.read", aliases: ["remember"], index: "Read memory notes")
        let knowledge = try row("knowledge.search", index: "Search knowledge")
        let rows = [memory, knowledge] + describe.metadata
        let listed = try BackendUIGMemoryDiscovery.wireListing(metadata: rows, caller: .local, granted: nil)
        let text = NativeRPCValue.array(listed).compact
        XCTAssertTrue(text.contains("knowledge_search"))
        XCTAssertFalse(text.contains("memory_read"))
        XCTAssertFalse(text.contains("Read memory notes"))
        XCTAssertEqual(rows.count, 4, "The registered source metadata is retained.")
    }

    /// Deck Memory (11 Oct 2026): its own tools are part of the product and are listed, memory.search among them
    /// (it searches Deck Memory too now), while the paused page's tools stay hidden beside them.
    func testDeckMemoryToolsAreListedWhileThePausedPagesToolsStayHidden() throws {
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] })
        let rows = try [row("memory.search", index: "Search memory"), row("memory.note.add", index: "Add a memory note"),
                        row("memory.board.read", index: "Read the board"), row("playbook.update", index: "Change the playbook"),
                        row("memory.read", index: "Read memory notes"), row("memory.graph", index: "Memory graph")] + describe.metadata
        let listed = try BackendUIGMemoryDiscovery.wireListing(metadata: rows, caller: .local, granted: nil)
        let text = NativeRPCValue.array(listed).compact
        for name in ["memory_search", "memory_note_add", "memory_board_read", "playbook_update"] { XCTAssertTrue(text.contains(name), name) }
        for name in ["memory_read", "memory_graph", "Read memory notes", "Memory graph"] { XCTAssertFalse(text.contains(name), name) }
        for id in DeckMemoryTools.toolIDs + ["memory.search"] {
            XCTAssertTrue(UIGMemoryVisibility.showsTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_")), id)
        }
    }

    func testAreaIndexAndDirectAliasDescribeBothHideMemory() throws {
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] })
        let memory = try row("memory.read", aliases: ["read_notes"], index: "Read memory")
        let others = try (0...BackendDeckCoreCatalogueDescribe.inlineIndexMax).map {
            try row("sessions.example\($0)", index: "Read example \($0)")
        }
        let rows = [memory] + others + describe.metadata
        let listed = try BackendUIGMemoryDiscovery.wireListing(metadata: rows, caller: .local, granted: nil)
        let description = listed.first { $0["name"].string == "tools_describe" }?["description"].string ?? ""
        XCTAssertTrue(description.contains("sessions —"))
        XCTAssertFalse(description.contains("memory —"))
        for name in ["memory.read", "memory_read", "read_notes"] {
            let output = try BackendUIGMemoryDiscovery.describe(.object([.init("tools", .array([.string(name)]))]),
                catalogue: rows, granted: nil, caller: .local)
            XCTAssertEqual(output.value["tools"].elements?.count, 0)
            XCTAssertEqual(output.value["unknown"].elements, [.string("no tool called \(name)")])
        }
        let output = try BackendUIGMemoryDiscovery.describe(.object([.init("area", .string("memory"))]),
            catalogue: rows, granted: nil, caller: .local)
        XCTAssertEqual(output.value["unknown"].elements, [.string("no area called memory")])
    }

    func testExistingGrantAndAudienceRulesRemainInForce() throws {
        let rows = try [row("memory.read", index: "Read memory notes"), row("knowledge.search"),
            row("sessions.secret", audience: "keys")]
        let listing = try BackendUIGMemoryDiscovery.wireListing(metadata: rows, caller: .local,
            granted: ["memory_read", "knowledge_search", "sessions_secret"])
        XCTAssertEqual(listing.compactMap { $0["name"].string }, ["knowledge_search"])
        let denied = try BackendUIGMemoryDiscovery.describe(.object([.init("tools", .array([.string("knowledge_search")]))]),
            catalogue: rows, granted: ["memory_read"], caller: .local)
        XCTAssertEqual(denied.value["tools"].elements?.count, 0)
        XCTAssertEqual(denied.value["unknown"].elements, [.string("no tool called knowledge_search")])
    }

    func testCoverageDoesNotLeakHiddenNamesOrCounts() throws {
        let rows: [BackendDeckCoreCatalogueCoverageRow] = [
            .init(area: "memory", action: "memory:spaces", tools: ["memory.read"]),
            .init(area: "agents", action: "memory:search", tools: ["memory.search"]),
            .init(area: "sessions", action: "hoot:memory", tools: ["hoot.memory"]),
            .init(area: "machines", action: "docker:stats", tools: ["docker.stats"])
        ]
        XCTAssertEqual(BackendUIGMemoryDiscovery.coverageRows(rows), Array(rows.suffix(2)))
        XCTAssertEqual(BackendUIGMemoryDiscovery.coverageAreas(["sessions", "memory", "machines"]), ["sessions", "machines"])
        // Tool listing: memory.search is a Deck Memory tool and is listed (11 Oct 2026); the paused page's memory.read is not.
        XCTAssertEqual(BackendUIGMemoryDiscovery.tools(try rows.flatMap { $0.tools ?? [] }.map { try row($0).tool }).map(\.id),
            ["memory.search", "hoot.memory", "docker.stats"])
    }

    func testUIDiscoveryFiltersOnlyMemoryCommands() {
        let commands: [NativeRPCValue] = [
            .object([.init("id", .string("view.memory")), .init("title", .string("Memory"))]),
            .object([.init("id", .string("open-memory")), .init("title", .string("Graph"))]),
            .object([.init("id", .string("view.tasks")), .init("title", .string("Tasks"))])
        ]
        let listing = NativeRPCValue.object([.init("commands", .array(commands)),
            .init("sessions", .array([.object([.init("id", .string("memory"))])])),
            .init("sections", .array([.string("copilot")])), .init("custom", .string("kept"))])
        let filtered = BackendUIGMemoryDiscovery.uiListing(listing)
        XCTAssertEqual(filtered["commands"].elements, Array(commands.suffix(1)))
        XCTAssertEqual(filtered["sessions"], listing["sessions"])
        XCTAssertEqual(filtered["sections"], listing["sections"])
        XCTAssertEqual(filtered["custom"], listing["custom"])
    }

    func testMixedCoverageActionRetainsItsNonMemoryTools() {
        let mixed = BackendDeckCoreCatalogueCoverageRow(area: "agents", action: "project:notes",
            tools: ["memory.read", "knowledge.get", "memory_search"])
        let hiddenOnly = BackendDeckCoreCatalogueCoverageRow(area: "agents", action: "project:old-notes",
            tools: ["memory.read"])
        let skipped = BackendDeckCoreCatalogueCoverageRow(area: "sessions", action: "session:clipboard", skip: "Person only.")
        let output = BackendUIGMemoryDiscovery.coverageRows([mixed, hiddenOnly, skipped])
        XCTAssertEqual(output, [.init(area: "agents", action: "project:notes", tools: ["knowledge.get"]), skipped])
        XCTAssertEqual(mixed.tools, ["memory.read", "knowledge.get", "memory_search"], "The raw coverage map stays intact.")
    }

    func testMemoryPauseDoesNotChangeRawRegistryAliasOwnership() throws {
        let memory = try row("memory.read", aliases: ["read_notes"], index: "Read memory")
        let knowledge = try row("knowledge.get", aliases: ["project_notes"])
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: [memory, knowledge])
        XCTAssertEqual(registry.resolve("read_notes")?.tool.id, "memory.read")
        XCTAssertEqual(registry.resolve("memory_read")?.tool.id, "memory.read")
        let filtered = BackendUIGMemoryDiscovery.metadata(registry.metadata)
        XCTAssertEqual(filtered.map { $0.tool.id }, ["knowledge.get"])
        XCTAssertEqual(registry.metadata.count, 2)
        let answer = try BackendUIGMemoryDiscovery.describe(.object([.init("tools", .array([.string("project_notes")]))]),
            catalogue: registry.metadata, granted: ["project_notes"], caller: .local)
        XCTAssertEqual(answer.value["tools"].elements?.first?["name"], .string("knowledge_get"))
    }
}
