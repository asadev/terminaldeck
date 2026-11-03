import Foundation
import TerminalDeckNativeCore

/// L8 (10 Oct): an AI app's MCP client (Hoot's Claude Code among them) gives up on a tool call after about
/// 120 seconds and reports "timed out" even though the work went on and finished. A call that is still
/// running at the budget answers NOW with a "still running" handle instead; the work itself is never
/// cancelled by that answer and keeps going in the background. Tools that are made to wait (their own
/// timeout argument: sessions_wait, notifications_wait, ...) are never cut short.
public enum BackendMCPCallBudget {
    public static let seconds: Double = 100

    public static func exempt(name: String, arguments: NativeRPCValue) -> Bool {
        let inner = arguments["name"].string ?? ""
        return name.lowercased().contains("wait") || inner.lowercased().contains("wait")
    }

    /// The operation's value, or nil if it is still running after `seconds` (it then keeps running unobserved).
    public static func within<T: Sendable>(_ seconds: Double = seconds,
                                           _ operation: @escaping @Sendable () async -> T) async -> T? {
        let job = Task { await operation() }
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled, once.claim() { done.resume(returning: nil) }
            }
            Task {
                let value = await job.value
                timer.cancel()
                if once.claim() { done.resume(returning: value) }
            }
        }
    }

    /// The structured "still running" answer: a handle the caller can follow up on, never an error.
    public static func stillRunning(tool: String, arguments: NativeRPCValue, startedAt: Double) -> NativeRPCValue {
        let inner = arguments["name"].string
        let shown = inner.map { tool + " → " + $0 } ?? tool
        return .object([
            .init("stillRunning", .bool(true)),
            .init("tool", .string(inner ?? tool)),
            .init("startedAt", .number(startedAt)),
            .init("note", .string("\(shown) is still working after \(Int(seconds)) seconds, so this answer comes back now instead of timing out. "
                + "The work was NOT cancelled and keeps going in the background. Check its outcome before repeating it: "
                + "tasks_progress or tasks_state for tasks and goals, sessions_list or sessions_get for sessions.")),
        ])
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
