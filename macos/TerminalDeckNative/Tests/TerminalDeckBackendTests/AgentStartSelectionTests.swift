import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AgentStartSelectionTests: XCTestCase {
    private func args(_ pairs: [(String, String)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, .string($0.1)) }) }
    func testEachProviderStartsWithoutInventingASavedProfile() throws {
        for provider in ["claude", "codex", "gemini"] {
            let choice = try BackendAgentStartSelection(arguments: args([("provider", provider)]), agents: [])
            XCTAssertEqual(choice.provider, provider)
            XCTAssertNil(choice.agent)
            XCTAssertEqual(choice.id, provider)
        }
    }
    func testHistoricalCodexAgentNameResolvesProvider() throws {
        let choice = try BackendAgentStartSelection(arguments: args([("agent", "codex")]), agents: [])
        XCTAssertEqual(choice.provider, "codex")
        XCTAssertNil(choice.agent)
    }
    func testSavedAgentWinsOverProviderAliasAndKeepsIdentity() throws {
        let saved = args([("id", "codex"), ("name", "Code lead"), ("provider", "codex"), ("model", "saved-model"), ("status", "active")])
        let choice = try BackendAgentStartSelection(arguments: args([("agent", "CODE LEAD")]), agents: [saved])
        XCTAssertEqual(choice.agent, saved)
        XCTAssertEqual(choice.name, "Code lead")
    }
    func testInvalidOrMismatchedChoiceRefusesWithNextStep() throws {
        XCTAssertThrowsError(try BackendAgentStartSelection(arguments: args([("agent", "missing")]), agents: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("agents_directory"))
        }
        XCTAssertThrowsError(try BackendAgentStartSelection(arguments: args([("provider", "shell")]), agents: []))
        let saved = args([("id", "lead"), ("provider", "claude")])
        XCTAssertThrowsError(try BackendAgentStartSelection(arguments: args([("agent", "lead"), ("provider", "codex")]), agents: [saved]))
        XCTAssertThrowsError(try BackendAgentStartSelection(arguments: .object([]), agents: []))
    }
    func testPublicAgentIdentityExcludesPrivateFields() {
        let profile = args([("id", "lead"), ("name", "Code lead"), ("provider", "codex"), ("model", "chosen-model"),
            ("instructions", "PRIVATE-FIXTURE"), ("notes", "PRIVATE-FIXTURE"), ("environment_variables", "PRIVATE-FIXTURE"), ("account", "PRIVATE-FIXTURE")])
        let publicValue = BackendAgentStartSelection.publicProfile(profile)
        XCTAssertEqual(publicValue["name"], .string("Code lead"))
        XCTAssertEqual(publicValue["ai"], .string("codex"))
        XCTAssertEqual(publicValue["model"], .string("chosen-model"))
        XCTAssertFalse(publicValue.compact.contains("PRIVATE-FIXTURE"))
        XCTAssertEqual(Set(publicValue.fields?.map(\.key) ?? []), ["id", "name", "ai", "provider", "model", "coverage"])
    }
    func testR73AutoDefaultAndClearRefusalForOtherStartModes() throws {
        try BackendAgentStartSelection.requireAuto(nil)
        try BackendAgentStartSelection.requireAuto("auto")
        for mode in ["ask", "bypass", "danger-full-access", "never"] {
            XCTAssertThrowsError(try BackendAgentStartSelection.requireAuto(mode)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Every new session starts in AUTO"))
                XCTAssertTrue(error.localizedDescription.contains("sessions_chat"))
            }
        }
    }
    func testAllStartToolsKeepOverlappingWorkAndAppStorageRefusals() throws {
        let row = args([("id", "busy"), ("cwd", "/fixture/project")]).setting("exitCode", .null)
        XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.requireStartRoom(cwd: "/fixture/project", sessions: [row], startedByCaller: { _ in true })) { error in
            XCTAssertTrue(error.localizedDescription.contains("separate git worktree"))
        }
        XCTAssertNoThrow(try BackendDeckCoreCatalogueBuiltins.requireStartRoom(cwd: "/fixture/another", sessions: [row], startedByCaller: { _ in true }))
        XCTAssertThrowsError(try BackendAgentStartSelection.requireSafeFolder("/fixture/data/inside", storageRoot: "/fixture/data"))
        XCTAssertNoThrow(try BackendAgentStartSelection.requireSafeFolder("/fixture/data-project", storageRoot: "/fixture/data"))
    }
}

final class AgentProjectAccessTests: XCTestCase {
    let projects = [PROJProject(id: "one", name: "One", folders: ["/fixture/primary", "/fixture/other"]),
        PROJProject(id: "two", name: "Two", folders: ["/fixture/private"])]
    func testSeatCanStartInsideEveryFolderOfItsRegisteredProject() throws {
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "starter", projectRoot: "/fixture/primary")
        let roots = try BackendAgentProjectAccess.roots(caller: caller, cwd: "/fixture/primary", projects: projects)
        XCTAssertTrue(roots.contains("/fixture/other"))
        XCTAssertTrue(roots.contains { BackendAgentProjectAccess.within("/fixture/other/subfolder", $0) })
        XCTAssertFalse(roots.contains { BackendAgentProjectAccess.within("/fixture/private", $0) })
        XCTAssertFalse(roots.contains { BackendAgentProjectAccess.within("/fixture/other-private", $0) })
    }
    func testIndependentFolderDoesNotOpenOtherProjects() throws {
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "starter", projectRoot: "/fixture/unregistered")
        XCTAssertEqual(try BackendAgentProjectAccess.roots(caller: caller, cwd: "/fixture/unregistered", projects: projects), ["/fixture/unregistered"])
    }
    func testCanonicalSymlinkEscapeIsOutsideGrant() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agent-project-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("project"), outside = scratch.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertFalse(BackendAgentProjectAccess.within(root.appendingPathComponent("escape").path, root.path))
    }
    func testNestedProjectUsesMostSpecificOwner() throws {
        let nested = projects + [PROJProject(id: "nested", name: "Nested", folders: ["/fixture/primary/nested", "/fixture/nested-other"])]
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "starter", projectRoot: "/fixture/primary/nested")
        let roots = try BackendAgentProjectAccess.roots(caller: caller, cwd: "/fixture/primary/nested", projects: nested)
        XCTAssertTrue(roots.contains("/fixture/nested-other"))
        XCTAssertFalse(roots.contains("/fixture/other"))
    }
}
