import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The test's own clock for mcp-events / notify-detect: ties fire in the order
/// they were set (as the source ManualClock does), and every schedule is
/// counted, overall and per delay, so a test can wait for one exact timer.
final class BackendDeckCoreTestPortS1EventsClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private struct Pending { let due: Double; let order: Int; let run: @Sendable () -> Void }
    private let lock = NSLock()
    private var instant: Double
    private var order = 0
    private var timers: [UUID: Pending] = [:]
    private var delays: [Double: BackendDeckCoreTestPortSecuritySignal] = [:]
    let scheduled = BackendDeckCoreTestPortSecuritySignal()
    init(_ now: Double) { instant = now }
    func now() -> Double { lock.withLock { instant } }
    /// Counts the timers set with exactly this delay.
    func signal(after milliseconds: Double) -> BackendDeckCoreTestPortSecuritySignal {
        lock.withLock { () -> BackendDeckCoreTestPortSecuritySignal in
            if let signal = delays[milliseconds] { return signal }
            let signal = BackendDeckCoreTestPortSecuritySignal(); delays[milliseconds] = signal; return signal
        }
    }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { order += 1; timers[id] = Pending(due: instant + max(milliseconds, 0), order: order, run: run) }
        scheduled.signal(); signal(after: milliseconds).signal()
        return id
    }
    func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
    func pending() -> Int { lock.withLock { timers.count } }
    func advance(_ milliseconds: Double) {
        let target = now() + milliseconds
        // Consumes the finite set of due timers; never waits or polls.
        while let run: (@Sendable () -> Void) = lock.withLock({ () -> (@Sendable () -> Void)? in
            guard let next = timers.filter({ $0.value.due <= target }).min(by: { ($0.value.due, $0.value.order) < ($1.value.due, $1.value.order) }) else { instant = target; return nil }
            instant = next.value.due; timers[next.key] = nil; return next.value.run
        }) { run() }
    }
}

/// Plays ChatGPT's receiver: echoes a verification, answers deliveries as told.
/// A delivery can be held open until the test releases it.
final class BackendDeckCoreTestPortS1EventsReceiver: @unchecked Sendable {
    enum Verification: Sendable { case echo, wrong, status(Int), unreachable }
    struct Post: Sendable { let url: String; let headers: [String: String]; let body: String; let at: Double; let isVerification: Bool }
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var recorded: [Post] = []
    private var queued: [Int] = [200]
    private var check: Verification = .echo
    private var held: Int?
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// Every post, verifications included.
    let posted = BackendDeckCoreTestPortSecuritySignal()
    /// Deliveries only (not verifications), signalled once recorded.
    let delivered = BackendDeckCoreTestPortSecuritySignal()
    init(now: @escaping @Sendable () -> Double) { self.now = now }
    /// Status for the next deliveries, in order; the last one repeats.
    var statuses: [Int] {
        get { lock.withLock { queued } }
        set { lock.withLock { queued = newValue } }
    }
    var verification: Verification {
        get { lock.withLock { check } }
        set { lock.withLock { check = newValue } }
    }
    func posts() -> [Post] { lock.withLock { recorded } }
    func deliveries() -> [Post] { posts().filter { !$0.isVerification } }
    func verifications() -> [Post] { posts().filter { $0.isVerification } }
    /// The delivery with this 1-based number is recorded, then waits for release().
    func hold(delivery number: Int) { lock.withLock { held = number; opened = false } }
    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in opened = true; let waiting = waiter; waiter = nil; return waiting }
        waiting?.resume()
    }
    func post(_ url: String, _ headers: [String: String], _ body: String) async throws -> BackendDeckCoreEventsCallbackAnswer {
        let parsed = try? NativeRPCValue.parseJSON(Data(body.utf8))
        let isVerification = parsed?["type"].string == "verification"
        let at = now()
        let decided = lock.withLock { () -> (status: Int, verification: Verification, hold: Bool) in
            recorded.append(Post(url: url, headers: headers, body: body, at: at, isVerification: isVerification))
            if isVerification { return (0, check, false) }
            let status = queued.count > 1 ? queued.removeFirst() : (queued.first ?? 200)
            let number = recorded.filter { !$0.isVerification }.count
            return (status, check, held == number)
        }
        posted.signal()
        if isVerification {
            switch decided.verification {
            case .unreachable: throw BackendDeckCoreEventsCallbackRefused(reason: "connection_refused", message: "connect ECONNREFUSED")
            case .status(let code): return .init(status: code, body: "")
            case .echo: return .init(status: 200, body: BackendDeckCoreTestPortSecurityValue.object([("challenge", parsed?["challenge"] ?? .null)]).compact)
            case .wrong: return .init(status: 200, body: BackendDeckCoreTestPortSecurityValue.object([("challenge", .string("something else"))]).compact)
            }
        }
        delivered.signal()
        if decided.hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in if opened { return true }; waiter = continuation; return false }
                if ready { continuation.resume() }
            }
        }
        return .init(status: decided.status, body: "")
    }
}

