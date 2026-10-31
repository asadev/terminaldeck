import Foundation
import TerminalDeckNativeCore

public enum BackendPCDecisionCall: Sendable { case app(NativeRPCContext), tool(BackendMCPCallContext) }
public struct BackendPCDecisionAccess: Sendable {
    public let verify: @Sendable (BackendPCDecisionCall, BackendTaskRecord, Bool) async throws -> String
    public var project: @Sendable (BackendPCDecisionCall, String, Bool) async throws -> Void = { _, _, _ in throw NativeRPCError(code: "not-granted", message: "Project workflow access is unavailable.") }
    public let owner: @Sendable (BackendPCDecisionCall, String, NativeRPCValue) async throws -> Void
    public init(verify: @escaping @Sendable (BackendPCDecisionCall, BackendTaskRecord, Bool) async throws -> String,
                owner: @escaping @Sendable (BackendPCDecisionCall, String, NativeRPCValue) async throws -> Void) { self.verify = verify; self.owner = owner }
}

/// Optional local business workflow. Persistence is supplied by the task owner.
/// A missing/corrupt record holds required tasks, while ordinary/CRM tasks stay off.
public actor BackendPCDecisions {
    private let persistence: BackendTaskPersistence, tasks: BackendTaskStore, access: BackendPCDecisionAccess
    private let local: BackendTaskLocalService
    private let finalWorkerValidation: Bool
    private let finalHootValidation: Bool, finalLeadValidation: Bool
    private let writer: (@Sendable (NativeRPCValue) throws -> Void)?
    private let nudge: @Sendable (String, String) async throws -> Bool
    private var policies = NativeRPCValue.object([]), decisions = NativeRPCValue.object([]), receipts = NativeRPCValue.object([])
    private var loaded = false, busy = false, problem: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(persistence: BackendTaskPersistence, tasks: BackendTaskStore, local: BackendTaskLocalService, access: BackendPCDecisionAccess,
                writer: (@Sendable (NativeRPCValue) throws -> Void)? = nil, finalWorkerValidation: Bool = false,
                finalHootValidation: Bool = false, finalLeadValidation: Bool = false, nudge: @escaping @Sendable (String, String) async throws -> Bool) {
        self.persistence = persistence; self.tasks = tasks; self.local = local; self.access = access; self.writer = writer; self.finalWorkerValidation = finalWorkerValidation
        self.finalHootValidation = finalHootValidation; self.finalLeadValidation = finalLeadValidation; self.nudge = nudge
    }
    public func start() {
        guard !loaded else { return }; loaded = true
        do {
            if let value = try persistence.read("pc-decisions.json", maximumBytes: 16 * 1024 * 1024) {
                guard value["v"].number == 1, value["policies"].fields != nil, value["decisions"].fields != nil, value["receipts"].fields != nil,
                      value["policies"].spreadFields.count <= 100, value["decisions"].spreadFields.count <= 2000, value["receipts"].spreadFields.count <= 5000 else { throw NativeRPCError.malformed("Unsupported decision state") }
                for entry in value["decisions"].spreadFields {
                    guard entry.value["task"].string == entry.key, entry.value["revision"].number != nil, entry.value["proposalRevision"].number != nil,
                          ["draft", "submitted", "approved", "rejected", "changes-requested", "off"].contains(entry.value["state"].string ?? ""), entry.value["history"].elements != nil else { throw NativeRPCError.malformed("Damaged decision record") }
                }
                policies = value["policies"]; decisions = value["decisions"]; receipts = value["receipts"]
            }
        } catch { problem = "Required decision storage is unreadable. Its files were kept; opted-in work is held." }
    }
    private func flush() throws {
        let value = NativeRPCValue.object([.init("v", .number(1)), .init("policies", policies), .init("decisions", decisions), .init("receipts", receipts)])
        let bytes = try value.encodedJSON()
        guard bytes.count <= 16 * 1024 * 1024 else { throw NativeRPCError(code: "decision-storage-full", message: "Decision history reached its 16 MB limit. Nothing was released.") }
        if let writer { try writer(value) } else { try persistence.writeBytes("pc-decisions.json", data: bytes) }
    }
    public func heldReason(_ task: BackendTaskRecord) -> String? {
        let required = PCDecisions.requires(task.value), record = decisions[task.id]
        guard required || record["required"].bool == true else { return nil }
        guard loaded, problem == nil else { return problem ?? "Required decision storage is not ready; work is held." }
        guard required, task.value["decisionRequired"].bool == true, record.fields != nil,
              record["id"] == task.value["decisionID"], record["policy"] == task.value["decisionPolicyID"], record["required"].bool == true else { return "The required decision binding is missing or inconsistent; work is held." }
        let policy = policies[record["policy"].string ?? ""]
        guard policy["revision"] == record["policyRevision"], policy["mode"].string == "owner-before-start" else { return "The workflow changed; the owner must bind and review the current workflow." }
        guard record["scope"].string == BackendPCDecisionMarker.fingerprint(task) else { return "The task scope changed. Save and submit a new proposal before it can start." }
        guard record["state"].string == "approved" else { return "Business decision: " + (record["state"].string ?? "missing proposal") + ". Waiting for owner review." }
        guard record["approvedProposal"] == record["proposalRevision"], record["approvedScope"] == record["scope"] else { return "Approval no longer matches this proposal and scope; submit it for review again." }
        guard record["released"].bool == true else { return "Approved; waiting for the owner's explicit Start approved work choice." }
        return nil
    }
    private func review(_ record: NativeRPCValue, task: BackendTaskRecord) -> NativeRPCValue {
        guard record.fields != nil else { return .null }
        return .object(["proposalRevision", "title", "body", "rationale", "scope"].map { .init($0, record[$0]) } + [.init("taskTitle", task.value["title"]), .init("taskInstructions", task.value["instructions"]), .init("project", .string(task.project)), .init("assignee", task.value["assignee"])])
    }
    private func view(_ task: BackendTaskRecord) -> NativeRPCValue {
        let rows = policies.spreadFields.map(\.value).filter { $0["project"].string == task.project }
        return .object([.init("ok", .bool(true)), .init("ownerReview", review(decisions[task.id], task: task)), .init("task", .string(task.id)), .init("eligible", .bool(PCDecisions.eligible(task.value))),
            .init("bindable", .bool((task.value["decisionEligible"].bool == true || PCDecisions.requires(task.value)) && task.assigneeKind == "none" && task.sessionID == nil && !["running", "queued", "setup"].contains(task.process))), .init("policies", .array(rows)), .init("decision", decisions[task.id].isNullish ? .null : decisions[task.id]),
            .init("held", heldReason(task).map(NativeRPCValue.string) ?? .null), .init("problem", problem.map(NativeRPCValue.string) ?? .null),
            .init("executionOwners", .array([("agent", finalWorkerValidation), ("hoot", finalHootValidation), ("seat", finalLeadValidation)].filter { $0.1 }.map { .string($0.0) })),
            .init("executionCapability", .string(finalWorkerValidation || finalHootValidation || finalLeadValidation ? "Only the listed final-validated execution owners may execute released work." : "Production opted-in work is held: final execution validation unavailable. NEEDS-HELPER."))])
    }
    private func task(_ id: String, allowIneligible: Bool = false) async throws -> BackendTaskRecord {
        guard let task = try await tasks.byID(id), allowIneligible || PCDecisions.eligible(task.value) else { throw NativeRPCError(code: "decision-local-only", message: "Business decisions apply only to standalone local tasks. Connected and CRM tasks keep their existing flow.") }; return task
    }
    public func perform(_ action: String, args: NativeRPCValue, call: BackendPCDecisionCall) async throws -> NativeRPCValue {
        guard loaded, PCDecisions.actions.contains(action) else { throw NativeRPCError.invalidArguments("That business-decision action is unavailable.") }
        if action == "policy" || action == "get" && args["project"].string != nil {
            return try await projectWorkflow(action, args: args, call: call)
        }
        let id = try args["task"].requireString("task", nonempty: true), initial = try await task(id, allowIneligible: action == "get"), mutation = action != "get"
        let author = try await access.verify(call, initial, mutation)
        if !mutation { return PCDecisions.eligible(initial.value) ? view(initial) : .object([.init("ok", .bool(true)), .init("eligible", .bool(false))]) }
        try persistence.writable()
        guard problem == nil else { throw NativeRPCError(code: "decision-unavailable", message: problem ?? "Required decision storage is not ready.") }
        let request = try PCDecisions.text(args["request"], label: "Request id", limit: 128)
        let receiptKey = id + ":" + action + ":" + request
        let savedReceipt = receipts[receiptKey]
        if !savedReceipt.isNullish {
            guard savedReceipt["args"] == args else { throw NativeRPCError(code: "decision-request-conflict", message: "That request id was already used for different arguments.") }
            if savedReceipt["status"].string != "creating" {
                let savedTask = try await task(savedReceipt["result"]["task"].string ?? id)
                _ = try await access.verify(call, savedTask, false)
                return view(savedTask).setting("started", .bool(false)).setting("replayed", .bool(true))
            }
        }
        let expected = try PCDecisions.count(args["expected"], key: "expected")
        let prior = decisions[id]
        guard expected == Int(prior["revision"].number ?? 0) else { throw NativeRPCError(code: "decision-stale", message: "The decision changed. Refresh before saving.") }
        let ownerAction = PCDecisions.ownerActions.contains(action)
        if ownerAction {
            if !["policy", "bind", "create"].contains(action) {
                _ = try PCDecisions.next(prior["state"].string ?? "draft", action: action)
                guard prior["scope"].string == BackendPCDecisionMarker.fingerprint(initial) else { throw NativeRPCError(code: "decision-stale", message: "Task scope changed. Save and submit a revised proposal before owner review.") }
                if ["changes", "reject"].contains(action) { _ = try PCDecisions.text(args["text"], label: "Decision reason", limit: 4000) }
            }
            if case .tool = call, prior.fields != nil, !["policy", "bind", "create"].contains(action) {
                let currentReview = review(prior, task: initial)
                guard currentReview.spreadFields.allSatisfy({ args["review"][$0.key] == $0.value }) else { throw NativeRPCError(code: "decision-review-needed", message: "Read decisions.get and include its exact ownerReview as review, so the person sees the current proposal before deciding.") }
            }
            let summary = args.setting("_taskTitle", initial.value["title"]).setting("_project", .string(initial.project))
                .setting("_workflowName", policies[args["policy"].string ?? ""]["name"])
            try await access.owner(call, action, summary)
        }
        // Review paperclip #6: the save lock is taken only after the owner's answer, so an open owner prompt never
        // blocks other decisions; what was read before the wait is rechecked under the lock.
        // #338: a decision that arrives while another saves waits its turn instead of being refused.
        await enter(); defer { leave() }
        guard problem == nil else { throw NativeRPCError(code: "decision-unavailable", message: problem ?? "Required decision storage is not ready.") }
        guard receipts[receiptKey] == savedReceipt, decisions[id] == prior else { throw NativeRPCError(code: "decision-stale", message: "The decision changed while the owner answered. Refresh and ask again.") }
        let checked = try await task(id)
        let verifiedAuthor = try await access.verify(call, checked, true)
        let current = try await task(id)
        guard verifiedAuthor == author, BackendPCDecisionMarker.fingerprint(current) == BackendPCDecisionMarker.fingerprint(initial), decisions[id] == prior else { throw NativeRPCError(code: "decision-stale", message: "The task or caller changed during review. Refresh and ask again.") }
        var old = (policies, decisions, receipts)
        var result: NativeRPCValue
        var target = current
        var release = false, clearMarker = false, capabilityHeld = false
        do {
            if action == "create" {
                let policyID = try args["policy"].requireString("policy"), policy = policies[policyID]
                guard policy["project"].string == current.project, policy["mode"].string == "owner-before-start" else { throw NativeRPCError.invalidArguments("Choose a required workflow in this task's project.") }
                let intent: NativeRPCValue
                if savedReceipt["status"].string == "creating" { intent = savedReceipt }
                else {
                    intent = .object([.init("args", args), .init("status", .string("creating")), .init("operation", .string(UUID().uuidString.lowercased())), .init("decision", .string(UUID().uuidString.lowercased()))])
                    receipts = receipts.setting(receiptKey, intent); try flush(); old = (policies, decisions, receipts)
                }
                let matches = try await tasks.all(includeTrash: true).filter { $0.value["decisionCreateRequest"] == intent["operation"] }
                guard matches.count <= 1 else { throw NativeRPCError(code: "decision-create-incomplete", message: "This creation request has conflicting task records. No second task was created.") }
                if let found = matches.first {
                    target = try await task(found.id)
                    _ = try await access.verify(call, target, true)
                } else {
                    guard savedReceipt.isNullish else { throw NativeRPCError(code: "decision-create-incomplete", message: "This creation request was interrupted. No matching task can be proven; inspect it before using a new request id.") }
                    target = try await local.create(.object([.init("title", current.value["title"]), .init("instructions", current.value["instructions"]), .init("project", .string(current.project)), .init("assignee", .string("none"))]), by: author,
                        decisionBinding: .object([.init("id", intent["decision"]), .init("policy", policy["id"]), .init("operation", intent["operation"])]))
                }
                target = try await bind(target, policy: policy, author: author, decisionID: intent["decision"].string)
            } else if action == "bind" {
                guard (current.value["decisionEligible"].bool == true || PCDecisions.requires(current.value)), current.assigneeKind == "none", current.sessionID == nil, !["running", "queued", "setup"].contains(current.process) else { throw NativeRPCError(code: "decision-bind-refused", message: "Only a never-dispatched, unassigned task can change workflow. Use New task in this workflow to make a safely bound copy.") }
                if let policyID = args["policy"].string {
                    let policy = policies[policyID]
                    guard policy["project"].string == current.project, policy["mode"].string == "owner-before-start" else { throw NativeRPCError.invalidArguments("Choose a required workflow in this project.") }
                    target = try await bind(current, policy: policy, author: author)
                } else {
                    clearMarker = true
                    decisions = decisions.setting(id, prior.setting("required", .bool(false)).setting("state", .string("off")).setting("revision", .number(Double(expected + 1))))
                }
            } else {
                guard prior.fields != nil, prior["required"].bool == true, current.value["decisionID"] == prior["id"] else { throw NativeRPCError.invalidArguments("Bind this task to a required workflow first.") }
                if action == "release" {
                    guard prior["released"].bool != true else { throw NativeRPCError(code: "decision-already-released", message: "This revision was already released. Refresh its task state.") }
                    guard prior["approvedProposal"] == prior["proposalRevision"], prior["approvedScope"] == prior["scope"] else { throw NativeRPCError(code: "decision-stale", message: "The approval no longer matches this proposal.") }
                }
                if action == "submit" {
                    _ = try PCDecisions.text(prior["title"], label: "Proposal title", limit: 300)
                    _ = try PCDecisions.text(prior["body"], label: "Proposal", limit: 20_000)
                }
                let state = prior["state"].string ?? "draft", next = try PCDecisions.next(state, action: action)
                var record = prior
                let note = try PCDecisions.text(args["text"], label: "Discussion/reason", limit: 4000, required: ["comment", "changes", "reject"].contains(action))
                if action == "draft" {
                    let title = try PCDecisions.text(args["title"], label: "Proposal title", limit: 300)
                    let body = try PCDecisions.text(args["body"], label: "Proposal", limit: 20_000)
                    let rationale = try PCDecisions.text(args["rationale"], label: "Rationale", limit: 8000, required: false)
                    record = record.setting("title", .string(title)).setting("body", .string(body)).setting("rationale", .string(rationale))
                        .setting("proposalRevision", .number((prior["proposalRevision"].number ?? 0) + 1))
                } else if action != "comment" {
                    guard prior["scope"].string == BackendPCDecisionMarker.fingerprint(current) else { throw NativeRPCError(code: "decision-stale", message: "The task scope changed. Save a revised proposal, then submit it again.") }
                }
                if action != "comment" {
                    target = try await tasks.decisionMarker(id, policy: prior["policy"].string, decision: prior["id"].string, required: true, expected: BackendPCDecisionMarker.fingerprint(current))
                    record = record.setting("scope", .string(BackendPCDecisionMarker.fingerprint(target)))
                }
                record = record.setting("state", .string(next)).setting("revision", .number(Double(expected + 1)))
                if action != "comment" { record = record.setting("released", .bool(false)) }
                if action == "approve" || action == "approve-start" { record = record.setting("approvedProposal", record["proposalRevision"]).setting("approvedScope", record["scope"]) }
                if action == "release" || action == "approve-start" {
                    guard action == "approve-start" || prior["released"].bool != true else { throw NativeRPCError(code: "decision-already-released", message: "This revision was already released. Refresh to see whether it started.") }
                    guard target.value["stopped"].bool != true, target.value["archivedAt"].isNullish, target.value["completedAt"].isNullish, target.value["result"].isNullish, target.sessionID == nil else { throw NativeRPCError(code: "decision-stopped", message: "Approved work is stopped, archived, finished or already active. It was not reopened.") }
                    let capable = target.assigneeKind == "agent" ? finalWorkerValidation : target.assigneeKind == "hoot" ? finalHootValidation : target.assigneeKind == "seat" ? finalLeadValidation : false
                    if capable {
                        record = record.setting("released", .bool(true)).setting("approvedScope", record["scope"])
                        release = true
                    } else { capabilityHeld = true }
                }
                let event = NativeRPCValue.object([.init("action", .string(action)), .init("by", .string(ownerAction ? "owner" : author)), .init("at", .number(BackendTaskValues.time())), .init("text", .string(note)), .init("proposalRevision", record["proposalRevision"]), .init("title", record["title"]), .init("body", record["body"]), .init("rationale", record["rationale"])])
                let history = prior["history"].elements ?? []
                guard history.count < 200 else { throw NativeRPCError.invalidArguments("This decision history is full. Preserve it and create a new workflow task.") }
                record = record.setting("history", .array(history + [event])); decisions = decisions.setting(id, record)
            }
            result = view(target).setting("started", .bool(false)).setting("task", .string(target.id))
            if receipts.spreadFields.count >= Self.receiptLimit { try await pruneFinished(); trimReceipts(keeping: receiptKey) }
            receipts = receipts.setting(receiptKey, .object([.init("args", args), .init("result", result), .init("at", .number(BackendTaskValues.time()))])); guard receipts.spreadFields.count <= Self.receiptLimit else { throw NativeRPCError.invalidArguments("Decision request history is full.") }
            try flush()
        } catch {
            (policies, decisions, receipts) = old
            if action == "create", target.id != current.id {
                throw NativeRPCError(code: "decision-create-incomplete", message: "The unassigned workflow task " + target.id + " is held. Retry this same request id to finish its binding; no second task will be created.", details: .object([.init("task", .string(target.id)), .init("request", .string(request))]))
            }
            throw error
        }
        if clearMarker {
            // State and receipt must be durable before removing the fail-closed marker.
            // A failed marker write leaves the old requirement in place.
            target = try await tasks.decisionMarker(id, policy: nil, decision: nil, required: false, expected: BackendPCDecisionMarker.fingerprint(current))
            result = view(target).setting("started", .bool(false))
        }
        if capabilityHeld { result = result.setting("held", .string("Approved but held: final execution validation unavailable. Release permission was not stored. NEEDS-HELPER.")).setting("started", .bool(false)) }
        if release {
            // Scope and approval are re-read by the real engine. A stopped task
            // is never reopened, and unavailable production hooks remain held.
            let started = (try? await nudge(target.id, receiptKey)) ?? false
            let latest = try await task(target.id)
            result = view(latest).setting("started", .bool(started))
            if !started { result = result.setting("held", .string("Approved but held: final execution validation unavailable, task changed, or its owner is not eligible to start. NEEDS-HELPER.")) }
        }
        return result
    }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
    /// Workflows belong to projects. Task revisions never participate in their saves.
    private func projectWorkflow(_ action: String, args: NativeRPCValue, call: BackendPCDecisionCall) async throws -> NativeRPCValue {
        let project: String
        if let folder = args["project"].string {
            guard !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("Choose a project.") }
            project = folder
            try await access.project(call, project, action == "policy")
        } else {
            let source = try await task(try args["task"].requireString("task"))
            _ = try await access.verify(call, source, action == "policy")
            project = source.project
        }
        func result() -> NativeRPCValue {
            .object([.init("ok", .bool(true)), .init("project", .string(project)), .init("policies", .array(policies.spreadFields.map(\.value).filter { $0["project"].string == project }))])
        }
        if action == "get" { return result() }
        try persistence.writable()
        guard problem == nil else { throw NativeRPCError(code: "decision-unavailable", message: problem ?? "Workflow storage is unavailable.") }
        let request = try PCDecisions.text(args["request"], label: "Request id", limit: 128)
        let key = "project:" + project + ":policy:" + request
        if !receipts[key].isNullish {
            guard receipts[key]["args"] == args else { throw NativeRPCError(code: "decision-request-conflict", message: "That request id was already used for different arguments.") }
            return result().setting("replayed", .bool(true))
        }
        let id = args["policy"].string ?? UUID().uuidString.lowercased(), prior = policies[id]
        let revision = try PCDecisions.count(args["policyExpected"], key: "policyExpected")
        guard revision == Int(prior["revision"].number ?? 0) else { throw NativeRPCError(code: "decision-stale", message: "The workflow changed. Refresh first.") }
        let name = try PCDecisions.text(args["name"], label: "Workflow name", limit: 120), mode = args["mode"].string ?? "off"
        guard ["off", "owner-before-start"].contains(mode) else { throw NativeRPCError.invalidArguments("A workflow is off or owner-before-start.") }
        try await access.owner(call, "policy", args.setting("_project", .string(project)).setting("_workflowName", .string(name)))
        await enter(); defer { leave() }
        guard problem == nil, policies[id] == prior, receipts[key].isNullish else { throw NativeRPCError(code: "decision-stale", message: "The workflow changed during review. Refresh first.") }
        if args["project"].string != nil { try await access.project(call, project, true) }
        else {
            let source = try await task(try args["task"].requireString("task"))
            _ = try await access.verify(call, source, true)
            guard source.project == project else { throw NativeRPCError(code: "decision-stale", message: "The project changed during review. Refresh first.") }
        }
        guard policies.spreadFields.count < 100 || prior.fields != nil, prior.isNullish || prior["project"].string == project else { throw NativeRPCError.invalidArguments("That workflow is outside this project or its limit.") }
        guard !decisions.spreadFields.contains(where: { $0.value["policy"].string == id && $0.value["required"].bool == true }) else { throw NativeRPCError(code: "decision-policy-bound", message: "This workflow is bound to tasks. Create a new named workflow, then deliberately bind unassigned tasks to it.") }
        let old = (policies, receipts)
        do {
            policies = policies.setting(id, .object([.init("id", .string(id)), .init("project", .string(project)), .init("name", .string(name)), .init("mode", .string(mode)), .init("revision", .number(Double(revision + 1)))]))
            trimReceipts(keeping: key)
            receipts = receipts.setting(key, .object([.init("args", args), .init("at", .number(BackendTaskValues.time()))]))
            try flush()
        } catch { (policies, receipts) = old; throw error }
        return result()
    }
    static let receiptLimit = 5000, decisionLimit = 2000
    /// Review paperclip #7: the lifetime caps no longer wedge the feature. Records and receipts of finished or
    /// missing tasks are dropped (a reopened task keeps its marker and stays held, so nothing runs unreviewed).
    private func pruneFinished() async throws {
        var open = Set<String>()
        for task in try await tasks.all(includeTrash: true) where task.value["result"].isNullish && task.value["completedAt"].isNullish { open.insert(task.id) }
        decisions = .object(decisions.spreadFields.filter { open.contains($0.key) })
        receipts = .object(receipts.spreadFields.filter { field in
            field.value["status"].string == "creating" || open.contains(field.value["args"]["task"].string ?? "") || open.contains(field.value["result"]["task"].string ?? "")
        })
    }
    /// Then the oldest finished receipts go: a replayed old request id still meets the revision check, so nothing runs twice.
    private func trimReceipts(keeping key: String) {
        let rows = receipts.spreadFields
        guard rows.count >= Self.receiptLimit else { return }
        let dropped = Set(rows.filter { $0.value["status"].string != "creating" && $0.key != key }
            .sorted { ($0.value["at"].number ?? 0) < ($1.value["at"].number ?? 0) }
            .prefix(rows.count - Self.receiptLimit * 4 / 5).map(\.key))
        receipts = .object(rows.filter { !dropped.contains($0.key) })
    }
    private func bind(_ task: BackendTaskRecord, policy: NativeRPCValue, author: String, decisionID: String? = nil) async throws -> BackendTaskRecord {
        if decisions.spreadFields.count >= Self.decisionLimit { try await pruneFinished() }
        guard decisions.spreadFields.count < Self.decisionLimit else { throw NativeRPCError.invalidArguments("Decision storage is full.") }
        let id = decisionID ?? UUID().uuidString.lowercased(), marked = try await tasks.decisionMarker(task.id, policy: policy["id"].string, decision: id, required: true, expected: BackendPCDecisionMarker.fingerprint(task))
        let existing = decisions[task.id]
        decisions = decisions.setting(task.id, .object([.init("id", .string(id)), .init("task", .string(task.id)), .init("policy", policy["id"]), .init("policyRevision", policy["revision"]),
            .init("required", .bool(true)), .init("revision", .number((existing["revision"].number ?? 0) + 1)), .init("proposalRevision", .number(1)), .init("state", .string("draft")),
            .init("title", task.value["title"]), .init("body", task.value["instructions"]), .init("rationale", .string("")), .init("scope", .string(BackendPCDecisionMarker.fingerprint(marked))), .init("released", .bool(false)),
            .init("history", .array((existing["history"].elements ?? []) + [.object([.init("action", .string("bind")), .init("by", .string(author)), .init("at", .number(BackendTaskValues.time()))])]))]))
        return marked
    }
}
