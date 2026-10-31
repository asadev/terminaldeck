import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The Deck Memory tools as an AI sees them: listed, and cheap enough to list.
final class DeckMemoryToolsTests: XCTestCase {
    private struct Unused: Error {}
    /// Only the tools' own descriptions are read here; nothing is called.
    private func definitions() throws -> [BackendDeckToolsDefinition] {
        try DeckMemoryTools.definitions(access: .init(
            caller: { _ in throw Unused() }, knownFolder: { _, _ in throw Unused() }, session: { _, _ in throw Unused() },
            runnableProject: { _, _ in throw Unused() }, rpc: { _ in throw Unused() },
            authorize: { _, _, _, _, _, _ in throw Unused() }, record: { _, _, _, _ in throw Unused() }))
    }

    func testEveryMemoryToolIsDeclaredOnceAndCanBeFound() throws {
        let tools = try definitions()
        XCTAssertEqual(tools.map { $0.spec.id }.sorted(), DeckMemoryTools.toolIDs.sorted())
        XCTAssertEqual(Set(tools.map { $0.spec.wireName }).count, tools.count)
        for tool in tools {
            XCTAssertTrue(BackendUIGMemoryDiscovery.showsTool(tool.spec), tool.spec.id + " would be hidden by the old Memory page's pause")
            XCTAssertFalse(tool.title.isEmpty); XCTAssertEqual(tool.spec.inputSchema["type"].string, "object", tool.spec.id)
            XCTAssertEqual(tool.spec.inputSchema["additionalProperties"], .bool(false), tool.spec.id)
        }
        // The helper's own five tools (M2) and memory.search are found too; the paused page's reader is not.
        for id in ["memory.search", "memory.helper.status", "memory.helper.run", "memory.tidy.run", "memory.checklist.read", "memory.checklist.add"] {
            XCTAssertTrue(UIGMemoryVisibility.showsTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_")), id)
        }
        XCTAssertFalse(UIGMemoryVisibility.showsTool(id: "memory.read", wireName: "memory_read"))
        // A session is granted every one of them except the playbook change, which is the person's and Hoot's.
        XCTAssertEqual(Set(DeckMemoryTools.sessionToolIDs), Set(DeckMemoryTools.toolIDs).subtracting(["playbook.update"]))
        XCTAssertTrue(DeckMemoryTools.sessionToolNames.isSubset(of: BackendOrdinarySessionToolGrant.names))
    }

    /// The same bill every listed tool pays (catalogue test L272: under 600 tokens each). A tool over it gets a
    /// shorter description, never a higher limit.
    func testEveryMemoryToolFitsThePerToolListingCost() throws {
        var listed = try definitions().map(\.catalogueMetadata)
        listed += try BackendDeckToolsAppMetadata.entries().filter { $0.spec.id == "memory.search" }
            .map { BackendDeckCoreCatalogueMetadata(tool: $0.spec, title: $0.title, aliases: $0.aliases, index: $0.index, audience: $0.audience) }
        XCTAssertEqual(listed.count, DeckMemoryTools.toolIDs.count + 1)
        for tool in listed {
            let cost = BackendDeckCoreCatalogueRules.estimateTokens(tool.advertisedValue.compact)
            XCTAssertGreaterThan(cost, 60, tool.tool.id + " says too little to be used well")
            XCTAssertLessThan(cost, 600, "\(tool.tool.id) costs \(cost) tokens to list: shorten its description")
        }
    }

    /// No approval card for a seat presenting its own handoff; every other tool that changes something asks.
    func testWhichToolsAsk() throws {
        let tiers = Dictionary(uniqueKeysWithValues: try definitions().map { ($0.spec.id, $0.spec.tier) })
        XCTAssertEqual(tiers["handoff.present"], .read)
        for id in ["memory.card.read", "memory.board.read", "memory.diary.read", "playbook.read"] { XCTAssertEqual(tiers[id], .read, id) }
        for id in ["memory.note.add", "memory.topic.update"] { XCTAssertEqual(tiers[id], .act, id) }
        XCTAssertNil(tiers["memory.refresh.now"], "the desk refresh tool is gone (28 Oct 2026)")
        for id in ["memory.note.archive", "playbook.update"] { XCTAssertEqual(tiers[id], .alter, id) }
    }
}
