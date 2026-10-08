import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("TAG key restrictions and discovery")
struct TAGProfilePolicyTests {
    func value(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(fields) }
    func refused(_ input: NativeRPCValue, old: NativeRPCValue, contains: String) {
        do { _ = try BackendTAGProfilePolicy.validate(input: input, existing: old); Issue.record("A widening change was accepted") }
        catch { #expect(error.localizedDescription.contains(contains)); #expect(error.localizedDescription.contains("Settings → Task agents")) }
    }
    @Test func blocksAndSkillsOnlyNarrow() throws {
        let old = value([("blockedTools", .array([.string("Edit")])), ("skillsOff", .bool(false))])
        let narrowed = try BackendTAGProfilePolicy.validate(input: value([("blockedTools", .array([.string("Edit"), .string("Bash")])), ("skillsOff", .bool(true))]), existing: old)
        #expect(narrowed["blockedTools"].elements?.count == 2 && narrowed["skillsOff"].bool == true)
        refused(value([("blockedTools", .array([]))]), old: old, contains: "Removing the Edit block")
        refused(value([("skillsOff", .bool(false))]), old: narrowed, contains: "Turning skills back on")
        #expect(try BackendTAGProfilePolicy.validate(input: value([("name", .string("Renamed"))]), existing: narrowed)["blockedTools"] == narrowed["blockedTools"])
        #expect(try BackendTAGProfilePolicy.validate(input: value([("sourceFile", .null)]), existing: nil)["sourceFile"].isNullish)
        refused(value([("sourceFile", .null)]), old: value([("sourceFile", .string("/fixture/.claude/agents/inspector.md"))]), contains: "Changing the imported agent source")
    }
    @Test func allowListCanBeSetAndShrunkButNeverRemovedOrExpanded() throws {
        let initial = try BackendTAGProfilePolicy.validate(input: value([("allowedTools", .array([.string("Read"), .string("mcp__terminaldeck__tasks_delegate")]))]), existing: nil)
        let reduced = try BackendTAGProfilePolicy.validate(input: value([("allowedTools", .array([.string("Read")]))]), existing: initial)
        #expect(reduced["allowedTools"].elements == [.string("Read")])
        refused(value([("allowedTools", .null)]), old: reduced, contains: "Removing the tool allow-list")
        refused(value([("allowedTools", .array([.string("Read"), .string("Edit")]))]), old: reduced, contains: "Adding Edit")
        let empty = try BackendTAGProfilePolicy.validate(input: value([("allowedTools", .array([]))]), existing: reduced)
        refused(value([("allowedTools", .array([.string("Read")]))]), old: empty, contains: "Adding Read")
        let group = value([("allowedTools", .array([.string("mcp__deck-control")]))])
        let exact = try BackendTAGProfilePolicy.validate(input: value([("allowedTools", .array([.string("mcp__deck-control__tasks_get")]))]), existing: group)
        refused(group, old: exact, contains: "Adding mcp__deck-control")
    }
    @Test func everyPermissionDirection() throws {
        let modes = ["plan", "default", "acceptEdits", "bypassPermissions"]
        for (before, oldMode) in modes.enumerated() {
            for (after, newMode) in modes.enumerated() {
                let old = value([("permissionMode", .string(oldMode))]), input = value([("permissionMode", .string(newMode))])
                if after > before { refused(input, old: old, contains: "Changing permission mode from \(oldMode) to \(newMode)") }
                else { #expect(try BackendTAGProfilePolicy.validate(input: input, existing: old)["permissionMode"].string == newMode) }
            }
        }
        #expect(try BackendTAGProfilePolicy.validate(input: value([("permissionMode", .string("default"))]), existing: nil, inheritedPermissionMode: "bypassPermissions")["permissionMode"].string == "default")
        refused(value([("permissionMode", .null)]), old: value([("permissionMode", .string("plan"))]), contains: "to default")
        do {
            _ = try BackendTAGProfilePolicy.validate(input: value([("permissionMode", .null)]), existing: value([("permissionMode", .string("plan"))]), inheritedPermissionMode: "auto")
            Issue.record("An unknown inherited permission mode relaxed plan")
        } catch { #expect(error.localizedDescription.contains("from plan to auto")) }
    }
    @Test func keepOpenCanBeShortenedOnly() throws {
        let timed = value([("keepAliveMinutes", .number(30))])
        #expect(try BackendTAGProfilePolicy.validate(input: value([("keepAliveMinutes", .number(5))]), existing: timed)["keepAliveMinutes"].number == 5)
        refused(value([("keepAliveMinutes", .number(31))]), old: timed, contains: "Extending keep-open")
        refused(value([("keepAliveUntilClose", .bool(true))]), old: timed, contains: "until you close it")
        let indefinite = value([("keepAliveUntilClose", .bool(true)), ("keepAliveMinutes", .number(30))])
        #expect(try BackendTAGProfilePolicy.validate(input: value([("keepAliveUntilClose", .bool(false)), ("keepAliveMinutes", .number(1440))]), existing: indefinite)["keepAliveUntilClose"].bool == false)
        #expect(try BackendTAGProfilePolicy.validate(input: .object([]), existing: indefinite)["keepAliveUntilClose"].bool == true)
        #expect(throws: NativeRPCError.self) { try BackendTAGProfilePolicy.validate(input: value([("keepAliveMinutes", .number(1e308))]), existing: timed) }
    }
    @Test func hiddenTaskToolsHaveExactKeyAndSettingsHint() throws {
        let specs = try ["tasks.agents", "tasks.agents_import"].map { id in
            let tool = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "Task agent profiles", inputSchema: .object([]), tier: .read)
            return BackendDeckCoreCatalogueMetadata(tool: tool, title: "Task agents", index: "Profiles", keyGrant: "tasks")
        }
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "k1", keyName: "Commander", tasks: false)
        let answer = try BackendDeckCoreCatalogueDescribe.answer(value([("area", .string("agents"))]), catalogue: specs, granted: nil, caller: key).value
        #expect(answer["taskToolsHidden"].number == 2)
        #expect(answer["area"].string == "agents" && answer["unknown"].isNullish)
        #expect(answer["note"].string == "2 task tools hidden. Turn on 'Your tasks' for key Commander in Settings → Connect an AI app.")
        let on = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "k1", tasks: true)
        #expect(try BackendDeckCoreCatalogueDescribe.answer(value([("area", .string("agents"))]), catalogue: specs, granted: nil, caller: on).value["taskToolsHidden"].isNullish)
    }
    @Test func defaultProjectAndOriginPersistBeforeExecution() async throws {
        let fixture = try await BackendCrmTaskDetailParityFixture.make()
        let builder = try #require(try await fixture.config.agent("builder"))
        _ = try await fixture.config.saveAgent(builder.setting("defaultProject", .string("/work/app")))
        let task = try await fixture.local.create(value([("title", .string("Uses the profile folder")), ("assignee", .string("builder")), ("notificationKeyId", .string("forged"))]), by: "app:Commander", notificationKeyID: "commander-key")
        #expect(task.project == "/work/app")
        #expect(task.value["notificationKeyId"].string == "commander-key")
        #expect(task.value["keyId"].string == "local")
        let child = try await fixture.local.create(value([("title", .string("Partner work")), ("assignee", .string("tester")), ("project", .string("/work/other"))]), parentID: task.id)
        #expect(child.value["parentTaskId"].string == task.id)
        #expect(child.value["notificationKeyId"].string == "commander-key")
        #expect(child.project == "/work/other")
        let owner = try await fixture.local.create(value([("title", .string("Owner work")), ("notificationKeyId", .string("forged"))]))
        #expect(owner.value["notificationKeyId"].isNullish)
        let assigned = try await fixture.local.update(owner.id, input: value([("assignee", .string("builder"))]), notificationKeyID: "assigning-key")
        #expect(assigned.project == "/work/app")
        #expect(assigned.value["notificationKeyId"].string == "assigning-key")
        #expect(try await fixture.store.claim(task.id, sessionID: "worker-session", liveSessionIDs: ["worker-session"], expectedAssignee: task.value["assignee"]))
        #expect(try await fixture.store.bySession("worker-session")?.id == task.id)
        await #expect(throws: NativeRPCError.self) {
            try await fixture.store.claim(task.id, sessionID: "other-session", liveSessionIDs: [], expectedAssignee: BackendTaskLocalService.assignment("tester", kind: "agent"))
        }
        #expect(try await fixture.store.byID(task.id)?.sessionID == "worker-session")
    }
}
