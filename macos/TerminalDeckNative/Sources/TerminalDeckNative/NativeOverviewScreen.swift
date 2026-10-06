import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Overview, drawn in Swift — src/renderer/dashboard/Dashboard.tsx one for one: the
/// running-sessions board on top (SessionBoard), then "This project" with its
/// widget grid (12 columns, drag a widget by its header, resize from its corner,
/// Alt+arrows to move and Alt+Shift+arrows to resize), "Add widget" and "Reset the
/// layout", saved per project on `dashboard:load` / `dashboard:save`.
struct NativeOverviewScreen: View {
    @State private var dashboard = DashboardScreenModel()
    @State private var board = BoardModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DeckScopeLine(path: project)
                        BoardView(model: board, projectPath: project)
                        DashboardSection(model: dashboard)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                DeckNeedsProject(label: "Overview", symbol: "square.grid.2x2")
            }
        }
        .background(.background)
        .onChange(of: project, initial: true) { _, path in dashboard.show(path) }
        .task { board.start() }
        .onDisappear {
            dashboard.leave()
            board.stop()
        }
        .sheet(isPresented: Binding(get: { dashboard.picking }, set: { dashboard.picking = $0 })) {
            WidgetPicker(model: dashboard)
        }
    }
}

// MARK: - The grid's model

@MainActor
@Observable
final class DashboardScreenModel {
    private(set) var projectPath: String?
    private(set) var layout = DashboardRules.createLayout("")
    private(set) var loaded = false
    var picking = false
    /// The page's `features.v2`, so a widget whose feature is off is not drawn.
    private(set) var features: [String: String] = [:]
    /// While a widget is dragged or resized: the grid as it would settle.
    private(set) var preview: DashboardLayout?
    private(set) var activeId: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pending: (path: String, layout: DashboardLayout)?

    var shown: DashboardLayout { preview ?? layout }
    var empty: Bool { layout.widgets.isEmpty }

    func drawn(_ layout: DashboardLayout) -> [DashboardWidget] {
        DashboardRules.readingOrder(layout).filter { DashboardRules.widgetOn($0.type, features: features) }
    }

    func show(_ path: String?) {
        guard path != projectPath else { return }
        flush()
        projectPath = path
        loaded = false
        preview = nil
        guard let path else { return }
        layout = DashboardRules.defaultLayout(path)
        readFeatures()
        Task {
            do {
                let raw = try await EngineBridge.shared.invoke("dashboard:load", [path])
                guard path == projectPath else { return }
                loaded = true
                set(DashboardRules.settle(DashboardRules.parse(raw, projectPath: path)))
            } catch {
                // Persistence stays off, as on the page; the default layout is shown.
            }
        }
    }

    func leave() { flush() }

    private func readFeatures() {
        AppModel.shared.web.webView.evaluateJavaScript("localStorage.getItem('features.v2')") { [weak self] value, _ in
            MainActor.assumeIsolated {
                self?.features = DashboardRules.featureState(value as? String)
            }
        }
    }

    /// Every change: the new grid, saved half a second later.
    private func set(_ next: DashboardLayout) {
        layout = next
        guard loaded, let path = projectPath else { return }
        pending = (path, next)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: DashboardRules.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        saveTask?.cancel()
        guard let pending else { return }
        self.pending = nil
        let body = DashboardRules.serialise(pending.layout)
        Task { _ = try? await EngineBridge.shared.invoke("dashboard:save", [pending.path, body]) }
    }

    func add(_ type: WidgetType) {
        set(DashboardRules.settle(DashboardRules.add(layout, type: type)))
        picking = false
    }

    func remove(_ id: String) { set(DashboardRules.settle(DashboardRules.remove(layout, id: id))) }

    func reset() {
        guard let projectPath else { return }
        set(DashboardRules.defaultLayout(projectPath))
    }

    /// Alt+arrows move, Alt+Shift+arrows resize.
    func nudge(_ id: String, dx: Int, dy: Int, resize: Bool) {
        guard let widget = layout.widgets.first(where: { $0.id == id }) else { return }
        let next = resize
            ? DashboardRules.resize(layout, id: id, w: widget.w + dx, h: widget.h + dy)
            : DashboardRules.move(layout, id: id, x: widget.x + dx, y: widget.y + dy)
        set(DashboardRules.settle(next, anchor: id))
    }

