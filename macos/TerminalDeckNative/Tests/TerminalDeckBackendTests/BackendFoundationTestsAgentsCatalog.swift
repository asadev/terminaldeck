import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The actual Core catalogue is deliberately narrow. Missing launch/status/
/// credential fields are recorded as gaps, never invented in these fixtures.
final class BackendFoundationTestsAgentsCatalog: XCTestCase {
    // src/shared/agent-catalog.test.ts:39
    func testEveryInstallableAgentHasAReadMoreURL() {
        for entry in CodingAICatalog.all where entry.install != nil { XCTAssertNotNil(entry.url, entry.id) }
    }
    // src/shared/agent-catalog.test.ts:46
    func testEveryAgentWithoutMultipleLoginsExplainsWhy() {
        for entry in CodingAICatalog.all where entry.logins != .multiple { XCTAssertNotNil(entry.loginsNote, entry.id) }
    }
    // src/shared/agent-catalog.test.ts:56
    func testLookupKeysMatchTheAgentsOwnIDs() {
        for entry in CodingAICatalog.all { XCTAssertEqual(CodingAICatalog.agent(entry.id)?.id, entry.id) }
    }
    // src/shared/agent-catalog.test.ts:93
    func testBinaryLookupListLeavesOutShell() {
        XCTAssertEqual(CodingAICatalog.lookup.map(\.id), ["claude", "codex", "gemini"])
    }
    // src/shared/agent-catalog.test.ts:99
    func testOneLoginAndMultipleLoginsAreDifferentCapabilities() {
        XCTAssertEqual(CodingAICatalog.all.filter(\.canHaveAccounts).map(\.id), ["claude", "codex"])
        XCTAssertEqual(CodingAICatalog.all.filter(\.hasAnyLogin).map(\.id), ["claude", "codex", "gemini"])
        XCTAssertFalse(CodingAICatalog.gemini.canHaveAccounts)
        XCTAssertTrue(CodingAICatalog.gemini.hasAnyLogin)
        XCTAssertFalse(CodingAICatalog.shell.hasAnyLogin)
    }
    // src/shared/agent-catalog.test.ts:115
    func testLoginRefusalUsesTheAgentsOwnSentence() throws {
        let gemini = try XCTUnwrap(CodingAICatalog.gemini.loginsNote), shell = try XCTUnwrap(CodingAICatalog.shell.loginsNote)
        XCTAssertTrue(gemini.contains("keychain")); XCTAssertTrue(shell.contains("shell")); XCTAssertNotEqual(gemini, shell)
    }
    // src/shared/agent-catalog.test.ts:142
    func testSignOutControlIsGatedByARealCommandCapability() {
        XCTAssertTrue(CodingAICatalog.hasSignOut("claude")); XCTAssertTrue(CodingAICatalog.hasSignOut("codex"))
        XCTAssertFalse(CodingAICatalog.hasSignOut("gemini")); XCTAssertFalse(CodingAICatalog.hasSignOut("shell"))
    }
    // src/shared/agent-catalog.test.ts:150
    func testMissingSignOutUsesTheAgentsOwnWords() {
        XCTAssertTrue(CodingAICatalog.signOutNote("gemini").contains("Gemini"))
        XCTAssertNotEqual(CodingAICatalog.signOutNote("gemini"), CodingAICatalog.signOutNote("shell"))
    }
}
