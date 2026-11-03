import CoreGraphics
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Asad, 1 Nov (round 3, the most important item): "moving the finger moves the Mac cursor with a delay; it is hard to
/// point". Finger → Mac pointer, measured through the real host the way the relay feeds it (one frame at a time: a frame
/// that is not a read is answered before the next is opened), on a simulated Cloudflare relay (132 ms each way, 20 Mbit/s)
/// while the Mac's screen keeps changing (pictures being made and sent at the same time, as when the pointer is in the
/// picture or the page under it reacts). The phone moves the pointer for 3 s, one message per display frame.
@Suite("This Mac's pointer: finger to cursor over the relay", .serialized)
struct PhonePointerLatencyTests {
    typealias Screen = PhoneScreenFixtures.ScriptedScreen
    static func now() -> Double { PhoneScreenFixtures.now() }

    /// Phone → Mac: frames arrive `oneWay` ms after they were sent, in order, and are fed to the host exactly as the relay
    /// client feeds them (`take`, then wait for the answer unless it runs alongside).
    actor Uplink {
        let oneWay: Double
        var queue: [(at: Double, text: String)] = []
        var host: BackendRemoteHost?
        var id: UUID?
        var running = false
        init(oneWay: Double) { self.oneWay = oneWay }
        func attach(_ host: BackendRemoteHost, _ id: UUID) { self.host = host; self.id = id }
        func send(_ text: String) {
            queue.append((PhonePointerLatencyTests.now() + oneWay, text))
            if !running { running = true; Task { await self.drain() } }
        }
        private func drain() async {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let wait = next.at - PhonePointerLatencyTests.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                guard let host, let id else { continue }
                if let taken = await host.take(id, text: next.text), !taken.alongside { await taken.answered.value }
            }
            running = false
        }
    }

    /// Mac → phone: pictures cross a link of `capacity`; the phone acks each one through the uplink once it has it.
    actor Downlink {
        let capacity: Double, oneWay: Double
        var free: Double = 0
        var uplink: Uplink?
        var frames = 0
        var pictures: [(sentAt: Double, arrival: Double)] = []
        var pointers: [(at: Double, n: Int)] = []
        init(capacity: Double, oneWay: Double) { self.capacity = capacity; self.oneWay = oneWay }
        func attach(_ uplink: Uplink) { self.uplink = uplink }
        func carry(_ message: BackendRemoteServerMessage) {
            let value = message.value
            let chars = value["data"].string?.utf8.count ?? 0
            let now = PhonePointerLatencyTests.now()
            let done = max(now, free) + Double(chars + 120) * 8_000 / capacity
            free = done
            if message.kind == .simsPointer { pointers.append((done + oneWay, Int(value["n"].number ?? 0))) }
        }
        /// The screen's video on the (fake) direct link (3 Nov: the only way the screen goes).
        func carryVideo(_ value: NativeRPCValue) {
            let chars = value["data"].string?.utf8.count ?? 0
            let now = PhonePointerLatencyTests.now()
            let done = max(now, free) + Double(chars + 120) * 8_000 / capacity
            free = done
            guard value["t"].string == "sims.video" else { return }
            let parts = Int(value["parts"].number ?? 1), part = Int(value["part"].number ?? 0)
            guard part == parts - 1, let uplink else { return }
            frames += 1
            pictures.append((now, done + oneWay + 8))
            let id = value["id"].string ?? "", seq = Int(value["seq"].number ?? -1)
            let at = done + oneWay + 8
            Task {
                let wait = at - PhonePointerLatencyTests.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                await uplink.send(#"{"t":"sims.ack","id":"\#(id)","seq":\#(seq)}"#)
            }
        }
    }

    /// When each pointer move reached the Mac's input (in the order applied).
    /// Moves added together on the Mac count once for each phone message they carried (each moves dx 0.002).
    final class Applied: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func note(count: Int = 1) { lock.withLock { for _ in 0..<max(0, count) { times.append(PhonePointerLatencyTests.now()) } } }
        var all: [Double] { lock.withLock { times } }
    }

    static func median(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.sorted()[values.count / 2] }
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func connect(_ down: Downlink, _ up: Uplink, screen: Screen, applied: Applied,
                         configure: (inout BackendPhoneDevices.Source) -> Void = { _ in }) async throws -> (BackendRemoteHost, BackendPhoneDevices.Installation, UUID, BackendRemoteTrustStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MACP-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let row = NativeRPCValue.object([.init("id", .string("mac:1")), .init("name", .string("Studio Mac")), .init("platform", .string("mac")),
            .init("kind", .string("display")), .init("state", .string("ready")), .init("canWatch", .bool(true)), .init("canControl", .bool(true))])
        var source = Self.source(down: down, screen: screen, applied: applied, row: row)
        configure(&source)
        let installation = try await BackendPhoneDevices.install(on: host, source: source)
        try await host.start()
        let timer = clock.scheduled.value() + 1
        let welcomed = PhoneScreenFixtures.Welcomed()
        let welcome = welcomeText
        let id = try #require(await host.accept(.init(address: "fixture", send: { text in
            if text.contains("\"welcome\"") { welcome.set(text); await welcomed.set() }
        }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        for _ in 0..<400 where !(await welcomed.done) { try await Task.sleep(for: .milliseconds(10)) }
        await up.attach(host, id)
        await down.attach(up)
        return (host, installation, id, trust, dir)
    }

    /// The welcome this host sent (to see what it offers).
    let welcomeText = Text()
    final class Text: @unchecked Sendable {
        private let lock = NSLock(); private var value = ""
        func set(_ text: String) { lock.withLock { value = text } }
        var text: String { lock.withLock { value } }
    }

    static func source(down: Downlink, screen: Screen, applied: Applied, row: NativeRPCValue) -> BackendPhoneDevices.Source {
        var source = BackendPhoneDevices.Source(
            list: { .object([.init("devices", .array([]))]) },
            power: { _, _ in .object([]) },
            stream: { _, _ in screen },
            input: { _, input in if case .pointer = input { applied.note() } },
            shot: { _ in throw NativeRPCError(code: "unavailable", message: "no") },
            deliver: { _ in "" },
            visibleSessions: { _ in [] },
            send: { _, message in await down.carry(message) },
            macRows: { [row] })
        PhoneScreenFixtures.link(&source) { value in await down.carryVideo(value) }
        // The direct path (round 3): pointer moves are applied the moment they arrive, coalesced.
        source.macPost = { _, input in
            if case let .pointer(dx, _, _) = input { applied.note(count: Int((dx / 0.002).rounded())) }
            return nil
        }
        source.pointer = { _ in BackendPhoneDevicePointer(x: 0.5, y: 0.5, onDisplay: true, shape: nil) }
        return source
    }

    /// Moves the pointer for `seconds` while the screen changes every 16 ms; answers each move's finger-to-Mac time.
    func run(label: String, round3: Bool) async throws -> [String: Double] {
        let down = Downlink(capacity: 20_000_000, oneWay: 132)
        let up = Uplink(oneWay: 132)
        let screen = Screen()
        let applied = Applied()
        let (host, installation, id, trust, dir) = try await connect(down, up, screen: screen, applied: applied)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        let watch = round3 ? #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"cursor":true,"video":["h264"]}"#
                           : #"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"video":["h264"]}"#
        await up.send(watch)
        try await Task.sleep(for: .milliseconds(2_500))
        var sent: [Double] = []
        let start = Self.now()
        var n = 0, offset = 0
        while Self.now() - start < 3_000 {
            n += 1
            sent.append(Self.now())
            // Yesterday's phone: every move with a request id, answered or refused; today's: numbered, no id.
            await up.send(round3 ? #"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.002,"dy":0.001,"n":\#(n)}"#
                                 : #"{"t":"sims.input","rid":"sim-in-\#(n)","id":"mac:1","do":"pointer","dx":0.002,"dy":0.001}"#)
            // The page under the pointer reacts (hover, a scrolling list): a new picture every frame.
            if n % 2 == 0 { offset += 12; await screen.set(PhoneScreenFixtures.screen(offset: offset)) }
            let wait = start + Double(n) * 16.7 - Self.now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
        }
        let fingerUp = Self.now()
        try await Task.sleep(for: .milliseconds(4_000))
        let times = applied.all
        // Coalesced moves count once for each finger message they carried (the Mac applies the newest sum).
        var latencies: [Double] = []
        for (index, at) in times.enumerated() where index < sent.count { latencies.append(at - sent[index]) }
        var out: [String: Double] = [:]
        out["moves.sent"] = Double(sent.count)
        out["moves.applied"] = Double(times.count)
        out["fingerToMac.medianMs"] = Self.median(latencies)
        out["fingerToMac.p90Ms"] = Self.percentile(latencies, 0.9)
        out["fingerToMac.maxMs"] = latencies.max() ?? .nan
        out["fingerToMac.oneWayRelayMs"] = 132
        out["stopsAfterLiftMs"] = (times.last.map { $0 - fingerUp }) ?? .nan
        out["pictures"] = Double(await down.frames)
        let pointers = await down.pointers
        out["pointerReports"] = Double(pointers.count)
        // Yesterday's phone saw the pointer move only in the next picture made after the Mac moved it (capture ≥ 17 ms).
        let pictures = await down.pictures
        var seen: [Double] = []
        for (index, at) in times.enumerated() where index < sent.count {
            if let picture = pictures.first(where: { $0.sentAt >= at + 17 }) { seen.append(picture.arrival - sent[index]) }
        }
        out["fingerToPointerInPicture.medianMs"] = Self.median(seen)
        out["fingerToPointerInPicture.p90Ms"] = Self.percentile(seen, 0.9)
        // Round 3: the phone draws the pointer the moment the finger moves; the Mac's word on it comes back here.
        var confirmed: [Double] = []
        for (index, at) in sent.enumerated() { if let report = pointers.first(where: { $0.n >= index + 1 }) { confirmed.append(report.at - at) } }
        out["macConfirms.medianMs"] = Self.median(confirmed)
        await up.send(#"{"t":"sims.unwatch","id":"mac:1"}"#)
        for key in out.keys.sorted() { print("MEASURE \(label) \(key)=\(String(format: "%.1f", out[key]!))") }
        return out
    }

    @Test func pointerLatencyOverTheRelay() async throws {
        let before = try await run(label: "pointer-yesterday-phone", round3: false)
        let after = try await run(label: "pointer-round3-phone", round3: true)
        // The relay alone is 132 ms one way; the Mac adds at most a few ms on the new path.
        #expect(after["fingerToMac.medianMs"]! < 160, "\(after)")
        #expect(after["fingerToMac.p90Ms"]! < 200, "\(after)")
        #expect(after["stopsAfterLiftMs"]! < 250, "the pointer stops when the finger lifts (plus the relay)")
        #expect(after["pointerReports"]! > 0, "the phone hears where the pointer is, to draw it itself")
        _ = before
    }

    /// Item 27 (drag), on the real path: a drag from the phone arrives on the Mac as press, held moves, let go — in that
    /// order, however the moves are added together — and a click after moves lands where the moves put the pointer.
    @Test func aDragArrivesInOrderThroughTheHost() async throws {
        let down = Downlink(capacity: 20_000_000, oneWay: 5)
        let up = Uplink(oneWay: 5)
        let screen = Screen()
        let applied = Applied()
        // Record what the Mac posts, in order.
        let log = Log()
        let (host, installation, id, trust, dir) = try await connect(down, up, screen: screen, applied: applied) { source in
            source.macPost = { _, input in log.add(input); return nil }
        }
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        await up.send(#"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"cursor":true,"video":["h264"]}"#)
        try await Task.sleep(for: .milliseconds(300))
        await up.send(#"{"t":"sims.input","id":"mac:1","do":"click","button":"left","phase":"down"}"#)
        for n in 1...20 { await up.send(#"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.01,"dy":0,"held":true,"n":\#(n)}"#) }
        await up.send(#"{"t":"sims.input","id":"mac:1","do":"click","button":"left","phase":"up"}"#)
        try await Task.sleep(for: .milliseconds(400))
        let posted = log.all
        #expect(posted.first == .click(button: "left", phase: "down"), "\(posted)")
        #expect(posted.last == .click(button: "left", phase: "up"), "\(posted)")
        let moves = posted.compactMap { input -> (Double, Bool)? in if case let .pointer(dx, _, held) = input { return (dx, held) }; return nil }
        #expect(abs(moves.reduce(0) { $0 + $1.0 } - 0.2) < 0.0001, "every move applied, added together or not")
        #expect(moves.allSatisfy { $0.1 }, "every move of a drag holds the button")
        await up.send(#"{"t":"sims.unwatch","id":"mac:1"}"#)
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var items: [BackendPhoneDeviceInput] = []
        func add(_ input: BackendPhoneDeviceInput) { lock.withLock { items.append(input) } }
        var all: [BackendPhoneDeviceInput] { lock.withLock { items } }
    }

    /// Item 24: with the Settings switch off, a phone may not watch or drive this Mac, and is told why.
    @Test func theSettingsSwitchRefusesPhones() async throws {
        let down = Downlink(capacity: 20_000_000, oneWay: 5)
        let up = Uplink(oneWay: 5)
        let screen = Screen()
        let applied = Applied()
        let (host, installation, _, trust, dir) = try await connect(down, up, screen: screen, applied: applied) { source in
            source.macAllowed = { false }
            source.macRefusal = "Off at the Mac."
        }
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        await up.send(#"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"cursor":true,"video":["h264"]}"#)
        await up.send(#"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.002,"dy":0,"n":1}"#)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await down.frames == 0, "no picture while the switch is off")
        #expect(applied.all.isEmpty, "no input while the switch is off")
    }

    @Test func recordAndPointerNumbersParse() throws {
        guard case .message(let record) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.record","rid":"r1","id":"ios:ABC","do":"stop","note":"look","to":"hoot"}"#) else {
            Issue.record("record refused"); return
        }
        #expect(record["do"].string == "stop" && record["note"].string == "look" && record["to"].string == "hoot")
        if case .message = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.record","rid":"r1","id":"ios:ABC","do":"pause"}"#) { Issue.record("an unknown step is refused") }
        guard case .message(let move) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.1,"dy":0,"n":42}"#) else {
            Issue.record("numbered move refused"); return
        }
        #expect(move["n"].number == 42 && move["rid"] == .missing)
        let pointer = try BackendRemoteServerMessage(.simsPointer, fields: [.init("id", .string("mac:1")), .init("x", .number(0.5)), .init("y", .number(0.25)), .init("n", .number(42))])
        #expect(pointer.kind == .simsPointer)
    }

    /// Reviewer M1 (item 27): a burst that arrives while the Mac is still posting — move, press, move, let go — is
    /// posted in exactly that order (the moves before the press are taken when the press is queued).
    @Test func aBurstKeepsMovesAndClicksInOrder() throws {
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        let first = Flag()
        let lane = BackendMacInputLane(label: "test") { input in
            if !first.swap() { gate.wait() }
            log.add(input)
            return nil
        }
        lane.send(.key("x"), refused: { _ in })   // keeps the queue busy until the gate opens
        Thread.sleep(forTimeInterval: 0.05)
        lane.pointer(dx: 0.1, dy: 0, held: false, n: 1, refused: { _ in })
        lane.send(.click(button: "left", phase: "down"), refused: { _ in })
        lane.pointer(dx: 0.2, dy: 0, held: true, n: 2, refused: { _ in })
        lane.pointer(dx: 0.05, dy: 0, held: true, n: 3, refused: { _ in })
        lane.send(.click(button: "left", phase: "up"), refused: { _ in })
        lane.pointer(dx: 0.3, dy: 0, held: false, n: 4, refused: { _ in })
        gate.signal()
        for _ in 0..<100 where log.all.count < 6 { Thread.sleep(forTimeInterval: 0.01) }
        let posted = log.all
        #expect(posted.count == 6, "\(posted)")
        guard posted.count == 6 else { return }
        #expect(posted[0] == .key("x"))
        #expect(posted[1] == .pointer(dx: 0.1, dy: 0, held: false))
        #expect(posted[2] == .click(button: "left", phase: "down"))
        if case let .pointer(dx, _, held) = posted[3] { #expect(abs(dx - 0.25) < 1e-9 && held) } else { Issue.record("\(posted[3])") }
        #expect(posted[4] == .click(button: "left", phase: "up"))
        #expect(posted[5] == .pointer(dx: 0.3, dy: 0, held: false))
        #expect(lane.applied == 4)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var set = false
        /// True if it was already set.
        func swap() -> Bool { lock.withLock { defer { set = true }; return set } }
    }

    /// Reviewer M6: a Mac offers `sims.record` only when it can record, so a phone never sends it to a Mac that would
    /// close the connection on it.
    @Test func recordIsOfferedOnlyWhenTheMacCanRecord() async throws {
        let without = PhonePointerLatencyTests()
        let (host1, installation1, _, trust1, dir1) = try await without.connect(Downlink(capacity: 1_000_000, oneWay: 1), Uplink(oneWay: 1),
                                                                                screen: Screen(), applied: Applied())
        #expect(without.welcomeText.text.contains("\"sims\""))
        #expect(!without.welcomeText.text.contains("sims.record"), "\(without.welcomeText.text)")
        await installation1.stop(); await host1.stop(); await trust1.close(); try? FileManager.default.removeItem(at: dir1)
        let with = PhonePointerLatencyTests()
        let (host2, installation2, _, trust2, dir2) = try await with.connect(Downlink(capacity: 1_000_000, oneWay: 1), Uplink(oneWay: 1),
                                                                             screen: Screen(), applied: Applied()) { source in
            source.record = { _ in "" }
        }
        #expect(with.welcomeText.text.contains("sims.record"), "\(with.welcomeText.text)")
        await installation2.stop(); await host2.stop(); await trust2.close(); try? FileManager.default.removeItem(at: dir2)
    }
}
