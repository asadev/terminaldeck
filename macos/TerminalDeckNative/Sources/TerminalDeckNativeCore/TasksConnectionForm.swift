import Foundation

// MARK: - The connection form

/// A connection while it is being typed. Lists are one entry per line.
public struct ConnectionDraft: Equatable, Sendable {
    public struct Identity: Equatable, Sendable {
        public var identity: String
        public var agentId: String
        public init(identity: String, agentId: String) {
            self.identity = identity
            self.agentId = agentId
        }
    }

    public var name: String
    public var eventsUrl: String
    public var hootIdentity: String
    public var allowedSenders: String
    public var folders: String
    public var maxHops: String
    public var identities: [Identity]
    public var statuses: String
    public var initial: String
    public var completed: String
    public var onStarted: String
    public var onVerified: String
    public var onBlocked: String
    public var projectID: String

    public init(_ connection: CrmConnection) {
        let s = connection.statuses
        projectID = connection.projectID
        name = connection.name ?? ""
        eventsUrl = connection.eventsUrl ?? ""
        hootIdentity = connection.hootIdentity ?? ""
        allowedSenders = connection.allowedSenders.joined(separator: "\n")
        folders = connection.folders.joined(separator: "\n")
        maxHops = String(connection.maxHops)
        identities = connection.identityOrder.map { Identity(identity: $0, agentId: connection.identities[$0] ?? "") }
        statuses = s.statuses.joined(separator: "\n")
        initial = s.initial
        completed = s.completed
        onStarted = s.onStarted ?? ""
        onVerified = s.onVerified ?? ""
        onBlocked = s.onBlocked ?? ""
    }
}

public enum ConnectionForm {
    /// Lines of a list box: trimmed, blanks dropped, repeats dropped.
    public static func lines(_ raw: String) -> [String] {
        var out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !out.contains(trimmed) { out.append(trimmed) }
        }
        return out
    }

    /// The statuses part of the patch, as `StatusConfig` (for tests and the wire).
    public struct Patch: Sendable {
        public var name: String?
        public var eventsUrl: String?
        public var hootIdentity: String?
        public var allowedSenders: [String]
        public var folders: [String]
        public var maxHops: Int
        public var identities: [String: String]
        public var statuses: StatusConfig
        public var projectID: String = PROJProjects.independentID

        public var wire: [String: Any] {
            ["name": orNullValue(name), "eventsUrl": orNullValue(eventsUrl), "hootIdentity": orNullValue(hootIdentity),
             "allowedSenders": allowedSenders, "folders": folders, "maxHops": maxHops, "identities": identities,
             "statuses": statuses.wire, "projectId": projectID]
        }
    }

    /// The patch `tasks:connection-save` is sent for the form's fields, or what to fix first.
    public static func patch(_ draft: ConnectionDraft) -> Result<Patch, TasksProblem> {
        let maxHops: Int
        switch AgentForm.whole(draft.maxHops, field: "The hand-off limit", min: 1, max: TasksLimits.maxHops,
                               fallback: TasksLimits.defaultHops) {
        case .failure(let problem): return .failure(problem)
        case .success(let value): maxHops = value
        }
        let statuses = lines(draft.statuses)
        if statuses.isEmpty { return .failure(TasksProblem("Name at least one CRM status.")) }
        func pick(_ value: String, _ fallback: String) -> String { statuses.contains(value) ? value : fallback }
        func optional(_ value: String) -> String? { statuses.contains(value) ? value : nil }
        var identities: [String: String] = [:]
        for row in draft.identities {
            let identity = row.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            if identity.isEmpty && row.agentId.isEmpty { continue }
            if identity.isEmpty { return .failure(TasksProblem("Each agent identity needs its CRM identity id.")) }
            if row.agentId.isEmpty { return .failure(TasksProblem("Choose which agent \(identity) is.")) }
            identities[identity] = row.agentId
        }
        return .success(Patch(
            name: AgentForm.orNil(draft.name), eventsUrl: AgentForm.orNil(draft.eventsUrl),
            hootIdentity: AgentForm.orNil(draft.hootIdentity), allowedSenders: lines(draft.allowedSenders),
            folders: lines(draft.folders), maxHops: maxHops, identities: identities,
            statuses: StatusConfig(statuses: statuses, initial: pick(draft.initial, statuses[0]),
                                   completed: pick(draft.completed, statuses[statuses.count - 1]),
                                   onStarted: optional(draft.onStarted), onVerified: optional(draft.onVerified),
                                   onBlocked: optional(draft.onBlocked)), projectID: draft.projectID))
    }
}
