package dev.terminaldeck.android.crypto

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.math.ec.rfc7748.X25519
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The Kotlin half of `src/shared/sealed.ts`: Noise IK, and nothing invented here.
 *
 * The TypeScript is normative. Every constant, every hash input and every byte offset below is
 * transcribed from it rather than chosen, and the two are held to that by
 * `SealedInteropTest`, which replays vectors produced by *running* `sealed.ts` — the same
 * handshake message, the same reply, the same directional keys, the same ciphertexts down to the
 * tag. A handshake that only talks to itself is worthless; that test is what makes this one not.
 *
 * ## Why BouncyCastle, and not the platform
 *
 * `minSdk` here is 26, and the platform cannot do this at 26:
 *
 *  - `KeyAgreement.getInstance("XDH")` and `KeyFactory.getInstance("XDH")` arrived in **API 33**.
 *    On API 26–32 there is no X25519 in the JCA at all, so the central primitive of the handshake
 *    simply does not exist.
 *  - `Cipher.getInstance("ChaCha20-Poly1305")` arrived in **API 28**.
 *  - HKDF-SHA256 has no JCA name on Android at any level; `Mac` plus a hand-rolled expand would
 *    work, but writing the one part of the schedule that is easy to get subtly wrong by hand is
 *    not a saving.
 *
 * So the choice is a library, and it is between BouncyCastle and Tink, both permissively licensed
 * (BouncyCastle's is the MIT licence verbatim; Tink is Apache 2.0). This uses **BouncyCastle's
 * lightweight API** — `bcprov-jdk18on` — for three reasons:
 *
 *  1. It exposes exactly the shapes Noise needs, in raw bytes: `X25519.calculateAgreement`,
 *     `ChaCha20Poly1305` over an `AEADParameters`, `HKDFBytesGenerator`. Tink is built around
 *     managed keysets and does not want to hand out a raw DH result or a bare HKDF, so the port
 *     would end up in `com.google.crypto.tink.subtle` anyway — the corner of Tink that is
 *     explicitly not a stable API.
 *  2. Nothing is registered as a JCA provider. These classes are called directly, so the app never
 *     touches `Security.insertProviderAt` and cannot change the behaviour of anything else on the
 *     device — which is the failure mode of shipping BouncyCastle the other way, on a platform
 *     that already carries a stripped copy of it under `com.android.org.bouncycastle`.
 *  3. It is one jar with no transitive dependencies. Tink brings protobuf.
 *
 * GPL was never in scope: it would relicense the app, exactly as `VENDORED.md` says about
 * termux-app.
 *
 * ## The three things this file gets right on purpose
 *
 * **The transcript hash.** `h` accumulates every public value in order and ends up mixed into the
 * key schedule, so a port that hashes the same values in a different order derives different keys
 * and fails on the first frame rather than being subtly weaker.
 *
 * **The nonce layout.** The counter goes in the **last eight bytes, little-endian**, leaving the
 * first four zero. This is the one that survives casual testing: big-endian works for the first
 * 256 frames of every session and then stops, so the vectors deliberately include counters 255,
 * 256 and 257.
 *
 * **The k1/k2 mirroring.** The initiator sends under `k1` and receives under `k2`; the responder
 * does the reverse. Getting this backwards produces two ends that each derive the right pair of
 * keys and cannot read a single byte from the other.
 *
 * ## And a fourth, which is not in this file at all
 *
 * Porting `sealed.ts` faithfully is necessary and not sufficient. The bytes this file produces are
 * the *payload*; `src/shared/relay-wire.ts` frames them with a version byte before they cross a
 * relay, so the wire carries 81 and 49 rather than the 80 and 48 below. That framing is
 * `protocol/RelayWire.kt`, and a client that has this file exactly right and that one missing is a
 * client that hangs. It is worth stating here because everything below passed its vectors while
 * the app could not connect to anything.
 */

/**
 * Every failure the sealed channel can produce, and deliberately only one sentence for the ones
 * that matter.
 *
 * `sealed.ts` refuses to distinguish "bad tag" from "unknown device" from "low-order point" out
 * loud, because telling a caller which check failed is an oracle. The same wording is kept here so
 * a log from the phone reads the same as a log from the Mac.
 */
class SealedException(message: String) : Exception(message)

/** A static identity. The private half never leaves the device that made it. */
class StaticKeyPair(val publicKey: ByteArray, val privateKey: ByteArray) {
    init {
        require(publicKey.size == Sealed.KEY_BYTES) { "x25519 public key must be 32 bytes" }
        require(privateKey.size == Sealed.KEY_BYTES) { "x25519 private key must be 32 bytes" }
    }

    companion object {
        /** Rebuild a pair from a stored private key. The public half is always re-derived. */
        fun fromPrivate(privateKey: ByteArray): StaticKeyPair {
            require(privateKey.size == Sealed.KEY_BYTES) { "x25519 private key must be 32 bytes" }
            val publicKey = ByteArray(Sealed.KEY_BYTES)
            X25519.scalarMultBase(privateKey, 0, publicKey, 0)
            return StaticKeyPair(publicKey, privateKey.copyOf())
        }
    }
}

object Sealed {

    /** Domain separator. Change any primitive and this string changes; there is nothing to negotiate. */
    const val NOISE_NAME = "Noise_IK_25519_ChaChaPoly_SHA256"

    /** Bumped with any change to the framing or key schedule. Matches `SEALED_VERSION`. */
    const val VERSION = 1

    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val TAG_BYTES = 16

    /**
     * The Noise IK message: ephemeral public key, then the encrypted static key and its tag.
     *
     * **Not** what goes on the wire. `RelayWire` puts a version byte in front of it, so a relay
     * carries 81. These two were once called `HANDSHAKE_MESSAGE_BYTES`/`HANDSHAKE_REPLY_BYTES`,
     * which is the name that produced a client unable to complete a single handshake.
     */
    const val NOISE_MESSAGE_BYTES = KEY_BYTES + KEY_BYTES + TAG_BYTES

    /** The Noise IK reply: responder ephemeral, then an empty confirmation and its tag. */
    const val NOISE_REPLY_BYTES = KEY_BYTES + TAG_BYTES

    /**
     * Highest message counter allowed under one key, as in the TypeScript: far below what the
     * nonce field could hold, so the failure is a closed connection and never a wrapped nonce.
     */
    const val MAX_COUNTER = 1L shl 48

    private val random = SecureRandom()

    fun generateStatic(): StaticKeyPair {
        val privateKey = ByteArray(KEY_BYTES)
        random.nextBytes(privateKey)
        return StaticKeyPair.fromPrivate(privateKey)
    }

    /* ------------------------------------------------------------------ primitives -- */

    internal fun hash(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in parts) digest.update(part)
        return digest.digest()
    }

    /**
     * X25519 with the all-zero output rejected.
     *
     * **Android's XDH does not do this and neither does BouncyCastle's raw scalar multiply.** A
     * peer that sends a low-order point forces the shared secret to zero on this side, which hands
     * an attacker a key they also know — RFC 7748 §6.1. `X25519.calculateAgreement` reports it by
     * returning false; the explicit comparison after it is the check the RFC actually asks for and
     * is kept so that swapping the primitive cannot silently drop it.
     */
    internal fun dh(privateRaw: ByteArray, publicRaw: ByteArray): ByteArray {
        if (privateRaw.size != KEY_BYTES || publicRaw.size != KEY_BYTES) {
            throw SealedException("handshake failed authentication")
        }
        val secret = ByteArray(KEY_BYTES)
        val ok = X25519.calculateAgreement(privateRaw, 0, publicRaw, 0, secret, 0)
        // MessageDigest.isEqual is the constant-time comparison on Android. Out of habit rather
        // than necessity: the value is not secret once it is zero.
        if (!ok || MessageDigest.isEqual(secret, ByteArray(KEY_BYTES))) {
            secret.fill(0)
            throw SealedException("handshake failed authentication")
        }
        return secret
    }

    /** Noise's `MixKey`: the next chaining key and a key usable now, from one HKDF. */
    internal fun mixKey(chainingKey: ByteArray, input: ByteArray): Pair<ByteArray, ByteArray> {
        val hkdf = HKDFBytesGenerator(SHA256Digest())
        hkdf.init(HKDFParameters(input, chainingKey, ByteArray(0)))
        val out = ByteArray(KEY_BYTES * 2)
        hkdf.generateBytes(out, 0, out.size)
        return out.copyOfRange(0, KEY_BYTES) to out.copyOfRange(KEY_BYTES, out.size)
    }

    /**
     * The counter in the last eight bytes, little-endian, first four zero.
     *
     * Writing it any other way is a silent interop break — see the note at the top of the file.
     */
    internal fun nonceOf(counter: Long): ByteArray {
        val nonce = ByteArray(NONCE_BYTES)
        var value = counter
        for (i in 0 until 8) {
            nonce[4 + i] = (value and 0xff).toByte()
            value = value ushr 8
        }
        return nonce
    }

    internal fun seal(key: ByteArray, counter: Long, plaintext: ByteArray, aad: ByteArray): ByteArray {
        val cipher = ChaCha20Poly1305()
        cipher.init(true, AEADParameters(KeyParameter(key), TAG_BYTES * 8, nonceOf(counter), aad))
        val out = ByteArray(cipher.getOutputSize(plaintext.size))
        var written = cipher.processBytes(plaintext, 0, plaintext.size, out, 0)
        written += cipher.doFinal(out, written)
        return if (written == out.size) out else out.copyOf(written)
    }

    internal fun open(key: ByteArray, counter: Long, frame: ByteArray, aad: ByteArray): ByteArray {
        if (frame.size < TAG_BYTES) throw SealedException("ciphertext shorter than its tag")
        val cipher = ChaCha20Poly1305()
        cipher.init(false, AEADParameters(KeyParameter(key), TAG_BYTES * 8, nonceOf(counter), aad))
        val out = ByteArray(cipher.getOutputSize(frame.size))
        return try {
            var written = cipher.processBytes(frame, 0, frame.size, out, 0)
            written += cipher.doFinal(out, written)
            if (written == out.size) out else out.copyOf(written)
        } catch (e: Exception) {
            // BouncyCastle throws InvalidCipherTextException for a bad tag and
            // IllegalStateException/IllegalArgumentException for a malformed length. All of them
            // are the same fact to a caller.
            throw SealedException("sealed frame failed authentication")
        }
    }

    /** Noise's `Split`: two directional keys plus the channel binding. */
    internal fun split(chainingKey: ByteArray, h: ByteArray): Triple<ByteArray, ByteArray, ByteArray> {
        val hkdf = HKDFBytesGenerator(SHA256Digest())
        hkdf.init(HKDFParameters(ByteArray(0), chainingKey, ByteArray(0)))
        val out = ByteArray(KEY_BYTES * 2)
        hkdf.generateBytes(out, 0, out.size)
        return Triple(out.copyOfRange(0, KEY_BYTES), out.copyOfRange(KEY_BYTES, out.size), h.copyOf())
    }

    /**
     * `h = HASH(HASH(protocol_name) ‖ rs)`.
     *
     * The name is longer than 32 bytes so it is hashed rather than padded, and the responder's
     * static public key is mixed in as the pre-message — which is what makes this IK and not XX.
     */
    internal fun initialState(responderStatic: ByteArray): Pair<ByteArray, ByteArray> {
        val h0 = hash(NOISE_NAME.toByteArray(Charsets.UTF_8))
        return h0 to hash(h0, responderStatic)
    }

    /* ----------------------------------------------------------------- fingerprints -- */

    /** Exactly 32 symbols: A–Z without `I` or `O`, then 2–9. */
    private const val BASE32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /**
     * A short, human-comparable form of a public key.
     *
     * Shown on the phone during pairing so a person can compare it with the one on the Mac. Not a
     * security boundary on its own — the pairing token and the approval step are — but it is what
     * turns "trust this device" from a dialog you dismiss into one you can check.
     */
    fun fingerprint(publicKey: ByteArray): String {
        val digest = hash("terminaldeck-fingerprint".toByteArray(Charsets.UTF_8), publicKey)
        var bits = 0
        var value = 0
        val out = StringBuilder()
        for (index in 0 until 15) {
            value = (value shl 8) or (digest[index].toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(BASE32[(value shr bits) and 31])
            }
        }
        return out.chunked(4).joinToString("-")
    }
}

