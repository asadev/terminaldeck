package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ChatRole
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CopilotAccess
import dev.terminaldeck.android.protocol.CopilotActionRow
import dev.terminaldeck.android.protocol.CopilotChatMessage
import dev.terminaldeck.android.protocol.CopilotConsentQuestion
import dev.terminaldeck.android.protocol.CopilotDesk
import dev.terminaldeck.android.protocol.CopilotEntry
import dev.terminaldeck.android.protocol.CopilotGrantWire
import dev.terminaldeck.android.protocol.CopilotLinkWire
import dev.terminaldeck.android.protocol.CopilotPendingRow
import dev.terminaldeck.android.protocol.CopilotSettledRow
import dev.terminaldeck.android.protocol.CopilotStateReport
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the copilot tab sends, and when.
 *
 * The rules worth pinning are the ones about **spending**: opening a tab must cost nothing, and the
 * one verb that spawns an agent must only ever leave on a tap.
 */
class CopilotControllerTest {

    private class Wire {
        val sent = mutableListOf<ClientMessage>()
        var connected = true
        fun send(message: ClientMessage): Boolean {
            if (!connected) return false
            sent += message
            return true
        }

        inline fun <reified T : ClientMessage> only(): List<T> = sent.filterIsInstance<T>()
        fun clear() = sent.clear()
    }

    private fun controller(
        wire: Wire,
        caps: Set<String> = setOf(Capability.COPILOT),
    ) = CopilotController(wire::send, { caps }, onChange = {})

    private fun grant(read: Boolean = true, act: Boolean = true, alter: Boolean = true) =
        ServerMessage.CopilotGrant(
            CopilotLinkWire(linked = true, open = true, grant = CopilotGrantWire(read, act, alter))
        )

    private fun state(run: String? = null, available: Boolean = true) =
        ServerMessage.CopilotStateFrame(
            CopilotStateReport(
                desk = CopilotDesk.Running,
                run = run,
                grant = CopilotGrantWire(read = true, act = true, alter = true),
                available = available,
            )
        )

    private fun opened(wire: Wire, run: String? = null): CopilotController {
        val c = controller(wire)
        c.open()
        c.receive(grant())
        c.receive(state(run))
        wire.clear()
        return c
    }

    @Test
    fun `a machine that never advertised a copilot draws no tab at all`() {
        val wire = Wire()
        val c = controller(wire, caps = emptySet())
        c.open()
        assertEquals(emptyList<ClientMessage>(), wire.sent)
        // Null rather than an empty view: the pill is *absent*, which is iOS's own rule for that tab.
        assertNull(c.view())
        assertEquals(CopilotAccess.NotOffered, c.access())
    }

    @Test
    fun `opening the tab spends nothing`() {
        val wire = Wire()
        controller(wire).open()
        // hello, attach, sessions, pending — all `read`. **No start.**
        assertEquals(1, wire.only<ClientMessage.CopilotHello>().size)
        assertEquals(1, wire.only<ClientMessage.CopilotAttach>().size)
        assertEquals(0, wire.only<ClientMessage.CopilotStart>().size)
    }

    @Test
    fun `opening twice does not re-attach`() {
        val wire = Wire()
        val c = controller(wire)
        c.open()
        c.open()
        assertEquals(1, wire.only<ClientMessage.CopilotAttach>().size)
    }

