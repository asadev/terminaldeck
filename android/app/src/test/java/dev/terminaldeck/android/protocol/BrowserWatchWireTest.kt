package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Watching a browser: the frames, the one message allowed past the text cap, and the arithmetic that
 * decides where on a page a finger landed.
 *
 * The coordinate math is the part that can be wrong silently — a viewer with a broken transform
 * still draws a page and still sends taps, they just land somewhere else — so it is the part with
 * the most checks.
 */
class BrowserWatchWireTest {

    private fun parse(raw: String): ServerFrames.Result = ServerFrames.parse(raw)

    private fun ok(raw: String): ServerMessage {
        val result = parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ------------------------------------------------------------------ wire -- */

    @Test
    fun `watch, unwatch and ack are the three flat frames`() {
        assertEquals(
            """{"t":"browser.watch","window":"","maxWidth":1080,"quality":50}""",
            ClientFrames.encode(ClientMessage.BrowserWatch("", 1080, 50)),
        )
        assertEquals(
            """{"t":"browser.unwatch","window":"slot-a"}""",
            ClientFrames.encode(ClientMessage.BrowserUnwatch("slot-a")),
        )
        assertEquals(
            """{"t":"browser.frame.ack","window":"","seq":7}""",
            ClientFrames.encode(ClientMessage.BrowserFrameAck("", 7)),
        )
    }

    @Test
    fun `an input frame writes exactly one of the four kinds`() {
        val tap = ClientFrames.encode(
            ClientMessage.BrowserInput(
                window = "",
                seq = 3,
                mouse = BrowserMouseWire(type = "down", x = 10, y = 20, button = "left", clicks = 1),
            )
        )
        assertTrue(tap, tap.contains(QUOTED_MOUSE))
        // The other three must not reach the wire at all — a frame naming two could not have been
        // one gesture, and the desktop parser is entitled to refuse it.
        assertTrue(
            tap,
            !tap.contains(QUOTED_KEY) && !tap.contains(QUOTED_TOUCH) && !tap.contains(QUOTED_PASTE),
        )

        val typed = ClientFrames.encode(ClientMessage.BrowserInput(window = "", seq = 3, paste = "hi"))
        assertEquals("""{"t":"browser.input","window":"","seq":3,"paste":"hi"}""", typed)
    }

    @Test
    fun `a surfaces push is believed without a rid, because it is not an answer`() {
        val message = ok(
            """{"t":"browser.surfaces.rows","surfaces":[
                {"window":"","url":"https://example.test/","title":"Example","live":true},
                {"window":"slot-a","url":"","title":"","live":false}]}"""
        ) as ServerMessage.BrowserSurfacesRows
        assertNull(message.rid)
        assertEquals(2, message.surfaces.size)
        assertEquals("Example", message.surfaces[0].displayTitle)
        // A row with neither title nor url still says something a person can pick out of a list.
        assertEquals("slot-a", message.surfaces[1].displayTitle)
        assertEquals("Front tab", message.surfaces[0].copy(title = "").displayTitle)
    }

    @Test
    fun `a masked frame is a curtain and carries no pixels`() {
        val frame = ok(
            """{"t":"browser.frame","window":"","seq":4,"w":800,"h":600,"dw":400,"dh":300,
                "scale":2,"offsetTop":0,"pageScale":1,"scrollX":0,"scrollY":0,
                "masked":true,"prompt":"Signing in.","data":""}"""
        ) as ServerMessage.BrowserFrame
        assertTrue(frame.masked)
        assertNull(frame.bytes())
        assertEquals("Signing in.", frame.curtain)
    }

    @Test
    fun `a curtain with no prompt still says something`() {
        val frame = ok(
            """{"t":"browser.frame","window":"","seq":1,"w":8,"h":6,"masked":true,"data":""}"""
        ) as ServerMessage.BrowserFrame
        assertEquals(DEFAULT_CURTAIN_PROMPT, frame.curtain)
    }

    @Test
    fun `a frame jpeg is decoded, and a corrupt one is null rather than a refusal`() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        val encoded = Base64.getEncoder().encodeToString(bytes)
        val good = ok(
            """{"t":"browser.frame","window":"","seq":2,"w":8,"h":6,"data":"$encoded"}"""
        ) as ServerMessage.BrowserFrame
        assertNotNull(good.bytes())
        assertEquals(4, good.bytes()!!.size)

        // Not a refusal: the painter acks a frame it could not draw, or one bad frame stalls the
        // whole cast behind the one-in-flight window the host holds.
        val bad = ok("""{"t":"browser.frame","window":"","seq":3,"w":8,"h":6,"data":"!!!not base64!!!"}""")
        assertNull((bad as ServerMessage.BrowserFrame).bytes())
    }

    /* ------------------------------------------------- the type-aware cap -- */

    @Test
    fun `a frame may be larger than the text cap, and nothing else may`() {
        val padding = "A".repeat(Protocol.MAX_MESSAGE_BYTES)
        val frame = """{"t":"browser.frame","window":"","seq":9,"w":8,"h":6,"data":"$padding"}"""
        assertTrue(Protocol.overBytes(frame, Protocol.MAX_MESSAGE_BYTES))
        assertTrue(parse(frame) is ServerFrames.Result.Ok)

        // The same size, a different `t`: refused, because the larger allowance a frame gets is
        // never borrowed by another message.
        val notAFrame = """{"t":"output","id":"s-1","data":"$padding"}"""
        assertTrue(parse(notAFrame) is ServerFrames.Result.Bad)
    }