/**
 * A live sealed channel, after the handshake.
 *
 * Send and receive counters are independent and never shared. `receive` refuses to advance on a
 * failed decrypt, so a forged frame costs the connection rather than desynchronising the counter.
 *
 * Synchronised because the two directions genuinely run on different threads here: keystrokes are
 * sealed on whichever thread the view is on and frames are opened on OkHttp's reader thread. The
 * counters are the state that must not interleave, and a nonce reused under ChaCha20-Poly1305
 * leaks the XOR of two plaintexts.
 */
class SealedChannel internal constructor(
    private val sendKey: ByteArray,
    private val receiveKey: ByteArray,
    /** The final transcript hash. Both sides have it; useful as a channel binding. */
    val channelBinding: ByteArray,
) {
    private var sendCounter = 0L
    private var receiveCounter = 0L

    @Synchronized
    fun send(plaintext: ByteArray): ByteArray {
        if (sendCounter >= Sealed.MAX_COUNTER) throw SealedException("sealed channel exhausted")
        val frame = Sealed.seal(sendKey, sendCounter, plaintext, EMPTY)
        sendCounter += 1
        return frame
    }

    @Synchronized
    fun receive(frame: ByteArray): ByteArray {
        if (receiveCounter >= Sealed.MAX_COUNTER) throw SealedException("sealed channel exhausted")
        val plaintext = try {
            Sealed.open(receiveKey, receiveCounter, frame, EMPTY)
        } catch (e: SealedException) {
            // One message for every failure, as on the Mac.
            throw SealedException("sealed frame failed authentication")
        }
        receiveCounter += 1
        return plaintext
    }

    fun sendText(value: String): ByteArray = send(value.toByteArray(Charsets.UTF_8))

    fun receiveText(frame: ByteArray): String = String(receive(frame), Charsets.UTF_8)

    private companion object {
        val EMPTY = ByteArray(0)
    }
}

