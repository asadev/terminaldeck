import Charts
import SwiftUI
import TerminalDeckNativeCore

/// What the page hands over when it opens the Session inspector.
struct SessionInspectorRequest: Decodable, Equatable {
    struct Scope: Decodable, Equatable {
        let startedAt: Double
        let resumed: Bool?
        let agentSessionId: String?
    }
    let cwd: String?
    let title: String?
    let transcriptPath: String?
    let session: Scope?
}

/// The Session inspector (`SessionInspector.tsx`): the session in front of you,
/// read off its transcript — six figures across the top (Requests, Prompt,
/// Output, Tools, Context, Elapsed), then Timeline, Usage, Tools and Context —
/// with Refresh and Done at the foot. The transcript is the session's own when
/// one can be told apart (`attributeTranscript`), else the folder's newest.
struct NativeSessionInspector: View {
    let request: SessionInspectorRequest
    let close: () -> Void

    enum Load: Equatable {
        case loading
        case ready(SessionInsights)
        case empty
        case error(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case timeline = "Timeline", usage = "Usage", tools = "Tools", context = "Context"
        var id: String { rawValue }
    }

    @State private var state: Load = .loading
    @State private var tab: Tab = .timeline
    @State private var attribution: String?
    @State private var nonce = 0

    private var insights: SessionInsights? {
        if case .ready(let value) = state { return value }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session inspector").font(.title3.weight(.semibold))
                    if let line = InsightsFormat.source(title: request.title, insights: insights,
                                                        attribution: request.transcriptPath != nil ? "session" : attribution) {
                        Text(line).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                // The page dialog's close button (`Modal` .modal-close).
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary.opacity(0.6), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close dialog")
                .accessibilityLabel("Close dialog")
            }
            .padding(20)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Text(insights.map { "Read \(InsightsFormat.clock($0.generatedAt))" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { nonce += 1 }.disabled(state == .loading)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
                // Esc, as the page's dialog closes on it: a sheet with nothing focused
                // never sees an exit command, but a cancel-action shortcut always fires.
                Button("Close dialog", action: close)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: insights == nil ? 460 : 760, height: insights == nil ? 220 : 640)
        .task(id: nonce) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            message("Reading the transcript…")
        case .error(let why):
            message("Could not read this session: \(why)", warn: true)
        case .empty:
            message(request.session != nil
                    ? "No transcript yet — one appears with the session’s first request."
                    : "No transcript for this folder yet — one appears with a session’s first request.")
        case .ready(let insights):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 0) {
                    Stat(label: "Requests", value: "\(Int(insights.requests))")
                    Stat(label: "Prompt", value: InsightsFormat.tokens(insights.usage.prompt),
                         hint: "Every prompt token the session sent, cache reads and writes included — not the uncached remainder the API reports as input.")
                    Stat(label: "Output", value: InsightsFormat.tokens(insights.usage.output), hint: "Output tokens across the session.")
                    Stat(label: "Tools", value: "\(Int(insights.toolCalls))")
                    Stat(label: "Context", value: insights.context.map { InsightsFormat.percent($0.percent, digits: 0) } ?? "—")
                    Stat(label: "Elapsed", value: InsightsFormat.duration(insights.durationMs),
                         hint: "\(InsightsFormat.duration(insights.generatingMs)) of it generating.")
                }
                Picker("Session detail", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).nativeUIGGreyControl()
                .labelsHidden()
                ScrollView {
                    Group {
                        switch tab {
                        case .timeline: TimelineTab(insights: insights)
                        case .usage: UsageTab(insights: insights)
                        case .tools: ToolsTab(insights: insights)
                        case .context: ContextTab(insights: insights)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }

    private func message(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .padding(20)
    }

    // MARK: Loading

    private func load() async {
        state = .loading
        if let path = request.transcriptPath, !path.isEmpty {
            state = await read("insights:session", path)
            return
        }
        guard let cwd = request.cwd, !cwd.isEmpty else {
            state = .empty
            return
        }
        guard let scope = request.session else {
            attribution = "project"
            state = await read("insights:latest", cwd)
            return
        }
        // The session's own transcript, looked for again every few seconds until one
        // appears (`useSessionTranscript`'s WAIT_MS), as the page does.
        while !Task.isCancelled {
            let files = BoardRules.transcriptFiles(try? await EngineBridge.shared.invoke("insights:list", [cwd]))
            let verdict = TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: scope.startedAt, resumed: scope.resumed == true,
                                                                                 agentSessionId: scope.agentSessionId))
            if case .choice(let path, _, let how) = verdict {
                attribution = how
                state = await read("insights:session", path)
                return
            }
            state = .empty
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func read(_ channel: String, _ arg: String) async -> Load {
        do {
            let raw = try await EngineBridge.shared.invoke(channel, [arg])
            guard let insights = SessionInsights.decode(raw) else { return .empty }
            return .ready(insights)
        } catch {
            return .error((error as? EngineWireError)?.description ?? String(describing: error))
        }
    }
}

// MARK: - Pieces

private struct Stat: View {
    let label: String
    let value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).help(hint ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Meter: View {
    let percent: Double
    var level = "ok"

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: box.size.width * min(100, max(0, percent)) / 100)
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        level == "critical" ? .red : level == "warning" ? .orange : .accentColor
    }
}

private struct Chip: View {
    let text: String
    var accent = false
    var quiet = false
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(accent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(quiet ? 0.08 : 0.16), in: .capsule)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.headline).padding(.top, 4) }
}

// MARK: - Tabs

private struct TimelineTab: View {
    let insights: SessionInsights
    static let page = 80
    @State private var visible = TimelineTab.page

