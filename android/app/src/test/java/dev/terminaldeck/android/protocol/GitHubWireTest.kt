package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `github.*` frames, against the shape the host speaks.
 *
 * The flip: the machine owns the GitHub login now, and this phone drives it. The three claims that
 * would break silently are the ones this covers first:
 *
 *  - `hello.capabilities` has to reach the wire and has to name `github`. `ProtocolJson` is
 *    configured with `encodeDefaults = false`, so a field carrying a default is silently not sent —
 *    and a host that does not see `github` there never pushes `github.changed`, so the login would
 *    look stale on a build whose round-trip tests all passed.
 *  - `credential` must be **gone** from the claimed list — a build still claiming it is telling the
 *    host to send a `credential.request` this client can no longer answer.
 *  - `github.state` and `github.changed` decode with every field the section draws, and a host that
 *    omits a field decodes rather than failing the frame — the additive rule.
 */
class GitHubWireTest {

    private fun encode(message: ClientMessage): String = ClientFrames.encode(message)

    private fun parse(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ----------------------------------------------------------------- hello -- */

    @Test
    fun `hello carries github in the capabilities it claims`() {
        val json = encode(
            ClientMessage.Hello(
                protocol = Protocol.VERSION,
                token = "device.secret",
                device = DeviceDescriptor(name = "Pixel", platform = "android"),
                capabilities = Capability.CLAIMED,
            )
        )
        assertTrue("the field must reach the wire: $json", json.contains("\"capabilities\":["))
        assertTrue("github must be claimed: $json", json.contains("\"github\""))
    }

    @Test
    fun `the claimed list is github plus the pushed-at names, and no longer credential`() {
        assertEquals(
            listOf(Capability.GITHUB, Capability.DEVICES, Capability.SETTINGS, Capability.WATCH),
            Capability.CLAIMED,
        )
        assertEquals(listOf("github", "devices", "settings", "watch"), Capability.CLAIMED)
        assertFalse("the phone no longer answers git logins", Capability.CLAIMED.contains("credential"))
    }

    /* -------------------------------------------------------------- requests -- */

    @Test
    fun `the four client verbs each carry their rid and their type`() {
        assertEquals("""{"t":"github.read","rid":"g1"}""", encode(ClientMessage.GithubRead("g1")))
        assertEquals("""{"t":"github.connect","rid":"g2"}""", encode(ClientMessage.GithubConnect("g2")))
        assertEquals("""{"t":"github.cancel","rid":"g3"}""", encode(ClientMessage.GithubCancel("g3")))
        assertEquals("""{"t":"github.disconnect","rid":"g4"}""", encode(ClientMessage.GithubDisconnect("g4")))
    }

    /* ---------------------------------------------------------------- states -- */

    @Test
    fun `a connected state is read with the account it names`() {
        val message = parse(
            """{"t":"github.state","rid":"g1","github":{"connected":true,"login":"octocat",""" +
                """"name":"The Octocat","source":"device","appConfigured":true}}"""
        ) as ServerMessage.GithubState
        assertEquals("g1", message.rid)
        assertTrue(message.github.connected)
        assertEquals("octocat", message.github.login)
        assertEquals("The Octocat", message.github.name)
        assertNull("no sign-in is in flight", message.github.pending)
    }

    @Test
    fun `a pending state carries the code and the url for the section to show`() {
        val message = parse(
            """{"t":"github.state","rid":"g2","github":{"connected":false,"appConfigured":true,""" +
                """"pending":{"userCode":"ABCD-1234","verificationUri":"https://github.com/login/device","expiresAt":1000}}}"""
        ) as ServerMessage.GithubState
        assertFalse(message.github.connected)
        assertEquals("ABCD-1234", message.github.pending?.userCode)
        assertEquals("https://github.com/login/device", message.github.pending?.verificationUri)
        assertEquals(1000L, message.github.pending?.expiresAt)
    }

    @Test
    fun `a host with no app configured comes through as a failure the section can show`() {
        val message = parse(
            """{"t":"github.state","rid":"g3","github":{"connected":false,"appConfigured":false,""" +
                """"failure":"No GitHub app is set up on this machine.","installUrl":"https://example.com/setup"}}"""
        ) as ServerMessage.GithubState
        assertFalse(message.github.appConfigured)
        assertEquals("No GitHub app is set up on this machine.", message.github.failure)
        assertEquals("https://example.com/setup", message.github.installUrl)
    }

    @Test
    fun `the unsolicited changed push is read with no rid`() {
        val message = parse(
            """{"t":"github.changed","github":{"connected":true,"login":"octocat"}}"""
        ) as ServerMessage.GithubChanged
        assertTrue(message.github.connected)
        assertEquals("octocat", message.github.login)
    }

    @Test
    fun `a state a future host trims to almost nothing still decodes, under the additive rule`() {
        // A host that sends only what it must — no login, no app flag, no pending — must not fail the
        // frame: every field carries a default, so this reads as "not connected" rather than as a
        // dropped frame.
        val message = parse("""{"t":"github.state","rid":"g4","github":{}}""") as ServerMessage.GithubState
        assertFalse(message.github.connected)
        assertNull(message.github.login)
        assertNull(message.github.pending)
    }

    @Test
    fun `an entirely absent github object defaults rather than failing the frame`() {
        val message = parse("""{"t":"github.changed"}""") as ServerMessage.GithubChanged
        assertFalse(message.github.connected)
    }
}
