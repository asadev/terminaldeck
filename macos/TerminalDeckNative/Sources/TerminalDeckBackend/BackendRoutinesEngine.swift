import Foundation
import TerminalDeckNativeCore

public enum BackendRoutinesCause: Sendable, Equatable {
    case manual(by: String)
    case sessionFinished(sessionId: String, exitCode: Int)
    case sessionFailed(sessionId: String, exitCode: Int)
    case sessionIdle(sessionId: String, afterMs: Double)
    case alert(alertId: String, severity: String, title: String, sessionId: String?)
    case gitChange(folder: String)
    case fileChange(folder: String, path: String)
    case schedule(dueAt: Double, missed: Int)
    public var kind: String {
        switch self {
        case .manual: return "manual"
        case .sessionFinished: return "session-finished"
        case .sessionFailed: return "session-failed"
        case .sessionIdle: return "session-idle"
        case .alert: return "alert"
        case .gitChange: return "git-change"
        case .fileChange: return "file-change"
        case .schedule: return "schedule"
        }
    }
    public var description: String {
        switch self {
        case .manual(let by): return by == "copilot" ? "Hoot asked for it." : "You asked for it."
        case .sessionFinished(let id, _): return "Session \(String(id.prefix(8))) finished."
        case .sessionFailed(let id, let code): return "Session \(String(id.prefix(8))) exited with code \(code)."
        case .sessionIdle(let id, _): return "Session \(String(id.prefix(8))) went quiet."
        case .alert(_, let severity, let title, _): return "A \(severity) alert appeared: \(title)"
        case .gitChange: return "The git status of the folder changed."
        case .fileChange(_, let path): return "\(path) changed."
        case .schedule(_, let missed): return missed > 0 ? "It came due, and it came due \(missed) more time\(missed == 1 ? "" : "s") while the app was closed." : "It came due."
        }
    }
}

/// The only in-process tool surface a routine receives. It has no attended API.
/// The shared control owns policy, consent, budgets and the tool audit row.
public struct BackendRoutinesToolCaller: Sendable {
    private let operation: @Sendable (String, NativeRPCValue, BackendMCPCancellation) async -> BackendDeckCoreSecurityCallResult
    public init(control: BackendDeckCoreSecurityControl) {
        operation = { name, args, cancellation in await control.unattendedCall(name: name, arguments: args, cancellation: cancellation) }
    }
    fileprivate init(operation: @escaping @Sendable (String, NativeRPCValue, BackendMCPCancellation) async -> BackendDeckCoreSecurityCallResult) { self.operation = operation }
    public func call(_ name: String, arguments: NativeRPCValue, cancellation: BackendMCPCancellation = .init()) async -> BackendDeckCoreSecurityCallResult {
        await operation(name, arguments, cancellation)
    }
}

