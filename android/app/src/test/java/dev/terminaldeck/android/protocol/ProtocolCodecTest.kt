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
                capabilities = listOf("credential"),
            )
        )
        assertEquals(
            """{"t":"hello","protocol":1,"token":"abc","device":{"name":"Pixel","platform":"android"},""" +
                """"capabilities":["credential"]}""",
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

    /**
     * The three answers about folders, kept apart at the parser.
     *
     * Absent is a desktop older than the field; empty is a person having removed every folder. They
     * arrive one key apart and mean opposite things — "carry on as before" against "nothing will
     * start here" — so this is the first place they could be flattened into each other.
     */
    @Test
    fun `welcome carries the folder grant, and absent is not the same as empty`() {
        val granted = (ServerFrames.parse(
            """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Pixel","token":null,"sessions":[],"folders":["/Users/asad/Projects/api"]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals(listOf("/Users/asad/Projects/api"), granted.folders)

        val emptied = (ServerFrames.parse(
            """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Pixel","token":null,"sessions":[],"folders":[]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals(emptyList<String>(), emptied.folders)

        val silent = (ServerFrames.parse(
            """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Pixel","token":null,"sessions":[]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals(null, silent.folders)
    }

    @Test
    fun `the pushed folders frame parses, including the one that empties the list`() {
        val pushed = (ServerFrames.parse("""{"t":"folders","folders":["/one","/two"]}""")
            as ServerFrames.Result.Ok).message as ServerMessage.Folders
        assertEquals(listOf("/one", "/two"), pushed.folders)

        // The frame that takes the last folder away. It has to survive as an empty list rather than
        // as a dropped frame: it is the moment the picker must stop offering anything.
        val emptied = (ServerFrames.parse("""{"t":"folders","folders":[]}""")
            as ServerFrames.Result.Ok).message as ServerMessage.Folders
        assertEquals(emptyList<String>(), emptied.folders)
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

    /* ---- capability `close` --------------------------------------------------------------- */

    @Test
    fun `close is tagged the way the desktop parses it`() {
        assertEquals("""{"t":"close","id":"s1"}""", ClientFrames.encode(ClientMessage.Close("s1")))
    }

    @Test
    fun `closed carries the id and is routed by it`() {
        val result = ServerFrames.parse("""{"t":"closed","id":"s1"}""")
        val message = (result as ServerFrames.Result.Ok).message as ServerMessage.Closed
        assertEquals("s1", message.id)
        // Routed like exit/status, so the session list can drop the row against the right session.
        assertEquals("s1", ServerFrames.sessionIdOf(message))
    }

    @Test
    fun `the close capability is the string the desktop advertises`() {
        assertEquals("close", Capability.CLOSE)
    }

    /* ---- capability `devices` ------------------------------------------------------------- */

    @Test
    fun `the devices verbs are tagged the way the desktop parses them`() {
        assertEquals("""{"t":"devices.list","rid":"r1"}""", ClientFrames.encode(ClientMessage.DevicesList("r1")))
        assertEquals(
            """{"t":"devices.revoke","rid":"r2","device":"d9"}""",
            ClientFrames.encode(ClientMessage.DevicesRevoke("r2", "d9")),
        )
        assertEquals("devices", Capability.DEVICES)
    }

    @Test
    fun `devices rows parse into the roster the screen reads`() {
        val raw = """{"t":"devices.rows","rid":"r1","devices":[""" +
            """{"id":"d1","name":"Pixel","kind":"mine","status":"approved","addedAt":10,""" +
            """"lastSeenAt":20,"connected":true,"fingerprint":"ab cd ef gh ij kl"},""" +
            """{"id":"d2","name":"Guest","kind":"guest","status":"pending","addedAt":30,""" +
            """"lastSeenAt":null,"connected":false,"fingerprint":null}]}"""
        val message = (ServerFrames.parse(raw) as ServerFrames.Result.Ok).message as ServerMessage.DevicesRows
        assertEquals("r1", message.rid)
        assertEquals(2, message.devices.size)
        val mine = message.devices[0]
        assertTrue(mine.isMine)
        assertTrue(!mine.isPending)
        assertEquals(20L, mine.lastSeenAt)
        val guest = message.devices[1]
        assertTrue(!guest.isMine)
        assertTrue(guest.isPending)
        assertEquals(null, guest.lastSeenAt)
        assertEquals(null, guest.fingerprint)
    }

    @Test
    fun `devices revoked carries the outcome and the fresh roster, and changed is unsolicited`() {
        val revoked = (ServerFrames.parse(
            """{"t":"devices.revoked","rid":"r3","ok":true,"message":"Removed.","devices":[]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.DevicesRevoked
        assertEquals("r3", revoked.rid)
        assertEquals(true, revoked.ok)
        assertEquals("Removed.", revoked.message)
        assertTrue(revoked.devices.isEmpty())

        val changed = (ServerFrames.parse(
            """{"t":"devices.changed","devices":[{"id":"d1","name":"Pixel","kind":"mine","status":"approved"}]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.DevicesChanged
        assertEquals(1, changed.devices.size)
        // addedAt/connected default when the frame omits them rather than failing the parse.
        assertEquals(0L, changed.devices[0].addedAt)
        assertEquals(false, changed.devices[0].connected)
    }

    /* ---- capability `settings` ------------------------------------------------------------ */

    @Test
    fun `the settings verbs are tagged the way the desktop parses them`() {
        assertEquals("""{"t":"settings.read","rid":"r1"}""", ClientFrames.encode(ClientMessage.SettingsRead("r1")))
        assertEquals(
            """{"t":"settings.apply","rid":"r2","key":"agents.defaultProvider","value":"codex"}""",
            ClientFrames.encode(ClientMessage.SettingsApply("r2", ServerSettingKey.DefaultProvider, "codex")),
        )
        assertEquals(
            """{"t":"settings.apply","rid":"r3","key":"general.restoreSessions","value":"true"}""",
            ClientFrames.encode(ClientMessage.SettingsApply("r3", ServerSettingKey.RestoreSessions, "true")),
        )
        assertEquals("settings", Capability.SETTINGS)
    }

    @Test
    fun `settings state parses the chooser with its options and the boolean without`() {
        val raw = """{"t":"settings.state","rid":"r1","settings":[""" +
            """{"key":"agents.defaultProvider","value":"claude","options":["claude","codex","gemini"]},""" +
            """{"key":"general.restoreSessions","value":"false"}]}"""
        val message = (ServerFrames.parse(raw) as ServerFrames.Result.Ok).message as ServerMessage.SettingsState
        assertEquals(2, message.settings.size)
        assertEquals("agents.defaultProvider", message.settings[0].key)
        assertEquals(ServerSettingKey.DefaultProvider, message.settings[0].known)
        assertEquals(listOf("claude", "codex", "gemini"), message.settings[0].options)
        assertEquals(ServerSettingKey.RestoreSessions, message.settings[1].known)
        assertEquals(null, message.settings[1].options)
    }

    @Test
    fun `a settings row naming a key outside the allowlist is dropped, not fatal to the frame`() {
        // Additive, the rule the whole protocol runs on: a future desktop adding a third server
        // setting must not stop an older phone reading the two it knows. The frame parses, the
        // unknown row survives decode as a free-string key, and `merge` drops it — leaving the known
        // one. A strict enum here would have failed the whole frame and hidden both settings.
        val raw = """{"t":"settings.state","rid":"r1","settings":[""" +
            """{"key":"remote.enabled","value":"true"},{"key":"general.restoreSessions","value":"false"}]}"""
        val message = (ServerFrames.parse(raw) as ServerFrames.Result.Ok).message as ServerMessage.SettingsState
        assertEquals(2, message.settings.size)
        assertEquals(null, message.settings[0].known)
        val drawn = ServerSettingWire.merge(null, message.settings)
        assertEquals(1, drawn.size)
        assertEquals(ServerSettingKey.RestoreSessions, drawn[0].known)
    }

    @Test
    fun `settings applied and changed parse`() {
        val applied = (ServerFrames.parse(
            """{"t":"settings.applied","rid":"r2","ok":false,"message":"No.","setting":{"key":"general.restoreSessions","value":"false"}}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.SettingsApplied
        assertEquals(false, applied.ok)
        assertEquals("No.", applied.message)
        assertEquals(ServerSettingKey.RestoreSessions, applied.setting.known)

        val changed = (ServerFrames.parse(
            """{"t":"settings.changed","settings":[{"key":"agents.defaultProvider","value":"shell"}]}"""
        ) as ServerFrames.Result.Ok).message as ServerMessage.SettingsChanged
        assertEquals("shell", changed.settings[0].value)
    }

    /* ---- welcome version fields ----------------------------------------------------------- */

    @Test
    fun `welcome carries the build and kind, and absent stays neutral`() {
        val full = """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Phone","token":null,""" +
            """"sessions":[],"capabilities":["close","devices","settings"],"hostPlatform":"win32",""" +
            """"appVersion":"0.10.0","hostKind":"headless","hostName":"studio-pc"}"""
        val message = (ServerFrames.parse(full) as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals("0.10.0", message.appVersion)
        assertEquals("headless", message.hostKind)
        assertEquals("studio-pc", message.hostName)

        val old = """{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"Phone","token":null,""" +
            """"sessions":[],"capabilities":[]}"""
        val older = (ServerFrames.parse(old) as ServerFrames.Result.Ok).message as ServerMessage.Welcome
        assertEquals(null, older.appVersion)
        assertEquals(null, older.hostKind)
        assertEquals(null, older.hostName)
    }
}
