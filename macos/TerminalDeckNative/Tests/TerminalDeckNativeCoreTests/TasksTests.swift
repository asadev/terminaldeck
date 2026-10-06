import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors src/renderer/tasks/tasks-model.test.ts and list-view.test.ts.

private var EMPTY: [String: Any] { [
    "agents": [Any](), "connections": [Any](), "keys": [Any](), "tasks": [Any](), "trash": [Any](),
    "outbox": ["pending": 0, "undelivered": 0], "localStatuses": ["To-Do"],
] }

private func with(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
    base.merging(extra) { _, new in new }
}

private let BUILDER = AgentProfile(id: "builder", name: "Builder", role: "builder", provider: "codex", maxConcurrent: 2,
                                   maxRunMinutes: 60, keepAliveMinutes: 30, verifyCommand: "npm test")

private extension Result {
    var problem: String? { if case .failure(let error) = self { return (error as? TasksProblem)?.message } else { return nil } }
    var value: Success? { try? get() }
}

@Suite("Tasks model — reading what main answers")
struct TasksModelReadTests {
    @Test func readsAStateAndRefusesSomethingThatIsNotOne() {
        let state = TasksDecode.state(EMPTY)
        #expect(state == TasksState(localStatuses: ["To-Do"]))
        #expect(state?.goals == [])
        #expect(TasksDecode.state(nil) == nil)
        #expect(TasksDecode.state(["agents": [Any]()]) == nil)
    }

    @Test func neverGuessesAConnectionIntoBeingOn() {
        let state = TasksDecode.state(with(EMPTY, ["connections": [["keyId": "k1", "enabled": "yes"]]]))
        #expect(state?.connections.first?.enabled == false)
        #expect(state?.connections.first?.statuses == DEFAULT_CRM_STATUSES)
        let on = TasksDecode.state(with(EMPTY, ["connections": [["keyId": "k1", "enabled": true]]]))
        #expect(on?.connections.first?.enabled == true)
    }

    @Test func keepsTheCrmStatusExactlyAndTheProcessStateApart() throws {
        let state = try #require(TasksDecode.state(with(EMPTY, ["tasks": [[
            "id": "k1:42", "title": "Fix login", "agent": "Builder", "crmStatus": "Working on it", "process": "running",
            "keepOpenUntil": NSNull(),
        ]]])))
        #expect(state.tasks[0].crmStatus == "Working on it")
        #expect(TasksRules.processLabel(state.tasks[0].process) == "Running")
        #expect(TasksRules.processLabel(.exited) == "Finished")
        #expect(TasksRules.processLabel(.queued) == "Queued")
        #expect(TasksRules.processLabel(.idle) == "")
    }

    @Test func carriesASecretOnlyOnASuccessAndASentenceOnARefusal() {
        #expect(TasksDecode.result(["ok": true, "state": EMPTY, "secret": "whsec_abc"]).secret == "whsec_abc")
        let refused = TasksDecode.result(["ok": false, "message": "No.", "state": EMPTY, "secret": "whsec_abc"])
        #expect(refused.ok == false)
        #expect(refused.message == "No.")
        #expect(refused.secret == nil)
        #expect(TasksDecode.result(nil).message?.contains("did not go through") == true)
    }

    @Test func readsATaskFieldByField() throws {
        let task = try #require(TasksDecode.task([
            "id": "local:1", "local": true, "assignee": "me", "labels": ["a", 3, "b"], "taskType": "milestone",
            "dueDate": "2026-10-07", "position": 2, "stalled": ["at": 5, "reason": "exited", "text": "It stopped"],
            "waitingOn": ["Other"], "useWorkspace": 1,
        ]))
        #expect(task.local)
        #expect(task.labels == ["a", "b"])
        #expect(task.taskType == "milestone")
        #expect(task.position == 2)
        #expect(task.stalled == TaskStall(at: 5, reason: .exited, text: "It stopped"))
        #expect(task.waitingOn == ["Other"])
        #expect(task.useWorkspace == false) // only a literal true
        #expect(task.title == "Untitled task")
        #expect(task.agent == "Hoot")
    }
}

