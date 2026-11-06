import Foundation
import TerminalDeckNativeCore

/// XPC cancellation reaches the task handling this exact request, including a forwarded password request.
public final class BackendMacReachRequest: NSObject, BackendMacReachRPC, @unchecked Sendable {
    private struct Work {
        let attempt: BackendMacSignInAttempt
        let password: Bool
        var task: Task<Void, Never>?
    }
    private let lock = NSLock()
    private var work: [String: Work] = [:]
    private var cancelled: [String] = []
    private let handler: @Sendable (String, Data) async throws -> Data
    public init(handler: @escaping @Sendable (String, Data) async throws -> Data) { self.handler = handler }
    public func request(_ command: String, id: String, payload: Data, reply: @escaping (Data?, String?) -> Void) {
        let answer = Answer(reply), password = command == "password"
        let expiry = password ? (try? NativeRPCValue.parseJSON(payload)["expiresAt"].number) : nil
        let attempt = BackendMacSignInAttempt(expiresAt: expiry ?? (password ? 0 : ProcessInfo.processInfo.systemUptime + 2))
        let changesScreen = !["frame", "rows", "status", "cursor", "close"].contains(command)
        let admitted = lock.withLock {
            guard !cancelled.contains(id), work[id] == nil,
                  !password || work.isEmpty,
                  !changesScreen || !work.values.contains(where: { $0.password }) else { return false }
            work[id] = Work(attempt: attempt, password: password)
            return true
        }
        guard admitted else { answer.send(nil, BackendMacSignInAttempt.failureWords); return }
        let task = Task {
            defer { _ = lock.withLock { work.removeValue(forKey: id) } }
            do {
                try Task.checkCancellation()
                if password { try attempt.check() }
                let data = try await BackendMacSignInAttempt.$current.withValue(password ? attempt : nil) {
                    try await handler(command, payload)
                }
                answer.send(data, nil)
            } catch { answer.send(nil, password ? BackendMacSignInAttempt.failureWords : (error as? NativeRPCError)?.message ?? "The Mac screen connection could not answer.") }
        }
        lock.withLock {
            if work[id] != nil { work[id]?.task = task } else { task.cancel() }
            if cancelled.contains(id) { attempt.cancel(); task.cancel() }
        }
    }
    public func cancel(_ id: String) {
        let current = lock.withLock {
            // A cancellation can overtake dispatch on XPC's receive queue. Remember it briefly without a payload.
            cancelled.append(id)
            if cancelled.count > 512 { cancelled.removeFirst(cancelled.count - 512) }
            return work[id]
        }
        current?.attempt.cancel(); current?.task?.cancel()
    }
    public func cancelAll() {
        let current = lock.withLock { Array(work.values) }
        for item in current { item.attempt.cancel(); item.task?.cancel() }
    }
    private final class Answer: @unchecked Sendable {
        let reply: (Data?, String?) -> Void
        init(_ reply: @escaping (Data?, String?) -> Void) { self.reply = reply }
        func send(_ data: Data?, _ problem: String?) { reply(data, problem) }
    }
}
