package dev.terminaldeck.android.github

import android.content.Context
import dev.terminaldeck.android.store.KeystoreVaultCipher
import dev.terminaldeck.android.store.VaultCipher
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * The one GitHub account this phone holds, and the drawer it holds it in.
 *
 * This is the whole of "their token stays on their device". A session on somebody else's machine
 * gets no git credentials of its own — the desktop's `git-guest.ts` sees to that — so when git over
 * there needs a login it asks over the sealed channel, and what answers is this. The token is read
 * out of storage, put into one reply, and is never written anywhere else: not to the host's disk,
 * not to a log, not into an error.
 *
 * ## Why not `EncryptedSharedPreferences`
 *
 * It would work, and it drags in `androidx.security-crypto` — a library whose 1.0 line has been
 * deprecated by Google with no replacement — for a job this module already does. `DeviceVault`
 * wraps a file with an AES-256-GCM key the Android Keystore holds and never exports, and that is
 * exactly the protection `EncryptedSharedPreferences` offers: worthless off this device, worthless
 * to another app on it, and refused by `adb backup` because `allowBackup="false"` already says so.
 * So this reuses [KeystoreVaultCipher] rather than adding a dependency to arrive at the same place.
 *
 * ## A different key and a different file, on purpose
 *
 * `KeystoreVaultCipher` takes its alias as a parameter for this reason alone. One wrapping key for
 * both would mean a Keystore entry lost for any reason — a restore onto another device, a
 * lock-screen change on some OEM builds — takes the pairings *and* the GitHub token together, so a
 * person would be unpaired from every machine and signed out of GitHub as one event. They are two
 * unrelated things and they fail separately.
 *
 * It also means they are forgotten independently, which is the behaviour anybody expects: unpairing
 * a machine must not sign you out of GitHub, and disconnecting GitHub must not cost you your
 * machines.
 *
 * ## What is deliberately not here
 *
 * No record of which repositories have been approved. The desktop remembers that — in memory, for
 * as long as its app is running — and a copy on this side would be a second answer to "has this
 * been approved" with no way to reconcile the two. What this phone remembers is one account; what
 * it consents to is one request at a time.
 *
 * ## No user authentication on the key
 *
 * The wrapping key is not `setUserAuthenticationRequired`, matching the vault next door, and here
 * the reason is sharper than convenience. A **read** — a fetch, a pull, a clone — is answered
 * silently, with nobody looking at the phone. A key that needed the lock screen would make exactly
 * those requests fail, at the moment the feature is most useful, with a sentence about the device
 * not being reachable that is true and completely misleading.
 */

/**
 * The account, minus the secret.
 *
 * Split from the token deliberately: everything on screen reads this, and nothing on screen has any
 * business holding the bytes that grant a push. The token is fetched, by name, at the one call site
 * that answers a request.
 */
data class GitHubAccount(
    /**
     * The login, as GitHub itself reported it.
     *
     * Never typed by the user. A name somebody typed is a name the prompt could get wrong, and the
     * prompt is the whole explanation of this feature.
     */
    val login: String,
    val source: Source,
    val connectedAt: Long,
) {
    /**
     * How the token got here.
     *
     * Recorded rather than inferred, because the two have different failure modes and the fix a
     * person needs is different: a device-flow token is revoked in GitHub's application settings,
     * and a personal access token is revoked in its own list and expires on a date.
     */
    enum class Source {
        /** Signed in through GitHub's device flow, in a browser on this phone. */
        SignIn,

        /** A fine-grained personal access token, pasted in. The fallback the design keeps. */
        Token,
    }
}

interface GitHubAccountStore {

    /** The account on screen, or null when nothing is connected. */
    fun account(): GitHubAccount?

    /**
     * The secret, read from storage at the moment it is needed.
     *
     * Deliberately a function rather than a field on [GitHubAccount]: the bytes exist in this
     * process for the length of one reply, and a data class that carried them would be copied into
     * every composable that draws the account name.
     */
    fun token(): String?

    /**
     * Connect, or replace what is connected.
     *
     * One account at a time — a phone with two GitHub logins would need a picker on the approval
     * prompt, and a prompt with a picker on it is no longer a question with an obvious answer.
     */
    fun connect(login: String, token: String, source: GitHubAccount.Source)

    /**
     * Forget the account and the token.
     *
     * The revocation that works from here: nothing on this phone can answer a credential request
     * afterwards. It does not revoke the token at GitHub — that is a page on github.com, and this
     * app claiming to have done it would be a claim it cannot keep.
     */
    fun disconnect()
}

