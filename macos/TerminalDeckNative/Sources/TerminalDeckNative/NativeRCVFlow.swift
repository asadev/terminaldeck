import SwiftUI
import TerminalDeckNativeCore

/// Flow (and Unrouted): everything that came in, newest first, beside the chosen
/// event — where it came from, which rule took it, where it went and what came back.
struct NativeRCVFlowPage: View {
    @Bindable var model: NativeRCVModel

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                filterBar
                if geometry.size.width >= 860 {
                    HStack(alignment: .top, spacing: 16) {
                        list.frame(width: min(460, geometry.size.width * 0.46))
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        list.frame(height: max(180, geometry.size.height * 0.4))
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .onChange(of: model.query) { _, _ in model.search() }
        .onChange(of: model.sourceFilter) { _, _ in model.search() }
        .onChange(of: model.statusFilter) { _, _ in model.search() }
    }

    // MARK: Search and filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.place == .unrouted ? "Search what no rule took" : "Search what came in", text: $model.query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            .frame(maxWidth: 420)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search the Receiver")

            Picker("Source", selection: $model.sourceFilter) {
                Text("All sources").tag(String?.none)
                Divider()
                ForEach(model.sources) { view in
                    Text(view.source.name).tag(String?.some(view.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Show one source")

            if model.place == .flow {
                Picker("Status", selection: $model.statusFilter) {
                    Text("Any status").tag(RCVStatus?.none)
                    Divider()
                    ForEach(RCVPresentation.statuses, id: \.self) { status in
                        Text(RCVPresentation.word(status)).tag(RCVStatus?.some(status))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(model.statusFilter.map(RCVPresentation.meaning) ?? "Show one status")
            }

            if model.narrowed && model.place == .flow {
                Text("\(model.visibleEvents.count) shown").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Button("Show everything") { model.showEverything() }
            }
            Spacer(minLength: 0)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh")
        }
    }

    // MARK: The list

    @ViewBuilder private var list: some View {
        let events = model.visibleEvents
        if events.isEmpty {
            let empty = model.place == .unrouted && !model.narrowedBeyondPlace
                ? RCVPresentation.emptyUnrouted
                : RCVPresentation.emptyFlow(hasOwnSources: RCVPresentation.hasOwnSources(model.sources), narrowed: model.narrowedBeyondPlace)
            NativePageEmpty(symbol: empty.symbol, title: empty.title, action: emptyAction(empty)) {
                Text(empty.message)
            }
        } else if let overview = model.overview {
            TimelineView(.everyMinute) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(RCVPresentation.rows(events, overview: overview)) { row in
                            NativeRCVFlowRow(row: row, now: context.date, selected: model.selectedEventID == row.id) {
                                model.select(row.id)
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            .accessibilityLabel(model.place == .unrouted ? "Unrouted events" : "Received events")
        }
    }

    private func emptyAction(_ empty: RCVPresentation.Empty) -> PageEmptyAction? {
        guard let label = empty.action else { return nil }
        if label == "Add a source" { return PageEmptyAction(label: label, primary: true, perform: { model.openSheet(.addSource) }) }
        return PageEmptyAction(label: label, perform: { model.showEverything() })
    }

    // MARK: The chosen event

    @ViewBuilder private var detail: some View {
        if let event = model.selectedEvent, let overview = model.overview {
            NativeRCVEventDetail(model: model, event: event, overview: overview)
                .id(event.id)
        } else if !model.visibleEvents.isEmpty {
            let empty = RCVPresentation.noSelection
            NativePageEmpty(symbol: empty.symbol, title: empty.title) { Text(empty.message) }
        }
    }
}

extension NativeRCVModel {
    /// Narrowed by the search or the filters (Unrouted itself is not "narrowed").
    var narrowedBeyondPlace: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceFilter != nil || (place == .flow && statusFilter != nil)
    }
}

/// One compact row: source symbol · title · time, then source · type → rule → target · status.
private struct NativeRCVFlowRow: View {
    let row: RCVPresentation.Row
    let now: Date
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: SymbolName.resolve(row.sourceSymbol, fallback: "arrow.down.circle"))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(RCVPresentation.relative(row.at, now: now))
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit().fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(row.sourceName) · \(row.kind)").lineLimit(1).layoutPriority(1)
                        if let route = row.route { Text(route).lineLimit(1).truncationMode(.tail) }
                        Spacer(minLength: 6)
                        NativeRCVStatusLabel(word: row.statusWord, symbol: row.statusSymbol, tone: row.tone)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .modifier(NativeRCVPick(selected: selected))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), from \(row.sourceName), \(row.statusWord)")
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
                .fixedSize(horizontal: false, vertical: true)
            Text("\(RCVPresentation.sourceName(event.sourceId, in: overview.sources)) · \(event.kind) · \(event.severity.rawValue) · \(RCVPresentation.relative(event.receivedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !event.text.isEmpty && event.text != event.title {
                Text(event.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
                        Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                            Text(line.words).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                Text(step.value).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: SymbolName.resolve(step.symbol, fallback: "circle"))
                    .foregroundStyle(NativeRCVColors.tone(step.tone))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(step.reached ? Color.primary : Color.secondary)
            if let detail = step.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                case .newTask: target = RCVTarget(kind: .newTask, id: agents.contains { $0.id == target.id } ? target.id : "")
                case .session: target = RCVTarget(kind: .session, id: "")
                }
            })) {
                ForEach(RCVTargetKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .labelsHidden()
            .fixedSize()
        }
        switch target.kind {
        case .agent, .newTask:
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

    private func choicePicker(_ label: String, _ choices: [RCVChoice], none: String) -> some View {
        Picker(label, selection: $target.id) {
            Text(none).tag("")
            if !target.id.isEmpty && !choices.contains(where: { $0.id == target.id }) {
                Text(target.id).tag(target.id)
            }
            ForEach(choices) { choice in Text(choice.name).tag(choice.id) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
