import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckToolsSessionsPortValues {
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    static func row(_ id: String = "s1", cwd: String = "/work/api", provider: String = "claude", exit: Double? = nil, created: Double = 1_000, resumed: Bool = false) -> NativeRPCValue {
        object([("id", .string(id)), ("cwd", .string(cwd)), ("title", .string(URL(fileURLWithPath: cwd).lastPathComponent)), ("provider", .string(provider)),
            ("createdAt", .number(created)), ("resumed", .bool(resumed)), ("exitCode", exit.map(NativeRPCValue.number) ?? .null), ("status", .string(exit == nil ? "waiting" : "exited")),
            ("attention", .string(exit == nil ? "quiet" : "done")), ("attentionReason", .string(exit == nil ? "prompt-ready" : "process-exited"))])
    }
    static func file(_ path: String, id: String = "c1", created: Double = 1_000, modified: Double = 2_000, bytes: Double = 1_000) -> NativeRPCValue {
        object([("path", .string(path)), ("sessionId", .string(id)), ("createdAt", .number(created)), ("modifiedAt", .number(modified)), ("bytes", .number(bytes))])
    }
    static func message(_ text: String, at: Double, role: String = "agent", id: String = "agent:1") -> NativeRPCValue { object([("id", .string(id)), ("role", .string(role)), ("at", .number(at)), ("text", .string(text)), ("truncated", .bool(false))]) }
    static func held(_ key: String, reason: String = "it could not be started") -> NativeRPCValue { object([("key", .string(key)), ("cwd", .string("/work/api")), ("provider", .string("claude")), ("profileId", .null), ("reason", .string(reason)), ("at", .number(1)), ("lastSeenAt", .number(1))]) }
    static func account(_ id: String = "work", name: String = "Work", provider: String = "claude") -> NativeRPCValue { object([("id", .string(id)), ("name", .string(name)), ("provider", .string(provider))]) }
    static func context(attended: Bool = true, sessionID: String = "caller") -> BackendMCPCallContext {
        .init(sessionID: sessionID, machineID: "", projectRoot: nil, attended: attended, allowedTools: Set(BackendDeckToolsSessionsCatalogue.entries.map(\.id)), allowedTiers: [.read, .act, .alter], cancellation: .init())
    }
    static func handler(_ id: String, in definitions: [BackendDeckToolsDefinition]) throws -> BackendNativeMCPServer.Handler {
        try XCTUnwrap(definitions.first { $0.spec.id == id }).handler
    }
    static func error(_ reply: BackendMCPToolReply) -> String { reply.structuredContent?["error"].string ?? reply.content.first?["text"].string ?? "" }
}

final class BackendDeckToolsSessionsPortClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: Double
    private var events: [Int] = []
    init(_ start: Double = 10_000) { time = start }
    var now: Double { lock.withLock { time } }
    var sleeps: [Int] { lock.withLock { events } }
    func advance(_ milliseconds: Int) { lock.withLock { time += Double(milliseconds); events.append(milliseconds) } }
    func clock(after: (@Sendable (Double) async throws -> Void)? = nil) -> BackendDeckToolsSessionsClock {
        .init(now: { self.now }, sleep: { milliseconds in self.advance(milliseconds); try await after?(self.now) })
    }
}

