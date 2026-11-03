import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U116 (#160, Asad's decision 7): a session an AI starts through the app's tools is filed under its own
/// folder's project and opens as a quiet tab there: listed and in the tab bar, never selected.
@MainActor
final class QuietTabsTests: XCTestCase {
    private let mine = "11111111-1111-4111-8111-111111111111"
    private let started = "44444444-4444-4444-8444-444444444444"

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }

    func testAnAIStartedSessionGetsATabAndARowWithoutTakingTheSelection() {
        let model = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() }, presentSession: { _ in }, confirm: { _ in true }))
        model.ingest(TabsState(tabs: [TabItem(id: mine, title: "Mine", kind: "session", active: true, closable: true)],
                               canNewTerminal: true, canNewBrowser: true))
        model.ingest(SidebarState(groups: [], projects: [SidebarProject(id: "/work", title: "Work", expanded: true,
            sessions: [SidebarItem(id: mine, title: "Mine", kind: .session)])], selectedId: mine, project: "/work"))
        model.created(["id": started, "title": "Security → Conversation", "cwd": "/work", "origin": "copilot"])
        XCTAssertTrue(model.tabs.tabs.contains { $0.id == started }, "a tab in the tab bar")
        XCTAssertEqual(model.tabs.activeID, mine, "the person's tab stays in front")
        XCTAssertEqual(model.sidebar.selectedId, mine)
        XCTAssertEqual(model.sidebar.projects.first { $0.id == "/work" }?.sessions.map(\.id), [mine, started], "listed in its own project")
    }

    func testEveryToolDoorStartOpensItQuietlyInItsFoldersProject() throws {
        let production = try source("TerminalDeckNative/NativeCompositionProduction.swift")
        XCTAssertTrue(production.contains("let started = try await joins.startSession(input)\n                await NativeButtonActions.openQuietly(started)"))
        for file in ["TerminalDeckNative/NativeCompositionSessionChats.swift", "TerminalDeckNative/NativeCompositionTeamChats.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("projectID: args[\"projectId\"].string ?? PROJProjects.resolve(projectID: nil, folder: cwd)"), file)
            XCTAssertTrue(text.contains("await NativeButtonActions.openQuietly(value)"), file)
        }
        let actions = try source("TerminalDeckNative/NativeButtonActions.swift")
        let quiet = try XCTUnwrap(actions.range(of: "static func openQuietly")).upperBound
        let body = actions[quiet...].prefix(200)
        XCTAssertFalse(body.contains("selectTab") || body.contains("activate"), "opening quietly never selects")
    }
}
