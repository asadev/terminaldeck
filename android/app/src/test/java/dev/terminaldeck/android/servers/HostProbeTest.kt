package dev.terminaldeck.android.servers

import dev.terminaldeck.android.signin.ServerAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reading what a server answered, and deciding what to offer because of it.
 *
 * This is the half of the feature that decides whether a button exists. `HostProbe.whyNot` removes
 * Install, `connectRefusal` removes Connect, and `line` is the one sentence a person reads about
 * their own machine — so every one of them is asked here against the shape a real server prints,
 * rather than against a fixture somebody wrote to match the parser.
 */
class HostProbeTest {

    private companion object {
        /** A key that parses, so a `Server address` block is a real one rather than a shape. */
        val KEY = ByteArray(32) { (it * 7 + 3).toByte() }
        const val HOST = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val RELAY = "wss://relay.terminaldeck.dev"

        val address: String get() = "td1 $RELAY $HOST ${ServerAddress.encodeKey(KEY)}"
    }

    /** What a bare Linux box with build tools and an old Node answers. */
    private fun bareServer(): String = """
        os	Linux
        arch	x86_64
        libc	gnu
        node	v18.19.1
        npm
        tools
        fetch	curl
        hash	sha256sum
        tar	yes
        home_free_kb	32786624
        state_dir	/root/.local/share/terminaldeck
        systemd_user	yes
        command
    """.trimIndent().replace("    ", "\t")

    private fun installedAndRunning(): String =
        """
            os	Linux
            arch	x86_64
            libc	gnu
            node	v22.14.0
            npm	/root/.terminaldeck/runtime/bin/npm
            tools
            fetch	curl
            hash	sha256sum
            tar	yes
            home_free_kb	32000000
            state_dir	/root/.local/share/terminaldeck
            state	yes
            systemd_user	yes
            unit	active
            linger	yes
            command	/root/.local/bin/terminaldeck
            version	0.10.1
        """.trimIndent() + "\n--- status ---\n" + """
            host: running as pid 8123

            Relay
              connected

            host id $HOST
            channels 0

            Server address
              $address
        """.trimIndent()

    /* --------------------------------------------------------------- reading -- */

    @Test
    fun `a bare server reads as nothing installed`() {
        val look = HostProbe.read(bareServer())

        assertFalse(look.host.isInstalled)
        assertEquals("linux", look.room.os)
        assertEquals("gnu", look.room.libc)
        assertTrue(look.room.systemdUser)
        assertEquals("curl", look.room.downloader)
        assertTrue(look.room.canHash)
        assertTrue(look.room.canUnpack)
        assertTrue("nothing missing means an empty list, never a list of one empty string",
            look.room.missingTools.isEmpty())
    }

    @Test
    fun `an installed and running host reads back with the address it printed`() {
        val look = HostProbe.read(installedAndRunning())

        assertTrue(look.host.isInstalled)
        assertEquals("0.10.1", look.host.version)
        assertEquals(HostRunning.YES, look.host.running)
        assertEquals("active", look.host.unit)
        assertTrue(look.host.linger)
        assertEquals(address, look.host.address)
        assertEquals(HostRelay.CONNECTED, HostProbe.relay(look.host.status))
        assertEquals(HOST, HostProbe.hostId(look.host.status))
        assertEquals(0, HostProbe.channels(look.host.status))
    }

    /**
     * The third state, and why it is not two.
     *
     * A half-installed host prints a command and no status at all. Reading that silence as "not
     * running" would put a claim on screen that nobody measured — `facts.ts`'s rule.
     */
    @Test
    fun `a host that would not say whether it is running is reported as not having said`() {
        val out = "command\t/root/.local/bin/terminaldeck\nversion\t0.10.1\n"

        val look = HostProbe.read(out)

        assertEquals(HostRunning.UNKNOWN, look.host.running)
        assertTrue(HostProbe.line(look.host).contains("would not say"))
    }

    @Test
    fun `a stopped host is told apart from a running one by its own sentence`() {
        val out = "command\t/root/.local/bin/terminaldeck\nversion\t0.10.1\n" +
            "--- status ---\nhost: not running\n"

        val look = HostProbe.read(out)

        assertEquals(HostRunning.NO, look.host.running)
        assertTrue(HostProbe.line(look.host).contains("is not running"))
    }

