/**
 * The commands the phone sends a server.
 *
 * Shell that is composed rather than typed has one failure mode worth a test
 * suite of its own: it is fine on the machine it was written against and wrong
 * on somebody else's. So what is asserted here is the shape of the *hazards* —
 * a home directory with a space in it, a quote inside a path, an installer that
 * would run before it is fully written, a daemon restarted by the unit that was
 * supposed to have stopped it.
 */

import XCTest
@testable import TerminalDeck

final class ServerScriptsTests: XCTestCase {

    func testQuotesAPathWithASpaceInIt() {
        XCTAssertEqual(ServerScripts.quote("/home/asad iqbal/.local/bin/terminaldeck"),
                       "'/home/asad iqbal/.local/bin/terminaldeck'")
    }

    /// The one that matters: a single quote inside the value must not end the
    /// quoting and start a command.
    func testAQuoteInsideAPathCannotEscapeIt() {
        XCTAssertEqual(ServerScripts.quote("/home/o'brien/bin"), "'/home/o'\\''brien/bin'")
    }

    // MARK: - Which host it installs

    /**
     * **Never the registry**, and this is the regression the whole of
     * `ServerScripts.hostPackage` exists for.
     *
     * `terminaldeck@latest` on npmjs.org was 0.6.1 while this app was 0.10.1,
     * and 0.6.1 is older than the host printing a server address — which is the
     * only thing a phone can dial. So the install succeeded, the service
     * started, and the connect step drew a refusal. Every step reported success
     * and the feature did not work. A test that only checked "an installer runs"
     * would have passed through all of it, so this one checks what it installs.
     */
    func testNeverInstallsWhateverTheRegistryHappensToCallLatest() {
        let command = ServerScripts.runInstaller(at: "/tmp/x/install.sh", version: "0.10.1")
        XCTAssertTrue(command.contains("TERMINALDECK_PACKAGE="),
                      "nothing is named, so the installer falls back to the registry")
        XCTAssertFalse(command.contains("terminaldeck@latest"))
        XCTAssertFalse(command.contains("@latest"))
    }

    /**
     * The exact asset `release.yml` uploads.
     *
     * That job runs `npm pack ./out/headless` and uploads the result beside the
     * Mac and Windows downloads, so the file is named after the package version
     * and the tag is that version with a `v`. Both halves of that are asserted
     * here because both are guesses this app makes about another file in this
     * repository, and a rename there would otherwise show up as a 404 on
     * somebody's server rather than as a failing test.
     */
    func testNamesTheReleaseTarballForItsOwnVersion() {
        XCTAssertEqual(ServerScripts.hostPackage(version: "0.10.1"),
                       "https://github.com/asadev/terminaldeck/releases/download/"
                           + "v0.10.1/terminaldeck-0.10.1.tgz")
    }

    /// It is a URL in single quotes, on one line, in front of `sh` — an export
    /// in an earlier command would land in a shell that has already exited,
    /// because `SSHSession.stream` opens a channel per command.
    func testTheInstallerRunsWithThePackageInItsOwnEnvironment() {
        let command = ServerScripts.runInstaller(at: "/tmp/o'brien/install.sh", version: "1.2.3")
        XCTAssertFalse(command.contains("\n"), "one command, one channel")
        XCTAssertTrue(command.hasSuffix("sh '/tmp/o'\\''brien/install.sh'"),
                      "the staged path is quoted: \(command)")
        XCTAssertTrue(command.hasPrefix("TERMINALDECK_PACKAGE='https://"))
    }

    /// Defaulted from the bundle rather than restated, so a version bump cannot
    /// leave this pointing at a release that is no longer the app.
    func testTakesTheVersionFromTheAppItself() {
        XCTAssertTrue(ServerScripts.hostPackage().contains("v\(Brand.version)"),
                      ServerScripts.hostPackage())
    }

    // MARK: - Getting the installer there

    func testStagesTheInstallerToAFileAndPrintsWhereItLanded() {
        let staged = ServerScripts.stageInstaller("#!/bin/sh\necho hello\n")
        XCTAssertTrue(staged.script.contains("mkdir -p"))
        XCTAssertTrue(staged.script.contains("chmod +x"))
        XCTAssertTrue(staged.script.hasSuffix("printf '%s\\n' \"$d/install.sh\""),
                      "the caller reads the path out of stdout")
    }

    /**
     * The heredoc is quoted, so nothing in the installer is expanded on the way.
     *
     * `install-headless.sh` is full of `$HOME`, `$(uname -m)` and backticks. An
     * unquoted heredoc would evaluate every one of them on arrival and write a
     * file that is not the installer.
     */
    func testTheHeredocExpandsNothing() {
        let staged = ServerScripts.stageInstaller("PREFIX=\"$HOME/.local\"\n")
        let mark = staged.script
            .split(separator: "\n")
            .first { $0.hasPrefix("cat > ") }?
            .components(separatedBy: "<<'").last?
            .replacingOccurrences(of: "'", with: "")
        XCTAssertNotNil(mark)
        XCTAssertTrue(mark!.hasPrefix("TD_INSTALLER_"))
        XCTAssertTrue(staged.script.contains("PREFIX=\"$HOME/.local\""))
    }

