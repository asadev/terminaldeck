import Foundation
import TerminalDeckNativeCore

/// #109: a comment on a task held by an agent or Hoot reaches that worker, and
/// the comment carries what is known about it: sent, delivered, seen, answered
/// or failed. Receipts are stored with the comment (`commentMeta[id].delivery`).
/// "Seen" and "answered" are never guessed from a terminal: the worker posting
/// in the same thread after the comment reached it is the proof.
/// (Reuses the receipt shape drafted by the FIXES chat, 10 Oct.)
enum BackendTaskCommentReceipt {
    static func sent(to id: String, name: String, at: Double) -> NativeRPCValue {
        BackendTaskValues.object([("state", .string("sent")), ("agentID", .string(id)), ("agentName", .string(name)),
            ("sentAt", .number(at)), ("deliveredAt", .null), ("seenAt", .null), ("answeredAt", .null), ("failedAt", .null),
            ("error", .null), ("waiting", .bool(false))])
    }
    static func delivered(_ value: NativeRPCValue, at: Double) -> NativeRPCValue {
        value.setting("state", .string("delivered")).setting("deliveredAt", .number(at)).setting("error", .null).setting("waiting", .bool(false))
    }
    /// The recipient started its turn on the comment (read it), before answering.
    static func seen(_ value: NativeRPCValue, at: Double) -> NativeRPCValue {
        let base = value["deliveredAt"].isNullish ? value.setting("deliveredAt", .number(at)) : value
        return base.setting("state", .string("seen")).setting("seenAt", .number(at)).setting("waiting", .bool(false))
    }
    static func failed(_ value: NativeRPCValue, reason: String, at: Double) -> NativeRPCValue {
        value.setting("state", .string("failed")).setting("error", .string(String(reason.prefix(500)))).setting("failedAt", .number(at)).setting("waiting", .bool(false))
    }
    /// How a comment is handed to the task engine: the comment itself, then a marker. The engine takes
    /// the marker off again (`enveloped`) and words the hand-over for whoever holds the task, so the
    /// worker never reads this line (FORK-TASKS, 11 Oct: it named the id twice and tasks_comment for
    /// agents that have no task tools).
    static func envelope(body: String, task: BackendTaskRecord) -> String {
        body + envelopeMark + "\(task.id). Answer in the task's comments with tasks_comment, task \(task.id).)"
    }
    static let envelopeMark = "\n\n(A comment on task "
    /// The comment inside an envelope; nil when the text is a plain reply.
    static func enveloped(_ text: String) -> String? {
        guard text.hasSuffix(".)"), let mark = text.range(of: envelopeMark, options: .backwards) else { return nil }
        return String(text[..<mark.lowerBound])
    }
}

/// Who wrote the comment that is being handed to a task's worker. Set only around that hand-over,
/// so the brief can say "the owner wrote…" or name the agent or AI app that did.
public enum BackendTaskCommentAuthor {
    @TaskLocal public static var current: String?
}

extension BackendTaskDetailService {
    /// What the popup may offer next to receipts: retry, asking Hoot instead and
    /// @asking another agent. "Is writing" is shown by the app from the
    /// recipient's live session status (`writingCandidates`), never guessed here.
    static var commentDeliveryFacts: [(String, NativeRPCValue)] {
        [("deliveryAvailable", .bool(true)),
         ("capabilities", BackendTaskValues.object([("retry", .bool(true)), ("askHoot", .bool(true)), ("mentions", .bool(true))])),
         ("writing", .null)]
    }

    func commentAuthorKind(_ id: String) async throws -> String {
        if id == "hoot" { return "hoot" }
        if id == "me" { return "human" }
        return try await local.configuration.agent(id) != nil ? "agent" : "human"
    }

    /// The stored receipt, moved on by what the thread shows: the worker
    /// writing in this task after the comment reached it has seen and answered it.
    static func projectedDelivery(_ receipt: NativeRPCValue, thread: [NativeRPCValue]) -> NativeRPCValue {
        guard let agent = receipt["agentID"].string, let state = receipt["state"].string,
              state == "delivered" || state == "seen" || (state == "sent" && receipt["waiting"].bool == true) else { return receipt }
        let after = receipt["sentAt"].number ?? 0
        guard let answer = thread.first(where: { $0["authorUserId"].string == agent && ($0["at"].number ?? 0) > after }),
              let at = answer["at"].number else { return receipt }
        var seen = receipt
        if seen["deliveredAt"].isNullish { seen = seen.setting("deliveredAt", .number(at)) }
        if seen["seenAt"].isNullish { seen = seen.setting("seenAt", .number(at)) }
        return seen.setting("state", .string("answered")).setting("answeredAt", .number(at)).setting("waiting", .bool(false))
    }

