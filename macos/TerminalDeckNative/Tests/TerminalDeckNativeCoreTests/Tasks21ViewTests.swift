import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite struct Tasks21ViewTests {
    @Test func oldViewsKeepTheirLayoutAndUnknownColumnsAreIgnored() {
        let old = TasksViewState.read(["columns": ["due": false], "columnOrder": ["unknown", "priority", "priority"],
            "columnWidths": ["due": -50.0, "assignee": 900.0, "unknown": 120.0]])
        #expect(!old.columns.due && old.columns.status)
        #expect(old.columns.order.first == "priority")
        #expect(Set(old.columns.order).count == 7)
        #expect(old.columns.width("due") == 72 && old.columns.width("assignee") == 360)
        #expect(old.columns.widths["unknown"] == nil)
    }
    @Test func savedViewPreservesAllSettingsInJSON() throws {
        var view = TasksViewState()
        view.tab = .board; view.groupBy = .priority; view.sort = .dueDate; view.showClosed = true
        view.subtasks = .expanded; view.filters.search = "release"; view.filters.priorities = ["High"]
        view.columns.reorder(["priority", "due"]); view.columns.resize("due", to: 145)
        let saved = TasksSavedView(id: "release", name: "Release", view: view)
        let bytes = try JSONSerialization.data(withJSONObject: [saved.json])
        let restored = TasksSavedView.read(try JSONSerialization.jsonObject(with: bytes))
        #expect(restored == [saved])
        #expect(TasksSavedView.read([["id": "", "name": "bad"], saved.json, saved.json]).count == 1)
    }
    @Test func tagsKeepExistingValuesAndCanRemoveReplaceOrClear() {
        #expect(TasksBulkTags.apply([" release ", "new", "new"], to: ["release", "old"], mode: "add") == ["release", "old", "new"])
        #expect(TasksBulkTags.apply(["release"], to: ["release", "old"], mode: "remove") == ["old"])
        #expect(TasksBulkTags.apply(["new"], to: ["old"], mode: "replace") == ["new"])
        #expect(TasksBulkTags.apply([], to: ["old"], mode: "clear").isEmpty)
    }
}