    /**
     * An address that will not parse is not an address.
     *
     * What reaches a screen either works when it is spent or is empty, because the alternative is a
     * Connect button that dials nothing.
     */
    @Test
    fun `a server address block that does not parse comes back empty`() {
        val status = "Server address\n  not actually an address\n"

        assertEquals("", HostProbe.serverAddress(status))
    }

    /**
     * Nil rather than zero when the line is missing.
     *
     * A host whose relay is off prints no channel count at all, and reading that absence as
     * "nothing is connected" would turn a host that is deliberately not dialling out into a broken
     * link.
     */
    @Test
    fun `a missing channel count is unknown rather than zero`() {
        assertNull(HostProbe.channels("Relay\n  off\n"))
        assertEquals(2, HostProbe.channels("channels 2\n"))
    }

    /* ------------------------------------------------- what is offered -- */

    @Test
    fun `a bare Linux box with the tools gets an Install button`() {
        assertNull(HostProbe.whyNot(HostProbe.read(bareServer()).room))
    }

    @Test
    fun `Windows gets a sentence instead of a button`() {
        val why = HostProbe.whyNot(HostRoom(os = "windows"))

        assertNotNull(why)
        assertTrue(why!!.contains("desktop app"))
    }

    @Test
    fun `musl gets the sentence about musl rather than the one about Node`() {
        val why = HostProbe.whyNot(HostRoom(os = "linux", libc = "musl"))

        assertTrue(why!!.contains("musl"))
        assertFalse("the Node sentence would send somebody to install a runtime that does not exist",
            why.contains("no curl or wget"))
    }

    /**
     * The compiler check comes before the Node check, and that order is the measurement.
     *
     * node-pty ships no Linux binary, so it compiles during the install and fails a minute in
     * without a compiler. Reporting the Node problem first would send somebody to install Node and
     * watch the install fail anyway.
     */
    @Test
    fun `missing build tools are named, with the command that adds them`() {
        val why = HostProbe.whyNot(
            HostRoom(os = "linux", missingTools = listOf("make", "gcc"), node = "v18.0.0")
        )

        assertTrue(why!!.contains("make, gcc"))
        assertTrue(why.contains("apt-get install -y make gcc"))
    }

    @Test
    fun `no room in the home folder is a number rather than a shrug`() {
        val why = HostProbe.whyNot(
            HostRoom(os = "linux", node = "v22.1.0", npm = "/usr/bin/npm", homeFreeKb = 50 * 1024)
        )

        assertTrue(why!!.contains("50 MB free"))
    }

    @Test
    fun `Node without npm is not a usable Node`() {
        assertFalse(HostProbe.usableNode(HostRoom(node = "v22.1.0", npm = "")))
        assertFalse(HostProbe.usableNode(HostRoom(node = "v18.19.1", npm = "/usr/bin/npm")))
        assertTrue(HostProbe.usableNode(HostRoom(node = "v22.14.0", npm = "/usr/bin/npm")))
    }

    /* --------------------------------------------------- connect refusals -- */

    @Test
    fun `a running host with an address has nothing in the way of connecting`() {
        val look = HostProbe.read(installedAndRunning())

        assertNull(HostProbe.connectRefusal(look.host))
    }

    @Test
    fun `a stopped host is told to be started first`() {
        val host = HostOnServer(command = "/usr/bin/terminaldeck", running = HostRunning.NO)

        assertTrue(HostProbe.connectRefusal(host)!!.contains("has to be running"))
    }

    @Test
    fun `a host with its relay off says there is no other route`() {
        val host = HostOnServer(
            command = "/usr/bin/terminaldeck",
            running = HostRunning.YES,
            status = "Relay\n  off\n",
        )

        assertTrue(HostProbe.connectRefusal(host)!!.contains("relay switched off"))
    }

    /**
     * A host too old to print an address, and the fix that is actually a fix.
     *
     * The sentence must not send somebody to a desktop: `ServerScripts.hostPackage` names the
     * release asset for **this app's own version**, so installing again from the phone genuinely
     * does put on a build that prints one. Saying otherwise would be advice this build has
     * outgrown.
     */
    @Test
    fun `a host older than the server address offers the install from here`() {
        val host = HostOnServer(
            command = "/usr/bin/terminaldeck",
            running = HostRunning.YES,
            status = "Relay\n  connected\n",
        )

        val refusal = HostProbe.connectRefusal(host)!!
        assertTrue(refusal.contains("older than the one that prints a server address"))
        assertTrue(refusal.contains("again from here"))
        assertFalse("the desktop is not the only route any more", refusal.contains("from a desktop"))
    }

