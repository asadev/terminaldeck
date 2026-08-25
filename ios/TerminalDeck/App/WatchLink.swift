/**
 * Watching the machine's browser from a phone — the surface list, and the frame
 * routing behind the live view.
 *
 * The client half of `watch`, reached over the capability the host advertises
 * only to one of the owner's own devices (watching a signed-in browser is an
 * owner act). This holds the shared part — the tab strip, the capability, and
 * the frames as they arrive — and `WatchView` holds the per-surface part: the
 * paint/ack loop and the gestures, because the ack has to fire from the draw
 * callback and a gesture is measured against the frame currently on screen.
 *
 * ## One surface at a time, on purpose
 *
 * The PWA mounts a canvas per watched window because a browser tab can hold
 * several at once. A phone screen is one surface: opening a tab from the strip
 * casts it full-screen, and closing the viewer stops the cast. So a single frame
 * sink is enough, and `frameHandler` is it — set by the viewer on appear,
 * cleared on disappear. A frame for a window nothing is showing is dropped, not
 * buffered: a live frame is stale before anything could catch up on it.
 */

import Foundation

/**
 * What this phone knows about the handover on one window.
 *
 * The wire's `browser.handover.state` plus two things it does not carry and this
 * end has to work out, because the person looking at the screen needs them and
 * the frame has no field for either.
 */
struct BrowserHandover: Equatable {
    /// A handover is outstanding on this window: the agent has stopped and is
    /// waiting for a person.
    var asking: Bool
    /// The agent's own sentence — what it wants typed.
    var prompt: String
    /// This device is the one holding it. The pixels arrive unmasked and the
    /// taps are dispatched; nothing else on the phone had to change for that.
    var mine: Bool
    /**
     * Somebody holds it — this device, or another one.
     *
     * Read off the frame rather than worked out here. It used to be derived from
     * the shape of the pushes (a second unsolicited state for a window already
     * asking could only be somebody taking it), and the derivation was correct
     * and still wrong to ship: a state this end guessed at was standing between
     * a blocked agent and the person who could unblock it, so it needed a hedge
     * — a demoted *ask for it anyway* — and that hedge was itself a way for a
     * second person to grab a page mid-password. `taken` is a fact from the
     * host, so it needs neither.
     *
     * With `mine` it makes the three states exactly: `!taken` is claimable,
     * `taken && mine` is yours, `taken && !mine` is somebody else's.
     */
    var taken: Bool
    /// The machine's own sentence, when a claim from this device was refused.
    /// Never this end's words for it: the wire's error frame carries no reason
    /// code for this and inventing one would be inventing why.
    var refusal: String?
}

@MainActor
@Observable
final class WatchLink {
    /// The watchable surfaces — the browser's tab strip — or empty until asked.
    private(set) var surfaces: [BrowserSurfaceRow] = []
    /// The window currently being cast to the viewer, or nil when none is open.
    private(set) var watching: String?

    /**
     * The handover on each window that has one, by window name.
     *
     * A dictionary rather than a single value because two windows can be asking
     * at once — two sessions, two agents, two logins — and the screen that draws
     * one of them is addressed by the window it is showing. Windows with nothing
     * outstanding are absent rather than present-and-false, so `handover(_:)`
     * returning nil is the ordinary answer and the bar is simply not drawn.
     */
    private(set) var handovers: [String: BrowserHandover] = [:]

    /**
     * Windows with a `take` or a `done` of ours in flight.
     *
     * Two jobs, and the second is the one that matters. It stops a double tap
     * sending a second claim — which on a `done` would be a second, opposite
     * answer to a question that has already been answered. And it is what
     * `wireErrored` reads: the wire's error frame carries no correlation id, so
     * an error arriving while exactly this is outstanding is treated as this
     * one's refusal. That is the same assumption `HostLink` already makes for
     * the copilot and for a folder browse, in the same words.
     */
    private var awaiting: Set<String> = []

