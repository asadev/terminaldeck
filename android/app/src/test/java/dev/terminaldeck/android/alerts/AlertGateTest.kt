package dev.terminaldeck.android.alerts

import dev.terminaldeck.android.protocol.RemoteSessionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whether a thing worth telling him about is worth a banner *right now*.
 *
 * [SessionAlerts] answers "did something happen"; this answers "is he already looking at it", and
 * the two together are the whole rule he asked for:
 *
 * > *"They should be only when the AI is working, I am outside of the application, and now there is
 * > something to answer … Instead, for every single move it is giving a notification."*
 *
 * Every case here is a way this could interrupt him at the wrong moment — the fastest way to get an
 * app's notifications switched off, which loses the one that mattered. The clock is moved by hand so
 * the five-second grace can be proved at four seconds and at six without either being real time
 * spent by everyone who ever runs this suite.
 */
class AlertGateTest {

    /** A clock the test advances itself. */
    private class Clock(var nowMs: Long = 1_700_000_000_000L) {
        fun advance(ms: Long) {
            nowMs += ms
        }
    }

    private val host = "mac"

    private fun alert(sessionId: String, kind: SessionAlert.Kind = SessionAlert.Kind.NeedsYou) =
        SessionAlert(hostId = host, hostName = "Mac", sessionId = sessionId, sessionTitle = "app", kind = kind)

    private fun session(id: String, status: String) =
        RemoteSessionView(id = id, title = "app", cwd = "/w/app", provider = "claude", status = status, exitCode = null)

    // ---- foreground, on the session he is reading -------------------------------------------------

    @Test
    fun `a session on screen is not worth a banner over the terminal he is reading`() {
        // The exact complaint: "even when I am inside the application, on the same page, it is
        // throwing notifications."
        val gate = AlertGate()
        gate.watching(host, "a")

        assertTrue(gate.isBeingWatched(alert("a")))
    }

    @Test
    fun `a different session is also silent while the app is open`() {
        // He overruled the old behaviour here: open on machine A's session while B stops and asks,
        // and B used to banner. He does not want that — *"only when I am outside of the application"*
        // — so while the app is foreground, every session is silent, and B's news is on the in-app
        // Alerts list and its row dot, not a banner over what he is reading.
        val gate = AlertGate()
        gate.watching(host, "a")

        assertTrue(gate.isBeingWatched(alert("b")))
    }

    @Test
    fun `a session nobody has looked at is still silent while the app is open`() {
        // Foreground with nothing open — the Sessions list, or Settings. A session that changes is
        // still not a banner while he is inside the app; it is a row that lights up on the list.
        val gate = AlertGate()
        assertTrue(gate.isBeingWatched(alert("a")))
    }

    // ---- away: the phone in a pocket, which is the whole point -----------------------------------

    @Test
    fun `nothing is watched once the app is in the background`() {
        // Away is the situation the feature exists for. Even the session that was on screen a moment
        // ago must be able to buzz him now — he put the phone down on it.
        val gate = AlertGate()
        gate.watching(host, "a")
        gate.leftForeground()

        assertFalse(gate.isBeingWatched(alert("a")))
    }

    @Test
    fun `coming back to the foreground quiets the watched session again`() {
        val gate = AlertGate()
        gate.watching(host, "a")
        gate.leftForeground()
        gate.enteredForeground()

        assertTrue(gate.isBeingWatched(alert("a")))
    }

    // ---- going in and straight back out ----------------------------------------------------------

    @Test
    fun `a session just left stays quiet while its settle verdict catches up`() {
        // "see, I go inside I come back it's throwing a new notification." Opening it made the
        // desktop reclassify it a beat later; that beat lands after he is back on the list.
        val clock = Clock()
        val gate = AlertGate { clock.nowMs }
        gate.watching(host, "a")
        gate.stoppedWatching(host, "a")

        clock.advance(1_000)
        assertTrue("the verdict is the tail of what he just closed", gate.isBeingWatched(alert("a")))
    }

