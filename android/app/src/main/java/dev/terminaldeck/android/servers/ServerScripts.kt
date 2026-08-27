package dev.terminaldeck.android.servers

import java.util.UUID

/**
 * The commands the phone sends a server, and the reasons each one is shaped the way it is.
 *
 * Everything here is a port of `src/main/servers/host.ts` by way of
 * `ios/TerminalDeck/Servers/ServerScripts.swift` — the same unit file, the same fallback when
 * there is no systemd, the same quoting. Two things are different from the desktop because the
 * phone's situation is different, and both are stated where they are done:
 *
 *  - **Getting the installer onto the server.** The desktop uploads two files over SFTP:
 *    `install.sh` and a tarball of the host. A phone cannot carry a tarball of a Node package it
 *    does not build, so it sends the installer only — and **names the tarball the installer is to
 *    fetch**, which is [hostPackage] below and is the whole reason that function exists.
 *  - **Start and stop.** The desktop has install and remove and nothing between them, because it
 *    is sitting in front of a terminal on that server. Asad asked for these two by name for the
 *    phone: *"then you can connect, and disconnect if you want"*, and before that, *"it brings it
 *    up"*.
 */
object ServerScripts {

    /**
     * The GitHub repository the release assets hang off.
     *
     * Spelled here rather than derived: the account is a person's, not the product's, and a
     * product name is the wrong thing to build an owner out of.
     */
    private const val REPO = "asadev/terminaldeck"

    /** The package slug — the npm name, the CLI command and the tarball's own prefix. */
    private const val ID = "terminaldeck"

    /**
     * One argument, safe inside single quotes.
     *
     * Every path this quotes came off the server itself — `command -v`, and the XDG folder the
     * host reads — so it is not attacker-controlled in any ordinary sense. It is quoted anyway,
     * because "not ordinarily attacker-controlled" is the assumption every shell injection was
     * built on, and because a home directory with a space in it is not exotic.
     */
    fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    /**
     * **Which host the server is told to install** — and why it is not `terminaldeck@latest` from
     * the registry.
     *
     * ## What was measured
     *
     * It was `terminaldeck@latest` on iOS, on the reasoning that the registry had stopped being a
     * placeholder and now carried a real package with both `bin` entries. That reasoning was right
     * and the conclusion was still wrong, because it checked whether the name resolved and not
     * **what version it resolved to**. Run against a bare Hetzner box on 2026-08-24: the install
     * succeeded, systemd started it, the card said *"is a machine of its own now"* — and then the
     * connect step drew a refusal, because `terminaldeck@latest` is **0.6.1** while this app is
     * 0.10.x, and 0.6.1 predates the host printing a server address. A server address is the only
     * thing a phone can dial. So the whole flow Asad asked for — *"you click, it installs, then
     * you can connect"* — installed a host and dead-ended, with every step reporting success.
     *
     * The registry is eight tagged versions behind and publishing to it is a separate act with a
     * separate credential. What is **not** behind is the release: `release.yml` runs
     * `npm pack ./out/headless` on every tag and uploads the tarball beside the Mac and Windows
     * downloads, built from the tagged tree rather than from somebody's disk. That asset is what
     * this names.
     *
     * ## Why the app's own version, exactly
     *
     * Because the two halves have to agree about the wire, and the only version this app can
     * promise anything about is its own. `npm pack` names the file after the package version, so
     * the asset for a tag is derivable rather than looked up — no registry, no API call, no token,
     * and nothing to be rate limited. A build whose tag was never released gets a 404, the install
     * fails, and the installer's own words are on the card; that is a worse day than a success and
     * a much better one than a host nobody can reach.
     */
    fun hostPackage(version: String): String =
        "https://github.com/$REPO/releases/download/v$version/$ID-$version.tgz"

    /**
     * The one command that runs the staged installer, with the package named.
     *
     * The assignment is in front of the command rather than exported earlier in a separate round
     * trip, because [SshSession.stream] opens a channel per command and an export would land in a
     * shell that has already exited.
     */
    fun runInstaller(path: String, version: String): String =
        "TERMINALDECK_PACKAGE=${quote(hostPackage(version))} sh ${quote(path)}"

