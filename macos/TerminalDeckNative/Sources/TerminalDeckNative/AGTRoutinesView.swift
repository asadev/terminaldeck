import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Agents frame owns the page, header, project picker and primary action.
struct AGTRoutinesView: View {
    var projectID: String? = nil
    var live = true
    @State private var model = ROUTINESPageModel()
    @State private var tab = "routines"
    @State private var filter = ROUTINESFilter.all
    @State private var deleting: ROUTINESRoutine?
    @State private var selectedRuns = Set<String>()
    @State private var openRun: ROUTINESRun?
    init(projectID: String? = nil, model: ROUTINESPageModel? = nil, live: Bool = true) {
        self.projectID = projectID; self.live = live; _model = State(initialValue: model ?? .shared)
    }

    static func subtitle(projectID: String? = nil) -> String {
        ROUTINESWords.subtitle(ROUTINESPageModel.shared.routines.filter { projectID == nil || $0.projectID == projectID })
    }
    private var scoped: [ROUTINESRoutine] { model.routines.filter { projectID == nil || $0.projectID == projectID } }
    private var visible: [ROUTINESRoutine] { scoped.filter(filter.accepts) }
    private var groups: [(id: String, rows: [ROUTINESRoutine])] {
        let grouped = Dictionary(grouping: visible, by: \.projectID)
        let order = NativePROJLabels.shared.projects.map(\.id)
        return grouped.keys.sorted { a, b in
            if a == b { return false }
            if a == "every-project" { return true }
            if b == "every-project" { return false }
            let left = order.firstIndex(of: a) ?? Int.max
            let right = order.firstIndex(of: b) ?? Int.max
            return left == right ? projectName(a).localizedStandardCompare(projectName(b)) == .orderedAscending : left < right
        }.map { ($0, grouped[$0] ?? []) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            toolbar
            if model.loading, model.routines.isEmpty { skeleton }
            else if let problem = model.loadProblem, model.routines.isEmpty { empty(title: "Couldn’t read routines", message: problem, button: "Try Again") { model.load() } }
            else if tab == "runs" { recentRuns }
            else if scoped.isEmpty { empty(title: "No routines yet", message: "A routine is a job an agent does by itself, on a schedule or when something happens.", button: "New routine") { model.newRoutine(projectID: projectID) } }
            else if visible.isEmpty { empty(title: "No routines match", message: "Choose another filter to see the routines in this project.", button: "Show all") { filter = .all } }
            else { ForEach(groups, id: \.id) { group in routineGroup(group.id, rows: group.rows) } }
            if let problem = model.actionProblem {
                HStack(spacing: 8) { Image(systemName: "exclamationmark.triangle").foregroundStyle(ROUTINESKit.warn); Text(problem).font(.callout); Spacer(); Button("Dismiss") { model.actionProblem = nil } }.padding(12)
            } else if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        .task { if live { model.start() } }
        .onChange(of: NativePROJLabels.shared.projects) { _, _ in model.reprojectRoutines() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ROUTINES.newRoutine"))) { _ in model.newRoutine(projectID: projectID) }
        .sheet(item: $model.draft) { draft in ROUTINESRoutineSheet(model: model, initial: draft) }
        .sheet(item: $openRun) { run in runDetail(run) }
        .alert("Delete \(deleting?.routine.name ?? "routine")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete routine", role: .destructive) { if let row = deleting { model.remove(row) }; deleting = nil }
        } message: { Text("Its routine file is removed from disk.") }
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            Picker("Routines view", selection: $tab) { Text("Routines").tag("routines"); Text("Recent runs").tag("runs") }.pickerStyle(.segmented).labelsHidden().frame(width: 208)
            FilterChips(selection: $filter, items: ROUTINESFilter.allCases.map {
                .init(id: $0, title: $0.title, count: scoped.filter($0.accepts).count, dot: $0 == .failed ? ROUTINESKit.bad : nil)
            })
            Spacer(minLength: 0)
            if model.loading { ProgressView().controlSize(.small) }
        }
    }
    private func routineGroup(_ id: String, rows: [ROUTINESRoutine]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(ROUTINESKit.projectColor(id)).frame(width: 8, height: 8)
                Text(projectName(id)).font(.headline)
                if id == "every-project" { Text("Hoot · \(rows.count)").font(.caption).foregroundStyle(.secondary) }
                else { Text("\(rows.count)").font(.caption).foregroundStyle(.secondary) }
            }
            ROUTINESCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        routineRow(row)
                        Routines21ReportsView(name: row.routine.name, agentID: row.agentID,
                            model: model.reportChat(row.id), live: live)
                        if index < rows.count - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
        }
    }
    private func routineRow(_ row: ROUTINESRoutine) -> some View {
        HStack(spacing: 12) {
            rowToggle(row)
            Button { model.edit(row) } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { rowName(row).frame(minWidth: 220, maxWidth: .infinity); rowWhen(row).frame(width: 178, alignment: .leading); rowAgent(row).frame(width: 126, alignment: .leading); rowLast(row).frame(width: 128, alignment: .leading) }
                    VStack(alignment: .leading, spacing: 5) { rowName(row); HStack(spacing: 14) { rowWhen(row); rowAgent(row); rowLast(row) } }
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).help("Edit \(row.routine.name)")
            rowActions(row)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contextMenu { rowMenu(row) }
    }
    private func rowToggle(_ row: ROUTINESRoutine) -> some View {
        Toggle(row.routine.name, isOn: Binding(get: { row.on }, set: { model.setOn(row, $0) })).labelsHidden().toggleStyle(.switch).tint(ROUTINESKit.switchOn).controlSize(.small).frame(width: 32)
            .disabled(model.busyID == row.id).accessibilityLabel("Run \(row.routine.name) automatically")
    }
    private func rowName(_ row: ROUTINESRoutine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.routine.name).font(.body.weight(.semibold)).lineLimit(1).foregroundStyle(row.on ? Color.primary : Color.secondary)
            if row.routine.pendingCount > 0 || row.routine.skippedCount > 0 {
                Text("\(row.routine.pendingCount) pending · at least \(row.routine.skippedCount) combined or skipped").font(.caption).foregroundStyle(.secondary).help(row.routine.queueReason ?? "Runs are processed one at a time.")
            }
            Text(row.description).font(.callout).foregroundStyle(row.routine.state == .paused && row.routine.consecutiveFailures >= 5 ? ROUTINESKit.warn : Color.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
    private func rowWhen(_ row: ROUTINESRoutine) -> some View {
        HStack(spacing: 5) {
            Image(systemName: row.routine.triggers.first?.hasPrefix("schedule") == true ? "clock" : "bolt")
                .symbolRenderingMode(.monochrome).foregroundStyle(.secondary)
            Text(ROUTINESWords.when(row.routine.triggers)).foregroundStyle(row.on ? Color.primary : Color.secondary)
        }.font(.callout).lineLimit(1)
    }
    private func rowAgent(_ row: ROUTINESRoutine) -> some View {
        HStack(spacing: 7) { ROUTINESKit.avatar(agentID: row.agentID, size: 22); Text(agentName(row.agentID)).font(.callout).lineLimit(1) }.opacity(row.on ? 1 : 0.5)
    }
    private func rowLast(_ row: ROUTINESRoutine) -> some View {
        HStack(spacing: 6) {
            if row.routine.lastOutcome != nil { Image(systemName: row.failed ? "xmark" : "checkmark").foregroundStyle(row.failed ? ROUTINESKit.bad : ROUTINESKit.good) }
            Text((row.failed ? "failed " : "") + ROUTINESWords.date(row.routine.lastRunAt)).foregroundStyle(row.failed ? ROUTINESKit.bad : Color.secondary)
        }.font(.caption).lineLimit(1).help(row.routine.lastError ?? "Last run")
    }
    private func rowActions(_ row: ROUTINESRoutine) -> some View {
        HStack(spacing: 6) {
            if row.failed { Button("Fix") { model.fix(row) }.controlSize(.small) }
            Button(model.busyID == row.id ? "Working…" : "Run now") { model.run(row) }.controlSize(.small).disabled(model.busyID != nil || row.routine.running)
            Menu { rowMenu(row) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).frame(width: 28).help("Routine actions").accessibilityLabel("Actions for \(row.routine.name)")
        }
    }
    @ViewBuilder private func rowMenu(_ row: ROUTINESRoutine) -> some View {
        Button("Edit…") { model.edit(row) }
        Button("Duplicate") { model.edit(row, duplicate: true) }
        Button("Show its file") { NativeFront.whenPersonActs("routines-show-file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.routine.file)]) } }
        Divider()
        Button("Delete…", role: .destructive) { deleting = row }
    }
    private var recentRuns: some View {
        let ids = Set(visible.map(\.id)), runs = model.runs.filter { ids.contains($0.routineID) }
        return VStack(alignment: .leading, spacing: 12) {
            if let problem = model.runsProblem { ROUTINESNotice(tone: .warn, text: problem); DeckRetryButton { model.load() } }
            else if runs.isEmpty { empty(title: "No runs yet", message: "A routine’s runs appear here after it starts.", button: "Show routines") { tab = "routines" } }
            else {
                Table(runs, selection: $selectedRuns) {
                    TableColumn("When") { run in Text(ROUTINESWords.date(run.when)) }
                    TableColumn("Routine") { run in Text(model.routines.first { $0.id == run.routineID }?.routine.name ?? run.routineID) }
                    TableColumn("Agent") { run in Text(agentName(run.agentID)) }
                    TableColumn("Result") { run in
                        Label(run.result == "ok" ? "Passed" : run.result == "failed" ? "Failed" : "Running", systemImage: run.result == "ok" ? "checkmark.circle" : run.result == "failed" ? "xmark.circle" : "clock")
                            .foregroundStyle(run.result == "failed" ? ROUTINESKit.bad : run.result == "ok" ? ROUTINESKit.good : Color.secondary)
                    }
                    TableColumn("Took") { run in Text(run.tookMs.map { String(format: "%.1f s", $0 / 1_000) } ?? "—") }
                    TableColumn("Tokens") { run in Text(run.tokens.map { Int($0).formatted() } ?? "—").monospacedDigit() }
                }.frame(height: max(180, min(460, CGFloat(runs.count * 30 + 34))))
                    .contextMenu(forSelectionType: String.self) { ids in Button("Open run") { if let id = ids.first { openRun = runs.first { $0.id == id } } } } primaryAction: { ids in if let id = ids.first { openRun = runs.first { $0.id == id } } }
            }
        }
    }
    private func runDetail(_ run: ROUTINESRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.routines.first { $0.id == run.routineID }?.routine.name ?? run.routineID).font(.title3.weight(.semibold))
            Form { LabeledContent("When", value: ROUTINESWords.date(run.when)); LabeledContent("Agent", value: agentName(run.agentID)); LabeledContent("Result", value: run.result); if let error = run.error { Text(error).textSelection(.enabled) }; if let output = run.output { Text(output).font(.callout).textSelection(.enabled) }; ForEach(run.sessionIDs, id: \.self) { id in Button("Open session \(id.prefix(8))") { AppModel.shared.selectTab(SessionTarget.local(id).tabId); openRun = nil } } }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { openRun = nil }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 560, height: 380)
    }
    private var skeleton: some View {
        ROUTINESCard { VStack(spacing: 0) { ForEach(0..<4) { _ in HStack(spacing: 12) { Capsule().fill(Color.secondary.opacity(0.10)).frame(width: 32, height: 18); VStack(alignment: .leading, spacing: 6) { RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)).frame(width: 240, height: 12); RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.07)).frame(width: 310, height: 10) }; Spacer() }.padding(12); Divider() } } }.accessibilityLabel("Loading routines")
    }
    private func empty(title: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) { Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 34)).foregroundStyle(.tertiary); Text(title).font(.headline); Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center); if button == "Try Again" { DeckRetryButton(action: action) } else { Button(button, action: action) } }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }
    private func projectName(_ id: String) -> String { id == "every-project" ? "Every project" : NativePROJLabels.shared.name(for: id) }
    private func agentName(_ id: String) -> String { id == "@hoot" ? "Hoot" : AGTAgentsStore.shared.agent(id)?.name ?? "Unavailable agent" }
}

