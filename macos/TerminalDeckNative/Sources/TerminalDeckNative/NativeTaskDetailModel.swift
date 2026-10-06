import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckNativeCore

/// One open task's popup: everything the reference CRM's task page reads and
/// writes (src/renderer/crm-task/task-detail-panel.tsx), each call one
/// `tasks:local-detail` call — its function's name and arguments — answered by the
/// engine with the CRM's own result shape. Changes show at once and are put back,
/// with the refusal said, when the engine refuses them.
@MainActor
@Observable
final class TaskDetailModel {
    enum Section: String, CaseIterable { case subtasks, checklist, dependencies, attachments }
    enum Load: Equatable { case loading, error(String), ready }

    let taskId: String
    private(set) var row: TaskRow
    private(set) var team: [CrmPerson]
    let me = CrmPeople.me

    /// The most recent refused write, in the engine's own words.
    var error: String?

    // What the popup changed, shown at once; the next state from the engine replaces it.
    private var overrides: [String: String?] = [:]
    private var overridesAt: Double = 0

    // The bundle: people, subtasks, checklists, dependencies, attachments.
    private(set) var bundleState: Load = .loading
    var people: TaskPeople?
    var subtasks: [SubtaskRow]?
    var checklists: [Checklist]?
    var dependencies: [TaskDependency]?
    var attachments: [TaskAttachment]?
    /// Which optional sections are on screen: whatever has rows, plus whatever an action row revealed.
    var shown: Set<Section> = []
    var justAdded: Section?
    /// A dependency kind asked for from a menu, and a key that remounts the section to open its adder.
    var depKind: DependencyKind?
    var depKey = 0

    // Extras: type, tags, time, recurrence options, subtask priority/due.
    var extras: TaskPageExtras?
    private(set) var extrasError: String?

    // The routine.
    var routine: RoutineView?
    private(set) var routineError: String?
    private(set) var routineBusy = false

    // Part 2: reminders, archive, times, tag colours, time-entry tags.
    var more: TaskMore?
    private(set) var moreError: String?
    var versions: [DescriptionVersion]?
    var historyOpen = false

    // Comments and activity.
    var comments: [TaskComment]?
    private(set) var commentsError: String?
    var commentExtras: CommentExtras?
    private(set) var activity: [TaskActivityRow]?
    private(set) var activityError: String?
    private(set) var activityTotal: Int?

    // Files on their way.
    struct PendingUpload: Identifiable { let id = UUID(); let fileName: String; let sizeBytes: Int }
    var pending: [PendingUpload] = []
    var linking = false

    // The page's own state.
    var activityOpen = true
    var hideEmpty = false
    var full = false

    // The task's own workspace.
    struct WorkspaceShown: Equatable { var folder, branch, repo, state: String; var reason: String? }
    struct WorkspaceView: Equatable { var workspace: WorkspaceShown?; var refusal: String? }
    private(set) var workspace: WorkspaceView?
    private(set) var workspaceBusy = false
    private(set) var workspaceNote: (ok: Bool, text: String)?

    @ObservationIgnored private var seen: [String: String] = [:]
    @ObservationIgnored private var activityTimer: Task<Void, Never>?
    @ObservationIgnored private var renameTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var renameOrigins: [String: String] = [:]
    @ObservationIgnored private var routineSaving = false

    init(row: TaskRow, agents: [AgentProfile]) {
        taskId = row.id
        self.row = row
        team = CrmPeople.local(agents.map { ($0.id, $0.name) })
        overridesAt = row.updatedAt
        let task = CrmTask(row, team: team)
        // Seeded with the line already known: "You created this task · when".
        if let created = task.createdAt {
            activity = [TaskActivityRow(id: "local-created-\(row.id)", taskId: row.id, kind: "created", payload: [:],
                                        actor: team.first { $0.id == task.createdBy }, actorUserId: task.createdBy, createdAt: created)]
        }
        seen = fingerprint(task)
        Task { await loadAll() }
    }

    // MARK: The task, with what this popup changed

    var task: CrmTask {
        var t = CrmTask(row, team: team)
        guard overridesAt == row.updatedAt else { return t }
        func has(_ key: String) -> Bool { overrides.keys.contains(key) }
        func value(_ key: String) -> String? { overrides[key] ?? nil }
        if let v = value("group") { t.group = v }
        if has("priority") { t.priority = value("priority") }
        if let v = value("startDate") { t.startDate = v }
        if let v = value("dueDate") { t.dueDate = v }
        if has("recurrence") { t.recurrence = value("recurrence") }
        if let v = value("title") { t.title = v }
        if let v = value("description") { t.description = v }
        if let v = value("board") { t.board = v }
        if has("assigneeUserId") {
            t.assigneeUserId = value("assigneeUserId")
            t.assignee = team.first { $0.id == t.assigneeUserId } ?? people?.primary
        }
        if has("archivedAt") { t.archivedAt = value("archivedAt") }
        return t
    }

    var canEditRow: Bool { task.assigneeUserId == me || task.createdBy == me }
    var meperson: CrmPerson? { team.first { $0.id == me } }

    /// Values shown at once; nil means "set to nothing".
    private func patch(_ values: [String: String?]) {
        if overridesAt != row.updatedAt {
            overrides = [:]
            overridesAt = row.updatedAt
        }
        for (key, value) in values { overrides[key] = .some(value) }
    }

