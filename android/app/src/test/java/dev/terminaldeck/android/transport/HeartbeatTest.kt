package dev.terminaldeck.android.transport

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One timer, every socket.
 *
 * Rule 7.10, and on a phone it is battery rather than tidiness. Every paired machine holds a socket
 * and every socket needs the keepalive, so unsynchronised timers would be N chances per cycle to
 * wake the radio for traffic that could have shared one window — and the radio, not the CPU, is what
 * a wake-up costs.
 *
 * The interval here is milliseconds rather than the real 25 seconds because the clock is virtual:
 * what is being checked is the shape of the loop, not the number, and the number is pinned by the
 * constants these tests deliberately do not use.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class HeartbeatTest {

    /** A socket, as the tick sees one. Records when it was pinged, in virtual milliseconds. */
    private class Socket(
        private val now: () -> Long,
        private val alive: () -> Boolean = { true },
    ) : Heartbeat.Member {
        val pings = mutableListOf<Long>()
        val pongsDue = mutableListOf<Long>()

        override fun ping(): Boolean {
            pings += now()
            return alive()
        }

        override fun pongDue() {
            pongsDue += now()
        }
    }

    @Test
    fun `three members are three sockets on one loop`() = runTest {
        val beat = Heartbeat(scope = backgroundScope, intervalMs = 1_000, graceMs = 400)
        val now = { testScheduler.currentTime }
        val a = Socket(now)
        val b = Socket(now)
        val c = Socket(now)

        assertFalse("nothing has joined yet", beat.isTicking)

        beat.join("a", a)
        beat.join("b", b)
        beat.join("c", c)
        runCurrent()

        assertEquals(3, beat.memberCount)
        assertTrue(beat.isTicking)
        assertTrue("joining must not beat", a.pings.isEmpty())

        // One cycle: the send phase at 600ms, the grace expiring at 1000ms.
        advanceTimeBy(1_001)
        runCurrent()

        // Every socket pinged, in the same turn of the same loop — which is the whole point, and is
        // exactly what three independent timers would not do.
        assertEquals(listOf(600L), a.pings)
        assertEquals(listOf(600L), b.pings)
        assertEquals(listOf(600L), c.pings)
        assertEquals(listOf(1_000L), a.pongsDue)
        assertEquals(listOf(1_000L), c.pongsDue)

        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf(600L, 1_600L), a.pings)
        assertEquals(listOf(600L, 1_600L), c.pings)
    }

    /**
     * A timer with nothing to do is pure cost, and on a phone it is cost that shows up in a battery
     * screen with this app's name against it.
     */
    @Test
    fun `the loop stops when the last member leaves and starts again with the next`() = runTest {
        val beat = Heartbeat(scope = backgroundScope, intervalMs = 1_000, graceMs = 400)
        val now = { testScheduler.currentTime }
        beat.join("a", Socket(now))
        beat.join("b", Socket(now))
        runCurrent()
        assertTrue(beat.isTicking)

        beat.leave("a")
        runCurrent()
        assertTrue("one machine left is still a machine to keep alive", beat.isTicking)
        assertEquals(1, beat.memberCount)

        beat.leave("b")
        runCurrent()
        assertFalse(beat.isTicking)
        assertEquals(0, beat.memberCount)

        beat.join("c", Socket(now))
        runCurrent()
        assertTrue("pairing another machine has to bring the tick back", beat.isTicking)
    }

    /**
     * Keyed by the owner, so a transport that reconnects replaces its own entry.
     *
     * Keying by the member instead would have every socket pinged as many times per tick as it had
     * ever been opened — worst on exactly the connection that is already struggling.
     */
    @Test
    fun `rejoining replaces rather than accumulates`() = runTest {
        val beat = Heartbeat(scope = backgroundScope, intervalMs = 1_000, graceMs = 400)
        val now = { testScheduler.currentTime }
        val owner = Any()
        val first = Socket(now)
        val second = Socket(now)

        beat.join(owner, first)
        beat.join(owner, second)
        runCurrent()
        assertEquals(1, beat.memberCount)

        advanceTimeBy(1_001)
        runCurrent()
        assertTrue("the socket that was replaced must not still be pinged", first.pings.isEmpty())
        assertEquals(1, second.pings.size)
    }

    /**
     * A member that says its socket has gone is dropped, and does not get asked about a pong it
     * could not have been sent.
     */
    @Test
    fun `a socket that cannot be written to is dropped by the tick`() = runTest {
        val beat = Heartbeat(scope = backgroundScope, intervalMs = 1_000, graceMs = 400)
        val now = { testScheduler.currentTime }
        val alive = Socket(now)
        val dead = Socket(now, alive = { false })

        beat.join("alive", alive)
        beat.join("dead", dead)
        runCurrent()

        advanceTimeBy(1_001)
        runCurrent()

        assertEquals(1, beat.memberCount)
        assertTrue("a socket that could not be written to is owed no grace", dead.pongsDue.isEmpty())
        assertEquals(1, alive.pongsDue.size)
    }

    /**
     * A resume realigns rather than leaving the tick where it was, so the first beat afterwards is a
     * full interval away instead of every machine being pinged at once on top of the reconnects that
     * are already in flight.
     */
    @Test
    fun `realigning restarts the phase without dropping anyone`() = runTest {
        val beat = Heartbeat(scope = backgroundScope, intervalMs = 1_000, graceMs = 400)
        val now = { testScheduler.currentTime }
        val socket = Socket(now)
        beat.join("a", socket)
        runCurrent()

        advanceTimeBy(500)
        runCurrent()
        assertTrue(socket.pings.isEmpty())

        beat.realign()
        runCurrent()
        assertEquals(1, beat.memberCount)
        assertTrue(beat.isTicking)

        // 100ms short of where the old phase would have fired.
        advanceTimeBy(100)
        runCurrent()
        assertTrue("the old phase must not survive a realign", socket.pings.isEmpty())

        advanceTimeBy(501)
        runCurrent()
        assertEquals(listOf(1_100L), socket.pings)
    }
}
