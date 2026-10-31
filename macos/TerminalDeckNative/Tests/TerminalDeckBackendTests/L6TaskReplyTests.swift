import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// #109: a comment on a task held by an agent or Hoot reaches it, and its
/// receipt moves sent → delivered → answered once it answers in the thread.
/// Memory stores and a stub engine only: no session, no AI, no files.
actor L6TaskReplyEngine: BackendTaskExecuting {
    enum Mode: Sendable { case deliver, throwing(String), blockerNote(String), queue }
    let store: BackendTaskStore
    var mode: Mode = .deliver
    var replies: [(String, String)] = []
    var accepted: [String] = [], acceptError: String?
    /// Runs while the reply is being handed over (Hoot's chat going busy mid-send).
    var onReply: (@Sendable () async -> Void)?
    func setOnReply(_ hook: (@Sendable () async -> Void)?) { onReply = hook }
    init(store: BackendTaskStore) { self.store = store }
    func set(_ mode: Mode) { self.mode = mode }
    func failAccept(_ reason: String?) { acceptError = reason }
    func accept(_ id: String) async throws {
        if let acceptError { throw NativeRPCError(code: "unavailable", message: acceptError) }
        accepted.append(id); _ = try await store.update(id, patch: crmParityValue(["process": "idle"]))
    }
    func reassign(_ id: String, assignee: NativeRPCValue) async throws {
        _ = try await store.update(id, patch: .object([.init("assignee", assignee), .init("mainAssignee", assignee["identity"])]))
    }
    func reply(_ id: String, text: String) async throws {
        switch mode {
        case .deliver: replies.append((id, text)); await onReply?()
        case .throwing(let reason): throw NativeRPCError(code: "unavailable", message: reason)
        case .blockerNote(let text): try await store.note(id, by: "hoot", kind: "blocker", text: text)
        case .queue: replies.append((id, text)); _ = try await store.update(id, patch: crmParityValue(["process": "queued"]))
        }
    }
    func cancel(_ id: String, reason: String) {}
}

@Suite struct L6TaskReplyTests {
    struct Rig {
        let store: BackendTaskStore, local: BackendTaskLocalService, detail: BackendTaskDetailService, engine: L6TaskReplyEngine
        func make(_ assignee: String) async throws -> String {
            try await local.create(crmParityValue(["title": "Sign-in button does nothing", "assignee": assignee, "status": "To-Do", "project": "/work/crm"]), by: "me").id
        }
        func call(_ fn: String, _ args: NativeRPCValue..., by: String = "me") async -> NativeRPCValue { await detail.call(fn, arguments: args, by: by) }
        func comments(_ id: String) async -> [NativeRPCValue] { await call("listTaskComments", .string(id))["comments"].elements ?? [] }
    }
    /// Every read of the task clock moves it on a second, so "after" is never a tie.
    static func clocked(_ body: @Sendable () async throws -> Void) async throws {
        let clock = BackendCrmTaskClockParityVirtualClock()
        clock.set(BackendCrmTime.parseInstant("2026-10-10T10:00:00Z")!.timeIntervalSince1970 * 1000); clock.setReadStep(1000)
        try await BackendTaskClockContext.withClock(clock) { try await body() }
    }
    static func rig() async throws -> Rig {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/l6-task-reply-inert.noindex"), ownership: .memory)
        let store = BackendTaskStore(persistence: persistence, changed: {})
        let engine = L6TaskReplyEngine(store: store)
        let config = try BackendTaskConfiguration(persistence: persistence), goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(crmParityValue(["id": "portal-mechanic", "name": "portal-mechanic", "maxRunMinutes": 0, "keepAliveMinutes": 0]))
        _ = try await config.saveAgent(crmParityValue(["id": "portal-reviewer", "name": "portal-reviewer", "maxRunMinutes": 0, "keepAliveMinutes": 0]))
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        let detail = BackendTaskDetailService(store: store, local: local, people: .native(configuration: config), problem: { _ in })
        return Rig(store: store, local: local, detail: detail, engine: engine)
    }