    func drag(_ id: String, x: Int, y: Int, w: Int, h: Int) {
        activeId = id
        preview = DashboardRules.preview(layout, id: id, x: x, y: y, w: w, h: h)
    }

    func drop() {
        if let preview { set(preview) }
        preview = nil
        activeId = nil
    }
}

// MARK: - "This project" and the grid

private struct DashboardSection: View {
    let model: DashboardScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("This project").font(.system(size: 15, weight: .semibold))
                if !model.empty {
                    Text("Drag a widget by its header · Alt+arrows to move").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { model.picking = true } label: { Label("Add widget", systemImage: "plus") }
                if !model.empty {
                    Button("Reset the layout", action: model.reset)
                }
            }
            if model.empty {
                Text("Nothing here yet. Add a widget for this folder's token usage, git state, GitHub or AI readiness.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let projectPath = model.projectPath {
                DashboardGrid(model: model, projectPath: projectPath)
            }
        }
    }
}

private struct DashboardGrid: View {
    let model: DashboardScreenModel
    let projectPath: String
    @State private var width: CGFloat = 0
    /// The pointer's offset from where the active widget started, while dragging.
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero

    private var column: CGFloat { max(1, width / CGFloat(DashboardRules.columns)) }
    private let row = CGFloat(DashboardRules.cellHeight)
    private let margin = CGFloat(DashboardRules.gridMargin)

    var body: some View {
        let shown = model.shown
        let widgets = model.drawn(shown)
        let rows = max(DashboardRules.rows(shown), 1)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: CGFloat(rows) * row)
            if let id = model.activeId, let slot = shown.widgets.first(where: { $0.id == id }) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .frame(width: frame(slot).width, height: frame(slot).height)
                    .offset(x: frame(slot).minX, y: frame(slot).minY)
            }
            ForEach(widgets) { widget in
                let base = model.layout.widgets.first(where: { $0.id == widget.id }) ?? widget
                let active = model.activeId == widget.id
                let rect = active ? frame(base) : frame(widget)
                WidgetCard(widget: widget, projectPath: projectPath, model: model,
                           headerDrag: headerDrag(base), cornerDrag: cornerDrag(base))
                    .frame(width: max(40, rect.width + (active ? resizeDelta.width : 0)),
                           height: max(40, rect.height + (active ? resizeDelta.height : 0)))
                    .offset(x: rect.minX + (active ? dragOffset.width : 0), y: rect.minY + (active ? dragOffset.height : 0))
                    .zIndex(active ? 1 : 0)
                    .shadow(color: .black.opacity(active ? 0.18 : 0), radius: 10, y: 4)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.preview)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .coordinateSpace(.named("dashboard-grid"))
    }

    private func frame(_ widget: DashboardWidget) -> CGRect {
        CGRect(x: CGFloat(widget.x) * column + margin / 2, y: CGFloat(widget.y) * row + margin / 2,
               width: CGFloat(widget.w) * column - margin, height: CGFloat(widget.h) * row - margin)
    }

    private func headerDrag(_ widget: DashboardWidget) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("dashboard-grid"))
            .onChanged { value in
                dragOffset = value.translation
                let x = Int(((CGFloat(widget.x) * column + value.translation.width) / column).rounded())
                let y = Int(((CGFloat(widget.y) * row + value.translation.height) / row).rounded())
                model.drag(widget.id, x: x, y: y, w: widget.w, h: widget.h)
            }
            .onEnded { _ in
                dragOffset = .zero
                model.drop()
            })
    }

    private func cornerDrag(_ widget: DashboardWidget) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("dashboard-grid"))
            .onChanged { value in
                resizeDelta = value.translation
                let w = Int(((CGFloat(widget.w) * column + value.translation.width) / column).rounded())
                let h = Int(((CGFloat(widget.h) * row + value.translation.height) / row).rounded())
                model.drag(widget.id, x: widget.x, y: widget.y, w: w, h: h)
            }
            .onEnded { _ in
                resizeDelta = .zero
                model.drop()
            })
    }
}

/// One widget: its header (the drag handle, Alt+arrows) with the remove button, its body, and the resize corner.
private struct WidgetCard: View {
    let widget: DashboardWidget
    let projectPath: String
    let model: DashboardScreenModel
    let headerDrag: AnyGesture<DragGesture.Value>
    let cornerDrag: AnyGesture<DragGesture.Value>
    @FocusState private var focused: Bool

