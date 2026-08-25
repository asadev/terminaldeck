/**
 * The four panels once they stopped being lists to look at.
 *
 * > *"these pages are not just to view the information — exactly all actions
 * > that we have in desktop application, they should be inside each option of
 * > them."*
 *
 * Everything below is a claim that cannot be established anywhere else. The wire
 * types are covered by unit tests and the host's own suites cover what each
 * panel declares; what nothing else covers is whether a phone **draws** a
 * declared filter, whether a required field actually holds the confirm button
 * shut, and whether a destructive action asks before it fires. All three are the
 * kind of thing that reads correctly in a diff and is wrong under a thumb.
 *
 * ## Running it
 *
 * These need a host that serves `panels`, and `ios/Harness/run.sh host` is not
 * one — the stand-in implements no panel family at all, by design. So this suite
 * takes the same two files `ScreenWalkUITests` and `ReviewScreensUITests` do,
 * and is driven by the same runner, which starts the product's own headless host
 * under its own HOME:
 *
 *     TD_READY_FILE=… TD_CODE_FILE=… xcodebuild test \
 *       -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/PanelActionsUITests
 *
 * It skips rather than fails with nothing at the other end, which is this
 * target's standing rule: a suite that goes red on a laptop with no host running
 * is a suite nobody runs.
 *
 * ## It never completes anything the machine would feel
 *
 * Every case that opens a form cancels it, and the destructive case answers
 * **Keep**. That is not squeamishness — it is the only way the assertion means
 * what it says: *the panel is unchanged afterwards* is half the proof that the
 * confirmation was real. Pressing a Remove is unavoidable, because "asks first"
 * cannot be established without pressing the thing that is supposed to ask; if
 * the dialog does not appear, that is the defect this case exists to find, and
 * the runner's host is a throwaway HOME rather than somebody's machine.
 *
 * ## Menu rows are asked for by their words
 *
 * A row with more than one action puts them behind a `…`, and a SwiftUI `Menu`'s
 * rows are not reachable by `accessibilityIdentifier` — measured twice in this
 * target, once on the New Session menu and once on the Browser one. The label is
 * what the presented row actually carries, so the label is what is asked for.
 */

import XCTest

final class PanelActionsUITests: XCTestCase {

    private var app: XCUIApplication!

    private func env(_ name: String) -> String { ProcessInfo.processInfo.environment[name] ?? "" }

    /// The pairing handshake this target already uses: the phone says when it is
    /// standing at the field, and whatever is driving the run mints a code then.
    /// A code is good for sixty seconds and a Simulator takes longer than that
    /// to build, install and launch, so it cannot be minted in advance.
    private var readyFile: String { env("TD_READY_FILE") }
    private var codeFile: String { env("TD_CODE_FILE") }

    private static let noHost =
        "No host serving panels. Run the runner that starts out/headless/host.mjs under its own "
        + "HOME and passes TD_READY_FILE / TD_CODE_FILE — the harness stand-in serves no panels."

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Where the search field is, and where it is not

