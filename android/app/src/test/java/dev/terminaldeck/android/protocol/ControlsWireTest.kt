package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The control cluster on the wire, and the decisions drawn off it.
 *
 * Everything here is checked against the shapes `src/main/remote/protocol.ts` composes and the
 * behaviour `pwa/src/session-controls.ts` and `ios/TerminalDeck/App/SessionControlsLink.swift`
 * already have — three clients that must agree, because the value a row sends ends up typed at a
 * real `claude` binary on somebody's machine.
 */
class ControlsWireTest {

    private fun parse(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ------------------------------------------------------------------ wire -- */

    @Test
    fun `a read names the request and the session`() {
        assertEquals(
            """{"t":"controls.read","rid":"ctl-1","id":"s-1"}""",
            ClientFrames.encode(ClientMessage.ControlsRead("ctl-1", "s-1")),
        )
    }

    @Test
    fun `an apply carries the control by its wire name`() {
        assertEquals(
            """{"t":"controls.apply","rid":"ctl-2","id":"s-1","control":"fast","value":"on"}""",
            ClientFrames.encode(ClientMessage.ControlsApply("ctl-2", "s-1", ControlName.Fast, "on")),
        )
        assertEquals(
            """{"t":"controls.apply","rid":"ctl-3","id":"s-1","control":"permission","value":"plan"}""",
            ClientFrames.encode(
                ClientMessage.ControlsApply("ctl-3", "s-1", ControlName.Permission, "plan")
            ),
        )
    }

    @Test
    fun `a reading narrows every field the desktop sends`() {
        val message = parse(
            """{"t":"controls.reading","rid":"r1","id":"s-1","reading":{
                "model":{"value":"opus","label":"Opus 5","source":"cli"},
                "effort":{"value":"xhigh","label":"Extra high","source":null},
                "fast":{"value":"off","label":"Off","source":null},
                "permission":{"value":null,"label":null,"source":null},
                "live":true,
                "agent":{"running":true,"saw":"claude"},
                "gate":{"canType":true,"reason":null}}}"""
        )
        val reading = (message as ServerMessage.ControlsReading).reading
        assertEquals("opus", reading.model.value)
        assertEquals("Opus 5", reading.model.label)
        assertTrue(reading.live)
        assertTrue(reading.agent.running)
        assertTrue(reading.gate.canType)
        // `source` is dropped rather than narrowed: nothing on a phone prints a source note, and a
        // build newer than this one may name one it has no word for.
        assertEquals(ControlReadingWire(value = "opus", label = "Opus 5"), reading.model)
    }

    @Test
    fun `a reading with nothing in it is the safe reading, not a refusal`() {
        val message = parse("""{"t":"controls.reading","rid":"r1","id":"s-1","reading":{}}""")
        val reading = (message as ServerMessage.ControlsReading).reading
        // Absent gate reads as "cannot type", which greys the chips rather than offering a press
        // that would be refused; absent agent reads as "no agent", which draws nothing at all.
        assertFalse(reading.gate.canType)
        assertFalse(reading.agent.running)
        assertFalse(reading.live)
        assertEquals(ControlReadingWire.EMPTY, reading.permission)
        assertFalse(SessionControls.clusterShown(reading))
    }

    @Test
    fun `a reading frame missing its reading altogether still parses`() {
        // The additive rule: a desktop that stopped sending the object is a desktop this phone shows
        // no cluster for, not one it drops the socket over.
        val message = parse("""{"t":"controls.reading","rid":"r1","id":"s-1"}""")
        assertEquals(ControlsReadingWire(), (message as ServerMessage.ControlsReading).reading)
    }

    @Test
    fun `an applied frame carries the far end's own re-read`() {
        val message = parse(
            """{"t":"controls.applied","rid":"r2","id":"s-1","ok":false,"message":"That session refused it.",
                "reading":{"value":"opus","label":"Opus 5","source":null}}"""
        ) as ServerMessage.ControlsApplied
        assertFalse(message.ok)
        assertEquals("That session refused it.", message.message)
        // The value that comes back is what the session is on, not what was pressed — which is what
        // makes a refused apply revert by construction.
        assertEquals("opus", message.reading.value)
    }

    /* ------------------------------------------------------------ decisions -- */

    @Test
    fun `the cluster is absent over a plain shell and over a dead session`() {
        val agentUp = ControlsReadingWire(live = true, agent = ControlAgentWire(running = true))
        assertTrue(SessionControls.clusterShown(agentUp))
        assertFalse(SessionControls.clusterShown(agentUp.copy(live = false)))
        assertFalse(SessionControls.clusterShown(agentUp.copy(agent = ControlAgentWire(running = false))))
        assertFalse(SessionControls.clusterShown(null))
    }

    @Test
    fun `a blocked control reports the far end's own sentence first`() {
        val reading = ControlsReadingWire(
            model = ControlReadingWire(unavailableReason = "This build has one model."),
            live = true,
            agent = ControlAgentWire(running = true),
            gate = ControlGateWire(canType = false, reason = "The session is busy."),
        )
        assertEquals("This build has one model.", SessionControls.blocked(ControlName.Model, reading))
        // No reason of its own: the typing gate answers, still in the far end's words.
        assertEquals("The session is busy.", SessionControls.blocked(ControlName.Effort, reading))
    }

    @Test
    fun `a gate with no sentence gets the one fallback that claims only what is known`() {
        val reading = ControlsReadingWire(live = true, agent = ControlAgentWire(running = true))
        assertEquals(
            "This session cannot be typed into right now, so nothing was sent.",
            SessionControls.blocked(ControlName.Permission, reading),
        )
    }

    @Test
    fun `nothing is blocked when the session can be typed into`() {
        val reading = ControlsReadingWire(
            live = true,
            agent = ControlAgentWire(running = true),
            gate = ControlGateWire(canType = true),
        )
        assertNull(SessionControls.blocked(ControlName.Model, reading))
    }

    @Test
    fun `fast flips from the reading rather than from what is on screen`() {
        assertEquals("off", SessionControls.fastFlip(ControlReadingWire(value = "on")))
        assertEquals("on", SessionControls.fastFlip(ControlReadingWire(value = "off")))
        // Nothing established: the switch is not drawn at all, and a press would turn it on.
        assertEquals("on", SessionControls.fastFlip(ControlReadingWire.EMPTY))
    }

    @Test
    fun `an apply's answer replaces only its own control`() {
        val before = ControlsReadingWire(
            model = ControlReadingWire("opus", "Opus 5"),
            effort = ControlReadingWire("high", "High"),
        )
        val after = before.applying(ControlName.Effort, ControlReadingWire("low", "Low"))
        assertEquals("Low", after.effort.label)
        assertEquals("Opus 5", after.model.label)
    }
}
