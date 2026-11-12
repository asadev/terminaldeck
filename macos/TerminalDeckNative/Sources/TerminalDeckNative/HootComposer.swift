import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TerminalDeckNativeCore

/// Shared A0 chat context. IDs, not display names, are carried to the host.
struct HootMention: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, CaseIterable, Sendable, Codable { case session, page, agent, simulator, tool, file, folder }
    var id: String
    var kind: Kind
    var name: String
    var project: String = ""
    var group: String = ""
    var symbol: String {
        switch kind { case .session: "terminal"; case .page: "doc"; case .agent: "person.crop.square"; case .simulator: "iphone"; case .tool: "puzzlepiece.extension"; case .file: "doc.text"; case .folder: "folder" }
    }
    var isReference: Bool { kind == .file || kind == .folder }
    var marker: String { "{{mention:\(kind.rawValue):\(id)}}" }
    var wire: NativeRPCValue { .object([.init("id", .string(id)), .init("kind", .string(kind.rawValue)), .init("name", .string(name)), .init("project", .string(project))]) }
}
struct HootComposerAttachment: Identifiable, Equatable, Sendable, Codable {
    var url: URL
    var source: String = ""
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}
enum HootPermissionMode: String, CaseIterable, Sendable, Codable {
    case ask = "ask", plan = "plan", changes = "changes", bypass = "bypass"
    var title: String { switch self { case .ask: "Asks before changes"; case .plan: "Plans only"; case .changes: "Changes without asking"; case .bypass: "Bypass permissions" } }
    /// The mode's full name, as a chat session's box shows it (Asad, 13 Oct: "Bypass permissions", nothing more).
    var fullName: String { switch self { case .ask: "Ask before edits"; case .plan: "Plan mode"; case .changes: "Edit automatically"; case .bypass: "Bypass permissions" } }
    /// The short choice shown under the message box.
    var short: String { switch self { case .ask: "Ask first"; case .plan: "Plan only"; case .changes: "Auto"; case .bypass: "Bypass permissions" } }
    /// Auto and Bypass confirm first.
    var risky: Bool { self == .changes || self == .bypass }
    var hint: String { switch self { case .ask: "Reads freely; asks before changing anything."; case .plan: "Reads and plans; makes no changes."; case .changes: "May change things within the access you have granted."; case .bypass: "The AI runs commands and changes files without asking you." } }
}
struct HootComposerModel: Identifiable, Equatable, Sendable {
    var id: String
    var provider: String
    var name: String
    var title: String { "\(provider) · \(name)" }
    /// Claude-style short effort words; xhigh reads as "Extra".
    static func effortName(_ effort: String) -> String {
        switch effort {
        case "default": "Default"
        case "xhigh": "Extra"
        case "ultracode": "Ultracode"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}
struct HootComposerTool: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
}
/// A slash command the AI itself offers (Asad, 13 Oct: "slash commands must work in chat, the way Claude's own app
/// does it"): reported by the CLI (Claude's handshake and session start, Gemini's ACP list), never a list of ours.
/// Sending "/name args" as the message runs it. The ones that only open the CLI's own terminal screens are not
/// offered; where the app has its own control for the same thing, the item opens that instead.
struct HootSlashCommand: Identifiable, Equatable, Sendable {
    var name: String
    var description: String = ""
    var argumentHint: String = ""
    /// Set when the app's own control does this: what picking it opens.
    var opensInApp: String? = nil
    var id: String { name }

    /// Only a terminal screen of the CLI's own (pickers, editors, set-up): nothing to type in a chat.
    static let terminalOnly: Set<String> = ["theme", "terminal-setup", "vim", "ide", "statusline", "upgrade", "hooks",
        "mcp", "agents", "memory", "bashes", "export", "privacy-settings", "exit", "quit", "rewind", "output-style",
        "install-github-app", "migrate-installer", "add-dir", "resume", "keybindings", "plugin"]
    /// The app's own control for the same thing.
    static let appControls: [String: String] = ["model": "Chat model picker", "reasoning": "Chat effort picker", "effort": "Chat effort picker", "approve": "Chat permissions", "login": "Settings (Coding AIs)",
        "logout": "Settings (Coding AIs)", "feedback": "Chat diagnostics", "bug": "Chat diagnostics", "doctor": "Chat diagnostics", "config": "Settings", "permissions": "Chat permissions", "status": "Chat account status"]

    /// What the CLI reported, as the menu offers it.
    static func offered(_ raw: NativeRPCValue) -> [HootSlashCommand] {
        (raw.elements ?? []).compactMap { row in
            guard let name = row["name"].string, !name.isEmpty, !terminalOnly.contains(name) else { return nil }
            return HootSlashCommand(name: name, description: row["description"].string ?? "",
                                    argumentHint: row["argumentHint"].string ?? "", opensInApp: appControls[name])
        }
    }
    /// The "/…" being typed: the whole box is one slash word so far (nil otherwise).
    static func query(_ text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) else { return nil }
        return String(text.dropFirst())
    }
    /// The commands for what is typed: the exact name first (so Return sends a whole typed name, never a longer one),
    /// then names that start with it, then names or descriptions that contain it.
    static func matches(_ commands: [HootSlashCommand], query: String) -> [HootSlashCommand] {
        let wanted = query.lowercased()
        guard !wanted.isEmpty else { return commands }
        let exact = commands.filter { $0.name.lowercased() == wanted }
        let starts = commands.filter { $0.name.lowercased().hasPrefix(wanted) && $0.name.lowercased() != wanted }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(wanted) && ($0.name.lowercased().contains(wanted) || $0.description.lowercased().contains(wanted)) }
        return exact + starts + contains
    }
}

