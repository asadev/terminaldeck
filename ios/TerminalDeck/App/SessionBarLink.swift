/**
 * What one session's bar knows.
 *
 * The client half of `usage` and `account` — a port of
 * `pwa/src/session-bar.ts`, which the browser client has had since 2026-08-18
 * and this app had none of. On his phone the app was a session list and a
 * terminal: no ring, no context, no account. Everything drawn from here is the
 * far machine's own figure,
 * read by the same `readUsage`, `readContextWindow` and `sessionAccount` that
 * draw the bar at the desk, which is what keeps one session from having two
 * truths depending on which screen is looking at it.
 *
 * ## One session at a time, on purpose
 *
 * A phone shows one terminal. This holds the state for whichever session is on
 * screen and drops it when another is opened — `follow(_:)` — rather than
 * keeping a table keyed by session. The alternative is a cache that has to be
 * invalidated on every account switch, every reconnect and every rolled-over
 * transcript, to save re-asking a question that costs a few milliseconds on the
 * far side.
 *
 * ## Nothing is polled
 *
 * `context` and `plan` are asked once on attach and then only when the session
 * goes quiet, which is the same event the desktop's own bar rides — a context
 * window moves when the agent writes to its transcript and at no other time.
 * `plan` is throttled on top of that because it is a round trip for a figure
 * that changes on the hour. `refresh` is only ever sent because a finger
 * pressed the ring: it boots a whole Claude Code on the other machine.
 *
 * ## No sentences
 *
 * There is no wording anywhere in this file or the views it feeds. A figure
 * that is not known is a chip that is **not drawn**. A switch the far end
 * refuses is a row that could not be pressed in the first place. The rule is
 * his, stated four times: *"don't put any single statement in anywhere… We want
 * simplicity. Let the smart people use it."*
 */

import Foundation

@MainActor
@Observable
final class SessionBarLink {

    /// The session on screen, or nil when none is. Every question carries it,
    /// and an answer about a different one is dropped rather than drawn.
    private(set) var sessionID: String?

    /// The highest plan window in use, 0…1, or nil for "no figure" — which is
    /// no ring rather than an empty one.
    private(set) var plan: Double?
    /// How full this session's context window is, 0…1, or nil.
    private(set) var context: Double?
    /// The login this session runs as, or nil until a machine has answered.
    private(set) var account: WireAccount?
    /// Every login the machine has, across agents. Which of them may be pressed
    /// is this client's decision; see `foreignAccount`.
    private(set) var accounts: [WireAccount] = []
    /// A refresh or a switch is in flight.
    private(set) var busy = false

    /*
     * ## Usage, the best version: a figure is drawn only while it is still true
     *
     * Asad, 2026-08-26: the ring and the bar *"are often stale"* — a percent
     * left on the row by a switch, a socket that went, or an agent mid-write.
     * The fix is not another read; it is refusing to draw a reading that is no
     * longer the machine's current answer. So each figure carries the moment it
     * landed, and `freshPlan` / `freshContext` withhold it the instant it stops
     * being current. Absent, never wrong — the same rule the chip already keeps
     * for a figure that was never known.
     */

    /// When the plan reading on screen last landed, or nil for "not a current
    /// reading". Set together with `plan`, cleared the moment `plan` could be
    /// about a different login (a switch), a dead socket, or another session.
    private(set) var planReadAt: Date?
    /// When the context reading on screen last landed, or nil. Set with
    /// `context`; additionally cleared the instant the session writes again,
    /// because an output frame moves the window and the last reading is behind
    /// it until the debounced re-read replaces it.
    private(set) var contextReadAt: Date?

    /// The plan figure, but only while it is genuinely the machine's current
    /// answer for the session on screen. Otherwise nil — no ring rather than a
    /// stale one. Press the ring (`refresh`) to read it again once it is gone.
    var freshPlan: Double? {
        guard sessionID != nil, planReadAt != nil else { return nil }
        return plan
    }
    /// The context figure, but only while genuinely fresh. Held through a quiet
    /// session — the window does not move when nothing is written — and withdrawn
    /// while the agent writes, so a climbing number is never read mid-flight.
    var freshContext: Double? {
        guard sessionID != nil, contextReadAt != nil else { return nil }
        return context
    }

