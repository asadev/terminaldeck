/**
 * The wire layer, which is the part of this app that a hostile or merely
 * mistaken peer talks to directly.
 *
 * These cover the cases where a synthesised decoder would have been wrong — the
 * three named in `WireCodec`'s header — plus the byte-counting, because a paste
 * measured in characters is a socket the desktop closes.
 */

import XCTest
@testable import TerminalDeck

final class WireCodecTests: XCTestCase {

    // MARK: - welcome

    func testWelcomeWithNullTokenMeansYouAlreadyHaveOne() {
        let raw = #"{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"iPhone","token":null,"sessions":[]}"#
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .welcome(_, _, _, token, _, _) = message else {
            return XCTFail("expected a welcome")
        }
        XCTAssertNil(token)
    }

    func testWelcomeWithNoTokenFieldIsRefused() {
        // Absent is not the same answer as null. A client that read them the
        // same way would believe it was paired while holding nothing.
        let raw = #"{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"iPhone","sessions":[]}"#
        guard case let .failed(reason) = WireCodec.decode(raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, "welcome without a token field")
    }

    func testWelcomeCarriesItsSessions() {
        let raw = """
        {"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"iPhone","token":"abc","sessions":[
          {"id":"s1","title":"one","cwd":"~/a","provider":"claude","status":"working","exitCode":null}
        ]}
        """
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .welcome(version, _, _, token, sessions, _) = message else {
            return XCTFail("expected a welcome")
        }
        XCTAssertEqual(version, 1)
        XCTAssertEqual(token, "abc")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].provider, "claude")
        XCTAssertNil(sessions[0].exitCode)
    }

    // MARK: - session rows

    func testOneBadRowDoesNotDiscardTheList() {
        // Four of five sessions is useful. None, because the fifth had a null
        // title, is not.
        let raw = """
        {"t":"sessions","sessions":[
          {"id":"s1","title":"one","cwd":"~/a","provider":"claude","status":"idle","exitCode":null},
          {"id":"s2","title":null,"cwd":"~/b","provider":"codex","status":"idle","exitCode":null},
          {"id":"s3","title":"three","cwd":"~/c","provider":"shell","status":"exited","exitCode":1}
        ]}
        """
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .sessions(sessions) = message else {
            return XCTFail("expected a session list")
        }
        XCTAssertEqual(sessions.map(\.id), ["s1", "s3"])
        XCTAssertEqual(sessions[1].exitCode, 1)
    }

    func testLastActivityIsReadEvenThoughRemoteSessionHasNoField() {
        let raw = """
        {"t":"sessions","sessions":[
          {"id":"s1","title":"one","cwd":"~/a","provider":"claude","status":"idle","exitCode":null,
           "lastActivityAt":1750000000000}
        ]}
        """
        guard case let .ok(_, activity) = WireCodec.decode(raw) else {
            return XCTFail("expected a session list")
        }
        XCTAssertEqual(activity["s1"], 1_750_000_000_000)
    }

    func testFractionalNumbersAreRefusedRatherThanTruncated() {
        // `as? Int` on 1.5 gives 1, which is a plausible exit code invented from
        // a broken one.
        let raw = #"{"t":"exit","id":"s1","exitCode":1.5}"#
        guard case .failed = WireCodec.decode(raw) else {
            return XCTFail("expected a refusal")
        }
    }

    func testBooleansAreNotNumbers() {
        let raw = #"{"t":"exit","id":"s1","exitCode":true}"#
        guard case .failed = WireCodec.decode(raw) else {
            return XCTFail("expected a refusal")
        }
    }

    // MARK: - other frames

    func testReplayIsOnlyTrueWhenTheDesktopSaysTrue() {
        guard case let .ok(.output(_, _, replay), _) = WireCodec.decode(#"{"t":"output","id":"s1","data":"hi"}"#) else {
            return XCTFail("expected output")
        }
        XCTAssertFalse(replay)

        guard case let .ok(.output(_, _, marked), _) =
                WireCodec.decode(#"{"t":"output","id":"s1","data":"hi","replay":true}"#) else {
            return XCTFail("expected output")
        }
        XCTAssertTrue(marked)
    }

    func testUnknownErrorCodeIsRefused() {
        guard case .failed = WireCodec.decode(#"{"t":"error","code":"teapot","message":"no"}"#) else {
            return XCTFail("expected a refusal")
        }
    }

    func testCaptivePortalHtmlIsNotAMessage() {
        guard case let .failed(reason) = WireCodec.decode("<html><body>Sign in to WiFi</body></html>") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, "not JSON")
    }

    func testUnknownMessageTypeIsDroppedNotCrashed() {
        guard case .failed = WireCodec.decode(#"{"t":"telemetry","payload":1}"#) else {
            return XCTFail("expected a refusal")
        }
    }

    // MARK: - outbound

    func testAttachOmitsTheSizeWhenThereIsNone() {
        let text = WireCodec.encode(.attach(id: "s1", size: nil))
        XCTAssertFalse(text.contains("cols"))
        XCTAssertFalse(text.contains("rows"))
        XCTAssertTrue(text.contains("\"t\":\"attach\""))
    }

    func testAttachCarriesBothDimensionsOrNeither() {
        guard let size = TerminalSize(cols: 100, rows: 30) else { return XCTFail("valid size refused") }
        let object = decodeOutbound(WireCodec.encode(.attach(id: "s1", size: size)))
        XCTAssertEqual(object["cols"] as? Int, 100)
        XCTAssertEqual(object["rows"] as? Int, 30)
    }

    func testSizesOutsideTheProtocolRangeAreNotConstructible() {
        // A layout mid-transition really does produce a two-column terminal, and
        // the desktop answers an out-of-range resize by closing the socket.
        XCTAssertNil(TerminalSize(cols: 2, rows: 30))
        XCTAssertNil(TerminalSize(cols: 100, rows: 4))
        XCTAssertNil(TerminalSize(cols: 10_000, rows: 30))
    }

    // MARK: - create

    func testCreateWithNothingIsAWholeRequest() {
        // `{"t":"create"}` on its own means "wherever you would have started
        // one", which is what a phone that knows nothing about the Mac sends.
        let object = decodeOutbound(WireCodec.encode(.create(folder: nil, size: nil)))
        XCTAssertEqual(object["t"] as? String, "create")
        XCTAssertNil(object["cwd"])
        XCTAssertNil(object["cols"])
        XCTAssertNil(object["rows"])
    }

    func testCreateNamesTheFolderAsCwd() {
        // `cwd`, not `folder` and not `title`: the field name is the desktop's.
        // This app used to send `{"t":"create","title":…}`, a shape invented
        // against this repo's own stand-in that no desktop would have accepted.
        guard let size = TerminalSize(cols: 100, rows: 30) else { return XCTFail("valid size refused") }
        let object = decodeOutbound(WireCodec.encode(.create(folder: "/Users/apple/Projects/deck", size: size)))
        XCTAssertEqual(object["cwd"] as? String, "/Users/apple/Projects/deck")
        XCTAssertEqual(object["cols"] as? Int, 100)
        XCTAssertEqual(object["rows"] as? Int, 30)
        XCTAssertNil(object["title"])
    }

    func testCreateCarriesBothDimensionsOrNeither() {
        // The desktop's parser reads "both or neither, never one" and closes the
        // socket on a `create` carrying only `cols`. Funnelling construction
        // through `TerminalSize` means this client cannot express that frame.
        let object = decodeOutbound(WireCodec.encode(.create(folder: "/a", size: nil)))
        XCTAssertNil(object["cols"])
        XCTAssertNil(object["rows"])
    }

    func testCreatedCarriesTheWholeRow() {
        // The row rather than an id, so the tap that started the session is the
        // tap that opens it: with two sessions in one folder there is no way to
        // guess which of the rows in a `sessions` frame is the new one.
        let raw = """
        {"t":"created","session":
          {"id":"s9","title":"deck","cwd":"~/deck","provider":"shell","status":"idle","exitCode":null}}
        """
        guard case let .ok(message, _) = WireCodec.decode(raw), case let .created(session) = message else {
            return XCTFail("expected a created")
        }
        XCTAssertEqual(session.id, "s9")
        XCTAssertEqual(session.cwd, "~/deck")
    }

    func testCreatedWithoutAUsableRowIsRefused() {
        // Fatal here, unlike in a list where four of five rows is still useful:
        // this frame is one row and naming the session is the whole of its job.
        for raw in [
            #"{"t":"created"}"#,
            #"{"t":"created","session":null}"#,
            #"{"t":"created","session":{"id":"","title":"x","cwd":"~","provider":"shell","status":"idle"}}"#,
        ] {
            guard case .failed = WireCodec.decode(raw) else {
                return XCTFail("expected a refusal for \(raw)")
            }
        }
    }

    func testUnavailableIsACodeThisClientUnderstands() {
        // Added with `create`: the Mac understood, was allowed, and could not.
        // A client that refused the code would print "error with an unknown
        // code" instead of the sentence the user needed to read.
        let raw = #"{"t":"error","code":"unavailable","message":"The folder may have moved."}"#
        guard case let .ok(message, _) = WireCodec.decode(raw), case let .error(code, text) = message else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(code, .unavailable)
        XCTAssertEqual(text, "The folder may have moved.")
    }

    func testHelloCarriesTheProtocolVersionAndDevice() {
        let object = decodeOutbound(
            WireCodec.encode(WireCodec.hello(token: "t", device: DeviceDescriptor(name: "iPhone", platform: "iOS 17"))))
        XCTAssertEqual(object["protocol"] as? Int, Wire.protocolVersion)
        XCTAssertEqual((object["device"] as? [String: Any])?["name"] as? String, "iPhone")
    }

    // MARK: - chunking

    func testShortInputIsOneChunk() {
        XCTAssertEqual(WireCodec.chunkInput("hello"), ["hello"])
        XCTAssertEqual(WireCodec.chunkInput(""), [])
    }

    func testChunkingCountsUtf8BytesNotCharacters() {
        // 8,192 four-byte scalars are 8,192 characters and 32,768 bytes; a cap
        // applied to the character count would wave a paste through at twice
        // the limit.
        let paste = String(repeating: "😀", count: 8_192)
        let chunks = WireCodec.chunkInput(paste, maxBytes: 16 * 1024)
        XCTAssertEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, 16 * 1024)
        }
        XCTAssertEqual(chunks.joined(), paste)
    }

    func testChunkingNeverSplitsAScalar() {
        let paste = String(repeating: "😀", count: 100)
        for chunk in WireCodec.chunkInput(paste, maxBytes: 7) {
            XCTAssertFalse(chunk.unicodeScalars.contains { $0.value == 0xFFFD })
            XCTAssertLessThanOrEqual(chunk.utf8.count, 7)
        }
    }

    // MARK: - ids

    func testSessionIdsFromOutsideAreChecked() {
        XCTAssertTrue(SessionID.isValid("a1b2-c3_d4"))
        XCTAssertTrue(SessionID.isValid("0"))
        XCTAssertFalse(SessionID.isValid(""))
        XCTAssertFalse(SessionID.isValid("-leading-dash"))
        XCTAssertFalse(SessionID.isValid("../../etc/passwd"))
        XCTAssertFalse(SessionID.isValid("emoji😀"))
        XCTAssertFalse(SessionID.isValid(String(repeating: "a", count: 65)))
    }

    // MARK: -

    private func decodeOutbound(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("encode produced something that is not a JSON object")
            return [:]
        }
        return object
    }
}
