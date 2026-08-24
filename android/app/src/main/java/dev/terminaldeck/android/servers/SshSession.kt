package dev.terminaldeck.android.servers

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.common.SSHException
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.transport.TransportException
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.UserAuthException
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64
import java.util.concurrent.TimeUnit

/**
 * How a sign-in is offered. Exactly the two the login screen asks for.
 */
sealed interface SshAuth {
    data class Password(val password: String) : SshAuth
    /** The text of a private key, as pasted. */
    data class Key(val text: String) : SshAuth
}

/** What one command on the server came to. */
data class SshRun(
    /** The command's exit status, or -1 when it ended without giving one. */
    val code: Int,
    val stdout: String,
    val stderr: String,
    /** True when output was cut off at the ceiling. Reported, never silent. */
    val truncated: Boolean = false,
)

/** The server's identity, in the form every other SSH tool prints. */
data class SshHostKey(
    /** The key's own algorithm name, as the server announced it — `ssh-ed25519` and so on. */
    val algorithm: String,
    /** `SHA256:` and unpadded base64 — byte-identical to `ssh-keyscan | ssh-keygen -lf -`. */
    val fingerprint: String,
)

/**
 * One SSH connection from the phone to one server — the thing Android did not have, and the reason
 * `AddServerScreen` printed a `curl … | sh` for somebody to go and type on the machine.
 *
 * ## What was chosen, and why
 *
 * Asad's requirement is that the phone manage a server exactly the way the Mac does: *"Say no
 * MacBook or Windows exists at all — a user only has a server and a phone."* The desktop does it
 * with `ssh2`, a Node library. iOS does it with `apple/swift-nio-ssh`. This does it with
 * **sshj 0.39.0**, Apache-2.0, the maintained pure-Java SSH client — chosen over writing one for
 * the reason `SSHSession.swift` states: SSH is a transport, a key exchange, six ciphers, a
 * user-auth layer and a channel multiplexer, and a bug in any of them is a security bug on
 * somebody's production server.
 *
 * It costs **about 780 KB** on the APK and reuses the BouncyCastle this app already carries. The
 * algorithm decisions it needed are in [AndroidSshConfig], which is where the Android-specific
 * facts live.
 *
 * ## The identity check is not optional
 *
 * `connection.ts` makes `hostVerifier` a required option so a second code path cannot forget it.
 * The equivalent here is that [open] takes the expected fingerprint as a **parameter** — there is
 * no constructor that skips it, and `null` means "first sight, tell me what you saw", not "trust
 * anything". [ServerStore] is what remembers the answer, and a changed key stops the connection
 * before a single byte of a password is offered.
 *
 * ## Nothing is kept open
 *
 * The desktop's rule, which is his: **events, not polling.** A session is opened for a piece of
 * work and closed when it ends. There is no keepalive, no reconnect loop and no timer per server —
 * facts are stamped with when they were measured and the screen shows the age instead.
 *
 * ## Every call is off the main thread
 *
 * sshj is blocking by design: `connect`, `auth` and reading a command's output all park the
 * calling thread. Every public method here is `suspend` and hops to [Dispatchers.IO] itself rather
 * than leaving that to callers, because a caller that forgets is an `NetworkOnMainThreadException`
 * on somebody's phone at the exact moment they pressed Log in.
 */
