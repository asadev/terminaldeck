package dev.terminaldeck.android.servers

import net.schmizz.sshj.common.Factory
import net.schmizz.sshj.userauth.keyprovider.FileKeyProvider
import net.schmizz.sshj.userauth.keyprovider.KeyFormat
import net.schmizz.sshj.userauth.keyprovider.KeyProvider
import net.schmizz.sshj.userauth.keyprovider.KeyProviderUtil
import net.schmizz.sshj.userauth.password.PasswordFinder
import net.schmizz.sshj.userauth.password.Resource

/**
 * Reading a private key somebody pasted, and saying honestly when it cannot be used.
 *
 * A port of `ios/TerminalDeck/Servers/SSHKeys.swift`, and deliberately a *shorter* one, because
 * the two libraries can do different things and the sentences have to be true about this one.
 * NIOSSH implements Ed25519 and the three NIST curves and nothing else, so iOS refuses RSA and DSA
 * by name. sshj implements RSA, DSA, ECDSA and Ed25519, in `openssh-key-v1`, PKCS#8, the old PEM
 * shapes and PuTTY's `.ppk`. So the only refusals left here are the ones that are about the *key*
 * rather than about the client:
 *
 *  - **A key with a passphrase on it.** Nothing on this screen can ask the server for a passphrase
 *    on somebody's behalf. This is a question rather than a defect, and it gets its own sentence.
 *  - **The public half.** The two files sit beside each other, only one of them can sign, and
 *    picking the wrong one is the mistake worth naming rather than reporting as "not a key".
 *  - **Something that is not a key at all**, including the paste that arrived as one line.
 *
 * ## What it never does
 *
 * It never logs, prints or returns the key material. What leaves here is a [KeyProvider] or a
 * sentence.
 *
 * ## Why the reader runs before the connection
 *
 * The same argument iOS makes: a key that cannot be used is a sentence about the key, not a failed
 * connection to a server. Running it under the field — see [PrivateKeyReadback] — means the person
 * finds out while they are still looking at what they pasted, and running it again inside
 * [SshSession.open] before anything is dialled means a bad key never spends an attempt against
 * somebody's rate limiter.
 */
object SshKeys {

    /**
     * The key readers, built once.
     *
     * `AndroidSshConfig` extends `DefaultConfig`, whose constructor **constructs and initialises
     * every cipher** to prune the ones this device cannot do — see `initCipherFactories` — and this
     * object's `read` runs under a text field on every change to it. Building a fresh config per
     * keystroke would put a full algorithm sweep behind each character of a pasted key. The reader
     * list is a property of the build rather than of the connection, so one is enough.
     */
    private val readers by lazy { AndroidSshConfig().fileKeyProviderFactories }

    /**
     * A pasted key, as something that can sign — or a stated reason it cannot.
     *
     * @throws PrivateKeyException carrying the sentence pair.
     */
    fun read(text: String): KeyProvider {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) throw PrivateKeyException(PrivateKeyProblem.NotAKey)

        // The mistake worth naming, checked before the format detector: a `.pub` file is a single
        // line beginning with the key type, which the detector answers `Unknown` for — and
        // "unknown format" sends somebody to look for a different file when the file they want is
        // sitting next to the one they used.
        if (trimmed.startsWith("ssh-") || trimmed.startsWith("ecdsa-") || trimmed.startsWith("sk-")) {
            throw PrivateKeyException(PrivateKeyProblem.PublicHalf)
        }

        val format = try {
            KeyProviderUtil.detectKeyFileFormat(trimmed, false)
        } catch (e: Exception) {
            throw PrivateKeyException(PrivateKeyProblem.NotAKey)
        }
        if (format == null || format == KeyFormat.Unknown) {
            throw PrivateKeyException(PrivateKeyProblem.NotAKey)
        }

        val provider: FileKeyProvider = Factory.Named.Util.create(readers, format.toString())
            ?: throw PrivateKeyException(PrivateKeyProblem.Unsupported(format.toString()))

        /*
         * The password finder that never has one, and records having been asked.
         *
         * This is how a passphrase is detected without decrypting anything: sshj asks for one
         * exactly when the key is encrypted, and answering `null` makes it fail. Without the flag,
         * that failure is indistinguishable from a corrupt file — and "that key could not be read"
         * in front of a perfectly good key with a passphrase on it is the sentence that sends
         * somebody to re-copy a file that was fine.
         */
        var asked = false
        val noPassphrase = object : PasswordFinder {
            override fun reqPassword(resource: Resource<*>?): CharArray? {
                asked = true
                return null
            }

            override fun shouldRetry(resource: Resource<*>?): Boolean = false
        }

