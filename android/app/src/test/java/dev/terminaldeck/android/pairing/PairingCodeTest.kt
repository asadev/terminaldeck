package dev.terminaldeck.android.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the pair screen is allowed to believe.
 *
 * The interesting cases are the refusals. A code arrives from a paste that picked up half a chat
 * message, or from a thumb on a keypad, and a parser that shrugs and fills in a default is one that
 * sends a single-use token somewhere else.
 *
 * This file used to be about URLs — `terminaldeck://pair#h=…&k=…&t=…`, read off a QR code or pasted.
 * Both are gone from the product: the QR did not work, and the link was a live bearer token in a
 * string. What arrives now is six digits somebody read off the machine's screen.
 */
class PairingCodeTest {

    @Test
    fun `reads six digits`() {
        assertEquals("482913", PairingCodes.parse("482913"))
        assertEquals(6, PairingCodes.CODE_LENGTH)
    }

    @Test
    fun `keeps a leading zero`() {
        /*
         * A code is six *digits*, not a number. `000042` is one the desktop mints about one time in
         * ten thousand, and anything on the path that treats it as an integer turns it into `42` —
         * which derives a different rendezvous slot from every other client and reads on screen as a
         * code that was typed correctly and found nothing.
         */
        assertEquals("000042", PairingCodes.parse("000042"))
        assertEquals("000000", PairingCodes.parse("000000"))
    }

    @Test
    fun `drops every separator something might have inserted`() {
        // The string makes a journey: read off a screen, sometimes retyped into a message, and
        // messages insert things. Refusing these would mean refusing the exact text somebody pasted.
        for (typed in listOf(" 482913 ", "482-913", "482 913", "482–913", "4 8 2 9 1 3")) {
            assertEquals("the separators in \"$typed\" should be dropped", "482913", PairingCodes.parse(typed))
        }
    }

    @Test
    fun `refuses a letter rather than folding it onto a digit`() {
        /*
         * The eight-character format this replaced folded `O` onto `0` and `I`/`L` onto `1`, because
         * the screen was showing letters and three of them are misread. The screen shows digits now,
         * so a letter is a typo — and folding a typo produces a *different valid code*, six
         * characters that read cleanly and belong to somebody else's pairing.
         */
        assertNull(PairingCodes.parse("O82913"))
        assertNull(PairingCodes.parse("48291I"))
        assertNull(PairingCodes.parse("H4K9-2FQT"))
        assertNull(PairingCodes.parse("terminaldeck://pair#h=AXGK7VAEYZHKTTVUKZ4U9HZQ7J"))
    }

    @Test
    fun `refuses anything that is not six digits`() {
        assertNull(PairingCodes.parse(""))
        assertNull(PairingCodes.parse("48291"))
        assertNull(PairingCodes.parse("4829131"))
        assertNull(PairingCodes.parse("------"))
    }

    @Test
    fun `does not walk a hostile paste`() {
        // Bounded before the scan, and it stops the moment there are too many digits. Neither is a
        // security boundary; both are what keeps a pasted megabyte off the main thread.
        assertNull(PairingCodes.parse("1".repeat(1_000_000)))
        assertEquals("482913", PairingCodes.parse("482913" + " ".repeat(1_000)))
    }

    @Test
    fun `knows a host id from the relay's alphabet`() {
        assertEquals(true, PairingCodes.isHostId("AXGK7VAEYZHKTTVUKZ4U9HZQ7J"))
        // `I`, `O`, `0` and `1` are not in the relay's base32, so anything carrying one is not a
        // host id — it was mistyped, or it came from somewhere else.
        assertEquals(false, PairingCodes.isHostId("IXGK7VAEYZHKTTVUKZ4U9HZQ7J"))
        assertEquals(false, PairingCodes.isHostId("AXGK7VAEYZHKTTVUKZ4U9HZQ7"))
    }

    @Test
    fun `refuses a relay that is not a websocket address`() {
        assertEquals(true, PairingCodes.isRelayUrl("wss://relay.terminaldeck.dev"))
        // `ws://` is allowed on purpose — the development relay has no certificate — and everything
        // inside the channel is sealed before it reaches the socket either way.
        assertEquals(true, PairingCodes.isRelayUrl("ws://10.0.2.2:8787"))
        assertEquals(false, PairingCodes.isRelayUrl("http://example.com"))
        assertEquals(false, PairingCodes.isRelayUrl("javascript:alert(1)"))
        assertEquals(false, PairingCodes.isRelayUrl("wss://relay with a space"))
    }
}
