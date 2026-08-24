package dev.terminaldeck.android.servers

/**
 * One open SSH connection, as everything above it needs to see one.
 *
 * The seam, and the only one [ServerConnector] has for the network. It exists for the reason
 * `DeckViewModel.lookup` and `DeckViewModel.serverSignIn` exist: the real implementation opens a
 * socket to somebody's server and runs shell on it, so a unit test that reached it would SSH into
 * a real machine from whatever laptop ran `./gradlew test`.
 *
 * What is behind it in the app is [SshSession]. What is behind it in the tests is a script of
 * canned answers — which is enough, because everything worth asking about the connector is about
 * *order and consequence*: does it check before it installs, does it stop when the check refuses,
 * does a failed install leave the server's own words on screen, does a re-login make a second row.
 */
interface SshLink {

    /** What the server proved itself with on this connection. */
    val hostKey: SshHostKey

    val isOpen: Boolean

    /** One script on standard input, one round trip. See [SshSession.run]. */
    suspend fun run(script: String, timeoutMs: Long = SshSession.COMMAND_TIMEOUT_MS): SshRun

    /** The same, with the output arriving as it happens. See [SshSession.stream]. */
    suspend fun stream(
        command: String,
        stdin: String? = null,
        timeoutMs: Long = SshSession.COMMAND_TIMEOUT_MS,
        onChunk: (String) -> Unit,
    ): SshRun

    fun close()
}

/** Where an address, a port and a login turn into an open connection. */
fun interface SshDialer {

    /**
     * @param expect the fingerprint this app last saw for this server, or null on first sight.
     * @throws SshException carrying the sentence pair a screen prints.
     */
    suspend fun open(
        address: String,
        port: Int,
        username: String,
        auth: SshAuth,
        expect: String?,
    ): SshLink

    companion object {
        /** The real one. Named rather than inlined so the default argument reads as a choice. */
        val real: SshDialer = SshDialer { address, port, username, auth, expect ->
            SshSession.open(address, port, username, auth, expect)
        }

        /**
         * One that never dials, for a `DeckViewModel` built without the real three.
         *
         * The default has to be *something*, and the something must not be [real]: a unit test that
         * reached it would open a socket to whatever hostname the test happened to use, from
         * whatever laptop ran the suite. This refuses with a sentence the screen can already print.
         */
        val refusing: SshDialer = SshDialer { _, _, _, _, _ -> SshProblem.NoAnswer.raise() }
    }
}
