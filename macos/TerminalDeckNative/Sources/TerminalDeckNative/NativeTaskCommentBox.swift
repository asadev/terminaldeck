import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - The comment box

/// Inert UI fixture: the real composer/panels can be mounted without opening popovers,
/// and the exact UI callbacks can be retained to exercise late deliveries after hiding.
@MainActor
final class NativeTaskCommentFixture {
    let initialDraft: HootComposerDraft
    let panelsInline: Bool
    var schedule: ((Date) -> Void)?
    var send: ((HootComposerDraft) -> Void)?
    var inputScope: NativeSessionInputScope?

    init(draft: HootComposerDraft = .init(), panelsInline: Bool = true) {
        initialDraft = draft
        self.panelsInline = panelsInline
    }
}

struct Composer: View {
    let model: TaskDetailModel
    let commands: [SlashCommand]
    let onAttach: ([URL]) async -> [TaskAttachment]
    var fixtureMode = false
    var fixture: NativeTaskCommentFixture? = nil

    var body: some View {
        NativeTaskCommentComposerContent(model: model, commands: commands, onAttach: onAttach,
                                         fixtureMode: fixtureMode, fixture: fixture)
            .id(model.taskId)
            .nativeSessionInputScope(ownerID: "task-comment/" + model.taskId)
    }
}

private struct NativeTaskCommentComposerContent: View {
    let model: TaskDetailModel
    let commands: [SlashCommand]
    let onAttach: ([URL]) async -> [TaskAttachment]
    var fixtureMode = false
    var fixture: NativeTaskCommentFixture? = nil
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @State private var inputRule = NativeSessionInputRule()
    @State private var sharedDraft = HootComposerDraft()
    private var value: String {
        get { sharedDraft.text }
        nonmutating set { sharedDraft.text = newValue }
    }
    @State private var posting = false
    @State private var preparedFiles: [String: TaskAttachment] = [:]
    @State private var assignee: CrmPerson?
    @State private var uploading = false
    @State private var recorder: NativeChild?
    @State private var recordingFile: URL?

    init(model: TaskDetailModel, commands: [SlashCommand], onAttach: @escaping ([URL]) async -> [TaskAttachment],
         fixtureMode: Bool, fixture: NativeTaskCommentFixture?) {
        self.model = model
        self.commands = commands
        self.onAttach = onAttach
        self.fixtureMode = fixtureMode
        self.fixture = fixture
        _sharedDraft = State(initialValue: fixture?.initialDraft ?? .init())
    }

