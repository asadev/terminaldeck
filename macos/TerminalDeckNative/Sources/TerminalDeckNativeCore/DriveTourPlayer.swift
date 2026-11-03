import Foundation

// The tour player: copilot/driving/tour-player.ts, ported one for one. It walks the
// stops on the scan engine, sends the window to each stop's session (or to Git),
// asks the focus layer to box it, waits a short grace for the box, and keeps the
// record the engine gets back. The window, the box and the clocks are passed in,
// so the whole walk is testable without a screen.

/// What the tour needs from the window: `navigator.ts`.
@MainActor
public protocol DriveNavigating: AnyObject {
    func selectTab(_ sessionId: String)
    func showPanel(_ id: String, focus: String?)
    func cwdOf(_ sessionId: String) -> String?
}

/// What the tour needs from the box layer: `focus-controller.ts` + measuring and scrolling.
@MainActor
public protocol DriveFocusing: AnyObject {
    func setFocus(_ target: FocusTarget, lit: Bool)
    func setLit(_ lit: Bool)
    func clearFocus()
    /// Why this target cannot be boxed right now, or nil when it can.
    func failure(_ target: FocusTarget) -> FocusFailure?
    /// Bring a terminal quote into view when it has scrolled off (`scrollToFocus`).
    func scrollTo(_ target: FocusTarget)
}

public struct TourView: Equatable, Sendable {
    public var record: TourRecord
    /// The stops in play order (a resume may have dropped some).
    public var stops: [TourStop]
    /// For each play position, the stop's index in the record.
    public var recordIndexes: [Int]
    public var scan: ScanState
    public var degraded: (index: Int, why: FocusFailure)?
    public var droppedHere: [(title: String, why: FocusFailure)]
    public var ended: Bool

    public static func == (a: TourView, b: TourView) -> Bool {
        a.record == b.record && a.stops == b.stops && a.recordIndexes == b.recordIndexes && a.scan == b.scan
            && a.degraded?.index == b.degraded?.index && a.degraded?.why == b.degraded?.why
            && a.droppedHere.map(\.title) == b.droppedHere.map(\.title) && a.ended == b.ended
    }

    /// The record's title for the session of the stop at a play position.
    public func sessionTitle(at index: Int) -> String {
        let recordIndex = index < recordIndexes.count ? recordIndexes[index] : index
        return recordIndex < record.stops.count ? record.stops[recordIndex].sessionTitle : ""
    }
}

public enum TourCommand: Sendable { case back, toggle, next, stop }

public enum TourReport: String, Sendable { case started, progress, ended }

@MainActor
public final class TourPlayer {
    /// How long a stop waits for its box before it is shown without one.
    public static let arriveGraceMs = 900.0
    /// A hold older than this re-checks every remaining stop on resume, not just the next.
    public static let resumeStaleMs = 5 * 60_000.0

    public typealias Cancel = () -> Void

    private let plan: [TourStop]
    private var order: [Int]
    private var record: TourRecord
    private(set) public var view: TourView
    private let engine: ScanEngine
    private weak var navigator: DriveNavigating?
    private weak var focus: DriveFocusing?
    private let report: (TourReport, TourRecord) -> Void
    private let now: () -> Double
    private let perfNow: () -> Double
    private let schedule: (Double, @escaping () -> Void) -> Cancel
    private let copilotSessionId: String?
    private var listeners: [UUID: () -> Void] = [:]
    private var pointedAt = -1
    private var grace: Cancel?
    private var lastFailure: FocusFailure?
    private var heldAt: Double?
    private var ended = false
    private var unsubscribe: (() -> Void)?

