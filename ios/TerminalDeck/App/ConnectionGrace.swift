/**
 * When the connection is worth saying anything about, and when silence is the
 * honest answer.
 *
 * Asad, watching the app open on his phone: *"when we just open the application,
 * it shows connecting actually — let it just not show that kind of yellow thing.
 * Let it give a few seconds; after five seconds if it is still not connected,
 * then show. Otherwise it will just load, so they will not even feel that it
 * takes time for connecting. And no need to show connected all the time. Also if
 * it gets disconnected for more than five seconds, then start showing connecting,
 * so they feel like okay it's trying to connect. But less than five seconds — if
 * it's disconnected less than five seconds, let's not show anything."*
 *
 * That is four rules and they are all the same rule: **a phone should only be
 * told about the connection when the connection is the thing standing between the
 * person and what they came for.** A relay dial takes about a second; a carrier
 * NAT drops a socket and the reconnect takes two. Announcing either one is not
 * information, it is a yellow bar teaching somebody that this app is flaky.
 *
 * | What is happening | What is drawn |
 * |---|---|
 * | The app has just been opened and is dialling | nothing, for five seconds |
 * | …and is still dialling after five seconds | the state, "Connecting" |
 * | Connected and heard from | **nothing at all** |
 * | Dropped, back inside five seconds | nothing — this is the whole point |
 * | Dropped, still down after five seconds | the state, "Reconnecting" |
 *
 * ## Why this is a struct with a clock passed in
 *
 * Because the alternative is four `Task.sleep`s spread across two screens, which
 * is how a rule like this comes to be *almost* implemented in three places and
 * differently in each. Everything here is a pure function of the states it has
 * been shown and the instant it is asked about, so all five rows of that table
 * are checkable in a test with a fake clock and no sleeping at all — see
 * `ConnectionGraceTests`. `ConnectionNotice` below is the ten lines that hold one
 * of these against a real clock and a real timer.
 *
 * ## The one case that is deliberately *not* delayed
 *
 * A credential that was refused, and a protocol version the two ends do not
 * share. Nothing is trying in either state — no retry is scheduled and none would
 * help — so a grace period there is not "wait and see", it is five seconds of
 * pretending. The delay exists to hide a *wait*; there is no wait to hide.
 *
 * ## And the one case that is deliberately *not* treated as connected
 *
 * `.online` with `verified == false` — the app is holding a socket it has not
 * heard from since it had reason to doubt it. `ConnectionState.verified` explains
 * at length why that is its own state and why the pill says "Checking" rather
 * than "Connected" there. It counts as unsettled here for the same reason: if the
 * probe comes back inside five seconds nothing was ever drawn, and if it does not
 * then doubt is exactly what the person should be told about.
 */

import Foundation
import Observation

struct ConnectionGrace: Equatable {

    /**
     * Five seconds. His number, said twice in the same breath, and it is a good
     * one for the reason he gave rather than by taste: it is comfortably longer
     * than a relay dial or a reconnect after a lift dropped the signal, and
     * comfortably shorter than the point at which somebody starts wondering
     * whether the app is broken.
     */
    static let grace: TimeInterval = 5

    /**
     * When the connection stopped being settled, or nil while it is settled.
     *
     * The **earliest** such moment, and that is the load-bearing detail. A
     * reconnect walks through several states — offline, connecting, waiting,
     * connecting again — and restarting this on each one would give a flapping
     * connection a fresh five seconds of silence every couple of hundred
     * milliseconds, so the notice would never appear no matter how long the
     * outage ran. Which is the opposite of the fifth row of the table.
     */
    private(set) var unsettledSince: Date?

    /// Whether the current state is one no amount of waiting improves. See the
    /// header: these are shown immediately.
    private(set) var isSettledFailure = false

    init() {}

    /// Nothing to say. `.online` *and* heard from — see the header for why the
    /// second half is not redundant.
    static func isSettled(_ state: ConnectionState) -> Bool {
        state.phase == .online && state.verified
    }

    /// A final answer from the machine. Retrying is not happening and would not
    /// help, so there is no wait for the grace period to be hiding.
    static func isFinal(_ state: ConnectionState) -> Bool {
        state.phase == .rejected || state.phase == .incompatible
    }

