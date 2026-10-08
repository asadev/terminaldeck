import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Additive tools stay outside the deck-tools registrar's exact source set,
    /// with the same runtime, security door and action row as the other tools.
    func installINT2HootChatTools(access: BackendDeckToolsAppAccess) async throws {
        guard let hoot else {
            throw NativeRPCError(code: "composition-incomplete", message: "Hoot chat tools need the existing desk runtime.")
        }
        let owner = "native.hoot-chat-tools", runtime = hoot.runtime
        let authority = self.authority!, joins = self.joins, root = self.root
        let requireOwner: @Sendable (BackendMCPCallContext) async throws -> Void = { native in
            let current = try await authority.resolve(native)
            try NativeCompositionINT2HootScope.requireOwner(current, runtime: runtime)
        }
        let definitions = try BackendHootChatMCP.definitions(runtime: runtime, access: access, visible: requireOwner).map {
            BackendDeckToolsDefinition(spec: $0.spec, title: $0.title, index: $0.index, aliases: $0.aliases,
                audience: "copilot", keyIndex: $0.keyIndex, keyGrant: $0.keyGrant, handler: $0.handler)
        }
        let policies = definitions.map { definition in
            let base = joins.nativePolicy(definition)
            return BackendDeckCoreSecurityToolPolicy(tool: base.tool, aliases: base.aliases, audience: "copilot",
                keyRequiresTasks: base.keyRequiresTasks, spendsDeviceInput: base.spendsDeviceInput,
                summary: base.summary, precheck: base.precheck,
                precheckAsync: { args, current in
                    try NativeCompositionINT2HootScope.requireOwner(current, runtime: runtime)
                    try await base.precheckAsync?(args, current)
                }, escalate: base.escalate, ownerMustAnswer: base.ownerMustAnswer,
                redactArgs: base.redactArgs, run: base.run)
        }
        let area = try BackendDeckToolsSupport.area(id: "hoot-chat", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area,
            metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "hoot-chat-tools", domains: ["hoot-chat-tools"], ownerID: owner,
                invokes: [], stop: {
                    await root.mcp.removeTools(ownerID: owner)
                    try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                }))
        } catch {
            await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            throw error
        }
    }
}

private enum NativeCompositionINT2HootScope {
    static func requireOwner(_ context: BackendDeckCoreSecurityCallContext, runtime: BackendCopilotSessionRuntime) throws {
        guard context.caller.kind == .local, !context.cancellation.isCancelled else {
            throw NativeRPCError(code: "access-denied", message: "The desk Hoot conversation belongs to this Mac's owner. This caller has no explicit desk-chat grant.")
        }
        guard context.native.sessionID.isEmpty || context.native.sessionID != runtime.structuredChat?.conversationID else {
            throw NativeRPCError(code: "access-denied", message: "Hoot cannot read, ask or stop its own conversation through the tool door.")
        }
    }
}
