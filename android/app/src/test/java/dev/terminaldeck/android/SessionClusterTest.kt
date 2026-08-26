package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.AccountWire
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ControlAgentWire
import dev.terminaldeck.android.protocol.ControlGateWire
import dev.terminaldeck.android.protocol.ControlName
import dev.terminaldeck.android.protocol.ControlReadingWire
import dev.terminaldeck.android.protocol.ControlsReadingWire
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.UsageAnswerWire
import dev.terminaldeck.android.protocol.UsageWant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The per-session clusters — the control strip and the bar — where the `rid` bookkeeping is, and
 * therefore where the bugs would be.
 *
 * These run without Android: both controllers are plain Kotlin with a `send` lambda and an injected
 * [Expiry], so the tests drive the socket with a recorder and the timers by hand. What is being
 * pinned is not "does a frame decode" — [dev.terminaldeck.android.protocol.ControlsWireTest] does
 * that — but the four things a request cluster can get wrong in a way that compiles: answering the
 * wrong question, answering about the wrong session, showing a value that was pressed rather than
 * one that was read, and leaving a spinner on forever.
 */
class SessionClusterTest {

    /** A timer store the test fires on demand; a cancelled one never fires. */
    private class FakeExpiry : Expiry {
        private class Timer(val onExpired: () -> Unit, var cancelled: Boolean = false)

        private val timers = mutableListOf<Timer>()

        override fun after(ms: Long, onExpired: () -> Unit): () -> Unit {
            val timer = Timer(onExpired)
            timers.add(timer)
            return { timer.cancelled = true }
        }

        fun fireAll() {
            val live = timers.filter { !it.cancelled }
            timers.clear()
            live.forEach { it.onExpired() }
        }
    }

    private class Recorder {
        val sent = mutableListOf<ClientMessage>()
        var online = true
        val send: (ClientMessage) -> Boolean = { m -> if (online) { sent.add(m); true } else false }

        inline fun <reified T : ClientMessage> only(): List<T> = sent.filterIsInstance<T>()
    }

    private fun reading(
        model: String? = "opus",
        canType: Boolean = true,
        live: Boolean = true,
        agent: Boolean = true,
    ) = ControlsReadingWire(
        model = ControlReadingWire(value = model, label = model),
        live = live,
        agent = ControlAgentWire(running = agent),
        gate = ControlGateWire(canType = canType),
    )

    /* ================================================================ controls == */

    private fun controls(
        rec: Recorder,
        expiry: FakeExpiry,
        caps: () -> Set<String> = { setOf("controls") },
    ) = SessionControlsController(rec.send, caps, expiry, onChange = {})

    @Test
    fun `controls ask nothing and draw nothing over a machine that never offered them`() {
        val rec = Recorder()
        var caps = emptySet<String>()
        val c = controls(rec, FakeExpiry(), caps = { caps })
        c.follow("s1")
        assertTrue(rec.sent.isEmpty())
        assertNull(c.view())

        // …and light up the moment a welcome names it, without being rebuilt.
        caps = setOf("controls")
        c.follow("s1")
        assertEquals(1, rec.only<ClientMessage.ControlsRead>().size)
    }

    @Test
    fun `nothing is drawn until a reading lands, and nothing at all over a plain shell`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        // The capability alone is not a cluster: a strip drawn before the first answer would print
        // four "Unknown" chips over a session nobody has read.
        assertNull(c.view())

