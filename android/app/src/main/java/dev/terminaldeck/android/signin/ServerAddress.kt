package dev.terminaldeck.android.signin

import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.pairing.PairingCodes

/**
 * A server's address, as somebody pastes it in.
 *
 * ## Why an address exists at all, when pairing needs only six digits
 *
 * Six digits work because a *desktop* is standing there minting them: the code names a rendezvous
 * slot, the machine showing it answers on that slot with its real address, and nothing has to be
 * carried by hand. A server has nobody standing at it. There is no screen to read a code off and no
 * app there to mint one, so the three facts a first connection needs have to travel some other way,
 * and the only route left is a person copying a string.
 *
 * Those three facts are exactly the ones [dev.terminaldeck.android.pairing.Rendezvous.Offer]
 * carries, and they are needed for the same reason:
 *
 *  - **relay** — which rendezvous service to open. Configurable because the whole design assumes it
 *    is hostile; pointing at somebody else's is supported.
 *  - **host id** — which slot at it. 26 characters of the relay's base32, a name an attacker can
 *    photograph and cannot claim.
 *  - **key** — the server's 32-byte X25519 static public key. This is the one that makes the
 *    handshake Noise **IK** rather than trust-on-first-use: without it the relay could answer in the
 *    server's place and nothing on this phone would notice.
 *
 * The temptation is to let somebody paste a host id alone and fetch the key from the relay. That is
 * asking the attacker for the fingerprint of the person you are about to trust, and it is refused
 * here by construction: there is no address without a key in it.
 *
 * ## None of it is secret, and that is what makes it pasteable
 *
 * An address is public. It admits nobody — the `enroll` that follows still has to prove an SSH
 * login the server itself accepts — so it can be mailed, printed or read down a phone line without
 * the danger the old `terminaldeck://pair?…t=<token>` link carried, which was a live bearer token in
 * a string whose only route between two machines was a chat app that keeps a copy.
 *
 * ## Reading is deliberately loose, and stops short of guessing
 *
 * A server prints an address; a person copies it out of a terminal, an email or a message. What
 * arrives has been through line wrapping, quote marks, a leading `$`, smart-quote substitution and
 * whatever else sits between the two. So this reads every shape those three facts plausibly arrive
 * in — a labelled block, a single line, a URL, the JSON a browser client stores — and then applies
 * **one** validator to whatever it found.
 *
 * What it will not do is guess. A missing key is not filled in from anywhere, a host id with one
 * wrong character is refused rather than corrected (the alphabet has no confusable glyphs in it, so
 * a wrong character is a wrong character), and every refusal says which of the three was missing —
 * because "that address is not valid" in front of a 150-character paste is a dead end.
 */
