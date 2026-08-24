package dev.terminaldeck.android.servers

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The order Asad asked for, asked of the thing that executes it.
 *
 * > *"First they log in to the server. Then it checks whether the headless Terminal Deck already
 * > exists there. If it exists it brings it up and asks you to connect; if not it gives the option
 * > to install — you click, it installs, then you can connect."*
 *
 * What is asked here is not "does SSH work" — that is [SshSession], and it is proven against a
 * real server rather than in a unit test — but the questions a person would ask holding the phone:
 * did my server appear, did the check run before the install, did a refused check stop it, did the
 * install name the right package, and did logging in twice cost me a duplicate row.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ServerConnectorTest {

    /* ------------------------------------------------------------- the double -- */

    /**
     * Canned answers for commands, matched on a substring.
     *
     * Registering the same pattern twice means *first this, then that*, and the last one registered
     * is what every call after it gets. That is not a convenience: the install runs the host probe
     * **twice** — once to decide whether it can install and once to check that it did — and a
     * double that answered the same thing both times could not tell a working install from one
     * that left nothing behind, which is the one shape that would otherwise be reported as success
     * and then dead-end at the connect.
     */
    private class Script {
        val runs = mutableListOf<String>()
        private val answers = mutableListOf<Pair<String, SshRun>>()

        fun on(contains: String, code: Int = 0, stdout: String = "", stderr: String = "") = apply {
            answers += contains to SshRun(code, stdout, stderr)
        }

        fun answer(command: String): SshRun {
            runs += command
            val at = answers.indexOfFirst { command.contains(it.first) }
            if (at < 0) return SshRun(0, "", "")
            val found = answers[at]
            val more = answers.drop(at + 1).any { command.contains(it.first) }
            if (more) answers.removeAt(at)
            return found.second
        }
    }

    private class FakeLink(
        private val script: Script,
        override val hostKey: SshHostKey,
    ) : SshLink {
        var closed = false
        override val isOpen: Boolean get() = !closed

        override suspend fun run(script: String, timeoutMs: Long): SshRun = this.script.answer(script)

        override suspend fun stream(
            command: String,
            stdin: String?,
            timeoutMs: Long,
            onChunk: (String) -> Unit,
        ): SshRun {
            val out = script.answer(command)
            if (out.stdout.isNotEmpty()) onChunk(out.stdout)
            return out
        }

        override fun close() {
            closed = true
        }
    }

    private companion object {
        const val KEY_PRINT = "SHA256:2SVIWmbzp3lk5gc4A+qWSV57+M1XBH9ifoD16FGA/9Y"
        const val PASSWORD = "correct-horse-battery-staple"
        val hostKey = SshHostKey("ssh-ed25519", KEY_PRINT)

        const val HOST_PROBE = "#the host probe"
        const val INSTALLER = "#!/bin/sh\n# the installer\n"
    }

    private val scripts = object : ScriptLibrary {
        override fun hostProbe(): String = HOST_PROBE
        override fun installer(): String? = INSTALLER
    }

    private val script = Script()
    private var dials = 0
    private var lastExpect: String? = null
    private var refuseWith: SshProblem? = null

    private val dialer = SshDialer { _, _, _, _, expect ->
        dials += 1
        lastExpect = expect
        refuseWith?.raise()
        FakeLink(script, hostKey)
    }

    private val store = InMemoryServerStore { 1_000L }

    private fun connector() = ServerConnector(
        store = store,
        scripts = scripts,
        dialer = dialer,
        appVersion = "0.10.0",
        now = { 1_000L },
    )

    private fun bareLinux(): String = listOf(
        "os\tLinux",
        "arch\tx86_64",
        "libc\tgnu",
        "node\tv18.19.1",
        "npm\t",
        "tools\t",
        "fetch\tcurl",
        "hash\tsha256sum",
        "tar\tyes",
        "home_free_kb\t32786624",
        "systemd_user\tyes",
        "command\t",
    ).joinToString("\n")

    private fun installed(): String = listOf(
        "os\tLinux",
        "arch\tx86_64",
        "libc\tgnu",
        "node\tv22.14.0",
        "npm\t/root/.terminaldeck/runtime/bin/npm",
        "tools\t",
        "fetch\tcurl",
        "hash\tsha256sum",
        "tar\tyes",
        "home_free_kb\t32000000",
        "systemd_user\tyes",
        "unit\tactive",
        "linger\tyes",
        "command\t/root/.local/bin/terminaldeck",
        "version\t0.10.1",
    ).joinToString("\n") + "\n--- status ---\nhost: running as pid 1\n"

    /* -------------------------------------------------------------- logging in -- */

    @Test
    fun `logging in stores the server, its host key, and what it found on it`() = runTest {
        script.on(HOST_PROBE, stdout = bareLinux())
        val connector = connector()

        connector.signIn(
            name = "hetzner",
            address = "178.105.239.176",
            port = null,
            username = "root",
            secret = PASSWORD,
            kind = ServerCredentialKind.PASSWORD,
        )

        val added = connector.state.value.login as LoginPhase.Added
        assertEquals("178.105.239.176", added.server.address)
        assertEquals("empty means 22", 22, added.server.port)
        assertEquals("root", added.server.username)
        assertEquals(KEY_PRINT, added.server.hostKey?.fingerprint)
        assertNull("first sight has nothing to compare against", lastExpect)
        assertNotNull(connector.state.value.views[added.server.id])
        assertEquals(PASSWORD, store.secret(added.server.id))
    }

    /**
     * The fingerprint is what every later connection is checked against.
     *
     * Not decoration: it is the only thing standing between a rebuilt server and an impostor, and
     * it has to reach [SshDialer.open] as the `expect` argument or the check does not happen at all.
     */
    @Test
    fun `a later connection is checked against the key the first one saw`() = runTest {
        script.on(HOST_PROBE, stdout = bareLinux())
        val connector = connector()
        connector.signIn("hetzner", "178.105.239.176", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        val id = (connector.state.value.login as LoginPhase.Added).server.id

        connector.release(id)
        connector.look(id)

        assertEquals(KEY_PRINT, lastExpect)
    }

    @Test
    fun `a refused login keeps its own sentence and stores nothing`() = runTest {
        refuseWith = SshProblem.SignInRefused
        val connector = connector()

        connector.signIn("hetzner", "178.105.239.176", null, "root", "wrong", ServerCredentialKind.PASSWORD)

        val failed = connector.state.value.login as LoginPhase.Failed
        assertEquals(SshProblem.SignInRefused.headline, failed.headline)
        assertTrue(store.all().isEmpty())
    }

    @Test
    fun `a port that is not a number is refused with the port sentence, not turned into 22`() = runTest {
        val connector = connector()

        connector.signIn("hetzner", "178.105.239.176", 0, "root", PASSWORD, ServerCredentialKind.PASSWORD)

        val failed = connector.state.value.login as LoginPhase.Failed
        assertEquals(ServerDraftProblem.BadPort.sentence, failed.headline)
        assertEquals("nothing was dialled", 0, dials)
    }

    @Test
    fun `an empty field never reaches the network`() = runTest {
        val connector = connector()

        connector.signIn("", "", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        assertTrue((connector.state.value.login as LoginPhase.Failed).headline.contains("address"))

        connector.signIn("h", "h", null, "  ", PASSWORD, ServerCredentialKind.PASSWORD)
        assertTrue((connector.state.value.login as LoginPhase.Failed).headline.contains("username"))

        connector.signIn("h", "h", null, "root", "", ServerCredentialKind.PASSWORD)
        assertTrue((connector.state.value.login as LoginPhase.Failed).headline.contains("password"))

        assertEquals(0, dials)
    }

    /**
     * The same login twice is the **same server**.
     *
     * Signing in again is a normal thing to do — after a revoke, after changing the password, or
     * simply because somebody was not sure it had worked — and it must not cost a duplicate row.
     * What is refreshed is the credential and the host key; what is kept is the id and the name.
     */
    @Test
    fun `logging in again re-credentials the same server rather than adding a second row`() = runTest {
        script.on(HOST_PROBE, stdout = bareLinux())
        val connector = connector()
        connector.signIn("hetzner", "178.105.239.176", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        val first = (connector.state.value.login as LoginPhase.Added).server
        connector.rename(first.id, "Frankfurt box")
        connector.resetLogin()

        connector.signIn("hetzner", "178.105.239.176", null, "root", "a-new-password", ServerCredentialKind.PASSWORD)

        assertEquals(1, store.all().size)
        assertEquals(first.id, (connector.state.value.login as LoginPhase.Added).server.id)
        assertEquals("the name a person gave it survives", "Frankfurt box", store.load(first.id)?.name)
        assertEquals("a-new-password", store.secret(first.id))
    }

    /** A second account on one box is a second server, because the triple is what a connection is. */
    @Test
    fun `a different account on the same box is a second server`() = runTest {
        script.on(HOST_PROBE, stdout = bareLinux())
        val connector = connector()
        connector.signIn("hetzner", "10.0.0.1", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        connector.resetLogin()
        connector.signIn("hetzner", "10.0.0.1", null, "asad", PASSWORD, ServerCredentialKind.PASSWORD)

        assertEquals(2, store.all().size)
    }

    /* --------------------------------------------------------------- installing -- */

    private suspend fun loggedIn(probe: String): Pair<ServerConnector, String> {
        script.on(HOST_PROBE, stdout = probe)
        val connector = connector()
        connector.signIn("hetzner", "178.105.239.176", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        return connector to (connector.state.value.login as LoginPhase.Added).server.id
    }

    /**
     * The whole order, in the commands that actually went out.
     *
     * Check, stage, install, unit, check again — and the install command carries the release asset
     * for this app's own version rather than `terminaldeck@latest`, which is the bug this lane was
     * told about before it started: the registry is stuck at 0.6.1, and 0.6.1 predates the host
     * printing a server address, so a registry install succeeds and then the connect dead-ends.
     */
    @Test
    fun `install checks first, then stages, then runs the release asset for this build`() = runTest {
        val (connector, id) = loggedIn(bareLinux())
        // The probe the install runs *after* the installer: the command is there now.
        script.on(HOST_PROBE, stdout = installed())
        script.on("install.sh <<", stdout = "/tmp/TD_INSTALLER_x/install.sh\n")
        script.on("TERMINALDECK_PACKAGE", stdout = "installed\n")
        script.on("systemctl --user enable", stdout = "linger yes\n")

        connector.install(id)

        val install = connector.state.value.installs.getValue(id)
        assertEquals(ServerInstallState.Step.DONE, install.step)
        assertTrue(install.line.contains("machine of its own"))

        val staged = script.runs.indexOfFirst { it.contains("install.sh <<") }
        val ran = script.runs.indexOfFirst { it.contains("TERMINALDECK_PACKAGE") }
        assertTrue("the check happens before anything is copied", script.runs.first() == HOST_PROBE)
        assertTrue("staged before run", staged in 0 until ran)
        assertTrue(
            "the release asset, not the registry",
            script.runs[ran].contains("releases/download/v0.10.0/terminaldeck-0.10.0.tgz"),
        )
        assertFalse(script.runs[ran].contains("@latest"))
    }

    @Test
    fun `a server that cannot take it is refused before the installer is copied`() = runTest {
        val alpine = bareLinux().replace("libc\tgnu", "libc\tmusl")
        val (connector, id) = loggedIn(alpine)

        connector.install(id)

        val install = connector.state.value.installs.getValue(id)
        assertEquals(ServerInstallState.Step.FAILED, install.step)
        assertTrue(install.line.contains("musl"))
        assertFalse("nothing was copied", script.runs.any { it.contains("install.sh <<") })
    }

    @Test
    fun `an installer that fails leaves the server's own exit code on the card`() = runTest {
        val (connector, id) = loggedIn(bareLinux())
        script.on("install.sh <<", stdout = "/tmp/x/install.sh\n")
        script.on("TERMINALDECK_PACKAGE", code = 3, stdout = "npm ERR! 404 Not Found\n")

        connector.install(id)

        val install = connector.state.value.installs.getValue(id)
        assertEquals(ServerInstallState.Step.FAILED, install.step)
        assertTrue(install.detail.contains("ended with 3"))
        assertTrue("the installer's own words, verbatim", install.output.contains("npm ERR! 404"))
    }

    /**
     * An install that finished but left no command is a failure, whatever the exit code said.
     *
     * The one shape that would otherwise be reported as success and then dead-end at the connect.
     */
    @Test
    fun `an install that leaves no command behind is not a success`() = runTest {
        val (connector, id) = loggedIn(bareLinux())
        script.on("install.sh <<", stdout = "/tmp/x/install.sh\n")

        connector.install(id)

        assertEquals(ServerInstallState.Step.FAILED, connector.state.value.installs.getValue(id).step)
    }

    @Test
    fun `a build with no installer in it says so instead of offering one`() = runTest {
        script.on(HOST_PROBE, stdout = bareLinux())
        // The probe still answers; only the installer is missing, which is the state of an APK
        // whose `copyHeadlessInstaller` never ran. Measured once, by unzipping one.
        val connector = ServerConnector(
            store = store,
            scripts = object : ScriptLibrary {
                override fun hostProbe(): String = HOST_PROBE
                override fun installer(): String? = null
            },
            dialer = dialer,
            appVersion = "0.10.0",
            now = { 1_000L },
        )
        connector.signIn("h", "10.0.0.2", null, "root", PASSWORD, ServerCredentialKind.PASSWORD)
        val id = (connector.state.value.login as LoginPhase.Added).server.id

        connector.install(id)

        assertTrue(
            connector.state.value.installs.getValue(id).line.contains("does not carry the installer")
        )
    }

    /* ------------------------------------------------------------- connecting -- */

    @Test
    fun `a host with no address to dial cannot be connected to`() = runTest {
        val (connector, id) = loggedIn(installed())

        assertFalse(connector.canConnect(id))
        assertNull(connector.connectTicket(id))
    }

    @Test
    fun `a connect ticket carries the address the host printed and the login this phone holds`() = runTest {
        val key = ByteArray(32) { (it + 1).toByte() }
        val address = "td1 wss://relay.terminaldeck.dev M9G95TNJT64Q928VW3HVRYDR8J " +
            dev.terminaldeck.android.signin.ServerAddress.encodeKey(key)
        val probe = installed() + "\nRelay\n  connected\n\nServer address\n  $address\n"
        val (connector, id) = loggedIn(probe)

        assertTrue(connector.canConnect(id))
        val ticket = connector.connectTicket(id)!!
        assertEquals(address, ticket.address)
        assertEquals("root", ticket.username)
        assertEquals(PASSWORD, ticket.secret)
    }

    /* ------------------------------------------------------------- bring up -- */

    @Test
    fun `bringing up a stopped host starts it`() = runTest {
        val stopped = installed().replace("host: running as pid 1", "host: not running")
        val (connector, id) = loggedIn(stopped)

        connector.bringUp(id)

        assertTrue(script.runs.any { it.contains("systemctl --user start") })
    }

    @Test
    fun `bringing up a host that is already running does nothing`() = runTest {
        val (connector, id) = loggedIn(installed())
        val before = script.runs.size

        connector.bringUp(id)

        assertEquals(before, script.runs.size)
    }

    /* --------------------------------------------------------------- sessions -- */

    /**
     * One handshake for one visit.
     *
     * Check, install and start are three round trips somebody makes in a row, and re-dialling
     * between them would be three sign-ins for one visit — on somebody's rate-limited sshd.
     */
    @Test
    fun `the connection is kept across the steps of one visit`() = runTest {
        val (connector, id) = loggedIn(bareLinux())
        script.on("install.sh <<", stdout = "/tmp/x/install.sh\n")
        val afterLogin = dials

        connector.look(id)
        connector.install(id)

        assertEquals("one dial for the login and none after it", afterLogin, dials)
    }

    @Test
    fun `forgetting a server drops its connection and everything remembered about it`() = runTest {
        val (connector, id) = loggedIn(bareLinux())

        connector.forget(id)

        assertTrue(store.all().isEmpty())
        assertNull(store.secret(id))
        assertNull(connector.state.value.views[id])
    }
}
