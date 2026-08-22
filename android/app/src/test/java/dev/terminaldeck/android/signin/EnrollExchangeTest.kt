package dev.terminaldeck.android.signin

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceDescriptor
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ProtocolErrorCode
import dev.terminaldeck.android.protocol.ProtocolJson
import dev.terminaldeck.android.protocol.ServerFrames
import dev.terminaldeck.android.protocol.ServerMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sign-in driver: the fixed frame sequence, and the ways it can end.
 *
 * A port of `pwa/src/signin.test.ts` and of iOS's `SignInLinkTests.swift`, asking the same questions
 * in the same order — because three clients implementing one wire is safe when they fail on the
 * drift, and not when nobody edits any of them.
 */
class EnrollExchangeTest {

    private val device = DeviceDescriptor(name = "Pixel", platform = "android")

    private fun input(method: EnrollMethod = EnrollMethod.Password) = EnrollExchange.Input(
        username = "asad",
        secret = if (method == EnrollMethod.Password) "hunter2" else "-----BEGIN OPENSSH PRIVATE KEY-----",
        method = method,
        device = device,
    )

    private val sent = mutableListOf<ClientMessage>()
    private var outcome: EnrollExchange.Outcome? = null
    private val exchange = EnrollExchange(send = { sent += it }, onOutcome = { outcome = it })

    private fun welcome() = ServerMessage.Welcome(
        protocol = Protocol.VERSION,
        deviceId = "dev-9",
        deviceName = "Pixel",
        token = null,
        sessions = emptyList(),
        capabilities = listOf("create"),
    )

    /* ------------------------------------------------------------ the happy path -- */

    @Test
    fun `it opens with enroll, carrying the login and this device`() {
        exchange.start(input())
        val first = sent.single() as ClientMessage.Enroll
        assertEquals(Protocol.VERSION, first.protocol)
        assertEquals("asad", first.username)
        assertEquals("hunter2", first.secret)
        assertEquals(EnrollMethod.Password, first.method)
        assertEquals(device, first.device)
        // The same list `hello` claims. A server that never sees `credential` here will not send
        // `credential.request` — the approval prompt would simply never appear.
        assertEquals(Capability.CLAIMED, first.capabilities)
    }