    /**
     * The file that lands is the file this app carries, byte for byte.
     *
     * A heredoc ends its body with the newline in front of the delimiter, so a
     * text that already ends in one is delivered a blank line longer. Caught by
     * hashing both ends against a real server — the script ran perfectly either
     * way, which is what makes it the kind of difference nobody notices until
     * something checks a signature.
     */
    func testDeliversExactlyTheBytesItWasGiven() {
        let installer = "#!/bin/sh\nset -eu\necho hello\n"
        let staged = ServerScripts.stageInstaller(installer)
        let lines = staged.script.components(separatedBy: "\n")
        guard let opens = lines.firstIndex(where: { $0.hasPrefix("cat > ") }),
              let mark = lines[opens].components(separatedBy: "<<'").last?
                  .replacingOccurrences(of: "'", with: ""),
              let closes = lines[(opens + 1)...].firstIndex(of: mark)
        else { return XCTFail("no heredoc in the staging script") }
        // What the far end's `cat` writes: the body, plus the newline that ends
        // its last line.
        let delivered = lines[(opens + 1)..<closes].joined(separator: "\n") + "\n"
        XCTAssertEqual(delivered, installer)
    }

    /// A delimiter that could appear in the installer would end the heredoc
    /// early and leave half a script on the server.
    func testTheDelimiterIsDifferentEveryTime() {
        let first = ServerScripts.stageInstaller("x")
        let second = ServerScripts.stageInstaller("x")
        XCTAssertNotEqual(first.script, second.script)
    }

    // MARK: - The unit

    func testWritesAUserUnitAndAsksForLingeringWithoutSudo() {
        let script = ServerScripts.service(command: "/root/.local/bin/terminaldeck")
        XCTAssertTrue(script.contains("$HOME/.config/systemd/user/terminaldeck.service"))
        // `enable` sets the boot symlink; `restart` is what actually brings it
        // up, split apart so a benign second enable cannot fail the step — see
        // the note over the proof loop in `service()`.
        XCTAssertTrue(script.contains("systemctl --user enable terminaldeck.service"))
        XCTAssertTrue(script.contains("systemctl --user restart terminaldeck.service"))
        XCTAssertTrue(script.contains("is-active --quiet"),
                      "the script must prove the unit came up, not assume it")
        XCTAssertTrue(script.contains("did not come up"),
                      "and fail loudly if it did not, so the card cannot claim success over a dead host")
        XCTAssertFalse(script.contains("sudo "), "this feature never asks for administrator access")
        XCTAssertTrue(script.contains("loginctl enable-linger"))
        XCTAssertTrue(script.contains("|| true"), "lingering is asked for, never required")
    }

    /**
     * **The unit does not fight the host the installer left running.**
     *
     * `install-headless.sh` starts one; this script then enables a unit whose
     * `ExecStart` is the same daemon, and the daemon refuses to be a second copy
     * — correctly, and with exit 1. `Restart=on-failure` turns that refusal into
     * a restart every five seconds forever: thirty-eight of them on a real
     * server before anybody looked, with nothing visible on the phone because
     * the host somebody pressed the button for was running fine. The stop has to
     * come before `enable --now`, so the order is asserted rather than the mere
     * presence of both.
     */
    func testStopsTheAlreadyRunningHostBeforeGivingTheUnitTheJob() {
        let script = ServerScripts.service(command: "/root/.local/bin/terminaldeck")
        guard let stopAt = script.range(of: "stop >/dev/null"),
              let startAt = script.range(of: "systemctl --user restart")
        else { return XCTFail("the service script no longer stops or no longer restarts") }
        XCTAssertTrue(stopAt.lowerBound < startAt.lowerBound,
                      "the unit is started while another host still holds the socket")
    }

    /**
     * `ExecStart` is the daemon, not the CLI.
     *
     * They are two programs. When the installer supplies its own Node it writes
     * a launcher for the CLI only, so a unit pointing at `~/.local/bin/…-host`
     * would name a file that is not there — which is why the script asks the
     * launcher which shape it is.
     */
    func testTheUnitStartsTheDaemonAndFindsItInBothLayouts() {
        let script = ServerScripts.service(command: "/root/.local/bin/terminaldeck")
        XCTAssertTrue(script.contains("terminaldeck-launcher"))
        XCTAssertTrue(script.contains("ExecStart=$host"))
        XCTAssertTrue(script.contains("[ -x \"$host\" ]"), "it refuses rather than writing a dead unit")
    }

    // MARK: - Start and stop