    var body: some View {
        let rows = Array(insights.timeline.suffix(visible))
        let hidden = insights.timeline.count - rows.count
        if insights.timeline.isEmpty {
            Text("No API requests in this transcript yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if hidden > 0 || insights.omittedRequests > 0 {
                    HStack(spacing: 8) {
                        if hidden > 0 {
                            Button("Show \(min(Self.page, hidden)) earlier") { visible += Self.page }
                        }
                        Text("Showing requests \(rows.first?.index ?? 0)–\(rows.last?.index ?? 0) of \(Int(insights.requests))"
                             + (insights.omittedRequests > 0 ? ". The first \(Int(insights.omittedRequests)) are summarised in the totals but not listed." : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows) { entry in
                    row(entry)
                    ForEach(Array(insights.compactions.filter { $0.afterRequest == entry.index }.enumerated()), id: \.offset) { _, marker in
                        Text("Compacted (\(marker.trigger)) — \(InsightsFormat.tokens(marker.preTokens)) down to \(InsightsFormat.tokens(marker.postTokens)), \(InsightsFormat.tokens(marker.reclaimedTokens)) reclaimed in \(InsightsFormat.duration(marker.durationMs)).")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 36)
                    }
                }
            }
            .onChange(of: insights.generatedAt) { visible = Self.page }
        }
    }

    private func row(_ entry: TimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(entry.index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(InsightsFormat.clock(entry.at, withDate: insights.dated)).font(.caption.monospacedDigit())
                    Chip(text: InsightsFormat.modelName(entry.model)).help(InsightsFormat.modelHint(entry.model) ?? "")
                    if entry.fast { Chip(text: "fast", accent: true) }
                    if entry.isSidechain { Chip(text: "sub-agent") }
                    if entry.stopReason == "end_turn" { Chip(text: "end of turn", quiet: true) }
                }
                if !entry.tools.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(entry.tools.enumerated()), id: \.offset) { _, tool in
                            Chip(text: InsightsFormat.toolName(tool), quiet: true).help(tool)
                        }
                    }
                }
                HStack(spacing: 14) {
                    fact("Prompt", InsightsFormat.tokens(entry.promptTokens))
                    fact("Output", InsightsFormat.tokens(entry.outputTokens))
                    fact("Generated in", InsightsFormat.duration(entry.streamMs))
                        .help("Span across the request's own transcript lines — a lower bound.")
                    fact("Waited", InsightsFormat.duration(entry.sinceLastMs))
                        .help("Gap since the previous request finished: tools running, or you thinking.")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(InsightsFormat.tokens(entry.totalTokens)).font(.callout.monospacedDigit()).help("Prompt and output together.")
                if let ctx = entry.contextPercent {
                    Text("\(InsightsFormat.percent(ctx)) ctx").font(.caption.monospacedDigit())
                        .foregroundStyle(InsightsFormat.level(ctx) == "ok" ? Color.secondary : (InsightsFormat.level(ctx) == "critical" ? Color.red : Color.orange))
                }
            }
        }
        .padding(8)
        .background(entry.isSidechain ? Color.secondary.opacity(0.06) : Color.clear, in: .rect(cornerRadius: 6))
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

private struct UsageTab: View {
    let insights: SessionInsights