@Suite("Tasks model — the mirror and the page")
struct TasksModelMirrorTests {
    @Test func showsOnlyWithATaskOrAConnection() {
        #expect(!TasksRules.showMirror(nil))
        #expect(!TasksRules.showMirror(TasksState()))
        #expect(TasksRules.showMirror(TasksDecode.state(with(EMPTY, ["connections": [["keyId": "k1"]]]))))
        #expect(TasksRules.showMirror(TasksDecode.state(with(EMPTY, ["tasks": [["id": "t"]]]))))
    }

    @Test func countsKeptOpenMinutesUp() {
        #expect(TasksRules.keptOpenMinutes(nil, now: 0) == nil)
        #expect(TasksRules.keptOpenMinutes(1_000, now: 2_000) == nil)
        #expect(TasksRules.keptOpenMinutes(12 * 60_000, now: 0) == 12)
        #expect(TasksRules.keptOpenMinutes(90_000, now: 0) == 2)
        #expect(TasksRules.keptOpenMinutes(10_000, now: 0) == 1)
    }

    @Test func pageFactsSayAgentsConnectionsAndTheOutbox() {
        var state = TasksState()
        #expect(TasksRules.facts(state) == ["0 task agents — add one in Settings to give tasks to an agent"])
        state.agents = [BUILDER]
        state.outbox = (2, 1)
        state.keys = [TasksKey(id: "k1", name: "Office", crmOnly: true, lastApp: nil)]
        state.connections = [TasksDecode.connection(["keyId": "k1", "enabled": true])!]
        #expect(TasksRules.facts(state) == [
            "CRM on “Office” is on, but needs an allowed sender and a project folder",
            "1 task agent",
            "2 updates on the way to the CRM · 1 could not be delivered",
        ])
        state.connections = [TasksDecode.connection(["keyId": "gone"])!]
        #expect(TasksRules.connectionLine(state) == "CRM on “a removed key” is off")
    }

    @Test func aLocalTaskNeedsATitleAndAnAgentNeedsAFolder() {
        var draft = LocalDraft(nil, statuses: ["To-Do", "Done"])
        #expect(draft.status == "To-Do")
        #expect(draft.payload().problem == "Give the task a title.")
        draft.title = "  Ship it "
        draft.assignee = "builder"
        #expect(draft.payload().problem == "Choose the project folder the agent should work in.")
        draft.assignee = "me"
        #expect(draft.payload().value?["title"] as? String == "Ship it")
    }
}

@Suite("Tasks model — the agent form")
struct TasksModelAgentTests {
    @Test func makesAnIdFromTheName() {
        #expect(AgentForm.slug("Code Reviewer") == "code-reviewer")
        #expect(AgentForm.slug("Builder", taken: ["builder"]) == "builder-2")
        #expect(AgentForm.slug("!!!") == "agent")
        #expect(AgentForm.slug("Café Bot") == "cafe-bot")
    }

    @Test func sendsNumbersAsNumbersBlanksAsNilsAndKeepsAnExistingId() {
        var draft = AgentDraft(BUILDER)
        draft.name = " Builder "
        draft.account = "  "
        draft.maxConcurrent = "3"
        var expected = BUILDER
        expected.maxConcurrent = 3
        #expect(AgentForm.payload(draft, agents: [BUILDER]).value == expected)
    }

    @Test func saysWhatToFixRatherThanSendingANumberOutOfRange() {
        var draft = AgentDraft(nil)
        draft.name = "Tester"
        draft.maxConcurrent = "9"
        #expect(AgentForm.payload(draft, agents: []).problem == "Tasks at once has to be a whole number from 1 to 5.")
    }

    @Test func sendsInstructionsToolsSkillsAndEffortAsTheMainProcessTakesThem() throws {
        var draft = AgentDraft(nil)
        draft.name = "Reviewer"
        draft.effort = "xhigh"
        draft.instructions = "  Read the diff first.  "
        draft.toolsPreferred = ["Read", "", "Grep", "Read"]
        draft.toolsAvoided = [" Bash "]
        draft.skills = ["code-review"]
        let saved = try #require(AgentForm.payload(draft, agents: []).value)
        #expect(saved.effort == "xhigh")
        #expect(saved.instructions == "Read the diff first.")
        #expect(saved.toolsPreferred == ["Read", "Grep"])
        #expect(saved.toolsAvoided == ["Bash"])
        #expect(saved.skills == ["code-review"])
        draft.effort = "turbo"
        #expect(AgentForm.payload(draft, agents: []).value?.effort == nil)
        let back = AgentDraft(saved)
        #expect(back.effort == "xhigh" && back.toolsPreferred == ["Read", "Grep"] && back.skills == ["code-review"])
    }

