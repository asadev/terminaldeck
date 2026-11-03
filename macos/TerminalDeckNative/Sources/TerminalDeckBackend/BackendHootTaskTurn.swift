import Foundation
import TerminalDeckNativeCore

/// A task the owner assigned to Hoot. Hoot works it in its own conversation with no user bubble:
/// the chat shows at most one compact line ("Working on task …"), and progress and the final
/// answer go back to the caller, which posts them as Hoot's comments on the task.
public struct BackendHootTaskTurn: Sendable, Equatable {
    public var taskID: String
    public var title: String
    public var body: String
    /// What Hoot is asked to do, written by the task engine. Not the person's own words.
    public var brief: String
    public var projectID: String?
    /// The engine's exact queued scope; a later approval must not authorize an older brief.
    public var decisionScope: String?
    public var clientMessageID: String
    public init(taskID: String, title: String, body: String, brief: String, projectID: String? = nil, decisionScope: String? = nil, clientMessageID: String = UUID().uuidString.lowercased()) {
        self.taskID = taskID; self.title = title; self.body = body; self.brief = brief; self.projectID = projectID
        self.decisionScope = decisionScope; self.clientMessageID = clientMessageID
    }
}

/// A turn Hoot works in the background: no user bubble, and what Hoot does and says for it is not shown
/// in the visible chat. A task turn is one (it leaves one compact line in the chat); a handoff asked for
/// from a button is another (it leaves nothing).
public struct BackendHootBackgroundTurn: Sendable, Equatable {
    /// Why the app started it, in one plain word ("task", "handoff"). Also what the diary stamps it with.
    public var reason: String
    /// What it is about: the task id, the topic id. Letters, digits, "-", "_", "." and ":" only.
    public var id: String
    public var title: String
    /// What Hoot is told. The app's words, never the person's.
    public var message: String
    /// The one compact line left in the chat; nil leaves nothing there at all.
    public var chatLine: String?
    public var clientMessageID: String
    public init(reason: String, id: String, title: String, message: String, chatLine: String? = nil, clientMessageID: String = UUID().uuidString.lowercased()) {
        self.reason = reason; self.id = id; self.title = title; self.message = message; self.chatLine = chatLine; self.clientMessageID = clientMessageID
    }
    public static let turnPrefix = "bg:"
    /// "bg:<reason>:<id>:" — every record of the turn carries a turn id that starts with this.
    public var turnPrefix: String { Self.turnPrefix + reason + ":" + id + ":" }
}

/// What the caller hears while Hoot works a task. Each call replaces the one before of its kind.
public enum BackendHootTaskProgress: Sendable, Equatable {
    /// Hoot took the task; the compact line is in its chat.
    case started
    /// One plain line on what Hoot is doing now ("Reading the task", "Using tasks comment").
    case step(String)
    /// Hoot's answer so far, whole (not a piece to append).
    case text(String)
}

public struct BackendHootTaskResult: Sendable, Equatable {
    /// Hoot's final words for the task, ready to post as its comment.
    public var answer: String
    /// False when Hoot was stopped or failed before finishing; `problem` says why in one plain sentence.
    public var finished: Bool
    public var problem: String?
    public init(answer: String, finished: Bool, problem: String? = nil) { self.answer = answer; self.finished = finished; self.problem = problem }
}

