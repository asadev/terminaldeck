package dev.terminaldeck.android.servers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shell this app sends somebody else's production server.
 *
 * Every one of these is a thing that was got wrong once, on iOS or on the desktop, and is written
 * down here so it cannot be got wrong again quietly.
 */
class ServerScriptsTest {

    /**
     * The release asset for this build, not `terminaldeck@latest`.
     *
     * The measurement, from 2026-08-24 on a bare Hetzner box: the registry's newest is **0.6.1**
     * while the app is 0.10.x, and 0.6.1 predates the host printing a server address. A server
     * address is the only thing a phone can dial, so a registry install succeeds, systemd starts
     * it, the card says *"is a machine of its own now"* — and the connect step then draws a
     * refusal, with every step before it reporting success.
     */
    @Test
    fun `the install fetches the release tarball for this app's own version`() {
        val url = ServerScripts.hostPackage("0.10.0")

        assertEquals(
            "https://github.com/asadev/terminaldeck/releases/download/v0.10.0/terminaldeck-0.10.0.tgz",
            url,
        )
    }

    @Test
    fun `the installer command names that package and nothing from the registry`() {
        val command = ServerScripts.runInstaller("/tmp/x/install.sh", "0.10.0")

        assertTrue(command.startsWith("TERMINALDECK_PACKAGE="))
        assertTrue(command.contains("terminaldeck-0.10.0.tgz"))
        assertFalse(command.contains("@latest"))
        assertTrue("the script is run, not sourced into something", command.contains("sh '/tmp/x/install.sh'"))
    }

    /**
     * One trailing newline is dropped, and the file still ends with one.
     *
     * A heredoc terminates its body with the newline *before* the delimiter, so embedding a text
     * that already ends in `\n` delivers a file one blank line longer than the original. Measured
     * against a real server by hashing both ends: `1797edb5…` there against `3255fe0b…` here, for a
     * script that ran perfectly well — exactly the kind of difference that is invisible until
     * something checks a signature.
     */
    @Test
    fun `staging a script that ends in a newline does not add a blank line to it`() {
        val staged = ServerScripts.stageInstaller("echo hi\n", mark = "MARK")

        assertTrue(staged.script.contains("cat > \$d/install.sh <<'MARK'\necho hi\nMARK\n"))
    }

    @Test
    fun `the heredoc is quoted, so nothing in the installer is expanded on the way`() {
        val staged = ServerScripts.stageInstaller("VALUE=\$HOME/x\n", mark = "MARK")

        assertTrue("a quoted delimiter is what stops the shell touching the body",
            staged.script.contains("<<'MARK'"))
        assertTrue(staged.script.contains("VALUE=\$HOME/x"))
    }

    @Test
    fun `the installer is staged to a file rather than piped into sh`() {
        // `sh -s` reads its script from the same stream anything it runs would read from, so one
        // command inside the installer that touches standard input eats the rest of the installer.
        val staged = ServerScripts.stageInstaller("echo hi", mark = "MARK")

        assertTrue(staged.path.endsWith("/install.sh"))
        assertTrue(staged.script.contains("chmod +x"))
        assertTrue("it answers with where it landed", staged.script.contains("printf '%s\\n'"))
    }

    /* ------------------------------------------------------------ the unit -- */

    /**
     * **Stop whatever is already running, because the unit is about to own it.**
     *
     * `install-headless.sh` leaves a host running — that is the point of it — and this script then
     * enables a unit whose `ExecStart` is the same daemon. The daemon refuses to be a second copy,
     * correctly, and with `Restart=on-failure` and `RestartSec=5` that is not a one-off failure but
     * a **loop**: measured on a real server, thirty-eight restarts and climbing, one failed unit
     * every five seconds in that machine's journal, for as long as it is up. Nothing on the phone
     * shows it, because the host somebody pressed the button for is running perfectly.
     */
    @Test
    fun `the unit stops the running host before it restarts under systemd`() {
        val script = ServerScripts.service("/root/.local/bin/terminaldeck")

        val stop = script.indexOf("\"\$b\" stop")
        val restart = script.indexOf("systemctl --user restart")
        assertTrue("both are there", stop >= 0 && restart >= 0)
        assertTrue("the unit is started while another host still holds the socket otherwise", stop < restart)
    }

