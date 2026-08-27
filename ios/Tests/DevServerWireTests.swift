/**
 * The `devserver` half of the wire, on this end.
 *
 * Four things here are worth pinning, and every one of them is a way this
 * feature could be wrong on screen while every other test in the suite passed.
 *
 * **A port that arrived on the wrong state must not reach a tunnel.** The
 * desktop promises `port` and `url` only on `ready` and tests that promise on
 * its own side; this end enforces it anyway, because the value is not merely
 * drawn — it is handed to `openLocalhost`, which binds a socket and points a web
 * view at it. A `starting` row carrying a port is the dead address under a live
 * row that this whole feature's rules exist to prevent, arriving off the network
 * instead of out of a merge.
 *
 * **An unknown status is refused rather than mapped.** All five draw different
 * controls; there is no honest default among them, and folding an unrecognised
 * word onto `idle` would put a Start button under a state nobody here
 * understands.
 *
 * **The row is untrusted display text, all four fields of it.** `note` is a line
 * a process printed. `script` and `command` come out of a `package.json` that
 * may have been cloned from a stranger. A newline in any of them turns one row
 * into three and pushes the button off the card.
 *
 * **The capability gate.** A desktop that has never heard of this does not send
 * the name, and nothing may be offered on that connection.
 */

import XCTest
@testable import TerminalDeck

final class DevServerWireTests: XCTestCase {

    // MARK: - Inbound

    func testEveryStatusDecodesToItsOwnCase() {
        let expected: [(String, DevServerStatus)] = [
            ("no-dev-script", .noDevScript),
            ("idle", .idle),
            ("starting", .starting),
            ("ready", .ready),
            ("failed", .failed),
        ]
        for (word, status) in expected {
            guard let report = WireCodec.devServerReport(["folder": "/p", "status": word]) else {
                return XCTFail("\(word) should decode")
            }
            XCTAssertEqual(report.status, status)
            XCTAssertEqual(report.folder, "/p")
        }
    }

