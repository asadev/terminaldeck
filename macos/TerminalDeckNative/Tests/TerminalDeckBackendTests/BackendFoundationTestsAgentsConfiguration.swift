import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendFoundationTestsAgentsClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Double = 0
    func set(_ value: Double) { lock.withLock { instant = value } }
    func now() -> Double { lock.withLock { instant } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        XCTFail("Agent settings must not schedule timers"); return UUID()
    }
    func cancel(_ handle: UUID) {}
}

final class BackendFoundationTestsAgentsConfiguration: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL, persistence: BackendTaskPersistence, configuration: BackendTaskConfiguration
        init(memory: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-task-agent-" + UUID().uuidString)
            persistence = try .init(directory: root.appendingPathComponent("remote"), ownership: memory ? .memory : .exclusive)
            configuration = try .init(persistence: persistence)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        var file: URL { persistence.directory.appendingPathComponent("agent-instructions/builder.md") }
        var settings: URL { persistence.directory.appendingPathComponent("task-config.json") }
    }
    private static func agent(_ additions: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        .object([.init("id", .string("builder")), .init("name", .string("Builder"))] + additions.map { .init($0.0, $0.1) })
    }
    private static func errorContains(_ fragment: String, operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected source refusal: " + fragment, file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(fragment), error.localizedDescription, file: file, line: line) }
    }
    // agent-instructions.test.ts:19. File content and owner permissions, not a
    // second implementation of InstructionsFiles in the test target.
    func testInstructionsAreWholePrivateFilesNamedByAgentID() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        let saved = try await f.configuration.saveAgent(Self.agent([("instructions", .string("Work on a branch.\nRun the tests."))]))
        XCTAssertEqual(saved["instructionsFile"].string, f.file.path)
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "Work on a branch.\nRun the tests.\n")
        let mode = try FileManager.default.attributesOfItem(atPath: f.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    // agent-instructions.test.ts:28
    func testBlankInstructionsRemoveTheFileAndMissingReadsAsNone() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        _ = try await f.configuration.saveAgent(Self.agent([("instructions", .string("x"))]))
        let saved = try await f.configuration.saveAgent(Self.agent([("instructions", .string("   "))]))
        XCTAssertEqual(saved["instructions"], .null); XCTAssertEqual(saved["instructionsFile"], .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
        let absent = try await f.configuration.agent("nobody"); XCTAssertNil(absent)
    }
    // agent-instructions.test.ts:43
    func testInstructionsOver32000CharactersAreRefused() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        await Self.errorContains("longer than") { _ = try await f.configuration.saveAgent(Self.agent([("instructions", .string(String(repeating: "x", count: 32_001)))])) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
    // agent-instructions.test.ts:47. External same-size edits are observable
    // without pretending native has the source's absent stat-cache API.
    func testOutsideEditorChangesAppearWithoutRestart() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        _ = try await f.configuration.saveAgent(Self.agent([("instructions", .string("First."))]))
        try Data("Second, from an editor.\n".utf8).write(to: f.file)
        let second = try await f.configuration.agent("builder"); XCTAssertEqual(second?["instructions"].string, "Second, from an editor.")
        try Data("Third, same size .....\n".utf8).write(to: f.file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: f.file.path)
        let third = try await f.configuration.agent("builder"); XCTAssertEqual(third?["instructions"].string, "Third, same size .....")
    }
    // agent-instructions.test.ts:63
    func testSettingsRestartOutsideEditAndClearUseOneInstructionFile() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        let saved = try await f.configuration.saveAgent(Self.agent([("provider", .string("claude")), ("instructions", .string("Work on a branch."))]))
        XCTAssertEqual(saved["instructions"].string, "Work on a branch."); XCTAssertEqual(saved["instructionsFile"].string, f.file.path)
        let stored = try NativeRPCValue.parseJSON(Data(contentsOf: f.settings)), row = try XCTUnwrap(stored["agents"].elements?.first)
        XCTAssertEqual(row["instructions"], .null); XCTAssertFalse(row.has("instructionsFile"))
        try Data("Work on a branch. Keep commits small.\n".utf8).write(to: f.file)
        let restored = try BackendTaskConfiguration(persistence: f.persistence); try await restored.start()
        let optionalChanged = try await restored.agent("builder")
        let changed = try XCTUnwrap(optionalChanged)
        XCTAssertEqual(changed["instructions"].string, "Work on a branch. Keep commits small."); XCTAssertEqual(changed["instructionsFile"].string, f.file.path)
        _ = try await restored.saveAgent(changed.setting("instructions", .null))
        let cleared = try await restored.agent("builder")
        XCTAssertEqual(cleared?["instructions"], .null); XCTAssertEqual(cleared?["instructionsFile"], .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
    // Expected parity failure: start() does not migrate old inline instructions.
    // agent-instructions.test.ts:82
    func testLegacyInlineInstructionsMigrateWithoutLosingConnections() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.persistence.write("task-config.json", value: .object([
            .init("v", .number(1)), .init("agents", .array([.object([.init("id", .string("old")), .init("name", .string("Old")), .init("instructions", .string("From before.")), .init("maxConcurrent", .number(1))])])),
            .init("connections", .array([.object([.init("keyId", .string("k1")), .init("name", .string("CRM"))])]))]))
        try await f.configuration.start()
        let old = try await f.configuration.agent("old")
        XCTAssertEqual(old?["instructions"].string, "From before."); XCTAssertEqual(old?["status"].string, "active"); XCTAssertEqual(old?["statusAt"], .null)
        let migratedFile = f.persistence.directory.appendingPathComponent("agent-instructions/old.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path))
        if FileManager.default.fileExists(atPath: migratedFile.path) { XCTAssertEqual(try String(contentsOf: migratedFile, encoding: .utf8), "From before.\n") }
        let stored = try NativeRPCValue.parseJSON(Data(contentsOf: f.settings))
        XCTAssertEqual(stored["agents"].elements?.first?["instructions"], .null)
        XCTAssertEqual(stored["connections"].elements?.first?["name"].string, "CRM")
    }
    // agent-instructions.test.ts:98
    func testRemovingAgentRemovesInstructionsAndRecreatedIDStartsBlank() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        _ = try await f.configuration.saveAgent(Self.agent([("instructions", .string("x"))])); try await f.configuration.removeAgent("builder")
        let recreated = try await f.configuration.saveAgent(Self.agent())
        XCTAssertEqual(recreated["instructions"], .null); XCTAssertEqual(recreated["instructionsFile"], .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
    }
    // agent-instructions.test.ts:105
    func testMemorySettingsHaveInstructionsWithoutPromisingAFile() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; try await f.configuration.start()
        let saved = try await f.configuration.saveAgent(Self.agent([("instructions", .string("x"))]))
        XCTAssertEqual(saved["instructions"].string, "x"); XCTAssertEqual(saved["instructionsFile"], .null)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
    }
    // agent-lifecycle.test.ts:19, via the real configuration owner and existing
    // TaskLocal clock seam. No wall-clock assumptions or sleeps.
    func testAllFourLifecycleActionsKeepExactChangeTimes() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; let clock = BackendFoundationTestsAgentsClock()
        try await BackendTaskClockContext.withClock(clock) {
            try await f.configuration.start(); _ = try await f.configuration.saveAgent(Self.agent())
            for (action, status, time) in [("pause", "paused", 100.0), ("resume", "active", 200.0), ("pause", "paused", 250.0), ("archive", "archived", 300.0), ("restore", "active", 400.0)] {
                clock.set(time); let result = try await f.configuration.setStatus("builder", action: action)
                XCTAssertEqual(result["status"].string, status); XCTAssertEqual(result["statusAt"].number, time)
            }
        }
    }
    // Expected parity failures: setStatus uses generic rather than source
    // agent-specific refusal sentences. agent-lifecycle.test.ts:27 and:96.
    func testInvalidLifecycleMovesKeepExactSourceRefusals() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; try await f.configuration.start()
        _ = try await f.configuration.saveAgent(Self.agent())
        await Self.errorContains("That agent no longer exists.") { _ = try await f.configuration.setStatus("ghost", action: "pause") }
        await Self.errorContains("Builder is not paused.") { _ = try await f.configuration.setStatus("builder", action: "resume") }
        await Self.errorContains("not something an agent can do") { _ = try await f.configuration.setStatus("builder", action: "delete") }
        _ = try await f.configuration.setStatus("builder", action: "archive")
        await Self.errorContains("Builder is archived. Restore it first.") { _ = try await f.configuration.setStatus("builder", action: "pause") }
        await Self.errorContains("Builder is already archived.") { _ = try await f.configuration.setStatus("builder", action: "archive") }
    }
    // agent-lifecycle.test.ts:60 persistence/time clauses. canDelegateTo is absent.
    func testPausedLifecycleSurvivesRestartThenResumesAtExactTime() async throws {
        let f = try Fixture(); defer { f.clean() }; let clock = BackendFoundationTestsAgentsClock()
        try await BackendTaskClockContext.withClock(clock) {
            try await f.configuration.start(); _ = try await f.configuration.saveAgent(Self.agent()); clock.set(1_000)
            let paused = try await f.configuration.setStatus("builder", action: "pause")
            XCTAssertEqual(paused["status"].string, "paused"); XCTAssertEqual(paused["statusAt"].number, 1_000)
            let restored = try BackendTaskConfiguration(persistence: f.persistence); try await restored.start()
            let state = try await restored.agent("builder"); XCTAssertEqual(state?["status"].string, "paused")
            clock.set(2_000); let active = try await restored.setStatus("builder", action: "resume")
            XCTAssertEqual(active["status"].string, "active"); XCTAssertEqual(active["statusAt"].number, 2_000)
        }
    }
    // agent-lifecycle.test.ts:71 retained-settings/identity clauses. The absent
    // pickableAgents API remains an explicitly counted clause in the handoff.
    func testArchiveKeepsInstructionsAndCRMIdentityAndCanRestore() async throws {
        let f = try Fixture(); defer { f.clean() }; try await f.configuration.start()
        _ = try await f.configuration.saveAgent(Self.agent([("instructions", .string("Keep it small."))]))
        _ = try await f.configuration.saveAgent(.object([.init("id", .string("tester")), .init("name", .string("Tester"))]))
        _ = try await f.configuration.saveConnection("k1", input: .object([.init("identities", .object([.init("u-builder", .string("builder"))]))]))
        _ = try await f.configuration.setStatus("builder", action: "archive")
        let all = try await f.configuration.allAgents(), archived = try await f.configuration.agent("builder"), connection = try await f.configuration.connection("k1")
        XCTAssertEqual(all.map { $0["id"].string }, ["builder", "tester"])
        XCTAssertEqual(archived?["status"].string, "archived"); XCTAssertEqual(archived?["instructions"].string, "Keep it small.")
        XCTAssertEqual(connection?["identities"], .object([.init("u-builder", .string("builder"))]))
        let restored = try await f.configuration.setStatus("builder", action: "restore"); XCTAssertEqual(restored["status"].string, "active")
    }
    // agent-lifecycle.test.ts:87
    func testSavingStaleFormDoesNotRestoreArchivedAgent() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; let clock = BackendFoundationTestsAgentsClock()
        try await BackendTaskClockContext.withClock(clock) {
            try await f.configuration.start(); let form = try await f.configuration.saveAgent(Self.agent()); clock.set(9)
            _ = try await f.configuration.setStatus("builder", action: "archive")
            let saved = try await f.configuration.saveAgent(form.setting("role", .string("reviewer")))
            XCTAssertEqual(saved["status"].string, "archived"); XCTAssertEqual(saved["statusAt"].number, 9); XCTAssertEqual(saved["role"].string, "reviewer")
            let created = try await f.configuration.saveAgent(.object([.init("id", .string("new")), .init("name", .string("New")), .init("status", .string("archived")), .init("statusAt", .number(1))]))
            XCTAssertEqual(created["status"].string, "active"); XCTAssertEqual(created["statusAt"], .null)
        }
    }
    // Expected parity failure: start() retains sleeping instead of normalizing
    // invalid status in memory while preserving the old bytes. lifecycle:103.
    func testInvalidStoredStatusFallsBackToActiveWithoutRewritingDisk() async throws {
        let f = try Fixture(); defer { f.clean() }
        let raw = #"{"v":1,"agents":[{"id":"odd","name":"Odd","status":"sleeping"}],"connections":[]}"#
        try f.persistence.writeBytes("task-config.json", data: Data(raw.utf8)); try await f.configuration.start()
        let odd = try await f.configuration.agent("odd")
        XCTAssertEqual(odd?["status"].string, "active"); XCTAssertEqual(odd?["statusAt"], .null)
        XCTAssertEqual(try String(contentsOf: f.settings, encoding: .utf8), raw)
    }
    // agent-briefing.test.ts:62
    func testOnlyClaudeCanSaveEnforcedToolOrSkillLimits() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; try await f.configuration.start()
        for provider in ["codex", "gemini", "custom:aider"] {
            await Self.errorContains("Only Claude Code") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string(provider)), ("blockedTools", .array([.string("Bash")]))])) }
            await Self.errorContains("Only Claude Code") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string(provider)), ("skillsOff", .bool(true))])) }
        }
        let defaultAgent = try await f.configuration.saveAgent(Self.agent([("provider", .null), ("blockedTools", .array([.string("Bash")]))]))
        XCTAssertEqual(defaultAgent["blockedTools"], .array([.string("Bash")]))
    }
    // Expected parity failures: native combines model/effort refusals and omits
    // the provider's label. agent-briefing.test.ts:71.
    func testUnsupportedModelAndEffortRefusalsKeepExactSourceWords() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; try await f.configuration.start()
        await Self.errorContains("Codex CLI cannot be given a model by this app. Clear it, or choose Claude Code.") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string("codex")), ("model", .string("gpt-5"))])) }
        await Self.errorContains("cannot be given an effort level") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string("gemini")), ("effort", .string("high"))])) }
        let saved = try await f.configuration.saveAgent(Self.agent([("provider", .string("claude")), ("model", .string("opus")), ("effort", .string("high"))]))
        XCTAssertEqual(saved["model"].string, "opus"); XCTAssertEqual(saved["effort"].string, "high")
    }
    // agent-briefing.test.ts:93 refusal clauses; pure stackText absent.
    func testShellRejectsInstructionAndToolAdviceWithSourceSentences() async throws {
        let f = try Fixture(memory: true); defer { f.clean() }; try await f.configuration.start()
        await Self.errorContains("cannot be given instructions") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string("shell")), ("instructions", .string("x"))])) }
        await Self.errorContains("tools to prefer or avoid") { _ = try await f.configuration.saveAgent(Self.agent([("provider", .string("shell")), ("toolsPreferred", .array([.string("Read")]))])) }
    }
}
