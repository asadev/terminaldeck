import Foundation
import CryptoKit

public enum AWWatchState: String, CaseIterable, Sendable {
    case working, waiting, idle, queued, finished, offline, unknown
    public var label: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .idle: "Idle"
        case .queued: "Queued"
        case .finished: "Finished"
        case .offline: "Offline"
        case .unknown: "Status unavailable"
        }
    }
    public static func observed(_ raw: String?, connected: Bool = true) -> Self {
        guard connected else { return .offline }
        switch raw {
        case "working", "running", "starting": return .working
        case "waiting", "input", "needs-input", "waiting-human", "blocked": return .waiting
        case "idle", "kept-open": return .idle
        case "queued": return .queued
        case "completed", "exited", "done", "cancelled": return .finished
        default: return .unknown
        }
    }
}

public struct AWWatchAgent: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let kind: String
    public let name: String
    public let provider: String
    public let project: String
    public let machineID: String
    public let machineName: String
    public let sessionID: String?
    public let taskID: String?
    public let taskTitle: String?
    public let state: AWWatchState
    public let action: String
    public let since: Double?
    public let updatedAt: Double?

    public static func identity(machine: String, kind: String, source: String) -> String {
        NativeRPCValue.array([.string(machine), .string(kind), .string(source)]).compact
    }
    public static func decode(_ value: NativeRPCValue) -> Self? {
        guard let id = value["id"].string, let source = value["sourceID"].string,
              let state = value["state"].string.flatMap(AWWatchState.init(rawValue:)) else { return nil }
        return Self(id: id, sourceID: source, kind: value["kind"].string ?? "session",
            name: value["name"].string ?? source, provider: value["provider"].string ?? "",
            project: value["project"].string ?? "", machineID: value["machineID"].string ?? "",
            machineName: value["machineName"].string ?? "This Mac", sessionID: value["sessionID"].string,
            taskID: value["taskID"].string, taskTitle: value["taskTitle"].string, state: state,
            action: value["action"].string ?? state.label, since: value["since"].number, updatedAt: value["updatedAt"].number)
    }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("sourceID", .string(sourceID)), .init("kind", .string(kind)),
            .init("name", .string(name)), .init("provider", .string(provider)), .init("project", .string(project)),
            .init("machineID", .string(machineID)), .init("machineName", .string(machineName)),
            .init("sessionID", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("taskID", taskID.map(NativeRPCValue.string) ?? .null),
            .init("taskTitle", taskTitle.map(NativeRPCValue.string) ?? .null), .init("state", .string(state.rawValue)),
            .init("action", .string(action)), .init("since", since.map(NativeRPCValue.number) ?? .null),
            .init("updatedAt", updatedAt.map(NativeRPCValue.number) ?? .null)])
    }
}

public struct AWWatchEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case message, tool, result, handoff, status }
    public let id: String
    public let kind: Kind
    public let speaker: String
    public let title: String
    public let text: String
    public let at: Double
    public let targetAgentID: String?
    public let failed: Bool
    public init(id: String, kind: Kind, speaker: String, title: String, text: String, at: Double,
                targetAgentID: String? = nil, failed: Bool = false) {
        self.id = id; self.kind = kind; self.speaker = speaker; self.title = title
        self.text = String(text.prefix(4000)); self.at = at; self.targetAgentID = targetAgentID; self.failed = failed
    }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("kind", .string(kind.rawValue)), .init("speaker", .string(speaker)),
            .init("title", .string(title)), .init("text", .string(text)), .init("at", .number(at)),
            .init("targetAgentID", targetAgentID.map(NativeRPCValue.string) ?? .null), .init("failed", .bool(failed))])
    }
    public static func decode(_ raw: NativeRPCValue) -> Self? {
        guard let id = raw["id"].string, let kind = raw["kind"].string.flatMap(Kind.init(rawValue:)) else { return nil }
        return Self(id: id, kind: kind, speaker: raw["speaker"].string ?? "Agent", title: raw["title"].string ?? "",
            text: raw["text"].string ?? "", at: raw["at"].number ?? 0,
            targetAgentID: raw["targetAgentID"].string, failed: raw["failed"].bool == true)
    }
}

