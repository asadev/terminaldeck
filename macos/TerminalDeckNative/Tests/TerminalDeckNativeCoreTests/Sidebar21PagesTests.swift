import XCTest
@testable import TerminalDeckNativeCore

final class Sidebar21PagesTests: XCTestCase {
    func testMoreIncludesOriginalPagesAndRejectsInventedEntries() {
        let rows: [SidebarItem] = [
            .init(id: "hoot", title: "Hoot", kind: .hoot),
            .init(id: "tasks", title: "Tasks", kind: .panel),
            .init(id: "files", title: "Files", symbol: "doc", kind: .panel),
            .init(id: "alerts", title: "Alerts", kind: .panel),
            .init(id: "settings", title: "Settings", kind: .panel),
            .init(id: "simulators", title: "Simulators", kind: .panel),
            .init(id: "session-fixture", title: "Session", kind: .session)
        ]
        let pages = Sidebar21Pages.catalogue(.init(groups: [.init(id: "all", title: nil, items: rows)], projects: [], selectedId: nil))
        let ids = pages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in Sidebar21Pages.upgradeOrder + ["overview"] { XCTAssertTrue(ids.contains(id), id) }
        for id in ["hoot", "alerts", "settings", "simulators", "session-fixture", "agents-routines", "remote", "files"] { XCTAssertFalse(ids.contains(id), id) }
    }
    func testUpgradePreservesPreviousDrawingOrder() {
        XCTAssertEqual(Sidebar21Pages.upgradeOrder, ["agents-all", "tasks", "artifacts", "sidebar-projects", "servers", "devices", "receiver", "mcp", "store"])
        XCTAssertEqual(Sidebar21Pages.defaults, ["agents-all", "tasks"])
    }
    func testArrowNavigationAndAgentSubpageSelection() {
        let pages = Sidebar21Pages.standard
        XCTAssertEqual(Sidebar21Pages.stepped(nil, delta: 1, pages: pages), "agents-all")
        XCTAssertEqual(Sidebar21Pages.stepped("tasks", delta: 1, pages: pages), "artifacts")
        XCTAssertEqual(Sidebar21Pages.stepped("agents-all", delta: -1, pages: pages), "agents-all")
        XCTAssertEqual(Sidebar21Pages.stepped("store", delta: 1, pages: pages), "overview")
        XCTAssertNil(Sidebar21Pages.stepped(nil, delta: 1, pages: []))
        XCTAssertEqual(Sidebar21Pages.selection("agents-routines"), "agents-routines")
        XCTAssertEqual(Sidebar21Pages.selection("agents-org"), "agents-all")
    }
}