/// mcp-events.test.ts's world: the clock, the receiver, each key's mode and
/// internet reach, and what the queue was told was delivered.
struct BackendDeckCoreTestPortS1EventsWorld: Sendable {
    struct Instance: Sendable { let events: BackendDeckCoreEvents; let changes: BackendDeckCoreTestPortSecuritySignal }
    static let secret = "whsec_" + Data(repeating: 7, count: 32).base64EncodedString()
    static let secret2 = "whsec_" + Data(repeating: 9, count: 32).base64EncodedString()
    static let urlA = "https://callbacks.example.com/mcp/events"
    let clock: BackendDeckCoreTestPortS1EventsClock
    let receiver: BackendDeckCoreTestPortS1EventsReceiver
    let modes: BackendDeckCoreSecurityTestBox<[String: String]>
    let internet: BackendDeckCoreSecurityTestBox<Bool>
    let delivered: BackendDeckCoreSecurityTestBox<[[String]]>
    init() {
        let clock = BackendDeckCoreTestPortS1EventsClock(1_800_000_000_000)
        self.clock = clock; receiver = BackendDeckCoreTestPortS1EventsReceiver(now: { clock.now() })
        modes = BackendDeckCoreSecurityTestBox(["key-a": "wait", "key-b": "wait"]); internet = BackendDeckCoreSecurityTestBox(true)
        delivered = BackendDeckCoreSecurityTestBox([])
    }
    func instance(directory: URL? = nil, owed: (@Sendable (String, String) async -> Bool)? = nil,
                  onDelivered: (@Sendable (String, String) async -> Void)? = nil) -> Instance {
        let changes = BackendDeckCoreTestPortSecuritySignal(), receiver = self.receiver, modes = self.modes, internet = self.internet, delivered = self.delivered
        let owing: @Sendable (String, String) async -> Bool = owed ?? { _, _ in true }
        let events = BackendDeckCoreEvents(directory: directory, mode: { modes.get()[$0] }, internet: { internet.get() }, clock: clock,
            post: { try await receiver.post($0, $1, $2) },
            onDelivered: { key, id in delivered.edit { $0.append([key, id]) }; if let onDelivered { await onDelivered(key, id) } },
            owed: owing, onChange: { changes.signal() })
        return Instance(events: events, changes: changes)
    }
}

/// notify-detect's surface: sessions and screen from the security fixture
/// surface, and the newest answer from the test's own map (`.null` = none yet).
struct BackendDeckCoreTestPortS1EventsAnswerSurface: BackendDeckCoreEventsDetectionSurface {
    let surface: BackendDeckCoreTestPortSecuritySurface
    let answers: BackendDeckCoreSecurityTestBox<[String: NativeRPCValue]>
    let clock: BackendDeckCoreTestPortS1EventsClock
    /// Signalled as each notification build starts reading.
    let builds: BackendDeckCoreTestPortSecuritySignal
    func notificationSessions() async throws -> [NativeRPCValue] { builds.signal(); return surface.listSessions() }
    func notificationScreen(sessionId: String) async throws -> String? { surface.screen }
    func notificationAnswer(session: NativeRPCValue) async throws -> NativeRPCValue? {
        let id = session["id"].string ?? ""
        guard let answer = answers.get()[id] else {
            return BackendDeckCoreTestPortSecurityValue.object([("at", .number(clock.now())), ("text", .string("the first answer in \(id)")), ("truncated", .bool(false))])
        }
        return answer == .null ? nil : answer.setting("truncated", .bool(false))
    }
}

