import Foundation
import TerminalDeckNativeCore

public enum AWWatchCaller: Sendable {
    case app(NativeRPCContext)
    case mcp(BackendMCPCallContext)
}
public struct AWWatchSnapshot: Sendable {
    public let agents: [AWWatchAgent]
    public let tasks: [NativeRPCValue]
    public let notices: [String]
    public init(agents: [AWWatchAgent], tasks: [NativeRPCValue], notices: [String] = []) {
        self.agents = agents; self.tasks = tasks; self.notices = notices
    }
}
public struct AWWatchConversation: Sendable {
    public let entries: [AWWatchEntry]
    public let notice: String?
    public let updatedAt: Double?
    /// App-only exact path for NativeTranscriptBackend's existing file watcher.
    public let watchPath: String?
    public init(entries: [AWWatchEntry], notice: String? = nil, updatedAt: Double? = nil, watchPath: String? = nil) {
        self.entries = entries; self.notice = notice; self.updatedAt = updatedAt; self.watchPath = watchPath
    }
}
public protocol AWAgentsWatchSource: Sendable {
    func authorize(_ caller: AWWatchCaller, tool: String, arguments: NativeRPCValue) async throws
    func snapshot(_ caller: AWWatchCaller) async throws -> AWWatchSnapshot
    func conversation(_ agent: AWWatchAgent, caller: AWWatchCaller) async throws -> AWWatchConversation
}

/// Production adapter to existing session authority, TAG store and HOOT stream.
/// Missing source bindings are explicit; no reader searches "newest in folder".
public struct AWAgentsWatchNativeSource: AWAgentsWatchSource {
    public struct StructuredHoot: Sendable {
        public let require: @Sendable (AWWatchCaller) async throws -> Void
        public let read: @Sendable (AWWatchCaller) async throws -> (agents: [AWWatchAgent], entries: [AWWatchEntry])
        public init(require: @escaping @Sendable (AWWatchCaller) async throws -> Void,
                    read: @escaping @Sendable (AWWatchCaller) async throws -> (agents: [AWWatchAgent], entries: [AWWatchEntry])) {
            self.require = require; self.read = read
        }
    }
    public typealias Remote = @Sendable (AWWatchCaller) async throws -> AWWatchSnapshot
    public typealias ResolveTranscript = @Sendable (AWWatchAgent, AWWatchCaller) async throws -> (path: String, scope: NativeTranscriptScope)?
    private let authority: BackendCompositionAuthority
    private let tasks: BackendTaskStateView
    private let taskAuthority: BackendTaskToolAuthority
    private let activity: AWAgentsWatchActivity?
    private let transcript: ResolveTranscript
    private let hoot: StructuredHoot?
    private let remote: Remote?
    private let remoteRead: (@Sendable (AWWatchAgent, AWWatchCaller) async throws -> AWWatchConversation)?