        provider.init(trimmed, null, noPassphrase)
        try {
            // Reading the private half is what actually parses it. A provider that merely
            // constructed proves nothing — sshj is lazy, and a key that will fail at the handshake
            // has to fail here instead.
            provider.private ?: throw PrivateKeyException(PrivateKeyProblem.NotAKey)
        } catch (e: PrivateKeyException) {
            throw e
        } catch (e: Exception) {
            if (asked) throw PrivateKeyException(PrivateKeyProblem.Locked)
            missingAlgorithm(e)?.let { throw PrivateKeyException(PrivateKeyProblem.NoProvider(it)) }
            throw PrivateKeyException(
                PrivateKeyProblem.Malformed(
                    "It parsed as far as its header and no further. Paste the whole file, from the " +
                        "BEGIN line to the END line, with nothing wrapped around it."
                )
            )
        }
        return provider
    }

    /**
     * The algorithm the platform would not supply, or null when that is not what went wrong.
     *
     * ## Why this case exists at all
     *
     * sshj asks the JCA for a `KeyFactory` by the name **SSH** uses, and for elliptic curves that
     * name is `ECDSA`. The JDK's own provider calls it `EC` and registers no alias, so on a plain
     * desktop JVM with no BouncyCastle registered, reading a perfectly good
     * `ssh-keygen -t ecdsa` key throws `NoSuchAlgorithmException: ECDSA KeyFactory not available`
     * — measured, on the machine this lane was built on.
     *
     * That is a fact about the *provider*, not about the key, and it must not arrive as *"that key
     * could not be read"* — which is the sentence that sends somebody to re-copy a file that is
     * fine. So it is detected by its own message and named.
     *
     * Whether it happens on Android is a separate question with a separate answer: the platform
     * ships a BouncyCastle provider that does alias `ECDSA` to `EC`, so an ECDSA key is expected to
     * read on a phone and not in this suite. Either way, what a person sees is true.
     */
    private fun missingAlgorithm(error: Throwable): String? {
        /*
         * Matched on the shape rather than on the first word.
         *
         * `NoSuchAlgorithmException("ECDSA KeyFactory not available")` is wrapped by a
         * `GeneralSecurityException` whose own message is the *toString* of the inner one — so it
         * reads `java.security.NoSuchAlgorithmException: ECDSA KeyFactory not available`, and
         * taking the first word names the exception class instead of the algorithm. It shipped a
         * headline reading *"This phone has no reader for java.security.NoSuchAlgorithmException:
         * keys"*, caught by this file's own test.
         */
        val shape = Regex("([A-Za-z0-9]+)\\s+\\w+\\s+not available")
        var at: Throwable? = error
        while (at != null) {
            shape.find(at.message.orEmpty())?.let { return it.groupValues[1] }
            at = at.cause
        }
        return null
    }

    /** The key's own kind, for a sentence about what arrived. Empty when it will not say. */
    fun kindOf(provider: KeyProvider): String = try {
        provider.type?.toString().orEmpty()
    } catch (e: Exception) {
        ""
    }
}

/**
 * Why a pasted key cannot be used. Every case carries the two sentences a screen prints.
 *
 * Shaped like [SshProblem] rather than like an exception hierarchy, because what a screen needs is
 * a headline and a next move, and every failure in this app has to be able to produce both.
 */
sealed interface PrivateKeyProblem {

    val headline: String
    val advice: String

    /** Nothing that looks like a private key at all. */
    data object NotAKey : PrivateKeyProblem {
        override val headline = "That is not a private key"
        override val advice =
            "Paste the whole file, including the BEGIN and END lines. It is the file with no .pub " +
                "on the end — the .pub one is the half that is meant to be public and cannot sign " +
                "anything."
    }

    /** The public half, which is the mistake worth naming rather than lumping in with the above. */
    data object PublicHalf : PrivateKeyProblem {
        override val headline = "That is the public half of a key"
        override val advice =
            "The one ending .pub is the half that is meant to be given away, and it cannot sign " +
                "anything. The private half is the file with the same name and no extension, and " +
                "it begins with a BEGIN line."
    }

    /** A real key, locked with a passphrase. */
    data object Locked : PrivateKeyProblem {
        override val headline = "That key has a passphrase on it"
        override val advice =
            "Nothing here can ask you for the passphrase on the server's behalf. Either use the " +
                "password for that account instead, or make a copy of the key with no passphrase: " +
                "`ssh-keygen -p -f <the key file>` and leave the new passphrase empty."
    }

    /** A shape sshj names and has no reader for. Rare, and named rather than guessed at. */
    data class Unsupported(val kind: String) : PrivateKeyProblem {
        override val headline = "$kind keys cannot be read here"
        override val advice =
            "This phone reads OpenSSH keys, PKCS#8 keys and PuTTY keys. An " +
                "`ssh-keygen -t ed25519` key works, and so does the account's password."
    }

