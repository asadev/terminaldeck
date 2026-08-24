/**
 * The commands the phone sends a server, and the reasons each one is shaped the
 * way it is.
 *
 * Everything here is a port of `src/main/servers/host.ts` — the same unit file,
 * the same fallback when there is no systemd, the same quoting. Two things are
 * new because the phone's situation is different, and both are stated where they
 * are done:
 *
 *  - **Getting the installer onto the server.** The desktop uploads two files
 *    over SFTP: `install.sh` and a tarball of the host, because
 *    `host-package.ts` argued that the npm name was a placeholder with no `bin`
 *    entry and installing it would leave *"a host that looks installed and
 *    answers nothing"*. A phone cannot carry a tarball of a Node package it does
 *    not build, so it sends the installer only — and **names the tarball the
 *    installer is to fetch**, which is `hostPackage` below and is the whole
 *    reason that function exists.
 *  - **Start and stop.** The desktop has install and remove and nothing between
 *    them, because it is sitting in front of a terminal on that server. Asad
 *    asked for these two by name for the phone: *"then you can connect, and
 *    disconnect if you want"*, and before that, *"it brings it up"*.
 *
 * Remove is not in that second list because it is not new: it is `removeScript`
 * ported line for line, and the header it comes from says why it exists at all
 * — *"If we want to uninstall we can uninstall."* It was missing here while the
 * install card promised it in as many words, which is a promise a card should
 * never have been able to make on its own.
 */

import Foundation

enum ServerScripts {

    /**
     * One argument, safe inside single quotes.
     *
     * Every path this quotes came off the server itself — `command -v`, and the
     * XDG folder the host reads — so it is not attacker-controlled in any
     * ordinary sense. It is quoted anyway, because "not ordinarily
     * attacker-controlled" is the assumption every shell injection was built on,
     * and because a home directory with a space in it is not exotic.
     */
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /**
     * **Which host the server is told to install** — and why it is not
     * `terminaldeck@latest` from the registry.
     *
     * ## What was measured
     *
     * It *was* `terminaldeck@latest`, on the reasoning that the registry had
     * stopped being a placeholder and now carried a real package with both `bin`
     * entries. That reasoning was right and the conclusion was still wrong,
     * because it checked whether the name resolved and not **what version it
     * resolved to**. Run against a bare Hetzner box on 2026-08-24: the install
     * succeeded, systemd started it, the card said *"is a machine of its own
     * now"* — and then the connect step drew a refusal, because
     * `terminaldeck@latest` is **0.6.1** while this app is 0.10.1, and 0.6.1
     * predates the host printing a server address. A server address is the only
     * thing a phone can dial. So the whole flow Asad asked for — *"you click, it
     * installs, then you can connect"* — installed a host and dead-ended, with
     * every step reporting success.
     *
     * The registry is eight tagged versions behind and publishing to it is a
     * separate act with a separate credential. What is **not** behind is the
     * release: `release.yml` runs `npm pack ./out/headless` on every tag and
     * uploads the tarball beside the Mac and Windows downloads, built from the
     * tagged tree rather than from somebody's disk. That asset is what this
     * names.
     *
     * ## Why the app's own version, exactly
     *
     * Because the two halves have to agree about the wire, and the only version
     * this app can promise anything about is its own. `npm pack` names the file
     * after the package version, so the asset for a tag is derivable rather than
     * looked up — no registry, no API call, no token, and nothing to be rate
     * limited. A build whose tag was never released gets a 404 from npm, the
     * install fails, and the installer's own words are on the card; that is a
     * worse day than a success and a much better one than a host nobody can
     * reach.
     */
    static func hostPackage(version: String = Brand.version) -> String {
        "https://github.com/asadev/\(Brand.id)/releases/download/"
            + "v\(version)/\(Brand.id)-\(version).tgz"
    }

    /**
     * The one command that runs the staged installer, with the package named.
     *
     * The assignment is in front of the command rather than exported earlier in
     * a separate round trip, because `SSHSession.stream` opens a channel per
     * command and an export would land in a shell that has already exited.
     */
    static func runInstaller(at path: String, version: String = Brand.version) -> String {
        "TERMINALDECK_PACKAGE=\(quote(packageToInstall(version: version))) sh \(quote(path))"
    }

