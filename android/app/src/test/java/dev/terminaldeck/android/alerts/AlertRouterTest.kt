package dev.terminaldeck.android.alerts

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Routing a notification tap back to the session it was raised for — the launch-race behaviour, which
 * is the whole reason the router exists: a tap delivered during a cold start arrives before the
 * composition has wired the opener, and it must not be lost.
 */
class AlertRouterTest {

    @After
    fun tearDown() = AlertRouter.reset()

    @Test
    fun `a target delivered while the opener is wired opens it now`() {
        AlertRouter.reset()
        val opened = mutableListOf<Pair<String, String>>()
        AlertRouter.open = { host, session -> opened += host to session }
        AlertRouter.deliver("host-1", "sess-1")
        assertEquals(listOf("host-1" to "sess-1"), opened)
    }

    @Test
    fun `a target that arrives before the opener is held, then flushed the moment it is wired`() {
        AlertRouter.reset()
        val opened = mutableListOf<Pair<String, String>>()
        // The cold-start case: the tap lands before the composition wires the opener.
        AlertRouter.deliver("host-1", "sess-1")
        assertEquals(emptyList<Pair<String, String>>(), opened)
        AlertRouter.open = { host, session -> opened += host to session }
        assertEquals(listOf("host-1" to "sess-1"), opened)
    }

    @Test
    fun `a held target flushes exactly once, so a recomposition does not replay it`() {
        AlertRouter.reset()
        var count = 0
        AlertRouter.deliver("h", "s")
        AlertRouter.open = { _, _ -> count += 1 }
        // Re-wiring (a recomposition, or a rotation) must not open the same session a second time.
        AlertRouter.open = { _, _ -> count += 1 }
        assertEquals(1, count)
    }

    @Test
    fun `an empty or missing id is dropped rather than opened`() {
        AlertRouter.reset()
        val opened = mutableListOf<Pair<String, String>>()
        AlertRouter.open = { host, session -> opened += host to session }
        AlertRouter.deliver(null, "s")
        AlertRouter.deliver("h", null)
        AlertRouter.deliver("", "s")
        AlertRouter.deliver("h", "")
        assertEquals(emptyList<Pair<String, String>>(), opened)
    }
}