/// key-door.fixture.ts with notifyTools: the real control gate (builtins, the
/// notification tools and describe), the access keys and their door, the
/// loopback server on a fake listener, the queue and the detector fed by
/// the control's own action rows.
struct BackendDeckCoreTestPortS1EventsKeyRig: Sendable {
    struct Key: Sendable { let id: String; let key: String; let name: String; let level: String }
    let clock: BackendDeckCoreTestPortS1EventsClock
    let surface: BackendDeckCoreTestPortSecuritySurface
    let answers: BackendDeckCoreSecurityTestBox<[String: NativeRPCValue]>
    let said: BackendDeckCoreSecurityTestBox<Int>
    let builds: BackendDeckCoreTestPortSecuritySignal
    let enqueued: BackendDeckCoreTestPortSecuritySignal
    let pauses: BackendDeckCoreTestPortSecuritySignal
    let notifySurface: BackendDeckCoreTestPortS1EventsAnswerSurface
    let control: BackendDeckCoreSecurityControl
    let keys: BackendDeckCoreSecurityAccessKeys
    let hub: BackendDeckCoreEventsHub
    let detector: BackendDeckCoreEventsDetector
    let events: BackendDeckCoreSecurityTestBox<BackendDeckCoreEvents?>
    let door: BackendDeckCoreSecurityAccessKeyDoor
    let server: BackendDeckCoreSecurityServer
    let endpoint: BackendDeckCoreSecurityEndpoint

