import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// WhatsApp agents, the screens (Asad, 15 Nov 2026; notes/review-20261115/DESIGN-WHATSAPP.md second version, sections 2
// and 3). Settings > AI apps gets a last group "WhatsApp" (one row per WhatsApp agent, built like the accounts list on
// Coding AIs); a session, an agent's page and Hoot get a "WhatsApp" submenu in their existing menus and ONE heading chip,
// shown only while a WhatsApp agent is attached there. Session rows get nothing. Everything reads and calls the one
// store, `NativeWhatsAppAgents` (the engine's); nothing here touches a key except to hand it to the store once.

/// The WhatsApp glyph. We ship nobody's logo: the plain outline "phone in a bubble", secondary colour, 13 pt; never green.
enum WhatsAppGlyph {
    static let symbol = "phone.bubble"
    static let size: CGFloat = 13
}

/// Every word the WhatsApp screens show.
enum WhatsAppWords {
    static let groupTitle = "WhatsApp"
    static let submenuTitle = "WhatsApp"
    /// The group's info popover: the whole manual way, then one secondary line.
    static let steps = """
    1. In WhatsApp open Settings > Agents and create an agent.
    2. Open its chat, then Chat info > API key, and copy the key.
    3. Add it here.
    """
    static let notEncrypted = "WhatsApp does not encrypt these chats end to end."
    static let addRow = "+ Add WhatsApp agent"
    static let keyPrompt = "Paste the key from WhatsApp"
    static let add = "Add"
    static let off = "Off"
    /// The switch (his word 4): on = answers go to WhatsApp; off = the agent stays attached and nothing is sent.
    static let send = "Send to WhatsApp"
    static let paused = "Paused"
    static let pause = "Pause"
    static let resume = "Resume"
    static let sessions = "Sessions"
    /// The submenu when he has no WhatsApp agent yet: one item that opens Settings > AI apps.
    static let addFromMenu = "Add a WhatsApp agent…"
    static let settingsSection = "ai-apps"
}

// MARK: - Where a WhatsApp agent can be received (the row's pop-up)

/// The pop-up's lists: Hoot · his agents by name under their project · "Sessions" with the open sessions · Nowhere.
struct WhatsAppReceiverChoices: Equatable {
    struct Choice: Equatable, Identifiable { let id: String; let name: String }
    struct Project: Equatable, Identifiable { let id: String; let name: String; let agents: [Choice] }
    var projects: [Project] = []
    var sessions: [Choice] = []

    /// The lists the app already has: saved agents (not archived) from the Agents store, sessions on this Mac from the
    /// side panel, each by the name the side panel shows.
    @MainActor static func live() -> WhatsAppReceiverChoices {
        let agents = AGTAgentsStore.shared.agents.filter { $0.kind == .profile && $0.profileID != nil && $0.status != "archived" }
        var order: [String] = []
        var byProject: [String: [Choice]] = [:]
        for agent in agents {
            let project = AGTLeads.projectName(agent)
            if byProject[project] == nil { order.append(project) }
            byProject[project, default: []].append(Choice(id: agent.profileID ?? agent.id, name: agent.name))
        }
        let projects = order.map { Project(id: $0, name: $0.isEmpty ? "Independent" : $0, agents: byProject[$0] ?? []) }
        var seen = Set<String>()
        var sessions: [Choice] = []
        for project in AppModel.shared.sidebar?.projects ?? [] {
            for item in project.sessions where !item.isHoot {
                guard case .local(let id)? = SessionTarget(tabId: item.id), seen.insert(id).inserted else { continue }
                sessions.append(Choice(id: id, name: SIDEBARSessionLine.title(item, store: SIDEBARProjectStore.shared)))
            }
        }
        return WhatsAppReceiverChoices(projects: projects, sessions: sessions)
    }

    /// The pop-up's tag for a receiver (agents and sessions by id, so a renamed one stays chosen).
    static func tag(_ receiver: WhatsAppReceiver) -> String {
        switch receiver {
        case .nowhere: return "nowhere"
        case .hoot: return "hoot"
        case .agent(let id, _): return "agent:" + id
        case .session(let id, _): return "session:" + id
        }
    }

