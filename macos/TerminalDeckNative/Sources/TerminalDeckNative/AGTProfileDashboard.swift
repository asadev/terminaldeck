import SwiftUI
import TerminalDeckNativeCore

struct AGTProfileDashboard: View {
    @Bindable var model: AGOPTProfileModel
    let actions: AgentMenu.Actions
    let selectTab: (String) -> Void
    let openTask: (String) -> Void
    let showTasks: () -> Void
    let showTeam: () -> Void
    let showRoutines: () -> Void
    let openRun: (String) -> Void
    let showChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.budget["paused"].bool == true {
                AGOPTCard {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        Text(model.budget["pauseReason"].string ?? "Paused — it reached its budget.")
                        Spacer()
                        Button("Raise the budget") { selectTab("budget") }
                        Button("Resume once") { Task { await model.perform("resume_once") } }
                    }.font(.callout)
                }
            }
            now
            if let id = model.profile?.id { AGTAgentSessionsCard(agentID: id) }   // its live sessions (13 Oct: one card per agent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4), spacing: 12) {
                metric("Runs · last 14 days", field: "runs14d", bars: daily { _ in true }, action: { selectTab("runs") })
                metric("Tasks done", field: "tasksDone", bars: daily { ($0["result"].string ?? "") == "completed" }, action: showTasks)
                success
                tokens
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    recentTasks.frame(minWidth: 490)
                    aboutColumn.frame(minWidth: 300, maxWidth: 430)
                }
                VStack(alignment: .leading, spacing: 12) { recentTasks; aboutColumn }
            }
        }
    }

    private var now: some View {
        AGOPTCard {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                let state = model.runtime["state"].string ?? model.profile?.status.rawValue ?? "ready"
                StatusLabel(status(state))
                VStack(alignment: .leading, spacing: 4) {
                    Text(nowTitle(state)).font(.body.weight(.semibold)).lineLimit(1)
                    Text(nowDetail(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let task = model.runtime["taskID"].string {
                    Button { openTask(task) } label: {
                        Text(model.runtime["taskLabel"].string ?? "Open task").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help("Open its task")
                }
                Spacer(minLength: 8)
                switch state {
                case "working":
                    actionButton("Watch", symbol: "eye", action: .watch)
                    actionButton("Pause", symbol: "pause", action: .pause)
                case "waiting", "waiting-for-you":
                    // Answer opens the task with its question (Watch only shows the session).
                    if let task = model.runtime["taskID"].string {
                        Button { openTask(task) } label: { Label("Answer", systemImage: "bubble.left") }
                            .buttonStyle(.bordered).controlSize(.small).help("Open its task to answer what it asked")
                    }
                    actionButton("Watch", symbol: "eye", action: .watch)
                case "paused": actionButton("Resume", symbol: "play", action: .pause)
                default: actionButton("Wake now", symbol: "sun.max", action: .wake)
                }
            }
            // PLAYBOOK-SEATS: what its latest job ran with, and where each choice came from.
            if let line = model.snapshot["choiceLine"].string ?? model.runs.lazy.compactMap(AGTChoiceLine.text(run:)).first {
                Text((model.runs.isEmpty ? "Choices: " : "Latest job: ") + line).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
          }
        }
    }
    private func actionButton(_ label: String, symbol: String, action: AgentMenu.Action) -> some View {
        Button { actions.perform[action]?() } label: { Label(label, systemImage: symbol) }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(actions.perform[action] == nil || actions.busy)
            .help(actions.reasons[action] ?? label)
    }
    /// Per-day counts for the last 14 days, from the agent's own run history.
    private func daily(_ include: (NativeRPCValue) -> Bool) -> [Double] {
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        var counts = Array(repeating: 0.0, count: 14)
        for run in model.runs where include(run) {
            guard let started = run["startedAt"].number else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: started / 1000))
            let back = calendar.dateComponents([.day], from: day, to: today).day ?? 99
            if (0..<14).contains(back) { counts[13 - back] += 1 }
        }
        return counts.contains { $0 > 0 } ? counts : []
    }
    private var activeTask: NativeRPCValue? {
        guard let id = model.runtime["taskID"].string else { return nil }
        return model.recentTasks.first { $0["id"].string == id }
    }
    private func nowTitle(_ state: String) -> String {
        if let title = model.runtime["title"].string { return title }
        if let task = activeTask?["title"].string { return task }
        switch state {
        case "paused": return "Paused by you"
        case "waiting", "waiting-for-you": return "Waiting for you"
        default:
            let last = model.runtime["lastFinishedRun"]["ended_at"].number
            return last.map { "Ready · last ran " + AGTTime.ago($0) } ?? "Ready for work"
        }
    }
    private func nowDetail(_ state: String) -> String {
        if let detail = model.runtime["detail"].string ?? model.runtime["step"].string { return detail }
        // The engine sends no queue count: the agent's own tasks that wait to start are the queue.
        let waiting = (AGTAgentsStore.shared.tasksState?.tasks ?? []).filter { $0.assignee == model.id && $0.process == .queued }.count
        let queued = max(Int(model.runtime["queuedCount"].number ?? 0), waiting)
        if state == "working", let started = model.runtime["startedAt"].number { return "Started " + AGTTime.ago(started) }
        if queued > 0 { return "\(queued) task\(queued == 1 ? "" : "s") waiting" }
        return state == "paused" ? "It takes no new work until you resume it." : "Nothing in its queue."
    }
    private func taskState(_ row: NativeRPCValue) -> String {
        if let state = row["state"].string { return state }
        if !row["result"].isNullish || row["completedAt"].number != nil { return (row["result"]["failed"].bool == true) ? "Failed" : "Done" }
        if row["questionOpen"].bool == true { return "Waiting for you" }
        if row["stopped"].bool == true { return "Stopped" }
        switch row["process"].string ?? "" {
        case "running": return "Working"
        case "queued": return "Queued"
        default: return "Ready"
        }
    }
    private func metric(_ title: String, field: String, bars: [Double], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AGOPTCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(number(model.stats[field])).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    AGTProfileSpark(values: bars)
                }.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
        }.buttonStyle(.plain).help("Open \(title.lowercased())")
    }
    private var success: some View {
        Button { selectTab("runs") } label: {
            AGOPTCard {
                VStack(alignment: .leading, spacing: 8) {
                    let rate = model.stats["successRate"].number
                    Text(rate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("Finished without help" + (model.stats["runs14d"].number.map { runs in " · " + (rate.map { "\(Int(($0 * runs).rounded())) / " } ?? "") + "\(Int(runs)) runs in 14 days" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    if let rate { ProgressView(value: min(1, max(0, rate))).tint(.green).frame(height: 28) }
                    else { Text("No measured result yet").font(.caption).foregroundStyle(.tertiary).frame(height: 28) }
                }.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
        }.buttonStyle(.plain).help("Open finished runs")
    }
    private var tokensCaption: String {
        if model.isAPI, let cost = model.stats["costUSD"].number { return "Tokens this month · ≈ " + cost.formatted(.currency(code: "USD").precision(.fractionLength(0))) + " on API" }
        if model.isPlan { return "Tokens this month · included in your plan" }
        return "Tokens this month"
    }
    private var tokens: some View {
        Button { selectTab("budget") } label: {
            AGOPTCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(number(model.stats["monthTokens"])).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text(tokensCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let limit = model.budget["limit"].number, limit > 0, let used = model.budget["used"].number {
                        ProgressView(value: min(1, max(0, used / limit))).tint(.blue)
                        Text(model.isAPI
                             ? used.formatted(.currency(code: "USD").precision(.fractionLength(2))) + " / " + limit.formatted(.currency(code: "USD").precision(.fractionLength(0))) + " budget · \(Int((used / limit * 100).rounded()))%"
                             : used.formatted(.number.notation(.compactName)) + " / " + limit.formatted(.number.notation(.compactName)) + " tokens · \(Int((used / limit * 100).rounded()))%")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
        }.buttonStyle(.plain).help("Open the agent's budget")
    }
    private var recentTasks: some View {
        AGOPTCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent tasks").font(.headline)
                    Spacer()
                    Button("See all \(model.snapshot["taskCount"].number.map { Int($0) } ?? model.recentTasks.count)", action: showTasks)
                        .buttonStyle(.borderless)
                }
                if model.recentTasks.isEmpty { Text("No tasks yet").font(.callout).foregroundStyle(.secondary).padding(.vertical, 16) }
                ForEach(model.recentTasks, id: \.compact) { row in
                    Button { if let id = row["id"].string { openTask(id) } } label: {
                        HStack(spacing: 12) {
                            let label = taskState(row)
                            Text(label).font(.caption.weight(.medium)).foregroundStyle(tagColor(label))
                                .frame(width: 98, height: 22).background(tagColor(label).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            Text(row["title"].string ?? "Untitled task").lineLimit(1)
                            Spacer(minLength: 4)
                            Text(AGTTime.ago(row["updatedAt"].number, none: "—")).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(AGOPTRowStyle()).disabled(row["id"].string == nil)
                }
            }
        }
    }
    private var aboutColumn: some View {
        VStack(spacing: 12) {
            AGOPTCard {
                VStack(spacing: 0) {
                    aboutRow("Project", text: model.snapshot["project"]["name"].string ?? AGTLeads.projectName(model.agent))
                    aboutRow("Reports to", text: model.snapshot["manager"]["name"].string ?? "No one")
                    aboutRow("Its team", text: "\(model.snapshot["team"].elements?.count ?? 0) agents", action: showTeam)
                    aboutRow("Runs on", text: [model.profile?.provider.map(AGTDirectory.providerLabel), model.ags.settings.model].compactMap { $0 }.joined(separator: " · "))
                    aboutRow("Routines", text: model.snapshot["routines"]["summary"].string ?? "None", action: showRoutines)
                    aboutRow("Skills", text: "\(model.skills.count) skills", action: { selectTab("skills") })
                }
            }
            if let latest = model.runs.first(where: { $0["finishedAt"].number != nil }) {
                AGOPTCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest finished run").font(.headline)
                        Text(latest["summary"].string ?? "No final summary was recorded.").font(.callout).lineLimit(5)
                        HStack {
                            Button("Open the run") { if let id = latest["id"].string { openRun(id) } }
                                .disabled(latest["taskID"].string == nil && latest["sessionID"].string == nil)
                            if latest["changePath"].string != nil {
                                Button("Show the change") { if let id = latest["id"].string { showChange(id) } }
                            }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }
    private func aboutRow(_ label: String, text: String, action: (() -> Void)? = nil) -> some View {
        Group {
            if let action { Button(action: action) { aboutLabel(label, text: text) }.buttonStyle(AGOPTRowStyle()) }
            else { aboutLabel(label, text: text).padding(.vertical, 8) }
        }
    }
    private func aboutLabel(_ label: String, text: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(text.isEmpty ? "Default" : text).lineLimit(1)
            Spacer(minLength: 0)
        }.font(.callout)
    }
    private func number(_ value: NativeRPCValue) -> String { value.number?.formatted(.number.notation(.compactName)) ?? "—" }
    private func status(_ raw: String) -> StatusLabel.State {
        switch raw { case "working": .working; case "waiting", "waiting-for-you": .waiting; case "paused": .paused; case "failed": .failed; default: .ready }
    }
    private func tagColor(_ raw: String) -> Color {
        switch raw.lowercased() { case "done": .green; case "working": .blue; case "waiting for you": .orange; case "failed": .red; default: .secondary }
    }
}

struct AGTProfileSpark: View {
    let values: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if values.isEmpty { Text("No recorded runs").font(.caption).foregroundStyle(.tertiary) }
            else {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.7))
                        .frame(maxWidth: .infinity).frame(height: max(2, 26 * max(0, value) / max(1, values.max() ?? 1)))
                }
            }
        }.frame(height: 28).accessibilityLabel("Daily activity")
    }
}
