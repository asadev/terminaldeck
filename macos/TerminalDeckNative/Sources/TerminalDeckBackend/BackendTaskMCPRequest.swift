import Foundation
import TerminalDeckNativeCore

/// Common caller, scope and approval checks run before any dedicated handler.
struct BackendTaskMCPRequest: Sendable {
    let id: String
    let baseTier: BackendMCPTier
    let verbWords: [String]?
    let caller: BackendMCPCallContext
    let args: NativeRPCValue
    let view: BackendTaskStateView
    let local: BackendTaskLocalService
    let engine: BackendTaskEngine
    let detail: BackendTaskDetailService
    let planning: BackendGoalPlanning
    let api: BackendTaskAPI?
    let delegation: BackendTaskDelegation?
    let authority: BackendTaskToolAuthority
    let knowledge: BackendTaskKnowledgeAdapter?
    let readAttachment: (@Sendable (BackendMCPCallContext, String) async throws -> (name: String, mime: String?, bytes: Data))?
    let island: BackendTaskIslandControl?
    let control: BackendTaskControlOperations?
    private(set) var by = ""
    private(set) var profileKey: String?
    private(set) var reviewOrdinaryProfileFields = false
    private(set) var agentArgs = NativeRPCValue.missing
    var verb: String { args["do"].string ?? "" }
    var tier: BackendMCPTier { BackendTaskToolPolicy.tier(id, arguments: args, fallback: baseTier) }
    var localTool: Bool { id.hasPrefix("tasks.local") || id.hasPrefix("tasks.agents") }

