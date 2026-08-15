package dev.terminaldeck.android.transport

import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.protocol.Protocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The sentences on the connection banner, and which computer they claim to be about.
 *
 * These are where the reported bug was actually read. Every one of them used to have "Mac" written
 * into it, so a phone paired to a Windows PC was told "The Mac closed the connection" and "Could not
 * reach that Mac. It may be asleep or offline." — about a tower running Windows, by an app that had
 * never been told what it was talking to and had guessed.
 *
 * Worth testing at this level rather than only through [HostPlatform]: the mapping can be perfect
 * while the noun never reaches the string. `closeReason` takes it as a required parameter precisely
 * so that a caller cannot forget, and this is the check that the parameter is used rather than
 * accepted and dropped.
 *
 * Mirrors `pwa/src/connection.test.ts`, which asks the same questions of the browser client's copy
 * of these sentences. The two clients are transcriptions of each other and drift silently
 * otherwise — the desktop is the only end that would notice, and it never sees them.
 */
class CloseReasonTest {

    private val PC = HostPlatform.WINDOWS.noun
    private val UNKNOWN = HostPlatform.UNKNOWN.noun

    /** A desktop that said `win32`. Every sentence has to follow, not just the first one. */
    @Test
    fun `a Windows machine is a PC in every sentence`() {
        assertEquals("The PC closed the connection.", closeReason(Protocol.Close.NORMAL, greeted = true, noun = PC))
        assertEquals(
            "The connection closed before the PC answered.",
            closeReason(Protocol.Close.NORMAL, greeted = false, noun = PC),
        )
        assertEquals(
            "The PC rejected a message from this app.",
            closeReason(Protocol.Close.PROTOCOL_ERROR, greeted = true, noun = PC),
        )
        assertEquals("The PC refused this device.", closeReason(Protocol.Close.POLICY_VIOLATION, greeted = true, noun = PC))
        assertEquals(
            "A message was too large for the PC to accept.",
            closeReason(Protocol.Close.MESSAGE_TOO_BIG, greeted = true, noun = PC),
        )
        assertEquals(
            "The PC asked this app to try again later.",
            closeReason(Protocol.Close.TRY_AGAIN_LATER, greeted = true, noun = PC),
        )
        assertEquals("The PC hit an internal error.", closeReason(Protocol.Close.INTERNAL_ERROR, greeted = true, noun = PC))
        assertEquals(
            "Could not reach that PC. It may be asleep or offline.",
            closeReason(4999, greeted = false, noun = PC),
        )
    }

    /**
     * The regression test: a desktop that never said what it is gets the neutral word.
     *
     * This is the case that matters most, because it is the one that used to look like it worked. A
     * build released before `welcome.hostPlatform` existed sends nothing, and the noun it produces
     * must be true of every machine rather than the specific one this app happened to be written on.
     */
    @Test
    fun `a machine that never said what it is is never called a Mac`() {
        val sentences = listOf(
            closeReason(Protocol.Close.NORMAL, greeted = true, noun = UNKNOWN),
            closeReason(Protocol.Close.NORMAL, greeted = false, noun = UNKNOWN),
            closeReason(Protocol.Close.POLICY_VIOLATION, greeted = true, noun = UNKNOWN),
            closeReason(Protocol.Close.INTERNAL_ERROR, greeted = true, noun = UNKNOWN),
            closeReason(4999, greeted = false, noun = UNKNOWN),
        )

        assertEquals("The desktop closed the connection.", sentences[0])
        assertEquals("Could not reach that desktop. It may be asleep or offline.", sentences[4])
        for (sentence in sentences) {
            assertFalse("guessed a machine: $sentence", sentence.contains("Mac"))
            assertFalse("guessed a machine: $sentence", sentence.contains("PC"))
        }
    }

    /**
     * `greeted` still changes the sentence, and still does so for both nouns.
     *
     * A close code means different things on either side of the handshake — during it, it is usually
     * the machine refusing this device; afterwards it is usually the network — and threading a noun
     * through was an easy way to lose that distinction by collapsing the two branches.
     */
    @Test
    fun `the same code says different things before and after the handshake`() {
        assertEquals("Connection lost.", closeReason(4999, greeted = true, noun = PC))
        assertEquals(
            "Could not reach that PC. It may be asleep or offline.",
            closeReason(4999, greeted = false, noun = PC),
        )
    }
}
