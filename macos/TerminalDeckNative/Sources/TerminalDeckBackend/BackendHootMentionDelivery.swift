import Foundation
import TerminalDeckNativeCore

/// L8 MENTION-DELIVERY API (11 Oct 2026): an "@agent" in Hoot's chat really wakes that agent.
///
/// There is ONE delivery path and it is the Tasks one: the message becomes a comment on a small carrier
/// task ("Asked from Hoot's chat") and `BackendTaskDetailService.addComment → deliverMentions → askAgent`
/// does the rest exactly as for a task comment: a question task for the agent, started the normal way
/// (its own session, account, settings, memory), with the same receipts and the same Try again.
/// What this file adds is only what the chat needs around it: the SEAT is addressed (a filled seat goes to
/// who fills it, a vacant seat that still holds memory goes to L4's `requestFill`, a lead that is a running
/// session is told in that session), and each mention gets one plain receipt.
public struct BackendHootMentionReceipt: Sendable, Codable, Equatable {
    /// The mention's id exactly as the chat sent it (an agent id or a seat key such as `role:crm/ios-engineer`).
    public var id: String
    /// Who it went to: the agent's name, or who was asked to fill the seat.
    public var name: String
    /// The seat that was addressed (`AGTSeat.key`), when known.
    public var seat: String?
    /// started · awake · queued · asked-to-fill · failed
    /// - started: the agent was asleep and a session was started for this message.
    /// - awake: it was already running and got the message.
    /// - queued: it is busy (or at its limit); the question starts as soon as it is free.
    /// - asked-to-fill: the seat is vacant; its lead (or Hoot) was asked to fill it.
    /// - failed: nothing was delivered; `detail` says why.
    public var outcome: String
    /// One plain sentence for the receipt under the message.
    public var detail: String
    /// The question task that carries the message (open it in Tasks to follow the answer), when there is one.
    public var taskID: String?
    /// The session that got it, when there is one.
    public var sessionID: String?
    /// Milliseconds since 1970.
    public var at: Double
    public var delivered: Bool { outcome != "failed" }
    /// The key of this one delivery: what `BackendHootMentionAnswer.receiptID` and the answered signal carry.
    /// It is the question task's id when there is one (so it survives an app restart), else a one-off id.
    public var receiptID: String = "m-" + UUID().uuidString.lowercased()

    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("seat", seat.map(NativeRPCValue.string) ?? .null),
                 .init("outcome", .string(outcome)), .init("detail", .string(detail)), .init("taskID", taskID.map(NativeRPCValue.string) ?? .null),
                 .init("sessionID", sessionID.map(NativeRPCValue.string) ?? .null), .init("at", .number(at)), .init("delivered", .bool(delivered)),
                 .init("receiptID", .string(receiptID))])
    }
}

/// "<seat> answered": the mentioned agent wrote its answer on the question task that carried the message.
public struct BackendHootMentionAnswer: Sendable, Codable, Equatable {
    /// The delivery this answers (`BackendHootMentionReceipt.receiptID`).
    public var receiptID: String
    /// The mention's id as the chat sent it, who answered, and the seat (when the delivery is still known).
    public var id: String
    public var name: String
    public var seat: String?
    /// Open this in Tasks to read the whole answer: the question task, and the answer's own row id in its thread.
    public var taskID: String
    public var commentID: String
    /// The answer's first line, at most 160 characters.
    public var preview: String
    /// Milliseconds since 1970.
    public var at: Double
    public var wireValue: NativeRPCValue {
        .object([.init("receiptID", .string(receiptID)), .init("id", .string(id)), .init("name", .string(name)), .init("seat", seat.map(NativeRPCValue.string) ?? .null),
                 .init("taskID", .string(taskID)), .init("commentID", .string(commentID)), .init("preview", .string(preview)), .init("at", .number(at))])
    }
}
public extension Notification.Name {
    /// Posted on the main thread when a mentioned agent answers; `userInfo["answer"]` is a `BackendHootMentionAnswer`.
    static let hootMentionAnswered = Notification.Name("dev.terminaldeck.hoot.mention-answered")
    /// Posted on the main thread when the delivery service has been installed.
    static let hootMentionDeliveryReady = Notification.Name("dev.terminaldeck.hoot.mention-delivery-ready")
}

