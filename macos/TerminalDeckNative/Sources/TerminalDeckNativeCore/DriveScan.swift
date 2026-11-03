import Foundation

// Hoot's scan through a tour: src/shared/scan.ts (the state machine, its words,
// the answer grouping) and copilot/driving/scan-engine.ts (the engine that ticks
// it every frame), ported one for one. Times are milliseconds.

public enum ScanStatus: String, Equatable, Sendable { case idle, travelling, scanning, paused, finished }

public enum PauseReason: String, Equatable, Sendable {
    case asked, scrolled, clicked, typed, selected
    case leftWindow = "left-window", hidden
    case steppedBack = "stepped-back", consent, stalled
}

public struct ScanState: Equatable, Sendable {
    public var status: ScanStatus = .idle
    public var count = 0
    public var index = 0
    public var elapsedMs = 0.0
    public var pausedBy: PauseReason?
    public var lastTickAt: Double?
    public var arrivedAt: Double?
    public var stalls = 0
    public var arrivals = 0
    public var seen: [Int] = []
    public init() {}
}

public enum ScanEvent: Equatable, Sendable {
    case play(at: Double, count: Int)
    case arrive(at: Double)
    case tick(at: Double)
    case next(at: Double, travel: Bool)
    case back(at: Double, travel: Bool)
    case jump(at: Double, index: Int, travel: Bool)
    case pause(at: Double, reason: PauseReason)
    case resume(at: Double)
    case stop(at: Double)
    case recount(at: Double, count: Int, index: Int)
}

public enum Scan {
    /// How long one stop holds before the scan moves on.
    public static let holdMs = 260.0
    /// A gap between ticks longer than this means the window stopped running.
    public static let maxTickGapMs = 1_000.0

    public static func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T { min(high, max(low, value)) }

    public static func reduce(_ state: ScanState, _ event: ScanEvent) -> ScanState {
        switch event {
        case .play(let at, let count):
            var opened = ScanState()
            opened.count = count
            opened.lastTickAt = at
            if count == 0 { opened.status = .finished; return opened }
            return enter(opened, 0, at, travel: true)
        case .arrive(let at):
            if state.arrivedAt != nil { return state }
            var arrived = state
            arrived.arrivedAt = at
            arrived.lastTickAt = at
            arrived.arrivals += 1
            if !arrived.seen.contains(state.index) { arrived.seen.append(state.index) }
            if state.status == .travelling { arrived.status = .scanning }
            return arrived
        case .tick(let at):
            return tick(state, at)
        case .next(let at, let travel):
            return leave(state, at, state.index + 1, travel: travel)
        case .back(let at, let travel):
            var back = leave(state, at, max(0, state.index - 1), travel: travel)
            back.status = .paused
            back.pausedBy = .steppedBack
            return back
        case .jump(let at, let index, _):
            return leave(state, at, clamp(index, 0, max(0, state.count - 1)), travel: true)
        case .pause(let at, let reason):
            if state.status == .idle || state.status == .finished || state.status == .paused { return state }
            var paused = state
            paused.status = .paused
            paused.pausedBy = reason
            paused.lastTickAt = at
            return paused
        case .resume(let at):
            if state.status != .paused { return state }
            var resumed = state
            resumed.status = state.arrivedAt == nil ? .travelling : .scanning
            resumed.pausedBy = nil
            resumed.lastTickAt = at
            return resumed
        case .stop:
            if state.status == .idle { return state }
            var stopped = state
            stopped.status = .finished
            stopped.pausedBy = nil
            return stopped
        case .recount(let at, let count, let index):
            if count <= 0 {
                var none = state
                none.count = 0
                none.status = .finished
                none.pausedBy = nil
                return none
            }
            var next = state
            next.count = count
            next.index = clamp(index, 0, count - 1)
            next.seen = state.seen.filter { $0 < count }
            next.lastTickAt = at
            return next
        }
    }

    private static func tick(_ state: ScanState, _ at: Double) -> ScanState {
        let gap = state.lastTickAt.map { at - $0 } ?? 0
        if gap > maxTickGapMs {
            var stalled = state
            stalled.lastTickAt = at
            stalled.stalls += 1
            if state.status == .scanning || state.status == .travelling {
                stalled.status = .paused
                stalled.pausedBy = .stalled
            }
            return stalled
        }
        if state.status != .scanning {
            var same = state
            same.lastTickAt = at
            return same
        }
        var advanced = state
        advanced.lastTickAt = at
        advanced.elapsedMs = state.elapsedMs + max(0, gap)
        if advanced.elapsedMs < holdMs { return advanced }
        return leave(advanced, at, state.index + 1, travel: true)
    }

    private static func leave(_ state: ScanState, _ at: Double, _ target: Int, travel: Bool) -> ScanState {
        if state.status == .idle || state.status == .finished { return state }
        if target >= state.count {
            var done = state
            done.status = .finished
            done.pausedBy = nil
            return done
        }
        return enter(state, clamp(target, 0, state.count - 1), at, travel: travel)
    }

    private static func enter(_ state: ScanState, _ index: Int, _ at: Double, travel: Bool) -> ScanState {
        var next = state
        next.index = index
        next.elapsedMs = 0
        next.lastTickAt = at
        next.arrivedAt = travel ? nil : at
        next.pausedBy = nil
        next.status = travel ? .travelling : .scanning
        if !travel {
            next.arrivals += 1
            if !next.seen.contains(index) { next.seen.append(index) }
        }
        return next
    }

