/**
 * One session's control cluster on a phone — model, effort, fast mode,
 * permission.
 *
 * A port of `pwa/src/session-controls.ts`. Nothing new is on the wire:
 * `controls.read` and `controls.apply` have been answered by every desktop since
 * 0.5.0 (the desktop's own remote window sends them), and this client never did,
 * so a phone could watch a session and never change what it runs at. This is a
 * client, not a feature — the same relationship `SessionBarLink` has to usage
 * and account.
 *
 * ## What is drawn, and what is deliberately not
 *
 * Nothing until a `controls.reading` lands, and nothing at all over a machine
 * whose welcome did not name `controls` — an older desktop gets a pane that is
 * exactly what it was rather than a row explaining what it lacks. Nothing over a
 * plain shell either: `agentRunning` says whether an agent CLI is drawing that
 * session's screen, and a model menu over `/bin/zsh` is the defect the desktop's
 * own cluster withdraws itself for.
 *
 * A control the far end says is barred keeps its chip, and the chip still opens
 * onto its rows: the reason rides above them as one short line rather than
 * replacing them. That is the opposite of the rule this file used to state, and
 * `SessionControlsView.swift` carries the whole account of why it turned round —
 * *"they are also not control they are just descriptions which i dont want
 * always"*. Most of what used to arrive here as a block no longer arrives at
 * all: a draft at the far prompt is now lifted, held across the command and
 * typed back unsent by `agent-controls.ts`, so picking a model over an unsent
 * message simply works.
 *
 * ## Honest in-flight and failed states
 *
 * A press sends the frame and says "Working…" until the machine answers. The
 * ticked row is never the row that was pressed — it is whatever the far end
 * *re-read* after the change settled, which is what makes a failed apply revert
 * by construction. A failure keeps its sentence until dismissed; a confirmation
 * clears itself; and a machine that never answers gets the one sentence that
 * does not guess (`noAnswer`), because the command is typed into the far pty
 * before anything comes back.
 */

import Foundation

@MainActor
@Observable
final class SessionControlsLink {
    /// The session this cluster is about, or nil when none is attached.
    private(set) var sessionID: String?
    /// The whole reading, or nil until one has landed.
    private(set) var reading: ControlsReadingWire?
    /// Which control is mid-change, or nil. While one is busy the others wait.
    private(set) var busy: ControlName?
    /// The far end's own sentence about the last change, with whether it was ok.
    private(set) var notice: Notice?

    struct Notice: Equatable { let ok: Bool; let text: String }

    /// The sentence for an apply nobody answered — word for word the guest's. It
    /// does not say "failed": the command is typed before anything comes back, so
    /// the session may well have changed, and claiming failure would send someone
    /// pressing again at a session that already moved.
    static let noAnswer = "That machine did not answer, so it is not known whether the change was made."
    /// And the one for a press while the socket is down — nothing was sent.
    static let notConnected = "Not connected right now, so nothing was sent."

    static let readTimeout: TimeInterval = 20
    static let applyTimeout: TimeInterval = 60
    private static let settle: TimeInterval = 1.2
    private static let confirm: TimeInterval = 4

    private enum Ask: Equatable { case read; case apply(ControlName) }
    private struct Pending { let kind: Ask; let id: String }

    private var capabilities: Set<String> = []
    private let wire: CopilotWire
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var counter = 0
    private var quiet: Task<Void, Never>?
    private var confirmClear: Task<Void, Never>?

    init(wire: CopilotWire) {
        self.wire = wire
    }

    // MARK: - Lifecycle

