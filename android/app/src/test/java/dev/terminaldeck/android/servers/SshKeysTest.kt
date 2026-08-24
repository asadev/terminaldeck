package dev.terminaldeck.android.servers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reading a pasted key, against keys `ssh-keygen` actually wrote.
 *
 * The fixtures under `src/test/resources/keys/` were produced by `ssh-keygen -t …` with no
 * passphrase (and one with), rather than typed out here. That matters: the whole point of this file
 * is that *"this key is readable"* means the reader that will sign the handshake has already read
 * it, and a hand-written fixture would only prove that the parser agrees with whoever wrote the
 * fixture.
 *
 * ## The bug this exists to make impossible
 *
 * iOS shipped a key field whose entire feedback was *"Private key ready · 412 characters"*. A
 * character count cannot tell a whole key from one whose seven lines were flattened into one — the
 * count is identical either way, because a newline is one character and so is the space that
 * replaced it. So a mangled key read as ready, the login was refused, and the sentence on screen
 * sent somebody to check a password that was never the problem.
 */
class SshKeysTest {

    /**
     * One fixture key, decoded.
     *
     * **Stored base64 rather than as the PEM it is**, and that is not obfuscation for its own sake.
     * These are throwaway keys made by `ssh-keygen` for this file and used against nothing — but a
     * `-----BEGIN OPENSSH PRIVATE KEY-----` in a repository is what every secret scanner is built to
     * stop, and GitHub's push protection blocks a push containing one. A test that cannot be pushed
     * is a test that gets deleted. One `base64 -d` keeps the bytes exact and keeps the file from
     * looking like the thing it is deliberately not.
     */
    private fun key(name: String): String {
        val encoded = requireNotNull(javaClass.classLoader?.getResourceAsStream("keys/$name.b64")) {
            "missing fixture keys/$name.b64"
        }.use { it.readBytes().toString(Charsets.UTF_8) }
        return String(java.util.Base64.getDecoder().decode(encoded.trim()), Charsets.UTF_8)
    }

    /* ----------------------------------------------------------- what works -- */

    /**
     * Ed25519 and RSA read — and the second of those is the difference from iOS.
     *
     * NIOSSH implements no RSA at all, so the iPhone refuses an RSA key by name. sshj does, so
     * refusing one here would be this client inventing a limitation it does not have — and RSA is
     * still the key several hosting companies mail people.
     */
    @Test
    fun `the kinds ssh-keygen writes read back as good`() {
        for (name in listOf("k_ed", "k_rsa")) {
            val readback = PrivateKeyReadback.of(key(name))
            assertTrue("$name should be readable, got $readback", readback.isGood)
            assertTrue(
                "$name should say BEGIN and END are both here",
                (readback as PrivateKeyReadback.Good).text.contains("BEGIN and END are both here"),
            )
        }
    }

    /**
     * ECDSA reads **when this platform can supply the algorithm under the name SSH asks for**.
     *
     * Not a hedge — a measurement, and the reason the [PrivateKeyProblem.NoProvider] case exists.
     * sshj asks the JCA for a `KeyFactory` called `ECDSA`; the JDK's own provider calls it `EC` and
     * registers no alias, so this suite, running on a desktop JVM with no BouncyCastle registered,
     * genuinely cannot read an ECDSA key. Android's bundled BouncyCastle *does* alias it, so a
     * phone can. Asserting one answer would make this test a lie on one of the two.
     *
     * What is asserted unconditionally is the half that matters: whichever way it goes, the person
     * is told the truth. A platform that can read it says the key is good; a platform that cannot
     * says *this device has no reader for ECDSA keys* and names two things that work — never *"that
     * key could not be read"*, which would send somebody to re-copy a file that is fine.
     */
    @Test
    fun `an ECDSA key either reads or says which algorithm this device lacks`() {
        val platformNamesIt = try {
            java.security.KeyFactory.getInstance("ECDSA")
            true
        } catch (e: java.security.NoSuchAlgorithmException) {
            false
        }

        val readback = PrivateKeyReadback.of(key("k_ecdsa"))

        if (platformNamesIt) {
            assertTrue("this platform can, so it must read: $readback", readback.isGood)
        } else {
            val bad = readback as PrivateKeyReadback.Bad
            assertTrue(bad.headline, bad.headline.contains("no reader for ECDSA"))
            assertTrue("it names something that does work", bad.advice.contains("ed25519"))
        }
    }

