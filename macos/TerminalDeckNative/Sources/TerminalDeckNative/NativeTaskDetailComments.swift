import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Comments

    func commentAgentProfile(_ id: String) -> AgentProfile? {
        commentAgentProfiles.first { $0.id == id }
    }

    var commentComposerCatalogue: HootComposerCatalogue {
        guard commentCapabilities["mentions"] == true else { return .init() }
        return .init(mentions: [HootMention(id: CrmPeople.hoot, kind: .agent, name: "Hoot")] + commentAgentProfiles.filter { $0.status != .archived }.map {
            HootMention(id: $0.id, kind: .agent, name: $0.name, project: $0.projectID)
        })
    }

    /// Every receipt of one comment: its holder first, then each agent @asked.
    func commentReceipts(_ id: String) -> [FIXESCommentDelivery] {
        (commentDeliveries[id].map { [$0] } ?? []) + (commentMentionDeliveries[id] ?? []).filter { $0.agentID != commentDeliveries[id]?.agentID }
    }

    var hootBusy: Bool { hootBusyOverride?() ?? NativeHootChatModel.shared.busy }
    func sessionStatus(_ id: String) -> String? {
        if let sessionStatusOverride { return sessionStatusOverride(id) }
        return liveSessionStatus[id] ?? AppModel.shared.sidebar?.item(id: id)?.status
    }

    /// Who is writing an answer now: a recipient that has the comment, has not
    /// answered, and whose session is working (Hoot: whose chat is busy).
    var currentWriting: FIXESTaskWritingProof? {
        if let commentWritingProof { return commentWritingProof }
        for candidate in commentWritingCandidates {
            let isHoot = candidate.agentID == CrmPeople.hoot
            let working = isHoot ? hootBusy : candidate.sessionID.map { sessionStatus($0) == "working" } ?? false
            guard working else { continue }
            let icon: AGTIcon = isHoot ? .symbol("bird") : commentAgentProfile(candidate.agentID).map {
                AGTIcon.parse($0.icon) ?? AGTIconCatalog.defaultIcon(name: $0.name, role: $0.role, provider: $0.provider ?? "")
            } ?? .symbol("person.crop.square")
            return FIXESTaskWritingProof(taskID: taskId, agentID: candidate.agentID, turnID: candidate.sessionID ?? "hoot-chat",
                                         name: candidate.name, icon: icon, isHoot: isHoot,
                                         colour: commentAgentProfile(candidate.agentID).flatMap { AGTIcon.colour($0.icon) })
        }
        return nil
    }

    func retryCommentDelivery(_ id: String, agent: String? = nil) async -> Bool {
        await commentDeliveryAction("retryCommentDelivery", id: id, capability: "retry", extra: agent)
    }

    func askHootInstead(_ id: String) async -> Bool {
        await commentDeliveryAction("askHootInstead", id: id, capability: "askHoot")
    }

    func commentDeliveryAction(_ function: String, id: String, capability: String, extra: String? = nil) async -> Bool {
        guard commentCapabilities[capability] == true else {
            error = "This comment action is not available yet."
            return false
        }
        guard !commentDeliveryPending.contains(id) else { return false }
        commentDeliveryPending.insert(id)
        defer { commentDeliveryPending.remove(id) }
        guard await write(function, extra.map { [taskId, id, $0] } ?? [taskId, id], label: "Comment") else { return false }
        await loadComments(); await loadCommentExtras()
        return true
    }

    func postCommentDraft(_ snapshot: HootComposerDraft, attachmentIDs: [String],
                          assignee: String?, scheduledFor: String?) async -> Bool {
        let mentions = snapshot.activeMentions
        guard mentions.isEmpty || commentCapabilities["mentions"] == true else {
            error = "Asking another agent from this thread is not available yet. Your comment is still here."
            return false
        }
        // An agent token reads "@Name" in the thread, so the text alone also asks it.
        var text = snapshot.mentions.reduce(snapshot.text) { $0.replacingOccurrences(of: $1.marker, with: $1.kind == .agent ? "@" + $1.name : $1.name) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachmentIDs.map(CrmText.fileToken).joined(separator: " ")
        if !files.isEmpty { text += (text.isEmpty ? "" : "\n") + files }
        guard !text.isEmpty else { return false }
        // A vacant seat that was mentioned ("seat:<key>"): nobody is there to wake, so its project's lead
        // (or Hoot) is asked to fill it (L4's AGTLeads.askToFill). The comment itself is posted as usual.
        let seats = mentions.filter { $0.kind == .agent && $0.id.hasPrefix(AGTDirectory.vacantSeatPrefix) }
        let agents = mentions.filter { !seats.contains($0) }
        for mention in seats {
            guard let seat = AGTSeat(key: String(mention.id.dropFirst(AGTDirectory.vacantSeatPrefix.count))) else { continue }
            if await AGTLeads.askToFill(seat, note: text) == nil {
                error = AGTAgentsStore.shared.message ?? "Nobody could be asked to fill that role. Your comment is still here."
                return false
            }
        }
        if agents.isEmpty { return await postComment(text, assignee: assignee, scheduledFor: scheduledFor) }
        var options: [String: Any] = ["mentions": agents.map { $0.wire.foundation ?? NSNull() }]
        if let assignee { options["assigneeUserId"] = assignee }
        if let scheduledFor { options["scheduledFor"] = scheduledFor }
        guard await write("addTaskCommentWith", [taskId, text, options], label: "Comment") else { return false }
        await loadComments(); await loadCommentExtras(); await loadActivity()
        return true
    }

    func postComment(_ body: String, parentId: String? = nil, assignee: String? = nil, scheduledFor: String? = nil) async -> Bool {
        let rich = parentId != nil || assignee != nil || scheduledFor != nil
        let result: Result<[String: Any], TasksProblem>
        if rich {
            var opts: [String: Any] = [:]
            if let parentId { opts["parentId"] = parentId }
            if let assignee { opts["assigneeUserId"] = assignee }
            if let scheduledFor { opts["scheduledFor"] = scheduledFor }
            result = await call("addTaskCommentWith", [taskId, body, opts])
        } else {
            result = await call("addTaskComment", [taskId, body])
        }
        if case .failure(let problem) = result {
            error = "Comment: \(problem.message)"
            return false
        }
        if case .success(let answer) = result, let warning = answer["warning"] as? String {
            error = warning
        }
        await loadComments()
        await loadCommentExtras()
        await loadActivity()
        return true
    }

    func react(_ commentId: String, _ emoji: String) {
        guard let prev = commentExtras else { return }
        var list = prev.reactions[commentId] ?? []
        if let i = list.firstIndex(where: { $0.emoji == emoji }) {
            if list[i].userIds.contains(me) { list[i].userIds.removeAll { $0 == me } } else { list[i].userIds.append(me) }
            list.removeAll { $0.userIds.isEmpty }
        } else {
            list.append(CommentReaction(emoji: emoji, userIds: [me]))
        }
        commentExtras?.reactions[commentId] = list
        Task {
            if !(await write("toggleCommentReaction", [taskId, commentId, emoji], label: "Reaction")) { commentExtras = prev }
        }
    }

    func resolve(_ commentId: String, _ resolved: Bool) {
        guard let prev = commentExtras else { return }
        var m = prev.meta[commentId] ?? CommentMeta()
        m.resolvedAt = resolved ? CrmTime.iso(Date().timeIntervalSince1970 * 1000) : nil
        m.resolvedBy = resolved ? me : nil
        commentExtras?.meta[commentId] = m
        Task { if !(await write("setCommentResolved", [taskId, commentId, resolved], label: "Resolve")) { commentExtras = prev } }
    }

    func sendNow(_ commentId: String) {
        Task {
            switch await call("sendScheduledNow", [taskId, commentId]) {
            case .failure(let problem): error = "Send now: \(problem.message)"
            case .success(let r): if let warning = r["warning"] as? String { error = "Send now: \(warning)" }
            }
            await loadCommentExtras()
        }
    }

}
