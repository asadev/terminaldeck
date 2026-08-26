package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `ports`, `web.open` and `dev.*` through the real codec.
 *
 * The three capabilities the localhost tab is built on. What can be wrong here is a field name or a
 * discriminator, and only the real encoder can be wrong about one.
 */
class WebAndPortsWireTest {

    private fun ok(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    @Test
    fun `asking what is listening is a bare frame with no fields to get wrong`() {
        assertEquals("""{"t":"ports"}""", ClientFrames.encode(ClientMessage.Ports))
    }

    @Test
    fun `the answer carries the number, the process and whether the owner was a guess`() {
        val message = ok(
            """{"t":"ports","ports":[{"port":5173,"process":"node"},{"port":2019,"process":"unknown","guessed":true}]}"""
        )
        val ports = (message as ServerMessage.Ports).ports
        assertEquals(listOf(5173, 2019), ports.map { it.port })
        assertEquals("node", ports[0].process)
        // `guessed` means the port answers and nothing could name its owner. A client that folded it
        // into the process name would be inventing an owner.
        assertEquals(false, ports[0].guessed)
        assertEquals(true, ports[1].guessed)
    }

    @Test
    fun `a machine with nothing listening answers an empty list rather than no field`() {
        assertEquals(ServerMessage.Ports(emptyList()), ok("""{"t":"ports"}"""))
    }

    @Test
    fun `opening a page on the machine names only the url`() {
        assertEquals(
            """{"t":"web.open","url":"http://localhost:5173/"}""",
            ClientFrames.encode(ClientMessage.WebOpen("http://localhost:5173/")),
        )
        assertEquals(ServerMessage.WebOpened("http://localhost:5173/"), ok("""{"t":"web.opened","url":"http://localhost:5173/"}"""))
    }

    @Test
    fun `the two dev verbs name a folder and nothing else — a command is never on the wire`() {
        assertEquals("""{"t":"dev.status","folder":"/w/app"}""", ClientFrames.encode(ClientMessage.DevStatus("/w/app")))
        assertEquals("""{"t":"dev.start","folder":"/w/app"}""", ClientFrames.encode(ClientMessage.DevStart("/w/app")))
    }

    @Test
    fun `a ready report carries the proven port and the address, and a failed one carries neither`() {
        val ready = ok(
            """{"t":"dev.state","state":{"folder":"/w/app","status":"ready","script":"dev",""" +
                """"command":"pnpm run dev","sessionId":"s1","port":5173,"url":"http://localhost:5173"}}"""
        ) as ServerMessage.DevState
        assertEquals(DevServerStatus.Ready, ready.state.status)
        assertEquals("http://localhost:5173", ready.state.openable)

        val failed = ok(
            """{"t":"dev.state","state":{"folder":"/w/app","status":"failed","message":"vite exited 1"}}"""
        ) as ServerMessage.DevState
        assertEquals(DevServerStatus.Failed, failed.state.status)
        // The one thing a client of this frame must never display: an address under a server that
        // is not there.
        assertEquals(null, failed.state.openable)
        assertEquals(true, failed.state.canStart)
    }

    @Test
    fun `a status a newer desktop grew is folded rather than dropping the frame`() {
        val message = ok("""{"t":"dev.state","state":{"folder":"/w/app","status":"hibernating"}}""") as ServerMessage.DevState
        assertEquals(DevServerStatus.Unknown, message.state.status)
        // Unknown offers nothing: it is neither a Start nor a Session, because this build does not
        // know what the word means.
        assertEquals(false, message.state.canStart)
        assertEquals(null, message.state.openable)
    }

    @Test
    fun `no-dev-script is not idle, and the difference is a button that would only be refused`() {
        val message = ok("""{"t":"dev.state","state":{"folder":"/w/app","status":"no-dev-script"}}""") as ServerMessage.DevState
        assertEquals(DevServerStatus.NoDevScript, message.state.status)
        assertEquals(false, message.state.canStart)
    }

    @Test
    fun `the capability names are the desktop's, spelled once`() {
        assertEquals("localhost", Capability.LOCALHOST)
        assertEquals("web", Capability.WEB)
        assertEquals("devserver", Capability.DEVSERVER)
        assertEquals("usage", Capability.USAGE)
        assertEquals("account", Capability.ACCOUNT)
        assertEquals("send", Capability.SEND)
        assertEquals("copilot", Capability.COPILOT)
    }
}