class SshSession private constructor(
    private val client: SSHClient,
    /** What the server proved itself with. Shown, and remembered by the store. */
    override val hostKey: SshHostKey,
) : SshLink {

    override val isOpen: Boolean get() = client.isConnected && client.isAuthenticated

    /**
     * One script, one round trip — `sh -s` with the script on its standard input, exactly as the
     * desktop runs it.
     *
     * Not `sh -c '…'`: a script arriving as an argument has to survive the server's own quoting,
     * and these scripts are a hundred lines of `awk`.
     */
    override suspend fun run(script: String, timeoutMs: Long): SshRun =
        exec(command = "sh -s", stdin = script, timeoutMs = timeoutMs, onChunk = null)

    /**
     * The same, with the output arriving as it happens.
     *
     * For the install, which takes minutes and whose whole complaint was silence — `host.ts`: *"a
     * person who looked away for a minute needs to come back to what happened, not only to
     * whatever is happening now."*
     */
    override suspend fun stream(
        command: String,
        stdin: String?,
        timeoutMs: Long,
        onChunk: (String) -> Unit,
    ): SshRun = exec(command, stdin, timeoutMs, onChunk)

    override fun close() {
        try {
            client.disconnect()
        } catch (e: Exception) {
            // Closing a connection that has already gone is the ordinary case, not a failure.
        }
    }

    /* ------------------------------------------------------------------ inside -- */

    private suspend fun exec(
        command: String,
        stdin: String?,
        timeoutMs: Long,
        onChunk: ((String) -> Unit)?,
    ): SshRun = withContext(Dispatchers.IO) {
        if (!client.isConnected) SshProblem.Lost.raise()
        val session: Session = try {
            client.startSession()
        } catch (e: Exception) {
            throw channelProblem(e)
        }
        /*
         * **The deadline closes the channel from another thread**, and it has to.
         *
         * sshj's channel input stream has no read timeout of its own: it blocks until bytes arrive
         * or the channel ends. So the obvious `withTimeout` around this would suspend a coroutine
         * that is parked inside a blocking `read()` — the cancellation would be noticed only when
         * the read returned, which is never, and the `finally` that would have closed the channel
         * cannot run until the thing it would unblock has unblocked. A deadlock at the exact moment
         * something has gone wrong on somebody's server.
         *
         * A watchdog on its own thread does not have that problem: closing the channel is what ends
         * the read, and the read ending is what lets everything else unwind. The flag is what turns
         * the resulting "the connection ended" into the sentence that is actually true.
         */
        val expired = java.util.concurrent.atomic.AtomicBoolean(false)
        val deadline = Thread {
            try {
                Thread.sleep(timeoutMs)
                expired.set(true)
                session.close()
            } catch (e: InterruptedException) {
                // The run finished first, which is the ordinary case.
            } catch (e: Exception) {
                // A channel that has already gone needs no closing.
            }
        }
        deadline.isDaemon = true
        deadline.start()
        try {
            val cmd = try {
                session.exec(command)
            } catch (e: Exception) {
                SshProblem.CommandFailed(
                    "It opened a session and refused to run anything in it. An account whose shell " +
                        "is set to `nologin`, or a `ForceCommand` in the server's SSH settings, " +
                        "does exactly this."
                ).raise()
            }

            if (!stdin.isNullOrEmpty()) {
                cmd.outputStream.write(stdin.toByteArray(Charsets.UTF_8))
                cmd.outputStream.flush()
            }
            // EOF on the way in, or `sh -s` waits forever for a script that has already arrived in
            // full. `close()` on the channel's own output stream is the half-close SSH calls EOF.
            try {
                cmd.outputStream.close()
            } catch (e: IOException) {
                // A server that already exited has nothing left to read. Not a failure of the run.
            }

            /*
             * stdout is drained on this thread and stderr on another, and that is not tidiness.
             *
             * The two are separate SSH channel streams with separate windows. Draining one to the
             * end while the other fills means the server blocks writing to the full one and never
             * reaches the end of the one being read — a deadlock that shows up only on the
             * commands that print a lot to both, which is exactly the installer.
             */
            val errors = StringBuilder()
            val errorPump = Thread {
                try {
                    drain(cmd.errorStream, MAX_OUTPUT_BYTES) { errors.append(it) }
                } catch (e: Exception) {
                    // Whatever stderr had to say is gone with the connection; stdout's fate is the
                    // answer this function returns.
                }
            }
            errorPump.isDaemon = true
            errorPump.start()

            val out = StringBuilder()
            var truncated = false
            try {
                truncated = drain(cmd.inputStream, MAX_OUTPUT_BYTES) {
                    out.append(it)
                    onChunk?.invoke(it)
                }
            } catch (e: Exception) {
                if (expired.get()) SshProblem.TimedOut.raise()
                if (!client.isConnected) SshProblem.Lost.raise()
                throw commandProblem(e)
            }

            if (expired.get()) SshProblem.TimedOut.raise()

            try {
                cmd.join(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (e: Exception) {
                if (!client.isConnected) SshProblem.Lost.raise()
                SshProblem.TimedOut.raise()
            }
            errorPump.join(2_000)

            SshRun(
                code = cmd.exitStatus ?: -1,
                stdout = out.toString(),
                stderr = errors.toString(),
                truncated = truncated,
            )
        } finally {
            deadline.interrupt()
            try {
                session.close()
            } catch (e: Exception) {
                // Same as `close()` above: an already-closed channel is the ordinary end.
            }
        }
    }

    /**
     * Read a stream to its end, handing over what arrives, and stop growing at the ceiling.
     *
     * The desktop's ceiling is kept for the reason `connection.ts` gives: `cat` of a log file is
     * one keystroke away from any command this app runs. What is dropped is the **tail of the
     * buffer**, not the tail of the stream — the reading continues, so the command still finishes
     * and still reports its exit status. Returns whether anything was dropped, because a truncated
     * answer that says so is usable and one that does not is a lie.
     */
    private fun drain(stream: InputStream, ceiling: Int, onText: (String) -> Unit): Boolean {
        val buffer = ByteArray(8 * 1024)
        var kept = 0
        var truncated = false
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            if (kept >= ceiling) {
                truncated = true
                continue
            }
            val take = minOf(read, ceiling - kept)
            if (take < read) truncated = true
            kept += take
            onText(String(buffer, 0, take, Charsets.UTF_8))
        }
        return truncated
    }

    /**
     * A session this server would not open.
     *
     * `MaxSessions 0`, an account at its channel limit, or a connection that has gone since the
     * last command — three different sentences would be guessing, and the one thing that is
     * certainly true is that the server refused.
     */
    private fun channelProblem(error: Exception): SshException {
        if (!client.isConnected) return SshException(SshProblem.Lost)
        return SshException(
            SshProblem.CommandFailed(
                "It would not open a session channel. A server that limits how many an account may " +
                    "hold at once refuses exactly this way."
            )
        )
    }

    private fun commandProblem(error: Exception): SshException = when (error) {
        is SshException -> error
        else -> SshException(SshProblem.Lost)
    }

    companion object {

        /** How long the handshake gets. The desktop's number, deliberately. */
        const val HANDSHAKE_TIMEOUT_MS = 20_000L

        /** How long any one ordinary command gets. The probe takes 293 ms on a real box. */
        const val COMMAND_TIMEOUT_MS = 30_000L

        /** The ceiling on one command's output, so `cat` of a log cannot become this app's heap. */
        const val MAX_OUTPUT_BYTES = 4 * 1024 * 1024

        /**
         * Dial, check the identity, and sign in.
         *
         * `expect` is the fingerprint this app last saw for this server. `null` is first sight —
         * the key is accepted and handed back for the caller to store and show — and a mismatch
         * fails before any credential is offered.
         */
        suspend fun open(
            address: String,
            port: Int,
            username: String,
            auth: SshAuth,
            expect: String?,
        ): SshSession = withContext(Dispatchers.IO) {
            // Read before anything is dialled: a key that cannot be used is a sentence about the
            // key, not a failed connection to a server — and a bad key must not spend an attempt
            // against somebody's rate limiter to find that out.
            val keyProvider = when (auth) {
                is SshAuth.Password -> null
                is SshAuth.Key -> try {
                    SshKeys.read(auth.text)
                } catch (e: PrivateKeyException) {
                    SshProblem.BadKey(e.problem).raise()
                }
            }

            val client = SSHClient(AndroidSshConfig())
            client.connectTimeout = HANDSHAKE_TIMEOUT_MS.toInt()
            client.timeout = HANDSHAKE_TIMEOUT_MS.toInt()

            val seen = TrustOnFirstSight(expect)
            client.addHostKeyVerifier(seen)

            try {
                client.connect(address, port)
            } catch (e: Exception) {
                closeQuietly(client)
                seen.refusal?.raise()
                dialProblem(e).raise()
            }

            try {
                if (keyProvider == null) {
                    client.authPassword(username, (auth as SshAuth.Password).password)
                } else {
                    client.authPublickey(username, keyProvider)
                }
            } catch (e: Exception) {
                closeQuietly(client)
                signInProblem(e).raise()
            }

            val key = seen.key ?: run {
                closeQuietly(client)
                SshProblem.NotAServer.raise()
            }
            SshSession(client, key)
        }

        private fun closeQuietly(client: SSHClient) {
            try {
                client.disconnect()
            } catch (e: Exception) {
                // Nothing left to do about a socket that is already gone.
            }
        }

        /**
         * A name that does not resolve fails in the resolver, before any socket is opened.
         *
         * Worth telling apart from a connect failure: one is a typo in the address and the other is
         * a port, a firewall or a machine that is off, and the two send somebody to different
         * places.
         */
        private fun dialProblem(error: Exception): SshProblem {
            /*
             * Logged, never shown.
             *
             * The exception's message names hosts, ports and algorithm lists — the same decision
             * `WebSocketDeckTransport` makes about its own failures. What reaches a screen is one
             * of the sentences in [SshProblem]; what a developer needs to tell three of them apart
             * is here.
             */
            Log.d(TAG, "dial failed", error)
            val text = messageChain(error)
            return when {
                error is UnknownHostException || error.cause is UnknownHostException ->
                    SshProblem.NoSuchAddress
                /*
                 * `connect()` in sshj is not only the socket: it runs the identification exchange
                 * and the key exchange too. So the three most common ways this fails are all
                 * `TransportException`, and they mean completely different things — a server that
                 * is not SSH, a server with no algorithm in common, and a host key this app
                 * refused. Collapsing them was measured: a perfectly good Hetzner box on port 22
                 * reported *"That answered, but not as a server"*.
                 */
                text.contains("KeyExchange", ignoreCase = true) ||
                    text.contains("negotiat", ignoreCase = true) ||
                    text.contains("no common", ignoreCase = true) ||
                    text.contains("KEY_EXCHANGE_FAILED", ignoreCase = true) -> SshProblem.NothingInCommon
                text.contains("protocol version", ignoreCase = true) ||
                    text.contains("bad packet", ignoreCase = true) ||
                    text.contains("Server closed connection during identification", ignoreCase = true) ->
                    SshProblem.NotAServer
                error is TransportException -> SshProblem.NotAServer
                else -> SshProblem.NoAnswer
            }
        }

        /** Every message in the cause chain, so a classifier can read all of them at once. */
        private fun messageChain(error: Throwable): String {
            val parts = mutableListOf<String>()
            var at: Throwable? = error
            var depth = 0
            while (at != null && depth < 8) {
                parts += at.toString()
                at = at.cause
                depth += 1
            }
            return parts.joinToString(" | ")
        }

        /**
         * Why a sign-in ended, in the server's terms.
         *
         * The order matters. A host-key refusal surfaces as an ordinary transport failure, so the
         * verifier's own verdict is asked for first — otherwise a server answering with a different
         * key would be reported as a wrong password, which is the one sentence that sends somebody
         * to change a credential that was never the problem.
         */
        private fun signInProblem(error: Exception): SshProblem {
            if (error is SshException) return error.problem
            Log.d(TAG, "sign-in failed", error)
            val message = messageChain(error)
            return when {
                error is UserAuthException -> SshProblem.SignInRefused
                message.contains("negotiat", ignoreCase = true) ||
                    message.contains("no common", ignoreCase = true) ||
                    message.contains("KeyExchange", ignoreCase = true) -> SshProblem.NothingInCommon
                else -> SshProblem.SignInRefused
            }
        }

        private const val TAG = "TerminalDeck"
    }
}

/**
 * The identity check, and the fingerprint every other tool prints.
 *
 * `SHA256:` followed by unpadded base64 of the SHA-256 of the key's own SSH wire encoding — which
 * is what `ssh-keyscan host | ssh-keygen -lf -` prints, and the whole value of showing it is that
 * a person can go and check it somewhere else.
 *
 * It is a class rather than a lambda because it has to be *asked afterwards* what it decided:
 * sshj reports a refused host key as a transport failure like any other, and the difference
 * between "that server is not the one you added" and "that address did not answer" is the whole
 * point of storing the fingerprint.
 */
internal class TrustOnFirstSight(private val expect: String?) : HostKeyVerifier {

    /** What the server proved itself with, once it has. */
    @Volatile
    var key: SshHostKey? = null
        private set

    /** Set when *this* is why the connection ended, so the sentence is the right one. */
    @Volatile
    var refusal: SshProblem? = null
        private set

    override fun verify(hostname: String?, port: Int, publicKey: PublicKey?): Boolean {
        if (publicKey == null) {
            refusal = SshProblem.NotAServer
            return false
        }
        val record = fingerprint(publicKey) ?: run {
            refusal = SshProblem.NotAServer
            return false
        }
        key = record
        val expected = expect
        if (expected != null && expected != record.fingerprint) {
            refusal = SshProblem.IdentityChanged(seen = record.fingerprint, stored = expected)
            return false
        }
        return true
    }

    /**
     * No known-hosts file, so nothing to say about what algorithms one already holds.
     *
     * sshj uses this to keep asking a server for the host key type it already trusts. This app's
     * memory is one fingerprint in [ServerStore], not a file of algorithms, and answering with a
     * list it cannot back up would narrow the negotiation for no reason.
     */
    override fun findExistingAlgorithms(hostname: String?, port: Int): List<String> = emptyList()

    private fun fingerprint(publicKey: PublicKey): SshHostKey? = try {
        val type = KeyType.fromKey(publicKey)
        if (type == KeyType.UNKNOWN) {
            null
        } else {
            val buffer = Buffer.PlainBuffer()
            type.putPubKeyIntoBuffer(publicKey, buffer)
            val digest = MessageDigest.getInstance("SHA-256").digest(buffer.compactData)
            SshHostKey(
                algorithm = type.toString(),
                fingerprint = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest),
            )
        }
    } catch (e: Exception) {
        // The key came off the wire and something about it would not encode. Logged, because
        // "that answered, but not as a server" is a very confident sentence to say about a
        // machine that answered perfectly and whose key this app simply could not name.
        Log.d("TerminalDeck", "host key could not be fingerprinted", e)
        null
    }
}

/** Resolving is worth its own name so a test can ask about it without opening a socket. */
internal fun resolves(address: String): Boolean = try {
    InetAddress.getByName(address)
    true
} catch (e: UnknownHostException) {
    false
}
