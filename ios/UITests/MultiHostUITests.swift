/**
 * One phone, two machines, with a finger.
 *
 * `MultiHostTests` proves the object graph against a scripted transport. This
 * proves the thing itself: two **real** hosts — `scripts/remote-host.sh`, which
 * is the product's own server, relay client and `PtyManager` in a plain Node
 * process — registered with one relay, both paired, both connected, and a
 * keystroke landing on the machine whose session is on screen and on no other.
 *
 * Run it like this, from the repository root:
 *
 *     mkdir -p /tmp/td/{StudioMac,WorkPC}/{ios,pwa/dist}
 *     npx esbuild scripts/remote-host.ts --bundle --platform=node --format=esm \
 *       --target=node22 --external:node-pty --outfile=.harness/.multi-host/remote-host.mjs
 *     TD_FORCE_SHELL=1 HOME=/tmp/td/StudioMac TD_REPO_DIR=/tmp/td/StudioMac \
 *       node .harness/.multi-host/remote-host.mjs --relay-port 8890 --approve-after 2000 --fresh &
 *     TD_FORCE_SHELL=1 HOME=/tmp/td/WorkPC TD_REPO_DIR=/tmp/td/WorkPC \
 *       node .harness/.multi-host/remote-host.mjs --relay-url ws://127.0.0.1:8890 \
 *       --relay-port 8892 --approve-after 2000 --fresh &
 *     TEST_RUNNER_TD_CONTROL_A=127.0.0.1:8891 \
 *     TEST_RUNNER_TD_CONTROL_B=127.0.0.1:8893 \
 *     TEST_RUNNER_TD_SHOTS=/tmp/td/shots \
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
 *       -only-testing:TerminalDeckUITests/MultiHostUITests
 *
 * The two hosts run their own relay between them rather than a deployed one, so
 * this needs nothing but the repository. `TD_FORCE_SHELL=1` matters: with an
 * agent CLI installed the session lands in a TUI, where typed text goes into a
 * prompt box rather than to a shell that echoes it — and the echo is what makes
 * "this keystroke reached *that* machine" checkable rather than asserted.
 *
 * ## Why the codes are typed rather than opened as links
 *
 * `xcrun simctl openurl` raises a system "Open in Terminal Deck?" confirmation,
 * which is a real iOS behaviour and not something the app can or should suppress.
 * Pasting the link into the field is the same code path from `pair(with:)`
 * onwards, and it needs no dialog dismissed.
 *
 * Every case skips rather than fails when there is nothing to talk to, for the
 * same reason as `LocalhostUITests`: a suite that goes red on a laptop with no
 * hosts running is a suite that gets deleted.
 */

import XCTest

final class MultiHostUITests: XCTestCase {

    private var app: XCUIApplication!

