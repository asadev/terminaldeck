import Foundation
import TerminalDeckNativeCore

/// One app-wide heavy-work owner. Queueing and completion are actor events, never polls.
/// The holder keeps a lease (30 minutes, renewed by each of its own lock calls); a holder
/// that died or forgot to release loses the lock when the lease runs out.
public actor BackendAGOPTCoordinator {
    public static let shared = BackendAGOPTCoordinator()
    public struct Ticket: Sendable, Equatable {
        public let id: String
        public let owner: String
    }
    private struct Waiter {
        let ticket: Ticket
        let continuation: CheckedContinuation<Void, Error>
    }
    private var holder: Ticket?
    private var ownerSessions: [String: String] = [:]
    private var queue: [Ticket] = []
    private var waiters: [UUID: Waiter] = [:]
    private var observers: [UUID: CheckedContinuation<UInt64, Never>] = [:]
    private var revision: UInt64 = 0
    private var leaseUntil: Date?
    /// withLease tickets end with their own scope, so they never expire mid-operation.
    private var unleased: Set<String> = []
    private var expiry: Task<Void, Never>?
    private let leaseSeconds: TimeInterval
    private let now: @Sendable () -> Date
    public init(leaseSeconds: TimeInterval = 30 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.leaseSeconds = leaseSeconds; self.now = now
    }

    public func request(owner: String, sessionID: String? = nil) throws -> Ticket {
        try request(owner: owner, sessionID: sessionID, leased: true)
    }
    private func request(owner: String, sessionID: String?, leased: Bool) throws -> Ticket {
        expireIfDue()
        guard !owner.isEmpty else { throw NativeRPCError.invalidArguments("A heavy job needs its real owner.") }
        guard holder?.owner != owner, !queue.contains(where: { $0.owner == owner }) else {
            throw NativeRPCError(code: "work-already-requested", message: "This caller already holds or is waiting for the heavy job lock.")
        }
        guard queue.count < 128 else { throw NativeRPCError(code: "work-queue-full", message: "The heavy job queue is full.") }
        let ticket = Ticket(id: UUID().uuidString.lowercased(), owner: owner)
        if let sessionID { ownerSessions[owner] = sessionID }
        if !leased { unleased.insert(ticket.id) }
        if holder == nil { grant(ticket) } else { queue.append(ticket) }
        changed(); return ticket
    }
    public func release(_ ticket: Ticket) throws {
        guard holder == ticket || queue.contains(ticket) else { throw NativeRPCError(code: "not-permitted", message: "Only the caller that requested this heavy job can release it.") }
        if holder == ticket { holder = nil; leaseUntil = nil; expiry?.cancel(); expiry = nil } else { queue.removeAll { $0 == ticket } }
        ownerSessions[ticket.owner] = nil; unleased.remove(ticket.id)
        settle(ticket, error: CancellationError())
        promote(); changed()
    }
    public func release(owner: String, ticketID: String) throws {
        let ticket = Ticket(id: ticketID, owner: owner); try release(ticket)
    }
    public func releaseAll(owner: String) {
        let tickets = ([holder].compactMap { $0 } + queue).filter { $0.owner == owner }
        for ticket in tickets { try? release(ticket) }
    }
    public func releaseSession(sessionID: String) {
        let owners = ownerSessions.filter { $0.value == sessionID }.map(\.key)
        for owner in owners { releaseAll(owner: owner) }
    }
    /// The person's own "Free" on At work: lets go of the current holder only;
    /// the queue keeps its order and the next waiting agent is granted.
    public func freeHolder() {
        if let holder { try? release(holder) }
    }
    /// Each lock call by the current holder is a sign of life and renews its lease.
    public func renew(owner: String) {
        expireIfDue()
        if holder?.owner == owner, leaseUntil != nil { leaseUntil = now().addingTimeInterval(leaseSeconds) }
    }
    private func grant(_ ticket: Ticket) {
        holder = ticket
        leaseUntil = unleased.contains(ticket.id) ? nil : now().addingTimeInterval(leaseSeconds); scheduleExpiry()
    }
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let leaseUntil else { expiry = nil; return }
        let delay = max(0, leaseUntil.timeIntervalSince(now()))
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.leaseCheck()
        }
    }
    private func leaseCheck() {
        guard holder != nil, let leaseUntil else { return }
        if now() >= leaseUntil { expireIfDue() } else { scheduleExpiry() }
    }
    private func expireIfDue() {
        guard let holder, let leaseUntil, now() >= leaseUntil else { return }
        try? release(holder)
    }
    private func promote() {
        guard holder == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst(); grant(next); settle(next, error: nil)
    }
    private func settle(_ ticket: Ticket, error: Error?) {
        let ids = waiters.filter { $0.value.ticket == ticket }.map(\.key)
        for id in ids {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
        }
    }
    private func changed() {
        revision &+= 1
        let pending = observers; observers.removeAll()
        for continuation in pending.values { continuation.resume(returning: revision) }
    }
    private func cancelledWait(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        // Cancellation before the operation starts must not strand a granted lease.
        try? release(waiter.ticket)
    }
    public func waitUntilGranted(_ ticket: Ticket) async throws {
        try Task.checkCancellation()
        if holder == ticket { return }
        guard queue.contains(ticket) else { throw NativeRPCError(code: "work-ticket-gone", message: "This heavy job request was released.") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { try? release(ticket); continuation.resume(throwing: CancellationError()); return }
                waiters[id] = Waiter(ticket: ticket, continuation: continuation)
            }
        } onCancel: { Task { await self.cancelledWait(id) } }
        try Task.checkCancellation()
    }
    public func withLease<T: Sendable>(owner: String, operation: @Sendable () async throws -> T) async throws -> T {
        let ticket = try request(owner: owner + ":" + UUID().uuidString.lowercased(), sessionID: nil, leased: false)
        do {
            try await waitUntilGranted(ticket); try Task.checkCancellation()
            let result = try await operation(); try release(ticket); return result
        } catch { try? release(ticket); throw error }
    }
    public func status(owner: String) -> NativeRPCValue {
        expireIfDue()
        let own = holder?.owner == owner ? holder : queue.first { $0.owner == owner }
        return .object([.init("revision", .number(Double(revision))), .init("busy", .bool(holder != nil)),
            .init("waiting", .number(Double(queue.count))), .init("ticket", own.map { .string($0.id) } ?? .null),
            .init("granted", .bool(holder?.owner == owner)), .init("position", own.flatMap { ticket in queue.firstIndex(of: ticket).map { .number(Double($0 + 1)) } } ?? .null)])
    }
    /// Wait for a change or deadline. A timeout returns current evidence; it does not
    /// acquire work or inspect files. Cancellation clears only this read waiter.
    public func wait(after: UInt64, seconds: Double = 45, cancellation: BackendMCPCancellation? = nil) async -> UInt64 {
        if revision != after || Task.isCancelled || cancellation?.isCancelled == true { return revision }
        let id = UUID()
        let timer = Task { try? await Task.sleep(for: .seconds(min(120, max(0, seconds)))); await self.endObservation(id) }
        let token = cancellation?.observe { Task { await self.endObservation(id) } }
        defer { timer.cancel(); if let token { cancellation?.removeObserver(token) } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancellation?.isCancelled == true || revision != after { continuation.resume(returning: revision) }
                else { observers[id] = continuation }
            }
        } onCancel: { Task { await self.endObservation(id) } }
    }
    private func endObservation(_ id: UUID) { observers.removeValue(forKey: id)?.resume(returning: revision) }
}

