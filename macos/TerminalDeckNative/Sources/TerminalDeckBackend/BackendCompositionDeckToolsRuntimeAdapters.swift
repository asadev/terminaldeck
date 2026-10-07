import Foundation
import TerminalDeckNativeCore

/// `BackendDeckToolsFilesRuntime` for the files and projects factories
/// (files-tools.ts / project-tools.ts deps in sessions-lane.ts).
public struct BackendCompositionDeckToolsFilesRuntime: BackendDeckToolsFilesRuntime {
    private let scope: BackendCompositionDeckToolsScope
    private let restore: BackendSessionRestoreContext
    /// `restoreContext` is the app's one resolver of a device session's actual
    /// grant and confinement (the same one session restore uses).
    public init(scope: BackendCompositionDeckToolsScope, restoreContext: BackendSessionRestoreContext) {
        self.scope = scope; restore = restoreContext
    }
    /// The caller's own NativeRPCContext: its real filesystem limits, never the app owner's.
    public func rpc(_ caller: BackendMCPCallContext) async throws -> NativeRPCContext { try await scope.gate.authority.rpc(caller) }
    public func knownFolder(_ path: String, caller: BackendMCPCallContext) async throws -> String { try await scope.knownFolder(path, native: caller) }
    public func requireSession(_ id: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await scope.session(id, native: caller) }
    /// deck-tools-HANDOFF item 5: this caller's own starter bucket in core.
    public func startedByCopilot(_ id: String, caller: BackendMCPCallContext) async throws -> Bool {
        try await scope.resolve(caller).startedByCopilot(id)
    }
    /// session-boundary.ts boundaryFor: what a held (device) session is confined
    /// to, or nil for a session held inside nothing. Only reached after
    /// `requireSession` admitted the session for this caller.
    public func boundary(_ id: String) async throws -> BackendDeviceBoundary? {
        let saved = try await scope.gate.authority.state.store.ledgerGet(id)
        guard !saved.isNullish else { return nil }
        return try await restore.context(for: BackendSessionSaved(saved)).deviceBoundary
    }
    /// files-tools.ts: files.upload and sessions.attach are `act` at their floor,
    /// whatever a path-less escalation suggested; the gate only ever raises.
    public func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier,
                          summary: String, arguments: NativeRPCValue) async throws {
        let floored: BackendMCPTier = ["files.upload", "sessions.attach"].contains(tool) && tier == .read ? .act : tier
        try await scope.gate.authorize(caller, floored, summary, false)
    }
    public func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {
        await scope.gate.noteResult(caller, summary)
    }
}

/// `BackendDeckToolsAssetRuntime` (asset-tools.ts): real caller kind, the one
/// gate, the source clock. A paired device is refused before any consent.
public struct BackendCompositionDeckToolsAssetRuntime: BackendDeckToolsAssetRuntime {
    private let gate: BackendCompositionDeckToolsGate
    private let clock: @Sendable () -> Double
    public init(gate: BackendCompositionDeckToolsGate,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.gate = gate; clock = now
    }
    public func now() -> Double { clock() }
    public func callerKind(_ caller: BackendMCPCallContext) async throws -> String {
        try await gate.authority.resolve(caller).caller.kind.rawValue
    }
    public func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier,
                          summary: String, arguments: NativeRPCValue) async throws {
        // Attendance never implies the owner; only the credential's kind counts.
        guard try await gate.authority.resolve(caller).caller.kind != .remote else {
            throw NativeRPCError(code: "not-granted", message: "\(tool) works on files and folders on this machine, so it only runs for something on it. A paired device cannot call it.")
        }
        try await gate.authorize(caller, tier, summary, false)
    }
    public func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {
        await gate.noteResult(caller, summary)
    }
}

/// `BackendDeckToolsTourRuntime` (tour-tool.ts): authenticated caller kind, the
/// person's `copilot.interactive` setting, the one gate, and the core evidence.
public struct BackendCompositionDeckToolsTourRuntime: BackendDeckToolsTourRuntime {
    /// tour-tool.ts INTERACTIVE_KEY (L97).
    public static let interactiveKey = "copilot.interactive"
    private let gate: BackendCompositionDeckToolsGate
    private let evidence: any BackendDeckToolsTourEvidence
    /// `evidence`: the one `BackendDeckToolsTourNativeEvidence` over core's surface.
    public init(gate: BackendCompositionDeckToolsGate, evidence: any BackendDeckToolsTourEvidence) {
        self.gate = gate; self.evidence = evidence
    }
    public func callerKind(_ context: BackendMCPCallContext) async throws -> String {
        try await gate.authority.resolve(context).caller.kind.rawValue
    }
    /// The raw stored value: anything but an explicit false is on (interactiveDriving, L99-105).
    public func interactiveSetting() async throws -> NativeRPCValue {
        await gate.authority.state.settings.value(Self.interactiveKey)
    }
    public func authorize(_ context: BackendMCPCallContext, tier: BackendMCPTier, summary: String) async throws {
        try await gate.authorize(context, tier, summary, false)
    }
    public func completed(_ context: BackendMCPCallContext, summary: NativeRPCValue) async throws {
        await gate.noteResult(context, summary)
    }
    public func facts(sessionID: String) async throws -> NativeRPCValue? { try await evidence.facts(sessionID: sessionID) }
    public func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool {
        try await evidence.supports(reason: reason, importance: importance, median: median, sample: sample)
    }
}
