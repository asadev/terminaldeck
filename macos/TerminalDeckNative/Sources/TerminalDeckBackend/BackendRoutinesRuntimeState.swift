import Foundation
import TerminalDeckNativeCore

public struct BackendRoutinesRefusal: Sendable, Equatable {
    public var at: Double, tool: String, reason: String, runId: String
    public init(at: Double, tool: String, reason: String, runId: String) { self.at = at; self.tool = tool; self.reason = reason; self.runId = runId }
    public var wire: NativeRPCValue { BackendRoutinesValues.object([("at", .number(at)), ("tool", .string(tool)), ("reason", .string(reason)), ("runId", .string(runId))]) }
}

public struct BackendRoutinesRuntime: Sendable, Equatable {
    public var runs: [Double] = []
    public var lastFiredAt: Double?, lastFinishedAt: Double?, lastOutcome: String?, lastError: String?
    public var consecutiveFailures: Int = 0
    public var pausedReason: String?
    public var refusals: [BackendRoutinesRefusal] = []
    public init() {}
    public mutating func noteRefusal(_ refusal: BackendRoutinesRefusal) {
        refusals.append(refusal); if refusals.count > 10 { refusals = Array(refusals.suffix(10)) }
    }
    public var wire: NativeRPCValue { BackendRoutinesValues.object([
        ("runs", .array(runs.map(NativeRPCValue.number))), ("lastFiredAt", BackendRoutinesValues.number(lastFiredAt)),
        ("lastFinishedAt", BackendRoutinesValues.number(lastFinishedAt)), ("lastOutcome", BackendRoutinesValues.text(lastOutcome)),
        ("lastError", BackendRoutinesValues.text(lastError)), ("consecutiveFailures", .number(Double(consecutiveFailures))),
        ("pausedReason", BackendRoutinesValues.text(pausedReason)), ("refusals", .array(refusals.map(\.wire)))]) }
}

/// runtime-state.ts. Run starts write immediately; other updates coalesce.
/// All access is synchronized because the engine and store watcher use separate
/// queues. Value snapshots can only change persisted state through `update`.
public final class BackendRoutinesRuntimeState: @unchecked Sendable {
    public static let version = 1
    public let fileURL: URL
    public var file: String { fileURL.path }
    private let now: @Sendable () -> Double, debounceMs: Double
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "dev.terminaldeck.routines.runtime", qos: .utility)
    private var routines: [String: BackendRoutinesRuntime]
    private var timer: DispatchWorkItem?
    private var persistenceError: String?
    public var lastPersistenceError: String? { lock.lock(); defer { lock.unlock() }; return persistenceError }
    public init(file: URL? = nil, userData: URL? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }, debounceMs: Double = 400) {
        fileURL = file ?? BackendRoutinesPaths.runtimeStateFileFor(userData ?? BackendRoutinesPaths.userData)
        self.now = now; self.debounceMs = debounceMs
        routines = Self.load(fileURL)
    }
    public static func emptyRuntime() -> BackendRoutinesRuntime { .init() }
    public static func noteRefusal(_ runtime: inout BackendRoutinesRuntime, refusal: BackendRoutinesRefusal) { runtime.noteRefusal(refusal) }
    public static func runtimeStateFileFor(_ userData: URL) -> URL { BackendRoutinesPaths.runtimeStateFileFor(userData) }
    public func get(_ id: String) -> BackendRoutinesRuntime {
        lock.lock(); defer { lock.unlock() }
        if let value = routines[id] { return value }
        let value = BackendRoutinesRuntime(); routines[id] = value; return value
    }
    public func update(_ id: String, change: (inout BackendRoutinesRuntime) -> Void, immediate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        var runtime = routines[id] ?? .init(); change(&runtime); routines[id] = runtime
        if immediate { flush() } else { schedule() }
    }
    public func forgetMissing(_ present: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let old = routines.count; routines = routines.filter { present.contains($0.key) }
        if routines.count != old { schedule() }
    }
    public func prune() {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now() - 25 * 60 * 60 * 1_000
        for id in Array(routines.keys) {
            guard var runtime = routines[id] else { continue }
            let kept = runtime.runs.filter { $0 >= cutoff }
            if kept.count != runtime.runs.count { runtime.runs = Array(kept.suffix(600)); routines[id] = runtime }
        }
    }
    private func schedule() {
        if debounceMs <= 0 { flush(); return }
        if timer != nil { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        timer = work; queue.asyncAfter(deadline: .now() + debounceMs / 1_000, execute: work)
    }
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil; prune()
        let data = BackendRoutinesValues.object([("version", .number(Double(Self.version))),
            ("routines", .object(routines.keys.sorted().map { .init($0, routines[$0]!.wire) }))])
        do { try BackendAccountFiles.writeAtomic(try data.encodedJSON(pretty: true), to: fileURL); persistenceError = nil }
        catch {
            // TS treats this as bookkeeping and keeps the engine alive. Expose
            // the failure so the assembled app can report persistence loss.
            persistenceError = error.localizedDescription
        }
    }
    public func stop() { flush() }
    private static func load(_ file: URL) -> [String: BackendRoutinesRuntime] {
        guard let bytes = try? Data(contentsOf: file), let raw = try? NativeRPCValue.parseJSON(bytes) else { return [:] }
        var result: [String: BackendRoutinesRuntime] = [:]
        for field in raw["routines"].spreadFields where field.key != "__proto__" {
            let value = field.value; var runtime = BackendRoutinesRuntime()
            runtime.runs = Array((value["runs"].elements ?? []).compactMap(\.number).suffix(600))
            runtime.lastFiredAt = value["lastFiredAt"].number; runtime.lastFinishedAt = value["lastFinishedAt"].number
            if let outcome = value["lastOutcome"].string, outcome == "ok" || outcome == "failed" { runtime.lastOutcome = outcome }
            if let error = value["lastError"].string { runtime.lastError = BackendRoutinesValues.slice(error, 500) }
            if let failures = value["consecutiveFailures"].number {
                runtime.consecutiveFailures = failures >= Double(Int.max) ? Int.max : Int(max(0, floor(failures)))
            }
            if let reason = value["pausedReason"].string { runtime.pausedReason = BackendRoutinesValues.slice(reason, 300) }
            runtime.refusals = Array((value["refusals"].elements ?? []).compactMap { entry -> BackendRoutinesRefusal? in
                guard entry.fields != nil, let at = entry["at"].number, let tool = entry["tool"].string,
                      let reason = entry["reason"].string, let runId = entry["runId"].string else { return nil }
                return .init(at: at, tool: BackendRoutinesValues.slice(tool, 100), reason: BackendRoutinesValues.slice(reason, 100), runId: BackendRoutinesValues.slice(runId, 100))
            }.suffix(10))
            result[field.key] = runtime
        }
        return result
    }
}