    /// What this machine said it can answer. Nothing is asked for a name that
    /// is not in here, so a desktop older than these capabilities gets a screen
    /// that is exactly what it was rather than one explaining what it lacks.
    private var capabilities: Set<String> = []

    private let wire: CopilotWire
    private var pending: [String: Ask] = [:]
    private var counter = 0
    private var askedPlanAt: Date?
    private var quiet: Task<Void, Never>?
    private let now: () -> Date

    /// How long before a quiet session's plan figure is worth asking for again.
    static let planThrottle: TimeInterval = 60

    private enum Ask: Equatable {
        case usage(UsageWant)
        case account
        case accountSwitch
        case loginsSignout
    }

    init(wire: CopilotWire, now: @escaping () -> Date = Date.init) {
        self.wire = wire
        self.now = now
    }

    // MARK: - Lifecycle

    /// What this machine advertised, taken from each welcome. Capabilities can
    /// change between connections — a guest device is handed a shorter list —
    /// so this is replaced rather than merged.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
    }

    var canReadUsage: Bool { capabilities.contains(WireCapability.usage) }
    var canReadAccount: Bool { capabilities.contains(WireCapability.account) }
    /// Whether this machine will sign one of its own logins out for this device —
    /// the gate on the sheet's Sign out control. A machine that advertises
    /// `account` but not `logins` (an older host, or a guest) draws no Sign out,
    /// exactly as it did before there was one.
    var canManageLogins: Bool { capabilities.contains(WireCapability.logins) }

    /**
     * The screen opened a session. Everything held about the last one goes:
     * a ring from another session is worse than no ring.
     *
     * Called again for a session this bar is *already* following whenever a
     * screen finds itself back in front — see `TerminalScreen.reclaimBar`.
     */
    func follow(_ id: String) {
        // **`figuresFor` and not `sessionID`.** `release` leaves the figures on
        // screen with nobody following them, so `sessionID` is nil at exactly the
        // moment this has to decide whether they are worth keeping — and nil is
        // not "another session". Asking whose the numbers *are* is the question
        // this line means; asking who is being followed was the question that
        // blanked the row on every return. See `release`.
        if figuresFor != id { forget() }
        sessionID = id
        figuresFor = id
        askUsage(.context)
        askPlan()
        askAccount()
    }

    /**
     * The screen for `id` has gone.
     *
     * **Id-scoped**, and it has to be. There is one of these per machine and there are two `TerminalScreen`s that
     * can be alive at once — the Sessions stack's and the Copilot stack's — so
     * "a screen went away" is not the same fact as "the session this bar is
     * following went away". Measured on the simulator against the app's own
     * shape (a `TabView` of two `NavigationStack`s, one pushed screen in each):
     *
     *     appear:leftRoot → push → appear:left-1 → tab to right →
     *     appear:rightRoot → push → appear:right-9 → tab back to left →
     *     *nothing at all* → pop → disappear:left-1
     *
     * Two things in that trace, and both are load bearing. A tab swap fires the
     * arriving screen's `onAppear` and **never** fires the leaving screen's
     * `onDisappear`; and coming back to a tab fires **nothing**, so a screen
     * that is on screen again has no callback to re-claim anything in. A bare
     * `forget()` on the leaving screen would therefore wipe the bar the screen
     * that is actually being looked at has just pointed at itself, and every
     * chip on it would sit empty for as long as that screen was up.
     */
    func release(_ id: String) {
        guard sessionID == id else { return }
        /*
         * **Stops following. Does not blank the row.**
         *
         * > *"coming back it refreshing the page every time I am coming, it
         * > should stay as it is… The visuals, the UI is refreshing kind of
         * > thing."*
         *
         * This used to be `forget()`, and `forget()` sets the three figures to
         * nil — at which point `SessionBarView` draws `EmptyView`, because *"a
         * chip whose figure is unknown is absent"*. That is right for a row with
         * nothing behind it and it is what made every return to a session a
         * visible jolt: the whole strip above the terminal disappeared, the
         * emulator slid up into the space it left, the three answers landed a
         * moment later and it all slid back down. Two layout changes and a
         * repaint of the session, for a session whose figures had not moved.
         *
         * So the two halves of `forget` are separated. What must stop when a
         * screen goes is the **asking** — the quiet-timer that re-reads a
         * printing session, and the questions in flight whose answers nobody is
         * going to look at. What is worth keeping is the **last answer**, held
         * against the session it was about, so somebody coming back sees the row
         * they left and watches the numbers correct themselves in place.
         *
         * The original argument for wiping was *"a ring from a session nobody is
         * looking at is a ring that will be wrong by the time anybody does"*, and
         * it is answered rather than overruled: `follow` re-asks all three the
         * instant the screen is back, so the stale reading is on screen for the
         * length of one round trip and is never what a person is left reading. A
         * *different* session still gets a clean bar — `follow` forgets when the
         * figures belong to somebody else, which is the case that argument was
         * really about.
         */
        quiet?.cancel()
        quiet = nil
        pending.removeAll()
        sessionID = nil
        busy = false
        askedPlanAt = nil
    }

    /**
     * Whose the figures currently on the row are.
     *
     * Distinct from `sessionID`, which is *who is being followed*, and the two
     * genuinely differ for as long as a session's screen is off the stack: after
     * `release` there is nobody to follow and there are still three numbers
     * drawn. This is what tells a return from a switch.
     */
    private(set) var figuresFor: String?

    /// The screen closed for good, or the socket went. Timers stop and nothing
    /// stale is left on a bar that may be drawn again in a second.
    func forget() {
        quiet?.cancel()
        quiet = nil
        pending.removeAll()
        sessionID = nil
        figuresFor = nil
        plan = nil
        context = nil
        planReadAt = nil
        contextReadAt = nil
        account = nil
        accounts = []
        busy = false
        askedPlanAt = nil
    }

    /**
     * The socket went.
     *
     * The figures go with it — a ring is a claim about now, and nothing over a
     * dead channel will correct it. Pending questions are dropped so that an
     * answer arriving on the next connection cannot land against a request id
     * minted on the last one.
     */
    func dropped() {
        quiet?.cancel()
        quiet = nil
        pending.removeAll()
        plan = nil
        context = nil
        planReadAt = nil
        contextReadAt = nil
        busy = false
        askedPlanAt = nil
    }

    /**
     * The session printed something and has now gone quiet.
     *
     * Debounced rather than sent per frame: one answer of an agent CLI is
     * hundreds of `output` frames, and a read per frame would be hundreds of
     * round trips across a relay for one paragraph.
     */
    func noteOutput() {
        // The window is moving. Whatever context figure is on the row is now
        // behind the session, so withdraw it until the debounced re-read below
        // replaces it — never a number climbing while it is read. The plan does
        // not move per output, so its ring stays and stays pressable.
        contextReadAt = nil
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.askUsage(.context)
            self.askPlan()
        }
    }

    // MARK: - Asking

    /// The ring was pressed. The one reading that costs anything over there, so
    /// it happens because a person asked and never on its own.
    func refresh() {
        askUsage(.refresh)
    }

    func askAccount() {
        guard let sessionID, canReadAccount else { return }
        let rid = nextRid()
        send(.accountRead(rid: rid, id: sessionID), rid: rid, as: .account)
    }

    func switchTo(_ accountId: String) {
        guard let sessionID else { return }
        // The usage on the row is this login's, and the switch replaces the
        // process — so withdraw both figures now rather than let the old login's
        // ring sit over the new one until a reading happens to land. They come
        // back when `accountSwitched` re-asks them for whatever runs after.
        planReadAt = nil
        contextReadAt = nil
        let rid = nextRid()
        busy = true
        send(.accountSwitch(rid: rid, id: sessionID, accountId: accountId), rid: rid, as: .accountSwitch)
    }

    /**
     * Sign one of this machine's logins out, from the phone.
     *
     * The act the audit found missing (gap 20): the sheet could move a session
     * between logins but never sign one out, which was desktop-only. This is the
     * machine-scoped verb — no session id — and it is gated on the machine
     * having advertised `logins`, so it is only ever sent where the sheet
     * actually drew the control. Whether the login is gone is the next
     * `account.read`, asked on `logins.signedout`, never assumed from the press.
     */
    func signOut(_ accountId: String) {
        guard canManageLogins else { return }
        let rid = nextRid()
        busy = true
        send(.loginsSignout(rid: rid, accountId: accountId), rid: rid, as: .loginsSignout)
    }

    @discardableResult
    private func askUsage(_ want: UsageWant) -> Bool {
        guard let sessionID, canReadUsage else { return false }
        if want == .refresh { busy = true }
        let rid = nextRid()
        return send(.usageRead(rid: rid, id: sessionID, want: want, force: want == .refresh),
                    rid: rid, as: .usage(want))
    }

    /**
     * The plan figure, at most once a minute.
     *
     * The clock is stamped only when a frame actually left, which is not a
     * detail: stamping it on the attempt means a machine that had not yet said
     * it answers `usage` — or a socket that was down for the two seconds of a
     * reconnect — starts a minute of silence over a question that was never
     * asked, and the ring stays empty for a minute after everything is working
     * again.
     */
    private func askPlan() {
        if let askedPlanAt, now().timeIntervalSince(askedPlanAt) < Self.planThrottle { return }
        if askUsage(.plan) { askedPlanAt = now() }
    }

    /**
     * A request id nothing else will mint.
     *
     * `rid` is what lets one socket carry a terminal, a copilot and this bar
     * asking at once and still tell three answers apart. The counter alone
     * would repeat across a reconnect, which is exactly when a late answer to a
     * dead question arrives.
     */
    private func nextRid() -> String {
        counter += 1
        return "bar-\(counter)-\(UUID().uuidString.prefix(6))"
    }

    /// The request is only remembered once the socket accepted it. A pending
    /// entry for a frame that never left would match a stray answer later — and
    /// a spinner that never stops is worse than a figure that never arrives.
    @discardableResult
    private func send(_ message: ClientMessage, rid: String, as ask: Ask) -> Bool {
        guard wire.send(message) else {
            switch ask {
            case .accountSwitch, .loginsSignout, .usage(.refresh): busy = false
            default: break
            }
            return false
        }
        pending[rid] = ask
        return true
    }

    // MARK: - Answers

    /// True when this frame was one of ours, so the router can stop.
    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .usageReading(rid, id, want, figures):
            guard let ask = pending.removeValue(forKey: rid), ask == .usage(want), id == sessionID else { return false }
            switch want {
            case .context:
                context = figures.context
                // Stamp only a real figure. A nil reading is "the machine did
                // not report", which is absent rather than a fresh nothing.
                contextReadAt = figures.context != nil ? now() : nil
            case .plan, .refresh:
                plan = figures.plan
                planReadAt = figures.plan != nil ? now() : nil
                busy = false
            }
            return true

        case let .accountState(rid, id, current, list):
            guard pending.removeValue(forKey: rid) != nil, id == sessionID else { return false }
            account = current
            accounts = list
            return true

        case let .accountSwitched(rid, id, _):
            guard pending.removeValue(forKey: rid) != nil, id == sessionID else { return false }
            busy = false
            // Asked again rather than assumed: the far end decides whether the
            // switch took, and a chip that renamed itself on the press would be
            // the one surface that disagrees with the machine.
            askAccount()
            // The usage is now about whatever login this session runs as — read
            // it again for the new one so the ring and bar come back fresh
            // rather than staying withdrawn from `switchTo` until the next
            // output. `askedPlanAt` is reset so the throttle does not swallow the
            // one plan read a switch genuinely needs.
            askUsage(.context)
            askedPlanAt = nil
            askPlan()
            return true

        case let .loginsSignedout(rid, _):
            // Machine-scoped: no session id to check, matched on rid alone.
            guard pending.removeValue(forKey: rid) != nil else { return false }
            busy = false
            // Re-read the machine's own list rather than trust the press: the
            // signed-out login's row loses its Sign out because the probe now
            // reports it signed out, which is the visible confirmation — the
            // same way a switch's confirmation is the fresh list, not a sentence.
            askAccount()
            return true

        default:
            return false
        }
    }
}