    /// The receiver a chosen tag stands for, with the name the list shows now (`current` keeps one no longer listed).
    func receiver(for tag: String, current: WhatsAppReceiver) -> WhatsAppReceiver {
        if tag == Self.tag(current) { return current }
        if tag == "hoot" { return .hoot }
        if tag.hasPrefix("agent:") {
            let id = String(tag.dropFirst(6))
            let name = projects.flatMap(\.agents).first { $0.id == id }?.name ?? ""
            return .agent(id: id, name: name)
        }
        if tag.hasPrefix("session:") {
            let id = String(tag.dropFirst(8))
            return .session(id: id, name: sessions.first { $0.id == id }?.name ?? "")
        }
        return .nowhere
    }

    /// True when the current receiver is an agent or session the lists no longer hold (it is still shown, by its name).
    func lacks(_ receiver: WhatsAppReceiver) -> Bool {
        switch receiver {
        case .nowhere, .hoot: return false
        case .agent(let id, _): return !projects.flatMap(\.agents).contains { $0.id == id }
        case .session(let id, _): return !sessions.contains { $0.id == id }
        }
    }
}

// MARK: - Settings > AI apps: the "WhatsApp" group

/// The last group of Settings > AI apps: title with ONE info button, one row per WhatsApp agent, "+ Add WhatsApp agent"
/// last, ALWAYS (his word 4: no limit on our side; agents of several WhatsApp accounts can be added). Built from the Settings kit and the Coding AIs account row's parts.
struct NativeWhatsAppSettingsGroup: View {
    var store: NativeWhatsAppAgents = .shared
    /// Picture tests pass fixed lists; the page reads the live ones.
    var choices: WhatsAppReceiverChoices? = nil
    /// Picture tests open the add row's fields.
    var startsAdding = false

    var body: some View {
        let lists = choices ?? WhatsAppReceiverChoices.live()
        VStack(alignment: .leading, spacing: DeckSettingsLook.groupTitleGap) {
            NativeWhatsAppGroupTitle()
            DeckSettingsGroup {
                ForEach(store.agents) { agent in
                    NativeWhatsAppAgentRow(agent: agent, store: store, choices: lists)
                }
                NativeWhatsAppAddRow(store: store, startsOpen: startsAdding)
            }
        }
    }
}

/// "WhatsApp" and its info button; the popover is the three steps and one secondary line.
struct NativeWhatsAppGroupTitle: View {
    @State private var shown = false
    var body: some View {
        HStack(spacing: DeckSettingsLook.infoGap) {
            Text(WhatsAppWords.groupTitle).font(DeckSettingsLook.groupTitle).foregroundStyle(.primary)
            Button { shown.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: DeckSettingsLook.infoGlyph)).foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(WhatsAppWords.groupTitle)")
            .popover(isPresented: $shown, arrowEdge: .bottom) { NativeWhatsAppInfoContent() }
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What the info popover shows (also drawn by the pictures, which cannot open a popover).
struct NativeWhatsAppInfoContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
            NativeWhatsAppAddGuide()
                .frame(width: DeckSettingsLook.popoverWidth, height: DeckSettingsLook.popoverWidth * 840 / 600)
                .clipShape(RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
                .accessibilityLabel("Animated WhatsApp guide: Settings > Agents, Add an agent, name it and Add, View API key, then Copy key and paste it here.")
            Text(WhatsAppWords.steps).font(DeckSettingsLook.rowTitle)
            Text(WhatsAppWords.notEncrypted).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: DeckSettingsLook.popoverWidth, alignment: .leading)
        .padding(14)
    }
}

/// SwiftUI Image shows only a GIF's first frame; AppKit owns playback while the popover is open.
private struct NativeWhatsAppAddGuide: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        if let url = Bundle.module.url(forResource: "whatsapp-add-agent", withExtension: "gif"),
           let image = NSImage(contentsOf: url) {
            // A GIF has pixel dimensions but no Retina scale: give AppKit the popover's logical size.
            image.size = NSSize(width: DeckSettingsLook.popoverWidth, height: DeckSettingsLook.popoverWidth * 840 / 600)
            view.image = image
        }
        view.animates = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}

    static func dismantleNSView(_ view: NSImageView, coordinator: ()) {
        view.animates = false
    }
}

