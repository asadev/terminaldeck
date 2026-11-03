import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Settings → Hoot's start, stop, restart and reset, plus the same MCP tools. The four "What Hoot may do"
    /// switches are gone (Asad, 12 Oct): Hoot can always do those things, so no switch is offered here.
    /// Called from installINT2HootChatTools; a failure leaves Hoot's chat working.
    func installHootSettings(access: BackendDeckToolsAppAccess) async throws {
        guard let hoot else {
            throw NativeRPCError(code: "composition-incomplete", message: "Hoot settings need the existing desk runtime.")
        }
        let runtime = hoot.runtime
        let authority = try wired(self.authority, "authority"), joins = self.joins, root = self.root
        let service = BackendROUTINESHootSettings(.init(fields: [:],
            start: { try await runtime.ensure().wireValue },
            stop: { try await runtime.stop().wireValue },
            restart: {
                _ = try await runtime.stop()
                return try await runtime.ensure().wireValue
            }))
        let channelOwner = "routines-hoot-settings", toolOwner = "native.hoot-settings-tools"
        try await service.register(registry: root.registry, ownerID: channelOwner,
                                   requireWindow: { context in try authority.requireLocalUI(context) })
        let visible: @Sendable (BackendMCPCallContext) async throws -> Void = { native in
            let current = try await authority.resolve(native)
            guard current.caller.kind == .local, !current.cancellation.isCancelled else {
                throw NativeRPCError(code: "access-denied", message: "Hoot's settings belong to this Mac's owner.")
            }
        }
        let definitions = try BackendROUTINESHootMCP.definitions(service: service, access: access, visible: visible,
            isHootSession: { session in (try? await runtime.state().sessionId) == session })
        let policies = definitions.map { joins.nativePolicy($0) }
        let area = try BackendDeckToolsSupport.area(id: "hoot-settings", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area,
            metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: toolOwner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: toolOwner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "hoot-settings", domains: ["hoot-settings"], ownerID: toolOwner,
                invokes: [], stop: {
                    await root.registry.removeOwner(channelOwner)
                    await root.mcp.removeTools(ownerID: toolOwner)
                    try joins.replaceContributions(owner: toolOwner, [], policiesWrapped: true)
                }))
        } catch {
            await root.registry.removeOwner(channelOwner)
            await root.mcp.removeTools(ownerID: toolOwner)
            try? joins.replaceContributions(owner: toolOwner, [], policiesWrapped: true)
            throw error
        }
    }
}
