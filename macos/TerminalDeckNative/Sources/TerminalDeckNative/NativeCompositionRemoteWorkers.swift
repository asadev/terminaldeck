import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Remote worker connections and named remote runs: the service (real HTTP, Keychain tokens,
    /// private records), the owner window's channel and the `agents.remote_*` MCP tools, all on one
    /// operation table. Local terminal sessions are not touched. A failure leaves only this feature out.
    func installRemoteWorkers() async {
        guard let authority, let core else { return }
        let owner = "pc.remote-workers", registry = root.registry, joins = self.joins, root = self.root
        let service = BackendRemoteWorkers(root: root.dataRoot, transport: BackendRemoteWorkerURLSession(),
            secrets: BackendConnectedTasksKeychain(appName: configuration.appName, namespace: "Remote Workers", devFile: "remote-workers"))
        await service.onChange { [registry] in try? await registry.publish(BackendRemoteWorkersMCP.changedChannel, arguments: [], ownerID: BackendCompositionRoot.appOwnerID) }
        let access = BackendRemoteWorkersAccess(verify: { call, _ in
            switch call {
            case .app(let context): try authority.requireLocalUI(context)
            case .tool(let native):
                // Only the owner's own Hoot/local callers. Worker sessions and outside keys cannot start
                // remote work or change where it goes.
                let resolved = try await authority.resolve(native)
                guard resolved.caller.kind == .local, !native.cancellation.isCancelled else {
                    throw NativeRPCError(code: "not-granted", message: "Remote workers belong to the owner and Hoot, not to worker sessions or outside keys.")
                }
            }
        })
        do {
            let definitions = try BackendRemoteWorkersMCP.definitions(service: service, access: access)
            let policies = definitions.map { definition -> BackendDeckCoreSecurityToolPolicy in
                let base = joins.nativePolicy(definition)
                return BackendDeckCoreSecurityToolPolicy(tool: base.tool, aliases: base.aliases, audience: base.audience, keyRequiresTasks: base.keyRequiresTasks,
                    spendsDeviceInput: base.spendsDeviceInput, summary: base.summary, precheck: base.precheck, precheckAsync: base.precheckAsync,
                    escalate: base.escalate, ownerMustAnswer: base.ownerMustAnswer, redactArgs: { BackendRemoteWorkersMCP.safeArguments($0) }, run: base.run)
            }
            let area = try BackendDeckToolsSupport.area(id: "remote-workers", definitions: definitions)
            let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
            try await BackendRemoteWorkersMCP.register(registry: registry, ownerID: owner, service: service, requireOwnerUI: { try authority.requireLocalUI($0) })
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "remote-workers", domains: ["remote-workers"], ownerID: owner, invokes: [BackendRemoteWorkersMCP.channel], sends: [],
                events: [BackendRemoteWorkersMCP.changedChannel], stop: {
                    await service.stopObserving()
                    await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                    try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                }))
            await service.reconcile()   // reads back active runs; never starts or resumes anything
        } catch {
            await service.stopObserving()
            await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            NSLog("[remote workers] Remote workers were not installed: %@", error.localizedDescription)
        }
    }
}
