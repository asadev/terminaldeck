import Foundation
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor PROJAuditEventSink {
    private var rows: [NativeRPCEvent] = []
    func accept(_ event: NativeRPCEvent) { rows.append(event) }
    func values() -> [NativeRPCEvent] { rows }
}

private struct PROJAuditTranscriptSource: BackendArtifactsTranscriptSource {
    let file: NativeTranscriptFile
    func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] { [file] }
    func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String { file.path }
}

final class PROJAuditRegressionsTests: PROJMadeUpTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-audit-" + UUID().uuidString + ".noindex").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testFullRegistryIDSurvivesRoutineDraftAndInvalidIDsNeverChangeIdentity() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")))
        let id = String(repeating: "x", count: 128)
        XCTAssertTrue(PROJProjects.isValidID(id))
        _ = try await projects.save(.init(id: id, name: "Long id", folders: ["/work/long-id"]))
        let draft = NativeRPCValue.object([.init("name", .string("Check")), .init("when", .array([.string("manual")])),
            .init("in", .string("/work/long-id")), .init("prompt", .string("Look at the fixture.")), .init("projectId", .string(id))])
        let routine = try XCTUnwrap(BackendRoutinesFormat.routineFromDraft("check", draft: draft).routine)
        XCTAssertEqual(routine.projectID, id)
        let loaded = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: BackendRoutinesFormat.serializeRoutine(routine)).routine)
        XCTAssertEqual(loaded.projectID, id)
        for invalid in ["line\nbreak", "bad\tid", "line\u{2028}break", "Capital", "bad_id", "-leading", String(repeating: "x", count: 129)] {
            XCTAssertFalse(PROJProjects.isValidID(invalid))
            do { _ = try await projects.save(.init(id: invalid, name: "Invalid")); XCTFail("Invalid registry id was saved") } catch {}
            XCTAssertNil(BackendRoutinesFormat.routineFromDraft("check", draft: draft.setting("projectId", .string(invalid))).routine)
        }
        let rows = try await projects.projects(); XCTAssertEqual(rows.count, 4)
    }

    func testLegacyServerStartFolderUsesCurrentRegistryButExplicitIndependentWins() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")))
        _ = try await projects.save(.init(id: "workspace", name: "Workspace", folders: ["/work/server-repo"]))
        let legacy = NativeRPCValue.object([.init("id", .string("legacy-server")), .init("projectIdInferred", .bool(true)),
            .init("projectId", .string("independent")), .init("startIn", .string("/work/server-repo/sub"))])
        let scoped = try await projects.filter([legacy], projectID: "workspace")
        XCTAssertEqual(scoped.count, 1); XCTAssertEqual(scoped.first?["projectId"].string, "workspace")
        let explicit = legacy.setting("projectIdInferred", .bool(false))
        let solo = try await projects.filter([explicit], projectID: "independent")
        XCTAssertEqual(solo.count, 1); XCTAssertEqual(solo.first?["projectId"].string, "independent")
    }

    func testCustomSessionWireKeepsIndependentAndMarksLegacyInference() throws {
        var input = BackendCreateSessionInput(cwd: "/work/crm", provider: "shell")
        let spawn = BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin")
        let legacy = BackendCompositionSuppliers.sessionWire(.init(id: "legacy", input: input, spawn: spawn))
        XCTAssertEqual(legacy["projectId"].string, "crm"); XCTAssertEqual(legacy["projectIdInferred"].bool, true)
        input.projectId = "independent"
        let explicit = BackendCompositionSuppliers.sessionWire(.init(id: "explicit", input: input, spawn: spawn))
        XCTAssertEqual(explicit["projectId"].string, "independent"); XCTAssertEqual(explicit["projectIdInferred"].bool, false)
        input.projectId = "  "
        let blank = BackendCompositionSuppliers.sessionWire(.init(id: "blank", input: input, spawn: spawn))
        XCTAssertEqual(blank["projectId"].string, "crm"); XCTAssertEqual(blank["projectIdInferred"].bool, true)
    }

    func testProjectFilterKeepsAllowedIndependentRowInsideBoundCRMFolder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")))
        let tools = try BackendPROJMCP.contribution(registry: projects, authorize: { _, _, _, _ in }, resources: { kind, project, caller in
            guard kind == "tasks", project == "independent", caller.projectRoot == "/work/crm" else { throw NativeRPCError.invalidArguments("Wrong source scope") }
            return [.object([.init("id", .string("allowed-task")), .init("projectId", .string("independent")),
                             .init("project", .string("/work/crm"))])]
        })
        let tool = try XCTUnwrap(tools.first { $0.0.id == "project_registry.filter" })
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: "/work/crm", attended: true,
                                          allowedTools: ["project_registry.filter", "tasks.list"], allowedTiers: [.read], cancellation: .init())
        let reply = try await tool.1(caller, .object([.init("kind", .string("tasks")), .init("projectId", .string("independent"))]))
        XCTAssertEqual(reply.structuredContent?["rows"].elements?.count, 1)
        XCTAssertEqual(reply.structuredContent?["rows"].elements?.first?["projectId"].string, "independent")
    }

    func testRegistryChangeBroadcastReachesTheNativeAppSubscriberOwner() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let channels = NativeChannelRegistry(), app = PROJAuditEventSink(), other = PROJAuditEventSink()
        let appSubscription = try await channels.subscribeAll(ownerID: BackendCompositionRoot.appOwnerID) { await app.accept($0) }
        let otherSubscription = try await channels.subscribeAll(ownerID: "owned-test-preview") { await other.accept($0) }
        let projects = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")), changed: {
            try? await channels.publish("project-registry:changed", arguments: [$0])
        })
        _ = try await projects.select("crm")
        let appEvents = await app.values(), otherEvents = await other.values()
        XCTAssertEqual(appEvents.count, 1); XCTAssertEqual(otherEvents.count, 1)
        XCTAssertEqual(appEvents.first?.channel, "project-registry:changed")
        XCTAssertEqual(appEvents.first?.arguments.first?["activeProjectId"].string, "crm")
        await appSubscription.cancelAndWait(); await otherSubscription.cancelAndWait(); await channels.shutdown()
    }

    func testNativeArtifactChannelsPreserveLiveRegistryIDAndApplyExplicitOverrideToEveryRow() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("custom-project"), transcript = root.appendingPathComponent("fixture.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("report.md")
        let line = NativeRPCValue.object([.init("timestamp", .string(ISO8601DateFormatter().string(from: Date()))),
            .init("message", .object([.init("content", .array([.object([.init("type", .string("tool_use")), .init("name", .string("Write")),
                .init("input", .object([.init("file_path", .string(file.path)), .init("content", .string("fixture text"))]))])]))]))])
        var bytes = try line.encodedJSON(); bytes.append(10); try bytes.write(to: transcript)
        let stamp = Date().timeIntervalSince1970 * 1000
        let source = PROJAuditTranscriptSource(file: .init(path: transcript.path, sessionID: "fixture-session", createdAt: stamp, modifiedAt: stamp, bytes: Int64(bytes.count)))
        let authority = BackendFilesystemAuthority(scope: { _ in .local })
        let index = BackendArtifactsIndex(source: source, authority: authority)
        let identities = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")))
        _ = try await identities.save(.init(id: "custom", name: "Custom", folders: [folder.path]))
        await index.bindProjectResolver { try await identities.resolve(projectID: nil, folder: $0) }
        let state = NativeStateStore(); _ = try await state.addProject(folder.path)
        let folders = try BackendProjectService(store: state, files: .init(authority: authority), home: root.path,
                                               appDataRoot: root.appendingPathComponent("state"), liveSessions: { [] })
        let channels = NativeChannelRegistry()
        _ = try await BackendArtifactsChannels.register(registry: channels, ownerID: "proj-artifacts-test", artifacts: index, projects: folders)
        let context = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        let request = NativeRPCValue.object([.init("cwd", .string(folder.path))])
        let listed = try await channels.invoke("artifacts:list", context: context, arguments: [request])
        XCTAssertEqual(listed["projectId"].string, "custom")
        XCTAssertEqual(listed["artifacts"].elements?.count, 1)
        XCTAssertEqual(listed["sessions"].elements?.count, 1)
        for key in ["artifacts", "sessions"] { XCTAssertTrue(listed[key].elements?.allSatisfy { $0["projectId"].string == "custom" } ?? false) }
        let explicit = try await channels.invoke("artifacts:list", context: context, arguments: [request.setting("projectId", .string("independent"))])
        XCTAssertEqual(explicit["projectId"].string, "independent")
        for key in ["artifacts", "sessions"] { XCTAssertTrue(explicit[key].elements?.allSatisfy { $0["projectId"].string == "independent" } ?? false) }
        let changes = try await channels.invoke("artifacts:changes", context: context, arguments: [request.setting("relPath", .string("report.md")).setting("projectId", .string("independent"))])
        XCTAssertEqual(changes["changes"].elements?.count, 1)
        XCTAssertEqual(changes["projectId"].string, "independent")
        XCTAssertTrue(changes["changes"].elements?.allSatisfy { $0["projectId"].string == "independent" } ?? false)
        await channels.shutdown(); await index.stop(); await state.close()
    }

    func testLegacyRoutineUnderKnownFolderIsReinferredForDeeperRegisteredProject() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Check\nwhen: manual\nin: /work/imatch/nested/src\n---\nLook at the fixture.\n"
        let old = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: source).routine)
        XCTAssertEqual(old.projectID, "imatch"); XCTAssertTrue(old.projectIdInferred)
        XCTAssertFalse(BackendRoutinesFormat.serializeRoutine(old).contains("project-id:"))
        let projects = BackendPROJRegistry(fileURL: PROJMadeUp.seed(root.appendingPathComponent("projects.json")))
        _ = try await projects.save(.init(id: "nested", name: "Nested", folders: ["/work/imatch/nested"]))
        let rows = try await projects.filter([old.wire], projectID: "nested")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["projectId"].string, "nested")
        let explicit = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: source.replacingOccurrences(of: "when: manual", with: "when: manual\nproject-id: independent")).routine)
        XCTAssertFalse(explicit.projectIdInferred)
        let roundTrip = try XCTUnwrap(BackendRoutinesFormat.parseRoutine("check", text: BackendRoutinesFormat.serializeRoutine(explicit)).routine)
        XCTAssertEqual(roundTrip.projectID, "independent"); XCTAssertFalse(roundTrip.projectIdInferred)
    }
}
