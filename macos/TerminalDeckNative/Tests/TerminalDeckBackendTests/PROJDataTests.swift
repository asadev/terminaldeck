import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct PROJDataNoAIEngine: BackendTaskExecuting {
    func accept(_ id: String) async throws { throw NativeRPCError(code: "fixture-no-ai", message: "No agent should run in this fixture.") }
    func reassign(_ id: String, assignee: NativeRPCValue) async throws { throw NativeRPCError(code: "fixture-no-ai", message: "No agent should run in this fixture.") }
    func reply(_ id: String, text: String) async throws { throw NativeRPCError(code: "fixture-no-ai", message: "No agent should run in this fixture.") }
    func cancel(_ id: String, reason: String) async throws { throw NativeRPCError(code: "fixture-no-ai", message: "No agent should run in this fixture.") }
}

final class PROJDataTests: PROJMadeUpTestCase {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-data-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    func testProjectSettingsKeepProjectsAndGlobalValuesSeparateAfterRestart() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = BackendAppSettingsStore(userData: folder, writable: true)
        _ = try await store.patch(.object([.init("appearance", .string("light"))]))
        _ = try await store.patchProject("imatch", values: .object([.init("answerStyle", .string("short"))]))
        _ = try await store.patchProject("crm", values: .object([.init("answerStyle", .string("detailed"))]))
        let reopened = BackendAppSettingsStore(userData: folder, writable: true)
        let imatch = await reopened.projectSettings("imatch"), crm = await reopened.projectSettings("crm"), global = await reopened.get()
        XCTAssertEqual(imatch["projectId"].string, "imatch")
        XCTAssertEqual(imatch["values"]["answerStyle"].string, "short")
        XCTAssertEqual(crm["values"]["answerStyle"].string, "detailed")
        XCTAssertEqual(global["values"]["appearance"].string, "light")
        XCTAssertTrue(global["values"]["answerStyle"].isNullish)
    }
    func testReadOnlySettingsDoNotCreateFilesAndFailedWriteDoesNotChangeCache() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = BackendAppSettingsStore(userData: folder)
        _ = await store.projectSettings("crm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("settings.json").path))
        do {
            _ = try await store.patchProject("crm", values: .object([.init("answerStyle", .string("changed"))]))
            XCTFail("A read-only owner accepted a settings change")
        } catch { }
        let unchanged = await store.projectSettings("crm")
        XCTAssertTrue(unchanged["values"]["answerStyle"].isNullish)
    }
    func testLegacyRoutineInfersFolderAndExplicitIndependentSurvivesSave() throws {
        let text = "# Check\nwhen: manual\nin: /work/imatch\n---\nHave a look.\n"
        let inferred = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: text).routine)
        XCTAssertEqual(inferred.projectID, "imatch")
        let independent = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: text.replacingOccurrences(of: "when: manual", with: "when: manual\nproject-id: independent")).routine)
        let reopened = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: BackendRoutinesFormat.serializeRoutine(independent)).routine)
        XCTAssertEqual(reopened.projectID, "independent")
        XCTAssertEqual(reopened.wire["projectId"].string, "independent")
    }
    func testRoutineDraftKeepsExplicitProjectID() throws {
        let draft = NativeRPCValue.object([.init("name", .string("Check")), .init("when", .array([.string("manual")])),
            .init("in", .string("/work/crm")), .init("prompt", .string("Have a look.")), .init("projectId", .string("independent"))])
        let routine = try XCTUnwrap(BackendRoutinesFormat.routineFromDraft("check", draft: draft).routine)
        XCTAssertEqual(routine.projectID, "independent")
    }
    func testReceiverSourcesLoadWithoutProjectAndKeepExplicitProject() throws {
        let source = RCVSource(id: "source", name: "CRM messages", preset: "custom", auth: .init(scheme: .none), mapping: .init(), projectID: "crm")
        let bytes = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(RCVSource.self, from: bytes).projectID, "crm")
        var old = try NativeRPCValue.parseJSON(bytes)
        old = old.removing("projectId")
        let legacy = try JSONDecoder().decode(RCVSource.self, from: old.encodedJSON())
        XCTAssertEqual(legacy.projectID, "independent")
    }
    func testLegacyArtifactRowsInheritListFolderButExplicitIndependentIsKept() throws {
        let value = NativeRPCValue.object([.init("root", .string("/work/imatch")),
            .init("artifacts", .array([.object([.init("relPath", .string("report.md"))]),
                .object([.init("relPath", .string("independent.md")), .init("projectId", .string("independent"))])]))])
        let result = try JSONDecoder().decode(ArtifactList.self, from: value.encodedJSON())
        XCTAssertEqual(result.projectID, "imatch")
        XCTAssertEqual(result.artifacts[0].projectID, "imatch")
        XCTAssertEqual(result.artifacts[1].projectID, "independent")
    }
    func testProjectSettingsMCPRefusalDoesNotWrite() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let registry = BackendPROJRegistry(fileURL: PROJMadeUp.seed(folder.appendingPathComponent("projects.json")))
        let settings = BackendAppSettingsStore(userData: folder, writable: true), server = BackendNativeMCPServer()
        try await BackendPROJSettings.register(server: server, registry: registry, settings: settings, ownerID: "proj-test", authorize: { _, _, _, tier in
            if tier != .read { throw NativeRPCError(code: "approval-denied", message: "The owner said no.") }
        })
        let rows = await server.registrations()
        let write = try XCTUnwrap(rows.first { $0.0.id == "project_settings.set" })
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["*"], allowedTiers: [.read, .alter], cancellation: BackendMCPCancellation())
        do {
            _ = try await write.1(caller, .object([.init("projectId", .string("crm")), .init("values", .object([.init("style", .string("new"))]))]))
            XCTFail("A refused settings change ran")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("settings.json").path))
    }
    func testProjectBoundSettingsCannotReadAnotherProject() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let registry = BackendPROJRegistry(fileURL: PROJMadeUp.seed(folder.appendingPathComponent("projects.json")))
        let server = BackendNativeMCPServer(), settings = BackendAppSettingsStore(userData: folder, writable: true)
        try await BackendPROJSettings.register(server: server, registry: registry, settings: settings, ownerID: "proj-test", authorize: { _, _, _, _ in })
        let registrations = await server.registrations()
        let read = try XCTUnwrap(registrations.first { $0.0.id == "project_settings.get" })
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: "/work/imatch", attended: true,
            allowedTools: ["*"], allowedTiers: [.read], cancellation: BackendMCPCancellation())
        do { _ = try await read.1(caller, .object([.init("projectId", .string("crm"))])); XCTFail("Cross-project settings were returned") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
    }
    func testTrustedIndependentSessionKeepsSettingsWhileWorkingInCRMFolder() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let registry = BackendPROJRegistry(fileURL: PROJMadeUp.seed(folder.appendingPathComponent("projects.json")))
        let server = BackendNativeMCPServer(), settings = BackendAppSettingsStore(userData: folder, writable: true)
        _ = try await settings.patchProject("independent", values: .object([.init("style", .string("short"))]))
        try await BackendPROJSettings.register(server: server, registry: registry, settings: settings, ownerID: "proj-test",
            authorize: { _, _, _, _ in }, projectIdentity: { _ in "independent" })
        let registrations = await server.registrations()
        let read = try XCTUnwrap(registrations.first { $0.0.id == "project_settings.get" })
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: "/work/crm", attended: true,
            allowedTools: ["*"], allowedTiers: [.read], cancellation: BackendMCPCancellation())
        let reply = try await read.1(caller, .object([.init("projectId", .string("independent"))]))
        XCTAssertEqual(reply.structuredContent?["values"]["style"].string, "short")
        do { _ = try await read.1(caller, .object([.init("projectId", .string("crm"))])); XCTFail("Working folder replaced explicit session ownership") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
    }
    func testLocalTaskExplicitProjectSurvivesFolderEditAndRestart() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = try BackendTaskPersistence(directory: folder, ownership: .exclusive)
        let store = BackendTaskStore(persistence: persistence), config = try BackendTaskConfiguration(persistence: persistence)
        let goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await config.start(); try await goals.start()
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: PROJDataNoAIEngine())
        let made = try await local.create(.object([.init("title", .string("Finished fixture")), .init("status", .string("Done")),
            .init("project", .string("/work/crm")), .init("projectId", .string("independent"))]))
        XCTAssertEqual(made.value["projectId"].string, "independent")
        let changed = try await local.update(made.id, input: .object([.init("project", .string("/work/imatch"))]))
        XCTAssertEqual(changed.value["projectId"].string, "independent")
        _ = try await local.update(made.id, input: .object([.init("projectId", .string("research"))]))
        let reopened = BackendTaskStore(persistence: persistence); try await reopened.start()
        let saved = try await reopened.byID(made.id)
        XCTAssertEqual(saved?.value["projectId"].string, "research")
        XCTAssertEqual(saved?.project, "/work/imatch")
        try await config.stop()
    }
    func testLocalTaskInvalidProjectDoesNotWriteAndMissingProjectStaysInferable() async throws {
        let folder = try scratch(); defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = try BackendTaskPersistence(directory: folder, ownership: .memory)
        let store = BackendTaskStore(persistence: persistence), config = try BackendTaskConfiguration(persistence: persistence)
        let goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await config.start(); try await goals.start()
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: PROJDataNoAIEngine())
        let input = NativeRPCValue.object([.init("title", .string("Finished fixture")), .init("status", .string("Done")), .init("project", .string("/work/crm"))])
        do { _ = try await local.create(input.setting("projectId", .string("../crm"))); XCTFail("Invalid project entered the task store") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "invalid-arguments") }
        let refused = try await store.all(); XCTAssertTrue(refused.isEmpty)
        let legacy = try await local.create(input)
        XCTAssertTrue(legacy.value["projectId"].isNullish)
        XCTAssertEqual(PROJProjects.resolve(projectID: legacy.value["projectId"].string, folder: legacy.project), "crm")
        try await config.stop()
    }
}
