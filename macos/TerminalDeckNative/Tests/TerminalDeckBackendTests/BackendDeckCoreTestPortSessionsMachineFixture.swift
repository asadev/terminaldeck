import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckCoreTestPortSessionsChannels: BackendDeckToolsMachinesChannels {
    typealias V = NativeRPCValue
    struct Call: Sendable { let channel: String; let args: [V] }
    private var answers: [String: V]
    private(set) var calls: [Call] = []
    init(_ answers: [String: V]) { self.answers = answers }
    func set(_ channel: String, _ answer: V) { answers[channel] = answer }
    func call(_ channel: String, _ arguments: [V], context: BackendDeckToolsMachinesContext) throws -> V {
        calls.append(.init(channel: channel, args: arguments))
        guard let value = answers[channel] else { throw NativeRPCError(code: "unexpected-fixture-call", message: "Fixture did not expect \(channel)") }
        return value
    }
}

struct BackendDeckCoreTestPortSessionsShells: BackendDeckToolsMachinesServerShells {
    let rows: [NativeRPCValue]
    init() { rows = [.object([.init("shellId", .string("s1 abc")), .init("serverId", .string("s1")), .init("openedAt", .number(1))])] }
    func openShells() -> [NativeRPCValue] { rows }
    func shellScreen(_ shellID: String) -> String? { shellID == "s1 abc" ? "me@web-1:~$ " : nil }
}

final class BackendDeckCoreTestPortSessionsGateTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var questions: [BackendDeckCoreSecurityConsentRequest] = []
    private var broker: BackendDeckCoreSecurityConsentBroker?
    var asked: [BackendDeckCoreSecurityConsentRequest] { lock.withLock { questions } }
    func bind(_ broker: BackendDeckCoreSecurityConsentBroker) { lock.withLock { self.broker = broker } }
    func answer(_ question: BackendDeckCoreSecurityConsentRequest, approved: Bool) async -> Bool {
        let owner = lock.withLock { questions.append(question); return broker }
        return await owner?.respond(id: question.id, approved: approved, by: "window") ?? false
    }
}
struct BackendDeckCoreTestPortSessionsUnusedTimerClock: BackendDeckCoreEventsClock {
    func now() -> Double { 1000 }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        XCTFail("A fake approver answers synchronously; no timer should remain pending")
        return UUID()
    }
    func cancel(_ handle: UUID) {}
}

