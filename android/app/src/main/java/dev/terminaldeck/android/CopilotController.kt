package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotActionRow
import dev.terminaldeck.android.protocol.CopilotConsentQuestion
import dev.terminaldeck.android.protocol.CopilotEntry
import dev.terminaldeck.android.protocol.CopilotLinkWire
import dev.terminaldeck.android.protocol.CopilotPendingRow
import dev.terminaldeck.android.protocol.CopilotSessionRow
import dev.terminaldeck.android.protocol.CopilotStateReport
import dev.terminaldeck.android.protocol.CopilotTimeline
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The machine's copilot, as this phone drives it.
 *
 * The client half of [Capability.COPILOT] — a transcription of `ios/TerminalDeck/App/CopilotLink.swift`.
 * *"Phones will have full control over copilot, same as the actual machine app."*
 *
 * ## Nothing is spent by opening the tab
 *
 * `copilot.hello` and `copilot.attach` are the `read` tier: they open the stream and replay what
 * exists. **`copilot.start` is separate and is only ever sent because a finger pressed Start**,
 * because it spawns an agent process on the far machine and that costs money. Folding it into the
 * attach would mean a person who tapped the wrong pill paid for a run.
 *
 * ## Leaving says so
 *
 * `copilot.detach` on the way out and `copilot.bye` when the machine goes. Neither kills the run:
 * the far side keeps it for a grace window, so a phone that locked its screen in a lift comes back
 * to the turn it left rather than to nothing.
 *
 * ## Nothing here writes a sentence about a refusal
 *
 * A tool call this device's grant did not cover arrives as a `copilot.tool` row with the copilot's
 * own words on it, and a settled confirmation says which device answered. Both are drawn verbatim.
 * The only strings this file composes are the ones about *this* end — a socket that is down, a
 * message that could not be sent — because those are facts the far machine has no opinion about.
 */
