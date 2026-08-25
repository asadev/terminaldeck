/**
 * Sending a file, and the clipboard both ways, against a **real** host on the
 * **live** relay.
 *
 * `ClipboardAndTransferUITests` already taps all of this. What it taps is
 * `ios/Harness/host-standin.ts` — a second implementation of the desktop,
 * written for this Simulator to talk to, with a relay of its own on loopback.
 * That is a good stand-in and it is still a stand-in, and this repository has
 * already paid for the difference twice: `PLAN.md` records both phone stand-ins
 * sharing a bug with their clients and hiding an 81-versus-80 byte error for a
 * day, and the ChaCha failure — every relayed handshake throwing inside a silent
 * catch while 3,628 Node tests passed — was invisible for weeks for exactly this
 * reason. Android sent 6,291,456 bytes to the packaged desktop over
 * `relay.terminaldeck.dev` on 2026-08-14 and the digests matched on both sides.
 * Until this file ran, iOS had never met a real host at all.
 *
 * So nothing in the path this exercises is written for the test: the product's
 * own headless host from `out/headless`, the same `registerRemoteIpc`,
 * `PtyManager`, `uploads.ts` and sealed channel the window build links, the
 * deployed relay, and a pairing link minted by the same `relayPairingLink` the
 * desktop's Pair panel calls.
 *
 * ## Nothing here grades itself
 *
 * A phone can draw whatever it likes on its own screen, and an upload row that
 * says "Landed at …" is the app's opinion of its own work. Every claim this
 * suite exists to support is settled on the **Mac**, after the run, by
 * `ios/Harness/live-transfer.sh`:
 *
 *  - the file: `shasum -a 256` over the source and over what landed in the
 *    host's uploads directory, which is the same comparison the Android proof
 *    made. The app's own digest is checked too, and not by this test — the host
 *    deletes rather than renames anything whose SHA-256 does not match what the
 *    phone claimed in `upload.end`, so a file that is *there under its own name*
 *    is a file the phone and the host independently agreed about.
 *  - the clipboard inwards: the shell writes a file in its own working folder
 *    and the Mac reads it.
 *  - the clipboard outwards: `xcrun simctl pbpaste`, which needs no consent and
 *    has nothing from this process in the loop. The value it must contain is one
 *    the host's own shell minted from `$RANDOM` a moment earlier, so no amount
 *    of cleverness on this side could have produced it.
 *
 * What is left for this file is the finger: raising the pickers, tapping the
 * cells, and standing still long enough for the evidence to be collected.
 *
 * ## Running it
 *
 *     ios/Harness/live-transfer.sh
 *
 * It is env-gated rather than always-on, and the gate is deliberately the thing
 * the harness provides: without `TD_READY_FILE` there is no host on the far end
 * and every case here would fail for the wrong reason. A skipped case reporting
 * green is the failure mode this whole exercise is against, which is why the
 * script exists and why it is one command.
 */

import CryptoKit
import XCTest