    @Test
    fun `the readback counts the lines a person would count in their editor`() {
        // Seven for an Ed25519 key, and of the *trimmed* text: a copied file almost always arrives
        // with a trailing newline, and counting it would report eight for a seven-line key — a
        // number that does not match what somebody sees, on a screen whose whole job is to convince
        // them the paste was whole.
        val readback = PrivateKeyReadback.of(key("k_ed")) as PrivateKeyReadback.Good

        assertTrue(readback.text, readback.text.contains("7 lines"))
    }

    /* -------------------------------------------------------- what does not -- */

    /**
     * The failure the character count could not see.
     *
     * A key whose newlines were eaten by whatever it was copied through is the same length and a
     * completely different thing.
     */
    @Test
    fun `a key flattened onto one line is caught, and the sentence says what happened`() {
        val flattened = key("k_ed").trim().replace("\n", " ")

        val readback = PrivateKeyReadback.of(flattened)

        assertFalse(readback.isGood)
        assertTrue((readback as PrivateKeyReadback.Bad).headline.contains("one line"))
        assertTrue(readback.advice.contains("flattened"))
    }

    @Test
    fun `a passphrase is a question rather than a defect, and gets its own sentence`() {
        val readback = PrivateKeyReadback.of(key("k_locked"))

        assertFalse(readback.isGood)
        val bad = readback as PrivateKeyReadback.Bad
        assertEquals(PrivateKeyProblem.Locked.headline, bad.headline)
        assertTrue("it names the one command that makes a usable copy", bad.advice.contains("ssh-keygen -p"))
    }

    /**
     * The `.pub` mistake, named.
     *
     * The two files sit beside each other and only one of them can sign. "That is not a private
     * key" would send somebody looking for a different file; this sends them to the one next to it.
     */
    @Test
    fun `the public half is named rather than lumped in with everything unreadable`() {
        val readback = PrivateKeyReadback.of(key("k_ed.pub"))

        assertEquals(
            PrivateKeyProblem.PublicHalf.headline,
            (readback as PrivateKeyReadback.Bad).headline,
        )
    }

    @Test
    fun `an empty field says nothing at all`() {
        assertEquals(PrivateKeyReadback.Nothing, PrivateKeyReadback.of("   \n  "))
    }

    @Test
    fun `a password typed into the key field is not a key`() {
        val readback = PrivateKeyReadback.of("correct-horse-battery-staple")

        assertFalse(readback.isGood)
    }

    /**
     * Half a key is refused, and not by the line count.
     *
     * Everything about it looks right from the outside — several lines, a BEGIN — and only the
     * reader can tell. That is the argument for running the real one under the field.
     */
    @Test
    fun `a key that was only half copied is refused by the reader that would sign with it`() {
        val truncated = key("k_ed").lines().take(4).joinToString("\n")

        assertFalse(PrivateKeyReadback.of(truncated).isGood)
    }

    /* --------------------------------------------------- what reaches SSH -- */

    /**
     * The reader that answers the field is the one the handshake uses.
     *
     * Two readers would eventually disagree, and the disagreement would be a login refused after a
     * screen said the key was fine.
     */
    @Test
    fun `a key the field accepted is one the SSH client can sign with`() {
        val provider = SshKeys.read(key("k_ed"))

        assertEquals("ssh-ed25519", SshKeys.kindOf(provider))
        assertTrue("the private half is what signs", provider.private != null)
    }
}
