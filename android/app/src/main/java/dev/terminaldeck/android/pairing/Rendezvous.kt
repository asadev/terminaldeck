package dev.terminaldeck.android.pairing

import dev.terminaldeck.android.crypto.HandshakeInitiator
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.SealedChannel
import dev.terminaldeck.android.crypto.SealedException
import dev.terminaldeck.android.crypto.StaticKeyPair
import dev.terminaldeck.android.protocol.RelayWire
import dev.terminaldeck.android.transport.toHttpish
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.bouncycastle.crypto.generators.SCrypt
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * How six typed digits find a machine.
 *
 * ## Why a code cannot simply be dialled
 *
 * Reaching a machine takes three facts: a relay address, a 26-character host id and the machine's
 * 32-byte X25519 public key. Together they are the *address*, and they are what makes the handshake
 * Noise **IK** rather than a trust-on-first-use — the phone knows which machine it is talking to
 * before it says anything, so a relay that swaps itself in fails to decrypt instead of succeeding
 * as a man in the middle. None of the three is secret. They are simply large: 130 bits of host id
 * and 256 of key, and six digits cannot carry four hundred bits.
 *
 * This app used to get all of it from a QR code, inside a `terminaldeck://pair#…` link. The QR did
 * not work and the link was a live bearer token in a string, so both are gone and this file is what
 * replaces them.
 *
 * ## The mechanism, which is the desktop's and is not restated here
 *
 * `src/main/remote/machines/rendezvous.ts` carries the full argument and is worth reading there
 * rather than summarised badly. In one paragraph: the machine showing a code claims a relay slot
 * named by that code, and answers on it with its real address. Both ends derive the slot's secret
 * **and the responder's static key pair** from the code, so the offer channel is an ordinary sealed
 * channel whose responder identity only somebody holding the code can produce. A relay that
 * substitutes itself fails `es` and this client's handshake refuses it. Nothing was added to the
 * relay and nothing is stored anywhere; the slot exists for exactly as long as the code is on
 * screen.
 *
 * ## Why the derivation is scrypt and must stay scrypt
 *
 * There are 10^6 codes. A slot lookup answers a yes/no question about a candidate code, over a relay
 * with no per-source rate limit anywhere in the path. If the slot were named by a hash, an attacker
 * would sweep the million in seconds, learn the live code exactly, and redeem it on the first try —
 * and the five-guess budget the desktop enforces would be worth nothing, because they would never
 * need a second guess.
 *
 * At N=16384, r=8, p=1 a guess costs 16 MiB and tens of milliseconds; the whole space is about ten
 * CPU-hours, inside a sixty-second window. Lowering N "because phones are slow" is the change this
 * file exists to make somebody argue for.
 *
 * BouncyCastle's `SCrypt` rather than a hand-written one, for the same reason `Sealed.kt` uses
 * BouncyCastle at all: it is already a dependency, it is the lightweight API taking and returning
 * raw bytes, and nothing is registered as a JCA provider. The JDK has no scrypt at any API level
 * this app supports.
 *
 * ## What is shared with the desktop, and what is restated
 *
 * Restated, because Kotlin cannot import TypeScript: the salt, the parameters, the seed split, and
 * the host-id alphabet. Two implementations of one derivation drift silently — nothing throws,
 * nothing logs, and a code typed correctly simply finds nothing — so `RendezvousTest` pins the
 * output against vectors produced by *running* the desktop's own module. That test is what makes
 * this file safe to have.
 */
object Rendezvous {

    /**
     * The domain separator, mixed in as the scrypt salt.
     *
     * Versioned because it pins the whole derivation: change the parameters below and this string
     * changes with them, so two builds that disagree fail to find each other at the relay rather
     * than half-completing a handshake with mismatched keys. There is nothing to negotiate and no
     * fallback.
     *
     * It must equal `RENDEZVOUS_SALT` in the desktop's module, byte for byte.
     */
    const val SALT = "terminaldeck-machine-pairing-v1"

    /** The desktop's parameters, and they must stay the desktop's parameters. */
    const val SCRYPT_N = 16384
    const val SCRYPT_R = 8
    const val SCRYPT_P = 1

    /** 32 bytes to name the slot with, then 32 to be the responder identity. */
    const val SEED_BYTES = 64

    /**
     * How long a lookup waits.
     *
     * The code lives sixty seconds and both halves of pairing — this lookup and the real connection
     * that follows — have to fit inside it. A lookup that waited thirty seconds would leave a
     * pairing that fails on a token which expired while it was waiting, and the sentence the person
     * reads would blame the wrong thing.
     */
    const val LOOKUP_TIMEOUT_MS = 12_000L