    /**
     * Put the installer on the server, and answer with where it landed.
     *
     * A heredoc with a delimiter nothing can collide with, rather than base64: base64 would need a
     * decoder on the far end and there are three spellings of that flag across the systems this has
     * to work on. A quoted heredoc expands nothing, so the script arrives byte for byte.
     *
     * It is staged to a file rather than piped straight into `sh -s`, and that is not tidiness.
     * `sh -s` reads its script from the same stream anything it runs would read from, so one
     * command inside the installer that touches standard input eats the rest of the installer. The
     * desktop stages a file for the same reason.
     */
    fun stageInstaller(installer: String, mark: String = newMark()): Staged {
        val path = "\$d/install.sh"
        // One trailing newline is dropped, and the file still ends with one.
        //
        // A heredoc terminates its body with the newline before the delimiter, so embedding a text
        // that already ends in `\n` delivers a file one blank line longer than the original.
        // Measured against a real server by hashing both ends: `1797edb5…` on the server against
        // `3255fe0b…` here, for a script that ran perfectly well — which is exactly the kind of
        // difference that is invisible until something checks a signature.
        val body = if (installer.endsWith("\n")) installer.dropLast(1) else installer
        val script = listOf(
            "set -e",
            "d=\${TMPDIR:-/tmp}/$mark",
            "mkdir -p \"\$d\"",
            "cat > $path <<'$mark'",
            body,
            mark,
            "chmod +x $path",
            "printf '%s\\n' \"$path\"",
        ).joinToString("\n")
        return Staged(script = script, path = path)
    }

    /** Where the installer went, and the script that put it there. */
    data class Staged(val script: String, val path: String)

    private fun newMark(): String = "TD_INSTALLER_" + UUID.randomUUID().toString().replace("-", "")

    /**
     * A systemd **user** unit, and why it is a user unit.
     *
     * A system unit lives in `/etc/systemd/system` and needs root to write, enable and start —
     * which this feature does not ask for. A user unit lives in the account's own home and
     * `systemctl --user` starts it with no privilege at all. What that costs is stated rather than
     * hidden: without lingering, the account's systemd manager stops when the last login ends,
     * taking the host with it — which is exactly what *"a phone that was paired to it then finds
     * nothing there"* looks like.
     *
     * `ExecStart` is `terminaldeck-host`, not `terminaldeck`: they are two programs, the second
     * being the CLI and the first the daemon. When the installer supplies its own Node it writes a
     * launcher for the CLI **only**, so the daemon has to be named by its real path with the
     * private runtime on PATH.
     */
    fun service(command: String): String = (
        listOf(
            "b=${quote(command)}",
        "if grep -q $ID-launcher \"\$b\" 2>/dev/null; then",
        "  rt=\"\$HOME/.$ID/runtime\"",
        "  host=\"\$rt/bin/$ID-host\"",
        "  bin=\"\$rt/bin\"",
        "else",
        "  bin=\$(dirname \"\$b\")",
        "  host=\"\$bin/$ID-host\"",
        "fi",
        "[ -x \"\$host\" ] || { echo \"no host daemon beside \$b\" >&2; exit 1; }",
        /*
         * **Stop whatever is already running, because the unit is about to own it.**
         *
         * `install-headless.sh` leaves a host running — that is the point of it — and this script
         * then enables a unit whose `ExecStart` is the same daemon. The daemon refuses to be a
         * second copy, correctly: *"A Terminal Deck host is already running here as pid …"*, exit
         * 1. With `Restart=on-failure` and `RestartSec=5` that is not a one-off failure, it is a
         * **loop**: measured on a real server on 2026-08-24, thirty-eight restarts and climbing,
         * one failed unit every five seconds in that machine's journal, for as long as it is up.
         * Nothing on the phone shows it, because the host somebody pressed the button for is
         * running perfectly — it is just the one the installer started rather than the one systemd
         * thinks it owns.
         */
        "\"\$b\" stop >/dev/null 2>&1 || true",
        "mkdir -p \"\$HOME/.config/systemd/user\" || exit 1",
        "cat > \"\$HOME/.config/systemd/user/$ID.service\" <<UNIT",
        "[Unit]",
        "Description=Terminal Deck host",
        "After=network-online.target",
        "",
        "[Service]",
        "Type=simple",
        "ExecStart=\$host",
        "Environment=PATH=\$bin:/usr/local/bin:/usr/bin:/bin",
        "Restart=on-failure",
        "RestartSec=5",
        "",
        "[Install]",
        "WantedBy=default.target",
        "UNIT",
        "systemctl --user daemon-reload || exit 1",
        // Enable, restart, and prove it came up — the shared restart-and-prove, so the update path
        // and the standalone Restart button cannot drift. See [enableRestartProve] for why it is
        // restart-and-check rather than `enable --now` and a hope.
        ) + enableRestartProve("the unit was written but did not come up") + listOf(
            // Lingering needs root. Asked for without sudo, so it succeeds where policy allows it
            // and fails harmlessly everywhere else — the caller reads the answer back rather than
            // assuming either way.
            "loginctl enable-linger \"\$(id -un)\" >/dev/null 2>&1 || true",
            "printf \"linger %s\\n\" \"\$(loginctl show-user \"\$(id -u)\" -p Linger --value 2>/dev/null)\"",
            "exit 0",
        )
    ).joinToString("\n")

