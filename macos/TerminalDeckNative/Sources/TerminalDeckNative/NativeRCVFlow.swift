import SwiftUI
import TerminalDeckNativeCore

extension NativeRCVModel {
    /// Narrowed by the search or the filters (Unrouted itself is not "narrowed").
    var narrowedBeyondPlace: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceFilter != nil || (place == .flow && statusFilter != nil)
    }
}

// MARK: - One event

private struct NativeRCVEventDetail: View {
    let model: NativeRCVModel
    let event: RCVEvent
    let overview: RCVOverview
    @State private var replying = false
    @State private var replyText = ""
    @State private var showRaw = false
    @State private var showHeaders = false

    private var source: RCVSource? { RCVPresentation.source(event.sourceId, in: overview.sources)?.source }

    var body: some View {
        let actions = RCVPresentation.actions(event, source: source)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                buttons(actions)
                NativeRCVActionLine(model: model)
                if replying { replyComposer }
                NativeRCVChain(steps: RCVPresentation.chain(event, overview: overview))
                replies
                trail
                fields
                rawAndHeaders
            }
            .padding(.trailing, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RCVPresentation.title(event))
                .font(.headline)
                .textSelection(.enabled)
                
            Text("\(RCVPresentation.sourceName(event.sourceId, in: overview.sources)) · \(event.kind) · \(event.severity.rawValue) · \(RCVPresentation.relative(event.receivedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !event.text.isEmpty && event.text != event.title {
                Text(event.text)
                    .textSelection(.enabled)
                    
                    .padding(.top, 6)
            }
            if let replayOf = event.replayOf, model.event(replayOf) != nil {
                Button("Show the original") { model.select(replayOf) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func buttons(_ actions: RCVPresentation.Actions) -> some View {
        let busy = model.busy != nil
        return HStack(spacing: 8) {
            if actions.suggest {
                Button(model.busy == "suggest" ? "Suggesting…" : "Suggest a rule") { Task { await model.suggest(event.id) } }
                    .help("Make a rule from this event and open it to check before saving")
            }
            if actions.askHoot {
                Button(model.busy == "ask-hoot" ? "Asking…" : "Ask Hoot") { Task { await model.askHoot(event.id) } }
                    .help("Hoot looks at it and tells you what it is and where it should go")
            }
            if actions.retry {
                Button(model.busy == "retry" ? "Retrying…" : "Retry") { Task { await model.retry(event.id) } }
                    .help(event.status == .held ? "Send it now instead of waiting" : "Try handing it over again")
            }
            if actions.route {
                Button("Route to…") { model.openSheet(.route(eventID: event.id)) }
                    .help("Send it to an agent, a running session or Hoot by hand")
            }
            if actions.replay {
                Button(model.busy == "replay" ? "Replaying…" : "Replay") { Task { await model.replay(event.id) } }
                    .help("Run it through the rules again as if it just arrived")
            }
            if actions.reply {
                Button("Reply") { replying.toggle() }
                    .help("Answer the sender through the same connection")
            }
        }
        .disabled(busy)
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeRCVHeading("Reply to the sender")
            TextField("Write the reply", text: $replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Text("It goes back through \(RCVPresentation.sourceName(event.sourceId, in: overview.sources)).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { replying = false; replyText = "" }
                Button(model.busy == "reply" ? "Sending…" : "Send") {
                    Task {
                        if await model.reply(event.id, text: replyText) { replying = false; replyText = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy != nil)
            }
        }
    }

    @ViewBuilder private var replies: some View {
        let lines = RCVPresentation.replyLines(event)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NativeRCVHeading("Replies")
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(line.headline, systemImage: line.symbol)
                            .font(.caption)
                            .foregroundStyle(NativeRCVColors.tone(line.tone))
                        Text(line.text).textSelection(.enabled)
                        if let detail = line.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var trail: some View {
        let lines = RCVPresentation.trail(event)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                NativeRCVHeading("What happened")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(lines) { line in
                        GridRow {
                            Text(line.time).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            Text(line.words).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        let pairs = RCVPresentation.fields(event)
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                NativeRCVHeading("Fields")
                NativeRCVPairs(pairs: pairs)
            }
        }
    }

    private var rawAndHeaders: some View {
        VStack(alignment: .leading, spacing: 8) {
            if event.status != .rejected {
                DisclosureGroup(isExpanded: $showRaw) {
                    VStack(alignment: .trailing, spacing: 6) {
                        let raw = RCVPresentation.prettyRaw(event.raw)
                        NativeRCVCopyButton(value: raw)
                        NativeRCVMonoBlock(text: raw)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("What arrived, exactly").font(.callout).foregroundStyle(.secondary)
                }
            }
            let headers = RCVPresentation.headers(event)
            if !headers.isEmpty {
                DisclosureGroup(isExpanded: $showHeaders) {
                    NativeRCVPairs(pairs: headers, monospaced: true).padding(.top, 6)
                } label: {
                    Text("Sender headers").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Name · value, two columns.
struct NativeRCVPairs: View {
    let pairs: [RCVPresentation.Pair]
    var monospaced = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(pairs) { pair in
                GridRow {
                    Text(pair.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text(pair.value)
                        .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Came from → Rule → Went to → Result, side by side when there is room.
private struct NativeRCVChain: View {
    let steps: [RCVPresentation.Step]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 22)
                    }
                    card(step).frame(minWidth: 104, maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary).padding(.leading, 14)
                    }
                    card(step)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where it went")
    }

    private func card(_ step: RCVPresentation.Step) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.label).font(.caption).foregroundStyle(.secondary)
            Label {
                Text(step.value).lineLimit(2)
            } icon: {
                Image(systemName: SymbolName.resolve(step.symbol, fallback: "circle"))
                    .foregroundStyle(NativeRCVColors.tone(step.tone))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(step.reached ? Color.primary : Color.secondary)
            if let detail = step.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Route to…

/// Send one event on by hand: to an agent, a running session or Hoot.
struct NativeRCVRouteSheet: View {
    let model: NativeRCVModel
    let eventID: String
    @State private var target = RCVTarget(kind: .hoot, id: "hoot")
    @State private var instruction = ""

    var body: some View {
        let event = model.event(eventID)
        VStack(spacing: 0) {
            NativeSettingsHead(title: "Route to…", blurb: event.map { "Send “\(RCVPresentation.title($0))” on by hand. No rule changes." })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                if let error = model.actionError { Section { NativeCodingAINotice(tone: .error, text: error) } }
                Section {
                    NativeRCVTargetFields(target: $target, agents: model.overview?.agents ?? [], sessions: model.overview?.sessions ?? [])
                }
                Section {
                    NativeSettingRow(label: "What to do", help: "Optional. Left empty, it is sent with its title and text.") {
                        EmptyView()
                    }
                    TextField("For example: Answer the customer and tell me what you said.", text: $instruction, axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            NativeRCVSheetBar {
                if model.busy == "route" { NativePageNote("Sending…", busy: true).frame(maxHeight: 24) }
            } trailing: {
                Button("Cancel") { model.openSheet(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { Task { await model.route(eventID, to: target, instruction: instruction) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy != nil || event == nil || (target.kind != .hoot && target.id.isEmpty))
            }
        }
        .frame(width: 560, height: 480)
    }
}

/// Who gets it: the kind, then the agent or session, and the conversation key for
/// an ongoing task. Shared by Route to… and the rule editor.
struct NativeRCVTargetFields: View {
    @Binding var target: RCVTarget
    let agents: [RCVChoice]
    let sessions: [RCVChoice]

    var body: some View {
        NativeSettingRow(label: "Send to", help: help) {
            Picker("Send to", selection: Binding(get: { target.kind }, set: { kind in
                guard kind != target.kind else { return }
                switch kind {
                case .hoot: target = RCVTarget(kind: .hoot, id: "hoot")
                case .agent: target = RCVTarget(kind: .agent, id: agents.contains { $0.id == target.id } ? target.id : "", threadKey: "{{fields.chat}}")
                case .newTask: target = RCVTarget(kind: .newTask, id: agents.contains { $0.id == target.id } ? target.id : "none")
                case .session: target = RCVTarget(kind: .session, id: "")
                }
            })) {
                // The shared row: Hoot's owl, and a plain mark for each other kind of place.
                ForEach(RCVTargetKind.allCases, id: \.self) { kind in DeckRowLabel(kind.title, image: Self.picture(kind)).tag(kind) }
            }
            .labelsHidden()
            .fixedSize()
        }
        switch target.kind {
        case .newTask:
            NativeSettingRow(label: "Assign to", help: "Leave the task in your task list, or give it to an agent.") {
                Picker("Assign to", selection: $target.id) {
                    DeckRowLabel("Task list", image: DeckRowIcon.symbolIcon("checklist")).tag("none")
                    ForEach(agents) { DeckRowLabel($0.name, image: DeckRowIcon.agent(id: $0.id)).tag($0.id) }
                    if !target.id.isEmpty && target.id != "none" && !agents.contains(where: { $0.id == target.id }) {
                        Text(target.id).tag(target.id)
                    }
                }.labelsHidden().fixedSize()
            }
        case .agent:
            NativeSettingRow(label: "Agent", help: agents.isEmpty ? "No task agents yet. Make one on the Tasks page." : nil) {
                choicePicker("Agent", agents, none: "Choose an agent")
            }
            if target.kind == .agent {
                NativeSettingRow(label: "Conversation", help: "Events with the same value here join one ongoing task, for example one chat. Empty: one task for the whole source.") {
                    TextField("{{fields.chat}}", text: Binding(get: { target.threadKey ?? "" }, set: { target.threadKey = $0.isEmpty ? nil : $0 }))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .frame(minWidth: 180, maxWidth: 240)
                }
            }
        case .session:
            NativeSettingRow(label: "Session", help: sessions.isEmpty ? "No AI session is running right now." : "Only AI sessions, never a plain shell.") {
                choicePicker("Session", sessions, none: "Choose a session")
            }
        case .hoot:
            EmptyView()
        }
    }

    private var help: String {
        switch target.kind {
        case .agent: "One ongoing task per conversation; later messages join it."
        case .newTask: "A new task every time."
        case .session: "Typed into a running AI session."
        case .hoot: "Hoot gets it as a task."
        }
    }

    private static func picture(_ kind: RCVTargetKind) -> NSImage {
        switch kind {
        case .hoot: DeckRowIcon.hoot
        case .agent: DeckRowIcon.symbolIcon("person.crop.circle")
        case .newTask: DeckRowIcon.symbolIcon("checklist")
        case .session: DeckRowIcon.session
        }
    }

    private func choicePicker(_ label: String, _ choices: [RCVChoice], none: String) -> some View {
        Picker(label, selection: $target.id) {
            Text(none).tag("")
            if !target.id.isEmpty && !choices.contains(where: { $0.id == target.id }) {
                Text(target.id).tag(target.id)
            }
            ForEach(choices) { choice in
                DeckRowLabel(choice.name, image: label == "Agent" ? DeckRowIcon.agent(id: choice.id) : DeckRowIcon.session(id: choice.id)).tag(choice.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}
/// The Events view keeps its selection in the existing Receiver model.
struct NativeRCVEventsPage: View {
    @Bindable var model: NativeRCVModel
    private var events: [RCVEvent] { model.visibleEvents.filter { model.projectFilter == nil || $0.projectID == model.projectFilter } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search events", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Button { model.statusFilter = model.statusFilter == .unrouted ? nil : .unrouted; model.search() } label: {
                    Text("Not routed").padding(.horizontal, 10).frame(height: 28)
                        .background(model.statusFilter == .unrouted ? Color.primary.opacity(0.1) : Color.primary.opacity(0.04), in: .capsule)
                }.buttonStyle(.plain)
                Spacer()
            }
            Table(events, selection: Binding(get: { model.selectedEventID }, set: { model.select($0) })) {
                TableColumn("Time") { event in Text(Date(timeIntervalSince1970: event.receivedAt / 1000), style: .time).font(.caption).monospacedDigit() }.width(85)
                TableColumn("Source") { event in Text(RCVPresentation.sourceName(event.sourceId, in: model.sources)).lineLimit(1) }.width(min: 110, ideal: 150)
                TableColumn("Project") { event in Text(PROJProjects.name(for: event.projectID, projects: model.projects)).lineLimit(1) }.width(100)
                TableColumn("Summary") { event in Text(RCVPresentation.title(event)).lineLimit(1) }
                TableColumn("Routed to") { event in Text(model.overview.flatMap { RCVPresentation.route(event, rules: $0.rules, agents: $0.agents, sessions: $0.sessions) } ?? "—").lineLimit(1) }.width(min: 120, ideal: 180)
                TableColumn("Status") { event in NativeRCVStatusLabel(word: RCVPresentation.word(event.status), symbol: RCVPresentation.symbol(event.status), tone: RCVPresentation.tone(event.status)) }.width(110)
            }.frame(minHeight: 360)
        }
        .onChange(of: model.query) { _, _ in model.search() }
        .inspector(isPresented: Binding(get: { model.selectedEventID != nil }, set: { if !$0 { model.select(nil) } })) {
            if let event = model.selectedEvent, let overview = model.overview {
                NativeRCVEventDetail(model: model, event: event, overview: overview).padding(16).inspectorColumnWidth(min: 300, ideal: 380, max: 480)
            }
        }
    }
}

/// Sources → Rules → destinations. The page owns scrolling and window bounds.
struct NativeRCVFlowGraph: View {
    let model: NativeRCVModel
    var openTarget: @MainActor (RCVTarget) -> Void = NativeRCVTargets.open
    private var sources: [RCVSourceView] { model.sources.filter { model.projectFilter == nil || $0.source.effectiveProjectScope == .all || $0.source.projectID == model.projectFilter } }
    private var rules: [RCVRule] { model.rules.filter { $0.sourceIds.isEmpty || $0.sourceIds.contains(where: { id in sources.contains { $0.id == id } }) } }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Sources", count: sources.count) {
                ForEach(sources) { source in
                    node(source.source.name, symbol: NativeRCVSourceType.of(source.source).symbol, detail: "\(source.eventCount) events") { NativeRCVSourceWindows.shared.open(model: model, view: source) }
                }
            }
            connector
            column("Rules", count: rules.count) {
                ForEach(rules) { rule in
                    node(rule.name, symbol: "line.3.horizontal.decrease", detail: rule.enabled ? "On" : "Paused") { model.openSheet(.rule(rule, isNew: false)) }
                }
                Button("Add a rule") { model.openSheet(.rule(RCVPresentation.newRule(), isNew: true)) }.buttonStyle(.bordered)
            }
            connector
            column("Agents and sessions", count: RCVPresentation.distinctTargets(in: rules).count) {
                ForEach(Array(RCVPresentation.distinctTargets(in: rules).enumerated()), id: \.offset) { _, target in
                    node(destination(target), symbol: target.kind == .session ? "terminal" : "person.crop.circle", detail: target.kind == .newTask && target.id == "none" ? "Task list" : target.kind.title) {
                        openTarget(target)
                    }
                }
            }
        }
    }
    private var connector: some View { VStack { Spacer().frame(height: 46); Rectangle().fill(.tertiary).frame(width: 16, height: 1); Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption) }.frame(width: 16) }
    private func destination(_ target: RCVTarget) -> String {
        if target.kind == .newTask && target.id == "none" { return "Task list" }
        return RCVPresentation.targetName(target, agents: model.overview?.agents ?? [], sessions: model.overview?.sessions ?? [])
    }
    private func column<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            content()
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func node(_ title: String, symbol: String, detail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) { Text(title).fontWeight(.semibold).lineLimit(1); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(.rect)
        }.buttonStyle(NativeRCVRowStyle()).background(NativeRCVSurface.card, in: .rect(cornerRadius: 12)).contextMenu { Button("Open", action: open) }
    }
}

@MainActor enum NativeRCVTargets {
    static func open(_ target: RCVTarget) {
        switch target.kind {
        case .session: AppModel.shared.selectTab(target.id)
        case .agent:
            AGTAgentsStore.shared.openProfile = target.id
            AppModel.shared.select("agents-all")
        case .newTask: AppModel.shared.select("tasks")
        case .hoot: AppModel.shared.select("hoot")
        }
    }
}
