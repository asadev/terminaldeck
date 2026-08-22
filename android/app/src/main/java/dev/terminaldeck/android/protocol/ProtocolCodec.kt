package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Encoding out, narrowing in.
 *
 * The desktop's `parseClientMessage` is the only door its inbound frames come through, and it
 * returns a reason rather than throwing, because an exception on the data path of a socket is how a
 * main process dies. The same argument holds on this side for a different reason: an exception on
 * the data path of a WebSocket listener crosses a coroutine boundary and lands somewhere the user
 * sees as the app closing. [ServerFrames.parse] therefore returns a result.
 */
val ProtocolJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
    coerceInputValues = true
    classDiscriminator = "t"
}

/** What the phone sends. Encoding cannot fail for these types, so it does not return a result. */
object ClientFrames {

    fun encode(message: ClientMessage): String = ProtocolJson.encodeToString(message)

    /**
     * Split a paste that is over [Protocol.MAX_INPUT_BYTES] into frames the desktop will accept.
     *
     * Splitting on a code-point boundary, not a UTF-16 one. A cut between the halves of a surrogate
     * pair produces two frames each carrying a lone surrogate, and the desktop encodes those as
     * U+FFFD — so a pasted emoji at exactly the wrong offset would arrive at the shell as two
     * replacement characters rather than one emoji. The desktop goes to the same trouble in
     * `chunkOutput` coming the other way.
     */
    fun chunkInput(id: String, data: String): List<ClientMessage.Input> {
        if (!Protocol.overBytes(data, Protocol.MAX_INPUT_BYTES)) {
            return listOf(ClientMessage.Input(id, data))
        }
        val chunks = mutableListOf<ClientMessage.Input>()
        var start = 0
        while (start < data.length) {
            var end = start
            var bytes = 0
            while (end < data.length) {
                val code = data[end].code
                val isPair = code in 0xd800..0xdbff &&
                    end + 1 < data.length &&
                    data[end + 1].code in 0xdc00..0xdfff
                val width = when {
                    code < 0x80 -> 1
                    code < 0x800 -> 2
                    isPair -> 4
                    else -> 3
                }
                if (bytes + width > Protocol.MAX_INPUT_BYTES) break
                bytes += width
                end += if (isPair) 2 else 1
            }
            // A single code point wider than the cap is impossible (4 bytes against 16 KiB), but a
            // zero-width step would spin forever, so refuse to make no progress.
            if (end == start) end = minOf(start + 1, data.length)
            chunks += ClientMessage.Input(id, data.substring(start, end))
            start = end
        }
        return chunks
    }
}

/** What the phone believes. Nothing here trusts its argument. */
object ServerFrames {

    sealed interface Result {
        data class Ok(val message: ServerMessage) : Result

        /**
         * A frame that could not be believed.
         *
         * [reason] never quotes the value that was refused. It is logged, and echoing text chosen
         * by whatever is on the other end of the socket into a log is how a parser becomes someone
         * else's output channel — the desktop's protocol.ts makes the same point about its own
         * refusals.
         */
        data class Bad(val reason: String) : Result
    }

    /**
     * The type-aware cap, transcribed from `parseServerMessage`.
     *
     * Measured cheaply first: a message inside the ordinary text cap takes the ordinary path — one
     * size check, one parse, byte for byte what it was before a screencast frame existed. Only a
     * message *over* that cap pays the second check, and the one message allowed past it is a
     * `browser.frame`, whose base64 JPEG is by design larger than the text cap. Anything larger, or
     * anything that size which is not a frame, is refused: the frame's bigger allowance is never
     * borrowed by another message.
     */
    fun parse(raw: String): Result {
        if (Protocol.overBytes(raw, Protocol.MAX_MESSAGE_BYTES)) {
            if (Protocol.overBytes(raw, Protocol.MAX_FRAME_MESSAGE_BYTES)) {
                return Result.Bad("frame over the message limit")
            }
            // Sniffed on the raw text rather than by decoding first, because decoding is what the
            // cap is protecting against: this asks "is it a frame" of a string that has already been
            // measured, and only then hands it to the serializer.
            if (!looksLikeFrame(raw)) {
                return Result.Bad("frame over the message limit")
            }
        }
        val decoded = try {
            ProtocolJson.decodeFromString<ServerMessage>(raw)
        } catch (e: SerializationException) {
            return Result.Bad("not a server message")
        } catch (e: IllegalArgumentException) {
            return Result.Bad("not a server message")
        }
        return narrow(decoded)
    }

