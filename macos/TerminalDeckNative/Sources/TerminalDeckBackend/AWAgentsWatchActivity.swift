import Foundation
import TerminalDeckNativeCore

/// An in-memory display receipt, not another hook reader or session store.
/// The existing hook owner calls accept ONLY after peer/session validation.
public actor AWAgentsWatchActivity {
    private struct Receipt { let tool: String; let at: Double }
    private var current: [String: Receipt] = [:]
    private let changed: @Sendable () async -> Void
    public init(changed: @escaping @Sendable () async -> Void = {}) { self.changed = changed }
    public func accept(_ event: BackendSessionHookEvent) async {
        guard let id = event.sessionID else { return }
        switch event.event {
        case "PreToolUse", "BeforeTool":
            guard let tool = event.toolName else { return }
            if current.count >= 256, current[id] == nil, let oldest = current.min(by: { $0.value.at < $1.value.at })?.key { current[oldest] = nil }
            current[id] = Receipt(tool: tool, at: event.receivedAt.timeIntervalSince1970 * 1000)
        case "PostToolUse", "PostToolUseFailure", "AfterTool", "PermissionRequest", "Stop", "StopFailure", "AfterAgent", "SessionEnd":
            current[id] = nil
        default: return
        }
        await changed()
    }
    public func remove(_ id: String) async { current[id] = nil; await changed() }
    public func stop() { current.removeAll() }
    public func decorate(_ sessions: [NativeRPCValue]) -> [NativeRPCValue] {
        sessions.map { session in
            guard let id = session["id"].string, let receipt = current[id] else { return session }
            return session.setting("currentTool", .string(receipt.tool)).setting("updatedAt", .number(receipt.at))
        }
    }
}
