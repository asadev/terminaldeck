import SwiftUI
import TerminalDeckNativeCore

/// The chat's icon strip where the 29-entry ⋯ menu was (Asad, 20 Oct 2026, after Claude Code's side panel: "only important
/// ones"): ⓘ Session, ⌨ Command output, ± Changes and ⋯ More, the same strip on Hoot's page, in the island and in every chat session.
enum NativeChatStripIcon: String, CaseIterable, Identifiable {
    case session, commandOutput, changes, more
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "Session"
        case .commandOutput: "Command output"
        case .changes: "Changes"
        case .more: "More"
        }
    }
    var symbol: String {
        switch self {
        case .session: "info.circle"
        case .commandOutput: "terminal"
        case .changes: "plus.forwardslash.minus"
        case .more: "ellipsis"
        }
    }
    var help: String {
        switch self {
        case .session: "Session: environment, context used and connections"
        case .commandOutput: "Command output from this chat's terminals"
        case .changes: "Changes: file changes and review"
        case .more: "More: past chats, export, pin or archive, problems"
        }
    }
    /// Opens through the same flag its chat feature tool uses; ⋯ More is a menu, not a panel.
    @MainActor func open(in model: NativeHootChatModel) {
        switch self {
        case .session: model.chatContextVisible = true
        case .commandOutput: model.chatFeaturePanels.insert("terminal-context")
        case .changes: model.chatFeaturePanels.insert("diffs")
        case .more: break
        }
    }
    @MainActor func shown(in model: NativeHootChatModel) -> Bool {
        switch self {
        case .session: model.chatSessionShown
        case .commandOutput: model.chatFeaturePanels.contains("terminal-context")
        case .changes: model.chatChangesShown
        case .more: model.chatProblemsShown
        }
    }
}

/// ⋯ More's short menu.
enum NativeChatMenuEntry: String, CaseIterable, Identifiable {
    case pastChats, export, organize, problems
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pastChats: "Past chats"
        case .export: "Export chat"
        case .organize: "Pin or archive"
        case .problems: "Problems"
        }
    }
    var symbol: String {
        switch self {
        case .pastChats: "clock.arrow.circlepath"
        case .export: "square.and.arrow.up"
        case .organize: "tray"
        case .problems: "exclamationmark.bubble"
        }
    }
    /// Panels whose open state lives in the menu, not the chat model (they have no tool-driven flag).
    var menuOwned: Bool { self == .pastChats || self == .export }
    /// Opens through the same flag its tool uses; menu-owned panels and the Pin or archive submenu have none.
    @MainActor func open(in model: NativeHootChatModel) {
        if self == .problems { model.chatDiagnosticsVisible = true }
    }
}

extension NativeHootChatModel {
    /// ⓘ Session shows for its own icon (the context tool's flag) and for every tool whose panel is now one of its lists.
    var chatSessionShown: Bool {
        chatContextVisible || chatSourcesVisible || chatArtifactsVisible || chatEditorContextVisible || chatConnectionsVisible || chatSkillsVisible
            || chatFeaturePanels.contains("mentions") || chatFeaturePanels.contains("mcp")
    }
    func closeChatSession() {
        chatContextVisible = false; chatSourcesVisible = false; chatArtifactsVisible = false; chatEditorContextVisible = false
        chatConnectionsVisible = false; chatSkillsVisible = false; chatFeaturePanels.subtract(["mentions", "mcp"])
    }
    /// ± Changes: the diffs tool's flag or the review tool's.
    var chatChangesShown: Bool { chatFeaturePanels.contains("diffs") || chatReviewVisible }
    func closeChatChanges() { chatFeaturePanels.remove("diffs"); chatReviewVisible = false }
    /// ⋯ More › Problems: warnings and errors, or the event log with its hook notices.
    var chatProblemsShown: Bool { chatDiagnosticsVisible || chatDetailsVisible || chatFeaturePanels.contains("hooks") }
    func closeChatProblems() { chatDiagnosticsVisible = false; chatDetailsVisible = false; chatFeaturePanels.remove("hooks") }
}