    /** The relay's guest endpoint, from `relay/src/rendezvous.ts`. */
    private const val GUEST_PATH = "/v1/join"

    /** The identity both ends derive from one code. */
    data class Identity(val hostId: String, val keys: StaticKeyPair)

    /**
     * The identity a code derives, or null for a string that is not a code.
     *
     * Deliberately expensive: 16 MiB and tens of milliseconds, which on a mid-range phone is a good
     * deal more. Callers run it off the main thread — [lookup] does — because freezing the one
     * screen where somebody is watching to see whether their code worked is the worst place in the
     * app to spend half a second.
     *
     * Normalised first, so both ends derive from the same string however each was typed or printed.
     * `482913`, ` 482 913 ` and `482-913` — the shape a code comes back in after a round trip
     * through a messaging app — all have to land on one seed.
     */
    fun identity(typed: String): Identity? {
        val code = PairingCodes.parse(typed) ?: return null
        val seed = SCrypt.generate(
            code.toByteArray(Charsets.UTF_8),
            SALT.toByteArray(Charsets.UTF_8),
            SCRYPT_N,
            SCRYPT_R,
            SCRYPT_P,
            SEED_BYTES,
        )
        val hostSecret = seed.copyOfRange(0, 32)
        val keys = StaticKeyPair.fromPrivate(seed.copyOfRange(32, 64))
        return Identity(slotName(hostSecret), keys)
    }

    /**
     * `BASE32(SHA-256(secret))`, 26 characters.
     *
     * The relay's own alphabet: A–Z without `I` or `O`, then 2–9, so a host id printed on a screen
     * has no character anybody misreads. `hostIdFor` in `src/shared/relay-wire.ts` is the
     * definition; this is the same function in Kotlin and `RendezvousTest` cross-checks the two.
     */
    fun slotName(secret: ByteArray): String {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val digest = MessageDigest.getInstance("SHA-256").digest(secret)
        val out = StringBuilder(26)
        var bits = 0
        var value = 0
        for (byte in digest) {
            value = (value shl 8) or (byte.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(alphabet[(value shr bits) and 31])
                if (out.length == 26) return out.toString()
            }
        }
        return out.toString()
    }

    /**
     * What the machine showing a code says about itself: an address, and nothing else.
     *
     * Every field is public. There is deliberately no secret in the offer — the channel it arrives
     * on is sealed, but a payload that relied on that would be one bad refactor away from being sent
     * in the clear, and this one is not.
     */
    data class Offer(val relayUrl: String, val hostId: String, val hostKey: ByteArray) {
        override fun equals(other: Any?): Boolean = this === other || (other is Offer &&
            relayUrl == other.relayUrl && hostId == other.hostId && hostKey.contentEquals(other.hostKey))

        override fun hashCode(): Int = (relayUrl.hashCode() * 31 + hostId.hashCode()) * 31 + hostKey.contentHashCode()
    }

    /** Bounded so a hostile answer cannot make this app hold a large string. */
    private const val MAX_OFFER_BYTES = 4 * 1024