    /**
     * The windows this phone has asked the machine to cast, and has not since
     * stopped.
     *
     * `watching` above is *the one window the viewer is showing* and stays a
     * single value; this is a different question that used to be read off it and
     * cannot be. Three screens can mount a canvas — a window on the Browser tab,
     * the surface viewer, and the page inside a session — and a second canvas
     * that starts and then stops the cast of **the same window** leaves
     * `watching` nil while a canvas that never moved is still on screen. *Is
     * anything arriving for this window?* has to survive that, because the pane
     * that draws a fold reads it to decide whether there is anything to fold.
     *
     * A record of what this end has asked for rather than of what the host is
     * doing: written when a `browser.watch` actually leaves, removed by
     * `unwatch`, and emptied by a new welcome along with everything else that
     * belonged to the last machine.
     */
    private var casting: Set<String> = []

    private var capabilities: Set<String> = []
    private var requested = false
    private let wire: CopilotWire
    private var counter = 0

    /// The viewer's frame sink. Set on appear, cleared on disappear. The frames
    /// themselves are never a property change — the viewer needs each one in a
    /// callback it can ack from — but *whether there is a sink at all* is read by
    /// `isCasting`, and that moves only when a canvas is built or dismantled.
    var frameHandler: ((BrowserFrame) -> Void)?

    init(wire: CopilotWire) {
        self.wire = wire
    }

    var offered: Bool { capabilities.contains(WireCapability.watch) }

    /// A new welcome: forget the last machine's strip. The surfaces belong to
    /// whichever machine this connection reaches, and a guest is not told the
    /// capability exists.
    func welcomed(capabilities: Set<String>) {
        self.capabilities = capabilities
        surfaces = []
        watching = nil
        casting = []
        requested = false
        frameHandler = nil
        // The handover belongs to a connection, not to a phone: `mine` is the
        // one per-connection field on the wire, and a socket that has just come
        // back is not the socket that was granted anything. Kept from before, it
        // would draw *you have this page* over a page this device no longer has.
        handovers = [:]
        awaiting = []
    }

    /// Ask for the tab strip once, when the screen opens.
    func ensureRead() {
        guard offered, !requested else { return }
        ask()
    }

    /**
     * Ask again, and this one has no `requested` guard on purpose.
     *
     * `BrowserSurfacesRowsFrame` describes itself as *"also pushed unsolicited
     * when the strip changes"* and **nothing sends that push**: `server.ts`
     * answers `browser.surfaces` and has no `surfacesChanged`, which
     * `src/headless/host.ts` records in its own words where it wires `openUrl` —
     * *"a row opened from the address bar is in the list the next time the list
     * is asked for."*
     *
     * So `ensureRead` asking once per connection meant the strip was frozen at
     * whatever the machine had when the first screen opened. A page opened from
     * the address bar — the whole of *"it should browser and stream here to
     * interact"* — never appeared, and neither did a window a session opened
     * while the phone was watching. This is one small frame, guarded on the
     * capability, and the screens that list surfaces call it on every appearance
     * the same way they already re-read the window list.
     */
    func read() {
        ask()
    }

    private func ask() {
        guard offered else { return }
        let rid = nextRid()
        guard wire.send(.browserSurfaces(rid: rid)) else { return }
        requested = true
    }

    /// Start (or renegotiate) the cast of one surface to the viewer. `window` is
    /// `""` for the front tab or a slot name. Idempotent host-side — re-sending
    /// it is how a resize renegotiates. Returns whether the frame left.
    @discardableResult
    func watch(window: String, maxWidth: Int, quality: Int) -> Bool {
        guard offered else { return false }
        watching = window
        let sent = wire.send(.browserWatch(window: window, maxWidth: maxWidth, quality: quality))
        // Recorded only once the frame has actually left: `casting` is what this
        // end has asked the machine for, and a send that failed asked it nothing.
        if sent { casting.insert(window) }
        return sent
    }