/**
 * The initiator's half of the handshake — the only half a phone ever runs.
 *
 * The device's own static public key travels **encrypted**, under a key derived from `es`. That is
 * the point of IK: a passive observer, the relay included, learns that some device connected, not
 * which one.
 *
 * @param ephemeral injectable so the known-answer vectors can pin it. Production never passes it;
 *   a caller that does is either a test or a bug, and it is spelled out here rather than hidden
 *   behind a seam because a "deterministic mode" that can be reached by accident is worse than an
 *   obvious parameter.
 */
class HandshakeInitiator(
    private val deviceStatic: StaticKeyPair,
    responderStaticPublic: ByteArray,
    ephemeral: StaticKeyPair = Sealed.generateStatic(),
) {
    private var chainingKey: ByteArray
    private var h: ByteArray
    private val ephemeralPrivate = ephemeral.privateKey

    /** Goes on the wire: ephemeral public key, then the encrypted static key. */
    val message: ByteArray

    init {
        require(responderStaticPublic.size == Sealed.KEY_BYTES) {
            "x25519 public key must be 32 bytes"
        }
        val (chain0, h0) = Sealed.initialState(responderStaticPublic)
        h = Sealed.hash(h0, ephemeral.publicKey)

        val (chain1, esKey) = Sealed.mixKey(chain0, Sealed.dh(ephemeral.privateKey, responderStaticPublic))
        val encryptedStatic = Sealed.seal(esKey, 0, deviceStatic.publicKey, h)
        h = Sealed.hash(h, encryptedStatic)

        val (chain2, _) = Sealed.mixKey(chain1, Sealed.dh(deviceStatic.privateKey, responderStaticPublic))
        chainingKey = chain2

        message = ephemeral.publicKey + encryptedStatic
    }

    /** Completes this side once the responder's reply arrives. */
    fun finish(reply: ByteArray): SealedChannel {
        if (reply.size != Sealed.NOISE_REPLY_BYTES) {
            throw SealedException("handshake reply was the wrong length")
        }
        val responderEphemeral = reply.copyOfRange(0, Sealed.KEY_BYTES)
        val confirmation = reply.copyOfRange(Sealed.KEY_BYTES, reply.size)

        h = Sealed.hash(h, responderEphemeral)

        val (chain1, _) = Sealed.mixKey(chainingKey, Sealed.dh(ephemeralPrivate, responderEphemeral))
        val (chain2, seKey) = Sealed.mixKey(chain1, Sealed.dh(deviceStatic.privateKey, responderEphemeral))
        chainingKey = chain2

        // An empty payload whose only job is to prove the responder derived the same keys. If this
        // opens, the far end holds the Mac's static private key.
        try {
            Sealed.open(seKey, 0, confirmation, h)
        } catch (e: SealedException) {
            throw SealedException("handshake reply failed authentication")
        }
        h = Sealed.hash(h, confirmation)

        val (k1, k2, binding) = Sealed.split(chainingKey, h)
        // The initiator sends under k1 and receives under k2; the responder mirrors.
        return SealedChannel(k1, k2, binding)
    }
}
