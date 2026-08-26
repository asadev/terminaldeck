package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.AccountWire
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.UsageReadings
import dev.terminaldeck.android.protocol.UsageWant

/**
 * What one session's bar knows, and the conversation behind it.
 *
 * The client half of [Capability.USAGE], [Capability.ACCOUNT], [Capability.CHAT] and
 * [Capability.SEND] — a transcription of `pwa/src/session-bar.ts`, by way
 * of `ios/TerminalDeck/App/SessionBarLink.swift`. The browser client has had all of it since
 * 2026-08-18 and this app had none of it: on a phone the app was a session list and a terminal, with
 * no ring, no context, no account and no conversation. Everything drawn from here is the far
 * machine's own figure, read by the same `readUsage`, `readContextWindow` and `sessionAccount` that
 * draw the bar at the desk, which is what keeps one session from having two truths depending on
 * which screen is looking at it.
 *
 * ## One session at a time, on purpose
 *
 * A phone shows one terminal. This holds the state for whichever session is on screen and drops it
 * when another is opened — [follow] — rather than keeping a table keyed by session. The alternative
 * is a cache that has to be invalidated on every account switch, every reconnect and every rolled-
 * over transcript, to save re-asking a question that costs a few milliseconds on the far side.
 *
 * ## Nothing is polled
 *
 * `context` and `plan` are asked once on attach and then only when the session goes quiet, which is
 * the same event the desktop's own bar rides — a context window moves when the agent writes to its
 * transcript and at no other time. `plan` is throttled on top of that because it is a round trip for
 * a figure that changes on the hour. `refresh` is only ever sent because a finger pressed the ring:
 * it boots a whole Claude Code on the other machine.
 *
 * ## No sentences
 *
 * There is no wording anywhere on this bar. A figure that is not known is a chip that is **not
 * drawn**; a switch the far end would refuse is a row that could not be pressed in the first place.
 * The one exception is the composer, which carries the machine's own refusal verbatim, because a
 * message that did not send and says nothing is a message somebody sends twice.
 */
