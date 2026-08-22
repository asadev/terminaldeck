package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceRosterRow
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.ServerSettingWire
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `rid`-correlated request clusters — the device roster and the two server settings — where the
 * bookkeeping is, and therefore where the bugs would be.
 *
 * These run without Android: the controllers are plain Kotlin with a [send] lambda and an injected
 * [Expiry], so the tests drive the socket with a recorder and the timers by hand.
 */
class RequestControllerTest {

    /** A timer store the test fires on demand; a cancelled one never fires. */
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

    /* ------------------------------------------------------- server settings -- */

    @Test
    fun `settings draws nothing and asks nothing until the machine advertises the capability`() {
        val rec = Recorder()
        var caps = emptySet<String>()
        val c = ServerSettingsController(rec.send, { caps }, FakeExpiry(), onChange = {})
        c.ensureRead()
        assertNull(c.view())
        assertTrue(rec.sent.isEmpty())

        caps = setOf("settings")
        c.ensureRead()
        assertTrue(c.view() != null)
        assertEquals(1, rec.sent.size)
        assertTrue(rec.sent[0] is ClientMessage.SettingsRead)
    }

    @Test
    fun `settings reads once per connection and the state answer populates the rows`() {
        val rec = Recorder()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        c.ensureRead() // idempotent — still one read
        assertEquals(1, rec.sent.size)
        val rid = (rec.sent[0] as ClientMessage.SettingsRead).rid

        assertNull(c.view()!!.rows) // "reading…" until the answer
        val handled = c.receive(
            ServerMessage.SettingsState(rid, listOf(ServerSettingWire("general.restoreSessions", "false")))
        )
        assertTrue(handled)
        assertEquals(1, c.view()!!.rows!!.size)
    }

    @Test
    fun `a state answer with the wrong rid is not this cluster's`() {
        val rec = Recorder()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        assertFalse(c.receive(ServerMessage.SettingsState("not-mine", emptyList())))
    }

    @Test
    fun `an apply locks the control, and the applied answer settles on the machine's own re-read`() {
        val rec = Recorder()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        val readRid = (rec.sent[0] as ClientMessage.SettingsRead).rid
        c.receive(ServerMessage.SettingsState(readRid, listOf(ServerSettingWire("general.restoreSessions", "false"))))

        c.apply(ServerSettingKey.RestoreSessions, "true")
        assertEquals(ServerSettingKey.RestoreSessions, c.view()!!.busy)
        val applyRid = (rec.sent.last() as ClientMessage.SettingsApply).rid

        // A second apply while one is in flight is refused — two writes never race into one store.
        c.apply(ServerSettingKey.DefaultProvider, "codex")
        assertEquals(1, rec.sent.count { it is ClientMessage.SettingsApply })

        // The machine refuses: the row settles on the machine's value, not the pressed one.
        c.receive(
            ServerMessage.SettingsApplied(
                applyRid, ok = false, message = "No.",
                setting = ServerSettingWire("general.restoreSessions", "false"),
            )
        )
        assertNull(c.view()!!.busy)
        assertEquals("false", c.view()!!.rows!!.first { it.known == ServerSettingKey.RestoreSessions }.value)
        assertEquals(false, c.view()!!.notice!!.ok)
    }

    @Test
    fun `an apply nobody answered times out into a fresh read`() {
        val rec = Recorder()
        val expiry = FakeExpiry()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, expiry, onChange = {})
        c.ensureRead()
        c.receive(ServerMessage.SettingsState((rec.sent[0] as ClientMessage.SettingsRead).rid, emptyList()))
        c.apply(ServerSettingKey.RestoreSessions, "true")
        val appliesBefore = rec.sent.count { it is ClientMessage.SettingsApply }
        val readsBefore = rec.sent.count { it is ClientMessage.SettingsRead }

        expiry.fireAll() // the apply timeout fires

