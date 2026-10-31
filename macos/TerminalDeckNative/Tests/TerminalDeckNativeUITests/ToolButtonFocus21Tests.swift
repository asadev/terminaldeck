import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The real dispatcher with inert effects. No app, alerts, windows or sessions.
@MainActor
final class ToolButtonFocus21Tests: XCTestCase {
    private let first = "11111111-1111-4111-8111-111111111111"
    private let second = "22222222-2222-4222-8222-222222222222"

    private func model(changed: @escaping @MainActor () -> Void = {}) -> NativeButtonActions {
        let model = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() },
            presentSession: { _ in }, confirm: { _ in true }, changed: changed))
        model.ingest(TabsState(tabs: [TabItem(id: first, title: "First", kind: "session", active: true, closable: true),
                                    TabItem(id: second, title: "Second", kind: "session", closable: true)],
                               canNewTerminal: true, canNewBrowser: true))
        model.ingest(SidebarState(groups: [], projects: [SidebarProject(id: "/work", title: "Work", expanded: true,
            sessions: [SidebarItem(id: first, title: "First", kind: .session),
                       SidebarItem(id: second, title: "Second", kind: .session)])], selectedId: first, project: "/work"))
        return model
    }

    func testMissingToolTabReturnsItsErrorWithoutSettingNativeAlertOrChangingSelection() async {
        let model = model(), tabs = model.tabs, sidebar = model.sidebar
        let task = NativeButtonActions.routeForTool(.selectTab("missing-history"), nativeSelection: { _ in false },
                                                   fallback: { model.runForTool(.selectTab("missing-history")) })
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused("That session or page is no longer open."))
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.tabs, tabs)
        XCTAssertEqual(model.sidebar, sidebar)
    }

    func testPersonErrorsRemainVisibleAndToolErrorsAndSuccessLeaveThemUntouched() async {
        let model = model()
        let personResult = await model.run(.selectTab("missing-person-tab")).value
        XCTAssertFalse(personResult)
        let personProblem = model.problem
        XCTAssertEqual(personProblem, "That session or page is no longer open.")
        let toolResult = await model.runForTool(.showPanel("missing-tool-page", focus: nil)).value
        XCTAssertEqual(toolResult, .refused("That page is not available in this window."))
        XCTAssertEqual(model.problem, personProblem)
        let success = await model.runForTool(.selectTab(second)).value
        XCTAssertEqual(success, .completed)
        XCTAssertEqual(model.problem, personProblem)
        XCTAssertEqual(model.tabs.activeID, second)
    }

    func testQueuedToolRequestsCarryIndependentErrors() async {
        let model = model()
        let firstTask = model.runForTool(.selectTab("missing-tab"))
        let secondTask = model.runForTool(.showPanel("missing-page", focus: nil))
        let firstOutcome = await firstTask.value, secondOutcome = await secondTask.value
        XCTAssertEqual(firstOutcome, .refused("That session or page is no longer open."))
        XCTAssertEqual(secondOutcome, .refused("That page is not available in this window."))
        XCTAssertNil(model.problem)
    }

    func testToolAndPersonActionsShareTheSameOrderedQueue() async {
        var selections: [String?] = []
        var current: NativeButtonActions?
        let model = model(changed: { selections.append(current?.tabs.activeID) })
        current = model
        let tool = model.runForTool(.selectTab(second))
        let person = model.run(.selectTab(first))
        let toolOutcome = await tool.value, personResult = await person.value
        XCTAssertEqual(toolOutcome, .completed)
        XCTAssertTrue(personResult)
        XCTAssertEqual(selections, [second, first])
        XCTAssertEqual(model.tabs.activeID, first)
    }

    func testAnExplicitNativeSelectionStillSupersedesAQueuedToolSelection() async {
        let model = model()
        let queued = model.runForTool(.selectTab(second))
        model.followNativeSelection(first)
        let result = await queued.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(model.tabs.activeID, first)
    }

    func testExplicitFinishedHistoryReopensOnlyItsClosedTabAndKeepsSnapshotsFromRevivingOthers() async {
        let model = model()
        let closedFirst = await model.runForTool(.closeSession(first)).value
        let closedSecond = await model.runForTool(.closeSession(second)).value
        XCTAssertEqual(closedFirst, .completed)
        XCTAssertEqual(closedSecond, .completed)
        let history: [String: Any] = ["id": first, "title": "Finished lead conversation", "cwd": "/work", "chat": true, "exitCode": 0]
        let stale: [String: Any] = ["id": second, "title": "Old closed conversation", "cwd": "/work", "chat": true, "exitCode": 0]
        model.created(history)
        model.created(stale)
        let unavailable = await model.runForTool(.selectTab(first)).value
        XCTAssertEqual(unavailable, .refused("That session or page is no longer open."))
        XCTAssertNil(model.problem)

        model.openedHistory(history)
        model.created(stale)
        let opened = await model.runForTool(.selectTab(first)).value
        XCTAssertEqual(opened, .completed)
        XCTAssertEqual(model.tabs.activeID, first)
        XCTAssertEqual(model.tabs.tabs.map(\.id), [first])
        XCTAssertNil(model.sidebar.item(id: second))
        XCTAssertNil(model.problem)
    }

    func testLiveOrMalformedMetadataCannotClearAClosedHistoryTombstone() async {
        let model = model()
        _ = await model.runForTool(.closeSession(first)).value
        model.openedHistory(["id": first, "chat": true, "cwd": "/work"])
        model.openedHistory(["id": first, "chat": false, "exitCode": 0, "cwd": "/work"])
        let result = await model.runForTool(.selectTab(first)).value
        XCTAssertEqual(result, .refused("That session or page is no longer open."))
        XCTAssertNil(model.problem)
    }

    func testFinishedHistoryReopensFromActualEncodedJSONFoundationMetadata() async throws {
        let model = model()
        _ = await model.runForTool(.closeSession(first)).value
        let wire = NativeRPCValue.object([.init("id", .string(first)), .init("title", .string("Finished lead conversation")),
            .init("cwd", .string("/work")), .init("chat", .bool(true)), .init("exitCode", .number(0))])
        let parsed = try NativeRPCValue.parseJSON(wire.encodedJSON())
        let row = try XCTUnwrap(parsed.foundation as? [String: Any])
        XCTAssertTrue(row["exitCode"] is Double)
        XCTAssertNil(row["exitCode"] as? Int)
        model.openedHistory(row)

        let result = await model.runForTool(.selectTab(first)).value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(model.tabs.activeID, first)
        XCTAssertEqual(model.tabs.tabs.map(\.id), [second, first])
        XCTAssertNil(model.problem)
    }
}
