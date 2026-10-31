import Testing
@testable import TerminalDeckNativeCore

@Suite struct UIGTasksPresentationTests {
    @Test func firstTaskAndGoalRemainReachableWithoutEmptyCRMNavigation() {
        #expect(UIGTasksPresentation.sections(TasksState()) == [.work, .goals])
        #expect(UIGTasksPresentation.sections(TasksState(tasks: [TaskRow(id: "local:a", local: true)])) == [.work, .goals])
        #expect(UIGTasksPresentation.sections(TasksState(tasks: [TaskRow(id: "crm:a")])) == [.work, .goals, .crm])
    }

    @Test func foldedFilterCountIncludesArchivedAndCountsCategories() {
        var filters = ListFilters()
        filters.search = "repair"
        #expect(UIGTasksPresentation.filterCount(filters) == 0)
        filters.statuses = ["To-Do", "Stuck"]
        filters.archived = true
        #expect(UIGTasksPresentation.filterCount(filters) == 2)
        filters.pile = .agents
        filters.priorities = ["Critical", "High"]
        filters.boards = ["Work", "none"]
        filters.due = .overdue
        #expect(UIGTasksPresentation.filterCount(filters) == 6)
    }

    @Test func resettingFoldedFiltersPreservesSearchViewAndColumnPreferences() {
        var view = TasksViewState()
        view.tab = .board
        view.groupBy = .priority
        view.showClosed = true
        view.columns.project = false
        view.filters.search = "repair"
        view.filters.pile = .favorites
        view.filters.statuses = ["Stuck"]
        view.filters.archived = true
        let reset = UIGTasksPresentation.resetFoldedFilters(view)
        #expect(reset.tab == .board && reset.groupBy == .priority && reset.showClosed)
        #expect(!reset.columns.project && reset.filters.search == "repair")
        #expect(reset.filters.pile == .all && reset.filters.statuses.isEmpty && !reset.filters.archived)
        #expect(UIGTasksPresentation.filterCount(reset.filters) == 0)
    }

    @Test func boardAndCalendarCountsMatchWhatTheirExistingRenderersDisplay() {
        let tasks = [TaskRow(id: "local:a", crmStatus: "To-Do", local: true, dueDate: "2026-10-08"),
                     TaskRow(id: "local:b", crmStatus: "Done", local: true, dueDate: "2026-10-20"),
                     TaskRow(id: "local:c", crmStatus: "Custom", local: true)]
        let week = TaskList.weekOf("2026-10-08")
        #expect(UIGTasksPresentation.contentCount(tasks, tab: .table, week: week) == 3)
        #expect(UIGTasksPresentation.contentCount(tasks, tab: .board, week: week) == 2)
        #expect(UIGTasksPresentation.contentCount(tasks, tab: .calendar, week: week) == 1)
    }
}