    /**
     * The release tarball — or, in a debug build only, a build being tried
     * before it is published.
     *
     * `install-headless.sh` names that case in its own header as one of the two
     * reasons `TERMINALDECK_PACKAGE` exists: *"a server with no route to
     * npmjs.org, or a build being tried before it is published"*. It is the only
     * way to put a host on a server from this app and then check the change you
     * just made to that host, because the release path can only ever install
     * what is already tagged. `TD_SERVER_HOST_PACKAGE` is anything npm accepts,
     * including a path on the far end.
     *
     * Debug only, beside the other `TD_SERVER_…` variables and for the same
     * reason. A shipping build has exactly one answer here.
     */
    static func packageToInstall(version: String = Brand.version) -> String {
        #if DEBUG
        let named = ProcessInfo.processInfo.environment["TD_SERVER_HOST_PACKAGE"] ?? ""
        if !named.isEmpty { return named }
        #endif
        return hostPackage(version: version)
    }

    /**
     * Put the installer on the server, and answer with where it landed.
     *
     * A heredoc with a delimiter nothing can collide with, rather than base64:
     * base64 would need a decoder on the far end and there are three spellings
     * of that flag across the systems this has to work on. A quoted heredoc
     * expands nothing, so the script arrives byte for byte.
     *
     * It is staged to a file rather than piped straight into `sh -s`, and that
     * is not tidiness. `sh -s` reads its script from the same stream anything it
     * runs would read from, so one command inside the installer that touches
     * standard input eats the rest of the installer. The desktop stages a file
     * for the same reason.
     */
    static func stageInstaller(_ installer: String) -> (script: String, path: String) {
        let mark = "TD_INSTALLER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let path = "$d/install.sh"
        // One trailing newline is dropped, and the file still ends with one.
        //
        // A heredoc terminates its body with the newline before the delimiter,
        // so embedding a text that already ends in `\n` delivers a file one
        // blank line longer than the original. Measured against a real server by
        // hashing both ends: `1797edb5…` on the server against `3255fe0b…` here,
        // for a script that ran perfectly well — which is exactly the kind of
        // difference that is invisible until something checks a signature.
        let body = installer.hasSuffix("\n") ? String(installer.dropLast()) : installer
        let script = [
            "set -e",
            "d=${TMPDIR:-/tmp}/\(mark)",
            "mkdir -p \"$d\"",
            "cat > \(path) <<'\(mark)'",
            body,
            mark,
            "chmod +x \(path)",
            "printf '%s\\n' \"\(path)\"",
        ].joined(separator: "\n")
        return (script, path)
    }

    /**
     * A systemd **user** unit, and why it is a user unit.
     *
     * A system unit lives in `/etc/systemd/system` and needs root to write,
     * enable and start — which this feature does not ask for. A user unit lives
     * in the account's own home and `systemctl --user` starts it with no
     * privilege at all. What that costs is stated rather than hidden: without
     * lingering, the account's systemd manager stops when the last login ends,
     * taking the host with it — which is exactly what *"a phone that was paired
     * to it then finds nothing there"* looks like.
     *
     * `ExecStart` is `terminaldeck-host`, not `terminaldeck`: they are two
     * programs, the second being the CLI and the first the daemon. When the
     * installer supplies its own Node it writes a launcher for the CLI **only**,
     * so the daemon has to be named by its real path with the private runtime on
     * PATH.
     */
    static func service(command: String) -> String {
        [
            "b=\(quote(command))",
            "if grep -q \(Brand.id)-launcher \"$b\" 2>/dev/null; then",
            "  rt=\"$HOME/.\(Brand.id)/runtime\"",
            "  host=\"$rt/bin/\(Brand.id)-host\"",
            "  bin=\"$rt/bin\"",
            "else",
            "  bin=$(dirname \"$b\")",
            "  host=\"$bin/\(Brand.id)-host\"",
            "fi",
            "[ -x \"$host\" ] || { echo \"no host daemon beside $b\" >&2; exit 1; }",
            /*
             * **Stop whatever is already running, because the unit is about to
             * own it.**
             *
             * `install-headless.sh` leaves a host running — that is the point of
             * it — and this script then enables a unit whose `ExecStart` is the
             * same daemon. The daemon refuses to be a second copy, correctly:
             * *"A Terminal Deck host is already running here as pid …"*, exit 1.
             * With `Restart=on-failure` and `RestartSec=5` that is not a one-off
             * failure, it is a **loop**: measured on a real server on
             * 2026-08-24, thirty-eight restarts and climbing, one failed unit
             * every five seconds in that machine's journal, for as long as it is
             * up. Nothing on the phone shows it, because the host somebody
             * pressed the button for is running perfectly — it is just the one
             * the installer started rather than the one systemd thinks it owns.
             *
             * So the running one is stopped, and `enable --now` on the next line
             * starts the same daemon under the unit. The end state is what the
             * card claims: one host, started by systemd, back after a reboot.
             */
            "\"$b\" stop >/dev/null 2>&1 || true",
            "mkdir -p \"$HOME/.config/systemd/user\" || exit 1",
            "cat > \"$HOME/.config/systemd/user/\(Brand.id).service\" <<UNIT",
            "[Unit]",
            "Description=\(Brand.name) host",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            "ExecStart=$host",
            "Environment=PATH=$bin:/usr/local/bin:/usr/bin:/bin",
            "Restart=on-failure",
            "RestartSec=5",
            "",
            "[Install]",
            "WantedBy=default.target",
            "UNIT",
            "systemctl --user daemon-reload || exit 1",
            "systemctl --user enable --now \(Brand.id).service || exit 1",
            // Lingering needs root. Asked for without sudo, so it succeeds where
            // policy allows it and fails harmlessly everywhere else — the caller
            // reads the answer back rather than assuming either way.
            "loginctl enable-linger \"$(id -un)\" >/dev/null 2>&1 || true",
            "printf \"linger %s\\n\" \"$(loginctl show-user \"$(id -u)\" -p Linger --value 2>/dev/null)\"",
            "exit 0",
        ].joined(separator: "\n")
    }