/* -------------------------------------------------------------------------- */

@Serializable
private data class StoredAccount(
    val login: String,
    val source: String,
    val connectedAt: Long,
    val token: String,
)

/**
 * The account and the token in one sealed file.
 *
 * One file rather than two, unlike the iOS client, which keeps two Keychain items so that the
 * common read — the account name, drawn on every frame that shows it — never has the token in a
 * buffer. That argument does not transfer: this file is opened by one AES-GCM `doFinal` that
 * produces the whole plaintext either way, so splitting it would buy a second decryption and no
 * privacy. What it would cost is a state where one half is on disk and the other is not, which is
 * the failure this shape cannot have.
 *
 * The account is cached after the first read because Compose reads it on every recomposition and a
 * Keystore round trip per frame is not free. **The token is not cached** — see [token].
 */
open class FileGitHubStore(
    private val file: File,
    private val cipher: VaultCipher,
) : GitHubAccountStore {

    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Any()

    private var cached: GitHubAccount? = null
    private var loaded = false

    override fun account(): GitHubAccount? = synchronized(lock) {
        if (!loaded) {
            loaded = true
            cached = read()?.toAccount()
        }
        cached
    }

    /**
     * Read the token, every time, and never keep it.
     *
     * The read costs microseconds and happens at most once per `git` invocation. What it buys is
     * that the bytes are not sitting in this process's heap between pushes, which is the difference
     * between a token that lives on the device and a token that lives in an app.
     */
    override fun token(): String? = synchronized(lock) { read()?.token }

    override fun connect(login: String, token: String, source: GitHubAccount.Source) {
        synchronized(lock) {
            val record = StoredAccount(
                login = login,
                source = source.name,
                connectedAt = System.currentTimeMillis(),
                token = token,
            )
            write(record)
            cached = record.toAccount()
            loaded = true
        }
    }

    override fun disconnect() {
        synchronized(lock) {
            file.delete()
            cached = null
            loaded = true
        }
    }

    private fun read(): StoredAccount? {
        if (!file.exists()) return null
        val plain = cipher.open(file.readBytes()) ?: return discard()
        return try {
            json.decodeFromString(StoredAccount.serializer(), plain.decodeToString())
        } catch (e: Exception) {
            // A blob this build cannot make sense of means the same thing as a wrapping key that
            // has gone: there is no account here, and connecting again is the only fix. It is
            // deleted rather than left, because a file that cannot be read is a file that will fail
            // to be read again on every push.
            discard()
        }
    }

    private fun discard(): StoredAccount? {
        file.delete()
        return null
    }

    private fun write(record: StoredAccount) {
        val blob = cipher.seal(json.encodeToString(StoredAccount.serializer(), record).toByteArray())
        // Written beside and renamed, like the vault: a process killed mid-write must not leave a
        // half file, which here would read as "no account" on a phone that has one.
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeBytes(blob)
        if (!temp.renameTo(file)) {
            file.writeBytes(blob)
            temp.delete()
        }
    }
}

private fun StoredAccount.toAccount(): GitHubAccount = GitHubAccount(
    login = login,
    // An unrecognised source is read as a pasted token rather than refused. The field only decides
    // one sentence on one screen — where to go to revoke it — and losing the account over a word
    // this build has not heard of would cost somebody their sign-in to fix a caption.
    source = GitHubAccount.Source.entries.firstOrNull { it.name == source } ?: GitHubAccount.Source.Token,
    connectedAt = connectedAt,
)

/** The store the app runs on: one file, wrapped by a key the hardware holds. */
class KeystoreGitHubStore(context: Context) : FileGitHubStore(
    File(context.filesDir, FILE_NAME),
    KeystoreVaultCipher(KeystoreVaultCipher.GITHUB_KEY_ALIAS),
)

private const val FILE_NAME = "github-account.v1.bin"

/**
 * A store that forgets on relaunch.
 *
 * For unit tests and Compose previews only — the Keystore does not exist on a JVM. Named so that
 * nothing mistakes it for storage.
 */
class InMemoryGitHubStore : GitHubAccountStore {

    private var record: GitHubAccount? = null
    private var secret: String? = null

    override fun account(): GitHubAccount? = record

    override fun token(): String? = secret

    override fun connect(login: String, token: String, source: GitHubAccount.Source) {
        record = GitHubAccount(login = login, source = source, connectedAt = System.currentTimeMillis())
        secret = token
    }

    override fun disconnect() {
        record = null
        secret = null
    }
}
