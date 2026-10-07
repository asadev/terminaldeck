import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreSecurityConsentRequest: Sendable {
    public let id: String
    public let tool: String
    public let tier: BackendMCPTier
    public let summary: String
    public let arguments: NativeRPCValue
    public let requestedAt: Double
    public let expiresAt: Double
    public let origin: String
    public let label: String?
    public let askedBy: String?
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("tool", .string(tool)), .init("tier", .string(tier.rawValue)), .init("summary", .string(summary)),
                 .init("args", arguments), .init("requestedAt", .number(requestedAt)), .init("expiresAt", .number(expiresAt)), .init("origin", .string(origin)),
                 .init("label", label.map(NativeRPCValue.string) ?? .missing), .init("askedBy", askedBy.map(NativeRPCValue.string) ?? .missing)])
    }
}
public struct BackendDeckCoreSecurityConsentOutcome: Sendable {
    public let granted: Bool
    public let reason: BackendDeckCoreSecurityRefusalReason?
    public let by: String?
    public let at: Double
    public var wireValue: NativeRPCValue {
        var value = NativeRPCValue.object([.init("granted", .bool(granted)), .init("by", by.map(NativeRPCValue.string) ?? .null), .init("at", .number(at))])
        if let reason { value = value.setting("reason", .string(reason.rawValue)) }; return value
    }
}

/// Default-deny broker; app/remote adapters authenticate the answering surface.
public actor BackendDeckCoreSecurityConsentBroker {
    public static let defaultTimeoutMilliseconds = 120_000
    public static let outsideAppTimeoutMilliseconds = 45_000
    public static let defaultMaximumPending = 3
    public typealias Ask = @Sendable (BackendDeckCoreSecurityConsentRequest) async throws -> Bool
    public typealias Settled = @Sendable (String, BackendDeckCoreSecurityConsentOutcome) async throws -> Void
    private struct Pending {
        let question: BackendDeckCoreSecurityConsentRequest
        let continuation: CheckedContinuation<BackendDeckCoreSecurityConsentOutcome, Never>
        let cancellation: BackendMCPCancellation?
        var observer: UUID?
        var timer: Task<Void, Never>?
        var scheduled: UUID?
    }
    private let ask: Ask
    private let settled: Settled?
    private let timeoutMilliseconds: Int
    private let maximumPending: Int
    private let now: @Sendable () -> Double
    private let clock: (any BackendDeckCoreEventsClock)?
    private var pending: [String: Pending] = [:]
    private var order: [String] = []
    private var stopped = false
    public init(timeoutMilliseconds: Int = defaultTimeoutMilliseconds, maximumPending: Int = defaultMaximumPending,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                clock: (any BackendDeckCoreEventsClock)? = nil,
                ask: @escaping Ask, settled: Settled? = nil) {
        self.timeoutMilliseconds = max(1, timeoutMilliseconds); self.maximumPending = max(1, maximumPending)
        if let clock { self.now = { clock.now() } } else { self.now = now }
        self.clock = clock; self.ask = ask; self.settled = settled
    }
    public func list() -> [BackendDeckCoreSecurityConsentRequest] { order.compactMap { pending[$0]?.question } }
    public func request(tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue,
                        cancellation: BackendMCPCancellation? = nil, origin: String = "window",
                        label: String? = nil, askedBy: String? = nil, timeoutMilliseconds: Int? = nil) async -> BackendDeckCoreSecurityConsentOutcome {
        let at = now()
        if stopped { return deny(.shuttingDown, at: at) }
        if cancellation?.isCancelled == true { return deny(.callerGone, at: at) }
        if pending.count >= maximumPending { return deny(.tooManyPending, at: at) }
        let wait = max(1, min(timeoutMilliseconds ?? self.timeoutMilliseconds, self.timeoutMilliseconds))
        let question = BackendDeckCoreSecurityConsentRequest(id: UUID().uuidString.lowercased(), tool: tool, tier: tier,
            summary: summary, arguments: arguments, requestedAt: at, expiresAt: at + Double(wait), origin: origin, label: label, askedBy: askedBy)
        return await withCheckedContinuation { continuation in
            pending[question.id] = Pending(question: question, continuation: continuation, cancellation: cancellation)
            order.append(question.id)
            if let cancellation {
                let id = cancellation.observe { [weak self] in Task { await self?.cancel(question.id) } }
                pending[question.id]?.observer = id
            }
            Task { await self.deliver(question, wait: wait) }
        }
    }
    private func deliver(_ question: BackendDeckCoreSecurityConsentRequest, wait: Int) async {
        guard let entry = pending[question.id] else { return }
        if entry.cancellation?.isCancelled == true { cancel(question.id); return }
        let delivered = (try? await ask(question)) == true
        guard pending[question.id] != nil else { return }
        guard delivered else { finish(question.id, outcome: deny(.noApprover), notify: false); return }
        if pending[question.id]?.cancellation?.isCancelled == true { cancel(question.id); return }
        let remaining = question.expiresAt - now()
        guard remaining > 0 else { expire(question.id); return }
        let delay = min(Double(wait), remaining)
        if let clock {
            pending[question.id]?.scheduled = clock.schedule(after: delay) { [weak self] in Task { await self?.expire(question.id) } }
            return
        }
        pending[question.id]?.timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000)) } catch { return }
            await self?.expire(question.id)
        }
    }
    public func respond(id: String, approved: Bool, by: String) -> Bool {
        guard let entry = pending[id], Self.mayAnswerFor(origin: entry.question.origin, by: by) else { return false }
        if entry.cancellation?.isCancelled == true { cancel(id); return false }
        let outcome = BackendDeckCoreSecurityConsentOutcome(granted: approved, reason: approved ? nil : .declined, by: by, at: now())
        finish(id, outcome: outcome); return true
    }
    public func mayAnswer(id: String, by: String) -> Bool { pending[id].map { Self.mayAnswerFor(origin: $0.question.origin, by: by) } ?? false }
    public func callerGone(_ surface: String) throws {
        guard surface != "window" else { throw NativeRPCError.invalidArguments("deck-control: use approverGone() for the window") }
        for id in order where pending[id]?.question.origin == surface { finish(id, outcome: deny(.callerGone)) }
    }
    public func approverGone() { for id in order { finish(id, outcome: deny(.approverGone)) } }
    public func stop() { stopped = true; for id in order { finish(id, outcome: deny(.shuttingDown)) } }
    private func cancel(_ id: String) { finish(id, outcome: deny(.callerGone)) }
    private func expire(_ id: String) { finish(id, outcome: deny(.timeout)) }
    private func deny(_ reason: BackendDeckCoreSecurityRefusalReason, at: Double? = nil) -> BackendDeckCoreSecurityConsentOutcome { .init(granted: false, reason: reason, by: nil, at: at ?? now()) }
    private func finish(_ id: String, outcome: BackendDeckCoreSecurityConsentOutcome, notify: Bool = true) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }; entry.timer?.cancel()
        if let scheduled = entry.scheduled { clock?.cancel(scheduled) }
        if let observer = entry.observer { entry.cancellation?.removeObserver(observer) }
        entry.continuation.resume(returning: outcome)
        if notify, let settled { Task { try? await settled(id, outcome) } }
    }
    public nonisolated static func mayAnswerFor(origin: String, by: String) -> Bool {
        by == "window" || by == origin || (origin.hasPrefix("key:") && origin.count > 4 && by.hasPrefix("device:"))
    }
}