        assertNull(c.view()!!.busy)
        assertEquals(false, c.view()!!.notice!!.ok)
        // It re-reads to settle on the machine's truth.
        assertTrue(rec.sent.count { it is ClientMessage.SettingsRead } > readsBefore)
        assertEquals(appliesBefore, rec.sent.count { it is ClientMessage.SettingsApply })
    }

    @Test
    fun `settings changed is absorbed unsolicited`() {
        val rec = Recorder()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        c.receive(ServerMessage.SettingsState((rec.sent[0] as ClientMessage.SettingsRead).rid, emptyList()))
        assertTrue(c.receive(ServerMessage.SettingsChanged(listOf(ServerSettingWire("agents.defaultProvider", "gemini")))))
        assertEquals("gemini", c.view()!!.rows!!.first().value)
    }

    @Test
    fun `a welcome renews the settings so the next visit re-reads`() {
        val rec = Recorder()
        val c = ServerSettingsController(rec.send, { setOf("settings") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        c.receive(ServerMessage.SettingsState((rec.sent[0] as ClientMessage.SettingsRead).rid, emptyList()))
        c.renew()
        assertNull(c.view()!!.rows)
        c.ensureRead()
        assertEquals(2, rec.sent.count { it is ClientMessage.SettingsRead })
    }

    /* ------------------------------------------------------------- devices -- */

    private fun device(id: String, kind: String = "mine", status: String = "approved") =
        DeviceRosterRow(id = id, name = id, kind = kind, status = status)

    @Test
    fun `devices asks once and the rows answer populates the roster`() {
        val rec = Recorder()
        val c = DeviceRosterController(rec.send, { setOf("devices") }, FakeExpiry(), onChange = {})
        c.ensureRead()
        c.ensureRead()
        assertEquals(1, rec.sent.count { it is ClientMessage.DevicesList })
        val rid = (rec.sent.first { it is ClientMessage.DevicesList } as ClientMessage.DevicesList).rid
        assertTrue(c.receive(ServerMessage.DevicesRows(rid, listOf(device("d1")))))
        assertEquals(1, c.view()!!.rows!!.size)
    }

    @Test
    fun `a revoke locks that row, and the revoked answer carries the fresh roster`() {
        val rec = Recorder()
        val c = DeviceRosterController(rec.send, { setOf("devices") }, FakeExpiry(), onChange = {})
        c.onWelcome("me")
        c.ensureRead()
        c.receive(ServerMessage.DevicesRows((rec.sent[0] as ClientMessage.DevicesList).rid, listOf(device("d1"), device("d2"))))

        c.revoke("d1")
        assertEquals("d1", c.view()!!.busy)
        val revokeRid = (rec.sent.last() as ClientMessage.DevicesRevoke).rid

        // A second revoke while one is in flight is refused.
        c.revoke("d2")
        assertEquals(1, rec.sent.count { it is ClientMessage.DevicesRevoke })

        c.receive(ServerMessage.DevicesRevoked(revokeRid, ok = true, message = "Removed.", devices = listOf(device("d2"))))
        assertNull(c.view()!!.busy)
        assertEquals(1, c.view()!!.rows!!.size)
        assertEquals("d2", c.view()!!.rows!!.first().id)
        assertEquals(true, c.view()!!.notice!!.ok)
    }

    @Test
    fun `devices changed is absorbed unsolicited, and myDeviceId rides through`() {
        val rec = Recorder()
        val c = DeviceRosterController(rec.send, { setOf("devices") }, FakeExpiry(), onChange = {})
        c.onWelcome("me")
        assertEquals("me", c.view()!!.myDeviceId)
        assertTrue(c.receive(ServerMessage.DevicesChanged(listOf(device("d1"), device("d2")))))
        assertEquals(2, c.view()!!.rows!!.size)
    }

    @Test
    fun `a self-revoke that times out says nothing scary because the socket close is the answer`() {
        val rec = Recorder()
        val expiry = FakeExpiry()
        val c = DeviceRosterController(rec.send, { setOf("devices") }, expiry, onChange = {})
        c.onWelcome("me")
        c.ensureRead()
        c.receive(ServerMessage.DevicesRows((rec.sent[0] as ClientMessage.DevicesList).rid, listOf(device("me"))))
        c.revoke("me")
        expiry.fireAll()
        // No notice for a self-revoke timeout — the socket dropping is the confirmation.
        assertNull(c.view()!!.notice)
    }
}