    /**
     * Read an offer, or null.
     *
     * Narrowed field by field, and it is the second of two locks rather than the only one: nobody
     * without the code can produce this frame at all, because the channel it arrives on is sealed
     * against a key derived from the code. It is here because a frame that is authenticated is still
     * not a frame that is well-formed — and what comes out of this function is dialled and then
     * handed a pairing code.
     *
     * The key is **decoded, not shape-checked**. An offer carries 32 bytes as standard base64,
     * because `machines/ipc.ts` re-encodes them that way, and standard base64 of 32 random bytes
     * contains a `+` or a `/` most of the time. A validator written for the base64url form the old
     * pairing link carried would refuse most real machines, intermittently, in a way that reads on
     * screen as a code that had expired.
     */
    fun parseOffer(raw: String): Offer? {
        if (raw.length > MAX_OFFER_BYTES) return null
        // `kotlinx.serialization` rather than `org.json`, and not by taste: `org.json` is a stub on
        // the JVM the unit tests run on and throws from every method, so an offer parser written
        // against it would be a parser no test could reach.
        val json = try {
            Json.parseToJsonElement(raw) as? JsonObject
        } catch (e: kotlinx.serialization.SerializationException) {
            null
        } ?: return null

        fun text(name: String): String? = (json[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

        if (text("t") != "machine") return null
        val relayUrl = text("relayUrl") ?: return null
        if (!PairingCodes.isRelayUrl(relayUrl)) return null
        val hostId = text("hostId") ?: return null
        if (!PairingCodes.isHostId(hostId)) return null

        val key = try {
            java.util.Base64.getDecoder().decode(text("publicKey") ?: return null)
        } catch (e: IllegalArgumentException) {
            return null
        }
        if (key.size != Sealed.KEY_BYTES) return null

        return Offer(relayUrl, hostId, key)
    }

    /**
     * Ask the rendezvous where the machine behind a code is.
     *
     * Nothing is sent. The machine showing the code answers as soon as the sealed channel is up, and
     * the whole conversation is that one frame — so this opens a channel, takes the first thing that
     * arrives, and hangs up.
     *
     * A **throwaway** key pair is used rather than this phone's own, matching the desktop and every
     * other client: the rendezvous authenticates the *responder* — it is the machine showing the
     * code that has to prove it holds the code — and nothing on the far side stores or looks at who
     * dialled. Putting the durable device key on a channel before there is a machine to associate it
     * with would be spending it for nothing.
     *
     * Null covers every failure — a code nobody is showing, a relay that will not answer, an offer
     * that does not parse — because the caller's next sentence is the same in all of them, and
     * telling them apart would mean describing the relay's behaviour to somebody who cannot act on
     * it.
     *
     * `client` is a seam for the tests: a unit test that used the real one would open a WebSocket to
     * the public relay from whatever machine the suite ran on.
     */
    suspend fun lookup(
        typed: String,
        relayUrl: String,
        client: OkHttpClient = defaultClient(),
        timeoutMs: Long = LOOKUP_TIMEOUT_MS,
    ): Offer? {
        // The derivation is memory-hard on purpose and this is a phone; `Dispatchers.Default` keeps
        // it off whichever thread the caller happened to be on.
        val identity = withContext(Dispatchers.Default) { identity(typed) } ?: return null

        val answer = CompletableDeferred<Offer?>()
        val request = Request.Builder()
            .url("${relayUrl.toHttpish().trimEnd('/')}$GUEST_PATH?host=${identity.hostId}")
            .build()

        var handshake: HandshakeInitiator? = null
        var channel: SealedChannel? = null

        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val started = HandshakeInitiator(Sealed.generateStatic(), identity.keys.publicKey)
                handshake = started
                webSocket.send(RelayWire.withSealedVersion(started.message).toByteString())
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val payload = bytes.toByteArray()
                val live = channel
                if (live == null) {
                    // The first frame back is the responder's half of the handshake. A relay that
                    // claimed this slot without holding the code cannot produce one that opens, so
                    // this is where an impostor is refused — before a single byte of its answer is
                    // parsed.
                    val opened = RelayWire.readSealedHandshake(payload, RelayWire.HANDSHAKE_REPLY_BYTES)
                    val reply = (opened as? RelayWire.SealedOpen.Ok)?.message
                    if (reply == null) return answer.complete(null).let { webSocket.cancel() }
                    channel = try {
                        handshake?.finish(reply)
                    } catch (e: SealedException) {
                        null
                    }
                    if (channel == null) {
                        answer.complete(null)
                        webSocket.cancel()
                    }
                    return
                }
                val text = try {
                    live.receiveText(payload)
                } catch (e: SealedException) {
                    null
                }
                answer.complete(text?.let(::parseOffer))
                webSocket.cancel()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                answer.complete(null)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                answer.complete(null)
            }
        })

        return try {
            withTimeoutOrNull(timeoutMs) { answer.await() }
        } finally {
            socket.cancel()
        }
    }

    /**
     * [lookup] with the two arguments a caller actually varies, as a function reference.
     *
     * `DeckViewModel` takes this as a parameter so a test can put a fixture in its place. A
     * default argument would not do: a method reference to a function with defaults is not a
     * `suspend (String, String) -> Offer?`, and the alternative — a lambda in the default — is a
     * closure the reader has to open the view model to understand.
     */
    suspend fun lookupAt(typed: String, relayUrl: String): Offer? = lookup(typed, relayUrl)

    /**
     * A client of its own, and a short one.
     *
     * The transport's client keeps a socket alive for hours and pings to survive a sleeping phone.
     * This one lives for a second and must give up quickly: the code it is looking up dies in sixty
     * seconds, and both halves of pairing have to happen inside that.
     */
    fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
}