public struct BackendRoutinesRunRequest: Sendable {
    public let routine: BackendRoutinesRoutine
    public let runId: String
    public let cause: BackendRoutinesCause
    public let chain: [String]
    public let cancellation: BackendMCPCancellation
    /// A computed constant prevents callers constructing an attended routine.
    public var attended: Bool { false }
    public let control: BackendRoutinesToolCaller?
    public init(routine: BackendRoutinesRoutine, runId: String, cause: BackendRoutinesCause, chain: [String], cancellation: BackendMCPCancellation = .init(), control: BackendRoutinesToolCaller? = nil) {
        self.routine = routine; self.runId = runId; self.cause = cause; self.chain = chain; self.cancellation = cancellation; self.control = control
    }
}
public struct BackendRoutinesRunOutcome: Sendable, Equatable {
    public let ok: Bool
    public let sessionIds: [String]
    public let error: String?
    public init(ok: Bool, sessionIds: [String] = [], error: String? = nil) { self.ok = ok; self.sessionIds = sessionIds; self.error = error }
}
public protocol BackendRoutinesRunner: Sendable {
    var cancellable: Bool { get }
    func run(_ request: BackendRoutinesRunRequest) async -> BackendRoutinesRunOutcome
}
public extension BackendRoutinesRunner { var cancellable: Bool { false } }
public struct BackendRoutinesRunResult: Sendable, Equatable {
    public let started: Bool
    public let runId: String?
    public let reason: String?
    public init(started: Bool, runId: String? = nil, reason: String? = nil) { self.started = started; self.runId = runId; self.reason = reason }
    public var wire: NativeRPCValue { .object([.init("started", .bool(started)), .init("runId", runId.map(NativeRPCValue.string) ?? .missing), .init("reason", reason.map(NativeRPCValue.string) ?? .missing)]) }
}
public struct BackendRoutinesSourceView: Sendable, Equatable {
    public let kind: String, subscribed: Bool, lastEventAt: Double?, events: Int, note: String?
    public var wire: NativeRPCValue { .object([.init("kind", .string(kind)), .init("subscribed", .bool(subscribed)), .init("lastEventAt", lastEventAt.map(NativeRPCValue.number) ?? .null), .init("events", .number(Double(events))), .init("note", note.map(NativeRPCValue.string) ?? .null)]) }
}
public struct BackendRoutinesView: Sendable, Equatable {
    public let id: String, name: String, file: String, folder: String?, triggers: [String], prompt: String
    public let enabled: Bool, overlap: BackendRoutinesOverlapPolicy?, state: String, reason: String?
    public let problems: [String], warnings: [String], lastFiredAt: Double?, lastRunAt: Double?, lastFinishedAt: Double?, lastOutcome: String?, lastError: String?
    public let consecutiveFailures: Int, refusedCalls: [BackendRoutinesRefusal], running: Bool, pending: Bool
    public let runsLastHour: Int, runsLastDay: Int, firesLastHour: Int, maxRunsPerHour: Int?, maxRunsPerDay: Int?, pausedUntil: Double?, nextDueAt: Double?, missedWhileClosed: Int, sources: [BackendRoutinesSourceView]
    public var wire: NativeRPCValue {
        func n(_ x: Double?) -> NativeRPCValue { x.map(NativeRPCValue.number) ?? .null }
        func s(_ x: String?) -> NativeRPCValue { x.map(NativeRPCValue.string) ?? .null }
        return .object([.init("id", .string(id)), .init("name", .string(name)), .init("file", .string(file)), .init("folder", s(folder)), .init("triggers", .array(triggers.map(NativeRPCValue.string))), .init("prompt", .string(prompt)), .init("enabled", .bool(enabled)), .init("overlap", s(overlap?.rawValue)), .init("state", .string(state)), .init("reason", s(reason)), .init("problems", .array(problems.map(NativeRPCValue.string))), .init("warnings", .array(warnings.map(NativeRPCValue.string))), .init("lastFiredAt", n(lastFiredAt)), .init("lastRunAt", n(lastRunAt)), .init("lastFinishedAt", n(lastFinishedAt)), .init("lastOutcome", s(lastOutcome)), .init("lastError", s(lastError)), .init("consecutiveFailures", .number(Double(consecutiveFailures))), .init("refusedCalls", .array(refusedCalls.map { .object([.init("at", .number($0.at)), .init("tool", .string($0.tool)), .init("reason", .string($0.reason)), .init("runId", .string($0.runId))]) })), .init("running", .bool(running)), .init("pending", .bool(pending)), .init("runsLastHour", .number(Double(runsLastHour))), .init("runsLastDay", .number(Double(runsLastDay))), .init("firesLastHour", .number(Double(firesLastHour))), .init("maxRunsPerHour", maxRunsPerHour.map { .number(Double($0)) } ?? .null), .init("maxRunsPerDay", maxRunsPerDay.map { .number(Double($0)) } ?? .null), .init("pausedUntil", n(pausedUntil)), .init("nextDueAt", n(nextDueAt)), .init("missedWhileClosed", .number(Double(missedWhileClosed))), .init("sources", .array(sources.map(\.wire)))])
    }
}

/// One-shot delay; never an interval. Injection keeps rule tests off real time.
public final class BackendRoutinesTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    public init(cancel: @escaping @Sendable () -> Void) { cancellation = cancel }
    public func cancel() { let callback = lock.withLock { let f = cancellation; cancellation = nil; return f }; callback?() }
    public static func schedule(_ callback: @escaping @Sendable () async -> Void, afterMs: Double) -> BackendRoutinesTimer {
        let task = Task { do { try await Task.sleep(for: .milliseconds(max(0, afterMs))) } catch { return }; guard !Task.isCancelled else { return }; await callback() }
        return BackendRoutinesTimer { task.cancel() }
    }
}