struct HootComposerCatalogue: Sendable {
    var referenceLoading = false
    var referenceProblem: String?
    var mentions: [HootMention] = []
    /// The "/" menu: the commands the AI itself offers (HootSlashCommand).
    var commands: [HootSlashCommand] = []
    /// The host supplies every installed Coding AI's offered models.
    var models: [HootComposerModel] = []
    var tools: [HootComposerTool] = []
    /// The selected Coding AI's effort levels (empty hides the Effort section).
    var efforts: [String] = []
    /// The level the CLI marks "Recommended" for the selected model (nil when none).
    var recommendedEffort: String? = nil
    /// Every installed Coding AI's live models, one section each, so switching back is always
    /// possible. A section with no live list shows just that AI's current model.
    var sections: [HootModelSection] = []
    /// A CLI alias in use ("claude:opus", "claude:sonnet[1m]") → the live model it means.
    var resolved: [String: String] = [:]
    /// Whether a model row is the saved choice, by its own id or the alias it stands for (every picker ticks with this).
    func isChosen(_ model: HootComposerModel, savedID: String) -> Bool { savedID == model.id || resolved[savedID] == model.id }
    var featured: [HootComposerModel] { sections.flatMap(\.featured) }
    var more: [HootComposerModel] { sections.flatMap(\.more) }
}
struct HootModelSection: Identifiable, Sendable {
    var id: String          // claude / codex / gemini
    var name: String        // Claude Code / Codex / Gemini
    var featured: [HootComposerModel] = []
    var more: [HootComposerModel] = []
    /// nil when this AI does not offer Fast mode (or it is not the AI in use).
    var fastMode: Bool? = nil
}
struct HootComposerDraft: Equatable, Sendable, Codable {
    var text = ""
    var mentions: [HootMention] = []
    var attachments: [HootComposerAttachment] = []
    var permissionMode: HootPermissionMode = .ask
    var modelID = ""
    var effort = ""
    var plainText: String { mentions.reduce(text) { $0.replacingOccurrences(of: $1.marker, with: $1.name) } }
    var canSend: Bool { !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    var activeMentions: [HootMention] { mentions.filter { text.contains($0.marker) } }
    var wire: NativeRPCValue { .object([
        .init("text", .string(plainText)), .init("mentions", .array(activeMentions.map(\.wire))),
        .init("attachments", .array(attachments.map { .object([.init("path", .string($0.url.path)), .init("name", .string($0.name)), .init("source", .string($0.source))]) })),
        .init("permissionMode", .string(permissionMode.rawValue)), .init("model", .string(modelID))]) }
    mutating func add(_ urls: [URL], source: String = "") {
        for url in urls where url.isFileURL && !attachments.contains(where: { $0.url == url }) {
            if attachments.count >= ChatAttach.maxAttachments { break }
            attachments.append(.init(url: url, source: source))
        }
    }
    mutating func insert(_ mention: HootMention) {
        if !mentions.contains(where: { $0.marker == mention.marker }) { mentions.append(mention) }
        text += mention.marker
    }
}

/// Floating chat control. Mount over the conversation with a bottom inset of
/// composer height +24; the host supplies data/actions and owns sending errors.
struct HootComposer: View {
    @Binding var draft: HootComposerDraft
    var ownerID: String? = nil
    var focusWhenShown = false
    var catalogue = HootComposerCatalogue()
    var showMeta = true
    /// Which part to draw. A chat can float `.box` over its scroll area (so messages slide
    /// behind the glass) and put `.meta` below it, outside the scroll area.
    var part: HootComposerPart = .whole
    var busy = false
    var allowsSteering = false
    var enabled = true
    var placeholder = "Ask Hoot — type @ to mention a session, page, agent or app"
    /// Who answers (Hoot, or a chat session's AI), for the words that name it.
    var agentName = "Hoot"
    /// A chat session's row under the box (Asad, 13 Oct): the mode's full name on the left, the model and the effort
    /// as plain words on the right, each opening its own short list. Hoot's own row is unchanged.
    var plainMeta = false
    var microphoneAvailable: Bool? = nil // nil: observe this Mac; false: deterministic fixture
    var onSend: (HootComposerDraft) -> Void
    var onStop: () -> Void
    var onScreenshot: (() -> Void)? = nil
    var onManageTools: (() -> Void)? = nil
    var onToolChange: ((String, Bool) -> Void)? = nil
    var onPermissionChange: ((HootPermissionMode) -> Void)? = nil
    var onModelChange: ((String) -> Void)? = nil
    var onEffortChange: ((String) -> Void)? = nil
    var onFastModeChange: ((Bool) -> Void)? = nil
    /// Count this up to type an "@" at the caret and open the @ list there, exactly as typing "@"
    /// does (the owner's own "Mention someone" button).
    var mentionRequest = 0
    /// A "/" item the app's own control answers (it opens that control; nothing is sent).
    var onAppCommand: ((HootSlashCommand) -> Void)? = nil
    var onReferenceQuery: ((String?) -> Void)? = nil
    var onRecall: ((Bool) -> Bool)? = nil
    var attachmentLimits: ChatAttachmentLimits? = nil
    var canStop = true
    var stopping = false
    /// The owner's own + panel (a task's comment box: what to add to the comment, the comment's options,
    /// the task's actions). The + opens it in a popover in place of the menu; nil keeps the menu (Hoot).
    var addPanel: ((HootComposerAddPanel) -> AnyView)? = nil
    /// The + button's name when the owner supplies its panel.
    var addPanelLabel = "Add to the message"
    var dictationOwner: HootComposerVoice? = nil
    var onDictationStart: (() -> Void)? = nil
    var onExpandLongPrompt: (() -> Void)? = nil
    /// Fixed activity belongs to the same message surface, so it adds no gap above the box.
    var status: AnyView? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.agkitOffscreenSolid) private var offscreenSolid
    @Environment(\.nativeScreenActive) private var screenActive
    @Environment(\.nativeSessionInputScope) private var inputScope
    @Environment(\.nativeTerminalSelected) private var layoutSelected
    @State private var inputRule = NativeSessionInputRule()
    @State private var localVoice = HootComposerVoice()
    private var voice: HootComposerVoice { dictationOwner ?? localVoice }
    @State private var editor = HootComposerEditorHandle()
    @State private var notice: String?
    @State private var mentionQuery: String?
    @State private var proposedTool: HootComposerTool?
    @State private var confirmChanges = false
    @State private var riskyMode: HootPermissionMode = .changes
    @State private var dragging = false
    @State private var sendAfterVoice = false
    @State private var showEffort = false
    @State private var addPanelOpen = false
    @State private var mentionAfterPanel = false
    /// The "/…" the person closed the menu on (Escape or a click elsewhere), so it stays closed for it.
    @State private var slashClosedOn: String?

