import Foundation
import XCTest
import Network
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckCoreTestPortSecurityValue {
    static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    static func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
}

/// Continuation barriers count actual callbacks. They never poll, sleep or
/// consume executor turns hoping that an operation has finished.
final class BackendDeckCoreTestPortSecuritySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func value() -> Int { lock.withLock { count } }
    func signal() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count += 1; let ready = waiting.filter { $0.0 <= count }.map(\.1); waiting.removeAll { $0.0 <= count }; return ready
        }
        for continuation in ready { continuation.resume() }
    }
    func wait(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if count >= target { return true }; waiting.append((target, continuation)); return false }
            if ready { continuation.resume() }
        }
    }
}

final class BackendDeckCoreTestPortSecurityClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Double
    private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
    let scheduled = BackendDeckCoreTestPortSecuritySignal()
    init(_ now: Double = 1_800_000_000_000) { instant = now }
    func now() -> Double { lock.withLock { instant } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = lock.withLock { let id = UUID(); timers[id] = (instant + max(milliseconds, 0), run); return id }; scheduled.signal(); return id
    }
    func cancel(_ id: UUID) { lock.withLock { timers[id] = nil } }
    func pending() -> Int { lock.withLock { timers.count } }
    func deadlines() -> [Double] { lock.withLock { timers.values.map(\.0).sorted() } }
    func advance(_ milliseconds: Double) {
        let target = now() + milliseconds
        // This consumes finite scheduled events, not a wait/poll loop.
        while let action: (@Sendable () -> Void) = lock.withLock({
            guard let next = timers.filter({ $0.value.0 <= target }).min(by: { $0.value.0 < $1.value.0 }) else { instant = target; return nil }
            instant = next.value.0; timers[next.key] = nil; return next.value.1
        }) { action() }
    }
    func set(_ milliseconds: Double) { lock.withLock { instant = milliseconds } }
}

actor BackendDeckCoreTestPortSecurityListener: BackendDeckCoreSecurityListening {
    let handler: BackendDeckCoreSecurityHTTPHandler
    let port: Int
    var requested: [Int] = []
    var stops = 0
    var failure: Error?
    let entered = BackendDeckCoreTestPortSecuritySignal()
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(port: Int = 47_821, failure: Error? = nil, paused: Bool = false, handler: @escaping BackendDeckCoreSecurityHTTPHandler) {
        self.port = port; self.failure = failure; self.paused = paused; self.handler = handler
    }
    func start(port: Int) async throws -> Int {
        requested.append(port); entered.signal()
        if paused { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }; return port == 0 ? self.port : port
    }
    func release() { paused = false; continuation?.resume(); continuation = nil }
    func stop() { stops += 1; release() }
    func snapshot() -> (requested: [Int], stops: Int) { (requested, stops) }
    func request(_ request: BackendDeckCoreSecurityHTTPRequest) async throws -> BackendDeckCoreSecurityHTTPResponse {
        guard !requested.isEmpty, stops == 0 else { throw NativeRPCError(code: "connection-refused", message: "The fake listener is closed.") }
        return await handler(request, .init())
    }
}

final class BackendDeckCoreTestPortSecurityPortWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = Set<Int>()
    private var next = 47_821
    var factory: BackendDeckCoreSecurityListenerFactory { { [self] handler in BackendDeckCoreTestPortSecurityWorldListener(world: self, handler: handler) } }
    func bind(_ wanted: Int) throws -> Int {
        try lock.withLock {
            if wanted > 0 { guard claimed.insert(wanted).inserted else { throw NWError.posix(.EADDRINUSE) }; return wanted }
            while claimed.contains(next) { next += 1 }
            let port = next; next += 1; claimed.insert(port); return port
        }
    }
    func release(_ port: Int) { lock.withLock { _ = claimed.remove(port) } }
}
private actor BackendDeckCoreTestPortSecurityWorldListener: BackendDeckCoreSecurityListening {
    let world: BackendDeckCoreTestPortSecurityPortWorld
    let handler: BackendDeckCoreSecurityHTTPHandler
    private var bound: Int?
    init(world: BackendDeckCoreTestPortSecurityPortWorld, handler: @escaping BackendDeckCoreSecurityHTTPHandler) { self.world = world; self.handler = handler }
    func start(port: Int) throws -> Int { let port = try world.bind(port); bound = port; return port }
    func stop() { if let bound { world.release(bound) }; bound = nil }
}