    /**
     * Stop the cast of the window being shown. Called when the viewer closes.
     *
     * **The handover survives this**, and it is no longer the workaround it
     * started as. The host now pushes the state to a connection that starts
     * watching a window with a question outstanding, so a re-watch re-establishes
     * the truth on its own and this could safely forget. It does not, for one
     * specific reason written five lines below: **this `unwatch` is
     * unconditional**. A canvas going away sends it even when another canvas is
     * showing the same surface and has its own `browser.watch` running, and the
     * host — which sees no *new* watch from that survivor — would push nothing to
     * replace what was cleared. Forgetting here would blank a live bar under
     * somebody's hands, mid-login, on a screen that never stopped watching.
     *
     * So the cost is inverted rather than removed: keeping it risks a stale bar
     * that the next push corrects, and the next push now always comes.
     *
     * The **cast** does not survive it, and that is the fact `casting` is kept
     * for. One connection is one `watcherId` on the host, so this stops the
     * pictures for every canvas on this phone and not only for the one going
     * away — which is how a session's page came to be drawn under a strip still
     * offering to fold it. `isCasting` below is what lets a screen see that
     * rather than assume the opposite.
     */
    func unwatch(window: String) {
        _ = wire.send(.browserUnwatch(window: window))
        casting.remove(window)
        if watching == window { watching = nil }
    }

    /**
     * Whether a page is actually reaching this phone for `window`.
     *
     * Both halves, because either one alone has been true while the screen was
     * blank: a `browser.watch` of ours still standing, **and** something
     * registered to draw what comes back. `WatchSurfaceUIView.tearDown` does the
     * two of them in one breath — it sends `browser.unwatch`, and when it is the
     * canvas that owns the sink it clears the sink — and one connection has one
     * `watcherId` on the host, so a canvas going away on one tab stops the cast
     * for a canvas on another tab and leaves it mounted, on screen and blind.
     * That is the state photographed under a strip still offering to fold a page
     * away; `SessionPageView` reads this to stop offering it.
     *
     * The sink is answered by *is there one at all* rather than by *is it this
     * window's*, which is the most this end can honestly say: `frameHandler` is a
     * closure handed in by whichever canvas holds it and it names no window here.
     * It over-reports only while another screen's canvas is alive and showing
     * something else — a moment when this window is not the one being looked at
     * — and it is read again on the next press.
     */
    func isCasting(_ window: String) -> Bool { casting.contains(window) && frameHandler != nil }

    /// Rendered — send the next frame. The one-in-flight backpressure.
    func ack(window: String, seq: Int) {
        _ = wire.send(.browserFrameAck(window: window, seq: seq))
    }

    /// A gesture aimed at the frame named by `seq`.
    func input(window: String, seq: Int, input: BrowserInput) {
        _ = wire.send(.browserInput(window: window, seq: seq, input: input))
    }

    // MARK: - The handover

    /// What this phone knows about the handover on one window, or nil when
    /// nothing is outstanding there.
    func handover(_ window: String) -> BrowserHandover? { handovers[window] }

    /// Whether an answer of ours about this window is still in flight — a claim
    /// sent, or a hand-back sent, and no state back yet.
    func isAwaiting(_ window: String) -> Bool { awaiting.contains(window) }

    /**
     * **That person is me.** Claim the page the agent is waiting on.
     *
     * Guarded on there actually being a question, because a `take` for a window
     * with no handover outstanding is refused at the far end and the refusal is
     * a sentence on a screen instead of a button that quietly does nothing. The
     * far end's other guard — that this connection may already watch the window
     * — is not repeated here: this end cannot know a grant, and a screen only
     * reaches this from a surface it is already being cast.
     */
    @discardableResult
    func take(window: String) -> Bool {
        guard offered, handovers[window]?.asking == true, !awaiting.contains(window) else { return false }
        let rid = nextRid()
        guard wire.send(.browserHandoverTake(rid: rid, window: window)) else { return false }
        // The last refusal goes with the new attempt. Leaving it up beside a
        // claim that is in flight is the screen contradicting itself.
        handovers[window]?.refusal = nil
        awaiting.insert(window)
        return true
    }

