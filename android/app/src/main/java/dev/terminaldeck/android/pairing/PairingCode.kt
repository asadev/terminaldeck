package dev.terminaldeck.android.pairing

import dev.terminaldeck.android.crypto.Sealed

/**
 * The pairing code, and the only place its text is believed.
 *
 * ## What a code has to carry
 *
 * Three things, because the relay path needs all three before a single byte can be sent:
 *
 *  - **`h`** — the 26-character host id from `relay/src/rendezvous.ts`. It is how the relay finds
 *    the Mac, and it is a name rather than a secret: it is `BASE32(SHA-256(hostSecret))`, so
 *    knowing it does not let anyone claim it.
 *  - **`k`** — the Mac's static X25519 public key, 32 bytes, base64url. This is what makes the
 *    handshake **IK** rather than a trust-on-first-use: the phone knows which machine it is
 *    talking to before it says anything, so a relay that swaps itself in fails to decrypt instead
 *    of succeeding as a man in the middle.
 *  - **`t`** — the single-use pairing token. The only secret in the code, spent on the first
 *    `hello` and exchanged there for a durable credential.
 *
 * `r` is optional: the relay's URL, for pointing a build at a relay that is not the default one.
 *
 * ## Why the fragment
 *
 * The same argument as `pwa/src/pair.ts`. A URL fragment is never sent to a server, so a code that
 * is shared as a link cannot deposit its token in an access log, a proxy log or a `Referer`
 * header. The parser also accepts a query string and a bare parameter blob, because a person
 * retyping a code off a screen is not going to reproduce a `#`, and refusing them would only push
 * people towards photographing the QR into a chat app.
 *
 * ## What is checked here and what is not
 *
 * Shape only. That the host is online, that the token is live, that the Mac's key is the one it
 * claims — none of those are answerable from a string, and a parser that appeared to answer them
 * would be the most dangerous kind of wrong. What this refuses is anything that cannot be a code:
 * a host id in the wrong alphabet, a key that is not 32 bytes, a token with whitespace or control
 * characters in it.
 */
data class PairingCode(
    val hostId: String,
    val hostStaticPublicKey: ByteArray,
    val token: String,
    /** Null when the code does not name one and the build's default should be used. */
    val relayUrl: String?,
) {
    /** The Mac's fingerprint, for comparing against what the desktop is showing. */
    val hostFingerprint: String get() = Sealed.fingerprint(hostStaticPublicKey)

    override fun equals(other: Any?): Boolean = this === other || (other is PairingCode &&
        hostId == other.hostId && token == other.token && relayUrl == other.relayUrl &&
        hostStaticPublicKey.contentEquals(other.hostStaticPublicKey))

    override fun hashCode(): Int = (hostId.hashCode() * 31 + token.hashCode()) * 31 + hostStaticPublicKey.contentHashCode()
}

object PairingCodes {

    /** Same alphabet as the relay's host ids and the key fingerprints: no `0`/`O`, no `1`/`I`. */
    private val HOST_ID = Regex("^[A-HJ-NP-Z2-9]{26}$")

    /** Escaped rather than literal: a raw control byte in a class is invisible in every diff. */
    private val UNPRINTABLE = Regex("[\\s\\u0000-\\u001f\\u007f]")

    private const val MAX_TOKEN_LENGTH = 200

    fun isHostId(value: String): Boolean = HOST_ID.matches(value)

    /**
     * Parse anything a user could plausibly hand this app, or return null.
     *
     * Accepted: `terminaldeck://pair#h=…&k=…&t=…`, the same over `https://`, a bare
     * `h=…&k=…&t=…`, with `?` instead of `#`. Rejected: everything else, silently — the pair
     * screen says "that is not a pairing code" and does not quote the text back, because the text
     * came off a camera pointed at whatever was in front of it.
     */
    fun parse(raw: String): PairingCode? {
        val text = raw.trim()
        if (text.isEmpty() || text.length > 2048) return null

        val body = text.substringAfter('#', missingDelimiterValue = "")
            .ifEmpty { text.substringAfter('?', missingDelimiterValue = "") }
            .ifEmpty { if (text.contains('=')) text else return null }

        val params = mutableMapOf<String, String>()
        for (pair in body.split('&')) {
            val at = pair.indexOf('=')
            if (at <= 0) continue
            val key = pair.substring(0, at)
            if (params.containsKey(key)) return null // a repeated parameter is not a code we wrote
            params[key] = decodeComponent(pair.substring(at + 1)) ?: return null
        }

        val hostId = params["h"] ?: return null
        if (!isHostId(hostId)) return null

        val key = params["k"]?.let(::decodeKey) ?: return null
        if (key.size != Sealed.KEY_BYTES) return null

        val token = params["t"] ?: return null
        if (token.isEmpty() || token.length > MAX_TOKEN_LENGTH || UNPRINTABLE.containsMatchIn(token)) return null

        val relay = params["r"]?.takeIf { it.isNotEmpty() }
        if (relay != null && !isRelayUrl(relay)) return null

        return PairingCode(hostId, key, token, relay)
    }

    /**
     * A relay address this client is willing to open.
     *
     * `ws://` is allowed as well as `wss://` because the development relay runs on a laptop with no
     * certificate, and a client that could only be pointed at production would have to be tested
     * against production. What stops that from being a downgrade is that the payload is sealed
     * before it reaches the socket: the relay is treated as hostile whether or not TLS is in front
     * of it, so `ws://` costs the metadata TLS would have hidden and nothing else.
     */
    fun isRelayUrl(value: String): Boolean {
        val lower = value.lowercase()
        if (!lower.startsWith("ws://") && !lower.startsWith("wss://")) return false
        val rest = value.substringAfter("://")
        return rest.isNotEmpty() && !UNPRINTABLE.containsMatchIn(value)
    }

    /** Base64url, padded or not. Anything else is not a key. */
    private fun decodeKey(value: String): ByteArray? = try {
        java.util.Base64.getUrlDecoder().decode(value.trimEnd('='))
    } catch (e: IllegalArgumentException) {
        null
    }

    /** Percent-decoding, without pulling in `Uri` — this file is unit-tested on a plain JVM. */
    private fun decodeComponent(value: String): String? {
        if (!value.contains('%') && !value.contains('+')) return value
        val out = StringBuilder(value.length)
        var i = 0
        while (i < value.length) {
            when (val char = value[i]) {
                '+' -> out.append(' ')
                '%' -> {
                    if (i + 2 >= value.length) return null
                    val hex = value.substring(i + 1, i + 3).toIntOrNull(16) ?: return null
                    out.append(hex.toChar())
                    i += 2
                }
                else -> out.append(char)
            }
            i += 1
        }
        return out.toString()
    }
}
