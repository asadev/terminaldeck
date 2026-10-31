import Foundation
import TerminalDeckNativeCore

/// Asad (12 Oct, install 10): Hoot's task work is fully separate. Each task Hoot works on (a task thread, a CRM-linked
/// task, @Hoot in a comment, a delegation) gets its OWN Hoot conversation and process, never the chat's. It is kept
/// for the task's next turn (resumed from its own saved conversation), and its answers go back to the task thread.
/// The chat Hoot still knows: every task turn leaves a short "where we are" topic in Hoot's memory, keyed to the task.
public protocol BackendHootTaskWorker: Sendable {
    func backgroundTurn(_ turn: BackendHootBackgroundTurn,
                        progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult
    func cancelBackgroundTurn(reason: String, id: String?) async
    /// Stops the process and keeps the conversation (the next turn resumes it).
    func isHostedTask() async -> Bool
    func rest() async
}

public extension BackendHootTaskWorker { func isHostedTask() async -> Bool { false } }
extension BackendCopilotSessionRuntime: BackendHootTaskWorker {
    public func isHostedTask() async -> Bool { await structuredChat?.hostedSessionID != nil }
    public func rest() async { _ = try? await invoke("hoot:stop", arguments: []) }
}

public actor BackendHootTaskConversations {
    public typealias Make = @Sendable (_ taskID: String) async throws -> any BackendHootTaskWorker
    private let make: Make
    private let memory: @Sendable () async -> any DeckMemoryStoring
    private var workers: [String: any BackendHootTaskWorker] = [:]
    private var visibleStart: (@Sendable (String, String, any BackendHootTaskWorker) async throws -> Void)?
    private var closing: @Sendable () async -> Bool = { false }
    private var visibleFinish: (@Sendable (String, BackendHootTaskResult) async -> Void)?
    public func setJobVisibility(started: @escaping @Sendable (String, String, any BackendHootTaskWorker) async throws -> Void,
                                 finished: @escaping @Sendable (String, BackendHootTaskResult) async -> Void, closing: @escaping @Sendable () async -> Bool = { false }) {
        self.closing = closing
        visibleStart = started; visibleFinish = finished
    }

    /// Each turn runs in the task's own conversation; its process rests when the turn ends,
    /// and the next turn resumes the same conversation.
    public init(memory: @escaping @Sendable () async -> any DeckMemoryStoring = { await DeckMemory.ready() }, make: @escaping Make) {
        self.make = make; self.memory = memory
    }

    /// The folder a task's conversation lives in (one per task, safe as a file name).
    public static func folderName(_ taskID: String) -> String {
        let safe = taskID.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? String($0) : "_" }.joined()
        return String(safe.prefix(120))
    }

    /// One comment on the task's thread (the person's, an agent's, a CRM context note, Hoot's own).
    public struct Comment: Sendable, Equatable {
        public var at: Double, by: String, kind: String, text: String
        public init(at: Double, by: String, kind: String = "comment", text: String) { self.at = at; self.by = by; self.kind = kind; self.text = text }
        /// From a task record's `notes`.
        public static func from(_ notes: NativeRPCValue) -> [Comment] {
            (notes.elements ?? []).compactMap { note in
                guard let text = note["text"].string, !text.isEmpty else { return nil }
                return .init(at: note["at"].number ?? 0, by: note["by"].string ?? "", kind: note["kind"].string ?? "comment", text: text)
            }
        }
    }
    public static let threadBudget = 8_000, commentCap = 2_000
    static func seenKey(_ taskID: String) -> String { "task.thread.seen." + taskID }