    init(directory: URL, clock: BackendDeckCoreTestPortS1EventsClock) async throws {
        let surface = BackendDeckCoreTestPortSecuritySurface()
        surface.projects = ["/work/api", "/work/site"]
        let answers = BackendDeckCoreSecurityTestBox<[String: NativeRPCValue]>([:]), said = BackendDeckCoreSecurityTestBox(0)
        let builds = BackendDeckCoreTestPortSecuritySignal(), enqueued = BackendDeckCoreTestPortSecuritySignal()
        let hubBox = BackendDeckCoreSecurityTestBox<BackendDeckCoreEventsHub?>(nil)
        let detectorBox = BackendDeckCoreSecurityTestBox<BackendDeckCoreEventsDetector?>(nil)
        let eventsBox = BackendDeckCoreSecurityTestBox<BackendDeckCoreEvents?>(nil)
        // Typing runs on its own time in the source rig, not on the notification clock.
        let builtins = try BackendDeckCoreCatalogueBuiltins.tools(surface: surface, typingClock: .init(now: { clock.now() }, sleep: { _ in }))
        let notify = try BackendDeckCoreAreaIntegration.eventsBundle(policies: BackendDeckCoreEventsTools.notificationPolicies(hub: { hubBox.get() }))
        let metadataBox = BackendDeckCoreSecurityTestBox<[BackendDeckCoreCatalogueMetadata]>([])
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { metadataBox.get() })
        let metadata = builtins.metadata + notify.metadata + describe.metadata
        metadataBox.set(metadata)
        let log = BackendDeckCoreSecurityActionLog(directory: directory.appendingPathComponent("log"), now: { clock.now() })
        // approver: false — nobody is there to confirm anything.
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: builtins.policies + notify.policies + describe.policies,
            now: { clock.now() }, onRow: { row in if let detector = detectorBox.get() { await detector.noteRow(row) } })
        let keys = BackendDeckCoreSecurityAccessKeys(directory: directory.appendingPathComponent("remote"), now: { clock.now() })
        let hub = BackendDeckCoreEventsHub(settings: { await keys.notifySettings(id: $0) }, clock: clock)
        hubBox.set(hub)
        let notifySurface = BackendDeckCoreTestPortS1EventsAnswerSurface(surface: surface, answers: answers, clock: clock, builds: builds)
        // The order deck-control's composition uses: queued first, then pushed.
        let detector = BackendDeckCoreEventsDetector(surface: notifySurface, starterOf: { await control.starterOf(sessionID: $0) },
            enqueue: { key, event, turn in
                let accepted = await hub.enqueue(keyId: key, event: event, turn: turn)
                if accepted, let events = eventsBox.get() { _ = await events.offer(keyId: key, event: event) }
                enqueued.signal(); return accepted
            }, clock: clock)
        detectorBox.set(detector)
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys, consent: consent, events: { @Sendable () async -> (any BackendDeckCoreSecurityEvents)? in
            if let events = eventsBox.get() { return events }; return nil
        })
        await door.activate()
        let server = BackendDeckCoreSecurityServer(control: control, keys: door, ownPorts: .init(),
            listenerFactory: { BackendDeckCoreTestPortSecurityListener(handler: $0) },
            listing: { _, caller, granted in try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: caller, granted: granted) })
        let endpoint = try await server.start()
        self.clock = clock; self.surface = surface; self.answers = answers; self.said = said; self.builds = builds; self.enqueued = enqueued
        self.pauses = clock.signal(after: BackendDeckCoreEventsDetector.answerLagMilliseconds)
        self.notifySurface = notifySurface; self.control = control; self.keys = keys; self.hub = hub; self.detector = detector
        self.events = eventsBox; self.door = door; self.server = server; self.endpoint = endpoint
    }
    /// rig.key(level, { name, askFirst }).
    func key(_ name: String, level: String = "work", askFirst: Bool? = nil) async throws -> Key {
        var input = BackendDeckCoreTestPortSecurityValue.object([("name", .string(name)), ("level", .string(level))])
        if let askFirst { input = input.setting("askFirst", .bool(askFirst)) }
        let made = try await keys.create(input)
        return Key(id: made["view"]["id"].string ?? "", key: made["key"].string ?? "", name: name, level: level)
    }
    /// notify-detect.test.ts caller(): the key's own tiers, never asking first.
    func caller(_ key: Key) -> BackendDeckCoreSecurityCaller {
        BackendDeckCoreSecurityCaller(kind: .key, tiers: BackendDeckCoreSecurityAccessKeys.tiersFor(key.level), keyID: key.id, keyName: key.name, askFirst: false)
    }
    /// The agent says something new in this session.
    func say(_ session: String, _ text: String? = nil) {
        let words: String
        if let text { words = text } else { said.edit { $0 += 1 }; words = "answer \(said.get())" }
        let at = clock.now() + Double(said.get())
        answers.edit { $0[session] = BackendDeckCoreTestPortSecurityValue.object([("at", .number(at)), ("text", .string(words))]) }
    }
    /// A Claude Code session that has only drawn its banner: no transcript.
    func silence(_ session: String) { answers.edit { $0[session] = .null } }
    func types(_ keyID: String) async -> [[String]] {
        let rows = await hub.list(keyId: keyID)
        return rows.map { [$0["sessionId"].string ?? "", $0["type"].string ?? ""] }
    }
    /// newDetector(target): the same surface, starter and clock, queued into `target`.
    func detector(target: BackendDeckCoreEventsHub) -> BackendDeckCoreEventsDetector {
        let control = self.control, enqueued = self.enqueued
        return BackendDeckCoreEventsDetector(surface: notifySurface, starterOf: { await control.starterOf(sessionID: $0) },
            enqueue: { key, event, turn in let accepted = await target.enqueue(keyId: key, event: event, turn: turn); enqueued.signal(); return accepted }, clock: clock)
    }
    /// McpEvents wired the way mcp-events-server.test.ts wires it, on this rig's keys and queue.
    func attachEvents(receiver: BackendDeckCoreTestPortS1EventsReceiver, changes: BackendDeckCoreTestPortSecuritySignal) -> BackendDeckCoreEvents {
        let keys = self.keys, hub = self.hub
        let events = BackendDeckCoreEvents(mode: { await keys.notifySettings(id: $0)?["mode"].string }, internet: { await keys.internet() }, clock: clock,
            post: { try await receiver.post($0, $1, $2) }, onDelivered: { _ = await hub.deliveredBy(keyId: $0, id: $1, via: "event") },
            onChange: { changes.signal() })
        self.events.set(events); return events
    }
    /// One HTTP POST to the loopback /mcp road, as an outside client sends it.
    func post(_ body: NativeRPCValue, credential: String?, extra: [String: String] = [:]) async throws -> BackendDeckCoreSecurityHTTPResponse {
        var headers = ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:40404"]
        if let credential { headers["authorization"] = "Bearer " + credential }
        for (name, value) in extra { headers[name] = value }
        return await server.respond(.init(method: "POST", path: "/mcp", headers: headers, body: try body.encodedJSON()))
    }
    func stop() async {
        await detector.stop(); await hub.stop()
        if let events = events.get() { await events.stop() }
        await door.stop(); await server.stop()
    }
}

