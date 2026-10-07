import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendSessionHookEvent: Sendable {
    public let provider: String
    public let event: String
    public let sessionID: String?
    public let cliSessionID: String?
    public let cwd: String?
    public let toolName: String?
    public let receivedAt: Date
    /// Internal bounded payload for actual usage/tool consumers, never included
    /// in a UI event or log. No process environment beyond config dirs is kept.
    public let payload: NativeRPCValue
    public let agentEnvironment: BackendAccountHookEvidence?
    public let peerPID: Int32
    public var metadata: NativeRPCValue {
        .object([.init("provider", .string(provider)), .init("event", .string(event)), .init("sessionId", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("cliSessionId", cliSessionID.map(NativeRPCValue.string) ?? .null), .init("cwd", cwd.map(NativeRPCValue.string) ?? .null),
            .init("toolName", toolName.map(NativeRPCValue.string) ?? .null), .init("receivedAt", .number(receivedAt.timeIntervalSince1970 * 1000))])
    }
    static func parse(provider: String, event: String, sessionID: String?, body: Data, environmentHeader: String?, peerPID: Int32) -> Self {
        let value = (try? NativeRPCValue.parseJSON(body, maximumBytes: 1024 * 1024)) ?? .object([])
        let payload = value.fields == nil ? NativeRPCValue.object([]) : value
        func nonempty(_ key: String) -> String? { payload[key].string.flatMap { $0.isEmpty ? nil : $0 } }
        var environment: BackendAccountHookEvidence?
        // TS hook-server.ts parseAgentEnv: only an object is a report; blank values are absent, the rest trimmed.
        func trimmed(_ value: NativeRPCValue) -> String? {
            value.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let header = environmentHeader, let bytes = Data(base64Encoded: header), bytes.count <= 64 * 1024,
           let raw = try? NativeRPCValue.parseJSON(bytes), raw.fields != nil, let key = BackendAccountProfile.configEnvironment(provider) {
            let vars = raw["vars"].fields != nil ? raw["vars"] : NativeRPCValue.object([])
            environment = BackendAccountHookEvidence(provider: provider, configDirectory: trimmed(vars[key]),
                home: trimmed(raw["home"]), environmentWasRead: raw["path"].bool == true)
        }
        return Self(provider: provider, event: event, sessionID: sessionID, cliSessionID: nonempty("session_id"),
            cwd: nonempty("cwd") ?? nonempty("workspace_dir"), toolName: nonempty("tool_name"), receivedAt: Date(), payload: payload, agentEnvironment: environment, peerPID: peerPID)
    }
}

public actor BackendSessionHookCoordinator {
    // nil only in the observer-only test seam below; production always has all three.
    private let lifecycle: BackendSessionLifecycleCoordinator?
    private let attribution: BackendAccountAttribution?
    private let ledger: BackendNativeLedger?
    private var listeners: [UUID: @Sendable (BackendSessionHookEvent) async -> Void] = [:]
    public init(lifecycle: BackendSessionLifecycleCoordinator, attribution: BackendAccountAttribution, ledger: BackendNativeLedger) {
        self.lifecycle = lifecycle; self.attribution = attribution; self.ledger = ledger
    }
    private init(observersOnly: Void) { lifecycle = nil; attribution = nil; ledger = nil }
    /// Test seam (REQ S5-1): no lifecycle/attribution/ledger, so `receive` skips
    /// the session bookkeeping and only calls the registered observers.
    static func observerOnlyForTesting() -> BackendSessionHookCoordinator { .init(observersOnly: ()) }
    public static let statuses: [String: [String: BackendSessionStatus]] = [
        "claude": ["SessionStart": .waiting, "UserPromptSubmit": .working, "PreToolUse": .working, "PostToolUse": .working,
                   "PostToolUseFailure": .working, "PermissionRequest": .input, "Notification": .input, "Stop": .completed, "StopFailure": .waiting, "SessionEnd": .exited],
        "codex": ["SessionStart": .waiting, "UserPromptSubmit": .working, "PreToolUse": .working, "PostToolUse": .working, "Stop": .completed],
        "gemini": ["SessionStart": .waiting, "BeforeAgent": .working, "BeforeTool": .working, "AfterTool": .working, "AfterAgent": .completed, "Notification": .input, "SessionEnd": .exited],
    ]
    @discardableResult
    public func observe(_ listener: @escaping @Sendable (BackendSessionHookEvent) async -> Void) -> UUID {
        let id = UUID(); listeners[id] = listener; return id
    }
    public func removeObserver(_ id: UUID) { listeners[id] = nil }
    public func receive(_ event: BackendSessionHookEvent) async {
        // External agent events remain available to the external-session/usage
        // domain without inventing a local PTY, account or process owner.
        if let lifecycle, let attribution, let ledger, let id = event.sessionID, let meta = lifecycle.manager.list().first(where: { $0.id == id }),
           (meta.provider == event.provider || meta.provider == "shell"), meta.exitCode == nil, let pid = lifecycle.manager.pidOf(id), Self.descendant(event.peerPID, root: pid) {
            let sidechain = event.payload["isSidechain"].bool == true || event.payload["is_sidechain"].bool == true
            let named = event.cliSessionID
            let matching = named == nil || meta.agentSessionId == nil || named == meta.agentSessionId
            if !sidechain && matching {
                await lifecycle.noteAgentObservation(sessionID: id, provider: event.provider, conversationID: named, ended: event.event == "SessionEnd")
                if let status = Self.statuses[event.provider]?[event.event] { await lifecycle.noteHookStatus(sessionID: id, status: meta.provider == "shell" && event.event == "SessionEnd" ? .waiting : status, receivedAt: event.receivedAt) }
                if let environment = event.agentEnvironment { await attribution.recordHook(sessionID: id, evidence: environment) }
                if event.event == "SessionStart", meta.provider != "shell", let named, named.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil {
                    lifecycle.manager.setAgentSessionId(id, conversationId: named)
                    try? await ledger.updateConversation(id, conversationID: named)
                }
                if ["UserPromptSubmit", "BeforeAgent"].contains(event.event) { try? await ledger.activity(id) }
                if event.event == "SessionEnd" { await attribution.drop(sessionID: id) }
            }
        }
        for listener in listeners.values { await listener(event) }
    }
    private static func descendant(_ peer: Int32, root: Int32) -> Bool {
        var current = peer, seen = Set<Int32>()
        for _ in 0..<64 {
            if current == root { return true }
            guard current > 1, seen.insert(current).inserted else { return false }
            var keys: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            let count = u_int(keys.count)
            var process = kinfo_proc(), length = MemoryLayout<kinfo_proc>.size
            guard sysctl(&keys, count, &process, &length, nil, 0) == 0, length > 0 else { return false }
            current = process.kp_eproc.e_ppid
        }
        return false
    }
    public func stop() { listeners.removeAll() }
}
