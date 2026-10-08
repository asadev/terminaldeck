import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Activity, the popup's right column (page/activity-pane.tsx + activity-feed.tsx):
// the header (search, followers, filter), the feed (activity lines and comment
// cards with replies, reactions, resolve, schedule), and the comment box with its
// toolbar (slash commands, attach, mention, assign, emoji, record, screenshot,
// dictate, send, send later).

struct TaskActivityPane: View {
    let model: TaskDetailModel
    let commands: [SlashCommand]
    let onAttach: ([URL]) async -> [TaskAttachment]
    @State private var searchOpen = false
    @State private var query = ""
    @State private var hidden: Set<FeedCategory> = []
    @State private var replyingTo: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Activity").font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                iconButton("magnifyingglass", "Search activity", on: searchOpen) {
                    searchOpen.toggle()
                    query = ""
                }
                FollowersBell(model: model)
                FilterMenu(hidden: $hidden)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider()
            if searchOpen {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    TextField("Search activity", text: $query)
                        .textFieldStyle(.plain)
                        .onExitCommand {
                            searchOpen = false
                            query = ""
                        }
                        .accessibilityLabel("Search activity text")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        if let error = model.activityError {
                            Text("Activity unavailable: \(error)").font(.caption).foregroundStyle(TaskTone.waiting)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(TaskTone.waiting.opacity(0.1)))
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if let error = model.commentsErrorText {
                            Text("Could not load comments: \(error)").font(.caption).foregroundStyle(TaskTone.input)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if let rows = model.activity, let total = model.activityTotal, total > rows.count {
                            Text("Showing the latest \(rows.count) of \(total.formatted(.number)) lines.").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if let rows = model.activity {
                            ActivityFeed(model: model, rows: rows, query: query, hidden: hidden, replyingTo: $replyingTo)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Loading…") }
                                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: (model.activity?.count ?? 0) + (model.comments?.count ?? 0)) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Composer(model: model, commands: commands, onAttach: onAttach)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity")
    }

    private func iconButton(_ icon: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Followers and filter

/// 🔔 n — who hears about this task. Locally there is no following: everyone on the
/// task is notified, and the list is the people on it.
private struct FollowersBell: View {
    let model: TaskDetailModel
    @State private var open = false
    @State private var query = ""

    var body: some View {
        let everyone = model.people?.list ?? []
        let n = everyone.count
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = words.isEmpty ? everyone : everyone.filter { $0.name.lowercased().contains(words) }
        Button { open.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "bell")
                Text("\(n)").font(.callout.weight(.medium))
            }
            .foregroundStyle(Color.purple)
            .padding(.horizontal, 6).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(n) \(n == 1 ? "follower" : "followers") will get notified")
        .accessibilityLabel("\(n) \(n == 1 ? "follower" : "followers") will get notified")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Everyone on this task is notified.").font(.caption2).foregroundStyle(TaskTone.waiting)
                Divider()
                TextField("Search Followers...", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search followers")
                Text("\(n) \(n == 1 ? "follower" : "followers")").font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { p in
                            HStack(spacing: 8) { PersonAvatar(person: p); Text(p.name).lineLimit(1); Spacer() }
                                .font(.callout).padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 224)
            }
            .padding(8)
            .frame(width: 290)
            .onDisappear { query = "" }
        }
    }
}

private struct FilterMenu: View {
    @Binding var hidden: Set<FeedCategory>
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hidden.isEmpty ? Color.secondary : Color.purple)
        .help("Filter activity")
        .accessibilityLabel("Filter activity")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Show").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { hidden = [] }.buttonStyle(.link).font(.caption)
                    Button("Comments only") { hidden = Set(FeedCategory.allCases.filter { $0 != .comments }) }.buttonStyle(.link).font(.caption)
                }
                .padding(.bottom, 4)
                ForEach(FeedCategory.allCases, id: \.self) { c in
                    Toggle(c.label, isOn: Binding(get: { !hidden.contains(c) }, set: { on in
                        if on { hidden.remove(c) } else { hidden.insert(c) }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
            .padding(10)
            .frame(width: 260)
        }
    }
}

// MARK: - The feed

private struct ActivityFeed: View {
    let model: TaskDetailModel
    let rows: [TaskActivityRow]
    let query: String
    let hidden: Set<FeedCategory>
    @Binding var replyingTo: String?
    @State private var expanded = false

    var body: some View {
        let viewer = model.me
        let meta = model.commentExtras?.meta ?? [:]
        let visible = (model.comments ?? []).filter { CrmComments.visible($0, meta[$0.id], viewer: viewer) }
        let threads = CrmComments.thread(visible, meta: meta)
        let who: (String?) -> String? = { id in id.flatMap { i in model.team.first { $0.id == i }?.name } }
        let all = ActivityFeedRules.build(rows, comments: threads.top, viewer: viewer, today: CrmTime.todayYmd(), who: who)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = all.filter { e in
            switch e {
            case .comment(let c):
                if hidden.contains(.comments) { return false }
                let thread = [c] + (threads.replies[c.id] ?? [])
                return q.isEmpty || thread.contains { $0.body.lowercased().contains(q) || $0.authorName.lowercased().contains(q) }
            case .activity(_, _, _, _, _, let text, let category):
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
private struct WhenText: View {
    let iso: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(CrmTime.activityTime(iso, now: context.date)).help(localStamp(iso))
        }
    }
}

private struct CommentCard: View {
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
                .font(.caption).foregroundStyle(Color.purple)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.purple.opacity(0.08))
            }
            HStack(spacing: 8) {
                PersonAvatar(person: CrmPerson(id: c.authorUserId ?? "", name: c.authorName, initials: c.authorInitials, color: c.authorColor))
                Text(c.authorUserId == viewer ? "You" : c.authorName).font(.callout.weight(.semibold))
                WhenText(iso: c.createdAt).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            CommentBody(model: model, text: c.body)
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
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
                                PersonAvatar(person: CrmPerson(id: r.authorUserId ?? "", name: r.authorName, initials: r.authorInitials, color: r.authorColor))
                                Text(r.authorUserId == viewer ? "You" : model.team.first { $0.id == r.authorUserId }?.name ?? "Someone")
                                    .font(.system(size: 13, weight: .semibold))
                                WhenText(iso: r.createdAt).font(.caption2).foregroundStyle(.tertiary)
                            }
                            CommentBody(model: model, text: r.body).padding(.leading, 26)
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
            withdrawn != nil ? TaskTone.input.opacity(0.5) : pending ? Color.purple.opacity(0.5) : Color(nsColor: .separatorColor),
            style: StrokeStyle(lineWidth: 1, dash: withdrawn != nil || pending ? [4] : [])))
        .opacity(resolved ? 0.75 : 1)
    }
}

