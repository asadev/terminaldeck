import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installFIXESIslandTools(access: BackendDeckToolsAppAccess) async throws {
        guard let authority else { throw NativeRPCError(code: "composition-incomplete", message: "Hoot's screen tools need the existing caller authority.") }
        let owner = "native.fixes-island-tools", joins = self.joins, root = self.root
        let definitions = try BackendFIXESIslandMCP.definitions(access: access,
            visible: { native in _ = try await authority.resolve(native) },
            read: { await MainActor.run { NativeFIXESIslandPreferences.shared.read() } },
            configure: { args in try await NativeFIXESIslandPreferences.shared.configure(args) })
        let policies = definitions.map { definition in
            let base = joins.nativePolicy(definition)
            return BackendDeckCoreSecurityToolPolicy(tool: base.tool, aliases: base.aliases, audience: base.audience,
                keyRequiresTasks: base.keyRequiresTasks, spendsDeviceInput: base.spendsDeviceInput,
                summary: base.summary, precheck: base.precheck, precheckAsync: base.precheckAsync,
                escalate: base.escalate, ownerMustAnswer: { args in
                    if definition.spec.tier != .read { return true }
                    return try base.ownerMustAnswer?(args) ?? false
                },
                redactArgs: base.redactArgs, run: base.run)
        }
        let area = try BackendDeckToolsSupport.area(id: "hoot-island", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "fixes-island-tools", domains: ["fixes-island-tools"], ownerID: owner, invokes: [], stop: {
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