public struct BackendRoutinesEngineOptions: Sendable {
    public typealias WatchFiles = @Sendable (String, @escaping @Sendable (String) -> Void) throws -> @Sendable () -> Void
    public typealias WatchGit = @Sendable (String, @escaping @Sendable () -> Void) throws -> @Sendable () -> Void
    public let store: BackendRoutinesStore, runtime: BackendRoutinesRuntimeState
    public let log: BackendRoutinesLogger
    public let runner: (any BackendRoutinesRunner)?, control: BackendRoutinesToolCaller?
    public let allowFolder: @Sendable (String) -> String?
    public let globalMaxRunsPerHour: @Sendable () -> Double
    public let now: @Sendable () -> Double
    public let setTimer: @Sendable (@escaping @Sendable () async -> Void, Double) -> BackendRoutinesTimer
    public let watchFiles: WatchFiles?, watchGit: WatchGit?
    public init(store: BackendRoutinesStore, runtime: BackendRoutinesRuntimeState, log: @escaping BackendRoutinesLogger,
                runner: (any BackendRoutinesRunner)? = nil, control: BackendRoutinesToolCaller? = nil,
                allowFolder: @escaping @Sendable (String) -> String? = { _ in nil },
                globalMaxRunsPerHour: @escaping @Sendable () -> Double = { 60 },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                setTimer: @escaping @Sendable (@escaping @Sendable () async -> Void, Double) -> BackendRoutinesTimer = { BackendRoutinesTimer.schedule($0, afterMs: $1) },
                watchFiles: WatchFiles? = nil, watchGit: WatchGit? = nil) {
        self.store = store; self.runtime = runtime; self.log = log; self.runner = runner; self.control = control; self.allowFolder = allowFolder; self.globalMaxRunsPerHour = globalMaxRunsPerHour; self.now = now; self.setTimer = setTimer; self.watchFiles = watchFiles; self.watchGit = watchGit
    }
}