/// The 7 pt dot: green connected, orange the key was refused, none while waiting for his first message.
struct NativeWhatsAppStateDot: View {
    let state: WhatsAppAgentState
    var body: some View {
        Group {
            switch state {
            case .connected: Circle().fill(Color.green)
            case .refused: Circle().fill(DeckTokens.warn)
            case .waiting: Color.clear
            }
        }
        .frame(width: DeckSettingsLook.stateDot, height: DeckSettingsLook.stateDot)
        .frame(width: DeckSettingsLook.rowTile, height: DeckSettingsLook.rowTile)
        .accessibilityHidden(state == .waiting)
        .accessibilityLabel(state == .connected ? "Connected" : "The key was refused")
    }
}

/// A field drawn the kit's quiet way (fill one step darker than the group, radius 6, no outline), text from the left.
private struct WhatsAppQuietField: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .frame(width: width, height: 22)
            .background(DeckSettingsQuietField.fill, in: RoundedRectangle(cornerRadius: DeckSettingsQuietField.radius))
    }
}

/// One WhatsApp agent: dot, its name, at the right where it is received (a pop-up) or the orange refusal, then "…".
/// Rename and Replace key turn the row into its one field in place.
struct NativeWhatsAppAgentRow: View {
    let agent: WhatsAppAgentProfile
    let store: NativeWhatsAppAgents
    let choices: WhatsAppReceiverChoices
    private enum Editing { case name, key }
    @State private var editing: Editing?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch editing {
            case .name: nameForm
            case .key: keyForm
            case nil: line
            }
            if editing != nil, let problem = store.problem { DeckSettingsProblem(text: problem) }
        }
    }

    private var line: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            DeckSettingsRowLabel(title: agent.name, leading: AnyView(NativeWhatsAppStateDot(state: agent.state)))
            Spacer(minLength: DeckTokens.Spacing.s8)
            if agent.state == .refused, let words = agent.state.words {
                Text(words).font(DeckSettingsLook.rowTitle).foregroundStyle(DeckTokens.warn).lineLimit(1)
            } else {
                // A paused row says "Paused" before its pop-up (section 2); otherwise waiting, or who answers.
                if let words = agent.sending ? (agent.state.words ?? agent.answeredElsewhereWords) : WhatsAppWords.paused {
                    Text(words).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                receiverPopUp
            }
            NativeSettingsMoreMenu(label: agent.name) {
                Button(agent.sending ? WhatsAppWords.pause : WhatsAppWords.resume) {
                    let on = !agent.sending, id = agent.id
                    Task { _ = await store.setSending(on, for: id) }
                }
                Button("Rename") { begin(.name) }
                Button("Replace key") { begin(.key) }
                Divider()
                Button("Remove", role: .destructive) { Task { await store.remove(agent.id) } }
            }
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Where it is received. Choosing moves it there at once; no question.
    private var receiverPopUp: some View {
        let current = WhatsAppReceiverChoices.tag(agent.receiver)
        return Picker("Where \(agent.name) is received", selection: Binding(get: { current }, set: { tag in
            let next = choices.receiver(for: tag, current: agent.receiver)
            guard !next.sameTarget(agent.receiver) else { return }
            Task { await store.setReceiver(agent.id, next) }
        })) {
            Text("Hoot").tag("hoot")
            ForEach(choices.projects) { project in
                Section(project.name) {
                    ForEach(project.agents) { Text($0.name).tag("agent:" + $0.id) }
                }
            }
            if !choices.sessions.isEmpty {
                Section(WhatsAppWords.sessions) {
                    ForEach(choices.sessions) { Text($0.name).tag("session:" + $0.id) }
                }
            }
            // A receiver no longer listed (an agent removed, a session elsewhere) still shows by its name.
            if choices.lacks(agent.receiver) { Text(agent.receiver.title).tag(current) }
            Divider()
            Text(WhatsAppReceiver.nowhere.title).tag("nowhere")
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private var nameForm: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            NativeSessionTextField("Name", text: $text, onSubmit: saveName)
                .onExitCommand(cancel)
                .sessionFocused($focused)
                .modifier(WhatsAppQuietField(width: 200))
                .accessibilityLabel("New name for \(agent.name)")
                .onChange(of: text) { _, value in
                    if value.count > WhatsAppAgentsLimits.maximumNameLength { text = String(value.prefix(WhatsAppAgentsLimits.maximumNameLength)) }
                }
            Spacer(minLength: 0)
            Button("Save", action: saveName).controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", action: cancel).controlSize(.small)
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
        .onAppear { focused = true }
    }

    private var keyForm: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            DeckSettingsRowLabel(title: agent.name, leading: AnyView(NativeWhatsAppStateDot(state: agent.state)))
            Spacer(minLength: DeckTokens.Spacing.s8)
            NativeSessionSecureField(WhatsAppWords.keyPrompt, text: $text, onSubmit: saveKey)
                .sessionFocused($focused)
                .modifier(WhatsAppQuietField(width: 200))
                .accessibilityLabel("New key for \(agent.name)")
            Button("Save", action: saveKey).controlSize(.small)
                .disabled(store.checking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", action: cancel).controlSize(.small)
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
        .onAppear { focused = true }
    }

    private func begin(_ what: Editing) {
        store.problem = nil
        text = what == .name ? agent.name : ""
        editing = what
    }
    private func cancel() { editing = nil; text = ""; store.problem = nil }
    private func saveName() {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        guard typed != agent.name else { cancel(); return }
        Task { if await store.rename(agent.id, to: typed) { editing = nil; text = "" } }
    }
    private func saveKey() {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !store.checking else { return }
        // A refused key keeps the field and says so in one orange line.
        Task { if await store.replaceKey(agent.id, key: key) { editing = nil; text = "" } }
    }
}

/// The last row: "+ Add WhatsApp agent", which turns into a name field (prefilled), a secure key field and a small "Add".
/// Return also adds; Escape closes it. A refused key says so in one orange line and keeps the fields.
struct NativeWhatsAppAddRow: View {
    let store: NativeWhatsAppAgents
    var startsOpen = false
    @State private var open = false
    @State private var name = ""
    @State private var key = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if open {
                HStack(spacing: DeckTokens.Spacing.s8) {
                    NativeSessionTextField("Name", text: $name, onSubmit: add)
                        .onExitCommand(close)
                        .modifier(WhatsAppQuietField(width: 160))
                        .accessibilityLabel("Name of the WhatsApp agent")
                        .onChange(of: name) { _, value in
                            if value.count > WhatsAppAgentsLimits.maximumNameLength { name = String(value.prefix(WhatsAppAgentsLimits.maximumNameLength)) }
                        }
                    NativeSessionSecureField(WhatsAppWords.keyPrompt, text: $key, onSubmit: add)
                        .sessionFocused($keyFocused)
                        .modifier(WhatsAppQuietField(width: 230))
                        .accessibilityLabel(WhatsAppWords.keyPrompt)
                    Spacer(minLength: 0)
                    Button(WhatsAppWords.add, action: add).controlSize(.small)
                        .disabled(store.checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, DeckSettingsLook.rowPadding)
                .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
                if let problem = store.problem { DeckSettingsProblem(text: problem) }
            } else {
                DeckSettingsButtonRow(title: WhatsAppWords.addRow) { begin() }
            }
        }
        .onAppear { if startsOpen, !open { begin() } }
    }

    private func begin() {
        store.problem = nil
        name = store.nextDefaultName
        key = ""
        open = true
        keyFocused = true
    }
    private func close() { open = false; key = ""; store.problem = nil }
    private func add() {
        let typedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedKey.isEmpty, !store.checking else { return }
        let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await store.add(name: typedName, key: typedKey) { open = false; key = ""; name = "" }
        }
    }
}

