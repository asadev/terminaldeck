import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// assembled-catalogue.test.ts, over what the native side can honestly assemble
/// without live services: every bundle BackendDeckCoreRuntime.start builds
/// itself (built-ins, app.where, tools.coverage, notifications + MCP,
/// tools.describe/run) plus the source descriptor rows of the two contributed
/// metadata tables (Safari browser tools; tasks/knowledge/servers/crm/hoot).
/// The deck-tools areas need their BackendDeckToolsDefinition factories with
/// live services and are not in this list; see S1c.md. L48 adds their ids from
/// the four source tables register() enforces (`deckToolsIDs`, S1i).
final class BackendDeckCoreTestPortS1MiscTests: BackendDeckCoreTestPortSecurityCase {
    private struct Name: Equatable { let id: String; let wire: String }
    private func assembled() throws -> [Name] {
        let surface = BackendDeckCoreTestPortSecuritySurface(), clock = BackendDeckCoreTestPortSecurityClock()
        let mcp = try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreTestPortSecurityMCPProvider())
        let bundles = try [
            BackendDeckCoreCatalogueBuiltins.tools(surface: surface, typingClock: BackendDeckCoreBriefClock(now: { clock.now() }, sleep: { clock.advance($0) })),
            BackendDeckCoreCatalogueWhere.tools(dependencies: BackendDeckCoreCatalogueWhereDependencies(window: BackendDeckCoreTestPortS1IndexNoWindow(), page: { nil })),
            BackendDeckCoreCatalogueCoverage.tools(),
            BackendDeckCoreAreaIntegration.eventsBundle(policies: BackendDeckCoreEventsTools.notificationPolicies(hub: { nil }) + mcp),
        ]
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] })
        let core = (bundles.flatMap(\.metadata) + describe.metadata).map { Name(id: $0.tool.id, wire: $0.tool.wireName) }
        let contributed = try (BackendDeckCoreBrowserMetadata.sourceDescriptors() + BackendDeckCoreSupplementMetadata.sourceDescriptors()).map { row in
            Name(id: try row["id"].requireString("id"), wire: try row["wire"].requireString("wire"))
        }
        return core + contributed
    }

    // TSCASE assembled-catalogue.test.ts:36
    func testAssembledCatalogueL36HasNoTwoToolsAnsweringToOneName() throws {
        let names = try assembled().flatMap { [$0.id, $0.wire] }
        var seen = Set<String>(), twice: [String] = []
        for name in names {
            if seen.insert(name).inserted { continue }
            if !twice.contains(name) { twice.append(name) }
        }
        XCTAssertEqual(twice, [])
        // Sanity: the list is the assembled one, not an empty pass.
        XCTAssertTrue(names.contains("settings.write")); XCTAssertTrue(names.contains("tools_describe")); XCTAssertTrue(names.contains("mcp.list"))
    }
    // TSCASE assembled-catalogue.test.ts:43
    func testAssembledCatalogueL43SpellsEveryWireNameAsItsIdWithUnderscores() throws {
        let odd = try assembled().filter { $0.wire != $0.id.replacingOccurrences(of: ".", with: "_") }.map { "\($0.id) → \($0.wire)" }
        XCTAssertEqual(odd, [])
    }

    // MARK: S1i sweep

    /// The deck-tools contribution by its four source tables. These are not a
    /// copy: each factory builds its specs from them, and
    /// BackendDeckToolsRegistration.register refuses definitions whose ids are
    /// not exactly this union, so it is the registered id set without a live service.
    private func deckToolsIDs() throws -> [String] {
        try BackendDeckToolsCatalogue.entries().map(\.spec.id) + BackendDeckToolsSessionsCatalogue.entries.map(\.id)
            + BackendDeckToolsAppMetadata.entries().map(\.spec.id)
            + BackendDeckToolsMachinesCatalogue.rows().map { try $0["id"].requireString("source tool id", nonempty: true) }
    }
    // TSCASE assembled-catalogue.test.ts:48
    func testAssembledCatalogueL48NamesEveryToolTheCoverageTablesPointAt() throws {
        let built = Set(try assembled().map(\.id) + deckToolsIDs())
        let missing = BackendDeckCoreCatalogueCoverage.rows.flatMap { row in
            (row.tools ?? []).filter { !built.contains($0) }.map { "\(row.area) \(row.action) → \($0)" }
        }
        XCTAssertEqual(missing, [])
        // Sanity: the deck-tools tables carry weight here (the table names their tools), not an empty pass.
        XCTAssertFalse(Set(BackendDeckCoreCatalogueCoverage.rows.flatMap { $0.tools ?? [] }).isDisjoint(with: try deckToolsIDs()))
    }
}
