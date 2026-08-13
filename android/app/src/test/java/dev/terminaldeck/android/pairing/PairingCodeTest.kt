package dev.terminaldeck.android.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the pair screen is allowed to believe.
 *
 * The interesting cases are the refusals. A code arrives from a camera pointed at whatever was in
 * front of it, or from a paste that picked up half a chat message, and a parser that shrugs and
 * fills in a default is one that sends a single-use token to an address someone else chose.
 */
class PairingCodeTest {

    private val hostId = "AXGK7VAEYZHKTTVUKZ4U9HZQ7J"
    private val key = ByteArray(32) { it.toByte() }
    private val keyText = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(key)
    private val token = "CoMPf6VplfGUZlG-3zFJ3zFWufYzi-U1AYlqBiKsUUk"

    private fun link(prefix: String = "terminaldeck://pair#", relay: String? = null): String =
        buildString {
            append(prefix)
            append("h=$hostId&k=$keyText&t=$token")
            if (relay != null) append("&r=$relay")
        }

    @Test
    fun `reads the shape the desktop prints`() {
        val code = PairingCodes.parse(link(relay = "ws%3A%2F%2F10.0.2.2%3A8787"))
        checkNotNull(code)
        assertEquals(hostId, code.hostId)
        assertArrayEquals(key, code.hostStaticPublicKey)
        assertEquals(token, code.token)
        assertEquals("ws://10.0.2.2:8787", code.relayUrl)
    }

    @Test
    fun `takes an https link, a query string and a bare blob`() {
        val expected = PairingCodes.parse(link())
        assertEquals(expected, PairingCodes.parse(link(prefix = "https://terminaldeck.dev/pair#")))
        assertEquals(expected, PairingCodes.parse(link(prefix = "terminaldeck://pair?")))
        assertEquals(expected, PairingCodes.parse(link(prefix = "")))
        assertEquals(expected, PairingCodes.parse("  ${link()}\n"))
    }

    @Test
    fun `a code with no relay leaves the choice to the app`() {
        assertNull(PairingCodes.parse(link())?.relayUrl)
    }

    @Test
    fun `refuses anything that is not a code`() {
        assertNull(PairingCodes.parse(""))
        assertNull(PairingCodes.parse("hello"))
        assertNull(PairingCodes.parse("https://terminaldeck.dev/"))
        // Missing each field in turn.
        assertNull(PairingCodes.parse("k=$keyText&t=$token"))
        assertNull(PairingCodes.parse("h=$hostId&t=$token"))
        assertNull(PairingCodes.parse("h=$hostId&k=$keyText"))
    }

    @Test
    fun `refuses a host id in the wrong alphabet or the wrong length`() {
        // `I`, `O`, `0` and `1` are not in the relay's base32 alphabet, so a code containing one
        // was mistyped or is not a host id at all.
        assertNull(PairingCodes.parse("h=IXGK7VAEYZHKTTVUKZ4U9HZQ7J&k=$keyText&t=$token"))
        assertNull(PairingCodes.parse("h=AXGK7VAEYZHKTTVUKZ4U9HZQ7&k=$keyText&t=$token"))
        assertNull(PairingCodes.parse("h=${hostId}A&k=$keyText&t=$token"))
    }

    @Test
    fun `refuses a key that is not 32 bytes`() {
        val short = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(31))
        assertNull(PairingCodes.parse("h=$hostId&k=$short&t=$token"))
        assertNull(PairingCodes.parse("h=$hostId&k=not-base64!!&t=$token"))
    }

    @Test
    fun `refuses a token with whitespace or control characters in it`() {
        assertNull(PairingCodes.parse("h=$hostId&k=$keyText&t="))
        assertNull(PairingCodes.parse("h=$hostId&k=$keyText&t=one two"))
        assertNull(PairingCodes.parse("h=$hostId&k=$keyText&t=${"x".repeat(201)}"))
    }

    @Test
    fun `refuses a relay that is not a websocket address`() {
        assertNull(PairingCodes.parse(link(relay = "http%3A%2F%2Fexample.com")))
        assertNull(PairingCodes.parse(link(relay = "javascript%3Aalert(1)")))
    }

    /**
     * A code carrying two of the same parameter is not one this project produced, and picking
     * either value would be picking one an attacker appended.
     */
    @Test
    fun `refuses a repeated parameter rather than choosing a winner`() {
        assertNull(PairingCodes.parse("h=$hostId&k=$keyText&t=$token&t=other"))
    }

    @Test
    fun `the fingerprint shown next to the code is the Mac's`() {
        val code = checkNotNull(PairingCodes.parse(link()))
        assertEquals(dev.terminaldeck.android.crypto.Sealed.fingerprint(key), code.hostFingerprint)
    }
}
