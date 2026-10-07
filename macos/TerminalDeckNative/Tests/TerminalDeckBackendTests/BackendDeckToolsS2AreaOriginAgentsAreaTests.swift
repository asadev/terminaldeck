import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// agents-area.test.ts against the actual Swift contributions that make up the
/// agents area (agents-area.ts = agent, account, mcp-server, hook, routine, app,
/// setup, usage and voice tools). The MCP server tools come from the real
/// source definitions through the production `BackendDeckCoreMCPPolicies.resolve`
/// path, so the area is complete (58 tools) without any manufactured spec.
@MainActor final class BackendDeckToolsS2AreaOriginAgentsAreaTests: XCTestCase {
    private static let ownedModules: Set<String> = ["agent-tools.ts", "account-tools.ts"]
    private static let appModules: Set<String> = ["app-tools", "hook-tools", "routine-tools", "setup-tools", "usage-tools", "voice-tools"]

    /// The area as the app assembles it: every definition from the real Swift
    /// catalogues of the nine source factories.
    static func agentsArea() throws -> [BackendDeckCoreCatalogueMetadata] {
        let owned = try BackendDeckToolsSessionsCatalogue.entries.filter { ownedModules.contains($0.sourceModule) }
            .map { BackendDeckCoreCatalogueMetadata(tool: try $0.spec(), title: $0.title, index: $0.index) }
        let policies = try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreEventsUnavailableMCPProvider())
        let mcp = try BackendDeckCoreEventsTools.metadata(policies: policies)
        let app = try BackendDeckToolsAppMetadata.entries().filter { appModules.contains($0.module) }
            .map { BackendDeckCoreCatalogueMetadata(tool: $0.spec, title: $0.title, aliases: $0.aliases, index: $0.index, audience: $0.audience) }
        return owned + mcp + app
    }
    private func builtins() throws -> [BackendDeckCoreCatalogueMetadata] { try BackendDeckCoreCatalogueLiterals.builtins() }
    private func describeTools() throws -> [BackendDeckCoreCatalogueMetadata] { try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata }

    // agents-area.test.ts:37
    func testAgentsAreaL37EveryToolHasAUniqueIDAndAWireNameTheAPIAccepts() throws {
        let tools = try Self.agentsArea(), ids = tools.map { $0.tool.id }
        XCTAssertEqual(Set(ids).count, ids.count)
        for tool in tools {
            XCTAssertEqual(tool.tool.wireName, tool.tool.id.replacingOccurrences(of: ".", with: "_"), tool.tool.id)
            XCTAssertNotNil(("mcp__deck-control__" + tool.tool.wireName).range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression), tool.tool.id)
        }
    }

    // agents-area.test.ts:45
    func testAgentsAreaL45CollidesWithNothingTheAppAlreadyServes() throws {
        let builtIn = Set(try builtins().map { $0.tool.id })
        XCTAssertEqual(try Self.agentsArea().map { $0.tool.id }.filter { builtIn.contains($0) }, [])
    }

    // agents-area.test.ts:50
    func testAgentsAreaL50RefusesUnknownArgumentsOnEverySchema() throws {
        for tool in try Self.agentsArea() {
            XCTAssertEqual(tool.tool.inputSchema["type"], .string("object"), tool.tool.id)
            XCTAssertEqual(tool.tool.inputSchema["additionalProperties"], .bool(false), tool.tool.id)
        }
    }

    // agents-area.test.ts:59
    func testAgentsAreaL59HoldsEveryToolBehindDescribeAtOneShortLineEach() throws {
        for tool in try Self.agentsArea() {
            XCTAssertNotNil(tool.index, tool.tool.id)
            XCTAssertLessThanOrEqual((tool.index ?? "").utf16.count, 100, tool.tool.id)
        }
    }

    // agents-area.test.ts:72
    func testAgentsAreaL72AddsNoAdvertisedSchemaToTheStandingListing() throws {
        let base = try builtins(), describe = try describeTools(), tools = try Self.agentsArea()
        let before = try BackendDeckCoreCatalogueDescribe.advertised(base + describe)
        let after = try BackendDeckCoreCatalogueDescribe.advertised(base + tools + describe)
        XCTAssertEqual(after.count, before.count)
    }

    // agents-area.test.ts:78
    func testAgentsAreaL78CostsTheStandingListingWhatItsIndexLinesCost() throws {
        let tools = try Self.agentsArea(), added = BackendDeckCoreCatalogueDescribe.index(tools)
        XCTAssertEqual(tools.count, 58)
        XCTAssertLessThan(added.utf16.count, 6_000)
        let base = try builtins(), describe = try describeTools()
        let before = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(base + describe))
        let after = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(base + tools + describe))
        XCTAssertLessThanOrEqual(after.tokens - before.tokens, BackendDeckCoreCatalogueRules.estimateTokens(added) + 50)
    }

    // agents-area.test.ts:96
    func testAgentsAreaL96MakesEveryConfigurationCredentialOrDeletingWriteAlter() throws {
        let tools = try Self.agentsArea()
        let alter = [
            "agents.add", "agents.remove",
            "accounts.create", "accounts.rename", "accounts.delete", "accounts.set_default", "accounts.sign_in", "accounts.sign_out", "accounts.share_history",
            "mcp.add", "mcp.edit", "mcp.remove", "mcp.call", "mcp.install",
            "hooks.install", "hooks.remove", "hooks.sync",
            "routines.save", "routines.delete",
            "app.clear_log", "settings.reset", "settings.clear_browser_data", "updates.install",
            "readiness.fix",
            "voice.save_key", "voice.forget_key",
        ]
        for id in alter { XCTAssertEqual(tools.first { $0.tool.id == id }?.tool.tier, .alter, id) }
    }

    // agents-area.test.ts:128
    func testAgentsAreaL128MarksEveryReadToolReadOnlyAndNothingElse() throws {
        for tool in try Self.agentsArea() {
            XCTAssertEqual(tool.advertisedValue["annotations"]["readOnlyHint"], .bool(tool.tool.tier == .read), tool.tool.id)
        }
    }

    // agents-area.test.ts:153 — the table also points at your own tasks' tools,
    // which are contributed beside the catalogue: their ids come from the real
    // native task registration on a non-listening server.
    func testAgentsAreaL153PointsEveryAgentsTableEntryAtAToolThatExists() async throws {
        let tasks = try await BackendCrmTaskToolsParityFixture.make()
        let taskToolIDs = tasks.registrations.map { $0.0.id }
        let areaIDs = try Self.agentsArea().map { $0.tool.id }, builtInIDs = try builtins().map { $0.tool.id }
        let known = Set(areaIDs + builtInIDs + taskToolIDs)
        let dangling = BackendDeckCoreCatalogueCoverage.rows.filter { $0.area == "agents" }.flatMap { row in
            (row.tools ?? []).filter { !known.contains($0) }.map { row.action + " → " + $0 }
        }
        XCTAssertEqual(dangling, [])
    }

    // agents-area.test.ts:168
    func testAgentsAreaL168LeavesNoToolInTheAreaThatNoChannelReaches() throws {
        let named = Set(BackendDeckCoreCatalogueCoverage.rows.filter { $0.area == "agents" }.flatMap { $0.tools ?? [] })
        XCTAssertEqual(try Self.agentsArea().map { $0.tool.id }.filter { !named.contains($0) }, [])
    }
}