    @Test
    fun `the same session is news only once the app is in the background`() {
        // With the rule now "silent while foreground", the grace no longer decides anything while he
        // is inside the app — a beat later, or a minute later, it stays silent. It becomes news the
        // moment he leaves: that is the one time he asked to hear.
        val clock = Clock()
        val gate = AlertGate { clock.nowMs }
        gate.watching(host, "a")
        gate.stoppedWatching(host, "a")

        clock.advance(AlertGate.WATCHED_GRACE_MS + 1_000)
        assertTrue("still inside the app, so still silent", gate.isBeingWatched(alert("a")))
        gate.leftForeground()
        assertFalse("away now, so it may buzz", gate.isBeingWatched(alert("a")))
    }

    @Test
    fun `re-entering a session measures the grace from the second time it was left`() {
        // The mark is cleared on the way in, so going in and out twice does not find the first
        // departure stale and post about the second.
        val clock = Clock()
        val gate = AlertGate { clock.nowMs }

        gate.watching(host, "a")
        gate.stoppedWatching(host, "a")
        clock.advance(AlertGate.WATCHED_GRACE_MS + 1_000) // the first departure is now ancient

        gate.watching(host, "a")
        gate.stoppedWatching(host, "a")
        clock.advance(1_000)

        assertTrue("measured from the second departure, one second ago", gate.isBeingWatched(alert("a")))
    }

    @Test
    fun `switching from one session to another does not clear the arriving one`() {
        // Compose runs the incoming screen's effect before the outgoing screen's dispose: B.watching
        // fires before A.stoppedWatching. If stoppedWatching cleared "open" unconditionally it would
        // wipe the mark B just set, and a banner about B would draw over B.
        val gate = AlertGate()
        gate.watching(host, "a") // A on screen
        gate.watching(host, "b") // B arrives on top
        gate.stoppedWatching(host, "a") // A finally disposes

        assertTrue("B is still the session on screen", gate.isBeingWatched(alert("b")))
    }

    // ---- the two ends of the rule, run through the real detector ---------------------------------

    @Test
    fun `background plus a session that stops and asks is a banner`() {
        // The one they install the app for: away, and a session went working -> waiting.
        val detector = SessionAlerts()
        val gate = AlertGate().apply { leftForeground() }
        detector.observe(host, "Mac", listOf(session("a", "working")))
        val raised = detector.observe(host, "Mac", listOf(session("a", "waiting")))

        assertEquals(1, raised.size)
        assertFalse(gate.isBeingWatched(raised.single()))
    }

    @Test
    fun `background plus a finished session is a banner`() {
        val detector = SessionAlerts()
        val gate = AlertGate().apply { leftForeground() }
        detector.observe(host, "Mac", listOf(session("a", "working")))
        val raised = detector.observe(host, "Mac", listOf(session("a", "completed")))

        assertEquals(SessionAlert.Kind.Finished, raised.single().kind)
        assertFalse(gate.isBeingWatched(raised.single()))
    }

    @Test
    fun `foreground on that session plus waiting is silence`() {
        val detector = SessionAlerts()
        val gate = AlertGate() // foreground by default
        gate.watching(host, "a")
        detector.observe(host, "Mac", listOf(session("a", "working")))
        val raised = detector.observe(host, "Mac", listOf(session("a", "waiting")))

        assertEquals(1, raised.size)
        assertTrue("he is looking at it", gate.isBeingWatched(raised.single()))
    }

    @Test
    fun `starting a session and ordinary running output are not alerts at all`() {
        // Neither reaches the gate: the detector seeds silently and says nothing for working, so
        // "for every single move" produces nothing to suppress in the first place.
        val detector = SessionAlerts()
        val seeded = detector.observe(host, "Mac", listOf(session("a", "working")))
        val stillWorking = detector.observe(host, "Mac", listOf(session("a", "working")))

        assertEquals(emptyList<SessionAlert>(), seeded)
        assertEquals(emptyList<SessionAlert>(), stillWorking)
    }

    @Test
    fun `the same waiting status arriving twice is one alert, not a stream`() {
        val detector = SessionAlerts()
        detector.observe(host, "Mac", listOf(session("a", "working")))
        val first = detector.observe(host, "Mac", listOf(session("a", "waiting")))
        val second = detector.observe(host, "Mac", listOf(session("a", "waiting")))

        assertEquals(1, first.size)
        assertEquals("nothing changed, so nothing is news", emptyList<SessionAlert>(), second)
    }
}
