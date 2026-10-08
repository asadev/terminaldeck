import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("TAG native profiles and linked work")
struct TAGAgentPresentationTests {
    @Test func oldProfilesKeepTheirDefaultsAndUnrestrictedTools() throws {
        let state = try #require(TasksDecode.state(["agents": [["id": "old", "name": "Old"]], "connections": []]))
        let old = try #require(state.agents.first)
        #expect(old.claudeAgent == nil)
        #expect(old.allowedTools == nil)
        #expect(old.permissionMode == nil)
        #expect(old.keepAliveUntilClose == nil)
        #expect(old.defaultProject == nil)
        #expect(old.reviewerAgent == nil)
        #expect(old.maxRunMinutes == TasksLimits.defaultRunMinutes)
        #expect(AgentDraft(old).allowedTools == nil)
    }

    @Test func emptyToolAllowListSurvivesDecodeEditAndWire() throws {
        let state = try #require(TasksDecode.state(["agents": [["id": "reader", "name": "Reader", "provider": "claude", "allowedTools": [], "permissionMode": "plan"]], "connections": []]))
        let agent = try #require(state.agents.first)
        #expect(agent.allowedTools == [])
        let saved = try AgentForm.payload(AgentDraft(agent), agents: [agent]).get()
        #expect(saved.allowedTools == [])
        #expect(saved.wire["allowedTools"] as? [String] == [])
        #expect(saved.permissionMode == "plan")
        var draft = AgentDraft(agent)
        draft.allowedTools = nil
        let unrestricted = try AgentForm.payload(draft, agents: [agent]).get()
        #expect(unrestricted.wire["allowedTools"] is NSNull)
    }

    @Test func profileSourceAndTaskSettingsSurviveAnOwnerEdit() throws {
        let inspector = AgentProfile(id: "inspector", name: "Inspector", provider: "claude")
        let imported = AgentProfile(id: "builder", name: "Builder", provider: "claude", blockedTools: ["Edit"],
                                    claudeAgent: "builder", allowedTools: ["Read", "mcp__deck__tasks_delegate"], permissionMode: "default",
                                    keepAliveUntilClose: true, defaultProject: "/tmp/project", reviewerAgent: "inspector",
                                    sourceFile: "/tmp/project/.claude/agents/builder.md", sourceDirectory: "/tmp/project/.claude/agents",
                                    syncedAt: 1_790_000_000_000, syncStatus: "synced")
        let state = try #require(TasksDecode.state(["agents": [imported.wire], "connections": []]))
        let decoded = try #require(state.agents.first)
        #expect(decoded == imported)
        let saved = try AgentForm.payload(AgentDraft(decoded), agents: [decoded, inspector]).get()
        #expect(saved == imported)
        #expect(TasksSettingsText.agentSummary(saved).contains("until you close it"))
        #expect(TAGAgentSettings.syncLabel(saved) == "Synced")
        #expect(TAGAgentSettings.reviewerLabel(saved, agents: [inspector]) == "Checked by: Inspector")
    }

    @Test func ownerMayWidenSettingsWhileNewAgentCapacityStaysFifty() throws {
        var old = AgentProfile(id: "a", name: "A", provider: "claude", blockedTools: ["Edit"], skillsOff: true,
                               claudeAgent: "a", allowedTools: ["Read"], permissionMode: "plan")
        old.keepAliveUntilClose = false
        var draft = AgentDraft(old)
        draft.blockedTools = []
        draft.skillsOff = false
        draft.allowedTools = ["Read", "Edit"]
        draft.permissionMode = "bypassPermissions"
        draft.keepAliveUntilClose = true
        let widened = try AgentForm.payload(draft, agents: [old]).get()
        #expect(widened.allowedTools == ["Read", "Edit"])
        #expect(widened.blockedTools.isEmpty && !widened.skillsOff)
        #expect(widened.permissionMode == "bypassPermissions" && widened.keepAliveUntilClose == true)
        let fifty = (0..<50).map { AgentProfile(id: "a\($0)", name: "A\($0)") }
        var fresh = AgentDraft(nil)
        fresh.name = "New"
        #expect(throws: TasksProblem.self) { try AgentForm.payload(fresh, agents: fifty).get() }
        #expect(try AgentForm.payload(AgentDraft(fifty[0]), agents: fifty).get().id == "a0")
    }

