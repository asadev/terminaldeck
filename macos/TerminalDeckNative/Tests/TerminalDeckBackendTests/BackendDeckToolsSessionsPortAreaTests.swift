import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Catalogue tests consume actual compiled metadata and the actual assembly /
/// describe/coverage functions. No nonexistent MCP tool is manufactured here.
@MainActor final class BackendDeckToolsSessionsPortAreaTests: XCTestCase {
    private let mcpIDs = ["mcp.list", "mcp.add", "mcp.edit", "mcp.remove", "mcp.connect", "mcp.disconnect", "mcp.call", "mcp.store", "mcp.install", "mcp.export", "mcp.import"]
    private func owned(_ modules: Set<String>) throws -> [BackendDeckCoreCatalogueMetadata] {
        try BackendDeckToolsSessionsCatalogue.entries.filter { modules.contains($0.sourceModule) }.map { .init(tool: try $0.spec(), title: $0.title, index: $0.index) }
    }
    private func app(_ modules: Set<String>) throws -> [BackendDeckCoreCatalogueMetadata] {
        try BackendDeckToolsAppMetadata.entries().filter { modules.contains($0.module) }.map { .init(tool: $0.spec, title: $0.title, aliases: $0.aliases, index: $0.index, audience: $0.audience) }
    }
    private func sessionLane() throws -> [BackendDeckCoreCatalogueMetadata] {
        let more = try owned(["session-more-tools.ts"])
        let filesProjects = try BackendDeckToolsCatalogue.entries().filter { ["files-tools", "project-tools"].contains($0.module) }.map { BackendDeckCoreCatalogueMetadata(tool: $0.spec, title: $0.title, index: $0.index) }
        return more + filesProjects + (try app(["copilot-admin-tools", "ui-tools"])) + (try BackendDeckCoreCatalogueCoverage.tools().metadata)
    }
    private func knownAgentMetadata() throws -> [BackendDeckCoreCatalogueMetadata] {
        try owned(["agent-tools.ts", "account-tools.ts"]) + app(["app-tools", "hook-tools", "routine-tools", "setup-tools", "usage-tools", "voice-tools"])
    }
    private func fullAgentMetadata() throws -> [BackendDeckCoreCatalogueMetadata] {
        let rows = try knownAgentMetadata(), actual = Set(rows.map { $0.tool.id }), missing = mcpIDs.filter { !actual.contains($0) }
        if !missing.isEmpty { throw XCTSkip("Source agents-area expects 58 real tools; native mcp-server-tools factory/metadata is absent: " + missing.joined(separator: ", ") + ". Integrator must supply its actual factory; do not create fake specs.") }
        XCTAssertEqual(rows.count, 58); return rows
    }
    func testSessionsLaneL55EverySourceChannelHasADecision() {
        let rows = BackendDeckCoreCatalogueCoverage.rows.filter { $0.area == "sessions" }
        XCTAssertFalse(rows.isEmpty); XCTAssertEqual(rows.filter { $0.tools == nil && $0.skip == nil }.map(\.action), [])
    }
    func testSessionsLaneL62CoverageOnlyNamesToolsThatExist() throws {
        let lane = try sessionLane(), base = try BackendDeckCoreCatalogueLiterals.builtins(), windows = try owned(["session-window-tools.ts"])
        let known = Set((lane + base + windows).map { $0.tool.id }).union(BrowserDriverVerb.allCases.map { $0.rawValue.replacingOccurrences(of: "_", with: ".") })
        let dangling = BackendDeckCoreCatalogueCoverage.rows.filter { ["sessions", "window"].contains($0.area) }.flatMap { row in (row.tools ?? []).filter { !known.contains($0) }.map { row.action + " → " + $0 } }
        XCTAssertEqual(dangling, [])
    }
    func testSessionsLaneL71NoBuiltinCollisionAndEveryWireMatchesID() throws {
        let lane = try sessionLane(), builtIn = Set(try BackendDeckCoreCatalogueLiterals.builtins().map { $0.tool.id }), ids = lane.map { $0.tool.id }
        XCTAssertEqual(ids.filter { builtIn.contains($0) }, []); XCTAssertEqual(Set(ids).count, ids.count)
        for row in lane { XCTAssertEqual(row.tool.wireName, row.tool.id.replacingOccurrences(of: ".", with: "_")) }
    }
    func testSessionsLaneL79AllLaneToolsAreHeldBehindDescribe() throws {
        let lane = try sessionLane(), base = try BackendDeckCoreCatalogueLiterals.builtins(), describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        XCTAssertEqual(lane.filter { $0.index == nil }.map { $0.tool.id }, [])
        let before = try BackendDeckCoreCatalogueDescribe.advertised(base + describe), after = try BackendDeckCoreCatalogueDescribe.advertised(base + lane + describe)
        XCTAssertEqual(after.count, before.count)
    }
    func testSessionsLaneL92IndexFitsMeasuredBudgetAndPerLineCeiling() throws {
        let lane = try sessionLane()
        for row in lane { XCTAssertLessThanOrEqual(row.index?.utf16.count ?? 0, 120, row.tool.id) }
        XCTAssertLessThan(BackendDeckCoreCatalogueRules.estimateTokens(BackendDeckCoreCatalogueDescribe.index(lane)), 1_200)
    }
    func testSessionsLaneL105EveryRequiredArgumentExistsAndUnknownKeysAreRefused() throws {
        for row in try sessionLane() {
            XCTAssertEqual(row.tool.inputSchema["type"], .string("object")); XCTAssertEqual(row.tool.inputSchema["additionalProperties"], .bool(false))
            for key in row.tool.inputSchema["required"].elements ?? [] { XCTAssertTrue(row.tool.inputSchema["properties"].has(key.string ?? "")) }
        }
    }
    func testAgentsAreaL37UniqueIDsAndAcceptedWireNames_SeamNeeded() throws {
        let rows = try fullAgentMetadata(); XCTAssertEqual(Set(rows.map { $0.tool.id }).count, rows.count)
        for row in rows {
            XCTAssertEqual(row.tool.wireName, row.tool.id.replacingOccurrences(of: ".", with: "_"))
            XCTAssertNotNil(("mcp__deck-control__" + row.tool.wireName).range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression))
        }
    }
    func testAgentsAreaL45NoBuiltinCollision_SeamNeeded() throws {
        let rows = try fullAgentMetadata(), builtIn = Set(try BackendDeckCoreCatalogueLiterals.builtins().map { $0.tool.id })
        XCTAssertEqual(rows.map { $0.tool.id }.filter { builtIn.contains($0) }, [])
    }
    func testAgentsAreaL50All58SchemasRejectUnknownProperties_SeamNeeded() throws {
        for row in try fullAgentMetadata() { XCTAssertEqual(row.tool.inputSchema["type"], .string("object")); XCTAssertEqual(row.tool.inputSchema["additionalProperties"], .bool(false)) }
    }
    func testAgentsAreaL59EveryIndexIsPresentAndAtMost100_SeamNeeded() throws {
        for row in try fullAgentMetadata() { XCTAssertNotNil(row.index); XCTAssertLessThanOrEqual(row.index?.utf16.count ?? 0, 100) }
    }
    func testAgentsAreaL72NoStandingSchemaGrowth_SeamNeeded() throws {
        let rows = try fullAgentMetadata(), base = try BackendDeckCoreCatalogueLiterals.builtins(), describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        XCTAssertEqual(try BackendDeckCoreCatalogueDescribe.advertised(base + rows + describe).count, try BackendDeckCoreCatalogueDescribe.advertised(base + describe).count)
    }
    func testAgentsAreaL78Exact58ToolsAndIndexBudget_SeamNeeded() throws {
        let rows = try fullAgentMetadata(), index = BackendDeckCoreCatalogueDescribe.index(rows)
        XCTAssertEqual(rows.count, 58); XCTAssertLessThan(index.utf16.count, 6_000)
        let base = try BackendDeckCoreCatalogueLiterals.builtins(), describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        let before = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(base + describe)), after = BackendDeckCoreCatalogueCost.measure(try BackendDeckCoreCatalogueDescribe.advertised(base + rows + describe))
        XCTAssertLessThanOrEqual(after.tokens - before.tokens, BackendDeckCoreCatalogueRules.estimateTokens(index) + 50)
    }
    func testAgentsAreaL96AllCredentialConfigAndDeleteToolsAlter_SeamNeeded() throws {
        let rows = try fullAgentMetadata()
        for id in ["agents.add", "agents.remove", "accounts.create", "accounts.rename", "accounts.delete", "accounts.set_default", "accounts.sign_in", "accounts.sign_out", "accounts.share_history", "mcp.add", "mcp.edit", "mcp.remove", "mcp.call", "mcp.install", "hooks.install", "hooks.remove", "hooks.sync", "routines.save", "routines.delete", "app.clear_log", "settings.reset", "settings.clear_browser_data", "updates.install", "readiness.fix", "voice.save_key", "voice.forget_key"] { XCTAssertEqual(rows.first { $0.tool.id == id }?.tool.tier, .alter, id) }
    }
    func testAgentsAreaL128ReadonlyHintMatchesBaseTier_SeamNeeded() throws {
        for row in try fullAgentMetadata() { XCTAssertEqual(row.advertisedValue["annotations"]["readOnlyHint"], .bool(row.tool.tier == .read)) }
    }
    func testAgentsAreaL134RoutinesUseActualChannelTierTableAndExcludeHumanText() throws {
        let rows = try app(["routine-tools"])
        for (id, channel) in [("routines.list", "routines:list"), ("routines.get", "routines:get"), ("routines.run", "routines:run"), ("routines.pause", "routines:pause"), ("routines.resume", "routines:resume"), ("routines.save", "routines:update"), ("routines.delete", "routines:delete")] {
            XCTAssertEqual(rows.first { $0.tool.id == id }?.tool.tier.rawValue, BackendRoutinesAPI.tiers[channel]?.rawValue)
        }
        XCTAssertEqual(BackendRoutinesAPI.tiers.values.filter { $0 == .human }.map(\.rawValue), ["human"])
        XCTAssertFalse(rows.contains { $0.tool.id.range(of: "save_?text", options: [.regularExpression, .caseInsensitive]) != nil })
    }
    func testAgentsAreaL153EveryChannelNamesAnActualFactoryTool_SeamNeeded() throws {
        _ = try fullAgentMetadata()
        throw XCTSkip("The complete agents table also requires native local-task/goal factory metadata from the task owner. Exact expectation: no dangling agents channel -> tool IDs after merging actual agents, builtins, local-task and goal tools.")
    }
    func testAgentsAreaL168NoUnreferencedAreaTool_SeamNeeded() throws {
        let rows = try fullAgentMetadata(), named = Set(BackendDeckCoreCatalogueCoverage.rows.filter { $0.area == "agents" }.flatMap { $0.tools ?? [] })
        XCTAssertEqual(rows.map { $0.tool.id }.filter { !named.contains($0) }, [])
    }
    func testAgentsAreaL179NoRemovedMacSpeechChannels() {
        XCTAssertFalse(BackendDeckCoreCatalogueCoverage.rows.contains { $0.area == "agents" && $0.action.hasPrefix("nspeech:") })
    }
}