/// One domain fake shared by uncovered handler tests. Only actual area factories
/// are under test; this fake records calls and supplies the same fixture facts
/// as the TS tests. It contains no duplicated tool parsing/gating implementation.
actor BackendDeckToolsSessionsPortRig: BackendDeckToolsSessionsRuntime, BackendDeckToolsSessionsSurface, BackendDeckToolsSessionsLiftRequests {
    typealias V = BackendDeckToolsSessionsPortValues
    var rows = [V.row(), V.row("s2", cwd: "/work/web")]
    var own = Set<String>(), gates: [(BackendMCPTier, String, NativeRPCValue)] = [], calls: [(String, NativeRPCValue)] = [], noted: [String] = []
    var callerIdentity = BackendDeckToolsSessionsCaller(kind: .local, callID: "call-1"), allowedFolders: Set<String> = ["/work/api", "/work/web"], grantedDeviceFolders: [String]? = ["/work/web"]
    var signals: [String: NativeRPCValue] = [:], screens: [String: String] = [:], files: [String: [NativeRPCValue]] = [:], messages: [String: [NativeRPCValue]] = [:], bytes: [String: Int] = [:]
    var heldRows = [V.held("k1"), V.held("k2")], retryRows: [NativeRPCValue] = [], retryStarted: [NativeRPCValue] = []
    var accountRows = [V.account("system:claude", name: "Personal"), V.account("p-work"), V.account("p-codex", name: "Codex work", provider: "codex")]
    var switchedRow = V.row("s1-as-p-work"), renameMissing = false
    var liftAnswer: NativeRPCValue?, slots: [String] = []
    func setRows(_ value: [NativeRPCValue]) { rows = value }
    func setOwn(_ value: Set<String>) { own = value }
    func setCaller(_ value: BackendDeckToolsSessionsCaller) { callerIdentity = value }
    func setDeviceFolders(_ value: [String]?) { grantedDeviceFolders = value }
    func setSignal(_ id: String = "s1", status: String, at: Double) { signals[id] = V.object([("status", .string(status)), ("at", .number(at))]) }
    func setScreen(_ text: String, id: String = "s1") { screens[id] = text }
    func setFiles(_ value: [NativeRPCValue], cwd: String = "/work/api") { files[cwd] = value }
    func setMessages(_ path: String, _ value: [NativeRPCValue], bytes: Int = 1_000) { messages[path] = value; self.bytes[path] = bytes }
    func setRetry(held: [NativeRPCValue], started: [NativeRPCValue] = []) { retryRows = held; retryStarted = started }
    func setHeld(_ value: [NativeRPCValue]) { heldRows = value }
    func setSwitched(_ value: NativeRPCValue) { switchedRow = value }
    func setAccounts(_ value: [NativeRPCValue]) { accountRows = value }
    func setLiftAnswer(_ value: NativeRPCValue) { liftAnswer = value }
    func setSlots(_ value: [String]) { slots = value }
    func log(_ method: String, _ value: NativeRPCValue = .null) { calls.append((method, value)) }
    func captured(_ method: String) -> [NativeRPCValue] { calls.filter { $0.0 == method }.map(\.1) }
    func caller(_ context: BackendMCPCallContext) -> BackendDeckToolsSessionsCaller { callerIdentity }
    func sessions(_ context: BackendMCPCallContext) -> [NativeRPCValue] {
        rows.map { row in
            let id = row["id"].string ?? "", exit = row["exitCode"].number.map(Int.init)
            let live = signals[id], status = BackendDeckCoreAttention.status(exitCode: exit, live: live?["status"].string)
            return row.setting("status", .string(status)).merging(BackendDeckCoreAttention.view(status: status, statusSince: live?["at"].number ?? row["createdAt"].number, exitCode: exit, now: live?["at"].number ?? 10_000))
        }
    }
    func knownFolders(_ context: BackendMCPCallContext) -> Set<String> { allowedFolders }
    func deviceFolders(deviceID: String, context: BackendMCPCallContext) -> [String]? { grantedDeviceFolders }
    func startedByCaller(sessionID: String, context: BackendMCPCallContext) -> Bool { own.contains(sessionID) }
    func noteStarted(sessionID: String, context: BackendMCPCallContext) { own.insert(sessionID); noted.append(sessionID) }
    func authorize(tool: BackendMCPTool, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue, context: BackendMCPCallContext) { gates.append((tier, summary, arguments)) }
    func recordResult(toolID: String, summary: NativeRPCValue, context: BackendMCPCallContext) { log("result:" + toolID, summary) }
    func browserSlots(sessionID: String, machineID: String, context: BackendMCPCallContext) -> [String] { slots }
    func status(sessionID: String, context: BackendMCPCallContext) -> NativeRPCValue? { signals[sessionID] }
    func screen(sessionID: String, context: BackendMCPCallContext) -> String? { screens[sessionID] }
    func write(sessionID: String, data: String, context: BackendMCPCallContext) { log("write", V.object([("sessionId", .string(sessionID)), ("data", .string(data))])) }
    func rename(sessionID: String, title: String, context: BackendMCPCallContext) -> String? { log("rename", V.object([("id", .string(sessionID)), ("title", .string(title))])); return renameMissing ? nil : title.isEmpty ? "api" : title }
    func held(context: BackendMCPCallContext) -> [NativeRPCValue] { heldRows }
    func retryHeld(key: String, context: BackendMCPCallContext) -> [NativeRPCValue] { log("retry", .string(key)); rows += retryStarted; heldRows = retryRows; return retryRows }
    func forgetHeld(key: String, context: BackendMCPCallContext) -> [NativeRPCValue] { log("forget", .string(key)); heldRows.removeAll { $0["key"].string == key }; return heldRows }
    func account(sessionID: String, context: BackendMCPCallContext) -> NativeRPCValue { V.object([("kind", .string("known")), ("profileName", .string("account of " + sessionID))]) }
    func limits(sessionID: String, context: BackendMCPCallContext) -> NativeRPCValue { V.object([("limits", .array([]))]) }
    func accountPlan(sessionID: String, profileID: String, context: BackendMCPCallContext) -> NativeRPCValue { log("plan", .string(profileID)); return V.object([("sessionId", .string(sessionID)), ("refusal", .null), ("from", .null), ("to", V.account(profileID)), ("conversation", .string("follows")), ("resume", .bool(true))]) }
    func switchAccount(sessionID: String, profileID: String, context: BackendMCPCallContext) -> NativeRPCValue { log("switch", V.object([("sessionId", .string(sessionID)), ("profileId", .string(profileID))])); return switchedRow }
    func switchLater(sessionID: String, profileID: String, context: BackendMCPCallContext) -> NativeRPCValue { V.object([("sessionId", .string(sessionID)), ("profileId", .string(profileID)), ("note", .string("later"))]) }
    func cancelSwitch(sessionID: String, context: BackendMCPCallContext) -> Bool { true }
    func armedSwitches(context: BackendMCPCallContext) -> [NativeRPCValue] { [] }
    func accounts(context: BackendMCPCallContext) -> [NativeRPCValue] { accountRows }
    func search(request: NativeRPCValue, context: BackendMCPCallContext) -> NativeRPCValue { log("search", request); return V.object([("ok", .bool(true)), ("hits", .array([V.object([("snippet", .string("x"))])]))]) }
    func insights(transcriptPath: String, context: BackendMCPCallContext) -> NativeRPCValue { V.object([("requests", .number(3)), ("timeline", .array([.number(1)])), ("contextSeries", .array([.number(1)])), ("heaviest", .array((1...7).map { .number(Double($0)) })), ("compactions", .array([.null, .null]))]) }
    func transcripts(cwd: String, context: BackendMCPCallContext) -> [NativeRPCValue] { files[cwd] ?? [] }
    func transcriptBytes(path: String, context: BackendMCPCallContext) -> Int { bytes[path] ?? 1_000 }
    func transcriptMessages(path: String, fromByte: Int, context: BackendMCPCallContext) -> [NativeRPCValue] { log("transcript", V.object([("path", .string(path)), ("fromByte", .number(Double(fromByte)))])); return messages[path] ?? [] }
    func start(input: BackendCreateSessionInput, deviceID: String?, context: BackendMCPCallContext) throws -> NativeRPCValue {
        let captured = try NativeRPCValue.parseJSON(JSONEncoder().encode(input))
        log("start", V.object([("input", captured), ("device", deviceID.map(NativeRPCValue.string) ?? .missing)]))
        let result = V.row("started-\(capturedCount("start"))", cwd: input.cwd, provider: input.provider ?? "claude")
        rows.append(result); return result
    }
    private func capturedCount(_ method: String) -> Int { calls.filter { $0.0 == method }.count }
    func file(askedBy: String, from: String, into: [String], reason: NativeRPCValue, context: BackendMCPCallContext) throws -> NativeRPCValue {
        log("lift", V.object([("askedBy", .string(askedBy)), ("from", .string(from)), ("into", .array(into.map(NativeRPCValue.string))), ("reason", reason)]))
        guard let liftAnswer else { throw BackendDeckToolsSupport.unavailable("The lift fixture result") }; return liftAnswer
    }
}
