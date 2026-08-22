package dev.terminaldeck.android.signin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a person can paste into the Add-a-server field, and what has to be refused.
 *
 * The two halves are equally load bearing. A parser that is too strict is a screen that refuses the
 * exact string the server printed, because it came through an email that wrapped it — and the
 * person has no way to tell which of the two ends is wrong. A parser that guesses is worse: a host
 * id it "corrected" is a different server, and a key it filled in from anywhere is the trust-on-
 * first-use this product does not do.
 *
 * So every shape below is one an address genuinely arrives in, and every refusal names the fact that
 * was missing rather than saying "invalid".
 */
class ServerAddressTest {

    private companion object {
        const val HOST = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val RELAY = "wss://relay.terminaldeck.dev"
    }

    /** 32 bytes, the size of an X25519 static public key, and never accidentally the right size. */
    private val key = ByteArray(32) { (it * 7 + 3).toByte() }
    private val base64Url = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(key)
    private val base64Std = java.util.Base64.getEncoder().encodeToString(key)

    private fun ok(raw: String): ServerAddress {
        return when (val result = ServerAddress.parse(raw)) {
            is ServerAddress.Companion.Result.Ok -> result.address
            is ServerAddress.Companion.Result.Bad -> throw AssertionError("refused: ${result.sentence}")
        }
    }

    private fun bad(raw: String): String {
        return when (val result = ServerAddress.parse(raw)) {
            is ServerAddress.Companion.Result.Bad -> result.sentence
            is ServerAddress.Companion.Result.Ok -> throw AssertionError("accepted ${result.address}")
        }
    }

    /* ------------------------------------------------------------------- shapes -- */

    @Test
    fun `the canonical line round-trips`() {
        val address = ServerAddress(RELAY, HOST, key)
        val line = ServerAddress.format(address)
        assertEquals("td1 $RELAY $HOST $base64Url", line)
        assertEquals(address, ok(line))
    }

    /**
     * The one that matters most in the field: a line that has been through something.
     *
     * Wrapped by an email client, indented by a terminal, quoted by a chat app. The three facts are
     * still all there, and a person who can see them on their screen will not accept being told the
     * address is invalid.
     */
    @Test
    fun `a wrapped and quoted paste still reads`() {
        val messy = "  \"td1\n   $RELAY\n   $HOST\n   $base64Url\"  "
        assertEquals(ServerAddress(RELAY, HOST, key), ok(messy))
    }

    /** A labelled block — what a status page prints, and what somebody copies out of one. */
    @Test
    fun `a labelled block reads`() {
        val block = """
            relay        $RELAY
            host id      $HOST
            key          $base64Url
        """.trimIndent()
        assertEquals(ServerAddress(RELAY, HOST, key), ok(block))
    }

    @Test
    fun `a url reads, percent-encoded relay and all`() {
        val encoded = "terminaldeck://server?r=wss%3A%2F%2Frelay.terminaldeck.dev&h=$HOST&k=$base64Url"
        assertEquals(ServerAddress(RELAY, HOST, key), ok(encoded))
    }

    /**
     * The JSON a browser client stores, field for field.
     *
     * `pwa/src/endpoint.ts`'s `asEndpoint` reads exactly this object, which is why it is the shape
     * this parser was written against: one blob, readable by every client in the product.
     */
    @Test
    fun `the stored endpoint json reads`() {
        val json = """{"kind":"relay","url":"$RELAY","hostId":"$HOST","hostKey":"$base64Url"}"""
        assertEquals(ServerAddress(RELAY, HOST, key), ok(json))
    }

    /** And the same object under the names a rendezvous offer uses for the same three fields. */
    @Test
    fun `an offer-shaped json reads`() {
        val json = """{"t":"machine","relayUrl":"$RELAY","hostId":"$HOST","publicKey":"$base64Std"}"""
        assertEquals(ServerAddress(RELAY, HOST, key), ok(json))
    }

