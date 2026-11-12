import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct AWAgentsWatchScreen: View {
    @State private var model: AWAgentsWatchModel
    @State private var sortOrder = [KeyPathComparator(\AWWatchAgent.cpuSort, order: .reverse)]
    @FocusState private var searchFocused: Bool
    @State private var columns = TableColumnCustomization<AWWatchAgent>()
    @State private var tableWidth: CGFloat = 1200
    @State private var hiddenColumns: Set<String> = []
    var embedded = false
    var projectID: String?
    var live = true
    init(sourceEvents: [String]? = nil, embedded: Bool = false, projectID: String? = nil,
         model: AWAgentsWatchModel? = nil, live: Bool = true) {
        _model = State(initialValue: model ?? sourceEvents.map { AWAgentsWatchModel(sourceEvents: $0) } ?? AWAgentsWatchModel())
        self.embedded = embedded; self.projectID = projectID; self.live = live
    }
    var body: some View {
        @Bindable var bound = model
        VStack(spacing: 12) {
            if !embedded {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agents").font(.system(size: 20, weight: .semibold))
                        Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    AWAtWorkHeaderActions(model: model)
                }.frame(height: 52)
            }
            toolbar
            if let error = model.error ?? model.usageError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Spacer()
                    DeckRetryButton("Try Again", autoRetry: true) { model.retry() }.buttonStyle(.bordered) // autoRetry: re-reads the agents-at-work list
                }.font(.callout)
            }
            if !model.notices.isEmpty { Text(model.notices.joined(separator: " ")).font(.caption).foregroundStyle(.secondary) }
            if tableWidth < 720 { compactRows } else { table }
            footer
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 48 } action: { tableWidth = $0; fitColumns() }
        .inspector(isPresented: $bound.inspectorPresented) { inspector.inspectorColumnWidth(360) }
        .onAppear { model.selectedProjectID = projectID; if live { model.start(); AGTHandsStore.shared.start() } }
        .onDisappear { if live { model.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: .init("AGFRAME.focusSearch"))) { note in
            if note.object as? String == "work" { searchFocused = true }
        }
        .onChange(of: model.inspectorPresented) { _, shown in model.inspectorChanged(shown) }
        .onChange(of: projectID) { _, id in model.selectedProjectID = id }
        .onChange(of: model.metric) { _, metric in
            switch metric {
            case .cpu: sortOrder = [KeyPathComparator(\AWWatchAgent.cpuSort, order: .reverse)]
            case .memory: sortOrder = [KeyPathComparator(\AWWatchAgent.memorySort, order: .reverse)]
            case .tokens: sortOrder = [KeyPathComparator(\AWWatchAgent.tokensSort, order: .reverse)]
            }
        }
    }
    private var toolbar: some View {
        @Bindable var bound = model
        let search = NativeSessionTextField("Find an agent, project or app", text: $bound.search).textFieldStyle(.roundedBorder)
            .sessionFocused($searchFocused).frame(minWidth: 110, maxWidth: 210)
        let chips = FilterChips(selection: $bound.source, items: AGTWatchSource.allCases.map { source in
            AGKITFilterItem(id: source, title: source == .all ? "Everything" : source.title,
                count: model.sourceCount(source))
        }).fixedSize()
        let metric = Picker("Load graph", selection: $bound.metric) {
            ForEach(AWLoadMetric.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 174)
        // Narrow windows: the source chips move to their own line instead of being cut off.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { search; chips; Spacer(minLength: 0); metric }.frame(height: 34)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { search; Spacer(minLength: 0); metric }.frame(height: 34)
                chips
            }
        }
    }
    /// Column minimums plus the inset table's cell spacing need about 830 pt for all eight
    /// columns and 760 pt for seven. Below that, drop Time, then Tokens (or Memory while
    /// Tokens is the chosen measure), so nothing scrolls sideways.
    private func fitColumns() {
        let narrow = tableWidth < 760
        let hidden: Set<String> = tableWidth >= 830 ? [] : narrow ? ["time", model.metric == .tokens ? "memory" : "tokens"] : ["time"]
        guard hidden != hiddenColumns else { return }
        for id in ["time", "tokens", "memory"] { columns[visibility: id] = hidden.contains(id) ? .hidden : .visible }
        hiddenColumns = hidden
    }
    private var selection: Binding<String?> {
        Binding(get: { model.selectedID }, set: { model.select($0) })
    }
    private var rows: [AWWatchAgent] { model.visible.sorted(using: sortOrder) }
    private var compactRows: some View {
        List(rows, selection: selection) { row in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    AWAgentMark(row: row, icon: model.icon(for: row), identity: model.colourIdentity(for: row))
                    Text(row.name).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    AWStateMark(state: row.state)
                }
                Text(row.action).fixedSize(horizontal: false, vertical: true)
                Text(model.projectName(row) + " · CPU " + (row.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                     + " · Memory " + (row.memoryBytes.map(AWResourceFormat.memory) ?? "—")
                     + " · " + AWResourceFormat.duration(since: row.since, now: model.sampledAt))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 5).tag(row.id)
                .contextMenu {
                    NativeSessionButton("Details") { model.select(row.id); model.inspectorPresented = true }
                    if !row.isOtherApp { NativeSessionButton("Watch in a tab") { model.select(row.id); model.openSession() } }
                }
                .onTapGesture(count: 2) { model.select(row.id); model.inspectorPresented = true }
        }.listStyle(.inset).font(.system(size: 12))
    }
    private var table: some View {
        Table(of: AWWatchAgent.self, selection: selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Agent", value: \.name) { row in
                HStack(spacing: 8) {
                    AWAgentMark(row: row, icon: model.icon(for: row), identity: model.colourIdentity(for: row))
                    Text(row.name).fontWeight(.medium).lineLimit(1)
                    // One row per hand's job: a seat with several hands says which hand this is.
                    if let hand = AGTHandsStore.shared.hand(session: row.sessionID), AGTHandsStore.shared.hands(on: hand.seat).count > 1 {
                        Text("hand \(hand.number)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(AWStyle.selection, in: RoundedRectangle(cornerRadius: 4))
                            .help(hand.job.isEmpty ? "One of several hands on the same seat" : "Its job: " + hand.job)
                    }
                    if let app = row.sourceApp {
                        Text(app).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(AWStyle.selection, in: RoundedRectangle(cornerRadius: 4))
                    }
                }.frame(height: 26)
            }.width(min: 110, ideal: 130)
            TableColumn("State", value: \.stateText) { row in AWStateMark(state: row.state) }.width(84)
            TableColumn("Doing now", value: \.action) { row in Text(row.action).lineLimit(1).help(row.action) }
                .width(min: 90, ideal: 110)
            TableColumn("% CPU", value: \.cpuSort) { row in resource(row.cpuPercent.map { String(format: "%.1f", $0) }, note: row.resourceNote) }.width(66)
            TableColumn("Memory", value: \.memorySort) { row in resource(row.memoryBytes.map(AWResourceFormat.memory), note: row.resourceNote) }.width(70)
                .customizationID("memory")
            TableColumn("Time", value: \.timeSort) { row in Text(AWResourceFormat.duration(since: row.since, now: model.sampledAt)).monospacedDigit() }.width(60)
                .customizationID("time")
            TableColumn("Tokens", value: \.tokensSort) { row in resource(row.tokensToday.map(AWResourceFormat.tokens), denied: false) }.width(60)
                .customizationID("tokens")
            TableColumn("Project", value: \.resolvedProjectID) { row in
                Group {
                    if row.kind == "hoot" { ProjectChip(name: "Every project", color: AGKITStyle.hoot) }
                    else {
                        let id = PROJProjects.resolve(projectID: row.projectID, folder: row.project, projects: NativePROJLabels.shared.projects)
                        ProjectChip(project: NativePROJLabels.shared.projects.first { $0.id == id }, name: model.projectName(row))
                    }
                }.help(row.project)
            }.width(92)
        } rows: {
            if model.source != .other {
                Section("In Terminal Deck · \(rows.filter { !$0.isOtherApp }.count)") {
                    ForEach(rows.filter { !$0.isOtherApp }) { TableRow($0) }
                }
            }
            if model.source != .terminalDeck {
                Section("In other apps · \(rows.filter(\.isOtherApp).count) · watch only — open them in their own app") {
                    ForEach(rows.filter(\.isOtherApp)) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.system(size: 12))
        // Narrow windows drop the least important columns instead of scrolling sideways.
        // A fresh table per column set: AppKit never shrinks a table's width when a column hides.
        .id(hiddenColumns.sorted().joined(separator: ","))
        .onChange(of: model.metric) { _, _ in fitColumns() }
        .contextMenu(forSelectionType: String.self) { ids in
            NativeSessionButton("Details") { model.select(ids.first); model.inspectorPresented = true }.disabled(ids.isEmpty)
            if let id = ids.first, model.deviceAgent(id) == nil { NativeSessionButton("Watch in a tab") { model.select(id); model.openSession() } }
            if let id = ids.first, let other = model.deviceAgent(id) {
                NativeSessionButton("Open in its app") { AGTWatchSource.bringForward(other) }
                NativeSessionButton("Copy resume command") { AGTWatchSource.copyResume(other) }.disabled(other.resumeCommand == nil)
            }
        } primaryAction: { ids in model.select(ids.first); model.inspectorPresented = true }
        .overlay {
            if model.loading {
                VStack(spacing: 8) { ForEach(0..<6) { _ in RoundedRectangle(cornerRadius: 4).fill(AWStyle.selection).frame(height: 26) } }
                    .padding(16).frame(maxHeight: .infinity, alignment: .top).accessibilityLabel("Loading agent activity")
            } else if rows.isEmpty, model.error == nil, model.usageError == nil {
                VStack(spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(model.search.isEmpty ? "No agents are running" : "No agents match this search").font(.headline)
                    Text("Start one from All agents, or wake one up.").font(.callout).foregroundStyle(.secondary)
                }.allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AWStyle.hairline, lineWidth: 1))
        .frame(minHeight: 0, maxHeight: .infinity)
    }
    private func resource(_ text: String?, denied: Bool = true, note: String? = nil) -> some View {
        Text(text ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            .help(note ?? (text == nil ? (denied ? "This Mac didn't allow reading this process, or no sample has arrived." : "Token usage is unavailable for this agent.") : text!))
    }
    private var footer: some View {
        GeometryReader { geometry in
            let side = min(230.0, max(160.0, geometry.size.width * 0.23))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    stat("Agents working", "\(model.shownCounts["working"] ?? 0)")
                    stat("Waiting for you", "\(model.shownCounts["waiting"] ?? 0)", color: AWStyle.warn)
                    stat("Tokens today", model.totalTokens.map(AWResourceFormat.tokens) ?? "—")
                    HStack(spacing: 6) {
                        stat("Heavy job running", model.heavyJob)
                        if model.heavyJobBusy {
                            NativeSessionButton("Free") { model.freeHeavyJob() }.buttonStyle(.link).font(.system(size: 11)).disabled(model.changing)
                                .help("Let go of the heavy job now so the next waiting agent can start. Use it when the agent holding it has stopped.")
                        }
                    }
                }.padding(.horizontal, 16).frame(width: side)
                Divider()
                AWLoadGraph(samples: model.history, metric: model.metric).padding(.horizontal, 16).frame(maxWidth: .infinity)
                Divider()
                VStack(spacing: 0) {
                    stat("Memory used by agents", model.totalMemory.map(AWResourceFormat.memory) ?? "—")
                    stat("Free memory", model.history.last?.freeMemoryBytes.map(AWResourceFormat.memory) ?? "—")
                    stat("Processes", model.history.last?.processes.map(String.init) ?? "—")
                    stat("Updated", model.history.isEmpty ? "—" : "live")
                }.padding(.horizontal, 16).frame(width: side)
            }.padding(.vertical, 12)
        }.frame(height: 118)
            .background(AWStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AWStyle.hairline, lineWidth: 1))
    }
    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) { Text(title).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 2); Text(value).foregroundStyle(color).monospacedDigit().lineLimit(1) }
            .font(.system(size: 11)).frame(height: 20).help(title + ": " + value)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let agent = model.selected {
                Text(agent.name).font(.headline)
                Text(model.projectName(agent)).font(.caption).foregroundStyle(.secondary)
                AWStateMark(state: agent.state)
                ViewThatFits(in: .horizontal) {
                    HStack { inspectorActions(agent) }
                    VStack(alignment: .leading) { inspectorActions(agent) }
                }
                Divider()
                if let error = model.conversationError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    DeckRetryButton("Try Again", autoRetry: true) { model.readSelected() } // autoRetry: re-reads the selected agent's conversation
                }
                if let notice = model.conversationNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if !entry.title.isEmpty { Text(entry.title).font(.callout.weight(.medium)) }
                                    Text(entry.text).font(entry.kind == .tool ? .system(.caption, design: .monospaced) : .callout).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(entry.id)
                            }
                            if model.entries.isEmpty { Text(model.reading ? "Reading conversation…" : "No conversation has arrived yet.").foregroundStyle(.secondary) }
                        }
                    }.onChange(of: model.entries) { _, _ in if model.follow, let id = model.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Toggle("Follow live", isOn: Binding(get: { model.follow }, set: { model.follow = $0 })).toggleStyle(.checkbox).tint(.accentColor).font(.caption)
            } else { Text("Choose an agent to see its details.").foregroundStyle(.secondary) }
        }.padding(16).frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
    @ViewBuilder private func inspectorActions(_ agent: AWWatchAgent) -> some View {
        if let other = model.deviceAgent(agent.id) {
            NativeSessionButton("Open in its app") { AGTWatchSource.bringForward(other) }
            NativeSessionButton("Copy resume command") { AGTWatchSource.copyResume(other) }.disabled(other.resumeCommand == nil)
            if other.state == .finished, other.resumeCommand != nil {
                NativeSessionButton("Resume here") { model.resumeRequested = true }
            }
        } else { NativeSessionButton("Watch in a tab") { model.openSession() }.disabled(agent.sessionID == nil && agent.kind != "hoot") }
    }
}

