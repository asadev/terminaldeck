package dev.terminaldeck.android.signin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The seam: what a server **prints**, read by what this app **runs**.
 *
 * ## Why this is separate from `ServerAddressTest`
 *
 * Because that file is thorough, was green throughout, and this parser still refused every real
 * address. Its fixtures are assembled from the three facts — the right instinct, and still an
 * assembly from *that file's idea* of the encoding. It spells a `td1` prefix, which is this
 * client's own readable line and not what a server writes. Meanwhile `formatServerAddress` emits
 * `srv1.` in front of the base64, `Base64.getDecoder()` throws on the `.`, and the Add-a-server
 * screen answered "that does not look like a server address" for the only string a server emits.
 *
 * So the rule here is the one that could have caught it: **no address in this file was typed by a
 * person.** Every string under test comes from [ServerAddressFixture.PRINTED_BY_A_HOST], which is
 * generated from the encoder itself and re-checked against it on every `vitest run` by
 * `src/shared/server-address-fixture.test.ts`. A hand-typed fixture is what let this bug exist, so
 * a hand-typed fixture cannot be what pins the fix.
 */
class ServerAddressSeamTest {

    /** The real encoder's real output. Generated — see that file's own header. */
    private val printed = ServerAddressFixture.PRINTED_BY_A_HOST

    private fun ok(raw: String): ServerAddress = when (val result = ServerAddress.parse(raw)) {
        is ServerAddress.Companion.Result.Ok -> result.address
        is ServerAddress.Companion.Result.Bad ->
            throw AssertionError("this app refused the address a server prints: ${result.sentence}")
    }

    private fun bad(raw: String): String = when (val result = ServerAddress.parse(raw)) {
        is ServerAddress.Companion.Result.Bad -> result.sentence
        is ServerAddress.Companion.Result.Ok -> throw AssertionError("accepted ${result.address}")
    }

    private fun expectTheFixtureMachine(raw: String) {
        val address = ok(raw)
        assertEquals(ServerAddressFixture.RELAY_URL, address.relayUrl)
        assertEquals(ServerAddressFixture.HOST_ID, address.hostId)
        // The bytes, not the spelling. The key inside that token is base64url and contains both `-`
        // and `_` — the pair a decoder that folds the alphabet wrongly drops, leaving a key two
        // bytes short and a handshake that fails with nothing on screen to explain it.
        assertTrue(
            "the key did not survive the decode",
            ServerAddressFixture.HOST_KEY.contentEquals(address.hostKey),
        )
    }

    /* ------------------------------------------------------------------ the address -- */

    @Test
    fun `the generated fixture announces the version this build reads`() {
        assertTrue(printed, printed.startsWith("srv${ServerAddress.VERSION}."))
    }

    @Test
    fun `the address a server prints is accepted`() {
        expectTheFixtureMachine(printed)
    }

    /* ------------------------------------------- the ways it survives being moved by hand -- */

    @Test
    fun `with the newline a terminal paste brings`() {
        expectTheFixtureMachine("  $printed\n")
    }

    /**
     * The paste this parser's loose reader exists for: what `renderAddress` in
     * `src/headless/cli.ts` puts on a console, selected with a finger — heading and closing
     * sentences included.
     */
    @Test
    fun `inside the block a console prints around it`() {
        val block = buildString {
            appendLine("Server address")
            appendLine()
            appendLine("  $printed")
            appendLine()
            appendLine("  Paste it into the app on a phone or another computer: Add a server, then")
            appendLine("  sign in with a username and password or key this machine already accepts.")
            appendLine()
            appendLine("  This address is not a secret. It holds a public key and a public name at a")
            appendLine("  relay, and it grants nothing on its own.")
        }
        expectTheFixtureMachine(block)
    }

    /**
     * A terminal that wrapped one long token at eighty columns.
     *
     * Also the case that proves every candidate is tried rather than the first taken: line one is
     * `srv1.` and seventy-five characters of body, which is a token by every rule this parser has
     * and decodes to nothing.
     */
    @Test
    fun `wrapped at eighty columns`() {
        expectTheFixtureMachine(printed.chunked(80).joinToString("\n"))
    }

    @Test
    fun `with the quotes a copy takes with it`() {
        expectTheFixtureMachine("\"$printed\"")
        expectTheFixtureMachine("<$printed>")
    }

    /* --------------------------------------------------------- what it cannot read -- */

    /**
     * Base64 decoding ignores what it does not recognise, so a shortened token decodes to
     * *something*. Refused, not half-read into an address that dials nothing.
     */
    @Test
    fun `a token whose tail a selection left behind`() {
        assertTrue(bad(printed.dropLast(6)).isNotEmpty())
    }

    /**
     * The whole point of a version in the prefix. An address from a newer server is a diagnosable
     * situation — update this app — and it must not arrive as the sentence a line of prose gets,
     * which sends somebody back to a clipboard that was never the problem.
     */
    @Test
    fun `an address from a newer server names the version`() {
        val future = "srv${ServerAddress.VERSION + 1}." + printed.substringAfter('.')
        val sentence = bad(future)
        assertTrue(sentence, sentence.contains("version ${ServerAddress.VERSION + 1}"))
        assertTrue(sentence, sentence.contains("older than that server"))
    }

    @Test
    fun `the same inside a block`() {
        val future = "srv9." + printed.substringAfter('.')
        val sentence = bad("Server address\n  $future\n\n  Paste it into the app.")
        assertTrue(sentence, sentence.contains("older than that server"))
    }

    /** A full stop in ordinary prose is not a version announcement. */
    @Test
    fun `prose is not a version announcement`() {
        for (text in listOf("srv1.", "srv2.zip", "the file is at srv1.example.com/thing")) {
            assertTrue(text, bad(text).isNotEmpty())
            assertTrue(text, !bad(text).contains("older than"))
        }
    }

    /** A paste that also held something readable was never a version problem. */
    @Test
    fun `a readable address beats a foreign token in the same paste`() {
        val future = "srv9." + printed.substringAfter('.')
        expectTheFixtureMachine("$future\n$printed")
    }
}