/// A comment's text: files as chips, "@Name" as chips.
private struct CommentBody: View {
    let model: TaskDetailModel
    let text: String

    var body: some View {
        TaskRichText(text: .constant(text), editable: false, font: .systemFont(ofSize: 13),
                     fileOf: { id in
                         guard let a = model.attachments?.first(where: { $0.id == id }) else { return nil }
                         let image = CrmFiles.isImage(mime: a.mimeType, fileName: a.fileName) ? a.previewUrl.flatMap(AttachmentsSection.image) : nil
                         return InlineFile(image: image, name: a.fileName)
                     },
                     mentionNames: model.team.map(\.name),
                     onClickFile: { model.openFile($0) },
                     insertion: .constant(nil))
    }
}

private struct Reactions: View {
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
                        .background(Capsule().fill(mine ? Color.primary.opacity(0.12) : Color(nsColor: .windowBackgroundColor)))
                        .overlay(Capsule().stroke(mine ? Color.secondary.opacity(0.45) : Color(nsColor: .separatorColor)))
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

private struct ReplyBox: View {
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
                Button("Reply") { go() }.buttonStyle(.borderedProminent).tint(.purple)
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

// MARK: - The comment box

private struct Composer: View {
    let model: TaskDetailModel
    let commands: [SlashCommand]
    let onAttach: ([URL]) async -> [TaskAttachment]
    @State private var value = ""
    @State private var posting = false
    @State private var insertion: TaskTextInsertion?
    @State private var slashOpen = false
    @State private var clipOpen = false
    @State private var emojiOpen = false
    @State private var assignOpen = false
    @State private var laterOpen = false
    @State private var assignee: CrmPerson?
    @State private var uploading = false
    @State private var recorder: Process?
    @State private var recordingFile: URL?

    private static let emoji = ["👍", "👏", "🙏", "🎉", "✅", "❌", "⚠️", "🔥", "❤️", "💯", "😀", "😂", "😅", "😊", "😍", "🤔", "😮", "😢", "😡", "👀",
                                "🚀", "📌", "📎", "📅", "⏰", "🏠", "🔑", "💰", "📞", "✉️", "🤝", "💪"]