    mutating func prepare() async throws {
        try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
        // The verb is checked before any work runs (local-task-tools.ts / goal-tools.ts verb()).
        if let verbWords, id != "hoot.island", !verbWords.contains(verb) { throw NativeRPCError.invalidArguments("do must be one of: " + verbWords.joined(separator: ", ")) }
        if id == "hoot.island" { guard ["get", "set"].contains(verb) else { throw NativeRPCError.invalidArguments("do must be get or set") } }
        guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: caller.attended ? "not-granted" : "not-permitted-unattended", message: "The caller cannot perform this task action") }
        if id != "crm.task" {
            if ["tasks.delegate", "tasks.review", "tasks.verify", "tasks.get", "tasks.comment"].contains(id), let require = authority.requireTaskAction { try await require(caller, id) }
            else if localTool || id == "tasks.delegate" || id == "tasks.claims" || id == "tasks.crm_sync" { try await authority.requireTasks(caller) }
            else { try await authority.requireHoot(caller) }
        }
        by = id == "crm.task" ? "" : try await authority.actorName(caller)
        // Lane TK: the calling session's project, and the project a listing covers (nil: every project).
        if let project = args["project"].string, !project.isEmpty { try await authority.project(caller, project) }
        if args.has("task") { _ = try await task(args["task"], localOnly: localTool || ["tasks.retry", "tasks.reassign", "tasks.review", "tasks.goals"].contains(id), trash: verb == "restore" || verb == "purge") }
        if id == "tasks.plan", let project = try await planning.validate(args) { try await authority.project(caller, project) }
        if ["save", "save-many"].contains(verb) && id == "tasks.agents" { profileKey = try await authority.callerKeyID?(caller) } else { profileKey = nil }
        if profileKey != nil { reviewOrdinaryProfileFields = try await authority.requiresOwnerProfileEdits?(caller) ?? false } else { reviewOrdinaryProfileFields = false }
        // A lead adds agents to its own project (a new agent's project and manager default to the lead's).
        agentArgs = args
        if id == "tasks.agents", ["save", "save-many"].contains(verb) { agentArgs = try await authority.scopedAgentRequest(caller, args, config: view.config) }
        if id == "tasks.agents", !["list", "save", "save-many"].contains(verb), let target = args["id"].string, let row = try await view.config.agent(target) {
            try await authority.checkAgentScope(caller, rows: [row], acting: verb, config: view.config)
        }
        if id == "tasks.agents_import", let scope = authority.agentScope, try await scope(caller) != .everything {
            throw NativeRPCError(code: "not-granted", message: "Importing agent files is Hoot's (or the owner's). Ask Hoot to import them.")
        }
        if id == "tasks.agents", ["save", "save-many"].contains(verb) {
            if let profileKey {
                _ = try await view.config.profileChangePreview(request: args, callerKeyID: profileKey, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", ownerReviewOrdinaryFields: reviewOrdinaryProfileFields)
                // One shared change (agent, with ids for save-many) or a list of whole agents (agents).
                let inputs: [NativeRPCValue], ids: [String]
                if args.has("agents") { inputs = try args["agents"].requireArray("agents") } else { inputs = [try args["agent"].requireObject("agent")] }
                if verb == "save-many", !args.has("agents") { ids = try (args["ids"].elements ?? []).map { try $0.requireString("agent id", nonempty: true) } }
                else { ids = inputs.compactMap { $0["id"].string } }
                for profileID in ids {
                    if let row = try await view.config.agent(profileID), let project = row["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) }
                }
                for input in inputs { if let project = input["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) } }
            } else {
                // Hoot, a task agent's or a lead's session (no key): the same tool, the same fields as the New
                // Agent screen. Every agent in the request is checked here, before the one consent; nothing is written.
                let rows = try await view.config.saveAgentsAsCaller(request: agentArgs, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", dryRun: true, ownerMode: try await authority.widensAgents?(caller) ?? false)
                try await authority.checkAgentScope(caller, rows: rows, acting: verb, config: view.config)
                for row in rows { if let project = row["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) } }
            }
        }
        if id == "tasks.agents_import", args.has("batches") {
            // #117: every batch folder is authorized and previewed before anything is written.
            for batch in try args["batches"].requireArray("agent batches") {
                let folder = try batch["folder"].requireString("folder", nonempty: true)
                try await authority.project(caller, folder)
                try await authority.project(caller, BackendTAGAgentImport.directory(folder).path)
            }
            _ = try await BackendPROJAgentBatches.preview(configuration: view.config, request: args, projects: PROJProjects.defaults)
        } else if id == "tasks.agents_import" {
            let folder = try args["folder"].requireString("folder", nonempty: true)
            try await authority.project(caller, folder)
            try await authority.project(caller, BackendTAGAgentImport.directory(folder).path)
            _ = try await view.config.importPreview(folder: folder, options: args["options"])
            let options = try BackendTAGAgentImport.options(args["options"])
            for entry in [options] + (options["agents"].fields ?? []).map(\.value) {
                if let path = entry["defaultProject"].string { try await authority.project(caller, path) }
            }
        }
        try await authority.authorize(caller, id, args, tier)
    }

    func home() async throws -> String? { try await authority.callerProject?(caller) }
    func listingScope() async throws -> String? { BackendTaskProjectScope.listing(args, callerProject: try await home()) }
    func task(_ raw: NativeRPCValue, localOnly: Bool = false, trash: Bool = false) async throws -> BackendTaskRecord {
        if localOnly {
            // local-task-tools.ts taskOf (the local tools) and goal-tools.ts taskArg (the goal tools).
            guard let key = raw.string, !key.isEmpty else { throw NativeRPCError.invalidArguments(localTool ? "task is required: an id from tasks_local" : "task is required: an id from tasks_progress or tasks_local") }
            let record = try await view.store.byID(key, includeTrash: trash)
            if let record, !record.isLocal { throw NativeRPCError(code: "not-permitted", message: localTool ? "That is a CRM task: the CRM owns it. Use tasks_list, tasks_get and the other CRM task tools for it." : "That is a CRM task: the CRM owns it. Use tasks_get, tasks_comment and tasks_verify for it.") }
            guard let record, try await authority.visible(caller, record) else { throw NativeRPCError.invalidArguments(trash ? "there is no task \(key) in the Trash" : "there is no task \(key)") }; return record
        }
        guard let id = raw.string, let record = try await view.store.byID(id, includeTrash: trash), try await authority.visible(caller, record) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        return record
    }
    func goalRow(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        guard let key = raw.string, !key.isEmpty else { throw NativeRPCError.invalidArguments("goal is required: an id from tasks_goals") }
        guard let goal = try await view.goals.byID(key) else { throw NativeRPCError.invalidArguments("there is no goal \(key)") }
        if BackendINT2PhonePanelCaller.current != nil {
            guard let project = goal["project"].string, !project.isEmpty else { throw NativeRPCError(code: "access-denied", message: "This phone cannot read or change an unscoped goal.") }
            try await authority.project(caller, project)
        }
        return goal
    }
    func goalView(_ goal: NativeRPCValue) async throws -> NativeRPCValue {
        let report = try await view.goals.progress(goal["id"].string ?? "", tasks: view.store.all())
        var counts = NativeRPCValue.object([]); for key in ["total", "done", "verified", "unverified", "stalled", "blocked"] { counts = counts.setting(key, report[key]) }; return goal.setting("progress", counts)
    }
}
