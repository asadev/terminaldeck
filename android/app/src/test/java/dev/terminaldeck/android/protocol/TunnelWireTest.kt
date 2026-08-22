package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The tunnel's frames, through the real codec.
 *
 * Every assertion here is against [ClientFrames.encode] and [ServerFrames.parse] rather than against
 * a hand-written JSON string compared to another hand-written JSON string: the thing that can be
 * wrong is the *discriminator and the field names the desktop's parser reads*, and only the real
 * encoder can be wrong about those.
 */
class TunnelWireTest {

    private fun ok(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    private fun bad(raw: String): String {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a refusal, got $result", result is ServerFrames.Result.Bad)
        return (result as ServerFrames.Result.Bad).reason
    }

    @Test
    fun `tunnel open names the id and the port the desktop's parser reads`() {
        assertEquals(
            """{"t":"tunnel.open","id":"t1","port":5173}""",
            ClientFrames.encode(ClientMessage.TunnelOpen("t1", 5173)),
        )
    }

    @Test
    fun `the four stream verbs are spelled the way the desktop spells them`() {
        assertEquals("""{"t":"net.open","ch":"c1","tunnel":"t1"}""", ClientFrames.encode(ClientMessage.NetOpen("c1", "t1")))
        assertEquals("""{"t":"net.data","ch":"c1","data":"aGk="}""", ClientFrames.encode(ClientMessage.NetData("c1", "aGk=")))
        assertEquals("""{"t":"net.ack","ch":"c1","bytes":24}""", ClientFrames.encode(ClientMessage.NetAck("c1", 24)))
        assertEquals("""{"t":"net.close","ch":"c1"}""", ClientFrames.encode(ClientMessage.NetClose("c1")))
        assertEquals("""{"t":"tunnel.close","id":"t1"}""", ClientFrames.encode(ClientMessage.TunnelClose("t1")))
    }

    @Test
    fun `a tunnel that opened carries the port back, so a client with two knows which`() {
        val message = ok("""{"t":"tunnel.opened","id":"t1","port":5173}""")
        assertEquals(ServerMessage.TunnelOpened("t1", 5173), message)
    }

    @Test
    fun `a tunnel opened on a port no socket can hold is refused rather than bound`() {
        assertEquals("tunnel.opened with an unusable port", bad("""{"t":"tunnel.opened","id":"t1","port":0}"""))
        assertEquals("tunnel.opened with an unusable port", bad("""{"t":"tunnel.opened","id":"t1","port":70000}"""))
        assertEquals("incomplete tunnel.opened", bad("""{"t":"tunnel.opened","id":"","port":5173}"""))
    }

    @Test
    fun `a closed tunnel carries the machine's own sentence, whatever the reason was`() {
        val message = ok("""{"t":"tunnel.closed","id":"t1","message":"Nothing is listening on 5173."}""")
        assertEquals(ServerMessage.TunnelClosed("t1", "Nothing is listening on 5173."), message)
        // The same frame answers a refusal, a teardown this phone asked for and a Stop pressed at
        // the desk. A missing sentence is not a reason to drop the frame — the tunnel is still over.
        assertEquals(ServerMessage.TunnelClosed("t1", ""), ok("""{"t":"tunnel.closed","id":"t1"}"""))
    }

    @Test
    fun `tunnelled bytes are checked as base64 before an allocator is handed them`() {
        val payload = Base64.getEncoder().encodeToString("<!doctype html>".toByteArray())
        assertEquals(ServerMessage.NetData("c1", payload), ok("""{"t":"net.data","ch":"c1","data":"$payload"}"""))
        // Refused rather than repaired: invented bytes in the middle of somebody's HTTP response are
        // worse than a stream that ends.
        assertEquals("net.data is not base64", bad("""{"t":"net.data","ch":"c1","data":"not base64!"}"""))
        assertEquals("net.data without a channel id", bad("""{"t":"net.data","ch":"","data":"aGk="}"""))
    }

    @Test
    fun `a chunk over the cap is refused, and the cap is the desktop's own arithmetic`() {
        // Four characters per three bytes, which is what MAX_NET_CHUNK_BYTES becomes on the wire.
        assertEquals(32_768, Protocol.MAX_NET_DATA_CHARS)
        val over = "A".repeat(Protocol.MAX_NET_DATA_CHARS + 4)
        assertEquals("net.data over the chunk limit", bad("""{"t":"net.data","ch":"c1","data":"$over"}"""))
    }

    @Test
    fun `an acknowledgement of a negative number is not an acknowledgement`() {
        assertEquals(ServerMessage.NetAck("c1", 24), ok("""{"t":"net.ack","ch":"c1","bytes":24}"""))
        assertEquals("net.ack out of range", bad("""{"t":"net.ack","ch":"c1","bytes":-1}"""))
        assertEquals("net.ack without a channel id", bad("""{"t":"net.ack","ch":"","bytes":1}"""))
    }

    @Test
    fun `a close without a channel names nothing and is refused`() {
        assertEquals(ServerMessage.NetClose("c1"), ok("""{"t":"net.close","ch":"c1"}"""))
        assertEquals("net.close without a channel id", bad("""{"t":"net.close","ch":""}"""))
    }

    @Test
    fun `the window is the desktop's, so a phone cannot buffer a source map into somebody's heap`() {
        assertEquals(256 * 1024, Protocol.NET_WINDOW_BYTES)
        assertEquals(24 * 1024, Protocol.MAX_NET_CHUNK_BYTES)
    }
}
