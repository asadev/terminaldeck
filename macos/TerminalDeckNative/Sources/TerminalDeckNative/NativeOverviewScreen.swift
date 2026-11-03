import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The fixed project dashboard. Each card reads and fails independently.
struct NativeOverviewScreen: View {
    var projectPath: String? = nil
    var embedded = false
    @State private var model = PROJPAGEOverviewModel()
    var body: some View {
        let folder = projectPath ?? DeckProject.current
        Group {
            if let folder {
                let project = NativePROJLabels.shared.projects.first { $0.folders.contains(folder) }
                    ?? PROJProject(id: folder, name: URL(fileURLWithPath: folder).lastPathComponent, folders: [folder], colour: "blue")
                if embedded {
                    PROJPAGEOverviewContent(model: model, project: project, navigate: DeckProject.show, fixWithHoot: { AppModel.shared.select("hoot") })
                } else { ProjectPage(project: project) }
            } else { DeckNeedsProject(label: "Overview", symbol: "square.grid.2x2") }
        }
        .task(id: folder) {
            if embedded, let folder { await model.load(project: NativePROJLabels.shared.projects.first { $0.folders.contains(folder) } ?? PROJProject(id: folder, name: URL(fileURLWithPath: folder).lastPathComponent, folders: [folder]), folder: folder) }
        }
        .onDisappear { model.stop() }
    }
}