    /**
     * Whether an over-cap message claims to be a `browser.frame`.
     *
     * A substring test rather than a parse, and deliberately loose: something that says it is a
     * frame and is not fails the serializer a line later, which is the check that matters. What this
     * decides is only whether a 90 KB string is worth handing to the parser at all, and a discriminator
     * this app writes and reads is enough to answer that.
     */
    private fun looksLikeFrame(raw: String): Boolean =
        raw.contains("\"t\":\"browser.frame\"") || raw.contains("\"t\": \"browser.frame\"")

    /**
     * The checks the serializer cannot express, applied after it has done the shape.
     *
     * Two frames need one, for opposite reasons. [ServerMessage.Enrolled] is handled first and is
     * covered where it is checked. [ServerMessage.CredentialRequest] needs one because it is the
     * single frame in this protocol whose contents are **drawn on a screen somebody reads before
     * approving a push**. Two strings on it are bounded on the wire, and an unbounded one here
     * would be a prompt whose last line — the machine that asked — can be pushed off the bottom by
     * a host name a kilometre long.
     *
     * A missing id or host is a refusal, because there is nothing to answer and nowhere to say it
     * went. An over-long repository is **not**: it is folded onto null, which is the same answer
     * this client already has to handle for a repository the desktop could not name, and which the
     * prompt says out loud rather than papering over.
     */
    private fun narrow(message: ServerMessage): Result {
        // The other frame the serializer's shape check is not enough for, and the reason is
        // different: `enrolled` is what a **sign-in** comes back as, pre-authentication, from a
        // machine this phone has never spoken to before. All three fields are required — a minted
        // device with no id or no credential is not one this phone can reconnect as, so a frame
        // missing either is refused rather than stored half-formed — and the credential is bounded
        // so a hostile host cannot hand this phone a megabyte to keep behind the Keystore. Every
        // check is `parseServerMessage`'s own, in the same order.
        if (message is ServerMessage.Enrolled) {
            if (message.deviceId.isEmpty() || message.deviceName.isEmpty() || message.credential.isEmpty()) {
                return Result.Bad("incomplete enrolled")
            }
            if (message.credential.length > Protocol.MAX_ENROLL_CREDENTIAL_LENGTH) {
                return Result.Bad("enrolled with an oversized credential")
            }
            return Result.Ok(message)
        }
        // A roster the machine sent, bounded rather than refused: a list that is one row too long is
        // a machine with a lot of logins, not a hostile frame, and the honest answer is the rows this
        // client will draw.
        if (message is ServerMessage.AccountState && message.accounts.size > Protocol.MAX_ACCOUNTS_REPORTED) {
            return Result.Ok(message.copy(accounts = message.accounts.take(Protocol.MAX_ACCOUNTS_REPORTED)))
        }
        // Kept from the **end**, matching `rows.slice(-MAX_CHAT_ROWS)` over there: a chat view shows
        // the newest of a conversation, and trimming the head of an over-long answer would keep the
        // oldest bubbles and drop the reply somebody is waiting to read.
        if (message is ServerMessage.ChatRows && message.rows.size > Protocol.MAX_CHAT_ROWS) {
            return Result.Ok(message.copy(rows = message.rows.takeLast(Protocol.MAX_CHAT_ROWS)))
        }
        // A tunnelled chunk is validated as base64 before an allocator is handed it, exactly as
        // `net.data` is on the desktop: the alphabet, and a length that is a multiple of four.
        // Refused rather than repaired — invented bytes in the middle of somebody's HTTP response
        // are worse than a stream that ends.
        if (message is ServerMessage.NetData) {
            if (message.ch.isEmpty()) return Result.Bad("net.data without a channel id")
            if (message.data.length > Protocol.MAX_NET_DATA_CHARS) {
                return Result.Bad("net.data over the chunk limit")
            }
            if (message.data.isNotEmpty() && !isBase64(message.data)) {
                return Result.Bad("net.data is not base64")
            }
            return Result.Ok(message)
        }
        if (message is ServerMessage.NetAck) {
            if (message.ch.isEmpty()) return Result.Bad("net.ack without a channel id")
            if (message.bytes < 0) return Result.Bad("net.ack out of range")
            return Result.Ok(message)
        }
        if (message is ServerMessage.NetClose && message.ch.isEmpty()) {
            return Result.Bad("net.close without a channel id")
        }
        if (message is ServerMessage.TunnelOpened) {
            if (message.id.isEmpty()) return Result.Bad("incomplete tunnel.opened")
            if (message.port < Protocol.MIN_PORT || message.port > Protocol.MAX_PORT) {
                return Result.Bad("tunnel.opened with an unusable port")
            }
            return Result.Ok(message)
        }
        if (message is ServerMessage.TunnelClosed && message.id.isEmpty()) {
            return Result.Bad("tunnel.closed without an id")
        }
        if (message !is ServerMessage.CredentialRequest) return Result.Ok(message)
        if (message.id.isEmpty()) return Result.Bad("credential.request without an id")
        if (message.host.isEmpty() || message.host.length > Protocol.MAX_CREDENTIAL_HOST_LENGTH) {
            return Result.Bad("credential.request without a usable host")
        }
        val repo = message.repo?.takeIf { it.isNotEmpty() && it.length <= Protocol.MAX_CREDENTIAL_REPO_LENGTH }
        return Result.Ok(if (repo == message.repo) message else message.copy(repo = repo))
    }