    /// - Parameters:
    ///   - now: wall clock (ms since 1970) for the record; `perfNow` for the scan.
    ///   - schedule: run an action after so many ms; returns a cancel.
    public init(message: TourMessage, copilotSessionId: String?, engine: ScanEngine, navigator: DriveNavigating?,
                focus: DriveFocusing?, report: @escaping (TourReport, TourRecord) -> Void,
                now: @escaping () -> Double, perfNow: @escaping () -> Double,
                schedule: @escaping (Double, @escaping () -> Void) -> Cancel) {
        self.plan = message.stops
        self.order = Array(message.stops.indices)
        self.record = message.record
        self.engine = engine
        self.navigator = navigator
        self.focus = focus
        self.report = report
        self.now = now
        self.perfNow = perfNow
        self.schedule = schedule
        self.copilotSessionId = copilotSessionId
        self.view = TourView(record: message.record, stops: message.stops, recordIndexes: Array(message.stops.indices),
                             scan: engine.getState(), degraded: nil, droppedHere: [], ended: false)
        unsubscribe = engine.subscribe { [weak self] in
            MainActor.assumeIsolated { self?.engineChanged() }
        }
        report(.started, record)
        engine.dispatch(.play(at: perfNow(), count: order.count))
        enterStop(0)
    }

