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

    /**
     * The curtain is read the opposite way round from a grant, and this is the
     * case that says why.
     *
     * Every other hardened boolean on this wire uses `literalTrue`, because
     * there the dangerous mistake is believing a permission nobody gave. `masked`
     * is a protection: `true` is the protection being **on**, so the dangerous
     * mistake is failing to believe it. `literalTrue` here would read
     * `{"masked":1}` as *not curtained* — and a frame that is not curtained is
     * one `WatchSurfaceUIView` dispatches taps and keystrokes against, because
     * every gesture guard is written `!frame.masked`. So: curtained unless the
     * host said, in a real boolean, that it is not.
     */
    func testTheCurtainIsOnUnlessTheHostSaidOtherwiseInARealBoolean() {
        func frame(_ maskedField: String, data: String = #""""#) -> BrowserFrame? {
            let json = """
            {"t":"browser.frame","window":"","seq":4,"w":8,"h":6,"dw":4,"dh":3,
             "scale":2,"offsetTop":0,"pageScale":1,"scrollX":0,"scrollY":0,
             \(maskedField)"data":\(data)}
            """
            guard case let .browserFrame(f) = decoded(json) else { return nil }
            return f
        }

        // A numeric 1 is not a boolean, and the safe reading of a curtain flag
        // that is not a boolean is that the curtain is up.
        XCTAssertEqual(frame(#""masked":1,"#)?.masked, true)
        // So is a string, and so is a null.
        XCTAssertEqual(frame(#""masked":"yes","#)?.masked, true)
        XCTAssertEqual(frame(#""masked":null,"#)?.masked, true)
        // Only a real `false` — or the field not being there at all, which is
        // every ordinary frame — takes it down.
        XCTAssertEqual(frame(#""masked":false,"#, data: #""aGk=""#)?.masked, false)
        XCTAssertEqual(frame("", data: #""aGk=""#)?.masked, false)
    }

    /**
     * No pixels is a curtain, whatever the flag says.
     *
     * The far end enforces the pairing from its side — a masked frame carrying
     * data is refused outright, because *"a masked frame with pixels in it is a
     * redaction that leaked."* This is the same invariant read from this end: an
     * empty frame that claims to be ordinary used to arrive as `masked: false`
     * with nothing to draw, and every gesture guard keys on `masked` rather than
     * on the bytes — so touches went to a page nobody could see.
     */
    func testAFrameWithNoPixelsIsACurtainEvenIfItSaysItIsNot() {
        let json = """
        {"t":"browser.frame","window":"","seq":4,"w":8,"h":6,"dw":4,"dh":3,
         "scale":2,"offsetTop":0,"pageScale":1,"scrollX":0,"scrollY":0,
         "masked":false,"data":""}
        """
        guard case let .browserFrame(frame) = decoded(json) else { return XCTFail() }
        XCTAssertTrue(frame.masked)
        XCTAssertTrue(frame.data.isEmpty)
    }

    /**
     * The other half of the sweep: the flags that decide a permission are read
     * strictly, and the ones that describe something are not.
     *
     * `granted` says a folder is already shared with an agent and `canType` says
     * this phone may draw a composer that types into somebody's running session.
     * Both would have read `1` as yes. `live`, beside `canType` in the same
     * object, colours a chip — it stays lenient, and this pins that the line was
     * drawn deliberately rather than missed.
     */
    func testOnlyThePermissionFlagsAreReadStrictly() {
        let folders = decoded(#"{"t":"folders.entries","path":"/a","entries":[{"name":"n","path":"/a/n","granted":1,"readable":1}]}"#)
        guard case let .folderEntries(_, _, entries) = folders else { return XCTFail() }
        XCTAssertEqual(entries.first?.granted, false, "a numeric 1 is not a grant")
        // `readable` keeps its `?? true` default and its lenient read: it decides
        // nothing but whether a tap is worth trying, and a strict read would grey
        // out every row a host does not annotate.
        XCTAssertEqual(entries.first?.readable, true)

        /*
         * Through `JSONSerialization`, not a Swift dictionary literal — and that
         * is not a detail, it is the whole trap. A native Swift `Int` in an
         * `[String: Any]` does **not** cast to `Bool`, so a hand-built fixture
         * quietly proves nothing: this assertion passed against the lenient code
         * on its first run for exactly that reason. Only an `NSNumber`, which is
         * what a decoded frame actually carries, goes through the ObjC bridge.
         */
        let gateJSON = #"{"live":1,"gate":{"canType":1}}"#
        let object = try! JSONSerialization.jsonObject(with: gateJSON.data(using: .utf8)!)
        let reading = WireCodec.controlsReading(object)
        XCTAssertFalse(reading.canType, "a numeric 1 does not open the composer")
        XCTAssertTrue(reading.live, "the descriptive flag beside it is deliberately lenient")

        // And the credential sheet, where the comment in the codec had promised
        // this behaviour for longer than the code delivered it: `prompt` is an
        // instruction to interrupt somebody and ask them for a secret.
        let ask = decoded(#"{"t":"credential.request","id":"c1","host":"github.com","operation":"read","prompt":1}"#)
        guard case let .credentialRequest(_, _, _, _, prompt) = ask else { return XCTFail() }
        XCTAssertFalse(prompt, "a numeric 1 does not raise a credential prompt")
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

    // MARK: - browser handover

    /**
     * The two client→host frames of the handover, which are the answer to the
     * half of his sentence the cast could not give.
     *
     * `carryOn` is written and never defaulted: the far end refuses a `done`
     * without it, because *done, keep going* and *stop, I'll take it from here*
     * end in two different places and a frame that forgot to say which is one
     * whose meaning would be invented — and the invented reading is the
     * destructive one half the time.
     */
    func testTheHandoverVerbsEncode() {
        let take = WireCodec.encode(.browserHandoverTake(rid: "h1", window: "B2"))
        let t = try! JSONSerialization.jsonObject(with: take.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(t["t"] as? String, "browser.handover.take")
        XCTAssertEqual(t["window"] as? String, "B2")
        XCTAssertEqual(t["rid"] as? String, "h1")

        for answer in [true, false] {
            let done = WireCodec.encode(.browserHandoverDone(rid: "h2", window: "B2", carryOn: answer))
            let d = try! JSONSerialization.jsonObject(with: done.data(using: .utf8)!) as! [String: Any]
            XCTAssertEqual(d["t"] as? String, "browser.handover.done")
            XCTAssertEqual(d["carryOn"] as? Bool, answer)
        }
    }

    /// The state frame: an answer when it carries a `rid`, an unsolicited push
    /// when it does not. Both shapes decode, and `mine` and `taken` come across
    /// as the two separate facts they are — *do I hold it* and *does anybody*.
    func testHandoverStateDecodesAsBothAnAnswerAndAPush() {
        let answer = decoded(#"{"t":"browser.handover.state","rid":"h1","window":"B2","asking":true,"prompt":"Sign in","mine":true,"taken":true}"#)
        guard case let .browserHandover(state) = answer else { return XCTFail() }
        XCTAssertEqual(state.rid, "h1")
        XCTAssertEqual(state.window, "B2")
        XCTAssertTrue(state.asking)
        XCTAssertTrue(state.mine)
        XCTAssertTrue(state.taken)
        XCTAssertEqual(state.prompt, "Sign in")

        // The third state, which used to have to be inferred: outstanding, not
        // mine, and held by somebody.
        let other = decoded(#"{"t":"browser.handover.state","window":"B2","asking":true,"prompt":"Sign in","mine":false,"taken":true}"#)
        guard case let .browserHandover(elsewhere) = other else { return XCTFail() }
        XCTAssertFalse(elsewhere.mine)
        XCTAssertTrue(elsewhere.taken)

        let push = decoded(#"{"t":"browser.handover.state","window":"","asking":true,"prompt":"Sign in","mine":false,"taken":false}"#)
        guard case let .browserHandover(pushed) = push else { return XCTFail() }
        XCTAssertNil(pushed.rid)
        XCTAssertFalse(pushed.taken)
        // The empty window is the front tab, which is the surface most pages a
        // phone opens on a server actually land on — never a malformed frame.
        XCTAssertEqual(pushed.window, "")
        XCTAssertFalse(pushed.mine)
    }

    /**
     * Read the safe way round, and refused when it names no surface.
     *
     * A missing `asking` reads as *nothing is being asked* and a missing `mine`
     * as *not mine*: both of those errors leave a person looking at a page they
     * are told they may not type into, where the errors the other way round put
     * a claim button under a question nobody asked. The prompt crosses the same
     * ceiling the curtain sentence crosses under — it is the same sentence
     * arriving by the other road.
     */
    func testHandoverStateIsNarrowedDefensively() {
        let vague = decoded(#"{"t":"browser.handover.state","window":"B2","asking":"yes","mine":1,"taken":1,"prompt":7}"#)
        guard case let .browserHandover(state) = vague else { return XCTFail() }
        XCTAssertFalse(state.asking)
        XCTAssertFalse(state.taken)
        /*
         * `"mine": 1` is the one that is not obvious, and it is why every field
         * of this frame goes through `WireCodec.literalTrue`.
         * `JSONSerialization` hands back an `NSNumber` for every JSON number and
         * Foundation bridges `NSNumber(1)` to `Bool` through the ObjC bridge, so
         * the ordinary `as? Bool == true` spelling reads a numeric 1 as **true**
         * — which on this field is a phone believing it may type into somebody's
         * login. This test failed on its first run for exactly that reason.
         */
        XCTAssertFalse(state.mine)
        XCTAssertEqual(state.prompt, "")

        XCTAssertNil(decoded(#"{"t":"browser.handover.state","asking":true,"mine":true}"#),
                     "a state naming no surface cannot be applied to one")

        let long = String(repeating: "x", count: Wire.maxWatchPromptLength + 40)
        let capped = decoded("{\"t\":\"browser.handover.state\",\"window\":\"B2\",\"asking\":true,\"mine\":false,\"taken\":false,\"prompt\":\"\(long)\"}")
        guard case let .browserHandover(bounded) = capped else { return XCTFail() }
        XCTAssertEqual(bounded.prompt.count, Wire.maxWatchPromptLength)
    }
}
