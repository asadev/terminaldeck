package dev.terminaldeck.android.github

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.GitHubHostWire
import dev.terminaldeck.android.protocol.GitHubPendingWire
import dev.terminaldeck.android.protocol.ServerMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `github.*` controller — the phone half of the flip, where the `rid` bookkeeping is and
 * therefore where the bugs would be.
 *
 * It is plain Kotlin behind a [send] lambda and an injected [Expiry], so this drives the socket with
 * a recorder and the timers by hand, the way [dev.terminaldeck.android.RequestControllerTest] does
 * for the settings and roster clusters it is modelled on.
 */
class ConnectGitHubControllerTest {

    private class FakeExpiry : Expiry {
        private class Timer(val onExpired: () -> Unit, var cancelled: Boolean = false)
        private val timers = mutableListOf<Timer>()
        override fun after(ms: Long, onExpired: () -> Unit): () -> Unit {
            val t = Timer(onExpired)
            timers.add(t)
            return { t.cancelled = true }
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
    }

    private fun controller(
        rec: Recorder,
        caps: () -> Set<String> = { setOf("github") },
        expiry: Expiry = FakeExpiry(),
    ) = ConnectGitHubController(rec.send, caps, expiry, onChange = {})

    @Test
    fun `draws nothing and asks nothing until the machine advertises github`() {
        val rec = Recorder()
        var caps = emptySet<String>()
        val c = controller(rec, caps = { caps })
        c.ensureRead()
        assertNull(c.view())
        assertTrue(rec.sent.isEmpty())

        caps = setOf("github")
        c.ensureRead()
        assertTrue(c.view() != null)
        assertEquals(1, rec.sent.size)
        assertTrue(rec.sent[0] is ClientMessage.GithubRead)
    }

    @Test
    fun `reads once per connection and the state answer populates the status`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        c.ensureRead() // idempotent — still one read
        assertEquals(1, rec.sent.size)
        val rid = (rec.sent[0] as ClientMessage.GithubRead).rid

        assertNull("null host means reading…", c.view()!!.host)
        val handled = c.receive(ServerMessage.GithubState(rid, GitHubHostWire(connected = true, login = "octocat")))
        assertTrue(handled)
        assertEquals("octocat", c.view()!!.host?.login)
        assertTrue(c.view()!!.host?.connected == true)
    }

    @Test
    fun `a state answer for a rid nobody asked is not claimed`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        assertFalse(c.receive(ServerMessage.GithubState("someone-elses-rid", GitHubHostWire())))
    }

    @Test
    fun `connect sends the frame and the pending state carries the code`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        rec.sent.clear()

        c.connect()
        assertEquals(1, rec.sent.size)
        val connect = rec.sent[0] as ClientMessage.GithubConnect
        assertTrue("connect locks the buttons while it is in flight", c.view()!!.busy)

        c.receive(
            ServerMessage.GithubState(
                connect.rid,
                GitHubHostWire(pending = GitHubPendingWire(userCode = "ABCD-1234", verificationUri = "https://github.com/login/device")),
            ),
        )
        assertFalse("the code is shown, so the buttons are live again", c.view()!!.busy)
        assertEquals("ABCD-1234", c.view()!!.host?.pending?.userCode)
    }

    @Test
    fun `the unsolicited changed push turns a pending sign-in into a connected account`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        val rid = (rec.sent[0] as ClientMessage.GithubRead).rid
        c.receive(ServerMessage.GithubState(rid, GitHubHostWire(pending = GitHubPendingWire(userCode = "ABCD-1234"))))

        // No rid — it is always claimed and always the newest truth.
        val handled = c.receive(ServerMessage.GithubChanged(GitHubHostWire(connected = true, login = "octocat")))
        assertTrue(handled)
        assertNull("the pending code is gone", c.view()!!.host?.pending)
        assertEquals("octocat", c.view()!!.host?.login)
    }

    @Test
    fun `disconnect sends the frame`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        rec.sent.clear()
        c.disconnect()
        assertEquals(1, rec.sent.size)
        assertTrue(rec.sent[0] is ClientMessage.GithubDisconnect)
    }

    @Test
    fun `cancel sends the frame`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        rec.sent.clear()
        c.cancel()
        assertEquals(1, rec.sent.size)
        assertTrue(rec.sent[0] is ClientMessage.GithubCancel)
    }

    @Test
    fun `a connect nobody answered times out into a local failure rather than a hung spinner`() {
        val rec = Recorder()
        val expiry = FakeExpiry()
        val c = controller(rec, expiry = expiry)
        c.ensureRead()
        c.connect()
        assertTrue(c.view()!!.busy)

        expiry.fireAll()
        assertFalse(c.view()!!.busy)
        assertTrue(c.view()!!.localFailure != null)
    }

    @Test
    fun `renew forgets the last machine and re-reads on the next ensureRead`() {
        val rec = Recorder()
        val c = controller(rec)
        c.ensureRead()
        val rid = (rec.sent[0] as ClientMessage.GithubRead).rid
        c.receive(ServerMessage.GithubState(rid, GitHubHostWire(connected = true, login = "octocat")))
        assertEquals("octocat", c.view()!!.host?.login)

        c.renew()
        assertNull("a welcome drops the last machine's status", c.view()!!.host)
        rec.sent.clear()
        c.ensureRead()
        assertEquals(1, rec.sent.size)
        assertTrue(rec.sent[0] is ClientMessage.GithubRead)
    }
}
