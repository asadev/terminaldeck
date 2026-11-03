import Foundation

// MARK: - Decoding

public enum TasksDecode {
    private typealias J = TasksJSON

    public static func inventory(_ raw: Any?) -> AgentInventory? {
        guard let r = J.record(raw), let tools = r["tools"] as? [Any], let skills = r["skills"] as? [Any] else { return nil }
        func choices(_ list: [Any]) -> [InventoryChoice] {
            list.compactMap { entry in
                let e = J.record(entry)
                guard let value = J.text(e?["value"]) else { return nil }
                return InventoryChoice(value: value, label: J.text(e?["label"]) ?? value, where: J.text(e?["where"]) ?? "")
            }
        }
        return AgentInventory(account: J.text(r["account"]) ?? "Default", tools: choices(tools), skills: choices(skills))
    }

    static func agent(_ raw: Any?) -> AgentProfile? {
        guard let r = J.record(raw), let id = J.text(r["id"]), let name = J.text(r["name"]) else { return nil }
        let status: AgentStatus
        if r["status"] == nil {
            status = .active
        } else if let raw = r["status"] as? String, let known = AgentStatus(rawValue: raw) {
            status = known
        } else {
            // Never guessed into taking work: a status this build does not know reads as paused.
            status = .paused
        }
        return AgentProfile(
            id: id, name: name, role: J.text(r["role"]) ?? "general", provider: J.text(r["provider"]),
            account: J.text(r["account"]), model: J.text(r["model"]), effort: J.text(r["effort"]),
            instructions: J.text(r["instructions"]), instructionsFile: J.text(r["instructionsFile"]),
            toolsPreferred: J.strings(r["toolsPreferred"]), toolsAvoided: J.strings(r["toolsAvoided"]),
            skills: J.strings(r["skills"]), blockedTools: J.strings(r["blockedTools"]), skillsOff: J.isTrue(r["skillsOff"]),
            maxConcurrent: J.int(r["maxConcurrent"], 0), maxRunMinutes: J.int(r["maxRunMinutes"], TasksLimits.defaultRunMinutes),
            keepAliveMinutes: J.int(r["keepAliveMinutes"], TasksLimits.defaultKeepAliveMinutes),
            verifyCommand: J.text(r["verifyCommand"]), status: status, statusAt: J.number(r["statusAt"]),
            claudeAgent: J.text(r["claudeAgent"]), allowedTools: r["allowedTools"] is [Any] ? J.strings(r["allowedTools"]) : nil,
            permissionMode: J.text(r["permissionMode"]), keepAliveUntilClose: J.bool(r["keepAliveUntilClose"]),
            defaultProject: J.text(r["defaultProject"]), reviewerAgent: J.text(r["reviewerAgent"]),
            sourceFile: J.text(r["sourceFile"]), sourceDirectory: J.text(r["sourceDirectory"]), syncedAt: J.number(r["syncedAt"]),
            syncStatus: J.text(r["syncStatus"]), syncError: J.text(r["syncError"]),
            icon: J.text(r["icon"]), reportsTo: J.text(r["reportsTo"]), projectID: J.text(r["projectId"]), projectIdInferred: J.isTrue(r["projectIdInferred"]),
            seat: J.text(r["seat"]), toolUseRestrictions: (r["toolUseRestrictions"] == nil || r["toolUseRestrictions"] is NSNull) ? nil : try? NativeRPCValue.fromFoundation(r["toolUseRestrictions"]))
    }

    static func statuses(_ raw: Any?) -> StatusConfig {
        let r = J.record(raw)
        let list = J.strings(r?["statuses"])
        guard r != nil, !list.isEmpty else { return DEFAULT_CRM_STATUSES }
        return StatusConfig(statuses: list, initial: J.text(r?["initial"]) ?? list[0],
                            completed: J.text(r?["completed"]) ?? list[list.count - 1],
                            onStarted: J.text(r?["onStarted"]), onVerified: J.text(r?["onVerified"]),
                            onBlocked: J.text(r?["onBlocked"]))
    }

    static func connection(_ raw: Any?) -> CrmConnection? {
        guard let r = J.record(raw), let keyId = J.text(r["keyId"]) else { return nil }
        var identities: [String: String] = [:]
        var order: [String] = []
        if let map = J.record(r["identities"]) {
            for (identity, agentId) in map.sorted(by: { $0.key < $1.key }) {
                if let agentId = agentId as? String {
                    identities[identity] = agentId
                    order.append(identity)
                }
            }
        }
        return CrmConnection(
            keyId: keyId, name: J.text(r["name"]),
            // Only a literal true draws it on: a connection that decides who can run
            // agents here must never be guessed into being switched on.
            enabled: J.isTrue(r["enabled"]), eventsUrl: J.text(r["eventsUrl"]), hasEventsSecret: J.isTrue(r["hasEventsSecret"]),
            statuses: statuses(r["statuses"]), hootIdentity: J.text(r["hootIdentity"]), identities: identities,
            identityOrder: order, allowedSenders: J.strings(r["allowedSenders"]), folders: J.strings(r["folders"]),
            maxHops: J.int(r["maxHops"], TasksLimits.defaultHops), projectID: PROJProjects.resolve(projectID: J.text(r["projectId"]), folder: J.strings(r["folders"]).first))
    }