final class LiveTransferUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Written by this test the moment it is standing at the pairing screen, so
    /// the harness knows when to mint. A code is worth sixty seconds and a
    /// Simulator takes longer than that to boot the app — mint it first and it
    /// has expired by the time anything can read it.
    private var readyFile: String { env("TD_READY_FILE") }
    /// Where the harness writes the six digits, once it has seen `readyFile`.
    /// The other half of the same handshake, and it is a file for the same
    /// reason: the code is minted after this test gets to the pairing screen, so
    /// it cannot have been an environment variable set at launch.
    private var codeFile: String { env("TD_CODE_FILE") }
    /// Where the host puts files that arrive from a phone.
    private var uploadsDir: String { env("TD_UPLOADS_DIR") }
    /// The photo, at the path the Simulator's own library holds it at.
    private var sourceMedia: String { env("TD_SOURCE_MEDIA") }
    private var shots: String { env("TD_SHOTS") }

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    /**
     * The skip, with the evidence for it attached.
     *
     * It lists what this process can actually see, and that is not decoration: a
     * skipped case reporting green is the failure this whole suite exists
     * against, and the first run of it skipped both cases while the harness had
     * plainly passed the variables to `xcodebuild` — they were in the "Build
     * settings from command line" block at the top of the log. Without the
     * visible names in the message the only way to tell "no harness" from "the
     * harness ran and the variables did not arrive" is to go and instrument the
     * test, which is a night nobody should have to spend twice.
     */
    private static var notRunning: String {
        let seen = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("TD_") || $0.hasPrefix("TEST_RUNNER") }
            .sorted()
        return "No live host is being driven. Run ios/Harness/live-transfer.sh, which starts the "
            + "headless host on the live relay, mints the pairing code and reads the evidence "
            + "off the Mac afterwards. This runner can see: "
            + (seen.isEmpty ? "no TD_ variables at all" : seen.joined(separator: ", "))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(readyFile.isEmpty, Self.notRunning)
        app = XCUIApplication()
        app.launch()
        try connect()
    }

    // MARK: - The file

    /**
     * A photo picked in another process, across the relay, onto the Mac's disk.
     *
     * The picker runs out of process — that is the whole reason this app needs
     * no photo-library permission — so its cells are in neither this app's
     * element tree nor any application this test can name on every iOS version.
     * `pickTheFirstPhoto` tries the query first and falls back to a real pixel
     * tap, which is what a finger is: it lands on whatever is drawn there
     * regardless of which process drew it.
     *
     * The wait at the end is on the **Mac's** uploads directory rather than on
     * the progress row, and that is not a preference. Measured twice on iOS
     * 26.5 and written down in `ClipboardAndTransferUITests`: the row is a
     * single accessibility element by design, so its snapshot does not refresh
     * when the sentence under the name changes, and predicates against `value`
     * and `label` time out after 180 seconds while the file is already on the
     * Mac with a matching digest.
     */
    func testAPhotoCrossesTheLiveRelayAndLandsWholeOnTheMac() throws {
        // Hashed here, inside the Simulator, from the bytes the library holds —
        // the same bytes the picker will hand the app. The Mac hashes what
        // arrives. Two programs, two ends, one number to compare, which is the
        // shape of the Android proof this is catching up with.
        try hashTheSource()

        try openASession()
        app.buttons["terminal.actions"].tap()
        let send = app.buttons["terminal.sendPhoto"]
        XCTAssertTrue(send.waitForExistence(timeout: 15),
                      "the host advertises `upload`, so Send Photo or Video must be in the menu")
        capture("20-send-menu")
        send.tap()

        // Nothing in this app has read the photo library to get here, so no
        // permission prompt is possible. If one ever appears this is where it
        // will be noticed rather than in App Review.
        XCTAssertFalse(app.alerts.element.waitForExistence(timeout: 3),
                       "picking a photo must not raise a permission prompt — see FilePickers.swift")
        sleep(3)
        capture("21-photo-picker")
        try pickTheFirstPhoto()

        let row = app.descendants(matching: .any).matching(identifier: "upload.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no progress row appeared")
        capture("22-upload-in-progress")

        XCTAssertTrue(waitForALandedFile(timeout: 240),
                      "nothing whole ever appeared in \(uploadsDir); the host deletes anything "
                      + "whose digest does not match, so a missing file is a failed digest or a "
                      + "transfer that never started")
        capture("23-upload-landed")

        // And the path is now at the prompt, quoted, with no newline after it —
        // the file is offered to the person, not run on their behalf.
        sleep(3)
        capture("24-path-typed-into-terminal")
        checkpoint("photo landed")
    }

    // MARK: - The clipboard

    /**
     * Both directions, in the order that lets the Mac check both.
     *
     * **Inwards first.** The harness puts a shell command on the device
     * pasteboard before the run and reads it back with `simctl pbpaste`, so the
     * reader is known to work before anything depends on it. Paste sends it into
     * the session, Return runs it, and the file it writes lands in the folder the
     * host granted — where the Mac reads it.
     *
     * **Outwards second, and last on purpose.** Copy Screen replaces the
     * pasteboard, so it has to come after the paste or it would destroy the
     * thing being pasted. The value it must carry is minted by the host's own
     * shell — `$RANDOM`, on the far side of the relay — printed back through the
     * sealed channel, and nothing here ever learns it. `simctl pbpaste` after the
     * run is where the two are compared.
     */
    func testTheClipboardCrossesInBothDirections() throws {
        try openASession()

        /* ---- inwards: the device pasteboard into a shell on the Mac -------- */

        app.buttons["terminal.actions"].tap()
        let paste = app.buttons["terminal.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 15))
        paste.tap()
        // Tapped if it appears and not required: iOS asks only the first time an
        // app reads another app's clipboard in a while, so insisting on the
        // prompt would make this pass or fail on the run order.
        _ = tapAllowPaste(timeout: 8)
        sleep(3)
        capture("30-pasted-at-the-prompt")

        // The paste is sitting at the prompt unexecuted, which is bracketed paste
        // doing its job. Return is what runs it.
        try press("\n")
        sleep(4)
        capture("31-paste-ran")
        checkpoint("paste-in ran")

        /* ---- outwards: the host's own randomness onto this pasteboard ------ */

        // Minted on the far side. `said.txt` is written and then read back, so
        // the value is both on the Mac's disk for the harness to compare against
        // and on this screen for Copy Screen to pick up.
        try run("echo TD-OUT-$RANDOM$RANDOM$RANDOM > said.txt")
        sleep(2)
        try run("cat said.txt")
        sleep(4)
        capture("32-host-value-on-screen")

        app.buttons["terminal.actions"].tap()
        let copyScreen = app.buttons["terminal.copyScreen"]
        XCTAssertTrue(copyScreen.waitForExistence(timeout: 15),
                      "Copy Screen must be reachable from the actions menu")
        copyScreen.tap()

        // Waited for rather than slept past: the toast is up for 2.5 seconds, and
        // the first version of a test like this photographed an empty screen
        // while the copy had plainly worked.
        let toast = app.staticTexts["terminal.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8),
                      "copying must say so; a silent clipboard button feels broken")
        XCTAssertTrue(toast.label.hasPrefix("Copied"),
                      "the toast should report what was copied, and said: \(toast.label)")
        capture("33-copied-out")
        checkpoint("copy-out done")

        // Nothing reads `UIPasteboard.general` from here, and that is measured
        // rather than squeamish: a cross-app read raises the system consent and
        // blocks the calling thread until it is answered — the same thread that
        // would have to tap Allow — so the run stops dead. `simctl pbpaste` on
        // the Mac reads it with no consent at all and is better evidence besides.
        sleep(2)
    }

    // MARK: - Getting there

    /**
     * Pair if this is the first run, and come straight up if it is not.
     *
     * Nothing is unpaired here on purpose. A pairing lasts until it is revoked,
     * so a second run must find the host still trusted and connect without a
     * code — which is that claim holding rather than a convenience.
     */
    private func connect() throws {
        let field = app.textFields["pairing.field"]
        if field.waitForExistence(timeout: 25) {
            capture("01-waiting-for-a-code")
            // The harness is watching for this file. It mints a code and writes
            // the six digits to `codeFile`, which is what this test then types.
            try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)

            /*
             * Typed, not deep-linked, because typing is the product.
             *
             * This used to be `simctl openurl` with a `terminaldeck://pair?…`
             * link — the same door a scanned QR came through — and it dragged a
             * SpringBoard alert with it: **Open in "Terminal Deck"?**, raised
             * before the app saw anything, because as far as iOS was concerned
             * another program was handing this app a link. The test had to find
             * and tap that alert, and the first run of it waited two minutes for
             * a pairing that never happened while a screenshot showed the alert
             * sitting over the pairing screen with nobody to answer it.
             *
             * None of that exists now. There is one way into this app and it is
             * six digits in a field, so the proof puts six digits in the field.
             */
            let code = waitForCode(timeout: 240)
            XCTAssertEqual(code.count, 6, "the harness never wrote a six-digit code to TD_CODE_FILE")
            field.tap()
            field.typeText(code)
            capture("01b-code-typed")
            // No tap on Pair: the field submits itself on the sixth digit, which
            // is behaviour worth proving rather than working around.
        } else {
            capture("01-already-paired")
        }

        // Long: a device has to redeem its code, be refused, and then be approved
        // on the host before the pill can turn green. That refusal is the product
        // declining to let anything in on a code alone.
        try waitForConnected(timeout: 180)
        capture("02-connected")
    }

    /**
     * A session this phone starts, in the folder the host granted it.
     *
     * Never an existing row. Sessions belong to whoever started them, and the
     * second case in this file would otherwise inherit whatever the first left at
     * the prompt.
     */
    private func openASession() throws {
        let new = app.buttons["sessions.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 90),
                      "the host advertises `create` and has granted a folder, so the button "
                      + "should be here")
        new.tap()
        // A menu when the host offers folders, a plain button when it does not.
        let inMenu = app.buttons["sessions.newDefault"]
        if inMenu.waitForExistence(timeout: 4) { inMenu.tap() }

        XCTAssertTrue(app.buttons["terminal.actions"].waitForExistence(timeout: 60),
                      "the session should open its terminal")
        // The shell has to have drawn a prompt before anything is typed at it.
        sleep(4)
        capture("10-terminal")
    }

    private func waitForConnected(timeout: TimeInterval) throws {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return }
            usleep(500_000)
        }
        capture("zz-not-connected")
        XCTFail("never reached Connected; the pill said \(pill.exists ? pill.label : "nothing")")
    }

    // MARK: - Typing

    /// Type a command and press Return.
    private func run(_ command: String) throws {
        try press(command + "\n")
    }

    /**
     * Put text into the session, raising the keyboard if it is down.
     *
     * The QuickPath tutorial — *"Speed up your typing by sliding your finger"* —
     * is put up by the system keyboard the first time it appears on a fresh
     * Simulator, and it sits over the key bar. Nothing to do with this app;
     * dismissed the way a person would.
     */
    private func press(_ text: String) throws {
        // Tapping the terminal, which is the only way in since the toolbar's
        // keyboard button was deleted — *"we don't need keyboard button also,
        // even in terminal pages, even on copilot pages, because when we click
        // inside the chat keyboard comes anyway."*
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal.view").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal screen should be up")
        if !app.keyboards.firstMatch.exists {
            terminal.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 20),
                          "tapping the terminal should raise a keyboard to type into")
        }
        let continueButton = app.buttons["Continue"]
        if continueButton.exists { continueButton.tap() }
        app.typeText(text)
    }

    /**
     * Wait for the harness to write six digits, and return them.
     *
     * A poll rather than a watcher, and it is the same trade `live-desktop.ts`
     * makes on its side: there is no event to subscribe to across a process
     * boundary that is a file on a Mac, the wait is bounded, and the alternative
     * is a `DispatchSource` on a file that does not exist yet.
     *
     * Whitespace is stripped rather than trusted: the file is written without a
     * trailing newline on purpose, and a newline typed into a `.numberPad` field
     * would be a character the parser refuses — a failure that would read as the
     * code being wrong.
     */
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

    // MARK: - The picker

    /**
     * Choose the photo the harness put there.
     *
     * The library is not empty — a Simulator ships with sample images — so the
     * harness adds its file last and this takes the first cell, which is where
     * `PHPickerViewController` puts the newest item. Picking the wrong one cannot
     * produce a false pass: the digests are compared on the Mac afterwards, and a
     * sample photo has neither the right size nor the right hash.
     */
    private func pickTheFirstPhoto() throws {
        if let picker = pickerApplication() {
            let tree = XCTAttachment(string: picker.debugDescription)
            tree.name = "picker-element-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let cell = picker.images.count > 0
                ? picker.images.element(boundBy: 0)
                : picker.cells.element(boundBy: 0)
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "the picker showed nothing")
            cell.tap()
            return
        }
        /*
         * A real pixel tap, because no element query can reach this view.
         *
         * The picker is hosted out of process precisely so the app cannot see the
         * library, and that privacy boundary is also an automation boundary. A
         * coordinate tap is not a query: it injects a touch at a point on the
         * screen, which is what a finger does. The offset is the centre of the
         * first cell in the grid — three columns starting under the header, with
         * the newest item top-left.
         */
        capture("21b-picker-before-a-pixel-tap")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.47)).tap()
    }

    /**
     * The process `PHPickerViewController` actually runs in.
     *
     * Several candidates because the hosting process has moved between releases.
     * `.state` is checked first: querying elements on an application that is not
     * running does not return empty, it throws.
     *
     * Deliberately **no** fallback to the host app. There was one in an earlier
     * version of this and it matched instantly on the ellipsis icon in the
     * navigation bar — every screen has images — so the test "found the picker"
     * before the picker had appeared and then tapped a toolbar button.
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
            for candidate in candidates where candidate.state == .runningForeground {
                if candidate.images.count > 0 || candidate.cells.count > 0 { return candidate }
            }
            usleep(400_000)
        }
        let states = candidates.map { "\($0.description): \($0.state.rawValue)" }.joined(separator: "\n")
        let note = XCTAttachment(string: "candidate states\n\(states)\n\nhost app tree\n\(app.debugDescription)")
        note.name = "picker-candidates"
        note.lifetime = .keepAlways
        add(note)
        return nil
    }

    // MARK: - Evidence

    /**
     * The source photo's digest, computed on this side.
     *
     * Streamed rather than read whole: the file is several megabytes and
     * `Data(contentsOf:)` on it inside a Simulator is a needless spike. The
     * number goes into the shots directory, which is a real folder on the Mac —
     * a Simulator process is a plain macOS process and writes host paths — so the
     * harness can print both digests side by side.
     */
    private func hashTheSource() throws {
        guard !sourceMedia.isEmpty else { return }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourceMedia))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        try? hex.write(toFile: "\(shots)/phone-side-digest.txt", atomically: true, encoding: .utf8)
    }

    /**
     * Wait for a whole file to appear in the host's uploads directory.
     *
     * A `.part` does not count and that is the entire subtlety: bytes go to
     * `<name>.part` and are renamed into place only after the host's own SHA-256
     * matches the one the phone reported. So the *rename* is the product's own
     * verdict on the transfer, and waiting for it means this test never has to
     * take the app's word for anything.
     */
    private func waitForALandedFile(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: uploadsDir)) ?? []
            if names.contains(where: { !$0.hasSuffix(".part") && !$0.hasPrefix(".") }) { return true }
            usleep(500_000)
        }
        return false
    }

    /**
     * A dated marker on the Mac, so what the harness reads can be tied to the
     * step that produced it rather than guessed at from timestamps.
     */
    private func checkpoint(_ label: String) {
        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(label)\n"
        if let handle = FileHandle(forWritingAtPath: "\(shots)/checkpoints.log") {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: "\(shots)/checkpoints.log", atomically: false, encoding: .utf8)
        }
    }

    /**
     * A frame, saved where a person can open it.
     *
     * Attached to the result bundle *and* written to a directory on the Mac. The
     * attachment is the tidy answer and needs `xcresulttool` to get at; the file
     * is the one somebody actually looks at. A progress bar that never moves and
     * a progress bar that moves look identical in a passing assertion.
     */
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard !shots.isEmpty else { return }
        // A folder per case. Both cases here connect, and both photograph the
        // session list on the way through, so a flat directory meant the second
        // one overwrote the first's frames — and the frame that was lost was the
        // interesting one, the list with nothing in it yet.
        let dir = "\(shots)/\(caseName)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// `-[LiveTransferUITests testFoo]` reduced to `testFoo`, for a directory name.
    private var caseName: String {
        name.split(whereSeparator: { " []-".contains($0) }).last.map(String.init) ?? "case"
    }
}
