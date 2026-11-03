import Foundation

/// AGT: turns a stream of change events into list reads spaced at least `spacing` apart (2 Nov, for install #25: the
/// Agents page re-read its whole list on every session status change and every Hoot chat update, about 60 % of a core).
/// The first event after a quiet spell reads at once; every event during the wait folds into one trailing read, so the
/// last change is always shown; only one read is ever in flight.
@MainActor
public final class AGTRefreshPacer {
    nonisolated public static let defaultSpacing: Duration = .milliseconds(1_500)
    private let spacing: Duration
    private let read: @MainActor () async -> Void
    private let clock = ContinuousClock()
    private var lastStart: ContinuousClock.Instant?
    private var inFlight = false
    private var wanted = false
    private var timer: Task<Void, Never>?
    /// Reads started so far.
    public private(set) var reads = 0

    public init(spacing: Duration = AGTRefreshPacer.defaultSpacing, read: @escaping @MainActor () async -> Void) {
        self.spacing = spacing; self.read = read
    }

    /// Something changed: read now, or once as soon as the spacing allows.
    public func request() {
        wanted = true
        pump()
    }

    /// Drop a waiting read (the screen went away). A read already in flight finishes.
    public func cancel() {
        wanted = false
        timer?.cancel(); timer = nil
    }

    private func pump() {
        guard wanted, !inFlight, timer == nil else { return }
        if let lastStart, clock.now < lastStart + spacing {
            let due = lastStart + spacing
            timer = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.timer = nil
                self.pump()
            }
            return
        }
        wanted = false; inFlight = true; lastStart = clock.now; reads += 1
        Task { [weak self] in
            guard let self else { return }
            await self.read()
            self.inFlight = false
            self.pump()
        }
    }
}
