import Foundation
import TerminalDeckNativeCore

/// An owner snapshot: nil status means the lifecycle has no accepted status yet.
/// This is never decoded from an alert read or a renderer/MCP argument.
public struct BackendAGSAlertSession: Sendable {
    public let id: String
    public let status: BackendSessionStatus?
    public init(id: String, status: BackendSessionStatus?) { self.id = id; self.status = status }
}

public struct BackendAGSAcceptedAlert: Sendable, Equatable {
    /// Stable for one accepted input episode; repeated receipts retain this identity.
    public let id: String
    public let alertID: String
    public let sessionID: String
    public let acceptedAt: Double
    public let kind = "session-blocked"
}

public struct BackendAGSAlertDeadline: Sendable {
    private let cancelWork: @Sendable () -> Void
    public init(cancel: @escaping @Sendable () -> Void) { cancelWork = cancel }
    public func cancel() { cancelWork() }
}

/// One-shot deadlines, not a repeating read of sessions or alerts.
public struct BackendAGSAlertScheduler: Sendable {
    public let now: @Sendable () -> Double
    public let schedule: @Sendable (Double, @escaping @Sendable () async -> Void) -> BackendAGSAlertDeadline
    public init(now: @escaping @Sendable () -> Double,
                schedule: @escaping @Sendable (Double, @escaping @Sendable () async -> Void) -> BackendAGSAlertDeadline) {
        self.now = now; self.schedule = schedule
    }
    public static let live = BackendAGSAlertScheduler(now: { Date().timeIntervalSince1970 * 1_000 }, schedule: { delay, work in
        let task = Task {
            do {
                try await Task.sleep(for: .milliseconds(max(0, delay)))
                try Task.checkCancellation()
                await work()
            } catch { /* Cancellation removes this input episode's deadline. */ }
        }
        return BackendAGSAlertDeadline { task.cancel() }
    })
}

/// Construct before the store so its existing saved-change callback can reach the
/// eventual producer without a composition/self race or a store→source retain cycle.
public actor BackendAGSAlertSettingsChanges {
    private weak var source: BackendAGSAlerts?
    public init() {}
    public func bind(_ source: BackendAGSAlerts?) { self.source = source }
    public func saved() async throws { try await source?.refreshHooks() }
}

