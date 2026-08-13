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

    /* ---- capability `create` ------------------------------------------------------------- */

    /**
     * The tag and the capability that gates it, both spelled the way the desktop spells them.
     *
     * This build sent `{"t":"new"}` gated on `session.create` for weeks and no desktop ever
     * advertised either — both were invented against this repo's own stand-in host. A string
     * comparison is the only kind of test that catches that class of mistake: the wrong tag compiles,
     * round-trips against itself, and closes the socket on the first tap.
     */
    @Test
    fun `create is tagged the way the desktop parses it`() {
        assertEquals("""{"t":"create"}""", ClientFrames.encode(ClientMessage.create(null, null, null)))
        assertEquals(
            """{"t":"create","cwd":"/Users/apple/Projects/terminaldeck"}""",
            ClientFrames.encode(ClientMessage.create("/Users/apple/Projects/terminaldeck", null, null)),
        )
        assertEquals(
            """{"t":"create","cwd":"/tmp/p","cols":80,"rows":24}""",
            ClientFrames.encode(ClientMessage.create("/tmp/p", 80, 24)),
        )
    }

    @Test
    fun `create omits the size entirely when either dimension is missing`() {
        assertEquals("""{"t":"create"}""", ClientFrames.encode(ClientMessage.create(null, 80, null)))
        assertEquals("""{"t":"create"}""", ClientFrames.encode(ClientMessage.create(null, null, 24)))
    }

    @Test
    fun `the create capability is the string the desktop advertises`() {
        // Not `session.create`. To an installed build that name still means "answers `new`", so
        // reusing it for this shape would light the button up and then refuse the frame it sends.
        assertEquals("create", Capability.CREATE)
    }

    @Test
    fun `created carries a whole session row`() {
        val raw = """{"t":"created","session":{"id":"s9","title":"deck","cwd":"/tmp","provider":"shell","status":"idle","exitCode":null}}"""
        val message = (ServerFrames.parse(raw) as ServerFrames.Result.Ok).message as ServerMessage.Created
        assertEquals("s9", message.session.id)
        assertEquals("/tmp", message.session.cwd)
        // The id is what the phone is about to navigate to, so it goes through the same shape check
        // an `attach` id would.
        assertEquals("s9", ServerFrames.sessionIdOf(message))
    }

    @Test
    fun `unavailable is a code this build understands rather than Unknown`() {
        // The desktop uses it for "would have, and could not" — a folder deleted since it was
        // listed. Mapping it to Unknown would be fine for display and wrong for meaning: it is the
        // one refusal worth retrying.
        val result = ServerFrames.parse("""{"t":"error","code":"unavailable","message":"gone"}""")
        val message = (result as ServerFrames.Result.Ok).message as ServerMessage.Error
        assertEquals(ProtocolErrorCode.Unavailable, message.code)
        assertTrue(!message.code.isFatal)
    }

    /* ---- capability `upload` ------------------------------------------------------------- */

    @Test
    fun `the upload frames are tagged the way the desktop parses them`() {
        assertEquals(
            """{"t":"upload.begin","id":"u1","name":"clip.mov","size":4096}""",
            ClientFrames.encode(ClientMessage.UploadBegin("u1", "clip.mov", 4096)),
        )
        assertEquals(
            """{"t":"upload.data","id":"u1","data":"AAEC"}""",
            ClientFrames.encode(ClientMessage.UploadData("u1", "AAEC")),
        )
        assertEquals(
            """{"t":"upload.end","id":"u1","sha256":"ab"}""",
            ClientFrames.encode(ClientMessage.UploadEnd("u1", "ab")),
        )
        assertEquals("""{"t":"upload.cancel","id":"u1"}""", ClientFrames.encode(ClientMessage.UploadCancel("u1")))
    }

    @Test
    fun `the upload answers parse into the shapes the progress row reads`() {
        val ready = (ServerFrames.parse("""{"t":"upload.ready","id":"u1","path":"/D/Terminal Deck/a.mov"}""")
            as ServerFrames.Result.Ok).message as ServerMessage.UploadReady
        assertEquals("/D/Terminal Deck/a.mov", ready.path)

        val ack = (ServerFrames.parse("""{"t":"upload.ack","id":"u1","bytes":24576}""")
            as ServerFrames.Result.Ok).message as ServerMessage.UploadAck
        assertEquals(24_576, ack.bytes)

        val done = (ServerFrames.parse("""{"t":"upload.done","id":"u1","path":"/D/a.mov","bytes":9,"sha256":"ff"}""")
            as ServerFrames.Result.Ok).message as ServerMessage.UploadDone
        assertEquals(9L, done.bytes)
        assertEquals("ff", done.sha256)

        // The sentence is what the user reads, and its absence must not lose the frame: the
        // *failing* is the message.
        val bare = (ServerFrames.parse("""{"t":"upload.failed","id":"u1"}""")
            as ServerFrames.Result.Ok).message as ServerMessage.UploadFailed
        assertTrue(bare.message.isNotEmpty())
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
    fun `a normal paste is not refused, and an enormous one is refused with both numbers`() {
        assertEquals(null, pasteRefusal("a stack trace\nwith a few lines\n"))
        // Exactly at the cap still goes: the boundary is inclusive, and a paste refused for being
        // exactly the size the message says is allowed is a message nobody believes twice.
        assertEquals(null, pasteRefusal("a".repeat(Protocol.MAX_PASTE_BYTES)))
        val refusal = pasteRefusal("a".repeat(Protocol.MAX_PASTE_BYTES + 1))
        assertTrue("an oversized paste must be refused", refusal != null)
        assertTrue("the refusal must name the limit: " + refusal, refusal!!.contains("1.0 MB"))
    }

    @Test
    fun `the paste cap counts bytes, so an emoji clipboard is not four times the limit`() {
        // 300,000 four-byte code points are 1.2 MB and 600,000 UTF-16 units. A length check would
        // wave it through and the Mac would drop the phone for buffering.
        val emoji = "\uD83D\uDC4D".repeat(300_000)
        assertTrue(pasteRefusal(emoji) != null)
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