    @Test func invalidProviderProjectAndReviewerAreRefused() {
        var draft = AgentDraft(nil)
        draft.name = "Builder"
        draft.provider = "codex"
        draft.allowedTools = ["Read"]
        #expect(throws: TasksProblem.self) { try AgentForm.payload(draft, agents: []).get() }
        draft.provider = "claude"
        draft.defaultProject = "relative/project"
        #expect(throws: TasksProblem.self) { try AgentForm.payload(draft, agents: []).get() }
        draft.defaultProject = "/tmp/project"
        draft.reviewerAgent = "missing"
        #expect(throws: TasksProblem.self) { try AgentForm.payload(draft, agents: []).get() }
    }

    @Test func childLinksStayWithinTheirKeyAndPreferFullIds() {
        let parent = TaskRow(id: "key1:parent", keyId: "key1", externalTaskId: "parent", title: "Build", createdAt: 1)
        let foreign = TaskRow(id: "key2:parent", keyId: "key2", externalTaskId: "parent", title: "Other")
        let legacy = TaskRow(id: "key1:child", keyId: "key1", externalTaskId: "child", createdAt: 3, parentExternalTaskId: "parent")
        let modern = TaskRow(id: "key1:child2", keyId: "key1", externalTaskId: "child2", createdAt: 2, parentTaskId: parent.id)
        let conflict = TaskRow(id: "key2:child", keyId: "key2", externalTaskId: "child", parentTaskId: foreign.id, parentExternalTaskId: "parent")
        let all = [parent, foreign, legacy, modern, conflict]
        #expect(TAGAgentSettings.parent(of: legacy, in: all)?.id == parent.id)
        #expect(TAGAgentSettings.parent(of: modern, in: all)?.id == parent.id)
        #expect(TAGAgentSettings.children(of: parent, in: all).map(\.id) == [modern.id, legacy.id])
        #expect(TAGAgentSettings.children(of: foreign, in: all).map(\.id) == [conflict.id])
    }

    @Test func taskDecodeKeepsUntilCloseAndReviewLinks() throws {
        let row = try #require(TasksDecode.task(["id": "child", "parentTaskId": "parent", "keepAliveUntilClose": true,
                                              "reviewerTaskId": "reviewer", "reviewOfTaskId": "original"]))
        #expect(row.keepAliveUntilClose == true)
        #expect(row.parentTaskId == "parent")
        #expect(row.reviewerTaskId == "reviewer" && row.reviewOfTaskId == "original")
        #expect(TasksDecode.task(["id": "old"])?.parentTaskId == nil)
    }

    @Test func agentDefaultProjectPassesNativeTaskValidationWithoutOverridingExplicitProject() throws {
        let agent = AgentProfile(id: "reader", name: "Reader", defaultProject: "/tmp/default-project")
        var draft = LocalDraft(nil, statuses: [])
        draft.title = "Read the docs"
        draft.assignee = agent.id
        let inferred = try draft.payload(agents: [agent]).get()
        #expect(inferred["project"] as? String == "/tmp/default-project")
        draft.project = "/tmp/explicit-project"
        #expect(try draft.payload(agents: [agent]).get()["project"] as? String == "/tmp/explicit-project")
        draft.project = ""
        draft.assignee = "missing"
        #expect(throws: TasksProblem.self) { try draft.payload(agents: [agent]).get() }
    }

    @Test func keyRowsShowActualGrantedScopesAndReadOlderKeys() throws {
        let old = try #require(AiAppsState.from(CodingAIJSON.parse(#"{"keys":[{"id":"old","name":"Old","level":"full","tasks":true}]}"#))?.keys.first)
        #expect(old.grantedScopes == nil)
        #expect(AiAppsLines.grantedScopes(old) == "Granted scopes: Read · Run actions · Full control · Your tasks")
        let narrowed = try #require(AiAppsState.from(CodingAIJSON.parse(#"{"keys":[{"id":"new","name":"New","level":"full","tasks":true,"grantedScopes":["look","tasks","look"]}]}"#))?.keys.first)
        #expect(AiAppsLines.grantedScopes(narrowed) == "Granted scopes: Read · Your tasks")
        let revoked = try #require(AiAppsState.from(CodingAIJSON.parse(#"{"keys":[{"id":"empty","name":"Empty","level":"look","grantedScopes":[]}]}"#))?.keys.first)
        #expect(AiAppsLines.grantedScopes(revoked) == "Granted scopes: None")
    }
}
