import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendCopilotRemoteTestBox: @unchecked Sendable {
    struct State {
        var mine: Set<String> = ["phone", "tablet"]
        var alive = Set<String>()
        var at: Double = 1000
        var spawned: [BackendCopilotRemoteSpawnRequest] = []
        var tokenCountsAtSpawn: [Int] = []
        var stopped: [String] = []
        var tokenCountsAtStop: [Int] = []
        var said: [(String, String)] = []
        var interrupted: [String] = []
        var interactiveWrites: [Bool] = []
        var interactive = true
        var applied = 0
        var logLimits: [Int] = []
        var chatters: [String: @Sendable (BackendCopilotRemoteChatUpdate) async -> Void] = [:]
    }
    private let lock = NSLock()
    private var state = State()
    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }
    @discardableResult func change<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }
}
actor BackendCopilotRemoteTestRelay {
    var runs: BackendCopilotRemoteRuns?
    func set(_ runs: BackendCopilotRemoteRuns) { self.runs = runs }
    func ask(_ question: BackendDeckCoreSecurityConsentRequest) async -> Bool { await runs?.ask(question) ?? false }
    func settled(_ id: String, _ outcome: BackendDeckCoreSecurityConsentOutcome) async { await runs?.settled(id, outcome: outcome) }
}
actor BackendCopilotRemoteTestStartGate {
    private var paused = false
    private var unblock: CheckedContinuation<Void, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        paused = true
        for continuation in entered { continuation.resume() }; entered.removeAll()
        await withCheckedContinuation { unblock = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }; await withCheckedContinuation { entered.append($0) }
    }
    func release() { unblock?.resume(); unblock = nil }
}
actor BackendCopilotRemoteTestRecorder {
    private var frames: [BackendRemoteServerMessage] = []
    private var unread: [BackendRemoteServerMessage.Kind: [BackendRemoteServerMessage]] = [:]
    private var waiting: [BackendRemoteServerMessage.Kind: [CheckedContinuation<BackendRemoteServerMessage, Never>]] = [:]
    func receive(_ frame: BackendRemoteServerMessage) {
        frames.append(frame)
        if var entries = waiting[frame.kind], !entries.isEmpty {
            let one = entries.removeFirst(); waiting[frame.kind] = entries; one.resume(returning: frame)
        } else { unread[frame.kind, default: []].append(frame) }
    }
    func all(_ kind: BackendRemoteServerMessage.Kind) -> [BackendRemoteServerMessage] { frames.filter { $0.kind == kind } }
    func next(_ kind: BackendRemoteServerMessage.Kind) async -> BackendRemoteServerMessage {
        if var entries = unread[kind], !entries.isEmpty { let one = entries.removeFirst(); unread[kind] = entries; return one }
        return await withCheckedContinuation { waiting[kind, default: []].append($0) }
    }
}
final class BackendCopilotRemoteTestFixture: Sendable {
    let directory: URL
    let box: BackendCopilotRemoteTestBox
    let table: BackendDeckCoreSecurityCallerTable
    let broker: BackendDeckCoreSecurityConsentBroker
    let runs: BackendCopilotRemoteRuns
    let hidden: BackendRemoteServeSessionHidden
    init(graceMilliseconds: Double = 60_000, endpointAvailable: Bool = true, spawnFails: Bool = false,
         sayFails: Bool = false, interruptFails: Bool = false, stopFails: Bool = false, timeoutMilliseconds: Int = 5_000,
         desktopAttached: Bool = false, startGate: BackendCopilotRemoteTestStartGate? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let box = BackendCopilotRemoteTestBox(), table = BackendDeckCoreSecurityCallerTable(), relay = BackendCopilotRemoteTestRelay()
        self.box = box; self.table = table
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: timeoutMilliseconds,
            now: { box.read { $0.at } }, ask: { question in let remote = await relay.ask(question); return desktopAttached || remote }, settled: { await relay.settled($0, $1) })
        self.broker = broker
        let endpoint = BackendDeckCoreSecurityEndpoint(port: 5599, token: "local-test", unattendedToken: "unattended-test", url: URL(string: "http://127.0.0.1:5599/mcp")!, callers: table)
        let registry = BackendCopilotRemoteSecurityRegistry(endpoint: { endpointAvailable ? endpoint : nil })
        let hidden = BackendRemoteServeSessionHidden(); self.hidden = hidden
        let deps = BackendCopilotRemoteRunDependencies(access: .init(isMine: { id in box.read { $0.mine.contains(id) } }),
            consent: { broker }, callers: registry,
            endpoint: { endpointAvailable ? try .init(url: endpoint.url, implementation: .native) : nil },
            root: { directory.appendingPathComponent("copilot").path },
            spawn: { request in
                let count = await table.size()
                let id = box.change { state in state.spawned.append(request); state.tokenCountsAtSpawn.append(count); return "run-\(state.spawned.count)" }
                if let startGate { await startGate.pause() }
                if spawnFails { throw NativeRPCError(code: "unavailable", message: "/private/test-secret-path missing CLI") }
                box.change { $0.alive.insert(id) }; return id
            }, isAlive: { id in box.read { $0.alive.contains(id) } }, stop: { id in
                let count = await table.size()
                box.change { $0.stopped.append(id); $0.tokenCountsAtStop.append(count) }
                if stopFails { throw NativeRPCError(code: "unavailable", message: "stop failed") }
                box.change { $0.alive.remove(id) }
            }, say: { id, text in
                if sayFails { throw BackendSessionFailure.missingSession }
                box.change { $0.said.append((id, text)) }
            }, interrupt: { id in
                if interruptFails { throw BackendSessionFailure.missingSession }
                box.change { $0.interrupted.append(id) }
            }, desk: { .init(status: "running", profile: "Personal", signedIn: true, available: true, reason: nil, interactive: box.read { $0.interactive }) },
            cost: { (11, 900) }, setInteractive: { on in box.change { $0.interactiveWrites.append(on); $0.interactive = on } },
            sessions: { [] }, log: { limit, _ in box.change { $0.logLimits.append(limit) }; return ([], false) },
            chat: { id, callback in box.change { $0.chatters[id] = callback }; return { box.change { $0.chatters[id] = nil } } },
            now: { box.read { $0.at } }, graceMilliseconds: graceMilliseconds, hidden: hidden)
        runs = BackendCopilotRemoteRuns(dependencies: deps)
        await relay.set(runs)
    }
    func watch(_ id: String, recorder: BackendCopilotRemoteTestRecorder) async -> UUID { await runs.watch(id) { await recorder.receive($0) } }
    func emit(_ id: String, text: String, reset: Bool = false) async {
        if let callback = box.read({ $0.chatters[id] }) {
            await callback(.init(messages: [.object([.init("id", .string("m1")), .init("role", .string("agent")), .init("text", .string(text)), .init("at", .number(5))])], reset: reset))
        }
    }
    func advance(_ ms: Double) { box.change { $0.at += ms } }
    func finish() async { await runs.stopAll(); await broker.stop(); try? FileManager.default.removeItem(at: directory) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
func BackendCopilotRemoteTestMessage(_ type: String, fields: [NativeRPCValue.Field] = []) throws -> BackendRemoteClientMessage {
    let raw = NativeRPCValue.object([.init("t", .string(type))] + fields)
    guard case .message(let frame) = BackendRemoteProtocol.parseClientMessage(raw) else { throw NativeRPCError.invalidArguments("Invalid test frame") }
    return frame
}
func BackendCopilotRemoteTestContext(_ deviceID: String, id: UUID = UUID(), mine: Bool = true) -> BackendRemoteHostContext {
    .init(connectionID: id, deviceID: deviceID, kind: mine ? .mine : .guest, address: "loopback-test", peerPublicKey: nil, claimedCapabilities: [],
        reach: .init(kind: mine ? .mine : .guest, unrestricted: mine, folders: [], accounts: nil, drivesWindows: mine))
}
