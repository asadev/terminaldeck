import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendServersSetupTests: XCTestCase, @unchecked Sendable {
    func testSharedSigninUsesExitStatusAndOnlyPublicEmailClaim() {
        let codex = BackendServersAgentSignin.signInSnippet(.codex, binary: "b", state: "i", account: "e", codexHome: "CXH", geminiEnv: "GENV")
        XCTAssertTrue(codex.contains(#"login status >/dev/null 2>&1; then i=yes; else i=no; fi"#))
        XCTAssertTrue(codex.contains(#"CODEX_HOME="${CXH:-$HOME/.codex}""#))
        XCTAssertTrue(codex.contains("cut -d. -f2")); XCTAssertTrue(codex.contains("${#tdt} % 4"))
        for decoder in ["base64 -d", "base64 -D", "openssl base64 -d -A"] { XCTAssertTrue(codex.contains(decoder)) }
        XCTAssertFalse(codex.contains("access_token")); XCTAssertFalse(codex.contains("refresh_token"))
        XCTAssertFalse(codex.contains("Not logged in"))
    }
    func testGeminiReadsItsOwnAuthRuleWithoutSpendingAQuota() {
        let gemini = BackendServersAgentSignin.signInSnippet(.gemini, binary: "b", state: "i", account: "e", codexHome: "CXH", geminiEnv: "GENV")
        for field in ["selectedType", "selectedAuthType", "google_accounts.json", "active", "tdg=$GENV"] { XCTAssertTrue(gemini.contains(field)) }
        for key in ["GEMINI_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA", "CODEX_HOME"] { XCTAssertTrue(BackendServersAgentSignin.agentEnvProbe.contains(key)) }
        for id in BackendServersSetupRules.setupAgents {
            XCTAssertFalse(BackendServersAgentSignin.signInSnippet(id, binary: "b", state: "i", account: "e", codexHome: "C", geminiEnv: "G").contains("-p "))
            let script = BackendServersSetupRules.findScript(id)
            XCTAssertTrue(script.contains(BackendServersAgentSignin.agentVersionAWK)); XCTAssertTrue(script.contains("TDENV"))
        }
    }
    func testInstallRefusesBeforeDownloadAndKeepsEachRowsDiskLimit() {
        let room = BackendServersAgentInstallRoom(downloader: "curl", npm: "/usr/bin/npm", memoryAvailableKb: 1_024 * 1_024, homeFreeKb: 1_024 * 1_024)
        XCTAssertNil(BackendServersSetupRules.whyNotInstall(.claude, room: room))
        var low = room; low.memoryAvailableKb = 256 * 1024
        XCTAssertTrue(BackendServersSetupRules.whyNotInstall(.claude, room: low)?.contains("256 MB") == true)
        for (id, needed) in [(BackendServersAgentID.claude, 350), (.codex, 330), (.gemini, 130)] {
            low = room; low.homeFreeKb = 30 * 1024
            XCTAssertTrue(BackendServersSetupRules.whyNotInstall(id, room: low)?.contains("about \(needed) MB") == true)
        }
        low = room; low.npm = ""
        XCTAssertNil(BackendServersSetupRules.installCommand(.codex, room: low))
        low = room; low.downloader = "wget"
        XCTAssertEqual(BackendServersSetupRules.installCommand(.claude, room: low), "wget -qO- https://claude.ai/install.sh | bash")
        for id in [BackendServersAgentID.codex, .gemini] {
            XCTAssertTrue(BackendServersSetupRules.installCommand(id, room: room)?.contains(#"--prefix "$HOME/.local""#) == true)
        }
    }
    func testOnlyAnExplicitLoopbackRedirectPortCanBeForwarded() {
        XCTAssertEqual(BackendServersSetupRules.authPortOf("https://example.invalid/auth?redirect_uri=http%3A%2F%2Flocalhost%3A48484%2Fcallback"), 48484)
        for target in ["https://remote.invalid:48484/callback", "http://localhost/callback", "http://localhost:0/callback", "http://localhost:65536/callback", "not-a-url"] {
            XCTAssertNil(BackendServersSetupRules.authPortOf("https://example.invalid/auth?redirect_uri=" + target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        }
        XCTAssertNil(BackendServersSetupRules.authPortOf("https://platform.claude.com/oauth/code"))
    }
    func testOneTimeCodeRequiresAnAnchorAndReadsPastPaintAndEarlierTokens() {
        XCTAssertNil(BackendServersSetupRules.oneTimeCodeIn("519G-KS0UC", deviceURL: nil))
        XCTAssertNil(BackendServersSetupRules.oneTimeCodeIn("one-time code\n/path-with-hyphen", deviceURL: nil))
        XCTAssertEqual(BackendServersSetupRules.oneTimeCodeIn("AAA-BBB\nEnter this one-time code (expires in 15 minutes)\n  \u{1b}[94m519G-KS0UC\u{1b}[0m\r\n", deviceURL: nil), "519G-KS0UC")
        XCTAssertEqual(BackendServersSetupRules.oneTimeCodeIn("https://auth.openai.com/codex/device\n519G-KS0UC", deviceURL: BackendServersSetupRules.deviceURL(.codex)), "519G-KS0UC")
    }
    func testRemovalNeverDeletesThePersonsAgentSettingsOrSystemCopy() {
        for id in BackendServersSetupRules.setupAgents {
            let script = BackendServersSetupRules.removeScript("/home/a b/.local/bin/" + id.rawValue, id: id)
            XCTAssertTrue(script.contains(#"case "$p" in "$HOME"/*)"#)); XCTAssertTrue(script.contains("not ours to remove"))
            for forbidden in [#"rm -rf "$HOME/.claude""#, #"rm -rf "$HOME/.codex""#, #"rm -rf "$HOME/.gemini""#] { XCTAssertFalse(script.contains(forbidden)) }
        }
    }
    func testGeminiFlowAndCancelPushIdleWithoutInventingALoginCommand() async {
        let shell = BackendServersSetupTestShell()
        let setups = BackendServersSetups(.init(runScript: { _, _ in .init(code: 0, stdout: "") }))
        let state = await setups.signIn("s", agentId: .gemini, shell: shell, binary: "/home/s/.local/bin/gemini")
        XCTAssertTrue(state.byHand); XCTAssertEqual(state.step, .signingIn)
        XCTAssertEqual(shell.writes, ["/home/s/.local/bin/gemini\n"])
        await setups.cancel("s")
        let after = await setups.stateOf("s", agentId: .gemini)
        XCTAssertEqual(after.step, .idle); XCTAssertFalse(after.byHand)
    }
    func testSigninFallbackCleansScratchButLeavesItsPromptRunning() async {
        let recording = BackendServersSetupTestLog()
        let shell = BackendServersSetupTestShell()
        let setups = BackendServersSetups(.init(runScript: { _, script in
            recording.add(script)
            if script.contains("mktemp -d") { return .init(code: 0, stdout: "/tmp/td-signin-abcdef") }
            return .init(code: 1, stdout: "")
        }))
        let state = await setups.signIn("s", agentId: .claude, shell: shell, binary: "/home/s/.local/bin/claude")
        XCTAssertTrue(state.byHand); XCTAssertTrue(shell.writes.first?.contains("auth login --claudeai") == true)
        XCTAssertFalse(shell.writes.contains("\u{03}"))
        XCTAssertTrue(recording.values.contains { $0 == "rm -rf '/tmp/td-signin-abcdef'" })
    }
    func testSignoutBelievesServerOverExitStatusAndGeminiTypesNothing() async {
        let shell = BackendServersSetupTestShell { data, shell in if data.contains("__terminaldeck_setup") { shell.emit("__terminaldeck_setup 1\n") } }
        let setups = BackendServersSetups(.init(runScript: { _, _ in .init(code: 0, stdout: "/home/s/codex\t0.149.0\tno\t\n") }))
        let state = await setups.signOut("s", agentId: .codex, shell: shell, binary: "/home/s/codex")
        XCTAssertEqual(state.step, .idle); XCTAssertTrue(state.line.contains("signed out"))
        let before = shell.writes.count
        let unsupported = await setups.signOut("s", agentId: .gemini, shell: shell, binary: "/home/s/gemini")
        XCTAssertEqual(unsupported.step, .failed); XCTAssertEqual(shell.writes.count, before)
    }
    func testTapeKeepsEarlyOutputAndReadsSplitSentinel() async {
        let shell = BackendServersSetupTestShell(), tape = BackendServersSetupTape(BackendServersSetupTestShell())
        tape.close()
        let closed = await tape.next("unused", milliseconds: 1)
        XCTAssertNil(closed)
        let live = BackendServersSetupTape(shell)
        shell.emit("Pairing code 123456\nFinger"); shell.emit("print ABCD-EFGH\n")
        let code = await live.next(BackendServersHostRules.codePattern, milliseconds: 1)
        let fingerprint = await live.next(BackendServersHostRules.fingerprintPattern, milliseconds: 1)
        XCTAssertEqual(code, "123456"); XCTAssertEqual(fingerprint, "ABCD-EFGH")
        live.forget(); shell.emit("Pairing code 654321\n")
        let fresh = await live.next(BackendServersHostRules.codePattern, milliseconds: 1)
        XCTAssertEqual(fresh, "654321"); live.close()
    }
    func testInstallGoesStraightToTheChosenAgentsSigninWithReceipt() async {
        let shell = BackendServersSetupTestShell { data, shell in if data.contains("__terminaldeck_setup") { shell.emit("__terminaldeck_setup 0\n") } }
        let log = BackendServersSetupTestLog()
        let setups = BackendServersSetups(.init(runScript: { _, _ in .init(code: 0, stdout: "/home/s/.local/bin/gemini\t0.56.0\tno\t\n") }, broadcast: { log.add($0.step.rawValue) }))
        let state = await setups.install("s", agentId: .gemini, shell: shell, room: .init(downloader: "curl", npm: "/npm"), serverName: "server")
        XCTAssertEqual(log.values, ["installing", "installed", "signing-in"])
        XCTAssertTrue(state.weInstalled); XCTAssertTrue(state.byHand)
        XCTAssertTrue(shell.writes.contains { $0.contains("@google/gemini-cli") })
        XCTAssertEqual(shell.writes.last, "/home/s/.local/bin/gemini\n")
    }
    func testCancellationStopsVisibleCommandAndClosesFutureWaitsImmediately() async {
        let shell = BackendServersSetupTestShell(), tape = BackendServersSetupTape(BackendServersSetupTestShell())
        let attempt = BackendServersSetupAttempt(serverId: "s")
        attempt.setStop { shell.write("\u{03}") }; attempt.setWake { tape.close() }
        await attempt.clean()
        let response = await tape.next("does-not-arrive", milliseconds: 12 * 60 * 1000)
        XCTAssertNil(response); XCTAssertTrue(attempt.cancelled); XCTAssertEqual(shell.writes, ["\u{03}"])
    }
    func testPhysicalTerminalEOFEndsFlowWaitWithoutWaitingForTheCeiling() async {
        let shell = BackendServersSetupTestShell(), tape = BackendServersSetupTape(BackendServersSetupTestShell())
        tape.close()
        let live = BackendServersSetupTape(shell)
        shell.emitEnd()
        let response = await live.next("never-arrives", milliseconds: 12 * 60 * 1000)
        XCTAssertNil(response)
    }
}

final class BackendServersSetupTestShell: BackendServersShell, @unchecked Sendable {
    private let lock = NSLock(); private var output: [UUID: @Sendable (String) -> Void] = [:]; private var sent: [String] = []
    private var ending: [UUID: @Sendable () -> Void] = [:]
    private let handler: (@Sendable (String, BackendServersSetupTestShell) -> Void)?
    init(_ handler: (@Sendable (String, BackendServersSetupTestShell) -> Void)? = nil) { self.handler = handler }
    var writes: [String] { lock.withLock { sent } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe {
        let id = UUID(); lock.withLock { output[id] = listener }; return { [weak self] in self?.lock.withLock { self?.output[id] = nil } }
    }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe {
        let id = UUID(); lock.withLock { ending[id] = listener }; return { [weak self] in self?.lock.withLock { self?.ending[id] = nil } }
    }
    func write(_ data: String) { lock.withLock { sent.append(data) }; handler?(data, self) }
    func emit(_ data: String) { let callbacks = lock.withLock { Array(output.values) }; for callback in callbacks { callback(data) } }
    func emitEnd() { let callbacks = lock.withLock { Array(ending.values) }; for callback in callbacks { callback() } }
    func resize(_ size: BackendServersTerminalSize) {}; func close() {}
}
final class BackendServersSetupTestLog: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func add(_ value: String) { lock.withLock { lines.append(value) } }
    var values: [String] { lock.withLock { lines } }
}
