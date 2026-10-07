import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/session-account.test.ts. Every `ps` here is the TS TABLE/DUMP fixture handed to
/// the actor's injected runner; /bin/ps is never run. `f.configuration.homeDirectory` stands for the
/// TS `homedir()` (the actor's own home), and the fixture's inherited environment for `process.env`.
final class BackendFoundationTestsF4SessionAccount: XCTestCase, @unchecked Sendable {
    private let table = [
        " 2471   850 claude",
        "  850   837 -zsh",
        "  837   740 login -pfl apple /bin/bash -c exec -la zsh /bin/zsh",
        "  740     1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "57565 57205 claude --session-id e90c48be-c4e5-4c6b-9e09-ffb2ff05193d",
        "57205 57200 /Users/apple/Projects/terminaldeck/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron .",
    ].joined(separator: "\n")
    private let dump = "  PID   TT  STAT      TIME COMMAND\n 2471 s001  S+     0:12.34 claude --session-id abc PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR=/Users/apple/.claude-work HOME=/Users/apple SHELL=/bin/zsh\n"

    // session-account.test.ts:64
    func testParsesPidParentAndWholeCommandLine() {
        let rows = BackendAccountAttribution.parseProcessTable(table)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0], BackendAccountProcessRow(pid: 2471, ppid: 850, command: "claude"))
        XCTAssertTrue(rows[4].command.contains("--session-id"))
    }
    // session-account.test.ts:73
    func testIgnoresHeaderAndNonRows() {
        XCTAssertEqual(BackendAccountAttribution.parseProcessTable("  PID  PPID COMMAND\n\n  not a row\n 12 3 sh"), [BackendAccountProcessRow(pid: 12, ppid: 3, command: "sh")])
    }
    // session-account.test.ts:87
    func testFindsAgentThatIsGrandchild() {
        let rows = BackendAccountAttribution.parseProcessTable(table)
        XCTAssertEqual(BackendAccountAttribution.agentUnder(rows, root: 740, binaries: ["claude"])?.pid, 2471)
    }
    // session-account.test.ts:92
    func testMatchesOnBasename() {
        let rows = BackendAccountAttribution.parseProcessTable(" 10 1 /opt/homebrew/bin/claude --session-id x")
        XCTAssertEqual(BackendAccountAttribution.agentUnder(rows, root: 1, binaries: ["claude"])?.pid, 10)
    }
    // session-account.test.ts:97
    func testNoAgentUnderSessionIsNil() {
        let rows = BackendAccountAttribution.parseProcessTable(table)
        XCTAssertNil(BackendAccountAttribution.agentUnder(rows, root: 850, binaries: ["codex"]))
    }
    // session-account.test.ts:146
    func testScrubbedEnvironmentIsToldFromReadOne() {
        XCTAssertTrue(BackendAccountAttribution.environmentWasRead(dump))
        XCTAssertFalse(BackendAccountAttribution.environmentWasRead("  PID   TT  STAT      TIME COMMAND\n69371   ??  SN  0:00.01 sleep 8\n"))
    }

    // session-account.test.ts:229
    func testNamesAgentsOwnDefaultStoreNotDeckInheritedDirectory() async throws {
        let inherited = FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-inherited-store").path
        try await BackendFoundationTestsAccountsWithFixture(environment: ["CLAUDE_CONFIG_DIR": inherited]) { f in
            let ps = FakePS(f, env: "")
            let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles, sessions: ladderSessions(f), ps: ps.run)
            let answer = await actor.sessionAccount(sessionID: "sess-ladder")
            XCTAssertNil(answer.reason)
            XCTAssertEqual(answer.configDir, f.configuration.homeDirectory.appendingPathComponent(".claude").path)
            XCTAssertNotEqual(answer.configDir, inherited)
            XCTAssertNil(answer.profileId)
            XCTAssertEqual(answer.source, "process")
        }
    }
    // session-account.test.ts:251
    func testStillNamesSystemProfileWhenNothingInherited() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles, sessions: ladderSessions(f), ps: FakePS(f, env: "").run)
            let answer = await actor.sessionAccount(sessionID: "sess-ladder")
            XCTAssertEqual(answer.wireValue["kind"], .string("known"))
            XCTAssertEqual(answer.configDir, f.configuration.homeDirectory.appendingPathComponent(".claude").path)
            XCTAssertEqual(answer.profileId, BackendAccountProfile.systemID("claude"))
            XCTAssertEqual(answer.profileName, "Default")
        }
    }
    // session-account.test.ts:264
    func testBelievesVariableTheAgentDeclares() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let declared = FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-declared-store").path
            let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles, sessions: ladderSessions(f), ps: FakePS(f, env: "CLAUDE_CONFIG_DIR=" + declared).run)
            let answer = await actor.sessionAccount(sessionID: "sess-ladder")
            XCTAssertEqual(answer.wireValue["kind"], .string("known"))
            XCTAssertEqual(answer.configDir, declared)
        }
    }

    // session-account.test.ts:325
    func testEstablishedConfigDirIsNilUntilProbeLands() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let actor = filesActor(f, "/tmp/work-store")
            let first = await actor.establishedConfigDir(sessionID: "sess-files")
            XCTAssertNil(first)
        }
    }
    // session-account.test.ts:333
    func testEstablishedConfigDirNamesStoreOnceItHas() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let actor = filesActor(f, "/tmp/work-store")
            _ = await actor.sessionAccount(sessionID: "sess-files")
            let established = await actor.establishedConfigDir(sessionID: "sess-files")
            XCTAssertEqual(established, "/tmp/work-store")
        }
    }
    // session-account.test.ts:339
    func testEstablishedConfigDirIsNilForDifferentAgent() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let actor = filesActor(f, "/tmp/work-store")
            _ = await actor.sessionAccount(sessionID: "sess-files")
            let established = await actor.establishedConfigDir(sessionID: "sess-files", provider: "codex")
            XCTAssertNil(established)
        }
    }

    // session-account.test.ts:625. The record changes as BackendPTYManager.setAccount changes it
    // (the in-place switch); the id and pid stay; no `ps` may run (spawn rung).
    func testSwitchedInPlaceNamesNewAccountSameIdSamePID() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            let work = try await f.create("work@example.com")
            let record = Record(BackendSessionMeta(id: "switched-in-place", input: .init(cwd: f.root.path, provider: "claude"),
                spawn: .init(provider: "claude", command: "never-run", args: [], path: "/fixture", profile: .init(id: BackendAccountProfile.systemID("claude"), name: "app.imatch.ae")),
                now: Date(timeIntervalSince1970: 0.001)))
            let ps = FakePS(f, env: "")
            let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles,
                sessions: .init(pidOf: { _ in 4242 }, describe: { _ in record.meta }), ps: ps.run)
            let before = await actor.sessionAccount(sessionID: "switched-in-place")
            XCTAssertEqual(before.wireValue["kind"], .string("known"))
            XCTAssertEqual(before.profileId, BackendAccountProfile.systemID("claude"))
            XCTAssertEqual(before.source, "spawn")

            record.update { $0.profileId = work.id; $0.profileName = work.name }

            let after = await actor.sessionAccount(sessionID: "switched-in-place")
            XCTAssertEqual(after.wireValue["kind"], .string("known"))
            XCTAssertEqual(after.profileId, work.id)
            XCTAssertEqual(after.profileName, "work@example.com")
            let established = await actor.establishedConfigDir(sessionID: "switched-in-place")
            XCTAssertEqual(established, work.configDir)
            XCTAssertEqual(ps.calls(), 0)
        }
    }

    /* -------------------------------------------------------------- rig -- */

    private func ladderSessions(_ f: BackendFoundationTestsAccountsFixture) -> BackendAccountAttribution.Sessions {
        let meta = BackendSessionMeta(id: "sess-ladder", input: .init(cwd: f.root.path, provider: "shell"), spawn: .init(provider: "shell", command: "never-run", args: [], path: "/fixture"))
        return .init(pidOf: { _ in 4242 }, describe: { _ in meta })
    }
    private func filesActor(_ f: BackendFoundationTestsAccountsFixture, _ directory: String) -> BackendAccountAttribution {
        let meta = BackendSessionMeta(id: "sess-files", input: .init(cwd: f.root.path, provider: "shell"), spawn: .init(provider: "shell", command: "never-run", args: [], path: "/fixture"))
        return BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles,
            sessions: .init(pidOf: { _ in 4242 }, describe: { _ in meta }), ps: FakePS(f, env: "CLAUDE_CONFIG_DIR=" + directory).run)
    }

    /// The TS `processWith` / `on` exec fake: one `claude` under pty 4242, with `PATH` and this
    /// account's own `HOME` always present.
    private final class FakePS: @unchecked Sendable {
        private let lock = NSLock(), home: String, env: String
        private var count = 0
        init(_ f: BackendFoundationTestsAccountsFixture, env: String) { home = f.configuration.homeDirectory.path; self.env = env }
        func calls() -> Int { lock.withLock { count } }
        var run: BackendAccountAttribution.ProcessRunner {
            { [self] arguments in
                lock.withLock { count += 1 }
                return arguments.first == "-Ao"
                    ? " 5000 4242 claude\n 4242    1 -zsh\n"
                    : "  PID   TT  STAT      TIME COMMAND\n 5000 s001  S+     0:01 claude PATH=/usr/bin \(env) HOME=\(home)\n"
            }
        }
    }
    /// The session record a switch rewrites in place (TS mutates the `SessionMeta` object).
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BackendSessionMeta
        init(_ value: BackendSessionMeta) { self.value = value }
        var meta: BackendSessionMeta { lock.withLock { value } }
        func update(_ change: (inout BackendSessionMeta) -> Void) { lock.withLock { change(&value) } }
    }
}
