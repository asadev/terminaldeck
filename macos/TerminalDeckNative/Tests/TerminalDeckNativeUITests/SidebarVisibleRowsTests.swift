import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class SidebarVisibleRowsTests: XCTestCase {
    func testFinishedPinAndLooseFolderAreAbsentFromPanelNavigation() throws {
        let suite = "part45-sidebar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = SIDEBARPins(defaults: defaults)
        pins.toggle("finished"); pins.toggle("working")
        let pages = Sidebar21Store(defaults: defaults)
        pages.initialize(existingUser: false, pages: Sidebar21Pages.standard)
        let working = SidebarItem(id: "working", title: "Working", kind: .session, status: "working")
        let finished = SidebarItem(id: "finished", title: "Finished", kind: .session, status: "exited")
        let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: [working, finished])],
            projects: [.init(id: "/scratch/loose", title: "Loose folder", expanded: false, sessions: [])], selectedId: nil)
        let store = SIDEBARProjectStore(defaults: defaults)
        store.liveIDs = [working.id]
        let panel = SIDEBARPanel(state: state, selected: nil, store: store,
            choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
            openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in },
            sessionPins: pins, pagePins: pages) { EmptyView() } hostFailure: { EmptyView() }
        XCTAssertTrue(panel.rowIDs.contains("working"))
        XCTAssertFalse(panel.rowIDs.contains("finished"))
        XCTAssertFalse(panel.rowIDs.contains("project:/scratch/loose"))
    }
    func testKeyboardOrderMatchesSectionsEvenWhenProjectsPinnedFirst() {
        XCTAssertEqual(SIDEBARVisibleRows.ids(pages: [Sidebar21Pages.projectsID, "tasks", "store"],
            projects: ["/registered"], sessions: ["pinned-running", "running"]),
            ["hoot", "tasks", "store", "project:/registered", "pinned-running", "running"])
    }
    func testHiddenProjectsAndNonRunningPinsCannotEnterNavigation() {
        XCTAssertEqual(SIDEBARVisibleRows.ids(pages: ["tasks"], projects: ["/registered"], sessions: []), ["hoot", "tasks"])
    }
}
