import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckToolsRootPortTourSupport {
    static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    static func stop(quote: String = "the build failed", note: String = "it failed", why: String = "files-changed", session: String = "s1") -> NativeRPCValue {
        o([("kind", .string("screen")), ("sessionId", .string(session)), ("quote", .string(quote)), ("note", .string(note)), ("why", .string(why))])
    }
    static func plan(_ stops: [NativeRPCValue]) -> NativeRPCValue { o([("question", .string("what happened?")), ("headline", .string("this happened")), ("stops", .array(stops))]) }
    struct Evidence: BackendDeckToolsTourEvidence {
        let screen: String, changed: [String], attention: String, attentionReason: String
        init(screen: String = "the build failed", changed: [String] = ["a.ts"], attention: String = "quiet", reason: String = "no-output") { self.screen = screen; self.changed = changed; self.attention = attention; attentionReason = reason }
        func facts(sessionID: String) async throws -> NativeRPCValue? {
            if sessionID != "s1" { return nil }
            return o([("session", o([("id", .string("s1")), ("cwd", .string("/work/api"))])), ("title", .string("api")),
                ("screen", .string(screen)), ("changed", .array(changed.map(NativeRPCValue.string))),
                ("importance", o([("attention", .string(attention)), ("attentionReason", .string(attentionReason)), ("exitCode", .null),
                    ("changedFiles", .number(Double(changed.count))), ("progress", .null), ("totalTokens", .null), ("lastMessage", .null)]))])
        }
        func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool {
            BackendDeckCoreImportance.supports(reason, input: importance, fleet: .init(medianTokens: median, sample: sample))
        }
    }
    static func checked(_ stops: [NativeRPCValue], evidence: Evidence = .init()) async throws -> BackendDeckToolsTour.Validated {
        try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan(stops)), evidence: evidence)
    }
    /// Shared core clock interface; advancing invokes due callbacks without
    /// sleeping. The callbacks enqueue actor work, which awaiting play observes.
    final class Clock: BackendDeckCoreEventsClock, @unchecked Sendable {
        private let lock = NSLock()
        private var instant = 1000.0
        private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
        func now() -> Double { lock.withLock { instant } }
        func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
            let id = UUID(); lock.withLock { timers[id] = (instant + milliseconds, run) }; return id
        }
        func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
        func advance(_ milliseconds: Double) {
            let callbacks: [@Sendable () -> Void] = lock.withLock {
                instant += milliseconds
                let due = timers.filter { $0.value.0 <= instant }.sorted { $0.value.0 < $1.value.0 }
                for entry in due { timers[entry.key] = nil }; return due.map { $0.value.1 }
            }
            callbacks.forEach { $0() }
        }
    }
    actor Window: BackendDeckToolsTourWindow {
        let available: Bool
        private var offers: [TourMessage] = []
        private var waiters: [CheckedContinuation<TourMessage, Never>] = []
        private var watchers: [UUID: @Sendable () -> Void] = [:]
        private var beforeSend: (@Sendable (TourMessage) -> Void)?
        private var unwatches = 0
        private var unwatchWaiters: [CheckedContinuation<Void, Never>] = []
        init(available: Bool = true, beforeSend: (@Sendable (TourMessage) -> Void)? = nil) { self.available = available; self.beforeSend = beforeSend }
        func send(_ tour: TourMessage) async -> Bool {
            beforeSend?(tour); offers.append(tour)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: tour) }
            return available
        }
        func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID { let id = UUID(); watchers[id] = gone; return id }
        func unwatch(_ id: UUID) async { watchers[id] = nil; unwatches += 1; let waiting = unwatchWaiters; unwatchWaiters = []; waiting.forEach { $0.resume() } }
        func waitForUnwatch() async { if unwatches > 0 { return }; await withCheckedContinuation { unwatchWaiters.append($0) } }
        func setBeforeSend(_ callback: @escaping @Sendable (TourMessage) -> Void) { beforeSend = callback }
        func offered() async -> TourMessage {
            if let last = offers.last { return last }
            return await withCheckedContinuation { waiters.append($0) }
        }
        func gone() { Array(watchers.values).forEach { $0() } }
        func unwatchCount() -> Int { unwatches }
        func offerCount() -> Int { offers.count }
    }
    struct Rig: Sendable {
        let directory: URL, clock: Clock, window: Window, stage: BackendDeckToolsTourStage
        func dispose() { try? FileManager.default.removeItem(at: directory) }
    }
    static func rig(window: Window = .init()) -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsRootPortTour-" + UUID().uuidString)
        let clock = Clock()
        let stage = BackendDeckToolsTourStage(logDirectory: directory, window: window, now: { clock.now() }, clock: clock, writeFailure: { _ in })
        return Rig(directory: directory, clock: clock, window: window, stage: stage)
    }
}
