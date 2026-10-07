import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsAccountsAttribution: XCTestCase, @unchecked Sendable {
    private let dump = "  PID   TT  STAT      TIME COMMAND\n 2471 s001  S+     0:12.34 claude --session-id abc PATH=/usr/bin:/bin CLAUDE_CONFIG_DIR=/Users/apple/.claude-work HOME=/Users/apple SHELL=/bin/zsh\n"
    // session-account.test.ts:112
    func testEnvironmentEndsAtNextVariable() { XCTAssertEqual(BackendAccountAttribution.environmentValue(dump, name: "CLAUDE_CONFIG_DIR"), "/Users/apple/.claude-work"); XCTAssertEqual(BackendAccountAttribution.environmentValue(dump, name: "HOME"), "/Users/apple") }
    // session-account.test.ts:117
    func testEnvironmentValuePreservesSpaces() { XCTAssertEqual(BackendAccountAttribution.environmentValue("x CLAUDE_CONFIG_DIR=/Users/apple/My Claude/cfg HOME=/Users/apple\n", name: "CLAUDE_CONFIG_DIR"), "/Users/apple/My Claude/cfg") }
    // session-account.test.ts:128
    func testActualEnvironmentOverridesArgumentDecoy() { XCTAssertEqual(BackendAccountAttribution.environmentValue("sh -c CLAUDE_CONFIG_DIR=/decoy claude PATH=/bin CLAUDE_CONFIG_DIR=/real\n", name: "CLAUDE_CONFIG_DIR"), "/real") }
    // session-account.test.ts:133
    func testAbsentEnvironmentVariableIsNil() { XCTAssertNil(BackendAccountAttribution.environmentValue(dump, name: "CODEX_HOME")) }
    // session-account.test.ts:625. The same session id and pid retain the new
    // spawn metadata; no /bin/ps invocation is reached by either read.
    func testInPlaceAccountRecordChangesNameWithSameSessionAndPID() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let work = try await f.create("work@example.com"), attribution = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles)
        var meta = BackendSessionMeta(id: "switched-in-place", input: .init(cwd: f.root.path, provider: "claude"), spawn: .init(provider: "claude", command: "never-run", args: [], path: "/fixture", profile: .init(id: "system", name: "app.imatch.ae")), now: Date(timeIntervalSince1970: 0.001))
        let before = await attribution.read(meta, pid: 4242); XCTAssertEqual(before.wireValue["kind"], .string("known")); XCTAssertEqual(before.profileId, "system"); XCTAssertEqual(before.source, "spawn")
        meta.profileId = work.id; meta.profileName = work.name
        let after = await attribution.read(meta, pid: 4242); XCTAssertEqual(after.profileId, work.id); XCTAssertEqual(after.profileName, "work@example.com"); XCTAssertEqual(after.configDir, work.configDir)
        // establishedConfigDir is separately recorded as a missing native API.
    } }
    // Supplementary Mac hook tests exercise the actual actor's available rung
    // while the Windows-only declarations remain explicit skips in the map.
    func testMacHookNamesOwnDefaultInsteadOfDeckInheritedDirectory() async throws { try await BackendFoundationTestsAccountsWithFixture(environment: ["CLAUDE_CONFIG_DIR": "/tmp/somebody-elses-store"]) { f in
        let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles), meta = shell(f)
        await actor.recordHook(sessionID: meta.id, evidence: .init(provider: "claude", configDirectory: nil, home: f.configuration.homeDirectory.path, environmentWasRead: true))
        let answer = await actor.read(meta, pid: nil); XCTAssertEqual(answer.configDir, f.configuration.homeDirectory.appendingPathComponent(".claude").path); XCTAssertNil(answer.profileId); XCTAssertEqual(answer.source, "hook")
    } }
    func testMacHookDeclaredDirectoryIsNamed() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles), meta = shell(f)
        await actor.recordHook(sessionID: meta.id, evidence: .init(provider: "claude", configDirectory: f.root.appendingPathComponent("declared-store").path, home: f.configuration.homeDirectory.path, environmentWasRead: true))
        let answer = await actor.read(meta, pid: nil); XCTAssertEqual(answer.source, "hook"); XCTAssertEqual(answer.configDir, f.root.appendingPathComponent("declared-store").path)
    } }
    func testMacForeignHomeAndUnprovedEnvironmentAreWithheld() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles), meta = shell(f)
        await actor.recordHook(sessionID: meta.id, evidence: .init(provider: "claude", configDirectory: nil, home: f.root.appendingPathComponent("other-person").path, environmentWasRead: true))
        let foreign = await actor.read(meta, pid: nil); XCTAssertEqual(foreign.wireValue["kind"], .string("withheld")); XCTAssertTrue(foreign.reason?.contains("different home") == true)
        await actor.recordHook(sessionID: meta.id, evidence: .init(provider: "claude", configDirectory: nil, home: f.configuration.homeDirectory.path, environmentWasRead: false))
        let scrubbed = await actor.read(meta, pid: nil); XCTAssertEqual(scrubbed.wireValue["kind"], .string("withheld")); XCTAssertNil(scrubbed.profileId)
    } }
    func testDroppingMacHookRemovesAccountEvidence() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let actor = BackendAccountAttribution(configuration: f.configuration, profiles: f.profiles), meta = shell(f)
        await actor.recordHook(sessionID: meta.id, evidence: .init(provider: "claude", configDirectory: f.root.appendingPathComponent("store").path, home: f.configuration.homeDirectory.path, environmentWasRead: true))
        let before = await actor.read(meta, pid: nil); XCTAssertEqual(before.wireValue["kind"], .string("known"))
        await actor.drop(sessionID: meta.id); let after = await actor.read(meta, pid: nil); XCTAssertEqual(after.wireValue["kind"], .string("withheld"))
    } }
    private func shell(_ f: BackendFoundationTestsAccountsFixture) -> BackendSessionMeta {
        .init(id: "sess-files", input: .init(cwd: f.root.path, provider: "shell"), spawn: .init(provider: "shell", command: "never-run", args: [], path: "/fixture"))
    }
}
