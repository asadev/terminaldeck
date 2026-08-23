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
        XCTAssertTrue(script.contains("systemctl --user enable --now"))
        XCTAssertFalse(script.contains("sudo "), "this feature never asks for administrator access")
        XCTAssertTrue(script.contains("loginctl enable-linger"))
        XCTAssertTrue(script.contains("|| true"), "lingering is asked for, never required")
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
}
