package dev.terminaldeck.android.github

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
 * What survives a relaunch, and what a disconnect actually removes.
 *
 * The Keystore does not exist on a JVM, so the cipher is stood in for — which is the reason
 * `FileGitHubStore` takes one at all. What is under test here is the half that can be wrong without
 * anybody noticing: an account that comes back after the process died, a `disconnect` that leaves
 * the token on disk, and the drawer being a *different* one from the pairings.
 */
class GitHubAccountTest {

    @get:Rule
    val folder = TemporaryFolder()

    /** Reversible, not secure. Its job is to prove the file is written and read back, nothing more. */
    private class FlipCipher : VaultCipher {
        override fun seal(plaintext: ByteArray): ByteArray = ByteArray(plaintext.size) { (plaintext[it] + 1).toByte() }

        override fun open(blob: ByteArray): ByteArray? =
            if (blob.isEmpty()) null else ByteArray(blob.size) { (blob[it] - 1).toByte() }
    }

    /** A cipher that has lost its key — a restore onto another device, a factory reset. */
    private class DeadCipher : VaultCipher {
        override fun seal(plaintext: ByteArray): ByteArray = plaintext

        override fun open(blob: ByteArray): ByteArray? = null
    }

    private fun file(): File = File(folder.root, "github-account.v1.bin")

    @Test
    fun `an account comes back after a relaunch`() {
        val at = file()
        FileGitHubStore(at, FlipCipher()).connect("asadev", "gho_secret", GitHubAccount.Source.SignIn)

        // A second store over the same file: this is the question the cache cannot answer.
        val next = FileGitHubStore(at, FlipCipher())
        assertEquals("asadev", next.account()?.login)
        assertEquals(GitHubAccount.Source.SignIn, next.account()?.source)
        assertEquals("gho_secret", next.token())
    }

    @Test
    fun `the account on screen never carries the token`() {
        val store = FileGitHubStore(file(), FlipCipher())
        store.connect("asadev", "gho_secret", GitHubAccount.Source.Token)

        val account = store.account()
        assertNotNull(account)
        // A data class that carried the secret would be copied into every composable that draws the
        // login. The only way to the bytes is the function.
        assertFalse(account.toString().contains("gho_secret"))
    }

    @Test
    fun `disconnect takes the token with it`() {
        val at = file()
        val store = FileGitHubStore(at, FlipCipher())
        store.connect("asadev", "gho_secret", GitHubAccount.Source.SignIn)
        store.disconnect()

        assertNull(store.account())
        assertNull(store.token())
        assertFalse("nothing may be left behind that a later read could find", at.exists())
        // And it is gone for a process that never saw the cache either.
        assertNull(FileGitHubStore(at, FlipCipher()).account())
    }

    @Test
    fun `connecting again replaces what was there`() {
        // One account at a time. Two GitHub logins would need a picker on the approval prompt, and
        // a prompt with a picker on it is no longer a question with an obvious answer.
        val store = FileGitHubStore(file(), FlipCipher())
        store.connect("asadev", "first", GitHubAccount.Source.SignIn)
        store.connect("someone-else", "second", GitHubAccount.Source.Token)

        assertEquals("someone-else", store.account()?.login)
        assertEquals("second", store.token())
    }

    @Test
    fun `a blob that cannot be opened reads as no account, and is dropped`() {
        val at = file()
        FileGitHubStore(at, FlipCipher()).connect("asadev", "gho_secret", GitHubAccount.Source.SignIn)

        val store = FileGitHubStore(at, DeadCipher())
        assertNull("the honest reading is that there is no account here", store.account())
        assertFalse("a file that cannot be read would fail to be read again on every push", at.exists())
    }

    @Test
    fun `garbage in the file does not throw on the path of a push`() {
        val at = file()
        at.writeBytes("not a record".toByteArray())
        val store = FileGitHubStore(at, FlipCipher())

        assertNull(store.account())
        assertNull(store.token())
    }

    @Test
    fun `it is a different drawer from the pairings`() {
        // One wrapping key for both would mean a Keystore entry lost for any reason unpairs every
        // machine *and* signs the person out of GitHub, as one event. They are unrelated things.
        assertTrue(
            dev.terminaldeck.android.store.KeystoreVaultCipher.GITHUB_KEY_ALIAS !=
                dev.terminaldeck.android.store.KeystoreVaultCipher.KEY_ALIAS
        )
    }
}
