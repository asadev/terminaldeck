import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("TAG agent profiles and real Claude definitions")
struct TAGProfilesTests {
    private func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(pairs) }
    private func profile(_ id: String, _ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        object([("id", .string(id)), ("name", .string(id)), ("provider", .string("claude"))] + pairs)
    }
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TAG-profiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func definition(_ name: String, tools: String = "Read, Grep", description: String = "Checks work") -> String {
        "---\nname: \(name)\ndescription: \(description)\nmodel: opus\ntools: \(tools)\n---\n\n# One Claude identity\n"
    }

    @Test func fiftyAgentsAndUpdatesAtCapacity() async throws {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/TAG-memory"), ownership: .memory))
        try await config.start()
        for index in 1...50 { _ = try await config.saveAgent(profile("agent-\(index)")) }
        #expect(try await config.allAgents().count == 50)
        _ = try await config.saveAgent(profile("agent-50", [("role", .string("Updated at capacity"))]))
        do { _ = try await config.saveAgent(profile("agent-51")); Issue.record("A 51st agent was accepted") }
        catch { #expect(error.localizedDescription.contains("at most 50")) }
    }

    @Test func oldProfilesKeepTimedDefaultsAndOptionalFields() throws {
        let clean = try BackendTaskConfiguration.cleanAgent(profile("legacy"), others: [])
        #expect(clean["allowedTools"].isNullish)
        #expect(clean["permissionMode"].isNullish)
        #expect(clean["claudeAgent"].isNullish)
        #expect(clean["keepAliveUntilClose"].bool == false)
        #expect(clean["keepAliveMinutes"].number == 30)
    }

    @Test func staleKeySaveCannotRemoveANewerOwnerBlock() async throws {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/TAG-memory"), ownership: .memory))
        try await config.start()
        let stale = try await config.saveAgent(profile("inspector", [("blockedTools", .array([.string("Edit")]))]))
        _ = try await config.saveAgent(stale.setting("blockedTools", .array([.string("Edit"), .string("Write")])))
        do { _ = try await config.saveAgentNarrowed(stale.setting("role", .string("Stale unrelated edit"))); Issue.record("A stale key save removed the owner block") }
        catch { #expect(error.localizedDescription.contains("Removing the Write block")) }
        #expect(try await config.agent("inspector")?["blockedTools"].elements == [.string("Edit"), .string("Write")])
        _ = try await config.saveAgentNarrowed(object([("id", .string("inspector")), ("skillsOff", .bool(true))]))
        #expect(try await config.agent("inspector")?["skillsOff"].bool == true)
    }

    @Test func profileSettingsPreserveEmptyAllowListAndMinuteCap() throws {
        let clean = try BackendTaskConfiguration.cleanAgent(profile("inspector", [
            ("allowedTools", .array([])), ("permissionMode", .string("plan")), ("claudeAgent", .string("inspector")),
            ("keepAliveUntilClose", .bool(true)), ("keepAliveMinutes", .number(1440)),
            ("defaultProject", .string("/work/app/../project")), ("reviewerAgent", .string("critic"))]), others: [])
        #expect(clean["allowedTools"].elements == [])
        #expect(clean["keepAliveUntilClose"].bool == true)
        #expect(clean["defaultProject"].string == "/work/project")
        #expect(clean["reviewerAgent"].string == "critic")
        let invalid: [[(String, NativeRPCValue)]] = [
            [("keepAliveMinutes", .number(1441))], [("permissionMode", .string("auto"))],
            [("defaultProject", .string("relative"))], [("allowedTools", .array([.string("bad tool")]))]]
        for pairs in invalid {
            do { _ = try BackendTaskConfiguration.cleanAgent(profile("invalid", pairs), others: []); Issue.record("Invalid setting was accepted") } catch {}
        }
    }

    @Test func threeCopiedCommanderDefinitionsImportWithoutBodyIdentity() throws {
        let fixtures = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("TAGAgentFixtures")
        for name in ["inspector", "critic", "db-surgeon"] {
            let definition = try #require(try BackendTAGAgentImport.read(fixtures.appendingPathComponent(name + ".md")))
            #expect(definition.name == name)
            #expect(definition.description.count > 60)
            #expect(definition.model != nil)
            #expect(definition.tools?.contains("Bash") == true)
            let clean = try BackendTaskConfiguration.cleanAgent(definition.profile, others: [])
            #expect(clean["claudeAgent"].string == name)
            #expect(clean["instructions"].isNullish)
            #expect(clean["role"].string == definition.description)
        }
    }

    @Test func frontmatterListsQuotesAndFoldedDescriptions() throws {
        let parsed = try #require(try BackendTAGAgentImport.parse("""
        ---
        name: inspector
        description: >-
          First line of the role.
          Second line of the role.
        model: inherit
        tools:
          - Read
          - 'mcp__deck-control__browser_read'
        ---
        Ignored body
        """))
        #expect(parsed.description == "First line of the role. Second line of the role.")
        #expect(parsed.model == nil)
        #expect(parsed.tools == ["Read", "mcp__deck-control__browser_read"])
        #expect(try BackendTAGAgentImport.parse("# Folder README") == nil)
        #expect(try BackendTAGAgentImport.parse(definition("none", tools: "[]"))?.tools == [])
    }

    @Test func diskImportUpdatesAndKeepsOwnerRestrictions() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), folder = project.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("inspector.md")
        try Data(definition("inspector", tools: "Read, Grep, Edit").utf8).write(to: file)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await config.start()
        do {
            let first = try await config.importAgents(folder: project.path, narrowOnly: true)
            #expect(first["imported"].number == 1)
            var saved = try #require(try await config.agent("inspector"))
            let importedPath = try #require(saved["sourceFile"].string)
            let importedAttributes = try FileManager.default.attributesOfItem(atPath: importedPath)
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let importedFileID = try #require(importedAttributes[.systemFileNumber] as? NSNumber)
            let sourceFileID = try #require(sourceAttributes[.systemFileNumber] as? NSNumber)
            let importedVolumeID = try #require(importedAttributes[.systemNumber] as? NSNumber)
            let sourceVolumeID = try #require(sourceAttributes[.systemNumber] as? NSNumber)
            #expect(importedFileID == sourceFileID && importedVolumeID == sourceVolumeID)
            #expect(saved["defaultProject"].string == project.path)
            saved = saved.setting("blockedTools", .array([.string("Edit")])).setting("skillsOff", .bool(true))
                .setting("allowedTools", .array([.string("Read")])).setting("permissionMode", .string("plan"))
                .setting("keepAliveMinutes", .number(5)).setting("reviewerAgent", .string("critic"))
            _ = try await config.saveAgent(saved)
            try Data(definition("inspector", tools: "Read, Write, Bash", description: "Changed role").utf8).write(to: file)
            let result = try await config.importAgents(folder: folder.path, narrowOnly: true)
            #expect(result["updated"].number == 1)
            #expect(result["errors"].elements?.isEmpty == true)
            let synced = try #require(try await config.agent("inspector"))
            #expect(synced["allowedTools"].elements == [.string("Read")])
            #expect(synced["blockedTools"].elements == [.string("Edit")])
            #expect(synced["skillsOff"].bool == true)
            #expect(synced["permissionMode"].string == "plan")
            #expect(synced["keepAliveMinutes"].number == 5)
            #expect(synced["reviewerAgent"].string == "critic")
            #expect(synced["role"].string == "Changed role")
            try await config.stop()
            try Data(definition("inspector", tools: "Read, Write", description: "Changed while app was closed").utf8).write(to: file)
            let reloaded = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
            try await reloaded.start()
            try await reloaded.startImportWatchers()
            #expect(try await reloaded.agent("inspector")?["claudeAgent"].string == "inspector")
            #expect(try await reloaded.agent("inspector")?["permissionMode"].string == "plan")
            #expect(try await reloaded.agent("inspector")?["role"].string == "Changed while app was closed")
            #expect(try await reloaded.agent("inspector")?["allowedTools"].elements == [.string("Read")])
            try await reloaded.stop()
        } catch { await config.stopImportWatchers(); throw error }
    }

    @Test func watcherResyncsAnEditedDefinitionWithoutPollingService() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("inspector.md")
        try Data(definition("inspector").utf8).write(to: file)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await config.start()
        do {
            _ = try await config.importAgents(folder: folder.path)
            try Data(definition("inspector", tools: "Read", description: "Changed by filesystem event").utf8).write(to: file, options: .atomic)
            // Only the test observes the result; production relies on FSEvents.
            var observed = false
            for _ in 0..<150 {
                if try await config.agent("inspector")?["role"].string == "Changed by filesystem event" { observed = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(observed)
            #expect(try await config.agent("inspector")?["syncStatus"].string == "synced")
            try await config.stop()
        } catch { await config.stopImportWatchers(); throw error }
    }

    @Test func missingAndMalformedSourcesKeepLastGoodProfile() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("inspector.md")
        try Data(definition("inspector").utf8).write(to: file)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await config.start()
        do {
            _ = try await config.importAgents(folder: folder.path)
            await config.stopImportWatchers()
            try Data("---\nname: inspector\n".utf8).write(to: file)
            #expect(try await config.importAgents(folder: folder.path)["errors"].elements?.count == 1)
            #expect(try await config.agent("inspector")?["syncStatus"].string == "error")
            #expect(try await config.agent("inspector")?["role"].string == "Checks work")
            try FileManager.default.removeItem(at: file)
            _ = try await config.importAgents(folder: folder.path)
            #expect(try await config.agent("inspector")?["syncStatus"].string == "missing")
            #expect(try await config.agent("inspector") != nil)
            try await config.stop()
        } catch { await config.stopImportWatchers(); throw error }
    }

    @Test func launcherKeepsOneIdentityAndDenyFollowsAllow() async throws {
        var input = BackendCreateSessionInput(cwd: "/work/project", provider: "claude")
        input.claudeAgent = "inspector"; input.agentInstructions = "must-not-read"
        input.allowedTools = ["Read", "Edit", "mcp__deck-control__browser_read"]
        input.deniedTools = ["Edit", "mcp__deck-control__browser_read"]
        input.permissionMode = "plan"
        let launcher = try BackendNativeInstructions(storageRoot: URL(fileURLWithPath: "/TAG-empty"))
        let args = try await launcher.arguments(input, provider: .init(id: "claude", command: "claude", args: [], resumeArgs: []), context: .init())
        #expect(Array(args.prefix(2)) == ["--agent", "inspector"])
        #expect(!args.contains("--append-system-prompt-file"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args[try #require(args.firstIndex(of: "--tools")) + 1] == "Read,Edit")
        let denyIndex = try #require(args.firstIndex(of: "--disallowedTools")), allowIndex = try #require(args.firstIndex(of: "--allowedTools"))
        #expect(denyIndex > allowIndex)
        #expect(args[try #require(args.firstIndex(of: "--permission-mode")) + 1] == "plan")
    }

    @Test func explicitDefaultAndEmptyToolsAreRealLaunchSettings() throws {
        var input = BackendCreateSessionInput(cwd: "/work/project", provider: "claude")
        input.permissionMode = "default"; input.allowedTools = []
        input.taskID = "local:retained-task"
        input.taskProject = "/work/project"
        let args = try BackendTAGLaunchArguments.arguments(input, provider: "claude")
        #expect(Array(args.prefix(2)) == ["--tools", ""])
        #expect(!args.contains("--permission-mode"))
        #expect(BackendTAGLaunchArguments.removingPermissionOverride(["--permission-mode", "bypassPermissions", "--continue", "--permission-mode=acceptEdits", "--dangerously-skip-permissions"]) == ["--continue"])
        let saved = try BackendSessionSaved(BackendSessionSaved.from(input))
        #expect(saved.input(resume: true).allowedTools == [])
        #expect(saved.input(resume: true).permissionMode == "default")
        #expect(saved.input(resume: true).taskID == "local:retained-task")
        #expect(saved.input(resume: true).taskProject == "/work/project")
    }

    @Test func importedIdentityLaunchesFromAnUnrelatedFolder() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("source-project"), source = project.appendingPathComponent(".claude/agents/inspector.md")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(definition("inspector").utf8).write(to: source)
        let remote = root.appendingPathComponent("remote"), specs = try BackendTaskPersistence(directory: remote.appendingPathComponent("task-briefs"), ownership: .exclusive)
        let agent = profile("inspector", [("claudeAgent", .string("inspector")), ("sourceFile", .string(source.path)), ("allowedTools", .array([.string("Read")]))])
        let file = try #require(try BackendTAGAgentDefinitionLaunch.prepare(agent: agent, specs: specs))
        var input = BackendCreateSessionInput(cwd: "/an/unrelated/isolated/workspace", provider: "claude")
        input.claudeAgent = "inspector"; input.agentDefinitionsFile = file; input.agentInstructions = "must-not-read"
        input.allowedTools = ["Read"]; input.taskID = "local:worker"
        let args = try await BackendNativeInstructions(storageRoot: remote).arguments(input, provider: .init(id: "claude", command: "claude", args: [], resumeArgs: []), context: .init())
        let encoded = args[try #require(args.firstIndex(of: "--agents")) + 1]
        let custom = try NativeRPCValue.parseJSON(Data(encoded.utf8))
        #expect(custom["inspector"]["prompt"].string?.contains("# One Claude identity") == true)
        #expect(custom["inspector"]["prompt"].string?.contains(project.path) == true)
        #expect(custom["inspector"]["tools"].elements == [.string("Read")])
        #expect(args[try #require(args.firstIndex(of: "--agent")) + 1] == "inspector")
        #expect(!args.contains("--append-system-prompt-file"))
        #expect(try BackendSessionSaved(BackendSessionSaved.from(input)).input(resume: true).agentDefinitionsFile == file)
        #expect(try String(contentsOf: source, encoding: .utf8) == definition("inspector"))
    }

    @Test func mcpGrantsNarrowAndDenyWinsForServerGroups() {
        let names: Set<String> = ["browser.read", "browser_read", "browser.open", "browser_open"]
        let one = BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: ["mcp__deck-control__browser_read"], denied: [])
        #expect(one == ["browser.read", "browser_read"])
        #expect(BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: [], denied: []).isEmpty)
        #expect(BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: ["mcp__deck-control"], denied: ["mcp__deck-control__browser_read"]) == ["browser.open", "browser_open"])
        #expect(BackendTAGToolPolicy.filter(names, server: "deck-control", allowed: ["mcp__deck-control__browser_read"], denied: ["mcp__deck-control"]).isEmpty)
        #expect(!BackendTAGToolPolicy.sessionNames(taskID: nil).contains("tasks.delegate"))
        let worker = BackendTAGToolPolicy.sessionNames(taskID: "local:worker")
        #expect(worker.contains("tasks.delegate"))
        #expect(worker.contains("tasks_review"))
        #expect(BackendTAGToolPolicy.filter(worker, server: "deck-control", allowed: ["Read"], denied: []).isEmpty)
        #expect(BackendTAGToolPolicy.filter(worker, server: "deck-control", allowed: ["mcp__deck-control__tasks_delegate"], denied: []) == ["tasks.delegate", "tasks_delegate"])
        #expect(BackendTAGToolPolicy.intersection(["mcp__deck-control"], ["mcp__deck-control__tasks_delegate"]) == ["mcp__deck-control__tasks_delegate"])
        #expect(BackendTAGToolPolicy.intersection(["mcp__deck-control__tasks_delegate"], ["mcp__deck-control"]) == ["mcp__deck-control__tasks_delegate"])
        #expect(!BackendTAGToolPolicy.covers("mcp__deck-control__tasks_delegate", tool: "mcp__deck-control"))
    }

    @Test func actualTaskLeaseRegistersOnlyPermittedTaskTools() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["browser.read", "tasks.delegate", "tasks.review", "tasks.verify"]
        let specs = try names.map { try BackendMCPTool(id: $0, wireName: $0.replacingOccurrences(of: ".", with: "_"), description: "TAG test registered tool", inputSchema: .object([]), tier: .act) }
        let endpoint = BackendDeckToolsSessionsPortEndpoint(specs: specs)
        let leases = try BackendSessionToolLeases(endpoint: endpoint, userData: root, clock: BackendDeckToolsSessionsPortScheduler(0))
        do {
            let ordinary = try #require(try await leases.prepareOrdinary(restricting: nil, deniedTools: []))
            #expect(try #require(await endpoint.snapshot().first).grant.allowedTools == ["browser.read", "browser_read"])
            await leases.abandon(ordinary.id)
            let worker = try #require(try await leases.prepareOrdinary(restricting: ["mcp__deck-control__tasks_delegate", "mcp__deck-control__tasks_review"], deniedTools: ["mcp__deck-control__tasks_review"], taskID: "local:parent", taskProject: "/work/project"))
            try await leases.bind(worker.id, sessionID: "worker-session")
            let registered = try #require(await endpoint.snapshot().first)
            #expect(registered.grant.allowedTools == ["tasks.delegate", "tasks_delegate"])
            #expect(registered.session == "worker-session")
            #expect(registered.grant.projectRoot == "/work/project")
            #expect(registered.grant.taskProject == "/work/project")
            await leases.release(sessionID: "worker-session")
            #expect(try await leases.prepareOrdinary(restricting: [], deniedTools: [], taskID: "local:parent") == nil)
            #expect(await endpoint.snapshot().isEmpty)
            await leases.stop()
        } catch { await leases.stop(); throw error }
    }

    @Test func taskProjectLeaseKeepsWorkspaceAndOriginalProjectWithoutWideningOrdinarySessions() throws {
        let original = "/work/project", workspace = "/work/isolated-workspace"
        let task = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "worker", projectRoot: original, taskProject: original)
        #expect(try BackendTAGTaskProjectScope.folders(openProjects: [original, "/work/other"], caller: task, cwd: workspace) == [original, workspace])
        #expect(BackendTAGTaskProjectScope.isOwnedWorkspace(workspace, caller: task, cwd: workspace))
        #expect(!BackendTAGTaskProjectScope.isOwnedWorkspace("/work/other", caller: task, cwd: workspace))
        let ordinary = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "ordinary", projectRoot: original)
        #expect(try BackendTAGTaskProjectScope.folders(openProjects: [original, "/work/other"], caller: ordinary, cwd: workspace) == [original])
        #expect(!BackendTAGTaskProjectScope.isOwnedWorkspace(workspace, caller: ordinary, cwd: workspace))
        let forged = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "worker", projectRoot: original, taskProject: "/work/other")
        do { _ = try BackendTAGTaskProjectScope.roots(caller: forged, cwd: workspace); Issue.record("Mismatched task project was accepted") } catch {}
    }

    @Test func defaultPartnerDelegationFromIsolatedWorkspaceKeepsCanonicalTaskProject() async throws {
        try await BackendRoutinesTaskEngineParityFixture.withFixture(workspace: { _ in "/work/isolated-workspace" }) { rig in
            let parent = try await rig.local.create(BackendRoutinesTaskEngineParityFixture.obj([("title", .string("Isolated parent")), ("project", .string("/work/project")), ("assignee", .string("builder"))]))
            let actual = try #require(await rig.probe.sessions().first)
            #expect(actual.cwd == "/work/isolated-workspace")
            let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act, .alter], sessionID: actual.id, projectRoot: parent.project, taskProject: parent.project)
            let allowed = try BackendTAGTaskProjectScope.folders(openProjects: [parent.project, "/work/other"], caller: caller, cwd: actual.cwd)
            #expect(allowed.contains(parent.project)); #expect(allowed.contains(actual.cwd)); #expect(!allowed.contains("/work/other"))
            let handed = try await rig.delegation.delegate(taskID: parent.id, agent: "fixer", title: "Partner check", instructions: "Check this scoped work.", project: nil, by: "taskagent:builder")
            let child = try await rig.record(handed["task"].requireString("child task"))
            #expect(child.project == parent.project)
            #expect(child.value["parentTaskId"].string == parent.id)
            #expect(child.value["hops"].number == 1)
        }
    }
}