    @Test func neverTurnsRequestsIntoEnforcedLimits() {
        var asked = AgentDraft(nil)
        asked.name = "Careful"
        asked.toolsAvoided = ["WebFetch"]
        asked.skills = ["code-review"]
        let a = AgentForm.payload(asked, agents: []).value
        #expect(a?.toolsAvoided == ["WebFetch"] && a?.blockedTools == [] && a?.skillsOff == false)
        var blocked = AgentDraft(nil)
        blocked.name = "Locked"
        blocked.provider = "claude"
        blocked.blockedTools = ["WebFetch", "WebFetch"]
        blocked.skillsOff = true
        let b = AgentForm.payload(blocked, agents: []).value
        #expect(b?.blockedTools == ["WebFetch"] && b?.skillsOff == true)
        var other = AgentDraft(nil)
        other.name = "Other"
        other.provider = "codex"
        other.blockedTools = ["Bash"]
        #expect(AgentForm.payload(other, agents: []).problem == AgentCapabilities.enforceOnlyClaude)
        other.blockedTools = []
        other.skillsOff = true
        #expect(AgentForm.payload(other, agents: []).problem != nil)
    }

    @Test func refusesAModelOrEffortTheAgentCannotBeGiven() {
        var codex = AgentDraft(nil)
        codex.name = "C"
        codex.provider = "codex"
        codex.model = "gpt-5"
        #expect(AgentForm.payload(codex, agents: []).problem
                == "Codex CLI cannot be given a model by this app. Clear it, or choose Claude Code.")
        var gemini = AgentDraft(nil)
        gemini.name = "G"
        gemini.provider = "gemini"
        gemini.effort = "high"
        #expect(AgentForm.payload(gemini, agents: []).problem != nil)
        var fallback = AgentDraft(nil)
        fallback.name = "D"
        fallback.model = "opus"
        fallback.effort = "high"
        #expect(AgentForm.payload(fallback, agents: []).value != nil)
    }

    @Test func readsAStatusAndNeverGuessesAnUnknownOneIntoTakingWork() {
        func read(_ status: Any?) -> AgentProfile? {
            var agent = BUILDER.wire
            agent["status"] = status
            agent["statusAt"] = 5
            if status == nil { agent.removeValue(forKey: "status") }
            return TasksDecode.state(with(EMPTY, ["agents": [agent]]))?.agents.first
        }
        #expect(read("archived")?.status == .archived && read("archived")?.statusAt == 5)
        #expect(read(nil)?.status == .active)
        #expect(read("sleeping")?.status == .paused)
    }

    @Test func offersNoArchivedAgentAndSaysWhenOneIsPaused() {
        var active = BUILDER
        active.id = "a"
        active.name = "Active"
        var resting = BUILDER
        resting.id = "p"
        resting.name = "Resting"
        resting.status = .paused
        var gone = BUILDER
        gone.id = "x"
        gone.name = "Gone"
        gone.status = .archived
        let choices = TasksRules.assigneeChoices([active, resting, gone])
        #expect(choices.map(\.id) == ["none", "me", "hoot", "a", "p"])
        #expect(choices.first { $0.id == "p" }?.label == "Resting (paused)")
        #expect(TasksRules.pickableAgents([active, resting, gone]).map(\.id) == ["a", "p"])
    }
}

@Suite("Tasks model — the connection form and goals")
struct TasksModelConnectionTests {
    private let connection = TasksDecode.connection(["keyId": "k1", "maxHops": 3])!

    @Test func startsFromTheDefaultStatuses() {
        #expect(ConnectionForm.patch(ConnectionDraft(connection)).value?.statuses == DEFAULT_CRM_STATUSES)
    }

    @Test func sendsListsOneEntryPerLine() {
        var draft = ConnectionDraft(connection)
        draft.allowedSenders = "u-1\n\n u-1 \nu-2"
        draft.folders = "/Users/a/site\n"
        let patch = ConnectionForm.patch(draft).value
        #expect(patch?.allowedSenders == ["u-1", "u-2"])
        #expect(patch?.folders == ["/Users/a/site"])
    }

