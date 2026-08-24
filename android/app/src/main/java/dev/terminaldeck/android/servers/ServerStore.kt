package dev.terminaldeck.android.servers

import dev.terminaldeck.android.store.VaultCipher
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/** Which kind of sign-in is stored for a server, without any of it. */
enum class ServerCredentialKind { PASSWORD, KEY, NONE }

/** One server, as a screen is allowed to see it. */
@Serializable
data class StoredServer(
    val id: String,
    /** The person's own name for it. Never an internal id. */
    val name: String,
    val address: String,
    val port: Int,
    val username: String,
    val credential: ServerCredentialKind,
    /** What it answered with the first time, and every time since. */
    val hostKeyAlgorithm: String? = null,
    val hostKeyFingerprint: String? = null,
    val addedAt: Long,
    val lastConnectedAt: Long? = null,
    /**
     * The machine row this server is currently connected as, or null.
     *
     * The one field with no counterpart on the desktop, and it is what makes **Disconnect** a real
     * control rather than a second Forget: connecting signs this phone in to the host running *on*
     * that server, which produces an ordinary machine in the machines list. Remembering which one
     * lets the server's own card say "connected" and take it away again without touching the
     * server record — so reconnecting is one press, not a whole sign-in.
     */
    val linkedHostId: String? = null,
) {
    /** What the server proved itself with, when it has. */
    val hostKey: SshHostKey?
        get() {
            val algorithm = hostKeyAlgorithm ?: return null
            val fingerprint = hostKeyFingerprint ?: return null
            return SshHostKey(algorithm, fingerprint)
        }

    /** `address:port`, with the port shown only when it is not the usual one. */
    val where: String
        get() = if (port == ServerStore.DEFAULT_PORT) address else "$address:$port"
}

/** Why a server could not be added. Every case is something the form can point at. */
sealed interface ServerDraftProblem {
    val sentence: String

    data object NoAddress : ServerDraftProblem {
        override val sentence = "A server needs an address."
    }

    data object NoUsername : ServerDraftProblem {
        override val sentence = "A server needs the username you would sign in with."
    }

    data object BadPort : ServerDraftProblem {
        override val sentence = "A port is a number from 1 to 65535. Leave it empty for 22."
    }

    data object TooMany : ServerDraftProblem {
        override val sentence = "This phone is holding as many servers as it will hold."
    }
}

class ServerDraftException(val problem: ServerDraftProblem) : Exception(problem.sentence)

/**
 * The servers this phone has signed into over SSH, and the sign-ins that reach them.
 *
 * ## Why this is not the pairing vault
 *
 * `store/DeviceVault.kt` holds machines this phone has a **relay credential** for: a host id, that
 * host's static key, and a token minted by the far end. What is here is a different thing entirely
 * — a hostname, a port, an account and the password or key that account already accepts on a
 * server that may not be running anything of ours at all. They meet only at the moment a connect
 * succeeds, and that meeting is [StoredServer.linkedHostId] and nothing more. Putting them in one
 * file would mean a machine list whose rows are two unrelated kinds of thing, which is the shape
 * `SERVERS-DESIGN.md` refuses in one line: *a server is never "paired" and a device is never
 * "signed in to."*
 *
 * ## Why the secrets are a second map rather than a field on the record
 *
 * `src/main/servers/store.ts` holds a server's *visible* record in one file and its password or
 * key in another, because on the desktop the first crosses the bridge to the renderer and the
 * second must never be anywhere near it. There is no such bridge here — every screen is in this
 * process — so the split buys nothing structural and is kept anyway: [all] is what draws the list,
 * and it decodes records only. A screenshot of a debugger sitting on the servers list has nothing
 * in it to leak.
 *
 * ## What the host key is doing in here
 *
 * It is not a secret — it is public by construction, and the whole point of showing it is that
 * somebody can check it against `ssh-keyscan` — but it is what the identity check in [SshSession]
 * compares against. Anything that can rewrite this record can silently retarget somebody's server
 * at a machine that is not theirs and the check would still pass. Sealed with the credential
 * beside it, which is the cheapest correct answer available on this platform.
 */
interface ServerStore {

    /** Every server, oldest first — the order they were added, which is the order somebody
     * remembers adding them in. */
    fun all(): List<StoredServer>

    fun load(id: String): StoredServer?

    /**
     * The password or key for one server.
     *
     * Read at the moment a connection is opened and never held: [SshSession] spends it in the
     * handshake and the caller drops it. Nothing keeps this in a property.
     */
    fun secret(id: String): String?

    /**
     * Add a server, or throw the reason it cannot be added.
     *
     * @throws ServerDraftException
     */
    fun add(
        name: String,
        address: String,
        port: Int?,
        username: String,
        secret: String,
        kind: ServerCredentialKind,
        hostKey: SshHostKey?,
    ): StoredServer

    fun save(server: StoredServer)

    /**
     * Forget a server here.
     *
     * Both halves, always together: a record with no secret beside it is a server that asks for a
     * password nobody typed, and a secret with no record is a password for a machine nothing can
     * name.
     */
    fun forget(id: String)

