import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct PROJAgentFixtureCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}
private actor PROJImportApprovals {
    var entries: [(String, NativeRPCValue, BackendMCPTier)] = []
    func record(_ tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) { entries.append((tool, arguments, tier)) }
}

@Suite("PROJ agents: projects, first install and approved imports", .madeUpProjects)
struct PROJAgentProjectsTests {
    private let names = ["crm-db", "diff-verifier", "portal-mechanic"]
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PROJ-agents-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    private func copiedCRM(in root: URL) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("PROJAgentFixtures")
        let folder = root.appendingPathComponent("crm-copy.noindex")
        let destination = folder.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names { try FileManager.default.copyItem(at: source.appendingPathComponent(name + ".md"), to: destination.appendingPathComponent(name + ".md")) }
        return folder
    }
    private func config(in root: URL, ownership: NativeStateStore.Ownership = .memory) async throws -> BackendTaskConfiguration {
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("records"), ownership: ownership))
        try await config.start()
        return config
    }
    private func row(_ id: String, folder: String? = nil) -> NativeRPCValue {
        var result = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(id)), .init("provider", .string("claude"))])
        if let folder { result = result.setting("defaultProject", .string(folder)) }
        return result
    }

    @Test func missingProjectsInferFromSourceBeforeLaunchFolderAndRespectBoundaries() throws {
        let cases: [(NativeRPCValue, String)] = [
            (row("a", folder: "/work/imatch"), "imatch"),
            (row("b", folder: "/work/imatch").setting("sourceDirectory", .string("/work/crm/.claude/agents")), "crm"),
            (row("c", folder: "/work/imatch-extra"), "independent"),
            (row("d", folder: "/work/imatch").setting("projectId", .string("independent")), "independent"),
            (row("e"), "independent")]
        for (input, expected) in cases {
            #expect(try BackendTaskConfiguration.cleanAgent(input, others: [])["projectId"].string == expected)
        }
    }

    @Test func explicitIndependentBatchIsPreservedOnResync() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copiedCRM(in: root), config = try await config(in: root)
        let result = try await config.importAgents(folder: folder.path, options: .object([.init("projectId", .string("independent"))]))
        #expect(result["imported"].number == 3 && result["errors"].elements?.isEmpty == true)
        _ = try await config.importAgents(folder: folder.path)
        for name in names { #expect(try await config.agent(name)?["projectId"].string == "independent") }
        try await config.stop()
    }

    @Test func perAgentOverrideKeepsOtherBatchMembersInCRM() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copiedCRM(in: root), config = try await config(in: root)
        let options: NativeRPCValue = .object([.init("projectId", .string("crm")), .init("agents", .object([
            .init("diff-verifier", .object([.init("projectId", .string("independent"))]))]))])
        let result = try await config.importAgents(folder: folder.path, options: options)
        #expect(result["errors"].elements?.isEmpty == true)
        #expect(try await config.agent("diff-verifier")?["projectId"].string == "independent")
        #expect(try await config.agent("crm-db")?["projectId"].string == "crm")
        #expect(try await config.agent("portal-mechanic")?["projectId"].string == "crm")
        try await config.stop()
    }

    @Test func invalidProjectChoicesCannotEnterImportOrProfile() throws {
        for id in ["", "CRM", "../crm", "crm project"] {
            #expect(throws: NativeRPCError.self) { try BackendTAGAgentImport.options(.object([.init("projectId", .string(id))])) }
        }
        #expect(throws: NativeRPCError.self) { try BackendTaskConfiguration.cleanAgent(row("bad").setting("projectId", .string("../crm")), others: []) }
    }

    @Test func registry128ByteProjectIDWorksForProfileAndImportedBatch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let projectID = "p" + String(repeating: "a", count: 127)
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try await registry.save(.init(id: projectID, name: "Long project", folders: ["/work/long-project"]))
        let cleaned = try BackendTaskConfiguration.cleanAgent(row("long-project-profile").setting("projectId", .string(projectID)), others: [])
        #expect(projectID.utf8.count == 128 && cleaned["projectId"].string == projectID)
        #expect(cleaned["projectIdInferred"].bool == false)
        let folder = try copiedCRM(in: root), config = try await config(in: root)
        let result = try await config.importAgents(folder: folder.path, options: .object([.init("projectId", .string(projectID))]))
        #expect(result["imported"].number == 3 && result["errors"].elements?.isEmpty == true)
        for name in names { #expect(try await config.agent(name)?["projectId"].string == projectID) }
        let tooLong = projectID + "a"
        #expect(throws: NativeRPCError.self) { try BackendTAGAgentImport.options(.object([.init("projectId", .string(tooLong))])) }
        #expect(throws: NativeRPCError.self) { try BackendTaskConfiguration.cleanAgent(row("too-long").setting("projectId", .string(tooLong)), others: []) }
        try await config.stop()
    }

    @Test func folderInferenceAndExplicitChoiceReachNativeModelsAndSavedDrafts() throws {
        let state = try #require(TasksDecode.state(["agents": [
            ["id": "legacy", "name": "Legacy", "defaultProject": "/work/imatch"],
            ["id": "separate", "name": "Separate", "defaultProject": "/work/crm", "projectId": "independent"]],
            "connections": [["keyId": "iloop", "folders": ["/work/crm"]]],
            "tasks": [["id": "task", "project": "/work/crm"]],
            "goals": [["id": "goal", "project": "/work/imatch"]]]))
        #expect(state.agents[0].projectID == "imatch" && state.agents[1].projectID == "independent")
        let saved = try AgentForm.payload(AgentDraft(state.agents[1]), agents: state.agents).get()
        #expect(saved.wire["projectId"] as? String == "independent")
        #expect(state.connections[0].projectID == "crm")
        #expect(try ConnectionForm.patch(ConnectionDraft(state.connections[0])).get().wire["projectId"] as? String == "crm")
        #expect(state.tasks[0].projectID == "crm" && state.tasks[0].projectId == "crm")
        #expect(!state.tasks[0].hasExplicitProjectID)
        #expect(!TaskRow(id: "blank", project: "/work/portal", projectID: " ").hasExplicitProjectID)
        #expect(!GoalRow(id: "blank", title: "Blank", project: "/work/portal", projectID: "").hasExplicitProjectID)
        #expect(TaskRow(id: "independent", project: "/work/imatch", projectID: "independent").hasExplicitProjectID)
        #expect(state.goals[0].projectID == "imatch")
        #expect(!state.goals[0].hasExplicitProjectID)
    }

    @Test func oneProjectCanHaveAgentsInTwoFoldersWithoutTwoGroups() {
        let profiles = [AgentProfile(id: "one", name: "One", defaultProject: "/first", projectID: "crm"),
            AgentProfile(id: "two", name: "Two", defaultProject: "/second", projectID: "crm"),
            AgentProfile(id: "separate", name: "Separate", projectID: "independent")]
        let agents = AGTDirectory.build(profiles: profiles.map(AGTProfileInput.init), live: [], tasks: [])
        let groups = AGTDirectory.groups(agents, by: .project)
        #expect(groups.first { $0.id == "project:crm" }?.agents.count == 2)
        #expect(groups.first { $0.id == "project:crm" }?.title == "CRM")
        #expect(groups.first { $0.id == "project:independent" }?.title == "Independent")
        #expect(agents.first { $0.id == "one" }?.wireValue["projectId"].string == "crm")
        let oldAndNew = AGTDirectory.build(profiles: [AGTProfileInput(id: "old", name: "Old", project: "/work/imatch"),
            AGTProfileInput(AgentProfile(id: "new", name: "New", defaultProject: "/work/imatch", projectID: "imatch"))], live: [], tasks: [])
        #expect(AGTDirectory.groups(oldAndNew, by: .project).first { $0.id == "project:imatch" }?.agents.count == 2)
    }

    @Test func legacyCustomFolderRemainsInferableWhileExplicitIndependentStaysSeparate() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"))
        _ = try await registry.save(.init(id: "portal", name: "Portal", folders: ["/work/portal"]))
        let legacy = try BackendTaskConfiguration.cleanAgent(row("legacy-custom", folder: "/work/portal"), others: [])
        let separate = try BackendTaskConfiguration.cleanAgent(row("independent-custom", folder: "/work/portal").setting("projectId", .string("independent")), others: [])
        #expect(legacy["projectId"].string == "independent" && legacy["projectIdInferred"].bool == true)
        #expect(separate["projectIdInferred"].bool == false)
        let resolved = try await registry.filter([legacy, separate], projectID: "portal", folderKey: "defaultProject")
        #expect(resolved.map { $0["id"].string } == ["legacy-custom"])
        #expect(resolved.first?["projectId"].string == "portal")
        let legacyValue = try #require(legacy.foundation)
        let state = try #require(TasksDecode.state(["agents": [legacyValue], "connections": []]))
        let draft = AgentDraft(state.agents[0])
        #expect(draft.projectID == nil && !state.agents[0].hasExplicitProjectID)
        let ordinaryEdit = try AgentForm.payload(draft, agents: state.agents).get()
        #expect(ordinaryEdit.wire["projectIdInferred"] as? Bool == true)
        let project = PROJProject(id: "portal", name: "Portal", folders: ["/work/portal"])
        let agents = AGTDirectory.build(profiles: [AGTProfileInput(state.agents[0]),
            AGTProfileInput(AgentProfile(id: "solo", name: "Solo", defaultProject: "/work/portal", projectID: "independent"))], live: [], tasks: [])
        let legacyAgent = try #require(agents.first { $0.id == "legacy-custom" })
        #expect(legacyAgent.projectID == nil)
        #expect(PROJProjects.resolve(projectID: legacyAgent.projectID, folder: legacyAgent.project, projects: PROJProjects.defaults + [project]) == "portal")
        let groups = AGTDirectory.groups(agents, by: .project, projects: PROJProjects.defaults + [project])
        #expect(groups.first { $0.id == "project:portal" }?.agents.count == 1)
        #expect(groups.first { $0.id == "project:independent" }?.agents.count == 1)
        let normalized = try BackendTAGAgentImport.options(.object([.init("projectId", .string("independent"))]))
        #expect(normalized["projectIdInferred"].bool == false)
        #expect(try BackendTAGAgentImport.options(normalized)["projectIdInferred"].bool == false)
        #expect(throws: NativeRPCError.self) { try BackendTAGAgentImport.options(.object([.init("projectIdInferred", .bool(true))])) }
    }

    @Test func canonicalAgentSettingsSaveKeepsProjectIdentity() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .memory)
        let config = try BackendTaskConfiguration(persistence: persistence), store = BackendAGSStore(persistence: persistence, cipher: PROJAgentFixtureCipher())
        try await config.start(); try await store.start(); try await config.bindAGS(store)
        _ = try await config.saveAgent(row("crm-agent", folder: "/work/crm").setting("projectId", .string("crm")))
        let revision = try await store.currentRevision()
        _ = try await config.saveSettingsForProfile("crm-agent", settings: .init(model: "sonnet"), expectedRevision: revision)
        #expect(try await config.agent("crm-agent")?["projectId"].string == "crm")
        try await config.stop()
    }

    @Test func actualMCPImportRetainsBatchProjectInApprovalAndProfiles() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try copiedCRM(in: root), config = try await config(in: root), approvals = PROJImportApprovals()
        let persistence = try BackendTaskPersistence(directory: root.appendingPathComponent("records"), ownership: .memory)
        let store = BackendTaskStore(persistence: persistence), goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await goals.start()
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] },
            start: { _, _, _, _, _ in throw NativeRPCError(code: "fixture", message: "No AI calls in project tests.") },
            send: { _, _ in throw NativeRPCError(code: "fixture", message: "No AI sends in project tests.") }, stop: { _ in },
            setControl: { _, _, _ in }, check: { _, _ in (true, "fixture") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access, workspace: { $0.project }, problem: { _ in })
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        let detail = BackendTaskDetailService(store: store, local: local, people: .native(configuration: config), problem: { _ in })
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil },
            post: { _, _ in throw NativeRPCError(code: "fixture", message: "No network in project tests.") }, onCommentID: { _, _ in }, problem: { _ in })
        let view = BackendTaskStateView(store: store, configuration: config, goals: goals, outbox: outbox, keyViews: { [] })
        let planning = BackendGoalPlanning(goals: goals, tasks: store, configuration: config, local: local, detail: detail)
        let server = BackendNativeMCPServer()
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true },
            project: { _, path in
                guard BackendTaskProjectScope.within(path, folder.path) else { throw NativeRPCError.invalidArguments("Outside copied fixture") }
            }, authorize: { _, tool, arguments, tier in await approvals.record(tool, arguments: arguments, tier: tier) }, actorName: { _ in "fixture" })
        _ = try await BackendTaskMCP.register(server: server, view: view, local: local, engine: engine, detail: detail, planning: planning, api: nil, authority: authority)
        let registrations = await server.registrations(), registration = try #require(registrations.first { $0.0.id == "tasks.agents_import" })
        let caller = BackendMCPCallContext(sessionID: "project-import-fixture", machineID: "fixture", projectRoot: folder.path,
            attended: true, allowedTools: Set(registrations.map { $0.0.id }), allowedTiers: [.read, .act, .alter], cancellation: BackendMCPCancellation())
        let arguments: NativeRPCValue = .object([.init("folder", .string(folder.path)), .init("options", .object([.init("projectId", .string("crm"))]))])
        let result = try #require(try await registration.1(caller, arguments).structuredContent)
        #expect(result["imported"].number == 3 && result["errors"].elements?.isEmpty == true)
        let captured = await approvals.entries
        #expect(captured.count == 1 && captured[0].0 == "tasks.agents_import" && captured[0].2 == .alter)
        #expect(captured[0].1["options"]["projectId"].string == "crm")
        for name in names { #expect(try await config.agent(name)?["projectId"].string == "crm") }
        try await config.stop(); try await store.stop(); try await goals.stop()
    }
}
