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

    fun parse(raw: String): Result {
        if (Protocol.overBytes(raw, Protocol.MAX_MESSAGE_BYTES)) {
            return Result.Bad("frame over the message limit")
        }
        return try {
            Result.Ok(ProtocolJson.decodeFromString<ServerMessage>(raw))
        } catch (e: SerializationException) {
            Result.Bad("not a server message")
        } catch (e: IllegalArgumentException) {
            Result.Bad("not a server message")
        }
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
        else -> null
    }?.takeIf { Protocol.isValidSessionId(it) }
}