    companion object {
        /** The port a server is reached on when nobody says otherwise. */
        const val DEFAULT_PORT = 22

        /** Names are shown on a screen and go into logs, so they are bounded. */
        const val MAX_NAME = 64

        /** Longer than this cannot resolve, so accepting it would only move the failure. */
        const val MAX_ADDRESS = 255

        const val MAX_USERNAME = 64

        /** Refuses to grow without bound if adding ever runs in a loop. */
        const val MAX_SERVERS = 64
    }
}

/* -------------------------------------------------------------------------- */

@Serializable
private data class ServerVault(
    val version: Int = CURRENT_VERSION,
    val servers: List<StoredServer> = emptyList(),
    /** Keyed by server id. Never read while drawing the list. */
    val secrets: Map<String, String> = emptyMap(),
)

private const val CURRENT_VERSION = 1

/**
 * The servers in one sealed file, under a Keystore key of their own.
 *
 * ## Why a third alias rather than the vault's
 *
 * `KeystoreVaultCipher` already explains why the GitHub token does not share the pairings' key: a
 * Keystore entry lost for any reason takes everything under it, so one alias for two things makes
 * one event out of two. The same argument makes this a third. A phone that loses its pairings
 * should not thereby lose the SSH logins that could put them back — that is the exact sequence
 * this feature exists for, and sharing a key would make the recovery route die with the thing it
 * recovers.
 *
 * Every mutation reads the whole blob, changes one thing and writes the whole blob back, for the
 * reason `FileDeviceVault` gives: there is never a moment when half of the change is on disk.
 */