public final class BackendHootMentionDelivery: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: BackendHootMentionDelivery?
    /// Installed by composition once Tasks exist. Nil before that: the chat shows "agents are still starting".
    public static var shared: BackendHootMentionDelivery? {
        get { lock.withLock { installed } }
        set {
            lock.withLock { installed = newValue }
            // L6: whoever waits for the service (Hoot's late-answer pass at start) hears when it is there.
            if newValue != nil { Task { await BackendMemoryEvents.shared.publish("hoot:mention-delivery-ready") } }
        }
    }

    private let state = NSLock()
    nonisolated(unsafe) private var waiting: [String: BackendHootMentionReceipt] = [:]     // by question task id
    nonisolated(unsafe) private var known: [String: BackendHootMentionAnswer] = [:]        // by receipt id
    nonisolated(unsafe) private var listeners: [UUID: AsyncStream<BackendHootMentionAnswer>.Continuation] = [:]
    private let detail: BackendTaskDetailService
    private let sessions: @Sendable () -> [BackendSessionMeta]
    private let tell: @Sendable (_ sessionID: String, _ line: String) async throws -> Void
    private let projects: @Sendable () async -> [PROJProject]

    /// - tell: types one line into a running session through the app's existing checked delivery
    ///   (the same one a task brief uses); used only for a lead that is a session.
    public init(detail: BackendTaskDetailService, sessions: @escaping @Sendable () -> [BackendSessionMeta],
                tell: @escaping @Sendable (_ sessionID: String, _ line: String) async throws -> Void,
                projects: @escaping @Sendable () async -> [PROJProject]) {
        self.detail = detail; self.sessions = sessions; self.tell = tell; self.projects = projects
    }

    /// Deliver one chat message to everyone it mentions. `context` is the message's own context wire
    /// (`BackendHOOTSIMChatContext.value`: `{mentions:[{kind,id,name,project?}], source}`); `@name` written in
    /// the text without a structured mention is found the same way a task comment finds it.
    /// Never throws: every mention comes back with a receipt.
    public func deliver(text: String, context: NativeRPCValue, by: String = "me") async -> [BackendHootMentionReceipt] {
        let now = BackendTaskValues.time()
        var receipts: [BackendHootMentionReceipt] = [], agents: [NativeRPCValue] = [], asked: [String: (mention: String, seat: String?)] = [:]
        let projects = await projects()
        let all = (try? await detail.local.configuration.allAgents())?.filter { $0["status"].string != "archived" } ?? []
        func fail(_ id: String, _ name: String, _ seat: String?, _ why: String) {
            receipts.append(.init(id: id, name: name, seat: seat, outcome: "failed", detail: why, taskID: nil, sessionID: nil, at: now))
        }
        func queue(_ agentID: String, mention: String, seat: String?) {
            guard asked[agentID] == nil else { return }
            asked[agentID] = (mention, seat); agents.append(.object([.init("kind", .string("agent")), .init("id", .string(agentID))]))
        }
        for row in context["mentions"].elements ?? [] where (row["kind"].string ?? "agent") == "agent" {
            guard let id = row["id"].string, !id.isEmpty, id != "hoot" else { continue }
            let shown = row["name"].string ?? id
            // A saved agent: its seat is where its memory lives; the message goes to the agent filling it.
            if let agent = all.first(where: { $0["id"].string == id }) {
                queue(id, mention: id, seat: Self.seat(of: agent, all: all, projects: projects)?.key); continue
            }
            guard let seat = AGTSeat(key: id) else { fail(id, shown, nil, "\(shown) is no longer one of your agents."); continue }
            switch seat {
            case .orchestrator: continue   // this IS Hoot's chat
            case .lead(let projectID):
                guard let project = projects.first(where: { $0.id == projectID }) else { fail(id, shown, seat.key, "That project no longer exists."); continue }
                guard let lead = AGTSeats.lead(of: project) else { receipts.append(await fill(seat, mention: id, shown: shown, note: text, by: by, at: now)); continue }
                if lead.kind == .agent { queue(lead.id, mention: id, seat: seat.key); continue }
                // The lead is a session the person started himself: awake by definition, told in its own session.
                let running = sessions().filter { $0.exitCode == nil }
                guard let session = running.first(where: { $0.id == lead.id })
                        ?? running.first(where: { $0.resolvedProjectID == project.id && $0.title.caseInsensitiveCompare(lead.name) == .orderedSame }) else {
                    fail(id, lead.name, seat.key, "\(lead.name) is not running right now. Open its session, then send this again."); continue
                }
                do {
                    try await tell(session.id, Self.line(for: text, by: by))
                    receipts.append(.init(id: id, name: lead.name, seat: seat.key, outcome: "awake", detail: "Sent to \(lead.name), which was already running.", taskID: nil, sessionID: session.id, at: BackendTaskValues.time()))
                    await Self.stamp(seat: seat, text: text, by: by, session: session.id, task: nil, hire: lead.name)
                } catch { fail(id, lead.name, seat.key, "\(lead.name) could not be told: \(error.localizedDescription)") }
            case .role:
                let holders = all.filter { Self.seat(of: $0, all: all, projects: projects)?.key == seat.key }
                if let holder = holders.first, let holderID = holder["id"].string { queue(holderID, mention: id, seat: seat.key) }
                else { receipts.append(await fill(seat, mention: id, shown: shown, note: text, by: by, at: now)) }
            }
        }
        // The ONE path: a comment on the carrier task; Tasks' own mention delivery asks each agent.
        let named = Self.namedInText(text, all: all).filter { asked[$0] == nil }
        if !agents.isEmpty || !named.isEmpty {
            do {
                let deliveries = try await detail.askFromHootChat(text: text, mentions: agents, by: by)
                for delivery in deliveries {
                    guard let agentID = delivery["agentID"].string else { continue }
                    let origin = asked[agentID], agent = all.first { $0["id"].string == agentID }
                    let seat = origin?.seat ?? agent.flatMap { Self.seat(of: $0, all: all, projects: projects)?.key }
                    var receipt = await receipt(delivery, mention: origin?.mention ?? agentID, seat: seat, sentAt: now)
                    if let taskID = receipt.taskID { receipt.receiptID = taskID; if receipt.delivered { state.withLock { waiting[taskID] = receipt } } }
                    receipts.append(receipt)
                    if receipt.delivered, let seat, let parsed = AGTSeat(key: seat) {
                        await Self.stamp(seat: parsed, text: text, by: by, session: receipt.sessionID, task: receipt.taskID, hire: receipt.name)
                    }
                }
                for (agentID, origin) in asked where !deliveries.contains(where: { $0["agentID"].string == agentID }) {
                    let name = all.first { $0["id"].string == agentID }?["name"].string ?? agentID
                    fail(origin.mention, name, origin.seat, "\(name) was not asked. Try again.")
                }
            } catch {
                for (agentID, origin) in asked {
                    let name = all.first { $0["id"].string == agentID }?["name"].string ?? agentID
                    fail(origin.mention, name, origin.seat, "\(name) could not be asked: \(error.localizedDescription)")
                }
            }
        }
        return receipts
    }

    // MARK: Answered
    /// Every answer as it arrives (each call is its own stream). The same answers are published on `hoot:mention-answered`.
    public func answers() -> AsyncStream<BackendHootMentionAnswer> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { self?.listeners[id] = nil } }
        }
    }
    /// The answer to one delivery, read from the question task itself (works after an app restart; nil = not answered yet).
    public func answer(receiptID: String) async -> BackendHootMentionAnswer? {
        if let cached = state.withLock({ known[receiptID] }) { return cached }
        guard receiptID.hasPrefix("local:") || !receiptID.hasPrefix("m-") else { return nil }
        return await read(taskID: receiptID, receipt: state.withLock { waiting[receiptID] })
    }
    /// Composition calls this on every task change (an event, never a timer): deliveries still waiting are looked at once.
    public func tasksChanged() async {
        for (taskID, receipt) in state.withLock({ waiting }) {
            guard let answer = await read(taskID: taskID, receipt: receipt) else { continue }
            let fresh = state.withLock { () -> Bool in
                guard known[answer.receiptID] == nil else { return false }
                known[answer.receiptID] = answer; waiting[taskID] = nil
                if known.count > 512 { known = known.filter { $0.value.at > answer.at - 86_400_000 } }
                return true
            }
            guard fresh else { continue }
            for listener in state.withLock({ Array(listeners.values) }) { listener.yield(answer) }
            if let value = try? NativeRPCValue.parseJSON(JSONEncoder().encode(answer)) {
                await BackendMemoryEvents.shared.publish("hoot:mention-answered", arguments: [value])
            }
        }
    }
    private func read(taskID: String, receipt: BackendHootMentionReceipt?) async -> BackendHootMentionAnswer? {
        guard let child = try? await detail.store.byID(taskID), child.value["askedFromTask"].string != nil else { return nil }
        // The agent's own words: its finished answer, else what it wrote back (a reply, a question, a blocker).
        // The engine's own "… started on this." progress line is not an answer.
        let agent = child.agentID
        let written = (child.value["notes"].elements ?? []).filter { note in
            note["by"].string == agent && ["completion", "reply", "question", "blocker"].contains(note["kind"].string ?? "") && !(note["text"].string ?? "").isEmpty
        }
        let body: String, at: Double
        if let answer = child.value["result"]["answer"].string, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = answer; at = child.value["result"]["at"].number ?? BackendTaskValues.time()
        } else if let note = written.last, let text = note["text"].string, let when = note["at"].number {
            body = text; at = when
        } else if let comment = (child.value["detail"]["comments"].elements ?? []).last(where: { $0["authorUserId"].string == agent }),
                  let text = comment["body"].string, let when = comment["at"].number {
            body = text; at = when
        } else { return nil }
        // The row the asking thread shows for it (Tasks' own id for an asked answer).
        let shown = BackendTaskDetailService.askedAnswers(child).last(where: { $0["body"].string == body })
            ?? BackendTaskDetailService.askedAnswers(child).max(by: { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) })
        let last: NativeRPCValue = shown ?? .object([])
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var name = receipt?.name ?? ""
        if name.isEmpty {
            let agent = try? await detail.local.configuration.agent(child.agentID)
            name = agent?["name"].string ?? child.agentID
        }
        return .init(receiptID: taskID, id: receipt?.id ?? child.agentID, name: name, seat: receipt?.seat, taskID: taskID,
                     commentID: last["id"].string ?? "", preview: line.count > 160 ? String(line.prefix(159)) + "…" : line, at: at)
    }

    /// One Tasks receipt (sent / delivered / failed, waiting) in the chat's words, with "started or already awake".
    private func receipt(_ delivery: NativeRPCValue, mention: String, seat: String?, sentAt: Double) async -> BackendHootMentionReceipt {
        let name = delivery["agentName"].string ?? mention, taskID = delivery["childTaskID"].string
        var out = BackendHootMentionReceipt(id: mention, name: name, seat: seat, outcome: "failed", detail: "", taskID: taskID, sessionID: nil, at: BackendTaskValues.time())
        if delivery["state"].string == "failed" {
            out.detail = "\(name) did not get it: " + (delivery["error"].string ?? "it could not be reached.")
            return out
        }
        let child: BackendTaskRecord?
        if let taskID { child = try? await detail.store.byID(taskID) } else { child = nil }
        out.sessionID = child?.sessionID
        if delivery["waiting"].bool == true || (child?.process == "queued" && child?.sessionID == nil) {
            out.outcome = "queued"; out.detail = "\(name) is busy. It gets this as soon as it is free."
            return out
        }
        // A worker kept open from its last job answers in the same session (already awake); otherwise one was started.
        let session = out.sessionID.flatMap { id in sessions().first { $0.id == id } }
        if let session, session.createdAt < sentAt - 1_000 { out.outcome = "awake"; out.detail = "Sent to \(name), which was already running." }
        else { out.outcome = "started"; out.detail = "\(name) was asleep. It was started and given the message." }
        return out
    }

    /// A vacant seat that still holds memory: nothing is hired here, its lead (or Hoot) is asked to fill it.
    private func fill(_ seat: AGTSeat, mention: String, shown: String, note: String, by: String, at: Double) async -> BackendHootMentionReceipt {
        guard let service = BackendAGTHandsService.shared else {
            return .init(id: mention, name: shown, seat: seat.key, outcome: "failed", detail: "Agents are still starting. Try again in a moment.", taskID: nil, sessionID: nil, at: at)
        }
        do {
            let reply = try await service.requestFill(seat: seat.owner, note: String(note.prefix(600)), by: by == "me" ? "You" : by)
            let who = reply["name"].string ?? "Hoot", title = reply["seatTitle"].string ?? shown
            return .init(id: mention, name: who, seat: seat.key, outcome: "asked-to-fill",
                         detail: "Nobody fills \"\(title)\" right now. \(who) was asked to fill it; whoever is hired inherits its memory.",
                         taskID: reply["task"].string, sessionID: reply["session"].string, at: BackendTaskValues.time())
        } catch {
            return .init(id: mention, name: shown, seat: seat.key, outcome: "failed", detail: "The request to fill \"\(shown)\" was not sent: \(error.localizedDescription)", taskID: nil, sessionID: nil, at: at)
        }
    }

    // MARK: Helpers
    /// The seat a saved agent fills (its project's lead seat, or its role), the way L4 resolves it.
    static func seat(of agent: NativeRPCValue, all: [NativeRPCValue], projects: [PROJProject]) -> AGTSeat? {
        guard let id = agent["id"].string else { return nil }
        let owner = BackendAGTMemoryOwners.resolve(profileID: id, claudeAgent: nil, projectID: nil, folder: nil, sessionID: nil, sessionTitle: nil, projects: projects, agents: all)
        return BackendAGTMemoryOwners.seat(owner)
    }
    /// Agents named with "@name" in the text (the same rule Tasks uses), to know whether there is anything to ask.
    static func namedInText(_ text: String, all: [NativeRPCValue]) -> [String] {
        let lower = text.lowercased()
        return all.compactMap { agent in
            guard let id = agent["id"].string, let name = agent["name"].string?.lowercased(), !name.isEmpty, lower.contains("@" + name) else { return nil }
            return id
        }
    }
    static func line(for text: String, by: String) -> String {
        let flat = text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return "[Terminal Deck] " + (by == "me" ? "The owner" : by) + " mentioned you in Hoot's chat: " + String(flat.prefix(3_500))
    }
    /// The diary: the PERSON wrote the message; the delivery is the APP's. Two rows on the seat's own diary.
    static func stamp(seat: AGTSeat, text: String, by: String, session: String?, task: String?, hire: String) async {
        guard DeckMemory.isReady else { return }
        let stamp = DeckMemoryStamp(owner: seat.owner, project: seat.projectID, session: session, agent: hire)
        var meta = ["from": "hoot-chat", "deliveredTo": hire]
        if let task { meta["task"] = task }
        _ = try? await DeckMemory.store.appendDiary([
            DeckMemoryDiaryDraft(stamp: stamp, role: .user, text: text, meta: meta, author: by == "me" ? .person : .orchestrator),
            DeckMemoryDiaryDraft(stamp: stamp, role: .event, text: "Delivered by the app from Hoot's chat to \(hire).", meta: meta, author: .app),
        ])
    }
}

