import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - The feed

struct ActivityFeed: View {
    let model: TaskDetailModel
    let rows: [TaskActivityRow]
    let query: String
    let hidden: Set<FeedCategory>
    @Binding var replyingTo: String?
    let pane: FIXESTaskThreadPane
    @State private var expanded = false

    var body: some View {
        let viewer = model.me
        let meta = model.commentExtras?.meta ?? [:]
        let visible = (model.comments ?? []).filter { CrmComments.visible($0, meta[$0.id], viewer: viewer) }
        let threads = CrmComments.thread(visible, meta: meta)
        let who: (String?) -> String? = { id in id.flatMap { i in model.team.first { $0.id == i }?.name } }
        let all = ActivityFeedRules.build(rows, comments: threads.top, viewer: viewer, today: CrmTime.todayYmd(), who: who)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let systemIDs = Set(rows.filter { ["created", "assigned", "unassigned"].contains($0.kind) }.map(\.id))
        let shown = all.filter { e in
            switch e {
            case .comment(let c):
                guard pane == .comments else { return false }
                if hidden.contains(.comments) { return false }
                let thread = [c] + (threads.replies[c.id] ?? [])
                return q.isEmpty || thread.contains { $0.body.lowercased().contains(q) || $0.authorName.lowercased().contains(q) }
            case .activity(let id, _, _, _, _, let text, let category):
                guard pane == .activity || systemIDs.contains(id) else { return false }
                if let category, hidden.contains(category) { return false }
                return q.isEmpty || text.lowercased().contains(q)
            }
        }
        let lastComment = shown.lastIndex { if case .comment = $0 { return true } else { return false } } ?? -1
        let folded: Set<String> = {
            guard !expanded && q.isEmpty && lastComment > 0 else { return [] }
            return Set(shown[1..<lastComment].compactMap { if case .activity(let id, _, _, _, _, _, _) = $0 { return id } else { return nil } })
        }()
        let firstFolded = shown.firstIndex { folded.contains($0.id) }
        VStack(alignment: .leading, spacing: 2) {
            if shown.isEmpty {
                Text(!q.isEmpty || !hidden.isEmpty ? "Nothing matches." : "Nothing has happened here yet.")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                if folded.contains(e.id) {
                    if i == firstFolded {
                        Button { expanded = true } label: { Label("Show more", systemImage: "chevron.right").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).frame(height: 32)
                    }
                } else {
                    switch e {
                    case .activity(_, let at, _, _, let parts, _, _):
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Color.secondary).frame(width: 4, height: 4).padding(.top, 8)
                            partsText(parts).font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            WhenText(iso: at).font(.caption).foregroundStyle(.tertiary).padding(.leading, 12)
                        }
                        .padding(.vertical, 6)
                    case .comment(let c):
                        CommentCard(model: model, comment: c, replies: threads.replies[c.id] ?? [], replyingTo: $replyingTo)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func partsText(_ parts: [FeedPart]) -> Text {
        parts.reduce(Text("")) { text, part in
            switch part {
            case .text(let s): return text + Text(s)
            case .strong(let s): return text + Text(s).fontWeight(.medium).foregroundColor(.primary)
            case .flag(let p): return text + Text(Image(systemName: "flag.fill")).foregroundColor(CrmColor.flag(p)) + Text(" ")
            case .timer: return text + Text(Image(systemName: "timer")) + Text(" ")
            }
        }
    }
}

/// A time that moves on ("5 mins", "Yesterday at …"), with the full time on hover.
struct WhenText: View {
    let iso: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(CrmTime.activityTime(iso, now: context.date)).help(localStamp(iso))
        }
    }
}

struct CommentCard: View {
    let model: TaskDetailModel
    let comment: TaskComment
    let replies: [TaskComment]
    @Binding var replyingTo: String?

