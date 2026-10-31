import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
@testable import TerminalDeckNative

final class Sidebar21Tests: XCTestCase {
    @MainActor private func scratch(_ run: (UserDefaults, Sidebar21Store) throws -> Void) rethrows {
        let name = "sidebar21-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults, Sidebar21Store(defaults: defaults))
    }
    @MainActor func testNewUserStartsWithAgentsAndTasks() throws {
        try scratch { defaults, pins in
            pins.initialize(existingUser: false, pages: Sidebar21Pages.standard)
            XCTAssertEqual(pins.ids, ["agents-all", "tasks"])
            XCTAssertEqual(Sidebar21Store(defaults: defaults).ids, pins.ids)
        }
    }
    @MainActor func testUpgradePinsEveryPreviouslyShownPageOnceAndDoesNotUndoUnpin() throws {
        try scratch { defaults, pins in
            pins.initialize(existingUser: true, pages: Sidebar21Pages.standard)
            XCTAssertEqual(pins.ids, Sidebar21Pages.upgradeOrder)
            pins.setPinned("servers", pinned: false, pages: Sidebar21Pages.standard)
            let reopened = Sidebar21Store(defaults: defaults)
            reopened.initialize(existingUser: true, pages: Sidebar21Pages.standard)
            XCTAssertFalse(reopened.isPinned("servers"))
        }
    }
    @MainActor func testUpgradeDetectionDoesNotMistakeAnEmptyNewFolderForAnExistingUser() throws {
        try scratch { defaults, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar21-upgrade-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(Sidebar21Store.isUpgrade(defaults: defaults, dataRoot: root, state: nil))
            try Data("{}".utf8).write(to: root.appendingPathComponent("settings.json"))
            XCTAssertTrue(Sidebar21Store.isUpgrade(defaults: defaults, dataRoot: root, state: nil))
            try FileManager.default.removeItem(at: root.appendingPathComponent("settings.json"))
            defaults.set("/scratch/project", forKey: "session-start.lastFolder.v1")
            XCTAssertTrue(Sidebar21Store.isUpgrade(defaults: defaults, dataRoot: root, state: nil))
        }
    }
    @MainActor func testPinUnpinAndDragOrderSurviveRestart() throws {
        try scratch { defaults, pins in
            pins.initialize(existingUser: false, pages: Sidebar21Pages.standard)
            pins.toggle("store", pages: Sidebar21Pages.standard)
            pins.setPinned("store", pinned: true, pages: Sidebar21Pages.standard)
            XCTAssertEqual(pins.ids, ["agents-all", "tasks", "store"])
            XCTAssertTrue(pins.move("store", to: "agents-all"))
            XCTAssertEqual(pins.ids, ["store", "agents-all", "tasks"])
            XCTAssertEqual(Sidebar21Store(defaults: defaults).ids, pins.ids)
            pins.toggle("store", pages: Sidebar21Pages.standard)
            pins.setPinned("hoot", pinned: true, pages: Sidebar21Pages.standard)
            XCTAssertEqual(pins.ids, ["agents-all", "tasks"])
            XCTAssertFalse(pins.reorder(["tasks", "tasks"]))
            XCTAssertFalse(pins.reorder(["tasks"]))
            XCTAssertTrue(pins.reorder(["tasks", "agents-all"]))
            XCTAssertEqual(Sidebar21Store(defaults: defaults).ids, ["tasks", "agents-all"])
        }
    }
    @MainActor func testMoreOpenChoosesThePageThenClosesWithoutPinning() throws {
        try scratch { _, pins in
            var actions: [String] = []
            XCTAssertTrue(Sidebar21MoreActions.open("artifacts", pages: Sidebar21Pages.standard,
                choose: { actions.append($0) }, dismiss: { actions.append("closed") }))
            XCTAssertEqual(actions, ["artifacts", "closed"])
            XCTAssertEqual(pins.ids, Sidebar21Pages.defaults)
            XCTAssertFalse(Sidebar21MoreActions.open("hoot", pages: Sidebar21Pages.standard, choose: { _ in XCTFail() }, dismiss: { XCTFail() }))
            XCTAssertTrue(SHELLRoutes.owns(Sidebar21Pages.projectsID))
        }
    }
    @MainActor func testMCPListOpenPinAndReorderUseTheSameStore() throws {
        try scratch { defaults, pins in
            let pages = Sidebar21Pages.standard
            var opened: [String] = []
            @MainActor func call(_ tool: String, _ args: NativeRPCValue = .object([])) throws -> NativeRPCValue {
                try Sidebar21MCP.perform(tool, args: args, pins: pins, pages: pages, open: { opened.append($0) })
            }
            let listing = try call("sidebar.pages.list")
            XCTAssertEqual(listing["pages"].elements?.count, pages.count)
            XCTAssertTrue(listing["pages"].elements?.first { $0["id"].string == "tasks" }?["pinned"].bool == true)
            _ = try call("sidebar.page.open", .object([.init("page", .string(Sidebar21Pages.projectsID))]))
            XCTAssertEqual(opened, [Sidebar21Pages.projectsID])
            _ = try call("sidebar.page.pin", .object([.init("page", .string("store")), .init("pinned", .bool(true))]))
            _ = try call("sidebar.pages.reorder", .object([.init("pages", .array(["store", "tasks", "agents-all"].map(NativeRPCValue.string)))]))
            XCTAssertEqual(Sidebar21Store(defaults: defaults).ids, ["store", "tasks", "agents-all"])
            _ = try call("sidebar.page.pin", .object([.init("page", .string("store")), .init("pinned", .bool(false))]))
            XCTAssertFalse(pins.isPinned("store"))
            XCTAssertThrowsError(try call("sidebar.page.open", .object([.init("page", .string("alerts"))])))
            XCTAssertThrowsError(try call("sidebar.pages.reorder", .object([.init("pages", .array([]))])))
        }
    }
    func testPageRowsHaveNoUnpinControlAndNotificationsAndRunningStaySeparate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/SidebarView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func row(_ item:"))
        let end = try XCTUnwrap(source.range(of: "private func projectRow"))
        let pageRows = source[start.lowerBound..<end.lowerBound]
        XCTAssertFalse(pageRows.contains("Unpin"))
        XCTAssertFalse(pageRows.contains("pins.toggle"))
        XCTAssertFalse(source.contains("header(\"Machines\")"))
        XCTAssertFalse(source.contains("header(\"Integrations\")"))
        XCTAssertTrue(source.contains("header(\"Running\")"))
        XCTAssertTrue(source.contains("identified(sessions)")) // R51: stable rail identity during switches.
        XCTAssertTrue(source.contains("SidebarSettingsLine(model: model)"))
        XCTAssertTrue(source.contains("Button { model.requestDevicesWindow() }"))
        XCTAssertFalse(source.contains("\"bell\""), "no in-app notifications")
    }
    @MainActor func testMCPToolsAreRegisteredAndRejectAnUngrantedCaller() async throws {
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder },
            session: { _, _ in .null }, runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
            authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let tools = try Sidebar21MCP.definitions(access: access, perform: { _, _ in XCTFail("Denied action reached the store"); return .null })
        XCTAssertEqual(tools.map(\.spec.wireName), ["sidebar_pages_list", "sidebar_page_open", "sidebar_page_pin", "sidebar_pages_reorder"])
        let denied = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: "/scratch", attended: true,
            allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init())
        for tool in tools {
            let reply = try await tool.handler(denied, .object([]))
            XCTAssertTrue(reply.isError)
        }
    }
    @MainActor func testRenderSidebarAndMoreLightDarkAndNarrowWithoutStartingTheApp() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let destination = try XCTUnwrap(ProcessInfo.processInfo.environment["TD_SIDEBAR21_FRAMES"])
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try scratch { _, pins in
            pins.initialize(existingUser: true, pages: Sidebar21Pages.standard)
            let session = SidebarItem(id: "fixture-session", title: "Review the sidebar", kind: .session, status: "working")
            let state = SidebarState(groups: [.init(id: "sessions", title: nil, items: [session])], projects: [
                .init(id: "/scratch/project", title: "Example project", expanded: false, sessions: [session])], selectedId: "tasks")
            let projects = SIDEBARProjectStore()
            projects.projects = [.init(id: "example", name: "Example project", folders: ["/scratch/project"])]
            projects.liveIDs = [session.id]
            func panel(_ width: CGFloat) -> some View {
                SIDEBARPanel(state: state, selected: state.selectedId, store: projects,
                    choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
                    openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in }, pagePins: pins) {
                        HStack { Label("Settings", systemImage: "gearshape"); Spacer(); Image(systemName: "laptopcomputer.and.iphone") }
                            .foregroundStyle(.secondary).font(.system(size: 13))
                    } hostFailure: { EmptyView() }.frame(width: width, height: 820)
            }
            for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                for width in [CGFloat(264), CGFloat(240)] {
                    try render(AnyView(panel(width)), size: .init(width: width, height: 820), scheme: scheme,
                        to: output.appendingPathComponent("sidebar21-panel-\(name)-\(Int(width)).png"))
                    let expanded = HStack(alignment: .top, spacing: 12) {
                        panel(width)
                        Sidebar21More(pages: Sidebar21Pages.standard, pins: pins, choose: { _ in }, dismiss: {})
                            .padding(.top, 84).padding(.trailing, 12)
                    }.background(DeckTokens.frame)
                    try render(AnyView(expanded), size: .init(width: width + 272, height: 820), scheme: scheme,
                        to: output.appendingPathComponent("sidebar21-more-\(name)-\(Int(width)).png"))
                }
            }
        }
        XCTAssertFalse(NSApp.isActive)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }
    @MainActor private func render(_ view: AnyView, size: CGSize, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 1000)
    }
}
