import Foundation
import TerminalDeckNativeCore

public enum BackendRoutinesCause: Sendable, Equatable {
    case manual(by: String)
    case sessionFinished(sessionId: String, exitCode: Int)
    case sessionFailed(sessionId: String, exitCode: Int)
    case taskCreated(taskID: String, title: String)
    case taskFinished(taskID: String, title: String)
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
        case .taskCreated: return "task-created"
        case .taskFinished: return "task-finished"
        case .sessionIdle: return "session-idle"
        case .alert: return "alert"
        case .gitChange: return "git-change"
        case .fileChange: return "file-change"
        case .schedule: return "schedule"
        }
    }
    public var description: String {
        switch self {
        case .manual(let by): return RNMHootSettingsMigration.isHootOrigin(by) ? "Hoot asked for it." : "You asked for it."
        case .sessionFinished(let id, _): return "Session \(String(id.prefix(8))) finished."
        case .sessionFailed(let id, let code): return "Session \(String(id.prefix(8))) exited with code \(code)."
        case .taskCreated(_, let title): return "A task was created: \(title)."
        case .taskFinished(_, let title): return "A task finished: \(title)."
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
    public let output: String?, tokens: Double?, costUSD: Double?
    /// costUSD comes only from the task/account billing owner's trusted API
    /// report for this exact run. Subscription/unknown costs stay nil.
    public init(ok: Bool, sessionIds: [String] = [], error: String? = nil, output: String? = nil, tokens: Double? = nil, costUSD: Double? = nil) {
        self.ok = ok; self.sessionIds = sessionIds; self.error = error; self.output = output
        self.tokens = tokens.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.costUSD = costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
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
    public var pendingCount = 0, skippedCount = 0, replayRemaining = 0
    public var queueReason: String? = nil, catchUp: String? = nil
    public var maxPending = 10, maxCatchUp = 5
    public var projectID: String? = nil
    public var projectIdInferred: Bool = false
    public let id: String, name: String, file: String, folder: String?, triggers: [String], prompt: String
    public let enabled: Bool, overlap: BackendRoutinesOverlapPolicy?, state: String, reason: String?
    public let problems: [String], warnings: [String], lastFiredAt: Double?, lastRunAt: Double?, lastFinishedAt: Double?, lastOutcome: String?, lastError: String?
    public let consecutiveFailures: Int, refusedCalls: [BackendRoutinesRefusal], running: Bool, pending: Bool
    public let runsLastHour: Int, runsLastDay: Int, firesLastHour: Int, maxRunsPerHour: Int?, maxRunsPerDay: Int?, pausedUntil: Double?, nextDueAt: Double?, missedWhileClosed: Int, sources: [BackendRoutinesSourceView]
    public var wire: NativeRPCValue {
        func n(_ x: Double?) -> NativeRPCValue { x.map(NativeRPCValue.number) ?? .null }
        func s(_ x: String?) -> NativeRPCValue { x.map(NativeRPCValue.string) ?? .null }
        return .object([.init("pendingCount", .number(Double(pendingCount))), .init("skippedCount", .number(Double(skippedCount))), .init("replayRemaining", .number(Double(replayRemaining))), .init("queueReason", s(queueReason)), .init("catchUp", s(catchUp)), .init("maxPending", .number(Double(maxPending))), .init("maxCatchUp", .number(Double(maxCatchUp))), .init("id", .string(id)), .init("projectId", .string(PROJProjects.resolve(projectID: projectID, folder: folder))), .init("projectIdInferred", .bool(projectIdInferred)), .init("name", .string(name)), .init("file", .string(file)), .init("folder", s(folder)), .init("triggers", .array(triggers.map(NativeRPCValue.string))), .init("prompt", .string(prompt)), .init("enabled", .bool(enabled)), .init("overlap", s(overlap?.rawValue)), .init("state", .string(state)), .init("reason", s(reason)), .init("problems", .array(problems.map(NativeRPCValue.string))), .init("warnings", .array(warnings.map(NativeRPCValue.string))), .init("lastFiredAt", n(lastFiredAt)), .init("lastRunAt", n(lastRunAt)), .init("lastFinishedAt", n(lastFinishedAt)), .init("lastOutcome", s(lastOutcome)), .init("lastError", s(lastError)), .init("consecutiveFailures", .number(Double(consecutiveFailures))), .init("refusedCalls", .array(refusedCalls.map { .object([.init("at", .number($0.at)), .init("tool", .string($0.tool)), .init("reason", .string($0.reason)), .init("runId", .string($0.runId))]) })), .init("running", .bool(running)), .init("pending", .bool(pending)), .init("runsLastHour", .number(Double(runsLastHour))), .init("runsLastDay", .number(Double(runsLastDay))), .init("firesLastHour", .number(Double(firesLastHour))), .init("maxRunsPerHour", maxRunsPerHour.map { .number(Double($0)) } ?? .null), .init("maxRunsPerDay", maxRunsPerDay.map { .number(Double($0)) } ?? .null), .init("pausedUntil", n(pausedUntil)), .init("nextDueAt", n(nextDueAt)), .init("missedWhileClosed", .number(Double(missedWhileClosed))), .init("sources", .array(sources.map(\.wire)))])
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
    public static let triggerKinds = ["session-finished", "session-failed", "session-idle", "task-created", "task-finished", "alert", "git-change", "file-change", "schedule", "manual"]
    private static let hour = 3_600_000.0, day = 86_400_000.0, maxTimeout = 2_147_483_647.0
    private struct Run: Sendable { let id: String, startedAt: Double, cancellation: BackendMCPCancellation; let pending: Pending; var cancelling = false, retired = false }
    private struct Pending: Sendable {
        let identity = UUID().uuidString
        let cause: BackendRoutinesCause, chain: [String]
        var scheduleKey: String? = nil, consumeThrough: Double? = nil
        var ignoresQuiet = false
    }
    private struct ScheduleState { let schedule: BackendRoutinesSchedule; var nextDue: Double }
    private final class Entry {
        let id: String, file: String
        var routine: BackendRoutinesRoutine?, problems: [String], warnings: [String]
        var armed = false, armProblem: String?, disposers: [@Sendable () -> Void] = []
        var running: Run?, pending: [Pending] = [], quietTimer: BackendRoutinesTimer?, cancelTimer: BackendRoutinesTimer?
        var schedules: [String: ScheduleState] = [:], skippedCount = 0
        var queueReason: String?
        var consumedThrough: [String: Double] = [:]
        var fires: [Double] = [], nextDueAt: Double?, scheduleAnchor: Double?, missedWhileClosed = 0
        init(_ item: BackendRoutinesStoredRoutine) { id = item.id; file = item.file; routine = item.routine; problems = item.problems; warnings = item.warnings }
    }
    private struct Session: Sendable { let cwd: String; var routineId: String?, runId: String? }
    private struct Source { var subscribed: Bool, note: String?, lastEventAt: Double?, events = 0 }
    private let options: BackendRoutinesEngineOptions
    private var runner: (any BackendRoutinesRunner)?, control: BackendRoutinesToolCaller?
    private var entries: [String: Entry] = [:], order: [String] = []
    private var retiredRuns: [String: Run] = [:]
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
        for id in order where !present.contains(id) {
            if let entry = entries.removeValue(forKey: id) {
                if var run = entry.running { run.retired = true; retiredRuns[id] = run }
                disarm(entry)
            }
        }
        order = stored.map(\.id)
        for item in stored {
            let existing = entries[item.id], next = Entry(item)
            if let existing {
                next.running = existing.running; next.fires = existing.fires; next.scheduleAnchor = existing.scheduleAnchor
                next.consumedThrough = existing.consumedThrough
                next.skippedCount = existing.skippedCount; next.queueReason = existing.queueReason
                next.cancelTimer = existing.cancelTimer; existing.cancelTimer = nil
                if existing.routine == next.routine, next.routine?.enabled == true {
                    next.pending = existing.pending; existing.pending = []
                    next.schedules = existing.schedules; next.nextDueAt = existing.nextDueAt
                    next.quietTimer = existing.quietTimer; existing.quietTimer = nil
                } else {
                    discardPending(existing, reason: "Pending triggers cleared because the routine changed or was disabled.")
                    options.runtime.update(item.id, change: { $0.scheduleCursors = [:] }, immediate: true)
                }
                disarm(existing, keepRun: true)
            }
            if existing == nil, let retired = retiredRuns.removeValue(forKey: item.id) {
                next.running = retired
                options.runtime.update(item.id, change: { $0.activeRunID = retired.id; $0.pausedReason = "The removed routine still has an unfinished run. Check its work before resuming." }, immediate: true)
            }
            entries[item.id] = next; arm(next)
            if !next.armed { discardPending(next, reason: next.armProblem ?? "Routine is not armed."); next.quietTimer?.cancel(); next.quietTimer = nil; next.cancelTimer?.cancel(); next.cancelTimer = nil }
        }
        options.runtime.forgetMissing(present); rearmSchedule()
    }
    private func arm(_ entry: Entry) {
        guard let routine = entry.routine else { entry.armProblem = "This routine could not be read."; return }
        guard routine.enabled else { entry.armProblem = "Turned off in its file (`enabled: no`)."; return }
        let checkpoint = options.runtime.get(entry.id)
        if entry.running == nil, entry.pending.isEmpty, checkpoint.activeRunID != nil || checkpoint.pendingAtCheckpoint > 0 {
            let reason = "A previous app process left a run or pending triggers unfinished. Check its work, then resume; pending event triggers are not restored and old scheduled times will be skipped."
            options.runtime.update(entry.id, change: { $0.pausedReason = reason }, immediate: true)
        }
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
                let now = options.now(), key = BackendRoutinesScheduling.serialize(schedule)
                guard entry.schedules[key] == nil else { continue }
                let due: Double
                if routine.catchUp != nil {
                    let cursor = options.runtime.get(entry.id).scheduleCursors[key] ?? now
                    if options.runtime.get(entry.id).scheduleCursors[key] == nil { options.runtime.update(entry.id, change: { $0.scheduleCursors[key] = now }, immediate: true) }
                    due = BackendRoutinesScheduling.nextDue(schedule, from: cursor, anchor: cursor)
                } else {
                    let since = options.runtime.get(entry.id).runs.last
                    if let since { entry.missedWhileClosed = BackendRoutinesScheduling.missedRuns(schedule, since: since, now: now); entry.scheduleAnchor = since }
                    due = BackendRoutinesScheduling.nextDue(schedule, from: now, anchor: entry.scheduleAnchor)
                }
                entry.schedules[key] = ScheduleState(schedule: schedule, nextDue: due)
                entry.nextDueAt = min(entry.nextDueAt ?? due, due)
            default: break
            }
        }
    }
    private func disarm(_ entry: Entry, keepRun: Bool = false) {
        for dispose in entry.disposers { dispose() }; entry.disposers = []; entry.armed = false; entry.nextDueAt = nil; entry.schedules = [:]
        entry.quietTimer?.cancel(); entry.quietTimer = nil; entry.cancelTimer?.cancel(); entry.cancelTimer = nil
        for key in Array(idleTimers.keys) where key.hasPrefix(entry.id + "\u{0}") { idleTimers.removeValue(forKey: key)?.cancel() }
        if !keepRun { discardPending(entry, reason: "Pending triggers cleared because the routine stopped."); entry.running?.cancellation.cancel() }
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
    public func noteTaskEvent(kind: String, task: BackendTaskRecord) {
        guard kind == "task-created" || kind == "task-finished", !task.project.isEmpty else { return }
        let taskProjectID = PROJProjects.resolve(projectID: task.value["projectId"].string, folder: task.project)
        let originRoutine = task.value["originRoutineId"].string, originRun = task.value["originRunId"].string
        let chain: [String]
        if let originRun {
            guard let known = runs[originRun], originRoutine == nil || known.contains(originRoutine!) else { return }
            chain = known
        } else if let originRoutine { chain = [originRoutine] }
        else {
            guard task.value["origin"].string != "routine", task.value["requestedBy"].string != "routine" else { return }
            chain = []
        }
        touchSource(kind)
        let title = task.value["title"].string ?? "Task"
        for entry in entries.values {
            guard entry.armed, let routine = entry.routine,
                  routine.projectID == "every-project" || routine.projectID == taskProjectID,
                  routine.triggers.contains(where: { $0.kind == kind }) else { continue }
            _ = fire(entry, cause: kind == "task-created" ? .taskCreated(taskID: task.id, title: title) : .taskFinished(taskID: task.id, title: title), chain: chain)
        }
    }
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
    /// #357: switched off and on again while a run is still stopping, the routine is on again at once; that run
    /// keeps its checkpoint and finishes by itself. Only a removed routine's unfinished run still refuses.
    public func resume(_ id: String) -> Bool {
        guard let entry = entries[id], entry.running?.retired != true else { return false }
        let stopping = entry.running != nil
        options.runtime.update(id, change: { $0.pausedReason = nil; $0.consecutiveFailures = 0; if !stopping { $0.activeRunID = nil }; $0.pendingAtCheckpoint = 0; $0.scheduleCursors = [:] }, immediate: true); disarm(entry, keepRun: stopping); arm(entry); rearmSchedule(); return true
    }
    private func touchSource(_ kind: String) { guard var source = sources[kind] else { return }; source.lastEventAt = options.now(); source.events += 1; source.subscribed = true; source.note = nil; sources[kind] = source }
    private func chainForSession(_ id: String) -> [String] { guard let session = sessions[id] else { return [] }; if let run = session.runId, let chain = runs[run] { return chain }; return session.routineId.map { [$0] } ?? [] }
    private func recordFire(_ entry: Entry) {
        let now = options.now(); entry.fires.append(now); entry.fires.removeAll { $0 <= now - Self.hour }
        options.runtime.update(entry.id, change: { $0.lastFiredAt = now })
    }
    private func fire(_ entry: Entry, cause: BackendRoutinesCause, chain: [String], ignoreQuiet: Bool = false) -> BackendRoutinesRunResult {
        recordFire(entry)
        return accept(entry, next: Pending(cause: cause, chain: chain, ignoresQuiet: ignoreQuiet))
    }
    private func accept(_ entry: Entry, next incoming: Pending, replay: Bool = false) -> BackendRoutinesRunResult {
        var next = incoming
        // Legacy busy/manual firings still settle through the quiet period.
        // Explicit replay and queue-each carry their original source timing.
        if !replay, entry.running != nil, entry.routine?.overlap != .queueAll { next.ignoresQuiet = false }
        guard let routine = entry.routine, !stopped, entry.armed else {
            return reject(entry, next: next, reason: entry.armProblem ?? "This routine is not armed.")
        }
        if next.chain.contains(routine.id) { return reject(entry, next: next, reason: "This would have been started by its own work.") }
        if next.chain.count >= Self.maxChainDepth { return reject(entry, next: next, reason: "Refused after \(Self.maxChainDepth) routines in a row started each other: \((next.chain + [routine.id]).joined(separator: " → ")).") }
        if let problem = budgetProblem(routine, now: options.now()) { return reject(entry, next: next, reason: problem) }
        if entry.running != nil || !entry.pending.isEmpty || quietDelay(entry, next: next) > 0 {
            if !replay, routine.overlap == .skip { return reject(entry, next: next, reason: "Skipped: the previous run is still going or within its quiet period.") }
            // Replay is explicitly serial, regardless of event overlap policy.
            if replay || routine.overlap == .queueAll {
                let limit = replay ? max(routine.maxCatchUp, routine.maxPending) : routine.maxPending
                guard entry.pending.count < limit else { return reject(entry, next: next, reason: "Pending queue is full (limit \(limit)); newest trigger refused.") }
                entry.pending.append(next)
            } else {
                let replaced = entry.pending; entry.pending = [next]
                for item in replaced { consume(entry, next: item) }
                entry.skippedCount += replaced.count
                if !replaced.isEmpty { entry.queueReason = "Pending triggers combined; keeping the latest." }
            }
            checkpointQueue(entry)
            if routine.overlap == .cancel, !replay, var running = entry.running, !running.cancelling {
                running.cancelling = true; entry.running = running; running.cancellation.cancel()
                options.log(.init(action: "routine.cancel", routine: entry.id, runID: running.id, outcome: "failed", detail: "Cancelled because the trigger fired again."))
                let id = entry.id, runId = running.id
                entry.cancelTimer = options.setTimer({ [weak self] in await self?.cancelGraceDue(id, runId: runId) }, Self.cancelGraceMs)
            }
            drain(entry)
            return .init(started: false, reason: "Queued; \(entry.pending.count) pending.")
        }
        return beginRun(entry, next: next)
    }
    private func quietDelay(_ entry: Entry, next: Pending) -> Double {
        guard !next.ignoresQuiet, let routine = entry.routine, let last = options.runtime.get(entry.id).runs.last else { return 0 }
        return max(0, routine.quietForMs - (options.now() - last))
    }
    private func checkpointQueue(_ entry: Entry) {
        options.runtime.update(entry.id, change: { $0.pendingAtCheckpoint = entry.pending.count }, immediate: true)
    }
    private func consume(_ entry: Entry, next: Pending) {
        guard let key = next.scheduleKey, let through = next.consumeThrough else { return }
        let horizon = max(entry.consumedThrough[key] ?? 0, through)
        entry.consumedThrough[key] = horizon
        let outstanding = entry.pending + (entry.running.map { [$0.pending] } ?? [])
        guard !outstanding.contains(where: { item in
            guard item.identity != next.identity, item.scheduleKey == key, case .schedule(let due, _) = item.cause else { return false }
            return due <= horizon
        }) else { return }
        options.runtime.update(entry.id, change: { $0.scheduleCursors[key] = max($0.scheduleCursors[key] ?? 0, horizon) }, immediate: true)
        entry.consumedThrough[key] = nil
    }
    private func reject(_ entry: Entry, next: Pending, reason: String) -> BackendRoutinesRunResult {
        entry.skippedCount += 1; entry.queueReason = reason; consume(entry, next: next)
        return refuse(entry, cause: next.cause, reason: reason)
    }
    private func discardPending(_ entry: Entry, reason: String) {
        guard !entry.pending.isEmpty else { return }
        let pending = entry.pending; entry.pending = []; checkpointQueue(entry)
        for next in pending { _ = reject(entry, next: next, reason: reason) }
    }
    private func drain(_ entry: Entry) {
        guard entry.running == nil, !entry.pending.isEmpty, !stopped else { return }
        guard entry.armed else { discardPending(entry, reason: "Pending triggers cleared because the routine is not armed."); return }
        let next = entry.pending[0], delay = quietDelay(entry, next: next)
        if delay > 0 {
            if entry.quietTimer == nil { let id = entry.id; entry.quietTimer = options.setTimer({ [weak self] in await self?.quietDue(id) }, delay) }
            return
        }
        entry.pending.removeFirst(); checkpointQueue(entry)
        if let routine = entry.routine, let problem = budgetProblem(routine, now: options.now()) {
            _ = reject(entry, next: next, reason: problem); drain(entry); return
        }
        if let routine = entry.routine, next.chain.contains(routine.id) || next.chain.count >= Self.maxChainDepth {
            _ = reject(entry, next: next, reason: "Pending trigger refused by the routine chain guard."); drain(entry); return
        }
        _ = beginRun(entry, next: next)
    }
    private func quietDue(_ id: String) { guard let entry = entries[id] else { return }; entry.quietTimer = nil; drain(entry) }
    private func cancelGraceDue(_ id: String, runId: String) {
        guard let entry = entries[id], entry.running?.id == runId else { return }
        entry.cancelTimer = nil; discardPending(entry, reason: "The previous run did not stop when asked, so pending triggers were dropped.")
    }
    /// `across` is every routine's runs this hour; a list counts it once for all its rows.
    private func budgetProblem(_ routine: BackendRoutinesRoutine, now: Double, across counted: Int? = nil) -> String? {
        let runtime = options.runtime.get(routine.id), lastHour = runtime.runs.filter { $0 > now - Self.hour }, lastDay = runtime.runs.filter { $0 > now - Self.day }
        if lastHour.count >= routine.maxRunsPerHour { return "Its hourly ceiling of \(routine.maxRunsPerHour) runs is used up. It can run again at \(Self.clock((lastHour.first ?? now) + Self.hour))." }
        if lastDay.count >= routine.maxRunsPerDay { return "Its daily ceiling of \(routine.maxRunsPerDay) runs is used up. It can run again at \(Self.clock((lastDay.first ?? now) + Self.day))." }
        let across = counted ?? runsThisHour(now)
        return Double(across) >= options.globalMaxRunsPerHour() ? "Every routine together has already run \(across) times this hour, which is this app's ceiling." : nil
    }
    private func runsThisHour(_ now: Double) -> Int { entries.keys.reduce(0) { $0 + options.runtime.get($1).runs.filter { $0 > now - Self.hour }.count } }
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
    private func beginRun(_ entry: Entry, next: Pending) -> BackendRoutinesRunResult {
        guard let routine = entry.routine, let runner else { return .init(started: false, reason: "This routine cannot run.") }
        guard entry.running == nil, entry.armed, !stopped else { return reject(entry, next: next, reason: "This routine is already running or stopped.") }
        let cause = next.cause, chain = next.chain
        let id = entry.id, runId = UUID().uuidString.lowercased(), at = options.now(), cancellation = BackendMCPCancellation(), nextChain = chain + [routine.id]
        entry.running = Run(id: runId, startedAt: at, cancellation: cancellation, pending: next)
        if runOrder.count >= 200 { runs[runOrder.removeFirst()] = nil }; runOrder.append(runId); runs[runId] = nextChain
        options.runtime.update(id, change: { $0.runs.append(at); $0.activeRunID = runId }, immediate: true)
        if let error = options.runtime.lastPersistenceError {
            entry.running = nil
            options.runtime.update(id, change: { $0.activeRunID = nil; if !$0.runs.isEmpty { $0.runs.removeLast() } }, immediate: true)
            let reason = "Could not save the run checkpoint, so nothing was started: " + error
            _ = pause(id, reason: reason)
            return refuse(entry, cause: cause, reason: reason)
        }
        options.log(.init(action: "routine.run", routine: id, runID: runId, outcome: "started", detail: cause.description, data: .object([.init("cause", .string(cause.kind)), .init("scheduleKey", next.scheduleKey.map(NativeRPCValue.string) ?? .null), .init("dueAt", { if case .schedule(let due, _) = cause { return NativeRPCValue.number(due) }; return .null }()), .init("agentId", .string(routine.routinesAgentID)), .init("projectId", .string(routine.projectID)), .init("projectIdInferred", .bool(routine.projectIdInferred)), .init("name", .string(routine.name)), .init("chain", .array(nextChain.map(NativeRPCValue.string))), .init("folder", .string(routine.folder))])))
        let request = BackendRoutinesRunRequest(routine: routine, runId: runId, cause: cause, chain: nextChain, cancellation: cancellation, control: callerFor(id, runId: runId))
        Task { let outcome = await runner.run(request); finishRun(id, runId: runId, startedAt: at, folder: routine.folder, outcome: outcome) }
        return .init(started: true, runId: runId)
    }
    private func finishRun(_ id: String, runId: String, startedAt: Double, folder: String, outcome: BackendRoutinesRunOutcome) {
        guard let entry = entries[id], entry.running?.id == runId else {
            if retiredRuns[id]?.id == runId {
                retiredRuns[id] = nil
                options.runtime.update(id, change: { $0.activeRunID = nil }, immediate: true)
            }
            return
        }
        if entry.running?.retired == true {
            entry.running = nil
            options.runtime.update(id, change: { $0.activeRunID = nil }, immediate: true)
            return
        }
        let completed = entry.running!.pending
        for sessionId in outcome.sessionIds {
            if var session = sessions[sessionId] { session.routineId = id; session.runId = runId; sessions[sessionId] = session }
            else { noteSessionStarted(id: sessionId, cwd: folder, originRoutineId: id, originRunId: runId) }
        }
        let at = options.now()
        consume(entry, next: completed)
        options.runtime.update(id, change: { runtime in runtime.activeRunID = nil; runtime.lastFinishedAt = at; runtime.lastOutcome = outcome.ok ? "ok" : "failed"; runtime.lastError = outcome.ok ? nil : BackendRoutinesExecutionText.prefix(outcome.error ?? "The run failed.", 500); runtime.consecutiveFailures = outcome.ok ? 0 : (runtime.consecutiveFailures == Int.max ? Int.max : runtime.consecutiveFailures + 1) }, immediate: true)
        options.log(.init(action: "routine.run", routine: id, runID: runId, outcome: outcome.ok ? "ok" : "failed", detail: outcome.ok ? nil : outcome.error, data: .object([.init("ms", .number(at - startedAt)), .init("sessions", .array(outcome.sessionIds.map(NativeRPCValue.string))), .init("output", outcome.output.map { .string(String($0.prefix(16_000))) } ?? .null), .init("tokens", outcome.tokens.map(NativeRPCValue.number) ?? .null), .init("costUSD", outcome.costUSD.map(NativeRPCValue.number) ?? .null)])))
        entry.running = nil; entry.cancelTimer?.cancel(); entry.cancelTimer = nil
        let runtime = options.runtime.get(id)
        if runtime.consecutiveFailures >= Self.maxConsecutiveFailures { discardPending(entry, reason: "Pending triggers cleared after repeated failures."); _ = pause(id, reason: "Stopped after \(runtime.consecutiveFailures) failures in a row. The last one said: \(runtime.lastError ?? "nothing")"); return }
        drain(entry)
    }
    private func rearmSchedule() {
        scheduleTimer?.cancel(); scheduleTimer = nil; guard !stopped, let earliest = entries.values.filter({ $0.armed }).compactMap(\.nextDueAt).min() else { return }
        scheduleTimer = options.setTimer({ [weak self] in await self?.scheduleDue() }, min(max(0, earliest - options.now()), Self.maxTimeout))
    }
    private func scheduleDue() { scheduleTimer = nil; fireDueSchedules(); rearmSchedule() }
    private func fireDueSchedules() {
        let now = options.now()
        for entry in entries.values {
            guard entry.armed, let routine = entry.routine else { continue }
            var ready: [Pending] = []
            for key in entry.schedules.keys.sorted() {
                guard var state = entry.schedules[key], state.nextDue <= now else { continue }
                let due = state.nextDue
                state.nextDue = BackendRoutinesScheduling.nextDue(state.schedule, from: now, anchor: due)
                entry.schedules[key] = state
                guard let policy = routine.catchUp else {
                    let missed = entry.missedWhileClosed; entry.missedWhileClosed = 0
                    ready.append(Pending(cause: .schedule(dueAt: due, missed: missed), chain: [], ignoresQuiet: true)); continue
                }
                // A repeated wake cannot rediscover an accepted occurrence: nextDue
                // moves in memory; only completion/refusal advances the durable cursor.
                if policy == .skip, now - due > 1_000 {
                    recordFire(entry); touchSource("schedule")
                    _ = reject(entry, next: Pending(cause: .schedule(dueAt: due, missed: 0), chain: [], scheduleKey: key, consumeThrough: now), reason: "Missed scheduled times skipped by policy."); continue
                }
                let projection = BackendRoutinesPolicies.occurrences(state.schedule, after: due - 1, through: now, limit: routine.maxCatchUp)
                // Interval enumeration must keep the original due instant as its anchor.
                var times = [due]
                if case .every = state.schedule {
                    times += BackendRoutinesPolicies.occurrences(state.schedule, after: due, through: now, limit: routine.maxCatchUp).times
                } else {
                    times = projection.times
                    if projection.hasMore, let last = times.last { times.append(BackendRoutinesScheduling.nextDue(state.schedule, from: last)) }
                }
                if policy != .replay { times = [due] }
                for (index, time) in times.enumerated() {
                    ready.append(Pending(cause: .schedule(dueAt: time, missed: 0), chain: [], scheduleKey: key, consumeThrough: index == times.count - 1 ? now : time, ignoresQuiet: true))
                }
            }
            ready.sort { a, b in
                guard case .schedule(let left, _) = a.cause, case .schedule(let right, _) = b.cause else { return false }
                return left == right ? (a.scheduleKey ?? "") < (b.scheduleKey ?? "") : left < right
            }
            let limit = routine.catchUp == .replay ? routine.maxCatchUp : (routine.catchUp == .skip ? ready.count : 1)
            let selected = Array(ready.prefix(limit)), excess = Array(ready.dropFirst(limit))
            if !excess.isEmpty {
                entry.skippedCount += excess.count
                entry.queueReason = routine.catchUp == .replay ? "Replay cap reached; extra missed times skipped (at least \(excess.count))." : "Missed schedules combined into one run; \(excess.count) additional triggers skipped."
                options.log(.init(action: "routine.skip", routine: entry.id, outcome: "refused", detail: entry.queueReason))
                // The last accepted occurrence for each trigger carries its horizon.
                // Triggers with no selected occurrence are deliberately skipped now.
                for item in excess where !selected.contains(where: { $0.scheduleKey == item.scheduleKey }) { consume(entry, next: item) }
            }
            for item in selected {
                var next = item
                if let key = item.scheduleKey, !excess.filter({ $0.scheduleKey == key }).isEmpty,
                   selected.last(where: { $0.scheduleKey == key })?.consumeThrough == item.consumeThrough { next.consumeThrough = now }
                touchSource("schedule")
                if routine.catchUp == nil { _ = fire(entry, cause: next.cause, chain: [], ignoreQuiet: true) }
                else { recordFire(entry); _ = accept(entry, next: next, replay: routine.catchUp == .replay) }
            }
            entry.nextDueAt = entry.schedules.values.map(\.nextDue).min()
        }
    }
    public func list() -> [BackendRoutinesView] { let now = options.now(), across = runsThisHour(now); return entries.keys.sorted().compactMap { entries[$0].map { view($0, now: now, across: across) } } }
    public func get(_ id: String) -> BackendRoutinesView? { entries[id].map { view($0, now: options.now()) } }
    private func view(_ entry: Entry, now: Double, across: Int? = nil) -> BackendRoutinesView {
        let routine = entry.routine, runtime = options.runtime.get(entry.id), kinds = Set(routine?.triggers.map(\.kind) ?? [])
        let mine = Self.triggerKinds.filter { kinds.contains($0) }.map { kind in let source = sources[kind]; return BackendRoutinesSourceView(kind: kind, subscribed: source?.subscribed ?? false, lastEventAt: source?.lastEventAt, events: source?.events ?? 0, note: source?.note) }
        let health = health(entry, routine: routine, now: now, paused: runtime.pausedReason, sources: mine, across: across)
        var projected = BackendRoutinesView(id: entry.id, name: routine?.name ?? entry.id, file: entry.file, folder: routine?.folder, triggers: routine?.triggers.map(BackendRoutinesFormat.serializeTrigger) ?? [], prompt: routine?.prompt ?? "", enabled: routine?.enabled ?? false, overlap: routine?.overlap, state: health.0, reason: health.1, problems: entry.problems, warnings: entry.warnings, lastFiredAt: runtime.lastFiredAt, lastRunAt: runtime.runs.last, lastFinishedAt: runtime.lastFinishedAt, lastOutcome: runtime.lastOutcome, lastError: runtime.lastError, consecutiveFailures: runtime.consecutiveFailures, refusedCalls: runtime.refusals, running: entry.running != nil, pending: !entry.pending.isEmpty, runsLastHour: runtime.runs.filter { $0 > now - Self.hour }.count, runsLastDay: runtime.runs.filter { $0 > now - Self.day }.count, firesLastHour: entry.fires.filter { $0 > now - Self.hour }.count, maxRunsPerHour: routine?.maxRunsPerHour, maxRunsPerDay: routine?.maxRunsPerDay, pausedUntil: health.2, nextDueAt: entry.nextDueAt, missedWhileClosed: entry.missedWhileClosed, sources: mine)
        projected.pendingCount = entry.pending.count; projected.skippedCount = entry.skippedCount
        projected.queueReason = entry.queueReason; projected.catchUp = routine?.catchUp?.rawValue
        projected.maxPending = routine?.maxPending ?? 10; projected.maxCatchUp = routine?.maxCatchUp ?? 5
        projected.replayRemaining = entry.pending.filter { $0.scheduleKey != nil }.count
        projected.projectID = routine?.projectID
        projected.projectIdInferred = routine?.projectIdInferred ?? false
        return projected
    }
    private func health(_ entry: Entry, routine: BackendRoutinesRoutine?, now: Double, paused: String?, sources: [BackendRoutinesSourceView], across: Int? = nil) -> (String, String?, Double?) {
        guard let routine else { return ("broken", entry.problems.first ?? "This routine could not be read.", nil) }
        if entry.running != nil { return ("running", nil, nil) }
        if !routine.enabled { return ("disabled", "Turned off in its file (`enabled: no`).", nil) }
        if let paused { return ("paused", paused, nil) }
        if let budget = budgetProblem(routine, now: now, across: across) { return ("paused", budget, options.runtime.get(entry.id).runs.first(where: { $0 > now - Self.hour }).map { $0 + Self.hour }) }
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
