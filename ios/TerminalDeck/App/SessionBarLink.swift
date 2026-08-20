/**
 * What one session's bar knows, and the conversation behind it.
 *
 * The client half of `usage`, `account` and `chat` — a port of
 * `pwa/src/session-bar.ts` and `pwa/src/chat-view.ts`, which the browser client
 * has had since 2026-08-18 and this app had none of. On his phone the app was
 * a session list and a terminal: no ring, no context, no account, no
 * conversation. Everything drawn from here is the far machine's own figure,
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

    /// The conversation, oldest first.
    private(set) var chat: [CopilotChatMessage] = []
    /// Nil until the far machine has answered once. False means the folder has
    /// no transcript at all — a different empty from a session that has not
    /// spoken yet, and the reason the toggle is absent rather than opening an
    /// empty screen.
    private(set) var transcript: Bool?

    /**
     * Whether the conversation is the thing on screen.
     *
     * Set by the screen, read here, because it decides one thing only: whether
     * a session going quiet is worth a transcript read. A terminal somebody is
     * typing into must not send a file read across a relay after every burst of
     * output.
     */
    var chatting = false

    /// What this machine said it can answer. Nothing is asked for a name that
    /// is not in here, so a desktop older than these capabilities gets a screen
    /// that is exactly what it was rather than one explaining what it lacks.
    private var capabilities: Set<String> = []

    private let wire: CopilotWire
    private var pending: [String: Ask] = [:]
    private var counter = 0
    private var askedPlanAt: Date?
    private var quiet: Task<Void, Never>?
    private var chatTail: Task<Void, Never>?
    private let now: () -> Date

    /// How long before a quiet session's plan figure is worth asking for again.
    static let planThrottle: TimeInterval = 60

    private enum Ask: Equatable {
        case usage(UsageWant)
        case account
        case accountSwitch
        case chat
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
    var canReadChat: Bool { capabilities.contains(WireCapability.chat) }

    /// The screen opened a session. Everything held about the last one goes:
    /// a ring from another session is worse than no ring.
    func follow(_ id: String) {
        if sessionID != id { forget() }
        sessionID = id
        askUsage(.context)
        askPlan()
        askAccount()
    }

    /// The screen closed, or the socket went. Timers stop and nothing stale is
    /// left on a bar that may be drawn again in a second.
    func forget() {
        quiet?.cancel()
        quiet = nil
        chatTail?.cancel()
        chatTail = nil
        pending.removeAll()
        sessionID = nil
        plan = nil
        context = nil
        account = nil
        accounts = []
        busy = false
        chat = []
        transcript = nil
        chatting = false
        askedPlanAt = nil
    }

    /**
     * The socket went.
     *
     * The figures go with it — a ring is a claim about now, and nothing over a
     * dead channel will correct it — and the conversation stays, because a
     * bubble is something that was said and a drop does not unsay it. Pending
     * questions are dropped so that an answer arriving on the next connection
     * cannot land against a request id minted on the last one.
     */
    func dropped() {
        quiet?.cancel()
        quiet = nil
        chatTail?.cancel()
        chatTail = nil
        pending.removeAll()
        plan = nil
        context = nil
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
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.askUsage(.context)
            self.askPlan()
        }
        guard chatting else { return }
        chatTail?.cancel()
        chatTail = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self else { return }
            self.askChat(tail: true)
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
        let rid = nextRid()
        busy = true
        send(.accountSwitch(rid: rid, id: sessionID, accountId: accountId), rid: rid, as: .accountSwitch)
    }

    /// `tail` false is what opening the view asks; true is what a quiet session
    /// asks. Nothing is asked while the conversation is not on screen.
    func askChat(tail: Bool) {
        guard let sessionID, canReadChat else { return }
        let rid = nextRid()
        send(.chatRead(rid: rid, id: sessionID, tail: tail), rid: rid, as: .chat)
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
            case .accountSwitch, .usage(.refresh): busy = false
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
            case .plan, .refresh:
                plan = figures.plan
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
            return true

        case let .chatRows(rid, id, rows, reset, found):
            guard pending.removeValue(forKey: rid) != nil, id == sessionID else { return false }
            chat = SessionBarLink.merge(held: chat, incoming: rows, reset: reset)
            transcript = found
            return true

        default:
            return false
        }
    }

    /**
     * Fold an answer into what is already held.
     *
     * By id: a match is replaced, anything else is appended. That is what makes
     * a growing answer redraw in place instead of stacking a paragraph at a
     * time. `reset` cannot be ignored — it means the far side's document is not
     * the one this view holds a prefix of, and appending through one draws the
     * conversation twice.
     */
    static func merge(held: [CopilotChatMessage],
                      incoming: [CopilotChatMessage],
                      reset: Bool) -> [CopilotChatMessage] {
        var rows = reset ? [] : held
        for row in incoming {
            if let at = rows.firstIndex(where: { $0.id == row.id }) {
                rows[at] = row
            } else {
                rows.append(row)
            }
        }
        return rows
    }
}