public enum BackendAGOPTWorkMCP {
    public static let toolIDs = ["agents.work_read", "agents.work_change", "agents.work_wait"]
    public static func definitions(access: BackendDeckToolsAppAccess, scope: BackendAGSAccess,
                                   coordinator: BackendAGOPTCoordinator = .shared) throws -> [BackendDeckToolsDefinition] {
        let schema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"profile":{"type":"string"},"action":{"type":"string","enum":["acquire","release"]},"ticket":{"type":"string"},"revision":{"type":"integer","minimum":0},"timeoutSeconds":{"type":"number","minimum":0,"maximum":120}},"additionalProperties":false}"#.utf8))
        return try toolIDs.map { id in
            let write = id == toolIDs[1], tier: BackendMCPTier = write ? .alter : .read
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: write ? "Request or release the shared heavy job lock. A queued ticket must wait until granted before work starts. Only your own ticket can be released. A granted lock is held for 30 minutes after your last heavy job call, then passes to the next agent." : id == toolIDs[2] ? "Wait for the shared heavy job done signal or a grant, without polling. Use the revision from agents_work_read; timeoutSeconds defaults to 45, at most 120." : "Read shared heavy job state and your own ticket. Other agents' identities remain private.", inputSchema: schema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: write ? "Change heavy job lock" : id == toolIDs[2] ? "Wait for heavy job" : "Read heavy job lock", index: spec.description) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(tier), !context.cancellation.isCancelled else { throw CancellationError() }
                    let allowed: Set<String> = write ? ["profile", "action", "ticket"] : id == toolIDs[2] ? ["profile", "revision", "timeoutSeconds"] : ["profile"]
                    guard let fields = args.fields, fields.allSatisfy({ allowed.contains($0.key) }), args["profile"].isNullish || args["profile"].string != nil else { throw NativeRPCError.invalidArguments("Use only the documented heavy job fields.") }
                    let profile = args["profile"].string
                    try await scope.require(context, profile, false)
                    let caller = try await access.caller(context)
                    let owner = try identity(caller, context: context)
                    if write {
                        guard let action = args["action"].string, ["acquire", "release"].contains(action), action == "acquire" ? args["ticket"].isNullish : args["ticket"].string != nil else { throw NativeRPCError.invalidArguments("Choose acquire, or release with your ticket.") }
                        try await access.authorize(context, id, args, tier, action == "acquire" ? "Request the shared heavy job lock for this caller." : "Release this caller's heavy job lock and signal the next waiting agent.", true)
                        guard !context.cancellation.isCancelled else { throw CancellationError() }
                        try await scope.require(context, profile, false)
                        guard try identity(try await access.caller(context), context: context) == owner else { throw NativeRPCError(code: "not-permitted", message: "The heavy job caller changed during approval.") }
                        await coordinator.renew(owner: owner)
                        if action == "acquire" { _ = try await coordinator.request(owner: owner, sessionID: caller.kind == .session ? caller.sessionID ?? context.sessionID : nil) }
                        else { try await coordinator.release(owner: owner, ticketID: args["ticket"].string!) }
                        let result = await coordinator.status(owner: owner)
                        try await access.record(context, id, args, result); return .value(result)
                    }
                    if id == toolIDs[2] {
                        guard let revision = args["revision"].number, revision.isFinite, revision >= 0, revision <= Double(Int32.max), revision.rounded() == revision,
                              args["timeoutSeconds"].isNullish || args["timeoutSeconds"].number.map({ $0.isFinite && (0...120).contains($0) }) == true else { throw NativeRPCError.invalidArguments("Read the lock revision first and use a wait of at most 120 seconds.") }
                        _ = await coordinator.wait(after: UInt64(revision), seconds: args["timeoutSeconds"].number ?? 45, cancellation: context.cancellation)
                        guard !context.cancellation.isCancelled else { throw CancellationError() }
                        try await scope.require(context, profile, false)
                    }
                    await coordinator.renew(owner: owner)
                    return .value(await coordinator.status(owner: owner))
                }
            }
        }
    }
    private static func identity(_ caller: BackendDeckToolsAppCaller, context: BackendMCPCallContext) throws -> String {
        let machine = caller.machineID ?? context.machineID
        switch caller.kind {
        case .local: return "local:" + machine
        case .key:
            guard let key = caller.keyID, !key.isEmpty else { throw NativeRPCError(code: "not-permitted", message: "The real key identity is not connected to heavy jobs.") }
            return "key:" + key
        case .session:
            let session = caller.sessionID ?? context.sessionID
            guard !session.isEmpty else { throw NativeRPCError(code: "not-permitted", message: "This worker has no current session identity.") }
            return "session:" + machine + ":" + session
        case .remote, .other: throw NativeRPCError(code: "not-permitted", message: "This transport cannot own a local heavy job.")
        }
    }
}