@MainActor @Observable final class PROJPAGEOverviewModel {
    typealias Read = @MainActor (String, [Any?]) async throws -> Any
    typealias Observe = @MainActor (String, @escaping ([Any]) -> Void) -> (() -> Void)
    typealias Watch = @MainActor (String) -> Void
    typealias SessionStatuses = @MainActor () -> [String: String]
    typealias Now = @MainActor () -> Date
    static let hideableCards: Set<String> = ["sessions", "agents", "usage", "git", "readiness", "taskLinks", "contentLinks"]
    var cards: [String: NativeRPCValue] = [:]
    var failures: [String: String] = [:]
    var hidden: Set<String> = [] {
        didSet { saveHiddenCards() }
    }
    var period = "today"
    var project: PROJProject?
    var folder: String?
    @ObservationIgnored private var subscriptions: [() -> Void] = []
    private var generation = 0
    private var usageVersion = 0
    private var watchedFolder: String?
    private var active = false
    private var settingsLoaded = false
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let observe: Observe
    @ObservationIgnored private let retainWatch: Watch
    @ObservationIgnored private let releaseWatch: Watch
    @ObservationIgnored private let sessionStatuses: SessionStatuses
    @ObservationIgnored private let now: Now
    @ObservationIgnored private let calendar: Calendar
    init(cards: [String: NativeRPCValue] = [:], read: @escaping Read = { channel, args in
        try await EngineBridge.shared.invoke(channel, args, timeout: 10)
    }, observe: @escaping Observe = { channel, receive in
        let subscription = EngineBridge.shared.on(channel, receive)
        return { subscription.cancel() }
    }, retainWatch: @escaping Watch = { _ = NativeCostWatch.retain($0) },
       releaseWatch: @escaping Watch = { NativeCostWatch.release($0) },
       sessionStatuses: @escaping SessionStatuses = {
        Dictionary((AppModel.shared.sidebar?.allItems ?? []).compactMap { item -> (String, String)? in
            guard item.kind == .session, let status = item.status else { return nil }
            return (item.id, status)
        }, uniquingKeysWith: { _, last in last })
    }, now: @escaping Now = { Date() }, calendar: Calendar = .current) {
        self.cards = cards; self.read = read; self.observe = observe
        self.retainWatch = retainWatch; self.releaseWatch = releaseWatch; self.sessionStatuses = sessionStatuses
        self.now = now; self.calendar = calendar
    }
    static func decodedHiddenCards(_ value: NativeRPCValue) -> Set<String> {
        let ids: [String]
        if let encoded = value.string, let data = encoded.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) { ids = decoded }
        else { ids = value.elements?.compactMap(\.string) ?? [] }
        return Set(ids).intersection(hideableCards)
    }
    func saveHiddenCards() {
        guard let project, settingsLoaded,
              let data = try? JSONEncoder().encode(Array(hidden.intersection(Self.hideableCards)).sorted()),
              let patch = String(data: data, encoding: .utf8) else { return }
        let mine = generation
        Task {
            do {
                _ = try await read("project-settings:set", [["projectId": project.id, "values": ["hiddenOverviewCards": patch]]])
                guard mine == generation, active else { return }
                failures["layout"] = nil
            } catch {
                guard mine == generation, active else { return }
                failures["layout"] = error.localizedDescription
            }
        }
    }
    func sessionAge(_ row: NativeRPCValue) -> String? {
        guard let created = row["createdAt"].number, created.isFinite, created > 0 else { return nil }
        let seconds = max(0, now().timeIntervalSince1970 - created / 1000)
        if seconds < 60 { return "Just started" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr" }
        return "\(Int(seconds / 86400)) days"
    }
    func workingAgentCount(_ value: NativeRPCValue) -> Int {
        let visible = Set((value["agents"].elements ?? []).filter(belongs)
            .filter { $0["status"].string != "archived" }.compactMap { $0["id"].string })
        let running = Set((value["tasks"].elements ?? []).filter(belongs)
            .filter { $0["process"].string == "running" }.compactMap { $0["assignee"].string })
        return visible.intersection(running).count
    }
    func agentSourceSummary(_ value: NativeRPCValue) -> String {
        let agents = (value["agents"].elements ?? []).filter(belongs).filter { $0["status"].string != "archived" }
        let sources = agents.compactMap { row -> String? in
            if let directory = row["sourceDirectory"].string { return NativeTranscriptPaths.resolved(directory) }
            if let file = row["sourceFile"].string { return URL(fileURLWithPath: file).deletingLastPathComponent().path }
            return nil
        }
        guard sources.count == agents.count, let source = sources.first, Set(sources).count == 1 else { return "\(agents.count) agents" }
        let root = folder.map(NativeTranscriptPaths.resolved)
        let shown = root.flatMap { source.hasPrefix($0 + "/") ? String(source.dropFirst($0.count + 1)) : nil }
            ?? PROJPAGEStyle.shortPath(source)
        return "\(agents.count) agents · from \(shown)"
    }
    func artifactsToday(_ value: NativeRPCValue) -> Int {
        guard let day = calendar.dateInterval(of: .day, for: now()) else { return 0 }
        return (value["artifacts"].elements ?? value["items"].elements ?? []).filter { row in
            guard let first = row["firstAt"].number, first.isFinite else { return false }
            let date = Date(timeIntervalSince1970: first / 1000)
            return date >= day.start && date < day.end
        }.count
    }
    var git: GitWidgetStatus? { cards["git"].map { GitWidgetRules.status($0.foundation) } }
    func load(project: PROJProject, folder: String) async {
        if self.folder != folder { cards = [:]; failures = [:] }
        generation += 1; let mine = generation; active = true; self.project = project; self.folder = folder
        settingsLoaded = false
        if subscriptions.isEmpty {
            subscriptions.append(observe("cost:update") { [weak self] args in
                guard let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw) else { return }
                self?.acceptUsage(value)
            })
            for (event, key) in [("session:status", "sessions"), ("session:created", "sessions"),
                ("session:removed", "sessions"), ("tasks:changed", "tasks"),
                ("receiver:changed", "receiver"), ("git:status-changed", "git")] {
                subscriptions.append(observe(event) { [weak self] _ in Task { await self?.reload(key) } })
            }
        }
        if watchedFolder != folder {
            if let old = watchedFolder { releaseWatch(old) }
            watchedFolder = folder; retainWatch(folder)
        }
        let settings = Task { await self.loadSettings(projectID: project.id, generation: mine) }
        let keys = ["sessions", "tasks", "git", "readiness", "usage", "servers", "receiver", "artifacts"]
        let jobs = keys.map { key in Task { await self.reload(key) } }
        for job in jobs { await job.value }
        await settings.value
    }
    private func loadSettings(projectID: String, generation mine: Int) async {
        if let answer = try? await read("project-settings:get", [["projectId": projectID]]),
           let value = try? NativeRPCValue.fromFoundation(answer), mine == generation, active {
            settingsLoaded = false
            hidden = Self.decodedHiddenCards(value["values"]["hiddenOverviewCards"])
        }
        guard mine == generation, active else { return }
        settingsLoaded = true
    }
    private func acceptUsage(_ value: NativeRPCValue) {
        guard active, let folder, let cwd = value["cwd"].string,
              NativeTranscriptPaths.resolved(folder) == NativeTranscriptPaths.resolved(cwd) else { return }
        usageVersion += 1
        if value["ok"].bool == false || value["error"].string != nil {
            cards["usage"] = nil
            failures["usage"] = value["error"].string ?? value["message"].string ?? "Usage could not be read."
        } else { cards["usage"] = value; failures["usage"] = nil }
    }
    func reload(_ key: String) async {
        guard active, let folder else { return }; let mine = generation, usageAtStart = usageVersion
        let channel: String, arguments: [Any?]
        switch key {
        case "sessions": channel = "session:list"; arguments = []
        case "tasks": channel = "tasks:state"; arguments = []
        case "git": channel = "git:status"; arguments = [folder]
        case "readiness": channel = "readiness:scan"; arguments = [folder]
        case "usage": channel = "cost:project"; arguments = [folder]
        case "servers": channel = "servers:list"; arguments = []
        case "receiver": channel = "receiver:overview"; arguments = [[String: Any]()]
        default: channel = "artifacts:list"; arguments = [["cwd": folder, "scope": "project", "projectId": project?.id ?? PROJProjects.independentID]]
        }
        do {
            var value = try NativeRPCValue.fromFoundation(try await read(channel, arguments))
            guard generation == mine, active else { return }
            if key == "usage", usageVersion != usageAtStart { return }
            if key == "artifacts", value["cancelled"].bool == true {
                throw NativeRPCError(code: "cancelled", message: "The artifact scan was cancelled. Try again.")
            }
            if value["ok"].bool == false || value["error"].string != nil {
                throw NativeRPCError(code: "unavailable", message: value["message"].string ?? value["error"].string ?? "The reader returned no data.")
            }
            if key == "sessions", let rows = value.elements {
                let statuses = sessionStatuses()
                value = .array(rows.map { row in statuses[row["id"].string ?? ""].map { row.setting("status", .string($0)) } ?? row })
            }
            cards[key] = value; failures[key] = nil
        } catch {
            guard generation == mine, active else { return }
            if key == "usage", usageVersion != usageAtStart { return }
            failures[key] = error.localizedDescription
        }
    }
    func stop() {
        generation += 1; usageVersion += 1; active = false
        subscriptions.forEach { $0() }; subscriptions = []
        if let watchedFolder { releaseWatch(watchedFolder) }; watchedFolder = nil
    }
    func belongs(_ row: NativeRPCValue) -> Bool {
        guard let project else { return true }
        let explicit = row["projectIdInferred"].bool == true ? nil : row["projectId"].string ?? row["projectID"].string
        return PROJProjects.resolve(projectID: explicit,
            folder: row["project"].string ?? row["projectPath"].string ?? row["cwd"].string ?? row["folder"].string ?? row["defaultProject"].string,
            projects: NativePROJLabels.shared.projects.filter { $0.id != project.id } + [project]) == project.id
    }
}

