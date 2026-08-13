package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire format, checked against the shapes `src/main/remote/protocol.ts` actually produces.
 *
 * These are string comparisons on purpose. The risk being tested is not that Kotlin can serialise a
 * data class — it is that the JSON this build emits differs by one key name from the JSON the
 * desktop's `parseClientMessage` will accept, which is a bug that compiles, passes any round-trip
 * test, and shows up as a socket that closes on the first keystroke.
 */
class ProtocolCodecTest {

    @Test
    fun `hello carries the tag the desktop switches on`() {
        val json = ClientFrames.encode(
            ClientMessage.Hello(
                protocol = 1,
                token = "abc",
                device = DeviceDescriptor(name = "Pixel", platform = "android"),
            )
        )
        assertEquals(
            """{"t":"hello","protocol":1,"token":"abc","device":{"name":"Pixel","platform":"android"}}""",
            json,
        )
    }

    @Test
    fun `list and ping serialise to a bare tag`() {
        assertEquals("""{"t":"list"}""", ClientFrames.encode(ClientMessage.List))
        assertEquals("""{"t":"ping"}""", ClientFrames.encode(ClientMessage.Ping))
    }

    /**
     * "both or neither, never one" — the desktop refuses an attach carrying a lone dimension with
     * `bad-message`, which closes the socket.
     */
    @Test
    fun `attach omits the size entirely when either dimension is missing`() {
        assertEquals("""{"t":"attach","id":"s1"}""", ClientFrames.encode(ClientMessage.attach("s1", null, null)))
        assertEquals("""{"t":"attach","id":"s1"}""", ClientFrames.encode(ClientMessage.attach("s1", 80, null)))
        assertEquals("""{"t":"attach","id":"s1"}""", ClientFrames.encode(ClientMessage.attach("s1", null, 24)))
        assertEquals(
            """{"t":"attach","id":"s1","cols":80,"rows":24}""",
            ClientFrames.encode(ClientMessage.attach("s1", 80, 24)),
        )
    }

    @Test
    fun `attach clamps a viewport the desktop would refuse`() {
        assertEquals(
            """{"t":"attach","id":"s1","cols":20,"rows":5}""",
            ClientFrames.encode(ClientMessage.attach("s1", 4, 1)),
        )
        assertEquals(
            """{"t":"attach","id":"s1","cols":500,"rows":200}""",
            ClientFrames.encode(ClientMessage.attach("s1", 9000, 9000)),
        )
    }

    @Test
    fun `welcome parses, including a null token`() {
        val raw = """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Mac","token":null,"sessions":[]}"""
        val result = ServerFrames.parse(raw)
        assertTrue(result is ServerFrames.Result.Ok)
        val message = (result as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals(null, message.token)
        assertEquals("Mac", message.deviceName)
    }

    @Test
    fun `output defaults replay to false when the desktop omits it`() {
        val live = ServerFrames.parse("""{"t":"output","id":"s1","data":"hi"}""")
        val replayed = ServerFrames.parse("""{"t":"output","id":"s1","data":"hi","replay":true}""")
        assertEquals(false, ((live as ServerFrames.Result.Ok).message as ServerMessage.Output).replay)
        assertEquals(true, ((replayed as ServerFrames.Result.Ok).message as ServerMessage.Output).replay)
    }

    @Test
    fun `error codes map from their hyphenated wire spelling`() {
        val result = ServerFrames.parse("""{"t":"error","code":"unknown-session","message":"nope"}""")
        val message = (result as ServerFrames.Result.Ok).message as ServerMessage.Error
        assertEquals(ProtocolErrorCode.UnknownSession, message.code)
    }

    /**
     * A future desktop refusing us for a reason this build has never heard of must still produce a
     * readable refusal, not a dropped frame.
     */
    @Test
    fun `an unrecognised error code becomes Unknown rather than a parse failure`() {
        val result = ServerFrames.parse("""{"t":"error","code":"teapot","message":"nope"}""")
        val message = (result as ServerFrames.Result.Ok).message as ServerMessage.Error
        assertEquals(ProtocolErrorCode.Unknown, message.code)
        assertEquals("nope", message.message)
    }

    @Test
    fun `garbage and unknown tags are refused rather than thrown`() {
        assertTrue(ServerFrames.parse("not json") is ServerFrames.Result.Bad)
        assertTrue(ServerFrames.parse("""{"t":"nonsense"}""") is ServerFrames.Result.Bad)
        assertTrue(ServerFrames.parse("[]") is ServerFrames.Result.Bad)
    }

    @Test
    fun `a frame over the message cap is refused without being parsed`() {
        val huge = "x".repeat(Protocol.MAX_MESSAGE_BYTES + 1)
        val result = ServerFrames.parse("""{"t":"output","id":"s1","data":"$huge"}""")
        assertTrue(result is ServerFrames.Result.Bad)
    }

    @Test
    fun `unknown keys do not break a frame this build can otherwise read`() {
        val result = ServerFrames.parse("""{"t":"attached","id":"s1","futureField":42}""")
        assertTrue(result is ServerFrames.Result.Ok)
    }
}

class ProtocolSizingTest {

