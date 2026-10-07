import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// index.test.ts's `SESSION` + `surface(settings)`: the dispatcher's fake app,
/// with the copilot folder on disk because the native runtime writes the two
/// MCP configs there (copilotPaths(userData).root in the source).
final class BackendDeckCoreTestPortS1IndexSurface: BackendDeckCoreCatalogueSurface, BackendDeckCoreEventsDetectionSurface, @unchecked Sendable {
    static let session = BackendDeckCoreTestPortSecurityValue.object([("id", .string("session-1")), ("cwd", .string("/work/api")), ("title", .string("api")),
        ("provider", .string("claude")), ("exitCode", .null), ("createdAt", .number(1))])
    private let lock = NSLock()
    private var values: NativeRPCValue = .object([.init("appearance.density", .string("comfortable"))])
    private let stateRoot: String
    private let homeRoot: String
    init(root: URL) { stateRoot = root.path; homeRoot = root.appendingPathComponent("copilot", isDirectory: true).path }
    func setting(_ key: String) -> NativeRPCValue { lock.withLock { values[key] } }
    func listSessions() -> [NativeRPCValue] { [Self.session] }
    func listProjects() -> [NativeRPCValue] { [BackendDeckCoreTestPortSecurityValue.object([("path", .string("/work/api")), ("lastOpenedAt", .number(1))])] }
    func sessionStatus(_ sessionID: String) -> NativeRPCValue { .null }
    func appStateRoot() -> String { stateRoot }
    func copilotRoot() -> String { homeRoot }
    func windows(sessionID: String) -> [NativeRPCValue] { [] }
    func readSettings() -> NativeRPCValue { .object([.init("settings", lock.withLock { values }), .init("preferences", .object([]))]) }
    func snapshotSettings() throws -> NativeRPCValue { .object([.init("path", .string("/tmp/settings.last-good.json")), .init("at", .number(0))]) }
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        lock.withLock { () -> NativeRPCValue in
            for field in patch.fields ?? [] {
                switch field.value {
                case .string, .number, .bool: values = values.setting(field.key, field.value)
                default: continue
                }
            }
            return values
        }
    }
    func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue { .object([]) }
    func sessionScreen(_ sessionID: String) async throws -> String? { "" }
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue { Self.session }
    func writeToSession(_ sessionID: String, data: String) async throws {}
    func killSession(_ sessionID: String) async throws {}
    func gitStatus(cwd: String) async throws -> NativeRPCValue { .object([.init("repo", .bool(false))]) }
    func alerts(projectPath: String) async throws -> NativeRPCValue { .object([.init("alerts", .array([]))]) }
    func notificationSessions() async throws -> [NativeRPCValue] { listSessions() }
    func notificationScreen(sessionId: String) async throws -> String? { "" }
    func notificationAnswer(session: NativeRPCValue) async throws -> NativeRPCValue? { nil }
}

/// FakeWindow: records what each window was sent and, when told to, answers a
/// confirmation through the same consent-respond channel a renderer uses.
final class BackendDeckCoreTestPortS1IndexWindows: @unchecked Sendable {
    private struct Sent: Sendable { let owner: String; let channel: String; let payload: NativeRPCValue }
    private let lock = NSLock()
    private var sent: [Sent] = []
    private var answers: [String: Bool] = [:]
    private var dead: Set<String> = []
    private var registry: NativeChannelRegistry?
    func use(_ registry: NativeChannelRegistry) { lock.withLock { self.registry = registry; dead = [] } }
    func answer(_ owner: String, _ decision: Bool) { lock.withLock { answers[owner] = decision } }
    func destroy(_ owner: String) { lock.withLock { _ = dead.insert(owner) } }
    func channels(_ owner: String) -> [String] { lock.withLock { sent.filter { $0.owner == owner }.map(\.channel) } }
    func send(owner: String, channel: String, payload: NativeRPCValue) async throws -> Bool {
        let (alive, decision, registry) = lock.withLock { () -> (Bool, Bool?, NativeChannelRegistry?) in
            guard !dead.contains(owner) else { return (false, nil, nil) }
            sent.append(.init(owner: owner, channel: channel, payload: payload)); return (true, answers[owner], self.registry)
        }
        guard alive else { return false }
        if channel == "deck-control:consent-request", let decision, let id = payload["id"].string, let registry {
            _ = try? await registry.invoke("deck-control:consent-respond", context: .init(caller: .nativeApp, ownerID: owner),
                arguments: [.string(id), .bool(decision)])
        }
        return true
    }
}

