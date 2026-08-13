package dev.terminaldeck.android.crypto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Interoperability with the Mac, checked against bytes the Mac's own code produced.
 *
 * The vectors in `sealed-fixtures.json` come out of `android/tools/gen-sealed-fixtures.cjs`, which
 * bundles `src/shared/sealed.ts` with esbuild and runs it under Node with the two ephemeral keys
 * pinned. Nothing in the fixture is computed by a second implementation of the schedule, so an
 * agreement here is an agreement with the code the desktop will actually run.
 *
 * Regenerate after any change to `sealed.ts`:
 *
 *     node android/tools/gen-sealed-fixtures.cjs
 */
class SealedInteropTest {

    private val fixtures: JsonObject = Json.parseToJsonElement(
        checkNotNull(javaClass.classLoader?.getResourceAsStream("sealed-fixtures.json")) {
            "sealed-fixtures.json is missing; run node android/tools/gen-sealed-fixtures.cjs"
        }.readBytes().decodeToString(),
    ).jsonObject

    private val keys = fixtures.field("keys").jsonObject
    private val handshake = fixtures.field("handshake").jsonObject

    private val mac = StaticKeyPair.fromPrivate(keys.hex("macStaticPrivate"))
    private val device = StaticKeyPair.fromPrivate(keys.hex("devicePrivate"))
    private val initiatorEphemeral = StaticKeyPair.fromPrivate(keys.hex("initiatorEphemeralPrivate"))
    private val responderEphemeral = StaticKeyPair.fromPrivate(keys.hex("responderEphemeralPrivate"))

    /* ------------------------------------------------------------- primitives -- */

    @Test
    fun `the protocol name and version match the desktop`() {
        assertEquals(fixtures.field("noiseName").jsonPrimitive.content, Sealed.NOISE_NAME)
        assertEquals(fixtures.field("sealedVersion").jsonPrimitive.int, Sealed.VERSION)
    }

    @Test
    fun `public keys derive to the same bytes OpenSSL produced`() {
        assertArrayEquals(keys.hex("macStaticPublic"), mac.publicKey)
        assertArrayEquals(keys.hex("devicePublic"), device.publicKey)
        assertArrayEquals(keys.hex("initiatorEphemeralPublic"), initiatorEphemeral.publicKey)
        assertArrayEquals(keys.hex("responderEphemeralPublic"), responderEphemeral.publicKey)
    }

    @Test
    fun `each Diffie-Hellman agrees with Node`() {
        for (vector in fixtures.field("dhVectors").array()) {
            val entry = vector.jsonObject
            assertArrayEquals(
                "dh ${entry.string("label")}",
                entry.hex("shared"),
                Sealed.dh(entry.hex("privateKey"), entry.hex("publicKey")),
            )
        }
    }

    /**
     * RFC 7748 §6.1. Node's OpenSSL refuses these before `sealed.ts` gets a chance to; Android's
     * XDH would not, and neither would a port that trusted its library, so this is the check that
     * has to exist on this side.
     */
    @Test
    fun `low-order points are refused rather than producing a shared key`() {
        val points = fixtures.field("lowOrder").array()
        assertTrue("the fixture carries no low-order points", points.isNotEmpty())
        for (point in points) {
            val entry = point.jsonObject
            try {
                Sealed.dh(initiatorEphemeral.privateKey, entry.hex("publicKey"))
                fail("accepted a low-order point: ${entry.string("publicKey")}")
            } catch (e: SealedException) {
                assertEquals("handshake failed authentication", e.message)
            }
        }
    }

    @Test
    fun `fingerprints read the same on both machines`() {
        for (entry in fixtures.field("fingerprints").array()) {
            val row = entry.jsonObject
            assertEquals(row.string("fingerprint"), Sealed.fingerprint(row.hex("publicKey")))
        }
    }

    /* -------------------------------------------------------------- handshake -- */

