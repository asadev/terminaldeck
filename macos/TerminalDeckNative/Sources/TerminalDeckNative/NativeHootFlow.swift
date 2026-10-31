import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Asad (12 Oct): "whenever AI is working … it should show a flow working … first thing whatever happened, next row next
// thing … what rule of ours is applied during the job and with green tick … specific skill has been applied and flow of
// the skill as well … any tool has been used … in a way that a human can easily understand … Once Hoot answers … folded
// back with that drop down button … a nicely, well organized table … including the other agents". Hoot's page only.
//
// Nothing here is guessed: tool rows are Hoot's own tool calls; a rule or skill step shows only when Hoot (or the agent)
// reported it with `flow.applied`; an agent shows when Hoot handed it a task or a session, from the app's task records.

/// One agent Hoot handed work to in this job, from the app's own task records and that agent's own reports.
struct HootFlowAgent: Equatable, Identifiable {
    var id: String
    var name: String
    /// The task's title (or the session's).
    var job: String
    /// When Hoot handed it over (the tool call's time), milliseconds.
    var handedAt: Double
    var finishedAt: Double?
    var working: Bool
    /// Where the task stands, in plain words ("Working", "Waiting to start", its status).
    var status: String = ""
    /// The agent's latest note on the task: what it did.
    var lastNote: String?
    var reports: [JobFlowEntry]
    var taskID: String?
}

/// One row of the flow, in plain words.
struct HootFlowLine: Equatable, Identifiable {
    enum Kind: Equatable { case tool, rule, skill, agent, agentDone }
    var id: String
    var kind: Kind
    /// "Hoot" or the agent's name.
    var who: String
    var title: String
    var detail: String?
    /// Milliseconds.
    var at: Double
    var running = false
    var failed = false
    /// The tool call behind it (its command and output open from the table).
    var rowID: String?
    var taskID: String?
    var badge: String {
        switch kind {
        case .tool: "Tool"
        case .rule: "Rule ✓"
        case .skill: "Skill"
        case .agent, .agentDone: "Agent"
        }
    }
}

