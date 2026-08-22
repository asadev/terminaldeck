/**
 * The 0.10.0 frames on the wire: welcome's version fields, sign-in, the control
 * cluster, the server settings, the device roster, and the live browser view.
 *
 * These are the decisions a screenshot cannot show — an allowlist that drops a
 * key it does not know, a masked frame that carries no pixels, a base64 body
 * refused before it reaches an image decoder, the claimed capabilities a host
 * reads to decide what to push. Each is the Swift mirror of a rule in
 * `src/main/remote/protocol.ts` and its PWA client.
 */

import XCTest
@testable import TerminalDeck

final class ParityWireTests: XCTestCase {

    private func decoded(_ json: String) -> ServerMessage? {
        guard case let .ok(message, _) = WireCodec.decode(json) else { return nil }
        return message
    }

    // MARK: - welcome: version awareness

    func testWelcomeCarriesAppVersionAndHostKind() {
        let json = """
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["controls"],"hostPlatform":"win32",
         "appVersion":"0.10.0","hostKind":"headless"}
        """
        guard case let .welcome(_, _, _, _, _, _, platform, _, _, _, appVersion, kind) = decoded(json) else {
            return XCTFail("expected a welcome")
        }
        XCTAssertEqual(platform, .windows)
        XCTAssertEqual(appVersion, "0.10.0")
        XCTAssertEqual(kind, .headless)
    }

    func testAWelcomeBeforeTheseFieldsIsStillAWelcome() {
        // Absent means older, and older is a real answer: no version, a neutral
        // kind — never a guess.
        let json = """
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,"sessions":[]}
        """
        guard case let .welcome(_, _, _, _, _, _, _, _, _, _, appVersion, kind) = decoded(json) else {
            return XCTFail("expected a welcome")
        }
        XCTAssertNil(appVersion)
        XCTAssertEqual(kind, .unknown)
    }

    func testAnUnknownHostKindIsDroppedNotGuessed() {
        let json = """
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"hostKind":"toaster"}
        """
        guard case let .welcome(_, _, _, _, _, _, _, _, _, _, _, kind) = decoded(json) else {
            return XCTFail("expected a welcome")
        }
        XCTAssertEqual(kind, .unknown)
    }

    // MARK: - claimed capabilities

    func testTheClientClaimsTheFourPushAndDualCapabilities() {
        // The same list `CLAIMED_CAPABILITIES` carries in the PWA: a question the
        // desktop asks (credential), two pushes a client would otherwise miss
        // (devices, settings), and the client half of a dual-listed name (watch).
        XCTAssertEqual(Set(WireCapability.claimed),
                       [WireCapability.credential, WireCapability.devices,
                        WireCapability.settings, WireCapability.watch])
    }

    // MARK: - sign-in

    func testEnrollEncodesTheLoginAndClaimedCapabilities() {
        let frame = WireCodec.encode(.enroll(protocolVersion: 1,
                                             device: DeviceDescriptor(name: "iPhone", platform: "ios"),
                                             username: "asad", secret: "hunter2",
                                             method: .password, capabilities: WireCapability.claimed))
        let object = try! JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(object["t"] as? String, "enroll")
        XCTAssertEqual(object["username"] as? String, "asad")
        XCTAssertEqual(object["secret"] as? String, "hunter2")
        XCTAssertEqual(object["method"] as? String, "password")
        XCTAssertEqual((object["capabilities"] as? [String])?.contains("watch"), true)
    }

    func testEnrolledDecodes() {
        let json = #"{"t":"enrolled","deviceId":"dev-9","deviceName":"iPhone","credential":"dev-9.abc"}"#
        guard case let .enrolled(id, name, credential) = decoded(json) else { return XCTFail() }
        XCTAssertEqual(id, "dev-9")
        XCTAssertEqual(name, "iPhone")
        XCTAssertEqual(credential, "dev-9.abc")
    }

    // MARK: - controls