    var body: some View {
        inputRule.bind(to: scope)
        inputRule.update(active: scope == nil ? active : true, enabled: !posting && !uploading)
        fixture?.inputScope = scope
        fixture?.send = { send(nil, snapshot: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            // Asad, 12 Oct: everything the comment box offers sits behind its one + (no separate ⋯), drawn as
            // the ⋯ popover was, in sections, so adding to the comment never reads like acting on the task.
            HootComposer(draft: $sharedDraft, catalogue: model.commentComposerCatalogue,
                         showMeta: false, busy: false, enabled: !posting && !uploading,
                         placeholder: placeholder, microphoneAvailable: fixtureMode ? false : nil,
                         onSend: { send(nil, snapshot: $0) }, onStop: {},
                         onScreenshot: fixtureMode ? nil : { screenshot() },
                         addPanel: { panel in AnyView(commentPanel(panel)) },
                         addPanelLabel: "Add to the comment, or act on the task")
                .padding(.horizontal, 12).padding(.top, 8)
                .accessibilityLabel("Write a comment")
            if fixture?.panelsInline == true {
                commentPanel(HootComposerAddPanel(close: {}, mention: {}))
            }
            if let assignee {
                HStack(spacing: 6) {
                    PersonAvatar(person: assignee)
                    Text("Assign to \(assignee.name)")
                    NativeSessionButton { self.assignee = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).accessibilityLabel("Don't assign this comment")
                }
                .font(.caption).foregroundStyle(TaskTone.accent)
                .padding(.leading, 2).padding(.trailing, 6).padding(.vertical, 2)
                .background(Capsule().fill(TaskTone.accent.opacity(0.1)))
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            if posting || uploading || recorder != nil {
                HStack(spacing: 8) {
                    if recorder != nil {
                        Circle().fill(TaskTone.input).frame(width: 7, height: 7)
                        Text("Recording the screen…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(uploading ? "Attaching files…" : "Posting comment…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 6)
            }
        }
        .padding(.bottom, 12)
        .onChange(of: sharedDraft.attachments.map(\.id)) { _, ids in
            preparedFiles = preparedFiles.filter { ids.contains($0.key) }
        }
        // #96: closing the task, or moving to another, ends a recording started here.
        .onChange(of: model.taskId) { _, _ in stopRecording() }
        .onDisappear { stopRecording() }
    }

    private func commentPanel(_ panel: HootComposerAddPanel) -> some View {
        CommentAddPanel(panel: panel, commands: commands, team: model.team,
                        rich: model.commentExtras != nil || fixture != nil, fixtureMode: fixtureMode,
                        recording: recorder != nil, canSchedule: sharedDraft.canSend && !posting && !uploading,
                        assignee: $assignee,
                        onFiles: { pickFiles(images: false) }, onPhotos: { pickFiles(images: true) },
                        onScreenshot: { screenshot() }, onRecord: { toggleRecording() },
                        onEmoji: { emoji in
                            guard inputRule.acceptsFocus else { return }
                            value += emoji
                        },
                        onSchedule: { at in send(CrmTime.iso(at.timeIntervalSince1970 * 1000)) }, fixture: fixture)
    }

    private var placeholder: String {
        if model.commentThreadUIReady, let name = model.task.assignee?.name, !name.isEmpty {
            return "Comment — \(name) answers here." + (model.commentCapabilities["mentions"] == true ? " Type @ to ask another agent." : "")
        }
        return model.commentCapabilities["mentions"] == true ? "Comment — type @ to ask an agent." : "Write a comment."
    }

    private func send(_ scheduledFor: String?, snapshot supplied: HootComposerDraft? = nil) {
        let snapshot = supplied ?? sharedDraft
        // This is the UI boundary only. Once accepted, upload/post work keeps its captured
        // task and draft and may complete while the user looks at another screen.
        guard inputRule.acceptsFocus, snapshot.canSend, !posting, !uploading else { return }
        posting = true
        let who = assignee?.id
        Task {
            defer { posting = false }
            var ids: [String] = []
            for file in snapshot.attachments {
                if preparedFiles[file.id] == nil {
                    let uploaded = await onAttach([file.url])
                    guard uploaded.count == 1, let row = uploaded.first else {
                        model.error = model.error ?? "Could not attach “\(file.name)”. Your comment is still here."
                        return
                    }
                    preparedFiles[file.id] = row
                }
                guard let id = preparedFiles[file.id]?.id else { return }
                ids.append(id)
            }
            let ok = await model.postCommentDraft(snapshot, attachmentIDs: ids, assignee: who, scheduledFor: scheduledFor)
            if ok {
                if sharedDraft == snapshot { sharedDraft = .init(); assignee = nil; preparedFiles = [:] }
            }
        }
    }

    /// Files (or only pictures) from the Mac's chooser go onto the task and into the comment.
    private func pickFiles(images: Bool) {
        guard inputRule.acceptsFocus, !fixtureMode, NativeFront.personActing else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if images { panel.allowedContentTypes = ChatAttach.imageExtensions.compactMap { UTType(filenameExtension: $0) } }
        guard panel.runModal() == .OK, inputRule.acceptsFocus else { return } // front-ok: guarded by NativeFront.personActing
        attach(panel.urls)
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sharedDraft.add(urls)
        uploading = true
        Task {
            defer { uploading = false }
            for url in urls {
                let key = url.path
                guard preparedFiles[key] == nil, sharedDraft.attachments.contains(where: { $0.id == key }) else { continue }
                let placed = await onAttach([url])
                if placed.count == 1, let row = placed.first { preparedFiles[key] = row }
            }
        }
    }

    private static func captureName(_ now: Date, _ ext: String, clip: Bool = false) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let name = String(format: "Screenshot %04d-%02d-%02d %02d.%02d.%@", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, ext)
        return clip ? name.replacingOccurrences(of: "Screenshot", with: "Clip") : name
    }

    /// The Mac's own screenshot: pick an area or a window; the picture is attached.
    private func screenshot() {
        guard inputRule.acceptsFocus, !fixtureMode, NativeFront.personActing else { return }
        guard let folder = captureFolder() else { return }
        let file = folder.appendingPathComponent(Self.captureName(Date(), "png"))
        let child = try? NativeChild.start(.init("/usr/sbin/screencapture", ["-i", "-x", file.path], output: .discard, errors: .discard), exit: { _ in
            Task { @MainActor in
                if FileManager.default.fileExists(atPath: file.path) { attach([file]) }
            }
        })
        // It waits for the person to pick an area; one walked away from is not left open for good.
        child?.endAfter(.seconds(600))
    }

    /// A screen recording: started here, stopped here; the clip is attached.
    private func toggleRecording() {
        guard inputRule.acceptsFocus, !fixtureMode, NativeFront.personActing else { return }
        if let recorder {
            // SIGINT: screencapture finishes the clip; ended outright if it has not within 10 s.
            recorder.stop(first: SIGINT, grace: .seconds(10))
            return
        }
        guard let folder = captureFolder() else { return }
        let file = folder.appendingPathComponent(Self.captureName(Date(), "mov", clip: true))
        do {
            recorder = try NativeChild.start(.init("/usr/sbin/screencapture", ["-v", "-x", file.path], output: .discard, errors: .discard), exit: { _ in
                Task { @MainActor in
                    // stopRecording() let this clip go (it cleared recordingFile): it is deleted, never attached.
                    guard recordingFile == file else { try? FileManager.default.removeItem(at: file); return }
                    recorder = nil
                    if FileManager.default.fileExists(atPath: file.path) { attach([file]) }
                }
            })
            recordingFile = file
        } catch {
            recorder = nil
        }
    }
    /// The comment's draft goes with the task, so the unfinished clip does too; nothing keeps the screen recording.
    private func stopRecording() {
        guard let recorder else { return }
        // Its exit finds recordingFile cleared and deletes the clip.
        recorder.stop(first: SIGINT, grace: .seconds(10))
        self.recorder = nil; recordingFile = nil
    }
    private func captureFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-comment-captures.noindex", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard folder.lastPathComponent.hasSuffix(".noindex") else { return nil }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder }
        catch { model.error = "Could not save the capture: " + error.localizedDescription; return nil }
    }
}

/// The comment box's one + (Asad, 12 Oct): what was behind the separate ⋯ and behind the box's own +,
/// once each, drawn as the ⋯ popover was. Three jobs, three headed parts: what goes INTO the comment,
/// how the comment is sent, and actions on the TASK itself.
struct CommentAddPanel: View {
    let panel: HootComposerAddPanel
    let commands: [SlashCommand]
    let team: [CrmPerson]
    let rich: Bool
    let fixtureMode: Bool
    let recording: Bool
    let canSchedule: Bool
    @Binding var assignee: CrmPerson?
    let onFiles: () -> Void
    let onPhotos: () -> Void
    let onScreenshot: () -> Void
    let onRecord: () -> Void
    let onEmoji: (String) -> Void
    let onSchedule: (Date) -> Void
    var fixture: NativeTaskCommentFixture? = nil
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @State private var inputRule = NativeSessionInputRule()
    @State private var emojiOpen = false
    @State private var assignOpen = false
    @State private var laterOpen = false

    static let emoji = ["👍", "👏", "🙏", "🎉", "✅", "❌", "⚠️", "🔥", "❤️", "💯", "😀", "😂", "😅", "😊", "😍", "🤔", "😮", "😢", "😡", "👀",
                        "🚀", "📌", "📎", "📅", "⏰", "🏠", "🔑", "💰", "📞", "✉️", "🤝", "💪"]

    var body: some View {
        inputRule.bind(to: scope)
        inputRule.update(active: scope == nil ? active : true, enabled: true)
        return VStack(alignment: .leading, spacing: 4) {
            heading("ADD TO THE COMMENT")
            HStack(spacing: 2) {
                // The chooser, the area picker and the recorder need the screen: the panel closes first.
                tool("paperclip", "Add files") { panel.close(); onFiles() }.disabled(fixtureMode)
                tool("photo", "Add photos") { panel.close(); onPhotos() }.disabled(fixtureMode)
                tool("camera", "Take a screenshot") { panel.close(); onScreenshot() }.disabled(fixtureMode)
                tool(recording ? "record.circle.fill" : "video", recording ? "Stop recording" : "Record a video clip") { panel.close(); onRecord() }
                    .foregroundStyle(recording ? TaskTone.input : Color.secondary)
                    .disabled(fixtureMode)
                tool("face.smiling", "Emoji") { emojiOpen.toggle() }
                    .popover(isPresented: $emojiOpen, arrowEdge: .top) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 8), spacing: 2) {
                            ForEach(Self.emoji, id: \.self) { e in
                                NativeSessionButton {
                                    emojiOpen = false
                                    onEmoji(e)
                                } label: { Text(e).font(.title3).frame(width: 28, height: 28) }
                                    .buttonStyle(.plain).accessibilityLabel("Insert \(e)")
                            }
                        }
                        .padding(8)
                    }
                tool("at", "Mention someone") { panel.mention() }
            }
            if rich {
                heading("SEND")
                HStack(spacing: 2) {
                    tool(assignee == nil ? "person" : "person.fill", "Assign this comment to someone") { assignOpen.toggle() }
                        .popover(isPresented: $assignOpen, arrowEdge: .top) {
                            PersonSearchList(team: team, isPicked: { $0 == assignee?.id }, onPick: { p in
                                guard inputRule.acceptsFocus else { return }
                                assignee = p.id == assignee?.id ? nil : p
                                assignOpen = false
                            })
                            .frame(width: 280)
                        }
                    tool("calendar.badge.clock", canSchedule ? "Send later" : "Send later (write the comment first)") { laterOpen.toggle() }
                        .disabled(!canSchedule)
                        .popover(isPresented: $laterOpen, arrowEdge: .top) {
                            schedulePanel
                        }
                }
            }
            if fixture?.panelsInline == true {
                schedulePanel.disabled(!canSchedule)
            }
            if !commands.isEmpty {
                Divider().padding(.vertical, 4)
                heading("TASK ACTIONS")
                SlashPanel(commands: commands, onMention: { panel.mention() }, onDone: { panel.close() }, embedded: true)
            }
        }
        .padding(8)
        .frame(width: 340, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add to the comment, or act on the task")
    }

