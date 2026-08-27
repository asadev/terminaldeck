package dev.terminaldeck.android.alerts

/**
 * Whether an alert is worth interrupting for *right now*, given where the person is looking.
 *
 * [SessionAlerts] decides *that* something worth telling somebody about happened — a session
 * stopped and is asking, or it finished. This decides whether to say it *now* with a banner or
 * stay quiet, and it is the whole of the bug he reported on the phone:
 *
 * > *"even when I am inside the application, on the same page, it is throwing notifications … They
 * > should be only when the AI is working, I am outside of the application, and now there is
 * > something to answer … Instead, for every single move it is giving a notification."*
 *
 * The rule underneath every method here is one sentence: **a notification means "this changed while
 * you were not looking".** If he is looking at the session, or was a moment ago, it did not.
 *
 * ## Why a separate, Android-free class
 *
 * The same judgement already lives on iOS, inside `DeckModel` (`ios/TerminalDeck/App/DeckModel.swift`
 * — `isForeground`, `leftSessionAt`, `isBeingWatched`). There it is testable because that model
 * takes an injected clock and a fake presenter. Here [DeckViewModel] is deliberately free of Android
 * and is an `AndroidViewModel`-shaped thing a plain unit test cannot build, so the rule that must
 * never regress is pulled out into this pure object — no `Context`, its own injected clock — where
 * `AlertGateTest` can move time by hand and prove "state X + where he is looking = Y".
 */
class AlertGate(private val now: () -> Long = { System.currentTimeMillis() }) {

    /**
     * Whether the app is on screen at all.
     *
     * Set by the scene from `ON_START`/`ON_STOP`, the same bracket iOS reads off `.active`/
     * `.background`. Read for exactly two decisions: whether the session being *looked at* should
     * also interrupt with a banner (it should not), and whether a reconnect's catch-up is news or a
     * summary line. With the phone in a pocket this is false, which is the whole situation the
     * feature exists for — so `false` never suppresses anything.
     */
    var isForeground: Boolean = true

    /**
     * The session whose terminal is on screen right now, threaded the way an alert is, or null.
     *
     * "On screen" and not "selected": a banner over the very terminal he is reading is the
     * interruption he complained about, and it is that screen's presence — not which machine is
     * current — that answers it.
     */
    private var open: String? = null

    /**
     * When each session's screen was last left, keyed the way an alert is threaded — machine and
     * session together, because session ids are unique per machine and nothing makes them unique
     * across them.
     */
    private val leftAt = HashMap<String, Long>()

    /** The app came forward. */
    fun enteredForeground() {
        isForeground = true
    }

    /** The app went away — backgrounded, not merely a dialog over it. */
    fun leftForeground() {
        isForeground = false
    }

    /**
     * A terminal came on screen.
     *
     * Marks the session as the one being looked at, and *clears* its departure time rather than
     * setting one: a session he is standing in is covered by [open], and leaving a stale departure
     * behind would mean re-entering a session shortened its own grace the next time he left.
     */
    fun watching(hostId: String, sessionId: String) {
        val thread = SessionAlert.thread(hostId, sessionId)
        open = thread
        leftAt.remove(thread)
    }

    /**
     * A terminal went off screen.
     *
     * Records when, so the [WATCHED_GRACE_MS] below can tell the tail of what he was watching from
     * genuine news. Clears [open] only if this is the session it named: Compose runs an incoming
     * screen's effects *before* the outgoing screen's dispose, so switching from session A to B
     * fires B's `watching` before A's `stoppedWatching`, and an unconditional clear here would wipe
     * the mark B just set, one frame after he opened it.
     */
    fun stoppedWatching(hostId: String, sessionId: String) {
        val thread = SessionAlert.thread(hostId, sessionId)
        if (open == thread) open = null
        leftAt[thread] = now()
    }

    /**
     * Whether this alert is about a session he is looking at — or has just finished looking at.
     *
     * The second half is the part that was missing on this client, and it is the whole of the
     * spam. The desktop does not classify a screen the instant it changes: it waits for the output
     * to stop and then decides (`session-activity.ts`, `SETTLE_MS`). So opening a session *produces
     * output* — `attach` carries this phone's viewport, the pty resizes, a full-screen CLI repaints
     * on `SIGWINCH` — and the `waiting` verdict lands about a second later, by which time he is
     * often back on the list with the session no longer [open]. Without the grace, that verdict is
     * drawn as a banner about something he did on purpose thirty frames ago:
     *
     * > *"see, I go inside I come back it's throwing a new notification. So this is a problem we
     * > need to fix. A lot of notifications."*
     *
     * Away from the app, none of this applies — that is exactly when he wants to hear — so the
     * whole check short-circuits on [isForeground].
     */
    fun isBeingWatched(alert: SessionAlert): Boolean {
        // The app being open at all is the whole answer — no push while he is inside it, whatever
        // screen he is on:
        //
        // > *"They should be only when the AI is working, I am outside of the application, and now
        // > there is something to answer. Even when I am inside the application, on the same page,
        // > it is throwing the notifications — it is too much."*
        //
        // Android, unlike iOS, has no OS-level foreground suppression — a posted notification always
        // shows — so this gate is where "inside the app = silent" has to live. The old check only
        // covered the one session on screen ([open]) and let a *different* session banner while he
        // was still in the app; that is the noise he is describing. The in-app Alerts list and the
        // row status dots carry the same news without interrupting. [open] and the just-left grace
        // stay below only to keep the (now unreachable while-foreground) reasoning honest for a
        // future where a per-screen exception is wanted; today, foreground alone suppresses.
        return isForeground
    }

    companion object {
        /**
         * How long after leaving a session its status changes are still his own doing rather than
         * news. Five seconds, and the number is not taste: it covers the desktop's 700 ms settle
         * plus a relay round trip with room to spare, and it is the same figure iOS uses
         * (`DeckModel.watchedGrace`). Anything later than that really did happen while he was not
         * looking.
         */
        const val WATCHED_GRACE_MS = 5_000L
    }
}