    func testAnIdleRowCarriesTheCommandItWouldRun() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"dev.state","state":{"folder":"/Users/a/app","status":"idle","script":"dev","command":"pnpm run dev"}}
        """#), case let .devState(report) = message else {
            return XCTFail("an idle dev.state should decode")
        }
        XCTAssertEqual(report.folder, "/Users/a/app")
        XCTAssertEqual(report.status, .idle)
        XCTAssertEqual(report.script, "dev")
        XCTAssertEqual(report.command, "pnpm run dev")
        XCTAssertNil(report.port, "idle has no port and must not be given one")
        XCTAssertNil(report.sessionId)
    }

    func testAReadyRowCarriesTheProvenPortAndItsSession() {
        guard let report = WireCodec.devServerReport([
            "folder": "/p", "status": "ready", "script": "dev", "command": "npm run dev",
            "sessionId": "01J8ZC4T9K5Q2V7XW3NHRF6MBD", "port": 5173, "url": "http://localhost:5173",
        ]) else {
            return XCTFail("a ready row should decode")
        }
        XCTAssertEqual(report.port, 5173)
        XCTAssertEqual(report.url, "http://localhost:5173")
        XCTAssertEqual(report.sessionId, "01J8ZC4T9K5Q2V7XW3NHRF6MBD")
    }

    /**
     * The rule with the sharpest consequence in this file.
     *
     * A port on anything other than `ready` is dropped, so nothing downstream can
     * open a tunnel to it. Checked for all four other statuses rather than for
     * one, because it is exactly the sort of guard that gets written for the
     * interesting case and forgotten for the boring ones.
     */
    func testAPortIsIgnoredOnEveryStatusExceptReady() {
        for word in ["no-dev-script", "idle", "starting", "failed"] {
            guard let report = WireCodec.devServerReport([
                "folder": "/p", "status": word, "port": 3000, "url": "http://localhost:3000",
            ]) else {
                return XCTFail("\(word) should still decode")
            }
            XCTAssertNil(report.port, "a \(word) row must not carry a port to a tunnel")
            XCTAssertNil(report.url, "a \(word) row must not carry an address")
        }
    }

    func testAStatusThisBuildDoesNotKnowIsRefused() {
        // Not mapped onto `idle`, which would draw a Start button under a state
        // this app has no idea about.
        XCTAssertNil(WireCodec.devServerReport(["folder": "/p", "status": "restarting"]))
        XCTAssertNil(WireCodec.devServerReport(["folder": "/p", "status": ""]))
        XCTAssertNil(WireCodec.devServerReport(["folder": "/p", "status": 3]))
    }

    func testARowWithoutAFolderIsRefused() {
        // The folder is the key a row is replaced under, so a row without one
        // could only ever be filed under a guess.
        XCTAssertNil(WireCodec.devServerReport(["status": "idle"]))
        XCTAssertNil(WireCodec.devServerReport(["folder": "", "status": "idle"]))
        guard case .failed = WireCodec.decode(#"{"t":"dev.state"}"#) else {
            return XCTFail("a dev.state with no state should be refused")
        }
        guard case .failed = WireCodec.decode(#"{"t":"dev.state","state":{"status":"idle"}}"#) else {
            return XCTFail("a dev.state with no folder should be refused")
        }
    }

    func testAPortThatIsNotAPortIsDroppedRatherThanCarried() {
        for port in ["0", "70000", "\"5173\"", "5173.5", "true", "null"] {
            guard let report = WireCodec.devServerReport(
                jsonRow(#"{"folder":"/p","status":"ready","port":\#(port)}"#)) else {
                return XCTFail("the row should still decode with port \(port)")
            }
            XCTAssertNil(report.port, "port \(port) is not a port")
        }
    }

    /// A session id that is not one cannot become the id in an `attach` — the
    /// same rule every other id on this wire is held to. Dropped rather than
    /// failing the row: the folder's state is still worth drawing, it just has
    /// nowhere to send somebody.
    func testASessionIdThatIsNotOneIsDropped() {
        guard let report = WireCodec.devServerReport([
            "folder": "/p", "status": "starting", "sessionId": "../../etc/passwd",
        ]) else {
            return XCTFail("the row should still decode")
        }
        XCTAssertNil(report.sessionId)
        XCTAssertEqual(report.status, .starting)
    }

    // MARK: - Untrusted text

    func testControlCharactersAreStrippedFromEveryDisplayField() {
        guard let report = WireCodec.devServerReport([
            "folder": "/p",
            "status": "starting",
            // A carriage return is what a progress bar prints; a newline is what
            // turns one row into three.
            "note": "building\r\n  1/4 modules",
            "command": "npm\u{0007} run dev",
            "script": "de\u{001b}v",
            "message": "it broke\nsomewhere",
        ]) else {
            return XCTFail("the row should decode")
        }
        for field in [report.note, report.command, report.script, report.message] {
            let value = field ?? ""
            XCTAssertFalse(value.isEmpty)
            XCTAssertFalse(value.unicodeScalars.contains { $0.value <= 0x1f || $0.value == 0x7f },
                           "\(value) still carries a control character")
        }
    }

    func testADisplayLineIsCutToTheLengthTheDesktopCapsItAt() {
        let long = String(repeating: "x", count: 5_000)
        guard let report = WireCodec.devServerReport([
            "folder": "/p", "status": "starting", "note": long,
        ]) else {
            return XCTFail("the row should decode")
        }
        XCTAssertEqual(report.note?.count, WireCodec.maxDisplayLine)
    }

    func testAnEmptyFieldReadsAsAbsentRatherThanAsABlankLine() {
        guard let report = WireCodec.devServerReport([
            "folder": "/p", "status": "idle", "command": "   ", "script": "",
        ]) else {
            return XCTFail("the row should decode")
        }
        XCTAssertNil(report.command)
        XCTAssertNil(report.script)
    }

    // MARK: - Outbound

    func testBothVerbsEncodeToTheShapeTheDesktopParses() {
        let cases: [(ClientMessage, [String: Any])] = [
            (.devStatus(folder: "/Users/a/app"), ["t": "dev.status", "folder": "/Users/a/app"]),
            (.devStart(folder: "/Users/a/app"), ["t": "dev.start", "folder": "/Users/a/app"]),
        ]
        for (message, expected) in cases {
            guard let data = WireCodec.encode(message).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return XCTFail("encode produced something that is not a JSON object")
            }
            XCTAssertEqual(object.keys.sorted(), expected.keys.sorted())
            for (key, value) in expected {
                XCTAssertEqual(object[key] as? String, value as? String, key)
            }
        }
    }

    // MARK: - The gate

    /// A desktop that has never heard of this feature does not send the name,
    /// and nothing may be offered on that connection.
    func testDevServersAreOnlyOfferedWhenTheDesktopAdvertisesThem() {
        let without = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"p","token":null,"sessions":[],"capabilities":["localhost","create"]}"#
        guard case let .ok(plain, _) = WireCodec.decode(without),
              case let .welcome(_, _, _, _, _, none, _, _, _, _, _, _) = plain else {
            return XCTFail("a welcome without devserver should decode")
        }
        XCTAssertFalse(none.contains(WireCapability.devserver),
                       "a host offering localhost has not thereby offered dev servers")

        let with = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"p","token":null,"sessions":[],"capabilities":["devserver"]}"#
        guard case let .ok(newer, _) = WireCodec.decode(with),
              case let .welcome(_, _, _, _, _, offered, _, _, _, _, _, _) = newer else {
            return XCTFail("a welcome with devserver should decode")
        }
        XCTAssertTrue(offered.contains(WireCapability.devserver))
    }

    /// The capability name is not claimed in `hello`. It is a verb this phone
    /// *sends*, gated by what the desktop advertised, so claiming it would say
    /// nothing — unlike `github`, whose `github.changed` push a client would
    /// otherwise miss.
    func testDevServerIsNotClaimedInHello() {
        // `devserver` is a thing this phone *asks for*, gated by what the desktop
        // advertised, so claiming it would say nothing. The claimed set is only
        // the names that run desktop→phone: the pushes a client would otherwise
        // miss (github, devices, settings), and the client half of a dual-listed
        // name (watch) — the same list `CLAIMED_CAPABILITIES` carries in the PWA.
        XCTAssertFalse(WireCapability.claimed.contains(WireCapability.devserver))
        XCTAssertEqual(Set(WireCapability.claimed),
                       [WireCapability.github, WireCapability.devices,
                        WireCapability.settings, WireCapability.watch])
    }

    private func jsonRow(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("the fixture is not JSON")
            return [:]
        }
        return object
    }
}
