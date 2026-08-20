/**
 * Why a terminal that is being filled in does not paint until it is full.
 *
 * ## The defect, which he filmed on the desktop and then found here
 *
 *   > *"app mobile app is also doing the same thing: when we open a session it
 *   > really scrolls everything exactly same way and then it loads and all of
 *   > this stuff. It is happening also in there, so make sure this is also
 *   > aligned and fixed."*
 *
 * Opening a session replays what it has already printed — that is the feature,
 * and it is what makes a session left running on another machine worth opening
 * from a phone at all. What is wrong is that the replay is **watched**: the
 * whole afternoon's output scrolls past, a screen at a time, before settling.
 *
 * ## Why "feed it all at once" is not the fix
 *
 * The backlog arrives in pieces, and it has to: the far machine sends up to 64
 * `output` frames of 32 KB each (`MAX_REPLAY_CHUNKS`, `OUTPUT_CHUNK_BYTES`), so
 * a busy session is dozens of separate writes. Each one is a `TerminalView.feed`
 * — parsed synchronously, then `feedFinish()` schedules a redraw — and SwiftTerm
 * coalesces those redraws at the frame rate rather than skipping them. Sixty
 * frames arriving over half a second are therefore *seen*, each one the viewport
 * a little further down the history.
 *
 * Collapsing them into one `feed` fixes the phone-side half and not the wire
 * half: the frames still arrive separately, so something still has to decide
 * when the last one has landed. That decision is this file, and holding the
 * bytes is what makes one `feed` possible at all.
 *
 * ## So the fix is about what is on screen while they land: nothing
 *
 * The terminal is held at `alpha = 0` while the backlog is written and revealed
 * once, scrolled to the bottom, when it has been. What a person sees is an empty
 * terminal for a moment and then the session, already at its latest output.
 *
 * `alpha`, not `isHidden` and not removing the view: SwiftTerm measures the view
 * to decide its column count, and both of the others take the geometry away —
 * a terminal that measured itself while hidden would negotiate a nonsense size
 * and reflow every line when it came back. `alpha` keeps the layout, keeps first
 * responder — so the keyboard accessory does not flicker — and costs one
 * composited layer that draws nothing.
 *
 * ## Knowing when the backlog has finished
 *
 * There is no end-of-replay marker on the wire: the frames carry `replay: true`
 * and the run of them simply stops. Two things end the hold, whichever comes
 * first, and both are needed:
 *
 *  - the first frame that is **not** a replay, which is the ordinary case for a
 *    session that is still printing; and
 *  - {@link quiet} milliseconds of silence, which is the ordinary case for a
 *    session that is idle and waiting for input, where no such frame is coming.
 *
 * Adding a marker to the protocol would have been the exact answer and would
 * also have meant an older desktop never sending one — a fix that works only
 * between two machines updated on the same day is not a fix.
 *
 * {@link limit} is the backstop under both: the screen is never held for longer
 * than that, whatever is or is not still arriving. **This module can only ever
 * delay a terminal; it must never be able to hide one.** A terminal left blank
 * because a frame never came would be a worse bug than the one this exists to
 * remove.
 *
 * ## Why this is its own type rather than four fields on `TerminalBridge`
 *
 * Because the policy is the part that can be wrong, and the policy is testable
 * without a simulator: it is a state machine over "a chunk arrived", "silence
 * happened", "the ceiling expired". `TerminalBridge` owns a `UIView` and cannot
 * be reasoned about in a unit test at all. The desktop made the same split for
 * the same reason — `src/renderer/components/terminal-backfill.ts` is the same
 * state machine, written twice because a Swift app cannot import TypeScript, and
 * `TerminalBackfillTests` pins the behaviour on this side.
 */

import Foundation

@MainActor
final class TerminalBackfill {

    /// Silence that means the far machine has finished replaying.
    static let quiet: TimeInterval = 0.15

    /// The longest any terminal is held. See the note above: this is a promise,
    /// not a tuning knob.
    static let limit: TimeInterval = 2.0

    /**
     * Somewhere to put a timer, so a test does not have to wait for one.
     *
     * The app hands in `DispatchQueue.main`; a test hands in a fake and calls
     * the block itself. Returning the cancel closure rather than a token keeps
     * the call sites to one line and means there is no handle to forget to
     * invalidate.
     */
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let write: (String) -> Void
    private let scrollToBottom: () -> Void
    private let setVisible: (Bool) -> Void
    private let schedule: Scheduler

    private var held: [String] = []
    private var holding = false
    private var cancelQuiet: (() -> Void)?
    private var cancelCeiling: (() -> Void)?

    init(write: @escaping (String) -> Void,
         scrollToBottom: @escaping () -> Void,
         setVisible: @escaping (Bool) -> Void,
         schedule: @escaping Scheduler = TerminalBackfill.mainQueue) {
        self.write = write
        self.scrollToBottom = scrollToBottom
        self.setVisible = setVisible
        self.schedule = schedule
    }

    /// The real one: a cancellable block on the main queue.
    static let mainQueue: Scheduler = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// Is the screen being held right now? Read by the tests and by nothing else.
    var isHolding: Bool { holding }

    /**
     * A backlog is about to arrive: hide the screen and start the clock.
     *
     * Called from the attach, before a single byte of it. Calling it while
     * already holding restarts the ceiling rather than being ignored, because
     * the second attach is a second replay and the first one's remaining
     * milliseconds are not a budget for it.
     */
    func begin() {
        stopClocks()
        holding = true
        setVisible(false)
        cancelCeiling = schedule(Self.limit) { [weak self] in self?.release() }
    }

    /**
     * One chunk from the wire.
     *
     * A frame that is not a replay ends the hold before it is written: it is the
     * session printing *now*, so the backlog before it is complete by definition
     * and everything held is older than it and must go first.
     */
    func feed(_ text: String, replay: Bool) {
        guard holding else {
            write(text)
            return
        }
        if !replay {
            release()
            write(text)
            return
        }
        held.append(text)
        cancelQuiet?()
        cancelQuiet = schedule(Self.quiet) { [weak self] in self?.release() }
    }

    /**
     * The backlog is complete: write what was held, in one call, and show the
     * screen at the bottom of it.
     *
     * Safe to call more than once; every call after the first does nothing. The
     * reveal is after the write rather than beside it because `feed` parses
     * synchronously — the bytes are on the buffer by the time this returns, and
     * `scrollToBottom` therefore has the whole backlog to scroll to.
     */
    func release() {
        guard holding else { return }
        holding = false
        stopClocks()
        let text = held.joined()
        held.removeAll()
        if !text.isEmpty { write(text) }
        scrollToBottom()
        setVisible(true)
    }

    /**
     * The terminal is going away.
     *
     * Deliberately **shows** the surface again rather than leaving it at zero:
     * the same bridge is reused when the session is opened a second time, and a
     * view left invisible by a teardown would be a terminal that never comes
     * back. Anything still held is dropped — it describes a screen nobody is
     * looking at any more.
     */
    func stop() {
        holding = false
        stopClocks()
        held.removeAll()
        setVisible(true)
    }

    private func stopClocks() {
        cancelQuiet?()
        cancelCeiling?()
        cancelQuiet = nil
        cancelCeiling = nil
    }
}