    static func note(_ raw: Any?) -> TaskNote? {
        guard let r = J.record(raw), let text = r["text"] as? String else { return nil }
        return TaskNote(at: J.count(r["at"], 0), by: J.text(r["by"]) ?? "", kind: J.text(r["kind"]) ?? "progress", text: text)
    }

    static func stall(_ raw: Any?) -> TaskStall? {
        guard let r = J.record(raw), let text = r["text"] as? String else { return nil }
        return TaskStall(at: J.count(r["at"], 0), reason: (r["reason"] as? String) == "exited" ? .exited : .quiet, text: text)
    }

    public static func task(_ raw: Any?) -> TaskRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let process: ProcessState = {
            switch r["process"] as? String {
            case "running": .running
            case "exited": .exited
            case "idle": .idle
            default: .queued
            }
        }()
        return TaskRow(
            id: id, keyId: J.text(r["keyId"]) ?? "", externalTaskId: J.text(r["externalTaskId"]) ?? "",
            title: J.text(r["title"]) ?? "Untitled task", agent: J.text(r["agent"]) ?? BRAND_ASSISTANT,
            project: J.text(r["project"]) ?? "", crmStatus: r["crmStatus"] as? String ?? "", process: process,
            keepOpenUntil: J.number(r["keepOpenUntil"]), verified: J.bool(r["verified"]),
            updatedAt: J.count(r["updatedAt"], 0), local: J.isTrue(r["local"]), assignee: J.text(r["assignee"]) ?? "none",
            instructions: r["instructions"] as? String ?? "", handedFrom: J.text(r["handedFrom"]),
            notes: (r["notes"] as? [Any] ?? []).compactMap(note), priority: J.text(r["priority"]),
            startDate: J.text(r["startDate"]), dueDate: J.text(r["dueDate"]), startTime: J.text(r["startTime"]),
            dueTime: J.text(r["dueTime"]), labels: J.strings(r["labels"]), board: J.text(r["board"]),
            taskType: (r["taskType"] as? String) == "milestone" ? "milestone" : "task",
            estimateMinutes: J.number(r["estimateMinutes"]), archivedAt: J.number(r["archivedAt"]),
            deletedAt: J.number(r["deletedAt"]), completedAt: J.number(r["completedAt"]), position: J.number(r["position"]),
            recurrence: J.text(r["recurrence"]), goalId: J.text(r["goalId"]), useWorkspace: J.isTrue(r["useWorkspace"]),
            stalled: stall(r["stalled"]), waitingOn: J.strings(r["waitingOn"]), createdAt: J.count(r["createdAt"], 0),
            keepAliveUntilClose: J.bool(r["keepAliveUntilClose"]), parentTaskId: J.text(r["parentTaskId"]),
            parentExternalTaskId: J.text(r["parentExternalTaskId"]), reviewerTaskId: J.text(r["reviewerTaskId"]),
            reviewOfTaskId: J.text(r["reviewOfTaskId"]), projectID: J.text(r["projectId"]))
    }

    static func goal(_ raw: Any?) -> GoalRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let p = J.record(r["progress"]) ?? [:]
        let status = (r["status"] as? String).flatMap(GoalStatus.init(rawValue:)) ?? .active
        return GoalRow(
            id: id, title: J.text(r["title"]) ?? "Untitled goal", description: r["description"] as? String ?? "",
            status: status, parentId: J.text(r["parentId"]), project: J.text(r["project"]),
            progress: GoalProgress(total: J.int(p["total"], 0), done: J.int(p["done"], 0), verified: J.int(p["verified"], 0),
                                   unverified: J.int(p["unverified"], 0), stalled: J.int(p["stalled"], 0),
                                   blocked: J.int(p["blocked"], 0)), projectID: J.text(r["projectId"]))
    }

    public static func state(_ raw: Any?) -> TasksState? {
        guard let r = J.record(raw), let agents = r["agents"] as? [Any], let connections = r["connections"] as? [Any] else {
            return nil
        }
        let outbox = J.record(r["outbox"]) ?? [:]
        let localStatuses = J.strings(r["localStatuses"])
        return TasksState(
            agents: agents.compactMap(agent),
            connections: connections.compactMap(connection),
            keys: (r["keys"] as? [Any] ?? []).compactMap { key in
                let k = J.record(key)
                guard let id = J.text(k?["id"]) else { return nil }
                return TasksKey(id: id, name: J.text(k?["name"]) ?? id, crmOnly: J.isTrue(k?["crmOnly"]), lastApp: J.text(k?["lastApp"]))
            },
            tasks: (r["tasks"] as? [Any] ?? []).compactMap(task),
            trash: (r["trash"] as? [Any] ?? []).compactMap(task),
            outbox: (J.int(outbox["pending"], 0), J.int(outbox["undelivered"], 0)),
            localStatuses: localStatuses.isEmpty ? DEFAULT_CRM_STATUSES.statuses : localStatuses,
            goals: (r["goals"] as? [Any] ?? []).compactMap(goal))
    }

    public static func result(_ raw: Any?) -> TasksResult {
        let r = J.record(raw)
        let ok = J.isTrue(r?["ok"])
        return TasksResult(
            ok: ok,
            message: J.text(r?["message"]) ?? (ok ? nil : "That did not go through, and the app did not say why."),
            state: state(r?["state"]),
            secret: ok ? J.text(r?["secret"]) : nil,
            key: ok ? J.text(r?["key"]) : nil)
    }
}