    private var schedulePanel: some View {
        SchedulePanel(fixture: fixture) { at in
            guard inputRule.acceptsFocus, canSchedule else { return }
            laterOpen = false
            panel.close()
            onSchedule(at)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).tracking(0.5).foregroundStyle(.tertiary)
            .padding(.horizontal, 6).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func tool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        NativeSessionButton(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 30, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// "/" — Inline (Mention a Person) and Task actions, searchable; a command with
/// options opens them. Inside the comment box's + it is the TASK ACTIONS part only
/// (the + has its own Mention).
struct SlashPanel: View {
    let commands: [SlashCommand]
    let onMention: () -> Void
    let onDone: () -> Void
    var embedded = false
    @State private var query = ""
    @State private var sub: SlashCommand?

    var body: some View {
        let all = (embedded ? [] : [SlashCommand(key: "mention", group: "INLINE", label: "Mention a Person", icon: "at", run: onMention)]) + commands
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = all.filter { needle.isEmpty || $0.label.lowercased().contains(needle) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let sub {
                    NativeSessionButton { self.sub = nil } label: { Label(sub.label, systemImage: "chevron.left").font(.caption.weight(.medium)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(sub.options) { o in
                        NativeSessionButton {
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
                        NativeSessionTextField("Search", text: $query).textFieldStyle(.plain).accessibilityLabel("Search commands")
                        if !query.isEmpty {
                            NativeSessionButton { query = "" } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    if list.isEmpty { Text("No command matches.").font(.caption).foregroundStyle(.tertiary).padding(8) }
                    ForEach(["INLINE", "TASK ACTIONS"], id: \.self) { group in
                        let items = list.filter { $0.group == group }
                        if !items.isEmpty {
                            if !embedded {
                                Text(group == "INLINE" ? "INLINE" : "TASK ACTIONS").font(.caption2.weight(.medium)).tracking(0.5)
                                    .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                            }
                            ForEach(items) { c in
                                NativeSessionButton {
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
            .padding(embedded ? 0 : 8)
        }
        .frame(width: embedded ? nil : 440)
        .frame(maxHeight: embedded ? 260 : 408)
    }
}

/// "Send later": a time of your own, or the quick choices.
struct SchedulePanel: View {
    let onPick: (Date) -> Void
    var fixture: NativeTaskCommentFixture? = nil
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @State private var inputRule = NativeSessionInputRule()
    @State private var custom = Date().addingTimeInterval(3600)

    init(fixture: NativeTaskCommentFixture? = nil, onPick: @escaping (Date) -> Void) {
        self.fixture = fixture
        self.onPick = onPick
    }

    private func pick(_ at: Date) {
        guard inputRule.acceptsFocus, at > Date() else { return }
        onPick(at)
    }

    var body: some View {
        inputRule.bind(to: scope)
        inputRule.update(active: scope == nil ? active : true, enabled: enabled)
        fixture?.schedule = { pick($0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                NativeSessionDatePicker(selection: Binding(get: { custom }, set: {
                    guard inputRule.acceptsFocus else { return }
                    custom = $0
                }))
                    .help("Your computer's time")
                Text("Local").font(.caption).foregroundStyle(.secondary)
                NativeSessionButton("Schedule") { pick(custom) }.buttonStyle(.borderedProminent).tint(TaskTone.accent).controlSize(.small)
                    .disabled(custom <= Date())
            }
            .padding(.bottom, 4)
            ForEach(CrmComments.schedulePresets(), id: \.key) { p in
                NativeSessionButton { pick(p.at) } label: {
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