    /// Start it without a unit — a container has no init by design, and a host
    /// running now is what somebody pressed the button for.
    static func startDirect(command: String) -> String {
        [
            "b=\(quote(command))",
            "if grep -q \(Brand.id)-launcher \"$b\" 2>/dev/null; then",
            "  h=\"$HOME/.\(Brand.id)/runtime/bin/\(Brand.id)-host\"",
            "else",
            "  h=\"$(dirname \"$b\")/\(Brand.id)-host\"",
            "fi",
            "[ -x \"$h\" ] || exit 1",
            /*
             * **Its output goes to a file, not to /dev/null.**
             *
             * This was `>/dev/null 2>&1`, and the cost of that is a sentence
             * this app shows: a session the host refuses to start says *"Check
             * it on the machine itself"* — and the reason it refused is written
             * to stderr by `session-create.ts`, which on a host started this way
             * went nowhere at all. So the remedy named on screen was impossible
             * to carry out on exactly the machines that need it, which are the
             * ones with no systemd to catch stderr for them.
             *
             * Beside the host's own log rather than in /tmp, so it is where
             * somebody already looking at that folder will find it, and it
             * survives a reboot that clears /tmp. Appended, not truncated: two
             * starts a week apart are two things worth reading.
             */
            "d=\"${XDG_DATA_HOME:-$HOME/.local/share}/\(Brand.id)\"",
            "mkdir -p \"$d\" 2>/dev/null || true",
            "nohup \"$h\" >>\"$d/host-stderr.log\" 2>&1 &",
            "exit 0",
        ].joined(separator: "\n")
    }

    /**
     * Start it, whichever way this server can.
     *
     * The unit first when there is a user systemd, because that is the one that
     * survives a reboot; the direct start when there is not. A machine with a
     * unit that is merely stopped is started by `systemctl`, not by a second
     * copy of the daemon running beside the one the unit will start later.
     */
    static func start(command: String, hasUnit: Bool, systemdUser: Bool) -> String {
        if hasUnit && systemdUser {
            return "systemctl --user start \(Brand.id).service && exit 0"
        }
        return startDirect(command: command)
    }