final class BackendDeckCoreTestPortSecuritySurface: BackendDeckCoreCatalogueSurface, @unchecked Sendable {
    typealias V = NativeRPCValue
    static func meta(_ id: String, cwd: String = "/work/api", provider: String = "claude", createdAt: Double = 1000, exitCode: Double? = nil) -> V {
        BackendDeckCoreTestPortSecurityValue.object([("id", .string(id)), ("cwd", .string(cwd)), ("title", .string(cwd.split(separator: "/").last.map(String.init) ?? "api")),
            ("provider", .string(provider)), ("createdAt", .number(createdAt)), ("exitCode", exitCode.map(V.number) ?? .null)])
    }
    var sessions = [meta("human-1"), meta("human-2", cwd: "/work/web")]
    var projects = ["/work/api", "/work/web", "/work/docs"]
    var statuses: [String: V] = ["human-1": BackendDeckCoreTestPortSecurityValue.object([("status", .string("working")), ("at", .number(2000))])]
    var settings: V = .object([.init("appearance.density", .string("comfortable"))])
    var preferences: V = BackendDeckCoreTestPortSecurityValue.object([("theme", .string("dark")), ("defaultProvider", .string("claude")), ("restoreSessions", .bool(true)), ("notifyOnComplete", .bool(true))])
    var accountRows: [V]? = nil
    var deviceGrants: [String: [String]]? = ["phone-1": ["/work/api"]]
    var writes: [(String, String)] = []
    var killed: [String] = []
    var starts: [V] = []
    var startedFor: [(String?, String)] = []
    var settingsTrace: [String] = []
    var snapshotFails = false
    var transcriptSize: Double = 0
    var transcript: [V] = []
    var transcriptReads: [(String, Double)] = []
    var screen = "the last screen\nof a shell"
    var stateRoot = "/state"
    var homeRoot = "/state/copilot"
    var snapshotPath = "/tmp/settings.last-good.json"
    var matches: [String: String] = ["/work/api": "/transcripts/api.jsonl"]
    func listSessions() -> [V] { sessions }
    func listProjects() -> [V] { projects.enumerated().map { .object([.init("path", .string($0.element)), .init("lastOpenedAt", .number(Double(3 - $0.offset)))]) } }
    func sessionStatus(_ id: String) -> V { statuses[id] ?? .null }
    func appStateRoot() -> String { stateRoot }
    func copilotRoot() -> String { homeRoot }
    func accounts() -> [V]? { accountRows }
    func deviceFolders(_ id: String) -> [String]? { deviceGrants?[id] ?? (deviceGrants == nil ? nil : []) }
    func windows(sessionID: String) -> [V] { [] }
    func readSettings() -> V { .object([.init("settings", settings), .init("preferences", preferences)]) }
    func snapshotSettings() throws -> V {
        settingsTrace.append("snapshot"); if snapshotFails { throw NativeRPCError(code: "filesystem", message: "read-only file system") }
        return .object([.init("path", .string(snapshotPath)), .init("at", .number(7))])
    }
    func writeSettings(_ patch: V) -> V {
        settingsTrace.append("write")
        for field in patch.fields ?? [] { settings = field.value == .null ? settings.removing(field.key) : settings.setting(field.key, field.value) }; return settings
    }
    func writePreferences(_ patch: V) -> V { settingsTrace.append("write"); preferences = preferences.merging(patch); return preferences }
    func startSession(input: V, forDevice: String?) async -> V {
        starts.append(input); startedFor.append((forDevice, input["cwd"].string ?? ""))
        let session = Self.meta("copilot-\(starts.count)", cwd: input["cwd"].string ?? "").merging(input); sessions.append(session); return session
    }
    func writeToSession(_ id: String, data: String) async { writes.append((id, data)) }
    func killSession(_ id: String) async { killed.append(id); sessions.removeAll { $0["id"].string == id } }
    func sessionScreen(_ id: String) async -> String? { screen }
    func gitStatus(cwd: String) async -> V { .object([.init("repo", .bool(true)), .init("cwd", .string(cwd)), .init("clean", .bool(true))]) }
    func alerts(projectPath: String) async -> V { .object([.init("projectPath", .string(projectPath)), .init("alerts", .array([.object([.init("id", .string("a"))])]))]) }
    func transcriptFor(session: V) async -> V { .object([.init("path", matches[session["cwd"].string ?? ""].map(V.string) ?? .null)]) }
    func transcriptBytes(path: String) async -> Double { transcriptSize }
    func readTranscriptFrom(path: String, fromByte: Double) async -> [V] { transcriptReads.append((path, fromByte)); return transcript }
}