class SessionBarController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private var sessionId: String? = null

    /**
     * Which screen currently owns this cluster.
     *
     * A number rather than a boolean, and it is the fix for a bug that only shows up on a device:
     * pushing the conversation over the terminal **disposes the terminal**, and Compose runs the new
     * screen's effects *before* the old screen's `onDispose`. So the terminal's teardown arrived
     * after the chat had already claimed the session and cleared it out from under it — the chat
     * screen then sat on "reading the conversation" forever, and the button that opened it looked
     * dead.
     *
     * [follow] hands out a token and [release] only forgets when the token it is given is still the
     * live one. Which makes the order the two effects run in stop mattering, rather than making this
     * code depend on it.
     */
    private var claim = 0

    private var plan: Double? = null
    private var context: Double? = null
    private var account: AccountWire? = null
    private var accounts: List<AccountWire> = emptyList()
    private var busy = false

    private sealed interface Ask {
        data class Usage(val want: UsageWant) : Ask
        data object Account : Ask
        data object AccountSwitch : Ask
    }

    private class Pending(val ask: Ask, val session: String, val cancel: () -> Unit)

    private val pending = HashMap<String, Pending>()
    private var quietCancel: (() -> Unit)? = null
    private var counter = 0
    private var askedPlanAt: Long? = null

    /**
     * Whether this cluster is about a session right now.
     *
     * The one honest way to pick *which machine's* bar a screen means. `firstOrNull { it.bar != null }`
     * is not it: every link is given a controller when it is built, so that expression answers with
     * whichever machine happens to be first in the map — which on a phone with five paired is a
     * machine that has been offline for a week. It sent `chat.read` to the wrong computer and the
     * conversation sat on a spinner.
     */
    val isFollowing: Boolean get() = sessionId != null

    fun canReadUsage(): Boolean = capabilities().contains(Capability.USAGE)

    fun canReadAccount(): Boolean = capabilities().contains(Capability.ACCOUNT)

    /**
     * A snapshot the bar draws from, or null when this machine offers none of it.
     *
     * Null rather than an empty view, so a machine older than these capabilities gets a terminal
     * exactly as it was rather than a bar with nothing in it.
     */
    fun view(): SessionBarView? {
        if (sessionId == null) return null
        if (!canReadUsage() && !canReadAccount()) return null
        return SessionBarView(
            plan = plan,
            context = context,
            account = account,
            accounts = accounts,
            busy = busy,
            canRefresh = canReadUsage(),
            canSwitchAccount = canReadAccount() && accounts.size > 1,
        )
    }

    /** The screen opened a session. Everything held about the last one goes. */
    fun follow(id: String): Int {
        if (sessionId != id) forget()
        sessionId = id
        askUsage(UsageWant.Context)
        askPlan()
        askAccount()
        claim += 1
        onChange()
        return claim
    }

    /**
     * The screen that held [follow]'s token has gone.
     *
     * Forgets only when nothing has claimed the session since — see [claim]. A screen that hands back
     * a stale token is one whose successor is already on top of it, and tearing down for that is how
     * the conversation lost the session it was opened for.
     */
    fun release(token: Int) {
        if (token == claim) forget()
    }

    fun forget() {
        stop()
        sessionId = null
        plan = null
        context = null
        account = null
        accounts = emptyList()
        busy = false
        askedPlanAt = null
        onChange()
    }

    /**
     * The socket went.
     *
     * The figures go with it — a ring is a claim about now, and nothing over a dead channel will
     * correct it — and **the conversation stays**, because a bubble is something that was said and a
     * drop does not unsay it. Pending questions drop so an answer arriving on the next connection
     * cannot land against a request id minted on the last one.
     */
    fun dropped() {
        stop()
        plan = null
        context = null
        busy = false
        askedPlanAt = null
        onChange()
    }

    /**
     * The session printed something and has now gone quiet.
     *
     * Debounced rather than sent per frame: one answer of an agent CLI is hundreds of `output`
     * frames, and a read per frame would be hundreds of round trips across a relay for one
     * paragraph.
     */
    fun noteOutput() {
        if (sessionId == null) return
        quietCancel?.invoke()
        quietCancel = expiry.after(QUIET_MS) {
            quietCancel = null
            askUsage(UsageWant.Context)
            askPlan()
            onChange()
        }
    }

    /** The ring was pressed. The one reading that costs anything over there. */
    fun refresh() {
        if (askUsage(UsageWant.Refresh)) onChange()
    }

    fun askAccount() {
        val id = sessionId ?: return
        if (!canReadAccount()) return
        val key = rid()
        dispatch(ClientMessage.AccountRead(key, id), key, Ask.Account, id)
    }

    fun switchAccount(accountId: String) {
        val id = sessionId ?: return
        if (!canReadAccount() || busy) return
        val key = rid()
        busy = true
        if (!dispatch(
                ClientMessage.AccountSwitch(key, id, accountId.take(Protocol.MAX_ACCOUNT_ID_LENGTH)),
                key,
                Ask.AccountSwitch,
                id,
            )
        ) {
            busy = false
        }
        onChange()
    }


    private fun askUsage(want: UsageWant): Boolean {
        val id = sessionId ?: return false
        if (!canReadUsage()) return false
        if (want == UsageWant.Refresh) {
            if (busy) return false
            busy = true
        }
        val key = rid()
        val left = dispatch(
            ClientMessage.UsageRead(key, id, want, force = want == UsageWant.Refresh),
            key,
            Ask.Usage(want),
            id,
        )
        if (!left && want == UsageWant.Refresh) busy = false
        return left
    }

    /**
     * The plan figure, at most once a minute.
     *
     * The clock is stamped only when a frame actually left, which is not a detail: stamping it on
     * the attempt means a machine that had not yet said it answers `usage` — or a socket that was
     * down for the two seconds of a reconnect — starts a minute of silence over a question that was
     * never asked, and the ring stays empty for a minute after everything is working again.
     */
    private fun askPlan() {
        val last = askedPlanAt
        if (last != null && now() - last < PLAN_THROTTLE_MS) return
        if (askUsage(UsageWant.Plan)) askedPlanAt = now()
    }

    /**
     * A request id nothing else will mint.
     *
     * `rid` is what lets one socket carry a terminal, a control cluster and this bar asking at once
     * and still tell three answers apart.
     */
    private fun rid(): String {
        counter += 1
        return "bar-$counter"
    }

    /**
     * The request is only remembered once the socket accepted it.
     *
     * A pending entry for a frame that never left would match a stray answer later — and a spinner
     * that never stops is worse than a figure that never arrives.
     */
    private fun dispatch(message: ClientMessage, key: String, ask: Ask, session: String): Boolean {
        if (!send(message)) return false
        val cancel = expiry.after(timeoutFor(ask)) {
            val dropped = pending.remove(key) ?: return@after
            when (dropped.ask) {
                is Ask.AccountSwitch, is Ask.Usage -> {
                    busy = false
                    onChange()
                }
                else -> Unit
            }
        }
        pending[key] = Pending(ask, session, cancel)
        return true
    }

    private fun timeoutFor(ask: Ask): Long = when (ask) {
        is Ask.Usage -> if (ask.want == UsageWant.Refresh) REFRESH_TIMEOUT_MS else READ_TIMEOUT_MS
        Ask.AccountSwitch -> SWITCH_TIMEOUT_MS
        else -> READ_TIMEOUT_MS
    }

    /** True when this frame was one of ours, so the router can stop. */
    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.UsageReading -> {
                val asked = pending[message.rid] ?: return false
                val want = (asked.ask as? Ask.Usage)?.want ?: return false
                // The want is checked as well as the rid: the three readings are not
                // interchangeable, and a context figure landing on a plan ring is a full ring drawn
                // out of the wrong number.
                if (want != message.want) return false
                settle(message.rid, asked)
                if (message.id != sessionId) return true
                val figures = UsageReadings.figures(message.want, message.answer.reading)
                when (message.want) {
                    UsageWant.Context -> context = figures.context
                    UsageWant.Plan, UsageWant.Refresh -> {
                        plan = figures.plan
                        busy = false
                    }
                }
                onChange()
                return true
            }
            is ServerMessage.AccountState -> {
                val asked = pending[message.rid] ?: return false
                settle(message.rid, asked)
                if (message.id != sessionId) return true
                account = message.current
                accounts = message.accounts
                onChange()
                return true
            }
            is ServerMessage.AccountSwitched -> {
                val asked = pending[message.rid] ?: return false
                settle(message.rid, asked)
                if (message.id != sessionId) return true
                busy = false
                // Asked again rather than assumed: the far end decides whether the switch took, and
                // a chip that renamed itself on the press would be the one surface that disagrees
                // with the machine.
                askAccount()
                onChange()
                return true
            }
            else -> return false
        }
    }

    private fun settle(requestId: String, asked: Pending) {
        asked.cancel()
        pending.remove(requestId)
    }

    fun stop() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        quietCancel?.invoke()
        quietCancel = null
    }

    companion object {
        const val READ_TIMEOUT_MS = 20_000L
        const val REFRESH_TIMEOUT_MS = 120_000L
        const val SWITCH_TIMEOUT_MS = 60_000L
        const val PLAN_THROTTLE_MS = 60_000L
        private const val QUIET_MS = 1_200L
    }
}

/**
 * What the session bar reads.
 *
 * Every figure is nullable and null means the same thing everywhere: *there is no figure*, which is
 * a chip that is not drawn rather than one drawn at zero.
 */
data class SessionBarView(
    val plan: Double?,
    val context: Double?,
    val account: AccountWire?,
    val accounts: List<AccountWire>,
    val busy: Boolean,
    val canRefresh: Boolean,
    val canSwitchAccount: Boolean,
)