    public static func isScanning(_ state: ScanState) -> Bool { state.status != .idle && state.status != .finished }

    public static func progress(_ state: ScanState) -> Double {
        if !isScanning(state) || state.count == 0 { return 0 }
        let within = clamp(state.elapsedMs / holdMs, 0, 1)
        return clamp((Double(state.index) + within) / Double(state.count), 0, 1)
    }

    public static func positionLabel(_ state: ScanState) -> String {
        state.count == 0 ? "" : "\(state.index + 1) of \(state.count)"
    }

    public static func pauseSentence(_ reason: PauseReason) -> String {
        switch reason {
        case .asked: return "Held"
        case .scrolled: return "Held — you scrolled"
        case .clicked: return "Held — you clicked"
        case .typed: return "Held — you typed"
        case .selected: return "Held — you selected some text"
        case .leftWindow: return "Held — you left the window"
        case .hidden: return "Held — the window was hidden"
        case .steppedBack: return "Held — you went back"
        case .consent: return "Held — something needs your permission"
        case .stalled: return "Held — the window stopped running"
        }
    }

    public static func statusSentence(_ state: ScanState) -> String {
        switch state.status {
        case .idle: return ""
        case .finished: return "Done — the answer is in the chat"
        case .travelling, .scanning: return "Scanning · \(positionLabel(state))"
        case .paused: return "\(state.pausedBy.map(pauseSentence) ?? "Held") · Space to carry on"
        }
    }

    // MARK: The answer, grouped by session

    public struct AnswerLine: Equatable, Sendable {
        public let why: String
        public let note: String
        public let quote: String
        public let shown: Bool
    }

    public struct AnswerSession: Equatable, Sendable {
        public let sessionId: String
        public let title: String
        public let lines: [AnswerLine]
    }

    public static func groupBySession(_ stops: [TourStopRecord], background: Bool = false) -> [AnswerSession] {
        var order: [String] = []
        var byId: [String: (title: String, lines: [AnswerLine])] = [:]
        for stop in stops {
            if byId[stop.sessionId] == nil {
                byId[stop.sessionId] = (stop.sessionTitle, [])
                order.append(stop.sessionId)
            }
            byId[stop.sessionId]!.lines.append(AnswerLine(why: stop.why, note: stop.note, quote: stop.quote,
                                                          shown: background || stop.shownAt != nil))
        }
        return order.map { AnswerSession(sessionId: $0, title: byId[$0]?.title ?? "", lines: byId[$0]?.lines ?? []) }
    }

    public static func answerSummary(_ sessions: [AnswerSession]) -> String {
        var shown = 0, sessionsShown = 0
        for session in sessions {
            let here = session.lines.filter(\.shown).count
            shown += here
            if here > 0 { sessionsShown += 1 }
        }
        if shown == 0 { return "Nothing was shown." }
        return "\(shown) thing\(shown == 1 ? "" : "s") across \(sessionsShown) session\(sessionsShown == 1 ? "" : "s")."
    }
}

/// `createScanEngine`: the reducer behind a store that publishes only shape changes,
/// and asks for a tick every frame while it scans or travels.
public final class ScanEngine: @unchecked Sendable {
    public typealias Frame = (_ tick: @escaping () -> Void) -> AnyObject
    private var live = ScanState()
    private var published = ScanState()
    private var frame: AnyObject?
    private var destroyed = false
    private var listeners: [UUID: () -> Void] = [:]
    private let now: () -> Double
    private let requestFrame: Frame
    private let cancelFrame: (AnyObject) -> Void

    public init(now: @escaping () -> Double, requestFrame: @escaping Frame, cancelFrame: @escaping (AnyObject) -> Void) {
        self.now = now
        self.requestFrame = requestFrame
        self.cancelFrame = cancelFrame
    }

    public func getState() -> ScanState { published }
    public func peek() -> ScanState { live }

    public func dispatch(_ event: ScanEvent) {
        if destroyed { return }
        commit(Scan.reduce(live, event))
        syncLoop()
    }

    @discardableResult
    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in self?.listeners[id] = nil }
    }

    public func destroy() {
        destroyed = true
        if let frame { cancelFrame(frame) }
        frame = nil
        listeners.removeAll()
    }

    private func commit(_ next: ScanState) {
        if next == live { return }
        let before = live
        live = next
        let shapeChanged = before.status != next.status || before.index != next.index || before.count != next.count
            || before.pausedBy != next.pausedBy || before.arrivals != next.arrivals || before.seen != next.seen
        if shapeChanged {
            published = live
            for listener in listeners.values { listener() }
        }
    }

    private func syncLoop() {
        if destroyed { return }
        if live.status == .scanning || live.status == .travelling {
            if frame == nil { frame = requestFrame { [weak self] in self?.onFrame() } }
            return
        }
        if let frame { cancelFrame(frame) }
        frame = nil
    }

    private func onFrame() {
        frame = nil
        if destroyed { return }
        commit(Scan.reduce(live, .tick(at: now())))
        syncLoop()
    }
}