    /**
     * Ask the host for its address — which is really a way of **waiting for the
     * relay dial to finish**, on the far side, where the answer lives.
     *
     * ## The gap this closes
     *
     * `start` returns the instant systemd or `nohup` has forked; the relay dial
     * is a WebSocket across the internet and is still in flight. So the probe
     * that ran a moment later read a `status` with no address block, and the
     * card that said *"start it and connect"* started it and then connected to
     * nothing at all — `canConnect` was false, `connect()` returned, and the
     * button had visibly done nothing. Measured by the host's own author on a
     * real server, in `waitForAddress`: *"the address was there when asked
     * again fourteen seconds later. Same code, same machine, different luck."*
     *
     * ## Why this command rather than a timer on the phone
     *
     * Because the wait already exists and it is already correct. `terminaldeck
     * address` polls its own daemon every 400 ms for up to ten seconds, and —
     * the part a phone-side loop could not copy — it only waits for a host
     * **young enough that the relay could still be dialling**, measured from
     * the host's own `startedAt`. A host that has been up for an hour with no
     * relay has a real problem and answers immediately, as it should. Re-running
     * the survey on a timer from here would be the phone asking the same
     * question over and over, which is the standing rule about polling, and it
     * would still be a worse answer than the one the host already has.
     *
     * Its output is deliberately thrown away. The address that reaches a screen
     * is the one `HostProbe.serverAddress` reads out of the following `status`
     * and validates with the real parser, and having two sources for one string
     * is how they come to disagree. What is wanted here is the *time*.
     *
     * Failure is not a failure: an older host has no `address` verb and exits
     * non-zero, which is one of the two states this whole card is about, and
     * the survey after it is what says so.
     */
    static func address(command: String) -> String {
        [
            "b=\(quote(command))",
            // `>/dev/null` on both: `address` writes a pasteable line to stdout
            // and a note to stderr, and neither is read here.
            "\"$b\" address >/dev/null 2>&1 || true",
            "exit 0",
        ].joined(separator: "\n")
    }

    /**
     * The way back, and it removes exactly what was added.
     *
     * `removeScript` from the desktop, line for line, including the guard that
     * matters most: **nothing outside `$HOME`**. Every path this is handed came
     * off the server itself through `command -v`, so a machine whose PATH turns
     * up a system-wide copy — installed by somebody else, by a package manager,
     * for everyone — is a machine where the honest answer is to refuse rather
     * than to start deleting on a phone user's behalf.
     *
     * The data folder is never touched unless it was asked for. That is the
     * same argument `setup.ts` makes about `~/.claude`: *"those folders are the
     * person's own … removing one would be deleting somebody's work under the
     * heading of undoing our own."*
     */
    static func remove(command: String, dataDir: String, alsoData: Bool) -> String {
        var lines = [
            "b=\(quote(command))",
            "case \"$b\" in \"$HOME\"/*) ;; *) echo \"not ours to remove\" >&2; exit 1 ;; esac",
            // The service first: stopping it is what releases the files below,
            // and a unit left enabled would keep trying to start a program that
            // has gone — every five seconds, for as long as that server is up.
            "if [ -f \"$HOME/.config/systemd/user/\(Brand.id).service\" ]; then",
            "  systemctl --user disable --now \(Brand.id).service >/dev/null 2>&1 || true",
            "  rm -f \"$HOME/.config/systemd/user/\(Brand.id).service\"",
            "  systemctl --user daemon-reload >/dev/null 2>&1 || true",
            "fi",
            // Then the daemon itself, in case it was started by hand rather than
            // by the unit. Its own command is the one thing that knows how to
            // stop it cleanly.
            "\"$b\" stop >/dev/null 2>&1 || true",
            "if grep -q \(Brand.id)-launcher \"$b\" 2>/dev/null; then",
            "  rm -rf \"$HOME/.\(Brand.id)/runtime\"",
            "  rm -f \"$b\"",
            "  rmdir \"$HOME/.\(Brand.id)\" 2>/dev/null || true",
            "else",
            "  d=$(dirname \"$b\")",
            "  rm -f \"$d/\(Brand.id)\" \"$d/\(Brand.id)-host\"",
            "  rm -rf \"$d/../lib/node_modules/\(Brand.id)\"",
            "fi",
        ]
        if alsoData {
            lines.append("dd=\(quote(dataDir))")
            lines.append(
                "case \"$dd\" in \"$HOME\"/*) rm -rf \"$dd\" ;; *) echo \"not ours to remove\" >&2 ;; esac")
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    /**
     * Stop it, and mean it.
     *
     * The unit first — stopping the daemon while its unit is still enabled would
     * have systemd start it again within `RestartSec` — and then the host's own
     * `stop`, which is what knows how to end it cleanly when it was started by
     * hand. Neither is treated as a failure on its own: a host started directly
     * has no unit, and a host under a unit has nothing left for `stop` to do.
     */
    static func stop(command: String, hasUnit: Bool) -> String {
        var lines = ["b=\(quote(command))"]
        if hasUnit {
            lines.append("systemctl --user stop \(Brand.id).service >/dev/null 2>&1 || true")
        }
        lines.append("\"$b\" stop >/dev/null 2>&1 || true")
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }
}