class FileServerStore(
    private val file: File,
    private val cipher: VaultCipher,
    private val now: () -> Long = System::currentTimeMillis,
) : ServerStore {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val lock = Any()

    @Volatile
    private var cached: ServerVault? = null

    override fun all(): List<StoredServer> = synchronized(lock) {
        state().servers.sortedBy { it.addedAt }
    }

    override fun load(id: String): StoredServer? = synchronized(lock) {
        state().servers.firstOrNull { it.id == id }
    }

    override fun secret(id: String): String? = synchronized(lock) {
        state().secrets[id]
    }

    override fun add(
        name: String,
        address: String,
        port: Int?,
        username: String,
        secret: String,
        kind: ServerCredentialKind,
        hostKey: SshHostKey?,
    ): StoredServer = synchronized(lock) {
        val cleanAddress = address.trim().take(ServerStore.MAX_ADDRESS)
        if (cleanAddress.isEmpty()) throw ServerDraftException(ServerDraftProblem.NoAddress)
        val cleanUser = username.trim().take(ServerStore.MAX_USERNAME)
        if (cleanUser.isEmpty()) throw ServerDraftException(ServerDraftProblem.NoUsername)
        val realPort = port ?: ServerStore.DEFAULT_PORT
        if (realPort < 1 || realPort > 65535) throw ServerDraftException(ServerDraftProblem.BadPort)

        val current = state()
        /*
         * The same login twice is the **same server**, not a second one.
         *
         * Photographed on iOS and then obvious: three logins to one box left three identical rows,
         * each with the same name and the same `root@…` under it. Signing in again is a normal
         * thing to do — after a revoke, after changing the password, or simply because somebody was
         * not sure it had worked — and it must not cost a duplicate row.
         *
         * Identity is address, port and account, because that triple is what a connection is made
         * of. Two accounts on one box are two servers and stay two rows. What is refreshed is the
         * credential and the host key — the two things the new sign-in just proved — and what is
         * kept is the id and the person's own name for it, so a card open on that server and a name
         * they typed both survive.
         */
        val already = current.servers.firstOrNull {
            it.address == cleanAddress && it.port == realPort && it.username == cleanUser
        }
        val cleanName = name.trim()

        if (already != null) {
            val updated = already.copy(
                credential = if (secret.isEmpty()) already.credential else kind,
                hostKeyAlgorithm = hostKey?.algorithm ?: already.hostKeyAlgorithm,
                hostKeyFingerprint = hostKey?.fingerprint ?: already.hostKeyFingerprint,
            )
            write(
                current.copy(
                    servers = current.servers.map { if (it.id == updated.id) updated else it },
                    secrets = if (secret.isEmpty()) {
                        current.secrets
                    } else {
                        current.secrets + (updated.id to secret)
                    },
                )
            )
            return updated
        }

        if (current.servers.size >= ServerStore.MAX_SERVERS) {
            throw ServerDraftException(ServerDraftProblem.TooMany)
        }

        val server = StoredServer(
            id = UUID.randomUUID().toString(),
            name = cleanName.ifEmpty { cleanAddress }.take(ServerStore.MAX_NAME),
            address = cleanAddress,
            port = realPort,
            username = cleanUser,
            credential = if (secret.isEmpty()) ServerCredentialKind.NONE else kind,
            hostKeyAlgorithm = hostKey?.algorithm,
            hostKeyFingerprint = hostKey?.fingerprint,
            addedAt = now(),
        )
        write(
            current.copy(
                servers = current.servers + server,
                secrets = if (secret.isEmpty()) current.secrets else current.secrets + (server.id to secret),
            )
        )
        return server
    }

    override fun save(server: StoredServer) = synchronized(lock) {
        val current = state()
        if (current.servers.none { it.id == server.id }) return
        write(current.copy(servers = current.servers.map { if (it.id == server.id) server else it }))
    }

    override fun forget(id: String) = synchronized(lock) {
        val current = state()
        write(
            current.copy(
                servers = current.servers.filterNot { it.id == id },
                secrets = current.secrets - id,
            )
        )
    }

    /* ------------------------------------------------------------ on disk -- */

    private fun state(): ServerVault {
        cached?.let { return it }
        val fresh = readFile() ?: ServerVault()
        cached = fresh
        return fresh
    }

    private fun readFile(): ServerVault? {
        if (!file.exists()) return null
        val blob = try {
            file.readBytes()
        } catch (e: Exception) {
            return null
        }
        val plain = cipher.open(blob) ?: run {
            /*
             * The wrapping key is gone — a restore onto another device, a lock-screen change on
             * some OEM builds, a factory reset of the secure hardware. There is nothing to
             * recover, and the honest reading of "the credential cannot be read" is that these
             * logins have to be typed again. The file is removed rather than left to fail on every
             * launch. `FileDeviceVault` makes the same call for the same reason.
             */
            file.delete()
            return null
        }
        return try {
            json.decodeFromString(ServerVault.serializer(), plain.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            file.delete()
            null
        }
    }

    private fun write(vault: ServerVault) {
        cached = vault
        try {
            file.parentFile?.mkdirs()
            file.writeBytes(cipher.seal(json.encodeToString(ServerVault.serializer(), vault).toByteArray()))
        } catch (e: Exception) {
            // Nothing useful to do: the in-memory copy is correct and the next write may land.
            // Reporting a disk failure as a sign-in failure would be a sentence about the wrong
            // thing entirely.
        }
    }
}

/** Everything the file one does, in memory. Only the tests build this. */
class InMemoryServerStore(private val now: () -> Long = System::currentTimeMillis) : ServerStore {

    private val servers = mutableListOf<StoredServer>()
    private val secrets = mutableMapOf<String, String>()
    private var nextId = 0

    override fun all(): List<StoredServer> = servers.sortedBy { it.addedAt }

    override fun load(id: String): StoredServer? = servers.firstOrNull { it.id == id }

    override fun secret(id: String): String? = secrets[id]

    override fun add(
        name: String,
        address: String,
        port: Int?,
        username: String,
        secret: String,
        kind: ServerCredentialKind,
        hostKey: SshHostKey?,
    ): StoredServer {
        val cleanAddress = address.trim().take(ServerStore.MAX_ADDRESS)
        if (cleanAddress.isEmpty()) throw ServerDraftException(ServerDraftProblem.NoAddress)
        val cleanUser = username.trim().take(ServerStore.MAX_USERNAME)
        if (cleanUser.isEmpty()) throw ServerDraftException(ServerDraftProblem.NoUsername)
        val realPort = port ?: ServerStore.DEFAULT_PORT
        if (realPort < 1 || realPort > 65535) throw ServerDraftException(ServerDraftProblem.BadPort)

        val already = servers.firstOrNull {
            it.address == cleanAddress && it.port == realPort && it.username == cleanUser
        }
        if (already != null) {
            val updated = already.copy(
                credential = if (secret.isEmpty()) already.credential else kind,
                hostKeyAlgorithm = hostKey?.algorithm ?: already.hostKeyAlgorithm,
                hostKeyFingerprint = hostKey?.fingerprint ?: already.hostKeyFingerprint,
            )
            servers[servers.indexOfFirst { it.id == updated.id }] = updated
            if (secret.isNotEmpty()) secrets[updated.id] = secret
            return updated
        }
        if (servers.size >= ServerStore.MAX_SERVERS) {
            throw ServerDraftException(ServerDraftProblem.TooMany)
        }
        val server = StoredServer(
            id = "server-${nextId++}",
            name = name.trim().ifEmpty { cleanAddress }.take(ServerStore.MAX_NAME),
            address = cleanAddress,
            port = realPort,
            username = cleanUser,
            credential = if (secret.isEmpty()) ServerCredentialKind.NONE else kind,
            hostKeyAlgorithm = hostKey?.algorithm,
            hostKeyFingerprint = hostKey?.fingerprint,
            addedAt = now(),
        )
        servers += server
        if (secret.isNotEmpty()) secrets[server.id] = secret
        return server
    }

    override fun save(server: StoredServer) {
        val at = servers.indexOfFirst { it.id == server.id }
        if (at >= 0) servers[at] = server
    }

    override fun forget(id: String) {
        servers.removeAll { it.id == id }
        secrets.remove(id)
    }
}
