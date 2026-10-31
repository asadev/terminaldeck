import AppKit
import SwiftUI
import TerminalDeckNativeCore

// DEPLOY-PIPELINE views, all from one record (DeployBoard) and these shared parts:
// - the project page's Deployments card: the live run as a step pipeline, then the history (the only history);
// - the side-panel pill while anything deploys (opens the project's card);
// - beside where the person asked: a slim panel at the right of Hoot's chat, or a strip at the top of the session.
// Every step shown is one that was reported or detected for that run: no fixed list of steps or tools.

// MARK: One step

/// A step's state as a small mark: a tick, a spinner, a cross, an empty ring (waiting), a dash (skipped).
struct DeployStateMark: View {
    let state: DeployState
    var stopped = false
    var body: some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark").foregroundStyle(DeckTokens.good)
            case .running: ProgressView().controlSize(.mini)
            case .failed: Image(systemName: "xmark").foregroundStyle(DeckTokens.bad)
            case .waiting: Image(systemName: stopped ? "minus" : "circle").foregroundStyle(DeckTokens.textTertiary)
            case .skipped: Image(systemName: "minus").foregroundStyle(DeckTokens.textTertiary)
            }
        }
        .font(.system(size: 10, weight: .bold)).frame(width: 14, height: 14)
        .accessibilityLabel(stopped ? "not run" : state.rawValue)
    }
}

/// What a click on a step shows: its tool, times, result in full, the log excerpt and the link.
struct DeployStepDetail: View {
    let step: DeployStep
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: step.symbol).foregroundStyle(.secondary)
                Text(step.name).font(.headline)
                Spacer(minLength: 8)
                DeployStateMark(state: step.state)
            }
            if let tool = step.tool { Text(tool).font(.callout).foregroundStyle(.secondary) }
            if let line = step.line {
                Text(line).font(.callout).foregroundStyle(step.state == .failed ? DeckTokens.bad : .primary).textSelection(.enabled)
            }
            if let times = DeployText.times(step) { Text(times).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            if let log = step.log {
                ScrollView {
                    Text(log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 180)
                .background(DeckTokens.page, in: .rect(cornerRadius: 6))
            }
            if let link = step.link, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }.buttonStyle(.bordered)
            }
        }
        .padding(14).frame(width: 340, alignment: .leading)
    }
}

/// One step in the horizontal pipeline: tool icon + name + mark, its result under it. Click: the step's details.
struct DeployStepChip: View {
    let step: DeployStep
    let current: Bool
    var stopped = false
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: step.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(step.name).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1)
                    DeployStateMark(state: step.state, stopped: stopped)
                }
                if let line = step.line {
                    Text(line).font(.system(size: 10.5)).lineLimit(1)
                        .foregroundStyle(step.state == .failed ? DeckTokens.bad : .secondary)
                } else if stopped {
                    Text("not run").font(.system(size: 10.5)).foregroundStyle(DeckTokens.textTertiary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6).frame(maxWidth: 220, alignment: .leading)
            .background(current ? Color.accentColor.opacity(0.12) : DeckTokens.page, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Color.accentColor.opacity(0.6) : DeckTokens.hairline, lineWidth: 1))
            .opacity(stopped || step.state == .skipped ? 0.55 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help((step.tool.map { $0 + " · " } ?? "") + (step.line ?? step.name))
        .popover(isPresented: $showing, arrowEdge: .bottom) { DeployStepDetail(step: step) }
    }
}