class BackendDeckCoreTestPortS1EventsCase: BackendDeckCoreTestPortSecurityCase {
    typealias Rig = BackendDeckCoreTestPortS1EventsKeyRig
    func keyRig(at now: Double = 5_000_000) async throws -> Rig {
        try await Rig(directory: scratch(), clock: BackendDeckCoreTestPortS1EventsClock(now))
    }
    /// new Date(ms).toISOString()
    func iso(_ milliseconds: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
    }
    func start(_ r: Rig, _ cwd: String, as caller: BackendDeckCoreSecurityCaller = .local, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let result = await r.control.call(name: "sessions.start", arguments: o([("cwd", .string(cwd))]), options: .init(caller: caller))
        XCTAssertTrue(result.ok, result.error ?? "", file: file, line: line)
        return try XCTUnwrap(result.value["session"]["id"].string, file: file, line: line)
    }
    func send(_ r: Rig, _ session: String, _ text: String, as caller: BackendDeckCoreSecurityCaller = .local) async -> BackendDeckCoreSecurityCallResult {
        await r.control.call(name: "sessions.send", arguments: o([("sessionId", .string(session)), ("text", .string(text))]), options: .init(caller: caller))
    }
    /// One whole turn, the way the hooks report it, ending on something new.
    func turn(_ r: Rig, _ session: String) async {
        r.say(session)
        await r.detector.noteStatus(sessionId: session, status: "working")
        await r.detector.noteStatus(sessionId: session, status: "completed")
        await r.detector.awaitIdle()
    }
    /// Every re-read of a transcript that has not caught up, on the test's clock:
    /// each lag pause is waited for (it is set by the build) before the clock moves.
    func waitOutLag(_ r: Rig, from mark: Int, firstStep: Double = BackendDeckCoreEventsDetector.answerLagMilliseconds) async {
        for step in 1...BackendDeckCoreEventsDetector.answerLagRetries {
            await r.pauses.wait(mark + step)
            r.clock.advance(step == 1 ? firstStep : BackendDeckCoreEventsDetector.answerLagMilliseconds)
        }
    }
    /// One 2026-07-28 request, as ChatGPT sends it: the _meta envelope plus the standard headers.
    func modern(_ r: Rig, _ credential: String, _ method: String, _ params: V = .object([]), id: Double) async throws -> (status: Int, body: V) {
        let body = rpc(method, id: .number(id), params: params, modern: true)
        let headers = BackendDeckCoreSecurityServer.withStandardHeaders(["mcp-protocol-version": "2026-07-28"], parsed: body)
        let reply = try await r.post(body, credential: credential, extra: headers)
        return (reply.status, try response(reply))
    }
    /// One request in the 2025 era, as the SDK client sends it.
    func legacy(_ r: Rig, _ credential: String, _ method: String, _ params: V = .object([]), id: Double) async throws -> V {
        try response(try await r.post(rpc(method, id: .number(id), params: params), credential: credential))
    }
}
