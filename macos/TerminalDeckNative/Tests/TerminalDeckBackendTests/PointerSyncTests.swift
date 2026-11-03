import CoreGraphics
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Item 60 (Asad, 1 Nov, on his iPhone against install #21): "the pointer feels very fast now, but sometimes the cursor
/// is not where I see it; after a blink it shows somewhere else instead of where I left it; while moving too."
///
/// A known finger path goes through the real host and the real input lane, over a simulated relay (132 ms each way,
/// with the bunching a real relay has: a few messages delivered at once), into a scratch Mac whose pointer behaves like
/// the system's: a posted move shows up a few ms later, and reading the pointer before that gives the old place. Every
/// display frame the test records (a) where the phone draws the pointer, (b) where the Mac's pointer really is, (c) the
/// last place the Mac reported — in the Mac's points (a 1512 × 982 display).
@Suite("This Mac's pointer: the phone and the Mac agree", .serialized)
struct PointerSyncTests {
    static let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }

    /// The Mac's pointer as the system has it: a posted place shows up `lag` ms later.
    final class FakePointer: @unchecked Sendable {
        private let lock = NSLock()
        private var posts: [(at: Double, point: CGPoint)] = [(0, CGPoint(x: 756, y: 491))]
        let lag: Double
        init(lag: Double) { self.lag = lag }
        func post(_ point: CGPoint) { lock.withLock { posts.append((PointerSyncTests.now(), point)) } }
        func location(at time: Double = PointerSyncTests.now()) -> CGPoint {
            lock.withLock { posts.last { $0.at + lag <= time }?.point ?? posts[0].point }
        }
    }

    /// The Mac side under test: yesterday's (moves added to the pointer read back) or today's (MacPointerModel).
    final class Mac: @unchecked Sendable {
        let pointer: FakePointer
        let model = MacPointerModel()
        let round4: Bool
        init(lag: Double, round4: Bool) { pointer = FakePointer(lag: lag); self.round4 = round4 }
        func post(_ input: BackendPhoneDeviceInput) {
            let b = PointerSyncTests.bounds, t = PointerSyncTests.now() / 1_000
            switch input {
            case let .pointer(dx, dy, _):
                if round4 { pointer.post(model.move(dx: dx, dy: dy, real: pointer.location(), bounds: b, now: t)) }
                else { let at = pointer.location(); pointer.post(MacPointerModel.clamp(CGPoint(x: at.x + dx * b.width, y: at.y + dy * b.height), to: b)) }
            case let .pointerTo(x, y, _):
                pointer.post(model.moveTo(x: x, y: y, bounds: b, now: t))
            default: break
            }
        }
        func report() -> BackendPhoneDevicePointer {
            let b = PointerSyncTests.bounds
            let at = round4 ? (model.placedIfFresh(bounds: b, now: PointerSyncTests.now() / 1_000) ?? pointer.location()) : pointer.location()
            return .init(x: at.x / b.width, y: at.y / b.height, onDisplay: true, shape: nil, displayWidth: b.width)
        }
    }

    /// The phone's drawn pointer: yesterday's (moves added on top of every report: report + moves not yet applied) or
    /// today's (the phone's own place is the truth while the finger is down and until the Mac has applied the last move;
    /// then a report moves it only when it differs by more than 6 points).
    final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        let round4: Bool
        var drawn: CGPoint?            // 0…1
        var unapplied: [(n: Int, dx: Double, dy: Double)] = []
        var lastSent = 0
        var fingerDown = false
        var lastReport: CGPoint?
        init(round4: Bool) { self.round4 = round4 }
        func heard(_ x: Double, _ y: Double, n: Int, width: Double) {
            lock.withLock {
                lastReport = CGPoint(x: x, y: y)
                guard let at = drawn else { drawn = CGPoint(x: x, y: y); return }
                if round4 {
                    guard !fingerDown, n >= lastSent else { return }
                    let points = hypot((x - at.x) * width, (y - at.y) * width * PointerSyncTests.bounds.height / PointerSyncTests.bounds.width)
                    if points > 6 { drawn = CGPoint(x: x, y: y) }
                } else {
                    unapplied.removeAll { $0.n <= n }
                    var p = CGPoint(x: x, y: y)
                    for move in unapplied { p = CGPoint(x: min(max(p.x + move.dx, 0), 0.9999), y: min(max(p.y + move.dy, 0), 0.9999)) }
                    drawn = p
                }
            }
        }
        /// One frame of finger movement (a share of the display); answers the message to send.
        func frame(dx: Double, dy: Double) -> String? {
            lock.withLock {
                guard let at = drawn else { return nil }
                let to = CGPoint(x: min(max(at.x + dx, 0), 0.9999), y: min(max(at.y + dy, 0), 0.9999))
                drawn = to
                lastSent += 1
                if round4 {
                    return #"{"t":"sims.input","id":"mac:1","do":"pointer","dx":\#(dx),"dy":\#(dy),"x":\#(to.x),"y":\#(to.y),"n":\#(lastSent)}"#
                }
                unapplied.append((lastSent, dx, dy))
                return #"{"t":"sims.input","id":"mac:1","do":"pointer","dx":\#(dx),"dy":\#(dy),"n":\#(lastSent)}"#
            }
        }
        var state: (drawn: CGPoint?, report: CGPoint?) { lock.withLock { (drawn, lastReport) } }
        func finger(_ down: Bool) { lock.withLock { fingerDown = down } }
    }

    /// Phone → Mac with the relay's bunching: messages leave every frame but arrive in bursts of up to 4.
    actor Uplink {
        var host: BackendRemoteHost?, id: UUID?
        var queue: [(at: Double, text: String)] = []
        var running = false
        var burst = 0
        func attach(_ host: BackendRemoteHost, _ id: UUID) { self.host = host; self.id = id }
        func send(_ text: String) {
            // Every few messages the relay holds them back and lets them go together.
            burst = (burst + 1) % 4
            let hold = burst == 0 ? 0.0 : Double(4 - burst) * 16
            queue.append((PointerSyncTests.now() + 132 + hold, text))
            queue.sort { $0.at < $1.at }
            if !running { running = true; Task { await self.drain() } }
        }
        private func drain() async {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let wait = next.at - PointerSyncTests.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
                guard let host, let id else { continue }
                if let taken = await host.take(id, text: next.text), !taken.alongside { await taken.answered.value }
            }
            running = false
        }
    }

    struct Samples {
        var drawnVsMac: [Double] = []      // points, every frame
        var jumps: [Double] = []           // points the drawn pointer moved in a frame beyond the finger's own move
        var restDrawnVsMac: Double = 0     // points, after the finger rested 1.5 s
        var restReportVsMac: Double = 0
        var lostTravel: Double = 0         // points between where the finger's path ends and where the Mac's pointer is
    }

    func run(round4: Bool, lag: Double, label: String) async throws -> Samples {
        let mac = Mac(lag: lag, round4: round4)
        let phone = Phone(round4: round4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PSY-" + UUID().uuidString)
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
        let screen = PhoneScreenFixtures.ScriptedScreen()
        var source = BackendPhoneDevices.Source(
            list: { .object([.init("devices", .array([]))]) }, power: { _, _ in .object([]) }, stream: { _, _ in screen }, input: { _, _ in },
            shot: { _ in throw NativeRPCError(code: "unavailable", message: "no") }, deliver: { _ in "" }, visibleSessions: { _ in [] },
            send: { _, message in
                // Mac → phone: the pointer report crosses the relay (132 ms) and is heard by the phone.
                guard message.kind == .simsPointer else { return }
                let v = message.value
                let x = v["x"].number ?? 0, y = v["y"].number ?? 0, n = Int(v["n"].number ?? 0), w = v["pw"].number ?? PointerSyncTests.bounds.width
                Task { try? await Task.sleep(nanoseconds: 132_000_000); phone.heard(x, y, n: n, width: w) }
            },
            macRows: { [row] })
        PhoneScreenFixtures.link(&source) { _ in }
        source.macPost = { _, input in mac.post(input); return nil }
        source.pointer = { _ in mac.report() }
        let installation = try await BackendPhoneDevices.install(on: host, source: source)
        try await host.start()
        let timer = clock.scheduled.value() + 1
        let welcomed = PhoneScreenFixtures.Welcomed()
        let id = try #require(await host.accept(.init(address: "fixture", send: { text in if text.contains("\"welcome\"") { await welcomed.set() } }, close: { _, _ in })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        for _ in 0..<400 where !(await welcomed.done) { try await Task.sleep(for: .milliseconds(10)) }
        let up = Uplink()
        await up.attach(host, id)
        defer { Task { await installation.stop(); await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: dir) } }
        await screen.set(PhoneScreenFixtures.screen(offset: 0))
        await up.send(#"{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":30,"cursor":true,"video":["h264"]}"#)
        // The first report gives the phone the pointer.
        for _ in 0..<200 where phone.state.drawn == nil { try await Task.sleep(for: .milliseconds(10)) }

        // The finger: a quick stroke right, a slow arc, a quick flick down-left, then rest (60 frames a second).
        var path: [(dx: Double, dy: Double)] = []
        for _ in 0..<30 { path.append((0.006, 0.001)) }
        for i in 0..<60 { let a = Double(i) / 60 * .pi; path.append((0.002 * cos(a), 0.003 * sin(a))) }
        for _ in 0..<20 { path.append((-0.008, 0.006)) }
        var samples = Samples()
        let b = Self.bounds
        func points(_ a: CGPoint, _ c: CGPoint) -> Double { hypot((a.x - c.x) * b.width, (a.y - c.y) * b.height) }
        phone.finger(true)
        var previous = phone.state.drawn!
        var intended = previous
        let start = Self.now()
        for (index, step) in path.enumerated() {
            if let message = phone.frame(dx: step.dx, dy: step.dy) { await up.send(message) }
            intended = CGPoint(x: min(max(intended.x + step.dx, 0), 0.9999), y: min(max(intended.y + step.dy, 0), 0.9999))
            let wait = start + Double(index + 1) * 16.7 - Self.now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            let state = phone.state, macAt = mac.pointer.location()
            let unit = CGPoint(x: macAt.x / b.width, y: macAt.y / b.height)
            if let drawn = state.drawn {
                samples.drawnVsMac.append(points(drawn, unit))
                let fingerMove = hypot(step.dx * b.width, step.dy * b.height)
                samples.jumps.append(max(0, points(drawn, previous) - fingerMove))
                previous = drawn
            }
        }
        phone.finger(false)
        // Rest: the finger lifted; the last moves arrive and the reports settle. The drawn pointer keeps being watched.
        for _ in 0..<90 {
            try await Task.sleep(nanoseconds: 16_700_000)
            if let drawn = phone.state.drawn { samples.jumps.append(points(drawn, previous)); previous = drawn }
        }
        let state = phone.state, macAt = mac.pointer.location()
        let unit = CGPoint(x: macAt.x / b.width, y: macAt.y / b.height)
        samples.restDrawnVsMac = state.drawn.map { points($0, unit) } ?? .nan
        samples.restReportVsMac = state.report.map { points($0, unit) } ?? .nan
        samples.lostTravel = points(intended, unit)
        await up.send(#"{"t":"sims.unwatch","id":"mac:1"}"#)
        let sorted = samples.drawnVsMac.sorted(), jumps = samples.jumps.sorted()
        func p(_ v: [Double], _ q: Double) -> Double { v.isEmpty ? .nan : v[min(v.count - 1, Int(Double(v.count) * q))] }
        print("MEASURE \(label) moving.drawnVsMac.median=\(String(format: "%.1f", p(sorted, 0.5))) p90=\(String(format: "%.1f", p(sorted, 0.9))) max=\(String(format: "%.1f", sorted.last ?? .nan)) pt")
        print("MEASURE \(label) jumps.max=\(String(format: "%.1f", jumps.last ?? .nan)) pt count>6pt=\(jumps.filter { $0 > 6 }.count)")
        print("MEASURE \(label) rest.drawnVsMac=\(String(format: "%.1f", samples.restDrawnVsMac)) pt rest.reportVsMac=\(String(format: "%.1f", samples.restReportVsMac)) pt lostTravel=\(String(format: "%.1f", samples.lostTravel)) pt")
        return samples
    }

    @Test func thePhoneAndTheMacAgree() async throws {
        let before = try await run(round4: false, lag: 6, label: "install21")
        let after = try await run(round4: true, lag: 6, label: "pointer-sync")
        _ = before
        // At rest: exactly the same place (the Mac goes where the phone draws).
        #expect(after.restDrawnVsMac < 1, "\(after.restDrawnVsMac)")
        #expect(after.lostTravel < 1, "no finger movement is lost: \(after.lostTravel)")
        // The drawn pointer never jumps on its own (no snap back from a stale report).
        #expect((after.jumps.max() ?? 0) < 6, "\(after.jumps.max() ?? 0)")
    }

    /// An older phone (moves by a share, no place) on the new Mac: the Mac builds on where it put the pointer, so a burst
    /// of moves read back too soon loses nothing.
    @Test func anOlderPhonesMovesAreNotLost() {
        let model = MacPointerModel()
        let b = Self.bounds
        let stale = CGPoint(x: 100, y: 100)   // the system still says the old place
        var at = CGPoint.zero
        for i in 0..<10 { at = model.move(dx: 0.01, dy: 0, real: stale, bounds: b, now: 1_000 + Double(i) * 0.001) }
        #expect(abs(at.x - (100 + 10 * 0.01 * b.width)) < 0.001, "\(at)")
        // A second later the system's place counts again (the person at the Mac may have moved it).
        let later = model.current(real: CGPoint(x: 900, y: 500), bounds: b, now: 1_002)
        #expect(later == CGPoint(x: 900, y: 500))
        #expect(model.moveTo(x: 0.5, y: 0.5, bounds: b, now: 1_003) == CGPoint(x: 756, y: 491))
    }

    @Test func theWireCarriesThePlace() throws {
        guard case .message(let move) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.01,"dy":0,"x":0.25,"y":0.75,"n":3,"held":true}"#) else {
            Issue.record("refused"); return
        }
        #expect(try BackendPhoneDevices.input(move, mac: true) == .pointerTo(x: 0.25, y: 0.75, held: true))
        guard case .message(let old) = BackendRemoteProtocol.parseClientMessage(#"{"t":"sims.input","id":"mac:1","do":"pointer","dx":0.01,"dy":0}"#) else {
            Issue.record("refused"); return
        }
        #expect(try BackendPhoneDevices.input(old, mac: true) == .pointer(dx: 0.01, dy: 0, held: false))
    }
}
