package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ServerMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The login handover on a watched browser window: the wire this phone sends to claim and hand back a
 * login, and the four states the bar draws from a `browser.handover.state`.
 *
 * The rules worth pinning are the safety ones: a claim is only sent for a window actually asking, a
 * hand-back only from the device that holds it, and the four-state decision — because getting it
 * wrong is either a blocked agent nobody can unblock or two people typing into one password field.
 */
class WatchHandoverTest {

    private class Wire {
        val sent = mutableListOf<ClientMessage>()
        var connected = true
        fun send(message: ClientMessage): Boolean {
            if (!connected) return false
            sent += message
            return true
        }

        inline fun <reified T : ClientMessage> only(): List<T> = sent.filterIsInstance<T>()
    }

    private fun controller(wire: Wire, caps: Set<String> = setOf(Capability.WATCH)) =
        WatchController(wire::send, { caps }, onChange = {})

    private fun asking(
        window: String = "",
        mine: Boolean = false,
        taken: Boolean = false,
        prompt: String = "Sign in with your billing account",
    ) = ServerMessage.BrowserHandover(
        window = window,
        asking = true,
        prompt = prompt,
        mine = mine,
        taken = taken,
    )

    @Test
    fun `an asking state becomes a handover the bar can draw`() {
        val wire = Wire()
        val c = controller(wire)
        c.receive(asking(prompt = "Enter the code we texted"))
        val handover = c.handover("")!!
        assertTrue(handover.asking)
        assertEquals("Enter the code we texted", handover.prompt)
        assertFalse(handover.mine)
        assertFalse(handover.taken)
    }

    @Test
    fun `a state that has stopped asking removes the handover`() {
        val wire = Wire()
        val c = controller(wire)
        c.receive(asking())
        assertTrue(c.handover("") != null)
        c.receive(ServerMessage.BrowserHandover(window = "", asking = false))
        assertNull(c.handover(""))
    }

    @Test
    fun `taking a window sends the claim and marks it awaiting, and only while one is asking`() {
        val wire = Wire()
        val c = controller(wire)
        // Nothing outstanding: a claim is refused here rather than sent and refused at the far end.
        assertFalse(c.take(""))
        assertEquals(0, wire.only<ClientMessage.BrowserHandoverTake>().size)

        c.receive(asking())
        assertTrue(c.take(""))
        assertEquals(1, wire.only<ClientMessage.BrowserHandoverTake>().size)
        assertTrue(c.isAwaiting(""))

        // A second tap while one is in flight must not send a second claim.
        assertFalse(c.take(""))
        assertEquals(1, wire.only<ClientMessage.BrowserHandoverTake>().size)
    }

    @Test
    fun `handing back is only from the device that holds it, and says which way`() {
        val wire = Wire()
        val c = controller(wire)
        // Not mine: no hand-back — a second watcher must not hand back a page mid-password.
        c.receive(asking(mine = false, taken = true))
        assertFalse(c.handBack("", carryOn = true))
        assertEquals(0, wire.only<ClientMessage.BrowserHandoverDone>().size)

        c.receive(asking(mine = true, taken = true))
        assertTrue(c.handBack("", carryOn = true))
        val done = wire.only<ClientMessage.BrowserHandoverDone>().single()
        assertTrue(done.carryOn)
        assertTrue(c.isAwaiting(""))
    }

    @Test
    fun `a refused claim is drawn beside a Try again, until a state frame clears it`() {
        val wire = Wire()
        val c = controller(wire)
        c.receive(asking())
        c.take("")
        assertTrue(c.isAwaiting(""))

        // The error frame names no request, so a refusal arriving while exactly one answer is
        // outstanding is treated as that one's.
        c.wireErrored("The agent was not ready for that yet.")
        val refused = c.handover("")!!
        assertEquals("The agent was not ready for that yet.", refused.refusal)
        assertFalse(c.isAwaiting(""))
        assertEquals(SessionHandover.Offer.Retry, SessionHandover.offer(refused))

        // A fresh state clears the refusal.
        c.receive(asking())
        assertNull(c.handover("")!!.refusal)
    }

    @Test
    fun `the four states each offer the right thing`() {
        val claim = BrowserHandover(asking = true, prompt = "", mine = false, taken = false)
        val elsewhere = BrowserHandover(asking = true, prompt = "", mine = false, taken = true)
        val held = BrowserHandover(asking = true, prompt = "", mine = true, taken = true)
        val retry = BrowserHandover(asking = true, prompt = "", mine = false, taken = false, refusal = "no")

        assertEquals(SessionHandover.Offer.Claim, SessionHandover.offer(claim))
        assertEquals(SessionHandover.Offer.Elsewhere, SessionHandover.offer(elsewhere))
        assertEquals(SessionHandover.Offer.HandBack, SessionHandover.offer(held))
        assertEquals(SessionHandover.Offer.Retry, SessionHandover.offer(retry))

        // `mine` outranks everything, including a leftover refusal.
        val heldWithStaleRefusal = held.copy(refusal = "old")
        assertEquals(SessionHandover.Offer.HandBack, SessionHandover.offer(heldWithStaleRefusal))
        assertEquals("You have this page", SessionHandover.headline(held))
        assertEquals("Another device is answering this", SessionHandover.headline(elsewhere))
    }

    @Test
    fun `a new welcome forgets an outstanding handover`() {
        val wire = Wire()
        val c = controller(wire)
        c.receive(asking(mine = true, taken = true))
        assertTrue(c.handover("") != null)
        c.renew()
        assertNull(c.handover(""))
    }
}