/// The strip. Each panel pops out of its own icon; panels left without an entry still open from ⋯ through their tools.
struct NativeChatMenu: View {
    @Bindable var model: NativeHootChatModel
    @State private var shown: NativeChatMenuEntry?
    /// Feature panels with no entry since 20 Oct 2026 that their chat feature tools still open.
    static let toolOnlyFeatures = [("agents", "Child agents"), ("model-timing", "Model switch"), ("notifications", "Notifications"), ("policy", "Permission policy")]
    var body: some View {
        // Chat keeps its tool-driven panels, without visible toolbar buttons or a reserved row.
        Color.clear.frame(width: 0, height: 0)
            .popover(isPresented: Binding(get: { model.chatSessionShown }, set: { if !$0 { model.closeChatSession() } })) { NativeChatSessionPanel(model: model) }
            .background { NativeChatFeaturePopover(model: model, feature: "terminal-context", title: NativeChatStripIcon.commandOutput.title) }
            .background {
                Color.clear.popover(isPresented: Binding(get: { model.chatChangesShown }, set: { if !$0 { model.closeChatChanges() } })) { NativeChatChangesPanel(model: model) }
            }
            .background { panels }
    }
    private func icon(_ icon: NativeChatStripIcon) -> some View {
        Button { icon.open(in: model) } label: { NativeChatStripGlyph(symbol: icon.symbol, active: icon.shown(in: model)) }
            .buttonStyle(.plain)
            .help(icon.help)
            .accessibilityLabel(icon.title)
    }
    private var more: some View {
        Menu {
            ForEach(NativeChatMenuEntry.allCases) { entry in item(entry) }
        } label: {
            NativeChatStripGlyph(symbol: NativeChatStripIcon.more.symbol, active: shown != nil || NativeChatStripIcon.more.shown(in: model))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(NativeChatStripIcon.more.help)
        .accessibilityLabel(NativeChatStripIcon.more.title)
        .background { panels }
    }
    @ViewBuilder private func item(_ entry: NativeChatMenuEntry) -> some View {
        if entry == .organize { NativeChatOrganizationMenu(model: model) }
        else {
            Button {
                if entry.menuOwned { shown = entry } else { entry.open(in: model) }
            } label: { Label(entry.title, systemImage: entry.symbol) }
        }
    }
    private func showing(_ entry: NativeChatMenuEntry) -> Binding<Bool> {
        Binding(get: { shown == entry }, set: { if !$0, shown == entry { shown = nil } })
    }
    /// ⋯ More's panels, and the ones whose entries left the menu, hang off ⋯ so a tool still opens each as it did.
    private var panels: some View {
        ZStack {
            Color.clear.popover(isPresented: showing(.pastChats)) { NativeChatLibraryView(sessionID: model.source.sessionID, prompts: model) }
            Color.clear.popover(isPresented: showing(.export)) { NativeChatExportView(model: model) }
            Color.clear.popover(isPresented: Binding(get: { model.chatProblemsShown }, set: { if !$0 { model.closeChatProblems() } })) { NativeChatProblemsPanel(model: model) }
            NativeChatSideQuestionPopover(model: model)
            NativeChatLongDraftPopover(model: model)
            NativeChatRoutinesPopover(model: model)
            NativeChatVoicePopover(model: model)
            NativeChatShortcutsPopover(model: model)
            NativeChatGoalsPopover(model: model)
            NativeChatControlsPopover(model: model)
            NativeChatAccountPopover(model: model)
            NativeChatCommandsPopover(model: model)
            NativeChatMemorySheet(model: model)
            ForEach(Self.toolOnlyFeatures, id: \.0) { item in
                NativeChatFeaturePopover(model: model, feature: item.0, title: item.1)
            }
        }
    }
}

/// One strip icon: a grey rail chip, blue while its panel is open.
struct NativeChatStripGlyph: View {
    let symbol: String
    var active = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            .frame(width: 26, height: 26)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .background(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// ± Changes: the file changes and the review of them, one tab each.
struct NativeChatChangesPanel: View {
    @Bindable var model: NativeHootChatModel
    var body: some View {
        NativeChatTabbedPanel([("files", "File changes"), ("review", "Review changes")],
                              first: model.chatReviewVisible && !model.chatFeaturePanels.contains("diffs") ? "review" : "files") { tab in
            if tab == "review" { NativeChatReviewPanel(model: model) }
            else { NativeChatFeaturePanelView(model: model, feature: "diffs", title: "File changes").padding(16).frame(width: 570) }
        }
    }
}

/// ⋯ More › Problems: warnings and errors, and the event log with the hook notices inside it.
struct NativeChatProblemsPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var hooksOpen = false
    var body: some View {
        NativeChatTabbedPanel([("problems", "Warnings & errors"), ("events", "Event log")],
                              first: model.chatDiagnosticsVisible ? "problems" : "events") { tab in
            if tab == "events" {
                VStack(alignment: .leading, spacing: 0) {
                    NativeChatDetailView(model: model)
                    DisclosureGroup("Hook notices", isExpanded: $hooksOpen) {
                        NativeChatFeaturePanelView(model: model, feature: "hooks", title: "Hook notices").padding(.top, 8)
                    }.padding([.horizontal, .bottom], 16).frame(width: 620)
                }
            } else { NativeChatDiagnosticsPanel(model: model) }
        }
        .onAppear { if model.chatFeaturePanels.contains("hooks") { hooksOpen = true } }
        .onChange(of: model.chatFeaturePanels.contains("hooks")) { _, asked in if asked { hooksOpen = true } }
    }
}

/// Panels that did one job share one popover, one tab per former panel.
struct NativeChatTabbedPanel<Content: View>: View {
    let tabs: [(String, String)]
    @State private var tab: String
    private let content: (String) -> Content
    init(_ tabs: [(String, String)], first: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.tabs = tabs; _tab = State(initialValue: first); self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tabs.count > 1 {
                Picker("Panel", selection: $tab) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { _, item in Text(item.1).tag(item.0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().padding([.horizontal, .top], 16)
            }
            content(tabs.contains { $0.0 == tab } ? tab : tabs.first?.0 ?? tab)
        }
    }
}
