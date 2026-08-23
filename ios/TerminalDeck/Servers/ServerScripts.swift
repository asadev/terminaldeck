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
 *    answers nothing"*. That is no longer true — the registry now carries a real
 *    `terminaldeck` with both `bin` entries — so the phone sends the installer
 *    only and lets it do what it was written to do. A phone cannot carry a
 *    tarball of a Node package it does not build, and it does not have to.
 *  - **Start and stop.** The desktop has install and remove and nothing between
 *    them, because it is sitting in front of a terminal on that server. Asad
 *    asked for these two by name for the phone: *"then you can connect, and
 *    disconnect if you want"*, and before that, *"it brings it up"*.
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
            "nohup \"$h\" >/dev/null 2>&1 &",
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
