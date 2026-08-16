package dev.terminaldeck.android.pairing

/**
 * The pairing code, and the only place its text is believed.
 *
 * ## Six digits, and nothing else
 *
 * `src/shared/short-code.ts` on the desktop is the format; this is the same rule in Kotlin.
 *
 * It used to be a URL — `terminaldeck://pair#h=…&k=…&t=…` — carrying a 26-character host id, the
 * Mac's 32-byte X25519 public key and a single-use token, read off a QR code or pasted out of a
 * message. It is gone. The QR did not work, and a link with a live pairing token in it is a bearer
 * secret whose only route to a phone is a chat app that keeps a copy of it.
 *
 * So the address is no longer *carried*; it is *looked up*, at the rendezvous slot the code names.
 * [Rendezvous] is that lookup and its header carries the argument for it — including why the
 * derivation is scrypt and must stay scrypt.
 *
 * ## Reading is looser than writing, and stops short of guessing
 *
 * Separators are dropped — spaces, hyphens, the curly dash a messaging app substitutes — because
 * the string makes a journey and things get inserted into it. A **letter** is refused rather than
 * folded. The eight-character format this replaced folded `O` onto `0` and `I`/`L` onto `1`, which
 * was right when the screen was showing letters and three of them are misread; the screen shows
 * digits now, so a letter is a typo, and folding a typo produces a *different valid code* belonging
 * to somebody else's pairing or to nobody at all.
 */
object PairingCodes {

    /** Digits in a code. `CODE_LENGTH` in `src/shared/short-code.ts`. */
    const val CODE_LENGTH = 6

    /** Same alphabet as the relay's host ids and the key fingerprints: no `0`/`O`, no `1`/`I`. */
    private val HOST_ID = Regex("^[A-HJ-NP-Z2-9]{26}$")

    /** Escaped rather than literal: a raw control byte in a class is invisible in every diff. */
    private val UNPRINTABLE = Regex("[\\s\\u0000-\\u001f\\u007f]")

    fun isHostId(value: String): Boolean = HOST_ID.matches(value)

    /**
     * What somebody typed, as the six digits they meant — or null.
     *
     * Bounded before it is scanned, and it stops the moment there are too many digits. Neither is a
     * security boundary — the code is checked for real by `device-auth.ts` on the far machine — but
     * a paste of a megabyte is still a megabyte to walk on the main thread, and the answer was never
     * going to be longer than six digits.
     */
    fun parse(raw: String): String? {
        val digits = StringBuilder(CODE_LENGTH)
        for (character in raw.take(256)) {
            if (character in '0'..'9') {
                digits.append(character)
                if (digits.length > CODE_LENGTH) return null
                continue
            }
            // A letter is a typo; see the header. Everything else — spaces, hyphens, the curly dash
            // a chat app substitutes — is separator noise and is dropped, because refusing it would
            // mean refusing the exact string somebody pasted out of a message.
            if (character.isLetter()) return null
        }
        return if (digits.length == CODE_LENGTH) digits.toString() else null
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
}
