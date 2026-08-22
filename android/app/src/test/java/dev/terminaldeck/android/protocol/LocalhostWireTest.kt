package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What is listening, what a dev server is doing, and the page that opens over there.
 *
 * The five dev-server states are the substance of this file. Two of the pairs are exactly the ones a
 * client must not collapse, and collapsing them is invisible from the code — it produces a button
 * whose only possible outcome is a refusal, or a Start drawn over a failure nobody was shown.
 */
class LocalhostWireTest {

    private fun ok(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("parse refused: $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ------------------------------------------------------------- outbound -- */

    @Test
    fun `the client verbs encode the shapes the desktop parses`() {
        assertEquals("""{"t":"ports"}""", ClientFrames.encode(ClientMessage.Ports))
        assertEquals(
            """{"t":"web.open","url":"http://localhost:3000"}""",
            ClientFrames.encode(ClientMessage.WebOpen("http://localhost:3000")),
        )
        assertEquals(
            """{"t":"dev.status","folder":"/Users/a/p"}""",
            ClientFrames.encode(ClientMessage.DevStatus("/Users/a/p")),
        )
        assertEquals(
            """{"t":"dev.start","folder":"/Users/a/p"}""",
            ClientFrames.encode(ClientMessage.DevStart("/Users/a/p")),
        )
    }

    /* -------------------------------------------------------------- inbound -- */

    @Test
    fun `ports narrow the port, the process and whether it was guessed`() {
        val frame = ok(
            """{"t":"ports","ports":[{"port":3000,"process":"node","guessed":false},{"port":5173,"process":"vite","guessed":true}]}"""
        ) as ServerMessage.Ports
        assertEquals(2, frame.ports.size)
        assertEquals(3000, frame.ports[0].port)
        assertFalse(frame.ports[0].guessed)
        // "node" read off the process table and "node" guessed from a port number are not the same
        // claim, and the row says which.
        assertTrue(frame.ports[1].guessed)
    }

    @Test
    fun `web opened echoes the url the machine actually opened`() {
        val frame = ok("""{"t":"web.opened","url":"http://localhost:3000/"}""") as ServerMessage.WebOpened
        // Echoed rather than remembered, so what is confirmed is what happened over there.
        assertEquals("http://localhost:3000/", frame.url)
    }

    @Test
    fun `every dev server status spells itself the way the wire does`() {
        val words = listOf("no-dev-script", "idle", "starting", "ready", "failed")
        val read = words.map { word ->
            (ok("""{"t":"dev.state","state":{"folder":"/p","status":"$word"}}""") as ServerMessage.DevState)
                .state.status
        }
        assertEquals(
            listOf(
                DevServerStatus.NoDevScript,
                DevServerStatus.Idle,
                DevServerStatus.Starting,
                DevServerStatus.Ready,
                DevServerStatus.Failed,
            ),
            read,
        )
    }

    @Test
    fun `a status this build has never heard of does not drop the frame`() {
        val frame = ok("""{"t":"dev.state","state":{"folder":"/p","status":"restarting"}}""")
            as ServerMessage.DevState
        // A client that refused to parse a sixth word would turn a future desktop's honest answer
        // into a dropped frame — and the row would keep whatever it said before, which is worse.
        assertEquals(DevServerStatus.Unknown, frame.state.status)
        assertEquals("/p", frame.state.folder)
    }

    @Test
    fun `no dev script is not idle`() {
        val none = (ok("""{"t":"dev.state","state":{"folder":"/p","status":"no-dev-script"}}""")
            as ServerMessage.DevState).state
        val idle = (ok("""{"t":"dev.state","state":{"folder":"/p","status":"idle","script":"dev","command":"pnpm run dev"}}""")
            as ServerMessage.DevState).state
        // `idle` means "press this"; `no-dev-script` means there is nothing to press and never will
        // be for this folder. A client that flattens them draws a button that can only be refused.
        assertFalse(none.canStart)
        assertTrue(idle.canStart)
        assertEquals("pnpm run dev", idle.command)
    }

    @Test
    fun `failed is not idle either, and carries the reason`() {
        val failed = (ok("""{"t":"dev.state","state":{"folder":"/p","status":"failed","message":"Port 3000 was already taken.","sessionId":"s9"}}""")
            as ServerMessage.DevState).state
        assertEquals("Port 3000 was already taken.", failed.message)
        // The session that failed is still there with the reason printed in it, and it is what the
        // row offers — so `sessionId` has to survive the narrowing.
        assertEquals("s9", failed.sessionId)
        assertNull(failed.openable)
    }

    @Test
    fun `an address is offered only on ready`() {
        val starting = (ok("""{"t":"dev.state","state":{"folder":"/p","status":"starting","url":"http://localhost:3000","note":"compiling"}}""")
            as ServerMessage.DevState).state
        // `ready` is only ever sent after something accepted a TCP connection on that port. A url
        // arriving under any other status is not a promise, so it is not offered as one.
        assertNull(starting.openable)
        assertTrue(starting.isBusy)
        assertEquals("compiling", starting.note)

        val ready = (ok("""{"t":"dev.state","state":{"folder":"/p","status":"ready","port":3000,"url":"http://localhost:3000"}}""")
            as ServerMessage.DevState).state
        assertEquals("http://localhost:3000", ready.openable)
        assertEquals(3000, ready.port)
        assertFalse(ready.canStart)
    }
}
