import Foundation
import TerminalDeckNativeCore

/// Owner-scoped client metadata for the existing deck-core Registry/Describe.
/// The runtime accepts this same snapshot through its liveMetadata hook; this
/// object creates no second server or action dispatcher. The grant callback
/// must preserve unrelated tools and the real authenticated caller predicates.
public final class BackendCompositionClientsDeckCatalogue: BackendCompositionClientsLazyCatalogue, @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: [BackendDeckCoreCatalogueMetadata]] = [:]
    private var order: [String] = []
    private var revision: UInt64 = 0
    private let baseMetadata: @Sendable () -> [BackendDeckCoreCatalogueMetadata]
    private let updateCallerGrants: @Sendable ([BackendDeckCoreCatalogueMetadata]) async throws -> Void
    private let report: @Sendable (String) -> Void
    public init(baseMetadata: @escaping @Sendable () -> [BackendDeckCoreCatalogueMetadata],
                updateCallerGrants: @escaping @Sendable ([BackendDeckCoreCatalogueMetadata]) async throws -> Void,
                report: @escaping @Sendable (String) -> Void) {
        self.baseMetadata = baseMetadata; self.updateCallerGrants = updateCallerGrants; self.report = report
    }
    private static let titles = [
        "memory.search": "Search your memory",
        "memory.read": "Read your memory",
        "knowledge.search": "Search project knowledge",
        "knowledge.get": "Read a project knowledge record",
        "knowledge.record": "Record project knowledge",
        "knowledge.supersede": "Replace or withdraw project knowledge",
        "knowledge.note": "Note project knowledge"
    ]
    public static func clientMetadata(tool: BackendMCPTool, index: String) throws -> BackendDeckCoreCatalogueMetadata {
        guard !tool.advertised, let title = titles[tool.id], !index.isEmpty else {
            throw BackendSessionFailure.missingCapability("the original held client metadata for " + tool.id)
        }
        return .init(tool: tool, title: title, index: index, audience: "copilot")
    }
    public func metadata() -> [BackendDeckCoreCatalogueMetadata] {
        lock.withLock { order.flatMap { owners[$0] ?? [] } }
    }
    /// Includes the existing core/descriptor metadata supplied by its owner.
    /// Alias collisions are checked with the original concrete registry.
    public func registry() throws -> BackendDeckCoreCatalogueRegistry {
        try BackendDeckCoreCatalogueRegistry(metadata: baseMetadata() + metadata())
    }
    public func install(ownerID: String, tools: [BackendMCPTool], index: [String: String], areas: [String: String]) async throws {
        guard !ownerID.isEmpty else { throw NativeRPCError.invalidArguments("A held client catalogue needs its registration owner.") }
        let rows = try tools.map { tool -> BackendDeckCoreCatalogueMetadata in
            guard let line = index[tool.id],
                  areas[tool.id] == BackendDeckCoreCatalogueDescribe.areaOf(tool.id) else {
                throw BackendSessionFailure.missingCapability("the original held client metadata for " + tool.id)
            }
            return try Self.clientMetadata(tool: tool, index: line)
        }
        _ = try BackendDeckCoreCatalogueRegistry(metadata: rows)
        let base = baseMetadata()
        let proposed = try lock.withLock { () throws -> (revision: UInt64, owners: [String: [BackendDeckCoreCatalogueMetadata]], order: [String], metadata: [BackendDeckCoreCatalogueMetadata]) in
            var next = owners, nextOrder = order
            next[ownerID] = rows
            if !nextOrder.contains(ownerID) { nextOrder.append(ownerID) }
            let all = nextOrder.flatMap { next[$0] ?? [] }
            _ = try BackendDeckCoreCatalogueRegistry(metadata: base + all)
            return (revision, next, nextOrder, all)
        }
        // Actual caller/grant ownership must be ready before publishing held
        // specifications. A failed grant update never publishes fake visibility.
        try await updateCallerGrants(proposed.metadata)
        let committed = lock.withLock { () -> Bool in
            guard revision == proposed.revision else { return false }
            owners = proposed.owners; order = proposed.order; revision &+= 1; return true
        }
        guard committed else {
            try await updateCallerGrants(metadata())
            throw NativeRPCError(code: "composition-conflict", message: "The held client catalogue changed while its caller grants were being updated.")
        }
    }
    public func remove(ownerID: String) async {
        let remaining = lock.withLock { () -> [BackendDeckCoreCatalogueMetadata] in
            owners[ownerID] = nil; order.removeAll { $0 == ownerID }; revision &+= 1
            return order.flatMap { owners[$0] ?? [] }
        }
        do { try await updateCallerGrants(remaining) }
        catch { report("Held client grant teardown: " + error.localizedDescription) }
    }
    /// Root transports pass their credential-resolved context; there is no
    /// unrestricted/default caller overload. Denied and unknown names retain
    /// the same source response, and missing describe grants expose full specs.
    public func wireListing(context: BackendDeckCoreSecurityCallContext) throws -> [NativeRPCValue] {
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        return try BackendDeckCoreCatalogueDescribe.wireListing(metadata: registry().metadata, caller: context.caller, granted: context.granted)
    }
    public func describe(arguments: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) throws -> BackendDeckCoreSecurityToolOutput {
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        return try BackendDeckCoreCatalogueDescribe.answer(arguments, catalogue: registry().metadata, granted: context.granted, caller: context.caller)
    }
}