enum HootFlow {
    static func bare(_ name: String) -> String { (name.components(separatedBy: "__").last ?? name).replacingOccurrences(of: ".", with: "_") }
    /// The tool a row really ran: a call through tools_run is the tool it named.
    static func toolName(_ row: HootChatRow) -> String {
        let name = bare(row.value["name"].string ?? "")
        if name == "tools_run", let inner = row.value["input"]["name"].string, !inner.isEmpty { return bare(inner) }
        return name
    }
    static func isReport(_ row: HootChatRow) -> Bool {
        row.kind == .toolCall && JobFlowWords.isReport(name: row.value["name"].string ?? "", input: row.value["input"])
    }
    /// Hoot's own Skill tool (Claude Code): the skill it opened.
    static func skillOpened(_ row: HootChatRow) -> String? {
        guard row.kind == .toolCall, bare(row.value["name"].string ?? "").lowercased() == "skill" else { return nil }
        let input = row.value["input"]
        return (input["skill"].string ?? input["command"].string ?? input["name"].string).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func failed(_ row: HootChatRow) -> Bool { row.value["isError"].bool == true || row.value["status"].string == "failed" }

    /// The flow of one job, oldest first. `live`: Hoot is still working on it.
    static func lines(_ rows: [HootChatRow], agents: [HootFlowAgent], live: Bool) -> [HootFlowLine] {
        var lines: [HootFlowLine] = []
        for row in rows where row.kind == .toolCall {
            let running = live && row.value["finished"].bool != true
            if isReport(row) {
                let args = JobFlowWords.arguments(row.value["input"]), said = JobFlowWords.text(row.value["output"])
                if let rule = args["rule"].string, !rule.isEmpty {
                    let reported = said.components(separatedBy: "\n").first { $0.hasPrefix(JobFlowWords.rulePrefix) }
                    let title = reported.map { String($0.dropFirst(JobFlowWords.rulePrefix.count)) } ?? DeckMemoryShortTitle.fallback(rule)
                    let isID = rule.range(of: #"^n-\d{8}-[a-z0-9]+$"#, options: .regularExpression) != nil
                    lines.append(.init(id: row.id + ":rule", kind: .rule, who: "Hoot", title: title,
                                       detail: isID ? "Note " + rule : rule, at: row.at, rowID: row.id))
                }
                if let skill = args["skill"].string, !skill.isEmpty {
                    let step = args["step"].number.map { Int($0) }
                    lines.append(.init(id: row.id + ":skill", kind: .skill, who: "Hoot",
                                       title: JobFlowWords.line(kind: .skill, title: skill, step: step, stepTitle: args["stepTitle"].string),
                                       detail: args["detail"].string, at: row.at, rowID: row.id))
                }
                continue
            }
            if let skill = skillOpened(row) {
                lines.append(.init(id: row.id, kind: .skill, who: "Hoot", title: "Using the skill " + skill, at: row.at, running: running, rowID: row.id))
                continue
            }
            guard HootStep.kind(row) != .plumbing else { continue }
            lines.append(.init(id: row.id, kind: .tool, who: "Hoot", title: HootStep.title(row, live: running), at: row.at,
                               running: running, failed: failed(row), rowID: row.id))
        }
        for agent in agents {
            lines.append(.init(id: "agent:" + agent.id, kind: .agent, who: "Hoot", title: "Gave \u{201C}\(agent.job)\u{201D} to \(agent.name)",
                               at: agent.handedAt, taskID: agent.taskID))
            for entry in agent.reports {
                lines.append(.init(id: "report:" + entry.id, kind: entry.kind == .rule ? .rule : .skill, who: agent.name,
                                   title: entry.kind == .rule ? entry.title : entry.line, detail: entry.full ?? entry.detail, at: entry.at, taskID: agent.taskID))
            }
            if let finished = agent.finishedAt {
                lines.append(.init(id: "done:" + agent.id, kind: .agentDone, who: agent.name, title: agent.name + " finished",
                                   detail: agent.lastNote, at: finished, taskID: agent.taskID))
            } else if agent.working {
                lines.append(.init(id: "working:" + agent.id, kind: .agentDone, who: agent.name, title: agent.name + " is working",
                                   detail: agent.lastNote, at: max(agent.handedAt, agent.reports.last?.at ?? 0) + 1, running: live, taskID: agent.taskID))
            }
        }
        // In the order it happened; ties keep the order they were found in.
        return lines.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// The calls that hand work out (a task planned, delegated, retried or reassigned; a session started or sent to).
    static let handingOut: Set<String> = ["tasks_plan", "tasks_delegate", "tasks_reassign", "tasks_retry", "tasks_local_change",
                                          "tasks_comment", "tasks_review", "sessions_start", "sessions_send"]
    /// The calls whose ANSWER names the work they made (a planned task, a delegated child, a new session). For the
    /// others only the task they were given counts, so a call that lists tasks never names them all.
    static let makesWork: Set<String> = ["tasks_plan", "tasks_delegate", "tasks_local_change", "sessions_start"]

    /// The agents of one job: tasks and sessions named by Hoot's hand-out calls, from the app's task list, with each
    /// agent's own reports (rules with a tick, skill steps) under it.
    static func agents(steps: [HootChatRow], tasks: [TaskRow], reports: [JobFlowEntry]) -> [HootFlowAgent] {
        let handed: [(text: String, at: Double)] = steps.compactMap { row in
            let name = toolName(row)
            guard row.kind == .toolCall, handingOut.contains(name) else { return nil }
            return (row.value["input"].compact + (makesWork.contains(name) ? "\n" + row.value["output"].compact : ""), row.at)
        }
        guard !handed.isEmpty else { return [] }
        var agents: [HootFlowAgent] = [], seen = Set<String>()
        // Work handed to an agent: never a task the person holds, Hoot's own, or nobody's.
        for task in tasks where !["me", "hoot", "none", ""].contains(task.assignee.lowercased()) {
            let keys = [task.id, task.externalTaskId].filter { $0.count >= 8 }
            guard let first = handed.first(where: { call in keys.contains { call.text.contains($0) } }), seen.insert(task.id).inserted else { continue }
            let mine = reports.filter { $0.task == task.id }
            // Finished only when the task says so; never guessed from a quiet session.
            let status = task.completedAt != nil ? "Finished" : task.process == .running ? "Working" : task.process == .queued ? "Waiting to start"
                : (task.crmStatus.isEmpty ? "Handed over" : task.crmStatus)
            agents.append(.init(id: task.id, name: task.agent.isEmpty ? "An agent" : task.agent, job: task.title, handedAt: first.at,
                                finishedAt: task.completedAt.map { max($0, first.at) }, working: task.process == .running || task.process == .queued,
                                status: status, lastNote: task.notes.last.map { String($0.text.prefix(240)) }, reports: mine, taskID: task.id))
        }
        // A session Hoot started itself (no task): its reports, by the session id the call answered with.
        let bySession = Dictionary(grouping: reports.filter { $0.task == nil }, by: \.session)
        for (session, entries) in bySession.sorted(by: { $0.key < $1.key }) {
            guard session.count >= 6, let first = handed.first(where: { $0.text.contains(session) }), seen.insert(session).inserted else { continue }
            agents.append(.init(id: session, name: entries.first?.who ?? "A session", job: entries.first?.who ?? "a session", handedAt: first.at,
                                finishedAt: nil, working: false, status: "Session", lastNote: nil, reports: entries))
        }
        return agents
    }

    /// "· 2 rules · 1 skill · 1 agent" after the folded line.
    static func counts(_ lines: [HootFlowLine], agents: Int) -> String {
        let rules = lines.filter { $0.kind == .rule }.count, skills = Set(lines.filter { $0.kind == .skill }.map(\.title)).count
        var parts: [String] = []
        if rules > 0 { parts.append(rules == 1 ? "1 rule" : "\(rules) rules") }
        if skills > 0 { parts.append(skills == 1 ? "1 skill step" : "\(skills) skill steps") }
        if agents > 0 { parts.append(agents == 1 ? "1 agent" : "\(agents) agents") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    static func time(_ at: Double) -> String {
        at > 0 ? Date(timeIntervalSince1970: at / 1000).formatted(date: .omitted, time: .standard) : ""
    }
}

/// The agents' reports, as the app keeps them, for every Hoot flow on screen. Refreshed when an agent reports.
@MainActor @Observable final class HootFlowReports {
    static let shared = HootFlowReports()
    private(set) var entries: [JobFlowEntry] = []
    @ObservationIgnored private var observer: NSObjectProtocol?
    private init() {}
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .jobFlowChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await HootFlowReports.shared.reload() }
        }
        Task { await reload() }
    }
    func reload() async { entries = await BackendJobFlowLog.shared.all() }
}

/// While Hoot works: the job as a live list, one plain row per thing, the current one with a spinner.
struct HootFlowLiveList: View {
    let lines: [HootFlowLine]
    static let shown = 3
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(lines) { line in
                        HootFlowLiveRow(line: line, current: line.id == lines.last(where: { $0.running })?.id).frame(height: 20).id(line.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(height: min(CGFloat(Self.shown) * 20 + CGFloat(Self.shown - 1) * 5, CGFloat(max(1, lines.count)) * 20 + CGFloat(max(0, lines.count - 1)) * 5))
            .onChange(of: lines.last?.id, initial: true) { if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently).accessibilityLabel("Current agent activity")
    }
}

struct HootFlowLiveRow: View {
    let line: HootFlowLine
    var current = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HootFlowIcon(line: line, current: current).frame(width: 14)
            Text(line.title).foregroundStyle(line.kind == .tool && !current ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .lineLimit(1).truncationMode(.middle)
            if line.who != "Hoot" { HootFlowWho(name: line.who) }
            Spacer(minLength: 8)
        }
        .font(.system(size: 12.5))
    }
}

struct HootFlowIcon: View {
    let line: HootFlowLine
    var current = false
    var body: some View {
        Group {
            if current || (line.running && line.kind != .tool) { ProgressView().controlSize(.mini) }
            else if line.failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            else {
                switch line.kind {
                case .rule: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skill: Image(systemName: "list.number").foregroundStyle(Color.accentColor)
                case .agent: Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.secondary)
                case .agentDone: Image(systemName: line.running ? "person.crop.circle" : "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
                case .tool: Image(systemName: "checkmark").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
    }
}

struct HootFlowWho: View {
    let name: String
    var body: some View {
        Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary.opacity(0.7), in: Capsule())
    }
}

/// After Hoot answers: the whole job as a table (time · who · what happened · kind), then one line per agent.
struct HootFlowTable: View {
    let lines: [HootFlowLine]
    let agents: [HootFlowAgent]
    let rows: [HootChatRow]
    var openTask: ((String) -> Void)? = nil
    @State private var detail: HootChatRow?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Time", "Who", "What happened", ""], id: \.self) { Text($0) }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(lines) { line in
                    GridRow {
                        Text(HootFlow.time(line.at)).monospacedDigit().foregroundStyle(.tertiary)
                        Text(line.who).foregroundStyle(line.who == "Hoot" ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary).lineLimit(1)
                        Button { open(line) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                HootFlowIcon(line: line).frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.title).foregroundStyle(.primary).lineLimit(2)
                                    if let more = line.detail, !more.isEmpty, more != line.title {
                                        Text(more).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                if line.rowID != nil || line.taskID != nil {
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                            }.contentShape(.rect)
                        }
                        .buttonStyle(.plain).disabled(line.rowID == nil && line.taskID == nil)
                        .popover(isPresented: Binding(get: { detail != nil && detail?.id == line.rowID }, set: { if !$0 { detail = nil } })) {
                            if let row = detail { HootStepDetails(row: row) }
                        }
                        Text(line.badge).font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(line.kind == .rule ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(line.kind == .rule ? AnyShapeStyle(Color.green.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                    }
                    .padding(.vertical, 6)
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 4)
            if !agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(agents) { agent in
                        Button { if let task = agent.taskID { openTask?(task) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: agent.finishedAt != nil ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                Text(agent.name).fontWeight(.medium)
                                Text(agent.job).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 8)
                                let rules = agent.reports.filter { $0.kind == .rule }.count, steps = agent.reports.filter { $0.kind == .skill }.count
                                if rules > 0 { Text("\(rules) rule\(rules == 1 ? "" : "s") ✓").foregroundStyle(.green) }
                                if steps > 0 { Text("\(steps) skill step\(steps == 1 ? "" : "s")").foregroundStyle(.secondary) }
                                Text(agent.finishedAt.map { "Finished " + HootFlow.time($0) } ?? agent.status)
                                    .foregroundStyle(.tertiary)
                                if agent.taskID != nil { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                            }
                            .font(.system(size: 12)).contentShape(.rect)
                        }.buttonStyle(.plain).disabled(agent.taskID == nil)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
    private func open(_ line: HootFlowLine) {
        if let id = line.rowID, let row = rows.first(where: { $0.id == id }) { detail = row }
        else if let task = line.taskID { openTask?(task) }
    }
}

/// A tool call's command and what came back.
struct HootStepDetails: View {
    let row: HootChatRow
    var body: some View {
        let input = row.value["input"]
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(HootStep.title(row)).font(.headline)
                if let command = input["command"].string ?? input["cmd"].string {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                } else if HootStep.kind(row) == .edit {
                    if let old = input["old_string"].string, !old.isEmpty { Text(old).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                    if let new = input["new_string"].string ?? input["content"].string { Text(new).font(.caption.monospaced()).foregroundStyle(.green).textSelection(.enabled) }
                } else {
                    Text(input.compact).font(.caption.monospaced()).textSelection(.enabled)
                }
                if row.value.has("output") {
                    Divider()
                    Text(row.value["output"].string ?? row.value["output"].compact).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 420, height: 320)
    }
}
