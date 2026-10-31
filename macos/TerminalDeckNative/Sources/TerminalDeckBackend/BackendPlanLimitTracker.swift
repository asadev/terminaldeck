import Foundation
import SwiftTerm
import TerminalDeckNativeCore

/// Port of src/main/plan-limit.ts's tracker and registry (`PlanLimitTracker`, `watchPlanSnapshots`,
/// `planSnapshot`, `planBilling`, `notePlanOutput`, `notePlanResize`, `dropPlanSession`). It reads a
/// session's own screen and writes to nothing. The account-based plan state in BackendUsageService
/// is a separate thing for the usage screens; this one answers wherever the TS tracker answered.
public struct BackendPlanLimitSnapshot: Sendable, Equatable {
    public let sessionID: String
    public let available: Bool
    public let limits: [BackendUsagePlanLimit]
    public let source: String?
    public let message: String?
    public let capturedAt: Double
    public let firstSeenAt: Double
    public let reason: String?

    public static func empty(_ sessionID: String, reason: String) -> Self {
        Self(sessionID: sessionID, available: false, limits: [], source: nil, message: nil, capturedAt: 0, firstSeenAt: 0, reason: reason)
    }
    public var wireValue: NativeRPCValue {
        BackendUsageIO.object([("sessionId", .string(sessionID)), ("available", .bool(available)), ("limits", .array(limits.map(\.wireValue))),
            ("source", BackendUsageIO.string(source)), ("message", BackendUsageIO.string(message)), ("capturedAt", .number(capturedAt)),
            ("firstSeenAt", .number(firstSeenAt)), ("reason", BackendUsageIO.string(reason))])
    }
}

public enum BackendPlanLimitText {
    public static let notSeen = "Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run."
    public static let notWatched = "No live session is being watched for plan limits."
    public static let evicted = "Plan limits are tracked for the most recently watched sessions only, and this one was released to make room. Reopen it to read them again."
}

public final class BackendPlanLimitTracker: @unchecked Sendable {
    private final class Delegate: TerminalDelegate {
        // A shadow: the attached terminal owns protocol replies.
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    public static let settleMilliseconds = 600
    public let sessionID: String
    private let lock = NSLock()
    private let delegate = Delegate()
    private let terminal: Terminal
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.plan-limit", qos: .utility)
    private let settle: Int
    private let onChange: @Sendable (BackendPlanLimitSnapshot) -> Void
    private let clock: @Sendable () -> Double
    private var timer: DispatchWorkItem?
    private var lastOutputAt: Double = 0
    private var snapshot: BackendPlanLimitSnapshot
    private var lastBilling: String?
    private var disposed = false

    public init(sessionID: String, cols: Int = 120, rows: Int = 40, settleMilliseconds: Int = BackendPlanLimitTracker.settleMilliseconds,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                onChange: @escaping @Sendable (BackendPlanLimitSnapshot) -> Void) {
        self.sessionID = sessionID; settle = settleMilliseconds; self.clock = clock; self.onChange = onChange
        terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: max(cols, 1), rows: max(rows, 1), termName: "xterm-256color", scrollback: 100))
        snapshot = .empty(sessionID, reason: BackendPlanLimitText.notSeen)
    }

    public var current: BackendPlanLimitSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }

    /// The account's billing as the CLI's own banner last stated it, or nil when none has been on this screen.
    /// Reads the screen rather than only what the settle timer caught, and never records absence.
    public func billing() -> String? {
        lock.lock(); defer { lock.unlock() }
        noteBilling(screenLocked())
        return lastBilling
    }

    public func push(_ chunk: String) {
        lock.lock()
        guard !disposed else { lock.unlock(); return }
        terminal.feed(byteArray: Array(chunk.utf8))
        lastOutputAt = clock()
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.capture() }
        timer = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(settle), execute: work)
    }

    /// Everything pushed is already on the screen: the parser here is synchronous. Kept so callers read like the TS.
    public func flush() async {}

    public func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !disposed else { return }
        terminal.resize(cols: max(cols, 1), rows: max(rows, 1))
    }

    /// The visible viewport, as the user sees it.
    public func screen() -> String { lock.lock(); defer { lock.unlock() }; return screenLocked() }

    private func screenLocked() -> String {
        (0..<terminal.getDims().rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }
    private func noteBilling(_ screen: String) { if let seen = BackendUsagePlanParser.billing(screen: screen) { lastBilling = seen } }

    /// Read the screen. True when the stored snapshot changed. A screen with no limits leaves the last reading
    /// alone (the panel is closed most of the time). `confirmed` is the one case where identical text counts as fresh.
    @discardableResult
    public func capture(at: Double? = nil, confirmed: Bool = false) -> Bool {
        lock.lock()
        let screen = screenLocked()
        // Read first, and even when no limits are on screen: that is the frame this exists for.
        noteBilling(screen)
        guard let parsed = BackendUsagePlanParser.parse(screen: screen) else { lock.unlock(); return false }
        let stamp = at ?? clock()
        let same = snapshot.available && snapshot.source == parsed.source && snapshot.message == parsed.message && snapshot.limits == parsed.limits
        // Re-stamp the time even when the numbers match: the reading really was taken again.
        let next = BackendPlanLimitSnapshot(sessionID: sessionID, available: true, limits: parsed.limits, source: parsed.source, message: parsed.message,
            capturedAt: stamp, firstSeenAt: same && !confirmed ? snapshot.firstSeenAt : stamp, reason: nil)
        snapshot = next
        lock.unlock()
        if !same { onChange(next) }
        return !same
    }

    /// True when nothing has been drawn for `ms`: the session is not mid-answer.
    public func settled(_ ms: Double, now: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lastOutputAt == 0 || (now ?? clock()) - lastOutputAt >= ms
    }

    public func dispose() {
        lock.lock(); defer { lock.unlock() }
        disposed = true; timer?.cancel(); timer = nil
    }
}