struct BackendDeckCoreTestPortSecurityRig: Sendable {
    enum Approval: Sendable { case absent, allow, decline, hold, broken }
    let surface: BackendDeckCoreTestPortSecuritySurface
    let clock: BackendDeckCoreTestPortSecurityClock
    let log: BackendDeckCoreSecurityActionLog
    let consent: BackendDeckCoreSecurityConsentBroker
    let control: BackendDeckCoreSecurityControl
    let metadata: [BackendDeckCoreCatalogueMetadata]
    let approval: BackendDeckCoreSecurityTestBox<Approval>
    let questions: BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>
    let asked: BackendDeckCoreTestPortSecuritySignal
    let settled: BackendDeckCoreTestPortSecuritySignal
    init(directory: URL, approval initial: Approval = .absent, clock: BackendDeckCoreTestPortSecurityClock = .init(),
         timeout: Int = 120_000, budgets: BackendDeckCoreSecurityBudgets = .init(), extras: [BackendDeckCoreSecurityToolPolicy] = []) throws {
        let surface = BackendDeckCoreTestPortSecuritySurface()
        let approval = BackendDeckCoreSecurityTestBox(initial), questions = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([])
        let broker = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let asked = BackendDeckCoreTestPortSecuritySignal(), settled = BackendDeckCoreTestPortSecuritySignal()
        let consent = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: timeout, clock: clock, ask: { question in
            surface.settingsTrace.append("asked"); questions.edit { $0.append(question) }; asked.signal()
            switch approval.get() {
            case .absent: return false
            case .broken: throw NativeRPCError(code: "window", message: "window gone")
            case .hold: return true
            case .allow: _ = await broker.get()?.respond(id: question.id, approved: true, by: "window"); return true
            case .decline: _ = await broker.get()?.respond(id: question.id, approved: false, by: "window"); return true
            }
        }, settled: { _, _ in settled.signal() })
        broker.set(consent)
        let builtins = try BackendDeckCoreCatalogueBuiltins.tools(surface: surface, typingClock: .init(now: { clock.now() }, sleep: { clock.advance($0) }))
        let metadataBox = BackendDeckCoreSecurityTestBox<[BackendDeckCoreCatalogueMetadata]>([])
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { metadataBox.get() })
        let metadata = builtins.metadata + describe.metadata
        metadataBox.set(metadata)
        let log = BackendDeckCoreSecurityActionLog(directory: directory, now: { clock.now() })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: builtins.policies + describe.policies + extras, budgets: budgets, now: { clock.now() })
        self.surface = surface; self.clock = clock; self.log = log; self.consent = consent; self.control = control
        self.metadata = metadata; self.approval = approval; self.questions = questions; self.asked = asked; self.settled = settled
    }
    func server(keys: BackendDeckCoreSecurityAccessKeyDoor? = nil,
                factory: @escaping BackendDeckCoreSecurityListenerFactory = { BackendDeckCoreTestPortSecurityListener(handler: $0) }) -> BackendDeckCoreSecurityServer {
        BackendDeckCoreSecurityServer(control: control, keys: keys, ownPorts: .init(), listenerFactory: factory,
            listing: { _, caller, granted in try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: caller, granted: granted) })
    }
    func call(_ name: String, _ args: NativeRPCValue = .object([]), _ options: BackendDeckCoreSecurityCallOptions = .init()) async -> BackendDeckCoreSecurityCallResult {
        await control.call(name: name, arguments: args, options: options)
    }
}