    var body: some View {
        let title = DashboardRules.title(widget.type)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button { model.remove(widget.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(title)")
                .accessibilityLabel("Remove \(title) widget")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .gesture(headerDrag)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 1.5).padding(2))
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.option) else { return .ignored }
                let delta: (Int, Int)
                switch press.key {
                case .leftArrow: delta = (-1, 0)
                case .rightArrow: delta = (1, 0)
                case .upArrow: delta = (0, -1)
                case .downArrow: delta = (0, 1)
                default: return .ignored
                }
                model.nudge(widget.id, dx: delta.0, dy: delta.1, resize: press.modifiers.contains(.shift))
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(title) widget. Alt with arrow keys to move, Alt and Shift with arrow keys to resize.")
            Divider()
            ScrollView {
                WidgetBody(type: widget.type, projectPath: projectPath)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .contentShape(.rect)
                .gesture(cornerDrag)
                .help("Drag to resize")
        }
    }
}

/// "Add a widget": every widget this window has, the ones already there greyed out.
private struct WidgetPicker: View {
    let model: DashboardScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a widget").font(.title3.weight(.semibold))
            Text("Widgets you already have are greyed out.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(DashboardRules.pickable().filter { DashboardRules.widgetOn($0, features: model.features) }, id: \.self) { type in
                    let allowed = DashboardRules.canAdd(model.layout, type)
                    Button { model.add(type) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(DashboardRules.title(type)).font(.callout.weight(.semibold))
                                Spacer()
                                if !allowed { Text("on the dashboard").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(DashboardRules.description(type)).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowed)
                    .opacity(allowed ? 1 : 0.5)
                }
            }
            HStack {
                Spacer()
                Button("Close") { model.picking = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Widgets

/// `useBridgeData`: loading, an error with Retry, or the answer — with the page's deadline.
/// One engine channel, called with the project path (or nothing), read by a pure transform.
@MainActor
@Observable
final class WidgetData<Value: Sendable> {
    enum State { case loading, failed(String), ready(Value) }
    private(set) var state: State = .loading
    @ObservationIgnored private var run = 0
    @ObservationIgnored private let channel: String
    @ObservationIgnored private let withPath: Bool
    @ObservationIgnored private let transform: @Sendable (Any, String) -> Value
    @ObservationIgnored private let what: String
    /// `WIDGET_DEADLINE_MS`.
    static var deadline: Double { 12 }

    nonisolated init(what: String, channel: String, withPath: Bool = true, transform: @escaping @Sendable (Any, String) -> Value) {
        self.what = what
        self.channel = channel
        self.withPath = withPath
        self.transform = transform
    }

    func load(_ projectPath: String) async {
        run += 1
        let mine = run
        state = .loading
        let channel = self.channel, transform = self.transform
        let args: [Any?] = withPath ? [projectPath] : []
        let work = Task { @MainActor () throws -> Value in
            transform(try await EngineBridge.shared.invoke(channel, args), projectPath)
        }
        let overdue = OverdueFlag()
        let timer = Task { @MainActor in
            try await Task.sleep(for: .seconds(Self.deadline))
            overdue.fired = true
            work.cancel()
        }
        let result: State
        do {
            result = .ready(try await work.value)
        } catch {
            result = .failed(overdue.fired ? ArtifactRules.overdue(what, seconds: Self.deadline) : deckMessage(error))
        }
        timer.cancel()
        guard mine == run else { return }
        state = result
    }
}

/// Set when a widget's read ran past its deadline (read on the main actor only).
private final class OverdueFlag: @unchecked Sendable { var fired = false }

private struct WidgetBody: View {
    let type: WidgetType
    let projectPath: String

    var body: some View {
        switch type {
        case .sessions: SessionsWidget(projectPath: projectPath)
        case .cost: UsageWidget(projectPath: projectPath)
        case .git: GitWidget(projectPath: projectPath)
        case .readiness: ReadinessWidget(projectPath: projectPath)
        case .github: GithubWidget(projectPath: projectPath)
        }
    }
}

/// `WidgetMessage`: a muted or error line, its detail, and at most one action.
private struct WidgetMessage: View {
    let title: String
    var detail: String?
    var error = false
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(error ? Color.red : Color.secondary)
            if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let action { Button(action.label, action: action.run).controlSize(.small).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StateView<Value: Sendable, Content: View>: View {
    let data: WidgetData<Value>
    let pending: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch data.state {
        case .loading: WidgetMessage(title: pending)
        case .failed(let message): WidgetMessage(title: "Could not load", detail: message, error: true, action: ("Retry", retry))
        case .ready(let value): content(value)
        }
    }
}

/// `Stat`: a figure and its word; pressable (with where it goes) when it leads somewhere.
private struct StatTile: View {
    let label: String
    let value: String
    var tone: DashboardWords.Tone?
    var goes: String?
    var action: (() -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tone == .crit ? Color.red : tone == .warn ? Color.orange : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let action {
            Button(action: action) { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .help(goes ?? "")
        } else {
            content
        }
    }
}

private struct WidgetStats<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { HStack(alignment: .top, spacing: 10) { content }.padding(.bottom, 8) }
}

private struct WidgetRow: View {
    var leading: String?
    var leadingMono = false
    let main: String
    var mono = false
    var sides: [String] = []
    var action: (() -> Void)?
    var help: String?

    var body: some View {
        let content = HStack(spacing: 8) {
            if let leading { Text(leading).font(leadingMono ? .system(size: 11, design: .monospaced) : .caption).foregroundStyle(.secondary) }
            Text(main).font(mono ? .system(size: 11.5, design: .monospaced) : .callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                Text(side).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        if let action {
            Button(action: action) { content.contentShape(.rect) }.buttonStyle(.plain).help(help ?? "")
        } else {
            content
        }
    }
}

private struct WidgetNote: View {
    let text: String
    var quiet = false
    var body: some View {
        Text(text).font(.caption).foregroundStyle(quiet ? .tertiary : .secondary).textSelection(.enabled).padding(.top, 4)
    }
}

// MARK: Usage

private struct UsageWidget: View {
    let projectPath: String
    @State private var data = WidgetData<UsageView>(what: "Reading this project’s transcripts", channel: "cost:project") { raw, _ in
        UsageRules.view(raw)
    }
    @State private var expanded = false

    var body: some View {
        StateView(data: data, pending: "Reading transcripts…", retry: { Task { await data.load(projectPath) } }) { view in
            readout(view)
        }
        .task(id: projectPath) { await data.load(projectPath) }
    }

    @ViewBuilder
    private func readout(_ view: UsageView) -> some View {
        if view.requests == 0 {
            WidgetMessage(title: UsageRules.emptyTitle(view), detail: UsageRules.emptyDetail(view))
        } else {
            let total = view.tokens.total
            let open: (() -> Void)? = total > 0 ? { expanded.toggle() } : nil
            let goes = expanded ? "Hide the breakdown" : "Show what the figures are made of"
            let percent = view.context?.percent
            let tone = DashboardWords.contextTone(percent)
            WidgetStats {
                StatTile(label: "tokens", value: DashboardWords.formatTokens(total), goes: goes, action: open)
                StatTile(label: "from cache", value: DashboardWords.formatPercent(view.tokens.cacheHitRate), goes: goes, action: open)
                StatTile(label: DashboardWords.plural(view.requests, "request"), value: String(view.requests), goes: goes, action: open)
                StatTile(label: "\(DashboardWords.plural(view.sessions, "session")) recorded", value: String(view.sessions), goes: goes, action: open)
            }
            WidgetNote(text: UsageRules.note(view))
            if expanded {
                Text("How \(DashboardWords.formatTokens(total)) tokens is made up").font(.caption.weight(.medium)).padding(.top, 6)
                ForEach(UsageRules.lines(view.tokens), id: \.label) { line in
                    WidgetRow(main: line.label, sides: [DashboardWords.formatTokens(line.tokens), DashboardWords.formatPercent(line.share)])
                }
                WidgetRow(main: "Total", sides: [DashboardWords.formatTokens(total), ""])
            }
            if let context = view.context, let percent {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Context window · session \(String(context.id.prefix(8)))") { DeckPage.run(.openInspector) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Open the session inspector")
                        Spacer()
                        Text("\(Int(percent.rounded()))%").font(.caption.weight(.semibold))
                            .foregroundStyle(tone == .crit ? Color.red : tone == .warn ? Color.orange : Color.primary)
                    }
                    WidgetNote(text: UsageRules.contextNote(context))
                    ProgressView(value: min(100, max(0, percent)), total: 100)
                        .tint(tone == .crit ? .red : tone == .warn ? .orange : .accentColor)
                        .accessibilityLabel("Context window in use")
                }
                .padding(.top, 8)
            }
            WidgetNote(text: UsageRules.quietNote(view), quiet: true)
        }
    }
}

// MARK: Git

private struct GitWidget: View {
    let projectPath: String
    @State private var data = WidgetData<GitWidgetStatus>(what: "Reading the repo", channel: "git:status") { raw, _ in
        GitWidgetRules.status(raw)
    }
    @State private var live: GitWidgetStatus?
    @State private var watch: EngineSubscription?

    var body: some View {
        StateView(data: data, pending: "Reading the repo…", retry: { Task { await data.load(projectPath) } }) { loaded in
            content(live ?? loaded)
        }
        .task(id: projectPath) {
            live = nil
            let path = projectPath
            watch = EngineBridge.shared.on("git:status-changed") { args in
                guard args.first as? String == path, let status = args.dropFirst().first as? [String: Any],
                      (status["repo"] as? Bool) == true else { return }
                live = GitWidgetRules.status(status)
            }
            _ = try? await EngineBridge.shared.invoke("git:watch", [path])
            await data.load(path)
        }
        .onDisappear {
            watch?.cancel()
            EngineBridge.shared.send("git:unwatch", [projectPath])
        }
    }

    @ViewBuilder
    private func content(_ status: GitWidgetStatus) -> some View {
        if !status.repo {
            WidgetMessage(title: GitWidgetRules.notRepoTitle(status.reason), detail: status.message)
        } else {
            let (shown, hidden) = GitWidgetRules.visibleFiles(status)
            HStack(spacing: 8) {
                Button(GitWidgetRules.branchName(status)) { DeckPage.navigate("git") }
                    .buttonStyle(.link)
                    .font(.system(size: 12, design: .monospaced))
                    .help("Open Source control")
                if status.ahead > 0 { Text("↑\(status.ahead)").help("Commits to push") }
                if status.behind > 0 { Text("↓\(status.behind)").help("Commits to pull") }
            }
            .font(.caption)
            .padding(.bottom, 6)
            if status.clean {
                WidgetMessage(title: "Working tree clean")
            } else {
                WidgetStats {
                    StatTile(label: "staged", value: String(status.staged.count), goes: "Open the staged files",
                             action: status.staged.isEmpty ? nil : { DeckPage.navigate("git", focus: "staged") })
                    StatTile(label: "changed", value: String(status.unstaged.count), goes: "Open the changed files",
                             action: status.unstaged.isEmpty ? nil : { DeckPage.navigate("git", focus: "unstaged") })
                    StatTile(label: "untracked", value: String(status.untracked.count), goes: "Open the untracked files",
                             action: status.untracked.isEmpty ? nil : { DeckPage.navigate("git", focus: "untracked") })
                    if !status.conflicted.isEmpty {
                        StatTile(label: DashboardWords.plural(status.conflicted.count, "conflict"), value: String(status.conflicted.count),
                                 tone: .crit, goes: "Open the conflicts", action: { DeckPage.navigate("git", focus: "conflicted") })
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, file in
                    WidgetRow(leading: GitWidgetRules.changeLabel(kind: file.kind, code: file.code), main: file.path, mono: true,
                        action: { DeckPage.openFile(file.path) }, help: "Open \(file.path)")
                }
                if hidden > 0 {
                    HStack(spacing: 4) {
                        WidgetNote(text: "…and \(hidden) more.")
                        Button("See them all") { DeckPage.navigate("git") }.buttonStyle(.link).font(.caption).padding(.top, 4)
                    }
                }
            }
        }
    }
}

// MARK: AI Readiness

private struct ReadinessWidget: View {
    let projectPath: String
    @State private var data = WidgetData<ReadinessWidgetView>(what: "Scoring the project", channel: "readiness:scan") { raw, _ in
        ReadinessWidgetRules.view(raw)
    }

    var body: some View {
        StateView(data: data, pending: "Scoring the project…", retry: { Task { await data.load(projectPath) } }) { view in
            WidgetStats {
                StatTile(label: view.band.isEmpty ? "readiness" : view.band, value: "\(view.score)%",
                         tone: ReadinessWidgetRules.tone(view.score), goes: "Open AI readiness", action: { DeckPage.navigate("readiness") })
                StatTile(label: "passing", value: ReadinessWidgetRules.passing(view.checks), goes: "Open AI readiness",
                         action: { DeckPage.navigate("readiness") })
            }
            if let capped = view.cappedBy { WidgetNote(text: "Held back by: \(capped)") }
            ForEach(ReadinessWidgetRules.sorted(view.checks), id: \.id) { check in
                HStack(spacing: 8) {
                    Circle().fill(color(check.status)).frame(width: 7, height: 7)
                        .help(check.gate ? "Caps the whole score until it passes" : "")
                    Text(check.title).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(check.status).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
        .task(id: projectPath) { await data.load(projectPath) }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "pass": return .green
        case "warn": return .orange
        case "fail": return .red
        default: return .secondary
        }
    }
}

// MARK: GitHub

private struct GithubWidget: View {
    let projectPath: String
    @State private var data = WidgetData<GithubWidgetView>(what: "Asking gh", channel: "github:overview") { raw, _ in
        GithubWidgetRules.view(raw)
    }

    var body: some View {
        let retry = { Task { await data.load(projectPath) } }
        StateView(data: data, pending: "Asking gh…", retry: { _ = retry() }) { view in
            if let failure = view.failure {
                WidgetMessage(title: "GitHub unavailable", detail: failure, action: ("Retry", { _ = retry() }))
            } else {
                let prs = view.items.filter(\.pr)
                let issues = view.items.filter { !$0.pr }
                if let repo = view.repo { WidgetNote(text: repo).font(.system(size: 11, design: .monospaced)) }
                if view.items.isEmpty && view.partial.isEmpty {
                    WidgetMessage(title: "Nothing open", detail: "No open pull requests or issues.")
                } else {
                    WidgetStats {
                        StatTile(label: DashboardWords.plural(prs.count, "pull request"), value: String(prs.count),
                                 goes: "Open the pull requests", action: prs.isEmpty ? nil : { DeckPage.navigate("github", focus: "pulls") })
                        StatTile(label: DashboardWords.plural(issues.count, "issue"), value: String(issues.count),
                                 goes: "Open the issues", action: issues.isEmpty ? nil : { DeckPage.navigate("github", focus: "issues") })
                    }
                    ForEach(view.items.prefix(GithubWidgetRules.maxRows), id: \.key) { item in
                        WidgetRow(leading: "#\(item.number)", leadingMono: true, main: item.title, sides: [item.pr ? "PR" : "issue"])
                    }
                    if view.items.count > GithubWidgetRules.maxRows {
                        WidgetNote(text: "…and \(view.items.count - GithubWidgetRules.maxRows) more.")
                    }
                }
                ForEach(view.partial, id: \.self) { WidgetNote(text: $0) }
            }
        }
        .task(id: projectPath) { await data.load(projectPath) }
    }
}

// MARK: Sessions (retired from the picker; still drawn when a saved layout has it)

private struct SessionsWidget: View {
    let projectPath: String
    @State private var swarm = false
    @State private var data = WidgetData<[BoardSession]>(what: "Looking for sessions", channel: "session:list", withPath: false) { raw, path in
        (raw as? [Any] ?? []).compactMap(BoardRules.sessionMeta).filter { $0.projectPath == path }
    }

    var body: some View {
        StateView(data: data, pending: "Looking for sessions…", retry: { Task { await data.load(projectPath) } }) { rows in
            if rows.isEmpty {
                WidgetMessage(title: "No sessions yet", detail: "Start one from the sidebar to see it here.")
            } else {
                let statuses = BoardModel.sidebarStatuses()
                let withStatus = rows.map { row -> BoardSession in
                    var next = row
                    if let status = statuses[row.id] { next.status = status }
                    return next
                }
                let live = withStatus.filter { ["working", "waiting", "input"].contains($0.status) }
                WidgetStats {
                    StatTile(label: DashboardWords.plural(rows.count, "session"), value: String(rows.count), goes: "Show them all at once",
                             action: swarm ? { DeckPage.run(.showSessions) } : nil)
                    StatTile(label: "running", value: String(live.count), goes: live.first.map { "Go to \($0.title)" },
                             action: live.first.map { first in { AppModel.shared.select(first.id) } })
                }
                ForEach(withStatus) { session in
                    Button { AppModel.shared.select(session.id) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(BoardColors.status(session.status)).frame(width: 7, height: 7)
                            Text(session.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(session.provider).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: projectPath) {
            // `onShowSessions` is only given while the swarm feature is on.
            swarm = (await DeckPage.features())["swarm"].map { $0 == "on" } ?? true
            await data.load(projectPath)
        }
    }
}

// MARK: - The running-sessions board

enum BoardColors {
    static func attention(_ attention: Attention) -> Color {
        switch attention {
        case .blocked: return .orange
        case .finished: return .green
        case .working: return .blue
        case .ready: return .secondary
        case .exited: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    static func status(_ status: String) -> Color { attention(BoardRules.attention(status)) }
}

@MainActor
@Observable
final class BoardModel {
    private(set) var live: [BoardSession] = []
    private(set) var folders: [String: BoardRules.FolderWork] = [:]
    private(set) var now = Date().timeIntervalSince1970 * 1000

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var awaitTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var planned: [String: String] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var started = false

    var sessions: [BoardSession] {
        let statuses = Self.sidebarStatuses()
        let merged = live.map { session -> BoardSession in
            var next = session
            // The page's own status (its store, through the side panel) wins until a change is seen here.
            if next.statusSince == 0, let status = statuses[session.id] { next.status = status }
            return next
        }
        return BoardRules.attachWork(merged, folders: folders)
    }

    /// Session id → status, as the page's side panel shows it.
    static func sidebarStatuses() -> [String: String] {
        guard let sidebar = AppModel.shared.sidebar else { return [:] }
        var out: [String: String] = [:]
        for item in sidebar.allItems where item.kind == .session {
            if let status = item.status { out[item.id] = status }
        }
        return out
    }

    func start() {
        guard !started else { return }
        started = true
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on("session:created") { [weak self] args in
            guard let self, let session = BoardRules.sessionMeta(args.first), !self.live.contains(where: { $0.id == session.id }) else { return }
            self.live.append(session)
            self.replan()
        })
        subscriptions.append(bridge.on("session:status") { [weak self] args in
            guard let self, let id = args.first as? String, let status = args.dropFirst().first as? String,
                  let index = self.live.firstIndex(where: { $0.id == id }), self.live[index].status != status else { return }
            self.live[index].status = status
            self.live[index].statusSince = Date().timeIntervalSince1970 * 1000
            self.replan()
        })
        subscriptions.append(bridge.on("session:exit") { [weak self] args in
            guard let self, let id = args.first as? String, let index = self.live.firstIndex(where: { $0.id == id }),
                  self.live[index].status != "exited" else { return }
            self.live[index].status = "exited"
            self.live[index].statusSince = Date().timeIntervalSince1970 * 1000
            self.replan()
        })
        subscriptions.append(bridge.on("cost:update") { [weak self] args in
            guard let self, let summary = args.first as? [String: Any], let cwd = summary["cwd"] as? String else { return }
            let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            guard self.watched.contains(trimmed) else { return }
            Task { await self.readCost(trimmed) }
        })
        Task {
            if let raw = try? await EngineBridge.shared.invoke("session:list", []) as? [Any] {
                live = raw.compactMap(BoardRules.sessionMeta)
                replan()
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !self.live.isEmpty { self.now = Date().timeIntervalSince1970 * 1000 }
            }
        }
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        ticker?.cancel()
        awaitTimers.values.forEach { $0.cancel() }
        awaitTimers = [:]
        // Counted with every other native watcher of the same folder (the engine counts per sender).
        for cwd in watched { NativeCostWatch.release(cwd) }
        watched = []
        started = false
    }

    /// `FolderWorkLoader` per folder: its transcripts (again every 4s while one is
    /// awaited) and its usage summary (again on each `cost:update` for it).
    private func replan() {
        let plan = BoardRules.folderPlan(live, folders: folders)
        for folder in plan {
            if planned[folder.cwd] != folder.sessionKey {
                planned[folder.cwd] = folder.sessionKey
                Task { await readFiles(folder.cwd) }
                if folders[folder.cwd] == nil { Task { await readCost(folder.cwd) } }
            }
            if folder.live && !watched.contains(folder.cwd) {
                watched.insert(folder.cwd)
                let cwd = folder.cwd
                Task { _ = await NativeCostWatch.retain(cwd) }
            }
            if folder.awaiting && awaitTimers[folder.cwd] == nil {
                let cwd = folder.cwd
                awaitTimers[cwd] = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: BoardRules.awaitTranscript)
                        await self?.readFiles(cwd)
                    }
                }
            } else if !folder.awaiting, let timer = awaitTimers.removeValue(forKey: folder.cwd) {
                timer.cancel()
            }
        }
    }

    private func readFiles(_ cwd: String) async {
        guard let raw = try? await EngineBridge.shared.invoke("insights:list", [cwd]) else { return }
        var work = folders[cwd] ?? BoardRules.FolderWork()
        work.files = BoardRules.transcriptFiles(raw)
        folders[cwd] = work
        replan()
    }

    private func readCost(_ cwd: String) async {
        guard let raw = try? await EngineBridge.shared.invoke("cost:project", [cwd]) else { return }
        var work = folders[cwd] ?? BoardRules.FolderWork()
        work.summaryAny = BoardRules.Box(raw)
        folders[cwd] = work
    }
}

private struct BoardView: View {
    let model: BoardModel
    let projectPath: String

    var body: some View {
        let sessions = model.sessions
        if sessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nothing is running", systemImage: "square.grid.2x2").font(.system(size: 15, weight: .semibold))
                Text("Start an agent in a folder and it appears here — what it is doing, how long it has been doing it, and whether it is waiting on you. Press ⌘T.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        } else {
            let counts = BoardRules.count(sessions)
            let (names, twins) = BoardRules.names(sessions)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(counts.total) \(DashboardWords.plural(counts.total, "session"))").font(.system(size: 15, weight: .semibold))
                    BoardSummary(parts: BoardRules.summaryParts(counts))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(BoardRules.sort(sessions)) { session in
                        BoardCard(session: session, name: names[session.id] ?? session.title, twin: twins.contains(session.id),
                                  now: model.now, here: session.projectPath == projectPath)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Running sessions")
        }
    }
}

private struct BoardSummary: View {
    let parts: [(attention: Attention, text: String)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text(" · ").foregroundStyle(.secondary) }
                Text(part.text).foregroundStyle(BoardColors.attention(part.attention))
            }
        }
        .font(.callout)
    }
}

private struct BoardCard: View {
    let session: BoardSession
    let name: String
    let twin: Bool
    let now: Double
    let here: Bool

    var body: some View {
        let attention = BoardRules.attention(session.status)
        let wants = BoardRules.wantsYou(attention)
        Button { AppModel.shared.select(session.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle().fill(BoardColors.attention(attention)).frame(width: 6, height: 6)
                        Text(BoardRules.label(attention))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(BoardColors.attention(attention).opacity(0.14), in: .capsule)
                    Spacer(minLength: 4)
                    Text("\(BoardRules.folderOf(session.projectPath))\(Text(here ? "" : " · other project").foregroundStyle(.tertiary))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(session.projectPath)
                }
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if twin { Text(BoardRules.shortSessionId(session.id)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                }
                .help(session.title)
                Text(BoardRules.stateSentence(session, now: now)).font(.callout).foregroundStyle(BoardColors.attention(attention))
                Text(BoardRules.meta(session, now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let work = session.work, work.requests > 0 {
                    HStack(alignment: .top, spacing: 14) {
                        BoardFigure(label: "Tokens", value: DashboardWords.formatTokens(work.tokens))
                        BoardFigure(label: "Requests", value: String(work.requests))
                        if let percent = work.contextPercent {
                            let tone = DashboardWords.contextTone(percent)
                            BoardFigure(label: "Context", value: "\(Int(percent.rounded()))%",
                                   color: tone == .crit ? .red : tone == .warn ? .orange : .primary)
                        }
                        if work.lastActivityAt > 0 {
                            BoardFigure(label: "Last wrote", value: "\(BoardRules.formatElapsed(max(0, now - work.lastActivityAt))) ago")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(wants ? BoardColors.attention(attention).opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: wants ? 1.2 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(name)")
    }
}

private struct BoardFigure: View {
    let label: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color).monospacedDigit()
        }
    }
}