    @Test
    fun `base64 of the json reads, with or without the tag`() {
        val json = """{"url":"$RELAY","hostId":"$HOST","hostKey":"$base64Url"}"""
        val blob = java.util.Base64.getEncoder().encodeToString(json.toByteArray())
        assertEquals(ServerAddress(RELAY, HOST, key), ok(blob))
        assertEquals(ServerAddress(RELAY, HOST, key), ok("td1:$blob"))
    }

    /**
     * Both alphabets of the same 32 bytes.
     *
     * The product encodes a key two ways — base64url in anything printed, standard base64 in a
     * rendezvous offer — and handling one and not the other is a server that signs in and a server
     * that does not, intermittently, for no reason a person could discover.
     */
    @Test
    fun `either base64 alphabet decodes to the same key`() {
        assertEquals(ok("td1 $RELAY $HOST $base64Url"), ok("td1 $RELAY $HOST $base64Std"))
    }

    @Test
    fun `a lowercase host id is read as the host id it is`() {
        assertEquals(HOST, ok("$RELAY ${HOST.lowercase()} $base64Url").hostId)
    }

    @Test
    fun `a trailing slash on the relay is dropped, because it is the same relay`() {
        assertEquals(RELAY, ok("td1 $RELAY/ $HOST $base64Url").relayUrl)
    }

    @Test
    fun `ws is allowed as well as wss, for a relay running on somebody's laptop`() {
        assertEquals("ws://192.168.1.9:8787", ok("ws://192.168.1.9:8787 $HOST $base64Url").relayUrl)
    }

    /* ---------------------------------------------------------------- refusals -- */

    @Test
    fun `an empty field asks for a paste rather than complaining`() {
        assertTrue(bad("   ").contains("Paste"))
    }

    @Test
    fun `a host id alone is refused, and the refusal names the key`() {
        // The whole argument for carrying the key: an id is a hash, so nothing can be derived from
        // it, and fetching the key from the relay is asking the attacker for the fingerprint.
        val sentence = bad("$RELAY $HOST")
        assertTrue(sentence, sentence.contains("key"))
    }

    @Test
    fun `an address with no relay in it says so`() {
        assertTrue(bad("$HOST $base64Url").contains("relay"))
    }

    @Test
    fun `an address with no host id in it says so`() {
        assertTrue(bad("$RELAY $base64Url").contains("host id"))
    }

    /** A key of the wrong length is not a key. It is refused, never padded or truncated. */
    @Test
    fun `a key that is not 32 bytes is refused`() {
        val short = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(31))
        assertTrue(bad("$RELAY $HOST $short").contains("32 bytes"))
    }

    /**
     * A host id with one wrong character is a wrong host id, not one to correct.
     *
     * The alphabet has no confusable glyphs in it — no 0/O, no 1/I — precisely so that a wrong
     * character can be treated as wrong. Folding it would silently name a different slot at the
     * relay, which is a connection attempt against somebody else's machine.
     */
    @Test
    fun `a host id with an excluded letter in it is refused, not folded`() {
        val withO = HOST.replaceRange(0, 1, "O")
        assertTrue(bad("$RELAY $withO $base64Url").contains("host id"))
    }

    @Test
    fun `an http url is not a relay address`() {
        assertTrue(bad("https://relay.terminaldeck.dev $HOST $base64Url").contains("relay"))
    }

    @Test
    fun `prose is refused with the sentence that says what an address is made of`() {
        val sentence = bad("hey can you get on my server, it is the one in frankfurt")
        assertTrue(sentence, sentence.contains("26-character host id"))
    }

    /** Bounded before it is scanned: a paste of a log file gets a sentence, not a walk. */
    @Test
    fun `an enormous paste is refused rather than scanned`() {
        val huge = "x".repeat(ServerAddress.MAX_INPUT_CHARS * 4)
        assertTrue(bad(huge).isNotEmpty())
    }
}