    public init(authority: BackendCompositionAuthority, tasks: BackendTaskStateView, taskAuthority: BackendTaskToolAuthority,
                transcript: @escaping ResolveTranscript, activity: AWAgentsWatchActivity? = nil, hoot: StructuredHoot? = nil,
                remote: Remote? = nil, remoteRead: (@Sendable (AWWatchAgent, AWWatchCaller) async throws -> AWWatchConversation)? = nil) {
        self.authority = authority; self.tasks = tasks; self.taskAuthority = taskAuthority
        self.activity = activity
        self.transcript = transcript; self.hoot = hoot; self.remote = remote; self.remoteRead = remoteRead
    }
    public func authorize(_ caller: AWWatchCaller, tool: String, arguments: NativeRPCValue) async throws {
        switch caller {
        case .app(let context): try authority.requireLocalUI(context)
        case .mcp(let context):
            try await authority.authorize(context, tool: tool, arguments: arguments, tier: .read, sentence: "Read agents at work")
        }
    }
    private func validate(_ caller: AWWatchCaller) async throws {
        switch caller {
        case .app(let context): try authority.requireLocalUI(context)
        case .mcp(let context): _ = try await authority.resolve(context)
        }
        try Task.checkCancellation()
    }
    public func snapshot(_ caller: AWWatchCaller) async throws -> AWWatchSnapshot {
        try await validate(caller)
        var sessions: [NativeRPCValue] = [], visibleTasks: [BackendTaskRecord] = [], notices: [String] = []
        for row in authority.sessionViews() {
            guard let id = row["id"].string, !authority.hidden.contains(id) else { continue }
            if case .mcp(let context) = caller {
                do { _ = try await authority.requireSession(id, native: context) }
                catch let error as NativeRPCError where error.code == "access-denied" { continue }
            }
            sessions.append(row)
        }
        var canReadTasks = true
        if case .mcp(let context) = caller {
            do { try await taskAuthority.requireTasks(context) }
            catch let error as NativeRPCError where ["access-denied", "not-permitted", "not-granted"].contains(error.code) {
                canReadTasks = false; notices.append("Task agents are outside this caller's task access.")
            }
        }
        if canReadTasks {
            for task in try await tasks.store.all() {
                if case .mcp(let context) = caller, try await !taskAuthority.visible(context, task) { continue }
                visibleTasks.append(task)
            }
        }
        let profiles = canReadTasks ? try await tasks.config.allAgents() : []
        let taskRows = visibleTasks.map { BackendTaskStateView.taskView($0, agents: profiles, all: visibleTasks) }
        if let activity { sessions = await activity.decorate(sessions) }
        let agentTasks = visibleTasks.filter { $0.assigneeKind == "agent" }.map { BackendTaskStateView.taskView($0, agents: profiles, all: visibleTasks) }
        var agents = AWWatchProjection.inventory(sessions: sessions, tasks: agentTasks)
        // Hoot's hidden session is intentionally absent above. Its structured
        // stream is the sole Hoot source, supplied by the HOOT lane.
        if let hoot {
            var allowed = true
            do { try await hoot.require(caller) }
            catch let error as NativeRPCError where ["access-denied", "not-permitted", "not-granted"].contains(error.code) { allowed = false }
            if allowed { agents += try await hoot.read(caller).agents }
        } else { notices.append("Hoot's structured activity source is not connected.") }
        if let remote {
            let elsewhere = try await remote(caller)
            agents += elsewhere.agents; notices += elsewhere.notices
            // Remote task ids must stay scoped to their machine, never joined
            // into the local TAG parent map.
        } else { notices.append("Connected-machine activity is not connected.") }
        try await validate(caller)
        return AWWatchSnapshot(agents: AWWatchProjection.sorted(agents), tasks: taskRows, notices: notices)
    }
    public func conversation(_ agent: AWWatchAgent, caller: AWWatchCaller) async throws -> AWWatchConversation {
        try await validate(caller)
        if !agent.machineID.isEmpty {
            guard let remoteRead else { throw unavailable("This machine's conversation reader is not connected.") }
            let read = try await remoteRead(agent, caller)
            try await validate(caller); return read
        }
        if agent.kind == "hoot" {
            guard let hoot else { throw unavailable("Hoot's structured activity source is not connected.") }
            try await hoot.require(caller)
            let read = try await hoot.read(caller)
            try await hoot.require(caller)
            try await validate(caller)
            return AWWatchConversation(entries: read.entries)
        }
        if case .mcp(let context) = caller, let id = agent.sessionID { _ = try await authority.requireSession(id, native: context) }
        guard agent.provider == "claude", let located = try await transcript(agent, caller) else {
            return AWWatchConversation(entries: [], notice: "A readable conversation is not available for this agent yet.")
        }
        let cancellation: BackendMCPCancellation?
        if case .mcp(let context) = caller { cancellation = context.cancellation } else { cancellation = nil }
        let result = try await AWAgentsWatchTranscript.read(path: located.path, scope: located.scope, cancellation: cancellation)
        try await validate(caller)
        return AWWatchConversation(entries: result.entries, notice: "Showing the recent conversation (bounded to 2 MiB).",
            updatedAt: result.updatedAt, watchPath: { if case .app = caller { located.path } else { nil } }())
    }
    private func unavailable(_ text: String) -> NativeRPCError { .init(code: "unavailable", message: text) }
}
