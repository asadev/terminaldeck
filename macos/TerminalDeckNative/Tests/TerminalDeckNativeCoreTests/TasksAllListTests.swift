import Testing
@testable import TerminalDeckNativeCore

/// The main Tasks list (13 Oct): project sections with groups inside, child tasks under their parent.
@Suite struct TasksAllListTests {
    let projects = [PROJProject(id: "td", name: "Terminal Deck", folders: ["/scratch/td"]),
                    PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/imatch"])]

    private func row(_ id: String, _ status: String, project: String = "/scratch/td", parent: String? = nil,
                     created: Double = 0) -> TaskRow {
        TaskRow(id: id, title: id, project: project, crmStatus: status, local: true, createdAt: created, parentTaskId: parent)
    }

    @Test func allProjectsMakesOneSectionPerProjectWithStatusGroupsInside() {
        let tasks = [row("a", "To-Do"), row("b", "In Progress"), row("c", "Done"),
                     row("d", "To-Do", project: "/scratch/imatch")]
        let sections = TasksAllList.sections(tasks, allProjects: true, projects: projects, by: .status,
                                             today: "2026-10-13", showClosed: false, assigneeName: { $0 })
        #expect(sections.map(\.label) == ["Terminal Deck", "iMatch"])
        #expect(sections.map(\.count) == [3, 1])
        let td = sections[0]
        #expect(td.groups.map(\.label) == ["To-Do", "In Progress", "Done"])
        #expect(td.groups.last?.folded == true, "Done starts folded inside a project too")
        // Keys stay unique across projects, and Add Task under a group lands in that project.
        #expect(Set(sections.flatMap(\.groups).map(\.key)).count == 4)
        #expect(td.groups[0].defaults?.status == "To-Do")
        #expect(td.groups[0].defaults?.projectID == "td")
        #expect(sections[1].groups[0].defaults?.project == "/scratch/imatch")
    }

    @Test func oneProjectOrGroupingByProjectKeepsTheListItHadBefore() {
        let tasks = [row("a", "To-Do"), row("d", "Stuck", project: "/scratch/imatch")]
        let one = TasksAllList.sections(tasks, allProjects: false, projects: projects, by: .status,
                                        today: "2026-10-13", showClosed: false, assigneeName: { $0 })
        #expect(one.count == 1 && one[0].label == nil)
        #expect(one[0].groups == TaskList.group(tasks, by: .status, today: "2026-10-13", showClosed: false, assigneeName: { $0 }))
        let byProject = TasksAllList.sections(tasks, allProjects: true, projects: projects, by: .project,
                                              today: "2026-10-13", showClosed: false, assigneeName: { $0 })
        #expect(byProject.count == 1 && byProject[0].label == nil)
        #expect(byProject[0].groups == TaskProjects.groups(tasks, projects: projects, showClosed: false))
        #expect(TasksAllList.sections([], allProjects: true, projects: projects, by: .status,
                                      today: "2026-10-13", showClosed: false, assigneeName: { $0 }).isEmpty)
    }

    @Test func childTasksSitUnderTheirParentInTheOrderTheyWereMade() {
        let tasks = [row("p", "To-Do"), row("c2", "To-Do", parent: "p", created: 2), row("c1", "In Progress", parent: "p", created: 1),
                     row("orphan", "To-Do", parent: "gone")]
        let nesting = TasksAllList.nesting(tasks)
        #expect(nesting.children["p"]?.map(\.id) == ["c1", "c2"])
        #expect(nesting.nested == ["c1", "c2"], "a child whose parent is not in the list stays a normal row")
        let folded = TasksAllList.lines(tasks, nesting: nesting, isOpen: { _ in false })
        #expect(folded.map(\.id) == ["p", "orphan"])
        #expect(folded[0].childCount == 2 && !folded[0].open)
        let opened = TasksAllList.lines(tasks, nesting: nesting, isOpen: { $0 == "p" })
        #expect(opened.map(\.id) == ["p", "c1", "c2", "orphan"])
        #expect(opened.map(\.depth) == [0, 1, 1, 0])
    }

    @Test func aLoopOfParentsNestsNobodySoNoTaskVanishes() {
        let tasks = [row("a", "To-Do", parent: "b"), row("b", "To-Do", parent: "a"), row("self", "To-Do", parent: "self")]
        let nesting = TasksAllList.nesting(tasks)
        #expect(nesting.nested.isEmpty)
        #expect(TasksAllList.lines(tasks, nesting: nesting, isOpen: { _ in true }).map(\.id) == ["a", "b", "self"])
    }

    @Test func sortingUsesDatesPrioritiesNamesAndStableTies() {
        let a = TaskRow(id: "a", title: "Zulu", priority: "Low", dueDate: "2026-10-15", createdAt: 3)
        let b = TaskRow(id: "b", title: "alpha", priority: "Critical", dueDate: "2026-10-14", createdAt: 1)
        let c = TaskRow(id: "c", title: "Beta", createdAt: 2)
        let rows = [a, c, b]
        #expect(TasksListSort.dueDate.ordered(rows).map(\.id) == ["b", "a", "c"])
        #expect(TasksListSort.priority.ordered(rows).map(\.id) == ["b", "a", "c"])
        #expect(TasksListSort.name.ordered(rows).map(\.id) == ["b", "c", "a"])
        #expect(TasksListSort.created.ordered(rows).map(\.id) == ["b", "c", "a"])
        #expect(TasksListSort.automatic.ordered(rows).map(\.id) == ["a", "c", "b"])
        let wire: [NativeRPCValue] = rows.map { .object([.init("title", .string($0.title)), .init("createdAt", .number($0.createdAt))]) }
        #expect(TasksListSort.created.ordered(wire).map { $0["title"].string } == ["alpha", "Beta", "Zulu"])
        var view = TasksViewState(); view.sort = .priority
        #expect(TasksViewState.read(view.json).sort == .priority)
        #expect(TasksViewState.read(["sort": "unknown"]).sort == .automatic)
    }

    @Test func theSubtasksSettingIsKeptWithTheView() {
        var view = TasksViewState()
        #expect(view.subtasks == .collapsed)
        view.subtasks = .expanded
        #expect(TasksViewState.read(view.json).subtasks == .expanded)
        #expect(TasksViewState.read(["subtasks": "sideways"]).subtasks == .collapsed)
        #expect(TasksTab.table.label == "List")
    }
}
