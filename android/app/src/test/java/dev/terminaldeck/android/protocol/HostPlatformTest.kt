package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What kind of machine the desktop said it is, and what this app is then allowed to call it.
 *
 * The bug being pinned: a phone paired to a Windows PC read "Send a photo, video or file to the
 * Mac". Nothing was wrong on the wire — the desktop had never said what it was, so the noun was a
 * string constant compiled into this app, and the constant said Mac.
 *
 * Two of the cases below are the whole requirement and the rest are supporting detail:
 *
 *  - `win32` must produce **PC**, or the field is being carried and ignored;
 *  - **absent** must produce **desktop**, or the fix has simply moved the guess.
 *
 * The second is the one worth being strict about. Every desktop released before
 * `welcome.hostPlatform` existed sends nothing, those desktops are still out there, and a fallback
 * of `MAC` would reproduce the original defect exactly while looking like it had been fixed.
 */
class HostPlatformTest {

    @Test
    fun `a desktop that says win32 is a PC`() {
        assertEquals(HostPlatform.WINDOWS, HostPlatform.fromWire("win32"))
        assertEquals("PC", HostPlatform.fromWire("win32").noun)
    }

    /**
     * The regression test for the original bug, stated as the thing a user would read.
     *
     * A desktop old enough to send no platform at all is not a Mac, is not a PC, and must not be
     * called either. "desktop" is true of every machine this app can reach.
     */
    @Test
    fun `a welcome with no platform at all is a desktop, never a Mac`() {
        assertEquals(HostPlatform.UNKNOWN, HostPlatform.fromWire(null))
        assertEquals("desktop", HostPlatform.fromWire(null).noun)
    }

    @Test
    fun `the other two platforms Electron ships on`() {
        assertEquals(HostPlatform.MAC, HostPlatform.fromWire("darwin"))
        assertEquals("Mac", HostPlatform.fromWire("darwin").noun)
        assertEquals(HostPlatform.LINUX, HostPlatform.fromWire("linux"))
        assertEquals("machine", HostPlatform.fromWire("linux").noun)
    }

    /**
     * Anything unrecognised joins the absent case rather than getting its own.
     *
     * A BSD, a platform that does not exist yet, a truncated field, an empty string, or a desktop
     * that has been tampered with on the way through: all of them are still a computer worth showing
     * sessions for, and none of them is a machine this build can name. The one answer this must
     * never fall to is the specific one.
     */
    @Test
    fun `anything else is unknown, and unknown is never the specific word`() {
        for (wire in listOf("freebsd", "", "  ", "Darwin", "WIN32", "win32 ", "mac", "PC", "android")) {
            assertEquals("'$wire' must not be recognised", HostPlatform.UNKNOWN, HostPlatform.fromWire(wire))
        }
    }

    /**
     * Deliberately case-sensitive, spelled out as its own expectation.
     *
     * `Darwin` above is not padding. These are literals produced by Node's `process.platform`, not
     * user input, and a lenient match here would be this client inventing a second, looser wire
     * vocabulary the desktop never agreed to — the kind of leniency that hides a genuine protocol
     * mismatch behind a screen that looks right.
     */
    @Test
    fun `the wire words are matched exactly`() {
        assertEquals(HostPlatform.MAC, HostPlatform.fromWire("darwin"))
        assertEquals(HostPlatform.UNKNOWN, HostPlatform.fromWire("Darwin"))
    }

    /**
     * The nouns compose without an article of their own.
     *
     * Every call site writes `"the $noun"` or `"a $noun"`, so a noun that carried "the" would read
     * "the the Mac" in some sentences and be silently wrong in the rest.
     */
    @Test
    fun `a noun drops into a sentence`() {
        assertEquals(
            listOf(
                "That session is no longer on the Mac.",
                "That session is no longer on the PC.",
                "That session is no longer on the machine.",
                "That session is no longer on the desktop.",
            ),
            HostPlatform.entries.map { "That session is no longer on the ${it.noun}." },
        )
    }

    /* ------------------------------------------------------------------ on the wire -- */

    /**
     * The field survives the decoder, and its absence survives it too.
     *
     * Worth asserting separately from [HostPlatform.fromWire]: the mapping can be perfect while the
     * JSON never reaches it. `hostPlatform` is additive rather than a protocol bump, so what makes
     * an older desktop keep working is the default on the field plus `ignoreUnknownKeys` — and a
     * `welcome` without a platform has to *decode*, not be refused as a bad frame.
     *
     * Driven through [ServerFrames.parse] rather than a `Json` built here, because that is the only
     * door frames actually come through and a bespoke decoder in a test can be configured into
     * agreeing with whatever the test wants.
     */
    @Test
    fun `a welcome carries the platform, and one without it still parses`() {
        val windows = welcome(
            """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Pixel","token":null,""" +
                """"sessions":[],"hostPlatform":"win32"}"""
        )
        assertEquals("win32", windows.hostPlatform)
        assertEquals("PC", HostPlatform.fromWire(windows.hostPlatform).noun)

        val older = welcome(
            """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Pixel","token":null,"sessions":[]}"""
        )
        assertEquals(null, older.hostPlatform)
        assertEquals("desktop", HostPlatform.fromWire(older.hostPlatform).noun)
    }

    private fun welcome(raw: String): ServerMessage.Welcome {
        val result = ServerFrames.parse(raw)
        val ok = result as? ServerFrames.Result.Ok ?: throw AssertionError("did not parse: $result")
        return ok.message as ServerMessage.Welcome
    }
}