data class ServerAddress(
    val relayUrl: String,
    val hostId: String,
    val hostKey: ByteArray,
) {

    /**
     * The six-group fingerprint of the server's key, for a screen to show before connecting.
     *
     * The same form the pair screen prints and the same one the server prints of itself, so the two
     * can be compared by eye. It is not a security boundary on its own — the handshake is — but it
     * is what turns "trust this server" from a sentence into something checkable.
     */
    val fingerprint: String get() = Sealed.fingerprint(hostKey)

    /** Enough of the host id to tell two servers apart at a glance. */
    val shortId: String get() = hostId.take(6)

    override fun equals(other: Any?): Boolean = this === other || (other is ServerAddress &&
        relayUrl == other.relayUrl && hostId == other.hostId && hostKey.contentEquals(other.hostKey))

    override fun hashCode(): Int = (relayUrl.hashCode() * 31 + hostId.hashCode()) * 31 + hostKey.contentHashCode()

    companion object {

        /**
         * Longest paste this will look at.
         *
         * Not a security boundary — nothing here is trusted — but an address is a few hundred
         * characters and a person who pastes a log file should get a sentence rather than a scan of
         * a megabyte on the main thread.
         */
        const val MAX_INPUT_CHARS = 8 * 1024

        /**
         * The canonical single line, and what a server should print.
         *
         * `td1` names the shape so that a reader who has never seen one can tell it is a Terminal
         * Deck address and not a URL somebody mangled, and so a future shape can be told from this
         * one rather than silently misread as it. The key is base64url with no padding, because the
         * line is copied out of terminals and `+`, `/` and `=` are the three characters most likely
         * to be broken by whatever it is copied through.
         *
         * Written by this client only in tests and in the "copy this address" affordances; the
         * source of a real one is the server. It is here because a format with exactly one writer
         * and several readers drifts, and the writer is the shortest way to pin it.
         */
        fun format(address: ServerAddress): String =
            "td1 ${address.relayUrl} ${address.hostId} ${encodeKey(address.hostKey)}"

        fun encodeKey(key: ByteArray): String =
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(key)

        /* ------------------------------------------------------------------ reading -- */

        sealed interface Result {
            data class Ok(val address: ServerAddress) : Result

            /**
             * Why this could not be read, in a sentence for the field's error line.
             *
             * It names the piece that was missing rather than the value that was wrong. Echoing a
             * pasted string back into a message is how an error line becomes somebody else's output
             * channel, and it is never the half a person needs: what they need is to know which of
             * the three facts is not in what they pasted.
             */
            data class Bad(val sentence: String) : Result
        }

        fun parse(raw: String): Result {
            val text = raw.take(MAX_INPUT_CHARS).trim().trim('"', '\'', '`', '<', '>')
            if (text.isEmpty()) return Result.Bad(EMPTY)

            val found = fromJson(text)
                ?: fromBase64Json(text)
                ?: fromUrl(text)
                ?: fromLooseText(text)
                ?: return Result.Bad(NOTHING_IN_IT)

            return validate(found)
        }

        /** The three fields as they were found, before any of them is believed. */
        private data class Found(val relayUrl: String?, val hostId: String?, val hostKey: String?)

        private fun validate(found: Found): Result {
            val relayUrl = found.relayUrl?.trimEnd('/')
            if (relayUrl == null || !PairingCodes.isRelayUrl(relayUrl)) return Result.Bad(NO_RELAY)
            val hostId = found.hostId?.uppercase()
            if (hostId == null || !PairingCodes.isHostId(hostId)) return Result.Bad(NO_HOST_ID)
            val key = found.hostKey?.let(::decodeKey) ?: return Result.Bad(NO_KEY)
            return Result.Ok(ServerAddress(relayUrl = relayUrl, hostId = hostId, hostKey = key))
        }

        /**
         * The 32 raw bytes behind a key, in either alphabet it arrives in, or null.
         *
         * This product encodes the same 32 bytes two ways and both reach a client: base64url,
         * because that is what survives being a line in a terminal, and standard base64, because
         * that is what `machines/ipc.ts` converts a rendezvous offer's key to on the way out.
         * Handling one and not the other is a server that pairs and a server that does not, for no
         * reason a person could ever discover.
         *
         * The two characters are folded rather than the encoding being chosen, because the
         * alphabets differ in exactly those two places and nowhere else. The length is then checked
         * rather than trusted: a key quietly two bytes short is a handshake that fails with nothing
         * to explain it.
         */
        private fun decodeKey(value: String): ByteArray? {
            val cleaned = value.trim().trimEnd('=').replace('-', '+').replace('_', '/')
            val bytes = try {
                java.util.Base64.getDecoder().decode(cleaned.padded())
            } catch (e: IllegalArgumentException) {
                return null
            }
            return bytes.takeIf { it.size == Sealed.KEY_BYTES }
        }

        /** Base64 wants a multiple of four; the padding is what a terminal drops first. */
        private fun String.padded(): String = when (length % 4) {
            2 -> "$this=="
            3 -> "$this="
            else -> this
        }

        /* --------------------------------------------------------------- the shapes -- */

        /**
         * The JSON a browser client keeps, and what a server that prints JSON would print.
         *
         * The field names are `pwa/src/endpoint.ts`'s stored shape — `url`, `hostId`, `hostKey` —
         * with the aliases the other two encodings of the same object already use in this codebase:
         * `relayUrl` and `publicKey` are what a rendezvous offer calls them.
         *
         * Read by hand rather than with a serializer. The input is a paste, so a strict decode
         * against a data class would fail on the first unexpected field and this has to survive an
         * object that carries more than it needs.
         */
        private fun fromJson(text: String): Found? {
            if (!text.startsWith("{")) return null
            fun field(vararg names: String): String? {
                for (name in names) {
                    val match = Regex("\"${Regex.escape(name)}\"\\s*:\\s*\"([^\"]*)\"").find(text)
                    if (match != null) return match.groupValues[1]
                }
                return null
            }
            return Found(
                relayUrl = field("url", "relayUrl", "relay"),
                hostId = field("hostId", "host", "id"),
                hostKey = field("hostKey", "publicKey", "key"),
            )
        }

        /** The same JSON, base64'd — which is how a blob survives a chat app that linkifies things. */
        private fun fromBase64Json(text: String): Found? {
            // `removePrefix`, not `substringAfter`: the two-argument form falls back to the string
            // it was *given*, so chaining two of them puts the prefix the first one stripped back on.
            val body = text.removePrefix("td1:").removePrefix("terminaldeck:").trim()
            if (body.isEmpty() || body.contains(' ') || body.contains('\n')) return null
            val decoded = try {
                java.util.Base64.getDecoder().decode(body.replace('-', '+').replace('_', '/').padded())
            } catch (e: IllegalArgumentException) {
                return null
            }
            val json = String(decoded, Charsets.UTF_8).trim()
            return if (json.startsWith("{")) fromJson(json) else null
        }

        /**
         * `terminaldeck://server?r=…&h=…&k=…`, and the long spellings of the same three.
         *
         * A scheme is one of the shapes an address plausibly arrives in — it is what a "copy link"
         * button produces — so it is read. Note what is **not** here: this app registers no intent
         * filter for it and never will. The scheme died with the pairing link for a good reason,
         * and a URL any installed app can be handed is not somewhere a client should take
         * instructions from. Read out of a field a person pasted into, it is just text.
         */
        private fun fromUrl(text: String): Found? {
            val query = when {
                text.startsWith("terminaldeck://", ignoreCase = true) -> text.substringAfter("://")
                text.startsWith("td://", ignoreCase = true) -> text.substringAfter("://")
                else -> return null
            }.substringAfter('?', "").ifEmpty { return null }

            val values = HashMap<String, String>()
            for (pair in query.split('&', ';')) {
                val name = pair.substringBefore('=', "").lowercase()
                if (name.isEmpty()) continue
                values[name] = decodePercent(pair.substringAfter('=', ""))
            }
            return Found(
                relayUrl = values["r"] ?: values["relay"] ?: values["url"],
                hostId = values["h"] ?: values["host"] ?: values["hostid"],
                hostKey = values["k"] ?: values["key"] ?: values["hostkey"],
            )
        }

        /** Enough of a URL decoder for a query somebody pasted. `+` is a space in a query string. */
        private fun decodePercent(value: String): String {
            if (!value.contains('%') && !value.contains('+')) return value
            val out = StringBuilder(value.length)
            var index = 0
            val plain = value.replace('+', ' ')
            while (index < plain.length) {
                val character = plain[index]
                val hex = if (character == '%' && index + 2 < plain.length) {
                    plain.substring(index + 1, index + 3).toIntOrNull(16)
                } else {
                    null
                }
                if (hex == null) {
                    out.append(character)
                    index += 1
                } else {
                    out.append(hex.toChar())
                    index += 3
                }
            }
            return out.toString()
        }

        /**
         * Anything with the three facts loose in it — which is most of what people actually paste.
         *
         * The canonical `td1 <relay> <host id> <key>` line lands here, and so does a labelled block
         * copied out of a status page, a line that got wrapped in an email, and the same three
         * strung together with tabs. Each fact is picked out by its own shape rather than by its
         * position, because position is the first thing a copy destroys:
         *
         *  - the relay is the token that starts `ws://` or `wss://`;
         *  - the host id is the token that is 26 characters of the relay's base32;
         *  - the key is the longest remaining token that decodes to 32 bytes.
         *
         * The shapes cannot collide. A host id is base32 with no lowercase and no `+/=`; a 32-byte
         * key is 43 base64 characters, never 26. So a scan cannot mistake one for the other, which
         * is what makes reading by shape safe rather than merely convenient.
         */
        private fun fromLooseText(text: String): Found? {
            val tokens = text.split(' ', '\t', '\n', '\r', ',').map { it.trim().trim('"', '\'', '<', '>') }
                .filter { it.isNotEmpty() }
            if (tokens.isEmpty()) return null

            val relayUrl = tokens.firstOrNull { it.startsWith("ws://", true) || it.startsWith("wss://", true) }
            val hostId = tokens.firstOrNull { PairingCodes.isHostId(it.uppercase()) }
            // Longest first: a wrapped key produces several fragments and only the whole one
            // decodes to 32 bytes, so this finds it without having to know it was wrapped.
            val hostKey = tokens.filter { it != relayUrl && it != hostId }
                .sortedByDescending { it.length }
                .firstOrNull { decodeKey(it) != null }
            if (relayUrl == null && hostId == null && hostKey == null) return null
            return Found(relayUrl = relayUrl, hostId = hostId, hostKey = hostKey)
        }

        /* -------------------------------------------------------------- the refusals -- */

        private const val MADE_OF =
            "A server address is a relay address starting wss://, a 26-character host id, and the " +
                "server's key."

        private const val EMPTY = "Paste the address the server printed."

        private const val NOTHING_IN_IT = "That does not look like a server address. $MADE_OF"

        private const val NO_RELAY = "There is no relay address in that. $MADE_OF"

        private const val NO_HOST_ID =
            "There is no host id in that — 26 characters, no 0, O, 1 or I. $MADE_OF"

        private const val NO_KEY =
            "There is no server key in that, or it is not 32 bytes. Copy the whole address: without " +
                "the key this phone cannot tell the real server from anything else answering for it."
    }
}