    @Test func turnsARemovedStatusIntoACommentOnly() {
        var draft = ConnectionDraft(connection)
        draft.statuses = "To-Do\nDone"
        #expect(ConnectionForm.patch(draft).value?.statuses == StatusConfig(
            statuses: ["To-Do", "Done"], initial: "To-Do", completed: "Done", onStarted: nil, onVerified: "Done", onBlocked: nil))
    }

    @Test func asksForTheAgentAnIdentityStandsFor() {
        var draft = ConnectionDraft(connection)
        draft.identities = [.init(identity: "crm-7", agentId: "")]
        #expect(ConnectionForm.patch(draft).problem == "Choose which agent crm-7 is.")
    }

    @Test func holdsTheHandOffLimitToOneToFive() {
        var draft = ConnectionDraft(connection)
        draft.maxHops = "6"
        #expect(ConnectionForm.patch(draft).problem == "The hand-off limit has to be a whole number from 1 to 5.")
    }

    @Test func goalsTreeParentsAndPayload() {
        let goals = [GoalRow(id: "a", title: "A"), GoalRow(id: "b", title: "B", parentId: "a"),
                     GoalRow(id: "c", title: "C", parentId: "b"), GoalRow(id: "d", title: "D", parentId: "missing")]
        #expect(Goals.tree(goals).map { "\($0.goal.id)\($0.depth)" } == ["a0", "b1", "c2", "d0"])
        #expect(Goals.parentChoices(goals, id: "b").map(\.id) == ["a", "d"])
        #expect(Goals.payload(GoalDraft(nil), id: nil).problem == "Give the goal a title.")
        var draft = GoalDraft(nil, parentId: "a")
        draft.title = " Grow "
        let payload = Goals.payload(draft, id: "g1").value
        #expect(payload?["title"] as? String == "Grow" && payload?["parentId"] as? String == "a" && payload?["id"] as? String == "g1")
    }
}

// MARK: - list-view

private let TODAY = "2026-10-07" // a Wednesday

nonisolated(unsafe) private var counter = 0
private func task(_ configure: (inout TaskRow) -> Void = { _ in }) -> TaskRow {
    counter += 1
    var row = TaskRow(id: "local:\(counter)", keyId: "local", externalTaskId: String(counter), title: "Task \(counter)", agent: "Me",
                      crmStatus: "To-Do", process: .idle, local: true, assignee: "me")
    configure(&row)
    return row
}

private func names(_ id: String) -> String {
    ["me": "Me", "none": "Unassigned", "hoot": "Hoot", "builder": "Builder"][id] ?? id
}

private func labels(_ tasks: [TaskRow], _ by: ListGroupBy, showClosed: Bool = false) -> [String] {
    TaskList.group(tasks, by: by, today: TODAY, showClosed: showClosed, assigneeName: names)
        .map { "\($0.label):\($0.items.count)\($0.folded ? " folded" : "")" }
}

@Suite("Task list — grouping, dates, filters")
struct TaskListTests {
    let tasks = [
        task { $0.crmStatus = "To-Do"; $0.priority = "High"; $0.labels = ["ops"]; $0.board = "Launch"; $0.dueDate = "2026-10-06" },
        task { $0.crmStatus = "Working on it"; $0.priority = "Critical"; $0.assignee = "builder"; $0.board = "Launch"; $0.dueDate = TODAY },
        task { $0.crmStatus = "Stuck"; $0.labels = ["ops", "web"]; $0.project = "/work/app"; $0.taskType = "milestone"; $0.dueDate = "2026-10-15" },
        task { $0.crmStatus = "Done"; $0.dueDate = "2026-10-01" },
    ]

