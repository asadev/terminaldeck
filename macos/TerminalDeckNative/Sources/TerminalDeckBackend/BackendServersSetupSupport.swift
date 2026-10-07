import Foundation
import TerminalDeckNativeCore

public enum BackendServersSetupFailure: Error, LocalizedError, Sendable {
    case unavailable(String), invalid(String)
    public var errorDescription: String? { switch self { case .unavailable(let s), .invalid(let s): s } }
}

/// A flow owns this subscription before it writes its first command. Keeping
/// one tape prevents a fingerprint/verdict printed during redemption being lost.
final class BackendServersSetupTape: @unchecked Sendable {
    private struct Waiter {
        let pattern: String
        let continuation: CheckedContinuation<String?, Never>
        var timer: Task<Void, Never>?
    }
    private let lock = NSLock()
    private var seen = ""
    private var waiters: [UUID: Waiter] = [:]
    private var subscriptions: [BackendServersUnsubscribe] = []
    private var closed = false
    init(_ shell: any BackendServersShell) {
        let output = shell.onData { [weak self] chunk in self?.append(chunk) }
        let end = shell.onClose { [weak self] in self?.close() }
        let kept = lock.withLock { () -> Bool in
            guard !closed else { return false }; subscriptions = [output, end]; return true
        }
        if !kept { output(); end() }
    }
    private func append(_ chunk: String) {
        let ready: [(Waiter, String)] = lock.withLock {
            guard !closed else { return [] }
            seen += chunk
            // Scope, rather than a byte cap, bounds the source tape: a
            // fingerprint printed during redemption must remain available.
            var ready: [(Waiter, String)] = []
            for (id, waiter) in waiters {
                if let value = Self.capture(waiter.pattern, seen) { ready.append((waiter, value)); waiters[id] = nil }
            }
            return ready
        }
        for (waiter, value) in ready { waiter.timer?.cancel(); waiter.continuation.resume(returning: value) }
    }
    static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
        return String(text[range])
    }
    func snapshot() -> String { lock.withLock { seen } }
    func forget() { lock.withLock { seen = "" } }
    func next(_ pattern: String, milliseconds: Int) async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let initial: (Bool, String?) = lock.withLock {
                    if Task.isCancelled { return (true, nil) }
                    if let value = Self.capture(pattern, seen) { return (true, value) }
                    if closed { return (true, nil) }
                    waiters[id] = Waiter(pattern: pattern, continuation: continuation)
                    return (false, nil)
                }
                if initial.0 { continuation.resume(returning: initial.1); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(max(0, milliseconds))) }
                    catch { return }
                    self?.settle(id)
                }
                let stored = lock.withLock { () -> Bool in
                    guard var waiter = waiters[id] else { return false }
                    waiter.timer = timer; waiters[id] = waiter; return true
                }
                if !stored { timer.cancel() }
            }
        } onCancel: { self.settle(id) }
    }
    private func settle(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.timer?.cancel(); waiter?.continuation.resume(returning: nil)
    }
    func cancelWaits() {
        let pending = lock.withLock { let values = Array(waiters.values); waiters.removeAll(); return values }
        for waiter in pending { waiter.timer?.cancel(); waiter.continuation.resume(returning: nil) }
    }
    func close() {
        let stops = lock.withLock { () -> [BackendServersUnsubscribe] in
            guard !closed else { return [] }; closed = true; let stops = subscriptions; subscriptions.removeAll(); return stops
        }
        for stop in stops { stop() }; cancelWaits()
    }
    deinit { close() }
}

/// Cancellation interrupts the same visible PTY and immediately ends native
/// waits. No process hunting, credential reading or second shell is involved.
final class BackendServersSetupAttempt: @unchecked Sendable {
    let id = UUID()
    let serverId: String
    let agentId: BackendServersAgentID?
    private let lock = NSLock()
    private var interrupted = false
    private var stopCommand: (@Sendable () -> Void)?
    private var wake: (@Sendable () -> Void)?
    private var undo: [@Sendable () async -> Void] = []
    init(serverId: String, agentId: BackendServersAgentID? = nil) { self.serverId = serverId; self.agentId = agentId }
    var cancelled: Bool { lock.withLock { interrupted } }
    func setStop(_ body: (@Sendable () -> Void)?) { lock.withLock { stopCommand = body } }
    func setWake(_ body: (@Sendable () -> Void)?) { lock.withLock { wake = body } }
    func addUndo(_ body: @escaping @Sendable () async -> Void) { lock.withLock { undo.append(body) } }
    func clean(interrupt: Bool = true, markCancelled: Bool = true) async {
        let steps = lock.withLock { () -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?, [@Sendable () async -> Void]) in
            if interrupt && markCancelled { interrupted = true }
            let out = (stopCommand, wake, Array(undo.reversed()))
            stopCommand = nil; wake = nil; undo.removeAll(); return out
        }
        if interrupt { steps.0?() }; steps.1?()
        for step in steps.2 { await step() }
    }
}

enum BackendServersSetupWire {
    static func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func capture(_ pattern: String, _ text: String) -> String? { BackendServersSetupTape.capture(pattern, text) }
}