/// The real accepted-alert producer for the existing ten-minute input-wait criterion.
/// Composition supplies only the coordinator's ordered, typed accepted lifecycle stream.
/// Transcript/git/provider alerts remain read-only until they have their own accepted producers.
public actor BackendAGSAlerts {
    public static let waitingMilliseconds: Double = 600_000
    public static let maximumSessions = 256
    private struct Entry {
        var status: BackendSessionStatus?
        var since: Double?
        var episode: UUID?
        var published = false
        var deadline: BackendAGSAlertDeadline?
        var deadlineID: UUID?
    }
    private let snapshot: @Sendable () async -> [BackendAGSAlertSession]
    private let currentStatus: @Sendable (String) async -> BackendSessionStatus?
    private let hooksEnabled: @Sendable () async throws -> Bool
    private let accepted: @Sendable (BackendAGSAcceptedAlert) async -> Void
    private let problem: @Sendable (String) async -> Void
    private let scheduler: BackendAGSAlertScheduler
    private var entries: [String: Entry] = [:]
    private var started = false
    private var starting = false
    private var stopped = false
    private var enabled = false
    private var refreshGeneration = 0
    private var baselineTouched = Set<String>()
    private var skipBaseline = false

    public init(snapshot: @escaping @Sendable () async -> [BackendAGSAlertSession],
                currentStatus: @escaping @Sendable (String) async -> BackendSessionStatus?,
                hooksEnabled: @escaping @Sendable () async throws -> Bool,
                accepted: @escaping @Sendable (BackendAGSAcceptedAlert) async -> Void,
                scheduler: BackendAGSAlertScheduler = .live,
                problem: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.snapshot = snapshot; self.currentStatus = currentStatus; self.hooksEnabled = hooksEnabled
        self.accepted = accepted; self.scheduler = scheduler; self.problem = problem
    }

    /// Bind to the typed fanout before starting. Events received during snapshot acquisition
    /// take precedence over baseline rows; an existing input never gets invented history.
    public func start() async throws {
        guard !stopped, !started, !starting else { return }
        starting = true
        defer { starting = false }
        let baseline = await snapshot()
        guard !stopped, !started else { return }
        let now = scheduler.now()
        if !skipBaseline {
            for row in baseline.prefix(Self.maximumSessions) where entries[row.id] == nil && !baselineTouched.contains(row.id) && validID(row.id) {
                insert(row.id, status: row.status, now: now)
            }
        }
        baselineTouched.removeAll()
        started = true
        try await refreshHooks()
    }

    /// The saved-defaults change callback calls this once; no settings polling.
    /// Reads failure disables all deadlines, rather than trusting old enabled hooks.
    public func refreshHooks() async throws {
        guard started, !stopped else { return }
        refreshGeneration += 1
        let mine = refreshGeneration
        do {
            let next = try await hooksEnabled()
            guard !stopped, mine == refreshGeneration else { return }
            setEnabled(next)
        } catch {
            if !stopped, mine == refreshGeneration { setEnabled(false) }
            throw error
        }
    }

    /// Backend-only seam. There is intentionally no public RPC registration for it.
    /// Raw .process(.status) and .data are not accepted status receipts.
    public func receive(_ event: BackendSessionLifecycleEvent) async {
        guard !stopped else { return }
        switch event {
        case .created(let session): touchBaseline(session.id); insertIfAbsent(session.id)
        case .replaced(let old, let session, _):
            touchBaseline(old); touchBaseline(session.id); remove(old); insertIfAbsent(session.id)
        case .status(let id, let status, _):
            guard validID(id) else { return }
            touchBaseline(id)
            if entries[id] == nil {
                guard entries.count < Self.maximumSessions else {
                    await problem("Accepted waiting alerts reached their session limit; no extra timer was started.")
                    return
                }
                insert(id, status: nil, now: scheduler.now())
            }
            update(id, status: status)
        case .process(.exit(let id, _)), .process(.removed(let id, _)): touchBaseline(id); remove(id)
        default: break
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true; enabled = false; started = false; refreshGeneration += 1
        for entry in entries.values { entry.deadline?.cancel() }
        entries.removeAll()
        baselineTouched.removeAll()
    }

    /// Bounded diagnostics without paths, account details or prompt content.
    public func state() -> (sessions: Int, deadlines: Int, enabled: Bool) {
        (entries.count, entries.values.filter { $0.deadline != nil }.count, enabled)
    }

    private func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 128 && !id.contains("\0") }
    private func touchBaseline(_ id: String) {
        guard !started, validID(id) else { return }
        if baselineTouched.count < Self.maximumSessions * 2 { baselineTouched.insert(id) }
        else { skipBaseline = true } // Bounded startup tombstones; never resurrect an unproven row.
    }
    private func insertIfAbsent(_ id: String) {
        guard validID(id), entries[id] == nil, entries.count < Self.maximumSessions else { return }
        insert(id, status: nil, now: scheduler.now())
    }
    private func insert(_ id: String, status: BackendSessionStatus?, now: Double) {
        guard entries.count < Self.maximumSessions else { return }
        var entry = Entry(status: status)
        if status == .input, now.isFinite {
            entry.since = now; entry.episode = UUID()
        }
        entries[id] = entry
    }
    private func remove(_ id: String) { entries.removeValue(forKey: id)?.deadline?.cancel() }
    private func update(_ id: String, status: BackendSessionStatus) {
        guard var entry = entries[id], entry.status != status else { return }
        entry.deadline?.cancel(); entry.deadline = nil; entry.deadlineID = nil
        entry.status = status; entry.since = nil; entry.episode = nil; entry.published = false
        let now = scheduler.now()
        if status == .input, now.isFinite { entry.since = now; entry.episode = UUID() }
        entries[id] = entry
        arm(id)
    }
    private func setEnabled(_ next: Bool) {
        guard enabled != next else { return }
        enabled = next
        if !next {
            for id in Array(entries.keys) { entries[id]?.deadline?.cancel(); entries[id]?.deadline = nil; entries[id]?.deadlineID = nil }
            return
        }
        let now = scheduler.now()
        for id in Array(entries.keys) {
            // A threshold crossed while hooks were off is an old baseline, not a new alert.
            if let since = entries[id]?.since, now - since >= Self.waitingMilliseconds {
                entries[id]?.published = true
            } else { arm(id) }
        }
    }
    private func arm(_ id: String) {
        guard started, enabled, !stopped, let entry = entries[id], entry.status == .input,
              !entry.published, entry.deadline == nil, let since = entry.since, let episode = entry.episode else { return }
        let now = scheduler.now(), delay = since + Self.waitingMilliseconds - now
        guard now.isFinite, delay.isFinite else { return }
        let token = UUID()
        let deadline = scheduler.schedule(max(0, delay)) { [weak self] in await self?.deadline(id, episode: episode, token: token) }
        entries[id]?.deadline = deadline
        entries[id]?.deadlineID = token
    }
    private func deadline(_ id: String, episode: UUID, token: UUID) async {
        guard started, enabled, !stopped, let entry = entries[id], entry.episode == episode,
              entry.deadlineID == token, entry.status == .input, !entry.published, let since = entry.since else { return }
        entries[id]?.deadline = nil; entries[id]?.deadlineID = nil
        let now = scheduler.now()
        guard now.isFinite else { return }
        if now - since < Self.waitingMilliseconds { arm(id); return } // A wall-clock correction moves this one deadline.
        let current = await currentStatus(id)
        guard started, enabled, !stopped, entries[id]?.episode == episode,
              entries[id]?.status == .input, entries[id]?.published == false else { return }
        guard current == .input else {
            // Missing/unknown status must not turn into an assumed waiting alert.
            if let current { update(id, status: current) }
            else { remove(id) }
            return
        }
        entries[id]?.published = true
        await accepted(.init(id: "session-blocked:" + id + ":" + episode.uuidString,
            alertID: "session-blocked:" + id, sessionID: id, acceptedAt: now))
    }
}
