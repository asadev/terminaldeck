package dev.terminaldeck.android.store

import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.StaticKeyPair
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The collection on disk, and the two things it must never get wrong.
 *
 * Both are about what happens across a write and a relaunch: a second pairing that drops the first,
 * and a blob written by the single-host build that stops decoding. Neither could be tested at all
 * while reading the file required the Android Keystore, which is why [VaultCipher] is an interface
 * and this file passes an honest no-op through it.
 */
class DeviceVaultTest {

    @get:Rule
    val temp = TemporaryFolder()

    /** No encryption, so the collection logic can be exercised on a plain JVM. See [VaultCipher]. */
    private class PlainCipher : VaultCipher {
        override fun seal(plaintext: ByteArray): ByteArray = plaintext
        override fun open(blob: ByteArray): ByteArray? = blob
    }

    private fun vault(file: File) = FileDeviceVault(file, PlainCipher())

    private fun file() = File(temp.root, "device-vault.v1.bin")

    private fun key(fill: Byte) = ByteArray(32) { fill }

    private companion object {
        const val MAC = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val PC = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"

        fun base64(bytes: ByteArray): String =
            java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /* ------------------------------------------------------- adding never removes -- */

    @Test
    fun `pairing a second machine leaves the first exactly as it was`() {
        val vault = vault(file())
        vault.beginPairing(MAC, key(1), "wss://relay.example", "token-mac")
        vault.storeCredential(MAC, "durable.mac", "device-1", "Pixel")
        vault.markApproved(MAC)

        vault.beginPairing(PC, key(2), "wss://relay.other", "token-pc")

        val hosts = vault.pairings()
        assertEquals(listOf(MAC, PC), hosts.map { it.hostId })
        val mac = hosts.first()
        assertEquals("durable.mac", mac.token)
        assertTrue("the first machine must still be approved", mac.approved)
        assertEquals("Pixel", mac.deviceName)
        assertArrayEquals(key(1), mac.hostStaticPublicKey)
    }

    /** The relaunch is when the loss would actually be noticed. */
    @Test
    fun `both machines come back off disk`() {
        val target = file()
        val first = vault(target)
        first.beginPairing(MAC, key(1), "wss://relay.example", "token-mac")
        first.beginPairing(PC, key(2), "wss://relay.other", "token-pc")
        val identity = first.identity().publicKey

        val relaunched = vault(target)
        assertEquals(listOf(MAC, PC), relaunched.pairings().map { it.hostId })
        assertArrayEquals("the device key is the phone's name, not a machine's", identity, relaunched.identity().publicKey)
    }

    /** A re-pair after a revoke is normal, and must not cost a row or a name. */
    @Test
    fun `re-pairing keeps a machine's place and its nickname`() {
        val vault = vault(file())
        vault.beginPairing(MAC, key(1), "wss://relay.example", "token-mac")
        vault.beginPairing(PC, key(2), "wss://relay.other", "token-pc")
        vault.rename(MAC, "Studio")

        vault.beginPairing(MAC, key(1), "wss://relay.example", "token-mac-2")

        val hosts = vault.pairings()
        assertEquals("no duplicate row for one computer", listOf(MAC, PC), hosts.map { it.hostId })
        assertEquals("Studio", hosts.first().nickname)
        assertEquals("token-mac-2", hosts.first().token)
        assertEquals("token-pc", hosts.last().token)
    }

    @Test
    fun `forgetting one machine keeps the others and the device key`() {
        val vault = vault(file())
        vault.beginPairing(MAC, key(1), "wss://relay.example", "token-mac")
        vault.beginPairing(PC, key(2), "wss://relay.other", "token-pc")
        vault.selectHost(MAC)
        val identity = vault.identity().publicKey

        vault.forget(MAC)

        assertEquals(listOf(PC), vault.pairings().map { it.hostId })
        assertNull("the selection cannot point at a machine that is gone", vault.selectedHost())
        assertArrayEquals(identity, vault.identity().publicKey)
    }

    /**
     * Unpairing from everything rotates the key; forgetting one must not.
     *
     * A public key a machine still lists is a device it would let back in without a code — so a
     * phone that has left every machine should stop being that device, and a phone that has left one
     * must not become a stranger on the others to do it.
     */
    @Test
    fun `unpairing everything rotates the device key`() {
        val vault = vault(file())
        vault.beginPairing(MAC, key(1), "wss://relay.example", "token-mac")
        val identity = vault.identity().publicKey

        vault.unpairAll()

        assertTrue(vault.pairings().isEmpty())
        assertFalse("the phone should stop being the device every machine trusted",
            identity.contentEquals(vault.identity().publicKey))
    }

    /* ------------------------------------------------------------------ migration -- */

    /**
     * A phone that has been paired for weeks updates into this build and must still have its Mac.
     *
     * The version-1 blob held one machine in top-level fields. Nothing about that shape is
     * reconstructible after the fact, so the fields are still declared and read by
     * `VaultData.folded` — and this is the test that fails if somebody deletes them for being
     * unused.
     */
    @Test
    fun `a single-host blob migrates into the collection`() {
        val privateKey = Sealed.generateStatic().privateKey
        val target = file()
        target.writeBytes(
            """
            {
              "version": 1,
              "devicePrivateKey": "${base64(privateKey)}",
              "hostId": "$MAC",
              "hostStaticPublicKey": "${base64(key(9))}",
              "relayUrl": "wss://relay.example",
              "token": "durable.mac",
              "deviceId": "device-1",
              "deviceName": "Pixel 8",
              "approved": true,
              "pairedAt": 1700000000000
            }
            """.trimIndent().toByteArray()
        )

        val vault = vault(target)
        val hosts = vault.pairings()

        assertEquals(1, hosts.size)
        val mac = hosts.single()
        assertEquals(MAC, mac.hostId)
        assertEquals("durable.mac", mac.token)
        assertEquals("Pixel 8", mac.deviceName)
        assertTrue(mac.approved)
        assertEquals(1700000000000L, mac.pairedAt)
        assertArrayEquals(key(9), mac.hostStaticPublicKey)
        assertEquals("the only machine there is, is the one to come back to", MAC, vault.selectedHost())
        assertArrayEquals(
            "the device key must survive the migration, or every machine forgets this phone",
            StaticKeyPair.fromPrivate(privateKey).publicKey,
            vault.identity().publicKey,
        )
    }

    /** And the migrated machine keeps its place when a second one is added on top of it. */
    @Test
    fun `a migrated machine is the oldest, and survives another pairing and a relaunch`() {
        val target = file()
        target.writeBytes(
            """
            {"version":1,"devicePrivateKey":"${base64(Sealed.generateStatic().privateKey)}",
             "hostId":"$MAC","hostStaticPublicKey":"${base64(key(9))}",
             "relayUrl":"wss://relay.example","token":"durable.mac","approved":true}
            """.trimIndent().toByteArray()
        )

        val vault = vault(target)
        vault.beginPairing(PC, key(2), "wss://relay.other", "token-pc")

        val relaunched = vault(target)
        assertEquals(listOf(MAC, PC), relaunched.pairings().map { it.hostId })
        assertNotNull(relaunched.pairing(MAC))
        assertTrue(relaunched.pairing(MAC)!!.approved)

        // Rewritten in the new shape rather than left for the next pairing to deal with, so a phone
        // that migrates and is never paired again is not one restore away from depending on code
        // that has been deleted.
        val written = target.readBytes().decodeToString()
        assertTrue("the payload should now say version 2", written.contains("\"version\":2"))
    }

    /**
     * A blob this build cannot read means one thing to a caller, whatever the reason.
     *
     * Not "regenerate a key and carry on": that produces a phone that fails authentication forever
     * with no explanation. It reports unpaired, which is a thing a person can act on.
     */
    @Test
    fun `an unreadable blob reports unpaired rather than pretending`() {
        val target = file()
        target.writeBytes("this is not a vault".toByteArray())

        val vault = vault(target)
        assertTrue(vault.pairings().isEmpty())
        assertNotNull("a fresh identity is created, and it is honest about being fresh", vault.identity())
    }
}