/// The run's steps left to right, in the order they happened, the current one highlighted. Every step stays in
/// view: a row that runs out of room wraps onto the next line (Asad, 13 Oct: the flow "is not completely visible").
struct DeployPipeline: View {
    let run: DeployRun
    var body: some View {
        if run.steps.isEmpty {
            Text("Starting…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 2)
        } else {
            TasksFlow(spacing: 4, lineSpacing: 6) {
                ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 4) {
                        if index > 0 { Image(systemName: "chevron.compact.right").font(.system(size: 11)).foregroundStyle(DeckTokens.textTertiary) }
                        DeployStepChip(step: step, current: index == run.currentIndex, stopped: run.stopped(index))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// The same steps top to bottom, for the slim panel and an opened history row.
struct DeployStepList: View {
    let run: DeployRun
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                DeployStepRow(step: step, current: run.isLive && index == run.currentIndex, stopped: run.stopped(index))
            }
        }
    }
}

struct DeployStepRow: View {
    let step: DeployStep
    var current = false
    var stopped = false
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DeployStateMark(state: step.state, stopped: stopped)
                Image(systemName: step.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1)
                    if let line = step.line {
                        Text(line).font(.system(size: 11)).lineLimit(2).foregroundStyle(step.state == .failed ? DeckTokens.bad : .secondary)
                    } else if stopped { Text("not run").font(.system(size: 11)).foregroundStyle(DeckTokens.textTertiary) }
                }
                Spacer(minLength: 4)
                if let tool = step.tool { Text(tool).font(.system(size: 10.5)).foregroundStyle(DeckTokens.textTertiary).lineLimit(1) }
                if let span = step.duration { Text(DeployFormat.duration(span)).font(.system(size: 10.5)).foregroundStyle(DeckTokens.textTertiary).monospacedDigit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(current ? Color.accentColor.opacity(0.10) : .clear, in: .rect(cornerRadius: 6))
            .opacity(stopped || step.state == .skipped ? 0.55 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .leading) { DeployStepDetail(step: step) }
    }
}

// MARK: Who and what

/// Asad, 12 Oct: on top only which agent is doing it and what — the agent's picture and name, and one plain line.
struct DeployRunHeader: View {
    let run: DeployRun
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: DeployText.picture(run.by)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(DeployText.shortName(run.by)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(DeployText.what(run, project: DeployBoard.shared.projectName(run.projectID))).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A finished run in one line: "Deployed v… · 7 steps · 4 min" and Open in project.
struct DeployFoldedLine: View {
    let run: DeployRun
    var body: some View {
        HStack(spacing: 6) {
            DeployStateMark(state: run.state)
            Text(DeployText.folded(run)).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(run.state == .failed ? DeckTokens.bad : .primary)
            Spacer(minLength: 4)
            Button("Open in project") { DeployBoard.shared.open(run.projectID) }.buttonStyle(.link).font(.system(size: 12))
        }
    }
}

enum DeployText {
    @MainActor static func picture(_ actor: DeployActor) -> NSImage {
        if actor.kind == "hoot" { return DeckRowIcon.agent(id: "hoot") }
        if let agent = actor.agentID { return DeckRowIcon.agent(id: agent) }
        switch actor.kind {
        case "source": return DeckRowIcon.symbolIcon(DeployToolIcon.symbol(actor.name))
        case "session", "lead": return DeckRowIcon.symbolIcon("terminal")
        case "app": return DeckRowIcon.symbolIcon("app.connected.to.app.below.fill")
        default: return DeckRowIcon.symbolIcon("person.crop.circle")
        }
    }
    static func shortName(_ actor: DeployActor) -> String { actor.name }
    /// "Installing Terminal Deck build 1c29bb8b": the run's own words, else what its current step is doing.
    static func what(_ run: DeployRun, project: String) -> String {
        if let title = run.title, !title.isEmpty { return title }
        if let step = run.current { return step.name + " · " + project }
        return "Deploying " + project
    }
    static func folded(_ run: DeployRun) -> String {
        let verb = run.state == .done ? "Deployed" : run.state == .failed ? "Failed" : "Cancelled"
        var parts = [verb + " " + run.label, "\(run.steps.count) step\(run.steps.count == 1 ? "" : "s")"]
        if let span = run.duration { parts.append(DeployFormat.duration(span)) }
        if run.state == .failed, let step = run.steps.first(where: { $0.state == .failed }) { parts.append("at " + step.name) }
        return parts.joined(separator: " · ")
    }
    static func times(_ step: DeployStep) -> String? {
        guard let start = step.startedAt else { return nil }
        let clock = Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)
        return clock + (step.duration.map { " · took " + DeployFormat.duration($0) } ?? "")
    }
    static func when(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(.relative(presentation: .named))
    }
}

// MARK: The project page's Deployments card

struct DeploymentsCard: View {
    let project: PROJProject
    private var board: DeployBoard { .shared }
    @State private var opened: Set<String> = []
    @State private var showingAll = false

    var body: some View {
        let runs = board.ledger.runs(project: project.id)
        let now = DeployBoard.now
        let live = runs.filter { $0.isLive && now - $0.updatedAt < DeployLedger.quietAfter }
        let history = runs.filter { run in !live.contains { $0.id == run.id } }
        Group {
            if !runs.isEmpty || board.reading.contains(project.id) {
                PROJPAGECard {
                    HStack(spacing: 8) {
                        Text("Deployments").font(.headline)
                        if board.reading.contains(project.id) { ProgressView().controlSize(.mini) }
                        Spacer()
                        Button { Task { await board.sync(project) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Read GitHub Actions and the project's servers again")
                            .accessibilityLabel("Refresh deployments")
                    }
                    ForEach(live) { run in
                        VStack(alignment: .leading, spacing: 8) {
                            DeployRunHeader(run: run)
                            DeployPipeline(run: run)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.05), in: .rect(cornerRadius: 10))
                    }
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(showingAll ? history : Array(history.prefix(5))) { run in historyRow(run, now: now) }
                        }
                        if history.count > 5 {
                            Button(showingAll ? "Show fewer" : "Show all \(history.count)") { showingAll.toggle() }.buttonStyle(.link).font(.callout)
                        }
                    }
                }
            }
        }
        .task(id: project.id) { await board.sync(project) }
    }