    /// What the machine advertised, from each welcome. Replaced, not merged: a
    /// guest reconnecting is handed a shorter list.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
    }

    var offered: Bool { capabilities.contains(WireCapability.controls) }

    /// The screen opened a session. Everything held about the last one goes.
    func follow(_ id: String) {
        if sessionID != id { forget() }
        sessionID = id
        ask()
    }

    /// The screen closed, or the socket went. Timers stop and nothing stale is
    /// left on a cluster that may draw again in a second.
    func forget() {
        quiet?.cancel(); quiet = nil
        confirmClear?.cancel(); confirmClear = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        pending.removeAll()
        sessionID = nil
        reading = nil
        busy = nil
        notice = nil
    }

    /// The socket went. The reading is a claim about now and nothing over a dead
    /// channel will correct it, so it goes; pending questions drop so a late
    /// answer cannot land against a request id from the last connection.
    func dropped() {
        quiet?.cancel(); quiet = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        pending.removeAll()
        reading = nil
        busy = nil
    }

    /// The session printed something and has gone quiet — the event every chip
    /// changes on, because the model line, the effort confirmation and the
    /// permission footer are all read from what the far pty writes.
    func noteOutput() {
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.ask()
        }
    }

    // MARK: - Asking

    private func ask() {
        guard let id = sessionID, offered else { return }
        let rid = nextRid()
        guard wire.send(.controlsRead(rid: rid, id: id)) else { return }
        pending[rid] = Pending(kind: .read, id: id)
        arm(rid, after: Self.readTimeout) { [weak self] in
            // A read nobody answered keeps the previous values — they are still
            // the last thing genuinely read. Before the first answer there is
            // nothing on screen to blank, which is its own honest state.
            self?.pending.removeValue(forKey: rid)
        }
    }

    func apply(_ control: ControlName, _ value: String) {
        guard let id = sessionID, busy == nil else { return }
        let rid = nextRid()
        guard wire.send(.controlsApply(rid: rid, id: id, control: control, value: value)) else {
            say(Notice(ok: false, text: Self.notConnected))
            return
        }
        pending[rid] = Pending(kind: .apply(control), id: id)
        busy = control
        say(nil)
        arm(rid, after: Self.applyTimeout) { [weak self] in
            guard let self, self.pending.removeValue(forKey: rid) != nil else { return }
            self.busy = nil
            self.say(Notice(ok: false, text: Self.noAnswer))
            // Asked rather than assumed: the change may well have landed, and a
            // fresh reading is the only honest tiebreak.
            self.ask()
        }
    }

    // MARK: - Answers

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .controlsReading(rid, id, reading):
            guard let asked = pending.removeValue(forKey: rid), asked.kind == .read else { return false }
            disarm(rid)
            // The session is checked as well as the rid, exactly as the guest
            // checks it, so another session's model can never land on this chip.
            if id != asked.id || id != sessionID { return true }
            self.reading = reading
            return true

        case let .controlsApplied(rid, id, ok, message, answer):
            guard let asked = pending.removeValue(forKey: rid), case let .apply(control) = asked.kind else { return false }
            disarm(rid)
            if id != asked.id || id != sessionID { return true }
            busy = nil
            // The far end's own words, verbatim — never a sentence composed here.
            say(Notice(ok: ok, text: message))
            reading = reading?.applying(control, answer)
            // A fresh read of the whole cluster: an apply can move more than its
            // own chip (picking a model turns fast mode off), and the answer
            // carried only one reading.
            ask()
            return true

        default:
            return false
        }
    }

    // MARK: - The notice's one clock

    private func say(_ notice: Notice?) {
        confirmClear?.cancel(); confirmClear = nil
        self.notice = notice
        if let notice, notice.ok {
            confirmClear = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.confirm * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.notice = nil
            }
        }
    }

    func dismissNotice() { say(nil) }

    // MARK: - rid + timers

    private func nextRid() -> String {
        counter += 1
        return "ctl-\(counter)-\(UUID().uuidString.prefix(6))"
    }

    private func arm(_ rid: String, after seconds: TimeInterval, _ fire: @escaping () -> Void) {
        timers[rid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
            self?.timers.removeValue(forKey: rid)
        }
    }

    private func disarm(_ rid: String) {
        timers.removeValue(forKey: rid)?.cancel()
    }
}

// MARK: - The pure decisions (ports of the exported functions of session-controls.ts)

enum SessionControls {
    /**
     * Whether there is a cluster to draw at all. Three answers fold to false:
     * no reading has landed, the far end had no such session (`live` false), or
     * the session is a plain shell (`agentRunning` false). Absent, not greyed.
     */
    static func clusterShown(_ reading: ControlsReadingWire?) -> Bool {
        guard let reading else { return false }
        return reading.live && reading.agentRunning
    }

    /**
     * Why nothing can be changed at this instant, for one control, or nil.
     *
     * The control's own `unavailableReason` first — every sentence is the far
     * end's; then the session's typing gate. The one fallback claims only what
     * is known: nothing was sent.
     *
     * ## What this answer is now used for, which is not what it was
     *
     * It used to select between two whole drawings: rows, or this sentence in
     * their place. It no longer does. The rows are always drawn, and this is one
     * short line above them plus the decision not to accept a press — see
     * `SessionControlsView.swift` for why, in his words. The function is
     * unchanged because the question it answers was never the wrong one; only
     * what the view did with the answer was.
     *
     * The two sources are also no longer the same *kind* of thing, and it is
     * worth naming which is which because the far end now clears one of them by
     * itself. `unavailableReason` is the far end saying it will never accept
     * this — a shell with no agent in it, a CLI whose model command has not been
     * established, an account without the credits for fast mode. The gate is a
     * state that flips on the session's next flush of output: mid-turn, a dialog
     * on screen, a prompt that cannot be read, a draft too big to lift. A draft
     * that *can* be lifted is no longer either: the desktop takes it, runs the
     * command and types it back unsent, and this answers nil throughout.
     */
    static func blocked(_ control: ControlName, _ reading: ControlsReadingWire) -> String? {
        let barred = reading.reading(control).unavailableReason
        if let barred, !barred.isEmpty { return barred }
        if !reading.canType {
            return reading.gateReason ?? "This session cannot be typed into right now, so nothing was sent."
        }
        return nil
    }

    /// What a chip prints: the value alone, never the control's name beside it.
    static func chipText(_ control: ControlName, _ reading: ControlsReadingWire) -> String {
        ControlCatalog.displayValue(reading.reading(control), control)
    }

    /// Whether an option is the one in force, for this control's reading.
    static func chosen(_ reading: ControlReadingWire, _ option: ControlOption) -> Bool {
        ControlCatalog.isCurrent(reading, option)
    }

    /// The value to send when the fast switch is pressed — computed from the
    /// reading, never from what the switch looks like, so a stale picture cannot
    /// send "on" to a session already on.
    static func fastFlip(_ reading: ControlReadingWire) -> String {
        reading.value == "on" ? "off" : "on"
    }
}