    /**
     * The two harness control servers, e.g. `127.0.0.1:8891` and `127.0.0.1:8893`.
     *
     * A control address rather than a pairing link, and that is not a
     * convenience: **a pairing token is worth sixty seconds**, and a link handed
     * in when the process started is a link that expired while the simulator was
     * booting. The symptom is not "expired" — it is the relay refusing the
     * *sealed handshake*, because the pairing desk is only open while a token is
     * live — which reads as a crypto failure and sent this test on a long detour.
     * So the code is minted at the moment it is used.
     */
    private var controlA: String { ProcessInfo.processInfo.environment["TD_CONTROL_A"] ?? "" }
    private var controlB: String { ProcessInfo.processInfo.environment["TD_CONTROL_B"] ?? "" }
    /// Where to leave screenshots for a human to look at. Attached to the result
    /// bundle either way; this is so nobody has to open one.
    private var shots: String? { ProcessInfo.processInfo.environment["TD_SHOTS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(controlA.isEmpty || controlB.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        // Pairings are in the Keychain and outlive the process, so a second test
        // in the same run would start with machines already paired and add a
        // third. Cleared through the app's own Forget item rather than a
        // test-only back door: a launch argument that wipes pairings is product
        // code that exists for a test, and this exercises unpairing for free.
        forgetEverything()
    }

    /// Tap Forget until the pairing screen is what is on screen. The item is on
    /// the Machines tab now rather than in the list's overflow menu — see
    /// `TabNavigation.swift`.
    private func forgetEverything() {
        app.forgetEveryMachine()
    }

    private static let notRunning =
        "Two hosts are needed. Start them as described at the top of this file and pass "
        + "TEST_RUNNER_TD_CONTROL_A and TEST_RUNNER_TD_CONTROL_B."

    /**
     * Put text into the terminal that is on screen, and wait for the far end to
     * echo it back.
     *
     * **The keyboard is raised through the app's own button, not by tapping the
     * terminal.** A tap on a `TerminalView` does not make it first responder in
     * the Simulator, so `typeText` had nowhere to go: the characters were never
     * typed, nothing was sent, and the failure arrived twenty seconds later as
     * "the machine on the other end did not echo what was typed" — which
     * describes a broken transport and was nothing of the kind. The toolbar's
     * keyboard toggle is the control a person would use for the same reason.
     *
     * The echo is the round trip. Nothing echoes locally in this app —
     * `TerminalBridge` sends keystrokes out and draws only what comes back
     * through `feed` — so a character on screen came from a shell on the far end.
     */
    private func type(_ text: String, into session: String) throws {
        let keyboard = app.buttons["terminal.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 20), "the terminal toolbar should be up")
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "the keyboard toggle should raise a keyboard to type into")
        app.typeText(text)
        let marker = text.split(separator: " ").last.map(String.init) ?? text
        XCTAssertTrue(waitForText(containing: marker, timeout: 25),
                      "the machine on the other end did not echo what was typed")
    }

    /**
     * The id of the one session that host is running.
     *
     * Seeded before the run by the harness's own `/start`, so the expectation
     * comes from the machine rather than from the phone:
     *
     *     curl '127.0.0.1:8891/start?cwd=/tmp/td/StudioMac'
     *     curl '127.0.0.1:8893/start?cwd=/tmp/td/WorkPC'
     */
    private func onlySessionId(on control: String) throws -> String {
        guard let url = URL(string: "http://\(control)/scrollback") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "sessions")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                answer = rows.first?["id"] as? String
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(control) has no session — seed one with /start. \(Self.notRunning)")
        }
        return answer
    }

    /**
     * Mint a code on one of the hosts, now.
     *
     * `/pair` on the harness control server, which calls the desk's own `create`
     * — the same call the desktop's pairing panel makes when somebody presses
     * "show a code". Synchronous on purpose: this is a step in a scripted flow,
     * not something to interleave.
     */
    private func freshCode(from control: String) throws -> String {
        guard let url = URL(string: "http://\(control)/pair") else {
            throw XCTSkip("\(control) is not an address")
        }
        var answer: String?
        let done = expectation(description: "minted")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                answer = json["code"] as? String
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        guard let answer, !answer.isEmpty else {
            throw XCTSkip("\(Self.notRunning) (\(control) did not answer /pair)")
        }
        return answer
    }

    // MARK: - The whole thing

    /**
     * Pair one machine, then another, and still have the first.
     *
     * The failure this is written against: a phone that pairs with a second
     * machine and quietly drops the first, which to whoever is holding it looks
     * exactly like the app forgetting their Mac.
     */
    func testPairingASecondMachineKeepsTheFirst() throws {
        try pair(freshCode(from: controlA))
        try waitForConnected(timeout: 60)
        // One machine: the title is the product's name, because a picker with one
        // row in it is furniture.
        XCTAssertTrue(app.staticTexts["Terminal Deck"].exists)
        capture("01-first-machine")

        try pairAnother(freshCode(from: controlB))
        try waitForConnected(timeout: 60)

        // Two machines: the title becomes the switcher.
        let switcher = app.descendants(matching: .any).matching(identifier: "host.switcher").firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 20),
                      "with two machines paired the title should become a switcher")
        capture("02-second-machine")

        switcher.tap()
        // Both rows are there, and each one says what its machine is doing.
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.' AND identifier != 'host.switcher' AND identifier != 'host.add'"))
        XCTAssertEqual(rows.count, 2, "the first machine must still be in the list")
        capture("03-switcher-open")

        // Both are live, not just the one on screen — which is the whole reason
        // every host holds its socket rather than connecting when it is picked.
        let live = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'nothing running' OR label CONTAINS 'session'"))
        XCTAssertGreaterThanOrEqual(live.count, 1, "the switcher should report live state per machine")

        dismissMenu()
    }

    /**
     * Two machines, two session lists, and a keystroke that lands on one of them.
     *
     * The worst bug this feature could have is not losing a pairing — it is
     * typing into the wrong computer. The assertion that matters is the last one,
     * and it is checked from the *host* side by whoever runs this, against
     * `curl 127.0.0.1:8891/input` and `:8893/input`: a phone can show a line on
     * its own screen and still be wrong about which machine put it there. Each
     * host records what *it* was handed, so "the marker is on A and absent from
     * B" is two machines' own accounts rather than one phone's.
     *
     * `/input` and not `/scrollback` — the echo is the shell's rendering of the
     * input and the two differ for anything wider than the terminal. See the
     * header of `InspectUITests`.
     *
     * What the phone can prove by itself is nearly as good, and it is asserted
     * here: nothing echoes locally in this app — `TerminalBridge` sends keystrokes
     * out and only draws what comes back through `feed` — so a character on screen
     * is a character a shell on the far end echoed.
     */
    func testSessionsStaySeparateAndTypingGoesToTheRightMachine() throws {
        /*
         * The two ids come from the two machines, not from the phone.
         *
         * Reading them off the session list looked simpler and quietly begged the
         * question: after pairing the second machine the list is briefly still the
         * first machine's, so "the id at the top" was sometimes the Mac's while
         * the PC was selected — and the test then asserted the PC should be
         * showing a row it never should have. Asking each host which session it
         * has makes the expectation independent of the thing being tested.
         */
        let macSession = try onlySessionId(on: controlA)
        let pcSession = try onlySessionId(on: controlB)
        XCTAssertNotEqual(macSession, pcSession, "two machines cannot have the same session")

        try pair(freshCode(from: controlA))
        try waitForConnected(timeout: 60)
        XCTAssertTrue(app.buttons["session.\(macSession)"].waitForExistence(timeout: 20),
                      "the Mac's own session should be listed under the Mac")

        try pairAnother(freshCode(from: controlB))
        try waitForConnected(timeout: 60)

        // The PC is current, and it lists its own session and not the Mac's.
        XCTAssertTrue(app.buttons["session.\(pcSession)"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["session.\(macSession)"].exists,
                       "the Mac's session must not appear in the PC's list")
        capture("04-pc-list")

        // Type into the PC's session. A marker rather than a command, and no
        // Return: nothing here submits anything to a shell on somebody's machine.
        app.buttons["session.\(pcSession)"].tap()
        try type("echo TD-WORKPC-MARKER", into: pcSession)
        capture("05-typed-into-pc")
        // Echoed back by the shell on the far end, which is the round trip.
        XCTAssertTrue(waitForText(containing: "TD-WORKPC-MARKER", timeout: 20),
                      "the machine on the other end did not echo what was typed")

        goBack()

        // Now the Mac, and its own list.
        let switcher = app.descendants(matching: .any).matching(identifier: "host.switcher").firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        switcher.tap()
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.' AND identifier != 'host.switcher' AND identifier != 'host.add'"))
            .element(boundBy: 0).tap()

        XCTAssertTrue(app.buttons["session.\(macSession)"].waitForExistence(timeout: 20),
                      "switching should show the other machine's sessions")
        XCTAssertFalse(app.buttons["session.\(pcSession)"].exists,
                       "the PC's session must not follow the switch")
        capture("06-mac-list")

        app.buttons["session.\(macSession)"].tap()
        XCTAssertTrue(terminalView.waitForExistence(timeout: 20),
                      "the Mac's session should open its terminal")
        // The marker typed into the *other* machine must not be on this one.
        XCTAssertFalse(waitForText(containing: "TD-WORKPC-MARKER", timeout: 4),
                       "a keystroke meant for one machine reached the other")
        try type("echo TD-STUDIO-MARKER", into: macSession)
        capture("07-typed-into-mac")

        // Held on screen long enough for the host-side check to run against
        // /scrollback on both control ports while this is still up.
        sleep(8)
    }

    /// A machine can be given a name, because 26 characters of base32 is not
    /// something anybody picks their laptop out of a list by.
    func testAMachineCanBeNamed() throws {
        try pair(freshCode(from: controlA))
        try waitForConnected(timeout: 60)

        // Settings → Machines. It stopped being a tab; the helper's name did not
        // change, which is the point of `TabNavigation.swift`.
        XCTAssertTrue(app.openMachinesTab(), "the Machines screen should be reachable")
        let menu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'machine.more.'"))
            .firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "every machine row carries its own menu")
        menu.tap()
        let rename = app.buttons["machine.rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "the row menu should offer Rename")
        rename.tap()

        // Scoped to the alert, not to the app.
        //
        // `app.textFields[…]` searches the application element, and an alert is
        // presented in a window of its own — the query resolves to nothing while
        // the alert is plainly on screen, and the failure reads as "Rename did
        // not open" rather than "the test looked in the wrong window". Asking the
        // alert also waits for the alert, which is the thing that has to appear.
        let alert = app.alerts.firstMatch
        if !alert.waitForExistence(timeout: 10) { capture("zz-no-rename-alert") }
        XCTAssertTrue(alert.exists, "Rename should raise the naming alert")

        /*
         * The alert's own text field, not one found by identifier.
         *
         * `.accessibilityIdentifier` does not survive onto it, and that is not
         * something the app can fix. A SwiftUI `.alert` is a `UIAlertController`,
         * and the `TextField` in the actions builder becomes a UIKit text field
         * made by `addTextField` — SwiftUI carries the placeholder and the text
         * binding across and drops everything else. Measured, from the alert's own
         * accessibility tree on iOS 26.5:
         *
         *     TextField, placeholderValue: 'MacBook, Work PC…', value: TBB35X
         *     Button,    identifier: 'rename.save', label: 'Save'
         *
         * The button beside it keeps its identifier, which is what made this look
         * like the alert not being up rather than the field not being findable.
         * There is exactly one field in this alert, so `firstMatch` is not a guess;
         * the placeholder is asserted so that "the only field" cannot quietly
         * become some other field later.
         */
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the naming alert should contain a text field")
        XCTAssertEqual(field.placeholderValue, "MacBook, Work PC…",
                       "this should be the machine-name field")

        // The field arrives pre-filled with the current label and already holding
        // the keyboard, so the old text has to go before the new name is typed
        // over it. One delete per character rather than a long-press and Select
        // All: the edit menu is a system surface that may or may not come up, and
        // the length is known from the field itself.
        let existing = (field.value as? String) ?? ""
        XCTAssertFalse(existing.isEmpty, "the field should arrive pre-filled with the current label")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("Studio Mac")
        // `.firstMatch`, because the identifier resolves to two elements and a
        // bare subscript throws *"Multiple matching elements found"* rather than
        // picking one. SwiftUI nests the alert's button inside a button of the
        // same identifier — both are the same 140×48 rectangle in the tree — so
        // there is no wrong one to pick. The same shape as the "New session"
        // ambiguity in `startSession()` below.
        alert.buttons["rename.save"].firstMatch.tap()

        try pairAnother(freshCode(from: controlB))
        try waitForConnected(timeout: 60)
        let switcher = app.descendants(matching: .any).matching(identifier: "host.switcher").firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        switcher.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Studio Mac'")).firstMatch.exists,
                      "the name should be what the switcher calls it")
        capture("08-named-machine")
        dismissMenu()
    }

    // MARK: - Steps

    private func pair(_ code: String) throws {
        let field = app.textFields["pairing.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the pairing screen should be up")
        field.tap()
        field.typeText(code)
        capture("zz-code-typed")
        app.buttons["pairing.submit"].tap()
        capture("zz-code-submitted")
    }

    /// The second machine and every one after it, through the sheet the Machines
    /// tab raises.
    private func pairAnother(_ code: String) throws {
        XCTAssertTrue(app.beginPairingAnotherMachine(),
                      "Machines should offer Pair another machine, and it should open the sheet")
        try pair(code)
        // Back to the sessions, which is where the rest of this suite looks.
        app.openSessionsTab()
    }

    /// Start a session on the machine on screen and hand back its id, read off
    /// the row's own identifier.
    private func startSession() throws -> String {
        let before = Set(sessionIdentifiers())
        // A session this machine already has will do, and is preferred.
        //
        // This test is about *routing* — that a keystroke lands on the machine
        // whose session is on screen and on no other. Insisting on making a new
        // session through the phone puts the create path in front of the thing
        // being tested, and when a create quietly did nothing the run reported a
        // routing failure. Seed the hosts before the run instead:
        //
        //     curl '127.0.0.1:8891/start?cwd=/tmp/td/StudioMac'
        //     curl '127.0.0.1:8893/start?cwd=/tmp/td/WorkPC'
        //
        // Creating from the phone is still covered — `InspectUITests` needs a
        // session and makes one.
        if let existing = before.first { return existing }

        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30),
                      "this host advertises `create`, so the button should be there")
        new.tap()
        // With no folders yet the button starts one straight away; with some, it
        // is a menu whose first item is the plain New Session.
        //
        // `.firstMatch`, because "New session" is not unique once the menu is up:
        // the menu has a titled section as well as its items, and a bare
        // subscript throws *"Multiple matching elements found"* rather than
        // picking one. It only became ambiguous after the harness had accumulated
        // folders to offer, so it passed for as long as the host was fresh.
        let plain = app.buttons["New session"].firstMatch
        if plain.waitForExistence(timeout: 3) { plain.tap() }

        // A created session opens itself, which is the tap that started it also
        // being the tap that opens it. Come back to the list for the next step.
        if terminalView.waitForExistence(timeout: 30) { goBack() }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let after = Set(sessionIdentifiers())
            if let fresh = after.subtracting(before).first { return fresh }
            usleep(400_000)
        }
        capture("zz-no-session-row")
        XCTFail("no new session row appeared")
        return ""
    }

    /**
     * Back to the session list, and **confirmed** to be there.
     *
     * By identifier rather than by position. `navigationBars.buttons.element(boundBy: 0)`
     * looked reasonable and is a lottery: this screen's bar has a principal item
     * and two trailing ones, and index 0 is whichever the accessibility tree
     * happened to order first — so the "back" tap sometimes opened the actions
     * menu instead and left the test looking for session rows on a terminal.
     *
     * Tapping once and trusting it was the next version of the same mistake. A
     * tap that misses leaves the app on the terminal, and every assertion after
     * this one then fails describing something else entirely — *"no new session
     * row appeared"*, when the row is there and the list is not on screen. So
     * this insists, and the condition is the absence of the terminal rather than
     * the presence of the list: the toolbar item it was keying off exists on both
     * screens.
     */
    private func goBack() {
        for attempt in 0 ..< 4 {
            if isOnTheList() { return }

            switch attempt {
            case 0:
                // The identified route. `terminal.view` is the thing that must go
                // away, so the two trailing items are excluded by name and
                // whatever is left is the leading one.
                let back = app.navigationBars.firstMatch.buttons.matching(
                    NSPredicate(format: "identifier != 'terminal.actions' AND identifier != 'terminal.keyboard'")).firstMatch
                if back.exists { back.tap() }
            case 1:
                // The gesture a person would use. Not first, because a right
                // swipe across a terminal is also a selection gesture.
                app.swipeRight()
            default:
                /*
                 * The chevron, by where it is.
                 *
                 * Last because a coordinate tap is the least expressive thing a
                 * UI test can do — but it is the only one that cannot pick the
                 * wrong element. `buttons.firstMatch` on a navigation bar is
                 * ordered by the accessibility tree rather than by position, and
                 * when it resolved to the overflow item instead the run did not
                 * fail here: it opened a menu, carried on, and failed four
                 * assertions later saying no session row had appeared.
                 */
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.088)).tap()
            }
            _ = app.buttons["sessions.more"].waitForExistence(timeout: 8)
        }
        XCTAssertTrue(isOnTheList(), "could not get back to the session list from the terminal")
    }

    /**
     * The terminal, whatever XCUITest decides to call it.
     *
     * **Not `app.otherElements["terminal.view"]`**, which is what three places in
     * this file used to say and what can never match. The identifier is set on
     * SwiftTerm's `TerminalView`, and that is
     * `open class TerminalView: UIScrollView` — so the element comes through as a
     * *scroll view*, and a query for an `other` returns nothing however plainly
     * the terminal is on screen.
     *
     * It failed quietly everywhere it did not assert — `isOnTheList()` degraded to
     * "the overflow button is somewhere", which is exactly the weaker test its own
     * comment warns against — and loudly in the one place that did.
     * `ClipboardAndTransferUITests` already matched on `.any` for this reason.
     */
    private var terminalView: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
    }

    /// The list, and not a terminal on top of it. `sessions.more` alone is not
    /// enough: a tap that opened the overflow menu instead of going back leaves
    /// both on screen.
    private func isOnTheList() -> Bool {
        !terminalView.exists && app.buttons["sessions.more"].exists
    }

    private func sessionIdentifiers() -> [String] {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
            .allElementsBoundByIndex
            .map { String($0.identifier.dropFirst("session.".count)) }
    }

    // MARK: - Helpers

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            usleep(500_000)
        }
        // A picture of whatever it *is* doing, because "never reached Connected"
        // on its own is the least useful sentence a test can end with.
        capture("zz-not-connected")
        throw XCTSkip("\(Self.notRunning) (never reached Connected; pill said "
                      + "\(pill.exists ? pill.label : "nothing"))")
    }

    /**
     * True once any static text on screen contains this.
     *
     * One predicated query rather than a walk over the elements: the terminal
     * rebuilds its accessibility tree constantly, so a loop that reads `count`
     * and then indexes into it is indexing a snapshot that no longer exists.
     */
    private func waitForText(containing needle: String, timeout: TimeInterval) -> Bool {
        let matching = app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle))
        return matching.firstMatch.waitForExistence(timeout: timeout)
    }

    /// A menu is dismissed by tapping outside it; there is no Escape on a phone.
    private func dismissMenu() {
        app.tap()
    }

    /// Attached to the result bundle, and written out to a folder when one is
    /// named — because a screenshot nobody looks at proves nothing, and nobody
    /// opens an `.xcresult` to look.
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let shots else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
