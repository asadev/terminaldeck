import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ENVFIX19Tests: XCTestCase, @unchecked Sendable {
    private var launcher: [String: String] {
        var env = Dictionary(uniqueKeysWithValues: BackendSessionEnvironment.loginShellSettings.map { ($0, "launcher") })
        for key in ["CI", "CODEX_CI", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_VERSION", "CODEX_HOME", "CODEX_FUTURE_SETTING"] { env[key] = "launcher" }
        env["HOME"] = "/tmp"; env["SHELL"] = "/bin/zsh"; env["PATH"] = "/usr/bin:/bin"
        return env
    }
    private func spawn() -> BackendSpawnSpec {
        .init(provider: "shell", command: "/bin/zsh", args: ["-l"], path: "/usr/bin:/bin", env: launcher)
    }
    private func assertClean(_ env: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        for key in launcher.keys where key.hasPrefix("CODEX_") || key == "CI" || BackendSessionEnvironment.loginShellSettings.contains(key) && key != "TERM" {
            XCTAssertNil(env[key], file: file, line: line)
        }
        XCTAssertEqual(env["TERM"], "xterm-256color", file: file, line: line)
        XCTAssertEqual(env["COLORTERM"], "truecolor", file: file, line: line)
        XCTAssertEqual(env["HOME"], "/tmp", file: file, line: line)
    }
    func testAppSessionScrubsLauncherAndCopiedAccountEnvironment() throws {
        assertClean(try BackendSessionEnvironment.forSession(id: "envfix", inherited: launcher, spawn: spawn()))
    }
    func testManagedHostLaunchScrubsLauncherEnvironment() throws {
        let launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(),
            input: .init(cwd: "/tmp", provider: "shell"), spawn: spawn(), inheritedEnvironment: launcher)
        let decoded = try JSONDecoder().decode(BackendHOSTProtocol.Launch.self, from: JSONEncoder().encode(launch))
        assertClean(decoded.environment)
    }
    func testLoginShellSettingsKeptButTermAndCodexRemainAppOwned() throws {
        var spec = spawn()
        spec.loginShellEnvironment = ["NO_COLOR": "", "PAGER": "less -R", "FORCE_COLOR": "2", "CLICOLOR": "1",
            "CLICOLOR_FORCE": "1", "GIT_PAGER": "less", "GH_PAGER": "less", "TERM": "dumb", "CODEX_CI": "1", "CI": "1"]
        let env = try BackendSessionEnvironment.forSession(id: "envfix", inherited: launcher, spawn: spec)
        for key in BackendSessionEnvironment.loginShellSettings where key != "TERM" { XCTAssertEqual(env[key], spec.loginShellEnvironment[key]) }
        XCTAssertEqual(env["TERM"], "xterm-256color"); XCTAssertNil(env["CODEX_CI"]); XCTAssertNil(env["CI"])
        spec.removeEnv = ["NO_COLOR"]
        XCTAssertNil(try BackendSessionEnvironment.forSession(id: "envfix", inherited: launcher, spawn: spec)["NO_COLOR"])
    }
    func testRealScratchLoginShellReadsZshrcWithoutLauncherPollution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-test-envfix19-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var base = launcher; base["HOME"] = root.path; base["ZDOTDIR"] = root.path
        try Data("export NO_COLOR=personal\nexport PAGER='less -R'\nunset FORCE_COLOR CLICOLOR CLICOLOR_FORCE GIT_PAGER GH_PAGER\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root,
            inheritedEnvironment: base, home: root.path, runner: BackendCommandRunner())
        let settings = await providers.loginSessionEnvironment()
        XCTAssertEqual(settings["NO_COLOR"], "personal"); XCTAssertEqual(settings["PAGER"], "less -R")
        XCTAssertNil(settings["FORCE_COLOR"]); XCTAssertNil(settings["GH_PAGER"])
        var child = spawn(); child.loginShellEnvironment = settings
        let env = try BackendSessionEnvironment.forSession(id: "envfix", inherited: base, spawn: child)
        XCTAssertEqual(env["NO_COLOR"], "personal"); XCTAssertEqual(env["TERM"], "xterm-256color")
        try Data("unset NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE PAGER GIT_PAGER GH_PAGER\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let cached = await providers.loginSessionEnvironment()
        XCTAssertEqual(cached["NO_COLOR"], "personal")
        await providers.resetCaches()
        let cleared = await providers.loginSessionEnvironment()
        XCTAssertNil(cleared["NO_COLOR"]); XCTAssertNil(cleared["PAGER"])
    }
    func testFailedLoginProbeNeverRestoresLauncherSettings() async throws {
        var base = launcher; base["SHELL"] = "/usr/bin/false"
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: URL(fileURLWithPath: "/tmp"),
            inheritedEnvironment: base, home: "/tmp", runner: BackendCommandRunner())
        var child = spawn(); child.loginShellEnvironment = await providers.loginSessionEnvironment()
        assertClean(try BackendSessionEnvironment.forSession(id: "envfix", inherited: base, spawn: child))
    }
    func testProbeParserPreservesEmptyValuesAndIgnoresGreeting() {
        let settings = BackendNativeProviders.parseLoginSessionEnvironment("hello\n\0NO_COLOR\0\0PAGER\0less -R\0")
        XCTAssertEqual(settings, ["NO_COLOR": "", "PAGER": "less -R"])
        XCTAssertEqual(BackendNativeProviders.parseLoginSessionEnvironment("hello"), [:])
        XCTAssertEqual(BackendNativeProviders.parseLoginSessionEnvironment("\0OTHER\0ignored\0"), [:])
    }
    func testBackgroundToolsStillRequestNoColor() {
        let github = BackendGitHubAuthenticator.toolEnvironment(launcher)
        XCTAssertEqual(github["NO_COLOR"], "1"); XCTAssertEqual(github["GH_PAGER"], "cat"); XCTAssertEqual(github["CLICOLOR"], "0")
        XCTAssertEqual(github["CODEX_THREAD_ID"], "launcher")
        let stays = BackendStaysFixedEngineFiles.environment(base: launcher, path: "/usr/bin:/bin", shim: nil, keep: nil)
        XCTAssertEqual(stays["NO_COLOR"], "1")
        let install = BackendAIToolInstallPlan.environment(inherited: launcher, path: "/usr/bin:/bin", home: "/tmp", extra: [:])
        XCTAssertEqual(install["NO_COLOR"], "1"); XCTAssertEqual(install["TERM"], "dumb")
        XCTAssertEqual(BackendSessionEnvironment.stripInherited(launcher)["NO_COLOR"], "launcher")
    }
}