public extension BackendCopilotSessionRuntime {
    /// L6 BACKGROUND-TURN API. Hoot works one request in the background and this returns when it has finished.
    /// - No user bubble and none of Hoot's words or steps in the visible chat (only `chatLine`, when given).
    /// - Waits its turn when Hoot is in the middle of another answer (one at a time, in order); starts Hoot if asleep.
    /// - `progress(.started)` = Hoot has the request; then `.step` / `.text` in order; never after the return.
    /// - The result is the end of the turn: `finished` or the plain reason it was not.
    /// - Throws `NativeRPCError` ("unavailable", "busy") when Hoot could not be given the request at all.
    func backgroundTurn(_ turn: BackendHootBackgroundTurn,
                        progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void = { _ in }) async throws -> BackendHootTaskResult {
        guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's chat is unavailable.") }
        guard !turn.reason.isEmpty, !turn.id.isEmpty, (turn.reason + turn.id).allSatisfy({ $0.isLetter || $0.isNumber || "-_.:".contains($0) }) else {
            throw NativeRPCError.invalidArguments("A background turn needs a plain reason and id.")
        }
        let slot = taskSlot()
        defer { slot.done.finish() }
        noteWaiting(turn.turnPrefix, 1)
        await slot.wait?.value
        noteWaiting(turn.turnPrefix, -1)
        // Stopped or given to someone else while it waited its turn: Hoot never starts it.
        if takeCancelled(turn.turnPrefix) { return .init(answer: "", finished: false, problem: "It was cancelled before Hoot started it.") }
        // The app wrote this, not the person, and the message says so.
        let context = NativeRPCValue.object([.init("source", .object([.init("kind", .string(turn.reason)), .init("title", .string(turn.title))]))])
        var sent = false
        for _ in 0..<24 where !sent {
            await chat.waitUntilIdle()
            do { _ = try await sayValidated(turn.message, context: context, clientMessageID: turn.clientMessageID, background: turn); sent = true }
            catch let error as NativeRPCError where error.code == "busy" { continue }
        }
        guard sent else { throw NativeRPCError(code: "busy", message: "Hoot stayed busy, so this is still waiting for it.") }
        var id = await chat.activeTurnID
        await progress(.started)
        var answer = "", step = "", finished = false, problem: String?
        for await snapshot in await chat.subscribe() {
            if await chat.hostedSessionID != nil, let latest = snapshot["events"].elements?.last?["turnId"].string { id = latest }
            let events = (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }.filter { $0.turnID == id }
            let read = BackendHootTaskTurns.read(events)
            if read.step != step, !read.step.isEmpty { step = read.step; await progress(.step(step)) }
            if read.answer != answer, !read.answer.isEmpty { answer = read.answer; await progress(.text(answer)) }
            finished = read.finished; problem = read.problem
            if snapshot["busy"].bool != true { break }
        }
        // Stopped on purpose (cancelBackgroundTurn): whatever the CLI said at the end, this is not a finished answer.
        if takeInterrupted(id) { finished = false; problem = "It was stopped before Hoot finished." }
        if !finished, problem == nil { problem = "Hoot stopped before it finished." }
        return .init(answer: answer, finished: finished, problem: finished ? nil : problem)
    }

    /// A handoff of the conversation up to and including the message at this event, written in the background.
    func handoffTurn(upTo sequence: Int, progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void = { _ in }) async throws -> BackendHootTaskResult {
        guard let chat = structuredChat, let cut = await chat.cut(at: sequence) else {
            throw NativeRPCError.invalidArguments("That message is not in this chat any more.")
        }
        let said = BackendHootDesk.said(await chat.recentMessages(through: sequence))
        return try await backgroundTurn(.init(reason: "handoff", id: "upto-" + String(sequence), title: "Handoff up to: " + cut.words,
                                              message: BackendHootTaskTurns.handoffRequest(upTo: cut, said: said)), progress: progress)
    }
    /// Stops a background turn (a task that was stopped or given to someone else). One that is running is
    /// interrupted; one still waiting its turn is never started. Either way its `backgroundTurn` call returns
    /// with finished false. Does nothing when there is no such turn.
    /// `id` nil: every turn of that reason (the handoff panel's Stop does not know whether it was "up to" a message).
    func cancelBackgroundTurn(reason: String, id: String?) async {
        guard let chat = structuredChat else { return }
        guard let id else {
            let prefix = BackendHootBackgroundTurn.turnPrefix + reason + ":"
            for waiting in waitingPrefixes(startingWith: prefix) { noteCancelled(waiting) }
            let turn = await chat.activeTurnID
            if turn.hasPrefix(prefix), await chat.isBusy { noteInterrupted(turn); try? await chat.interrupt() }
            return
        }
        let prefix = BackendHootBackgroundTurn(reason: reason, id: id, title: "", message: "").turnPrefix
        let turn = await chat.activeTurnID
        // The running one is interrupted, and any copy still waiting behind it never starts.
        noteCancelled(prefix)
        if turn.hasPrefix(prefix), await chat.isBusy { noteInterrupted(turn); try? await chat.interrupt() }
    }

    /// L6 TASK-TURN API. Hands Hoot one assigned task and returns when Hoot has finished it: a background
    /// turn that leaves one compact line in the chat ("Working on task …") and whose answer is for the task.
    /// The owner's assignment is the consent for the task tools on THIS task only; anything beyond that asks
    /// on screen as usual.
    func taskTurn(_ task: BackendHootTaskTurn,
                  progress: @escaping @Sendable (BackendHootTaskProgress) async -> Void) async throws -> BackendHootTaskResult {
        // A caller that already wrote the whole brief (the task engine does) is passed on as it is; the
        // wrapper is only for a caller that hands over the bare task.
        let ready = task.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await backgroundTurn(.init(reason: "task", id: task.taskID, title: task.title, message: ready.isEmpty ? BackendHootTaskTurns.message(task) : ready,
                                       chatLine: "Working on task \u{201C}\(task.title)\u{201D}", clientMessageID: task.clientMessageID), progress: progress)
    }
}