    var body: some View {
        let rich = model.commentExtras != nil
        let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            TaskTextEditor(text: Binding(get: { value }, set: { new in
                // "/" at the start opens the slash commands.
                if new == "/" && value.isEmpty {
                    slashOpen = true
                    return
                }
                value = String(new.prefix(4000))
            }), team: model.team,
                           placeholder: (model.comments?.isEmpty ?? true) ? "Write a comment..." : "Comment or type '/' for commands",
                           font: .systemFont(ofSize: 13), fileOf: { fileOf($0) }, onSubmit: { send(nil) }, autoFocus: false,
                           insertion: $insertion)
                .frame(minHeight: 44, maxHeight: 192, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                .accessibilityLabel("Write a comment")
            if let assignee {
                HStack(spacing: 6) {
                    PersonAvatar(person: assignee)
                    Text("Assign to \(assignee.name)")
                    Button { self.assignee = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).accessibilityLabel("Don't assign this comment")
                }
                .font(.caption).foregroundStyle(Color.purple)
                .padding(.leading, 2).padding(.trailing, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.1)))
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            HStack(spacing: 2) {
                Button { slashOpen.toggle() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Slash commands (/)").accessibilityLabel("Slash commands")
                .popover(isPresented: $slashOpen, arrowEdge: .top) {
                    SlashPanel(commands: commands, onMention: { mention() }, onDone: { slashOpen = false })
                }
                Divider().frame(height: 16).padding(.horizontal, 6)
                tool(uploading ? "arrow.triangle.2.circlepath" : "paperclip", "Attach a file to the comment") { clipOpen.toggle() }
                    .popover(isPresented: $clipOpen, arrowEdge: .top) {
                        Button {
                            clipOpen = false
                            pickFiles()
                        } label: {
                            Label("Upload file", systemImage: "arrow.up.doc").padding(.horizontal, 12).padding(.vertical, 6)
                                .frame(width: 200, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.vertical, 4)
                    }
                tool("at", "Mention someone") { mention() }
                if rich {
                    tool("person", "Assign comment") { assignOpen.toggle() }
                        .popover(isPresented: $assignOpen, arrowEdge: .top) {
                            PersonSearchList(team: model.team, isPicked: { $0 == assignee?.id }, onPick: { p in
                                assignee = p.id == assignee?.id ? nil : p
                                assignOpen = false
                            })
                            .frame(width: 280)
                        }
                }
                tool("face.smiling", "Emoji") { emojiOpen.toggle() }
                    .popover(isPresented: $emojiOpen, arrowEdge: .top) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 8), spacing: 2) {
                            ForEach(Self.emoji, id: \.self) { e in
                                Button {
                                    emojiOpen = false
                                    value += e
                                } label: { Text(e).font(.title3).frame(width: 28, height: 28) }
                                    .buttonStyle(.plain).accessibilityLabel("Insert \(e)")
                            }
                        }
                        .padding(8)
                    }
                tool(recorder != nil ? "record.circle.fill" : "video", recorder != nil ? "Stop recording" : "Record video clip") { toggleRecording() }
                    .foregroundStyle(recorder != nil ? TaskTone.input : Color.secondary)
                tool("camera", "Take a screenshot") { screenshot() }
                Spacer()
                tool("mic", "Dictate a comment") {
                    NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                HStack(spacing: 0) {
                    Button { send(nil) } label: {
                        Group {
                            if posting { ProgressView().controlSize(.mini) } else { Image(systemName: "paperplane.fill").font(.system(size: 12)) }
                        }
                        .frame(width: 34, height: 26)
                        .foregroundStyle(empty ? Color.secondary : Color.white)
                        .background(empty ? Color.secondary.opacity(0.12) : Color.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(empty || posting)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send comment")
                    if rich {
                        Button { laterOpen.toggle() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                .frame(width: 20, height: 26)
                                .foregroundStyle(empty ? Color.secondary : Color.white)
                                .background(empty ? Color.secondary.opacity(0.12) : Color.purple)
                        }
                        .buttonStyle(.plain)
                        .disabled(empty || posting)
                        .help("Schedule for later")
                        .accessibilityLabel("Schedule for later")
                        .popover(isPresented: $laterOpen, arrowEdge: .top) {
                            SchedulePanel { at in
                                laterOpen = false
                                send(CrmTime.iso(at.timeIntervalSince1970 * 1000))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 4)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            .frame(height: 38)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }

    private func tool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 28, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }

    private func fileOf(_ id: String) -> InlineFile? {
        guard let rows = model.attachments else { return InlineFile(image: nil, name: "Loading attachment…") }
        guard let a = rows.first(where: { $0.id == id }) else { return nil }
        let image = CrmFiles.isImage(mime: a.mimeType, fileName: a.fileName) ? a.previewUrl.flatMap(AttachmentsSection.image) : nil
        return InlineFile(image: image, name: a.fileName)
    }

    private func mention() {
        slashOpen = false
        value += (value.isEmpty || value.hasSuffix(" ") || value.hasSuffix("\n") ? "" : " ") + "@"
    }

    private func send(_ scheduledFor: String?) {
        let body = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !posting else { return }
        posting = true
        let who = assignee?.id
        Task {
            let ok = await model.postComment(body, assignee: who, scheduledFor: scheduledFor)
            posting = false
            if ok {
                value = ""
                assignee = nil
            }
        }
    }

    /// Files from the Mac's chooser go onto the task and into the comment.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard NativeFront.personActing, panel.runModal() == .OK else { return } // front-ok: guarded by NativeFront.personActing
        attach(panel.urls)
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploading = true
        Task {
            let placed = await onAttach(urls)
            uploading = false
            for a in placed { insertion = .file(a.id) }
        }
    }

    private static func captureName(_ now: Date, _ ext: String, clip: Bool = false) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let name = String(format: "Screenshot %04d-%02d-%02d %02d.%02d.%@", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, ext)
        return clip ? name.replacingOccurrences(of: "Screenshot", with: "Clip") : name
    }

    /// The Mac's own screenshot: pick an area or a window; the picture is attached.
    private func screenshot() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(Self.captureName(Date(), "png"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                if FileManager.default.fileExists(atPath: file.path) { attach([file]) }
            }
        }
        try? process.run()
    }

    /// A screen recording: started here, stopped here; the clip is attached.
    private func toggleRecording() {
        if let recorder {
            recorder.interrupt()
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(Self.captureName(Date(), "mov", clip: true))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                recorder = nil
                if FileManager.default.fileExists(atPath: file.path) { attach([file]) }
            }
        }
        do {
            try process.run()
            recorder = process
            recordingFile = file
        } catch {
            recorder = nil
        }
    }
}

/// "/" — Inline (Mention a Person) and Task actions, searchable; a command with
/// options opens them.
private struct SlashPanel: View {
    let commands: [SlashCommand]
    let onMention: () -> Void
    let onDone: () -> Void
    @State private var query = ""
    @State private var sub: SlashCommand?

