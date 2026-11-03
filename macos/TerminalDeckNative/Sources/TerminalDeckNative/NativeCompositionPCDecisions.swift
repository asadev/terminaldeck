import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installPCDecisions(persistence: BackendTaskPersistence, store: BackendTaskStore, local: BackendTaskLocalService, engine: BackendTaskEngine) async throws {
        guard let authority, let core else { throw NativeRPCError(code: "composition-incomplete", message: "Business decisions require the existing task authority.") }
        let joins = self.joins, root = self.root
        var access = BackendPCDecisionAccess(verify: { call, task, mutation in
            switch call {
            case .app(let context): try authority.requireLocalUI(context); return "owner"
            case .tool(let native):
                let tool = try await joins.nativeTool(native).0
                let resolved = try await authority.resolve(native)
                let caller = resolved.caller
                guard resolved.granted == nil || BackendMCPToolNames.permits(tool, granted: resolved.granted ?? []), caller.tiers.contains(.read), !mutation || caller.tiers.contains(.act) || caller.tiers.contains(.alter), !native.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "Decision access is no longer granted.") }
                if mutation, tool == "decisions.proposal" || mutation && tool == "decisions_proposal" {
                    try await joins.prepareNative(native, tier: .act, sentence: "Update this task's business proposal or discussion.")
                }
                if caller.kind == .local { return "owner-tool" }
                guard caller.kind == .session || caller.kind == .key && caller.tasks else { throw NativeRPCError(code: "not-granted", message: "This caller has no local task access.") }
                _ = try await authority.knownFolder(task.project, native: native)
                if caller.kind == .session {
                    let assigned = try await store.bySession(caller.sessionID ?? "")?.id == task.id
                    let lead = await BackendAGTLeadSeats.shared?.covers(tool: "tasks.comment", arguments: .object([.init("task", .string(task.id))]), sessionID: caller.sessionID, task: { try await store.byID($0) }) ?? false
                    guard assigned || lead else { throw NativeRPCError(code: "not-granted", message: "Only this task's worker or current project lead can propose or discuss it.") }
                }
                // Resolve live authority after all consent/folder/seat awaits.
                // resolve(native) retains the original caller; it is only the
                // ceiling, never sufficient proof of a current credential.
                let latest: BackendDeckCoreSecurityCaller
                let key: NativeRPCValue
                if caller.kind == .key, let id = caller.keyID {
                    latest = await core.keys.caller(id: id, nameAtArrival: caller.keyName ?? "AI app")
                    key = await core.keys.get(id: id) ?? .null
                } else {
                    latest = try await BackendToolUseRestrictions.authenticatedSessionCaller(resolved, endpoint: core.sessionEndpoint)
                    key = .null
                }
                guard !native.cancellation.isCancelled else { throw CancellationError() }
                try BackendPCDecisionGrant.require(original: caller, current: latest, key: key, tool: tool, folder: task.project, mutation: mutation)
                return caller.kind == .session ? "session:" + (caller.sessionID ?? "unknown") : "key:" + (caller.keyID ?? "unknown")
            }
        }, owner: { call, action, args in
            switch call {
            case .app(let context): try authority.requireLocalUI(context) // The native owner's button is the decision.
            case .tool(let native):
                // Owner-like keys are not human proof. Even bypass mode must use
                // the existing explicit owner-answer seam for this opted-in act.
                try await joins.prepareNative(native, tier: .alter, sentence: "Business decision: " + action + " for “" + (args["_taskTitle"].string ?? "task") + "” in " + (args["_project"].string ?? "its project") + ". Workflow: " + (args["_workflowName"].string ?? args["name"].string ?? "current proposal") + ". Review the exact proposal and task instructions in this request.", ownerMustAnswer: true)
            }
        })
        access.project = { call, folder, mutation in
            switch call {
            case .app(let context): try authority.requireLocalUI(context)
            case .tool(let native):
                let resolved = try await authority.resolve(native), tool = try await joins.nativeTool(native).0
                _ = try await authority.knownFolder(folder, native: native)
                let caller = resolved.caller
                guard caller.kind == .local || caller.kind == .key && caller.tasks else { throw NativeRPCError(code: "not-granted", message: "Project workflows require owner or task-key access.") }
                if caller.kind == .key, let id = caller.keyID {
                    let latest = await core.keys.caller(id: id, nameAtArrival: caller.keyName ?? "AI app")
                    try BackendPCDecisionGrant.require(original: caller, current: latest, key: await core.keys.get(id: id) ?? .null, tool: tool, folder: folder, mutation: mutation)
                }
                guard !native.cancellation.isCancelled else { throw CancellationError() }
            }
        }
        // Review paperclip #1: worker start/send, Hoot turns/chat and lead-seat delivery each revalidate the decision at
        // their final effect, hosted helper effects included (9d209a92), so all three owners are turned on.
        let service = BackendPCDecisions(persistence: persistence, tasks: store, local: local, access: access,
            finalWorkerValidation: true, finalHootValidation: true, finalLeadValidation: true,
            nudge: { id, token in try await engine.releaseDecision(id, token: token) })
        await engine.setDecisionExecutionOwners(hoot: true, lead: true)
        await service.start()
        await engine.setBusinessDecision { task in await service.heldReason(task) }
        let owner = "pc.business-decisions"
        let registry = root.registry
        try await BackendPCDecisionsMCP.register(registry: registry, ownerID: owner, service: service, requireOwnerUI: { try authority.requireLocalUI($0) })
        let definitions = try BackendPCDecisionsMCP.definitions(service: service, changed: { try await registry.publish("tasks:changed", arguments: []) })
        let area = try BackendDeckToolsSupport.area(id: "business-decisions", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: definitions.map { joins.nativePolicy($0) })
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "business-decisions", domains: ["business-decisions"], ownerID: owner, invokes: [BackendPCDecisionsMCP.channel], stop: {
                await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch { await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner); throw error }
    }
}
