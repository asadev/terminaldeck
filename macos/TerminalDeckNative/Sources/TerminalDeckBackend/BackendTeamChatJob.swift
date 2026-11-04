import Foundation
import TerminalDeckNativeCore

/// The two sides and the one job. History lives beside this job's existing chat file.
public struct BackendTeamChatJob: Codable, Equatable, Sendable {
    public var fromID: String
    public var fromName: String
    public var agentID: String
    public var agentName: String
    public var title: String
    public var taskID: String?
    /// The actual starter session, rather than the seat's reusable profile ID.
    public var starterSessionID: String? = nil
    /// Set only by the checked Resume action. The launcher grants a fresh tool lease.
    public var resumedFromSessionID: String? = nil
    /// 30 Oct (Decker): the job stays open when a turn ends (a seat with background work still running); the starter
    /// ends it with finish or stop. nil: the delivered answer closes the job, as before.
    public var keepOpen: Bool? = nil
    public init(fromID: String, fromName: String, agentID: String, agentName: String, title: String, taskID: String? = nil) {
        self.fromID = fromID; self.fromName = fromName; self.agentID = agentID; self.agentName = agentName
        self.title = title; self.taskID = taskID
    }
    public var sessionTitle: String { fromName + " → " + agentName + " · " + title }
}

public struct BackendTeamChatRecord: Codable, Equatable, Sendable {
    public var session: BackendSessionMeta
    public var job: BackendTeamChatJob
    public var finishedAt: Date?
    public var result: String?
    public var failed: Bool = false
    public var key: String
    /// An existing Hoot task chat keeps its own file and fenced runtime.
    public var historyPath: String? = nil
    public var turnID: String? = nil
    public var cursor: Int? = nil
    public var interruptedAt: Date? = nil
    public var resumedBySessionID: String? = nil
    /// Original launch rules, without executable arguments, environment or credentials.
    /// Never included in the public job summary: an agent's private instructions stay private.
    public var resumeInput: BackendCreateSessionInput? = nil
    public var isFinished: Bool { finishedAt != nil }
    public var canResume: Bool { interruptedAt != nil && resumedBySessionID == nil && historyPath == nil }
    public var resumeHandle: NativeRPCValue {
        guard canResume else { return .null }
        return .object([.init("tool", .string("sessions_conversations")), .init("do", .string("resume")),
            .init("sessionId", .string(session.id))])
    }
    public var restartEvent: NativeRPCValue {
        guard let interruptedAt else { return .null }
        return .object([.init("kind", .string("ended-by-restart")), .init("sessionId", .string(session.id)),
            .init("starterSessionId", job.starterSessionID.map(NativeRPCValue.string) ?? .null),
            .init("starter", .string(job.fromID)), .init("at", .number(interruptedAt.timeIntervalSince1970 * 1000)),
            .init("message", .string("Ended by restart — Resume")), .init("resume", resumeHandle),
            .init("resumedBySessionId", resumedBySessionID.map(NativeRPCValue.string) ?? .null)])
    }
    public var wire: NativeRPCValue {
        var summary = self
        summary.result = result.map { String($0.prefix(1000)) }
        summary.resumeInput = nil
        return ((try? NativeRPCValue.parseJSON(JSONEncoder().encode(summary))) ?? .null)
            .setting("resume", resumeHandle).setting("restartEvent", restartEvent)
    }
}

public enum BackendTeamChatDiary {
    /// Same diary/search store as Hoot. Source keys make incremental replay safe.
    public static func drafts(_ job: BackendTeamChatRecord, snapshot: NativeRPCValue, owner: DeckMemoryOwner) -> [DeckMemoryDiaryDraft] {
        let stamp = DeckMemoryStamp(owner: owner, project: job.session.resolvedProjectID, session: job.session.id,
            agent: job.job.agentID, job: job.job.taskID ?? job.job.title)
        return (snapshot["events"].elements ?? []).compactMap { event in
            guard let text = event["value"]["text"].string, !text.isEmpty else { return nil }
            let kind = event["kind"].string ?? ""
            guard ["user", "message"].contains(kind) else { return nil }
            return DeckMemoryDiaryDraft(stamp: stamp, role: kind == "user" ? .user : .assistant, text: text,
                conversation: job.session.id, turn: event["turnId"].string,
                externalID: "team-chat:" + job.session.id + ":" + String(Int(event["sequence"].number ?? 0)),
                meta: ["from": job.job.fromID, "to": job.job.agentID],
                author: kind == "user" ? (job.job.fromID == "hoot" ? .orchestrator : .agent) : DeckMemoryAuthor.of(owner) ?? .agent)
        }
    }
}

public struct BackendTeamChatSender: Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public static func resolve(caller: BackendDeckCoreSecurityCaller, input: BackendCreateSessionInput?, session: BackendSessionMeta?,
                               owner: DeckMemorySessionOwner?, projects: [PROJProject]) -> Self {
        let ownerName = owner.flatMap { $0.name.isEmpty ? nil : $0.name }
        if caller.kind == .key { return .init(id: "key:" + (caller.keyID ?? "app"), name: caller.keyName ?? "AI app") }
        if let id = input?.agentProfileID ?? input?.agentInstructions {
            return .init(id: id, name: input?.teamJob?.agentName ?? ownerName ?? id)
        }
        if owner?.kind == .lead, let project = projects.first(where: { $0.id == (owner?.project ?? owner?.id) }),
           let lead = AGTSeats.lead(of: project) {
            return .init(id: lead.id, name: lead.name)
        }
        if let id = caller.sessionID { return .init(id: id, name: ownerName ?? session?.title ?? "Agent") }
        return .init(id: "hoot", name: "Hoot")
    }
    public static func request(_ raw: String, agents: [NativeRPCValue] = []) -> Self {
        var id = raw
        for prefix in ["taskagent:", "agent:"] where id.hasPrefix(prefix) { id = String(id.dropFirst(prefix.count)) }
        if id == "hoot" { return .init(id: id, name: "Hoot") }
        if id == "me" { return .init(id: id, name: "You") }
        if let agent = agents.first(where: { $0["id"].string == id }) { return .init(id: id, name: agent["name"].string ?? id) }
        return .init(id: id, name: id)
    }
}