    func testStartsThroughSystemdWhenThereIsAUnitToStart() {
        let script = ServerScripts.start(command: "/root/.local/bin/terminaldeck",
                                         hasUnit: true, systemdUser: true)
        XCTAssertTrue(script.contains("systemctl --user start"))
        XCTAssertFalse(script.contains("nohup"),
                       "a second daemon beside the one the unit will start is two hosts")
    }

    func testStartsDirectlyWhereThereIsNoInitAtAll() {
        let script = ServerScripts.start(command: "/root/.local/bin/terminaldeck",
                                         hasUnit: false, systemdUser: false)
        XCTAssertTrue(script.contains("nohup"))
        /*
         * And its output is kept. A host started this way has no journal behind
         * it, so `>/dev/null 2>&1` — which is what this was — threw away the
         * only copy of the reason a session refused to start, while the phone
         * told the person to go and check that machine.
         */
        XCTAssertFalse(script.contains(">/dev/null 2>&1 &"),
                       "the host's own words about a refused session go nowhere")
        XCTAssertTrue(script.contains("host-stderr.log"))
    }

    /**
     * Stopping the daemon while its unit is still running would have systemd
     * start it again within `RestartSec`, so the unit is stopped first.
     */
    func testStopsTheUnitBeforeTheDaemon() {
        let script = ServerScripts.stop(command: "/root/.local/bin/terminaldeck", hasUnit: true)
        let unitAt = script.range(of: "systemctl --user stop")
        let daemonAt = script.range(of: "\"$b\" stop")
        XCTAssertNotNil(unitAt)
        XCTAssertNotNil(daemonAt)
        XCTAssertTrue(unitAt!.lowerBound < daemonAt!.lowerBound)
    }

    func testStopsAHostThatWasStartedByHandAndHasNoUnit() {
        let script = ServerScripts.stop(command: "/root/.local/bin/terminaldeck", hasUnit: false)
        XCTAssertFalse(script.contains("systemctl"))
        XCTAssertTrue(script.contains("\"$b\" stop"))
    }

    // MARK: - Restart

    /**
     * The standalone Restart button, on a server that already has a unit: the
     * update path's restart-and-prove, standing on its own.
     *
     * It restarts the unit and **checks it came up** — that is the whole reason
     * this is not `systemctl --user restart` and a hope. A restart that loses the
     * socket race gets one more try and is then reported, exactly as the update
     * path proves it. And it does *not* re-write the unit: a plain restart of an
     * installed, unitised host has no business rewriting the file.
     */
    func testRestartThroughSystemdRestartsTheUnitAndProvesItCameUp() {
        let script = ServerScripts.restart(command: "/root/.local/bin/terminaldeck",
                                           hasUnit: true, systemdUser: true)
        XCTAssertTrue(script.contains("systemctl --user restart terminaldeck.service"))
        XCTAssertTrue(script.contains("is-active --quiet"),
                      "a restart that cannot prove it came up is a control that lies")
        XCTAssertTrue(script.contains("did not come up"))
        XCTAssertTrue(script.contains("systemctl --user enable terminaldeck.service"),
                      "restart also arms a disabled unit for boot — \"it activates it\"")
        XCTAssertFalse(script.contains("[Unit]"),
                       "a plain restart does not re-write the unit file")
        XCTAssertFalse(script.contains("sudo "))
    }

    /**
     * Restart on an installed host with a user systemd but **no unit of ours
     * yet** — started by hand, or by an old build. This is the "if it is not
     * automatically activated we click restart and it activates it on the
     * server" half: it writes the unit and brings it up, which is the very verb
     * the install path runs, so the two cannot answer differently.
     */
    func testRestartWithNoUnitYetCreatesTheUnitAndActivatesIt() {
        let script = ServerScripts.restart(command: "/root/.local/bin/terminaldeck",
                                           hasUnit: false, systemdUser: true)
        XCTAssertEqual(script, ServerScripts.service(command: "/root/.local/bin/terminaldeck"),
                       "activating a host that has no unit is exactly what `service` does")
        XCTAssertTrue(script.contains("$HOME/.config/systemd/user/terminaldeck.service"))
    }

    /**
     * Restart where there is no systemd at all — a container. There is no unit
     * to be active, so it stops the daemon the way its own command knows how and
     * starts it again directly; the survey the connector runs afterwards is what
     * reports whether it is up.
     */
    func testRestartWithoutSystemdStopsThenStartsDirectly() {
        let script = ServerScripts.restart(command: "/root/.local/bin/terminaldeck",
                                           hasUnit: false, systemdUser: false)
        XCTAssertFalse(script.contains("systemctl"),
                       "a container has no init by design")
        XCTAssertTrue(script.contains("\"$b\" stop"))
        XCTAssertTrue(script.contains("nohup"))
        // Stop before start, or the restart is a start beside a host still up.
        let stopAt = script.range(of: "\"$b\" stop")
        let startAt = script.range(of: "nohup")
        XCTAssertNotNil(stopAt)
        XCTAssertNotNil(startAt)
        XCTAssertTrue(stopAt!.lowerBound < startAt!.lowerBound)
    }
}