// MARK: - The submenu and the chip (switching from where he is)

/// What the "WhatsApp" submenu lists for one place: his WhatsApp agents by name, a check on the ones attached here.
enum WhatsAppMenu {
    struct Item: Equatable, Identifiable { let id: String; let name: String; let checked: Bool }
    enum Choice: Equatable { case agent(String), off, sending(Bool) }

    static func items(_ agents: [WhatsAppAgentProfile], here: WhatsAppReceiver) -> [Item] {
        agents.map { Item(id: $0.id, name: $0.name, checked: $0.receiver.sameTarget(here)) }
    }

    /// A WhatsApp agent: attached HERE (taken from wherever it was). "Off": every one attached here goes to Nowhere.
    @MainActor @discardableResult
    static func perform(_ choice: Choice, here: WhatsAppReceiver, store: NativeWhatsAppAgents) async -> Bool {
        switch choice {
        case .agent(let id): return await store.attach(id, to: here)
        case .off: return await store.off(here)
        case .sending(let on):
            // The switch belongs to the WhatsApp agent attached here (the chip's).
            guard let agent = store.chip(for: here) else { return false }
            return await store.setSending(on, for: agent.id)
        }
    }

    @MainActor static func choose(_ choice: Choice, here: WhatsAppReceiver, store: NativeWhatsAppAgents) {
        Task { await perform(choice, here: here, store: store) }
    }
}

