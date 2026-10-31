import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane TK (7 Oct 2026): tasks by project — the scoping rule, the "All projects"
// grouping, Move to Project's targets, and old records without a project.

private let app = TaskProject(path: "/work/app", title: "App")
private let site = TaskProject(path: "/work/site", title: "Site")
private let nested = TaskProject(path: "/work/app/packages/ui", title: "UI kit")
private let open = [site, app, nested]

private func row(_ id: String, _ project: String, status: String = "To-Do", assignee: String = "me", due: String? = nil) -> TaskRow {
    TaskRow(id: "local:\(id)", keyId: "local", externalTaskId: id, title: id, project: project, crmStatus: status,
            local: true, assignee: assignee, dueDate: due)
}

@Suite struct TKTaskProjectsTests {
    @Test func aFolderBelongsToTheDeepestOpenProjectHoldingIt() {
        #expect(TaskProjects.belongs("/work/app", to: "/work/app", among: open))
        #expect(TaskProjects.belongs("/work/app/src/", to: "/work/app", among: open))
        #expect(!TaskProjects.belongs("/work/app/packages/ui/button", to: "/work/app", among: open))
        #expect(TaskProjects.belongs("/work/app/packages/ui/button", to: "/work/app/packages/ui", among: open))
        #expect(!TaskProjects.belongs("/work/application", to: "/work/app", among: open))
        #expect(!TaskProjects.belongs("", to: "/work/app", among: open))
        // A current project the sidebar does not list still holds its own folders.
        #expect(TaskProjects.belongs("/elsewhere/x", to: "/elsewhere/", among: open))
    }

    @Test func thisProjectNeedsACurrentProject() {
        #expect(TaskProjects.effective(.this, current: "/work/app") == .this)
        #expect(TaskProjects.effective(.this, current: nil) == .all)
        #expect(TaskProjects.effective(.this, current: "  ") == .all)
        #expect(TaskProjects.effective(.all, current: "/work/app") == .all)
        #expect(TaskProjectScope.this.label == "This project" && TaskProjectScope.all.label == "All projects")
    }

    @Test func thisProjectShowsOnlyItsTasksTrashAndGoals() {
        var state = TasksState(tasks: [row("a", "/work/app"), row("b", "/work/site"), row("c", ""), row("d", "/work/app/lib")],
                               trash: [row("t1", "/work/app"), row("t2", "/work/site")])
        state.goals = [GoalRow(id: "g1", title: "Mine", project: "/work/app"), GoalRow(id: "g2", title: "Theirs", project: "/work/site"),
                       GoalRow(id: "g3", title: "Anywhere")]
        let scoped = TaskProjects.scoped(state, scope: .this, current: "/work/app", open: open)
        #expect(scoped.tasks.map(\.externalTaskId) == ["a", "d"])
        #expect(scoped.trash.map(\.externalTaskId) == ["t1"])
        #expect(scoped.goals.map(\.id) == ["g1", "g3"])
        #expect(TaskProjects.scoped(state, scope: .all, current: "/work/app", open: open) == state)
        #expect(TaskProjects.scoped(state, scope: .this, current: nil, open: open) == state)
    }

    @Test func allProjectsGroupsUnderEachProjectsNameWithNoProjectLast() {
        let tasks = [row("loose", ""), row("old", "/archive/old-thing"), row("a1", "/work/app/src"), row("s1", "/work/site"),
                     row("ui", "/work/app/packages/ui"), row("done", "/work/app", status: "Done")]
        let groups = TaskProjects.groups(tasks, open: open, showClosed: false)
        #expect(groups.map(\.label) == ["Site", "App", "UI kit", "old-thing", "No project", "Done"])
        #expect(groups.map(\.key) == ["project:/work/site", "project:/work/app", "project:/work/app/packages/ui",
                                      "project:/archive/old-thing", "project:none", "__closed"])
        #expect(groups[1].items.map(\.externalTaskId) == ["a1"])
        #expect(groups.last?.folded == true && groups.last?.items.map(\.externalTaskId) == ["done"])
        // "+ Add task" under a group lands in that group's project.
        #expect(groups[1].defaults?.wire["project"] as? String == "/work/app")
        #expect(groups[4].defaults?.wire["project"] as? String == "")
        let shown = TaskProjects.groups(tasks, open: open, showClosed: true)
        #expect(shown.map(\.label) == ["Site", "App", "UI kit", "old-thing", "No project"])
        #expect(shown[1].items.map(\.externalTaskId).sorted() == ["a1", "done"])
    }

    @Test func groupsKeepTheDueOrderInsideAProject() {
        let groups = TaskProjects.groups([row("late", "/work/app", due: "2026-10-20"), row("soon", "/work/app", due: "2026-10-08"),
                                          row("none", "/work/app")], open: open, showClosed: false)
        #expect(groups.count == 1 && groups[0].items.map(\.externalTaskId) == ["soon", "late", "none"])
    }

    @Test func moveToProjectOffersEveryOtherOpenProject() {
        #expect(TaskProjects.moveTargets(for: row("a", "/work/app/src"), open: open).map(\.path) == ["/work/site", "/work/app/packages/ui"])
        #expect(TaskProjects.moveTargets(for: row("b", ""), open: open).map(\.path) == ["/work/site", "/work/app", "/work/app/packages/ui"])
        #expect(TaskProjects.canClearProject(row("mine", "/work/app")))
        #expect(!TaskProjects.canClearProject(row("agent", "/work/app", assignee: "hoot")))
        #expect(!TaskProjects.canClearProject(row("loose", "")))
    }

    @Test func aReminderForAnotherProjectsTaskMovesTheWindowThereFirst() {
        #expect(TaskProjects.revealTarget(for: "/work/site/docs", current: "/work/app", open: open) == "/work/site")
        #expect(TaskProjects.revealTarget(for: "/work/app/packages/ui/x", current: "/work/app", open: open) == "/work/app/packages/ui")
        #expect(TaskProjects.revealTarget(for: "/work/app/src", current: "/work/app/", open: open) == nil)
        #expect(TaskProjects.revealTarget(for: "/work/site", current: nil, open: open) == "/work/site")
        #expect(TaskProjects.revealTarget(for: "", current: "/work/app", open: open) == nil)
        #expect(TaskProjects.revealTarget(for: "/closed/folder", current: "/work/app", open: open) == nil)
    }

    @Test func projectNamesComeFromTheSidebar() {
        #expect(TaskProjects.name(of: "/work/app/", among: open) == "App")
        #expect(TaskProjects.name(of: "/tmp/closed-one", among: open) == "closed-one")
        #expect(TaskProjects.name(of: "", among: open) == "No project")
    }

    @Test func anOldTaskWithoutAProjectDecodesAsNoProject() throws {
        let old = try #require(TasksDecode.task(["id": "local:x", "keyId": "local", "externalTaskId": "x", "title": "Old", "local": true]))
        #expect(old.project == "")
        #expect(TaskProjects.groups([old], open: open, showClosed: false).map(\.label) == ["No project"])
        #expect(TaskProjects.scoped(TasksState(tasks: [old]), scope: .this, current: "/work/app", open: open).tasks.isEmpty)
    }

    @Test func groupDefaultsSendTheProjectOnlyWhenSet() {
        #expect(GroupDefaults(status: "Done").wire["project"] == nil)
        #expect(GroupDefaults(project: "/work/app").wire["project"] as? String == "/work/app")
    }
}