    @Test
    fun `a frame over the frame cap is refused too`() {
        val padding = "A".repeat(Protocol.MAX_FRAME_MESSAGE_BYTES + 1)
        val huge = """{"t":"browser.frame","window":"","seq":9,"w":8,"h":6,"data":"$padding"}"""
        assertTrue(parse(huge) is ServerFrames.Result.Bad)
    }

    @Test
    fun `the frame cap is the base64 of the byte cap plus room for the rest`() {
        assertEquals(WatchMath.base64Chars(Protocol.MAX_FRAME_BYTES), Protocol.MAX_FRAME_DATA_CHARS)
        assertEquals(Protocol.MAX_FRAME_DATA_CHARS + 2 * 1024, Protocol.MAX_FRAME_MESSAGE_BYTES)
    }

    /* ----------------------------------------------------------------- math -- */

    @Test
    fun `the asked width is clamped into the host range`() {
        assertEquals(1080, WatchMath.watchWidth(1080))
        assertEquals(Protocol.MIN_WATCH_WIDTH, WatchMath.watchWidth(4))
        assertEquals(Protocol.MAX_WATCH_WIDTH, WatchMath.watchWidth(9000))
        assertEquals(Protocol.MAX_WATCH_QUALITY, WatchMath.watchQuality(500))
        assertEquals(Protocol.MIN_WATCH_QUALITY, WatchMath.watchQuality(0))
        assertEquals(DEFAULT_WATCH_QUALITY, WatchMath.watchQuality(DEFAULT_WATCH_QUALITY))
    }

    @Test
    fun `a point maps to image pixels of the frame it was drawn against`() {
        // A 1000x500 image drawn into a 500x250 box: everything is halved.
        assertEquals(200 to 100, WatchMath.imageCoords(1000, 500, 500f, 250f, 100f, 50f))
        // The corners land on the corners.
        assertEquals(0 to 0, WatchMath.imageCoords(1000, 500, 500f, 250f, 0f, 0f))
        assertEquals(1000 to 500, WatchMath.imageCoords(1000, 500, 500f, 250f, 500f, 250f))
    }

    @Test
    fun `a drag that leaves the view still names a pixel on the page`() {
        assertEquals(0 to 0, WatchMath.imageCoords(1000, 500, 500f, 250f, -80f, -80f))
        assertEquals(1000 to 500, WatchMath.imageCoords(1000, 500, 500f, 250f, 900f, 900f))
    }

    @Test
    fun `a view with no size names the origin rather than dividing by zero`() {
        assertEquals(0 to 0, WatchMath.imageCoords(1000, 500, 0f, 0f, 12f, 12f))
    }

    @Test
    fun `a paste keeps tab and newline, drops the other controls, and cuts on a code point`() {
        // A bell and a DEL: the two ends of the range a page field would choke on.
        val bell = "\u0007"
        val del = "\u007F"
        assertEquals("ab\tc\nd", WatchMath.cleanPaste("a" + bell + "b\tc\nd" + del))
        // Four bytes for an astral character: a cap of five keeps it whole, a cap of three cannot.
        val astral = "\uD83D\uDE00"
        assertEquals(astral, WatchMath.cleanPaste(astral, maxBytes = 5))
        assertEquals("", WatchMath.cleanPaste(astral, maxBytes = 3))
        assertEquals(Protocol.MAX_INPUT_BYTES, WatchMath.cleanPaste("x".repeat(100_000)).length)
    }

    /* -------------------------------------------------------------- handover -- */

    @Test
    fun `a handover state is read whole, and reads the safe way round when a field is missing`() {
        val full = ok(
            """{"t":"browser.handover.state","window":"slot-a","rid":"r1","asking":true,"prompt":"Sign in","mine":true,"taken":true}"""
        ) as ServerMessage.BrowserHandover
        assertEquals("slot-a", full.window)
        assertEquals("r1", full.rid)
        assertTrue(full.asking)
        assertEquals("Sign in", full.prompt)
        assertTrue(full.mine)
        assertTrue(full.taken)

        // Everything but the window may be absent, and each missing field reads the safe way: not
        // asking, not mine, not taken — never a claim button under a question nobody asked.
        val bare = ok("""{"t":"browser.handover.state","window":""}""") as ServerMessage.BrowserHandover
        assertEquals("", bare.window)
        assertFalse(bare.asking)
        assertFalse(bare.mine)
        assertFalse(bare.taken)
        assertEquals("", bare.prompt)
    }

    @Test
    fun `the take and done frames are the two flat claims`() {
        assertEquals(
            """{"t":"browser.handover.take","rid":"h1","window":"slot-a"}""",
            ClientFrames.encode(ClientMessage.BrowserHandoverTake("h1", "slot-a")),
        )
        assertEquals(
            """{"t":"browser.handover.done","rid":"h2","window":"","carryOn":true}""",
            ClientFrames.encode(ClientMessage.BrowserHandoverDone("h2", "", carryOn = true)),
        )
    }

    private companion object {
        // Written as concatenations rather than as escaped literals so that what the assertion is
        // looking for reads as a JSON key rather than as a wall of backslashes.
        const val Q = "\""
        const val QUOTED_MOUSE = Q + "mouse" + Q
        const val QUOTED_KEY = Q + "key" + Q
        const val QUOTED_TOUCH = Q + "touch" + Q
        const val QUOTED_PASTE = Q + "paste" + Q
    }
}
