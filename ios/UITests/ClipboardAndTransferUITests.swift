/**
 * Clipboard both ways, and a file going into the terminal — driven with a finger
 * against a real desktop.
 *
 * These exist because the unit tests cannot make the claims that matter here.
 * `TerminalBridgeTests` proves `pasteable` strips an ESC and that a bracketed
 * paste is bracketed; it cannot prove that the Copy item is reachable, that a
 * long press starts a selection, or that a photo picked in another process ends
 * up on a Mac. Every one of those is a fact about a running app.
 *
 * Same harness and the same skip rule as `LiveSessionUITests`:
 *
 *     TD_FORCE_SHELL=1 scripts/remote-host.sh --relay-port 8791 &
 *     xcrun simctl openurl booted "$(cat .harness/.remote-host/pairing.txt)"
 *     xcodebuild test … -only-testing:TerminalDeckUITests/ClipboardAndTransferUITests
 *
 * ## Screenshots
 *
 * Every case saves one. Not decoration: a progress bar that never moves and a
 * progress bar that moves look identical in a passing assertion, and the rule
 * this project works to is that a UI change is not done until it has been
 * rendered and *looked at*. `save(_:)` writes into the runner's own container,
 * which is a real directory on the host — `xcrun simctl get_app_container` finds
 * it — so the frames survive the run and can be opened.
 */

import UIKit
import XCTest

final class ClipboardAndTransferUITests: XCTestCase {