    @discardableResult
    public func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            MainActor.assumeIsolated { self?.listeners[id] = nil }
        }
    }

    private func recordIndex(_ play: Int) -> Int { play >= 0 && play < order.count ? order[play] : -1 }
    private func stopAt(_ play: Int) -> TourStop? {
        let i = recordIndex(play)
        return i >= 0 && i < plan.count ? plan[i] : nil
    }

    private func publish(degraded: (index: Int, why: FocusFailure)?? = nil, droppedHere: [(title: String, why: FocusFailure)]? = nil) {
        if let degraded { view.degraded = degraded }
        if let droppedHere { view.droppedHere = droppedHere }
        view.record = record
        view.stops = order.map { plan[$0] }
        view.recordIndexes = order
        view.scan = engine.peek()
        view.ended = ended
        for listener in listeners.values { listener() }
    }

    private func noteShown(_ play: Int, at: Double) {
        let index = recordIndex(play)
        for i in record.stops.indices where record.stops[i].index == index && record.stops[i].shownAt == nil {
            record.stops[i].shownAt = at
        }
    }

    private func noteLeft(_ play: Int, failure: FocusFailure?) {
        let index = recordIndex(play)
        for i in record.stops.indices where record.stops[i].index == index {
            let shown = record.stops[i].shownAt
            record.stops[i].dwellMs = shown.map { max(0, now() - $0) }
            record.stops[i].degraded = failure != nil
            record.stops[i].degradedWhy = failure.map(DriveTour.degradeSentence)
        }
        report(.progress, record)
    }

    private func travel(to stop: TourStop) {
        let cwd = navigator?.cwdOf(stop.sessionId)
        focus?.setLit(false)
        lastFailure = nil
        if let navigator {
            navigator.selectTab(stop.sessionId)
            if DriveTour.goesToGit(stop) { navigator.showPanel("git", focus: nil) }
        }
        guard let target = DriveTour.focus(stop, cwd: cwd) else {
            lastFailure = .anchorMissing
            focus?.setFocus(.anchor(.sessionRow(sessionId: stop.sessionId)), lit: false)
            return
        }
        focus?.setFocus(target, lit: false)
        if case .terminal = target { focus?.scrollTo(target) }
    }

    private func enterStop(_ play: Int) {
        guard let stop = stopAt(play) else { return }
        pointedAt = play
        grace?()
        travel(to: stop)
        grace = schedule(Self.arriveGraceMs) { [weak self] in
            guard let self, !self.ended else { return }
            self.grace = nil
            let why = self.lastFailure ?? .anchorMissing
            self.noteShown(play, at: self.now())
            self.publish(degraded: .some((play, why)))
            self.engine.dispatch(.arrive(at: self.perfNow()))
        }
        publish(degraded: .some(nil))
    }

    /// The box layer's report: drawn, or why not (`FocusReport`).
    public func reported(drawn: Bool, why: FocusFailure?) {
        if ended { return }
        if drawn {
            lastFailure = nil
            if let grace {
                grace()
                self.grace = nil
                focus?.setLit(true)
                noteShown(pointedAt, at: now())
                publish(degraded: .some(nil))
                engine.dispatch(.arrive(at: perfNow()))
            }
            return
        }
        lastFailure = why
        if grace == nil, view.degraded?.index == pointedAt {
            publish(degraded: .some((pointedAt, lastFailure ?? .anchorMissing)))
        }
    }

    private func engineChanged() {
        if ended { return }
        let state = engine.getState()
        if state.status == .finished { finish(); return }
        if state.index != pointedAt && Scan.isScanning(state) {
            if pointedAt >= 0 { noteLeft(pointedAt, failure: lastFailure) }
            enterStop(state.index)
        }
        if state.status == .paused && heldAt == nil { heldAt = now() }
        if state.status != .paused && heldAt != nil { heldAt = nil }
        publish()
    }

    /// Something the person did that holds the scan (`attachInterruption`).
    public func interrupt(_ reason: PauseReason) {
        if ended { return }
        engine.dispatch(.pause(at: perfNow(), reason: reason))
    }

    public func command(_ name: TourCommand) {
        if ended { return }
        switch name {
        case .next: engine.dispatch(.next(at: perfNow(), travel: true))
        case .back: engine.dispatch(.back(at: perfNow(), travel: true))
        case .toggle:
            if engine.peek().status == .paused { resume() } else { engine.dispatch(.pause(at: perfNow(), reason: .asked)) }
        case .stop: end()
        }
    }

    /// Space, ←, →, Escape drive the panel while a scan runs; nothing else is taken.
    public func key(_ key: String) -> Bool {
        guard !ended, Scan.isScanning(engine.peek()) else { return false }
        switch key {
        case " ": command(.toggle)
        case "ArrowRight": command(.next)
        case "ArrowLeft": command(.back)
        case "Escape": command(.stop)
        default: return false
        }
        return true
    }

    private func resume() {
        let state = engine.peek()
        let stale = heldAt.map { now() - $0 > Self.resumeStaleMs } ?? false
        let from = state.index
        let through = stale ? order.count - 1 : from
        var lost: [Int] = []
        var dropped: [(title: String, why: FocusFailure)] = []
        if from <= through {
            for index in from...through {
                guard let stop = stopAt(index) else { continue }
                let target = DriveTour.focus(stop, cwd: navigator?.cwdOf(stop.sessionId))
                let failure: FocusFailure? = target.map { focus?.failure($0) } ?? .anchorMissing
                if let failure, failure == .quoteNotFound || failure == .notRegistered {
                    lost.append(index)
                    dropped.append((stop.note, failure))
                }
            }
        }
        if lost.isEmpty {
            enterStop(from)
            engine.dispatch(.resume(at: perfNow()))
            return
        }
        let gone = Set(lost)
        let kept = order.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        if kept.isEmpty { end(); return }
        let landing = min(from - lost.filter { $0 < from }.count, kept.count - 1)
        order = kept
        publish(droppedHere: view.droppedHere + dropped)
        engine.dispatch(.recount(at: perfNow(), count: order.count, index: max(0, landing)))
        engine.dispatch(.resume(at: perfNow()))
        enterStop(max(0, landing))
    }

    public func jump(_ index: Int) {
        if ended { return }
        engine.dispatch(.jump(at: perfNow(), index: index, travel: true))
        engine.dispatch(.pause(at: perfNow(), reason: .steppedBack))
    }

    private func finish() {
        if ended { return }
        ended = true
        grace?()
        grace = nil
        unsubscribe?()
        focus?.clearFocus()
        if pointedAt >= 0 { noteLeft(pointedAt, failure: lastFailure) }
        let shown = record.stops.filter { $0.shownAt != nil }.count
        record.endedAt = now()
        record.stoppedAfter = shown > 0 && shown < record.stops.count ? shown - 1 : nil
        report(.ended, record)
        engine.destroy()
        if let id = copilotSessionId { navigator?.selectTab(id) }
        publish()
    }

    public func end() {
        if ended { return }
        engine.dispatch(.stop(at: perfNow()))
        finish()
    }
}