    @Test
    fun `leaving detaches, and does not stop the run`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.close()
        // A phone that locks its screen in a lift has not asked for its agent to be killed mid-turn.
        assertEquals(1, wire.only<ClientMessage.CopilotDetach>().size)
        assertEquals(0, wire.only<ClientMessage.CopilotStop>().size)
    }

    @Test
    fun `Start is the only verb that spawns anything, and it is refused without the act tier`() {
        val wire = Wire()
        val c = controller(wire)
        c.open()
        c.receive(ServerMessage.CopilotGrant(CopilotLinkWire(linked = true, open = true, grant = CopilotGrantWire(read = true))))
        wire.clear()

        assertEquals(CopilotAccess.Watch, c.access())
        c.start()
        c.say("do the thing")
        c.cancel()
        c.stopRun()
        // Not drawn in that state, and refused here as well: two locks on the same door.
        assertEquals(emptyList<ClientMessage>(), wire.sent)
    }

    @Test
    fun `with the act tier the four verbs reach the wire`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.start()
        c.cancel()
        c.stopRun()
        assertTrue(c.say("ship it"))
        assertEquals(1, wire.only<ClientMessage.CopilotStart>().size)
        assertEquals(1, wire.only<ClientMessage.CopilotCancel>().size)
        assertEquals(1, wire.only<ClientMessage.CopilotStop>().size)
        assertEquals("ship it", wire.only<ClientMessage.CopilotSay>().single().text)
    }

    @Test
    fun `a message with a control character is refused here rather than sent`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        // The text is written into a pty holding an agent CLI: a carriage return submits early and
        // turns the rest into a second prompt. Refused rather than stripped — stripping turns a
        // hostile value into a different legal-looking message, and the result is a turn somebody
        // pays for. The desktop answers one by closing the socket.
        assertFalse(c.say("ship it\r\nrm -rf /"))
        assertEquals(0, wire.only<ClientMessage.CopilotSay>().size)
        assertEquals(CopilotController.UNUSABLE, c.view()!!.notice!!.text)
    }

    @Test
    fun `an over-long message is refused before the socket is spent on it`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        assertFalse(c.say("a".repeat(Protocol.MAX_COPILOT_SAY_BYTES + 1)))
        assertEquals(0, wire.only<ClientMessage.CopilotSay>().size)
        assertEquals(CopilotController.TOO_LONG, c.view()!!.notice!!.text)
    }

    @Test
    fun `a message while the socket is down keeps its draft and says so`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        wire.connected = false
        assertFalse(c.say("ship it"))
        assertEquals(CopilotController.NOT_CONNECTED, c.view()!!.notice!!.text)
    }

    @Test
    fun `an empty message is not a message`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        assertFalse(c.say("   "))
        assertEquals(0, wire.only<ClientMessage.CopilotSay>().size)
        // And no notice: nothing went wrong, somebody pressed send on an empty box.
        assertNull(c.view()!!.notice)
    }

    @Test
    fun `a conversation frame from a dead run is dropped rather than spliced onto the live one`() {
        val wire = Wire()
        val c = opened(wire, run = "r2")
        c.receive(ServerMessage.CopilotChat("r2", listOf(message("m1", "live"))))
        c.receive(ServerMessage.CopilotChat("r1", listOf(message("m0", "from the dead run"))))
        // Without the run check a phone that reconnected after the grace window would read an answer
        // to a question it never asked in this run.
        assertEquals(listOf("m1"), c.view()!!.entries.map { (it as CopilotEntry.Said).message.id })
    }

    @Test
    fun `a reset is taken whatever run it names, because it is the whole conversation`() {
        val wire = Wire()
        val c = opened(wire, run = "r2")
        c.receive(ServerMessage.CopilotChat("r2", listOf(message("m1", "old"))))
        c.receive(ServerMessage.CopilotChat("r3", listOf(message("m9", "new")), reset = true))
        assertEquals(listOf("m9"), c.view()!!.entries.map { (it as CopilotEntry.Said).message.id })
    }

    @Test
    fun `what it said and what it did land on one list, in arrival order`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(ServerMessage.CopilotChat("r1", listOf(message("m1", "reading the file"))))
        c.receive(ServerMessage.CopilotTool(CopilotActionRow(id = "a1", tool = "read_file")))
        c.receive(ServerMessage.CopilotChat("r1", listOf(message("m2", "done"))))

        val entries = c.view()!!.entries
        assertEquals(3, entries.size)
        assertTrue(entries[0] is CopilotEntry.Said)
        assertTrue(entries[1] is CopilotEntry.Did)
        assertTrue(entries[2] is CopilotEntry.Said)
    }

    @Test
    fun `a question this device may answer is taken off the screen on the send, not on the settle`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(ServerMessage.CopilotAsk(question("q1")))
        assertNotNull(c.view()!!.question)

        c.answer(true)
        // The far end answers every question exactly once and the loser of a race is told where it
        // was answered, so a dialog left up would be one this device can no longer act on.
        assertNull(c.view()!!.question)
        val sent = wire.only<ClientMessage.CopilotAnswer>().single()
        assertEquals("q1", sent.id)
        assertEquals(true, sent.approved)
    }

    @Test
    fun `an answer that could not be sent keeps the question on screen`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(ServerMessage.CopilotAsk(question("q1")))
        wire.connected = false
        c.answer(true)
        assertNotNull("a question answered into a dead socket is still a question", c.view()!!.question)
        assertEquals(CopilotController.NOT_CONNECTED, c.view()!!.notice!!.text)
    }

    @Test
    fun `a settled confirmation clears it and says where the answer came from`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(ServerMessage.CopilotAsk(question("q1")))
        c.receive(ServerMessage.CopilotSettled(CopilotSettledRow(id = "q1", granted = true, by = "Asad's Mac")))
        assertNull(c.view()!!.question)
        assertEquals("Answered on Asad's Mac.", c.view()!!.notice!!.text)
    }

    @Test
    fun `the badge counts what this device can actually answer`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(
            ServerMessage.CopilotPendingRows(
                listOf(
                    CopilotPendingRow(id = "q1", mine = true),
                    CopilotPendingRow(id = "q2", mine = false),
                )
            )
        )
        // A badge counting somebody else's question would send a person to a screen with nothing to
        // press.
        assertEquals(1, c.view()!!.waitingCount)
    }

    @Test
    fun `a dropped socket keeps the conversation and loses the state`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(ServerMessage.CopilotChat("r1", listOf(message("m1", "said"))))
        c.receive(ServerMessage.CopilotAsk(question("q1")))

        c.dropped()

        val view = c.view()!!
        // A bubble is something that was said and a drop does not unsay it.
        assertEquals(1, view.entries.size)
        // A state is a claim about now and nothing over a dead channel will correct it.
        assertNull(view.state)
        // And an unanswerable confirmation left on screen is three buttons that do nothing.
        assertNull(view.question)
    }

    @Test
    fun `a grant that closed re-opens on the next visit`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.receive(
            ServerMessage.CopilotGrant(
                CopilotLinkWire(linked = true, open = false, grant = CopilotGrantWire(read = true, act = true))
            )
        )
        wire.clear()
        c.open()
        // A client that kept `attached` after the far side stopped serving it would never re-open.
        assertEquals(1, wire.only<ClientMessage.CopilotHello>().size)
    }

    @Test
    fun `the state's own grant is read, so a fresh attach does not draw Connecting`() {
        val wire = Wire()
        val c = controller(wire)
        c.open()
        // The attach answers with the state first; a tab that waited for the `copilot.grant` push
        // would draw Connecting over a copilot that was already open.
        c.receive(state(run = "r1"))
        assertEquals(CopilotAccess.Direct, c.access())
        assertTrue(c.view()!!.canSay)
    }

    @Test
    fun `Start is drawn only when there is no run and the machine says it can`() {
        val wire = Wire()
        val c = controller(wire)
        c.open()
        c.receive(state(run = null, available = true))
        assertTrue(c.view()!!.canStart)
        assertFalse(c.view()!!.canSay)

        c.receive(state(run = "r1"))
        // A run exists: Start would be a second process, which the far end answers with the run that
        // already exists rather than a second one.
        assertFalse(c.view()!!.canStart)
        assertTrue(c.view()!!.canSay)
    }

    @Test
    fun `a machine that cannot start one says so in its own words and offers no button`() {
        val wire = Wire()
        val c = controller(wire)
        c.open()
        c.receive(
            ServerMessage.CopilotStateFrame(
                CopilotStateReport(
                    grant = CopilotGrantWire(read = true, act = true, alter = true),
                    available = false,
                    reason = "No API key configured.",
                )
            )
        )
        assertFalse(c.view()!!.canStart)
        // *"No API key configured"* is not a thing this end can rephrase without guessing at a setup
        // it cannot see.
        assertEquals("No API key configured.", c.view()!!.unavailable)
    }

    @Test
    fun `a log read is asked once however fast somebody scrolls`() {
        val wire = Wire()
        val c = opened(wire, run = "r1")
        c.readLog()
        c.readLog()
        assertEquals(1, wire.only<ClientMessage.CopilotLog>().size)

        c.receive(ServerMessage.CopilotLogRows(listOf(CopilotActionRow(id = "a1")), more = true))
        c.readLog(before = "a1")
        assertEquals(2, wire.only<ClientMessage.CopilotLog>().size)
        assertEquals("a1", wire.only<ClientMessage.CopilotLog>().last().before)
    }

    private fun message(id: String, text: String) =
        CopilotChatMessage(id = id, role = ChatRole.Agent, text = text)

    private fun question(id: String) = CopilotConsentQuestion(
        id = id,
        tool = "write_file",
        tier = "alter",
        summary = "Write src/main.ts",
        origin = "r1",
        requestedAt = 1,
        expiresAt = 2,
    )
}