    /// Hand one saved comment to the task's worker and record the outcome.
    /// `raw` keeps the text as written (the hand-back path stores it as a reply note).
    func deliverToAssignee(_ task: BackendTaskRecord, commentID: String, body: String, to target: String, raw: Bool, by: String = "me") async throws -> NativeRPCValue {
        let name = (try? await people.named(target)["name"].string) ?? (target == "hoot" ? "Hoot" : target)
        let sentAt = BackendTaskValues.time()
        var receipt = BackendTaskCommentReceipt.sent(to: target, name: name, at: sentAt)
        try await writeCommentReceipt(task.id, commentID: commentID, receipt)
        seenAwaiting.insert(target)
        do {
            let handed = raw ? body : BackendTaskCommentReceipt.envelope(body: body, task: task)
            _ = try await BackendTaskCommentAuthor.$current.withValue(by) { try await local.reply(task.id, text: handed) }
            let after = try await local.task(task.id)
            let blocker = (after.value["notes"].elements ?? []).last { $0["kind"].string == "blocker" && ($0["at"].number ?? 0) >= sentAt }
            if let blocker {
                // The engine could not hand it over and said why on the task (Hoot not running, agent gone).
                receipt = BackendTaskCommentReceipt.failed(receipt, reason: blocker["text"].string ?? "It could not be reached.", at: BackendTaskValues.time())
            } else if after.process == "queued", after.sessionID == nil {
                // Waiting for a free slot: it starts with the task when one opens.
                receipt = receipt.setting("waiting", .bool(true))
            } else {
                receipt = BackendTaskCommentReceipt.delivered(receipt, at: BackendTaskValues.time())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            receipt = BackendTaskCommentReceipt.failed(receipt, reason: error.localizedDescription, at: BackendTaskValues.time())
        }
        try await writeCommentReceipt(task.id, commentID: commentID, receipt)
        if receipt["state"].string == "failed" {
            return ok([("delivery", receipt), ("warning", .string("Posted, but it could not reach \(name): " + (receipt["error"].string ?? "")))])
        }
        return ok([("delivery", receipt)])
    }

    /// Try a saved comment again. Only its writer may, only when it failed or is
    /// still waiting, and it goes to whoever holds the task now. No new comment.
    /// `agent` names an @mentioned recipient to ask again instead of the holder.
    func retryCommentDelivery(_ task: BackendTaskRecord, commentID: String, by: String, agent: String? = nil) async throws -> NativeRPCValue {
        let d = detail(task)
        guard let row = (d["comments"].elements ?? []).first(where: { $0["id"].string == commentID }), let body = row["body"].string else {
            throw NativeRPCError.invalidArguments("That comment is no longer on this task")
        }
        guard row["authorUserId"].string == by else { throw NativeRPCError.invalidArguments("Only the person who wrote it can send it again") }
        let holder = task.isHeldByWorker ? task.agentID : nil
        let mentions = d["commentMeta"][commentID]["mentions"].elements ?? []
        let mentionTarget = agent.flatMap { wanted in wanted == holder ? nil : wanted }
            ?? (agent == nil && Self.retriable(d["commentMeta"][commentID]["delivery"]) == false
                ? mentions.first(where: { $0["state"].string == "failed" })?["agentID"].string : nil)
        if let mentionTarget {
            guard let old = mentions.first(where: { $0["agentID"].string == mentionTarget }) else { throw NativeRPCError.invalidArguments("That agent was not asked in this comment.") }
            guard old["state"].string == "failed" else { return ok([("delivery", old)]) }
            return ok([("delivery", try await askAgent(task, commentID: commentID, body: body, by: by, to: mentionTarget))])
        }
        let receipt = d["commentMeta"][commentID]["delivery"]
        guard receipt["state"].string == "failed" || receipt["waiting"].bool == true || receipt.isNullish else { return ok([("delivery", receipt)]) }
        if task.isHeldByWorker {
            guard task.agentID != by else { return ok() }
            return try await deliverToAssignee(task, commentID: commentID, body: body, to: task.agentID, raw: false, by: by)
        }
        guard let back = task.value["handedFrom"].string, back != by else {
            throw NativeRPCError.invalidArguments("Nobody is assigned to answer this task. Assign it to an agent or Hoot first.")
        }
        return try await deliverToAssignee(task, commentID: commentID, body: body, to: back, raw: true, by: by)
    }

    func writeCommentReceipt(_ taskID: String, commentID: String, _ receipt: NativeRPCValue) async throws {
        let current = try await local.task(taskID)
        var d = detail(current)
        let meta = d["commentMeta"][commentID].isNullish ? NativeRPCValue.object([]) : d["commentMeta"][commentID]
        d = d.setting("commentMeta", d["commentMeta"].setting(commentID, meta.setting("delivery", receipt)))
        try await persist(current, d: d)
    }
}

// MARK: @mentions (#109): ask another agent or Hoot from the same thread.
extension BackendTaskDetailService {
    static func retriable(_ receipt: NativeRPCValue) -> Bool { receipt["state"].string == "failed" || receipt["waiting"].bool == true }