    func testControlsReadAndApplyEncode() {
        let read = WireCodec.encode(.controlsRead(rid: "r1", id: "s1"))
        XCTAssertTrue(read.contains("\"t\":\"controls.read\"") || read.contains("controls.read"))
        let apply = WireCodec.encode(.controlsApply(rid: "r2", id: "s1", control: .effort, value: "xhigh"))
        let object = try! JSONSerialization.jsonObject(with: apply.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(object["t"] as? String, "controls.apply")
        XCTAssertEqual(object["control"] as? String, "effort")
        XCTAssertEqual(object["value"] as? String, "xhigh")
    }

    func testControlsReadingNarrowsDefensively() {
        // A reading with a bad gate and no agent draws nothing — the safe read,
        // which greys the chips rather than offering a press that is refused.
        let json = """
        {"t":"controls.reading","rid":"r1","id":"s1","reading":{
          "model":{"value":"opus","label":"Opus 5","source":"screen"},
          "effort":{"value":null,"label":null,"source":null},
          "fast":{"value":"off","label":"Off"},
          "permission":{"value":"auto","label":"Auto","unavailableReason":""},
          "live":true,"agent":{"running":true,"saw":"claude"},"gate":{"canType":true,"reason":null}}}
        """
        guard case let .controlsReading(_, _, reading) = decoded(json) else { return XCTFail() }
        XCTAssertEqual(reading.model.label, "Opus 5")
        XCTAssertNil(reading.effort.value)
        XCTAssertTrue(reading.live)
        XCTAssertTrue(reading.agentRunning)
        XCTAssertTrue(reading.canType)
    }

    func testControlsAppliedCarriesTheReReadReading() {
        // No `control` field on the wire — the asking side knows which control
        // this answers from the rid it minted, and the reading is what redraws.
        let json = """
        {"t":"controls.applied","rid":"r2","id":"s1","ok":true,"message":"Effort is now Extra high.",
         "reading":{"value":"xhigh","label":"Extra high","source":"screen"}}
        """
        guard case let .controlsApplied(_, _, ok, message, reading) = decoded(json) else { return XCTFail() }
        XCTAssertTrue(ok)
        XCTAssertEqual(message, "Effort is now Extra high.")
        XCTAssertEqual(reading.value, "xhigh")
    }

    // MARK: - settings

    func testSettingsApplyEncodesTheAllowlistedKey() {
        let frame = WireCodec.encode(.settingsApply(rid: "r1", key: .defaultProvider, value: "codex"))
        let object = try! JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(object["key"] as? String, "agents.defaultProvider")
        XCTAssertEqual(object["value"] as? String, "codex")
    }

    func testSettingsStateDropsAKeyOutsideTheAllowlist() {
        // `remote.enabled` and `advanced.debugMode` are unrepresentable here — a
        // row naming one is dropped, never carried inward.
        let json = """
        {"t":"settings.state","rid":"r1","settings":[
          {"key":"agents.defaultProvider","value":"claude","options":["claude","codex"]},
          {"key":"remote.enabled","value":"true"},
          {"key":"general.restoreSessions","value":"false"}]}
        """
        guard case let .settingsState(_, settings) = decoded(json) else { return XCTFail() }
        XCTAssertEqual(settings.map(\.key), [.defaultProvider, .restoreSessions])
        XCTAssertEqual(settings.first?.options, ["claude", "codex"])
    }

    func testSettingsChangedHasNoRid() {
        let json = #"{"t":"settings.changed","settings":[{"key":"general.restoreSessions","value":"true"}]}"#
        guard case let .settingsChanged(settings) = decoded(json) else { return XCTFail() }
        XCTAssertEqual(settings.first?.value, "true")
    }

    // MARK: - devices

    func testDevicesRevokeEncodes() {
        let frame = WireCodec.encode(.devicesRevoke(rid: "r1", device: "dev-2"))
        let object = try! JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(object["t"] as? String, "devices.revoke")
        XCTAssertEqual(object["device"] as? String, "dev-2")
    }

    func testDeviceRosterRowValidatesKindAndStatus() {
        // A kind or status this build does not know drops the row rather than
        // guessing, the same rule a dev-server status keeps.
        let good = WireCodec.deviceRosterRow([
            "id": "d1", "name": "iPhone", "kind": "mine", "status": "approved",
            "addedAt": 1000, "lastSeenAt": 2000, "connected": true, "fingerprint": "AA BB CC",
        ] as [String: Any])
        XCTAssertEqual(good?.kind, .mine)
        XCTAssertEqual(good?.connected, true)
        XCTAssertNil(WireCodec.deviceRosterRow([
            "id": "d1", "name": "iPhone", "kind": "unknown-kind", "status": "approved",
        ] as [String: Any]))
    }

    func testDevicesRowsDropsAMalformedRowNotTheList() {
        let json = """
        {"t":"devices.rows","rid":"r1","devices":[
          {"id":"d1","name":"iPhone","kind":"mine","status":"approved","connected":true},
          {"id":"","name":"broken","kind":"guest","status":"pending"},
          {"id":"d2","name":"iPad","kind":"guest","status":"pending","connected":false}]}
        """
        guard case let .devicesRows(_, devices) = decoded(json) else { return XCTFail() }
        XCTAssertEqual(devices.map(\.id), ["d1", "d2"])
    }

    // MARK: - browser watch

    func testBrowserWatchAndAckEncode() {
        let watch = WireCodec.encode(.browserWatch(window: "", maxWidth: 800, quality: 50))
        let w = try! JSONSerialization.jsonObject(with: watch.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(w["t"] as? String, "browser.watch")
        XCTAssertEqual(w["maxWidth"] as? Int, 800)
        let ack = WireCodec.encode(.browserFrameAck(window: "B2", seq: 7))
        let a = try! JSONSerialization.jsonObject(with: ack.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(a["t"] as? String, "browser.frame.ack")
        XCTAssertEqual(a["seq"] as? Int, 7)
    }

    func testBrowserInputWritesExactlyOneKind() {
        let mouse = WireCodec.encode(.browserInput(window: "", seq: 3,
            input: .mouse(.init(type: .down, x: 10, y: 20, button: .left, clicks: 1, dx: nil, dy: nil))))
        let m = try! JSONSerialization.jsonObject(with: mouse.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil(m["mouse"])
        XCTAssertNil(m["key"]); XCTAssertNil(m["touch"]); XCTAssertNil(m["paste"])
        let mouseObj = m["mouse"] as! [String: Any]
        XCTAssertEqual(mouseObj["type"] as? String, "down")
        XCTAssertEqual(mouseObj["button"] as? String, "left")

        let paste = WireCodec.encode(.browserInput(window: "", seq: 3, input: .paste("hi")))
        let p = try! JSONSerialization.jsonObject(with: paste.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(p["paste"] as? String, "hi")
        XCTAssertNil(p["mouse"])
    }

    func testBrowserInputTouchClipsToTheTouchPointCap() {
        let points = (0..<20).map { CGPoint(x: $0, y: $0) }
        let frame = WireCodec.encode(.browserInput(window: "", seq: 1, input: .touch(.init(type: .start, points: points))))
        let object = try! JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        let touch = object["touch"] as! [String: Any]
        XCTAssertEqual((touch["points"] as? [Any])?.count, Wire.maxTouchPoints)
    }

    func testAMaskedFrameCarriesNoPixels() {
        let json = """
        {"t":"browser.frame","window":"","seq":4,"w":800,"h":600,"dw":400,"dh":300,
         "scale":2,"offsetTop":0,"pageScale":1,"scrollX":0,"scrollY":0,"masked":true,
         "prompt":"typing a password","data":""}
        """
        guard case let .browserFrame(frame) = decoded(json) else { return XCTFail() }
        XCTAssertTrue(frame.masked)
        XCTAssertTrue(frame.data.isEmpty)
        XCTAssertEqual(frame.prompt, "typing a password")
    }

    func testACorruptFrameBodyIsRefusedNotHalfDecoded() {
        // A non-masked frame whose data is not valid base64 is refused here
        // rather than handed half-decoded to the image decoder — the `net.data`
        // rule, one wire.
        let json = """
        {"t":"browser.frame","window":"","seq":4,"w":8,"h":6,"dw":4,"dh":3,
         "scale":2,"offsetTop":0,"pageScale":1,"scrollX":0,"scrollY":0,"data":"not!base64!"}
        """
        if case .ok = WireCodec.decode(json) { XCTFail("a corrupt frame body should be refused") }
    }

    func testBrowserSurfacesRowsCarriesRidWhenAnswering() {
        let answer = decoded(#"{"t":"browser.surfaces.rows","rid":"r1","surfaces":[{"window":"","url":"https://x","title":"X","live":true}]}"#)
        guard case let .browserSurfaces(rid, surfaces) = answer else { return XCTFail() }
        XCTAssertEqual(rid, "r1")
        XCTAssertEqual(surfaces.first?.live, true)

        let push = decoded(#"{"t":"browser.surfaces.rows","surfaces":[]}"#)
        guard case let .browserSurfaces(pushRid, _) = push else { return XCTFail() }
        XCTAssertNil(pushRid)
    }
}
