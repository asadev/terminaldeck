import CoreGraphics
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac to Mac (31 Oct): Mac A (`BackendRemoteMacScreens`) shows Mac B's screen. Mac B is the real remote host with the
/// real `sims` service and a fake screen and fake input; the two are joined in memory where the link would carry the
/// frames (3 Nov: the screen is H.264 on the direct link, decoded on Mac A). The access rules are Mac B's: Work or Full
/// control to watch, Full control to click and type.
@Suite("Mac to Mac over the real host", .serialized)
struct MacToMacHostTests {
    /// Mac B's screen and what reached it.
    private actor MacB {
        var inputs: [BackendPhoneDeviceInput] = []
        var viewers: [[BackendPhoneMacViewer]] = []
        func input(_ value: BackendPhoneDeviceInput) { inputs.append(value) }
        func saw(_ value: [BackendPhoneMacViewer]) { viewers.append(value) }
    }
    private actor Screen: BackendPhoneDeviceStream {
        var count = 0
        func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
            count += 1
            try? await Task.sleep(for: .milliseconds(40))
            guard let buffer = VideoPipelineTests.buffer(MacToMacHostTests.desktop(shade: count)) else { return .unchanged }
            return .pixels(.init(buffer, capturedAt: Date().timeIntervalSince1970 * 1_000))
        }
        func endReason() -> String { "gone" }
        func stop() {}
    }
    /// What Mac A's viewer received.
    private actor Viewer {
        var pictures: [BackendRemoteMacPicture] = []
        var events: [BackendRemoteMacEvent] = []
        func picture(_ value: BackendRemoteMacPicture) { pictures.append(value) }
        func event(_ value: BackendRemoteMacEvent) { events.append(value) }
        var states: [String] { events.compactMap { if case let .state(state, _) = $0 { return state } else { return nil } } }
        var notes: [String] { events.compactMap { if case let .state(_, note) = $0 { return note } else { return nil } } }
        var refusals: [String] { events.compactMap { if case let .refused(words) = $0 { return words } else { return nil } } }
    }
    /// The relay, in memory: Mac B's frames to Mac A's screens actor, and Mac A's requests matched by rid.
    private actor Pipe {
        var waiting: [String: CheckedContinuation<NativeRPCValue, Error>] = [:]
        func wait(_ rid: String) async throws -> NativeRPCValue {
            try await withCheckedThrowingContinuation { waiting[rid] = $0 }
        }
        func deliver(_ frame: NativeRPCValue) -> Bool {
            guard let rid = frame["rid"].string, let waiter = waiting.removeValue(forKey: rid) else { return false }
            if frame["t"].string == "error" { waiter.resume(throwing: NativeRPCError(code: "refused", message: frame["message"].string ?? "")) }
            else { waiter.resume(returning: frame) }
            return true
        }
    }

    /// A Mac desktop with fine detail (like text), so pictures are large and cross in parts.
    static func desktop(width: Int = 1600, height: Int = 1000, shade: Int = 0) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 77 &+ UInt32(shade)
        for row in stride(from: 0, to: height, by: 2) { for col in stride(from: 0, to: width, by: 2) {
            seed = seed &* 1664525 &+ 1013904223
            let value = UInt8(truncatingIfNeeded: seed >> 24)
            for dy in 0..<2 { for dx in 0..<2 where row + dy < height && col + dx < width { for c in 0..<3 { bytes[((row + dy) * width + col + dx) * 4 + c] = value } } }
        } }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    private static let display = NativeRPCValue.object([.init("id", .string("mac:2")), .init("name", .string("Studio Mac")), .init("platform", .string("mac")),
        .init("kind", .string("display")), .init("state", .string("ready")), .init("runtime", .string("5120 × 2880")), .init("canWatch", .bool(true)),
        .init("canControl", .bool(true)), .init("note", .string(""))])

    /// Mac B approves Mac A at `level` and serves its screen; Mac A's screens actor is linked to it.
    private func pair(level: BackendINT2PhoneAccessLevel) async throws -> (BackendRemoteHost, BackendPhoneDevices.Installation, BackendRemoteMacScreens, MacB, UUID, BackendRemoteTrustStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("M2M-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Office MacBook", address: "fixture", publicKey: nil, platform: "darwin")
        try await trust.approveWithPhoneAccess(device.device.id, level: level)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Studio Mac", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let macB = MacB(), screens = BackendRemoteMacScreens(), pipe = Pipe()
        var source = BackendPhoneDevices.Source(
            list: { .object([.init("available", .bool(true)), .init("devices", .array([]))]) },
            power: { _, _ in .object([]) },
            stream: { _, _ in Screen() },
            input: { _, value in await macB.input(value) },
            shot: { _ in throw NativeRPCError(code: "unavailable", message: "no still in this test") },
            deliver: { _ in "" }, visibleSessions: { _ in [] },
            send: { [weak host] id, message in try await host?.sendToConnection(id, message: message) },
            macRows: { [Self.display] },
            phoneName: { context in await trust.device(context.deviceID)?.name ?? "?" },
            macViewers: { await macB.saw($0) })
        // Mac A's link to Mac B: the screen's video reaches its screens actor.
        PhoneScreenFixtures.link(&source) { value in await screens.received("mac-b", value) }
        let installation = try await BackendPhoneDevices.install(on: host, source: source)
        try await host.start()
        let timer = clock.scheduled.value() + 1
        // Mac A's side of the wire: every frame Mac B sends reaches its screens actor (or answers a request).
        let id = try #require(await host.accept(.init(address: "fixture", send: { text in
            let frame = try NativeRPCValue.parseJSON(Data(text.utf8))
            if await pipe.deliver(frame) { return }
            await screens.received("mac-b", frame)
        }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Office MacBook")), .init("platform", .string("darwin"))])), .init("capabilities", .array([]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        @Sendable func frame(_ type: String, _ fields: [NativeRPCValue.Field]) throws -> String {
            String(decoding: try NativeRPCValue.object([.init("t", .string(type))] + fields).encodedJSON(), as: UTF8.self)
        }
        await screens.bind(.init(
            send: { _, type, fields in await host.receive(id, text: try frame(type, fields)) },
            request: { _, type, fields, _ in
                let rid = "req-" + UUID().uuidString.prefix(8).lowercased()
                async let answer = pipe.wait(rid)
                try await Task.sleep(for: .milliseconds(5))
                await host.receive(id, text: try frame(type, fields + [.init("rid", .string(rid))]))
                return try await answer
            },
            name: { _ in "Studio Mac" }))
        try await Task.sleep(for: .milliseconds(100))
        return (host, installation, screens, macB, id, trust, dir)
    }

    @Test func fullControlMacSeesAndDrivesTheOtherMac() async throws {
        let (host, installation, screens, macB, _, trust, dir) = try await pair(level: .full)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        // Mac A lists Mac B's displays (its "This Mac" rows).
        let displays = try await screens.displays("mac-b")
        #expect(displays.map { $0["name"].string } == ["Studio Mac"])
        // Mac A opens the display: H.264 arrives on the link, is joined and decoded here, and each ack lets the next come.
        let viewer = Viewer()
        try await screens.open("mac-b", display: "mac:2", onPicture: { picture in Task { await viewer.picture(picture) } },
                               onEvent: { event in Task { await viewer.event(event) } })
        try await waitFor { await viewer.pictures.count >= 1 }
        let first = try #require(await viewer.pictures.first)
        #expect(first.width == 1600 && first.height == 1000, "a whole decoded picture")
        #expect(await viewer.states.contains("live"))
        try await waitFor { await viewer.pictures.count >= 2 }
        // Mac B's card names Mac A.
        try await waitFor { await macB.viewers.last?.first?.phone == "Office MacBook" }
        // Mac A's real mouse and keys: a right click, a drag, ⌘C and a typed Urdu word reach Mac B in order.
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("mouse")), .init("phase", .string("down")), .init("button", .string("right")),
                                                        .init("x", .number(0.25)), .init("y", .number(0.5)), .init("clicks", .number(1))])
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("mouse")), .init("phase", .string("drag")), .init("button", .string("left")),
                                                        .init("x", .number(0.3)), .init("y", .number(0.5))])
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("keycode")), .init("code", .number(8)), .init("down", .bool(true)),
                                                        .init("mods", .array([.string("command")]))])
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("type")), .init("text", .string("سلام"))])
        try await waitFor { await macB.inputs.count == 4 }
        #expect(await macB.inputs == [.mouse(phase: "down", button: "right", x: 0.25, y: 0.5, clicks: 1),
                                      .mouse(phase: "drag", button: "left", x: 0.3, y: 0.5, clicks: 1),
                                      .keyCode(8, down: true, modifiers: ["command"]), .type("سلام")])
        try await waitFor { await macB.viewers.last?.first?.controlling == true }
        // MCP status lists the remote view; closing it lets Mac B's card go.
        #expect(await screens.watching().first?["display"].string == "mac:2")
        // A button and a key still down when the view ends are let go on Mac B (Reviewer, 31 Oct).
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("mouse")), .init("phase", .string("down")), .init("button", .string("left")),
                                                        .init("x", .number(0.6)), .init("y", .number(0.4)), .init("clicks", .number(1))])
        try await waitFor { await macB.inputs.count == 5 }
        await screens.close("mac-b", display: "mac:2")
        try await waitFor { await macB.viewers.last?.isEmpty == true }
        // Held: the right button (pressed first, never released), the left button and ⌘C's key 8.
        try await waitFor { await macB.inputs.count == 8 }
        let released = Array(await macB.inputs.suffix(3))
        #expect(released == [.mouse(phase: "up", button: "left", x: 0.6, y: 0.4, clicks: 1), .mouse(phase: "up", button: "right", x: 0.6, y: 0.4, clicks: 1),
                             .keyCode(8, down: false, modifiers: [])])
    }

    /// Security M1 (27): a connected computer's bad screen message (numbers out of range, unlimited pieces, an empty
    /// video header) is dropped and a keyframe asked for; this Mac's app stays up and the screen carries on.
    @Test func badScreenMessagesAreDroppedAndAskForAKeyframe() async throws {
        func frame(_ json: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(json.utf8)) }
        let bad = [#"{"t":"sims.video","id":"mac:2","seq":1e300,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":-1,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1.5,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":1e9,"part":0,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":65,"part":0,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":0,"part":0,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":2,"part":-1,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":2,"part":2,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"parts":2,"part":1e300,"data":"AAAAAWU=","key":true}"#,
                   #"{"t":"sims.video","id":"mac:2","seq":1,"data":"","key":true}"#]
        // The rules: each one refused, and a keyframe asked (at most once a second).
        var rules = BackendVideoViewerRules()
        var now = 10_000.0
        for text in bad {
            now += 1_001
            #expect(rules.take(try frame(text), now: now) == .refused(askKey: true), "\(text)")
        }
        #expect(rules.take(try frame(bad[0]), now: now + 10) == .refused(askKey: false), "asked at most once a second")
        // Pieces past 4 MiB in all are refused, and forgotten.
        let big = String(repeating: "A", count: 1_100_000)
        rules = BackendVideoViewerRules()
        var outcomes: [BackendVideoViewerRules.Outcome] = []
        for part in 0..<4 { outcomes.append(rules.take(try frame(#"{"t":"sims.video","id":"mac:2","seq":3,"parts":5,"part":\#(part),"data":"\#(big)","key":true}"#), now: 20_000)) }
        #expect(outcomes == [.waiting, .waiting, .waiting, .refused(askKey: true)])
        // An empty video header (`"sps":""`) never reaches VideoToolbox.
        #expect(BackendH264Decoder().decode(Data([0, 0, 0, 1, 0x65, 0x88]), sps: Data(), pps: Data()) == nil)
        #expect(BackendH264Decoder().decode(Data(), sps: nil, pps: nil) == nil)
        // Live: the same messages reach the open viewer, which drops each; the screen keeps coming afterwards.
        let (host, installation, screens, _, _, trust, dir) = try await pair(level: .full)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        let viewer = Viewer()
        try await screens.open("mac-b", display: "mac:2", onPicture: { picture in Task { await viewer.picture(picture) } },
                               onEvent: { event in Task { await viewer.event(event) } })
        try await waitFor { await viewer.pictures.count >= 1 }
        for text in bad { await screens.received("mac-b", try frame(text)) }
        let before = await viewer.pictures.count
        try await waitFor { await viewer.pictures.count > before }
        #expect(await viewer.pictures.last?.width == 1600, "still a whole decoded picture")
    }

    @Test func workMacWatchesButCannotClick() async throws {
        let (host, installation, screens, macB, _, trust, dir) = try await pair(level: .work)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        let viewer = Viewer()
        try await screens.open("mac-b", display: "mac:2", onPicture: { picture in Task { await viewer.picture(picture) } },
                               onEvent: { event in Task { await viewer.event(event) } })
        try await waitFor { await viewer.pictures.count >= 1 }
        await screens.input("mac-b", display: "mac:2", [.init("do", .string("mouse")), .init("phase", .string("down")), .init("button", .string("left")),
                                                        .init("x", .number(0.5)), .init("y", .number(0.5))])
        try await waitFor { await !viewer.refusals.isEmpty }
        #expect(await viewer.refusals.first == BackendPhoneDevices.macControlRefused)
        #expect(await macB.inputs.isEmpty)
    }

    @Test func lookOnlyMacMayNotWatch() async throws {
        let (host, installation, screens, _, _, trust, dir) = try await pair(level: .look)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        let viewer = Viewer()
        try await screens.open("mac-b", display: "mac:2", onPicture: { picture in Task { await viewer.picture(picture) } },
                               onEvent: { event in Task { await viewer.event(event) } })
        try await waitFor { await viewer.states.contains("ended") }
        #expect(await viewer.notes.last == BackendPhoneDevices.macWatchRefused)
        #expect(await viewer.pictures.isEmpty)
    }

    @Test func aRefusedClickDoesNotEndTheMachineLink() async throws {
        // Reviewer, 31 Oct: Mac B's refusal of one click (it carries the click's rid) must not drop Mac A's link, or the
        // viewer asks again on every reconnect, forever. A refusal without a rid (a revoked device) still ends it.
        let guest = BackendRemoteGuest(id: "mac-b", secrets: .init(hostID: "host", hostPublicKey: Data(repeating: 1, count: 32), relayURL: "wss://relay.example",
            credential: "x.y", guestIdentity: .generate()), localName: "Office MacBook", onState: { _ in }, onOutput: { _, _, _ in }, onWelcome: { _ in })
        try await guest.feedForTest(#"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"Office MacBook","token":null,"sessions":[],"capabilities":["sims"]}"#)
        #expect(await guest.state().phase == .online)
        for code in ["unavailable", "unauthorized"] {   // Mac B now answers "unavailable" (its access-denied); an older Mac B said "unauthorized"
            try await guest.feedForTest(#"{"t":"error","code":"\#(code)","message":"\#(BackendPhoneDevices.macControlRefused)","rid":"m2m-in-7"}"#)
            #expect(await guest.state().phase == .online, "a refused request (\(code)) leaves the link up")
        }
        try await guest.feedForTest(#"{"t":"error","code":"unauthorized","message":"This device is no longer approved."}"#)
        #expect(await guest.state().phase != .online, "a refusal of the link itself ends it")
        await guest.disconnect()
    }

    @Test func macMouseAndKeyCodesAreCheckedShapes() {
        func refused(_ text: String) -> Bool { if case .refused = BackendRemoteProtocol.parseClientMessage(text) { return true }; return false }
        #expect(!refused(#"{"t":"sims.input","rid":"r","id":"mac:2","do":"mouse","phase":"down","button":"middle","x":0.1,"y":0.9,"clicks":2}"#))
        #expect(refused(#"{"t":"sims.input","rid":"r","id":"mac:2","do":"mouse","phase":"wiggle","button":"left","x":0.1,"y":0.9}"#))
        #expect(refused(#"{"t":"sims.input","rid":"r","id":"mac:2","do":"keycode","code":300,"down":true}"#))
        #expect(!refused(#"{"t":"sims.input","rid":"r","id":"mac:2","do":"keycode","code":122,"down":false,"mods":["fn","shift"]}"#))
    }

    @Test func machineLinksRetryWithinThirtySeconds() {
        // The relay link's own rule (BackendRemoteRelayClient) is shared by the machine links' 30 s ceiling.
        #expect(BackendRemoteRelayClient.retryDelay(attempt: 9, jitter: 1) == 30_000)
    }

    private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "fixture-timeout", message: "The other Mac did not answer.")
    }
}