    /// Agents named in the comment: structured composer tokens first, then "@Name"
    /// written in the text (so an MCP or typed comment asks the same way).
    func mentionedAgents(_ body: String, structured: NativeRPCValue) async throws -> [String] {
        var found: [String] = []
        for row in structured.elements ?? [] where (row["kind"].string ?? "agent") == "agent" {
            guard let id = row["id"].string, !id.isEmpty else { continue }
            var resolved = id == "hoot" ? "hoot" : try await local.configuration.agent(id)?["id"].string
            // L4-AGENTS: a project's lead seat ("lead:<project id>"): the agent that leads, or the seat a session fills.
            if resolved == nil, BackendAGTLeadSeats.isAddress(id) { resolved = await BackendAGTLeadSeats.shared?.mentionTarget(id) }
            if let resolved, !found.contains(resolved) { found.append(resolved) }
        }
        let lower = body.lowercased()
        var named: [(String, String)] = [("hoot", "hoot")]
        for agent in try await local.configuration.allAgents() where agent["status"].string != "archived" {
            if let id = agent["id"].string, let name = agent["name"].string { named.append((id, name.lowercased())) }
        }
        for lead in await BackendAGTLeadSeats.shared?.named() ?? [] { named.append((lead.id, lead.name.lowercased())) }   // L4-AGENTS: session leads by name
        for (id, name) in named where !found.contains(id) && !name.isEmpty {
            var search = lower.startIndex..<lower.endIndex
            while let hit = lower.range(of: "@" + name, range: search) {
                let before = hit.lowerBound == lower.startIndex || lower[lower.index(before: hit.lowerBound)].isWhitespace
                let next: Character? = hit.upperBound < lower.endIndex ? lower[hit.upperBound] : nil
                if before && !(next?.isLetter == true || next?.isNumber == true || next == "-" || next == "_") { found.append(id); break }
                search = hit.upperBound..<lower.endIndex
            }
        }
        return found
    }

    /// Ask every mentioned agent other than the task's holder and the writer.
    /// `except`: the worker the comment was assigned to, which has been asked already.
    func deliverMentions(_ task: BackendTaskRecord, commentID: String, body: String, by: String, structured: NativeRPCValue, except: String? = nil) async throws -> [NativeRPCValue] {
        let holder = task.isHeldByWorker ? task.agentID : task.value["handedFrom"].string
        var receipts: [NativeRPCValue] = []
        for target in try await mentionedAgents(body, structured: structured) where target != holder && target != by && target != except {
            receipts.append(try await askAgent(task, commentID: commentID, body: body, by: by, to: target))
        }
        return receipts
    }

    /// "Ask Hoot instead": the same comment goes to Hoot as a question on this task.
    func askHootInstead(_ task: BackendTaskRecord, commentID: String, by: String) async throws -> NativeRPCValue {
        let d = detail(task)
        guard let row = (d["comments"].elements ?? []).first(where: { $0["id"].string == commentID }), let body = row["body"].string else {
            throw NativeRPCError.invalidArguments("That comment is no longer on this task")
        }
        guard row["authorUserId"].string == by else { throw NativeRPCError.invalidArguments("Only the person who wrote it can ask Hoot with it") }
        if task.assigneeKind == "hoot" { return try await retryCommentDelivery(task, commentID: commentID, by: by) }
        if let old = (d["commentMeta"][commentID]["mentions"].elements ?? []).first(where: { $0["agentID"].string == "hoot" }), !Self.retriable(old) {
            return ok([("delivery", old)])
        }
        return ok([("delivery", try await askAgent(task, commentID: commentID, body: body, by: by, to: "hoot"))])
    }