@MainActor @Observable final class ROUTINESPageModel {
    static let shared = ROUTINESPageModel()
    var routines: [ROUTINESRoutine] = []
    var runs: [ROUTINESRun] = []
    var draft: ROUTINESDraft?
    var loading = true
    var hootFolder = ""
    var loadProblem: String?
    var runsProblem: String?
    var actionProblem: String?
    var status: String?
    var busyID: String?
    var fixture = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runsLoading = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var latestRoutinesRead: CodingAIJSON?
    @ObservationIgnored private var reportChats: [String: Routines21ReportsModel] = [:]
    @ObservationIgnored var call: @MainActor (String, [Any?]) async throws -> CodingAIJSON = { channel, args in CodingAIJSON(try await EngineBridge.shared.invoke(channel, args)) }

    func start() {
        guard !fixture else { return }
        AGTAgentsStore.shared.start(); NativePROJLabels.shared.start()
        if subscriptions.isEmpty { for event in ["routines:changed", "tasks:changed", "session:exit", "hoot:chat:changed", "project-registry:changed"] { subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in self?.load() }) } }
        load()
    }
    func load() {
        guard !fixture else { loading = false; return }
        generation += 1; let mine = generation; loading = true; loadProblem = nil; runsProblem = nil; runsLoading = true
        Task {
            do {
                let value = try await call("routines:list", [])
                guard mine == generation else { return }; latestRoutinesRead = value; reprojectRoutines(); loading = false
                // A deleted routine's report chat goes with it.
                let ids = Set(routines.map(\.id))
                for (id, chat) in reportChats where !ids.contains(id) { chat.stop() }
                reportChats = reportChats.filter { ids.contains($0.key) }
            } catch { guard mine == generation else { return }; loading = false; runsLoading = false; loadProblem = CodingAIErrorText.from(error, fallback: "Couldn’t read routines."); return }
            // The runs are read on their own: slow runs never undo routines that already loaded.
            do { let recent = try await call("routines:recent-runs", [200]); guard mine == generation else { return }; runs = ROUTINESRun.list(recent); runsProblem = nil }
            catch { guard mine == generation else { return }; runsProblem = CodingAIErrorText.from(error, fallback: "Couldn’t read recent runs.") }
            runsLoading = false
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard mine == generation else { return }
            if loading { generation += 1; loading = false; runsLoading = false; loadProblem = "The engine didn’t answer in time." }
            else if runsLoading { runsProblem = "Recent runs are slow to read. They appear here when they arrive." }
        }
    }
    func newRoutine(projectID: String?) {
        var next = ROUTINESDraft(id: "routine-" + String(UUID().uuidString.prefix(8)).lowercased())
        if let projectID { next.projectID = projectID; next.folder = NativePROJLabels.shared.projects.first { $0.id == projectID }?.folders.first ?? "" }
        draft = next
        if next.folder.isEmpty { Task { do { let folder = try await defaultHootFolder(); if draft?.id == next.id { draft?.folder = folder } } catch { actionProblem = "Couldn’t read Hoot’s routine folder." } } }
    }
    func reprojectRoutines() {
        guard let raw = latestRoutinesRead else { return }
        routines = ROUTINESRoutine.list(raw, projects: NativePROJLabels.shared.projects)
    }
    func defaultHootFolder() async throws -> String {
        if !hootFolder.isEmpty { return hootFolder }
        let raw = try await call("hoot:folder", [])
        hootFolder = raw["home"].text ?? raw["folder"].text ?? raw["path"].text ?? raw.text ?? ""
        return hootFolder
    }
    func edit(_ row: ROUTINESRoutine, duplicate: Bool = false) {
        busyID = row.id
        Task {
            defer { busyID = nil }
            do {
                guard case .text(let text, _) = CopilotRoutineText.from(try await call("routines:text", [row.id])) else { actionProblem = "Couldn’t read this routine’s file."; return }
                var next = ROUTINESDraft.read(id: duplicate ? "routine-" + String(UUID().uuidString.prefix(8)).lowercased() : row.id, text: text)
                next.agentID = row.agentID; next.projectID = row.projectID
                if duplicate { next.name += " copy" }
                draft = next
            } catch { actionProblem = CodingAIErrorText.from(error, fallback: "Couldn’t read this routine’s file.") }
        }
    }
    func reportChat(_ id: String) -> Routines21ReportsModel {
        if let existing = reportChats[id] { return existing }
        let chat = Routines21ReportsModel(routineID: id, call: { [weak self] channel, args in
            guard let self else { throw NativeRPCError(code: "routine-page-closed", message: "Reopen Routines to try again.") }
            return try await self.call(channel, args)
        })
        chat.fixture = fixture; chat.loading = !fixture
        reportChats[id] = chat
        return chat
    }
    func save(_ next: ROUTINESDraft, destinations: [Routines21Destination]? = nil) async -> Bool {
        guard next.problem == nil else { actionProblem = next.problem; return false }
        busyID = next.id; defer { busyID = nil }
        var routineSaved = false
        do {
            switch CopilotRoutineWrite.from(try await call("routines:save-text", [next.id, next.text])) {
            case .saved:
                routineSaved = true
                if let destinations {
                    let response = try await call("routines:set-destinations", [next.id, destinations.map(\.wire)])
                    if response["ok"].bool == false { actionProblem = "The routine saved, but its result destinations did not. Try saving again."; return false }
                }
                status = "Saved \(next.name)."; draft = nil; load(); return true
            case .problems(let problems): actionProblem = problems.joined(separator: " "); return false
            }
        } catch {
            actionProblem = routineSaved ? "The routine saved, but its result destinations did not. Try saving again." : CodingAIErrorText.from(error, fallback: "The routine did not save.")
            return false
        }
    }
    func run(_ row: ROUTINESRoutine) { act(row.id) { [self] in CopilotRoutineWords.runLine(try await call("routines:run", [row.id]), name: row.routine.name) } }
    func setOn(_ row: ROUTINESRoutine, _ on: Bool) {
        act(row.id) { [self] in
            guard case .text(let source, _) = CopilotRoutineText.from(try await call("routines:text", [row.id])) else { throw NativeRPCError(code: "routine-not-readable", message: "Its routine file could not be read.") }
            let next = ROUTINESDraft.settingEnabled(source, to: on)
            guard case .saved = CopilotRoutineWrite.from(try await call("routines:save-text", [row.id, next])) else { throw NativeRPCError(code: "routine-not-saved", message: "Its routine file could not be saved.") }
            do {
                let result = try await call(on ? "routines:resume" : "routines:pause", [row.id, "Paused from Routines."])
                guard result.bool != false else { throw NativeRPCError(code: "routine-not-changed", message: "This routine could not be \(on ? "turned on" : "paused"). Check its file.") }
            } catch {
                // The file already says the new state but the schedule refused it: put the file back, so both say the same.
                _ = try? await call("routines:save-text", [row.id, source])
                throw error
            }
            return "\(row.routine.name) is \(on ? "on" : "off")."
        }
    }
    func remove(_ row: ROUTINESRoutine) { act(row.id) { [self] in let result = try await call("routines:delete", [row.id]); guard result["ok"].isTrue else { throw NativeRPCError(code: "routine-not-deleted", message: result["problems"].array?.compactMap(\.text).joined(separator: " ") ?? "The file was not deleted.") }; return "Deleted \(row.routine.name)." } }
    func fix(_ row: ROUTINESRoutine) {
        let reason = row.routine.lastError ?? row.routine.reason ?? "The run failed."
        let chat = NativeHootChatModel.shared
        chat.draft = "\(row.routine.name) failed: \(reason). Fix it?"
        chat.attachments.append((name: row.routine.name + " failure", value: .object([.init("type", .string("text")), .init("text", .string("Routine \(row.id)\nFile: \(row.routine.file)\nFailure: \(reason)"))])))
        NativeHootModel.shared.show(turn: nil)
    }
    private func act(_ id: String, _ work: @escaping @MainActor () async throws -> String?) {
        guard busyID == nil else { return }; busyID = id; actionProblem = nil; status = nil
        // Read again after a refusal too: a step that went through before it shows as it really is.
        Task { defer { busyID = nil }; do { status = try await work(); load() } catch { actionProblem = CodingAIErrorText.from(error, fallback: "The routine could not be changed."); load() } }
    }
}