        val rid = (rec.sent.single() as ClientMessage.ControlsRead).rid
        c.receive(ServerMessage.ControlsReading(rid, "s1", reading(agent = false)))
        // A model menu over `/bin/zsh` is the defect the desktop's own cluster withdraws itself for.
        assertNull(c.view())
    }

    @Test
    fun `an answer about another session never lands on this chip`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        val rid = (rec.sent.single() as ClientMessage.ControlsRead).rid
        // The rid matches; the session does not. Claimed — it *was* our question — but not drawn.
        assertTrue(c.receive(ServerMessage.ControlsReading(rid, "s2", reading(model = "haiku"))))
        assertNull(c.view())
    }

    @Test
    fun `a stray answer to a question nobody asked is not claimed`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        // An rid from no request of ours: a reconnect that raced a reply, or another cluster's.
        assertFalse(c.receive(ServerMessage.ControlsReading("ctl-999", "s1", reading())))
    }

    @Test
    fun `the ticked row is the far end's re-read, never the value that was pressed`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading(model = "opus")))

        c.apply(ControlName.Model, "haiku")
        assertEquals(ControlName.Model, c.view()!!.busy)

        val applyRid = (rec.only<ClientMessage.ControlsApply>().single()).rid
        // The machine refused, and re-read what the session is *actually* on.
        c.receive(
            ServerMessage.ControlsApplied(
                applyRid, "s1", ok = false, message = "That session is busy.",
                reading = ControlReadingWire(value = "opus", label = "Opus 5"),
            )
        )
        val view = c.view()!!
        assertNull(view.busy)
        // A refused apply reverts by construction, because nothing was ever set from the press.
        assertEquals("opus", view.reading!!.model.value)
        // The machine's own words, verbatim.
        assertEquals("That session is busy.", view.notice!!.text)
        assertFalse(view.notice!!.ok)
    }

    @Test
    fun `an apply nobody answered says the one thing that does not guess`() {
        val rec = Recorder()
        val expiry = FakeExpiry()
        val c = controls(rec, expiry)
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        c.apply(ControlName.Model, "haiku")
        expiry.fireAll()

        val view = c.view()!!
        assertNull(view.busy)
        // It does not say "failed": the command is typed before anything comes back, so claiming
        // failure would send someone pressing again at a session that already moved.
        assertEquals(SessionControlsController.NO_ANSWER, view.notice!!.text)
        // And it asks again rather than assuming, because a fresh reading is the only honest
        // tiebreak.
        assertTrue(rec.only<ClientMessage.ControlsRead>().size >= 2)
    }

    @Test
    fun `a press while the socket is down says nothing was sent`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        rec.online = false
        c.apply(ControlName.Model, "haiku")
        val view = c.view()!!
        // Nothing is in flight, because nothing left.
        assertNull(view.busy)
        assertEquals(SessionControlsController.NOT_CONNECTED, view.notice!!.text)
    }

    @Test
    fun `a second press while one is in flight is refused rather than queued`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        c.apply(ControlName.Model, "haiku")
        c.apply(ControlName.Effort, "low")
        // Two commands typed at one pty in the same breath is how a session ends up at neither of
        // the two things that were asked for.
        assertEquals(1, rec.only<ClientMessage.ControlsApply>().size)
    }

    @Test
    fun `opening another session drops everything held about the last one`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading(model = "opus")))
        assertNotNull(c.view())

        c.follow("s2")
        // A chip carrying the last session's model is worse than no chip: it is the one surface that
        // would disagree with the machine about which session is on screen.
        assertNull(c.view())
    }

    @Test
    fun `a dropped socket clears the reading and keeps the session`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        c.dropped()
        // A reading is a claim about now and nothing over a dead channel will correct it.
        assertNull(c.view())

        rec.sent.clear()
        // The screen showing that session has not closed, so a reconnect re-reads it.
        c.noteOutput()
        FakeExpiry()
        c.follow("s1")
        assertEquals("s1", (rec.only<ClientMessage.ControlsRead>().first()).id)
    }

    @Test
    fun `a bounded value is what reaches the wire`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())
        c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        c.apply(ControlName.Model, "m".repeat(400))
        val sent = rec.only<ClientMessage.ControlsApply>().single()
        // The desktop refuses an over-long value by closing the socket, so a phone that sent one
        // would spend the connection rather than get a sentence back.
        assertEquals(dev.terminaldeck.android.protocol.Protocol.MAX_CONTROL_VALUE_LENGTH, sent.value.length)
    }

    private fun rid(rec: Recorder, at: Int): String =
        (rec.only<ClientMessage.ControlsRead>()[at]).rid

    /* ===================================================================== bar == */

    private fun bar(
        rec: Recorder,
        expiry: FakeExpiry,
        caps: () -> Set<String> = { setOf("usage", "account", "chat", "send") },
        clock: () -> Long = { 0L },
    ) = SessionBarController(rec.send, caps, expiry, onChange = {}, now = clock)

    private fun json(raw: String): JsonElement = Json.parseToJsonElement(raw)

    @Test
    fun `the bar asks nothing over a machine that offers none of it`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry(), caps = { emptySet() })
        b.follow("s1")
        assertTrue(rec.sent.isEmpty())
        // Null rather than an empty bar, so an older machine gets a terminal exactly as it was.
        assertNull(b.view())
    }

    @Test
    fun `following a session asks for context, plan and account and nothing else`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        assertEquals(
            listOf(UsageWant.Context, UsageWant.Plan),
            rec.only<ClientMessage.UsageRead>().map { it.want },
        )
        assertEquals(1, rec.only<ClientMessage.AccountRead>().size)
    }

    @Test
    fun `only a refresh forces, and only a refresh spins`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        assertTrue(rec.only<ClientMessage.UsageRead>().none { it.force })
        assertFalse(b.view()!!.busy)

        b.refresh()
        val refresh = rec.only<ClientMessage.UsageRead>().single { it.want == UsageWant.Refresh }
        // It boots a whole agent on the other machine, so it happens because a finger asked.
        assertTrue(refresh.force)
        assertTrue(b.view()!!.busy)
    }

    @Test
    fun `a context answer never lands on the plan ring`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        val planAsk = rec.only<ClientMessage.UsageRead>().single { it.want == UsageWant.Plan }
        // The right rid, the wrong want. Refused, because the three readings are not
        // interchangeable and a context figure on a plan ring is the wrong number drawn full.
        assertFalse(
            b.receive(
                ServerMessage.UsageReading(
                    planAsk.rid, "s1", UsageWant.Context,
                    UsageAnswerWire(json("""{"state":"read","percent":90}""")),
                )
            )
        )
        assertNull(b.view()!!.plan)
    }

    @Test
    fun `the two figures land on their own chips`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        val asks = rec.only<ClientMessage.UsageRead>()
        b.receive(
            ServerMessage.UsageReading(
                asks.first { it.want == UsageWant.Context }.rid, "s1", UsageWant.Context,
                UsageAnswerWire(json("""{"state":"read","percent":40}""")),
            )
        )
        b.receive(
            ServerMessage.UsageReading(
                asks.first { it.want == UsageWant.Plan }.rid, "s1", UsageWant.Plan,
                UsageAnswerWire(json("""{"readings":[{"used":{"state":"reported","fraction":0.6}}]}""")),
            )
        )
        val view = b.view()!!
        assertEquals(0.4, view.context!!, 1e-9)
        assertEquals(0.6, view.plan!!, 1e-9)
    }

    @Test
    fun `the plan clock is stamped only when a frame actually left`() {
        val rec = Recorder()
        var now = 0L
        val b = bar(rec, FakeExpiry(), clock = { now })
        rec.online = false
        b.follow("s1")
        // Nothing left the phone, so nothing may start a minute of silence: stamping on the attempt
        // is what leaves the ring empty for a minute after everything is working again.
        rec.online = true
        now = 10
        b.noteOutput()
        // The debounce timer has not fired yet, so ask through follow instead.
        b.follow("s1")
        assertEquals(1, rec.only<ClientMessage.UsageRead>().count { it.want == UsageWant.Plan })
    }

    @Test
    fun `plan is throttled to once a minute and context is not`() {
        val rec = Recorder()
        var now = 1_000L
        val expiry = FakeExpiry()
        val b = bar(rec, expiry, clock = { now })
        b.follow("s1")
        rec.sent.clear()

        b.noteOutput()
        expiry.fireAll()
        // Context moves whenever the agent writes to its transcript; plan changes on the hour.
        assertEquals(1, rec.only<ClientMessage.UsageRead>().count { it.want == UsageWant.Context })
        assertEquals(0, rec.only<ClientMessage.UsageRead>().count { it.want == UsageWant.Plan })

        now += SessionBarController.PLAN_THROTTLE_MS + 1
        b.noteOutput()
        expiry.fireAll()
        assertEquals(1, rec.only<ClientMessage.UsageRead>().count { it.want == UsageWant.Plan })
    }

    @Test
    fun `a switch is never a rename, it is a re-read`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        b.receive(
            ServerMessage.AccountState(
                rec.only<ClientMessage.AccountRead>().single().rid, "s1",
                current = AccountWire("a1", "Work", provider = "claude"),
                accounts = listOf(
                    AccountWire("a1", "Work", provider = "claude"),
                    AccountWire("a2", "Home", provider = "claude"),
                ),
            )
        )
        assertEquals("Work", b.view()!!.account!!.name)
        assertTrue(b.view()!!.canSwitchAccount)

        rec.sent.clear()
        b.switchAccount("a2")
        assertTrue(b.view()!!.busy)
        val switch = rec.only<ClientMessage.AccountSwitch>().single()
        b.receive(ServerMessage.AccountSwitched(switch.rid, "s1", ok = true, message = "Switched."))
        // The chip has not renamed itself; a fresh read is on the wire, because the far end decides
        // whether the switch took and a chip that renamed on the press would be the one surface
        // that disagrees with the machine.
        assertEquals("Work", b.view()!!.account!!.name)
        assertFalse(b.view()!!.busy)
        assertEquals(1, rec.only<ClientMessage.AccountRead>().size)
    }

    @Test
    fun `an over-long account id is bounded before it is spent`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())
        b.follow("s1")
        b.switchAccount("a".repeat(500))
        assertEquals(
            Protocol.MAX_ACCOUNT_ID_LENGTH,
            rec.only<ClientMessage.AccountSwitch>().single().accountId.length,
        )
    }

    /* ============================================================== the claim == */

    /**
     * The screen that follows a session hands its claim back, and a **stale** claim tears nothing
     * down.
     *
     * The bug this pins is not reachable from a unit test of one controller — it is an *ordering*
     * bug in Compose, where an incoming screen's effects run before the outgoing screen's
     * `onDispose`. Driven against a live host on 2026-08-22, opening the conversation over a
     * terminal disposed the terminal, the terminal's teardown then cleared the session the
     * conversation had already claimed, and the chat route popped itself back three times a second.
     * The button looked dead.
     *
     * What is testable, and what fixes it, is that `release` is keyed on the claim rather than on
     * nothing. These four assertions are the whole contract.
     */
    @Test
    fun `a stale claim releases nothing, so a screen cannot clear its successor's session`() {
        val rec = Recorder()
        val c = controls(rec, FakeExpiry())

        val first = c.follow("s1")
        c.receive(ServerMessage.ControlsReading(rid(rec, 0), "s1", reading()))
        assertNotNull(c.view())

        // The conversation opens over it and claims the same session.
        val second = c.follow("s1")
        assertTrue("each follow is a new claim", second != first)

        // *Then* the terminal underneath is disposed and hands back the claim it was given.
        c.release(first)
        assertNotNull("the session the conversation is showing survives", c.view())

        // And the screen that actually holds it can still let go.
        c.release(second)
        assertNull(c.view())
    }

    @Test
    fun `the bar keeps the same rule, because the two clusters are released together`() {
        val rec = Recorder()
        val b = bar(rec, FakeExpiry())

        val first = b.follow("s1")
        assertTrue(b.isFollowing)
        val second = b.follow("s1")

        b.release(first)
        // `isFollowing` is what picks *which machine's* bar a verb acts on; a stale release that
        // cleared it would send the next `chat.read` to whichever machine happens to be first in the
        // map — which on a phone with five paired is one that has been offline for a week.
        assertTrue(b.isFollowing)

        b.release(second)
        assertFalse(b.isFollowing)
    }
}