    @Test func authenticatedTaskAgentPostsAsItsProfileAndDoesNotWakeItself() async throws {
        let r = try await Self.rig(), id = try await r.make("portal-mechanic")
        let posted = await r.call("addTaskComment", .string(id), .string("PONG"), by: "taskagent:portal-mechanic")
        #expect(posted["id"].string != nil)
        let comments = await r.comments(id)
        let own = comments.first { $0["body"].string == "PONG" }
        #expect(own?["authorUserId"].string == "portal-mechanic")
        #expect(own?["authorName"].string == "portal-mechanic")
        #expect(own?["authorKind"].string == "agent")
        let echoes = await r.engine.replies
        #expect(echoes.isEmpty)
    }
    @Test func plainCommentReachesTheAgentAndItsAnswerLandsInTheThread() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            let posted = await r.call("addTaskComment", .string(id), .string("Also check it in Safari"))
            #expect(posted["ok"].bool == true)
            // No @mention needed: the assignee gets it, told where to answer.
            let sent = await r.engine.replies
            #expect(sent.count == 1 && sent[0].1.hasPrefix("Also check it in Safari") && sent[0].1.contains("tasks_comment"))
            var mine = try #require(await r.comments(id).first { $0["body"].string == "Also check it in Safari" })
            #expect(mine["delivery"]["state"].string == "delivered" && mine["delivery"]["agentName"].string == "portal-mechanic")
            #expect(mine["delivery"]["deliveredAt"].number != nil && mine["delivery"]["seenAt"].isNullish)
            // The agent answers through tasks_comment (a task note): same thread, receipt becomes seen/answered.
            try await r.store.note(id, by: "portal-mechanic", kind: "progress", text: "Done. Works in Safari too.")
            let thread = await r.comments(id)
            mine = try #require(thread.first { $0["body"].string == "Also check it in Safari" })
            #expect(mine["delivery"]["state"].string == "answered" && mine["delivery"]["seenAt"].number != nil)
            let answer = try #require(thread.first { $0["body"].string == "Done. Works in Safari too." })
            #expect(answer["authorKind"].string == "agent" && answer["authorName"].string == "portal-mechanic")
            #expect(mine["authorKind"].string == "human")
            let listed = await r.call("listTaskComments", .string(id))
            #expect(listed["deliveryAvailable"].bool == true && listed["capabilities"]["retry"].bool == true && listed["capabilities"]["askHoot"].bool == true && listed["capabilities"]["mentions"].bool == true)
        }
    }

    @Test func hootTaskCommentIsDeliveredAndAnAgentNeverMessagesItself() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("hoot")
            _ = await r.call("addTaskComment", .string(id), .string("What is left?"))
            let replies1 = await r.engine.replies
            #expect(replies1.count == 1)
            // Hoot writing in its own task is an answer, not a new delivery to itself.
            _ = await r.call("addTaskComment", .string(id), .string("Only the test is left."), by: "hoot")
            let replies2 = await r.engine.replies
            #expect(replies2.count == 1)
            let thread = await r.comments(id)
            #expect(thread.first { $0["body"].string == "What is left?" }?["delivery"]["state"].string == "answered")
            #expect(thread.first { $0["body"].string == "Only the test is left." }?["authorKind"].string == "hoot")
            #expect(thread.first { $0["body"].string == "Only the test is left." }?["delivery"].isNullish == true)
        }
    }

    @Test func failureIsShownAndTryAgainUsesTheSameComment() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("hoot")
            await r.engine.set(.blockerNote("Hoot is not running on this Mac, so this task is waiting for it."))
            let posted = await r.call("addTaskComment", .string(id), .string("Are you there?"))
            #expect(posted["ok"].bool == true && (posted["warning"].string ?? "").contains("could not reach Hoot"))
            var mine = try #require(await r.comments(id).first { $0["body"].string == "Are you there?" })
            #expect(mine["delivery"]["state"].string == "failed" && (mine["delivery"]["error"].string ?? "").contains("not running"))
            let commentID = try #require(mine["id"].string)
            // Only its writer may retry it.
            #expect(await r.call("retryCommentDelivery", .string(id), .string(commentID), by: "portal-mechanic")["ok"].bool == false)
            await r.engine.set(.deliver)
            #expect(await r.call("retryCommentDelivery", .string(id), .string(commentID))["ok"].bool == true)
            let thread = await r.comments(id)
            mine = try #require(thread.first { $0["body"].string == "Are you there?" })
            #expect(mine["delivery"]["state"].string == "delivered")
            #expect(thread.filter { $0["body"].string == "Are you there?" }.count == 1)
            let replies3 = await r.engine.replies
            #expect(replies3.count == 1)
            // A delivered comment is not sent twice.
            _ = await r.call("retryCommentDelivery", .string(id), .string(commentID))
            let replies4 = await r.engine.replies
            #expect(replies4.count == 1)
        }
    }

    @Test func thrownSendFailsAndQueuedWorkerWaits() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            await r.engine.set(.throwing("The agent's account is signed out."))
            _ = await r.call("addTaskComment", .string(id), .string("First"))
            #expect(await r.comments(id).first { $0["body"].string == "First" }?["delivery"]["state"].string == "failed")
            await r.engine.set(.queue)
            _ = await r.call("addTaskComment", .string(id), .string("Second"))
            let waiting = try #require(await r.comments(id).first { $0["body"].string == "Second" })
            #expect(waiting["delivery"]["state"].string == "sent" && waiting["delivery"]["waiting"].bool == true)
        }
    }

    @Test func unassignedTaskCommentStaysOnlyAComment() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("me")
            #expect(await r.call("addTaskComment", .string(id), .string("Note to self"))["ok"].bool == true)
            let replies5 = await r.engine.replies
            #expect(replies5.isEmpty)
            #expect(await r.comments(id).first?["delivery"].isNullish == true)
        }
    }

    // MARK: @mentions and the writing candidates (#109 part 2)
    static func asked(_ r: Rig, _ id: String) async throws -> [BackendTaskRecord] {
        try await r.store.all().filter { $0.value["askedFromTask"].string == id }
    }

    @Test func mentionedAgentIsAskedWithItsOwnReceiptAndAnswersInTheThread() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            let body = "@portal-reviewer please check the diff"
            let posted = await r.call("addTaskCommentWith", .string(id), .string(body),
                crmParityValue(["mentions": [["id": "portal-reviewer", "kind": "agent", "name": "portal-reviewer", "project": ""]]]))
            #expect(posted["ok"].bool == true)
            let replies = await r.engine.replies, accepted = await r.engine.accepted
            #expect(replies.count == 1)
            let children = try await Self.asked(r, id)
            #expect(children.count == 1)
            let child = try #require(children.first)
            #expect(child.agentID == "portal-reviewer" && accepted.contains(child.id) && child.value["parentTaskId"].string == id)
            var thread = await r.comments(id)
            var mine = try #require(thread.first { $0["body"].string == body })
            #expect(mine["mentionDeliveries"].elements?.first?["agentID"].string == "portal-reviewer")
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "delivered")
            let listed = await r.call("listTaskComments", .string(id))
            let candidates = Set(listed["writingCandidates"].elements?.compactMap { $0["agentID"].string } ?? [])
            #expect(candidates == ["portal-mechanic", "portal-reviewer"])
            // The reviewer answers on its question task with tasks_comment: shown here, receipt answered.
            try await r.store.note(child.id, by: "portal-reviewer", kind: "completion", text: "Diff looks right.")
            thread = await r.comments(id)
            #expect(thread.contains { $0["body"].string == "Diff looks right." && $0["authorKind"].string == "agent" && $0["authorUserId"].string == "portal-reviewer" })
            mine = try #require(thread.first { $0["body"].string == body })
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "answered")
            #expect(mine["delivery"]["state"].string == "delivered")
            let after = await r.call("listTaskComments", .string(id))
            #expect((after["writingCandidates"].elements ?? []).compactMap { $0["agentID"].string } == ["portal-mechanic"])
        }
    }

    @Test func typedMentionAndAskHootInsteadUseTheSamePath() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            // Typed "@Hoot" (as an MCP caller writes it), no composer token.
            _ = await r.call("addTaskComment", .string(id), .string("What do you think, @Hoot?"))
            var hoot = try await Self.asked(r, id).filter { $0.assigneeKind == "hoot" }
            #expect(hoot.count == 1)
            // Naming the holder or yourself asks nobody extra.
            _ = await r.call("addTaskComment", .string(id), .string("@portal-mechanic go on"))
            let all = try await Self.asked(r, id)
            #expect(all.count == 1)
            await r.engine.set(.throwing("signed out"))
            _ = await r.call("addTaskComment", .string(id), .string("Anyone?"))
            let failed = try #require(await r.comments(id).first { $0["body"].string == "Anyone?" })
            #expect(failed["delivery"]["state"].string == "failed")
            let cid = try #require(failed["id"].string)
            let asked = await r.call("askHootInstead", .string(id), .string(cid))
            #expect(asked["ok"].bool == true)
            let again = try #require(await r.comments(id).first { $0["body"].string == "Anyone?" })
            #expect(again["mentionDeliveries"].elements?.first?["agentID"].string == "hoot")
            hoot = try await Self.asked(r, id).filter { $0.assigneeKind == "hoot" }
            #expect(hoot.count == 2)
        }
    }

    @Test func failedMentionRetriesOnlyThatAgent() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            await r.engine.failAccept("No free slot for portal-reviewer.")
            _ = await r.call("addTaskComment", .string(id), .string("@portal-reviewer look"))
            var mine = try #require(await r.comments(id).first { $0["body"].string == "@portal-reviewer look" })
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "failed")
            let cid = try #require(mine["id"].string)
            await r.engine.failAccept(nil)
            let before = await r.engine.replies
            let retried = await r.call("retryCommentDelivery", .string(id), .string(cid), .string("portal-reviewer"))
            #expect(retried["ok"].bool == true)
            let after = await r.engine.replies
            #expect(after.count == before.count)
            mine = try #require(await r.comments(id).first { $0["body"].string == "@portal-reviewer look" })
            #expect(mine["mentionDeliveries"].elements?.count == 1)
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "delivered")
        }
    }

    // MARK: seen on read, and a question that could not start (#109 part 3)
    @Test func agentTurnStartingOnTheCommentMarksItSeen() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            _ = try await r.store.update(id, patch: crmParityValue(["sessionId": "sess-agent-1"]))
            // A turn that started before the comment says nothing about it.
            await r.detail.noteRecipientWorking(sessionID: "sess-agent-1"); await r.detail.settleSeen()
            _ = await r.call("addTaskComment", .string(id), .string("Also check Safari"))
            var mine = try #require(await r.comments(id).first { $0["body"].string == "Also check Safari" })
            #expect(mine["delivery"]["state"].string == "delivered")
            // Another session's turn is not this agent reading it.
            await r.detail.noteRecipientWorking(sessionID: "sess-someone-else"); await r.detail.settleSeen()
            mine = try #require(await r.comments(id).first { $0["body"].string == "Also check Safari" })
            #expect(mine["delivery"]["state"].string == "delivered")
            await r.detail.noteRecipientWorking(sessionID: "sess-agent-1"); await r.detail.settleSeen()
            mine = try #require(await r.comments(id).first { $0["body"].string == "Also check Safari" })
            #expect(mine["delivery"]["state"].string == "seen")
            let seenAt = try #require(mine["delivery"]["seenAt"].number)
            let listed = await r.call("listTaskComments", .string(id))
            #expect((listed["writingCandidates"].elements ?? []).compactMap { $0["agentID"].string } == ["portal-mechanic"])
            try await r.store.note(id, by: "portal-mechanic", kind: "progress", text: "Checked Safari.")
            mine = try #require(await r.comments(id).first { $0["body"].string == "Also check Safari" })
            #expect(mine["delivery"]["state"].string == "answered")
            #expect(mine["delivery"]["seenAt"].number == seenAt)
        }
    }

    @Test func hootChatGoingBusyWhileItIsHandedOverMarksItSeen() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("hoot")
            // Hoot's chat goes busy on the message while the comment is still being delivered.
            let detail = r.detail
            await r.engine.setOnReply { await detail.noteRecipientWorking(sessionID: nil) }
            _ = await r.call("addTaskComment", .string(id), .string("Summarise it for me"))
            await r.detail.settleSeen()
            let mine = try #require(await r.comments(id).first { $0["body"].string == "Summarise it for me" })
            #expect(mine["delivery"]["state"].string == "seen" && mine["delivery"]["seenAt"].number != nil)
        }
    }

    @Test func askedAgentsTurnOnItsQuestionMarksThatMentionSeen() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            _ = await r.call("addTaskComment", .string(id), .string("@portal-reviewer check the diff"))
            let children = try await Self.asked(r, id)
            let child = try #require(children.first)
            _ = try await r.store.update(child.id, patch: crmParityValue(["sessionId": "sess-reviewer"]))
            await r.detail.noteRecipientWorking(sessionID: "sess-reviewer"); await r.detail.settleSeen()
            let mine = try #require(await r.comments(id).first { $0["body"].string == "@portal-reviewer check the diff" })
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "seen")
            #expect(mine["delivery"]["state"].string == "delivered")
        }
    }

    @Test func aQuestionThatCouldNotStartStaysLinkedAndTryAgainReplacesIt() async throws {
        try await Self.clocked {
            let r = try await Self.rig(), id = try await r.make("portal-mechanic")
            await r.engine.failAccept("No free slot for portal-reviewer.")
            _ = await r.call("addTaskComment", .string(id), .string("@portal-reviewer look"))
            var mine = try #require(await r.comments(id).first { $0["body"].string == "@portal-reviewer look" })
            let failed = try #require(mine["mentionDeliveries"].elements?.first)
            #expect(failed["state"].string == "failed")
            let orphanID = try #require(failed["childTaskID"].string)
            let linked = try await Self.asked(r, id)
            #expect(linked.map(\.id) == [orphanID])
            let all = try await r.store.all()
            #expect(all.filter { $0.value["parentTaskId"].string == id && $0.value["askedFromTask"].isNullish }.isEmpty)
            await r.engine.failAccept(nil)
            let cid = try #require(mine["id"].string)
            let retried = await r.call("retryCommentDelivery", .string(id), .string(cid), .string("portal-reviewer"))
            #expect(retried["ok"].bool == true)
            let after = try await Self.asked(r, id)
            #expect(after.count == 1 && after.first?.id != orphanID)
            let orphanStill = try await r.store.byID(orphanID)
            #expect(orphanStill == nil)
            mine = try #require(await r.comments(id).first { $0["body"].string == "@portal-reviewer look" })
            #expect(mine["mentionDeliveries"].elements?.count == 1)
            #expect(mine["mentionDeliveries"].elements?.first?["state"].string == "delivered")
            #expect(mine["mentionDeliveries"].elements?.first?["childTaskID"].string == after.first?.id)
        }
    }
}
