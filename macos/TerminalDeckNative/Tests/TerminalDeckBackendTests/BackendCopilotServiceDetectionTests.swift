import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendCopilotServiceDetectionCommands: BackendAppSessionCommandExecuting {
    struct Call: Sendable { let command: String; let arguments: [String]; let timeout: Int; let environment: [String: String] }
    var calls: [Call] = []
    let standalone: Bool
    let extensionPresent: Bool
    let authenticated: Bool
    init(standalone: Bool, extensionPresent: Bool = false, authenticated: Bool = false) {
        self.standalone = standalone; self.extensionPresent = extensionPresent; self.authenticated = authenticated
    }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        calls.append(.init(command: command, arguments: arguments, timeout: timeoutMilliseconds, environment: environment))
        if arguments == ["-c", "which copilot"] { return .init(stdout: standalone ? "/synthetic/copilot\n" : "", stderr: standalone ? "" : "copilot not found", exitCode: standalone ? 0 : 1) }
        if arguments == ["extension", "list"] { return .init(stdout: extensionPresent ? "gh copilot\tgithub/gh-copilot\tv1.1.1\n" : "", exitCode: 0) }
        if arguments == ["auth", "status"] { return .init(stdout: "must never be returned to the panel", exitCode: authenticated ? 0 : 1) }
        if arguments == ["--version"] { return .init(stdout: "1.2.3\n", exitCode: 0) }
        return .init(exitCode: 1)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { throw NativeRPCError(code: "unavailable", message: "Synthetic probe cannot detach.") }
    func snapshot() -> [Call] { calls }
}
final class BackendCopilotServiceDetectionTests: XCTestCase {
    func testExtensionAndSignInSignals() {
        XCTAssertTrue(BackendCopilotServiceDetector.hasExtension("gh copilot\tgithub/gh-copilot\tv1.1.1\n"))
        XCTAssertFalse(BackendCopilotServiceDetector.hasExtension(""))
        XCTAssertFalse(BackendCopilotServiceDetector.hasExtension("gh notes\tsomeone/gh-notes-for-copilot-users\tv0.1\n"))
        for variable in ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"] {
            XCTAssertTrue(BackendCopilotServiceDetector.signedIn(environment: [variable: "synthetic"], directoryEntries: [], ghAuthenticated: false))
        }
        XCTAssertFalse(BackendCopilotServiceDetector.signedIn(environment: ["GH_TOKEN": " \u{FEFF} "], directoryEntries: ["ide"], ghAuthenticated: false))
        XCTAssertTrue(BackendCopilotServiceDetector.signedIn(environment: [:], directoryEntries: ["ide", "config.json"], ghAuthenticated: false))
        XCTAssertTrue(BackendCopilotServiceDetector.signedIn(environment: [:], directoryEntries: [], ghAuthenticated: true))
        XCTAssertFalse(BackendCopilotServiceDetector.signedIn(environment: [:], directoryEntries: [], ghAuthenticated: false))
    }
    func testStandaloneUsesAlreadyResolvedPathSkipsExtensionAndTokenAvoidsAuthProbe() async {
        let commands = BackendCopilotServiceDetectionCommands(standalone: true)
        let detector = BackendCopilotServiceDetector(executor: commands, environment: ["GH_TOKEN": "synthetic", "SHELL": "/bin/zsh"], home: "/no-synthetic-home")
        let detection = await detector.detect(path: "/synthetic")
        XCTAssertEqual(detection.route, "cli"); XCTAssertEqual(detection.state, "ready"); XCTAssertEqual(detection.version, "1.2.3")
        let calls = await commands.snapshot()
        XCTAssertEqual(calls.map(\.arguments), [["-c", "which copilot"], ["--version"]])
        // tool-probe.ts:88-89 launchSpec: off Windows the version probe runs the bare name on the resolved PATH
        // (copilot.test.ts:98 asserts readVersion gets "copilot"), never the which-output path.
        XCTAssertEqual(calls.last?.command, "copilot")
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 5000 && $0.environment["PATH"] == "/synthetic" })
        let row = BackendCopilotServiceDetector.toolStatus(detection)
        XCTAssertEqual(row["required"].bool, false); XCTAssertEqual(row["label"].string, "GitHub Copilot")
    }
    func testMissingAndExtensionRemediesNeverClaimUnseenAuthentication() async {
        let missing = await BackendCopilotServiceDetector(executor: BackendCopilotServiceDetectionCommands(standalone: false), environment: ["SHELL": "/bin/zsh"], home: "/no-synthetic-home").detect(path: "/synthetic")
        XCTAssertEqual(missing.state, "missing"); XCTAssertNil(missing.route); XCTAssertEqual(missing.remedy, "Install the GitHub Copilot CLI, then check again.")
        let commands = BackendCopilotServiceDetectionCommands(standalone: false, extensionPresent: true)
        let installed = await BackendCopilotServiceDetector(executor: commands, environment: ["SHELL": "/bin/zsh"], home: "/no-synthetic-home").detect(path: "/synthetic")
        XCTAssertEqual(installed.state, "installed-not-authed"); XCTAssertEqual(installed.route, "gh-extension"); XCTAssertNil(installed.version)
        XCTAssertEqual(installed.remedy, "Installed as a `gh` extension, but `gh` is not signed in. Run `gh auth login`.")
        XCTAssertFalse(installed.wireValue.compact.contains("must never be returned"))
        let row = BackendCopilotServiceDetector.toolStatus(installed)
        XCTAssertEqual(row["required"].bool, false); XCTAssertEqual(row["url"].string, "https://github.com/github/copilot-cli")
    }
}