struct BackendDeckCoreTestPortSecurityDoorFixture: Sendable {
    let rig: BackendDeckCoreTestPortSecurityRig
    let keys: BackendDeckCoreSecurityAccessKeys
    let door: BackendDeckCoreSecurityAccessKeyDoor
    let server: BackendDeckCoreSecurityServer
    let endpoint: BackendDeckCoreSecurityEndpoint
    let listener: BackendDeckCoreTestPortSecurityListener
    init(directory: URL, approval: BackendDeckCoreTestPortSecurityRig.Approval = .absent,
         timeout: Int = 120_000, budgets: BackendDeckCoreSecurityBudgets = .init(), events: (any BackendDeckCoreSecurityEvents)? = nil) async throws {
        let rig = try BackendDeckCoreTestPortSecurityRig(directory: directory.appendingPathComponent("log"), approval: approval, timeout: timeout, budgets: budgets)
        rig.surface.projects = ["/work/api", "/work/site"]
        let keys = BackendDeckCoreSecurityAccessKeys(directory: directory.appendingPathComponent("remote"), now: { rig.clock.now() })
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys, consent: rig.consent, events: { events }); await door.activate()
        let captured = BackendDeckCoreSecurityTestBox<BackendDeckCoreTestPortSecurityListener?>(nil)
        let server = rig.server(keys: door, factory: { handler in let listener = BackendDeckCoreTestPortSecurityListener(handler: handler); captured.set(listener); return listener }), endpoint = try await server.start()
        guard let listener = captured.get() else { throw NativeRPCError(code: "test-fixture", message: "The fake listener did not start.") }
        self.rig = rig; self.keys = keys; self.door = door; self.server = server; self.endpoint = endpoint; self.listener = listener
    }
    func post(_ body: NativeRPCValue, credential: String?, pathCredential: Bool = false,
              headers extra: [String: String] = [:], method: String = "POST", path: String? = nil) async throws -> BackendDeckCoreSecurityHTTPResponse {
        var headers = ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:40404"]
        if !pathCredential, let credential { headers["authorization"] = "Bearer " + credential }
        for (key, value) in extra { headers[key] = value }
        return await server.respond(.init(method: method, path: path ?? (pathCredential ? "/mcp/" + (credential ?? "") : "/mcp"), headers: headers, body: try body.encodedJSON()))
    }
    func stop() async { await door.stop(); await server.stop() }
}

@MainActor
class BackendDeckCoreTestPortSecurityCase: XCTestCase {
    typealias V = NativeRPCValue
    func o(_ fields: [(String, V)]) -> V { BackendDeckCoreTestPortSecurityValue.object(fields) }
    func json(_ text: String) throws -> V { try BackendDeckCoreTestPortSecurityValue.json(text) }
    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    func rig(approval: BackendDeckCoreTestPortSecurityRig.Approval = .absent, budgets: BackendDeckCoreSecurityBudgets = .init(), extras: [BackendDeckCoreSecurityToolPolicy] = []) throws -> BackendDeckCoreTestPortSecurityRig {
        try .init(directory: scratch(), approval: approval, budgets: budgets, extras: extras)
    }
    func assertError(_ work: () throws -> Void, code: String? = nil, contains: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        do { try work(); XCTFail("Expected source refusal", file: file, line: line) }
        catch { if let code { XCTAssertEqual((error as? NativeRPCError)?.code, code, file: file, line: line) }; if let contains { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription, file: file, line: line) } }
    }
    func assertAsyncError(_ work: () async throws -> Void, code: String? = nil, contains: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected source refusal", file: file, line: line) }
        catch { if let code { XCTAssertEqual((error as? NativeRPCError)?.code, code, file: file, line: line) }; if let contains { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription, file: file, line: line) } }
    }
    func made(_ keys: BackendDeckCoreSecurityAccessKeys, name: String = "ChatGPT", level: String = "full", extras: V = .object([])) async throws -> V {
        try await keys.create(o([("name", .string(name)), ("level", .string(level))]).merging(extras))
    }
    func rpc(_ method: String, id: V = .number(1), params: V = .object([]), modern: Bool = false) -> V {
        let meta = o([("io.modelcontextprotocol/protocolVersion", .string("2026-07-28")), ("io.modelcontextprotocol/clientCapabilities", .object([])),
            ("io.modelcontextprotocol/clientInfo", o([("name", .string("openai-mcp")), ("version", .string("2.0.0"))]))])
        return o([("jsonrpc", .string("2.0")), ("id", id), ("method", .string(method)), ("params", modern ? params.setting("_meta", meta) : params)])
    }
    func response(_ reply: BackendDeckCoreSecurityHTTPResponse) throws -> V { try V.parseJSON(reply.body) }
    func assertValue(_ value: V, _ expected: V, file: StaticString = #filePath, line: UInt = #line) {
        func canonical(_ value: V) -> V {
            switch value {
            case .object(let fields): return .object(fields.filter { $0.value != .missing }.sorted { $0.key < $1.key }.map { .init($0.key, canonical($0.value)) })
            case .array(let values): return .array(values.map(canonical))
            default: return value
            }
        }
        XCTAssertEqual(canonical(value), canonical(expected), file: file, line: line)
    }
    var headers: [String: String] { ["content-type": "application/json", "accept": "application/json, text/event-stream", "host": "127.0.0.1:40404"] }
}