    /// HOOT-THREAD (12 Oct): the task's Hoot sees the thread. First turn: the thread so far (when it is long, the
    /// newest comments, the rest named). Every later turn: every comment posted since its last turn, so it knows what
    /// agents and the person said before it answers. Hoot's own comments are not repeated to it.
    static func threadSection(_ comments: [Comment], seen: Double?) -> String? {
        let others = comments.filter { $0.by.lowercased() != "hoot" }.sorted { $0.at < $1.at }
        func who(_ comment: Comment) -> String {
            let by = comment.by.isEmpty ? "someone" : comment.by == "me" ? "the owner" : comment.by
            return by + (comment.kind == "comment" || comment.kind == "progress" ? "" : " (" + comment.kind + ")")
        }
        func line(_ comment: Comment) -> String {
            let text = comment.text.count > commentCap ? String(comment.text.prefix(commentCap)) + " […]" : comment.text
            let when = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: comment.at / 1000))
            return "- " + when + " · " + who(comment) + ": " + text.replacingOccurrences(of: "\n", with: "\n  ")
        }
        if let seen {
            let new = others.filter { $0.at > seen }
            return new.isEmpty ? nil : "## New on the task's thread since your last turn\n" + new.map(line).joined(separator: "\n")
        }
        guard !others.isEmpty else { return nil }
        let all = others.map(line)
        if all.joined(separator: "\n").count <= threadBudget { return "## The task's thread so far\n" + all.joined(separator: "\n") }
        var kept: [String] = [], used = 0
        for text in all.reversed() { guard used + text.count <= threadBudget || kept.isEmpty else { break }; kept.append(text); used += text.count }
        return "## The task's thread so far, newest first (\(all.count - kept.count) earlier comments left out; tasks_get reads them)\n" + kept.joined(separator: "\n")
    }

    /// One turn on this task, in the task's own conversation. Returns Hoot's answer for the task thread.
    public func turn(taskID: String, title: String, message: String, comments: [Comment] = [], clientMessageID: String = UUID().uuidString.lowercased(),
                     progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void = { _ in }) async throws -> BackendHootTaskResult {
        try await BackendPCDecisionDelivery.verify()
        let worker: any BackendHootTaskWorker
        if let known = workers[taskID] { worker = known } else { worker = try await make(taskID); workers[taskID] = worker }
        try await BackendPCDecisionDelivery.verify()
        let store = await memory()
        let saved: String? = (try? await store.value(Self.seenKey(taskID), owner: .hoot)) ?? nil
        let seen = saved.flatMap(Double.init)
        var told = message
        if let thread = Self.threadSection(comments, seen: seen) { told += "\n\n" + thread }
        let result: BackendHootTaskResult
        do {
            try await visibleStart?(taskID, title, worker)
            try await BackendPCDecisionDelivery.verify()
            result = try await worker.backgroundTurn(.init(reason: "task", id: taskID, title: title, message: told, chatLine: nil, clientMessageID: clientMessageID), progress: progress)
            if let newest = comments.map(\.at).max() { try? await store.setValue(String(max(newest, seen ?? 0)), key: Self.seenKey(taskID), owner: .hoot) }
        } catch {
            if await closing(), await worker.isHostedTask() { throw CancellationError() }
            await visibleFinish?(taskID, .init(answer: "", finished: false, problem: error.localizedDescription))
            await worker.rest(); workers[taskID] = nil
            throw error
        }
        if await closing(), await worker.isHostedTask() { return result }
        await remember(taskID: taskID, title: title, result: result)
        await visibleFinish?(taskID, result)
        await worker.rest(); workers[taskID] = nil
        return result
    }
    /// The task was stopped, deleted or given to someone else: its turn ends now.
    public func cancel(taskID: String) async { await workers[taskID]?.cancelBackgroundTurn(reason: "task", id: taskID) }
    /// The tasks whose turn is running now.
    public func tasks() -> [String] { workers.keys.sorted() }

    /// The task's "where we are" topic in Hoot's memory (one per task, replaced each turn), written by the app from
    /// what the task conversation answered, so the chat Hoot can read it when the person asks about the task.
    public static func topicTitle(taskID: String, title: String) -> String { "Task \(taskID): \(title)" }
    func remember(taskID: String, title: String, result: BackendHootTaskResult) async {
        let store = await memory()
        var stamp = DeckMemoryStamp.hoot
        stamp.job = "task:" + taskID
        let when = ISO8601DateFormatter().string(from: Date())
        var body = "Worked on by Hoot in this task's own conversation (never the chat). Last turn: \(when), "
            + (result.finished ? "finished." : "not finished" + (result.problem.map { " (" + $0 + ")" } ?? "") + ".")
        let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !answer.isEmpty { body += "\n\nHoot's last answer on the task thread:\n" + String(answer.prefix(1_500)) }
        body += "\n\nThe whole thread, its status and its agents: the task tools (tasks_get with task \(taskID))."
        _ = try? await store.updateTopic(.hoot, title: Self.topicTitle(taskID: taskID, title: title), body: body, stamp: stamp)
    }
}
