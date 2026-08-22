package dev.terminaldeck.android.alerts

import dev.terminaldeck.android.protocol.RemoteSessionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What is worth interrupting somebody for, and what is not.
 *
 * Every rule here is one somebody would otherwise have to discover by being buzzed at the wrong
 * moment, which is a bug that gets an app's notifications switched off entirely — and that loses the
 * one alert that mattered.
 */
class SessionAlertsTest {

    private fun session(id: String, status: String, exit: Int? = null) = RemoteSessionView(
        id = id,
        title = "app",
        cwd = "/w/app",
        provider = "claude",
        status = status,
        exitCode = exit,
    )

    @Test
    fun `the first list from a machine announces nothing at all`() {
        val alerts = SessionAlerts()
        // A session that was already waiting before this phone ever heard of it did not just start
        // waiting. Seeding silently is what stops a reconnect telling somebody three times about
        // something that happened while they were asleep.
        val raised = alerts.observe("mac", "Mac", listOf(session("s1", "waiting"), session("s2", "working")))
        assertEquals(emptyList<SessionAlert>(), raised)
        assertEquals("waiting", alerts.lastKnownStatus("mac", "s1"))
    }

    @Test
    fun `a session that stops and asks is the alert people install the app for`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        val raised = alerts.observe("mac", "Mac", listOf(session("s1", "waiting")))

        assertEquals(1, raised.size)
        assertEquals(SessionAlert.Kind.NeedsYou, raised[0].kind)
        // Named machine and all: a phone paired with three computers cannot say "waiting for you"
        // and leave somebody guessing which one they have to walk over to.
        assertEquals("Waiting for you on Mac.", raised[0].body)
        assertEquals("app", raised[0].title)
    }

    @Test
    fun `input is the same news as waiting, because it is the same event`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        assertEquals(SessionAlert.Kind.NeedsYou, alerts.observe("mac", "Mac", listOf(session("s1", "input"))).single().kind)
    }

    @Test
    fun `moving between two ways of asking is not a second alert`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "waiting")))
        assertEquals(emptyList<SessionAlert>(), alerts.observe("mac", "Mac", listOf(session("s1", "input"))))
    }

    @Test
    fun `a session starting work is not news`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "idle")))
        // Being buzzed because the app did what it was told is how people turn notifications off.
        assertEquals(emptyList<SessionAlert>(), alerts.observe("mac", "Mac", listOf(session("s1", "working"))))
    }

    @Test
    fun `finishing arrives quietly, and an exit code is carried into the sentence`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working"), session("s2", "working")))
        val raised = alerts.observe(
            "mac", "Mac",
            listOf(session("s1", "completed"), session("s2", "exited", exit = 1)),
        )
        assertEquals(2, raised.size)
        assertTrue(raised.all { it.kind == SessionAlert.Kind.Finished })
        assertEquals("Finished on Mac.", raised[0].body)
        assertEquals("Stopped on Mac — exit 1.", raised[1].body)
    }

    @Test
    fun `a clean exit is ended rather than stopped`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        val raised = alerts.observe("mac", "Mac", listOf(session("s1", "exited", exit = 0))).single()
        assertEquals("Ended on Mac.", raised.body)
    }

    @Test
    fun `completed then exited is one thing ending twice, so it is announced once`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        assertEquals(1, alerts.observe("mac", "Mac", listOf(session("s1", "completed"))).size)
        assertEquals(emptyList<SessionAlert>(), alerts.observe("mac", "Mac", listOf(session("s1", "exited", exit = 0))))
    }

    @Test
    fun `a word this build has never heard produces no alert rather than a guess`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        // The vocabulary belongs to the desktop and a newer one may add to it. Guessing what an
        // unknown status means is how an app invents an event.
        assertEquals(emptyList<SessionAlert>(), alerts.observe("mac", "Mac", listOf(session("s1", "hibernating"))))
    }

    @Test
    fun `a session that was not in the previous list is silent even when it arrives waiting`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        val raised = alerts.observe("mac", "Mac", listOf(session("s1", "working"), session("s2", "waiting")))
        // It is either one this phone just asked for — the person is looking at it — or one somebody
        // started at the desk. "A new session exists" is not a thing to interrupt anybody for.
        assertEquals(emptyList<SessionAlert>(), raised)
        // And it is remembered, so the *next* change to it is news.
        assertEquals("waiting", alerts.lastKnownStatus("mac", "s2"))
    }

    @Test
    fun `two machines with the same session id do not shadow each other`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        alerts.observe("pc", "PC", listOf(session("s1", "working")))

        val raised = alerts.observe("pc", "PC", listOf(session("s1", "waiting"))).single()
        assertEquals("PC", raised.hostName)
        // The Mac's own s1 is untouched — a flat map would have reported one machine's work as the
        // other's.
        assertEquals("working", alerts.lastKnownStatus("mac", "s1"))
    }

    @Test
    fun `a machine that is forgotten seeds again rather than firing everything at once`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        alerts.forget("mac")
        assertNull(alerts.lastKnownStatus("mac", "s1"))
        assertEquals(emptyList<SessionAlert>(), alerts.observe("mac", "Mac", listOf(session("s1", "waiting"))))
    }

    @Test
    fun `a session the machine stopped listing is forgotten rather than reported`() {
        val alerts = SessionAlerts()
        alerts.observe("mac", "Mac", listOf(session("s1", "working"), session("s2", "working")))
        alerts.observe("mac", "Mac", listOf(session("s1", "working")))
        assertNull(alerts.lastKnownStatus("mac", "s2"))
    }

    @Test
    fun `one session is named the same way everywhere it is named`() {
        val alert = SessionAlert("mac", "Mac", "s1", "app", SessionAlert.Kind.NeedsYou)
        assertEquals("mac.s1", alert.thread)
        assertEquals(SessionAlert.thread("mac", "s1"), alert.thread)
    }

    @Test
    fun `a session with no title still has something to put on a lock screen`() {
        val alert = SessionAlert("mac", "Mac", "s1", "", SessionAlert.Kind.Finished)
        assertEquals("Session", alert.title)
    }

    @Test
    fun `the away line counts, and it counts in English`() {
        fun needs(id: String) = SessionAlert("mac", "Mac", id, "app", SessionAlert.Kind.NeedsYou)
        fun done(id: String) = SessionAlert("mac", "Mac", id, "app", SessionAlert.Kind.Finished)

        assertNull(AwayReport.sentence(emptyList()))
        assertEquals("While you were away: 1 session needs you.", AwayReport.sentence(listOf(needs("a"))))
        assertEquals("While you were away: 2 sessions need you.", AwayReport.sentence(listOf(needs("a"), needs("b"))))
        assertEquals("While you were away: 1 finished.", AwayReport.sentence(listOf(done("a"))))
        assertEquals(
            "While you were away: 1 session needs you, 2 finished.",
            AwayReport.sentence(listOf(needs("a"), done("b"), done("c"))),
        )
    }
}