    /** A supported kind whose bytes did not parse. Carries the reason. */
    data class Malformed(override val advice: String) : PrivateKeyProblem {
        override val headline = "That key could not be read"
    }

    /**
     * A real, whole key of a kind this device's cryptography provider will not supply.
     *
     * Named rather than reported as malformed, because the two send somebody to opposite places:
     * one is a paste to redo and this one is a key to swap. See [SshKeys.missingAlgorithm].
     */
    data class NoProvider(val algorithm: String) : PrivateKeyProblem {
        override val headline = "This phone has no reader for $algorithm keys"
        override val advice =
            "The key itself is fine — this device's cryptography does not supply that algorithm " +
                "under the name SSH asks for. An `ssh-keygen -t ed25519` key works, and so does " +
                "the account's password."
    }
}

/** [PrivateKeyProblem] as something a reader can throw. */
class PrivateKeyException(val problem: PrivateKeyProblem) : Exception(problem.headline)

/* -------------------------------------------------------------------------- */

/**
 * **What was actually pasted**, read back and described.
 *
 * ## The bug this exists to make impossible
 *
 * iOS shipped a key field whose entire feedback was *"Private key ready · 412 characters"*. A
 * character count cannot tell a whole key from a key whose seven lines were flattened into one —
 * the count is identical either way, because a newline is one character and so is the space that
 * replaced it. So a mangled key read as ready, the login was refused, and the sentence on screen
 * sent somebody to check a password that was never the problem.
 *
 * A private key is **seven lines** for Ed25519, and the first and last are the BEGIN and END. This
 * says how many lines came through and whether both are present, and it runs the real reader over
 * the bytes — [SshKeys.read], the same one the handshake will use — so *"this key is readable"*
 * means the thing that is about to sign has already read it.
 *
 * Nothing here renders the key. What it returns is a sentence about it.
 */
sealed interface PrivateKeyReadback {

    /** Readable by the reader that will sign with it. */
    data class Good(val text: String) : PrivateKeyReadback

    /** Something arrived and it is not usable. The reader's own words. */
    data class Bad(val headline: String, val advice: String) : PrivateKeyReadback

    /** Nothing in the field. */
    data object Nothing : PrivateKeyReadback

    val sentence: String?
        get() = when (this) {
            is Good -> text
            is Bad -> headline
            Nothing -> null
        }

    val isGood: Boolean get() = this is Good

    companion object {

        /**
         * Look at a pasted key.
         *
         * The line count is of the **trimmed** text, because a copied file almost always arrives
         * with a trailing newline and counting it would report eight lines for a seven-line key —
         * a number that does not match what somebody sees in their editor, on a screen whose whole
         * job is to convince them the paste was whole.
         */
        fun of(raw: String): PrivateKeyReadback {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return Nothing

            val lines = trimmed.split("\n").size
            val provider = try {
                SshKeys.read(trimmed)
            } catch (e: PrivateKeyException) {
                /*
                 * A key that survived the paste and is simply of a kind this app will not use is a
                 * different complaint from a key that arrived as one line, and saying both at once
                 * says neither. The line count goes out only when the failure could plausibly *be*
                 * the paste.
                 */
                /*
                 * A single line that did not read is almost always the flattening, whatever the
                 * reader called it.
                 *
                 * It is not always `NotAKey`: a key whose newlines were eaten still carries
                 * `BEGIN OPENSSH PRIVATE KEY`, so the format detector recognises it and the reader
                 * fails *inside* the format — which comes back as `Malformed`. Both mean the same
                 * thing to the person holding the phone, and neither of the readers' own sentences
                 * mentions the newlines that are the actual problem.
                 *
                 * `Locked`, `PublicHalf` and `NoProvider` are deliberately not folded in: those are
                 * true statements about a paste that arrived whole, and replacing them with "that
                 * arrived as one line" would be a worse sentence than the one it replaced.
                 */
                val couldBeThePaste = e.problem is PrivateKeyProblem.NotAKey ||
                    e.problem is PrivateKeyProblem.Malformed
                if (couldBeThePaste && lines <= 1) {
                    return Bad(
                        headline = "That arrived as one line.",
                        advice = "A private key is several lines and this field kept only one, " +
                            "which usually means it was copied out of somewhere that flattened it. " +
                            "Paste it again, or open the key file and copy all of it including the " +
                            "BEGIN and END lines.",
                    )
                }
                return Bad(e.problem.headline, e.problem.advice)
            } catch (e: Exception) {
                return Bad("That key could not be read.", e.toString())
            }

            val kind = SshKeys.kindOf(provider).ifEmpty { "Private" }
            val ends = trimmed.startsWith("-----BEGIN") && trimmed.endsWith("KEY-----")
            return Good(
                "$kind key · $lines line${if (lines == 1) "" else "s"}" +
                    if (ends) " · BEGIN and END are both here" else ""
            )
        }
    }
}
