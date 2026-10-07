import Foundation
import TerminalDeckNativeCore

/// One composition-root entry point for the complete deck-tools contribution.
/// The factories' required runtime/environment callbacks must already be bound
/// to the shared core consent, budget, provenance and action-log owner. This
/// registrar neither invents those services nor creates a second gate/server.
public enum BackendDeckToolsRegistration {
    public static let ownerID = "backend.deck-tools"

    public struct Installed: Sendable {
        public let areas: [BackendDeckCoreToolArea]
        /// Join with core/Safari/client metadata for tools.describe, source
        /// aliases, audience filtering and progressive catalogue disclosure.
        public let metadata: [BackendDeckCoreCatalogueMetadata]
        public let toolIDs: [String]
    }

    /// Pass the definitions from every factory in deck-tools-HANDOFF.md once;
    /// include the shared browser.lift_request definition only once. Invoke
    /// before starting the endpoint, after the source gate callbacks are wired.
    ///
    /// All identity/metadata/area checks precede the one atomic server mutation.
    /// Repeating this call replaces only this registrar's own contribution;
    /// collisions with another owner fail without changing either contribution.
    /// Core bundles/policies retain the real runtime gates described above.
    @discardableResult
    public static func register(on server: BackendNativeMCPServer,
                                definitions: [BackendDeckToolsDefinition]) async throws -> Installed {
        let rootIDs = try BackendDeckToolsCatalogue.entries().map { $0.spec.id }
        let sessionIDs = BackendDeckToolsSessionsCatalogue.entries.map(\.id)
        let appIDs = try BackendDeckToolsAppMetadata.entries().map { $0.spec.id }
        let machineIDs = try BackendDeckToolsMachinesCatalogue.rows().map {
            try $0["id"].requireString("source tool id", nonempty: true)
        }
        let expected = Set(rootIDs + sessionIDs + appIDs + machineIDs)
        let supplied = Set(definitions.map { $0.spec.id })
        guard supplied == expected, definitions.count == expected.count else {
            let missing = expected.subtracting(supplied).sorted().joined(separator: ", ")
            let extra = supplied.subtracting(expected).sorted().joined(separator: ", ")
            throw NativeRPCError.invalidArguments(
                "The deck-tools registration requires each source tool exactly once. "
                + "Missing: \(missing.isEmpty ? "none" : missing). "
                + "Extra: \(extra.isEmpty ? "none" : extra). "
                + "Duplicate entries: \(definitions.count - supplied.count).")
        }

        let metadata = definitions.map(\.catalogueMetadata)
        _ = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        let grouped = Dictionary(grouping: definitions) {
            BackendDeckCoreCatalogueDescribe.areaOf($0.spec.id)
        }
        let order = BackendDeckCoreCatalogueDescribe.areas.map(\.id)
        let names = grouped.keys.sorted { first, second in
            let a = order.firstIndex(of: first) ?? order.count
            let b = order.firstIndex(of: second) ?? order.count
            return a == b ? first < second : a < b
        }
        let areas = try names.map { name in
            try BackendDeckToolsSupport.area(id: name, definitions: grouped[name]!)
        }
        var contribution: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = []
        for area in areas {
            for tool in area.tools {
                guard let handler = area.handlers[tool.id] else {
                    throw BackendDeckToolsSupport.unavailable("the \(tool.id) registration handler")
                }
                contribution.append((tool, handler))
            }
        }
        try Task.checkCancellation()
        try await server.replaceTools(ownerID: ownerID, tools: contribution)
        return Installed(areas: areas, metadata: metadata, toolIDs: areas.flatMap { $0.tools.map(\.id) })
    }
}