    private var hasMicrophone: Bool { microphoneAvailable ?? voice.available }
    private var selectedModel: String { catalogue.models.first(where: { $0.id == draft.modelID })?.title ?? "Choose Coding AI and model" }
    var body: some View {
        inputRule.bind(to: inputScope)
        inputRule.update(active: inputScope == nil ? screenActive : true, enabled: enabled)
        let voiceOwner = voice
        let sendAfterVoiceBinding = $sendAfterVoice
        inputRule.onScopeWillDeactivate = { [weak voiceOwner] in
            // The epoch changes synchronously; discard the voice continuation even if
            // the same screen returns before the asynchronous stop has completed.
            Task {
                sendAfterVoiceBinding.wrappedValue = false
                if let voiceOwner, voiceOwner.recording || voiceOwner.starting { await voiceOwner.stop() }
            }
        }
        return VStack(spacing: 8) {
            if part == .box, let line = notice ?? voice.problem {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if part != .meta {
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    if let status { status }
                    if let shown = slashShown { slashMenu(shown) }
                    if !draft.attachments.isEmpty {
                        attachments
                        if let attachmentLimits { Text(attachmentLimits.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    ZStack(alignment: .topLeading) {
                        if draft.text.utf8.count > 4096, let onExpandLongPrompt {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Large prompt · \(draft.text.utf8.count) / 262144 UTF-8 bytes").font(.caption).foregroundStyle(.secondary)
                                Text(String(draft.plainText.prefix(240))).font(.callout).lineLimit(3)
                                NativeSessionButton("Edit full prompt", action: onExpandLongPrompt)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                        HootComposerEditor(draft: $draft, ownerID: ownerID, focusWhenShown: focusWhenShown,
                                           selected: layoutSelected ?? true, handle: editor, onReturn: returnPressed,
                                           onFiles: addFiles, onMentionQuery: { mentionQuery = $0 },
                                           mentionNames: { DeckMentionRows.names(for: catalogue.mentions) }, onRecall: onRecall)
                            .id(ownerID)
                            .id(inputScope?.identity)
                            .frame(height: editor.height)
                        }
                        if draft.text.isEmpty && !voice.recording {
                            Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(.top, 3).allowsHitTesting(false)
                        }
                    }
                    .disabled(!enabled)
                    HStack(spacing: 8) {
                        addMenu
                        Spacer(minLength: 8)
                        if voice.recording { levelMeter }
                        else if voice.starting || voice.finishing {
                            Text(voice.finishing ? "Finishing dictation…" : "Getting dictation ready…")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        NativeSessionButton { toggleVoice() } label: {
                            Image(systemName: voice.recording ? "waveform" : "mic")
                                .foregroundStyle(voice.recording ? Color.red : Color.secondary)
                                .frame(width: 32, height: 32)
                                .background(AGKITStyle.selection, in: .circle)
                        }.buttonStyle(.plain).disabled(!enabled || (!hasMicrophone && !voice.recording) || voice.starting || voice.finishing)
                            .opacity(!hasMicrophone && !voice.recording ? 0.4 : 1)
                            .help(hasMicrophone ? (voice.recording ? "Stop dictation" : "Dictate a message") : "No microphone connected")
                            .accessibilityLabel(hasMicrophone ? (voice.recording ? "Stop dictation" : "Dictate a message") : "No microphone connected")
                        primaryControl
                    }
                }
                .padding(16)
                .foregroundStyle(.primary)
                .modifier(HootComposerSurface(solid: reduceTransparency || offscreenSolid))
                .overlay { if dragging { RoundedRectangle(cornerRadius: 22).stroke(Color.accentColor, lineWidth: 2) } }
            }
            }
            if part != .box && showMeta { metadata }
            if part == .whole, let line = notice ?? voice.problem {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: 720)
        .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
            guard inputRule.acceptsFocus else { return false }
            Task { for provider in providers {
                if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) { addFiles([url]) }
                else if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { addFiles([url]) }
            } }
            return true
        }
        .onAppear {
            inputRule.update(active: inputScope == nil ? screenActive : true, enabled: enabled)
            voice.viewAppeared()
        }
        .onChange(of: screenActive) { _, shown in
            if !shown {
                sendAfterVoice = false
                mentionQuery = nil
                if voice.recording || voice.starting { Task { await voice.stop() } }
            }
        }
        .onDisappear {
            inputRule.update(active: false, enabled: false)
            sendAfterVoice = false
            if voice.viewDisappeared() { Task { await voice.stop() } }
        }
        .onChange(of: mentionRequest) { _, _ in if enabled { editor.typeMentionSign() } }
        .onChange(of: mentionQuery) { _, query in onReferenceQuery?(query) }
        // The panel's "Mention": the @ list opens on the box, so the panel closes first.
        .onChange(of: addPanelOpen) { _, open in
            if !open, mentionAfterPanel { mentionAfterPanel = false; if enabled { editor.typeMentionSign() } }
        }
        .popover(isPresented: Binding(get: { mentionQuery != nil }, set: { if !$0 { mentionQuery = nil } }), arrowEdge: .top) {
            // FORK-L1: profile rows (avatar, project · role, awake dot), sections, ↑ ↓ Return, scrolls.
            VStack(spacing: 4) {
                if catalogue.referenceLoading { ProgressView().controlSize(.small).padding(6) }
                if let problem = catalogue.referenceProblem { Text(problem).font(.caption).foregroundStyle(.secondary).padding(8) }
                DeckMentionPicker(candidates: catalogue.mentions, query: mentionQuery ?? "",
                                  onPick: { insert($0, replaceQuery: true) }, onCancel: { mentionQuery = nil })
            }
        }
        .confirmationDialog(riskyMode == .bypass ? "Let \(agentName) work without asking?" : "Allow changes without asking in this chat?", isPresented: $confirmChanges) {
            NativeSessionButton(riskyMode == .bypass ? "Use Bypass permissions" : "Allow changes", role: riskyMode == .bypass ? .destructive : nil) { setPermission(riskyMode) }
        } message: { Text(riskyMode.hint) }
        .confirmationDialog("Change this chat's connected tool?", isPresented: Binding(get: { proposedTool != nil }, set: { if !$0 { proposedTool = nil } })) {
            if let tool = proposedTool { NativeSessionButton(tool.enabled ? "Turn off \(tool.name)" : "Turn on \(tool.name)") { onToolChange?(tool.id, !tool.enabled); proposedTool = nil } }
        } message: { Text("This changes which tools Hoot can use for this chat.") }
    }
    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 8) {
                        HootAttachmentThumbnail(url: attachment.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            if !attachment.source.isEmpty { Text(attachment.source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        NativeSessionButton { draft.attachments.removeAll { $0.id == attachment.id }; HootPastedFiles.discard([attachment.url]) } label: { Image(systemName: "xmark.circle.fill").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(attachment.name)").accessibilityLabel("Remove \(attachment.name)")
                    }.padding(.leading, 12).padding(.vertical, 6).frame(maxWidth: 280)
                        .background(AGKITStyle.card, in: .rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(AGKITStyle.hairline))
                }
            }
        }
    }
    @ViewBuilder private var addMenu: some View {
        if let addPanel {
            NativeSessionButton { addPanelOpen.toggle() } label: {
                Image(systemName: "plus").font(.system(size: 16))
                    .frame(width: 32, height: 32).background(AGKITStyle.selection, in: .circle).contentShape(.circle)
            }
            .buttonStyle(.plain).foregroundStyle(.primary).disabled(!enabled)
            .help(addPanelLabel).accessibilityLabel(addPanelLabel)
            .popover(isPresented: $addPanelOpen, arrowEdge: .top) {
                addPanel(HootComposerAddPanel(close: { addPanelOpen = false },
                                              mention: { mentionAfterPanel = true; addPanelOpen = false }))
            }
        } else {
            menuForAdding
        }
    }
    private var menuForAdding: some View {
        Menu {
            NativeSessionButton("Add files…", systemImage: NativeAttachMenu.symbol(.file)) { browse(images: false) }.keyboardShortcut("o")
            NativeSessionButton("Add photos…", systemImage: NativeAttachMenu.symbol(.image)) { browse(images: true) }
            if let onScreenshot { NativeSessionButton("Take a screenshot", systemImage: "camera.viewfinder", action: onScreenshot) }
            Divider()
            Section("Mention") {
                ForEach(HootMention.Kind.allCases, id: \.self) { kind in
                    Menu(mentionTitle(kind)) {
                        let candidates = catalogue.mentions.filter { $0.kind == kind }
                        if candidates.isEmpty { Text("None available") }
                        let groups = Array(Set(candidates.map { mentionGroup($0) })).sorted {
                            let a = $0 == "Running" || $0 == "Booted" ? 0 : 1
                            let b = $1 == "Running" || $1 == "Booted" ? 0 : 1
                            return a == b ? $0 < $1 : a < b
                        }
                        ForEach(groups, id: \.self) { group in
                            Section(group) {
                                ForEach(candidates.filter { mentionGroup($0) == group }, id: \.marker) { mention in
                                    NativeSessionButton { insert(mention) } label: {
                                        Label(mention.name + (mention.project.isEmpty ? "" : " · " + mention.project), systemImage: mention.symbol)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // SETTINGS-TRUTH row 104: the per-tool list was never filled and every switch was dead. Only the real way to
            // manage tools stays, and only where it works.
            if let onManageTools {
                Divider()
                NativeSessionButton("Manage tools in MCP servers…", systemImage: "puzzlepiece.extension") { onManageTools() }
            }
        } label: { Image(systemName: "plus").font(.system(size: 16)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 32, height: 32).background(AGKITStyle.selection, in: .circle).contentShape(.circle).disabled(!enabled)
            .help("Add files, photos or a mention").accessibilityLabel("Add files, photos or a mention")
    }
    /// Short choices, like Claude's own pickers; the explanation is only a tooltip.
    private var metadata: some View {
        HStack {
            Menu {
                ForEach(HootPermissionMode.allCases, id: \.self) { mode in
                    NativeSessionButton { if mode.risky { riskyMode = mode; confirmChanges = true } else { setPermission(mode) } } label: {
                        choice(mode.short, draft.permissionMode == mode)
                    }.help(mode.hint)
                }
            } label: {
                if plainMeta { Text(draft.permissionMode.fullName).lineLimit(1) }
                else { HStack(spacing: 3) { Label(draft.permissionMode.short, systemImage: "shield"); chevron } }
            }
            .help(draft.permissionMode.hint)
            .frame(minHeight: 28).contentShape(.rect)
            Spacer(minLength: 8)
            // Two short buttons, like Claude's "Fable 5.1  Extra": the model, then the effort.
            if !catalogue.models.isEmpty || !catalogue.featured.isEmpty {
                Menu {
                    // Every installed AI's live list, grouped; nothing added on his behalf, no error row.
                    if catalogue.sections.isEmpty {
                        choice(shortModel, true)
                    }
                    ForEach(catalogue.sections) { section in
                        Section(section.name) {
                            ForEach(section.featured) { model in modelButton(model) }
                            if !section.more.isEmpty {
                                Menu("More models") { ForEach(section.more) { model in modelButton(model) } }
                            }
                            if let fast = section.fastMode {
                                Toggle("Fast mode", isOn: Binding(get: { fast }, set: { onFastModeChange?($0) }))
                            }
                        }
                    }
                } label: { Text(shortModel).lineLimit(1) }  // no arrow (Asad 10 Oct)
                .help(selectedModel)
                .frame(minHeight: 28).contentShape(.rect)
            }
            if !catalogue.efforts.isEmpty, !draft.effort.isEmpty {
                NativeSessionButton { showEffort.toggle() } label: {
                    HStack(spacing: 3) {
                        // As wide as the widest level, so the popover never moves while dragging.
                        ZStack(alignment: .leading) {
                            ForEach(catalogue.efforts, id: \.self) { Text(effortWord($0)).hidden() }
                            Text(effortWord(draft.effort))
                        }.lineLimit(1)
                    }
                }
                .help("Effort")
                .frame(minHeight: 28).contentShape(.rect)
                .popover(isPresented: $showEffort, arrowEdge: .bottom) {
                    HootEffortSlider(levels: catalogue.efforts, recommended: catalogue.recommendedEffort, selected: draft.effort) { effort in
                        draft.effort = effort; onEffortChange?(effort)
                    }
                }
            }
        }.font(.system(size: 12)).foregroundStyle(.secondary).menuStyle(.button).buttonStyle(.plain).padding(.horizontal, 12).disabled(!enabled)
    }
    private func modelButton(_ model: HootComposerModel) -> some View {
        NativeSessionButton { draft.modelID = model.id; onModelChange?(model.id) } label: {
            choice(model.name, catalogue.isChosen(model, savedID: draft.modelID))
        }
    }
    @ViewBuilder private func choice(_ title: String, _ selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
    /// "Opus 5" rather than "Claude Code · Opus 5"; the Coding AI's name when on its default.
    private var shortModel: String {
        // The real name ("Opus 5.5"), never the CLI's alias ("opus").
        let id = catalogue.resolved[draft.modelID] ?? draft.modelID
        guard let model = (catalogue.featured + catalogue.more + catalogue.models).first(where: { $0.id == id }) else {
            let alias = draft.modelID.split(separator: ":").last.map(String.init) ?? ""
            return alias.isEmpty ? "Choose a model" : alias.replacingOccurrences(of: "[1m]", with: "").capitalized
        }
        if model.name == model.id.split(separator: ":").last.map(String.init) {
            return model.name.replacingOccurrences(of: "[1m]", with: "").capitalized   // an alias with no live match
        }
        return ["Default", "default"].contains(model.name) ? "Choose model" : model.name
    }
    /// Drawn by SwiftUI so the quiet secondary colour holds (a borderless AppKit menu draws its title in full label colour).
    private var chevron: some View { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
    private var levelMeter: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("Listening").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 4)
            ForEach(0..<8) { index in
                Capsule().fill(Color.red.opacity(0.75)).frame(width: 3, height: 4 + CGFloat(max(0, voice.level * 24 - Float(abs(index - 3)) * 2)))
            }
        }.frame(height: 24).accessibilityLabel("Listening").accessibilityValue("Microphone level \(Int(voice.level * 100)) percent")
    }
    private func mentionTitle(_ kind: HootMention.Kind) -> String { switch kind { case .session: "A session"; case .page: "A page"; case .agent: "An agent"; case .simulator: "A simulator"; case .tool: "A connected tool"; case .file: "A project file"; case .folder: "A project folder" } }
    private func mentionGroup(_ mention: HootMention) -> String {
        if mention.kind == .agent { return mention.project.isEmpty ? "Independent" : mention.project }
        if !mention.group.isEmpty { return mention.group }
        return mention.kind == .session ? "Running" : mention.kind == .simulator ? "Available" : ""
    }
    private func setPermission(_ mode: HootPermissionMode) { draft.permissionMode = mode; onPermissionChange?(mode) }
    /// "Extra high", "Max" in a chat session's row; Hoot's short words otherwise.
    private func effortWord(_ effort: String) -> String {
        guard plainMeta else { return HootComposerModel.effortName(effort) }
        return effort == "xhigh" ? "Extra high" : HootComposerModel.effortName(effort)
    }
    private func insert(_ mention: HootMention, replaceQuery: Bool = false) {
        guard inputRule.acceptsFocus else { return }
        editor.insert(mention, draft: $draft, replaceQuery: replaceQuery); mentionQuery = nil
    }
    private func browse(images: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = images ? "Add photos" : "Add files"; panel.prompt = "Add"
        if let attachmentLimits {
            guard !attachmentLimits.extensions.isEmpty else { notice = attachmentLimits.note; return }
            panel.message = attachmentLimits.note
            panel.allowedContentTypes = attachmentLimits.extensions.filter { !images || $0 != "pdf" }.compactMap { UTType(filenameExtension: $0) }
            panel.allowsOtherFileTypes = false
        } else if images { panel.allowedContentTypes = ChatAttach.imageExtensions.compactMap { UTType(filenameExtension: $0) } }
        panel.begin { result in if result == .OK { addFiles(panel.urls) } }
    }
    private func addFiles(_ urls: [URL]) {
        guard inputRule.acceptsFocus else { return }
        guard let attachmentLimits else { draft.add(urls); return }
        var proposed = draft.attachments
        for url in urls where !proposed.contains(where: { $0.url == url }) { proposed.append(.init(url: url)) }
        do { try attachmentLimits.validateFiles(proposed.map(\.url)); draft.attachments = proposed; notice = nil }
        catch { notice = error.localizedDescription }
    }
    private func toggleVoice() {
        if voice.recording { Task { await finishVoice() }; return }
        guard hasMicrophone else { return }
        onDictationStart?()
        sendAfterVoice = NSEvent.modifierFlags.contains(.option)
        let dictation = HootDictationSplice()
        let epoch = inputRule.epoch
        Task { await voice.start { heard in
            guard inputRule.acceptsFocus, inputRule.epoch == epoch else { return }
            draft.text = dictation.write(heard, into: draft.text)
        } }
    }
    private func finishVoice() async {
        let epoch = inputRule.epoch
        await voice.stop()
        guard inputRule.acceptsFocus, inputRule.epoch == epoch else { sendAfterVoice = false; return }
        if sendAfterVoice { sendAfterVoice = false; sendDraft() }
    }
    /// The "/" menu while one slash word is typed and the AI offers commands that match it.
    private var slashShown: [HootSlashCommand]? {
        guard enabled, !catalogue.commands.isEmpty, let query = HootSlashCommand.query(draft.text), slashClosedOn != draft.text else { return nil }
        let found = HootSlashCommand.matches(catalogue.commands, query: query)
        return found.isEmpty ? nil : found
    }
    private func slashMenu(_ commands: [HootSlashCommand]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(commands.prefix(40).enumerated()), id: \.element.id) { index, command in
                    NativeSessionButton { pickSlash(command) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("/" + command.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            if !command.argumentHint.isEmpty {
                                Text(command.argumentHint).font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                            Text(command.opensInApp.map { "Opens " + $0 } ?? command.description)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(index == 0 ? AGKITStyle.selection : Color.clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("/" + command.name + (command.description.isEmpty ? "" : ", " + command.description))
                }
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { slashClosedOn = draft.text }
        .accessibilityLabel("Commands")
    }
    /// A command picked from the "/" menu: typed into the box ready for its arguments (Return sends it), or, when the
    /// app has its own control for it, that control opens and nothing is sent.
    private func pickSlash(_ command: HootSlashCommand) {
        if command.opensInApp != nil {
            draft.text = ""
            onAppCommand?(command)
            return
        }
        draft.text = "/" + command.name + " "
        slashClosedOn = nil
    }

    /// Return in the box: while an "@…" is typed (the list open, or about to appear) it picks the row the list would
    /// take, or closes the list when nobody matches; it never sends the half-typed text. The Send button still sends.
    private func returnPressed() {
        // A half-typed "/…" takes the menu's first command; a whole command name is sent as it is.
        if let shown = slashShown, let first = shown.first, let typed = HootSlashCommand.query(draft.text), typed != first.name {
            pickSlash(first); return
        }
        if let query = mentionQuery ?? openQueryAtCaret() {
            if let mention = DeckMentionPicker.firstPick(candidates: catalogue.mentions, query: query) { insert(mention, replaceQuery: true) }
            else { mentionQuery = nil }
            return
        }
        submit()
    }
    /// The "@…" before the caret, read from the box itself (covers the moment before the list's state has caught up).
    private func openQueryAtCaret() -> String? {
        guard let text = editor.textView else { return nil }
        let string = text.string as NSString, caret = min(text.selectedRange().location, string.length)
        return DeckMentionQuery.open(before: string.substring(to: caret), names: { DeckMentionRows.names(for: catalogue.mentions) })
    }
    private func submit() {
        if voice.recording { Task { await finishVoice() }; return }
        sendDraft()
    }
    private var primaryAction: ChatComposerControl {
        .action(turnRunning: busy, hasDraft: draft.canSend || voice.recording, allowsQueue: allowsSteering, stopping: stopping, canStop: canStop)
    }
    private var primaryDisabled: Bool {
        if !enabled || stopping { return true }
        if primaryAction == .stop { return !canStop }
        return (busy && !allowsSteering) || voice.starting || voice.finishing || (!draft.canSend && !voice.recording)
    }
    private var primaryControl: some View {
        NativeSessionButton { if primaryAction == .stop { onStop() } else { submit() } } label: {
            Group {
                if stopping { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: primaryAction == .stop ? "stop.fill" : "arrow.up").font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(.white).frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(primaryDisabled ? 0.4 : 1), in: .circle)
        }
        .buttonStyle(.plain).disabled(primaryDisabled)
        .help(primaryAction == .queue && canStop ? "Queue for after this answer. Right-click to stop the current answer." : primaryAction.label)
        .accessibilityLabel(primaryAction.label).accessibilityIdentifier("composer.primary")
        .contextMenu {
            if primaryAction == .queue && canStop {
                NativeSessionButton("Stop current answer", systemImage: "stop.fill", action: onStop).disabled(!enabled || !canStop)
            }
        }
    }
    private func sendDraft() {
        guard inputRule.acceptsFocus, draft.canSend, (!busy || allowsSteering), !voice.starting, !voice.finishing else { return }
        do { try attachmentLimits?.validateFiles(draft.attachments.map(\.url)); onSend(draft) }
        catch { notice = error.localizedDescription }
    }
}

/// What an owner's + panel can ask of the box.
struct HootComposerAddPanel {
    /// Closes the panel.
    let close: @MainActor () -> Void
    /// Closes the panel, then types "@" at the caret and opens the @ list there, as typing "@" does.
    let mention: @MainActor () -> Void
}

private struct HootComposerSurface: ViewModifier {
    var solid: Bool
    func body(content: Content) -> some View {
        if solid {
            content.background(AGKITStyle.card, in: .rect(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(AGKITStyle.hairline, lineWidth: 0.5))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }
}
private struct AGKITOffscreenSolidKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}
extension EnvironmentValues {
    /// Offscreen test targets exercise the same surface as Reduce Transparency.
    var agkitOffscreenSolid: Bool {
        get { self[AGKITOffscreenSolidKey.self] }
        set { self[AGKITOffscreenSolidKey.self] = newValue }
    }
}

@MainActor @Observable final class HootComposerEditorHandle {
    weak var textView: NSTextView?
    var height: CGFloat = 24
    /// A "Mention someone" button: types "@" at the caret THROUGH THE BOX, as the person would, so
    /// the box's own change notice runs and the @ list opens there (a space first when the "@"
    /// would otherwise stick to the word before it).
    func typeMentionSign() {
        guard let textView = textView as? NativeSessionTextView,
              textView.inputRule.acceptsFocus, let window = textView.window,
              window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        window.makeFirstResponder(textView)
        let text = textView.string as NSString
        var range = textView.selectedRange()
        range.location = min(range.location, text.length); range.length = min(range.length, text.length - range.location)
        let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let spaced = before.isEmpty || before.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
        textView.insertText((spaced ? "" : " ") + "@", replacementRange: range)
        textView.window?.makeFirstResponder(textView)
    }
    /// Puts a mention at the caret, or over the "@…" being typed (a pick from the @ list).
    /// The draft is written THROUGH ITS BINDING, never through an `inout` copy. 11 Oct (Asad, his
    /// real app: "@", click an agent, nothing is mentioned): the box's own change notice writes the
    /// new text into the draft while this runs; an `inout` copy taken before that was then written
    /// back over it with the OLD text, so the box was redrawn from "@…" and the mention was gone.
    func insert(_ mention: HootMention, draft: Binding<HootComposerDraft>, replaceQuery: Bool) {
        guard let textView = textView as? NativeSessionTextView, textView.inputRule.acceptsFocus,
              let window = textView.window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil, let storage = textView.textStorage else { return }
        window.makeFirstResponder(textView)
        var range = textView.selectedRange()
        range.location = min(range.location, storage.length); range.length = min(range.length, storage.length - range.location)
        if replaceQuery {
            let prefix = (storage.string as NSString).substring(to: range.location)
            if let at = prefix.range(of: "@", options: .backwards) { range = NSRange(location: (String(prefix[..<at.lowerBound]) as NSString).length, length: (String(prefix[at.lowerBound...]) as NSString).length) }
        }
        storage.replaceCharacters(in: range, with: HootComposerEditor.token(mention))
        textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
        // One write, from what the box now holds: the text with the mention's marker, and who is mentioned.
        var next = draft.wrappedValue
        if !next.mentions.contains(where: { $0.marker == mention.marker }) { next.mentions.append(mention) }
        next.text = HootComposerEditor.raw(textView)
        next.mentions = next.activeMentions
        draft.wrappedValue = next
        // The box's own notice still runs (its height, and the @ list's query), now on a draft that agrees with it.
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
        textView.window?.makeFirstResponder(textView)
    }
}
private final class HootMentionAttachment: NSTextAttachment {
    let mention: HootMention
    init(_ mention: HootMention) {
        self.mention = mention
        super.init(data: nil, ofType: nil)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let title = " \(mention.name) " as NSString
        let width = min(240, title.size(withAttributes: [.font: font]).width + 20)
        image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 0.5; shape.stroke()
            let symbol = NSImage(systemSymbolName: mention.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
            symbol?.draw(in: NSRect(x: 5, y: 5, width: 12, height: 12))
            title.draw(in: NSRect(x: 19, y: 3, width: width - 19, height: 18), withAttributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
            return true
        }
        bounds = NSRect(x: 0, y: -5, width: width, height: 22)
    }
    required init?(coder: NSCoder) { return nil }
}
private struct HootComposerEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    /// 30 Oct (Asad: his message pasted into Hoot was waiting in another chat's box): a chat that was switched away
    /// from stays mounted, transparent, so the switch back is instant. Its box must let go of the keyboard then, or
    /// typing and Paste land in a box nobody can see.
    @Environment(\.nativeScreenActive) private var onShow
    @Environment(\.nativeSessionInputScope) private var inputScope
    @Binding var draft: HootComposerDraft
    let ownerID: String?
    let focusWhenShown: Bool
    let selected: Bool
    let handle: HootComposerEditorHandle
    let onReturn: () -> Void
    let onFiles: ([URL]) -> Void
    let onMentionQuery: (String?) -> Void
    /// The names the @ list can show, asked for only when a space was typed after "@".
    var mentionNames: () -> [String] = { [] }
    var onRecall: ((Bool) -> Bool)? = nil
    static func token(_ mention: HootMention) -> NSAttributedString { NSAttributedString(attachment: HootMentionAttachment(mention)) }
    /// The box's text as the draft keeps it: each mention chip written as its marker.
    @MainActor static func raw(_ text: NSTextView) -> String {
        guard let storage = text.textStorage else { return text.string }
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let token = attrs[.attachment] as? HootMentionAttachment { result += token.mention.marker }
            else { result += (storage.string as NSString).substring(with: range) }
        }
        return result
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // never a legacy scroller track inside the rounded box
        let text = HootComposerTextView(); text.isRichText = false; text.isEditable = true; text.drawsBackground = false
        text.font = .systemFont(ofSize: 14); text.textColor = .labelColor; text.textContainerInset = .zero
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainer?.lineFragmentPadding = 0
        text.delegate = context.coordinator; text.onFiles = onFiles
        context.coordinator.text = text
        text.onWindowAttachment = { [weak coordinator = context.coordinator] in coordinator?.updateFocus() }
        text.onInputAvailabilityChanged = { [weak coordinator = context.coordinator] in coordinator?.updateFocus() }
        scroll.documentView = text; handle.textView = text
        text.setAccessibilityLabel("Message to Hoot")
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let ownerChanged = context.coordinator.parent.ownerID != ownerID
        guard let text = view.documentView as? HootComposerTextView else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if ownerChanged {
            // AppKit undo and marked text belong to the old owner too.
            text.undoManager?.removeAllActions()
            text.discardComposition()
        }
        context.coordinator.parent = self
        text.inputRule.bind(to: inputScope)
        text.updateInput(active: inputScope == nil ? onShow : true, enabled: isEnabled)
        text.onFiles = isEnabled ? onFiles : nil
        text.onShow = onShow
        let composingCurrentDraft = text.hasMarkedText() && !ownerChanged
            && context.coordinator.lastRenderedDraft == draft.text
        if !composingCurrentDraft && context.coordinator.raw(text) != draft.text {
            let attributed = NSMutableAttributedString(string: "")
            var remaining = draft.text[...]
            while !remaining.isEmpty {
                let next = draft.mentions.compactMap { mention -> (HootMention, Range<String.Index>)? in
                    guard let range = remaining.range(of: mention.marker) else { return nil }; return (mention, range)
                }.min { $0.1.lowerBound < $1.1.lowerBound }
                guard let (mention, range) = next else { attributed.append(NSAttributedString(string: String(remaining))); break }
                attributed.append(NSAttributedString(string: String(remaining[..<range.lowerBound]))); attributed.append(Self.token(mention))
                remaining = remaining[range.upperBound...]
            }
            attributed.addAttributes([.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: attributed.length))
            let caret = min(text.selectedRange().location, attributed.length)
            text.discardComposition()
            text.inputRule.withExplicitUpdate {
                text.textStorage?.setAttributedString(attributed)
                text.setSelectedRange(NSRange(location: caret, length: 0))
            }
        }
        context.coordinator.lastRenderedDraft = draft.text
        context.coordinator.resize(text)
        context.coordinator.updateFocus()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HootComposerEditor
        var updating = false
        var lastRenderedDraft: String?
        weak var text: HootComposerTextView?
        private var wasAvailable = false
        private var pendingFocus = false
        private var focusTask: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []

        init(_ parent: HootComposerEditor) {
            self.parent = parent
            super.init()
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification,
                         NSApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let notifiedWindow = (note.object as? NSWindow).map(ObjectIdentifier.init)
                    let notificationName = note.name
                    MainActor.assumeIsolated {
                        guard let self, let text = self.text, let window = text.window,
                              notifiedWindow == ObjectIdentifier(window) || notificationName == NSApplication.didBecomeActiveNotification else { return }
                        if self.parent.focusWhenShown && self.parent.selected && text.inputRule.acceptsFocus {
                            self.pendingFocus = true
                            self.restoreFocus()
                        }
                    }
                })
            }
        }

        isolated deinit {
            focusTask?.cancel()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func updateFocus() {
            guard let text else { return }
            let available = parent.focusWhenShown && parent.selected && text.inputRule.acceptsFocus
            if !available {
                let previouslyAvailable = wasAvailable
                wasAvailable = false
                pendingFocus = false
                focusTask?.cancel()
                if previouslyAvailable, text.window?.firstResponder === text {
                    let window = text.window
                    window?.makeFirstResponder(nil)
                    if let window { DeckTerminalSlot.restoreFocus(in: window, request: false) }
                }
                return
            }
            if !wasAvailable { pendingFocus = true }
            wasAvailable = true
            restoreFocus()
            guard pendingFocus else { return }
            focusTask?.cancel()
            let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restoreFocus() } }
            focusTask = task
            DispatchQueue.main.async(execute: task)
        }

        private func restoreFocus() {
            guard pendingFocus, parent.focusWhenShown, parent.selected, let text,
                  text.inputRule.acceptsFocus, let window = text.window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            if window.firstResponder === text { pendingFocus = false; return }
            if let current = window.firstResponder as? NSView {
                let hidden = nativeSessionInputRule(for: current).map { !$0.acceptsFocus } ?? false
                if current.window !== window || current.isHiddenOrHasHiddenAncestor || hidden {
                    window.makeFirstResponder(nil)
                } else if NativeKeyboardFocus.isTyping(current) { return }
            }
            if window.makeFirstResponder(text) { pendingFocus = false }
        }
        func raw(_ text: NSTextView) -> String { HootComposerEditor.raw(text) }
        func textDidChange(_ notification: Notification) {
            guard !updating, let text = notification.object as? NativeSessionTextView,
                  text.allowsUserInput, !text.hasMarkedText(), text === parent.handle.textView else { return }
            parent.draft.text = raw(text); parent.draft.mentions = parent.draft.activeMentions
            let prefix = (text.string as NSString).substring(to: min(text.selectedRange().location, (text.string as NSString).length))
            // FORK-L1: the picker says what still counts as asking for the @ list (a name can have spaces).
            parent.onMentionQuery(DeckMentionQuery.open(before: prefix, names: parent.mentionNames))
            resize(text)
        }
        func resize(_ text: NSTextView) {
            guard let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            let eightLines = layout.defaultLineHeight(for: text.font ?? .systemFont(ofSize: 14)) * 8 + 4
            let wanted = min(eightLines, max(24, layout.usedRect(for: container).height + 4))
            if parent.handle.height != wanted { Task { @MainActor in parent.handle.height = wanted } }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let guarded = textView as? NativeSessionTextView, guarded.allowsUserInput else { return true }
            let previous = selector == #selector(NSResponder.moveUp(_:))
            let next = selector == #selector(NSResponder.moveDown(_:))
            let modifiers = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
            let caret = textView.selectedRange(), end = (textView.string as NSString).length
            if (previous || next), !textView.hasMarkedText(), modifiers.isEmpty, caret.length == 0, caret.location == end,
               parent.onRecall?(previous) == true {
                textView.string = parent.draft.text
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                parent.onMentionQuery(nil)
                resize(textView)
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(), !NSEvent.modifierFlags.contains(.shift) else { return false }
            parent.onReturn(); return true
        }
    }
}
final class HootComposerTextView: NativeSessionTextView {
    var onFiles: (([URL]) -> Void)?
    /// False while its chat is hidden: it takes no keyboard focus and no typed or pasted text (see `onShow` above).
    var onShow = true {
        didSet { updateInput(active: inputRule.hasScope ? true : onShow, enabled: inputRule.enabled) }
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)), allowsUserInput,
           NSPasteboard.general.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) { return true }
        return super.validateMenuItem(menuItem)
    }
    override func paste(_ sender: Any?) {
        guard allowsUserInput else { return }
        guard let onFiles else { super.paste(sender); return }
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { onFiles(urls); return }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            do { onFiles([try HootPastedFiles.make(data, type: board.data(forType: .png) != nil ? "png" : "tiff")]) } catch { NSSound.beep() }
            return
        }
        if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation {
            do { onFiles([try HootPastedFiles.make(data, type: "tiff")]) } catch { NSSound.beep() }
            return
        }
        super.paste(sender)
    }
}

/// U144 (#535): a picture pasted into the box is a file in the temporary folder made only for the box. It goes when
/// its × removes it or its message is sent; one left by a send that never finished goes after a week.
enum HootPastedFiles {
    static let prefix = "AGKIT-pasted-"
    static let keptSeconds = 7.0 * 24 * 3_600
    static func make(_ data: Data, type: String, in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date()) throws -> URL {
        sweep(in: folder, now: now)
        let url = folder.appendingPathComponent(prefix + UUID().uuidString + "." + type)
        try data.write(to: url); return url
    }
    static func isPasted(_ url: URL, in folder: URL = FileManager.default.temporaryDirectory) -> Bool {
        url.lastPathComponent.hasPrefix(prefix) && url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }
    static func discard(_ urls: [URL], in folder: URL = FileManager.default.temporaryDirectory) {
        for url in urls where isPasted(url, in: folder) { try? FileManager.default.removeItem(at: url) }
    }
    static func sweep(in folder: URL, now: Date) {
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            guard let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(changed) > keptSeconds else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension HootEffortSlider {
    /// Small round dots every 6 pt (the mask for the glowing track).
    static var dots: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(ellipseIn: CGRect(x: x, y: size.height / 2 - 1.75, width: 3.5, height: 3.5)), with: .color(.white))
                x += 6
            }
        }
    }
    /// Content painted with a purple, blue and pink gradient that drifts slowly
    /// (static when Reduce Motion is on).
    /// Sized by the content itself (the gradient never takes extra room).
    func shimmer<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        content().hidden().overlay {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? 0 : CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3)
                LinearGradient(colors: Self.aiColours, startPoint: UnitPoint(x: -1 + phase * 2, y: 0.5),
                               endPoint: UnitPoint(x: 1 + phase * 2, y: 0.5))
            }
            .mask(content())
        }
    }
}