struct PROJPAGEOverviewContent: View {
    @Bindable var model: PROJPAGEOverviewModel
    let project: PROJProject
    var navigate: (String) -> Void
    var fixWithHoot: () -> Void
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error = model.failures["layout"] {
                HStack { Label("Couldn’t save hidden cards.", systemImage: "exclamationmark.triangle").help(error); Button("Try again") { model.saveHiddenCards() } }.font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    heading("Sessions"); Spacer()
                    if let rows = sessionRows { Text("\(rows.count) running").font(.caption).foregroundStyle(.secondary) }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    if !model.hidden.contains("sessions") { sessions }
                    if !model.hidden.contains("agents") { card("agents", title: "Agents", dataKey: "tasks", trailing: agentsHeader) { value in
                        let agents = (value["agents"].elements ?? []).filter(model.belongs).filter { $0["status"].string != "archived" }
                        Text(model.agentSourceSummary(value)).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 4) { ForEach(Array(agents.prefix(6).enumerated()), id: \.offset) { index, row in
                            AgentAvatar(icon: AGTIcon.parse(row["icon"].string) ?? .symbol("person.crop.circle"), size: 24,
                                tint: (row["colour"].string ?? row["color"].string).map(PROJPAGEStyle.colour),
                                id: row["id"].string, colour: AGTIcon.colour(row["icon"].string))
                        }; if agents.count > 6 { Text("+\(agents.count - 6)").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 6)
                        Button("Open Agents") { navigate("agents-all") }.buttonStyle(.bordered)
                    } }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                heading("At a glance")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    if !model.hidden.contains("usage") { usage }
                    if !model.hidden.contains("git") { card("git", title: "Code", trailing: codeHeader) { value in
                        let status = GitWidgetRules.status(value.foundation)
                        Button { navigate("git") } label: {
                            HStack { metric(String(status.staged.count), "staged"); metric(String(status.unstaged.count), "changed"); metric(String(status.untracked.count), "untracked") }.padding(.vertical, 8).contentShape(.rect)
                        }.buttonStyle(.plain)
                        if let commit = value["lastCommit"]["subject"].string { Text(commit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Button("Review changes") { navigate("git") }.buttonStyle(.bordered)
                    } }
                    if !model.hidden.contains("readiness") { card("readiness", title: "Readiness", trailing: readinessHeader) { value in
                        if let report = ReadinessReport(json: value.foundation) {
                        let progress = AIRReadinessProgress(report: report)
                        let passed = progress.passing
                        let needed = progress.passing + progress.remaining
                        HStack(spacing: 16) {
                            Button { navigate("readiness") } label: { PROJPAGEOverviewRing(passed: passed, total: needed).contentShape(.rect) }.buttonStyle(.plain).help("Open readiness")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(passed) / \(needed) checks").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                ForEach(Array(report.checks.filter { $0.status == .fail || $0.status == .warn || AIRReadinessActions.isUnverified($0) }.prefix(2)), id: \.id) { Text(NativeAIRReadinessText.title($0)).font(.callout).lineLimit(1) }
                            }
                        }.padding(.vertical, 8)
                        Button("Fix with Hoot", action: fixWithHoot).buttonStyle(.bordered)
                        } else { Label("Couldn't read readiness.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    } }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12)], spacing: 12) {
                if !model.hidden.contains("taskLinks") { PROJPAGECard {
                    link("Tasks", key: "tasks", symbol: "checklist", destination: "tasks", hideCard: "taskLinks") { value in
                        let rows = (value["tasks"].elements ?? []).filter(model.belongs)
                        let agents = Set((value["agents"].elements ?? []).compactMap { $0["id"].string })
                        let assigned = rows.filter { agents.contains($0["assignee"].string ?? "") || $0["assigneeKind"].string == "agent" }.count
                        return "\(rows.filter { $0["completedAt"].number == nil && $0["crmStatus"].string != "Done" }.count) open · \(rows.filter { $0["crmStatus"].string == "Stuck" || $0["stalled"].fields != nil || !($0["waitingOn"].elements ?? []).isEmpty }.count) blocked · \(assigned) with agents"
                    }
                    Divider()
                    link("Linked server", key: "servers", symbol: "server.rack", destination: "servers", hideCard: "taskLinks") { value in
                        let rows = (value.elements ?? value["servers"].elements ?? []).filter(model.belongs)
                        return rows.isEmpty ? "No linked servers" : rows.compactMap { $0["name"].string }.joined(separator: " · ")
                    }
                }.contextMenu { Button("Hide card") { model.hidden.insert("taskLinks") } } }
                if !model.hidden.contains("contentLinks") { PROJPAGECard {
                    link("Receiver", key: "receiver", symbol: "antenna.radiowaves.left.and.right", destination: "receiver", hideCard: "contentLinks") { value in
                        let sources = (value["sources"].elements ?? []).filter { model.belongs($0["source"].fields == nil ? $0 : $0["source"]) }
                        return "\(sources.count) sources"
                    }
                    Divider()
                    link("Artifacts", key: "artifacts", symbol: "doc.richtext", destination: "artifacts", hideCard: "contentLinks") { value in
                        let files = (value["artifacts"].elements ?? value["items"].elements ?? []).count
                        let partial = value["truncated"].bool == true ? "+" : ""
                        return "\(files)\(partial) files and pictures · \(model.artifactsToday(value))\(partial) new today"
                    }
                }.contextMenu { Button("Hide card") { model.hidden.insert("contentLinks") } } }
            }
        }.font(.system(size: 13))
    }
    private func statusWord(_ status: String?) -> String {
        switch status?.lowercased() {
        case "working": "Working"
        case "waiting", "needs-input", "blocked": "Waiting for you"
        case "failed", "exited": "Stopped"
        case "done", "finished": "Done"
        default: "At a prompt"
        }
    }
    private func statusColour(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "working": .green
        case "waiting", "needs-input", "blocked": .orange
        case "failed", "exited": .red
        default: .secondary
        }
    }
    private func heading(_ title: String) -> some View { Text(title).font(.system(size: 15, weight: .semibold)) }
    private var sessionRows: [NativeRPCValue]? {
        guard let value = model.cards["sessions"] else { return nil }
        return (value.elements ?? value["sessions"].elements ?? []).filter(model.belongs)
            .filter { $0["exitCode"].number == nil && $0["status"].string != "exited" }
    }
    @ViewBuilder private var sessions: some View {
        if let rows = sessionRows {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                PROJPAGECard {
                    HStack(alignment: .top, spacing: 10) {
                        let identity = NativeSessionRowIdentity(id: row["id"].string ?? "", folder: row["cwd"].string, provider: row["provider"].string, chat: row["chat"].bool == true, project: project)
                        identity.picture(size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row["title"].string ?? "Session").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text([identity.subtitle, row["model"].string, model.sessionAge(row)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        HStack(spacing: 4) { Circle().fill(statusColour(row["status"].string)).frame(width: 6, height: 6); Text(statusWord(row["status"].string)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(row["lastLine"].string ?? "Open the session to see its conversation.").lineLimit(2).frame(minHeight: 34, alignment: .top)
                    HStack { Button("Open") { if let id = row["id"].string { AppModel.shared.selectTab(id) } }; Button("Watch") { navigate("agents-watch") } }.buttonStyle(.bordered)
                }.contextMenu { Button("Hide sessions") { model.hidden.insert("sessions") } }
            }
            if rows.isEmpty { PROJPAGECard { Text("No sessions running").foregroundStyle(.secondary); Text("Start a session in \(project.name).").font(.caption).foregroundStyle(.secondary) } }
        } else { card("sessions", title: "Sessions") { _ in EmptyView() } }
    }
    private var agentsHeader: AnyView? {
        guard let value = model.cards["tasks"] else { return nil }
        let working = model.workingAgentCount(value)
        return AnyView(HStack(spacing: 4) {
            Circle().fill(working > 0 ? Color.green : .secondary).frame(width: 6, height: 6)
            Text("\(working) working")
        }.font(.caption).foregroundStyle(.secondary))
    }
    private var codeHeader: AnyView? {
        guard let status = model.git else { return nil }
        return AnyView(HStack(spacing: 6) {
            Label(status.branchName ?? "No repository", systemImage: "arrow.triangle.branch").lineLimit(1)
            if status.ahead > 0 { Label(String(status.ahead), systemImage: "arrow.up") }
            if status.behind > 0 { Label(String(status.behind), systemImage: "arrow.down") }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).frame(height: 22).background(.primary.opacity(0.06), in: .rect(cornerRadius: 6)))
    }
    private var readinessHeader: AnyView? {
        guard let raw = model.cards["readiness"], let report = ReadinessReport(json: raw.foundation) else { return nil }
        let progress = AIRReadinessProgress(report: report)
        return AnyView(HStack(spacing: 4) {
            Circle().fill(progress.ready ? Color.green : .orange).frame(width: 6, height: 6)
            Text(progress.ready ? "All passed" : "\(progress.remaining) to finish")
        }.font(.caption).foregroundStyle(.secondary))
    }
    /// The real numbers behind the bars: "Today 1.24M · 7 days 6.8M tokens".
    static func usageNumbers(_ value: NativeRPCValue) -> String {
        func total(_ key: String) -> String? {
            let period = value["periods"][key]
            guard period.fields != nil else { return nil }
            return DashboardWords.formatTokens(UsageRules.view(period.foundation).tokens.total)
        }
        let parts = [total("today").map { "Today \($0)" }, total("week").map { "7 days \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "" : parts.joined(separator: " · ") + " tokens"
    }
    private var usage: some View {
        card("usage", title: "Usage", trailing: AnyView(Picker("Usage range", selection: $model.period) { Text("Today").tag("today"); Text("7 days").tag("week") }.pickerStyle(.segmented).labelsHidden().nativeUIGGreyControl().fixedSize())) { value in
            let period = value["periods"][model.period]
            if period.fields != nil {
                if period["scanning"].bool == true || value["scanning"].bool == true { Text("Totals so far").font(.caption).foregroundStyle(.secondary) }
                let reading = UsageRules.view(period.foundation)
                HStack { metric(DashboardWords.formatTokens(reading.tokens.total), "tokens"); metric(String(reading.requests), "turns"); metric(reading.models.first ?? "—", "mostly") }.padding(.vertical, 8)
                let bars = period["bars"].elements ?? []
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(bars.prefix(12).enumerated()), id: \.offset) { index, bar in
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.75)).frame(height: max(2, min(48, (bar.number ?? 0) * 48)))
                    }
                }.frame(height: 52).accessibilityLabel("Token usage history")
                Text(Self.usageNumbers(value)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if let note = value["scanNote"].string, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(note)
                } else if period["partial"].bool == true || period["truncated"].bool == true || value["truncated"].bool == true {
                    Text("Some usage is missing from these totals.").font(.caption).foregroundStyle(.secondary)
                }
                if let unknown = period["unknownTimestamps"].number, unknown > 0 {
                    Text("\(Int(unknown)) requests have no date.").font(.caption).foregroundStyle(.secondary)
                }
                if value["canRetry"].bool == true { DeckRetryButton("Try Again") { Task { await model.reload("usage") } }.buttonStyle(.bordered) }
            } else {
                Text("Couldn't read usage for this range.").foregroundStyle(.secondary)
                DeckRetryButton("Try Again") { Task { await model.reload("usage") } }.buttonStyle(.bordered)
            }
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func card<C: View>(_ key: String, title: String, dataKey: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: @escaping (NativeRPCValue) -> C) -> some View {
        let dataKey = dataKey ?? key
        return PROJPAGECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { heading(title); Spacer(minLength: 8); if let trailing { trailing } }
                if let failure = model.failures[dataKey] {
                    Label("Couldn't read \(title.lowercased()).", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).help(failure)
                    DeckRetryButton("Try Again") { Task { await model.reload(dataKey) } }.buttonStyle(.bordered)
                } else if let value = model.cards[dataKey] { content(value) }
                else {
                    ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.06)).frame(height: 16) }
                }
            }.frame(minHeight: 138, alignment: .top)
        }.contextMenu { Button("Hide") { model.hidden.insert(key) } }
    }
    private func link(_ title: String, key: String, symbol: String, destination: String, hideCard: String, summary: @escaping (NativeRPCValue) -> String) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 12) { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 13, weight: .semibold)); Text(model.failures[key] == nil ? model.cards[key].map(summary) ?? "Loading…" : "Couldn't read \(title.lowercased()).").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(.rect)
        }.buttonStyle(.plain).contextMenu { Button("Open") { navigate(destination) }; Button("Check now") { Task { await model.reload(key) } }; Button("Hide card") { model.hidden.insert(hideCard) } }
    }
}

private struct PROJPAGEOverviewRing: View {
    let passed: Int
    let total: Int
    var body: some View {
        ZStack { Circle().stroke(.primary.opacity(0.07), lineWidth: 6); Circle().trim(from: 0, to: CGFloat(passed) / CGFloat(max(1, total))).stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90)); Text("\(passed)/\(total)").font(.system(size: 13, weight: .semibold)) }.frame(width: 52, height: 52)
    }
}