    /**
     * The one decision this screen makes for itself, measured.
     *
     * `PanelRequest` carries `query` and the payload carries no flag saying
     * whether the host read it, so `PanelView` names the panels that do —
     * `artifacts.ts`, `store.ts` and `mcp.ts` all filter on `request.query`, and
     * `readiness.ts` says in its own header that it deliberately does not. The
     * asymmetry *is* the assertion: a field over the readiness list would be a
     * control that cannot act, and readiness declares scopes, so this is also
     * what stops anybody "simplifying" the rule into *has scopes, has search*.
     */
    func testSearchIsOfferedWhereTheHostAnswersAQueryAndNowhereElse() throws {
        try connect()

        var seen = 0
        for tool in ["artifacts", "store", "mcp"] {
            guard openPanel(tool) else { continue }
            seen += 1
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5),
                          "\(tool) answers a query on the host and should offer a field for it")
            leavePanel()
        }

        if openPanel("readiness") {
            seen += 1
            // Waited for rather than checked immediately: a field that appears a
            // beat late would pass an instant assertion and be wrong on screen.
            _ = app.buttons["panel.readiness.refresh"].waitForExistence(timeout: 10)
            XCTAssertEqual(app.searchFields.count, 0,
                           "readiness does not read `query`, so a field over it would filter nothing")
            leavePanel()
        }

        try XCTSkipIf(seen == 0, "this machine offered none of the four panels")
    }

    // MARK: - The filters the machine declared

    /**
     * The pills are the host's, and exactly one of them is on.
     *
     * `PanelScope` guarantees it and the screen does not paper over a list where
     * none is — so this checks the guarantee rather than assuming it, and checks
     * the two things the phone owes on top: the chosen pill says *selected* to
     * VoiceOver, because a border is a colour and colour is never the only
     * channel, and it does not take a tap, because re-asking the question
     * already on screen would blank the rows to answer it identically.
     */
    func testAPanelDrawsTheFiltersTheMachineDeclared() throws {
        try connect()

        var panelsWithFilters = 0
        for tool in ["artifacts", "store", "readiness", "mcp"] {
            guard openPanel(tool) else { continue }
            _ = app.buttons["panel.\(tool).refresh"].waitForExistence(timeout: 15)

            let pills = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'panel.\(tool).scope.'"))
            if pills.count > 0 {
                panelsWithFilters += 1
                let chosen = (0 ..< pills.count)
                    .map { pills.element(boundBy: $0) }
                    .filter(\.isSelected)
                XCTAssertEqual(chosen.count, 1,
                               "\(tool) should draw exactly one filter as the one in use")
                XCTAssertFalse(chosen.first?.isEnabled ?? true,
                               "the filter already being shown should not take a tap")
            }
            leavePanel()
        }

        try XCTSkipIf(panelsWithFilters == 0, "no panel on this machine declared any filter")
    }

    // MARK: - Forms

    /**
     * A form opens prefilled, refuses to send while a required box is empty, and
     * leaves the machine alone when it is cancelled.
     *
     * The disabled confirm is the assertion that matters. `PanelField.required`
     * is a boolean on the wire and the only place it can be honoured is here; a
     * form that sent anyway would put the refusal on the machine, where it comes
     * back as a `notice` about a request the person thought they had completed.
     */
    func testAFormRefusesToSendUntilItsRequiredFieldsAreFilled() throws {
        try connect()
        try XCTSkipUnless(openPanel("mcp"), "this machine does not offer the MCP panel")

        let add = app.buttons["panel.mcp.act.add"]
        guard add.waitForExistence(timeout: 15) else {
            leavePanel()
            throw XCTSkip("this machine offered no way to add an MCP server")
        }
        let rowsBefore = rowCount("mcp")
        add.tap()

        let name = app.textFields["panel.form.field.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10),
                      "the Add action declares fields, so it should open a form")
        let submit = app.buttons["panel.form.submit"]
        XCTAssertTrue(submit.exists, "a form should carry the action's own confirm button")
        XCTAssertFalse(submit.isEnabled,
                       "Name is required and empty, so nothing should be sendable yet")

        name.tap()
        name.typeText("td-uitest")
        XCTAssertTrue(submit.isEnabled,
                      "every required field now has something in it")

        app.buttons["panel.form.cancel"].tap()
        XCTAssertTrue(app.buttons["panel.mcp.refresh"].waitForExistence(timeout: 10),
                      "Cancel should put the panel back")
        XCTAssertEqual(rowCount("mcp"), rowsBefore,
                       "a cancelled form must not have reached the machine")
        leavePanel()
    }

    // MARK: - Destructive actions

    /**
     * Remove asks, and answering Keep leaves the machine exactly as it was.
     *
     * Two facts in one case because neither is worth much alone: a dialog that
     * appears and then removes the row anyway is not a confirmation, and a row
     * that survives because the tap missed proves nothing about the dialog.
     *
     * Reached through the row's `…`, because an MCP row carries three verbs and
     * three words beside a server name is a row nobody can read. The menu's rows
     * are asked for by label — see the header.
     */
    func testARemoveAsksBeforeItRemovesAnything() throws {
        try connect()
        try XCTSkipUnless(openPanel("mcp"), "this machine does not offer the MCP panel")
        _ = app.buttons["panel.mcp.refresh"].waitForExistence(timeout: 15)

        let menus = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'panel.mcp.row.' AND identifier ENDSWITH '.more'"))
        guard menus.count > 0 else {
            leavePanel()
            throw XCTSkip("no MCP server on this machine has more than one thing that can be done to it")
        }
        let rowsBefore = rowCount("mcp")

        menus.element(boundBy: 0).tap()
        let remove = app.buttons["Remove"]
        guard remove.waitForExistence(timeout: 5) else {
            app.dismissAnyMenu()
            leavePanel()
            throw XCTSkip("this machine offered no Remove on its first MCP server")
        }
        remove.tap()

        // The dialog, by the one button this app writes on every one of them.
        // Asking for the sheet itself is the fragile version: a confirmation is
        // an action sheet on a phone and an alert on a pad, and the word is the
        // same on both.
        let keep = app.buttons["Keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5),
                      "a destructive action must not fire on a single tap")
        keep.tap()

        XCTAssertTrue(app.buttons["panel.mcp.refresh"].waitForExistence(timeout: 10),
                      "answering Keep should leave the panel where it was")
        XCTAssertEqual(rowCount("mcp"), rowsBefore,
                       "Keep must leave the machine's servers alone")
        leavePanel()
    }

    // MARK: - Getting there

    /**
     * Paired and connected, or skipped.
     *
     * A phone that is already paired starts on the session list with no field to
     * type into — a pairing lasts until it is revoked — so the field is asked for
     * rather than asserted, which is what makes this suite re-runnable against a
     * Simulator nobody erased.
     */
    private func connect() throws {
        if app.reachPairingField(timeout: 8) {
            try XCTSkipIf(readyFile.isEmpty, Self.noHost)
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
            let code = waitForCode(timeout: 240)
            try XCTSkipIf(code.count != 6, Self.noHost)
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            let submit = app.buttons["pairing.submit"]
            if submit.exists && submit.isHittable { submit.tap() }
        }

        let arrived = app.buttons["sessions.new"].waitForExistence(timeout: 180)
            || app.buttons["sessions.more"].waitForExistence(timeout: 5)
        try XCTSkipUnless(arrived, Self.noHost)
    }

    /**
     * One of the four panels, from the Menu tab.
     *
     * False rather than a failure when the row is not drawn: the three
     * capabilities behind these tools are owner-device only, and a machine that
     * withheld `panels` draws no rows at all — which is the app working. Every
     * caller skips on it.
     */
    private func openPanel(_ tool: String) -> Bool {
        guard app.openSettingsTab() else { return false }
        let row = app.descendants(matching: .any)
            .matching(identifier: "machine.tools.\(tool)").firstMatch
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap()
        return true
    }

    /// Back to the Menu screen. The navigation bar's leading button, which is
    /// where a pushed screen's Back is whether or not the bar also carries a
    /// search field.
    private func leavePanel() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        _ = app.buttons["settings.machines"].waitForExistence(timeout: 5)
    }

    /// How many rows the panel is drawing. The identifier carries the row's
    /// position, so counting them is counting the list — which is what "the
    /// machine is unchanged" means on a screen whose answer *is* the list.
    private func rowCount(_ tool: String) -> Int {
        // A full-string regex rather than a prefix: the buttons *on* a row
        // carry identifiers that begin the same way — `…row.0.more`,
        // `…row.0.act.connect` — and counting those too would make the number
        // depend on which verbs the machine happened to offer.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "panel\\.\(tool)\\.row\\.[0-9]+"))
            .count
    }

    private func waitForCode(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: codeFile, encoding: .utf8) {
                let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if digits.count == 6 { return digits }
            }
            usleep(400_000)
        }
        return ""
    }
}
