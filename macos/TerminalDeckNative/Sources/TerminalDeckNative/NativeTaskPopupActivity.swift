import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - Main

enum FIXESTaskThreadPane: String, CaseIterable { case comments, activity }
/// Only the existing engine's current task/agent/turn push may populate this.
struct FIXESTaskWritingProof {
    let taskID: String
    let agentID: String
    let turnID: String
    let name: String
    let icon: AGTIcon
    let isHoot: Bool
    /// The agent's chosen glyph colour, so the line matches its comment avatar.
    let colour: String?
    init(taskID: String, agentID: String, turnID: String, name: String, icon: AGTIcon, isHoot: Bool, colour: String? = nil) {
        self.taskID = taskID; self.agentID = agentID; self.turnID = turnID
        self.name = name; self.icon = icon; self.isHoot = isHoot; self.colour = colour
    }
}

// Activity, the popup's right column (page/activity-pane.tsx + activity-feed.tsx):
// the header (search, followers, filter), the feed (activity lines and comment
// cards with replies, reactions, resolve, schedule), and the comment box with its
// toolbar (slash commands, attach, mention, assign, emoji, record, screenshot,
// dictate, send, send later).

struct TaskActivityPane: View {
    let model: TaskDetailModel
    let commands: [SlashCommand]
    let onAttach: ([URL]) async -> [TaskAttachment]
    var fixtureMode = false
    @State private var searchOpen = false
    @State private var query = ""
    @State private var hidden: Set<FeedCategory> = []
    @State private var replyingTo: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Picker("Task thread", selection: Binding(get: { model.commentPaneSelection }, set: { model.commentPaneSelection = $0 })) {
                    Text("Comments \(visibleCommentCount)").tag(FIXESTaskThreadPane.comments)
                    Text("Activity").tag(FIXESTaskThreadPane.activity)
                }.pickerStyle(.segmented).fixedSize().accessibilityLabel("Comments or activity")
                Spacer(minLength: 4)
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
                        if model.commentPaneSelection == .activity, let error = model.activityError {
                            Text("Activity unavailable: \(error)").font(.caption).foregroundStyle(TaskTone.waiting)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(TaskTone.waiting.opacity(0.1)))
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if let error = model.commentsErrorText {
                            Text("Could not load comments: \(error)").font(.caption).foregroundStyle(TaskTone.input)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if model.commentPaneSelection == .activity, let rows = model.activity, let total = model.activityTotal, total > rows.count {
                            Text("Showing the latest \(rows.count) of \(total.formatted(.number)) lines.").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        if (model.commentPaneSelection == .comments ? model.comments != nil : model.activity != nil) {
                            ActivityFeed(model: model, rows: model.activity ?? [], query: query, hidden: hidden,
                                         replyingTo: $replyingTo, pane: model.commentPaneSelection)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Loading…") }
                                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        if model.commentPaneSelection == .comments, let proof = model.currentWriting,
                           proof.taskID == model.taskId, !proof.turnID.isEmpty {
                            FIXESTaskTypingRow(proof: proof)
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
            // One comment box per task: a popup that moves to another task never carries the draft over (30 Oct).
            Composer(model: model, commands: commands, onAttach: onAttach, fixtureMode: fixtureMode).id(model.taskId)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task comments and activity")
    }

    private var visibleCommentCount: Int {
        let meta = model.commentExtras?.meta ?? [:]
        return (model.comments ?? []).filter { CrmComments.visible($0, meta[$0.id], viewer: model.me) }.count
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
