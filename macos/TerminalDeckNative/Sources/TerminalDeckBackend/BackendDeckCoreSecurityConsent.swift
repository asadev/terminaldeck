import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreSecurityConsentRequest: Sendable {
    public let id: String
    public let tool: String
    public let tier: BackendMCPTier
    public var summary: String
    public var arguments: NativeRPCValue
    public let requestedAt: Double
    public var expiresAt: Double
    public let origin: String
    public let label: String?
    public let askedBy: String?
    public var profileBatch: BackendTAGProfileConsentBatch? = nil
    public var wireValue: NativeRPCValue {
        var value = NativeRPCValue.object([.init("id", .string(id)), .init("tool", .string(tool)), .init("tier", .string(tier.rawValue)), .init("summary", .string(summary)),
                 .init("args", arguments), .init("requestedAt", .number(requestedAt)), .init("expiresAt", .number(expiresAt)), .init("origin", .string(origin)),
                 .init("label", label.map(NativeRPCValue.string) ?? .missing), .init("askedBy", askedBy.map(NativeRPCValue.string) ?? .missing)])
        if let profileBatch { value = value.setting("profileBatch", profileBatch.wireValue) }
        return value
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
    private struct Subscriber {
        let continuation: CheckedContinuation<BackendDeckCoreSecurityConsentOutcome, Never>
        let cancellation: BackendMCPCancellation?
        var observer: UUID?
        let items: [String]
    }
    private struct Pending {
        var question: BackendDeckCoreSecurityConsentRequest
        var subscribers: [UUID: Subscriber]
        var subscribersOrder: [UUID]
        let wait: Int
        var revision = 1
        var delivering = false
        var timer: Task<Void, Never>?
        var scheduled: UUID?
    }
    private struct Receipt {
        let id: String, by: String
        let expiresAt: Double
        var batch: BackendTAGProfileConsentBatch
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
    private var ownerActive = false
    private var profileReceipts: [String: Receipt] = [:]
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
                        label: String? = nil, askedBy: String? = nil, timeoutMilliseconds: Int? = nil,
                        profileBatch: BackendTAGProfileConsentBatch? = nil) async -> BackendDeckCoreSecurityConsentOutcome {
        let at = now()
        if stopped { return deny(.shuttingDown, at: at) }
        if cancellation?.isCancelled == true { return deny(.callerGone, at: at) }
        if let profileBatch, origin != "key:" + profileBatch.keyID { return deny(.notPermitted, at: at) }
        profileReceipts = profileReceipts.filter { $0.value.expiresAt > at }
        if let profileBatch, var receipt = profileReceipts[groupKey(profileBatch)] {
            receipt.batch.append(profileBatch.items); profileReceipts[groupKey(profileBatch)] = receipt
            return .init(granted: true, reason: nil, by: receipt.by, at: at)
        }
        let joined = profileBatch.flatMap { batch in order.first { pending[$0]?.question.profileBatch.map { groupKey($0) == groupKey(batch) } == true } }
        if joined == nil, pending.count >= maximumPending { return deny(.tooManyPending, at: at) }
        let wait = max(1, min(timeoutMilliseconds ?? self.timeoutMilliseconds, self.timeoutMilliseconds))
        var descriptor = profileBatch; descriptor?.waitsWhileOwnerActive = ownerActive
        let question = BackendDeckCoreSecurityConsentRequest(id: joined ?? UUID().uuidString.lowercased(), tool: tool, tier: tier,
            summary: summary, arguments: arguments, requestedAt: at, expiresAt: at + Double(wait), origin: origin, label: label, askedBy: askedBy)
        let token = UUID()
        return await withCheckedContinuation { continuation in
            if var existing = pending[question.id] {
                existing.subscribers[token] = Subscriber(continuation: continuation, cancellation: cancellation, items: profileBatch?.items ?? [])
                existing.subscribersOrder.append(token)
                existing.question.profileBatch?.append(profileBatch?.items ?? [])
                existing.question.summary = existing.question.profileBatch?.summary ?? existing.question.summary
                existing.revision += 1
                pending[question.id] = existing
            } else {
                var fresh = question; fresh.profileBatch = descriptor
                fresh.summary = descriptor?.summary ?? summary
                pending[question.id] = Pending(question: fresh, subscribers: [token: Subscriber(continuation: continuation, cancellation: cancellation, items: descriptor?.items ?? [])], subscribersOrder: [token], wait: wait)
                order.append(question.id)
            }
            if let cancellation {
                let observer = cancellation.observe { [weak self] in Task { await self?.cancel(question.id, subscriber: token) } }
                pending[question.id]?.subscribers[token]?.observer = observer
            }
            queueDelivery(question.id)
        }
    }
    private func queueDelivery(_ id: String) {
        guard var entry = pending[id], !entry.delivering else { return }
        entry.delivering = true; pending[id] = entry
        Task { await self.deliver(id) }
    }
    private func deliver(_ id: String) async {
        while let entry = pending[id] {
            guard entry.subscribers.values.contains(where: { $0.cancellation?.isCancelled != true }) else { finish(id, outcome: deny(.callerGone)); return }
            let delivered = (try? await ask(entry.question)) == true
            guard var current = pending[id] else { return }
            guard delivered else { finish(id, outcome: deny(.noApprover), notify: false); return }
            if current.revision != entry.revision { continue }
            current.delivering = false; pending[id] = current
            break
        }
        guard let entry = pending[id] else { return }; let question = entry.question
        if waitsForActiveOwner(entry) { return }
        guard pending[id]?.scheduled == nil, pending[id]?.timer == nil else { return }
        let remaining = question.expiresAt - now()
        guard remaining > 0 else { expire(question.id); return }
        let delay = min(Double(entry.wait), remaining)
        if let clock {
            pending[question.id]?.scheduled = clock.schedule(after: delay) { [weak self] in Task { await self?.expire(question.id) } }
            return
        }
        pending[question.id]?.timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000)) } catch { return }
            await self?.expire(question.id)
        }
    }
    public func respond(id: String, approved: Bool, by: String, allowKindMinutes: Int? = nil) -> Bool {
        guard let entry = pending[id], Self.mayAnswerFor(origin: entry.question.origin, by: by) else { return false }
        guard waitsForActiveOwner(entry) || entry.question.expiresAt > now() else { expire(id); return false }
        guard entry.subscribers.values.contains(where: { $0.cancellation?.isCancelled != true }) else { finish(id, outcome: deny(.callerGone)); return false }
        if entry.question.tool == "access.request_scope" || entry.question.profileBatch != nil, by != "window", !by.hasPrefix("device:") { return false }
        if let allowKindMinutes, allowKindMinutes != 10 || entry.question.profileBatch == nil { return false }
        var approver = by
        if approved, let batch = entry.question.profileBatch {
            let duration = allowKindMinutes == 10 ? BackendTAGProfileConsent.kindMilliseconds : BackendTAGProfileConsent.shortBatchMilliseconds
            approver = "\(allowKindMinutes == 10 ? "kind" : "batch"):\(id):\(by)"
            profileReceipts[groupKey(batch)] = Receipt(id: id, by: approver, expiresAt: now() + duration, batch: batch)
        }
        let outcome = BackendDeckCoreSecurityConsentOutcome(granted: approved, reason: approved ? nil : .declined, by: approver, at: now())
        finish(id, outcome: outcome); return true
    }
    public func mayAnswer(id: String, by: String) -> Bool {
        pending[id].map { question in
            (waitsForActiveOwner(question) || question.question.expiresAt > now()) && Self.mayAnswerFor(origin: question.question.origin, by: by) &&
                (question.question.tool != "access.request_scope" && question.question.profileBatch == nil || by == "window" || by.hasPrefix("device:"))
        } ?? false
    }
    public func callerGone(_ surface: String) throws {
        guard surface != "window" else { throw NativeRPCError.invalidArguments("deck-control: use approverGone() for the window") }
        for id in order where pending[id]?.question.origin == surface { finish(id, outcome: deny(.callerGone)) }
    }
    public func approverGone() { for id in order { finish(id, outcome: deny(.approverGone)) } }
    public func stop() { stopped = true; for id in order { finish(id, outcome: deny(.shuttingDown)) } }
    public func noteOwnerActive(_ active: Bool) {
        guard !stopped, ownerActive != active else { return }; ownerActive = active
        for id in order {
            guard var entry = pending[id], entry.question.profileBatch != nil else { continue }
            entry.question.profileBatch?.waitsWhileOwnerActive = active
            entry.timer?.cancel(); entry.timer = nil
            if let scheduled = entry.scheduled { clock?.cancel(scheduled); entry.scheduled = nil }
            if !active { entry.question.expiresAt = now() + Double(entry.wait) }
            entry.revision += 1
            pending[id] = entry
            queueDelivery(id)
        }
    }
    private func waitsForActiveOwner(_ entry: Pending) -> Bool { entry.question.profileBatch != nil && ownerActive }
    private func groupKey(_ batch: BackendTAGProfileConsentBatch) -> String { batch.keyID + ":" + batch.kind }
    private func cancel(_ id: String, subscriber: UUID) {
        guard var entry = pending[id], let one = entry.subscribers.removeValue(forKey: subscriber) else { return }
        entry.subscribersOrder.removeAll { $0 == subscriber }
        if let observer = one.observer { one.cancellation?.removeObserver(observer) }
        one.continuation.resume(returning: deny(.callerGone))
        if entry.subscribers.isEmpty { pending[id] = entry; finish(id, outcome: deny(.callerGone)); return }
        if var batch = entry.question.profileBatch {
            batch.items = []; for token in entry.subscribersOrder { batch.append(entry.subscribers[token]?.items ?? []) }
            entry.question.profileBatch = batch; entry.question.summary = batch.summary
        }
        entry.revision += 1
        pending[id] = entry; queueDelivery(id)
    }
    private func expire(_ id: String) { guard let entry = pending[id], !waitsForActiveOwner(entry) else { return }; finish(id, outcome: deny(.timeout)) }
    private func deny(_ reason: BackendDeckCoreSecurityRefusalReason, at: Double? = nil) -> BackendDeckCoreSecurityConsentOutcome { .init(granted: false, reason: reason, by: nil, at: at ?? now()) }
    private func finish(_ id: String, outcome: BackendDeckCoreSecurityConsentOutcome, notify: Bool = true) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }; entry.timer?.cancel()
        if let scheduled = entry.scheduled { clock?.cancel(scheduled) }
        for subscriber in entry.subscribers.values {
            if let observer = subscriber.observer { subscriber.cancellation?.removeObserver(observer) }
            subscriber.continuation.resume(returning: subscriber.cancellation?.isCancelled == true ? deny(.callerGone) : outcome)
        }
        if notify, let settled { Task { try? await settled(id, outcome) } }
    }
    public nonisolated static func mayAnswerFor(origin: String, by: String) -> Bool {
        // The island is the person's own screen on this Mac, like the window (H10, 11 Oct: its Allow/Deny answered nothing).
        by == "window" || by == "island" || by == origin || ((origin == "plugin-consent" || origin.hasPrefix("key:") && origin.count > 4) && by.hasPrefix("device:"))
    }
}
