import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func BackendDeckToolsMachinesPortObject(_ values: [String: NativeRPCValue]) -> NativeRPCValue { .object(values.map { .init($0.key, $0.value) }) }
func BackendDeckToolsMachinesPortSpec(_ id: String) throws -> BackendMCPTool {
    guard let row = try BackendDeckToolsMachinesCatalogue.rows().first(where: { $0["id"].string == id }) else { throw BackendDeckToolsArgs.bad("no fixture tool \(id)") }
    return try .init(id: id, wireName: row["wire"].string!, description: row["description"].string!, inputSchema: row["inputSchema"], tier: BackendMCPTier(rawValue: row["tier"].string!)!, advertised: false)
}
final class BackendDeckToolsMachinesPortClockFake: BackendDeckCoreEventsClock, @unchecked Sendable {
    private struct Timer { let at: Double; let order: Int; let run: @Sendable () -> Void }
    private let lock = NSLock()
    private var value: Double
    private var timers: [UUID: Timer] = [:]
    private var scheduled = 0
    private var observations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sleeps: [Int] = []
    init(now: Double = 1_800_000_000_000) { value = now }
    func now() -> Double { lock.withLock { value } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            scheduled += 1; timers[id] = Timer(at: value + max(0, milliseconds), order: scheduled, run: run)
            let ready = observations.filter { $0.0 <= scheduled }.map(\.1); observations.removeAll { $0.0 <= scheduled }; return ready
        }
        for observation in ready { observation.resume() }; return id
    }
    func cancel(_ handle: UUID) { _ = lock.withLock { timers.removeValue(forKey: handle) } }
    func whenScheduled(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in if scheduled >= count { return true }; observations.append((count, continuation)); return false }
            if ready { continuation.resume() }
        }
    }
    func advance(_ milliseconds: Double) {
        let ready = lock.withLock { () -> [Timer] in
            value += milliseconds
            let ready = timers.filter { $0.value.at <= value }.sorted { $0.value.at == $1.value.at ? $0.value.order < $1.value.order : $0.value.at < $1.value.at }
            for entry in ready { timers[entry.key] = nil }; return ready.map(\.value)
        }
        for timer in ready { timer.run() }
    }
    func sleep(_ milliseconds: Int) { lock.withLock { sleeps.append(milliseconds) } }
    func sleepValues() -> [Int] { lock.withLock { sleeps } }
    func pendingCount() -> Int { lock.withLock { timers.count } }
}
actor BackendDeckToolsMachinesPortSignal {
    private var sent = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func send() { sent = true; let old = waiting; waiting = []; for one in old { one.resume() } }
    func wait() async { if sent { return }; await withCheckedContinuation { waiting.append($0) } }
}
actor BackendDeckToolsMachinesPortLedger {
    var started = Set<String>()
    func has(_ id: String) -> Bool { started.contains(id) }
    func note(_ id: String) { started.insert(id) }
}
func BackendDeckToolsMachinesPortContext(_ kind: BackendDeckToolsMachinesContext.Kind = .local, session: String? = nil,
                                       machine: String = "", key: String? = nil, attended: Bool = true,
                                       ledger: BackendDeckToolsMachinesPortLedger = .init()) -> BackendDeckToolsMachinesContext {
    .init(kind: kind, attended: attended, sessionID: session, machineID: machine, keyID: key, rpc: .init(caller: .nativeApp, ownerID: "fixture"), startedByCopilot: { await ledger.has($0) }, noteStarted: { await ledger.note($0) })
}
func BackendDeckToolsMachinesPortNativeContext() -> BackendMCPCallContext {
    .init(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init())
}
actor BackendDeckToolsMachinesPortEnvironment: BackendDeckToolsMachinesEnvironment {
    let source: BackendDeckToolsMachinesContext
    var records: [NativeRPCValue] = []
    var asks = 0
    init(_ source: BackendDeckToolsMachinesContext = BackendDeckToolsMachinesPortContext()) { self.source = source }
    func context(for call: BackendMCPCallContext) -> BackendDeckToolsMachinesContext { source }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws { try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments) }
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy, operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        if policy.tier == .alter || policy.ownerMustAnswer { asks += 1 }
        let result = try await operation()
        records.append(BackendDeckToolsMachinesPortObject(["args": policy.loggedArguments, "result": result.summary, "sentence": .string(policy.sentence)]))
        return .value(result.value)
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?, loggedArguments: NativeRPCValue, error: any Error) -> BackendMCPToolReply {
        records.append(BackendDeckToolsMachinesPortObject(["args": loggedArguments, "error": .string(error.localizedDescription)]))
        return BackendDeckToolsMachinesFactory.failureReply(error)
    }
    func log() -> String { NativeRPCValue.array(records).compact }
    func questionCount() -> Int { asks }
}
actor BackendDeckToolsMachinesPortChannels: BackendDeckToolsMachinesChannels {
    typealias Hook = @Sendable (String, [NativeRPCValue]) async throws -> NativeRPCValue?
    var answers: [String: NativeRPCValue]
    var calls: [(String, [NativeRPCValue])] = []
    var hook: Hook?
    init(_ answers: [String: NativeRPCValue] = [:]) { self.answers = answers }
    func set(_ channel: String, _ value: NativeRPCValue) { answers[channel] = value }
    func onCall(_ hook: @escaping Hook) { self.hook = hook }
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        calls.append((channel, arguments))
        if let value = try await hook?(channel, arguments) { return value }
        guard let value = answers[channel] else { throw BackendDeckToolsSupport.unavailable(channel) }; return value
    }
    func seen(_ channel: String) -> [[NativeRPCValue]] { calls.filter { $0.0 == channel }.map(\.1) }
    func all() -> [String] { calls.map(\.0) }
}
func BackendDeckToolsMachinesPortView(_ sessions: [String] = ["s-theirs"]) -> NativeRPCValue {
    let o = BackendDeckToolsMachinesPortObject
    return o(["here": .string("Mac mini"), "blocked": .null,
              "machines": .array([o(["id": .string("m1"), "name": .string("Office PC"), "platform": .string("win32"), "lastConnectedAt": .number(2)])]),
              "links": .array([o(["id": .string("m1"), "state": .string("online"), "reason": .null, "sessions": .array(sessions.map { o(["id": .string($0), "title": .string($0), "cwd": .string("/work"), "provider": .string("claude"), "status": .string("waiting"), "exitCode": .null]) }), "folders": .array([.string("/work")]), "ports": .array([o(["port": .number(3_000), "process": .string("node"), "guessed": .bool(false)])]), "copilot": .null, "hostVersion": .string("0.15.0")])])])
}
func BackendDeckToolsMachinesPortMachineArea(_ channels: BackendDeckToolsMachinesPortChannels,
    registry: NativeChannelRegistry = .init(), watch: BackendDeckToolsMachinesWatch? = nil,
    clock: BackendDeckToolsMachinesPortClockFake = .init()) -> BackendDeckToolsMachinesArea {
    .init(channels: channels, stateWaiter: .init(registry: registry, clock: clock), watch: watch ?? .init(clock: clock), dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"), sleep: { clock.sleep($0) })
}
func BackendDeckToolsMachinesPortMessage(_ id: String, _ role: String, _ text: String) -> NativeRPCValue {
    BackendDeckToolsMachinesPortObject(["id": .string(id), "role": .string(role), "text": .string(text), "at": .number(0)])
}
func BackendDeckToolsMachinesPortChat(_ messages: [NativeRPCValue], run: String = "r1", reset: Bool = false) -> NativeRPCValue {
    BackendDeckToolsMachinesPortObject(["machineId": .string("m1"), "chat": BackendDeckToolsMachinesPortObject(["run": .string(run), "messages": .array(messages), "reset": .bool(reset)])])
}

/// Vitest's object equality ignores object field order; NativeRPCValue's enum
/// equality preserves it. Keep arrays ordered while comparing JSON objects by key.
func BackendDeckToolsMachinesPortNormalized(_ value: NativeRPCValue) -> NativeRPCValue {
    if let fields = value.fields { return .object(fields.sorted { $0.key < $1.key }.map { .init($0.key, BackendDeckToolsMachinesPortNormalized($0.value)) }) }
    if let array = value.elements { return .array(array.map(BackendDeckToolsMachinesPortNormalized)) }; return value
}
func BackendDeckToolsMachinesPortEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T,
                                                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try left(), b = try right()
        if T.self == NativeRPCValue?.self {
            XCTAssertEqual((a as! NativeRPCValue?).map(BackendDeckToolsMachinesPortNormalized), (b as! NativeRPCValue?).map(BackendDeckToolsMachinesPortNormalized), message(), file: file, line: line)
        } else if let a = a as? NativeRPCValue, let b = b as? NativeRPCValue {
            XCTAssertEqual(BackendDeckToolsMachinesPortNormalized(a), BackendDeckToolsMachinesPortNormalized(b), message(), file: file, line: line)
        } else if let a = a as? [NativeRPCValue], let b = b as? [NativeRPCValue] {
            XCTAssertEqual(a.map(BackendDeckToolsMachinesPortNormalized), b.map(BackendDeckToolsMachinesPortNormalized), message(), file: file, line: line)
        } else if let a = a as? [[NativeRPCValue]], let b = b as? [[NativeRPCValue]] {
            XCTAssertEqual(a.map { $0.map(BackendDeckToolsMachinesPortNormalized) }, b.map { $0.map(BackendDeckToolsMachinesPortNormalized) }, message(), file: file, line: line)
        } else { XCTAssertEqual(a, b, message(), file: file, line: line) }
    } catch { XCTFail(error.localizedDescription, file: file, line: line) }
}