    @Test
    fun `utf8Length agrees with the platform encoder`() {
        for (sample in listOf("", "ascii", "éüñ", "端末", "👩‍💻 family", "mixed 端 é 👍")) {
            assertEquals(sample, sample.toByteArray(Charsets.UTF_8).size, Protocol.utf8Length(sample))
        }
    }

    @Test
    fun `a lone high surrogate counts as the three bytes an encoder spends on it`() {
        val lone = "\uD83D"
        assertEquals(3, Protocol.utf8Length(lone))
    }

    @Test
    fun `overBytes catches a string whose units are under the cap but whose bytes are not`() {
        // 8,192 emoji: 16,384 UTF-16 units, 32,768 bytes. Under a 16 KiB cap by length, double it
        // by bytes — the case a length-only check waves through.
        val emoji = "👍".repeat(8_192)
        assertTrue(Protocol.overBytes(emoji, Protocol.MAX_INPUT_BYTES))
    }

    @Test
    fun `a normal keystroke is one input frame`() {
        assertEquals(1, ClientFrames.chunkInput("s1", "ls -la\r").size)
    }

    /** A split between the halves of a surrogate pair arrives at the shell as two U+FFFD. */
    @Test
    fun `chunkInput never splits a surrogate pair and loses nothing`() {
        val paste = "👍".repeat(6_000)
        val chunks = ClientFrames.chunkInput("s1", paste)
        assertTrue("expected more than one chunk", chunks.size > 1)
        for (chunk in chunks) {
            assertTrue("chunk over the input cap", !Protocol.overBytes(chunk.data, Protocol.MAX_INPUT_BYTES))
            assertTrue("chunk starts with a lone low surrogate", !chunk.data.first().isLowSurrogate())
            assertTrue("chunk ends with a lone high surrogate", !chunk.data.last().isHighSurrogate())
        }
        assertEquals(paste, chunks.joinToString("") { it.data })
    }

    @Test
    fun `session ids are validated the way the desktop validates them`() {
        assertTrue(Protocol.isValidSessionId("9f3c1a2e-4b7d-4c1a-9e2f-0a1b2c3d4e5f"))
        assertTrue(Protocol.isValidSessionId("a"))
        assertTrue(!Protocol.isValidSessionId(""))
        assertTrue(!Protocol.isValidSessionId("-leading-hyphen"))
        assertTrue(!Protocol.isValidSessionId("has space"))
        assertTrue(!Protocol.isValidSessionId("../../etc/passwd"))
        assertTrue(!Protocol.isValidSessionId("a".repeat(65)))
        assertTrue(Protocol.isValidSessionId("a".repeat(64)))
        // Anchoring: a newline must not let a bad id pass by matching only its first line.
        assertTrue(!Protocol.isValidSessionId("good\nbad id"))
    }
}