    /**
     * Hand it back, and say which of the two things that means.
     *
     * `carryOn: true` returns the baton and the agent's blocked call resolves;
     * `carryOn: false` ends the drive. Only from the device that holds it —
     * `mine` is the guard, and the far end applies the same one, because a
     * second watcher handing back a page mid-password on behalf of the person
     * typing into it is the exact thing both ends are written to refuse.
     */
    @discardableResult
    func handBack(window: String, carryOn: Bool) -> Bool {
        guard offered, handovers[window]?.mine == true, !awaiting.contains(window) else { return false }
        let rid = nextRid()
        guard wire.send(.browserHandoverDone(rid: rid, window: window, carryOn: carryOn)) else { return false }
        awaiting.insert(window)
        return true
    }

    /**
     * The machine refused something while an answer of ours was in flight.
     *
     * `error` carries no correlation id — the whole wire has one shape of error
     * and it names no request — so this cannot be narrowed to *our* frame
     * without inventing a field. What it can be narrowed to is *a moment when
     * this phone had exactly one handover answer outstanding*, which is what
     * `awaiting` is, and the cost of being wrong is one sentence on a bar that
     * the next state push clears.
     *
     * The refusal is drawn **beside** the claim rather than instead of it, and
     * the claim becomes *Try again*. Taking the button away would be this end
     * deciding the refusal is permanent, which it has no way to know — the
     * likeliest one is a race, the agent's question arriving here a moment
     * before the far end was ready to be asked about it. A sentence in the
     * machine's own words plus a way to ask again is what this end can honestly
     * offer; any state frame that follows clears both.
     */
    func wireErrored(_ message: String) {
        guard !awaiting.isEmpty else { return }
        let sentence = message.isEmpty ? "The machine refused that." : message
        for window in awaiting {
            handovers[window]?.refusal = sentence
        }
        awaiting.removeAll()
    }

    @discardableResult
    func receive(_ message: ServerMessage) -> Bool {
        switch message {
        case let .browserSurfaces(_, surfaces):
            // Answer or unsolicited push — the strip is the whole list either
            // way, so the rid is not matched (there is nothing to resolve).
            self.surfaces = surfaces
            return true
        case let .browserFrame(frame):
            // Routed to the open viewer, or dropped. A frame for a surface
            // nothing is showing is stale the instant it is not drawn.
            frameHandler?(frame)
            return true
        case let .browserHandover(state):
            apply(state)
            return true
        default:
            return false
        }
    }

    /**
     * Fold one state frame into what this phone is showing.
     *
     * Answer and push are the same thing here, the way they are for the surface
     * strip — the state is the whole truth either way, so the rid is not matched
     * and nothing is resolved against it. It is a plain overwrite now that
     * `taken` is carried rather than derived: there is no reading of this frame
     * that needs to know what the last one said.
     *
     * A window that has stopped asking is **removed** rather than kept with
     * `asking: false`. The one thing this end still holds of its own — a refusal
     * — is about one outstanding question, and a question that is over should
     * not leave its answers behind for the next one to inherit.
     */
    private func apply(_ state: BrowserHandoverState) {
        awaiting.remove(state.window)
        guard state.asking else {
            handovers[state.window] = nil
            return
        }
        handovers[state.window] = BrowserHandover(asking: true, prompt: state.prompt,
                                                  mine: state.mine, taken: state.taken,
                                                  refusal: nil)
    }

    private func nextRid() -> String {
        counter += 1
        return "wch-\(counter)-\(UUID().uuidString.prefix(6))"
    }
}
