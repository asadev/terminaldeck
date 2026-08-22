package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The four credential frames, byte for byte against `src/main/remote/protocol.ts`.
 *
 * The desktop's parser is the normative one and it closes the socket on a frame it cannot read, so
 * every one of these is a claim about what that parser will accept. The three that matter most are
 * not about happy paths:
 *
 *  - `hello.capabilities` has to reach the wire. `ProtocolJson` is configured with
 *    `encodeDefaults = false`, so a field carrying a default is a field that is silently not sent —
 *    and a desktop that does not see `credential` there never asks this phone anything. The whole
 *    feature would be dark on a build whose round-trip tests all passed.
 *  - `remember` has to be absent unless somebody pressed that button. The desktop reads
 *    `remember === true`, and the difference between the two taps is the entire consent model.
 *  - `credential.deny` has to carry its reason. `no-account` is not a refusal, and the desktop
 *    writes a different sentence for it — one that points at this phone rather than at the person
 *    who pushed.
 */
class CredentialWireTest {

    private fun encode(message: ClientMessage): String = ClientFrames.encode(message)

    private fun parse(raw: String): ServerMessage {
        val result = ServerFrames.parse(raw)
        assertTrue("expected a frame, got $result", result is ServerFrames.Result.Ok)
        return (result as ServerFrames.Result.Ok).message
    }

    /* ----------------------------------------------------------------- hello -- */

    @Test
    fun `hello carries the capabilities this phone can answer`() {
        val json = encode(
            ClientMessage.Hello(
                protocol = Protocol.VERSION,
                token = "device.secret",
                device = DeviceDescriptor(name = "Pixel", platform = "android"),
                capabilities = Capability.CLAIMED,
            )
        )
        assertTrue(
            "the field must reach the wire: $json",
            json.contains("\"capabilities\":[\"credential\",\"devices\",\"settings\",\"watch\"]"),
        )
    }

    @Test
    fun `the claimed list is only what the desktop pushes at this phone`() {
        // `create`, `localhost` and `upload` are things this phone asks for and are gated on the
        // desktop having advertised them, so claiming them here would say nothing at all. The four
        // that are here each have a frame the desktop *pushes* — `credential.request`,
        // `devices.changed`, `settings.changed`, `browser.frame` — and `server.ts` skips every
        // connection that did not claim the name before pushing one.
        //
        // Word for word `CLAIMED_CAPABILITIES` in `pwa/src/protocol-client.ts` and
        // `WireCapability.claimed` on iOS. The order is theirs too, because it is what reaches the
        // wire and three clients disagreeing about it is three different hellos.
        assertEquals(
            listOf(Capability.CREDENTIAL, Capability.DEVICES, Capability.SETTINGS, Capability.WATCH),
            Capability.CLAIMED,
        )
        assertEquals(listOf("credential", "devices", "settings", "watch"), Capability.CLAIMED)
    }

    /* ------------------------------------------------------------ the answers -- */

    @Test
    fun `an acknowledgement is the id and nothing else`() {
        assertEquals("""{"t":"credential.ack","id":"req-1"}""", encode(ClientMessage.CredentialAck("req-1")))
    }

    @Test
    fun `a plain approval does not write remember at all`() {
        val json = encode(ClientMessage.CredentialAnswer("req-1", "asadev", "gho_x", remember = false))
        assertFalse("a literal false would carry consent as its name: $json", json.contains("remember"))
        assertTrue(json.contains("\"username\":\"asadev\""))
        assertTrue(json.contains("\"password\":\"gho_x\""))
    }

    @Test
    fun `always writes remember as the literal true the desktop looks for`() {
        val json = encode(ClientMessage.CredentialAnswer("req-1", "asadev", "gho_x", remember = true))
        assertTrue(json, json.contains("\"remember\":true"))
    }

    @Test
    fun `a refusal always names which of the two things happened`() {
        assertTrue(
            encode(ClientMessage.CredentialDeny("req-1", CredentialDenial.Denied))
                .contains("\"reason\":\"denied\"")
        )
        assertTrue(
            // Absent would be read as `denied` on the desktop, which would turn "this phone has no
            // GitHub connected" into "somebody said no" — two different sentences with two
            // different fixes.
            encode(ClientMessage.CredentialDeny("req-1", CredentialDenial.NoAccount))
                .contains("\"reason\":\"no-account\"")
        )
    }

    /* ------------------------------------------------------------ the question -- */

    @Test
    fun `a request is read with every field the prompt draws`() {
        val message = parse(
            """{"t":"credential.request","id":"req-1","host":"github.com","repo":"asadev/terminaldeck",""" +
                """"operation":"write","prompt":true}"""
        )
        assertEquals(
            ServerMessage.CredentialRequest(
                id = "req-1",
                host = "github.com",
                repo = "asadev/terminaldeck",
                operation = CredentialOperation.Write,
                prompt = true,
            ),
            message,
        )
    }

    @Test
    fun `a repository the desktop could not name arrives as null rather than refused`() {
        // Null is a legitimate outcome the desktop passes along rather than papering over — a gist,
        // a wiki, a self-hosted layout. Refusing the frame would turn "this machine does not know
        // what the repository is called" into "that push is not answerable at all".
        val message = parse(
            """{"t":"credential.request","id":"req-1","host":"github.com","repo":null,"operation":"write","prompt":true}"""
        ) as ServerMessage.CredentialRequest
        assertNull(message.repo)
    }

    @Test
    fun `an absent prompt reads as silent`() {
        val message = parse(
            """{"t":"credential.request","id":"req-1","host":"github.com","operation":"read"}"""
        ) as ServerMessage.CredentialRequest
        assertFalse("interrupting a person is done only when the desktop says so", message.prompt)
        assertEquals(CredentialOperation.Read, message.operation)
    }

    @Test
    fun `an unreadable operation prompts rather than going quiet`() {
        // The direction of this default is chosen, not accidental, and it is the desktop's own:
        // prompting for a fetch costs one tap nobody needed, and *not* prompting for a push is the
        // entire feature not working.
        val message = parse(
            """{"t":"credential.request","id":"req-1","host":"github.com","operation":"sideways","prompt":true}"""
        ) as ServerMessage.CredentialRequest
        assertEquals(CredentialOperation.Write, message.operation)
    }

    @Test
    fun `a host longer than the wire allows is refused`() {
        val raw = """{"t":"credential.request","id":"r","host":"${"h".repeat(Protocol.MAX_CREDENTIAL_HOST_LENGTH + 1)}",""" +
            """"operation":"write","prompt":true}"""
        assertTrue(ServerFrames.parse(raw) is ServerFrames.Result.Bad)
    }

    @Test
    fun `a repository longer than the wire allows is folded onto null, not refused`() {
        // Same answer this client already has to draw for a repository the desktop could not name,
        // and the prompt says so out loud. A refusal would lose a push over a long string.
        val raw = """{"t":"credential.request","id":"r","host":"github.com",""" +
            """"repo":"${"a".repeat(Protocol.MAX_CREDENTIAL_REPO_LENGTH + 1)}","operation":"write","prompt":true}"""
        val message = parse(raw) as ServerMessage.CredentialRequest
        assertNull(message.repo)
    }

    @Test
    fun `a request with no id is refused because there is nothing to answer`() {
        val raw = """{"t":"credential.request","id":"","host":"github.com","operation":"write","prompt":true}"""
        assertTrue(ServerFrames.parse(raw) is ServerFrames.Result.Bad)
    }
}