struct AWAtWorkHeaderActions: View {
    @Bindable var model: AWAgentsWatchModel
    var body: some View {
        HStack(spacing: 8) {
            NativeSessionButton { model.stopRequested = true } label: { Image(systemName: "stop").frame(width: 28, height: 28) }
                .help("Stop the selected agent").accessibilityLabel("Stop the selected agent")
                .disabled(model.selected == nil || model.selected?.isOtherApp == true || model.selected?.state == .finished || model.changing)
            NativeSessionButton { model.inspectorPresented.toggle() } label: { Image(systemName: "info.circle").frame(width: 28, height: 28) }
                .help("Details").accessibilityLabel("Details").keyboardShortcut("i", modifiers: .command).disabled(model.selected == nil && !model.inspectorPresented)
        }.buttonStyle(.borderless)
        .confirmationDialog("Stop \(model.selected?.name ?? "this agent")?", isPresented: $model.stopRequested) {
            NativeSessionButton("Stop agent", role: .destructive) { model.stopSelected() }
        } message: { Text("Its running work will stop.") }
        .confirmationDialog("Resume this agent in Terminal Deck?", isPresented: $model.resumeRequested) {
            NativeSessionButton("Resume here") { model.resumeSelected() }
        }
    }
}

// One-line AGKIT seam once READY: typealias AWAgentTile = AgentAvatar.
private typealias AWAgentTile = AgentAvatar
private struct AWAgentMark: View {
    let row: AWWatchAgent
    let icon: AGTIcon
    let identity: (id: String, colour: String?)
    var body: some View {
        AWAgentTile(icon: icon, size: 22,
            tint: row.isOtherApp ? (row.provider == "claude" ? .orange : row.provider == "gemini" ? .purple : .gray) : nil,
            hoot: row.kind == "hoot", id: identity.id, colour: identity.colour)
    }
}
private struct AWStateMark: View {
    let state: AWWatchState
    var body: some View {
        StatusLabel(state == .working ? .working : state == .waiting ? .waiting : .idle,
            text: state.label, fontSize: 11)
    }
}
extension AWWatchAgent {
    var cpuSort: Double { cpuPercent ?? -1 }
    var memorySort: Double { memoryBytes ?? -1 }
    var tokensSort: Double { tokensToday ?? -1 }
    var timeSort: Double { since ?? .greatestFiniteMagnitude }
    var stateText: String { state.label }
}
enum AWResourceFormat {
    static func memory(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max), max(0, bytes))), countStyle: .memory) }
    static func tokens(_ count: Double) -> String { count >= 1_000_000 ? String(format: "%.1fM", count / 1_000_000) : count >= 1000 ? String(format: "%.1fk", count / 1000) : String(format: "%.0f", count) }
    static func duration(since: Double?, now: Double) -> String {
        guard let since, since > 0 else { return "—" }
        let seconds = Int(max(0, (now - since) / 1000))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
