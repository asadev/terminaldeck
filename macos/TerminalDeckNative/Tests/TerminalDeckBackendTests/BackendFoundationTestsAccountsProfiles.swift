import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsAccountsProfiles: XCTestCase, @unchecked Sendable {
    private func resolution(_ fields: [(String, NativeRPCValue)] = [], session: String? = nil, project: String? = nil, provider: String? = nil) async throws -> BackendAccountProfile {
        try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsRaw(fields)) { f in
            try await f.profiles.resolve(sessionProfileID: session, projectPath: project, provider: provider)
        }
    }
    // profiles.test.ts:107–171: every precedence rung, including stale choices.
    func testSessionChoiceWins() async throws { let p = try await resolution([("defaultProfileId", .string("personal")), ("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("personal"))]))], session: "work", project: "/w/app"); XCTAssertEqual(p.id, "work") }
    func testProjectDefaultWins() async throws { let p = try await resolution([("defaultProfileId", .string("personal")), ("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("work"))]))], project: "/w/app"); XCTAssertEqual(p.id, "work") }
    func testGlobalDefaultWins() async throws { let p = try await resolution([("defaultProfileId", .string("personal"))], project: "/w/other"); XCTAssertEqual(p.id, "personal") }
    func testNoChoiceUsesSystem() async throws { for project in [String?](arrayLiteral: nil, "/w/app") { let p = try await resolution(project: project); XCTAssertEqual(p.id, "system") } }
    func testDeletedSessionFallsThrough() async throws { let p = try await resolution([("defaultProfileId", .string("personal")), ("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("work"))]))], session: "gone", project: "/w/app"); XCTAssertEqual(p.id, "work") }
    func testDeletedProjectFallsThrough() async throws { let p = try await resolution([("defaultProfileId", .string("personal")), ("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("gone"))]))], project: "/w/app"); XCTAssertEqual(p.id, "personal") }
    func testDeletedGlobalFallsThrough() async throws { let p = try await resolution([("defaultProfileId", .string("gone"))], project: "/w/app"); XCTAssertEqual(p.id, "system") }
    func testProjectPathSpellingsMatch() async throws { for path in ["/w/app/", "/w/app/../app"] { let p = try await resolution([("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("work"))]))], project: path); XCTAssertEqual(p.id, "work") } }
    func testEmptyOrNilSessionChoiceFallsThrough() async throws { for session in [String?](arrayLiteral: "", nil) { let p = try await resolution([("defaultProfileId", .string("personal"))], session: session); XCTAssertEqual(p.id, "personal") } }
    func testExplicitSystemChoiceWins() async throws { let p = try await resolution([("defaultProfileId", .string("personal"))], session: "system"); XCTAssertEqual(p.id, "system") }
    func testResolutionReturnsWholeProfile() async throws { let named = try await resolution([("defaultProfileId", .string("work"))]), system = try await resolution(); XCTAssertEqual(named.id, "work"); XCTAssertTrue(system.system) }

    // Source accepts junk state as empty; the store boots it empty and moves
    // the file aside before its first write.
    // profiles.test.ts:181
    func testJunkStateSanitizesToEmpty() async throws {
        for raw in [NativeRPCValue.null, .string("nope"), BackendFoundationTestsAccountsObject([("profiles", .string("no"))])] {
            try await BackendFoundationTestsAccountsWithFixture(raw: raw) { f in let s = try await f.profiles.snapshot(); XCTAssertEqual(s.profiles, []) }
        }
    }
    // profiles.test.ts:187
    func testPersistedSystemIDIsRejected() async throws {
        try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([BackendFoundationTestsAccountsRawProfile("system"), BackendFoundationTestsAccountsRawProfile("work")]))])) { f in let s = try await f.profiles.snapshot(); XCTAssertEqual(s.profiles.map(\.id), ["work"]) }
    }
    // profiles.test.ts:193
    func testPersistedSystemFlagIsNeverTrusted() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([BackendFoundationTestsAccountsRawProfile("work", system: true)]))])) { f in let s = try await f.profiles.snapshot(); XCTAssertFalse(try XCTUnwrap(s.profiles.first).system) } }
    // profiles.test.ts:198
    func testSanitizeDropsStaleDefaults() async throws {
        let raw = BackendFoundationTestsAccountsObject([("profiles", .array([BackendFoundationTestsAccountsRawProfile("work")])), ("defaultProfileId", .string("gone")), ("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app", .string("gone")), ("/w/other", .string("work"))]))])
        try await BackendFoundationTestsAccountsWithFixture(raw: raw) { f in let s = try await f.profiles.snapshot(); XCTAssertNil(s.defaultProfileID); XCTAssertEqual(s.projectDefaults, ["/w/other": "work"]) }
    }
    // profiles.test.ts:208
    func testSanitizeKeepsSystemDefault() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([])), ("defaultProfileId", .string("system"))])) { f in let s = try await f.profiles.snapshot(); XCTAssertEqual(s.defaultProfileID, "system") } }
    // profiles.test.ts:213
    func testSanitizeCanonicalizesProjectKeys() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsRaw([("projectDefaults", BackendFoundationTestsAccountsObject([("/w/app/", .string("work"))]))])) { f in let s = try await f.profiles.snapshot(); XCTAssertEqual(Array(s.projectDefaults.keys), ["/w/app"]) } }
    // profiles.test.ts:221
    func testSanitizeDropsDuplicateIDs() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([BackendFoundationTestsAccountsRawProfile("work"), BackendFoundationTestsAccountsRawProfile("work", name: "Other")]))])) { f in let s = try await f.profiles.snapshot(); XCTAssertEqual(s.profiles.count, 1); XCTAssertEqual(s.profiles.first?.name, "work") } }

    // profiles.test.ts:309. Test slugs through real allocation, not a copied slugger.
    func testSlugNamesStaySafe() async throws {
        for (name, id) in [("Work Account", "work-account"), ("  Personal  ", "personal"), ("../../etc", "etc")] { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create(name); XCTAssertEqual(p.id, id) } }
    }
    // profiles.test.ts:322
    func testIDsAreUniqueAndNeverSystem() async throws {
        try await BackendFoundationTestsAccountsWithFixture { f in
            _ = try await f.create("Work"); let second = try await f.create("work!"); let third = try await f.create("work?")
            XCTAssertEqual(second.id, "work-2"); XCTAssertEqual(third.id, "work-3")
            let reserved = try await f.create("System"); XCTAssertEqual(reserved.id, "system-2")
        }
    }
    // profiles.test.ts:328
    func testNamesCollapseWhitespaceAndRejectBlankOrOverlong() throws {
        XCTAssertEqual(try BackendAccountProfileStore.normalizedName("  Work   Account "), "Work Account")
        // The source's non-string case is normalizeProfileName(42), not the RPC boundary.
        XCTAssertThrowsError(try BackendAccountProfileStore.normalizedName(NativeRPCValue.number(42))) { XCTAssertTrue($0.localizedDescription.contains("needs a name")) }
        for (text, fragment) in [("   ", "needs a name"), (String(repeating: "x", count: 61), "60 characters")] {
            XCTAssertThrowsError(try BackendAccountProfileStore.normalizedName(text)) { XCTAssertTrue($0.localizedDescription.contains(fragment)) }
        }
    }
    // profiles.test.ts:335
    func testNamesStripControlAndBidiCharacters() throws {
        for (raw, clean) in [("Work\0Account", "Work Account"), ("Work \u{202e}gro.exe", "Work gro.exe"), ("a\u{200b}b", "a b"), ("Work\nAccount", "Work Account"), ("Работа", "Работа")] { XCTAssertEqual(try BackendAccountProfileStore.normalizedName(raw), clean) }
        XCTAssertThrowsError(try BackendAccountProfileStore.normalizedName("\0\u{202e}")) { XCTAssertTrue($0.localizedDescription.contains("needs a name")) }
    }
    // profiles.test.ts:353
    func testOnlyDescendantsAreManaged() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let root = f.configuration.profilesRoot.path
        for (path, managed) in [(root + "/work", true), (root + "/work/nested", true), (root, false), (f.configuration.homeDirectory.appendingPathComponent(".claude").path, false), (root + "/../boards", false), ("relative/path", false), ("", false)] {
            var p = f.profile("work"); p.configDir = path; let result = await f.profiles.managed(p); XCTAssertEqual(result, managed, path)
        }
    } }
    // profiles.test.ts:364 — the source asserts isProtectedDir itself (its create
    // refusal wording is pinned by :694 below), so this asks the real predicate.
    func testHomeRootAndOwnClaudeAreProtected() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        for path in [f.configuration.homeDirectory.path, f.configuration.homeDirectory.appendingPathComponent(".claude").path, "/"] { XCTAssertTrue(f.profiles.isProtectedDir(path), path) }
        XCTAssertFalse(f.profiles.isProtectedDir(f.configuration.profilesRoot.appendingPathComponent("work").path))
        let normal = try await f.create("Normal"); XCTAssertTrue(FileManager.default.fileExists(atPath: normal.configDir))
    } }
    // profiles.test.ts:371
    func testSystemCannotBeDeleted() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        await BackendFoundationTestsAccountsExpectError("cannot be deleted") { _ = try await f.profiles.removeMetadata(id: "system") }
        let rows = try await f.profiles.list(); XCTAssertTrue(rows.contains(where: \.system))
    } }
    // profiles.test.ts:376
    func testManagedDirectoryIsDeletedWhenAsked() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let p = try await f.create("Work"); XCTAssertTrue(FileManager.default.fileExists(atPath: p.configDir))
        _ = try await f.profiles.removeMetadata(id: p.id); let deleted = try await f.profiles.deleteManagedDirectory(p)
        XCTAssertTrue(deleted); XCTAssertFalse(FileManager.default.fileExists(atPath: p.configDir))
    } }
    // profiles.test.ts:384
    func testAdoptedDirectorySurvivesDeletion() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let dir = f.root.appendingPathComponent("pre-existing-claude"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".claude.json"))
        let p = try await f.create("Adopted", directory: dir.path); _ = try await f.profiles.removeMetadata(id: p.id)
        let deleted = try await f.profiles.deleteManagedDirectory(p), missing = try await f.profiles.find(p.id)
        XCTAssertFalse(deleted); XCTAssertNil(missing); XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude.json").path))
    } }
    // profiles.test.ts:399
    func testMetadataDeletionKeepsDirectoryByDefault() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work"); _ = try await f.profiles.removeMetadata(id: p.id); XCTAssertTrue(FileManager.default.fileExists(atPath: p.configDir)) } }
    // profiles.test.ts:412
    func testDeleteClearsGlobalAndProjectDefaults() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let p = try await f.create("Work"); try await f.profiles.setDefault(p.id); try await f.profiles.setDefault(p.id, projectPath: "/w/app")
        _ = try await f.profiles.removeMetadata(id: p.id); let s = try await f.profiles.snapshot(), resolved = try await f.profiles.resolve(sessionProfileID: nil, projectPath: "/w/app", provider: nil)
        XCTAssertNil(s.defaultProfileID); XCTAssertEqual(s.projectDefaults, [:]); XCTAssertEqual(resolved.id, "system")
    } }
    // profiles.test.ts:429
    func testCreateOwnDirectory() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work Account"); XCTAssertEqual(p.id, "work-account"); XCTAssertEqual(p.configDir, f.configuration.profilesRoot.appendingPathComponent("work-account").path); XCTAssertTrue(FileManager.default.fileExists(atPath: p.configDir)); XCTAssertFalse(p.system) } }
    // profiles.test.ts:455
    func testEverySystemInstallAppearsFirst() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        _ = try await f.create("Work"); let rows = try await f.profiles.list(); XCTAssertTrue(rows[0].system)
        XCTAssertEqual(rows.map(\.name), ["Default", "Default (Codex CLI)", "Default (Gemini CLI)", "Work"]); XCTAssertEqual(rows.map(\.provider), ["claude", "codex", "gemini", "claude"])
    } }
    // profiles.test.ts:476,517: exact source refusal contains keychain.
    func testGeminiHasOneInstallAndCannotAddAnother() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let rows = try await f.profiles.list(provider: "gemini"); XCTAssertEqual(rows.map(\.name), ["Default (Gemini CLI)"]); XCTAssertTrue(rows[0].system)
        await BackendFoundationTestsAccountsExpectError("keychain") { _ = try await f.create("Second", provider: "gemini") }
    } }
    func testUnverifiedProviderCreationLeavesNoRow() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        await BackendFoundationTestsAccountsExpectError("keychain") { _ = try await f.create("Google", provider: "gemini") }; let rows = try await f.profiles.list(); XCTAssertFalse(rows.contains { $0.name == "Google" })
    } }
    // profiles.test.ts:491
    func testGeminiSystemIDResolves() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.profiles.resolve(sessionProfileID: nil, projectPath: nil, provider: "gemini"); XCTAssertEqual(p.id, "system:gemini"); XCTAssertEqual(p.provider, "gemini"); XCTAssertTrue(p.system) } }
    // profiles.test.ts:501
    func testSameNameIsScopedByProvider() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let claude = try await f.create("Work"), codex = try await f.create("Work", provider: "codex")
        let c = try await f.profiles.list(provider: "claude"), x = try await f.profiles.list(provider: "codex")
        XCTAssertEqual(c.map(\.name), ["Default", "Work"]); XCTAssertEqual(x.map(\.name), ["Default (Codex CLI)", "Work"]); XCTAssertNotEqual(claude.configDir, codex.configDir)
    } }
    // profiles.test.ts:524
    func testDuplicateNamesAreCaseInsensitive() async throws { try await BackendFoundationTestsAccountsWithFixture { f in _ = try await f.create("Work"); for name in ["work", "Default"] { await BackendFoundationTestsAccountsExpectError("already exists") { _ = try await f.create(name) } } } }
    // profiles.test.ts:530
    func testColorsDifferUntilPaletteExhaustion() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let a = try await f.create("One"), b = try await f.create("Two"); XCTAssertNotEqual(a.color, b.color) } }
    // profiles.test.ts:536
    func testFirstCustomColorDiffersFromSystem() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("One"), optionalSystem = try await f.profiles.find("system"); let s = try XCTUnwrap(optionalSystem); XCTAssertNotEqual(p.color, s.color) } }
    // profiles.test.ts:544
    func testProfileAndDefaultPersistAcrossReload() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let p = try await f.create("Work"); try await f.profiles.setDefault(p.id, projectPath: "/w/app"); await f.profiles.close()
        let reloaded = try BackendAccountProfileStore(configuration: f.configuration, stateStore: f.state)
        do { let s = try await reloaded.snapshot(), resolved = try await reloaded.resolve(sessionProfileID: nil, projectPath: "/w/app", provider: nil); XCTAssertEqual(s.profiles.map(\.id), [p.id]); XCTAssertEqual(resolved.id, p.id); await reloaded.close() }
        catch { await reloaded.close(); throw error }
    } }
    // profiles.test.ts:560
    func testRenameRejectsClash() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work"); _ = try await f.create("Personal"); let renamed = try await f.profiles.rename(id: p.id, name: "Day Job"); XCTAssertEqual(renamed.name, "Day Job"); await BackendFoundationTestsAccountsExpectError("already exists") { _ = try await f.profiles.rename(id: p.id, name: "Personal") } } }
    // profiles.test.ts:581
    func testRenameSystemNeverMovesIdentityOrDirectory() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        let optionalBefore = try await f.profiles.find("system"), renamed = try await f.profiles.rename(id: "system", name: "  Personal Claude  "), optionalAfter = try await f.profiles.find("system"), rows = try await f.profiles.list()
        let before = try XCTUnwrap(optionalBefore), after = try XCTUnwrap(optionalAfter)
        XCTAssertEqual(renamed.name, "Personal Claude"); XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.configDir, before.configDir); XCTAssertTrue(after.system); XCTAssertEqual(rows.first { $0.id == "system" }?.name, "Personal Claude")
    } }
    // profiles.test.ts:594
    func testSystemNamePersistsOnDisk() async throws { try await BackendFoundationTestsAccountsWithFixture { f in _ = try await f.profiles.rename(id: "system", name: "Personal Claude"); await f.profiles.close(); let reloaded = try BackendAccountProfileStore(configuration: f.configuration, stateStore: f.state); do { let p = try await reloaded.find("system"); XCTAssertEqual(p?.name, "Personal Claude"); await reloaded.close() } catch { await reloaded.close(); throw error } } }
    // profiles.test.ts:600
    func testGeneratedNameClearsSystemOverride() async throws { try await BackendFoundationTestsAccountsWithFixture { f in _ = try await f.profiles.rename(id: "system", name: "Personal Claude"); let p = try await f.profiles.rename(id: "system", name: "Default"), s = try await f.profiles.snapshot(); XCTAssertEqual(p.name, "Default"); XCTAssertNil(s.systemNames["system"]) } }
    // profiles.test.ts:608
    func testSystemNameCollisionsWorkBothWays() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        _ = try await f.create("Work"); await BackendFoundationTestsAccountsExpectError("already exists") { _ = try await f.profiles.rename(id: "system", name: "Work") }
        _ = try await f.profiles.rename(id: "system", name: "Personal Claude"); let spare = try await f.create("Spare")
        await BackendFoundationTestsAccountsExpectError("already exists") { _ = try await f.profiles.rename(id: spare.id, name: "personal claude") }
    } }
    // profiles.test.ts:619
    func testHandEditedSystemNamesAreSanitized() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([])), ("systemNames", BackendFoundationTestsAccountsObject([("system", .string("  Work\u{202e}gro.exe  ")), ("not-a-system-id", .string("Nope")), ("system:codex", .string(""))]))])) { f in
        let s = try await f.profiles.snapshot(), p = try await f.profiles.find("system:codex"); XCTAssertEqual(s.systemNames["system"], "Work gro.exe"); XCTAssertNil(s.systemNames["not-a-system-id"]); XCTAssertNil(s.systemNames["system:codex"]); XCTAssertEqual(p?.name, "Default (Codex CLI)")
    } }
    // profiles.test.ts:645
    func testRenameKeepsIDAndProjectDefault() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work"); try await f.profiles.setDefault(p.id, projectPath: "/w/app"); _ = try await f.profiles.rename(id: p.id, name: "Day Job"); let resolved = try await f.profiles.resolve(sessionProfileID: nil, projectPath: "/w/app", provider: nil); XCTAssertEqual(resolved.id, p.id) } }
    // profiles.test.ts:652
    func testDefaultRefusesMissingAccountAndEmptyProjectPath() async throws { try await BackendFoundationTestsAccountsWithFixture { f in
        await BackendFoundationTestsAccountsExpectError("no profile") { try await f.profiles.setDefault("gone") }; await BackendFoundationTestsAccountsExpectError("no profile") { try await f.profiles.setDefault("gone", projectPath: "/w/app") }; await BackendFoundationTestsAccountsExpectError("project path") { try await f.profiles.setDefault(nil, projectPath: "") }
    } }
    // profiles.test.ts:658
    func testSystemGlobalDefaultIsStoredAsNull() async throws { try await BackendFoundationTestsAccountsWithFixture { f in try await f.profiles.setDefault("system"); let s = try await f.profiles.snapshot(); XCTAssertNil(s.defaultProfileID) } }
    // profiles.test.ts:663
    func testClearProjectDefault() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work"); try await f.profiles.setDefault(p.id, projectPath: "/w/app"); try await f.profiles.setDefault(nil, projectPath: "/w/app"); let s = try await f.profiles.snapshot(); XCTAssertEqual(s.projectDefaults, [:]) } }
    // profiles.test.ts:670
    func testLastUsedRecordsAndMissingAccountIsNoop() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.create("Work"); XCTAssertNil(p.lastUsedAt); try await f.profiles.markUsed(id: p.id); let used = try await f.profiles.find(p.id); XCTAssertNotNil(used?.lastUsedAt); try await f.profiles.markUsed(id: "gone") } }
    // profiles.test.ts:686
    func testAdoptionRefusesRelativeDirectory() async throws { try await BackendFoundationTestsAccountsWithFixture { f in await BackendFoundationTestsAccountsExpectError("absolute") { _ = try await f.create("Bad", directory: "relative") } } }
    // profiles.test.ts:694
    func testAdoptionRefusesOwnClaudeHomeAndRootWithSourceWords() async throws { try await BackendFoundationTestsAccountsWithFixture { f in for (i, dir) in [f.configuration.homeDirectory.appendingPathComponent(".claude").path, f.configuration.homeDirectory.path, "/"].enumerated() { await BackendFoundationTestsAccountsExpectError("your own") { _ = try await f.create("Own \(i)", directory: dir) } } } }
    // profiles.test.ts:707
    func testAdoptionRefusesOwnCodexAndNamesAgent() async throws { try await BackendFoundationTestsAccountsWithFixture { f in await BackendFoundationTestsAccountsExpectError("your own Codex CLI install") { _ = try await f.create("Mine", provider: "codex", directory: f.configuration.homeDirectory.appendingPathComponent(".codex").path) } } }
    // profiles.test.ts:716
    func testAdoptionRefusesUsedDirectoryWithOwningName() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let shared = f.root.appendingPathComponent("shared-config").path; _ = try await f.create("Work", directory: shared); for dir in [shared, shared + "/"] { await BackendFoundationTestsAccountsExpectError("already uses") { _ = try await f.create("Personal", directory: dir) } } } }
    // profiles.test.ts:727
    func testOrdinaryChosenDirectoryIsAdopted() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let dir = f.root.appendingPathComponent("my-own-claude"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); let p = try await f.create("Adopted", directory: dir.path); XCTAssertEqual(p.configDir, dir.path) } }
    // profiles.test.ts:790
    func testPersistenceKeepsUnknownTopLevelKeys() async throws { try await BackendFoundationTestsAccountsWithFixture(raw: BackendFoundationTestsAccountsObject([("profiles", .array([])), ("telemetryOptOut", .bool(true)), ("futureFeature", BackendFoundationTestsAccountsObject([("keep", .string("me"))]))])) { f in _ = try await f.create("Work"); let raw = try f.disk(); XCTAssertEqual(raw["telemetryOptOut"], .bool(true)); XCTAssertEqual(raw["futureFeature"], BackendFoundationTestsAccountsObject([("keep", .string("me"))])); XCTAssertEqual(raw["profiles"].elements?.count, 1) } }
    // profiles.test.ts:823
    func testFirstRunDoesNotCreateBackup() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let file = f.configuration.dataDirectory.appendingPathComponent("profiles.json"); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); _ = try await f.create("Work"); let backups = try FileManager.default.contentsOfDirectory(atPath: f.configuration.dataDirectory.path).filter { $0.contains("profiles.json.bak-") }; XCTAssertEqual(backups, []) } }
    // profiles.test.ts:871,876,893
    func testSystemDirectoriesRespectInheritedAndExplicitEmptyEnvironment() async throws { try await BackendFoundationTestsAccountsWithFixture(environment: ["CLAUDE_CONFIG_DIR": "/tmp/terminaldeck-inherited-install", "CODEX_HOME": "/tmp/terminaldeck-inherited-install"]) { f in
        for provider in ["claude", "codex"] { XCTAssertEqual(f.configuration.systemDirectory(provider), "/tmp/terminaldeck-inherited-install"); XCTAssertEqual(f.configuration.systemDirectory(provider, environment: [:]), f.configuration.homeDirectory.appendingPathComponent("." + provider).path) }
        XCTAssertEqual(f.configuration.systemDirectory("claude", environment: ["CLAUDE_CONFIG_DIR": "   "]), f.configuration.homeDirectory.appendingPathComponent(".claude").path)
    } }
    // vault-profiles.test.ts:110 (metadata transaction, vault lifecycle separately blocked).
    func testNewAppKeptProfilePersistsLoginStore() async throws { try await BackendFoundationTestsAccountsWithFixture { f in let p = try await f.profiles.create(name: "work@example.com", vaultManaged: true, beforeCommit: { _ in }); XCTAssertEqual(p.loginStore, "app"); XCTAssertTrue(p.promised); XCTAssertEqual(try f.disk()["profiles"].elements?.first?["loginStore"].string, "app") } }
}
