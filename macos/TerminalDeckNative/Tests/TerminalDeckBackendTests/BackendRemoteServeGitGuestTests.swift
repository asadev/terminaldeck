import XCTest
import Foundation
@testable import TerminalDeckBackend

final class BackendRemoteServeGitGuestTests: XCTestCase {
    func testHelperClearComesBeforeDeviceHelperAndRepositoryNamesTravel() {
        let request = BackendRemoteServeGitGuest.Request(directory: URL(fileURLWithPath: "/tmp/guest"), link: .init(url: "http://127.0.0.1:1/credential", key: "secret", helper: "/tmp/it's here/askpass.sh"))
        let entries = BackendRemoteServeGitGuest.entries(request)
        XCTAssertEqual(entries[0].0, "credential.helper"); XCTAssertEqual(entries[0].1, "")
        XCTAssertEqual(entries[1].0, "credential.helper"); XCTAssertEqual(entries[1].1, "!'/tmp/it'\\''s here/askpass.sh'")
        XCTAssertTrue(entries.contains { $0 == ("credential.useHttpPath", "true") })
        XCTAssertEqual(entries.filter { $0.0.hasSuffix(".insteadOf") }.map(\.1), ["git@github.com:", "ssh://git@github.com/"])
        XCTAssertTrue(entries.contains { $0.0 == "core.sshCommand" && $0.1.contains("IdentityAgent=none") && $0.1.contains("IdentitiesOnly=yes") && $0.1.contains("IdentityFile=/dev/null") })
    }
    func testNoProxyStillIsolatesEveryCredentialPath() {
        let plan = BackendRemoteServeGitGuest.environment(.init(directory: URL(fileURLWithPath: "/tmp/device")))
        for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK", "GIT_ASKPASS", "SSH_ASKPASS", "GIT_CONFIG", "GIT_SSH", "GIT_SSH_COMMAND"] { XCTAssertTrue(plan.remove.contains(name)); XCTAssertNil(plan.set[name]) }
        XCTAssertEqual(plan.set["GIT_TERMINAL_PROMPT"], "0"); XCTAssertEqual(plan.set["GH_CONFIG_DIR"], "/tmp/device/gh")
        XCTAssertEqual(plan.set["GIT_CONFIG_GLOBAL"], "/tmp/device/gitconfig"); XCTAssertEqual(plan.set["GIT_CONFIG_VALUE_0"], "")
        let env = plan.applying(to: ["GH_TOKEN": "owner", "SSH_AUTH_SOCK": "/owner/agent", "KEEP": "yes"])
        XCTAssertNil(env["GH_TOKEN"]); XCTAssertNil(env["SSH_AUTH_SOCK"]); XCTAssertEqual(env["KEEP"], "yes")
    }
    func testSecretStaysInEnvironmentAndNeverConflictsWithRemovals() {
        let request = BackendRemoteServeGitGuest.Request(directory: URL(fileURLWithPath: "/tmp/device"), link: .init(url: "http://127.0.0.1:1/credential", key: "device-secret", helper: "/tmp/helper"))
        let env = BackendRemoteServeGitGuest.environment(request)
        XCTAssertEqual(env.set[BackendRemoteServeGitGuest.credentialKeyVariable], "device-secret")
        XCTAssertFalse(BackendRemoteServeGitGuest.askpassScript().contains("device-secret"))
        for name in env.remove { XCTAssertNil(env.set[name]) }
        for name in env.paths { XCTAssertNotNil(env.set[name]) }
    }
    func testGuestOwnsConfigButGeneratedHelperIsRefreshed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-git-guest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("askpass.sh"), request = BackendRemoteServeGitGuest.Request(directory: root.appendingPathComponent("device"), link: .init(url: "http://127.0.0.1:1/credential", key: "never-on-disk", helper: helper.path))
        _ = try BackendRemoteServeGitGuest.prepare(request)
        let config = request.directory.appendingPathComponent("gitconfig")
        try Data("[user]\n\temail = guest@example.com\n".utf8).write(to: config)
        try Data("old helper".utf8).write(to: helper)
        _ = try BackendRemoteServeGitGuest.prepare(request)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "[user]\n\temail = guest@example.com\n")
        XCTAssertEqual(try String(contentsOf: helper, encoding: .utf8), BackendRemoteServeGitGuest.askpassScript())
        XCTAssertFalse(try String(contentsOf: helper, encoding: .utf8).contains("never-on-disk"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    /// This test is WRITTEN ONLY during the migration. The final integration
    /// worker can run it as positive evidence about real Git precedence.
    func testActualGitCannotUseGlobalSystemOrRepositoryOwnerHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-git-precedence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("owner.ran"), helper = root.appendingPathComponent("owner.sh")
        let text = "#!/bin/sh\ncat >/dev/null\nprintf 'ran\\n' >> \(BackendRemoteServeGitGuest.shellPath(marker.path))\nprintf 'username=owner\\npassword=owner-secret\\n'\n"
        try Data(text.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let global = root.appendingPathComponent("owner-global"), system = root.appendingPathComponent("owner-system")
        let config = "[credential]\n\thelper = !\(BackendRemoteServeGitGuest.shellPath(helper.path))\n"
        try Data(config.utf8).write(to: global); try Data(config.utf8).write(to: system)
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = global.path; env["GIT_CONFIG_SYSTEM"] = system.path; env["GIT_TERMINAL_PROMPT"] = "0"
        let before = try git(["credential", "fill"], cwd: root, env: env, input: "protocol=https\nhost=github.com\npath=owner/repo.git\n\n")
        XCTAssertTrue(before.contains("owner-secret")); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        _ = try git(["init", "-q"], cwd: root, env: env)
        _ = try git(["config", "credential.helper", "!" + BackendRemoteServeGitGuest.shellPath(helper.path)], cwd: root, env: env)
        let guest = try BackendRemoteServeGitGuest.prepare(.init(directory: root.appendingPathComponent("device")))
        let after = try git(["credential", "fill"], cwd: root, env: guest.applying(to: env), input: "protocol=https\nhost=github.com\npath=owner/repo.git\n\n")
        XCTAssertFalse(after.contains("owner-secret")); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    private func git(_ args: [String], cwd: URL, env: [String: String], input: String = "") throws -> String {
        let child = Process(), stdout = Pipe(), stdin = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git"); child.arguments = args; child.environment = env; child.currentDirectoryURL = cwd
        child.standardOutput = stdout; child.standardError = FileHandle.nullDevice; child.standardInput = stdin
        try child.run(); try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