    /// The engine's newer state for this task (after any change, from anywhere).
    func update(row next: TaskRow, agents: [AgentProfile]) {
        let changed = next != row
        row = next
        team = CrmPeople.local(agents.map { ($0.id, $0.name) })
        guard changed else { return }
        // A change of the task's own fields shows in its activity a moment later.
        let print = fingerprint(task)
        if print != seen {
            seen = print
            activityTimer?.cancel()
            activityTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await self?.loadActivity()
            }
        }
        Task { await loadWorkspace() }
    }

    private func fingerprint(_ t: CrmTask) -> [String: String] {
        ["group": t.group, "priority": t.priority ?? "", "start": t.startDate, "due": t.dueDate, "title": t.title,
         "description": t.description, "board": t.board]
    }

    // MARK: Calls

    /// One `tasks:local-detail` call; never a throw — a failure is a sentence.
    func call(_ fn: String, _ args: [Any?]) async -> Result<[String: Any], TasksProblem> {
        guard EngineBridge.shared.isReady else { return .failure(TasksProblem("This build cannot change tasks.")) }
        do {
            return CrmDecode.ok(try await EngineBridge.shared.invoke("tasks:local-detail", [fn, args]))
        } catch {
            return .failure(TasksProblem(error.localizedDescription))
        }
    }

    /// A write whose answer is only ok or a refusal.
    @discardableResult
    func write(_ fn: String, _ args: [Any?], label: String? = nil) async -> Bool {
        switch await call(fn, args) {
        case .success: return true
        case .failure(let problem):
            if let label { error = "\(label): \(problem.message)" }
            return false
        }
    }

    // MARK: Reads

    private func loadAll() async {
        async let bundle: () = loadBundle()
        async let extras: () = loadExtras()
        async let routine: () = loadRoutine()
        async let more: () = loadMore()
        async let comments: () = loadComments()
        async let commentExtras: () = loadCommentExtras()
        async let activity: () = loadActivity()
        async let workspace: () = loadWorkspace()
        _ = await (bundle, extras, routine, more, comments, commentExtras, activity, workspace)
    }

    func loadBundle() async {
        switch await call("fetchTaskDetailBundle", [taskId]) {
        case .failure(let problem):
            bundleState = .error(problem.message)
        case .success(let r):
            guard let b = CrmDecode.bundle(r["bundle"]) else {
                bundleState = .error("Could not load this task.")
                return
            }
            people = b.people
            subtasks = b.subtasks
            checklists = b.checklists
            dependencies = b.dependencies
            attachments = b.attachments
            if !b.subtasks.isEmpty { shown.insert(.subtasks) }
            if !b.checklists.isEmpty { shown.insert(.checklist) }
            if !b.dependencies.isEmpty { shown.insert(.dependencies) }
            if !b.attachments.isEmpty { shown.insert(.attachments) }
            bundleState = .ready
        }
    }

    func retryBundle() {
        bundleState = .loading
        Task { await loadBundle() }
    }

    private func loadExtras() async {
        switch await call("fetchTaskPageExtras", [taskId]) {
        case .success(let r): extras = CrmDecode.extras(r["extras"])
        case .failure(let problem): extrasError = problem.message
        }
    }

    func loadRoutine() async {
        switch await call("fetchRoutine", [taskId]) {
        case .success(let r):
            routine = CrmDecode.routine(r["routine"])
            routineError = nil
        case .failure(let problem):
            routineError = problem.message
        }
    }

    func loadMore() async {
        let raw: Any
        do {
            guard EngineBridge.shared.isReady else { return }
            raw = try await EngineBridge.shared.invoke("tasks:local-detail", ["fetchTaskMore", [taskId]])
        } catch {
            moreError = "Couldn't load follow, reminders and archive — try again."
            return
        }
        let r = TasksJSON.record(raw)
        if TasksJSON.isTrue(r?["ok"]), let m = CrmDecode.more(r?["more"]) {
            more = m
            moreError = nil
        } else if TasksJSON.isTrue(r?["notReady"]) {
            // Before its migration, what needs it is hidden, never shown disabled.
            moreError = nil
        } else {
            moreError = "Couldn't load follow, reminders and archive — try again."
        }
    }

    func loadComments() async {
        switch await call("listTaskComments", [taskId]) {
        case .success(let r): comments = (r["comments"] as? [Any] ?? []).compactMap(CrmDecode.comment)
        case .failure(let problem):
            comments = []
            commentsError = problem.message
        }
    }

    func loadCommentExtras() async {
        if case .success(let r) = await call("fetchCommentExtras", [taskId]) {
            commentExtras = CrmDecode.commentExtras(r["extras"])
        }
    }

    func loadActivity() async {
        switch await call("listTaskActivity", [taskId]) {
        case .success(let r):
            activity = (r["rows"] as? [Any] ?? []).compactMap(CrmDecode.activity)
            activityTotal = TasksJSON.number(r["total"]).map { Int($0) }
            activityError = nil
        case .failure(let problem):
            activity = []
            activityTotal = nil
            activityError = problem.message
        }
    }

    func refreshActivity() { Task { await loadActivity() } }

    /// A Fields "Button" changed the status or commented, or a Files field uploaded:
    /// everything it could have touched is read again.
    func refetchAll() {
        Task {
            await loadBundle()
            await loadActivity()
            if case .success(let r) = await call("listTaskComments", [taskId]) {
                comments = (r["comments"] as? [Any] ?? []).compactMap(CrmDecode.comment)
            }
        }
    }

    // MARK: Sections

    func reveal(_ section: Section) {
        shown.insert(section)
        // A checklist section with no list has nothing to type into, so the first list
        // is made on reveal — on the engine too, so what is on screen exists.
        if section == .checklist, checklists?.isEmpty == true {
            Task { await addChecklist(title: "Checklist") }
        }
        justAdded = section
    }

    func relate(_ kind: DependencyKind) {
        depKind = kind
        depKey += 1
        reveal(.dependencies)
    }

    // MARK: The row

    func changeStatus(_ next: String) {
        let prev = task.group
        guard next != prev else { return }
        patch(["group": next])
        Task {
            if !(await write("setTaskStatus", [taskId, next], label: "Status")) { patch(["group": prev]) }
            await loadRoutine()
        }
    }

    func changePriority(_ next: String?) {
        let prev = task.priority
        guard next != prev else { return }
        patch(["priority": next])
        Task {
            if !(await write("updateTask", [taskId, ["priority": next ?? NSNull()] as [String: Any]], label: "Priority")) {
                patch(["priority": prev])
            }
        }
    }

    /// Start and due dates (and the old recurrence word); a cleared date takes its time with it.
    func saveDates(start: String, due: String, recurrence: String?? = nil) {
        let t = task
        var body: [String: Any] = [:]
        if start != t.startDate { body["startDate"] = start }
        if due != t.dueDate { body["dueDate"] = due }
        if let recurrence, recurrence != t.recurrence { body["recurrence"] = recurrence ?? NSNull() }
        guard !body.isEmpty else { return }
        let prev: [String: String?] = ["startDate": t.startDate, "dueDate": t.dueDate, "recurrence": t.recurrence]
        var next: [String: String?] = [:]
        for (k, v) in body { next[k] = .some(v as? String) }
        patch(next)
        Task {
            switch await call("updateTask", [taskId, body]) {
            case .failure(let problem):
                patch(prev)
                error = "Dates: \(problem.message)"
            case .success(let r):
                if let kept = r["warning"] as? String {
                    error = "Dates: \(kept)"
                } else if body["startDate"] as? String == "" || body["dueDate"] as? String == "" {
                    if body["startDate"] as? String == "" { more?.startTime = nil }
                    if body["dueDate"] as? String == "" { more?.dueTime = nil }
                }
            }
        }
    }

    func setTime(_ which: String, _ hm: String?) {
        guard more != nil else { return }
        if which == "start" { more?.startTime = hm } else { more?.dueTime = hm }
        let body: [String: Any] = which == "start" ? ["startTime": hm ?? NSNull()] : ["dueTime": hm ?? NSNull()]
        moreDo("Time") { await self.call("setTaskTimes", [self.taskId, body]) }
    }

    func moveBoard(_ board: String) {
        let prev = task.board
        patch(["board": board])
        Task { if !(await write("moveTask", [taskId, board], label: "Move")) { patch(["board": prev]) } }
    }

    private func patchExtras(_ label: String, _ apply: (inout TaskPageExtras) -> Void, _ run: @escaping () async -> Bool) {
        guard var next = extras else { return }
        let prev = extras
        apply(&next)
        extras = next
        Task {
            if !(await run()) {
                extras = prev
            }
        }
        _ = label
    }

    func changeType(_ type: String) {
        patchExtras("Task type", { $0.taskType = type }) { await self.write("setTaskType", [self.taskId, type], label: "Task type") }
    }

    func changeLabels(_ labels: [String]) {
        patchExtras("Tags", { $0.labels = labels }) { await self.write("setTaskLabels", [self.taskId, labels], label: "Tags") }
    }

    func changeSubtaskMeta(_ subtaskId: String, priority: String?? = nil, dueDate: String?? = nil) {
        var body: [String: Any] = [:]
        if let priority { body["priority"] = priority ?? NSNull() }
        if let dueDate { body["dueDate"] = dueDate ?? NSNull() }
        patchExtras("Subtask", { x in
            var cur = x.subtaskMeta[subtaskId] ?? SubtaskMeta()
            if let priority { cur.priority = priority }
            if let dueDate { cur.dueDate = dueDate }
            x.subtaskMeta[subtaskId] = cur
        }) { await self.write("setSubtaskMeta", [self.taskId, subtaskId, body], label: "Subtask") }
    }

    func duplicate(onDuplicated: @escaping (String) -> Void) {
        Task {
            switch await call("duplicateTask", [taskId]) {
            case .failure(let problem): error = "Duplicate: \(problem.message)"
            case .success(let r): if let id = r["id"] as? String { onDuplicated(id) }
            }
        }
    }

    /// The task's text: one field (the heading is its first line or sentence).
    func saveTitle(_ text: String) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if clean == task.title { return true }
        switch await call("updateTask", [taskId, ["title": clean]]) {
        case .failure(let problem):
            error = "Title: \(problem.message)"
            return false
        case .success:
            patch(["title": clean])
            return true
        }
    }

    func saveDescription(_ text: String) async {
        switch await call("updateTask", [taskId, ["description": text]]) {
        case .failure(let problem): error = "Description: \(problem.message)"
        case .success: patch(["description": text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    // MARK: Time

    /// Every call answers with the rows to show, or its reason.
    func timeStart() async -> String? {
        switch await call("startTaskTimer", [taskId]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let entry = CrmDecode.timeEntry(r["entry"]) {
                extras?.timeEntries.removeAll { $0.userId == me && $0.endedAt == nil }
                extras?.timeEntries.append(entry)
            }
            refreshActivity()
            return nil
        }
    }

    func timeStop() async -> String? {
        switch await call("stopTaskTimer", [taskId]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let done = CrmDecode.timeEntry(r["entry"]), let i = extras?.timeEntries.firstIndex(where: { $0.id == done.id }) {
                extras?.timeEntries[i] = done
            }
            refreshActivity()
            return nil
        }
    }

    func timeAdd(seconds: Double, date: String, note: String, billable: Bool, tags: [String]) async -> String? {
        let input: [String: Any] = ["seconds": seconds, "date": date, "note": note, "billable": billable, "tags": tags]
        switch await call("addTaskTimeEntry", [taskId, input]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            guard let entry = CrmDecode.timeEntry(r["entry"]) else { return nil }
            extras?.timeEntries.append(entry)
            if !tags.isEmpty {
                switch await call("setTimeEntryTags", [taskId, entry.id, tags]) {
                case .success(let t): more?.entryTags[entry.id] = TasksJSON.strings(t["tags"])
                case .failure(let problem): error = "Time tags: \(problem.message)"
                }
            }
            refreshActivity()
            return nil
        }
    }

    func timeDelete(_ entryId: String) async -> String? {
        switch await call("deleteTaskTimeEntry", [taskId, entryId]) {
        case .failure(let problem): return problem.message
        case .success:
            extras?.timeEntries.removeAll { $0.id == entryId }
            return nil
        }
    }

    func timeEstimate(_ minutes: Double?) async -> String? {
        switch await call("setTimeEstimate", [taskId, minutes ?? NSNull()]) {
        case .failure(let problem): return problem.message
        case .success:
            extras?.estimateMinutes = minutes
            refreshActivity()
            return nil
        }
    }

    // MARK: Part 2 (more)

    /// Run a part-2 action; its refusal is shown, its success re-reads the part and the feed.
    func moreDo(_ label: String, _ run: @escaping () async -> Result<[String: Any], TasksProblem>,
                after: (([String: Any]) -> Void)? = nil) {
        Task {
            switch await run() {
            case .failure(let problem):
                error = "\(label): \(problem.message)"
                await loadMore()
            case .success(let r):
                after?(r)
                await loadMore()
                await loadActivity()
            }
        }
    }

    func remind(_ at: Date) {
        moreDo("Remind me") { await self.call("setReminder", [self.taskId, CrmTime.iso(at.timeIntervalSince1970 * 1000), NSNull()]) }
    }

    func clearReminder(_ id: String) {
        moreDo("Reminder") { await self.call("clearReminder", [self.taskId, id]) }
    }

    func setArchived(_ archived: Bool) {
        moreDo(archived ? "Archive" : "Restore", { await self.call("setArchived", [self.taskId, archived]) }) { _ in
            self.patch(["archivedAt": archived ? CrmTime.iso(Date().timeIntervalSince1970 * 1000) : nil])
        }
    }

    func merge(into target: String, onGone: @escaping (String?) -> Void) {
        moreDo("Merge", { await self.call("mergeTaskInto", [self.taskId, target]) }) { _ in onGone(target) }
    }

    func convert(toSubtaskOf parent: String, onGone: @escaping (String?) -> Void) {
        moreDo("Convert to subtask", { await self.call("convertToSubtask", [self.taskId, parent]) }) { _ in onGone(parent) }
    }

    func syncDates(_ on: Bool) {
        moreDo("Sync dates", { await self.call("setSyncSubtaskDates", [self.taskId, on]) }) { r in
            if let due = r["dueDate"] as? String {
                self.patch(["startDate": (r["startDate"] as? String) ?? self.task.startDate, "dueDate": due])
            }
        }
    }

    func setTypeFromMenu(_ type: String) {
        guard let prev = extras?.taskType else { return }
        extras?.taskType = type
        Task {
            if !(await write("setTaskType", [taskId, type], label: "Task type")) { extras?.taskType = prev }
        }
    }

    func setLabelColor(_ label: String, _ color: String) {
        moreDo("Tag colour") { await self.call("setLabelColor", [label, color]) }
    }

    func deleteLabelEverywhere(_ label: String) {
        moreDo("Delete tag", { await self.call("deleteLabelEverywhere", [label]) }) { _ in
            self.extras?.labels.removeAll { $0.lowercased() == label.lowercased() }
        }
    }

    func openDescriptionHistory() {
        historyOpen = true
        versions = nil
        Task {
            switch await call("fetchDescriptionHistory", [taskId]) {
            case .success(let r): versions = (r["versions"] as? [Any] ?? []).compactMap(CrmDecode.version)
            case .failure(let problem):
                historyOpen = false
                error = "Description history: \(problem.message)"
            }
        }
    }

    // MARK: The routine

    /// The Recurring panel's Save: the whole routine, one at a time.
    func saveRoutine(_ rule: CrmValue?, legacy: String?) {
        guard !routineSaving else { return }
        routineSaving = true
        routineBusy = true
        let prevRec = task.recurrence
        let prevRoutine = routine
        let onThisTask = routine == nil || routine?.isRoot == true
        if onThisTask { patch(["recurrence": legacy]) }
        if routine != nil {
            routine?.rule = rule
        } else {
            routine = RoutineView(rootTaskId: taskId, rootTitle: task.title, isRoot: true, rule: rule, canEdit: true, history: [],
                                  historyError: nil, lastError: nil, next: [], peopleCount: 1, version: nil, stuck: nil,
                                  canRestart: false, anchor: nil, occurrence: nil, datesSoFar: 0)
        }
        Task {
            defer {
                routineSaving = false
                routineBusy = false
            }
            switch await call("saveRoutine", [taskId, rule?.any ?? NSNull(), prevRoutine?.version ?? NSNull()]) {
            case .failure(let problem):
                if onThisTask { patch(["recurrence": prevRec]) }
                routine = prevRoutine
                error = "Recurring: \(problem.message)"
            case .success(let r):
                if r.keys.contains("version") { routine?.version = TasksJSON.number(r["version"]) }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func restartRoutine() {
        Task {
            switch await call("restartRoutine", [taskId]) {
            case .failure(let problem): error = "Restart: \(problem.message)"
            case .success(let r):
                if let warning = r["warning"] as? String { error = "Restart: \(warning)" }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func stopRoutine() {
        let prevRec = task.recurrence
        let onThisTask = routine == nil || routine?.isRoot == true
        if onThisTask { patch(["recurrence": nil]) }
        Task {
            switch await call("stopRoutine", [taskId]) {
            case .failure(let problem):
                if onThisTask { patch(["recurrence": prevRec]) }
                error = "Stop recurring: \(problem.message)"
            case .success:
                if !onThisTask { patch(["recurrence": nil]) }
                await loadRoutine()
                await loadActivity()
            }
        }
    }

    func pauseRoutine(_ paused: Bool) {
        Task {
            switch await call("pauseRoutine", [taskId, paused]) {
            case .failure(let problem): error = "\(paused ? "Pause" : "Resume"): \(problem.message)"
            case .success: await loadRoutine()
            }
        }
    }

    // MARK: People

    /// Someone put on the task from @, Share or a slash command.
    func invite(_ person: CrmPerson) {
        guard let cur = people, !cur.has(person.id) else { return }
        let list = cur.list
        let personal = list.isEmpty || (list.count == 1 && cur.primary?.id == me && person.id != me)
        changePeople(personal && cur.primary?.id != person.id ? TaskPeople(primary: person) : cur.adding(person))
    }

    func removeFromTask(_ personId: String) {
        guard let cur = people else { return }
        changePeople(cur.removing(personId))
    }

    /// The people control's own change: the main person, then who joined or left.
    func changePeople(_ next: TaskPeople) {
        guard let prev = people else { return }
        if prev.primary?.id != next.primary?.id && next.primary == nil {
            error = "A task needs a main person. Add someone else before taking \(prev.primary?.name ?? "the main person") off."
            return
        }
        people = next
        Task {
            if let primary = next.primary, primary.id != prev.primary?.id {
                guard await write("assignTask", [taskId, primary.id], label: "Making \(primary.name) the main person") else {
                    people = prev
                    return
                }
                patch(["assigneeUserId": primary.id])
            }
            let prevIds = Set(prev.list.map(\.id)), nextIds = Set(next.list.map(\.id))
            for p in next.list where !prevIds.contains(p.id) && !(p.id == next.primary?.id && prev.primary?.id != next.primary?.id) {
                if !(await write("addTaskAssignee", [taskId, p.id], label: "Adding \(p.name)")) {
                    people = prev
                    return
                }
            }
            for p in prev.list where !nextIds.contains(p.id) && p.id != prev.primary?.id {
                if !(await write("removeTaskAssignee", [taskId, p.id], label: "Removing \(p.name)")) {
                    people = prev
                    return
                }
            }
        }
    }

    /// Someone given an item joins the task, on screen.
    private func joinLocally(_ userId: String?) {
        guard let userId, let cur = people, !cur.has(userId), let person = team.first(where: { $0.id == userId }) else { return }
        people = cur.adding(person)
    }

    // MARK: Subtasks

    private func q(_ s: String) -> String { "“\(s)”" }

    func addSubtask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let draft = SubtaskRow(id: "draft-\(UUID().uuidString)", title: trimmed)
        subtasks = (subtasks ?? []) + [draft]
        Task {
            switch await call("addTaskSubtask", [taskId, trimmed]) {
            case .failure(let problem):
                subtasks?.removeAll { $0.id == draft.id }
                error = "Adding subtask \(q(trimmed)): \(problem.message)"
            case .success(let r):
                guard let id = r["id"] as? String else {
                    error = "Adding subtask \(q(trimmed)): saved, but the server returned no id"
                    return
                }
                if let i = subtasks?.firstIndex(where: { $0.id == draft.id }) { subtasks?[i].id = id }
            }
        }
    }

    func setSubtaskDone(_ row: SubtaskRow, _ done: Bool) {
        update(subtask: row.id) { $0.done = done }
        Task {
            if !(await write("setTaskSubtaskDone", [taskId, row.id, done], label: "\(done ? "Ticking" : "Unticking") \(q(row.title))")) {
                update(subtask: row.id) { $0.done = !done }
            }
        }
    }

    func setSubtaskAssignee(_ row: SubtaskRow, _ userId: String?) {
        let prev = row.assigneeUserId
        update(subtask: row.id) { $0.assigneeUserId = userId }
        joinLocally(userId)
        Task {
            if !(await write("setTaskSubtaskAssignee", [taskId, row.id, userId ?? NSNull()],
                             label: "\(userId != nil ? "Assigning" : "Unassigning") \(q(row.title))")) {
                update(subtask: row.id) { $0.assigneeUserId = prev }
            }
        }
    }

    func deleteSubtask(_ row: SubtaskRow) {
        let before = subtasks
        subtasks?.removeAll { $0.id == row.id }
        Task {
            if !(await write("deleteTaskSubtask", [taskId, row.id], label: "Removing subtask \(q(row.title))")) { subtasks = before }
        }
    }

    private func update(subtask id: String, _ change: (inout SubtaskRow) -> Void) {
        guard let i = subtasks?.firstIndex(where: { $0.id == id }) else { return }
        change(&subtasks![i])
    }

    // MARK: Checklists

    func addChecklist(title: String) async {
        let draft = Checklist(id: "draft-\(UUID().uuidString)", title: title, sortOrder: nil, items: [])
        checklists = (checklists ?? []) + [draft]
        switch await call("addChecklist", [taskId, title]) {
        case .failure(let problem):
            checklists?.removeAll { $0.id == draft.id }
            error = "Adding checklist \(q(title)): \(problem.message)"
        case .success(let r):
            if let id = r["id"] as? String, let i = checklists?.firstIndex(where: { $0.id == draft.id }) { checklists?[i].id = id }
        }
    }

    func deleteChecklist(_ list: Checklist) {
        let before = checklists
        checklists?.removeAll { $0.id == list.id }
        Task { if !(await write("deleteChecklist", [list.id], label: "Removing checklist \(q(list.title))")) { checklists = before } }
    }

    /// Renames arrive a keystroke at a time; the engine hears the title once typing
    /// pauses, and a refusal puts the original back.
    func renameChecklist(_ listId: String, _ title: String) {
        guard let i = checklists?.firstIndex(where: { $0.id == listId }) else { return }
        if renameOrigins[listId] == nil { renameOrigins[listId] = checklists![i].title }
        checklists![i].title = title
        renameTimers[listId]?.cancel()
        renameTimers[listId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.flushRename(listId)
        }
    }

    func flushRename(_ listId: String) async {
        renameTimers[listId] = nil
        guard let origin = renameOrigins.removeValue(forKey: listId),
              let list = checklists?.first(where: { $0.id == listId }), list.title != origin else { return }
        if !(await write("renameChecklist", [listId, list.title], label: "Renaming checklist to \(q(list.title))")) {
            if let i = checklists?.firstIndex(where: { $0.id == listId }) { checklists?[i].title = origin }
        }
    }

    /// A rename still waiting when the popup closes is sent, not lost.
    func flushRenames() {
        for (listId, timer) in renameTimers {
            timer.cancel()
            Task { await flushRename(listId) }
        }
    }

    func addChecklistItem(_ list: Checklist, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let li = checklists?.firstIndex(where: { $0.id == list.id }) else { return }
        let draft = ChecklistItem(id: "draft-\(UUID().uuidString)", title: trimmed, done: false, sortOrder: nil, assigneeUserId: nil)
        checklists![li].items.append(draft)
        Task {
            switch await call("addChecklistItem", [list.id, trimmed]) {
            case .failure(let problem):
                updateItem(draft.id, { _ in }, remove: true)
                error = "Adding item \(q(trimmed)): \(problem.message)"
            case .success(let r):
                if let id = r["id"] as? String { updateItem(draft.id) { $0.id = id } }
            }
        }
    }

    func setItemDone(_ item: ChecklistItem, _ done: Bool) {
        updateItem(item.id) { $0.done = done }
        Task {
            if !(await write("setChecklistItemDone", [item.id, done], label: "\(done ? "Ticking" : "Unticking") \(q(item.title))")) {
                updateItem(item.id) { $0.done = !done }
            }
        }
    }

    func setItemAssignee(_ item: ChecklistItem, _ userId: String?) {
        let prev = item.assigneeUserId
        updateItem(item.id) { $0.assigneeUserId = userId }
        joinLocally(userId)
        Task {
            if !(await write("setChecklistItemAssignee", [item.id, userId ?? NSNull()],
                             label: "\(userId != nil ? "Assigning" : "Unassigning") \(q(item.title))")) {
                updateItem(item.id) { $0.assigneeUserId = prev }
            }
        }
    }

    func deleteItem(_ item: ChecklistItem) {
        let before = checklists
        updateItem(item.id, { _ in }, remove: true)
        Task { if !(await write("deleteChecklistItem", [item.id], label: "Removing item \(q(item.title))")) { checklists = before } }
    }

    private func updateItem(_ id: String, _ change: (inout ChecklistItem) -> Void, remove: Bool = false) {
        guard var lists = checklists else { return }
        for li in lists.indices {
            if let ii = lists[li].items.firstIndex(where: { $0.id == id }) {
                if remove { lists[li].items.remove(at: ii) } else { change(&lists[li].items[ii]) }
            }
        }
        checklists = lists
    }

    // MARK: Dependencies

    func addDependency(_ kind: DependencyKind, otherId: String, otherTitle: String) {
        let dep = TaskDependency(kind: kind, otherTaskId: otherId, otherTitle: otherTitle, otherDone: false)
        guard dependencies?.contains(where: { $0.id == dep.id }) == false else { return }
        dependencies = (dependencies ?? []) + [dep]
        Task {
            if !(await write("addTaskDependency", [taskId, otherId, kind.rawValue], label: "Linking \(q(otherTitle))")) {
                dependencies?.removeAll { $0.id == dep.id }
            }
        }
    }

    func removeDependency(_ dep: TaskDependency) {
        let before = dependencies
        dependencies?.removeAll { $0.id == dep.id }
        Task {
            if !(await write("removeTaskDependency", [taskId, dep.otherTaskId, dep.kind.rawValue], label: "Unlinking \(q(dep.otherTitle))")) {
                dependencies = before
            }
        }
    }

    // MARK: Files

    /// Files from any door (Attach file, a drop, a paste, the comment box's clip): each
    /// checked with the upload rule first, then copied in. Returns what was attached.
    @discardableResult
    func upload(_ urls: [URL]) async -> [TaskAttachment] {
        guard bundleState == .ready else {
            error = "Still loading this task — try the file again in a moment."
            return []
        }
        shown.insert(.attachments)
        var done: [TaskAttachment] = []
        for url in urls {
            let name = url.lastPathComponent
            let data = (try? Data(contentsOf: url)) ?? Data()
            if let refusal = CrmFiles.checkUpload(name: name, size: data.count) {
                error = refusal
                continue
            }
            let pendingRow = PendingUpload(fileName: name, sizeBytes: data.count)
            pending.append(pendingRow)
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let result = await call("uploadTaskFile", [taskId, ["name": name, "type": type, "bytes": data] as [String: Any]])
            pending.removeAll { $0.id == pendingRow.id }
            switch result {
            case .failure(let problem):
                error = "Upload “\(name)”: \(problem.message)"
            case .success(let r):
                if let a = CrmDecode.attachment(r["attachment"]) {
                    attachments = (attachments ?? []) + [a]
                    done.append(a)
                }
            }
        }
        return done
    }

    /// "Upload from device": the Mac's own file chooser, in the engine, checks and copies each file.
    func chooseFromDevice() async -> [TaskAttachment] {
        guard bundleState == .ready else {
            error = "Still loading this task — try the file again in a moment."
            return []
        }
        switch await call("chooseTaskFiles", [taskId]) {
        case .failure(let problem):
            error = "Upload: \(problem.message)"
            return []
        case .success(let r):
            let added = (r["attachments"] as? [Any] ?? []).compactMap(CrmDecode.attachment)
            if !added.isEmpty {
                shown.insert(.attachments)
                attachments = (attachments ?? []) + added
            }
            let errors = TasksJSON.strings(r["errors"])
            if !errors.isEmpty { error = errors.joined(separator: " ") }
            return added
        }
    }

    func detach(_ attachment: TaskAttachment) {
        let before = attachments
        attachments?.removeAll { $0.id == attachment.id }
        Task {
            if !(await write("detachTaskAttachment", [attachment.id], label: "Removing \(q(attachment.fileName))")) { attachments = before }
        }
    }

    func attachDocument(id documentId: String, fileName: String) {
        Task {
            switch await call("attachExistingDocument", [taskId, documentId]) {
            case .failure(let problem): error = "Attaching \(q(fileName)): \(problem.message)"
            case .success: await loadBundle()
            }
        }
    }

    func openFile(_ attachmentId: String) {
        Task { _ = await call("openTaskFile", [taskId, attachmentId]) }
    }

    // MARK: Comments

    func postComment(_ body: String, parentId: String? = nil, assignee: String? = nil, scheduledFor: String? = nil) async -> Bool {
        let rich = parentId != nil || assignee != nil || scheduledFor != nil
        let result: Result<[String: Any], TasksProblem>
        if rich {
            var opts: [String: Any] = [:]
            if let parentId { opts["parentId"] = parentId }
            if let assignee { opts["assigneeUserId"] = assignee }
            if let scheduledFor { opts["scheduledFor"] = scheduledFor }
            result = await call("addTaskCommentWith", [taskId, body, opts])
        } else {
            result = await call("addTaskComment", [taskId, body])
        }
        if case .failure(let problem) = result {
            error = "Comment: \(problem.message)"
            return false
        }
        await loadComments()
        await loadCommentExtras()
        await loadActivity()
        return true
    }

    func react(_ commentId: String, _ emoji: String) {
        guard let prev = commentExtras else { return }
        var list = prev.reactions[commentId] ?? []
        if let i = list.firstIndex(where: { $0.emoji == emoji }) {
            if list[i].userIds.contains(me) { list[i].userIds.removeAll { $0 == me } } else { list[i].userIds.append(me) }
            list.removeAll { $0.userIds.isEmpty }
        } else {
            list.append(CommentReaction(emoji: emoji, userIds: [me]))
        }
        commentExtras?.reactions[commentId] = list
        Task {
            if !(await write("toggleCommentReaction", [taskId, commentId, emoji], label: "Reaction")) { commentExtras = prev }
        }
    }

    func resolve(_ commentId: String, _ resolved: Bool) {
        guard let prev = commentExtras else { return }
        var m = prev.meta[commentId] ?? CommentMeta()
        m.resolvedAt = resolved ? CrmTime.iso(Date().timeIntervalSince1970 * 1000) : nil
        m.resolvedBy = resolved ? me : nil
        commentExtras?.meta[commentId] = m
        Task { if !(await write("setCommentResolved", [taskId, commentId, resolved], label: "Resolve")) { commentExtras = prev } }
    }

    func sendNow(_ commentId: String) {
        Task {
            switch await call("sendScheduledNow", [taskId, commentId]) {
            case .failure(let problem): error = "Send now: \(problem.message)"
            case .success(let r): if let warning = r["warning"] as? String { error = "Send now: \(warning)" }
            }
            await loadCommentExtras()
        }
    }

    // MARK: The workspace

    func loadWorkspace() async {
        guard EngineBridge.shared.isReady, let raw = try? await EngineBridge.shared.invoke("tasks:workspace", [taskId]) else {
            workspace = WorkspaceView(workspace: nil, refusal: nil)
            return
        }
        workspace = Self.workspaceView(raw)
    }

    static func workspaceView(_ value: Any?) -> WorkspaceView {
        guard let raw = value as? [String: Any] else { return WorkspaceView(workspace: nil, refusal: nil) }
        let refusal = raw["refusal"] as? String
        guard let w = raw["workspace"] as? [String: Any], let folder = w["folder"] as? String, let branch = w["branch"] as? String,
              let repo = w["repo"] as? String, let state = w["state"] as? String, ["active", "kept", "removed"].contains(state)
        else { return WorkspaceView(workspace: nil, refusal: refusal) }
        return WorkspaceView(workspace: WorkspaceShown(folder: folder, branch: branch, repo: repo, state: state, reason: w["reason"] as? String),
                             refusal: refusal)
    }

    var showsWorkspace: Bool {
        guard let workspace else { return false }
        return workspace.workspace != nil || workspace.refusal != nil
    }

    func openWorkspace() {
        Task {
            do {
                let answer = try await EngineBridge.shared.invoke("tasks:workspace-open", [taskId]) as? [String: Any]
                workspaceNote = TasksJSON.isTrue(answer?["ok"]) ? nil : (false, answer?["error"] as? String ?? "The folder could not be opened.")
            } catch {
                workspaceNote = (false, error.localizedDescription)
            }
        }
    }

    func removeWorkspace() {
        workspaceBusy = true
        workspaceNote = nil
        Task {
            defer { workspaceBusy = false }
            do {
                let answer = try await EngineBridge.shared.invoke("tasks:workspace-remove", [taskId]) as? [String: Any]
                if let view = answer?["view"] { workspace = Self.workspaceView(view) }
                workspaceNote = (TasksJSON.isTrue(answer?["ok"]), answer?["message"] as? String ?? "The workspace could not be removed.")
            } catch {
                workspaceNote = (false, error.localizedDescription)
            }
        }
    }

    // MARK: Project folder and workspace choice (local only)

    func setProject(_ path: String) async -> String? {
        switch await call("setTaskProject", [taskId, path]) {
        case .failure(let problem): return problem.message
        case .success: return nil
        }
    }

    func chooseProject() async -> (project: String?, problem: String?) {
        switch await call("chooseTaskProject", [taskId]) {
        case .failure(let problem): return (nil, problem.message == "failed" ? nil : problem.message)
        case .success(let r): return (r["project"] as? String, nil)
        }
    }

    func setUseWorkspace(_ on: Bool) async -> String? {
        let result = await TasksStore.shared.call("tasks:local-update", [taskId, ["useWorkspace": on]])
        TasksStore.shared.adopt(result)
        return result.ok ? nil : result.message
    }

    /// The comments' read failed: its sentence.
    var commentsErrorText: String? { commentsError }
    /// The extras' read failed: its sentence.
    var extrasErrorText: String? { extrasError }
    /// Part 2's read failed: its sentence.
    var moreErrorText: String? { moreError }

    // MARK: Counts for the top row

    var forMe: Int {
        guard let people else { return 0 }
        let subs = (subtasks ?? []).filter { !$0.done && people.assignee(for: $0.assigneeUserId).person?.id == me }.count
        let items = (checklists ?? []).flatMap(\.items).filter { !$0.done && people.assignee(for: $0.assigneeUserId).person?.id == me }.count
        return subs + items
    }

    /// Nobody but the viewer on it: the breadcrumb's 🔒.
    var personal: Bool {
        guard let people else { return false }
        let list = people.list
        return list.isEmpty || (list.count == 1 && list[0].id == me)
    }
}