    @Test func byStatusTheFiveStagesDoneFolded() {
        #expect(labels(tasks, .status) == ["To-Do:1", "Working on it:1", "Stuck:1", "Done:1 folded"])
        #expect(TaskList.group(tasks, by: .status, today: TODAY, showClosed: false, assigneeName: names)[0].defaults
                == GroupDefaults(status: "To-Do"))
    }

    @Test func byDueClosedPulledOut() {
        #expect(labels(tasks, .due) == ["Overdue:1", "Today:1", "Next:1", "Done:1 folded"])
        #expect(labels(tasks, .due, showClosed: true) == ["Overdue:2", "Today:1", "Next:1"])
    }

    @Test func byEveryOtherGrouping() {
        #expect(labels(tasks, .priority) == ["Critical:1", "High:1", "No priority:1", "Done:1 folded"])
        #expect(labels(tasks, .tags) == ["ops:2", "web:1", "No tags:1", "Done:1 folded"])
        #expect(labels(tasks, .assignee) == ["Builder:1", "Me:2", "Done:1 folded"])
        #expect(labels(tasks, .type) == ["Task:2", "Milestone:1", "Done:1 folded"])
        #expect(labels(tasks, .board) == ["Launch:2", "No board:1", "Done:1 folded"])
        #expect(labels(tasks, .project) == ["app:1", "No project:2", "Done:1 folded"])
        #expect(labels(tasks, .none) == ["3 Tasks:3", "Done:1 folded"])
    }

    @Test func readsADueDateTheCrmWayAndBucketsIt() {
        #expect([TODAY, "2026-10-08", "2026-10-06", "2026-11-15", "2027-01-02"].map { TaskList.relativeDue($0, today: TODAY) }
                == ["Today", "Tomorrow", "Yesterday", "15 Nov", "2 Jan 2027"])
        #expect(TaskList.dueBucket("2026-10-18", today: TODAY) == .next)
        #expect(TaskList.dueBucket("2026-10-19", today: TODAY) == .later)
        #expect(TaskList.dueBucket(nil, today: TODAY) == .unscheduled)
        #expect(TaskList.dueBucket(TODAY, today: TODAY, dueTime: "09:00", nowHm: "10:00") == .overdue)
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
        #expect(TaskList.createdLabel(noon.timeIntervalSince1970 * 1000, today: TODAY) == "Today")
        #expect(TaskList.weekOf(TODAY) == ["2026-10-05", "2026-10-06", TODAY, "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"])
        #expect(TaskList.ymdAddDays("2026-12-31", 1) == "2027-01-01")
        #expect(TaskList.ymdWeekday(TODAY) == 3)
    }

    let mixed = [
        task { $0.assignee = "me"; $0.priority = "Low"; $0.board = "Home"; $0.dueDate = "2026-10-01" },
        task { $0.assignee = "builder"; $0.dueDate = TODAY; $0.title = "Fix the login" },
        task { $0.assignee = "none"; $0.crmStatus = "Done" },
        task { $0.assignee = "me"; $0.archivedAt = 5 },
    ]

    private func titles(_ configure: (inout ListFilters) -> Void, favorites: Set<String> = []) -> [String] {
        var filters = ListFilters()
        configure(&filters)
        return TaskList.filter(mixed, filters, today: TODAY, nowHm: nil, favorites: favorites).map(\.title)
    }

    @Test func filtersByPileStatusPriorityBoardDueSearchAndArchive() {
        #expect(titles { _ in }.count == 3)
        #expect(titles { $0.pile = .mine } == [mixed[0].title])
        #expect(titles { $0.pile = .agents } == ["Fix the login"])
        #expect(titles { $0.pile = .unassigned } == [mixed[2].title])
        #expect(titles { $0.statuses = ["Done"] } == [mixed[2].title])
        #expect(titles { $0.priorities = ["none"] }.count == 2)
        #expect(titles { $0.boards = ["Home"] } == [mixed[0].title])
        #expect(titles { $0.due = .overdue } == [mixed[0].title])
        #expect(titles { $0.due = .today } == ["Fix the login"])
        #expect(titles { $0.search = "LOGIN" } == ["Fix the login"])
        #expect(titles { $0.archived = true } == [mixed[3].title])
    }

    @Test func favoritesHoldWhatYouStarred() {
        #expect(titles({ $0.pile = .favorites }, favorites: []) == [])
        #expect(titles({ $0.pile = .favorites }, favorites: [mixed[1].id, "gone"]) == ["Fix the login"])
        #expect(titles({ $0.pile = .favorites }, favorites: [mixed[3].id]) == [])
    }

    @Test func countsTheTilesLeavingTheArchiveOut() {
        let tiles = TaskList.summary(mixed, today: TODAY, nowHm: nil)
        #expect(tiles.open == 2 && tiles.overdue == 1 && tiles.today == 1 && tiles.done == 1)
    }

    @Test func movesToTheNextStageAndReordersOnlyWhatIsVisible() {
        #expect(TaskList.statusOrder.map(TaskList.nextStatus) == ["Working on it", "In Progress", "Done", "In Progress", nil])
        #expect(TaskList.reorderWithinSlots(["a", "b", "c", "d"], ["c", "a"]) == ["c", "b", "a", "d"])
    }
}
