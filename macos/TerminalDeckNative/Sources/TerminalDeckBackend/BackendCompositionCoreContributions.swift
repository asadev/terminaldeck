import Foundation
import TerminalDeckNativeCore

/// The agent-facing catalogue beyond the core's own tools, exactly as the
/// source deck-control assembled it (and as S1j's catalogue-cost port proves):
/// the 128 deck-tools, the Safari tools with their source rows, and the task
/// and server-room tools with theirs. Every handler is the native owner's own,
/// registered on the root's MCP collector; every policy goes through the one
/// core door (`BackendCompositionProductionBindings.mcpPolicy`).
public enum BackendCompositionCoreContributions {
    /// Every source deck-tools id (root, sessions, app, machines catalogues).
    /// Other owners must not register these on the root collector.
    public static func deckToolsSourceIDs() throws -> Set<String> {
        let root = try BackendDeckToolsCatalogue.entries().map { $0.spec.id }
        let sessions = BackendDeckToolsSessionsCatalogue.entries.map(\.id)
        let app = try BackendDeckToolsAppMetadata.entries().map { $0.spec.id }
        let machines = try BackendDeckToolsMachinesCatalogue.rows().map { try $0["id"].requireString("source tool id", nonempty: true) }
        return Set(root + sessions + app + machines).union(BackendAIRReadinessTools.toolIDs).union(BackendSFXMCP.toolIDs)
    }

    /// The Safari tools the browser owner registered, with their source rows
    /// (requireComplete: the whole source browser contribution or nothing).
    public static func safari(server: BackendNativeMCPServer, joins: BackendCompositionProductionBindings) async throws -> BackendDeckCoreCatalogueBundle {
        let rows = Set(try BackendDeckCoreBrowserMetadata.sourceDescriptors().compactMap { $0["id"].string })
        let registered = await server.registrations().filter { rows.contains($0.0.id) }
        let metadata = try BackendDeckCoreBrowserMetadata.entries(specs: registered.map(\.0), requireComplete: true)
        return try bundle(metadata, registered, joins)
    }

    /// Task and server-room tools with their source rows. Knowledge rows are
    /// left to the clients' knowledge owner (its own grant authority).
    public static func supplement(server: BackendNativeMCPServer, joins: BackendCompositionProductionBindings,
                                  knowledgeFromClients: Bool) async throws -> BackendDeckCoreCatalogueBundle {
        let knowledge = Set(try BackendKnowledgeMCP.specifications().map(\.id))
        let rows = Set(try BackendDeckCoreSupplementMetadata.sourceDescriptors().compactMap { $0["id"].string })
            .subtracting(knowledgeFromClients ? knowledge : [])
        let registered = await server.registrations().filter { rows.contains($0.0.id) }
        let missing = rows.subtracting(registered.map { $0.0.id }).subtracting(BackendDeckCoreSupplementMetadata.retiredIDs)
        guard missing.isEmpty else {
            throw BackendSessionFailure.missingCapability("the task/server tools " + missing.sorted().joined(separator: ", "))
        }
        let metadata = try BackendDeckCoreSupplementMetadata.entries(specs: registered.map(\.0))
        return try bundle(metadata, registered, joins)
    }

    private static func bundle(_ metadata: [BackendDeckCoreCatalogueMetadata], _ registered: [(BackendMCPTool, BackendNativeMCPServer.Handler)],
                               _ joins: BackendCompositionProductionBindings) throws -> BackendDeckCoreCatalogueBundle {
        let policies = try metadata.map { row -> BackendDeckCoreSecurityToolPolicy in
            guard let handler = registered.first(where: { $0.0.id == row.tool.id })?.1 else {
                throw BackendSessionFailure.missingCapability("the registered handler for " + row.tool.id)
            }
            return joins.mcpPolicy(row, handler: handler)
        }
        return try BackendDeckCoreCatalogueBundle(metadata: metadata, policies: policies)
    }
}