    var body: some View {
        let c = comment
        let viewer = model.me
        let m = model.commentExtras?.meta[c.id]
        let withdrawn = m?.withdrawn
        let pending = withdrawn == nil && CrmComments.isPending(m)
        let assignee = m?.assigneeUserId.flatMap { id in model.team.first { $0.id == id } }
        let resolved = m?.resolvedAt != nil
        let resolver = m?.resolvedBy.map { rid in rid == viewer ? "you" : model.team.first { $0.id == rid }?.name ?? "someone" }
        let footer = model.commentExtras != nil
        VStack(alignment: .leading, spacing: 0) {
            if let withdrawn {
                Label("Not posted — \(withdrawn.reason). Only you can see it.", systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(TaskTone.input)
                    .padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaskTone.input.opacity(0.1))
            }
            if pending, let when = m?.scheduledFor {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                    Text((CrmTime.date(when).map { $0 > Date() } ?? false)
                         ? "Scheduled for \(CrmComments.formatScheduled(when)) — only you can see it until then"
                         : "Waiting to be sent — only you can see it until it goes out")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if footer {
                        Button { model.sendNow(c.id) } label: { Label("Send now", systemImage: "paperplane").font(.caption.weight(.medium)) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.caption).foregroundStyle(TaskTone.accent)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(TaskTone.accent.opacity(0.08))
            }
            HStack(spacing: 8) {
                FIXESTaskCommentAvatar(model: model, comment: c)
                Text(c.authorUserId == viewer ? "You" : c.authorName).font(.callout.weight(.semibold))
                if FIXESTaskCommentAvatar.isAgent(model, c) { FIXESTaskAgentTag() }
                WhenText(iso: c.createdAt).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            CommentBody(model: model, text: c.body)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(c.authorUserId == viewer ? Color.accentColor.opacity(0.08) : Color.clear,
                            in: .rect(cornerRadius: 14))
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
            if c.authorUserId == viewer, !model.commentReceipts(c.id).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.commentReceipts(c.id), id: \.agentID) { receipt in
                        FIXESTaskReceiptRow(model: model, commentID: c.id, receipt: receipt)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            if assignee != nil || resolved {
                HStack(spacing: 8) {
                    if let assignee {
                        Image(systemName: "person").foregroundStyle(.tertiary)
                        Text("Assigned to ") + Text(m?.assigneeUserId == viewer ? "you" : assignee.name).fontWeight(.medium)
                    }
                    if resolved {
                        Label("Resolved\(resolver.map { " by \($0)" } ?? "")", systemImage: "checkmark").foregroundStyle(TaskTone.completed)
                    }
                    Spacer()
                    if footer {
                        Button { model.resolve(c.id, !resolved) } label: {
                            Label(resolved ? "Reopen" : "Resolve", systemImage: resolved ? "arrow.counterclockwise" : "checkmark").font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(replies) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                FIXESTaskCommentAvatar(model: model, comment: r)
                                Text(r.authorUserId == viewer ? "You" : model.team.first { $0.id == r.authorUserId }?.name ?? "Someone")
                                    .font(.system(size: 13, weight: .semibold))
                                if FIXESTaskCommentAvatar.isAgent(model, r) { FIXESTaskAgentTag() }
                                WhenText(iso: r.createdAt).font(.caption2).foregroundStyle(.tertiary)
                            }
                            CommentBody(model: model, text: r.body).padding(.leading, 26)
                            if r.authorUserId == viewer {
                                ForEach(model.commentReceipts(r.id), id: \.agentID) { receipt in
                                    FIXESTaskReceiptRow(model: model, commentID: r.id, receipt: receipt).padding(.leading, 26)
                                }
                            }
                            if footer { Reactions(model: model, commentId: r.id, small: true).padding(.leading, 26) }
                        }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 2) }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .accessibilityLabel("Replies")
            }
            if replyingTo == c.id {
                ReplyBox(model: model, onCancel: { replyingTo = nil }) { body in
                    let ok = await model.postComment(body, parentId: c.id)
                    if ok { replyingTo = nil }
                    return ok
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if footer {
                Divider()
                HStack {
                    Reactions(model: model, commentId: c.id, small: false)
                    Spacer()
                    Button { replyingTo = replyingTo == c.id ? nil : c.id } label: { Label("Reply", systemImage: "arrowshape.turn.up.left").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            withdrawn != nil ? TaskTone.input.opacity(0.5) : pending ? TaskTone.accent.opacity(0.5) : Color(nsColor: .separatorColor),
            style: StrokeStyle(lineWidth: 1, dash: withdrawn != nil || pending ? [4] : [])))
        .opacity(resolved ? 0.75 : 1)
    }
}

struct FIXESTaskAgentTag: View {
    var body: some View {
        Text("agent").font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
    }
}
struct FIXESTaskCommentAvatar: View {
    let model: TaskDetailModel
    let comment: TaskComment
    static func isAgent(_ model: TaskDetailModel, _ comment: TaskComment) -> Bool {
        guard let id = comment.authorUserId, id != model.me else { return false }
        return id == CrmPeople.hoot || model.commentAgentProfile(id) != nil
    }
    var body: some View {
        if comment.authorUserId == CrmPeople.hoot {
            AgentAvatar(icon: .symbol("bird"), size: 26, hoot: true)
        } else if let id = comment.authorUserId, let profile = model.commentAgentProfile(id) {
            AgentAvatar(icon: AGTIcon.parse(profile.icon) ?? AGTIconCatalog.defaultIcon(name: profile.name, role: profile.role, provider: profile.provider ?? ""), size: 26,
                        id: profile.id, colour: AGTIcon.colour(profile.icon))
        } else {
            PersonAvatar(person: CrmPerson(id: comment.authorUserId ?? "", name: comment.authorName,
                                          initials: comment.authorInitials, color: comment.authorColor))
        }
    }
}
struct FIXESTaskTypingRow: View {
    let proof: FIXESTaskWritingProof
    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(icon: proof.icon, size: 20, hoot: proof.isHoot, id: proof.isHoot ? nil : proof.agentID, colour: proof.colour)
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(Color.secondary).frame(width: 4, height: 4) }
            }
            Text("\(proof.name) is writing a reply for you…").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 8)
            .accessibilityLabel("\(proof.name) is writing a reply for you")
    }
}
struct FIXESTaskReceiptRow: View {
    let model: TaskDetailModel
    let commentID: String
    let receipt: FIXESCommentDelivery
    @State private var changing = false
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if receipt.state == .sent { ProgressView().controlSize(.mini) }
                else if receipt.state != .failed { Image(systemName: "checkmark") }
                Text(receipt.message)
            }.font(.system(size: 11.5))
                .foregroundStyle(receipt.state == .failed ? Color.red : Color.secondary)
            if receipt.state == .failed {
                HStack(spacing: 8) {
                    Button("Try Again") { perform(askHoot: false) }
                        .disabled(model.commentCapabilities["retry"] != true)
                    if model.commentCapabilities["askHoot"] == true, receipt.agentID != CrmPeople.hoot {
                        Button("Ask Hoot instead") { perform(askHoot: true) }
                    }
                    if changing { ProgressView().controlSize(.mini) }
                }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.commentThreadUIReady || changing)
                    .help(model.commentThreadUIReady ? "Send this saved comment again" : "Comment delivery actions are unavailable for this task.")
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(receipt.message)
    }
    private func perform(askHoot: Bool) {
        guard model.commentThreadUIReady, model.commentCapabilities[askHoot ? "askHoot" : "retry"] == true, !changing else { return }
        changing = true; problem = nil
        Task {
            defer { changing = false }
            let ok: Bool
            if askHoot { ok = await model.askHootInstead(commentID) }
            else { ok = await model.retryCommentDelivery(commentID, agent: receipt.agentID) }
            if !ok { problem = model.error ?? "Could not send this comment. Try again." }
            // Receipt changes only through the real model read/push.
        }
    }
}