    /**
     * Whether a string is base64 the way the desktop's `BASE64_RE` means it.
     *
     * Checked rather than decoded-and-caught, because the point is to refuse before the bytes are
     * allocated: a 32 KiB string that turns out not to be base64 should cost a scan, not a decode
     * and an exception on the socket's own thread.
     */
    private fun isBase64(value: String): Boolean {
        if (value.isEmpty() || value.length % 4 != 0) return false
        var padding = 0
        for (index in value.indices) {
            val ch = value[index]
            when {
                ch == '=' -> {
                    padding += 1
                    // Padding is only ever the last one or two characters. A `=` anywhere else is a
                    // string that decodes to something other than what it looks like.
                    if (padding > 2 || index < value.length - 2) return false
                }
                padding > 0 -> return false
                ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '+' || ch == '/' -> Unit
                else -> return false
            }
        }
        return true
    }

    /**
     * Whether a frame names a session id this build is willing to route.
     *
     * The desktop validates ids on the way in; this validates them on the way back, because the
     * ids arriving here are used as map keys against live [dev.terminaldeck.android.session]
     * objects and a frame naming a session we never attached to is either a bug over there or
     * something that is not the desktop.
     */
    fun sessionIdOf(message: ServerMessage): String? = when (message) {
        is ServerMessage.Attached -> message.id
        is ServerMessage.Detached -> message.id
        is ServerMessage.Output -> message.id
        is ServerMessage.Status -> message.id
        is ServerMessage.Exit -> message.id
        is ServerMessage.Closed -> message.id
        // Not routed like the others — nothing is attached to it yet — but it is the id the phone
        // is about to navigate to, and an id that would be refused by `attach` must not become a
        // route argument.
        is ServerMessage.Created -> message.session.id
        else -> null
    }?.takeIf { Protocol.isValidSessionId(it) }
}