/// Presentation of already-authorized source rows. No store or identity owner.
public enum AWWatchProjection {
    public static func inventory(sessions: [NativeRPCValue], tasks: [NativeRPCValue], hoot: NativeRPCValue = .missing,
                                 machineID: String = "", machineName: String = "This Mac", connected: Bool = true) -> [AWWatchAgent] {
        let hootSession = hoot["sessionId"].string
        let tasks = tasks.filter { $0["assignee"].string != "me" && $0["assignee"]["kind"].string != "human" }
        var linked = Set<String>(), rows: [AWWatchAgent] = []
        for session in sessions {
            guard let source = session["id"].string, session["provider"].string != "shell" else { continue }
            let task = tasks.first { $0["sessionId"].string == source }
            if let taskID = task?["id"].string { linked.insert(taskID) }
            let isHoot = source == hootSession
            let state = AWWatchState.observed(session["exitCode"].number != nil ? "exited" :
                session["attention"].string ?? session["status"].string ?? task?["process"].string, connected: connected)
            let tool = session["currentTool"].string
            rows.append(AWWatchAgent(id: AWWatchAgent.identity(machine: machineID, kind: isHoot ? "hoot" : "session", source: source),
                sourceID: source, kind: isHoot ? "hoot" : "session", name: isHoot ? "Hoot" : task?["agent"].string ?? session["title"].string ?? source,
                provider: session["provider"].string ?? "", project: session["cwd"].string ?? "",
                machineID: machineID, machineName: machineName, sessionID: source, taskID: task?["id"].string,
                taskTitle: task?["title"].string, state: state,
                action: state == .working ? tool.map(action) ?? "Working" : state.label,
                since: session["statusSince"].number, updatedAt: session["updatedAt"].number ?? session["statusSince"].number))
        }
        for task in tasks where !linked.contains(task["id"].string ?? "") {
            guard let source = task["id"].string else { continue }
            let state = AWWatchState.observed(task["questionOpen"].bool == true ? "input" : task["process"].string, connected: connected)
            rows.append(AWWatchAgent(id: AWWatchAgent.identity(machine: machineID, kind: "task", source: source), sourceID: source, kind: "task",
                name: task["agent"].string ?? task["assignee"]["agentId"].string ?? "Task agent", provider: "claude",
                project: task["project"].string ?? "", machineID: machineID, machineName: machineName,
                sessionID: task["sessionId"].string, taskID: source, taskTitle: task["title"].string,
                state: state, action: state.label, since: task["runStartedAt"].number, updatedAt: task["updatedAt"].number))
        }
        return sorted(rows)
    }
    public static func sorted(_ rows: [AWWatchAgent]) -> [AWWatchAgent] {
        func rank(_ state: AWWatchState) -> Int { switch state { case .working: 0; case .waiting: 1; case .queued: 2; case .idle: 3; case .unknown: 4; case .offline: 5; case .finished: 6 } }
        return rows.sorted { rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.id < $1.id }
    }
    public static func action(_ tool: String) -> String {
        let name = tool.lowercased()
        if ["read", "glob", "grep", "search", "list", "open"].contains(where: name.hasPrefix) { return "Reading · \(tool)" }
        if ["edit", "write", "apply_patch", "notebookedit"].contains(where: name.hasPrefix) { return "Editing · \(tool)" }
        if ["bash", "exec", "shell", "command"].contains(where: name.hasPrefix) { return "Running · \(tool)" }
        return "Using \(tool)"
    }
    public static func filtered(_ rows: [AWWatchAgent], state: String? = nil, project: String? = nil,
                                machine: String? = nil, query: String = "") -> [AWWatchAgent] {
        rows.filter { row in
            (state == nil || row.state.rawValue == state) && (project == nil || row.project == project) &&
            (machine == nil || row.machineID == machine) && (query.isEmpty ||
                [row.name, row.provider, row.project, row.taskTitle ?? "", row.machineName].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    public static func page(_ entries: [AWWatchEntry], after: String?, limit: Int) -> NativeRPCValue {
        let bounded = min(200, max(1, limit))
        let envelope = after.flatMap { try? NativeRPCValue.parseJSON(Data($0.utf8), maximumBytes: 8192) }?.elements
        let cursorID = envelope?.first?.string ?? after
        var index = cursorID.flatMap { cursor in entries.firstIndex { $0.id == cursor } }
        if let found = index, let expected = envelope?.last?.string, envelope?.count == 2,
           digest(Array(entries.prefix(found + 1))) != expected { index = nil }
        let reset = after != nil && index == nil
        let candidates = index.map { Array(entries.dropFirst($0 + 1)) } ?? Array(entries.suffix(bounded).reversed())
        var page: [AWWatchEntry] = [], bytes = 0
        for entry in candidates.prefix(bounded) {
            let size = entry.wireValue.compact.utf8.count
            guard bytes + size <= 128 * 1024 else { break }
            page.append(entry); bytes += size
        }
        if index == nil { page.reverse() }
        return .object([.init("entries", .array(page.map(\.wireValue))), .init("reset", .bool(reset)),
            .init("cursor", page.last.flatMap { last -> NativeRPCValue? in
                guard let position = entries.firstIndex(where: { $0.id == last.id }) else { return nil }
                return .string(NativeRPCValue.array([.string(last.id), .string(digest(Array(entries.prefix(position + 1))))]).compact)
            } ?? after.map(NativeRPCValue.string) ?? .null),
            .init("hasMore", .bool(page.count < candidates.count))])
    }
    private static func digest(_ entries: [AWWatchEntry]) -> String {
        var digest = SHA256()
        for entry in entries { digest.update(data: Data(entry.wireValue.compact.utf8)) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