    var body: some View {
        let all = [SlashCommand(key: "mention", group: "INLINE", label: "Mention a Person", icon: "at", run: onMention)] + commands
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = all.filter { needle.isEmpty || $0.label.lowercased().contains(needle) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let sub {
                    Button { self.sub = nil } label: { Label(sub.label, systemImage: "chevron.left").font(.caption.weight(.medium)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(sub.options) { o in
                        Button {
                            o.run()
                            onDone()
                        } label: {
                            HStack(spacing: 10) {
                                if let person = o.person { PersonAvatar(person: person) }
                                Text(o.label)
                                Spacer()
                            }
                            .frame(height: 36).padding(.horizontal, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                        TextField("Search", text: $query).textFieldStyle(.plain).accessibilityLabel("Search commands")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    if list.isEmpty { Text("No command matches.").font(.caption).foregroundStyle(.tertiary).padding(8) }
                    ForEach(["INLINE", "TASK ACTIONS"], id: \.self) { group in
                        let items = list.filter { $0.group == group }
                        if !items.isEmpty {
                            Text(group == "INLINE" ? "INLINE" : "TASK ACTIONS").font(.caption2.weight(.medium)).tracking(0.5)
                                .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                            ForEach(items) { c in
                                Button {
                                    if !c.options.isEmpty { sub = c }
                                    else {
                                        c.run?()
                                        if c.key != "mention" { onDone() } else { onDone() }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: c.icon).font(.caption).frame(width: 24, height: 24)
                                            .background(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                                        Text(c.label)
                                        Spacer()
                                        if !c.options.isEmpty { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                                    }
                                    .frame(height: 36).padding(.horizontal, 8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 440)
        .frame(maxHeight: 408)
    }
}

/// "Send later": a time of your own, or the quick choices.
private struct SchedulePanel: View {
    let onPick: (Date) -> Void
    @State private var custom = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DatePicker("Pick a time", selection: $custom, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    .help("Your computer's time")
                Text("Local").font(.caption).foregroundStyle(.secondary)
                Button("Schedule") { onPick(custom) }.buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                    .disabled(custom <= Date())
            }
            .padding(.bottom, 4)
            ForEach(CrmComments.schedulePresets(), id: \.key) { p in
                Button { onPick(p.at) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock").font(.caption).foregroundStyle(.tertiary)
                        Text(p.label)
                        Spacer()
                        Text(p.hint).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(height: 32).padding(.horizontal, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 300)
    }
}