    @Test
    fun `enrolled is answered with a hello carrying the minted credential, on the same socket`() {
        exchange.start(input())
        exchange.receive(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"))

        val hello = sent.last() as ClientMessage.Hello
        assertEquals("dev-9.secret", hello.token)
        assertEquals(device, hello.device)
        assertEquals(Capability.CLAIMED, hello.capabilities)
        // Not finished yet. A credential stored on the strength of `enrolled` alone is a pairing
        // that looks done on screen and fails at the next launch.
        assertNull(outcome)
    }

    @Test
    fun `the welcome is what settles it, and it carries the server's own facts`() {
        exchange.start(input())
        exchange.receive(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"))
        exchange.receive(welcome())

        val signedIn = outcome as EnrollExchange.Outcome.SignedIn
        assertEquals("dev-9.secret", signedIn.credential)
        assertEquals("dev-9", signedIn.deviceId)
        assertEquals("Pixel", signedIn.deviceName)
        assertEquals(listOf("create"), signedIn.welcome.capabilities)
    }

    /* ---------------------------------------------------------------- refusals -- */

    @Test
    fun `a refusal ends it in the server's own words`() {
        exchange.start(input())
        exchange.receive(
            ServerMessage.Error(
                code = ProtocolErrorCode.Unauthorized,
                message = "That sign-in was refused. Check the username, and the password or key, then try again.",
            )
        )
        val refused = outcome as EnrollExchange.Outcome.Refused
        assertTrue(refused.sentence.startsWith("That sign-in was refused."))
    }

    /**
     * `bad-message` is the one code that is not about the login.
     *
     * A server too old to know `enroll` hits its parser's default case and refuses with it. Telling
     * somebody their password was wrong at that point sends them to change a password that was never
     * the problem.
     */
    @Test
    fun `a server too old to know enroll is reported as too old, not as a bad password`() {
        exchange.start(input())
        exchange.receive(ServerMessage.Error(code = ProtocolErrorCode.BadMessage, message = "unknown message"))
        val refused = outcome as EnrollExchange.Outcome.Refused
        assertEquals(EnrollExchange.TOO_OLD, refused.sentence)
    }

    @Test
    fun `a refusal after the hello ends it too`() {
        exchange.start(input())
        exchange.receive(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"))
        exchange.receive(ServerMessage.Error(code = ProtocolErrorCode.Unauthenticated, message = "no"))
        assertTrue(outcome is EnrollExchange.Outcome.Refused)
    }

    @Test
    fun `a socket that goes mid-exchange settles it rather than leaving a spinner`() {
        exchange.start(input())
        exchange.connectionLost("The connection dropped.")
        assertEquals(EnrollExchange.Outcome.Refused("The connection dropped."), outcome)
    }

    /* -------------------------------------------------------------- stray frames -- */

    /**
     * Until the welcome lands the socket is unauthenticated — the server says so itself. A frame
     * that arrives before it is dropped rather than acted on, because acting on one would be acting
     * on an unauthenticated socket.
     */
    @Test
    fun `a stray frame before the welcome is dropped`() {
        exchange.start(input())
        exchange.receive(ServerMessage.Sessions(emptyList()))
        assertNull(outcome)
        assertEquals(1, sent.size)

        exchange.receive(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"))
        exchange.receive(welcome())
        assertTrue(outcome is EnrollExchange.Outcome.SignedIn)
    }

    @Test
    fun `it settles exactly once`() {
        var settlements = 0
        val once = EnrollExchange(send = {}, onOutcome = { settlements += 1 })
        once.start(input())
        once.receive(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"))
        once.receive(welcome())
        once.receive(welcome())
        once.receive(ServerMessage.Error(code = ProtocolErrorCode.Unauthorized, message = "late"))
        assertEquals(1, settlements)
    }

    /* ----------------------------------------------------------------- the wire -- */

    /**
     * The frame as bytes, against the desktop's own field names.
     *
     * The Kotlin type could be perfect and the wire still wrong: `ProtocolJson` is configured with
     * `encodeDefaults = false`, so a field that carried a default would silently not be written —
     * which is how a hello without a protocol version ships and closes every socket it opens.
     */
    @Test
    fun `the enroll frame is the one protocol_ts describes`() {
        exchange.start(input(EnrollMethod.Key))
        val json = ProtocolJson.encodeToString(ClientMessage.serializer(), sent.single())
        assertTrue(json, json.contains("\"t\":\"enroll\""))
        assertTrue(json, json.contains("\"protocol\":1"))
        assertTrue(json, json.contains("\"method\":\"key\""))
        assertTrue(json, json.contains("\"username\":\"asad\""))
        assertTrue(json, json.contains("\"platform\":\"android\""))
    }

    /** And the answer, read back through the parser every inbound frame goes through. */
    @Test
    fun `an enrolled frame parses, and a half-formed one is refused`() {
        val good = """{"t":"enrolled","deviceId":"dev-9","deviceName":"Pixel","credential":"dev-9.secret"}"""
        val parsed = ServerFrames.parse(good) as ServerFrames.Result.Ok
        assertEquals(ServerMessage.Enrolled("dev-9", "Pixel", "dev-9.secret"), parsed.message)

        // A credential is what this phone would store behind the Keystore, so a frame missing one is
        // refused rather than kept half-formed.
        val empty = """{"t":"enrolled","deviceId":"dev-9","deviceName":"Pixel","credential":""}"""
        assertTrue(ServerFrames.parse(empty) is ServerFrames.Result.Bad)

        // And a hostile host cannot hand this phone a megabyte to keep.
        val huge = """{"t":"enrolled","deviceId":"d","deviceName":"P","credential":"${"x".repeat(Protocol.MAX_ENROLL_CREDENTIAL_LENGTH + 1)}"}"""
        assertTrue(ServerFrames.parse(huge) is ServerFrames.Result.Bad)
    }
}
