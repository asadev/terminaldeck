/**
 * The SSH client, against a **real server**, from the phone's own runtime.
 *
 * Skipped unless one is named, which is this repository's standing shape for a
 * live test (`*.live.test.ts` on the desktop side). Nothing is written down and
 * nothing is installed: it signs in, checks the identity, runs both survey
 * scripts and leaves.
 *
 *     TD_SERVER_ADDRESS=… TD_SERVER_PORT=22 TD_SERVER_USER=root \
 *     TD_SERVER_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     xcodebuild test -only-testing:TerminalDeckTests/SSHSessionLiveTests …
 *
 * It exists because the unit tests read output that was captured once, and a
 * reader that is perfect against a fixture proves nothing about the client that
 * produced it. This is the half that talks to somebody's sshd.
 */

import CryptoKit
import XCTest
@testable import TerminalDeck

final class SSHSessionLiveTests: XCTestCase {

    private func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    func testSignsInToARealServerAndSurveysIt() async throws {
        let address = env("TD_SERVER_ADDRESS")
        try XCTSkipIf(address.isEmpty, "No TD_SERVER_ADDRESS: nothing real to sign in to.")
        let key = env("TD_SERVER_KEY")
        let password = env("TD_SERVER_PASSWORD")
        let auth: SSHAuthMethod = key.isEmpty ? .password(password) : .key(key)

        let session = try await SSHSession.open(address: address,
                                                port: Int(env("TD_SERVER_PORT")) ?? 22,
                                                username: env("TD_SERVER_USER"),
                                                auth: auth,
                                                expect: nil)
        defer { session.close() }

        // The fingerprint is the one `ssh-keyscan host | ssh-keygen -lf -`
        // prints. That equality is the entire value of showing it.
        XCTAssertTrue(session.hostKey.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(session.hostKey.algorithm.isEmpty)

        let survey = try await session.run(ProbeScripts.server)
        XCTAssertEqual(survey.code, 0, survey.stderr)
        let facts = ServerProbe.read(survey.stdout)
        XCTAssertNotNil(facts.os.value, "a server that would not say what it is")
        XCTAssertNotNil(facts.uptimeSeconds.value)

        let host = try await session.run(ProbeScripts.host)
        XCTAssertEqual(host.code, 0, host.stderr)
        let look = HostProbe.read(host.stdout)
        XCTAssertFalse(look.room.os.isEmpty)
    }

    /**
     * The whole install channel, with the writing switched off.
     *
     * `install-headless.sh` has a dry run — `TERMINALDECK_DRYRUN=1` prints the
     * plan and exits, writing nothing — and that is exactly the shape of proof
     * this needs: it stages the real installer over the SSH channel, runs it,
     * and reads back the plan the far end made for **its own** architecture,
     * libc and Node. Everything the install does except the changes.
     *
     * Deliberately not a real install. The machine on the other end of a live
     * test is somebody's, and a suite that installed a service on it would be
     * the thing this repository has a rule against.
     *
     * The one footprint is a temporary directory under `$TMPDIR` holding a copy
     * of the installer, which the run removes.
     */
    func testStagesAndRunsTheRealInstallerWithoutWritingAnything() async throws {
        let address = env("TD_SERVER_ADDRESS")
        try XCTSkipIf(address.isEmpty, "No TD_SERVER_ADDRESS: nothing real to stage onto.")
        guard let installer = Bundle.main.url(forResource: "install-headless", withExtension: "sh"),
              let text = try? String(contentsOf: installer, encoding: .utf8)
        else { return XCTFail("this build does not carry the installer") }

        let key = env("TD_SERVER_KEY")
        let session = try await SSHSession.open(address: address,
                                                port: Int(env("TD_SERVER_PORT")) ?? 22,
                                                username: env("TD_SERVER_USER"),
                                                auth: key.isEmpty
                                                    ? .password(env("TD_SERVER_PASSWORD")) : .key(key),
                                                expect: nil)
        defer { session.close() }

        let staged = ServerScripts.stageInstaller(text)
        let put = try await session.run(staged.script)
        let path = put.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(put.code, 0, put.stderr)
        XCTAssertTrue(path.hasSuffix("/install.sh"), "got: \(path)")

        /*
         * The installer arrived **byte for byte**, checked by hash.
         *
         * A heredoc that expanded anything would have eaten the `$HOME`s and the
         * `$(uname -m)`s on the way and left a script that still runs and does
         * the wrong thing. Compared by digest rather than with `cmp - file`,
         * which was the first version and was quietly meaningless: `run` puts
         * its script on standard input, so a `-` inside it reads whatever is
         * left of the script rather than anything this side sent.
         */
        let digest = try await session.run("sha256sum \(ServerScripts.quote(path)) | cut -d' ' -f1")
        let here = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest.stdout.trimmingCharacters(in: .whitespacesAndNewlines), here,
                       "the installer on the server is not the installer this app carries")

        var plan = ""
        let ran = try await session.stream(
            command: "TERMINALDECK_DRYRUN=1 sh \(ServerScripts.quote(path))",
            stdin: nil,
            timeout: .seconds(60)
        ) { chunk in plan += chunk }
        XCTAssertEqual(ran.code, 0, ran.stderr)
        XCTAssertTrue(ran.stdout.contains("Dry run"), ran.stdout)
        XCTAssertTrue(ran.stdout.contains("this machine"), ran.stdout)
        // The streamed copy and the collected one are the same bytes in the same
        // order — the property `DispatchQueue.main.async` is there to keep.
        XCTAssertEqual(plan, ran.stdout)

        _ = try await session.run("rm -rf \(ServerScripts.quote((path as NSString).deletingLastPathComponent))")
    }

    /// The identity check, proved by breaking it: a stored fingerprint that does
    /// not match must stop the connection **before** a credential is offered.
    func testRefusesAServerWhoseKeyIsNotTheOneWeStored() async throws {
        let address = env("TD_SERVER_ADDRESS")
        try XCTSkipIf(address.isEmpty, "No TD_SERVER_ADDRESS: nothing real to sign in to.")
        let key = env("TD_SERVER_KEY")
        do {
            _ = try await SSHSession.open(address: address,
                                          port: Int(env("TD_SERVER_PORT")) ?? 22,
                                          username: env("TD_SERVER_USER"),
                                          auth: key.isEmpty
                                              ? .password(env("TD_SERVER_PASSWORD")) : .key(key),
                                          expect: "SHA256:thisIsNotTheKeyThatServerHas")
            XCTFail("a server with the wrong host key was accepted")
        } catch let problem as SSHProblem {
            guard case .identityChanged = problem else {
                return XCTFail("wrong refusal: \(problem)")
            }
        }
    }
}
