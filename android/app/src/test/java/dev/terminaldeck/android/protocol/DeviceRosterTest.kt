package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The device screen's three sentences, mirrored from `pwa/src/devices.ts`. */
class DeviceRosterTest {

    private fun row(
        kind: String = "mine",
        status: String = "approved",
        lastSeenAt: Long? = null,
        connected: Boolean = false,
        fingerprint: String? = "ab cd ef gh ij kl",
    ) = DeviceRosterRow(
        id = "d1",
        name = "Pixel",
        kind = kind,
        status = status,
        addedAt = 0,
        lastSeenAt = lastSeenAt,
        connected = connected,
        fingerprint = fingerprint,
    )

    @Test
    fun `standing leads with the wait for a pending row and names the kind for an approved one`() {
        assertEquals("Waiting to be approved", DeviceRoster.standing(row(status = "pending")))
        assertEquals("Your device", DeviceRoster.standing(row(kind = "mine")))
        assertEquals("Guest", DeviceRoster.standing(row(kind = "guest")))
    }

    @Test
    fun `last seen prefers connected-now, then a relative time, then never`() {
        val now = 1_000_000_000L
        assertEquals("Connected now", DeviceRoster.lastSeen(row(connected = true), now))
        assertEquals("Never connected", DeviceRoster.lastSeen(row(lastSeenAt = null), now))
        assertEquals("Seen moments ago", DeviceRoster.lastSeen(row(lastSeenAt = now - 30_000), now))
        assertEquals("Seen 5m ago", DeviceRoster.lastSeen(row(lastSeenAt = now - 5 * 60_000), now))
        assertEquals("Seen 3h ago", DeviceRoster.lastSeen(row(lastSeenAt = now - 3 * 3_600_000), now))
        assertEquals("Seen yesterday", DeviceRoster.lastSeen(row(lastSeenAt = now - 25 * 3_600_000), now))
        assertEquals("Seen 3d ago", DeviceRoster.lastSeen(row(lastSeenAt = now - 3 * 24 * 3_600_000L), now))
        // A clock that ran backwards is not negative time.
        assertEquals("Seen moments ago", DeviceRoster.lastSeen(row(lastSeenAt = now + 5000), now))
    }

    @Test
    fun `the fingerprint falls back to a sentence rather than a blank`() {
        assertEquals("ab cd ef gh ij kl", DeviceRoster.fingerprint(row()))
        assertTrue(DeviceRoster.fingerprint(row(fingerprint = null)).startsWith("No key"))
    }

    @Test
    fun `offered reads the capability`() {
        assertTrue(DeviceRoster.offered(setOf("devices")))
        assertTrue(!DeviceRoster.offered(setOf("create")))
    }
}
