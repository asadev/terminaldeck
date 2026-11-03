import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// CONNECT-SKILLS (11 Oct): one-click install of Claude Code, Codex and Gemini CLI. No process runs here except
/// the small version-probe scripts the resolver test writes into its own scratch home.
final class AIToolInstallTests: XCTestCase {
    private final class FakeRunner: BackendAIToolInstallRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(argv: [String], env: [String: String])] = []
        let answer: @Sendable ([String]) -> (ok: Bool, output: String)
        init(_ answer: @escaping @Sendable ([String]) -> (ok: Bool, output: String) = { _ in (true, "") }) { self.answer = answer }
        func run(_ argv: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int,
                 line: @escaping @Sendable (String) -> Void) async -> (ok: Bool, output: String) {
            lock.withLock { calls.append((argv, environment)) }
            line("working")
            return answer(argv)
        }
        var recorded: [(argv: [String], env: [String: String])] { lock.withLock { calls } }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false; private var events: [NativeRPCValue] = []
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
        func add(_ event: NativeRPCValue) { lock.withLock { events.append(event) } }
        var states: [String] { lock.withLock { events.compactMap { $0["state"].string } } }
    }
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-tool-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func installer(_ runner: FakeRunner, root: URL, installedAfter flag: Flag, brew: String? = nil, npm: String? = nil,
                           alreadyThere: Bool = false, events: Flag? = nil) -> BackendAIToolInstaller {
        BackendAIToolInstaller(dependencies: .init(runner: runner, loginPath: { "/usr/bin:/bin" }, lookup: { command, _ in
            if command == "brew" || command == "/opt/homebrew/bin/brew" { return brew }
            if command == "npm" { return npm }
            return nil
        }, installed: { _, _ in (alreadyThere || flag.isSet) ? ("/Users/x/.local/bin/tool", "1.2.3 (Tool)") : (nil, nil) },
           resetCaches: {}, publish: { events?.add($0) }, scratch: root.appendingPathComponent("scratch"), home: root.path,
           environment: ["PATH": "/usr/bin", "SUDO_ASKPASS": "/x/askpass", "CLAUDE_CONFIG_DIR": "/x/other-account"]))
    }

    // MARK: Routes

    func testEachAIUsesItsOfficialRouteAndNeverAdmin() {
        guard case .attempts(let claude) = BackendAIToolInstallPlan.plan("claude", brew: "/opt/homebrew/bin/brew", npm: "/usr/local/bin/npm") else { return XCTFail() }
        // Claude Code: Anthropic's native installer only (needs no Node.js), even when npm is there.
        XCTAssertEqual(claude.map(\.kind), [.script])
        XCTAssertEqual(claude.first?.scriptURL, "https://claude.ai/install.sh")
        XCTAssertEqual(claude.first?.shell, "/bin/bash")
        guard case .attempts(let codex) = BackendAIToolInstallPlan.plan("codex", brew: "/opt/homebrew/bin/brew", npm: "/usr/local/bin/npm") else { return XCTFail() }
        XCTAssertEqual(codex.map(\.kind), [.script, .homebrew, .npm])
        XCTAssertEqual(codex[0].scriptURL, "https://chatgpt.com/codex/install.sh")
        XCTAssertEqual(codex[0].environment["CODEX_NON_INTERACTIVE"], "1")
        XCTAssertEqual(codex[1].argv, ["/opt/homebrew/bin/brew", "install", "--cask", "codex"])
        XCTAssertEqual(codex[2].argv, ["/usr/local/bin/npm", "install", "-g", "@openai/codex"])
        guard case .attempts(let codexBare) = BackendAIToolInstallPlan.plan("codex", brew: nil, npm: nil) else { return XCTFail() }
        XCTAssertEqual(codexBare.map(\.kind), [.script], "a stock Mac still installs Codex")
        guard case .attempts(let gemini) = BackendAIToolInstallPlan.plan("gemini", brew: "/opt/homebrew/bin/brew", npm: "/usr/local/bin/npm") else { return XCTFail() }
        XCTAssertEqual(gemini.map(\.argv), [["/opt/homebrew/bin/brew", "install", "gemini-cli"], ["/usr/local/bin/npm", "install", "-g", "@google/gemini-cli"]])
        guard case .needs(let message, let help) = BackendAIToolInstallPlan.plan("gemini", brew: nil, npm: nil) else { return XCTFail("a stock Mac has no Gemini route") }
        XCTAssertTrue(message.contains("Node.js")); XCTAssertEqual(help, "https://nodejs.org/en/download")
        for attempt in claude + codex + gemini {
            XCTAssertFalse(attempt.argv.contains { $0 == "sudo" || $0.hasSuffix("/sudo") }, "never admin rights")
        }
        let env = BackendAIToolInstallPlan.environment(inherited: ["SUDO_ASKPASS": "/a", "SSH_ASKPASS": "/b", "CODEX_HOME": "/c", "CLAUDE_CONFIG_DIR": "/d", "PATH": "/opt/x"],
                                                      path: "/opt/homebrew/bin", home: "/Users/someone", extra: ["CI": "1"])
        XCTAssertNil(env["SUDO_ASKPASS"]); XCTAssertNil(env["SSH_ASKPASS"]); XCTAssertNil(env["CODEX_HOME"]); XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], "/Users/someone"); XCTAssertEqual(env["NONINTERACTIVE"], "1"); XCTAssertEqual(env["CI"], "1")
    }

    // MARK: The install

    func testInstallRunsTheOfficialInstallerThenChecksItStarts() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag(), events = Flag()
        let runner = FakeRunner { argv in
            if argv.first == "/bin/bash" { flag.set() }   // the installer ran: the AI is there now
            return (true, "")
        }
        let status = try await installer(runner, root: root, installedAfter: flag, events: events).install("claude")
        XCTAssertEqual(status.state, "installed"); XCTAssertEqual(status.version, "1.2.3 (Tool)")
        XCTAssertTrue(status.message.contains("Next: sign in"))
        let calls = runner.recorded
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Array(calls[0].argv.prefix(1)), ["/usr/bin/curl"]); XCTAssertEqual(calls[0].argv.last, "https://claude.ai/install.sh")
        XCTAssertEqual(calls[1].argv.first, "/bin/bash")
        let script = try XCTUnwrap(calls[1].argv.last)
        XCTAssertTrue(script.hasPrefix(root.appendingPathComponent("scratch").path), "downloaded inside the app's own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: script), "the downloaded installer is removed afterwards")
        XCTAssertNil(calls[1].env["SUDO_ASKPASS"]); XCTAssertNil(calls[1].env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(events.states.first, "running"); XCTAssertEqual(events.states.last, "installed")
    }

    func testCodexFallsBackToHomebrewWhenItsInstallerFails() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let flag = Flag()
        let runner = FakeRunner { argv in
            if argv.first == "/bin/sh" { return (false, "curl: (6) Could not resolve host: releases.openai.com") }
            if argv.contains("--cask") { flag.set() }
            return (true, "")
        }
        let status = try await installer(runner, root: root, installedAfter: flag, brew: "/opt/homebrew/bin/brew").install("codex")
        XCTAssertEqual(status.state, "installed"); XCTAssertEqual(status.route, "Homebrew")
        XCTAssertEqual(runner.recorded.last?.argv, ["/opt/homebrew/bin/brew", "install", "--cask", "codex"])
        XCTAssertEqual(runner.recorded.last?.env["HOMEBREW_NO_AUTO_UPDATE"], "1")
    }

    func testGeminiOnAStockMacSaysWhatItNeedsAndRunsNothing() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        let status = try await installer(runner, root: root, installedAfter: Flag()).install("gemini")
        XCTAssertEqual(status.state, "needs"); XCTAssertEqual(status.helpURL, "https://nodejs.org/en/download")
        XCTAssertTrue(runner.recorded.isEmpty)
    }

    func testAlreadyInstalledRunsNothingAndUnknownToolsAreRefused() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(), service = installer(runner, root: root, installedAfter: Flag(), alreadyThere: true)
        let status = try await service.install("codex")
        XCTAssertEqual(status.state, "installed"); XCTAssertTrue(status.message.contains("already installed"))
        XCTAssertTrue(runner.recorded.isEmpty)
        do { _ = try await service.install("rm -rf /"); XCTFail("only the three AIs install") } catch {}
    }

    func testAFailureIsSaidPlainlyAndAdminIsNeverAskedFor() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner { argv in argv.first == "/usr/bin/curl" ? (true, "") : (false, "npm ERR! code EACCES\nnpm ERR! syscall mkdir") }
        let status = try await installer(runner, root: root, installedAfter: Flag()).install("claude")
        XCTAssertEqual(status.state, "failed")
        XCTAssertTrue(status.message.contains("never uses admin rights"), status.message)
        XCTAssertEqual(status.helpURL, "https://code.claude.com/docs/en/setup")
        XCTAssertTrue(BackendAIToolInstaller.reason("curl: (6) Could not resolve host: claude.ai", route: "the official installer").contains("internet"))
    }

    // MARK: What a stranger is told

    func testMissingAIIsOfferedInstallNotATerminalCommand() {
        let missing = BackendNativeProviders.Binary(id: "claude", onPath: nil, runnable: nil, version: nil, broken: false, said: nil, usedAlternate: false, checkedAt: Date())
        let line = BackendAppAccountSignInService.binaryProblem(missing)
        XCTAssertFalse(line.contains("npm"), line); XCTAssertTrue(line.contains("Press Install"), line)
        XCTAssertEqual(BackendAIToolInstallText.missingTool(in: line), "claude")
        let broken = BackendNativeProviders.Binary(id: "gemini", onPath: "/usr/local/bin/gemini", runnable: nil, version: nil, broken: true, said: nil, usedAlternate: false, checkedAt: Date())
        XCTAssertEqual(BackendAIToolInstallText.missingTool(in: BackendAppAccountSignInService.binaryProblem(broken)), "gemini")
        XCTAssertFalse(BackendCommunityProjection.agentLine(missing).contains("npm install"))
        XCTAssertNil(BackendAIToolInstallText.missingTool(in: "The sign-in could not be started."))
    }

    // MARK: The real thing, in a throwaway home (opt-in: TD_REAL_AI_INSTALL=claude|codex, downloads the real AI)

    func testRealOfficialInstallIntoAThrowawayHome() async throws {
        guard let tool = ProcessInfo.processInfo.environment["TD_REAL_AI_INSTALL"], BackendAIToolInstallPlan.tools.contains(tool) else {
            throw XCTSkip("Set TD_REAL_AI_INSTALL=claude or codex to install the real AI into a scratch home.")
        }
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let system = "/usr/bin:/bin:/usr/sbin:/sbin"   // a stock Mac: no Homebrew, no Node.js, nothing of this Mac's own
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: home, inheritedEnvironment: ["PATH": system],
                                                   home: home.path, runner: BackendCommandRunner(),
                                                   loginPath: { BackendNativeProviders.withOfficialInstallFolder(system, home: home.path) })
        let events = Flag()
        let service = BackendAIToolInstaller(dependencies: .init(loginPath: { try await providers.loginPath() }, installed: { id, refresh in
            let binary = await providers.resolveBinary(id, path: (try? await providers.loginPath()) ?? system, refresh: refresh)
            return (binary.runnable, binary.version)
        }, resetCaches: { await providers.resetCaches() }, publish: { events.add($0) },
           scratch: home.appendingPathComponent("app-data/ai-tool-install"), home: home.path, environment: ["PATH": system]))
        let status = try await service.install(tool)
        XCTAssertEqual(status.state, "installed", status.message)
        XCTAssertTrue(status.version?.isEmpty == false)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: home.appendingPathComponent(".local/bin/" + tool).path))
        print("REAL INSTALL \(tool): \(status.message) route=\(status.route ?? "-") states=\(events.states)")
    }

    // MARK: Found where the official installers put it

    func testTheOfficialInstallFolderIsAlwaysLookedIn() async throws {
        XCTAssertEqual(BackendNativeProviders.withOfficialInstallFolder("/usr/bin:/bin", home: "/Users/a"), "/usr/bin:/bin:/Users/a/.local/bin")
        XCTAssertEqual(BackendNativeProviders.withOfficialInstallFolder("/Users/a/.local/bin:/usr/bin", home: "/Users/a"), "/Users/a/.local/bin:/usr/bin")
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent(".local/bin"), other = root.appendingPathComponent("other-bin")
        try FileManager.default.createDirectory(at: official, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        func script(_ url: URL, _ body: String) throws {
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script(official.appendingPathComponent("claude"), "echo '9.9.9 (Claude Code)'")
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root, inheritedEnvironment: [:], home: root.path, runner: BackendCommandRunner())
        // Not on the PATH at all: found in ~/.local/bin (Claude's installer does not add it to PATH).
        let plain = await providers.resolveBinary("claude", path: "/usr/bin:/bin", refresh: true)
        XCTAssertEqual(plain.runnable, official.appendingPathComponent("claude").path)
        XCTAssertEqual(plain.version, "9.9.9 (Claude Code)"); XCTAssertFalse(plain.usedAlternate)
        // A broken copy earlier on the PATH no longer hides the fresh one.
        try script(other.appendingPathComponent("claude"), "exit 3")
        let shadowed = await providers.resolveBinary("claude", path: other.path + ":/usr/bin:/bin", refresh: true)
        XCTAssertEqual(shadowed.onPath, other.appendingPathComponent("claude").path)
        XCTAssertEqual(shadowed.runnable, official.appendingPathComponent("claude").path); XCTAssertTrue(shadowed.usedAlternate)
    }
}
