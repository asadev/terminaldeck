import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendRoutinesFoundationParityRegistrationActions: BackendRoutinesActionAppending {
    func appendRoutineAction(_ value: NativeRPCValue) {}
}
struct BackendRoutinesFoundationParityRegistrationRoutineRig: Sendable {
    let directory: URL, service: BackendRoutinesService
    static func make(wired: [String] = []) async throws -> Self {
        let directory = try routinesTaskScratch(), clock = BackendRoutinesTaskEngineParityClock()
        let service = await BackendRoutinesService.create(options: .init(userData: directory, runner: .disabled,
            actions: BackendRoutinesFoundationParityRegistrationActions(), now: { clock.now() }, wired: wired, seedFolder: { nil }))
        let routine = BackendRoutinesRoutine(id: "probe", name: "Probe", triggers: [.sessionFinished, .sessionFailed, .sessionIdle(afterMs: 900_000), .alert(severity: nil, alertKind: nil)],
            folder: "/work/app", prompt: "Read evidence.", enabled: false)
        _ = try service.store.save(routine); await service.engine.reload()
        return .init(directory: directory, service: service)
    }
    func sources() async throws -> [String: BackendRoutinesSourceView] {
        let view = try #require(await service.engine.get("probe"))
        return Dictionary(uniqueKeysWithValues: view.sources.map { ($0.kind, $0) })
    }
}
actor BackendRoutinesFoundationParityRegistrationProbe {
    var installed: [String] = [], detached: [String] = [], dispatched: [NativeRPCValue] = [], received: [NativeRPCValue] = [], verified: [NativeRPCValue] = []
    var authorized: [String] = [], recorded: [String] = [], stateReads = 0, deny = false
    var capturedSuppliers: BackendCrmRegistration.Suppliers?
    private var started: (@Sendable (BackendSessionMeta) async -> Void)?
    private var status: (@Sendable (String, BackendSessionStatus) async -> Void)?
    private var exit: (@Sendable (String, Int) async -> Void)?
    private var alerts: (@Sendable (NativeRPCValue) async -> Void)?
    private var wake: (@Sendable () async -> Void)?
    private var changed: (@Sendable () async -> Void)?
    private var staleStatus: (@Sendable (String, BackendSessionStatus) async -> Void)?
    private var staleExit: (@Sendable (String, Int) async -> Void)?
    private var staleAlerts: (@Sendable (NativeRPCValue) async -> Void)?
    func lease(_ kind: String) -> NativeRPCSubscription {
        installed.append(kind)
        return NativeRPCSubscription { [weak self] in await self?.detach(kind) }
    }
    private func detach(_ kind: String) {
        detached.append(kind)
        switch kind {
        case "started": started = nil
        case "status": status = nil
        case "exit": exit = nil
        case "alerts": alerts = nil
        case "wake": wake = nil
        case "changed": changed = nil
        case "suppliers": capturedSuppliers = nil
        default: break
        }
    }
    func subscribeStarted(_ callback: @escaping @Sendable (BackendSessionMeta) async -> Void) async -> NativeRPCSubscription {
        started = callback; let metadata = Self.metadata()
        await callback(metadata); return lease("started")
    }
    func subscribeStatus(_ callback: @escaping @Sendable (String, BackendSessionStatus) async -> Void) -> NativeRPCSubscription {
        status = callback; staleStatus = callback; return lease("status")
    }
    func subscribeExit(_ callback: @escaping @Sendable (String, Int) async -> Void) -> NativeRPCSubscription {
        exit = callback; staleExit = callback; return lease("exit")
    }
    func subscribeAlerts(_ callback: @escaping @Sendable (NativeRPCValue) async -> Void) -> NativeRPCSubscription {
        alerts = callback; staleAlerts = callback; return lease("alerts")
    }
    func subscribeWake(_ callback: @escaping @Sendable () async -> Void) -> NativeRPCSubscription { wake = callback; return lease("wake") }
    func subscribeChanged(_ callback: @escaping @Sendable () async -> Void) -> NativeRPCSubscription { changed = callback; return lease("changed") }
    func emitRoutineEvents(stale: Bool = false) async {
        await (stale ? staleStatus : status)?("s-1", .working)
        await (stale ? staleExit : exit)?("s-1", 17)
        await (stale ? staleAlerts : alerts)?(routinesTaskObject([("projectPath", .string("/work/app")), ("alerts", .array([]))]))
        if !stale { await wake?() }
    }
    func emitChanged() async { await changed?() }
    func capture(_ suppliers: BackendCrmRegistration.Suppliers) { capturedSuppliers = suppliers }
    func state() -> NativeRPCValue { stateReads += 1; return routinesTaskObject([("marker", .string("real supplied state"))]) }
    func receive(_ event: NativeRPCEvent) { received.append(event.wireValue) }
    func dispatch(_ function: String, _ args: [NativeRPCValue], _ by: String) -> NativeRPCValue {
        let value = routinesTaskObject([("function", .string(function)), ("args", .array(args)), ("by", .string(by))]); dispatched.append(value); return value
    }
    func verify(_ channel: String, _ owner: String) { verified.append(.array([.string(channel), .string(owner)])) }
    func setDeny(_ value: Bool) { deny = value }
    func authorize(_ id: String) throws { authorized.append(id); if deny { throw NativeRPCError(code: "registration-test-denied", message: "Consent refused by the supplied access adapter.") } }
    func record(_ id: String) { recorded.append(id) }
    nonisolated static func metadata() -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: "/work/app", provider: "claude")
        input.originRoutineId = "origin"; input.originRunId = "origin-run"
        return BackendSessionMeta(id: "s-1", input: input,
            spawn: .init(provider: "claude", command: "/fake/no-process", args: [], path: "/fake", agentSessionId: "conversation", resumed: false), now: Date(timeIntervalSince1970: 1_800_000_000))
    }
    nonisolated func access() -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path }, session: { _, _ in .null },
            runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "registration-test") },
            authorize: { _, id, _, _, _, _ in try await self.authorize(id) }, record: { _, id, _, _ in await self.record(id) }, now: { 1_800_000_000_000 })
    }
    nonisolated func routineBindings() -> BackendRoutinesEventBindings {
        .init(sessionStarted: { await self.subscribeStarted($0) }, sessionStatus: { await self.subscribeStatus($0) },
            sessionExit: { await self.subscribeExit($0) }, alertReport: { await self.subscribeAlerts($0) }, wake: { await self.subscribeWake($0) })
    }
    nonisolated func installation(_ suppliers: BackendCrmRegistration.Suppliers, functions: Set<String> = ["addTaskSubtask"]) async -> BackendCrmRegistration.TaskOwnerInstallation {
        await capture(suppliers)
        let dispatcher = BackendCrmRegistration.DetailDispatcher(implementedFunctions: functions, call: { fn, args, by in await self.dispatch(fn, args, by) })
        return .init(dispatcher: dispatcher, supplierLease: await lease("suppliers"))
    }
}
func registrationTestTool(id: String, wire: String) throws -> BackendMCPTool {
    try .init(id: id, wireName: wire, description: "Unrelated test-owner tool", inputSchema: routinesTaskObject([("type", .string("object"))]), tier: .read)
}
func registrationTestContext() -> BackendMCPCallContext {
    .init(sessionID: "test", machineID: "local", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init())
}