/// A comment's text: files as chips, "@Name" as chips.
struct CommentBody: View {
    let model: TaskDetailModel
    let text: String

    var body: some View {
        TaskRichText(text: .constant(text), editable: false, font: .systemFont(ofSize: 13),
                     fileOf: { id in
                         guard let a = model.attachments?.first(where: { $0.id == id }) else { return nil }
                         let image = CrmFiles.isImage(mime: a.mimeType, fileName: a.fileName) ? a.previewUrl.flatMap { TaskPictures.image(id: a.id, $0) } : nil
                         return InlineFile(image: image, name: a.fileName)
                     },
                     mentionNames: model.team.map(\.name),
                     onClickFile: { model.openFile($0) },
                     insertion: .constant(nil))
    }
}

struct Reactions: View {
    let model: TaskDetailModel
    let commentId: String
    let small: Bool
    @State private var open = false

    var body: some View {
        let list = model.commentExtras?.reactions[commentId] ?? []
        HStack(spacing: 4) {
            ForEach(list, id: \.emoji) { r in
                let mine = r.userIds.contains(model.me)
                let who = r.userIds.map { id in id == model.me ? "You" : model.team.first { $0.id == id }?.name ?? "Someone" }.joined(separator: ", ")
                Button { model.react(commentId, r.emoji) } label: {
                    HStack(spacing: 4) { Text(r.emoji); Text("\(r.userIds.count)").monospacedDigit() }
                        .font(.caption)
                        .padding(.horizontal, 6).frame(height: 24)
                        .background(Capsule().fill(mine ? TaskTone.accent.opacity(0.12) : Color(nsColor: .windowBackgroundColor)))
                        .overlay(Capsule().stroke(mine ? TaskTone.accent.opacity(0.4) : Color(nsColor: .separatorColor)))
                }
                .buttonStyle(.plain)
                .help(who)
                .accessibilityLabel("\(r.emoji) \(r.userIds.count) — \(who)")
                .accessibilityAddTraits(mine ? .isSelected : [])
            }
            Button { open.toggle() } label: { Image(systemName: "face.smiling").font(.system(size: small ? 12 : 14)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("React").accessibilityLabel("Add a reaction")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    HStack(spacing: 2) {
                        ForEach(CrmComments.reactions, id: \.self) { e in
                            Button {
                                open = false
                                model.react(commentId, e)
                            } label: { Text(e).font(.title3).frame(width: 32, height: 32) }
                                .buttonStyle(.plain).accessibilityLabel("React \(e)")
                        }
                    }
                    .padding(6)
                }
        }
    }
}

struct ReplyBox: View {
    let model: TaskDetailModel
    let onCancel: () -> Void
    let onSend: (String) async -> Bool
    @State private var value = ""
    @State private var busy = false
    @State private var insertion: TaskTextInsertion?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TaskTextEditor(text: Binding(get: { value }, set: { value = String($0.prefix(4000)) }), team: model.team, placeholder: "Reply…",
                           font: .systemFont(ofSize: 13), onEscape: onCancel, onSubmit: { go() }, insertion: $insertion)
                .frame(minHeight: 36, alignment: .topLeading)
                .padding(.horizontal, 12).padding(.top, 8)
                .accessibilityLabel("Write a reply")
            HStack(spacing: 6) {
                Button("Cancel", action: onCancel)
                Button("Reply") { go() }.buttonStyle(.borderedProminent).tint(TaskTone.accent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    private func go() {
        let body = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy else { return }
        busy = true
        Task {
            if await onSend(body) { value = "" }
            busy = false
        }
    }
}