    /// A mentioned agent is asked through a small question task under this one,
    /// so it starts the normal way (its own session, account and settings). Its
    /// answer, posted with tasks_comment on that question, shows in this thread.
    func askAgent(_ task: BackendTaskRecord, commentID: String, body: String, by: String, to target: String) async throws -> NativeRPCValue {
        let name = (try? await people.named(target)["name"].string) ?? (target == "hoot" ? "Hoot" : target)
        let asker = by == "me" ? "The owner" : (try? await people.named(by)["name"].string) ?? "Someone"
        let title = String((task.value["title"].string ?? "a task").prefix(200))
        // Asking again: a question that never started is cleaned away (Trash) so
        // one comment never leaves two questions for the same agent; a live one is kept.
        let earlier = detail(try await local.task(task.id))["commentMeta"][commentID]["mentions"].elements?.first { $0["agentID"].string == target }
        if let oldID = earlier?["childTaskID"].string, let old = try await store.byID(oldID) {
            if old.sessionID != nil, earlier?["state"].string != "failed" { return earlier! }
            if old.sessionID == nil { try? await local.remove(oldID, by: by) }
        }
        let sentAt = BackendTaskValues.time()
        var receipt = BackendTaskCommentReceipt.sent(to: target, name: name, at: sentAt)
        seenAwaiting.insert(target)
        do {
            let input = BackendTaskValues.object([
                ("title", .string("Question on “\(title)”")),
                ("instructions", .string("\(asker) asked you this in a comment on the task “\(title)”:\n\n\(BackendTaskBriefComposition.quoted(body))\n\nYour answer is shown in that task's comments.")),
                ("assignee", .string(target)), ("project", .string(task.project))])
            let child = try await local.create(input, by: by, parentID: task.id)
            _ = try await store.update(child.id, patch: BackendTaskValues.object([("askedFromTask", .string(task.id)), ("askedFromComment", .string(commentID))]))
            receipt = receipt.setting("childTaskID", .string(child.id))
            let after = try await local.task(child.id)
            if let blocker = (after.value["notes"].elements ?? []).last(where: { $0["kind"].string == "blocker" && ($0["at"].number ?? 0) >= sentAt }) {
                receipt = BackendTaskCommentReceipt.failed(receipt, reason: blocker["text"].string ?? "It could not be reached.", at: BackendTaskValues.time())
            } else if target != "hoot", after.process == "queued", after.sessionID == nil {
                receipt = receipt.setting("waiting", .bool(true))
            } else {
                receipt = BackendTaskCommentReceipt.delivered(receipt, at: BackendTaskValues.time())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            receipt = BackendTaskCommentReceipt.failed(receipt, reason: error.localizedDescription, at: BackendTaskValues.time())
            // A question saved before its start failed stays linked to this comment, so
            // Try Again cleans it instead of leaving an unlinked task behind.
            if receipt["childTaskID"].isNullish, let orphan = try await store.all().first(where: {
                $0.value["parentTaskId"].string == task.id && $0.agentID == target && $0.value["askedFromTask"].isNullish
                    && ($0.value["createdAt"].number ?? 0) >= sentAt
            }) {
                _ = try? await store.update(orphan.id, patch: BackendTaskValues.object([("askedFromTask", .string(task.id)), ("askedFromComment", .string(commentID))]))
                receipt = receipt.setting("childTaskID", .string(orphan.id))
            }
        }
        let current = try await local.task(task.id)
        var d = detail(current)
        let meta = d["commentMeta"][commentID].isNullish ? NativeRPCValue.object([]) : d["commentMeta"][commentID]
        var list = (meta["mentions"].elements ?? []).filter { $0["agentID"].string != target }
        list.append(receipt)
        d = d.setting("commentMeta", d["commentMeta"].setting(commentID, meta.setting("mentions", .array(list))))
        try await persist(current, d: d)
        return receipt
    }

    /// The question tasks asked from this task's comments.
    func askedTasks(_ task: BackendTaskRecord) async throws -> [BackendTaskRecord] {
        try await store.all().filter { $0.value["askedFromTask"].string == task.id }
    }

    /// What the asked agent wrote on its question task, shown in this thread.
    static func askedAnswers(_ child: BackendTaskRecord) -> [NativeRPCValue] {
        let agent = child.agentID
        return (child.value["notes"].elements ?? []).compactMap { note in
            guard note["by"].string == agent, ["progress", "question", "blocker", "completion", "reply"].contains(note["kind"].string ?? ""),
                  let text = note["text"].string, let at = note["at"].number else { return nil }
            return BackendTaskValues.object([("id", .string("asked-\(child.id)-\(Int(at))")), ("authorUserId", .string(agent)), ("body", .string(text)), ("at", .number(at))])
        } + (child.value["detail"]["comments"].elements ?? []).compactMap { row in
            guard row["authorUserId"].string == agent, let id = row["id"].string else { return nil }
            return row.setting("id", .string("asked-" + id))
        }
    }

    /// A mention receipt moved on by its question task: answered once the agent
    /// writes; failed if the question was blocked before any answer.
    static func projectedMention(_ receipt: NativeRPCValue, asked: [BackendTaskRecord], thread: [NativeRPCValue]) -> NativeRPCValue {
        let answered = projectedDelivery(receipt, thread: thread)
        if answered["state"].string == "answered" { return answered }
        guard let childID = receipt["childTaskID"].string, let child = asked.first(where: { $0.id == childID }),
              ["delivered", "seen", "sent"].contains(receipt["state"].string ?? "") else { return receipt }
        let after = receipt["sentAt"].number ?? 0
        if let blocker = (child.value["notes"].elements ?? []).last(where: { $0["kind"].string == "blocker" && ($0["at"].number ?? 0) > after && $0["by"].string != child.agentID }) {
            return BackendTaskCommentReceipt.failed(receipt, reason: blocker["text"].string ?? "It could not be reached.", at: blocker["at"].number ?? after)
        }
        if receipt["waiting"].bool == true, child.sessionID != nil {
            return BackendTaskCommentReceipt.delivered(receipt, at: child.value["runStartedAt"].number ?? after)
        }
        return receipt
    }

    /// Who may be writing an answer right now: each recipient that has the
    /// comment and has not answered, with the session it works in. The app shows
    /// "<name> is writing…" while that session's live status is working (or, for
    /// Hoot, while Hoot's chat is busy), both from existing pushed events.
    func writingCandidates(_ task: BackendTaskRecord, thread: [NativeRPCValue]) async throws -> [NativeRPCValue] {
        var seen = Set<String>(), out: [NativeRPCValue] = []
        let asked = try await askedTasks(task)
        for row in thread {
            var receipts: [(NativeRPCValue, String?)] = []
            if row["delivery"].fields != nil { receipts.append((row["delivery"], task.sessionID)) }
            for mention in row["mentionDeliveries"].elements ?? [] {
                receipts.append((mention, asked.first { $0.id == mention["childTaskID"].string }?.sessionID))
            }
            for (receipt, session) in receipts where ["delivered", "seen"].contains(receipt["state"].string ?? "") {
                guard let agent = receipt["agentID"].string, seen.insert(agent).inserted else { continue }
                out.append(BackendTaskValues.object([("agentID", .string(agent)), ("name", receipt["agentName"]),
                    ("sessionID", session.map(NativeRPCValue.string) ?? .null), ("taskID", .string(task.id))]))
            }
        }
        // FORK-TASKS: the agent the task was given to, from the moment its session exists (not only
        // after a comment reached it). The app shows "<name> is writing…" while that session works.
        if task.assigneeKind == "agent", let session = task.sessionID, task.value["result"].isNullish, seen.insert(task.agentID).inserted {
            let name = (try? await people.named(task.agentID)["name"].string) ?? task.agentID
            out.append(BackendTaskValues.object([("agentID", .string(task.agentID)), ("name", .string(name)),
                ("sessionID", .string(session)), ("taskID", .string(task.id))]))
        }
        return out
    }
}

// MARK: "Seen" (#109): the recipient read the comment — its turn started on it.
extension BackendTaskDetailService {
    /// Keep the listeners that report a recipient starting its turn
    /// (`session:status` working; Hoot's chat busy). Cancelled on stop.
    public func retainCommentSeenFeeds(_ feeds: [NativeRPCSubscription]) { seenFeeds += feeds }