extension BackendTaskDetailService {
    /// The message as a comment on the one carrier task, with its mentions: the existing
    /// `addComment → deliverMentions → askAgent` path, nothing else. Returns Tasks' own mention receipts.
    func askFromHootChat(text: String, mentions: [NativeRPCValue], by: String) async throws -> [NativeRPCValue] {
        let marker = "hootChatMentions"
        let carrier: BackendTaskRecord
        if let existing = try await store.all().first(where: { $0.value[marker].bool == true && $0.value["trashedAt"].isNullish && $0.value["archived"].bool != true }) {
            carrier = existing
        } else {
            let made = try await local.create(BackendTaskValues.object([
                ("title", .string("Asked from Hoot's chat")),
                ("instructions", .string("Kept by the app. Each message in Hoot's chat that @mentions an agent is a comment here, and each agent's answer shows under it.")),
                ("assignee", .string("none"))]), by: by)
            _ = try await store.update(made.id, patch: BackendTaskValues.object([(marker, .bool(true))]))
            carrier = try await local.task(made.id)
        }
        // A comment holds 2,000 characters; a longer chat message is cut for the agent and says so.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.utf16.count <= 1_900 ? trimmed : String(trimmed.prefix(1_800)) + " … (cut here; the whole message is in Hoot's chat)"
        let reply = try await addComment(carrier, body: .string(body), options: BackendTaskValues.object([("mentions", .array(mentions))]), by: by)
        return reply["mentionDeliveries"].elements ?? []
    }
}