class CopilotController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val onChange: () -> Unit,
) {

    private var link: CopilotLinkWire? = null
    private var state: CopilotStateReport? = null
    private var entries: List<CopilotEntry> = emptyList()
    private var sessions: List<CopilotSessionRow> = emptyList()
    private var pending: List<CopilotPendingRow> = emptyList()
    private var question: CopilotConsentQuestion? = null
    private var notice: ActionNotice? = null

    /** Whether the stream is open on this socket, so a re-attach is not sent on every visit. */
    private var attached = false

    /** True while a `copilot.log` is outstanding, so a second scroll does not ask twice. */
    private var readingLog = false

    /** Whether the machine advertises a copilot at all. The first of the two gates. */
    fun offered(): Boolean = capabilities().contains(Capability.COPILOT)

    /**
     * Where this phone stands, from what the machine said and nothing else.
     *
     * The capability is the first gate and the grant is the second — see [CopilotAccess].
     */
    fun access(): CopilotAccess = CopilotAccess.read(offered(), link)

    /**
     * A snapshot the tab draws from, or null when this machine offers no copilot to this phone.
     *
     * Null rather than an empty view, so the pill is simply absent over a machine with no copilot —
     * iOS's own rule for that tab: conditional, never an empty one.
     */
    fun view(): CopilotView? {
        val access = access()
        if (access == CopilotAccess.NotOffered) return null
        return CopilotView(
            access = access,
            state = state,
            entries = entries,
            sessions = sessions,
            pending = pending,
            question = question,
            notice = notice,
            waitingCount = pending.count { it.mine } + (if (question != null) 1 else 0),
        )
    }

    /* ------------------------------------------------------------------ lifecycle -- */

    /**
     * The tab opened.
     *
     * `hello` then `attach`, and nothing else: both are `read`, so a machine that has granted this
     * device only watching gets exactly the same two frames and exactly the same replay.
     */
    fun open() {
        if (!offered() || attached) return
        if (!send(ClientMessage.CopilotHello)) return
        send(ClientMessage.CopilotAttach)
        send(ClientMessage.CopilotSessions)
        send(ClientMessage.CopilotPending)
        attached = true
        onChange()
    }

    /**
     * The tab closed.
     *
     * Detach rather than stop: leaving a screen is not asking for an agent to be killed mid-turn.
     */
    fun close() {
        if (!attached) return
        attached = false
        send(ClientMessage.CopilotDetach)
        onChange()
    }

    /**
     * The connection went, or a welcome replaced it.
     *
     * The **conversation stays** and the state goes. A bubble is something that was said and a drop
     * does not unsay it; a state is a claim about now and nothing over a dead channel will correct
     * it. The question goes too — an unanswerable confirmation left on screen is three buttons that
     * do nothing, which is the design brief's first rule.
     */
    fun dropped() {
        attached = false
        readingLog = false
        state = null
        question = null
        pending = emptyList()
        onChange()
    }

    /** The machine came back. Re-open if the tab is what is on screen. */
    fun renew() {
        val wasAttached = attached
        attached = false
        if (wasAttached) open()
    }

    fun stop() {
        attached = false
        link = null
        state = null
        entries = emptyList()
        sessions = emptyList()
        pending = emptyList()
        question = null
        notice = null
    }

    /* ---------------------------------------------------------------------- verbs -- */

    /**
     * Start this device's run. **The one verb that spends money, and it is only ever a tap.**
     *
     * Refused on this side when the grant does not carry `act`, rather than sent and refused over
     * there: the button is not drawn in that state, and this is the second lock on the same door.
     */
    fun start() {
        if (!access().canAct) return
        if (!send(ClientMessage.CopilotStart)) {
            say(false, NOT_CONNECTED)
            return
        }
        onChange()
    }

    /** Interrupt the turn in flight. This device's own run and nothing else. */
    fun cancel() {
        if (!access().canAct) return
        if (!send(ClientMessage.CopilotCancel)) say(false, NOT_CONNECTED)
    }

    /** End this device's run. The conversation stays on screen — it is what was said. */
    fun stopRun() {
        if (!access().canAct) return
        if (!send(ClientMessage.CopilotStop)) say(false, NOT_CONNECTED)
    }

    /**
     * Say something to it.
     *
     * Returns whether the composer may clear its draft. False keeps it in the box, which is the whole
     * reason a composer reports rather than fires and forgets: a message that did not send and says
     * nothing is a message somebody sends twice.
     *
     * Two checks happen here rather than at the far end, and both are refusals the desktop would make
     * by **closing the socket**: an over-long message, and one carrying a control character. The
     * second is the security one — the text is written into a pty holding an agent CLI, where a
     * carriage return submits early and turns the rest into a second prompt. Refused rather than
     * stripped, because stripping turns a hostile value into a different legal-looking message and
     * the result of that is a turn somebody pays for.
     */
    fun say(text: String): Boolean {
        if (!access().canAct) return false
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return false
        if (Protocol.overBytes(trimmed, Protocol.MAX_COPILOT_SAY_BYTES)) {
            say(false, TOO_LONG)
            return false
        }
        if (Protocol.hasControlCharacters(trimmed)) {
            say(false, UNUSABLE)
            return false
        }
        if (!send(ClientMessage.CopilotSay(trimmed))) {
            say(false, NOT_CONNECTED)
            return false
        }
        notice = null
        onChange()
        return true
    }

    /**
     * Answer the confirmation on screen.
     *
     * The question is taken off the screen on the send rather than on the settle, because the far end
     * answers every question exactly once and the loser of a race is told where it was answered — so
     * a dialog left up would be one this device can no longer act on.
     */
    fun answer(approved: Boolean) {
        val asking = question ?: return
        if (!send(ClientMessage.CopilotAnswer(asking.id, approved))) {
            say(false, NOT_CONNECTED)
            return
        }
        question = null
        onChange()
    }

    /** Page the log backwards. A no-op while one is outstanding, so a fast scroll asks once. */
    fun readLog(before: String? = null) {
        if (access() == CopilotAccess.NotOffered || readingLog) return
        if (!send(ClientMessage.CopilotLog(limit = Protocol.MAX_COPILOT_LOG_ROWS, before = before))) return
        readingLog = true
    }

    fun refreshSessions() {
        if (access() == CopilotAccess.NotOffered) return
        send(ClientMessage.CopilotSessions)
    }

    fun dismissNotice() {
        if (notice == null) return
        notice = null
        onChange()
    }

    /* --------------------------------------------------------------------- frames -- */

    /** True when the frame belonged to the copilot. Unclaimed frames fall through to the fold. */
    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.CopilotGrant -> {
                link = message.link
                // A grant that closed takes the stream with it: the far side has stopped serving this
                // connection, and a client that kept `attached` would never re-open on the next visit.
                if (!message.link.open) attached = false
            }

            is ServerMessage.CopilotStateFrame -> {
                state = message.state
                // The grant rides on the state as well as on its own frame. Read from whichever
                // arrived last rather than only from `copilot.grant`, because a fresh attach answers
                // with the state first and a tab that waited for the push would draw Connecting over
                // a copilot that was already open.
                link = (link ?: CopilotLinkWire()).copy(
                    linked = true,
                    open = true,
                    grant = message.state.grant,
                )
            }

            is ServerMessage.CopilotChat -> {
                /*
                 * A frame from a previous run is dropped rather than merged.
                 *
                 * Without this a phone that reconnected after the grace window expired would splice
                 * the end of a dead conversation onto the start of a live one, and the person would
                 * read an answer to a question they never asked in this run. A `reset` is always
                 * taken, because a reset is the far side saying *this is the whole conversation now*.
                 */
                val run = state?.run
                if (!message.reset && run != null && message.run.isNotEmpty() && message.run != run) {
                    return true
                }
                entries = CopilotTimeline.mergeChat(entries, message.messages, message.reset)
            }

            is ServerMessage.CopilotTool -> entries = CopilotTimeline.mergeTool(entries, message.row)

            is ServerMessage.CopilotLogRows -> {
                readingLog = false
                entries = CopilotTimeline.mergeLog(entries, message.rows)
            }

            is ServerMessage.CopilotSessionsRows -> sessions = message.sessions

            is ServerMessage.CopilotPendingRows -> pending = message.questions

            is ServerMessage.CopilotAsk -> {
                // Only ever sent to the surface that owns the run that raised it, so arriving here is
                // itself the permission — there is no second check to make.
                question = message.question
            }

            is ServerMessage.CopilotSettled -> {
                if (question?.id == message.settled.id) question = null
                pending = pending.filterNot { it.id == message.settled.id }
                // Where it was answered, in the machine's own words. A dialog that vanished without
                // saying would be the app doing something behind a person's back.
                val by = message.settled.by
                if (by != null && by.isNotEmpty()) {
                    say(message.settled.granted, "Answered on $by.")
                }
            }

            else -> return false
        }
        onChange()
        return true
    }

    private fun say(ok: Boolean, text: String) {
        notice = ActionNotice(ok, text)
    }

    companion object {
        const val NOT_CONNECTED = "Not connected, so that did not reach the machine."
        const val TOO_LONG = "That message is longer than the machine will take at once."
        const val UNUSABLE =
            "That message has a line break or a control character in it, which the agent would read " +
                "as a second prompt. Take it out and send it again."
    }
}

/**
 * What the Copilot tab reads.
 *
 * [waitingCount] is what the pill's badge draws. It counts this device's own questions — the ones it
 * can actually answer — because a badge that counted somebody else's would send a person to a screen
 * with nothing to press.
 */
data class CopilotView(
    val access: CopilotAccess,
    val state: CopilotStateReport?,
    val entries: List<CopilotEntry>,
    val sessions: List<CopilotSessionRow>,
    val pending: List<CopilotPendingRow>,
    val question: CopilotConsentQuestion?,
    val notice: ActionNotice?,
    val waitingCount: Int,
) {
    /** Whether the composer is drawn: this device may act, and it has a run to talk to. */
    val canSay: Boolean get() = access.canAct && state?.hasRun == true

    /** Whether Start is drawn: this device may act, has no run, and the machine says it can. */
    val canStart: Boolean
        get() = access.canAct && state?.hasRun != true && state?.available == true

    /** The machine's own sentence for why there is no copilot to start, or null. */
    val unavailable: String?
        get() {
            val report = state ?: return null
            if (report.available) return null
            return report.reason?.takeIf { it.isNotEmpty() }
        }
}
