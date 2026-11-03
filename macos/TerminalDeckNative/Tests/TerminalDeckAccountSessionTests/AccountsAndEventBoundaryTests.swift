import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U175: account and event boundaries, with temporary files and no real Keychain or CLI calls.
final class AccountsAndEventBoundaryTests: XCTestCase, @unchecked Sendable {
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }

    func testEffectiveAccountFallsBackThroughEveryLevelWithoutCrossingProviders() async throws {
        try await withAccountSessionFixture { f in
            let app = try await f.create("App"), project = try await f.create("Project"), seat = try await f.create("Seat"), session = try await f.create("Session")
            let codex = try await f.create("Codex", provider: "codex")
            try await f.profiles.setLevel(.app, provider: "claude", id: app.id)
            try await f.profiles.setLevel(.app, provider: "codex", id: codex.id)
            try await f.profiles.setLevel(.project(path: "/work"), provider: "claude", id: project.id)
            try await f.profiles.setLevel(.seat(key: "role:work/tester"), provider: "claude", id: seat.id)
            let explicit = try await f.profiles.effective(sessionProfileID: session.id, projectPath: "/work/src", provider: "claude", seat: "role:work/tester")
            XCTAssertEqual(explicit.profile.id, session.id); XCTAssertEqual(explicit.source, .session)
            let seated = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/work/src", provider: "claude", seat: "role:work/tester")
            XCTAssertEqual(seated.profile.id, seat.id); XCTAssertEqual(seated.source, .seat)
            try await f.profiles.setLevel(.seat(key: "role:work/tester"), provider: "claude", id: nil)
            let projected = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/work/src", provider: "claude", seat: "role:work/tester")
            XCTAssertEqual(projected.profile.id, project.id); XCTAssertEqual(projected.source, .project); XCTAssertEqual(projected.sourceKey, "/work")
            let otherAI = try await f.profiles.effective(sessionProfileID: seat.id, projectPath: "/work/src", provider: "codex")
            XCTAssertEqual(otherAI.profile.id, codex.id); XCTAssertEqual(otherAI.source, .app)
            try await f.profiles.setLevel(.project(path: "/work"), provider: "claude", id: nil)
            let inherited = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/work/src", provider: "claude")
            XCTAssertEqual(inherited.profile.id, app.id); XCTAssertEqual(inherited.source, .app)
            try await f.profiles.setLevel(.app, provider: "claude", id: nil)
            let system = try await f.profiles.effective(sessionProfileID: nil, projectPath: "/work/src", provider: "claude")
            XCTAssertTrue(system.profile.system); XCTAssertEqual(system.source, .system)
        }
    }

    func testProjectAccountUsesLongestFolderAndDoesNotMatchASiblingPrefix() {
        let levels = BackendAccountLevelsSnapshot(projects: ["/work": ["claude": "parent"], "/work/app": ["claude": "child"], "/work/app/src": ["codex": "other-ai"]])
        XCTAssertEqual(levels.project(containing: "/work/app/src/../file", provider: "claude")?.id, "child")
        XCTAssertEqual(levels.project(containing: "/work/apple", provider: "claude")?.id, "parent")
        XCTAssertNil(levels.project(containing: "/worker", provider: "claude"))
        XCTAssertNil(levels.project(containing: "work/app", provider: "claude"))
    }

    func testAccountLevelRejectsMalformedPathsAndSeatKeys() {
        for path in ["relative", "/work\0bad", "/" + String(repeating: "x", count: 4096)] {
            XCTAssertNil(BackendAccountLevel(wire: object([("kind", .string("project")), ("path", .string(path))])))
        }
        for key in ["", "tester", "role:work/tester\nother", "lead:\0bad"] {
            XCTAssertNil(BackendAccountLevel(wire: object([("kind", .string("seat")), ("key", .string(key))])))
        }
        let level = BackendAccountLevel(wire: object([("kind", .string("project")), ("path", .string("/work/a/../b"))]))
        XCTAssertEqual(level, .project(path: "/work/b"))
    }

    func testMissingAPIAccountFailsClosedInsteadOfUsingTheAppLogin() async throws {
        try await withAccountSessionFixture { f in
            let app = try await f.create("App")
            try await f.profiles.setLevel(.app, provider: "claude", id: app.id)
            do {
                _ = try await f.profiles.effective(sessionProfileID: "api-key-" + String(repeating: "a", count: 24), projectPath: nil, provider: "claude")
                XCTFail("An unavailable API account must not fall back to another login")
            } catch { XCTAssertTrue(error.localizedDescription.contains("No other account was used")) }
        }
    }

    func testEveryAPIMutationAuthorizesBeforeLookingUpOrChangingAnAccount() async throws {
        try await withAccountSessionFixture { f in
            let access = BackendAPIAccountAccess(find: { _, _ in XCTFail("Unauthorized lookup"); return nil }, list: { _ in [] },
                create: { _, _, _, _ in throw BackendAccountFailure("Unexpected create") }, rename: { _, _, _ in throw BackendAccountFailure("Unexpected rename") },
                remove: { _, _ in XCTFail("Unauthorized removal"); return .null })
            let service = BackendAPIAccountService(configuration: f.configuration, access: access, authorizeMutation: { _ in throw BackendAccountFailure("Fixture authorization denied") })
            let context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
            let listed = try await service.invoke("profiles:api:list", args: [], context: context)
            XCTAssertEqual(listed, .array([]))
            for channel in BackendAPIAccountService.channels.subtracting(["profiles:api:list"]) {
                do { _ = try await service.invoke(channel, args: [self.object([("id", .string("other"))])], context: context); XCTFail(channel) }
                catch { XCTAssertEqual(error.localizedDescription, "Fixture authorization denied") }
            }
        }
    }

    func testAPIRemovalCannotDeleteAnAccountOutsideThisAppsLoginRoot() async throws {
        try await withAccountSessionFixture { f in
            let foreign = f.profile("api-key-" + String(repeating: "a", count: 24))
            let access = BackendAPIAccountAccess(find: { _, _ in foreign }, list: { _ in [foreign] },
                create: { _, _, _, _ in throw BackendAccountFailure("Unexpected create") }, rename: { _, _, _ in throw BackendAccountFailure("Unexpected rename") },
                remove: { _, _ in XCTFail("Must not delete the foreign account"); return .null })
            let service = BackendAPIAccountService(configuration: f.configuration, access: access, authorizeMutation: { _ in })
            do { _ = try await service.invoke("profiles:api:remove", args: [self.object([("id", .string(foreign.id))])], context: .init(caller: .nativeApp, ownerID: "fixture")); XCTFail("Foreign account accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("owned by this copy")) }
        }
    }

    func testKeyValidationRejectsShellAndStorageDelimitersWithoutOpeningKeychain() throws {
        for key in ["short", "eight key", "abcdefgh\n", "abcd\"efgh", "abcd\\efgh", "abcdéefgh", String(repeating: "a", count: 8193)] {
            XCTAssertThrowsError(try BackendAPIAccountKeychain.validate(key), key)
        }
        try BackendAPIAccountKeychain.validate("fixture-key-123")
        try BackendAPIAccountKeychain.validate(String(repeating: "a", count: 8192))
    }

    func testTAGToolNamesCannotSmuggleArgumentsOrUnknownPermissionModes() throws {
        for name in ["Read\nBash", "", "Read\0", "Bash; rm -rf /tmp/fixture"] {
            XCTAssertThrowsError(try BackendTAGAgentProfile.fields(object([("allowedTools", .array([.string(name)]))]), provider: "claude"))
        }
        XCTAssertThrowsError(try BackendTAGAgentProfile.fields(object([("permissionMode", .string("allow-everything"))]), provider: "claude"))
        let fields = try BackendTAGAgentProfile.fields(object([("allowedTools", .array([.string(" Read "), .string("Read")]))]), provider: "claude")
        XCTAssertEqual(object(fields)["allowedTools"], .array([.string("Read")]))
    }

    func testEventRedactionPreservesEditablePathsButRemovesNestedCredentials() {
        let value = object([("path", .string("/Users/fixture/Projects/deck")), ("nested", .array([object([("apiKey", .string("fixture-key")), ("note", .string("password=hunter2"))])]))])
        let safe = BackendDeckCoreEventsRedaction.value(value)
        XCTAssertEqual(safe["path"].string, "/Users/fixture/Projects/deck")
        XCTAssertFalse(safe.compact.contains("fixture-key")); XCTAssertFalse(safe.compact.contains("hunter2"))
        XCTAssertEqual(BackendDeckCoreEventsRedaction.value(safe), safe)
        XCTAssertEqual(BackendDeckCoreEventsRedaction.redact("/Users/fixture/work session-only-secret", extraSecrets: ["session-only-secret"]), "/Users/fixture/work [redacted]")
        let stripped = BackendDeckCoreEventsRedaction.withoutSecrets(object([("nested", .array([object([("token", .string("private")), ("credentialsRetained", .bool(true))])]))]))
        XCTAssertFalse(stripped.compact.contains("private")); XCTAssertEqual(stripped["nested"].elements?.first?["credentialsRetained"].bool, true)
    }

    func testCodexUsageCandidateMatchesProjectAndConversationAndIgnoresSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("u175-usage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (file, cwd, id) in [("wanted", "/work/app", "conversation"), ("sibling", "/work/apple", "other"), ("other", "/work/app", "another")] {
            let value = object([("type", .string("session_meta")), ("payload", object([("cwd", .string(cwd)), ("id", .string(id))]))])
            try (value.compact + "\n").write(to: sessions.appendingPathComponent(file + ".jsonl"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("link.jsonl"), withDestinationURL: sessions.appendingPathComponent("wanted.jsonl"))
        let found = try BackendUsageCodex.projectCandidates(home: root.path, cwd: "/work/app", conversationID: "conversation")
        XCTAssertEqual(found.map(\.conversationID), ["conversation"])
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["wanted.jsonl"])
        XCTAssertTrue(try BackendUsageCodex.projectCandidates(home: root.path, cwd: "/work/app", conversationID: nil, byteBudget: 0).isEmpty)
    }

    func testMemoryProfileWritesAreNeverAdvertisedAsReadOnlyTools() throws {
        let access = BackendDeckToolsAppAccess(caller: { _ in throw BackendAccountFailure("Not invoked") },
            knownFolder: { _, _ in throw BackendAccountFailure("Not invoked") }, session: { _, _ in .null },
            runnableProject: { _, _ in throw BackendAccountFailure("Not invoked") }, rpc: { _ in .init(caller: .nativeApp, ownerID: "fixture") },
            authorize: { _, _, _, _, _, _ in XCTFail("Catalogue construction must not request permission") }, record: { _, _, _, _ in })
        let tools = try DeckMemoryProfileTools.definitions(access: access)
        XCTAssertEqual(Set(tools.map(\.id)).count, tools.count)
        let tiers = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0.tier) })
        for id in ["memory.note.edit", "memory.note.restore", "memory.topic.set_open", "memory.question.answer"] { XCTAssertEqual(tiers[id], .act, id) }
        for id in ["memory.card.save", "memory.template.save", "memory.board.remove", "memory.flow.switch"] { XCTAssertEqual(tiers[id], .alter, id) }
        for id in ["memory.notes.list", "memory.template.read", "memory.topics.list", "memory.questions", "memory.handoffs"] { XCTAssertEqual(tiers[id], .read, id) }
    }
}