/// The `remoteApprover` relay: records questions and settlements; inert by default.
final class BackendDeckCoreTestPortS1IndexRelay: BackendDeckCoreConsentRelay, @unchecked Sendable {
    private let lock = NSLock()
    private var askedRows: [BackendDeckCoreSecurityConsentRequest] = []
    private var settledRows: [(String, BackendDeckCoreSecurityConsentOutcome)] = []
    private var delivering = false
    private var exploding = false
    let askedSignal = BackendDeckCoreTestPortSecuritySignal()
    let settledSignal = BackendDeckCoreTestPortSecuritySignal()
    func delivers(_ value: Bool) { lock.withLock { delivering = value } }
    func explodes(_ value: Bool) { lock.withLock { exploding = value } }
    func asked() -> [BackendDeckCoreSecurityConsentRequest] { lock.withLock { askedRows } }
    func settled() -> [(String, BackendDeckCoreSecurityConsentOutcome)] { lock.withLock { settledRows } }
    func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool {
        let (explode, deliver) = lock.withLock { (exploding, delivering) }
        if explode { throw NativeRPCError(code: "relay", message: "the phone layer blew up") }
        lock.withLock { askedRows.append(request) }; askedSignal.signal(); return deliver
    }
    func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws {
        lock.withLock { settledRows.append((id, outcome)) }; settledSignal.signal()
    }
}

struct BackendDeckCoreTestPortS1IndexFeatures: BackendDeckCoreFeatureLifecycle {
    func recover(control: BackendDeckCoreSecurityControl) async throws {}
    func noteStatus(sessionID: String, status: String) async {}
    func noteExit(sessionID: String, exitCode: Int) async {}
    func tasksWake() async {}
    func stopTasks() async {}
    func stopPlugins() async {}
}
struct BackendDeckCoreTestPortS1IndexNoWindow: BackendDeckCoreCatalogueWhereWindow {
    func read() async throws -> NativeRPCValue { .null }
}

/// The index.test.ts rig: the real registration over a fake app, a fake
/// listener for the authenticated HTTP handler, and fake clocks.
final class BackendDeckCoreTestPortS1IndexRig: @unchecked Sendable {
    struct Pushed: Sendable { let channel: String; let payload: NativeRPCValue }
    private struct Live: Sendable {
        let registry: NativeChannelRegistry
        let runtime: BackendDeckCoreRuntime
        let listener: BackendDeckCoreTestPortSecurityListener
        let observer: NativeRPCSubscription
    }
    static let approver = "approver-window", other = "other-window", activityPane = "s1c-activity-pane"
    let root: URL
    let surface: BackendDeckCoreTestPortS1IndexSurface
    let windows = BackendDeckCoreTestPortS1IndexWindows()
    let relay = BackendDeckCoreTestPortS1IndexRelay()
    /// The consent timeout clock never advances in these tests, so any refusal
    /// that arrives is the no-approver path rather than a timeout.
    let consentClock = BackendDeckCoreTestPortSecurityClock()
    let otherClock = BackendDeckCoreTestPortSecurityClock()
    let pushedBox = BackendDeckCoreSecurityTestBox<[Pushed]>([])
    let settledPush = BackendDeckCoreTestPortSecuritySignal()
    private let lock = NSLock()
    private var live: Live?

    init(root: URL) { self.root = root; surface = BackendDeckCoreTestPortS1IndexSurface(root: root) }
    static func boot(root: URL, trustEveryWindow: Bool = false) async throws -> BackendDeckCoreTestPortS1IndexRig {
        let rig = BackendDeckCoreTestPortS1IndexRig(root: root); try await rig.start(trustEveryWindow: trustEveryWindow); return rig
    }
    private var current: Live {
        guard let value = lock.withLock({ live }) else { preconditionFailure("The index rig is not running.") }
        return value
    }
    var registry: NativeChannelRegistry { current.registry }
    var runtime: BackendDeckCoreRuntime { current.runtime }
    func pushed(_ channel: String) -> [NativeRPCValue] { pushedBox.get().filter { $0.channel == channel }.map(\.payload) }