    /**
     * **`restart` and a proof, not `enable --now` and a hope.**
     *
     * On a real WSL box on 2026-08-27 the stop landed and the start did not — the process just
     * killed was still releasing its pid lock — and the in-app Update finished having replaced the
     * files and left the host **down**, while the card said *"is a machine of its own now"*. That
     * is Asad's report in his own words: *"after updating server app it keeps reconnecting… server
     * is still connected but not the sessions"*. So `enable` is split off `--now`, `restart` cannot
     * be raced by a CLI stop that already happened, and the script waits and checks `is-active`
     * before it exits 0 — failing loudly if the unit never came up rather than claiming success
     * over a dead host.
     */
    @Test
    fun `the unit restarts and proves it came up rather than assuming`() {
        val script = ServerScripts.service("/root/.local/bin/terminaldeck")

        assertTrue("enable sets the boot symlink, split off --now",
            script.contains("systemctl --user enable terminaldeck.service"))
        assertFalse("--now is gone, because restart is what brings it up",
            script.contains("systemctl --user enable --now"))
        assertTrue(script.contains("systemctl --user restart terminaldeck.service"))
        assertTrue("it proves the unit came up, not assumes it", script.contains("is-active --quiet"))
        assertTrue("and fails loudly if it did not, so the card cannot claim success over a dead host",
            script.contains("did not come up"))
    }

    /**
     * `ExecStart` is the daemon, not the CLI.
     *
     * They are two programs. When the installer supplies its own Node it writes a launcher for the
     * CLI **only**, so the daemon has to be named by its real path with the private runtime on
     * PATH — which is the branch on `terminaldeck-launcher`.
     */
    @Test
    fun `the unit starts the host daemon and not the command line tool`() {
        val script = ServerScripts.service("/root/.local/bin/terminaldeck")

        assertTrue(script.contains("terminaldeck-host"))
        assertTrue("it detects the launcher the installer writes", script.contains("terminaldeck-launcher"))
        assertTrue("and refuses to write a unit that cannot start", script.contains("[ -x \"\$host\" ]"))
    }

    @Test
    fun `it is a user unit, so nothing here asks for root`() {
        val script = ServerScripts.service("/usr/bin/terminaldeck")

        assertTrue(script.contains("\$HOME/.config/systemd/user/terminaldeck.service"))
        assertFalse("a system unit would need root to write and enable", script.contains("/etc/systemd/system"))
        assertFalse("nothing here runs under sudo", script.contains("sudo systemctl"))
    }

    @Test
    fun `lingering is asked for without sudo and its answer is read back`() {
        val script = ServerScripts.service("/usr/bin/terminaldeck")

        assertTrue(script.contains("loginctl enable-linger"))
        assertTrue("it succeeds where policy allows and fails harmlessly elsewhere",
            script.contains("enable-linger \"\$(id -un)\" >/dev/null 2>&1 || true"))
        assertTrue("the caller reads the answer rather than assuming either way",
            script.contains("printf \"linger %s\\n\""))
    }

    /* ---------------------------------------------------- starting & stopping -- */

    /**
     * **Its output goes to a file, not to /dev/null.**
     *
     * A session the host refuses to start says *"Check it on the machine itself"* — and the reason
     * it refused is written to stderr, which on a host started with `>/dev/null` went nowhere at
     * all. So the remedy named on screen was impossible to carry out on exactly the machines that
     * need it, which are the ones with no systemd to catch stderr for them.
     */
    @Test
    fun `a direct start keeps the daemon's own words somewhere findable`() {
        val script = ServerScripts.startDirect("/usr/bin/terminaldeck")

        assertTrue(script.contains("host-stderr.log"))
        assertTrue("appended, because two starts a week apart are two things worth reading",
            script.contains(">>"))
        assertFalse(script.contains(">/dev/null 2>&1 &"))
        assertTrue("beside the host's own state rather than in /tmp, which a reboot clears",
            script.contains("\${XDG_DATA_HOME:-\$HOME/.local/share}/terminaldeck"))
    }

