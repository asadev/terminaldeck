import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@Suite(.serialized) @MainActor struct TASKS21SavedViewsTests {
    @Test func tabsRememberTheirOwnChangesAndSurviveReopening() throws {
        let suite = "tasks21-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        model.view.groupBy = .priority; model.view.sort = .dueDate
        model.view.columns.reorder(["priority", "due"]); model.view.columns.resize("due", to: 156)
        model.view.filters.search = "ship"
        model.saveView(named: "Shipping")
        let first = try #require(model.activeViewID)
        model.selectTab(.board); model.view.filters.search = "review"; model.saveView(named: "Reviews")
        model.selectView(first)
        #expect(model.view.tab == .table && model.view.filters.search == "ship")
        #expect(model.view.columns.width("due") == 156)
        model.view.columns.resize("due", to: 180)
        let reopened = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        #expect(reopened.activeViewID == first && reopened.view.columns.width("due") == 180)
        reopened.renameView(first, to: "Release")
        #expect(reopened.savedViews.first?.name == "Release")
        reopened.deleteView(first)
        #expect(reopened.activeViewID == nil && reopened.savedViews.count == 1)
    }
    @Test func toolsDriveTheSameModelAndRejectMissingNamesOrIds() throws {
        let suite = "tasks21-tools-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        _ = try model.viewsTool(.fromFoundation(["do": "update", "state": ["groupBy": "priority", "columnOrder": ["due"], "columnWidths": ["due": 180]]]))
        let saved = try model.viewsTool(.fromFoundation(["do": "save", "name": "Due first"]))
        let id = try #require(saved["active"].string)
        #expect(model.view.columns.order.first == "due")
        _ = try model.viewsTool(.fromFoundation(["do": "rename", "id": id, "name": "Dates"]))
        #expect(model.savedViews.first?.name == "Dates")
        #expect(throws: NativeRPCError.self) { try model.viewsTool(.fromFoundation(["do": "select", "id": "missing"])) }
        #expect(throws: NativeRPCError.self) { try model.viewsTool(.fromFoundation(["do": "save", "name": "  "])) }
        _ = try model.viewsTool(.fromFoundation(["do": "delete", "id": id]))
        #expect(model.savedViews.isEmpty)
    }
    /// U26 (#94): a filter tried in an open saved view never changes that view until Update view.
    @Test func triedFiltersStayOutOfTheSavedViewUntilUpdated() throws {
        let suite = "tasks21-try-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        model.view.filters.search = "overdue"; model.saveView(named: "Overdue only")
        let id = try #require(model.activeViewID), saved = model.view
        model.view.filters.search = "archived look"
        #expect(model.activeViewChanged && model.savedViews.first?.view == saved)
        #expect(MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: []).savedViews.first?.view.filters.search == "overdue")
        model.selectTab(.board); model.selectView(id)
        #expect(model.view == saved && !model.activeViewChanged)
        model.view.filters.search = "kept"; model.resaveView(id)
        #expect(model.savedViews.first?.view.filters.search == "kept" && !model.activeViewChanged)
        model.view.filters.search = "tried"; model.revertView(id)
        #expect(model.view.filters.search == "kept")
        model.view.filters.search = "by tool"
        #expect(try model.viewsTool(.fromFoundation(["do": "list"]))["changed"].bool == true)
        _ = try model.viewsTool(.fromFoundation(["do": "resave", "id": id]))
        #expect(model.savedViews.first?.view.filters.search == "by tool")
        model.selectTab(.table)
        #expect(throws: NativeRPCError.self) { try model.viewsTool(.fromFoundation(["do": "revert", "id": id])) }
    }
    @Test func resizedColumnsMatchHeadersAndCellsWithoutCrowdingTheName() {
        var columns = TasksColumns()
        columns.reorder(["priority", "due", "assignee"]); columns.resize("priority", to: 140)
        let wide = TasksListColumns.fitting(width: 1200, columns: columns, statusGroups: true, projectSections: true, hasGoals: false)
        #expect(wide.shown == [.priority, .due, .assignee])
        #expect(wide.width(.priority) == 140 && wide.nameWidth >= 240)
        let narrow = TasksListColumns.fitting(width: 500, columns: columns, statusGroups: true, projectSections: true, hasGoals: false)
        #expect(narrow.shown == [.due] && narrow.nameWidth >= 240)
    }
}