    /**
     * **`restart` and then a proof, not `enable --now` and a hope** — the shared heart of both the
     * update path ([service]) and the standalone Restart button ([restart]).
     *
     * `enable --now` starts a stopped unit — but only if the daemon it runs can take the socket the
     * instant it is asked, and after a `"$b" stop` the process it just killed may still be releasing
     * its pid lock and its relay slot. On a real WSL box on 2026-08-27 that race lost: the stop
     * landed, the start did not, and the in-app Update finished having replaced the files and left
     * the host **down** — while the card said *"is a machine of its own now"*. That is the bug Asad
     * reported in his own words: *"after updating server app it keeps reconnecting… server is still
     * connected but not the sessions"*.
     *
     * So the unit is enabled for next boot, then **restarted** — which from systemd's own view is
     * stop-if-running-then-start and cannot be raced by a CLI stop that already happened — and then
     * this waits for the daemon to take the socket and **checks that it did**. A daemon that lost
     * the lock race gets a moment and one more restart; only then is failure real, and it is
     * reported rather than swallowed. `enable` is split off `--now` so a benign second enable cannot
     * fail the step — and, for the standalone Restart, it is also what *arms a disabled unit for
     * boot*, which is half of "if it is not automatically activated we click restart and it
     * activates it on the server".
     */
    private fun enableRestartProve(failure: String): List<String> = listOf(
        "systemctl --user enable $ID.service >/dev/null 2>&1 || true",
        "systemctl --user restart $ID.service || exit 1",
        "up=",
        "for _ in 1 2 3 4 5 6; do",
        "  if systemctl --user is-active --quiet $ID.service; then up=1; break; fi",
        "  sleep 1",
        "done",
        "if [ -z \"\$up\" ]; then",
        // One deliberate retry: the daemon's own "already running" refusal clears once the killed
        // process finishes letting go, which is exactly the window a second restart a few seconds
        // later steps past.
        "  systemctl --user restart $ID.service || exit 1",
        "  for _ in 1 2 3 4 5 6; do",
        "    if systemctl --user is-active --quiet $ID.service; then up=1; break; fi",
        "    sleep 1",
        "  done",
        "fi",
        "[ -n \"\$up\" ] || { echo \"$failure\" >&2; exit 1; }",
    )

