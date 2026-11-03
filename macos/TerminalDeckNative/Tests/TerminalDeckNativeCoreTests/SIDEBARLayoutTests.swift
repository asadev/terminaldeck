import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("SIDEBAR layout", .enabled(if: ProcessInfo.processInfo.environment["TD_WIP"] == "SIDEBAR"))
struct SIDEBARLayoutTests {
    private func session(_ id: String, _ status: String = "working") -> SidebarItem {
        .init(id: id, title: id, kind: .session, status: status)
    }
    private func state(_ items: [SidebarItem], projects: [SidebarProject] = []) -> SidebarState {
        .init(groups: [.init(id: "sessions", title: nil, items: items)], projects: projects, selectedId: nil)
    }

    @Test func runningExcludesHeldStoppedFailedAndPageRows() {
        let rows = [session("live"), session("held:saved"), session("stopped", "exited"),
                    session("broken", "failed"), SidebarItem(id: "tasks", title: "Tasks", kind: .panel)]
        #expect(SIDEBARLayout.running(state(rows)).map(\.id) == ["live"])
    }

    @Test func runningDeduplicatesAcrossGroupsAndCollapsedProjects() {
        let duplicate = session("same")
        let project = SidebarProject(id: "/scratch/project", title: "Project", expanded: false, sessions: [duplicate, session("other")])
        let rows = SIDEBARLayout.running(state([duplicate, duplicate], projects: [project]))
        #expect(Set(rows.map(\.id)) == ["same", "other"])
        #expect(rows.count == 2)
    }

    @Test func liveSessionIDsOverrideStaleStatusAndEmptyMeansNone() {
        let sidebar = state([session("stale", "exited"), session("not-live"), session("held:saved")])
        #expect(SIDEBARLayout.running(sidebar, liveIDs: ["stale", "held:saved"]).map(\.id) == ["stale"])
        #expect(SIDEBARLayout.running(sidebar, liveIDs: []).isEmpty)
    }

    @Test func runningSortsByCreationTimeWithDeterministicTies() {
        let sidebar = state([session("older"), session("newer"), session("tie-a"), session("tie-z")])
        #expect(SIDEBARLayout.running(sidebar, started: ["older": 1, "newer": 20, "tie-a": 10, "tie-z": 10]).map(\.id)
                == ["newer", "tie-z", "tie-a", "older"])
    }

    @Test func agentsViewsShareOneSelectionWhileOtherDestinationsStayDistinct() {
        for id in ["agents-all", "agents-org", "agents-watch", "agents-routines", "agents-skills"] {
            #expect(SIDEBARLayout.selected(id) == "agents-all")
        }
        #expect(SIDEBARLayout.selected("tasks") == "tasks")
        #expect(SIDEBARLayout.selected("project:/scratch/project") == "project:/scratch/project")
        #expect(SIDEBARLayout.selected(nil) == nil)
    }

    @Test func registryColoursUseExactHexAndNamedPaletteThroughFolderResolution() {
        let projects = [SidebarProject(id: "/scratch/a", title: "A", expanded: true, sessions: [])]
        let registry = [PROJProject(id: "a", name: "A", folders: ["/scratch/a"], colour: "#123ABC"),
                        PROJProject(id: "b", name: "B", folders: ["/scratch/b"], colour: "purple")]
        #expect(SIDEBARLayout.colour(path: "/scratch/a/nested", projects: projects, registry: registry) == "#123ABC")
        #expect(SIDEBARLayout.colour(path: "/scratch/b", projects: projects, registry: registry) == "#8E5CF7")
    }

    @Test func fallbackColoursStayStableAndIndependentUsesGraphite() {
        let projects = (0..<10).map { SidebarProject(id: "/scratch/p\($0)", title: "P\($0)", expanded: false, sessions: []) }
        #expect(SIDEBARLayout.colour(path: projects[9].id, projects: projects, registry: []) == "#8E5CF7")
        var expanded = projects
        expanded[9].expanded = true
        #expect(SIDEBARLayout.colour(path: projects[9].id, projects: expanded, registry: []) == "#8E5CF7")
        #expect(SIDEBARLayout.colour(path: nil, projects: projects, registry: []) == "#8E8E93")
        #expect(SIDEBARLayout.colour(path: "/scratch/unknown", projects: projects, registry: []) == "#0A84FF")
        let registry = [PROJProject(id: "first", name: "First", folders: ["/scratch/first"]),
                        PROJProject(id: "second", name: "Second", folders: ["/scratch/second"]),
                        PROJProject(id: "independent", name: "Independent", colour: "graphite")]
        let onlySecond = [SidebarProject(id: "/scratch/second", title: "Second", expanded: false, sessions: [])]
        #expect(SIDEBARLayout.colour(path: "/scratch/second", projects: onlySecond, registry: registry) == "#8E5CF7")
        #expect(SIDEBARLayout.colour(path: projects[9].id, projects: projects, registry: registry) == "#8E5CF7")
    }

    @Test func projectMappingFindsOwningFolderWithoutUsingSelection() {
        let project = SidebarProject(id: "/scratch/a", title: "A", expanded: false, sessions: [session("owned")])
        let special = SidebarProject(id: "hoot-started", title: "Hoot started", expanded: true, sessions: [session("owned")])
        let sidebar = state([session("independent")], projects: [special, project])
        #expect(SIDEBARLayout.project(for: "owned", in: sidebar)?.id == "/scratch/a")
        #expect(SIDEBARLayout.project(for: "independent", in: sidebar) == nil)
        #expect(SIDEBARLayout.project(for: "missing", in: sidebar) == nil)
    }
}