    @Test
    fun `the first handshake message is byte-identical to the one Node sent`() {
        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral)
        assertArrayEquals(handshake.hex("message"), initiator.message)
        assertEquals(Sealed.NOISE_MESSAGE_BYTES, initiator.message.size)
    }

    @Test
    fun `the reply is byte-identical and both ends derive the same directional keys`() {
        val answered = respondToHandshake(mac, handshake.hex("message"), responderEphemeral) { key ->
            key.contentEquals(device.publicKey)
        }
        assertArrayEquals(handshake.hex("reply"), answered.reply)
        assertArrayEquals(device.publicKey, answered.devicePublicKey)
        assertArrayEquals(handshake.hex("binding"), answered.channel.channelBinding)

        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral).finish(handshake.hex("reply"))
        assertArrayEquals(handshake.hex("binding"), initiator.channelBinding)

        // k1/k2 are checked through the wire rather than by reading private fields: the initiator
        // sealing under k1 must be openable by the responder receiving under k1, and a port that
        // mirrored them the wrong way round derives both keys correctly and reads nothing.
        val probe = initiator.send("k1".toByteArray())
        assertEquals("k1", String(answered.channel.receive(probe)))
        val back = answered.channel.send("k2".toByteArray())
        assertEquals("k2", String(initiator.receive(back)))
    }

    /**
     * The nonce layout, at the counters where a big-endian port would still look fine.
     *
     * Every recorded frame is compared in sequence, so reaching counter 512 means the port has
     * produced 513 consecutive frames whose nonces matched Node's.
     */
    @Test
    fun `sealed frames match Node byte for byte in both directions`() {
        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral).finish(handshake.hex("reply"))
        val responder = respondToHandshake(mac, handshake.hex("message"), responderEphemeral).channel

        replay(initiator, responder, fixtures.field("initiatorToResponder").array())
        replay(responder, initiator, fixtures.field("responderToInitiator").array())
    }

    private fun replay(sender: SealedChannel, receiver: SealedChannel, expected: JsonArray) {
        val byCounter = expected.associate { it.jsonObject.field("counter").jsonPrimitive.int to it.jsonObject }
        val total = fixtures.field("frameCount").jsonPrimitive.int
        var checked = 0
        for (counter in 0 until total) {
            val row = byCounter[counter]
            if (row == null) {
                // Not recorded, but still sent: the counter has to advance in lockstep or the
                // recorded frames further down would be sealed under the wrong nonce.
                receiver.receive(sender.send(ByteArray(0)))
                continue
            }
            val plaintext = row.string("plaintext")
            val frame = sender.sendText(plaintext)
            assertArrayEquals("frame at counter $counter", row.hex("frame"), frame)
            // And the same bytes Node sealed open on this side, which is the half that proves the
            // receive path rather than the send path.
            assertEquals(plaintext, receiver.receiveText(row.hex("frame")))
            checked += 1
        }
        assertEquals(byCounter.size, checked)
    }

    /* ------------------------------------------------------------- refusals -- */

    @Test
    fun `a tampered frame fails and does not advance the counter`() {
        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral).finish(handshake.hex("reply"))
        val responder = respondToHandshake(mac, handshake.hex("message"), responderEphemeral).channel

        val good = initiator.sendText("hello")
        val bent = good.copyOf()
        bent[3] = (bent[3].toInt() xor 0x01).toByte()

        try {
            responder.receive(bent)
            fail("opened a tampered frame")
        } catch (e: SealedException) {
            assertEquals("sealed frame failed authentication", e.message)
        }
        // The counter did not move, so the original still opens.
        assertEquals("hello", responder.receiveText(good))
    }

    @Test
    fun `a handshake from an unknown device is refused with the same sentence`() {
        val stranger = Sealed.generateStatic()
        val message = HandshakeInitiator(stranger, mac.publicKey).message
        try {
            respondToHandshake(mac, message, responderEphemeral) { false }
            fail("admitted an unknown device")
        } catch (e: SealedException) {
            assertEquals("handshake failed authentication", e.message)
        }
    }

    @Test
    fun `a reply from an impostor Mac does not open`() {
        val impostor = Sealed.generateStatic()
        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral)
        val forged = respondToHandshake(impostor, HandshakeInitiator(device, impostor.publicKey).message).reply
        try {
            initiator.finish(forged)
            fail("accepted a reply from a machine that does not hold the Mac's key")
        } catch (e: SealedException) {
            assertEquals("handshake reply failed authentication", e.message)
        }
    }

    @Test
    fun `wrong-length handshake material is refused before any key work`() {
        val initiator = HandshakeInitiator(device, mac.publicKey, initiatorEphemeral)
        try {
            initiator.finish(ByteArray(Sealed.NOISE_REPLY_BYTES - 1))
            fail("accepted a short reply")
        } catch (e: SealedException) {
            assertEquals("handshake reply was the wrong length", e.message)
        }
        try {
            respondToHandshake(mac, ByteArray(Sealed.NOISE_MESSAGE_BYTES + 1), responderEphemeral)
            fail("accepted a long message")
        } catch (e: SealedException) {
            assertEquals("handshake message was the wrong length", e.message)
        }
    }

    @Test
    fun `two handshakes with fresh ephemerals do not repeat a key`() {
        val first = HandshakeInitiator(device, mac.publicKey)
        val second = HandshakeInitiator(device, mac.publicKey)
        assertNotEquals(first.message.toHex(), second.message.toHex())

        val answered = respondToHandshake(mac, first.message)
        val channel = first.finish(answered.reply)
        assertEquals("live", String(answered.channel.receive(channel.send("live".toByteArray()))))
    }

    /* ---------------------------------------------------------------- helpers -- */

    private fun JsonObject.field(name: String) =
        checkNotNull(this[name]) { "the fixture has no $name; regenerate it" }

    private fun JsonObject.string(name: String) = field(name).jsonPrimitive.content

    private fun JsonObject.hex(name: String) = string(name).fromHex()

    private fun kotlinx.serialization.json.JsonElement.array() = this as JsonArray

    private fun String.fromHex(): ByteArray {
        val out = ByteArray(length / 2)
        for (i in out.indices) {
            out[i] = ((digit(this[i * 2]) shl 4) or digit(this[i * 2 + 1])).toByte()
        }
        return out
    }

    private fun digit(char: Char): Int = Character.digit(char, 16).also {
        require(it >= 0) { "not hex" }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
