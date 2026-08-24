package dev.terminaldeck.android.servers

import dev.terminaldeck.android.store.VaultCipher
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
 * What survives a relaunch, what never reaches the disk in the clear, and what a lost wrapping key
 * means.
 *
 * The cipher is a stand-in — the real one is the Android Keystore, which does not exist on this
 * classpath — and that split is the whole reason `FileServerStore` takes a [VaultCipher] rather
 * than reaching for the Keystore itself. `FileDeviceVault` makes the same argument: the two things
 * this must never get wrong are both about what happens across a write and a relaunch, and neither
 * can be tested at all while reading the file requires hardware.
 */
class ServerStoreTest {

    @get:Rule
    val folder = TemporaryFolder()

    /** Reversible, and *not* a no-op: a test that sealed nothing could not tell plaintext from not. */
    private class XorCipher(private val key: Byte = 0x5A) : VaultCipher {
        override fun seal(plaintext: ByteArray): ByteArray =
            ByteArray(plaintext.size) { (plaintext[it].toInt() xor key.toInt()).toByte() }

        override fun open(blob: ByteArray): ByteArray? =
            ByteArray(blob.size) { (blob[it].toInt() xor key.toInt()).toByte() }
    }

    private class DeadCipher : VaultCipher {
        override fun seal(plaintext: ByteArray): ByteArray = plaintext
        override fun open(blob: ByteArray): ByteArray? = null
    }

    private companion object {
        const val PASSWORD = "correct-horse-battery-staple"
        val hostKey = SshHostKey("ssh-ed25519", "SHA256:2SVIWmbzp3lk5gc4A+qWSV57+M1XBH9ifoD16FGA/9Y")
    }

    private lateinit var file: File

    private fun store(cipher: VaultCipher = XorCipher()) =
        FileServerStore(file, cipher) { 1_000L }

    @org.junit.Before
    fun setUp() {
        file = File(folder.newFolder(), "servers.bin")
    }

    private fun add(
        store: ServerStore,
        address: String = "178.105.239.176",
        port: Int? = null,
        username: String = "root",
        secret: String = PASSWORD,
    ) = store.add(
        name = "hetzner",
        address = address,
        port = port,
        username = username,
        secret = secret,
        kind = ServerCredentialKind.PASSWORD,
        hostKey = hostKey,
    )

    /* -------------------------------------------------------------- writing -- */

    @Test
    fun `a server and its sign-in survive a relaunch`() {
        val id = add(store()).id

        val fresh = store()
        val server = fresh.load(id)

        assertNotNull(server)
        assertEquals("178.105.239.176", server!!.address)
        assertEquals(22, server.port)
        assertEquals(hostKey.fingerprint, server.hostKey?.fingerprint)
        assertEquals(PASSWORD, fresh.secret(id))
    }

    /**
     * The password never reaches the disk in the clear.
     *
     * The one thing in this app that is somebody's *actual server password*. A store that wrote it
     * plainly would be leaving it in a file readable by anything that can read the app's data
     * directory, and it would survive being copied off a rooted phone intact.
     */
    @Test
    fun `nothing readable is on disk`() {
        add(store())

        val raw = file.readBytes().toString(Charsets.ISO_8859_1)

        assertFalse(raw.contains(PASSWORD))
        assertFalse(raw.contains("178.105.239.176"))
        assertFalse(raw.contains("root"))
    }

    /**
     * The same login twice is the same server.
     *
     * Identity is address, port and account, because that triple is what a connection is made of.
     * What is refreshed is the credential and the host key — the two things the new sign-in just
     * proved — and what is kept is the id and the person's own name for it.
     */
    @Test
    fun `logging in again updates the row rather than adding another`() {
        val store = store()
        val first = add(store)
        store.save(first.copy(name = "Frankfurt box"))

        val again = add(store, secret = "a-new-password")

        assertEquals(1, store.all().size)
        assertEquals(first.id, again.id)
        assertEquals("Frankfurt box", store.load(first.id)?.name)
        assertEquals("a-new-password", store.secret(first.id))
    }

    @Test
    fun `a second account on one box is a second server`() {
        val store = store()
        add(store, username = "root")
        add(store, username = "asad")

        assertEquals(2, store.all().size)
    }

    @Test
    fun `a different port on one box is a different server`() {
        val store = store()
        add(store, port = null)
        add(store, port = 2222)

        assertEquals(2, store.all().size)
    }

    /** A re-login that carries no secret keeps the one already stored. */
    @Test
    fun `an empty secret on a re-login does not erase the sign-in`() {
        val store = store()
        val first = add(store)

        add(store, secret = "")

        assertEquals(PASSWORD, store.secret(first.id))
        assertEquals(ServerCredentialKind.PASSWORD, store.load(first.id)?.credential)
    }

    /* -------------------------------------------------------------- refusing -- */

    @Test
    fun `a draft with a field missing is refused with the sentence for that field`() {
        val store = store()

        for ((address, username, port, expected) in listOf(
            listOf("", "root", null, ServerDraftProblem.NoAddress),
            listOf("h", "  ", null, ServerDraftProblem.NoUsername),
            listOf("h", "root", 0, ServerDraftProblem.BadPort),
            listOf("h", "root", 70000, ServerDraftProblem.BadPort),
        )) {
            val problem = try {
                store.add(
                    name = "x",
                    address = address as String,
                    port = port as Int?,
                    username = username as String,
                    secret = PASSWORD,
                    kind = ServerCredentialKind.PASSWORD,
                    hostKey = null,
                )
                null
            } catch (e: ServerDraftException) {
                e.problem
            }
            assertEquals(expected, problem)
        }
    }

    /* -------------------------------------------------------------- forgetting -- */

    @Test
    fun `forgetting takes the record and the sign-in together`() {
        val store = store()
        val id = add(store).id

        store.forget(id)

        assertNull(store.load(id))
        assertNull("a secret with no record is a password for a machine nothing can name",
            store.secret(id))
        assertNull("and it does not come back on a relaunch", store().load(id))
    }

    /* -------------------------------------------------------- a lost key -- */

    /**
     * The wrapping key is gone, and there is nothing to recover.
     *
     * A restore onto another device, a lock-screen change on some OEM builds, a factory reset of
     * the secure hardware. The honest reading of "the credential cannot be read" is that these
     * logins have to be typed again — so the file goes rather than failing on every launch for
     * ever, and nothing silently regenerates a key and pretends the login survived.
     */
    @Test
    fun `a blob that will not open is discarded rather than failing for ever`() {
        add(store())
        assertTrue(file.exists())

        val after = FileServerStore(file, DeadCipher()) { 1_000L }

        assertTrue(after.all().isEmpty())
        assertFalse(file.exists())
    }

    @Test
    fun `a truncated file reads as no servers rather than throwing on the way into a screen`() {
        add(store())
        file.writeBytes(file.readBytes().copyOfRange(0, 8))

        assertTrue(store().all().isEmpty())
    }

    /* ----------------------------------------------------------- in memory -- */

    /**
     * The double the connector's tests drive answers the same questions the real one does.
     *
     * Two implementations of one interface is two chances to disagree, and the disagreement would
     * be a suite that passes against behaviour the app does not have.
     */
    @Test
    fun `the in-memory store behaves like the file one`() {
        val memory = InMemoryServerStore { 1_000L }
        val first = add(memory)
        add(memory, secret = "second")

        assertEquals(1, memory.all().size)
        assertEquals("second", memory.secret(first.id))

        memory.forget(first.id)
        assertTrue(memory.all().isEmpty())
        assertNull(memory.secret(first.id))
    }
}