    @ViewBuilder private func historyRow(_ run: DeployRun, now: Double) -> some View {
        let open = opened.contains(run.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { opened.remove(run.id) } else { opened.insert(run.id) }
            } label: {
                HStack(spacing: 8) {
                    DeployStateMark(state: run.isLive ? .waiting : run.state)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(run.label).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            if let title = run.title, title != run.label { Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Text(rowLine(run, now: now)).font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(run.state == .failed ? DeckTokens.bad : .secondary)
                    }
                    Spacer(minLength: 8)
                    Text(DeployText.when(run.startedAt)).font(.system(size: 11)).foregroundStyle(DeckTokens.textTertiary)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6).contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    DeployStepList(run: run)
                    if let link = run.link, let url = URL(string: link) {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.right.square") }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.leading, 22).padding(.bottom, 6)
            }
            Divider().opacity(0.5)
        }
    }

    /// "Done · 4 min · run by Release agent · asked via Hoot · 11 steps".
    private func rowLine(_ run: DeployRun, now: Double) -> String {
        var parts: [String] = []
        if run.isLive { parts.append("no news for \(DeployFormat.duration(now - run.updatedAt))") }
        else {
            parts.append(run.result.map { run.resultWord + ": " + $0 } ?? run.resultWord)
        }
        if let span = run.duration { parts.append(DeployFormat.duration(span)) }
        parts.append(run.byLine)
        parts.append("\(run.steps.count) step\(run.steps.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// The pill and "Open in project" bring the project's Overview up, where the Deployments card is.
    func deployFocus(_ projectID: String, show: @escaping () -> Void) -> some View {
        modifier(DeployFocusModifier(projectID: projectID, show: show))
    }
}

private struct DeployFocusModifier: ViewModifier {
    let projectID: String
    let show: () -> Void
    func body(content: Content) -> some View {
        content.task(id: DeployBoard.shared.focus) {
            guard DeployBoard.shared.focus == projectID else { return }
            show(); DeployBoard.shared.focus = nil
        }
    }
}

// MARK: The side-panel pill

/// "Deploying Terminal Deck · step 4 of 7 · Install" while anything deploys; nothing otherwise.
struct DeploySidebarPill: View {
    private var board: DeployBoard { .shared }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let names = Dictionary(SHELLRoutes.registry.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            if let pill = DeployPill.line(board.ledger, projectName: { names[$0] ?? $0 }, at: context.date.timeIntervalSince1970) {
                Button { board.open(pill.run.projectID) } label: {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(pill.text).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(pill.full + ". Click to open \(board.projectName(pill.run.projectID))'s deployments.")
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

// MARK: Beside where the person asked

/// The top of a session that asked for (or is) the deployment: the live run, folded to one line when it ends.
struct DeploySessionStrip: View {
    let sessionID: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let run = DeployBoard.shared.ledger.strip(forSession: sessionID, at: context.date.timeIntervalSince1970) {
                VStack(alignment: .leading, spacing: 6) {
                    if run.isLive {
                        DeployRunHeader(run: run)
                        DeployPipeline(run: run)
                    } else {
                        DeployFoldedLine(run: run)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                // On the session's own paper (its light or dark scheme), a shade apart from the terminal.
                .background(Color.primary.opacity(0.05))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1) }
            }
        }
    }
}

/// The slim panel at the right of Hoot's chat (Asad, 12 Oct: beside the chat, so the chat keeps going): runs asked for
/// in Hoot's chat while they go, then a few minutes folded. Two live runs stack. It can be folded away.
struct DeployHootPanel: View {
    @AppStorage("deploy.hootPanel.collapsed") private var collapsed = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let runs = DeployBoard.shared.ledger.hootPanel(at: context.date.timeIntervalSince1970)
            if !runs.isEmpty {
                HStack(spacing: 0) {
                    Divider()
                    if collapsed {
                        Button { collapsed = false } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "sidebar.right")
                                if runs.contains(where: \.isLive) { ProgressView().controlSize(.mini) }
                            }
                            .frame(width: 30).frame(maxHeight: .infinity, alignment: .top).padding(.top, 14).contentShape(.rect)
                        }
                        .buttonStyle(.plain).help("Show deployments").accessibilityLabel("Show deployments")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Deployments").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button { collapsed = true } label: { Image(systemName: "sidebar.right") }
                                    .buttonStyle(.borderless).help("Hide deployments").accessibilityLabel("Hide deployments")
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(runs) { run in
                                        VStack(alignment: .leading, spacing: 8) {
                                            if run.isLive {
                                                DeployRunHeader(run: run)
                                                DeployStepList(run: run)
                                            } else { DeployFoldedLine(run: run) }
                                        }
                                        .padding(10).background(DeckTokens.card, in: .rect(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DeckTokens.hairline, lineWidth: 1))
                                    }
                                }
                            }
                        }
                        .padding(12).frame(width: 280)
                    }
                }
            }
        }
    }
}