    func start(trustEveryWindow: Bool = false) async throws {
        let registry = NativeChannelRegistry()
        windows.use(registry)
        let windows = self.windows, pushedBox = self.pushedBox, settledPush = self.settledPush
        let consentClock = self.consentClock, otherClock = self.otherClock
        let window = BackendDeckCoreWindowConsent(
            isApprover: { context in trustEveryWindow || context.ownerID == BackendDeckCoreTestPortS1IndexRig.approver },
            send: { owner, channel, payload in try await windows.send(owner: owner, channel: channel, payload: payload) },
            broadcast: { channel, payload in
                pushedBox.edit { $0.append(Pushed(channel: channel, payload: payload)) }
                if channel == "deck-control:consent-settled" { settledPush.signal() }
            },
            relay: relay)
        let captured = BackendDeckCoreSecurityTestBox<BackendDeckCoreTestPortSecurityListener?>(nil)
        let providers = BackendDeckCoreRegistration.Providers(surface: surface, window: window,
            whereDependencies: BackendDeckCoreCatalogueWhereDependencies(window: BackendDeckCoreTestPortS1IndexNoWindow(), page: { nil }),
            mcp: BackendDeckCoreTestPortSecurityMCPProvider(), features: BackendDeckCoreTestPortS1IndexFeatures(), channelBridge: { nil })
        let options = BackendDeckCoreRegistration.Options(ownership: .exclusive, port: 0, consentTimeoutMilliseconds: 150,
            listenerFactory: { handler in
                let listener = BackendDeckCoreTestPortSecurityListener(handler: handler); captured.set(listener); return listener
            },
            consentClock: consentClock, notificationClock: otherClock,
            typingClock: BackendDeckCoreBriefClock(now: { otherClock.now() }, sleep: { otherClock.advance($0) }))
        let runtime = try await BackendDeckCoreRegistration.register(registry: registry, ownPorts: BackendDevOwnPorts(), dataDirectory: root,
            providers: providers, options: options)
        let observer: NativeRPCSubscription
        do {
            observer = try await registry.subscribe("deck-control:action", ownerID: Self.activityPane) { event in
                pushedBox.edit { $0.append(Pushed(channel: event.channel, payload: event.arguments.first ?? .null)) }
            }
        } catch { await runtime.stop(); throw error }
        guard let listener = captured.get() else {
            await observer.cancelAndWait(); await runtime.stop()
            throw NativeRPCError(code: "test-fixture", message: "The fake listener did not start.")
        }
        lock.withLock { live = Live(registry: registry, runtime: runtime, listener: listener, observer: observer) }
    }
    func stop() async {
        let value = lock.withLock { () -> Live? in let value = live; live = nil; return value }
        guard let value else { return }
        await value.observer.cancelAndWait(); await value.runtime.stop()
    }
    /// A second registerDeckControlIpc on the same registry (index.test.ts:273).
    func registerAgain() async throws {
        let window = BackendDeckCoreWindowConsent(isApprover: { _ in false }, send: { _, _, _ in false }, broadcast: { _, _ in })
        let providers = BackendDeckCoreRegistration.Providers(surface: BackendDeckCoreTestPortS1IndexSurface(root: root.appendingPathComponent("second", isDirectory: true)),
            window: window, whereDependencies: BackendDeckCoreCatalogueWhereDependencies(window: BackendDeckCoreTestPortS1IndexNoWindow(), page: { nil }),
            mcp: BackendDeckCoreTestPortSecurityMCPProvider(), features: BackendDeckCoreTestPortS1IndexFeatures(), channelBridge: { nil })
        let second = try await BackendDeckCoreRegistration.register(registry: registry, ownPorts: BackendDevOwnPorts(), dataDirectory: root, providers: providers,
            options: BackendDeckCoreRegistration.Options(ownership: .exclusive, port: 0, listenerFactory: { BackendDeckCoreTestPortSecurityListener(handler: $0) }))
        await second.stop()
    }
    func invoke(_ channel: String, from owner: String, _ arguments: [NativeRPCValue] = []) async throws -> NativeRPCValue {
        try await registry.invoke(channel, context: NativeRPCContext(caller: .nativeApp, ownerID: owner), arguments: arguments)
    }
    /// callTool: one authenticated MCP tools/call through the runtime's own HTTP handler.
    func call(_ name: String, _ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let live = current
        let body = try BackendDeckCoreTestPortSecurityValue.object([("jsonrpc", .string("2.0")), ("id", .number(1)), ("method", .string("tools/call")),
            ("params", BackendDeckCoreTestPortSecurityValue.object([("name", .string(name)), ("arguments", arguments)]))]).encodedJSON()
        let headers = ["content-type": "application/json", "accept": "application/json, text/event-stream",
            "host": "127.0.0.1:\(live.runtime.endpoint.port)", "authorization": "Bearer " + live.runtime.endpoint.token]
        let reply = try await live.listener.request(BackendDeckCoreSecurityHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body))
        return try NativeRPCValue.parseJSON(reply.body)["result"]
    }
}
