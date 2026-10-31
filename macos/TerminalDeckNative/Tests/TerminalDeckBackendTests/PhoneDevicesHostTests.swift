import CoreGraphics
import Foundation
import ImageIO
import Testing
import TerminalDeckNativeCore
import UniformTypeIdentifiers
@testable import TerminalDeckBackend

/// The phone's Devices page (31 Oct): the Mac's simulators and emulators over the real host and a paired phone, with a
/// fake device engine: the list, a live watch paced by acks, input in order, Look only refused for driving, and an
/// annotated still drawn here and delivered.
@Suite("Phone devices over the real host", .serialized)
struct PhoneDevicesHostTests {
    private actor Wire {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func rows(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
    }
    private actor Engine {
        var inputs: [BackendPhoneDeviceInput] = []
        var powered: [(String, Bool)] = []
        var delivered: [BackendPhoneDeviceAnnotation] = []
        var streamsStopped = 0
        var macViewers: [[BackendPhoneMacViewer]] = []
        var inputIDs: [String] = []
        func viewers(_ value: [BackendPhoneMacViewer]) { macViewers.append(value) }
        func inputTo(_ id: String, _ value: BackendPhoneDeviceInput) { inputIDs.append(id); inputs.append(value) }
        func input(_ value: BackendPhoneDeviceInput) { inputs.append(value) }
        func power(_ id: String, _ on: Bool) { powered.append((id, on)) }
        func deliver(_ value: BackendPhoneDeviceAnnotation) { delivered.append(value) }
        func stopped() { streamsStopped += 1 }
    }
    /// A screen that draws a new picture every time it is asked.
    private actor FakeStream: BackendPhoneDeviceStream {
        let engine: Engine
        let noisy: Bool
        var count = 0
        var stopped = false
        init(engine: Engine, noisy: Bool = false) { self.engine = engine; self.noisy = noisy }
        func next(maxWidth: Int, quality: Int, maxBytes: Int) async -> BackendPhoneDeviceFrame? {
            guard !stopped else { return nil }
            count += 1
            let image = noisy ? PhoneDevicesHostTests.noise(width: 1600, height: 1000) : PhoneDevicesHostTests.picture(shade: count)
            return BackendPhoneDevices.encode(image, maxWidth: maxWidth, quality: quality, maxBytes: maxBytes)
        }
        func endReason() -> String { "gone" }
        func stop() async { if !stopped { stopped = true; await engine.stopped() } }
    }

    static func picture(shade: Int, width: Int = 390, height: Int = 844) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(shade % 10) / 10, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    /// A desktop-sized picture that does not compress (a fake Mac screen full of detail).
    static func noise(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        // Detail in 3-pixel blocks, like small text: hard to compress, but not pure noise.
        for row in 0..<height { for col in 0..<width where row % 3 == 0 && col % 3 == 0 {
            seed = seed &* 1664525 &+ 1013904223
            let value = UInt8(truncatingIfNeeded: seed >> 24)
            for dy in 0..<min(3, height - row) { for dx in 0..<min(3, width - col) { for c in 0..<3 { bytes[((row + dy) * width + col + dx) * 4 + c] = value } } }
        } }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static let rows = NativeRPCValue.object([.init("available", .bool(true)), .init("devices", .array([
        .object([.init("id", .string("ios:11111111-2222-3333-4444-555555555555")), .init("name", .string("iPhone 17")), .init("platform", .string("ios")),
                 .init("kind", .string("simulator")), .init("state", .string("ready")), .init("runtime", .string("iOS 27.0")),
                 .init("canBoot", .bool(false)), .init("canShutDown", .bool(true)), .init("canRotate", .bool(true)),
                 .init("buttons", .array([.string("home"), .string("lock")]))]),
        .object([.init("id", .string("avd:Scratch_Pixel")), .init("name", .string("Scratch Pixel")), .init("platform", .string("android")),
                 .init("kind", .string("emulator")), .init("state", .string("shutdown")), .init("canBoot", .bool(true))]),
    ]))])
    nonisolated(unsafe) private static var leases: [NativeRPCSubscription] = []
    private static let iphone = "ios:11111111-2222-3333-4444-555555555555"
    private static let macDisplay = "mac:1"
    private static let macRow = NativeRPCValue.object([.init("id", .string(macDisplay)), .init("name", .string("Studio Mac")), .init("platform", .string("mac")),
        .init("kind", .string("display")), .init("state", .string("ready")), .init("runtime", .string("3024 × 1964")), .init("canWatch", .bool(true)),
        .init("canControl", .bool(true)), .init("note", .string(""))])

    private func connect(level: BackendINT2PhoneAccessLevel, extra: [BackendRemoteHostFeature] = []) async throws -> (BackendRemoteHost, BackendPhoneDevices.Installation, Wire, Engine, UUID, BackendRemoteTrustStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SIMS-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: level)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let engine = Engine(), wire = Wire()
        let shotPNG = Self.png(Self.picture(shade: 3, width: 1170, height: 2532))
        let source = BackendPhoneDevices.Source(
            list: { Self.rows },
            power: { id, on in await engine.power(id, on); return .object([.init("ok", .bool(true)), .init("id", .string("android:emulator-5560"))]) },
            stream: { id, _ in FakeStream(engine: engine, noisy: id.hasPrefix("mac:")) },
            input: { id, value in await engine.inputTo(id, value) },
            shot: { _ in .init(png: shotPNG, width: 1170, height: 2532) },
            deliver: { value in await engine.deliver(value); return "Sent to Hoot." },
            visibleSessions: { _ in ["s-chat-1"] },
            send: { [weak host] id, message in try await host?.sendToConnection(id, message: message) },
            macRows: { [Self.macRow] }, phoneName: { _ in "Asad's iPhone" }, macViewers: { await engine.viewers($0) })
        let installation = try await BackendPhoneDevices.install(on: host, source: source)
        // The lease is kept for the test's life: a dropped lease takes its features away again.
        if !extra.isEmpty { Self.leases.append(try await host.installFeatures(ownerID: "fixture.extra", features: extra, connectionClosed: { _ in })) }
        try await host.start()
        let timer = clock.scheduled.value() + 1
        let id = try #require(await host.accept(.init(address: "fixture", send: { try await wire.receive($0) }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        try await waitFor { await wire.rows("welcome").count == 1 }
        return (host, installation, wire, engine, id, trust, dir)
    }

    @Test func listWatchAckInputAndAnnotate() async throws {
        let (host, installation, wire, engine, id, trust, dir) = try await connect(level: .work)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        let offered = await wire.rows("welcome").first?["capabilities"].elements ?? []
        #expect(offered.contains(.string("sims")), "the Mac offers its devices to its owner's phone")

        await host.receive(id, text: #"{"t":"sims.list","rid":"l1"}"#)
        try await waitFor { await !wire.rows("sims.rows").isEmpty }
        let list = try #require(await wire.rows("sims.rows").first)
        #expect(list["rid"].string == "l1")
        #expect(list["devices"].elements?.map { $0["name"].string ?? "" } == ["Studio Mac", "iPhone 17", "Scratch Pixel"], "this Mac first, then running devices")
        #expect(list["devices"].elements?.last?["canStart"].bool == true)

        // Watching: told it opens, then live, then pictures — never more than two unacked.
        await host.receive(id, text: #"{"t":"sims.watch","id":"\#(Self.iphone)","maxWidth":390,"quality":60,"fps":24}"#)
        try await waitFor { await wire.rows("sims.frame").count >= 2 }
        try await Task.sleep(for: .milliseconds(150))
        let states = await wire.rows("sims.state").map { $0["state"].string ?? "" }
        #expect(states.prefix(2) == ["opening", "live"])
        let early = await wire.rows("sims.frame")
        #expect(early.count == 2, "two pictures on the way, then it waits for an ack (got \(early.count))")
        let first = try #require(early.first)
        #expect(first["w"].number == 390)
        #expect((Data(base64Encoded: first["data"].string ?? "")?.count ?? 0) > 100)
        await host.receive(id, text: #"{"t":"sims.ack","id":"\#(Self.iphone)","seq":1}"#)
        try await waitFor { await wire.rows("sims.frame").count >= 3 }

        // Input in the order it came.
        await host.receive(id, text: #"{"t":"sims.input","rid":"i1","id":"\#(Self.iphone)","do":"tap","x":0.5,"y":0.25}"#)
        await host.receive(id, text: #"{"t":"sims.input","rid":"i2","id":"\#(Self.iphone)","do":"button","button":"home"}"#)
        await host.receive(id, text: #"{"t":"sims.input","rid":"i3","id":"\#(Self.iphone)","do":"type","text":"héllo"}"#)
        try await waitFor { await engine.inputs.count == 3 }
        #expect(await engine.inputs == [.tap(x: 0.5, y: 0.25, holdMilliseconds: nil), .button("home"), .type("héllo")])

        // A still, marked on the phone and drawn here at full size, then delivered.
        await host.receive(id, text: #"{"t":"sims.shot","rid":"s1","id":"\#(Self.iphone)"}"#)
        try await waitFor { await !wire.rows("sims.shot").isEmpty }
        let shot = try #require(await wire.rows("sims.shot").first)
        #expect(shot["w"].number == 1170 && shot["h"].number == 2532)
        let token = try #require(shot["shot"].string)
        await host.receive(id, text: #"{"t":"sims.annotate","rid":"a1","id":"\#(Self.iphone)","shot":"\#(token)","to":"hoot","note":"This button is cut off","marks":[{"c":0,"p":[0.1,0.1,0.5,0.5,0.9,0.2]}]}"#)
        try await waitFor { await !wire.rows("sims.sent").isEmpty }
        let sent = try #require(await wire.rows("sims.sent").first)
        #expect(sent["ok"].bool == true && sent["message"].string == "Sent to Hoot.")
        let delivered = try #require(await engine.delivered.first)
        #expect(delivered.note == "This button is cut off" && delivered.width == 1170 && delivered.to == "hoot")
        #expect(BackendPhoneDevices.image(delivered.png)?.width == 1170)

        // A chat the phone does not see is refused.
        await host.receive(id, text: #"{"t":"sims.annotate","rid":"a2","id":"\#(Self.iphone)","shot":"\#(token)","to":"s-other","marks":[]}"#)
        try await waitFor { await wire.rows("error").contains { $0["rid"].string == "a2" } }

        // Starting a device answers with the fresh list and the id it runs as.
        await host.receive(id, text: #"{"t":"sims.power","rid":"p1","id":"avd:Scratch_Pixel","on":true}"#)
        try await waitFor { await wire.rows("sims.rows").contains { $0["rid"].string == "p1" } }
        #expect(await wire.rows("sims.rows").first { $0["rid"].string == "p1" }?["started"].string == "android:emulator-5560")
        #expect(await engine.powered.first?.1 == true)

        // Unwatch stops the stream.
        await host.receive(id, text: #"{"t":"sims.unwatch","id":"\#(Self.iphone)"}"#)
        try await waitFor { await engine.streamsStopped == 1 }
        #expect(await installation.devices.watching().elements?.isEmpty == true)
    }

    /// Reviewer, 31 Oct: a real Mac said push and activity in no welcome (they were missing from the host's table of
    /// required messages). A Full-control phone is now offered every phone-round capability.
    @Test func aFullControlPhoneIsOfferedEveryPhoneRoundCapability() async throws {
        let push = BackendPhonePush(file: nil, host: .init(mayHear: { _, _ in true }, relay: { nil }, post: { _, _, _ in (200, Data()) }, macName: "Fixture"))
        func stub(_ capability: String, _ messages: Set<String>) -> BackendRemoteHostFeature {
            .init(capability: capability, messageTypes: messages, policy: .grantedDevice) { _, _ in [] }
        }
        let extra = [await push.feature(), stub(BackendPhoneActivity.capability, BackendPhoneActivity.messages),
                     stub("git.write", BackendPhoneChanges.writeMessages)]
        let (host, installation, wire, _, _, trust, dir) = try await connect(level: .full, extra: extra)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        let offered = Set((await wire.rows("welcome").first?["capabilities"].elements ?? []).compactMap(\.string))
        for name in ["push", "activity", "sims", "git.write"] { #expect(offered.contains(name), "welcome lacks \(name): \(offered.sorted())") }
    }

    @Test func lookOnlyMayWatchButNotDrive() async throws {
        let (host, installation, wire, engine, id, trust, dir) = try await connect(level: .look)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await host.receive(id, text: #"{"t":"sims.list","rid":"l1"}"#)
        try await waitFor { await !wire.rows("sims.rows").isEmpty }
        await host.receive(id, text: #"{"t":"sims.input","rid":"i1","id":"\#(Self.iphone)","do":"tap","x":0.5,"y":0.5}"#)
        await host.receive(id, text: #"{"t":"sims.power","rid":"p1","id":"\#(Self.iphone)","on":false}"#)
        try await waitFor { await wire.rows("error").count >= 2 }
        let inputs = await engine.inputs, powered = await engine.powered
        #expect(inputs.isEmpty && powered.isEmpty)
    }

    @Test func thisMacStreamsInPartsAndOnlyFullControlDrives() async throws {
        let (host, installation, wire, engine, id, trust, dir) = try await connect(level: .full)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await host.receive(id, text: #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":1600,"quality":70,"fps":20}"#)
        try await waitFor {
            let first = await wire.rows("sims.frame").filter { $0["seq"].number == 1 }
            return first.count >= 2 && Double(first.count) == first.first?["parts"].number
        }
        // A detailed Mac picture is larger than one frame may carry: it crosses in parts that join back to one JPEG.
        let parts = await wire.rows("sims.frame").filter { $0["seq"].number == 1 }
        #expect(parts.count >= 2, "a large picture is sent in parts")
        #expect(parts.allSatisfy { $0["parts"].number == Double(parts.count) })
        let joined = parts.sorted { ($0["part"].number ?? 0) < ($1["part"].number ?? 0) }.compactMap { $0["data"].string }.joined()
        let jpeg = try #require(Data(base64Encoded: joined))
        #expect(jpeg.count > BackendPhoneDevices.frameBudget && jpeg.count <= BackendPhoneDevices.macFrameBudget)
        #expect((BackendPhoneDevices.image(jpeg)?.width ?? 0) > 600, "detail kept: still a large picture")
        // The Mac's card is told who watches.
        try await waitFor { await engine.macViewers.last?.first?.phone == "Asad's iPhone" }
        // Full control: a right click, a scroll and a shortcut reach the Mac.
        await host.receive(id, text: #"{"t":"sims.input","rid":"i1","id":"mac:1","do":"tap","x":0.5,"y":0.5,"right":true}"#)
        await host.receive(id, text: #"{"t":"sims.input","rid":"i2","id":"mac:1","do":"scroll","x":0.5,"y":0.5,"dx":0,"dy":-0.2}"#)
        await host.receive(id, text: #"{"t":"sims.input","rid":"i3","id":"mac:1","do":"key","key":"c","mods":["command"]}"#)
        try await waitFor { await engine.inputs.count == 3 }
        #expect(await engine.inputs == [.secondaryTap(x: 0.5, y: 0.5), .scroll(x: 0.5, y: 0.5, dx: 0, dy: -0.2), .shortcut("c", modifiers: ["command"])])
        #expect(await engine.inputIDs.allSatisfy { $0 == "mac:1" })
        try await waitFor { await engine.macViewers.last?.first?.controlling == true }
        // Stop on the Mac: the phone is told, the card empties.
        await installation.devices.stopMac()
        try await waitFor { await wire.rows("sims.state").contains { $0["id"].string == "mac:1" && $0["state"].string == "ended" } }
        #expect(await engine.macViewers.last?.isEmpty == true)
    }

    /// Reviewer, 31 Oct: the safe default is that a Look-only phone may not watch this Mac's screen, nor take a still
    /// of it (`macWatchLevels`, one switch); it may still watch a simulator.
    @Test func lookOnlyPhoneMayNotWatchThisMac() async throws {
        let (host, installation, wire, _, id, trust, dir) = try await connect(level: .look)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await host.receive(id, text: #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":800,"quality":50}"#)
        await host.receive(id, text: #"{"t":"sims.shot","rid":"s1","id":"mac:1"}"#)
        try await waitFor { await wire.rows("error").filter { ["w1", "s1"].contains($0["rid"].string ?? "") }.count == 2 }
        #expect(await wire.rows("error").allSatisfy { $0["message"].string == BackendPhoneDevices.macWatchRefused })
        let frames = await wire.rows("sims.frame"), shots = await wire.rows("sims.shot")
        #expect(frames.isEmpty && shots.isEmpty)
        #expect(!BackendPhoneDevices.macWatchLevels.contains(.look))
    }

    @Test func workPhoneMayWatchThisMacButNotClick() async throws {
        let (host, installation, wire, engine, id, trust, dir) = try await connect(level: .work)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await host.receive(id, text: #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":800,"quality":50}"#)
        try await waitFor { await !wire.rows("sims.frame").isEmpty }
        await host.receive(id, text: #"{"t":"sims.input","rid":"i1","id":"mac:1","do":"tap","x":0.5,"y":0.5}"#)
        try await waitFor { await wire.rows("error").contains { $0["rid"].string == "i1" } }
        #expect(await wire.rows("error").first { $0["rid"].string == "i1" }?["message"].string == BackendPhoneDevices.macControlRefused)
        #expect(await engine.inputs.isEmpty)
    }

    @Test func relayRetriesSoonAndNeverWaitsMoreThanThirtySeconds() {
        #expect((1...7).map { BackendRemoteRelayClient.retryDelay(attempt: $0, jitter: 1) } == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000])
        #expect(BackendRemoteRelayClient.retryDelay(attempt: 40, jitter: 1.2) == 30_000)
        #expect(BackendRemoteRelayClient.retryDelay(attempt: 2, jitter: 0.8) == 1_600)
        #expect(BackendRemoteRelayClient.heartbeatSeconds == 10 && BackendRemoteRelayClient.pongSeconds == 30)
    }

    @Test func thisMacKeepsItsSharpnessAndSpendsLessWhenSlow() {
        var watch = BackendPhoneDevices.Watch(wantedWidth: 2560, wantedQuality: 70, fps: 30, width: 2560, quality: 70, started: 0, name: "", deviceName: "")
        watch.mac = true; watch.wantedFPS = 30
        #expect(BackendPhoneDevices.macBudget(watch) == 2_500_000 / 8 / 4)
        for _ in 0..<5 { watch.smoothed = 600; watch.sinceTune = 5; BackendPhoneDevices.tune(&watch) }
        #expect(watch.width == 2560, "the resolution stays for text")
        #expect(watch.bitrate == BackendPhoneDevices.macBitrate.floor && watch.fps == 15)
        for _ in 0..<40 { watch.smoothed = 40; watch.sinceTune = 12; BackendPhoneDevices.tune(&watch) }
        #expect(watch.bitrate == BackendPhoneDevices.macBitrate.ceiling && watch.fps == 30)
    }

    @Test func shapesAreChecked() {
        func refused(_ text: String) -> Bool { if case .refused = BackendRemoteProtocol.parseClientMessage(text) { return true }; return false }
        #expect(refused(#"{"t":"sims.watch","id":"ios:x y","maxWidth":300,"quality":50}"#), "an id with a space")
        #expect(refused(#"{"t":"sims.input","id":"ios:abc","do":"explode"}"#))
        #expect(refused(#"{"t":"sims.input","id":"ios:abc","do":"button","button":"selfdestruct"}"#))
        #expect(refused(#"{"t":"sims.annotate","rid":"a","id":"ios:abc","shot":"zz","to":"hoot","marks":[]}"#))
        #expect(!refused(#"{"t":"sims.input","id":"android:emulator-5554","do":"swipe","x":0,"y":1,"x2":3,"y2":-1,"ms":200}"#))
        #expect(!refused(#"{"t":"sims.input","id":"mac:69733382","do":"key","key":"tab","mods":["command","shift"]}"#))
        #expect(refused(#"{"t":"sims.input","id":"mac:1","do":"key","key":"c","mods":["hyper"]}"#), "an unknown modifier")
        #expect(refused(#"{"t":"sims.input","id":"mac:1","do":"key","key":"C;rm"}"#))
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.watch","id":"avd:My.Pixel_8","maxWidth":9000,"quality":5}"#) {
            #expect(message["maxWidth"].number == 2560 && message["quality"].number == 10)
        } else { Issue.record("a watch with out-of-range numbers is clamped, not refused") }
    }

    @Test func slowAcksMakeSmallerPictures() {
        var watch = BackendPhoneDevices.Watch(wantedWidth: 800, wantedQuality: 70, fps: 15, width: 800, quality: 70, started: 0, name: "", deviceName: "")
        watch.smoothed = 600; watch.sinceTune = 5
        BackendPhoneDevices.tune(&watch)
        #expect(watch.width < 800 && watch.quality < 70)
        watch.smoothed = 50; watch.sinceTune = 12
        let lowered = watch.width
        BackendPhoneDevices.tune(&watch)
        #expect(watch.width > lowered && watch.width <= 800)
    }

    @Test func encodeKeepsUnderTheBudget() throws {
        let frame = try #require(BackendPhoneDevices.encode(Self.picture(shade: 1, width: 1290, height: 2796), maxWidth: 720, quality: 90, maxBytes: 20_000))
        #expect(frame.width <= 720 && frame.jpeg.count <= 20_000)
    }

    private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<400 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "fixture-timeout", message: "The host did not answer.")
    }
}