/// The pure parts of a background turn: what Hoot is told for a task, and what its records say so far.
public enum BackendHootTaskTurns {
    public static func message(_ task: BackendHootTaskTurn) -> String {
        var lines = ["[A task from \(BackendSharedBrand.name), assigned to you by the person. Task \(task.taskID): \u{201C}\(task.title)\u{201D}. The person does not see this message in the chat; what you answer here is posted as your comment on the task, so answer for the task.]"]
        let body = task.body.trimmingCharacters(in: .whitespacesAndNewlines), brief = task.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append("The task says:\n" + body) }
        if !brief.isEmpty { lines.append(brief) }
        return lines.joined(separator: "\n\n")
    }
    /// A handoff of the conversation up to and including one message (the message's own handoff button).
    public static func handoffRequest(upTo cut: (fromPerson: Bool, words: String, at: Double), said: String?) -> String {
        let date = Date(timeIntervalSince1970: cut.at / 1000)
        let shown = DateFormatter(); shown.dateFormat = "d MMM yyyy, HH:mm:ss"
        let iso = ISO8601DateFormatter().string(from: date)
        return """
        [A request from \(BackendSharedBrand.name)'s Context handoff button on one message, not typed by the person. Nothing you write here is shown in the chat.]

        Write a context handoff of this conversation UP TO AND INCLUDING \(cut.fromPerson ? "the person's" : "your") message of \(shown.string(from: date)) (\(iso)): \u{201C}\(cut.words)\u{201D}. Treat that message as the latest one. Leave out everything that was said, decided or done after it, in this chat and in memory: when you read notes, topics or the diary, use only what is dated up to \(iso); where a topic note was rewritten later, give the state as it stood then if the diary shows it, and say plainly where you cannot tell.

        In this order: the goal · where things stood at that message · decisions and why · the person's corrections in their own words · open items and who was waiting · the next step · where the detail is (files, sessions, and words to look up in the diary).
        \(said.map { "\n## The conversation up to that message, the last messages word for word\n\n" + $0 + "\n" } ?? "")
        Deliver it with the `handoff_present` tool: title \u{201C}Handoff up to: \(cut.words)\u{201D}, topic \u{201C}whole conversation\u{201D}. Do not paste it as your answer; answer with one short line saying it is delivered, or why it could not be.
        """
    }
    /// What Hoot is asked when the person presses Context handoff (topicID nil = the whole conversation).
    public static func handoffRequest(topicID: String?, title: String) -> String {
        let about = topicID == nil ? "this whole conversation" : "the topic \u{201C}\(title)\u{201D}"
        return """
        [A request from \(BackendSharedBrand.name)'s Context handoff button, not typed by the person. Nothing you write here is shown in the chat.]

        Write a context handoff for \(about): a document that someone with none of this context could carry on from. In this order: the goal · where things stand now · decisions and why · the person's corrections in their own words · open items and who is waiting · the next step · where the detail is (files, sessions, and words to look up in the diary). Use your memory tools for anything that is not on your desk; do not guess.

        Deliver the document with the `handoff_present` tool. Do not paste it as your answer; answer with one short line saying it is delivered, or why it could not be.
        """
    }
    /// Hoot's words (the last text it wrote), the step it is on, and whether the turn ended cleanly.
    public static func read(_ events: [HootChatEvent]) -> (answer: String, step: String, finished: Bool, problem: String?) {
        let rows = HootChatProjection.rows(events)
        let answer = rows.last { [.message, .textDelta].contains($0.kind) && $0.value["background"].fields == nil }?.value["text"].string ?? ""
        let running = rows.last { $0.kind == .toolCall && $0.value["finished"].bool != true }?.value["name"].string ?? ""
        let step = running.isEmpty ? "" : "Using " + running.replacingOccurrences(of: "mcp__deck-control__", with: "").replacingOccurrences(of: "_", with: " ")
        let stopped = events.contains { $0.record.kind == .interrupted }
        let failure = rows.last { $0.kind == .error }?.value["text"].string
        let completed = events.contains { $0.record.kind == .completed }
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), step, completed && !stopped && failure == nil,
                stopped ? "Hoot was stopped before it finished." : failure)
    }
}