    /**
     * **Restart the host on this server**, standalone — his own words for the button this is behind:
     *
     * > *"we should have one button to restart the terminal deck — if it is not automatically
     * > activated we click restart and it activates it on the server; if we want to close it we can
     * > close, if we want to open we can open. We cannot do it directly on a headless server, so we
     * > need the control here in the server page to manage whenever it is needed (heavy CPU, many
     * > browser tabs, many sessions)."*
     *
     * Three shapes, one per kind of server:
     *
     *  - **A user unit already exists** — reuse the update path's restart-and-prove exactly
     *    ([enableRestartProve]): enable, restart, wait, and *check it came up*. This is
     *    `systemctl --user restart terminaldeck.service` with the proof around it, independent of
     *    the host's own protocol version, so it works against a server this app has never updated.
     *  - **A user systemd but no unit of ours yet** — installed, but started by hand or by an old
     *    build. [service] writes the unit and brings it up under it, the "it activates it" half.
     *  - **No systemd at all** — a container. Stop it the way its own command knows how, then start
     *    it again directly; the survey the caller runs afterwards is what reports the result.
     */
    fun restart(command: String, hasUnit: Boolean, systemdUser: Boolean): String = when {
        systemdUser && hasUnit ->
            (enableRestartProve("the unit was restarted but did not come up") + "exit 0")
                .joinToString("\n")
        systemdUser -> service(command)
        else -> listOf(
            "b=${quote(command)}",
            "\"\$b\" stop >/dev/null 2>&1 || true",
            startDirect(command),
        ).joinToString("\n")
    }

    /**
     * Start it without a unit — a container has no init by design, and a host running now is what
     * somebody pressed the button for.
     */
    fun startDirect(command: String): String = listOf(
        "b=${quote(command)}",
        "if grep -q $ID-launcher \"\$b\" 2>/dev/null; then",
        "  h=\"\$HOME/.$ID/runtime/bin/$ID-host\"",
        "else",
        "  h=\"\$(dirname \"\$b\")/$ID-host\"",
        "fi",
        "[ -x \"\$h\" ] || exit 1",
        /*
         * **Its output goes to a file, not to /dev/null.**
         *
         * This was `>/dev/null 2>&1`, and the cost of that is a sentence this app shows: a session
         * the host refuses to start says *"Check it on the machine itself"* — and the reason it
         * refused is written to stderr by `session-create.ts`, which on a host started this way
         * went nowhere at all. So the remedy named on screen was impossible to carry out on
         * exactly the machines that need it, which are the ones with no systemd to catch stderr
         * for them.
         *
         * Beside the host's own log rather than in /tmp, so it is where somebody already looking at
         * that folder will find it, and it survives a reboot that clears /tmp. Appended, not
         * truncated: two starts a week apart are two things worth reading.
         */
        "d=\"\${XDG_DATA_HOME:-\$HOME/.local/share}/$ID\"",
        "mkdir -p \"\$d\" 2>/dev/null || true",
        "nohup \"\$h\" >>\"\$d/host-stderr.log\" 2>&1 &",
        "exit 0",
    ).joinToString("\n")

    /**
     * Start it, whichever way this server can.
     *
     * The unit first when there is a user systemd, because that is the one that survives a reboot;
     * the direct start when there is not. A machine with a unit that is merely stopped is started
     * by `systemctl`, not by a second copy of the daemon running beside the one the unit will
     * start later.
     */
    fun start(command: String, hasUnit: Boolean, systemdUser: Boolean): String =
        if (hasUnit && systemdUser) {
            "systemctl --user start $ID.service && exit 0"
        } else {
            startDirect(command)
        }

    /**
     * Ask the host for its address — which is really a way of **waiting for the relay dial to
     * finish**, on the far side, where the answer lives.
     *
     * ## The gap this closes
     *
     * [start] returns the instant systemd or `nohup` has forked; the relay dial is a WebSocket
     * across the internet and is still in flight. So the probe that ran a moment later read a
     * `status` with no address block, and the card that said *"start it and connect"* started it
     * and then connected to nothing at all. Measured by the host's own author on a real server:
     * *"the address was there when asked again fourteen seconds later. Same code, same machine,
     * different luck."*
     *
     * ## Why this command rather than a timer on the phone
     *
     * Because the wait already exists and it is already correct. `terminaldeck address` polls its
     * own daemon every 400 ms for up to ten seconds, and — the part a phone-side loop could not
     * copy — it only waits for a host **young enough that the relay could still be dialling**,
     * measured from the host's own `startedAt`. Re-running the survey on a timer from here would be
     * the phone asking the same question over and over, which is the standing rule about polling,
     * and it would still be a worse answer than the one the host already has.
     *
     * Its output is deliberately thrown away. The address that reaches a screen is the one
     * [HostProbe.serverAddress] reads out of the following `status`; having two sources for one
     * string is how they come to disagree. What is wanted here is the *time*. Failure is not a
     * failure: an older host has no `address` verb and exits non-zero, which is one of the two
     * states the card is about, and the survey after it is what says so.
     */
    fun address(command: String): String = listOf(
        "b=${quote(command)}",
        // `>/dev/null` on both: `address` writes a pasteable line to stdout and a note to stderr,
        // and neither is read here.
        "\"\$b\" address >/dev/null 2>&1 || true",
        "exit 0",
    ).joinToString("\n")