/// The message box alone, the permission/model row alone, or both stacked.
enum HootComposerPart: Sendable { case whole, box, meta }

/// Claude-style effort picker: "Effort  High", a Faster-to-Smarter track with one tick per level,
/// a round knob on the current level and "Recommended" under the recommended tick.
struct HootEffortSlider: View {
    var levels: [String]
    var recommended: String?
    var selected: String
    var onChange: (String) -> Void
    @State private var showInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let info = "Higher effort thinks longer and costs more tokens. Ultracode runs a deeper multi-step mode for hard coding jobs. Recommended is the best balance for this model."
    /// The smartest end (Max, Ultracode) glows in mixed AI colours.
    private var smart: Bool { ["max", "ultracode", "ultra"].contains(selected) }
    private static let aiColours: [Color] = [.purple, .blue, .pink, .purple]
    private let inset: CGFloat = 10
    private func x(_ index: Int, _ width: CGFloat) -> CGFloat {
        guard levels.count > 1 else { return width / 2 }
        return inset + (width - inset * 2) * CGFloat(index) / CGFloat(levels.count - 1)
    }
    private func pick(_ location: CGFloat, _ width: CGFloat) {
        guard !levels.isEmpty else { return }
        let index = levels.indices.min { abs(x($0, width) - location) < abs(x($1, width) - location) } ?? 0
        if levels[index] != selected { onChange(levels[index]) }
    }
    var body: some View {
        let current = levels.firstIndex(of: selected) ?? 0
        let recommendedIndex = recommended.flatMap { levels.firstIndex(of: $0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Effort").foregroundStyle(.primary)
                if smart {
                    shimmer { Text(HootComposerModel.effortName(selected)) }
                } else {
                    Text(HootComposerModel.effortName(selected)).foregroundStyle(Color.accentColor)
                }
                Spacer()
                NativeSessionButton { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(Self.info).accessibilityLabel("About effort")
            }.font(.system(size: 13, weight: .semibold))
            if showInfo {
                Text(Self.info).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("Faster").foregroundStyle(.secondary)
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .topLeading) {
                        Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4).offset(y: 10)
                        if smart {
                            // A dotted track glowing in moving AI colours toward the smart end.
                            shimmer { Color.white }
                                .mask(Self.dots).frame(width: max(0, x(current, width)), height: 8).offset(y: 8)
                        } else {
                            Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(0, x(current, width)), height: 4).offset(y: 10)
                        }
                        ForEach(levels.indices, id: \.self) { index in
                            Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 2, height: 8).offset(x: x(index, width) - 1, y: 8)
                        }
                        Circle().fill(Color.white).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                            .frame(width: 16, height: 16).offset(x: x(current, width) - 8, y: 4)
                            .animation(.snappy(duration: 0.15), value: current)
                        if let recommendedIndex {
                            Text("Recommended").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                                .frame(width: 90).offset(x: x(recommendedIndex, width) - 45, y: 24)
                        }
                    }
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { pick($0.location.x, width) })
                }.frame(height: 40)
                Text("Smarter").foregroundStyle(.secondary)
            }.font(.system(size: 11))
        }
        .padding(14).frame(width: 320)
        .animation(.snappy(duration: 0.15), value: showInfo)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort").accessibilityValue(HootComposerModel.effortName(selected))
        .accessibilityAdjustableAction { direction in
            let index = levels.firstIndex(of: selected) ?? 0
            let next = direction == .increment ? min(levels.count - 1, index + 1) : max(0, index - 1)
            if levels.indices.contains(next), levels[next] != selected { onChange(levels[next]) }
        }
    }
}

/// Decode only a small image, off the UI thread, rather than loading a full camera photo in the composer.
private struct HootAttachmentThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: ChatAttach.imageExtensions.contains(url.pathExtension.lowercased()) ? "photo" : "doc")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40).clipped().clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel("Preview of \(url.lastPathComponent)")
        .task(id: url) {
            let sourceURL = url
            let bytes = await Task.detached(priority: .utility) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 120
                      ] as CFDictionary) else { return nil }
                let bitmap = NSBitmapImageRep(cgImage: image)
                return bitmap.representation(using: .png, properties: [:])
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = bytes.flatMap(NSImage.init(data:))
        }
    }
}