    /// The connection changed. Called for every state, including the ones that
    /// change nothing here.
    mutating func observe(_ state: ConnectionState, at now: Date) {
        if Self.isSettled(state) {
            unsettledSince = nil
            isSettledFailure = false
            return
        }
        isSettledFailure = Self.isFinal(state)
        // Only when there is not already one. See `unsettledSince`.
        if unsettledSince == nil { unsettledSince = now }
    }

    /// Whether anything should be on screen at this instant.
    func isShowing(at now: Date) -> Bool {
        guard let unsettledSince else { return false }
        if isSettledFailure { return true }
        return now.timeIntervalSince(unsettledSince) >= Self.grace
    }

    /**
     * The instant at which the answer would change from hidden to shown, or nil
     * when nothing is pending.
     *
     * This is what makes the driver a single one-shot sleep rather than a poll:
     * there is exactly one future moment at which this object's answer changes
     * on its own, and it can say when. Nil while settled (nothing is coming) and
     * nil once showing (it has already happened).
     */
    func deadline(at now: Date) -> Date? {
        guard let unsettledSince, !isShowing(at: now) else { return nil }
        return unsettledSince.addingTimeInterval(Self.grace)
    }
}

/**
 * What wakes a `ConnectionGrace` up when its deadline passes.
 *
 * A seam with one implementation in the app and one in the tests, and it exists
 * for a reason worth stating: a test that proved this rule by sleeping for five
 * real seconds would be five seconds of every future run, and a test that proved
 * it by sleeping for five *hundred milliseconds* would be proving a different
 * rule. The fake one below fires on command, so the whole thing is exercised
 * synchronously and the real clock never enters into it.
 */
@MainActor
protocol NoticeScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void)
    func cancel()
}

/// The real one: one `Task`, cancelled and replaced rather than accumulated.
@MainActor
final class TaskNoticeScheduler: NoticeScheduler {
    private var pending: Task<Void, Never>?

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
        cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // A cancelled sleep throws, but a sleep that has already finished
            // when the cancellation lands does not — so the flag is checked
            // rather than relied on the throw.
            guard !Task.isCancelled else { return }
            body()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/**
 * A `ConnectionGrace` held against a real clock, for the views to read.
 *
 * One of these per machine, on `HostLink`, and the count matters: a screen that
 * owned its own would give a machine that has been down for a minute a fresh five
 * seconds of silence every time somebody navigated back to the session list,
 * which is a rule that is right in the small and wrong exactly when it matters.
 * The pill in the toolbar, the banner over the list and the banner over a
 * terminal all read this one object, so the three of them cannot disagree about
 * whether now is the moment to say something.
 */
@MainActor
@Observable
final class ConnectionNotice {

    /// Whether the connection is worth drawing right now.
    private(set) var isShowing = false

    @ObservationIgnored private var grace = ConnectionGrace()
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let scheduler: NoticeScheduler

    init(now: @escaping () -> Date = Date.init, scheduler: NoticeScheduler? = nil) {
        self.now = now
        // Defaulted in the body rather than in the signature: a default argument
        // is evaluated outside the actor and this type is main-actor isolated.
        self.scheduler = scheduler ?? TaskNoticeScheduler()
    }

    /// The connection changed.
    func observe(_ state: ConnectionState) {
        grace.observe(state, at: now())
        settle()
    }

    /**
     * Ask again, without anything having changed.
     *
     * Called when the app comes back to the foreground, and it is not
     * defensive: a suspended app does not run its timers, so a phone that went
     * into a pocket connected and came out disconnected has a `Task` that was
     * due to fire two minutes ago and has not. Recomputing against the clock is
     * the only thing that notices.
     */
    func refresh() {
        settle()
    }

    private func settle() {
        let at = now()
        let wanted = grace.isShowing(at: at)
        // Compared before assigning. `@Observable` publishes on every write, and
        // this is called from every connection state change on every machine —
        // a write of the same value would rebuild the session list for nothing.
        if isShowing != wanted { isShowing = wanted }

        guard let deadline = grace.deadline(at: at) else {
            scheduler.cancel()
            return
        }
        scheduler.schedule(after: max(0, deadline.timeIntervalSince(at))) { [weak self] in
            self?.settle()
        }
    }
}
