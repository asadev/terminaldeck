package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotActionRow
import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.CopilotConsentQuestion
import dev.terminaldeck.android.protocol.CopilotEntry
import dev.terminaldeck.android.protocol.CopilotGrantWire
import dev.terminaldeck.android.protocol.CopilotLinkWire
import dev.terminaldeck.android.protocol.CopilotPendingRow
import dev.terminaldeck.android.protocol.CopilotSendState
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
    private val expiry: Expiry,
    private val now: () -> Long = System::currentTimeMillis,
    private val onChange: () -> Unit,
) {

    private var link: CopilotLinkWire? = null
    private var state: CopilotStateReport? = null
    private var entries: List<CopilotEntry> = emptyList()
    private var sessions: List<CopilotSessionRow> = emptyList()
    private var pending: List<CopilotPendingRow> = emptyList()
    private var question: CopilotConsentQuestion? = null
    private var notice: ActionNotice? = null

    /**
     * The screen is up and wants the stream.
     *
     * Separate from [attached], and the separation is a defect this class shipped. There was one
     * flag for both, so a socket that dropped cleared it — and the `welcome` that followed found
     * nothing to renew, because the thing it tested had been cleared by the drop three seconds
     * earlier. The screen stayed exactly as it was, with a live composer over a stream that had
     * gone, and nothing on it ever changed again. Measured on an emulator on 2026-08-22.
     */
    private var wanted = false

    /** `copilot.hello` is on this socket. Cleared by a drop, because the next socket is a new one. */
    private var helloed = false

    /** Whether the stream is open on this socket, so a re-attach is not sent on every visit. */
    private var attached = false

    /** Counter behind the local id on a [CopilotEntry.Mine]. Never leaves this device. */
    private var sent = 0L

    /** Cancels for the waits on this phone's own messages, by local id. */
    private val waits = mutableMapOf<String, () -> Unit>()

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
            // The grant the machine handed this device, so the control screen's permission panel can
            // draw the three tiers as *readings*. Kept from whichever of the grant frame and the
            // state frame arrived last — see [receive] — so it is the same one [access] was read off.
            grant = link?.grant ?: CopilotGrantWire(),
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
     * **`hello` first, and `attach` only once it has been answered.** They used to go out together
     * in one burst, and that was the bug a person met on their very first visit to this screen:
     * `server.ts` refuses every `copilot.*` verb from a socket whose `copilotOpen` is still false,
     * and `copilotOpen` is set by the *answer* to the hello. So the attach, the session list and
     * the pending list were all three refused, no `copilot.state` ever came back, and the screen
     * drew an empty grey bar under the word **"Watching"** — over a phone that had been granted
     * every tier. Leaving the screen and coming back fixed it, because by then the hello had landed.
     * Photographed on an emulator on 2026-08-22, against the real desktop code.
     *
     * The subscription now hangs off `copilot.grant` with `open: true`, which is what iOS's
     * `CopilotLink` has always done and is the only ordering the desktop actually promises.
     */
    fun open() {
        if (!offered()) return
        wanted = true
        /*
         * The shortcut is gated on **this socket having said hello**, not on the grant.
         *
         * `dropped()` deliberately keeps the last grant — it is a fact about the machine, and
         * throwing it away would take the screen down for the three seconds of a reconnect. But it
         * is not a fact about the *new* socket, and reading it as one put the original defect
         * straight back: after a reconnect this method saw `link.open == true`, skipped the hello
         * and sent an attach that the desktop refused, so the screen kept a conversation it could
         * no longer add to and lost its state strip and composer for good. Reproduced on an
         * emulator by turning airplane mode on and off.
         */
        if (helloed) {
            if (link?.open == true && !attached) subscribe()
            return
        }
        if (!send(ClientMessage.CopilotHello)) return
        helloed = true
        onChange()
    }

    /**
     * Ask for the stream and for the two lists it does not replay.
     *
     * Every frame here is `read`, so a device granted only watching sends exactly these and gets
     * exactly the same replay.
     */
    private fun subscribe() {
        if (!offered() || attached) return
        if (!send(ClientMessage.CopilotAttach)) return
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
        wanted = false
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
        helloed = false
        readingLog = false
        state = null
        question = null
        pending = emptyList()
        onChange()
    }

    /**
     * The machine came back. Say hello again if the tab is what is on screen.
     *
     * Keyed on [wanted] — *is this screen up* — rather than on [attached], which the drop has
     * already cleared by the time this runs. The old version read the flag the drop had just
     * cleared, concluded nothing had been attached, and returned: after **any** reconnect the
     * copilot screen went permanently deaf, keeping a conversation that could no longer grow and a
     * composer whose messages went into a stream nobody was serving.
     */
    fun renew() {
        attached = false
        helloed = false
        if (wanted) open()
    }

    fun stop() {
        wanted = false
        attached = false
        helloed = false
        link = null
        state = null
        entries = emptyList()
        sessions = emptyList()
        pending = emptyList()
        question = null
        notice = null
        for (cancel in waits.values) cancel()
        waits.clear()
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
     * Turn driving mode's on-screen scan on or off — the machine's own
     * `copilot.interactive` setting, the desktop's *"show me what it is looking
     * at"* switch.
     *
     * The `alter` tier, guarded here as well as by the switch being drawn only
     * under that grant: it writes a machine setting, and `alter` is the tier that
     * means *a person deliberately decided this device may*. The machine echoes a
     * fresh `copilot.state` after the write — the same as [start] and [stopRun] —
     * so the switch follows the setting it changed rather than this end asserting
     * a value nothing confirmed.
     */
    fun setInteractive(on: Boolean) {
        if (link?.grant?.alter != true) return
        if (!send(ClientMessage.CopilotSetInteractive(on))) say(false, NOT_CONNECTED)
    }

    /**
     * A sentence about this end, put on screen.
     *
     * The `onChange()` is the whole of what was missing, and it made every one of these silent:
     * *"Not connected, so that did not reach the machine"*, the length refusal and the control-
     * character refusal were all composed correctly, stored on the field the screen draws, and
     * never shown — because nothing told Compose to look again. A person pressing Send over a dead
     * socket got a draft that stayed in the box for no stated reason, which reads as a button that
     * has stopped working.
     */
    private fun say(ok: Boolean, text: String) {
        notice = ActionNotice(ok, text)
        onChange()
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
        /*
         * The bubble, now, rather than in three seconds' time.
         *
         * Drawn **only on this branch** — the one where the frame is on the socket. Every refusal
         * above keeps the draft in the box and says why under the composer, because a bubble over a
         * full text field is one message shown twice and the person cannot tell which one is real.
         */
        sent += 1
        val localId = sent.toString()
        entries = CopilotTimeline.appendMine(
            entries,
            CopilotEntry.Mine(localId = localId, text = trimmed, at = now()),
        )
        waits[localId] = expiry.after(ECHO_WAIT_MS) {
            waits.remove(localId)
            if (entries.none { it is CopilotEntry.Mine && it.localId == localId }) return@after
            entries = CopilotTimeline.mark(entries, localId, CopilotSendState.Unacknowledged)
            onChange()
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
                // A grant that closed takes the stream **and the hello** with it: the far side has
                // stopped serving this connection, so the next visit has to introduce itself again.
                // A client that kept either flag would never re-open.
                if (!message.link.open) {
                    attached = false
                    helloed = false
                }
                // And an *open* one is the answer to the hello — the moment the desktop starts
                // serving `copilot.*` on this socket, and therefore the only moment an attach can
                // succeed. See [open].
                if (message.link.open && wanted && !attached) subscribe()
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
                sweepWaits()
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

    /**
     * Drop the waits belonging to rows the machine has now echoed.
     *
     * A timer left running against a row that is no longer on the timeline would fire into nothing,
     * which is harmless, and would hold a closure over this controller for half a minute, which is
     * the kind of thing that outlives a machine being forgotten. Cheap to sweep, so it is swept.
     */
    private fun sweepWaits() {
        if (waits.isEmpty()) return
        val alive = entries.filterIsInstance<CopilotEntry.Mine>().map { it.localId }.toSet()
        val gone = waits.keys.filterNot { alive.contains(it) }
        for (id in gone) waits.remove(id)?.invoke()
    }

    companion object {
        /**
         * How long one of this phone's own messages may go unechoed before the row says so.
         *
         * The echo is not a network acknowledgement, and no shorter number would be honest: it comes
         * back when the agent CLI has taken the turn, and the first message to a device starts the
         * run — a cold CLI reading an MCP config, several seconds on this Mac and more on a slow
         * one. Thirty is comfortably past that, and is the number `pwa/src/copilot.ts` reached for
         * the same question from the same measurement.
         */
        const val ECHO_WAIT_MS = 30_000L

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
    /** The three tiers the machine granted this device, drawn as readings on the control screen's
     *  permission panel. Not switches — pairing as one of the owner's own devices *is* the grant,
     *  and nothing on this phone can widen it. */
    val grant: CopilotGrantWire = CopilotGrantWire(),
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
