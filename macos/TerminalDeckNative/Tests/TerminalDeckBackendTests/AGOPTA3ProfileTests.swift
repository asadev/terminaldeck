import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct AGOPTA3Cipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}
private actor AGOPTA3Gate {
    var allowed = true, approved = true, approvals = 0, performed = 0
    func require(_ id: String) throws { guard allowed, id == "agent" else { throw NativeRPCError(code: "not-granted", message: "Scope removed") } }
    func authorize() throws { approvals += 1; guard approved else { throw NativeRPCError(code: "denied", message: "Owner denied") } }
    func perform() { performed += 1 }
    func deny() { approved = false }
    func revoke() { allowed = false }
}
final class AGOPTA3ProfileTests: XCTestCase, @unchecked Sendable {
    private let call = BackendAGOPTProfileCall.app(.init(caller: .nativeApp, ownerID: "fixture"))
    private func fixture(source: String? = nil) async throws -> (BackendTaskConfiguration, BackendAGSStore) {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-a3-memory"), ownership: .memory)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start()
        var profile = NativeRPCValue.object([.init("id", .string("agent")), .init("name", .string("Agent")), .init("provider", .string("claude"))])
        if let source { profile = profile.setting("sourceFile", .string(source)) }
        _ = try await config.saveAgent(profile)
        let store = BackendAGSStore(persistence: persistence, cipher: AGOPTA3Cipher()); try await store.start()
        return (config, store)
    }
    private func access(_ gate: AGOPTA3Gate, after: @escaping @Sendable () async throws -> Void = {}) -> BackendAGOPTProfileAccess {
        .init(require: { _, id, _ in try await gate.require(id) }, authorize: { _, _, _, _ in try await gate.authorize(); try await after() }, rpc: { _ in .init(caller: .nativeApp, ownerID: "fixture") })
    }
    func testProfileUsesOneConfigAndNullablePlanMoneyWithoutApproval() async throws {
        let (config, store) = try await fixture(), gate = AGOPTA3Gate()
        let service = BackendAGOPTProfileService(configuration: config, ags: store, access: access(gate), dependencies: .init(dashboard: { _ in .object([.init("runtime", .object([.init("state", .string("ready"))])), .init("stats", .object([.init("isAPIAccount", .bool(false)), .init("costUSD", .number(61))])), .init("tasks", .array([]))]) }, runs: { _, _ in [.object([.init("id", .string("run")), .init("costUSD", .number(61))])] }, budget: { _ in .object([.init("billing_kind", .string("subscription")), .init("unit", .string("tokens")), .init("used", .number(1000)), .init("cost_usd", .number(61)), .init("coverage", .string("observed"))]) }))
        let read = try await service.profile("agent", call: call)
        XCTAssertEqual(read["profile"]["name"].string, "Agent"); XCTAssertEqual(read["runtime"]["state"].string, "ready")
        XCTAssertTrue(read["stats"]["costUSD"].isNullish); XCTAssertTrue(read["runs"].elements?.first?["costUSD"].isNullish == true)
        XCTAssertTrue(read["budget"]["cost_usd"].isNullish); XCTAssertEqual(read["budget"]["used"].number, 1000)
        let count = await gate.approvals; XCTAssertEqual(count, 0)
    }
    func testActionsAskFirstAndDeniedOrRevokedScopeNeverPerforms() async throws {
        let (config, store) = try await fixture(), gate = AGOPTA3Gate()
        let deps = BackendAGOPTProfileService.Dependencies(perform: { _, _, _, _ in await gate.perform(); return .object([.init("ok", .bool(true))]) })
        let service = BackendAGOPTProfileService(configuration: config, ags: store, access: access(gate), dependencies: deps)
        _ = try await service.action("agent", action: "assign_task", call: call)
        let count = await gate.approvals, performed = await gate.performed; XCTAssertEqual(count, 0); XCTAssertEqual(performed, 1)
        await gate.deny()
        do { _ = try await service.action("agent", action: "stop_all", call: call); XCTFail("Denied stop performed") } catch {}
        let after = await gate.performed; XCTAssertEqual(after, 1)
        let revoked = AGOPTA3Gate()
        let changing = BackendAGOPTProfileService(configuration: config, ags: store, access: access(revoked, after: { await revoked.revoke() }), dependencies: .init(perform: { _, _, _, _ in await revoked.perform(); return .null }))
        do { _ = try await changing.action("agent", action: "wake", call: call); XCTFail("Revoked wake performed") } catch {}
        let absent = await revoked.performed; XCTAssertEqual(absent, 0)
    }
    func testUnavailableActionsAreHonestAndFieldWritesUseCanonicalSupplier() async throws {
        let (config, store) = try await fixture(), gate = AGOPTA3Gate()
        let missing = BackendAGOPTProfileService(configuration: config, ags: store, access: access(gate), dependencies: .init())
        do { _ = try await missing.action("agent", action: "wake", call: call); XCTFail("Missing runtime returned success") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let linked = BackendAGOPTProfileService(configuration: config, ags: store, access: access(gate), dependencies: .init(settingsSet: { _, id, field, value in
            XCTAssertEqual(id, "agent"); XCTAssertEqual(field, "name")
            guard let current = try await config.agent(id) else { throw NativeRPCError.invalidArguments("Missing fixture") }
            return try await config.saveAgent(current.setting("name", value))
        }))
        _ = try await linked.setSetting("agent", field: "name", value: .string("Changed"), call: call)
        let real = try await config.agent("agent"); XCTAssertEqual(real?["name"].string, "Changed")
    }
    func testSnakeFieldAdapterKeepsStopAndMonthlyBudgetsCanonical() throws {
        let profile = NativeRPCValue.object([.init("id", .string("agent")), .init("name", .string("Agent")), .init("provider", .string("claude")), .init("keepAliveMinutes", .number(30))])
        let stopped = try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "stop_when_done", value: .bool(true))
        XCTAssertEqual(stopped.profile["keepAliveUntilClose"].bool, false); XCTAssertEqual(stopped.profile["keepAliveMinutes"].number, 0)
        let kept = try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "stop_when_done", value: .bool(false))
        XCTAssertEqual(kept.profile["keepAliveUntilClose"].bool, true); XCTAssertTrue(kept.settings.keepOpen)
        let budget = try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "monthly_budget_usd", value: .number(150))
        XCTAssertEqual(budget.settings.efficiency?.monthlyBudgetUSD, 150)
        XCTAssertThrowsError(try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "creator_key", value: .string("forged")))
    }
    /// #520: the AI tools' "Stop when done" writes what the agent window's switch writes.
    func testStopWhenDoneIsOneRuleForWindowAndTools() throws {
        let profile = NativeRPCValue.object([.init("id", .string("agent")), .init("name", .string("Agent")), .init("provider", .string("claude")), .init("keepAliveMinutes", .number(30))])
        for stop in [true, false] {
            var window = AGSAgentSettings(); AGSStopWhenDone.apply(stop, to: &window)
            let tool = try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "stop_when_done", value: .bool(stop))
            XCTAssertEqual(tool.settings.keepOpen, window.keepOpen)
            XCTAssertEqual(tool.settings.efficiency?.completion, window.efficiency?.completion)
            XCTAssertEqual(tool.profile["keepAliveUntilClose"].bool, AGSStopWhenDone.keepAlive(stop).untilClose)
            XCTAssertEqual(try BackendAGOPTProfileFieldAdapter.values(profile: tool.profile, settings: tool.settings)["stop_when_done"].bool, stop)
        }
        let off = try BackendAGOPTProfileFieldAdapter.proposal(profile: profile, settings: .init(), field: "stop_when_done", value: .bool(false))
        XCTAssertNil(off.settings.efficiency?.completion, "turning it off does not make finishing park the session")
    }
    func testPublicAGSBudgetChangesUseSameFrozenPlanAndPreservePrivateSettings() async throws {
        let (config, store) = try await fixture(); try await config.bindAGS(store)
        var settings = AGSAgentSettings()
        settings.environment = ["PRIVATE_FIXTURE": "hidden"]
        settings.efficiency = .init(agentTokenBudget: 1000)
        _ = try await config.saveSettingsForProfile("agent", settings: settings, expectedRevision: store.currentRevision())
        let wide = NativeRPCValue.object([.init("id", .string("agent")), .init("field", .string("monthly_token_budget")), .init("value", .number(2000))])
        let prepared = try await config.prepareSettingsFieldChange(request: wide, callerKeyID: "creator")
        XCTAssertEqual(prepared["needsApproval"].bool, true)
        let before = try await store.profile("agent"); XCTAssertEqual(before?.efficiency?.agentTokenBudget, 1000)
        _ = try await config.applyApprovedAgentChanges(planID: prepared["planId"].string!, callerKeyID: "creator")
        let after = try await store.profile("agent"); XCTAssertEqual(after?.efficiency?.agentTokenBudget, 2000)
        XCTAssertEqual(after?.environment["PRIVATE_FIXTURE"], "hidden")
        let narrow = wide.setting("value", .number(500))
        let immediate = try await config.prepareSettingsFieldChange(request: narrow, callerKeyID: "creator")
        XCTAssertEqual(immediate["needsApproval"].bool, false)
        let limited = try await store.profile("agent"); XCTAssertEqual(limited?.efficiency?.agentTokenBudget, 500)
    }
    func testPublicAGSPlanDenialStaleAndPrivateKeyFieldsDoNotWrite() async throws {
        let (config, store) = try await fixture(); try await config.bindAGS(store)
        let request = NativeRPCValue.object([.init("id", .string("agent")), .init("field", .string("mcp_servers")), .init("value", .object([.init("new-server", .bool(true))]))])
        let plan = try await config.prepareSettingsFieldChange(request: request, callerKeyID: "creator")
        XCTAssertEqual(plan["needsApproval"].bool, true)
        try await config.discardAgentChangeRequest(request: request, callerKeyID: "creator")
        do { _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "creator"); XCTFail("Denied settings applied") } catch {}
        let next = try await config.prepareSettingsFieldChange(request: request, callerKeyID: "creator")
        let current = try await config.agent("agent")!
        _ = try await config.saveAgent(current.setting("name", .string("Changed")))
        do { _ = try await config.applyApprovedAgentChanges(planID: next["planId"].string!, callerKeyID: "creator"); XCTFail("Stale settings applied") } catch {}
        let hidden = request.setting("field", .string("environment_variables")).setting("value", .object([.init("SECRET", .string("blocked"))]))
        do { _ = try await config.prepareSettingsFieldChange(request: hidden, callerKeyID: "creator"); XCTFail("Key injected environment") } catch {}
        let unchanged = try await store.profile("agent"); XCTAssertNotEqual(unchanged?.mcpServers["new-server"], true); XCTAssertNil(unchanged?.environment["SECRET"])
    }
    func testPublicProfileHistoryHonorsCurrentScopeAndRemovesPrivateAccountPaths() async throws {
        let (config, store) = try await fixture(), gate = AGOPTA3Gate()
        let scoped = BackendAGOPTProfileAccess(require: { _, id, _ in try await gate.require(id) }, authorize: { _, _, _, _ in try await gate.authorize() }, rpc: { _ in .init(caller: .page, ownerID: "fixture") }, visibleRecord: { _, row in row["id"].string == "permitted" }, completeHistory: { _ in false })
        let deps = BackendAGOPTProfileService.Dependencies(dashboard: { _ in .object([.init("runtime", .object([.init("state", .string("working")), .init("id", .string("other")), .init("summary", .string("private job"))])), .init("stats", .object([.init("isAPIAccount", .bool(true)), .init("tokensMonth", .number(400))])), .init("tasks", .array([.object([.init("id", .string("permitted")), .init("account_id", .string("hidden-account"))]), .object([.init("id", .string("other"))])]))]) }, runs: { _, _ in [.object([.init("id", .string("permitted")), .init("accountID", .string("hidden-account")), .init("cwd", .string("/private/path"))]), .object([.init("id", .string("other"))])] }, budget: { _ in .object([.init("billing_kind", .string("api")), .init("unit", .string("usd")), .init("used", .number(20)), .init("tokens", .number(400))]) })
        let service = BackendAGOPTProfileService(configuration: config, ags: store, access: scoped, dependencies: deps)
        let native = BackendMCPCallContext(sessionID: "", machineID: "fixture", projectRoot: nil, attended: true, allowedTools: ["*"], allowedTiers: [.read, .alter], cancellation: BackendMCPCancellation())
        let value = try await service.profile("agent", call: .tool(native))
        XCTAssertEqual(value["runs"].elements?.count, 1); XCTAssertEqual(value["tasks"].elements?.count, 1)
        XCTAssertTrue(value["runs"].elements!.first!["accountID"].isNullish); XCTAssertTrue(value["runs"].elements!.first!["cwd"].isNullish)
        XCTAssertTrue(value["runtime"]["summary"].isNullish); XCTAssertTrue(value["stats"]["tokensMonth"].isNullish)
        XCTAssertTrue(value["budget"]["used"].isNullish); XCTAssertEqual(value["budget"]["coverage"].string, "scope-limited")
    }
    func testNativeOwnerFieldSavePreventsLaterCreatorFirstValueWidening() async throws {
        let (config, store) = try await fixture(); try await config.bindAGS(store)
        let created = try await config.saveAgentNarrowed(.object([.init("id", .string("second")), .init("name", .string("Second")), .init("provider", .string("claude"))]), callerKeyID: "creator")
        XCTAssertEqual(created["creatorKeyId"].string, "creator")
        XCTAssertFalse((created["keyInitializedFields"].elements ?? []).contains(.string("permissionMode")))
        let revision = try await store.currentRevision()
        _ = try await config.saveSettingsFieldOwner("second", field: "before_it_changes_files", value: .string("plan"), expectedRevision: revision)
        let restricted = try await config.agent("second")!
        XCTAssertTrue((restricted["keyInitializedFields"].elements ?? []).contains(.string("permissionMode")))
        let attempted = NativeRPCValue.object([.init("id", .string("second")), .init("field", .string("before_it_changes_files")), .init("value", .string("bypassPermissions"))])
        let review = try await config.prepareSettingsFieldChange(request: attempted, callerKeyID: "creator")
        XCTAssertEqual(review["needsApproval"].bool, true)
        let unchanged = try await config.agent("second"); XCTAssertEqual(unchanged?["permissionMode"].string, "plan")
    }
    func testInstructionsConflictAndKeepMineReviewDoNotRunAnyAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-a3-doc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("agent.md"); try Data("Original\n".utf8).write(to: file)
        let (config, _) = try await fixture(source: file.path), gate = AGOPTA3Gate()
        let authority = BackendFilesystemAuthority(scope: { _ in .local })
        let docs = BackendAGOPTProfileDocuments(authority: authority, access: access(gate), currentProfile: { try await config.agent($0) }, managedPath: { _ in nil })
        let found = try await config.agent("agent"), profile = try XCTUnwrap(found)
        let read = try await docs.read(call: call, id: "agent", profile: profile), revision = try XCTUnwrap(read["revision"].string)
        try Data("External edit\n".utf8).write(to: file)
        do { _ = try await docs.save(call: call, id: "agent", profile: profile, text: "Mine\n", hash: revision, keepMine: false); XCTFail("Conflict overwritten") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "file-changed") }
        let before = await gate.approvals; XCTAssertEqual(before, 0)
        let saved = try await docs.save(call: call, id: "agent", profile: profile, text: "Mine\n", hash: revision, keepMine: true)
        XCTAssertEqual(saved["body"].string, "Mine\n"); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Mine\n")
        let count = await gate.approvals; XCTAssertEqual(count, 1)
    }
    func testFileChangedDuringApprovalCannotBeReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-a3-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("agent.md"); try Data("Original\n".utf8).write(to: file)
        let (config, _) = try await fixture(source: file.path), gate = AGOPTA3Gate()
        let authority = BackendFilesystemAuthority(scope: { _ in .local })
        let docs = BackendAGOPTProfileDocuments(authority: authority, access: access(gate, after: { try Data("Third writer\n".utf8).write(to: file) }), currentProfile: { try await config.agent($0) }, managedPath: { _ in nil })
        let found = try await config.agent("agent"), profile = try XCTUnwrap(found)
        let read = try await docs.read(call: call, id: "agent", profile: profile)
        do { _ = try await docs.save(call: call, id: "agent", profile: profile, text: "Mine\n", hash: read["revision"].string!, keepMine: false); XCTFail("Late change overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Third writer\n")
    }
}
