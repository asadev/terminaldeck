import Foundation
import Testing
@testable import TerminalDeckNativeCore

private let identityProjects: [PROJProject] = [
    .init(id: "alpha", name: "Shared name", folders: ["/work/alpha", "/archive/alpha"]),
    .init(id: "beta", name: "Shared name", folders: ["/work/alpha/nested", "/work/beta"]),
    .init(id: "independent", name: "Independent")
]

@Suite struct PROJTaskIdentityTests {
    @Test func legacyCustomFoldersUseCurrentRegistryAndDeepestBoundary() {
        let rows = [TaskRow(id: "a", project: "/work/alpha/src"), TaskRow(id: "b", project: "/archive/alpha/sub"),
                    TaskRow(id: "nested", project: "/work/alpha/nested/source"), TaskRow(id: "boundary", project: "/work/alpha-old")]
        #expect(!rows[0].hasExplicitProjectID)
        #expect(rows.map { TaskProjects.projectID(for: $0, projects: identityProjects) } == ["alpha", "alpha", "beta", "independent"])
    }

    @Test func explicitIndependentAndOtherIdentityWinOverExecutionFolder() {
        let independent = TaskRow(id: "solo", project: "/work/alpha", projectID: "independent")
        let other = TaskRow(id: "other", project: "/work/alpha/nested", projectID: "alpha")
        #expect(TaskProjects.projectID(for: independent, projects: identityProjects) == "independent")
        #expect(TaskProjects.projectID(for: other, projects: identityProjects) == "alpha")
        #expect(independent.project == "/work/alpha")
    }

    @Test func identityScopeFiltersTasksTrashGoalsAndNilReturnsAll() {
        let state = TasksState(tasks: [.init(id: "a", project: "/work/alpha"), .init(id: "b", project: "/archive/alpha"),
                                     .init(id: "solo", project: "/work/alpha", projectID: "independent")],
                               trash: [.init(id: "trash-a", project: "/archive/alpha"), .init(id: "trash-b", project: "/work/beta")],
                               goals: [.init(id: "goal-a", title: "Alpha", project: "/archive/alpha"),
                                       .init(id: "goal-b", title: "Beta", project: "/work/alpha/nested"),
                                       .init(id: "solo-goal", title: "Solo", project: "/work/alpha", projectID: "independent")])
        let scoped = TaskProjects.scoped(state, projectID: "alpha", projects: identityProjects)
        #expect(scoped.tasks.map(\.id) == ["a", "b"])
        #expect(scoped.trash.map(\.id) == ["trash-a"])
        #expect(scoped.goals.map(\.id) == ["goal-a"])
        #expect(TaskProjects.scoped(state, projectID: nil, projects: identityProjects) == state)
        let solo = TaskProjects.scoped(state, projectID: "independent", projects: identityProjects)
        #expect(solo.tasks.map(\.id) == ["solo"] && solo.goals.map(\.id) == ["solo-goal"])
    }

    @Test func groupsMergeSeveralFoldersAndKeepKeysStableAcrossNameChanges() {
        let rows = [TaskRow(id: "a", project: "/work/alpha", crmStatus: "To-Do"), TaskRow(id: "b", project: "/archive/alpha", crmStatus: "To-Do"),
                    TaskRow(id: "beta", project: "/work/beta", crmStatus: "To-Do"), TaskRow(id: "solo", projectID: "independent")]
        let groups = TaskProjects.groups(rows, projects: identityProjects, showClosed: false)
        #expect(groups.map(\.key) == ["project:alpha", "project:beta", "project:independent"])
        #expect(groups[0].items.map(\.id).sorted() == ["a", "b"])
        #expect(groups[0].label == groups[1].label)
        var renamed = identityProjects; renamed[0].name = "Renamed alpha"
        let later = TaskProjects.groups(rows, projects: renamed, showClosed: false)
        #expect(later.map(\.key) == groups.map(\.key))
        #expect(later[0].label == "Renamed alpha")
    }

    @Test func groupCreateDefaultsSendIdentityAndExecutionFolderSeparately() {
        let groups = TaskProjects.groups([.init(id: "a", project: "/archive/alpha"), .init(id: "solo", project: "/work/alpha", projectID: "independent")],
                                         projects: identityProjects, showClosed: false)
        #expect(groups[0].defaults?.wire["projectId"] as? String == "alpha")
        #expect(groups[0].defaults?.wire["project"] as? String == "/work/alpha")
        #expect(groups[1].defaults?.wire["projectId"] as? String == "independent")
        #expect(groups[1].defaults?.wire["project"] as? String == "")
        #expect(GroupDefaults(status: "Done").wire["projectId"] == nil)
    }

    @Test func decodedLegacyTaskRemainsInferableAndClosedGroupingStillWorks() throws {
        let old = try #require(TasksDecode.task(["id": "local:old", "title": "Old", "project": "/archive/alpha", "local": true, "crmStatus": "Done"]))
        #expect(!old.hasExplicitProjectID)
        #expect(TaskProjects.projectID(for: old, projects: identityProjects) == "alpha")
        let folded = TaskProjects.groups([old], projects: identityProjects, showClosed: false)
        #expect(folded.map(\.key) == ["__closed"] && folded[0].folded)
        let shown = TaskProjects.groups([old], projects: identityProjects, showClosed: true)
        #expect(shown.map(\.key) == ["project:alpha"])
        #expect(TaskProjects.groups([old], open: [.init(path: "/archive/alpha", title: "Old folder")], showClosed: true)[0].label == "Old folder")
    }
}
