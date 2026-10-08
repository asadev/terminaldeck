import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class UIGMemoryVisibilityTests: XCTestCase {
    func testSidebarRemovesOnlyMemoryPanelAndClearsItsSelection() {
        let session = SidebarItem(id: "memory", title: "Memory", kind: .session)
        let panel = SidebarItem(id: "memory", title: "Memory", kind: .panel)
        let tasks = SidebarItem(id: "tasks", title: "Tasks", kind: .panel)
        let state = SidebarState(groups: [.init(id: "pages", title: "Pages", items: [panel, tasks])],
            projects: [.init(id: "/example", title: "Example", expanded: true, sessions: [session])],
            selectedId: "memory", project: "/example", openFile: "readme.md", focus: "graph")
        let result = UIGMemoryVisibility.sidebar(state)
        XCTAssertEqual(result.groups.first?.items, [tasks])
        XCTAssertEqual(result.projects.first?.sessions, [session])
        XCTAssertEqual(result.project, state.project)
        XCTAssertEqual(result.openFile, state.openFile)
        XCTAssertNil(result.selectedId)
        XCTAssertNil(result.focus)
        XCTAssertEqual(state.groups.first?.items, [panel, tasks], "The source state is preserved.")
    }

    func testSessionNamedMemoryAndOrdinarySelectionStayAvailable() {
        let session = SidebarItem(id: "memory", title: "Memory", kind: .session)
        let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: [session])],
            projects: [], selectedId: "memory")
        XCTAssertEqual(UIGMemoryVisibility.sidebar(state), state)
        XCTAssertTrue(UIGMemoryVisibility.showsScreen(.init(kind: .session, id: "memory")))
    }

    func testTabsAndRestoredWindowsDropMemoryWithoutRemovingSessionsOrHoot() {
        let tabs = TabsState(tabs: [.init(id: "memory", title: "Memory", kind: "panel", active: true),
            .init(id: "memory", title: "Memory", kind: "session"),
            .init(id: "tasks", title: "Tasks", kind: "panel")], canNewTerminal: true, canNewBrowser: true)
        let result = UIGMemoryVisibility.tabs(tabs)
        XCTAssertEqual(result.tabs.map(\.kind), ["session", "panel"])
        XCTAssertNil(result.activeID)
        XCTAssertTrue(result.canNewTerminal)
        XCTAssertTrue(result.canNewBrowser)
        let refs: [ScreenRef] = [.init(kind: .panel, id: "memory"), .init(kind: .session, id: "memory"),
            .init(kind: .panel, id: "hoot", isHoot: true)]
        XCTAssertEqual(UIGMemoryVisibility.restoredScreens(refs), Array(refs.dropFirst()))
    }

    func testPaletteAndMenuUseIdentityRatherThanDisplayText() {
        let commands = [PaletteCommand(id: "view.memory", title: "Graph"),
            PaletteCommand(id: "view.tasks", title: "Memory"),
            PaletteCommand(id: "hoot.memory", title: "Hoot's memory")]
        XCTAssertEqual(UIGMemoryVisibility.palette(commands).map(\.id), ["view.tasks", "hoot.memory"])
        for id in ["memory", "open-memory", "view.memory", "panel.memory", "memory.open", "view:memory", "panel:memory"] {
            XCTAssertFalse(UIGMemoryVisibility.showsCommand(id), id)
            XCTAssertFalse(UIGMemoryVisibility.showsMenuCommand(.init(.view, "Graph", .page(id))))
        }
        XCTAssertTrue(UIGMemoryVisibility.showsMenuCommand(.init(.view, "Memory", .page("view.tasks"))))
    }

    func testNativePageDoorCannotOpenThePausedMemoryPanel() {
        XCTAssertFalse(UIGMemoryVisibility.showsPageCommand(.showPanel("memory", focus: "graph")))
        XCTAssertTrue(UIGMemoryVisibility.showsPageCommand(.showPanel("tasks", focus: nil)))
        XCTAssertTrue(UIGMemoryVisibility.showsPageCommand(.select("memory")), "Selection must check the row kind at the AppModel owner.")
        XCTAssertTrue(UIGMemoryVisibility.showsPageCommand(.nativeScreens(["memory", "tasks"])),
            "Keep Memory registered so the retained page does not mount behind the unavailable native view.")
    }

    func testOnlyNativeMemoryToolNamespaceIsHidden() {
        for (id, wire) in [("memory.search", "memory_search"), ("memory.read", "memory_read"), ("memory.graph", "memory_graph")] {
            XCTAssertFalse(UIGMemoryVisibility.showsTool(id: id, wireName: wire))
        }
        for (id, wire) in [("hoot.memory", "hoot_memory"), ("knowledge.search", "knowledge_search"),
            ("docker.stats", "docker_stats"), ("memoryProfiler.read", "memoryProfiler_read")] {
            XCTAssertTrue(UIGMemoryVisibility.showsTool(id: id, wireName: wire))
        }
    }

    func testActualSidebarAndTabWireKindsPreventNameCollisions() throws {
        let sidebarData = Data(#"{"groups":[{"id":"project","title":"Project","items":[{"id":"memory","title":"Memory","kind":"panel"},{"id":"tasks","title":"Tasks","kind":"panel"}]}],"projects":[{"id":"/work/Memory","title":"Memory","expanded":true,"sessions":[{"id":"s1","title":"Memory","kind":"session"}]}],"selectedId":"s1","project":"/work/Memory"}"#.utf8)
        let state = try JSONDecoder().decode(SidebarState.self, from: sidebarData)
        let filtered = UIGMemoryVisibility.sidebar(state)
        XCTAssertEqual(filtered.groups.first?.items.map(\.id), ["tasks"])
        XCTAssertEqual(filtered.projects, state.projects)
        XCTAssertEqual(filtered.selectedId, "s1")
        XCTAssertEqual(filtered.project, "/work/Memory")
        let tabData = Data(#"{"tabs":[{"id":"memory","title":"Memory","kind":"session","active":true},{"id":"b1","title":"Memory","kind":"browser"}],"canNewTerminal":true,"canNewBrowser":true}"#.utf8)
        let tabs = try JSONDecoder().decode(TabsState.self, from: tabData)
        XCTAssertEqual(UIGMemoryVisibility.tabs(tabs), tabs)
    }
}
