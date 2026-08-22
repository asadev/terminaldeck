package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The version arithmetic the "update this server from a desktop" sentence hangs on.
 *
 * Mirrors `pwa/src/host-version.ts`; the risk is not that a comparison can be written but that this
 * copy and the browser's disagree about whether a phone is ahead — which would show the nudge on one
 * client and not the other for the same pair of builds.
 */
class HostVersionTest {

    @Test
    fun `release segments compare left to right with a missing one as zero`() {
        assertTrue(HostVersion.compare("0.10.0", "0.9.9") > 0)
        assertTrue(HostVersion.compare("0.9.0", "0.10.0") < 0)
        assertEquals(0, HostVersion.compare("1.2.3", "1.2.3"))
        assertEquals(0, HostVersion.compare("1.2", "1.2.0"))
        assertTrue(HostVersion.compare("v0.10.0", "0.10.0") == 0)
    }

    @Test
    fun `a prerelease sorts below the release it belongs to`() {
        assertTrue(HostVersion.compare("1.0.0-beta", "1.0.0") < 0)
        assertTrue(HostVersion.compare("1.0.0", "1.0.0-beta") > 0)
        assertTrue(HostVersion.compare("1.0.0-alpha", "1.0.0-beta") < 0)
        assertTrue(HostVersion.compare("1.0.0-alpha.1", "1.0.0-alpha.2") < 0)
        // Numeric identifiers rank below alphanumeric ones.
        assertTrue(HostVersion.compare("1.0.0-1", "1.0.0-alpha") < 0)
        // Build metadata takes no part in precedence.
        assertEquals(0, HostVersion.compare("1.0.0+abc", "1.0.0+def"))
    }

    @Test
    fun `ahead is default-closed unless both numbers are real and the client is strictly greater`() {
        assertTrue(HostVersion.clientIsAhead("0.10.0", "0.9.0"))
        assertFalse(HostVersion.clientIsAhead("0.9.0", "0.10.0"))
        assertFalse(HostVersion.clientIsAhead("0.10.0", "0.10.0"))
        // A non-answer on either side manufactures no verdict.
        assertFalse(HostVersion.clientIsAhead("0.10.0", ""))
        assertFalse(HostVersion.clientIsAhead("", "0.9.0"))
        assertFalse(HostVersion.clientIsAhead("unknown", "0.9.0"))
        assertFalse(HostVersion.clientIsAhead("0.10.0", "unknown"))
    }

    @Test
    fun `the kind noun is server for headless and desktop for desktop and nothing for the rest`() {
        assertEquals("server", HostVersion.hostKindNoun("headless"))
        assertEquals("desktop", HostVersion.hostKindNoun("desktop"))
        assertNull(HostVersion.hostKindNoun(null))
        assertNull(HostVersion.hostKindNoun("something-else"))
    }

    @Test
    fun `the version line names the kind when there is one and draws nothing without a version`() {
        assertEquals("version 0.10.0 · server", HostVersion.hostVersionLine("0.10.0", "headless"))
        assertEquals("version 0.10.0 · desktop", HostVersion.hostVersionLine("0.10.0", "desktop"))
        assertEquals("version 0.10.0", HostVersion.hostVersionLine("0.10.0", null))
        assertEquals("", HostVersion.hostVersionLine("", "headless"))
    }

    @Test
    fun `the behind sentence appears only when ahead and names the right kind of box`() {
        val server = HostVersion.behindSentence("0.10.0", "0.9.0", "headless")
        assertTrue(server != null && server.contains("server"))
        val desktop = HostVersion.behindSentence("0.10.0", "0.9.0", "desktop")
        assertTrue(desktop != null && desktop.contains("desktop"))
        // Not ahead: nothing to say.
        assertNull(HostVersion.behindSentence("0.9.0", "0.10.0", "headless"))
        assertNull(HostVersion.behindSentence("0.10.0", "", "headless"))
    }
}