    /**
     * The way back, and it removes exactly what was added.
     *
     * `removeScript` from the desktop, line for line, including the guard that matters most:
     * **nothing outside `$HOME`**. Every path this is handed came off the server itself through
     * `command -v`, so a machine whose PATH turns up a system-wide copy — installed by somebody
     * else, by a package manager, for everyone — is a machine where the honest answer is to refuse
     * rather than to start deleting on a phone user's behalf.
     *
     * The data folder is never touched unless it was asked for. That is the same argument `setup.ts`
     * makes about `~/.claude`: *"those folders are the person's own … removing one would be deleting
     * somebody's work under the heading of undoing our own."*
     */
    fun remove(command: String, dataDir: String, alsoData: Boolean): String {
        val lines = mutableListOf(
            "b=${quote(command)}",
            "case \"\$b\" in \"\$HOME\"/*) ;; *) echo \"not ours to remove\" >&2; exit 1 ;; esac",
            // The service first: stopping it is what releases the files below, and a unit left
            // enabled would keep trying to start a program that has gone — every five seconds, for
            // as long as that server is up.
            "if [ -f \"\$HOME/.config/systemd/user/$ID.service\" ]; then",
            "  systemctl --user disable --now $ID.service >/dev/null 2>&1 || true",
            "  rm -f \"\$HOME/.config/systemd/user/$ID.service\"",
            "  systemctl --user daemon-reload >/dev/null 2>&1 || true",
            "fi",
            // Then the daemon itself, in case it was started by hand rather than by the unit. Its
            // own command is the one thing that knows how to stop it cleanly.
            "\"\$b\" stop >/dev/null 2>&1 || true",
            "if grep -q $ID-launcher \"\$b\" 2>/dev/null; then",
            "  rm -rf \"\$HOME/.$ID/runtime\"",
            "  rm -f \"\$b\"",
            "  rmdir \"\$HOME/.$ID\" 2>/dev/null || true",
            "else",
            "  d=\$(dirname \"\$b\")",
            "  rm -f \"\$d/$ID\" \"\$d/$ID-host\"",
            "  rm -rf \"\$d/../lib/node_modules/$ID\"",
            "fi",
        )
        if (alsoData) {
            lines += "dd=${quote(dataDir)}"
            lines += "case \"\$dd\" in \"\$HOME\"/*) rm -rf \"\$dd\" ;; *) echo \"not ours to remove\" >&2 ;; esac"
        }
        lines += "exit 0"
        return lines.joinToString("\n")
    }

    /**
     * Stop it, and mean it.
     *
     * The unit first — stopping the daemon while its unit is still enabled would have systemd
     * start it again within `RestartSec` — and then the host's own `stop`, which is what knows how
     * to end it cleanly when it was started by hand. Neither is treated as a failure on its own: a
     * host started directly has no unit, and a host under a unit has nothing left for `stop` to do.
     */
    fun stop(command: String, hasUnit: Boolean): String {
        val lines = mutableListOf("b=${quote(command)}")
        if (hasUnit) {
            lines += "systemctl --user stop $ID.service >/dev/null 2>&1 || true"
        }
        lines += "\"\$b\" stop >/dev/null 2>&1 || true"
        lines += "exit 0"
        return lines.joinToString("\n")
    }
}
