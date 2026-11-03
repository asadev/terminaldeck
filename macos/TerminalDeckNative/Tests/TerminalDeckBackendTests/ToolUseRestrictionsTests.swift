import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct ToolUseCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}
private actor ToolUseFixture {
    var rules: NativeRPCValue = .null
    var binding = "A"
    var missing = false
    var reads = 0
    var tightenOnSubjectRead = 0
    func set(_ value: NativeRPCValue) { rules = value }
    func switchBinding() { binding = "B" }
    func deleteProfile() { missing = true }
    func tightenOnSecondSubject() { reads = 0; tightenOnSubjectRead = 2 }
    func subject() -> BackendToolUseRestrictions.Subject {
        reads += 1
        if reads == tightenOnSubjectRead { rules = .object([.init("version", .number(99))]) }
        return .init(stamp: "worker:" + binding, profileID: binding)
    }
    func profile(_ id: String) -> NativeRPCValue? { missing ? nil : .object([.init("id", .string(id)), .init("toolUseRestrictions", rules)]) }
}
final class ToolUseRestrictionsTests: XCTestCase, @unchecked Sendable {
    private func json(_ string: String) throws -> NativeRPCValue { try .parseJSON(Data(string.utf8)) }
    private func rules(_ args: NativeRPCValue, tool: String = "demo.change", blocked: Bool = false) -> NativeRPCValue {
        .object([.init("version", .number(1)), .init("tools", .array([.object([.init("service", .string(tool.split(separator: ".").dropLast().joined(separator: "."))), .init("tool", .string(tool)), .init("cases", .array(blocked ? [] : [.object([.init("arguments", args)])]))])]))])
    }
    private let args = NativeRPCValue.object([.init("action", .string("read")), .init("secret", .string("fixture-value"))])
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolUse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func control(_ fixture: ToolUseFixture) async throws -> BackendDeckCoreSecurityControl {
        let c = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: .init(ask: { _ in false }))
        let inspector = BackendToolUseRestrictions(subject: { _ in await fixture.subject() }, profile: { await fixture.profile($0) })
        await c.setToolUseInspector { context, tool, args, stamp in try await inspector.inspect(context, tool: tool, arguments: args, expected: stamp) }
        return c
    }
    private func tool(_ id: String = "demo.change", alias: [String] = [], precheck: (@Sendable (NativeRPCValue, BackendDeckCoreSecurityCallContext) async throws -> Void)? = nil, run: @escaping BackendDeckCoreSecurityToolPolicy.Handler) throws -> BackendDeckCoreSecurityToolPolicy {
        .init(tool: try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id, inputSchema: try json(#"{"type":"object","properties":{"action":{"type":"string"},"secret":{"type":"string"}},"required":["action","secret"],"additionalProperties":false}"#), tier: .act), aliases: alias, keyRequiresTasks: true, summary: { _, _ in "Fixture" }, precheckAsync: precheck, redactArgs: { $0.setting("secret", .string("[redacted]")) }, run: run)
    }
    private let options = BackendDeckCoreSecurityCallOptions(caller: .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "s", machineID: ""), granted: ["demo.change", "tools.run"])
    func testExactTypedFullObjectsAndMalformedUnknownPolicies() throws {
        let full = try json(#"{"action":"read","nested":{"x":null,"flag":false,"count":0}}"#)
        let policy = try ToolUseRestrictions(rules(full))
        XCTAssertTrue(policy.permits(tool: "demo.change", arguments: full))
        XCTAssertFalse(policy.permits(tool: "demo.change", arguments: full.setting("extra", .null)))
        XCTAssertFalse(policy.permits(tool: "demo.change", arguments: full.setting("action", .null)))
        XCTAssertFalse(ToolUseRestrictions.equal(.bool(false), .number(0)))
        XCTAssertFalse(ToolUseRestrictions.equal(.missing, .null))
        XCTAssertTrue(ToolUseRestrictions.isNarrowing(.null, previous: .missing))
        XCTAssertTrue(ToolUseRestrictions.isNarrowing(.missing, previous: .null))
        XCTAssertThrowsError(try ToolUseRestrictions(rules(args, tool: "tools.run")))
        XCTAssertThrowsError(try ToolUseRestrictions.require(rules(args, tool: "tools.run"), tool: "demo.change", arguments: args))
        XCTAssertTrue(policy.permits(tool: "other.read", arguments: .object([])))
        XCTAssertThrowsError(try ToolUseRestrictions(policy.raw.setting("version", .number(2))))
        XCTAssertThrowsError(try ToolUseRestrictions(policy.raw.setting("unknown", .bool(true))))
        let actionCase = try json(#"{"arguments":{"action":"read"},"action":{"path":["action"],"value":"write"}}"#)
        let bad = rules(.object([])).setting("tools", .array([.object([.init("service", .string("demo")), .init("tool", .string("demo.change")), .init("cases", .array([actionCase]))])]))
        XCTAssertThrowsError(try ToolUseRestrictions(bad))
        XCTAssertThrowsError(try ToolUseRestrictions(rules(.object([.init("huge", .string(String(repeating: "x", count: 70000)))]))))
        let encoded = try JSONEncoder().encode(policy)
        XCTAssertTrue(ToolUseRestrictions.equal(try JSONDecoder().decode(ToolUseRestrictions.self, from: encoded).raw, policy.raw))
    }
    func testAliasesDirectAndBothToolsRunFormsUseCanonicalInnerRules() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0), args = self.args
        await f.set(rules(args))
        try await c.register([try tool(alias: ["old.change"]) { _, _ in counter.edit { $0 += 1 }; return .init(value: .bool(true)) }, .init(tool: try .init(id: "tools.run", wireName: "tools_run", description: "Run", inputSchema: .object([]), tier: .read), summary: { _, _ in "Run" }, run: { _, _ in XCTFail("Wrapper never runs"); return .init(value: .null) })])
        for name in ["demo.change", "demo_change", "old.change"] {
            let good = await c.call(name: name, arguments: args, options: options); XCTAssertTrue(good.ok)
            let no = await c.call(name: name, arguments: args.setting("action", .string("write")), options: options); XCTAssertFalse(no.ok); XCTAssertEqual(no.refusal, .notGranted)
        }
        for encoded in [args, .string(args.compact)] {
            let run = NativeRPCValue.object([.init("name", .string("old.change")), .init("arguments", encoded)])
            let good = await c.call(name: "tools_run", arguments: run, options: options); XCTAssertTrue(good.ok)
        }
        let nested = await c.call(name: "tools.run", arguments: .object([.init("name", .string("tools.run")), .init("arguments", .object([]))]), options: options); XCTAssertFalse(nested.ok)
        let forged = await c.call(name: "demo.change", arguments: args.setting("profileId", .string("B")), options: options); XCTAssertFalse(forged.ok)
        XCTAssertEqual(counter.get(), 5)
    }
    func testMatchingRulesCannotWidenGrantsTiersOrSchema() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0)
        await f.set(rules(args))
        try await c.register([try tool { _, _ in counter.edit { $0 += 1 }; return .init(value: .null) }])
        let noGrant = await c.call(name: "demo.change", arguments: args, options: .init(caller: options.caller, granted: [])); XCTAssertFalse(noGrant.ok)
        let noTier = await c.call(name: "demo.change", arguments: args, options: .init(caller: .init(kind: .key, tiers: [.read], keyID: "fixture"), granted: ["demo.change"])); XCTAssertFalse(noTier.ok)
        let noTasks = await c.call(name: "demo.change", arguments: args, options: .init(caller: .init(kind: .key, tiers: [.read, .act, .alter], keyID: "fixture", tasks: false), granted: ["demo.change"])); XCTAssertFalse(noTasks.ok)
        let schema = await c.call(name: "demo.change", arguments: args.setting("secret", .number(0)), options: options); XCTAssertFalse(schema.ok)
        await f.set(.object([.init("version", .number(99))]))
        let invalid = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertFalse(invalid.ok)
        XCTAssertEqual(counter.get(), 0)
    }
    func testBindingChangedDuringAsyncPrecheckNeverEntersHandler() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0)
        await f.set(rules(args))
        try await c.register([try tool(precheck: { _, _ in await f.switchBinding() }) { _, _ in counter.edit { $0 += 1 }; return .init(value: .null) }])
        let result = await c.call(name: "demo.change", arguments: args, options: options)
        XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .notGranted); XCTAssertEqual(counter.get(), 0)
    }
    func testEffectRechecksTightenedPolicyAndOriginalUnredactedArguments() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0), args = self.args
        await f.set(rules(args))
        try await c.register([try tool { given, context in
            await f.set(.object([.init("version", .number(99))]))
            _ = try await c.prepareEffect(context: context, tool: "demo.change", arguments: given.setting("secret", .string("[redacted]")), tier: .act, sentence: "Fixture", ownerMustAnswer: false)
            counter.edit { $0 += 1 }; return .init(value: .null)
        }])
        let held = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertFalse(held.ok); XCTAssertEqual(counter.get(), 0)
        // Allowed original value must match even when the contributed effect
        // binds its scrubbed view. The evaluator never sees the placeholder.
        let f2 = ToolUseFixture(), c2 = try await control(f2)
        await f2.set(rules(args))
        try await c2.register([try tool { given, context in
            _ = try await c2.prepareEffect(context: context, tool: "demo.change", arguments: given.setting("secret", .string("[redacted]")), tier: .act, sentence: "Fixture", ownerMustAnswer: false)
            counter.edit { $0 += 1 }; return .init(value: .null)
        }])
        let good = await c2.call(name: "demo.change", arguments: args, options: options); XCTAssertTrue(good.ok); XCTAssertEqual(counter.get(), 1)
    }
    func testPolicyTightenedInFinalSubjectAwaitAndDeletedProfileDeny() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0)
        await f.set(rules(args)); await f.tightenOnSecondSubject()
        try await c.register([try tool { _, _ in counter.edit { $0 += 1 }; return .init(value: .null) }])
        let held = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertFalse(held.ok)
        await f.set(rules(args)); await f.deleteProfile()
        let deleted = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertFalse(deleted.ok); XCTAssertEqual(counter.get(), 0)
    }
    func testAuthoritativeSubjectUsesExactSessionTaskAndMachineOnly() throws {
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "s", machineID: "")
        let live = BackendSessionMeta(id: "s", input: .init(cwd: "/fixture", provider: "claude"), spawn: .init(provider: "claude", command: "fixture", args: [], path: "/fixture"))
        let task = try BackendTaskRecord(.object([.init("id", .string("local:x")), .init("keyId", .string("local")), .init("externalTaskId", .string("x")), .init("sessionId", .string("s")), .init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("A"))]))]))
        let found = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: task, namedProfile: "B", lead: false)
        XCTAssertEqual(found.profileID, "A")
        let remote = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read], sessionID: "s", machineID: "remote")
        XCTAssertThrowsError(try BackendToolUseRestrictions.resolve(caller: remote, live: live, task: task, namedProfile: nil, lead: false))
        XCTAssertThrowsError(try BackendToolUseRestrictions.resolve(caller: caller, live: nil, task: task, namedProfile: "A", lead: false))
        let owner = try BackendToolUseRestrictions.resolve(caller: .local, live: nil, task: task, namedProfile: "A", lead: false); XCTAssertNil(owner.profileID)
        let namedLead = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: nil, namedProfile: "A", lead: true); XCTAssertEqual(namedLead.profileID, "A")
        let workerLead = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: task, namedProfile: "B", lead: true); XCTAssertEqual(workerLead.profileID, "A")
        let plainLead = try BackendToolUseRestrictions.resolve(caller: caller, live: live, task: nil, namedProfile: nil, lead: true); XCTAssertNil(plainLead.profileID)
    }
    func testNamedProfileLeadIsRestrictedWhilePlainLeadRetainsOwnGrant() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0)
        await f.set(rules(args, blocked: true))
        let live = BackendSessionMeta(id: "s", input: .init(cwd: "/fixture", provider: "claude"), spawn: .init(provider: "claude", command: "fixture", args: [], path: "/fixture"))
        let named = try BackendToolUseRestrictions.resolve(caller: options.caller, live: live, task: nil, namedProfile: "A", lead: true)
        let namedInspector = BackendToolUseRestrictions(subject: { _ in named }, profile: { await f.profile($0) })
        await c.setToolUseInspector { context, tool, args, stamp in try await namedInspector.inspect(context, tool: tool, arguments: args, expected: stamp) }
        try await c.register([try tool { _, _ in counter.edit { $0 += 1 }; return .init(value: .null) }])
        let held = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertFalse(held.ok); XCTAssertEqual(counter.get(), 0)
        let plain = try BackendToolUseRestrictions.resolve(caller: options.caller, live: live, task: nil, namedProfile: nil, lead: true)
        let plainInspector = BackendToolUseRestrictions(subject: { _ in plain }, profile: { await f.profile($0) })
        await c.setToolUseInspector { context, tool, args, stamp in try await plainInspector.inspect(context, tool: tool, arguments: args, expected: stamp) }
        let allowed = await c.call(name: "demo.change", arguments: args, options: options); XCTAssertTrue(allowed.ok); XCTAssertEqual(counter.get(), 1)
    }
    func testMalformedAssigneeCannotSelectAnExistingUnknownProfile() async throws {
        let f = ToolUseFixture(), c = try await control(f), counter = BackendDeckCoreSecurityTestBox(0)
        let persistence = try BackendTaskPersistence(directory: try temporary(), ownership: .exclusive)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start()
        _ = try await config.saveAgent(.object([.init("id", .string("unknown")), .init("name", .string("Unknown")), .init("provider", .string("claude"))]))
        let live = BackendSessionMeta(id: "s", input: .init(cwd: "/fixture", provider: "claude"), spawn: .init(provider: "claude", command: "fixture", args: [], path: "/fixture"))
        let malformed = try BackendTaskRecord(.object([.init("id", .string("local:x")), .init("keyId", .string("local")), .init("externalTaskId", .string("x")), .init("sessionId", .string("s")), .init("assignee", .object([.init("kind", .string("agent"))]))]))
        let inspector = BackendToolUseRestrictions(subject: { context in
            try BackendToolUseRestrictions.resolve(caller: context.caller, live: live, task: malformed, namedProfile: nil, lead: false)
        }, profile: { try await config.agent($0) })
        await c.setToolUseInspector { context, tool, args, stamp in try await inspector.inspect(context, tool: tool, arguments: args, expected: stamp) }
        try await c.register([try tool { _, _ in counter.edit { $0 += 1 }; return .init(value: .null) }])
        let held = await c.call(name: "demo.change", arguments: args, options: options)
        XCTAssertFalse(held.ok); XCTAssertEqual(held.refusal, .notGranted); XCTAssertEqual(counter.get(), 0)
        let existing = try await config.agent("unknown"); XCTAssertEqual(existing?["id"], .string("unknown"))
    }
    func testCanonicalPersistencePartialBatchAGSImportAndInvalidReload() async throws {
        let root = try temporary(), persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start()
        let rule = rules(args)
        await config.setToolUseCatalogue { ["demo.change"] }
        let row = NativeRPCValue.object([.init("id", .string("agent")), .init("name", .string("Agent")), .init("provider", .string("claude")), .init("toolUseRestrictions", rule)])
        _ = try await config.saveAgent(row)
        _ = try await config.saveAgent(row.removing("toolUseRestrictions").setting("name", .string("Renamed")))
        _ = try await config.saveAgentsAsCaller(request: .object([.init("do", .string("save-many")), .init("ids", .array([.string("agent")])), .init("agent", .object([.init("role", .string("Reviewer"))]))]), ownerMode: true)
        let ags = BackendAGSStore(persistence: persistence, cipher: ToolUseCipher()); try await ags.start(); try await config.bindAGS(ags)
        let revision = try await ags.currentRevision()
        _ = try await config.saveAgentWithAGS(row.removing("toolUseRestrictions"), settings: .init(provider: "claude"), expectedRevision: revision)
        let currentValue = try await config.agent("agent")
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current["toolUseRestrictions"], rule)
        let definition = try XCTUnwrap(BackendTAGAgentImport.parse("---\nname: agent\ndescription: Worker\n---\nInstructions"))
        let imported = BackendTAGAgentImport.merge(definition, existing: current, directory: root, file: root.appendingPathComponent("agent.md"))
        XCTAssertEqual(imported["toolUseRestrictions"], rule)
        let definitions = root.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        try Data("---\nname: agent\ndescription: Worker\n---\nInstructions".utf8).write(to: definitions.appendingPathComponent("agent.md"))
        let importResult = try await config.importAgents(folder: root.path)
        await config.stopImportWatchers()
        XCTAssertEqual(importResult["errors"].elements?.count, 0)
        let importedCurrent = try await config.agent("agent"); XCTAssertEqual(importedCurrent?["toolUseRestrictions"], rule)
        let restored = try BackendTaskConfiguration(persistence: persistence); try await restored.start()
        let loaded = try await restored.agent("agent"); XCTAssertEqual(loaded?["toolUseRestrictions"], rule)
        do { _ = try await config.saveAgent(row.setting("toolUseRestrictions", rules(args, tool: "unknown.alias"))); XCTFail("Unknown canonical tool saved") } catch {}
        // A damaged rule remains visible and restrictive after loading, not
        // silently discarded by the normal profile serializer.
        let invalid = row.setting("toolUseRestrictions", .object([.init("version", .number(42))]))
        let brokenP = try BackendTaskPersistence(directory: try temporary(), ownership: .exclusive)
        try brokenP.write("task-config.json", value: .object([.init("v", .number(1)), .init("agents", .array([invalid]))]))
        let broken = try BackendTaskConfiguration(persistence: brokenP); try await broken.start()
        let damagedValue = try await broken.agent("agent")
        let damaged = try XCTUnwrap(damagedValue)
        XCTAssertNotNil(ToolUseRestrictions.problem(damaged["toolUseRestrictions"]))
        do { try ToolUseRestrictions.require(damaged["toolUseRestrictions"], tool: "anything.read", arguments: .object([])); XCTFail("Invalid state became unrestricted") } catch {}
    }
    func testNonOwnerOnlyProvenCaseSubsetsAndRealSettingsToolRoundTrip() async throws {
        let p = try BackendTaskPersistence(directory: try temporary(), ownership: .exclusive)
        let config = try BackendTaskConfiguration(persistence: p); try await config.start()
        let rule = rules(args), row = NativeRPCValue.object([.init("id", .string("agent")), .init("name", .string("Agent")), .init("provider", .string("claude")), .init("toolUseRestrictions", rule)])
        _ = try await config.saveAgent(row)
        XCTAssertNoThrow(try BackendTAGProfilePolicy.validate(input: .object([.init("toolUseRestrictions", rules(args, blocked: true))]), existing: row))
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: .object([.init("toolUseRestrictions", .null)]), existing: row))
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: .object([.init("toolUseRestrictions", rules(args.setting("action", .string("write"))))]), existing: row))
        let split = try BackendAGOPTProfileChanges.split(patch: .object([.init("toolUseRestrictions", .null)]), existing: row, callerKeyID: "fixture", inheritedPermissionMode: "default")
        XCTAssertTrue(split.narrow["toolUseRestrictions"].isNullish); XCTAssertTrue(split.wide.has("toolUseRestrictions"))
        let ags = BackendAGSStore(persistence: p, cipher: ToolUseCipher()); try await ags.start(); try await config.bindAGS(ags)
        let service = BackendAGOPTProfileService(configuration: config, ags: ags, access: .init(require: { _, _, _ in }, authorize: { _, _, _, _ in }, rpc: { _ in .init(caller: .nativeApp, ownerID: "fixture") }), dependencies: .init(settingsSet: { _, id, field, value in
            try await config.saveSettingsFieldOwner(id, field: field, value: value, expectedRevision: try await ags.currentRevision())
        }))
        let definitions = try BackendAGOPTProfileMCP.definitions(service: service)
        // #532: tools that change an agent are listed at their true tier, so Hoot in Ask first is asked.
        for definition in definitions {
            XCTAssertEqual(definition.spec.tier, definition.spec.id.hasSuffix("_get") ? .read : .alter, definition.spec.id)
        }
        let tool = try XCTUnwrap(definitions.first { $0.spec.id == "agents.settings_set" })
        XCTAssertTrue(tool.spec.inputSchema["properties"]["field"]["enum"].elements?.contains(.string("tool_use_restrictions")) == true)
        let native = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: ["agents.settings_set"], allowedTiers: [.read, .act, .alter], cancellation: .init())
        let reply = try await tool.handler(native, .object([.init("id", .string("agent")), .init("field", .string("tool_use_restrictions")), .init("value", rule)]))
        XCTAssertFalse(reply.isError)
        let view = try await service.settings("agent", call: .app(.init(caller: .nativeApp, ownerID: "fixture")))
        XCTAssertEqual(view["values"]["tool_use_restrictions"], rule)
        let decoded = try XCTUnwrap(TasksDecode.state(["agents": [row.foundation as Any], "connections": [] as [Any]])?.agents.first)
        let draft = AgentDraft(decoded)
        let payload = try AgentForm.payload(draft, agents: []).get()
        XCTAssertTrue(ToolUseRestrictions.equal(try NativeRPCValue.fromFoundation(payload.wire)["toolUseRestrictions"], rule))
    }
}