/// Events drive all triggers. The only clock wake-ups are a shared next-due
/// timer, an event's idle/quiet delay, and a cancellation grace deadline.
public actor BackendRoutinesEngine {
    public static let maxChainDepth = 3, maxConsecutiveFailures = 5
    public static let cancelGraceMs = 10_000.0, defaultGlobalMaxRunsPerHour = 60
    public static let triggerKinds = ["session-finished", "session-failed", "session-idle", "alert", "git-change", "file-change", "schedule", "manual"]
    private static let hour = 3_600_000.0, day = 86_400_000.0, maxTimeout = 2_147_483_647.0
    private struct Run: Sendable { let id: String, startedAt: Double, cancellation: BackendMCPCancellation; var cancelling = false }
    private struct Pending: Sendable { let cause: BackendRoutinesCause, chain: [String] }
    private final class Entry {
        let id: String, file: String
        var routine: BackendRoutinesRoutine?, problems: [String], warnings: [String]
        var armed = false, armProblem: String?, disposers: [@Sendable () -> Void] = []
        var running: Run?, pending: Pending?, quietTimer: BackendRoutinesTimer?, cancelTimer: BackendRoutinesTimer?
        var fires: [Double] = [], nextDueAt: Double?, scheduleAnchor: Double?, missedWhileClosed = 0
        init(_ item: BackendRoutinesStoredRoutine) { id = item.id; file = item.file; routine = item.routine; problems = item.problems; warnings = item.warnings }
    }
    private struct Session: Sendable { let cwd: String; var routineId: String?, runId: String? }
    private struct Source { var subscribed: Bool, note: String?, lastEventAt: Double?, events = 0 }
    private let options: BackendRoutinesEngineOptions
    private var runner: (any BackendRoutinesRunner)?, control: BackendRoutinesToolCaller?
    private var entries: [String: Entry] = [:], order: [String] = []
    private var sessions: [String: Session] = [:], sessionOrder: [String] = []
    private var runs: [String: [String]] = [:], runOrder: [String] = []
    private var sources: [String: Source] = [:], alertsSeen: [String: Set<String>] = [:], idleTimers: [String: BackendRoutinesTimer] = [:]
    private var scheduleTimer: BackendRoutinesTimer?, started = false, stopped = false
    public init(options: BackendRoutinesEngineOptions) {
        self.options = options; runner = options.runner; control = options.control
        for kind in Self.triggerKinds { let builtIn = kind == "manual" || kind == "schedule"; sources[kind] = Source(subscribed: builtIn, note: builtIn ? nil : "Nothing in this process has subscribed to this yet.", lastEventAt: nil) }
    }
    public func start() throws {
        guard !started, !stopped else { return }; started = true; reload()
        try options.store.startWatching(onChange: { [weak self] in Task { await self?.reload() } })
    }
    public func stop() {
        stopped = true
        for entry in entries.values { disarm(entry) }
        for timer in idleTimers.values { timer.cancel() }; idleTimers.removeAll()
        scheduleTimer?.cancel(); scheduleTimer = nil; options.runtime.stop(); options.store.stop()
    }
    public func setRunner(_ value: (any BackendRoutinesRunner)?) { runner = value; if started { reload() } }
    public func setControl(_ value: BackendRoutinesToolCaller?) { control = value }
    public func markSource(_ kind: String, subscribed: Bool, note: String? = nil) { guard var source = sources[kind] else { return }; source.subscribed = subscribed; source.note = note; sources[kind] = source }
    public func reload() {
        guard !stopped else { return }
        let stored = options.store.list(), present = Set(stored.map(\.id))
        for id in order where !present.contains(id) { if let entry = entries.removeValue(forKey: id) { disarm(entry) } }
        order = stored.map(\.id)
        for item in stored {
            let existing = entries[item.id], next = Entry(item)
            if let existing { next.running = existing.running; next.pending = existing.running == nil ? nil : existing.pending; next.fires = existing.fires; next.scheduleAnchor = existing.scheduleAnchor; next.cancelTimer = existing.cancelTimer; existing.cancelTimer = nil; disarm(existing, keepRun: true) }
            entries[item.id] = next; arm(next)
        }
        options.runtime.forgetMissing(present); rearmSchedule()
    }
    private func arm(_ entry: Entry) {
        guard let routine = entry.routine else { entry.armProblem = "This routine could not be read."; return }
        guard routine.enabled else { entry.armProblem = "Turned off in its file (`enabled: no`)."; return }
        if let paused = options.runtime.get(entry.id).pausedReason { entry.armProblem = paused; return }
        guard runner != nil else { entry.armProblem = "Hoot is not running in this build yet, so there is nothing for a routine to run through."; return }
        guard routine.folder.hasPrefix("/") else { entry.armProblem = "`in: \(routine.folder)` is not an absolute path."; return }
        if let problem = options.allowFolder(routine.folder) { entry.armProblem = problem; return }
        entry.armProblem = nil; entry.armed = true
        for trigger in routine.triggers {
            switch trigger {
            case .fileChange:
                guard let watch = options.watchFiles else { markSource("file-change", subscribed: false, note: "No file watcher is wired in this process."); continue }
                do { entry.disposers.append(try watch(routine.folder) { [weak self] path in Task { await self?.fileChanged(id: routine.id, folder: routine.folder, path: path) } }) }
                catch { markSource("file-change", subscribed: false, note: error.localizedDescription) }
            case .gitChange:
                guard let watch = options.watchGit else { markSource("git-change", subscribed: false, note: "No git watch is wired in this process."); continue }
                do { entry.disposers.append(try watch(routine.folder) { [weak self] in Task { await self?.gitChanged(id: routine.id, folder: routine.folder) } }) }
                catch { markSource("git-change", subscribed: false, note: error.localizedDescription) }
            case .schedule(let schedule):
                let now = options.now(), since = options.runtime.get(entry.id).runs.last
                if let since { entry.missedWhileClosed = BackendRoutinesScheduling.missedRuns(schedule, since: since, now: now); entry.scheduleAnchor = since }
                let due = BackendRoutinesScheduling.nextDue(schedule, from: now, anchor: entry.scheduleAnchor)
                entry.nextDueAt = min(entry.nextDueAt ?? due, due)
            default: break
            }
        }
    }
    private func disarm(_ entry: Entry, keepRun: Bool = false) {
        for dispose in entry.disposers { dispose() }; entry.disposers = []; entry.armed = false; entry.nextDueAt = nil
        entry.quietTimer?.cancel(); entry.quietTimer = nil; entry.cancelTimer?.cancel(); entry.cancelTimer = nil
        for key in Array(idleTimers.keys) where key.hasPrefix(entry.id + "\u{0}") { idleTimers.removeValue(forKey: key)?.cancel() }
        if !keepRun { entry.running?.cancellation.cancel() }
    }
    private func fileChanged(id: String, folder: String, path: String) {
        touchSource("file-change"); guard let entry = entries[id], let routine = entry.routine else { return }
        for trigger in routine.triggers { if case .fileChange(let glob) = trigger, BackendRoutinesGlob.matches(glob, path: path) { _ = fire(entry, cause: .fileChange(folder: folder, path: path), chain: []); return } }
    }
    private func gitChanged(id: String, folder: String) { touchSource("git-change"); if let entry = entries[id] { _ = fire(entry, cause: .gitChange(folder: folder), chain: []) } }
    public func noteSessionStarted(_ meta: BackendSessionMeta) { noteSessionStarted(id: meta.id, cwd: meta.cwd, originRoutineId: meta.originRoutineId, originRunId: meta.originRunId) }
    public func noteSessionStarted(id: String, cwd: String, originRoutineId: String? = nil, originRunId: String? = nil) {
        if sessions[id] == nil { if sessionOrder.count >= 500 { sessions[sessionOrder.removeFirst()] = nil }; sessionOrder.append(id) }
        sessions[id] = Session(cwd: cwd, routineId: originRoutineId, runId: originRunId)
    }
    public func noteSessionStatus(sessionId: String, status: BackendSessionStatus) {
        touchSource("session-idle"); let session = sessions[sessionId], quiet = status == .idle || status == .waiting
        for entry in entries.values {
            guard entry.armed, let routine = entry.routine else { continue }
            for trigger in routine.triggers {
                guard case .sessionIdle(let afterMs) = trigger else { continue }; let key = entry.id + "\u{0}" + sessionId
                idleTimers.removeValue(forKey: key)?.cancel()
                guard quiet, session == nil || Self.within(routine.folder, child: session!.cwd) else { continue }
                let id = entry.id
                idleTimers[key] = options.setTimer({ [weak self] in await self?.idleDue(key: key, id: id, sessionId: sessionId, afterMs: afterMs) }, afterMs)
            }
        }
    }
    private func idleDue(key: String, id: String, sessionId: String, afterMs: Double) { idleTimers[key] = nil; if let entry = entries[id] { _ = fire(entry, cause: .sessionIdle(sessionId: sessionId, afterMs: afterMs), chain: chainForSession(sessionId)) } }
    public func noteSessionExit(sessionId: String, exitCode: Int) {
        let kind = exitCode == 0 ? "session-finished" : "session-failed"; touchSource(kind)
        let session = sessions[sessionId], chain = chainForSession(sessionId)
        for key in Array(idleTimers.keys) where key.hasSuffix("\u{0}" + sessionId) { idleTimers.removeValue(forKey: key)?.cancel() }
        for entry in entries.values {
            guard entry.armed, let routine = entry.routine, session == nil || Self.within(routine.folder, child: session!.cwd), routine.triggers.contains(where: { $0.kind == kind }) else { continue }
            _ = fire(entry, cause: exitCode == 0 ? .sessionFinished(sessionId: sessionId, exitCode: exitCode) : .sessionFailed(sessionId: sessionId, exitCode: exitCode), chain: chain)
        }
        sessions[sessionId] = nil; sessionOrder.removeAll { $0 == sessionId }
    }
    /// Receives the same wire report already produced by BackendAlertsService;
    /// it never starts an alerts scan or another polling loop.
    public func noteAlertReport(_ report: NativeRPCValue) {
        guard let project = report["projectPath"].string, let alerts = report["alerts"].elements else { return }
        touchSource("alert"); let previous = alertsSeen[project] ?? []; alertsSeen[project] = Set(alerts.compactMap { $0["id"].string })
        for alert in alerts {
            guard let id = alert["id"].string, !previous.contains(id), let severity = alert["severity"].string, let title = alert["title"].string else { continue }
            for entry in entries.values {
                guard entry.armed, let routine = entry.routine, Self.within(routine.folder, child: project) else { continue }
                for trigger in routine.triggers {
                    guard case .alert(let filter, let alertKind) = trigger, filter == nil || filter == severity, alertKind == nil || alertKind == alert["kind"].string else { continue }
                    let session = alert["sessionId"].string
                    _ = fire(entry, cause: .alert(alertId: id, severity: severity, title: title, sessionId: session), chain: session.map(chainForSession) ?? []); break
                }
            }
        }
    }
    public func wake() { guard started, !stopped else { return }; fireDueSchedules(); rearmSchedule() }
    public func runNow(_ id: String, by: String = "user") -> BackendRoutinesRunResult {
        touchSource("manual")
        guard let entry = entries[id] else { return .init(started: false, reason: "There is no routine called `\(id)`.") }
        guard entry.routine != nil else { return .init(started: false, reason: entry.problems.first ?? "This routine could not be read.") }
        guard runner != nil else { return .init(started: false, reason: "Hoot is not running in this build yet, so there is nothing for a routine to run through.") }
        return fire(entry, cause: .manual(by: by), chain: [], ignoreQuiet: true)
    }
    public func pause(_ id: String, reason: String) -> Bool {
        guard let entry = entries[id] else { return false }; options.runtime.update(id, change: { $0.pausedReason = reason }, immediate: true); disarm(entry); arm(entry); return true
    }
    public func resume(_ id: String) -> Bool {
        guard let entry = entries[id] else { return false }; options.runtime.update(id, change: { $0.pausedReason = nil; $0.consecutiveFailures = 0 }, immediate: true); disarm(entry); arm(entry); rearmSchedule(); return true
    }
    private func touchSource(_ kind: String) { guard var source = sources[kind] else { return }; source.lastEventAt = options.now(); source.events += 1; source.subscribed = true; source.note = nil; sources[kind] = source }
    private func chainForSession(_ id: String) -> [String] { guard let session = sessions[id] else { return [] }; if let run = session.runId, let chain = runs[run] { return chain }; return session.routineId.map { [$0] } ?? [] }
    private func fire(_ entry: Entry, cause: BackendRoutinesCause, chain: [String], ignoreQuiet: Bool = false) -> BackendRoutinesRunResult {
        guard let routine = entry.routine, !stopped else { return .init(started: false, reason: "This routine cannot run.") }
        guard entry.armed else { return .init(started: false, reason: entry.armProblem ?? "This routine is not armed.") }
        let now = options.now(); entry.fires.append(now); entry.fires.removeAll { $0 <= now - Self.hour }; options.runtime.update(entry.id, change: { $0.lastFiredAt = now })
        if chain.contains(routine.id) { return refuse(entry, cause: cause, reason: "This would have been started by its own work.") }
        if chain.count >= Self.maxChainDepth { return refuse(entry, cause: cause, reason: "Refused after \(Self.maxChainDepth) routines in a row started each other: \((chain + [routine.id]).joined(separator: " → ")).") }
        if let problem = budgetProblem(routine, now: now) { return refuse(entry, cause: cause, reason: problem) }
        if entry.running != nil { return overlapping(entry, routine: routine, cause: cause, chain: chain) }
        if !ignoreQuiet, let last = options.runtime.get(entry.id).runs.last, now - last < routine.quietForMs {
            if routine.overlap == .skip { return refuse(entry, cause: cause, reason: "Within its quiet period, and set to skip.") }
            entry.pending = Pending(cause: cause, chain: chain)
            if entry.quietTimer == nil { let id = entry.id; entry.quietTimer = options.setTimer({ [weak self] in await self?.quietDue(id) }, routine.quietForMs - (now - last)) }
            return .init(started: false, reason: "Queued until its quiet period is over.")
        }
        return beginRun(entry, cause: cause, chain: chain)
    }
    private func quietDue(_ id: String) { guard let entry = entries[id] else { return }; entry.quietTimer = nil; let next = entry.pending; entry.pending = nil; if let next, entry.running == nil, entry.armed, !stopped { _ = beginRun(entry, cause: next.cause, chain: next.chain) } }
    private func overlapping(_ entry: Entry, routine: BackendRoutinesRoutine, cause: BackendRoutinesCause, chain: [String]) -> BackendRoutinesRunResult {
        if routine.overlap == .skip { return refuse(entry, cause: cause, reason: "Skipped: the previous run is still going.") }
        entry.pending = Pending(cause: cause, chain: chain)
        if routine.overlap == .cancel, var running = entry.running, !running.cancelling {
            running.cancelling = true; entry.running = running; running.cancellation.cancel()
            options.log(.init(action: "routine.cancel", routine: entry.id, runID: running.id, outcome: "failed", detail: "Cancelled because the trigger fired again."))
            let id = entry.id, runId = running.id
            entry.cancelTimer = options.setTimer({ [weak self] in await self?.cancelGraceDue(id, runId: runId) }, Self.cancelGraceMs)
            return .init(started: false, reason: "Cancelling the previous run.")
        }
        return .init(started: false, reason: "Queued behind the run that is going.")
    }
    private func cancelGraceDue(_ id: String, runId: String) { guard let entry = entries[id] else { return }; entry.cancelTimer = nil; guard entry.running?.id == runId else { return }; entry.pending = nil; options.log(.init(action: "routine.cancel", routine: id, runID: runId, outcome: "refused", detail: "The previous run did not stop when it was asked to, so the new one was dropped.")) }
    private func budgetProblem(_ routine: BackendRoutinesRoutine, now: Double) -> String? {
        let runtime = options.runtime.get(routine.id), lastHour = runtime.runs.filter { $0 > now - Self.hour }, lastDay = runtime.runs.filter { $0 > now - Self.day }
        if lastHour.count >= routine.maxRunsPerHour { return "Its hourly ceiling of \(routine.maxRunsPerHour) runs is used up. It can run again at \(Self.clock((lastHour.first ?? now) + Self.hour))." }
        if lastDay.count >= routine.maxRunsPerDay { return "Its daily ceiling of \(routine.maxRunsPerDay) runs is used up. It can run again at \(Self.clock((lastDay.first ?? now) + Self.day))." }
        let across = entries.keys.reduce(0) { $0 + options.runtime.get($1).runs.filter { $0 > now - Self.hour }.count }
        return Double(across) >= options.globalMaxRunsPerHour() ? "Every routine together has already run \(across) times this hour, which is this app's ceiling." : nil
    }
    private func refuse(_ entry: Entry, cause: BackendRoutinesCause, reason: String) -> BackendRoutinesRunResult { options.log(.init(action: "routine.skip", routine: entry.id, outcome: "refused", detail: reason, data: .object([.init("cause", .string(cause.kind))]))); return .init(started: false, reason: reason) }
    private func callerFor(_ id: String, runId: String) -> BackendRoutinesToolCaller? {
        guard let control else { return nil }
        return BackendRoutinesToolCaller(operation: { [weak self] name, args, cancellation in
            let result = await control.call(name, arguments: args, cancellation: cancellation)
            if let refusal = result.refusal { await self?.rememberRefusal(id, runId: runId, tool: result.row["tool"].string ?? name, reason: refusal.rawValue) }; return result
        })
    }
    private func rememberRefusal(_ id: String, runId: String, tool: String, reason: String) {
        let refusal = BackendRoutinesRefusal(at: options.now(), tool: tool, reason: reason, runId: runId)
        options.runtime.update(id, change: { $0.noteRefusal(refusal) }, immediate: true)
        options.log(.init(action: "routine.refused", routine: id, runID: runId, outcome: "refused", detail: reason == "not-permitted-unattended" ? "\(tool) needs a person to confirm it, and nothing was watching this run." : "\(tool) was refused: \(reason).", data: .object([.init("tool", .string(tool)), .init("reason", .string(reason))])))
    }
    private func beginRun(_ entry: Entry, cause: BackendRoutinesCause, chain: [String]) -> BackendRoutinesRunResult {
        guard let routine = entry.routine, let runner else { return .init(started: false, reason: "This routine cannot run.") }
        let id = entry.id, runId = UUID().uuidString.lowercased(), at = options.now(), cancellation = BackendMCPCancellation(), nextChain = chain + [routine.id]
        entry.running = Run(id: runId, startedAt: at, cancellation: cancellation)
        if runOrder.count >= 200 { runs[runOrder.removeFirst()] = nil }; runOrder.append(runId); runs[runId] = nextChain
        options.runtime.update(id, change: { $0.runs.append(at) }, immediate: true)
        options.log(.init(action: "routine.run", routine: id, runID: runId, outcome: "started", detail: cause.description, data: .object([.init("chain", .array(nextChain.map(NativeRPCValue.string))), .init("folder", .string(routine.folder))])))
        let request = BackendRoutinesRunRequest(routine: routine, runId: runId, cause: cause, chain: nextChain, cancellation: cancellation, control: callerFor(id, runId: runId))
        Task { let outcome = await runner.run(request); finishRun(id, runId: runId, startedAt: at, folder: routine.folder, outcome: outcome) }
        return .init(started: true, runId: runId)
    }
    private func finishRun(_ id: String, runId: String, startedAt: Double, folder: String, outcome: BackendRoutinesRunOutcome) {
        for sessionId in outcome.sessionIds {
            if var session = sessions[sessionId] { session.routineId = id; session.runId = runId; sessions[sessionId] = session }
            else { noteSessionStarted(id: sessionId, cwd: folder, originRoutineId: id, originRunId: runId) }
        }
        let at = options.now()
        options.runtime.update(id, change: { runtime in runtime.lastFinishedAt = at; runtime.lastOutcome = outcome.ok ? "ok" : "failed"; runtime.lastError = outcome.ok ? nil : BackendRoutinesExecutionText.prefix(outcome.error ?? "The run failed.", 500); runtime.consecutiveFailures = outcome.ok ? 0 : (runtime.consecutiveFailures == Int.max ? Int.max : runtime.consecutiveFailures + 1) }, immediate: true)
        options.log(.init(action: "routine.run", routine: id, runID: runId, outcome: outcome.ok ? "ok" : "failed", detail: outcome.ok ? nil : outcome.error, data: .object([.init("ms", .number(at - startedAt)), .init("sessions", .array(outcome.sessionIds.map(NativeRPCValue.string)))])))
        guard let entry = entries[id] else { return }
        if entry.running?.id == runId { entry.running = nil }; entry.cancelTimer?.cancel(); entry.cancelTimer = nil
        let runtime = options.runtime.get(id)
        if runtime.consecutiveFailures >= Self.maxConsecutiveFailures { entry.pending = nil; _ = pause(id, reason: "Stopped after \(runtime.consecutiveFailures) failures in a row. The last one said: \(runtime.lastError ?? "nothing")"); return }
        let pending = entry.pending; entry.pending = nil
        if let pending, !stopped, entry.armed { _ = fire(entry, cause: pending.cause, chain: pending.chain) }
    }
    private func rearmSchedule() {
        scheduleTimer?.cancel(); scheduleTimer = nil; guard !stopped, let earliest = entries.values.filter({ $0.armed }).compactMap(\.nextDueAt).min() else { return }
        scheduleTimer = options.setTimer({ [weak self] in await self?.scheduleDue() }, min(max(0, earliest - options.now()), Self.maxTimeout))
    }
    private func scheduleDue() { scheduleTimer = nil; fireDueSchedules(); rearmSchedule() }
    private func fireDueSchedules() {
        let now = options.now()
        for entry in entries.values {
            guard entry.armed, let routine = entry.routine, let due = entry.nextDueAt, due <= now else { continue }
            let missed = entry.missedWhileClosed; entry.missedWhileClosed = 0; entry.scheduleAnchor = due; entry.nextDueAt = nil
            for trigger in routine.triggers { if case .schedule(let schedule) = trigger { let next = BackendRoutinesScheduling.nextDue(schedule, from: now, anchor: due); entry.nextDueAt = min(entry.nextDueAt ?? next, next) } }
            touchSource("schedule"); _ = fire(entry, cause: .schedule(dueAt: due, missed: missed), chain: [], ignoreQuiet: true)
        }
    }
    public func list() -> [BackendRoutinesView] { let now = options.now(); return entries.keys.sorted().compactMap { entries[$0].map { view($0, now: now) } } }
    public func get(_ id: String) -> BackendRoutinesView? { entries[id].map { view($0, now: options.now()) } }
    private func view(_ entry: Entry, now: Double) -> BackendRoutinesView {
        let routine = entry.routine, runtime = options.runtime.get(entry.id), kinds = Set(routine?.triggers.map(\.kind) ?? [])
        let mine = Self.triggerKinds.filter { kinds.contains($0) }.map { kind in let source = sources[kind]; return BackendRoutinesSourceView(kind: kind, subscribed: source?.subscribed ?? false, lastEventAt: source?.lastEventAt, events: source?.events ?? 0, note: source?.note) }
        let health = health(entry, routine: routine, now: now, paused: runtime.pausedReason, sources: mine)
        return BackendRoutinesView(id: entry.id, name: routine?.name ?? entry.id, file: entry.file, folder: routine?.folder, triggers: routine?.triggers.map(BackendRoutinesFormat.serializeTrigger) ?? [], prompt: routine?.prompt ?? "", enabled: routine?.enabled ?? false, overlap: routine?.overlap, state: health.0, reason: health.1, problems: entry.problems, warnings: entry.warnings, lastFiredAt: runtime.lastFiredAt, lastRunAt: runtime.runs.last, lastFinishedAt: runtime.lastFinishedAt, lastOutcome: runtime.lastOutcome, lastError: runtime.lastError, consecutiveFailures: runtime.consecutiveFailures, refusedCalls: runtime.refusals, running: entry.running != nil, pending: entry.pending != nil, runsLastHour: runtime.runs.filter { $0 > now - Self.hour }.count, runsLastDay: runtime.runs.filter { $0 > now - Self.day }.count, firesLastHour: entry.fires.filter { $0 > now - Self.hour }.count, maxRunsPerHour: routine?.maxRunsPerHour, maxRunsPerDay: routine?.maxRunsPerDay, pausedUntil: health.2, nextDueAt: entry.nextDueAt, missedWhileClosed: entry.missedWhileClosed, sources: mine)
    }
    private func health(_ entry: Entry, routine: BackendRoutinesRoutine?, now: Double, paused: String?, sources: [BackendRoutinesSourceView]) -> (String, String?, Double?) {
        guard let routine else { return ("broken", entry.problems.first ?? "This routine could not be read.", nil) }
        if entry.running != nil { return ("running", nil, nil) }
        if !routine.enabled { return ("disabled", "Turned off in its file (`enabled: no`).", nil) }
        if let paused { return ("paused", paused, nil) }
        if let budget = budgetProblem(routine, now: now) { return ("paused", budget, options.runtime.get(entry.id).runs.first(where: { $0 > now - Self.hour }).map { $0 + Self.hour }) }
        if !entry.armed { return ("unarmed", entry.armProblem ?? "Not armed.", nil) }
        if let dead = sources.first(where: { !$0.subscribed }) { return ("unarmed", dead.note ?? "Nothing is subscribed to `\(dead.kind)` in this build.", nil) }
        if let expected = routine.expectEveryMs { let since = options.runtime.get(entry.id).lastFiredAt; if since == nil || now - since! > expected { return ("stale", since.map { "Nothing has fired this routine since \(Self.clock($0)), and it said it expected to by now." } ?? "This routine has never fired, and it said it expected to by now.", nil) } }
        return ("armed", nil, nil)
    }
    public nonisolated static func within(_ folder: String, child: String) -> Bool { let root = URL(fileURLWithPath: folder).standardizedFileURL.path, path = URL(fileURLWithPath: child).standardizedFileURL.path; return path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    private static func clock(_ at: Double) -> String { let components = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: at / 1000)); return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0) }
}

enum BackendRoutinesExecutionText {
    static func prefix(_ text: String, _ length: Int) -> String { String(decoding: text.utf16.prefix(length), as: UTF16.self) }
}