/// Resident trackers (at most eight, each a small headless terminal) and their listeners.
public actor BackendPlanLimits {
    public static let maxTrackers = 8
    private struct Entry { let tracker: BackendPlanLimitTracker; var listeners: [String: @Sendable (BackendPlanLimitSnapshot) -> Void] }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let settleMilliseconds: Int
    private let clock: @Sendable () -> Double

    public init(settleMilliseconds: Int = BackendPlanLimitTracker.settleMilliseconds, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.settleMilliseconds = settleMilliseconds; self.clock = clock
    }

    /// Watch a session: hand back the reading held right now and call `listener` on every change until `unwatch`.
    /// Holding a listener keeps the tracker resident.
    @discardableResult
    public func watch(_ sessionID: String, key: String, listener: @escaping @Sendable (BackendPlanLimitSnapshot) -> Void) throws -> BackendPlanLimitSnapshot {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("plan-limit: a session id is required") }
        let entry = ensure(sessionID)
        entries[sessionID]?.listeners[key] = listener
        return entry.tracker.current
    }
    public func unwatch(_ sessionID: String, key: String) {
        guard entries[sessionID] != nil else { return }
        entries[sessionID]?.listeners[key] = nil
        if entries[sessionID]?.listeners.isEmpty == true { drop(sessionID) }
    }
    /// The reading held for a session now, without subscribing. An unwatched session has no reading, which is not an empty one.
    public func snapshot(_ sessionID: String) -> BackendPlanLimitSnapshot { entries[sessionID]?.tracker.current ?? .empty(sessionID, reason: BackendPlanLimitText.notWatched) }
    /// Nil is "no banner seen" (or not watched), never "no subscription".
    public func billing(_ sessionID: String) -> String? { entries[sessionID]?.tracker.billing() }
    public func noteOutput(_ sessionID: String, _ chunk: String) { entries[sessionID]?.tracker.push(chunk) }
    public func noteResize(_ sessionID: String, cols: Int, rows: Int) { entries[sessionID]?.tracker.resize(cols: cols, rows: rows) }
    public func drop(_ sessionID: String) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        order.removeAll { $0 == sessionID }
        entry.tracker.dispose()
    }
    public var count: Int { entries.count }

    func broadcast(_ snapshot: BackendPlanLimitSnapshot) {
        guard let entry = entries[snapshot.sessionID] else { return }
        for listener in entry.listeners.values { listener(snapshot) }
    }
    private func evict(_ sessionID: String) {
        // Tell whoever was watching, or their strip keeps showing a number nothing will update again.
        broadcast(.empty(sessionID, reason: BackendPlanLimitText.evicted))
        drop(sessionID)
    }
    private func ensure(_ sessionID: String) -> Entry {
        if let existing = entries[sessionID] { return existing }
        if entries.count >= Self.maxTrackers, let oldest = order.first { evict(oldest) }
        let tracker = BackendPlanLimitTracker(sessionID: sessionID, settleMilliseconds: settleMilliseconds, clock: clock) { [weak self] snapshot in
            Task { await self?.broadcast(snapshot) }
        }
        let entry = Entry(tracker: tracker, listeners: [:])
        entries[sessionID] = entry; order.append(sessionID)
        return entry
    }
}