    /// A session went to working (`sessionID`), or Hoot's chat went busy (nil).
    /// Returns at once; the receipt is updated after any delivery in progress.
    public func noteRecipientWorking(sessionID: String?) {
        guard !seenClosed else { return }
        // Until the first signal has read what was already waiting (after a restart), keep every signal.
        if seenPrimed { guard !seenAwaiting.isEmpty, sessionID != nil || seenAwaiting.contains("hoot") else { return } }
        // Hoot's chat repeats "busy" for every streamed step: one queued signal per source is enough.
        guard !seenSignals.contains(where: { $0.session == sessionID }) else { return }
        seenSignals.append((sessionID, BackendTaskValues.time()))
        if seenJob == nil { seenJob = Task { [weak self] in await self?.applySeenSignals() } }
    }
    /// For tests and orderly callers: every queued "seen" signal is applied.
    public func settleSeen() async { while let job = seenJob { await job.value } }

    func applySeenSignals() async {
        if !seenPrimed { seenPrimed = true; seenAwaiting.formUnion((try? await awaitingRecipients()) ?? []) }
        while !seenSignals.isEmpty, !Task.isCancelled {
            let signal = seenSignals.removeFirst()
            do { try await markSeen(sessionID: signal.session, at: signal.at) } catch { await reportSeenFailure(error) }
        }
        seenJob = nil
    }

