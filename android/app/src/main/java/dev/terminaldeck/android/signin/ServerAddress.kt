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
 * in — the `srv1.` token a server prints, a labelled block, a single line, a URL, the JSON a browser
 * client stores — and then applies **one** validator to whatever it found.
 *
 * The first of those is the format and the rest are tolerances around it. That ordering is worth
 * stating because it was once the other way round in this file: every tolerance was implemented and
 * the format itself was not, so the screen refused the only string a server ever prints. See
 * [Companion.announced].
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
         * Which spelling of a server address this build reads.
         *
         * `SERVER_ADDRESS_VERSION` in `src/shared/server-address.ts`, restated because Kotlin
         * cannot import a TypeScript constant. It is not left to drift:
         * `ServerAddressFixture.kt` beside the tests is generated from the real encoder, and
         * `src/shared/server-address-fixture.test.ts` fails on every `vitest run` the moment that
         * generated string stops matching what a host prints — so a format bump reaches this file
         * as a red test rather than as a phone that refuses every address.
         */
        const val VERSION = 1

        /**
         * A readable line this client can write, which is **not** the format a server prints.
         *
         * That distinction cost the feature once and is worth stating plainly. A server prints
         * `srv1.` followed by base64url of the endpoint object — see `formatServerAddress` in
         * `src/shared/server-address.ts` — and for a while this parser did not know that string
         * existed, because it was written in parallel with the encoder and nothing fed one into the
         * other. `td1` is a spelling for the *loose* shape below: three space-separated facts a
         * person can read at a glance and this client can put on a clipboard.
         *
         * The key is base64url with no padding, because the line is copied out of terminals and
         * `+`, `/` and `=` are the three characters most likely to be broken by whatever it is
         * copied through.
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

            // The token a server actually prints, first: it is the only shape that says out loud
            // what it is, and it is the one this parser could not read until the seam was tested.
            val tokens = announced(text)
            for (token in tokens) {
                if (token.version != VERSION) continue
                val json = decodeBase64Url(token.body)?.toString(Charsets.UTF_8)?.trim() ?: continue
                // Both ends, and then all three facts. [fromJson] reads fields with a regex rather
                // than a parser — deliberately, because a paste carries more than it needs — so it
                // answers a `Found` for a *fragment* of the object too, and a fragment is exactly
                // what the first line of a wrapped token decodes to: `srv1.` and seventy-five
                // characters of body is 56 bytes of JSON that begins `{"kind":"relay","url":"wss…`
                // and stops mid-field. Committing to that candidate returns "there is no host id in
                // that" about a paste whose next candidate is the whole, valid address.
                if (!json.startsWith("{") || !json.endsWith("}")) continue
                val decoded = fromJson(json) ?: continue
                if (decoded.relayUrl == null || decoded.hostId == null || decoded.hostKey == null) continue
                // Straight to `validate` once a token has decoded to a complete object: a real
                // address with one bad field in it deserves that field's sentence rather than
                // "that does not look like a server address".
                return validate(decoded)
            }

            val found = fromJson(text)
                ?: fromBase64Json(text)
                ?: fromUrl(text)
                ?: fromLooseText(text)

            if (found != null) return validate(found)

            // Last, and only once nothing in the paste worked: a token announcing a format this
            // build does not read is the *reason* nothing worked, and it is a different sentence
            // from "that is not an address" — the fix is a software update rather than another trip
            // to the clipboard. A paste that also held something readable was never a version
            // problem, which is why this is here rather than at the top.
            val foreign = tokens.firstOrNull { it.version != VERSION }
            return if (foreign == null) Result.Bad(NOTHING_IN_IT) else Result.Bad(wrongVersion(foreign.version))
        }

        /* ------------------------------------------------------- the versioned token -- */

        /** A token that named a format, and the format it named. */
        private data class Announced(val version: Int, val body: String)

        /**
         * `srv1.<base64url>`, wherever in a paste it sits.
         *
         * ## The bug this exists to have not shipped
         *
         * `formatServerAddress` writes a version prefix in front of the base64 and nothing here
         * knew about it. `fromBase64Json` strips `td1:` and `terminaldeck:` — two labels this
         * product has never printed — and the real separator is a `.`, which `Base64.getDecoder()`
         * throws on. Every shape then failed in turn and the screen said "that does not look like a
         * server address" about the only string a server emits. Green suite, dead feature.
         *
         * ## Why it is looked for rather than required at the front
         *
         * Because of what a server prints around it: `renderAddress` in `src/headless/cli.ts` puts
         * a `Server address` heading above the token and two sentences below it, and a finger
         * selecting that on a phone takes the heading and at least one sentence. That is the paste
         * [fromLooseText] exists for, and the token has to be findable in it.
         *
         * So each whitespace-separated chunk is tested on its own, and the whole paste with its
         * whitespace removed is tested last — the other thing a clipboard does to one long token,
         * a terminal wrapping it at eighty columns. Every candidate is kept rather than the first,
         * because a wrapped token puts `srv1.` and seventy-five characters of body on a line of
         * their own: that chunk is a token by every rule here and decodes to nothing, and stopping
         * at it would refuse the joined candidate that follows.
         *
         * The body is held to base64url and to a length no accident reaches. "Your app is too old",
         * told to somebody who pasted the wrong thing, is worse than no sentence at all.
         */
        private val TOKEN =
            Regex("""^[<"'`(\[]*srv([0-9]{1,4})\.([A-Za-z0-9_-]{16,})[)\]>"'`,;.]*${'$'}""", RegexOption.IGNORE_CASE)

        private fun announced(text: String): List<Announced> {
            val chunks = text.split(' ', '\t', '\n', '\r') + text.filterNot { it.isWhitespace() }
            return chunks.mapNotNull { chunk ->
                val match = TOKEN.find(chunk) ?: return@mapNotNull null
                val version = match.groupValues[1].toIntOrNull() ?: return@mapNotNull null
                Announced(version, match.groupValues[2])
            }
        }

        /** base64url or standard base64, folded and padded, or null. The same fold as [decodeKey]. */
        private fun decodeBase64Url(text: String): ByteArray? = try {
            java.util.Base64.getDecoder().decode(text.replace('-', '+').replace('_', '/').padded())
        } catch (e: IllegalArgumentException) {
            null
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

        /**
         * The refusal for an address this build is simply too old (or too new) to read.
         *
         * Both directions are written because the sentence has to name the half that is behind.
         * Only one of them can happen today — version 1 is the first there has been — and writing
         * the pair costs a branch and means the wrong one can never be printed the day there is a
         * second.
         */
        private fun wrongVersion(announced: Int): String = if (announced > VERSION) {
            "That address is version $announced and this app reads version $VERSION, so this app is " +
                "older than that server. Update the app on this phone, then paste the address again."
        } else {
            "That address is version $announced and this app reads version $VERSION, so that server " +
                "is older than this app. Update the server, then copy its address again."
        }

        private const val NO_KEY =
            "There is no server key in that, or it is not 32 bytes. Copy the whole address: without " +
                "the key this phone cannot tell the real server from anything else answering for it."
    }
}