    /* ------------------------------------------------------- reach line -- */

    @Test
    fun `a host with no unit says it will not come back after a reboot`() {
        val host = HostOnServer(command = "/usr/bin/terminaldeck", unit = "")

        assertTrue(HostProbe.reachLine(host)!!.contains("will not come back"))
    }

    @Test
    fun `a unit without lingering names the one command that fixes it`() {
        val host = HostOnServer(command = "/usr/bin/terminaldeck", unit = "active", linger = false)

        assertTrue(HostProbe.reachLine(host)!!.contains("enable-linger"))
    }

    @Test
    fun `nothing installed has nothing to say about tomorrow`() {
        assertNull(HostProbe.reachLine(HostOnServer()))
    }

    /* ------------------------------------------------------- update available -- */

    private fun on(version: String): HostOnServer =
        HostOnServer(command = "/home/asad/.local/bin/terminaldeck", version = version)

    @Test
    fun `it offers this build when the server is behind`() {
        assertEquals("0.10.3", HostProbe.updateAvailable(on("0.10.1"), mine = "0.10.3"))
        assertEquals("0.10.0", HostProbe.updateAvailable(on("0.9.9"), mine = "0.10.0"))
    }

    /**
     * The one a string comparison gets wrong, and the reason this is not `<` on the strings.
     * `"0.9.1" < "0.10.1"` is **false** as text, because `9` sorts after `1`. This product has
     * shipped both a 0.9 and a 0.10, so that ordering is the release it is actually on.
     */
    @Test
    fun `it compares fields as numbers, not as text`() {
        assertEquals("0.10.1", HostProbe.updateAvailable(on("0.9.1"), mine = "0.10.1"))
        assertNull(HostProbe.updateAvailable(on("0.10.1"), mine = "0.9.1"))
    }

    @Test
    fun `it says nothing when the server is level or ahead`() {
        assertNull(HostProbe.updateAvailable(on("0.10.3"), mine = "0.10.3"))
        // A phone on an older build than the server is real, and "updating" it *down* would make
        // the machine worse.
        assertNull(HostProbe.updateAvailable(on("0.11.0"), mine = "0.10.3"))
    }

    @Test
    fun `it says nothing with no host to update`() {
        assertNull(HostProbe.updateAvailable(HostOnServer(version = "0.1.0"), mine = "0.10.3"))
    }

    /** Silence rather than a guess: the cost is a missing button, the cost of guessing is an install nobody asked for. */
    @Test
    fun `it says nothing rather than guessing at an odd version`() {
        for (odd in listOf("", "unknown", "0.10.1-rc.1", "2026.08.24.1", "v", "0.a.1", "-1.0.0")) {
            assertNull(odd, HostProbe.updateAvailable(on(odd), mine = "0.10.3"))
        }
    }

    @Test
    fun `it tolerates a leading v and pads a short version`() {
        assertEquals("0.10.3", HostProbe.updateAvailable(on("v0.10.1"), mine = "0.10.3"))
        assertEquals("0.10.3", HostProbe.updateAvailable(on("0.10"), mine = "0.10.3"))
        assertNull(HostProbe.updateAvailable(on("1"), mine = "0.10.3"))
    }

    /* ------------------------------------------------------- the way back -- */

    @Test
    fun `removing names what stays and what goes with the data`() {
        val host = HostOnServer(
            command = "/home/asad/.local/bin/terminaldeck",
            unit = "active",
            dataDir = "/home/asad/.local/share/terminaldeck",
        )

        val kept = HostProbe.removeConsequence(host, alsoData = false)
        assertTrue("it names the service it stops", kept.contains("Its service is stopped"))
        assertTrue("and says what is left behind", kept.contains("holds the devices paired to it"))

        val taken = HostProbe.removeConsequence(host, alsoData = true)
        assertTrue(taken.contains("goes too"))
        assertTrue("and warns pairing is lost", taken.contains("connecting again"))
    }
}