    func markSeen(sessionID: String?, at: Double) async throws {
        await enter(); defer { leave() }
        // (task holding the receipts, recipient, its question task when @asked)
        var targets: [(task: BackendTaskRecord, agent: String, child: String?)] = []
        if let sessionID {
            guard let worker = try await store.bySession(sessionID), worker.isLocal, seenAwaiting.contains(worker.agentID) else { return }
            if let parentID = worker.value["askedFromTask"].string, let parent = try await store.byID(parentID) {
                targets.append((parent, worker.agentID, worker.id))
            } else { targets.append((worker, worker.agentID, nil)) }
        } else {
            for task in try await store.all() where task.isLocal && !detail(task)["commentMeta"].isNullish {
                targets.append((task, "hoot", nil))
            }
        }
        var stillAwaiting = Set<String>()
        for target in targets {
            let current = try await local.task(target.task.id)
            var d = detail(current), meta = d["commentMeta"], touched = false
            for field in meta.fields ?? [] {
                var entry = field.value
                let primary = entry["delivery"]
                if primary["agentID"].string == target.agent, target.child == nil, Self.unread(primary, before: at) {
                    entry = entry.setting("delivery", BackendTaskCommentReceipt.seen(primary, at: at)); touched = true
                }
                if var mentions = entry["mentions"].elements {
                    for index in mentions.indices where mentions[index]["agentID"].string == target.agent && Self.unread(mentions[index], before: at)
                        && (target.child == nil || mentions[index]["childTaskID"].string == target.child) {
                        mentions[index] = BackendTaskCommentReceipt.seen(mentions[index], at: at); touched = true
                    }
                    entry = entry.setting("mentions", .array(mentions))
                }
                if touched { meta = meta.setting(field.key, entry) }
            }
            if touched { d = d.setting("commentMeta", meta); try await persist(current, d: d) }
        }
        // Forget a recipient once nothing it was sent is still unread anywhere.
        stillAwaiting = try await awaitingRecipients()
        seenAwaiting = seenAwaiting.intersection(stillAwaiting)
    }
    /// Every recipient with a comment it has not read yet.
    func awaitingRecipients() async throws -> Set<String> {
        var found = Set<String>()
        for task in try await store.all() where task.isLocal {
            for field in detail(task)["commentMeta"].fields ?? [] {
                for receipt in [field.value["delivery"]] + (field.value["mentions"].elements ?? []) {
                    if let agent = receipt["agentID"].string, ["sent", "delivered"].contains(receipt["state"].string ?? "") { found.insert(agent) }
                }
            }
        }
        return found
    }
    /// Delivered (or handed over) before this signal, not yet read.
    static func unread(_ receipt: NativeRPCValue, before at: Double) -> Bool {
        ["sent", "delivered"].contains(receipt["state"].string ?? "") && (receipt["sentAt"].number ?? .infinity) <= at
    }
}