    var body: some View {
        let usage = insights.usage
        let total = usage.total
        let parts = [("Output", usage.output), ("Cache writes", usage.cacheWrite5m + usage.cacheWrite1h),
                     ("Cache reads", usage.cacheRead), ("Fresh input", usage.input)].sorted { $0.1 > $1.1 }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Where the tokens went")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { head("Line item"); head("Tokens"); head("Share") }
                ForEach(parts, id: \.0) { part in
                    GridRow {
                        Text(part.0)
                        Text(InsightsFormat.tokens(part.1)).monospacedDigit()
                        Meter(percent: total > 0 ? part.1 / total * 100 : 0).frame(width: 160)
                    }
                }
            }
            Text("\(InsightsFormat.percent(insights.cacheHitRate * 100)) of the prompt came from cache.")
                .font(.caption).foregroundStyle(.secondary)
                .help("Fresh input is only the part of a prompt that was neither written to cache nor read from it. On a warm session that is a few hundred tokens against a prompt of hundreds of thousands.")
            SectionTitle(text: "By model")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { head("Model"); head("Requests"); head("Prompt"); head("Output"); head("Share") }
                ForEach(insights.models) { model in
                    GridRow {
                        Text(InsightsFormat.modelName(model.model)).help(InsightsFormat.modelHint(model.model) ?? "")
                        Text("\(Int(model.requests))").monospacedDigit()
                        Text(InsightsFormat.tokens(model.promptTokens)).monospacedDigit()
                        Text(InsightsFormat.tokens(model.outputTokens)).monospacedDigit()
                        Meter(percent: model.share * 100).frame(width: 120)
                    }
                }
            }
            if !insights.heaviest.isEmpty {
                SectionTitle(text: "Largest requests")
                ForEach(insights.heaviest) { entry in
                    HStack(spacing: 10) {
                        Text("#\(entry.index)").monospacedDigit()
                        Text(InsightsFormat.clock(entry.at, withDate: insights.dated)).foregroundStyle(.secondary)
                        Text("\(InsightsFormat.tokens(entry.promptTokens)) prompt · \(InsightsFormat.tokens(entry.outputTokens)) out")
                        Spacer()
                        Text(InsightsFormat.tokens(entry.totalTokens)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct ToolsTab: View {
    let insights: SessionInsights

    var body: some View {
        if insights.tools.isEmpty {
            Text("This session has not called a tool.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Stat(label: "Tool calls", value: "\(Int(insights.toolCalls))")
                    Stat(label: "Failures", value: "\(Int(insights.toolFailures)) (\(InsightsFormat.percent(insights.toolCalls > 0 ? insights.toolFailures / insights.toolCalls * 100 : 0)))")
                    Stat(label: "Distinct tools", value: "\(insights.tools.count)", hint: "Counted by tool name, MCP tools included.")
                    Stat(label: "In tools", value: InsightsFormat.duration(insights.toolMs), hint: "Summed call-to-result elapsed time.")
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { head("Tool"); head("Calls"); head("Failed"); head("Avg"); head("Slowest"); head("Share") }
                    ForEach(insights.tools) { tool in
                        GridRow {
                            HStack(spacing: 4) {
                                Text(InsightsFormat.toolName(tool.name)).help(tool.name)
                                if let server = tool.server { Chip(text: server, quiet: true) }
                            }
                            Text("\(Int(tool.calls))").monospacedDigit()
                            Text(tool.failures > 0 ? "\(Int(tool.failures))" : "—").monospacedDigit()
                                .foregroundStyle(tool.failures > 0 ? Color.red : Color.primary)
                                .help(tool.failures > 0 ? "\(InsightsFormat.percent(tool.failures / tool.calls * 100)) of its calls" : "")
                            Text(tool.timedCalls > 0 ? InsightsFormat.duration(tool.avgMs) : "—").monospacedDigit()
                            Text(tool.timedCalls > 0 ? InsightsFormat.duration(tool.maxMs) : "—").monospacedDigit()
                            Meter(percent: tool.share * 100).frame(width: 100)
                        }
                    }
                }
                Text("Wall clock, so time spent waiting on you counts.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContextTab: View {
    let insights: SessionInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Context window")
            if let context = insights.context {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(InsightsFormat.percent(context.percent)).font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.level == "critical" ? Color.red : context.level == "warning" ? Color.orange : Color.primary)
                    Text("\(InsightsFormat.tokens(context.tokens)) of \(InsightsFormat.tokens(context.window)) · \(InsightsFormat.tokens(context.remaining)) left")
                        .foregroundStyle(.secondary)
                }
                Meter(percent: context.percent, level: context.level)
                if context.percent > 100 {
                    Text("Over the window — the bar stops at 100%, the number does not.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No request has reported a prompt size yet.").font(.callout).foregroundStyle(.secondary)
            }
            if insights.contextSeries.count > 1 {
                SectionTitle(text: "How it filled")
                ContextChart(series: insights.contextSeries)
            }
            SectionTitle(text: "Fixed prefix")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(InsightsFormat.tokens(insights.preContextTokens)).font(.title2.weight(.semibold).monospacedDigit())
                Text(insights.context.map { $0.window > 0 ? "\(InsightsFormat.percent(insights.preContextTokens / $0.window * 100)) of the window" : "system prompt, instructions file and tool schemas" }
                     ?? "system prompt, instructions file and tool schemas")
                    .foregroundStyle(.secondary)
            }
            Text("Every turn re-pays it, so it is the one number worth trimming.")
                .font(.caption).foregroundStyle(.secondary).help("Usually your instructions file and MCP tool schemas.")
            if !insights.warnings.isEmpty {
                SectionTitle(text: "Warnings")
                ForEach(insights.warnings) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(warning.level == "critical" ? Color.red : Color.orange)
                }
            }
            SectionTitle(text: "Compactions")
            if insights.compactions.isEmpty {
                Text("Not compacted yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(insights.compactions.enumerated()), id: \.offset) { _, marker in
                    HStack(spacing: 10) {
                        Text(InsightsFormat.clock(marker.at, withDate: insights.dated))
                        Text(marker.trigger).foregroundStyle(.secondary)
                        Text("\(InsightsFormat.tokens(marker.preTokens)) → \(InsightsFormat.tokens(marker.postTokens))")
                        Spacer()
                        Text("−\(InsightsFormat.tokens(marker.reclaimedTokens)) in \(InsightsFormat.duration(marker.durationMs))")
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// `ContextChart`: context per request, the peak marked, the hovered request read out.
private struct ContextChart: View {
    let series: [ContextPoint]
    @State private var hover: Int?

    var body: some View {
        let points = InsightsFormat.downsample(series, target: 160)
        let peak = points.max { $0.percent < $1.percent } ?? points[0]
        let top = InsightsFormat.axisMax(peak.percent)
        if top <= 0 {
            Text("No request has reported a prompt size yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            let level = InsightsFormat.level(peak.percent)
            let tint: Color = level == "critical" ? .red : level == "warning" ? .orange : .accentColor
            let hovered = hover.flatMap { at in points.first { $0.index == at } }
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(points, id: \.index) { point in
                        AreaMark(x: .value("Request", point.index), y: .value("Context", min(top, point.percent)))
                            .foregroundStyle(tint.opacity(0.15))
                        LineMark(x: .value("Request", point.index), y: .value("Context", min(top, point.percent)))
                            .foregroundStyle(tint)
                    }
                    PointMark(x: .value("Request", peak.index), y: .value("Context", min(top, peak.percent))).foregroundStyle(tint)
                    if let hovered {
                        RuleMark(x: .value("Request", hovered.index)).foregroundStyle(.secondary)
                        PointMark(x: .value("Request", hovered.index), y: .value("Context", min(top, hovered.percent))).foregroundStyle(.primary)
                    }
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(values: [0, top / 2, top]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(InsightsFormat.axisLabel(value.as(Double.self) ?? 0)) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: [points.first!.index, points.last!.index]) { value in
                        AxisValueLabel { Text("request \(value.as(Int.self) ?? 0)") }
                    }
                }
                .chartOverlay { proxy in
                    Rectangle().fill(.clear).contentShape(.rect)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let at):
                                if let x: Int = proxy.value(atX: at.x) {
                                    hover = points.min { abs($0.index - x) < abs($1.index - x) }?.index
                                }
                            case .ended:
                                hover = nil
                            }
                        }
                }
                .frame(height: 160)
                Group {
                    if let hovered {
                        Text("Request \(hovered.index) — \(InsightsFormat.percent(hovered.percent)) of the window, \(InsightsFormat.tokens(hovered.tokens)) in the prompt.")
                    } else {
                        Text("Context per request across the session — peak \(InsightsFormat.percent(peak.percent)) at request \(peak.index). The axis tops out at \(InsightsFormat.axisLabel(top)) of the window.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private func head(_ text: String) -> some View {
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
}