enum BackendDeckCoreTestPortSessionsMachineFixtureSupport {
    typealias V = NativeRPCValue
    typealias Policy = BackendDeckToolsMachinesPolicy
    typealias Output = BackendDeckToolsMachinesOutput
    typealias Context = BackendDeckToolsMachinesContext
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    struct Gated: Sendable { let result: BackendDeckCoreSecurityCallResult; let logText: String; let asked: [BackendDeckCoreSecurityConsentRequest] }
    static func call(id: String, arguments: V, context: Context = S.context(), approved: Bool = true,
                     prepare: @escaping @Sendable (BackendMCPTool, V, Context) async throws -> Policy,
                     run: @escaping @Sendable (String, V, Context) async throws -> Output) async throws -> Gated {
        let tool = try S.spec(id)
        var prepared: Policy?, error: (any Error)?
        do { prepared = try await prepare(tool, arguments, context) } catch let thrown { error = thrown }
        let policy = prepared, preflightError = error
        let wrapped = BackendDeckCoreSecurityToolPolicy(tool: tool, spendsDeviceInput: policy?.spends == "device-input",
            summary: { _, _ in policy?.sentence ?? id }, precheck: { _, _ in if let preflightError { throw preflightError } },
            escalate: { _, _ in policy?.tier }, ownerMustAnswer: { _ in policy?.ownerMustAnswer ?? false },
            redactArgs: { args in policy?.loggedArguments ?? args }, run: { args, _ in
                let result = try await run(id, args, context); return .init(value: result.value, summary: result.summary)
            })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortSessions-machine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = BackendDeckCoreSecurityActionLog(directory: directory, now: {1000}), trace = BackendDeckCoreTestPortSessionsGateTrace()
        let broker = BackendDeckCoreSecurityConsentBroker(clock: BackendDeckCoreTestPortSessionsUnusedTimerClock(), ask: { await trace.answer($0, approved: approved) })
        trace.bind(broker)
        let gate = try BackendDeckCoreSecurityControl(log: log, consent: broker, policies: [wrapped], now: {1000})
        let caller = BackendDeckCoreSecurityCaller(kind: BackendDeckCoreSecurityCaller.Kind(rawValue: context.kind.rawValue) ?? .local,
            tiers: [.read,.act,.alter], deviceID: context.deviceID, sessionID: context.sessionID, machineID: context.machineID)
        let result = await gate.call(name: id, arguments: arguments, options: .init(caller: caller, attended: context.attended))
        let logFile = await log.file
        return .init(result: result, logText: (try? String(contentsOf: logFile, encoding: .utf8)) ?? "", asked: trace.asked)
    }
    static var remoteDevices: V { .array([
        S.o([("id", .string("d-phone")),("name",.string("iPhone")),("addedAt",.number(1)),("lastSeenAt",.number(2)),("approved",.bool(true)),("revoked",.bool(false)),("status",.string("approved")),("fingerprint",.string("F1"))]),
        S.o([("id", .string("d-guest")),("name",.string("Saba’s laptop")),("addedAt",.number(1)),("lastSeenAt",.null),("approved",.bool(false)),("revoked",.bool(false)),("status",.string("pending")),("fingerprint",.string("F2"))])]) }
    static var remoteAnswers: [String: V] { [
        "remote:status": S.o([("running",.bool(true)),("url",.null),("address",.null),("port",.number(0)),("reason",.null),("directReason",.string("Tailscale is not signed in")),
            ("relay",S.o([("url",.string("wss://relay")),("hostId",.string("h")),("publicKey",.string("pk")),("fingerprint",.string("HOST-F")),("connected",.bool(true)),("channels",.number(1)),("reason",.null),("retryAt",.null)])),
            ("connections",.array([S.o([("id",.string("c1")),("deviceId",.string("d-phone")),("deviceName",.string("iPhone")),("platform",.string("ios")),("address",.string("relay")),("connectedAt",.number(5)),("sessionIds",.array([.string("s1")])),("sessions",.array([])),("tunnels",.array([]))])]))]),
        "remote:devices": remoteDevices,"remote:kinds":.array([S.o([("deviceId",.string("d-phone")),("kind",.string("mine")),("decidedAt",.number(1))])]),
        "remote:folders":.array([]),"remote:accounts":.array([]),"remote:sessions":.array([]),"remote:windows":.array([.string("d-phone")]),
        "remote:sessions:running":.array([S.o([("id",.string("s1")),("title",.string("build")),("cwd",.string("/work")),("provider",.string("claude")),("status",.string("working")),("exitCode",.null)])]),
        "power:lid-awake:get":S.o([("supported",.bool(true)),("on",.bool(false))]),"confine:state":S.o([("platform",.string("darwin")),("confining",.bool(true))]),
        "tailnet:status":.object([.init("running",.bool(false))]),"remote:pair":S.o([("token",.string("135790")),("expiresAt",.number(99)),("findable",.bool(true))])
    ] }
    static let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nTHE-ACTUAL-KEY-MATERIAL\n-----END OPENSSH PRIVATE KEY-----\n"
    static var serverAnswers: [String: V] { [
        "servers:list":.array([S.o([("id",.string("s1")),("name",.string("web-1")),("address",.string("10.0.0.5"))])]),
        "servers:keys":.array([S.o([("path",.string("/home/me/.ssh/id_ed25519")),("name",.string("id_ed25519")),("what",.string("A key made by OpenSSH")),("locked",.bool(false))])]),
        "servers:key-read":S.o([("ok",.bool(true)),("key",.string(privateKey))]),"servers:add":S.o([("ok",.bool(true)),("id",.string("s2")),("savedSignIn",.bool(true)),("note",.string(""))]),
        "servers:shell:write":.object([.init("written",.bool(true))]),"servers:shell:open":S.o([("ok",.bool(true)),("shellId",.string("s1 fresh"))]),"servers:shell:close":.object([.init("closed",.bool(true))])
    ] }
    static func servers(_ channels: BackendDeckCoreTestPortSessionsChannels) -> BackendDeckToolsMachinesServers { .init(channels:channels,shells:BackendDeckCoreTestPortSessionsShells(),dataRoot:URL(fileURLWithPath:"/fixture/data"),home:URL(fileURLWithPath:"/home/me")) }
}