/// The items, used by the submenu and by the chip's own menu.
struct NativeWhatsAppMenuItems: View {
    let here: WhatsAppReceiver
    var store: NativeWhatsAppAgents = .shared

    var body: some View {
        let items = WhatsAppMenu.items(store.agents, here: here)
        if items.isEmpty {
            Button(WhatsAppWords.addFromMenu) { AppModel.shared.openSettings(section: WhatsAppWords.settingsSection) }
        } else {
            ForEach(items) { item in
                Toggle(item.name, isOn: Binding(get: { item.checked }, set: { _ in
                    if !item.checked { WhatsAppMenu.choose(.agent(item.id), here: here, store: store) }
                }))
            }
            Divider()
            if let attached = store.chip(for: here) {
                Toggle(WhatsAppWords.send, isOn: Binding(get: { attached.sending }, set: { on in
                    WhatsAppMenu.choose(.sending(on), here: here, store: store)
                }))
            }
            Button(WhatsAppWords.off) { WhatsAppMenu.choose(.off, here: here, store: store) }
                .disabled(!items.contains(where: \.checked))
        }
    }
}

/// "WhatsApp ▸" inside an existing menu (a session row's right-click and ⋯, an agent's and Hoot's ⋯).
struct NativeWhatsAppSubmenu: View {
    let here: WhatsAppReceiver
    var store: NativeWhatsAppAgents = .shared
    var body: some View {
        Menu(WhatsAppWords.submenuTitle) { NativeWhatsAppMenuItems(here: here, store: store) }
    }
}

/// The heading's WhatsApp button: ONLY while a WhatsApp agent is attached here. Review of 18 Nov (item 16: "this
/// WhatsApp button is too bigger. We just need a nicer option than this"): ONE small button in place of the name and
/// the big switch, a grey outline while it is not sending and filled with the accent while it is. A press opens the
/// app's own menu: the "Send to WhatsApp" switch on top, then the agent choice, then Off. Nothing when none is attached.
struct NativeWhatsAppChip: View {
    let here: WhatsAppReceiver
    var store: NativeWhatsAppAgents = .shared
    /// The dot before it, when it follows another chip in the line.
    var separated = true
    @State private var open = false

    var body: some View {
        if let agent = store.chip(for: here) {
            if separated { ChipSeparator() }
            Button { open.toggle() } label: { DeckWhatsAppMark(on: agent.sending) }
                .buttonStyle(.plain)
                .help(agent.sending ? "Sending to WhatsApp: \(agent.name)" : "WhatsApp: \(agent.name), not sending")
                .accessibilityLabel("WhatsApp: \(agent.name)")
                .accessibilityValue(agent.sending ? "Sending" : "Not sending")
                .deckMenu(isPresented: $open) {
                    DeckMenuToggleRow(title: WhatsAppWords.send, isOn: Binding(get: { agent.sending }, set: { on in
                        WhatsAppMenu.choose(.sending(on), here: here, store: store)
                    }))
                    DeckMenuDivider()
                    DeckMenuSection("Agent")
                    ForEach(WhatsAppMenu.items(store.agents, here: here)) { item in
                        DeckMenuRow(item.name, checked: item.checked) {
                            if !item.checked { WhatsAppMenu.choose(.agent(item.id), here: here, store: store) }
                        }
                    }
                    DeckMenuDivider()
                    DeckMenuRow(WhatsAppWords.off, symbol: "xmark.circle") { WhatsAppMenu.choose(.off, here: here, store: store) }
                }
        }
    }
}

/// The button's face: 18 x 18 (the height of the line it sits in), radius 5. Off = a grey hairline outline and a grey
/// glyph; on = filled with the accent, white glyph.
struct DeckWhatsAppMark: View {
    let on: Bool

    var body: some View {
        Image(systemName: WhatsAppGlyph.symbol).font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(width: 18, height: 18)
            .background(on ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.secondary.opacity(on ? 0 : 0.5), lineWidth: 1))
            .contentShape(.rect)
    }
}