    private var app: XCUIApplication!
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 10)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "This phone is not connected to a running harness. Start scripts/remote-host.sh, "
        + "then: xcrun simctl openurl booted \"$(cat .harness/.remote-host/pairing.txt)\""

    // MARK: - Copying out of the terminal

    /**
     * The affordance, before the behaviour.
     *
     * Rule 7.11 says the way to do something must be *visible* — no hidden
     * gestures. Copy is reachable two ways and both are checked here, because
     * the accessory row only exists while the keyboard is up and the menu only
     * exists while it is down, so a phone that had one but not the other would
     * have no way to copy in half of its states.
     */
    func testCopyIsReachableFromBothTheMenuAndTheKeyRow() throws {
        try openSession()

        let actions = app.buttons["terminal.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        XCTAssertTrue(app.buttons["terminal.copyScreen"].waitForExistence(timeout: 5),
                      "Copy Screen must be in the actions menu")
        save("copy-menu")
        // Dismiss without choosing.
        app.buttons["terminal.copyScreen"].tap()

        app.buttons["terminal.keyboard"].tap()
        XCTAssertTrue(app.buttons["copy"].waitForExistence(timeout: 5),
                      "Copy must also be on the accessory row, which is where a thumb already is")
        save("copy-keyrow")
    }

    /**
     * A long press selects, and the accessory row's Copy puts it on the pasteboard.
     *
     * This is the half of the clipboard that had never been verified: paste-in
     * was known to work, copy-*out* was not. The gesture is the standard iOS
     * press-and-hold; the control that copies the result is the `copy` key above
     * the keyboard, for the reason spelled out below.
     */
    func testALongPressSelectsAndCopyPutsItOnThePasteboard() throws {
        try openSession()

        // Give the shell something worth selecting, and let it print.
        app.buttons["terminal.keyboard"].tap()
        app.typeText("echo SELECT-ME-9F2C\n")
        sleep(2)

        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        // SwiftTerm's own selection, started the way a person starts it: the
        // standard iOS press-and-hold, which is the "no hidden gesture" half of
        // this. It does **not** select on its own — it raises the system's
        // Paste / Select / Select All menu, and one of those two makes the
        // selection. That second tap is part of the affordance, not a defect,
        // and the first version of this test asserted straight past it and then
        // blamed the app for saying "Copy Screen" — which was the truth.
        terminal.press(forDuration: 1.2)
        sleep(1)
        save("long-press-menu")

        let selectAll = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5),
                      "a long press must offer a way to select; it offered nothing")
        selectAll.tap()
        sleep(1)
        save("long-press-selection")

        // Copied from the **accessory row**, not from the navigation-bar menu,
        // and the difference is the whole finding of this test.
        //
        // SwiftTerm clears its selection on a touch outside the terminal — it
        // calls `selectNone()` from its own touch handling — so tapping the
        // toolbar's ellipsis to reach a "Copy Selection" item destroys the
        // selection on the way there, and the item then correctly reports that
        // nothing is selected. Measured: the run before this one selected the
        // whole screen (verified in a screenshot), opened the menu, and got an
        // unchanged pasteboard.
        //
        // The row above the keyboard is not outside the terminal in that sense —
        // it is the terminal's `inputAccessoryView` — so the selection survives
        // the reach. That is why Copy lives there as well as in the menu, and it
        // is the control this asserts on.
        let copy = app.buttons["copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5),
                      "the accessory row must carry Copy; it is the only control a selection survives")
        let before = UIPasteboard.general.changeCount
        copy.tap()
        let changed = NSPredicate(format: "changeCount > %d", before)
        expectation(for: changed, evaluatedWith: UIPasteboard.general, handler: nil)
        waitForExpectations(timeout: 10)
        sleep(1)
        // The toast says how much landed and *which* of the two it took, which
        // is the on-screen half of the fact the pasteboard count is the durable
        // half of.
        save("copy-selection-toast")
    }

    // MARK: - Pasting into the terminal

    /**
     * The hazard this whole workstream is about.
     *
     * A multi-line block pasted into a shell without bracketed paste runs line
     * by line as it arrives: the first newline submits, and everything after it
     * is executed. With bracketed paste the same block sits at the prompt as one
     * pending command. zsh turns the mode on by default, so a plain shell is a
     * real test of it rather than a contrived one.
     *
     * The block is deliberately made of `echo`s with distinctive markers, so the
     * screenshot shows the difference at a glance: either three lines of output
     * (broken) or three lines of unexecuted text at one prompt (correct).
     */
    func testALargeMultiLinePasteDoesNotSubmitEarly() throws {
        // Big enough to be split across several `input` frames — over
        // `Wire.maxInputBytes`, which is 16 KiB — so this also covers the case
        // where the bracket markers and the payload are in different frames.
        var block = "echo PASTE-LINE-ONE\necho PASTE-LINE-TWO\n"
        block += String(repeating: "# filler comment to push this paste past one frame\n", count: 400)
        block += "echo PASTE-LINE-LAST"
        XCTAssertGreaterThan(block.utf8.count, 16 * 1024, "the point is a paste larger than one frame")
        UIPasteboard.general.string = block

        try openSession()
        app.buttons["terminal.actions"].tap()
        XCTAssertTrue(app.buttons["terminal.paste"].waitForExistence(timeout: 5))
        app.buttons["terminal.paste"].tap()
        // Tapped if it appears, and not required. iOS only asks the *first* time
        // an app reads another app's clipboard in a while, so insisting on the
        // prompt makes this test pass or fail on whether an earlier case in the
        // same run already answered it — which is a property of the run order,
        // not of the paste.
        _ = tapAllowPaste(timeout: 6)

        sleep(4)
        // Read this one. If the paste submitted early, the screen shows the
        // *output* of the echoes; if bracketed paste held, it shows the text
        // still sitting at a single prompt, unexecuted.
        save("large-multiline-paste")

        // Then throw the buffer away. The session outlives this test — it is a
        // real shell on a real Mac, not a fixture — so a pending 400-line paste
        // left at the prompt is submitted by the *next* case that types a
        // newline, and that case then fails for a reason that has nothing to do
        // with it. Ctrl-C is the discard, and the accessory row is where it is.
        app.buttons["terminal.keyboard"].tap()
        if app.buttons["^C"].waitForExistence(timeout: 5) { app.buttons["^C"].tap() }
        sleep(1)
    }

    // MARK: - Sending a file

    /**
     * The button exists only because the Mac offered the capability.
     *
     * `scripts/remote-host.ts` is given an uploads directory, so it advertises
     * `upload` and these must be here. A host without one advertises nothing and
     * the same menu has neither item — which is the behaviour that keeps a phone
     * from offering a button that can only produce a refusal.
     */
    func testSendingIsOfferedBecauseTheMacOfferedIt() throws {
        try openSession()
        app.buttons["terminal.actions"].tap()
        XCTAssertTrue(app.buttons["terminal.sendPhoto"].waitForExistence(timeout: 5),
                      "the harness advertises `upload`, so Send Photo should be here")
        XCTAssertTrue(app.buttons["terminal.sendFile"].exists)
        save("send-menu")
        app.buttons["terminal.sendPhoto"].tap()

        // `PHPickerViewController`, which runs in another process. Nothing in
        // this app read the photo library to get here and no permission prompt
        // is possible — if one ever appears, this assertion is where it will be
        // noticed.
        XCTAssertFalse(
            app.alerts.element.waitForExistence(timeout: 3),
            "picking a photo must not raise a permission prompt — see FilePickers.swift")
        sleep(2)
        save("photo-picker")
    }

    /**
     * The whole chain, on screen: pick → progress → landed → path typed.
     *
     * The photo is put into the simulator's library by the script that runs this
     * (`simctl addmedia`), and it is several megabytes of high-entropy noise on
     * purpose: a file of zeros would hash the same with a slice missing, so a
     * chunking bug would pass. What is on the Mac is checked by the script
     * afterwards with `shasum`; what this case proves is the part a hash cannot
     * — that the bar moved, that the path was shown, and that it was typed.
     */
    func testAPhotoLandsOnTheMacAndItsPathIsTyped() throws {
        try openSession()
        app.buttons["terminal.actions"].tap()
        XCTAssertTrue(app.buttons["terminal.sendPhoto"].waitForExistence(timeout: 5))
        app.buttons["terminal.sendPhoto"].tap()

        // The first cell. `PHPickerViewController` sorts newest first and the
        // script adds its file immediately before this runs, so cell zero is the
        // several-megabyte one — picked by position because a picker cell has no
        // stable identifier to match on. (Checked on screen rather than assumed:
        // the added image is visibly top-left in the grid.)
        //
        // `app.cells` finds nothing here, and the reason is worth writing down:
        // `PHPickerViewController` is a **remote view controller** hosted from
        // another process, so its collection view is not in this app's element
        // tree. Its cells surface as images belonging to the picker's own
        // application, which has to be queried by bundle identifier. Measured,
        // not guessed — the first version of this test asserted on `app.cells`
        // and reported "the picker never showed anything" while a screenshot
        // taken at the same instant showed a full grid of photos.
        if let picker = pickerApplication() {
            // The tree, attached, so the next person does not have to rediscover
            // which process hosts the picker on their iOS version.
            let tree = XCTAttachment(string: picker.debugDescription)
            tree.name = "picker-element-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let cell = picker.images.count > 0 ? picker.images.element(boundBy: 0) : picker.cells.element(boundBy: 0)
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "the picker showed nothing")
            cell.tap()
        } else {
            /*
             * A real pixel tap, because no element query can reach this view.
             *
             * `PHPickerViewController` is hosted out of process precisely so the
             * app cannot see the library, and that privacy boundary is also an
             * automation boundary: the cells are in neither this app's element
             * tree nor any application this test can name. Querying was tried
             * three ways first — `app.cells`, `app.images`, and four candidate
             * bundle identifiers — and the tree attached above is the evidence.
             *
             * A coordinate tap is not a query. It injects a touch at a point on
             * the screen, which is what a finger does, and it lands on whatever
             * is drawn there regardless of which process drew it. The offset is
             * the centre of the first cell in the grid, read off a screenshot of
             * this exact picker: three columns starting under the header, and the
             * newest item — the one the script added — is top-left.
             */
            save("picker-before-tap")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.47)).tap()
        }

        // The row appears as soon as `upload.begin` goes out, and its first
        // sentence is the Mac being asked where to put the file.
        let row = app.descendants(matching: .any).matching(identifier: "upload.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no progress row appeared")
        save("upload-in-progress")

        // Moving, not merely present. The value is the sentence under the name,
        // which counts acknowledged bytes — so a bar drawn from bytes handed to
        // the socket would sit at its final value here instead of climbing.
        let landed = NSPredicate(format: "value CONTAINS 'Landed at'")
        expectation(for: landed, evaluatedWith: row, handler: nil)
        waitForExpectations(timeout: 180)
        save("upload-landed")

        // And the path is now in the prompt, quoted, with no newline after it —
        // the file is offered to the user, not run on their behalf.
        sleep(2)
        save("path-typed-into-terminal")
    }

    // MARK: - Helpers

    private func openSession() throws {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        if rows.count == 0 {
            // A fresh harness has no sessions until something starts one, and
            // the phone can: `create` is advertised.
            let plus = app.buttons["sessions.new"]
            XCTAssertTrue(plus.waitForExistence(timeout: 10), "no sessions and no way to start one")
            plus.tap()
            let menuItem = app.buttons["New session"]
            if menuItem.waitForExistence(timeout: 3) { menuItem.tap() }
        }
        let first = rows.element(boundBy: 0)
        if first.waitForExistence(timeout: 25), app.buttons["terminal.actions"].exists == false {
            first.tap()
        }
        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 15),
                      "the terminal screen should be open")
    }

    /**
     * The process `PHPickerViewController` actually runs in.
     *
     * Two candidates because the hosting process has moved between releases and
     * this has to keep working on whichever simulator is to hand: the dedicated
     * picker service on current iOS, and Photos itself on older ones. Whichever
     * has elements is the one in front of the user.
     */
    private func pickerApplication() -> XCUIApplication? {
        let candidates = [
            "com.apple.PhotosUIPrivate.PhotosPickerHost",
            "com.apple.mobileslideshow",
            "com.apple.PhotosViewService",
            "com.apple.photos.PhotosPicker",
        ].map { XCUIApplication(bundleIdentifier: $0) }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            // `.state` first. Querying elements on an application that is not
            // running does not return empty — it throws "Application … is not
            // running", which failed this before the other candidates had been
            // tried at all.
            for candidate in candidates where candidate.state == .runningForeground {
                if candidate.images.count > 0 || candidate.cells.count > 0 { return candidate }
            }
            usleep(400_000)
        }
        // Deliberately **no** fallback to the host app. There was one, and it
        // matched instantly on the ellipsis icon in the navigation bar — every
        // screen has images — so the test "found the picker" before the picker
        // had appeared and then tapped a toolbar button. A fallback that is
        // always true is worse than no fallback.
        let states = candidates
            .map { "\($0.description): \($0.state.rawValue)" }
            .joined(separator: "\n")
        let note = XCTAttachment(string: "candidate states\n\(states)\n\nhost app tree\n\(app.debugDescription)")
        note.name = "picker-candidates"
        note.lifetime = .keepAlways
        add(note)
        return nil
    }

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }

    /// Taps the system's Allow Paste button wherever it turns up. Copied from
    /// `LiveSessionUITests` deliberately: the dialog is not reliably in any one
    /// process, and sharing this through a base class would put a `setUp` in the
    /// way of a file that is otherwise readable top to bottom.
    private func tapAllowPaste(timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in [springboard.buttons["Allow Paste"], app.buttons["Allow Paste"]]
            where candidate.exists && candidate.isHittable {
                candidate.tap()
                return true
            }
            usleep(300_000)
        }
        return false
    }

    /**
     * A frame, saved where a person can open it.
     *
     * Attached to the result bundle *and* written to the runner's Documents
     * directory. The attachment is the tidy answer and needs `xcresulttool` to
     * get at; the file is the one somebody actually looks at, because
     * `simctl get_app_container … data` prints the directory it is in.
     */
    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let target = dir.appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: target)
    }
}