    @Test
    fun `a machine with a stopped unit is started by systemd rather than by a second copy`() {
        val withUnit = ServerScripts.start("/usr/bin/terminaldeck", hasUnit = true, systemdUser = true)
        val without = ServerScripts.start("/usr/bin/terminaldeck", hasUnit = false, systemdUser = true)

        assertTrue(withUnit.contains("systemctl --user start terminaldeck.service"))
        assertTrue("a container has no init by design", without.contains("nohup"))
    }

    /**
     * The unit first, then the host's own stop.
     *
     * Stopping the daemon while its unit is still enabled would have systemd start it again within
     * `RestartSec`. Neither is a failure on its own: a host started directly has no unit, and a
     * host under a unit has nothing left for `stop` to do.
     */
    @Test
    fun `stopping goes through the unit first when there is one`() {
        val script = ServerScripts.stop("/usr/bin/terminaldeck", hasUnit = true)

        val unit = script.indexOf("systemctl --user stop")
        val own = script.indexOf("\"\$b\" stop")
        assertTrue(unit in 0 until own)
        assertTrue("neither is treated as fatal", script.contains("|| true"))
    }

    /* -------------------------------------------------------- address & remove -- */

    /**
     * Asking for the address is really **waiting for the relay dial**, on the far side where the
     * answer lives. Its own output is thrown away — the address a screen shows is read out of the
     * next `status` by [HostProbe.serverAddress]; what this buys is the seconds. A host too old to
     * have the verb exits non-zero, which is why the failure is swallowed.
     */
    @Test
    fun `asking for the address waits and never treats a missing verb as failure`() {
        val script = ServerScripts.address("/usr/bin/terminaldeck")

        assertTrue(script.contains("\"\$b\" address"))
        assertTrue("its output is not what is read; the survey after it is", script.contains(">/dev/null"))
        assertTrue("an older host has no such verb and that is one of the states, not an error",
            script.contains("|| true"))
    }

    /**
     * Remove refuses anything outside `$HOME`, and takes the service down before the files.
     *
     * Every path came off the server through `command -v`, so a system-wide copy installed for
     * everyone is one the honest answer is to refuse rather than start deleting on a phone user's
     * behalf. The unit goes first because a unit left enabled would keep restarting a program that
     * has gone.
     */
    @Test
    fun `remove refuses outside home and takes the service down first`() {
        val script = ServerScripts.remove("/root/.local/bin/terminaldeck", "/root/.local/share/terminaldeck", alsoData = false)

        assertTrue("the guard that refuses a system-wide copy", script.contains("not ours to remove"))
        assertTrue(script.contains("case \"\$b\" in \"\$HOME\"/*)"))
        val disable = script.indexOf("systemctl --user disable --now")
        val stop = script.indexOf("\"\$b\" stop")
        assertTrue("the unit is disabled before the daemon is stopped", disable in 0 until stop)
    }

    @Test
    fun `remove leaves the data folder alone unless it was asked for`() {
        val kept = ServerScripts.remove("/root/.local/bin/terminaldeck", "/root/.local/share/terminaldeck", alsoData = false)
        val taken = ServerScripts.remove("/root/.local/bin/terminaldeck", "/root/.local/share/terminaldeck", alsoData = true)

        assertFalse("the folder is somebody's own; untouched unless named", kept.contains("rm -rf \"\$dd\""))
        assertTrue(taken.contains("dd="))
        assertTrue("and the same home guard applies to it", taken.contains("rm -rf \"\$dd\""))
    }

    /* ------------------------------------------------------------- quoting -- */

    @Test
    fun `a path with a space or a quote in it survives being quoted`() {
        assertEquals("'/home/asad user/bin/td'", ServerScripts.quote("/home/asad user/bin/td"))
        assertEquals("'it'\\''s'", ServerScripts.quote("it's"))
    }

    @Test
    fun `every command that names the binary quotes it`() {
        val awkward = "/home/a b/bin/terminaldeck"

        for (script in listOf(
            ServerScripts.service(awkward),
            ServerScripts.startDirect(awkward),
            ServerScripts.stop(awkward, hasUnit = true),
        )) {
            assertTrue(script, script.contains(ServerScripts.quote(awkward)))
            assertFalse("never bare", script.contains("b=$awkward\n"))
        }
    }
}
