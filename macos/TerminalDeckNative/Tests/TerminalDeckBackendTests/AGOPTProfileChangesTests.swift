import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct AGOPTProfileCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
}
final class AGOPTProfileChangesTests: XCTestCase, @unchecked Sendable {
    private func value(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func config() throws -> BackendTaskConfiguration { try .init(persistence: .init(directory: URL(fileURLWithPath: "/tmp/agopt-profiles-memory"), ownership: .memory)) }
    private func seed(_ config: BackendTaskConfiguration, ids: [String]) async throws {
        for id in ids { _ = try await config.saveAgent(.object([.init("id", .string(id)), .init("name", .string(id)), .init("provider", .string("claude")), .init("keepAliveUntilClose", .bool(false)), .init("allowedTools", .array([.string("Read")])), .init("permissionMode", .string("plan")), .init("maxRunMinutes", .number(60))])) }
    }
    private func batch(ids: [String], patch: NativeRPCValue) -> NativeRPCValue { .object([.init("do", .string("save-many")), .init("ids", .array(ids.map(NativeRPCValue.string))), .init("agent", patch)]) }
    func testExactCreatorBackfillAndAmbiguityGrantNothing() throws {
        let profile = try value(#"{"id":"worker","creatorKeyId":null,"keyInitializedFields":[]}"#)
        let row = try value(#"{"action":"tasks.save","outcome":"ok","caller":{"keyId":"creator"},"args":{"agent":{"id":"worker","allowedTools":["Read"]}}}"#)
        let repaired = BackendAGOPTProfileCreators.backfill(profile, rows: [row])
        XCTAssertEqual(repaired["creatorKeyId"].string, "creator")
        XCTAssertEqual(repaired["keyInitializedFields"].elements?.compactMap(\.string), ["allowedTools"])
        let conflict = row.setting("caller", .object([.init("keyId", .string("another"))]))
        XCTAssertTrue(BackendAGOPTProfileCreators.backfill(profile, rows: [row, conflict])["creatorKeyId"].isNullish)
        XCTAssertTrue(BackendAGOPTProfileCreators.backfill(profile, rows: [row.setting("outcome", .string("refused"))])["creatorKeyId"].isNullish)
        XCTAssertTrue(BackendAGOPTProfileCreators.backfill(profile, rows: [row.setting("operation", .string("update"))])["creatorKeyId"].isNullish)
        XCTAssertTrue(BackendAGOPTProfileCreators.backfill(profile, rows: [row.setting("args", .object([.init("agent", .object([.init("id", .string("other")), .init("name", .string("worker"))]))]))])["creatorKeyId"].isNullish)
    }
    func testCreatorCanSelectUninitializedPermissionOtherKeyCannotAndKeepOpenStillWidens() throws {
        let raw = try value(#"{"id":"worker","allowedTools":["Read"],"permissionMode":"plan","keepAliveUntilClose":false,"keyInitializedFields":[]}"#)
        let log = try value(#"{"tool":"tasks.save","outcome":"ok","keyId":"creator","args":{"id":"worker","allowedTools":["Read"]}}"#)
        let profile = BackendAGOPTProfileCreators.backfill(raw, rows: [log])
        let choice = try value(#"{"permissionMode":"acceptEdits"}"#)
        XCTAssertEqual(try BackendTAGProfilePolicy.validate(input: choice, existing: profile, callerKeyID: "creator")["permissionMode"].string, "acceptEdits")
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: choice, existing: profile, callerKeyID: "another"))
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: value(#"{"keepAliveUntilClose":true}"#), existing: profile, callerKeyID: "creator"))
        XCTAssertEqual(try BackendTAGProfilePolicy.validate(input: value(#"{"keepAliveUntilClose":false}"#), existing: profile, callerKeyID: "creator")["keepAliveUntilClose"].bool, false)
    }
    func testBackfillReadsLogWithoutWritingAndLoaderKeepsExactSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-history-" + UUID().uuidString)
        let remote = root.appendingPathComponent("remote"), log = root.appendingPathComponent("hoot-log/actions.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(#"{"action":"tasks.save","outcome":"ok","keyId":"exact-key","args":{"agent":{"id":"worker","allowedTools":["Read"]}}}"#.utf8)
        try bytes.write(to: log)
        let persistence = try BackendTaskPersistence(directory: remote, ownership: .exclusive)
        let first = try BackendTaskConfiguration(persistence: persistence); try await first.start(); try await seed(first, ids: ["worker"])
        let originalConfig = try Data(contentsOf: remote.appendingPathComponent("task-config.json"))
        let loaded = try BackendTaskConfiguration(persistence: persistence); try await loaded.start()
        let row = try await loaded.agent("worker"); XCTAssertEqual(row?["creatorKeyId"].string, "exact-key")
        XCTAssertEqual(try Data(contentsOf: log), bytes)
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent("task-config.json")), originalConfig)
    }
    func testGrouped24CardAndAllowAppliesExactlyAllReviewedRowsAndAGS() async throws {
        let config = try config(); try await config.start()
        let ids = (1...24).map { "agent-" + String($0) }; try await seed(config, ids: ids)
        let store = BackendAGSStore(persistence: try .init(directory: URL(fileURLWithPath: "/tmp/agopt-ags-memory"), ownership: .memory), cipher: AGOPTProfileCipher())
        try await store.start(); try await config.bindAGS(store)
        let request = batch(ids: ids, patch: try value(#"{"keepAliveUntilClose":true}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "commander")
        XCTAssertEqual(plan["count"].number, 24); XCTAssertTrue(plan["summary"].string!.contains("keep 24 agents open until you close them")); XCTAssertEqual(plan["names"].elements?.count, 24)
        for id in ids { let row = try await config.agent(id); XCTAssertEqual(row?["keepAliveUntilClose"].bool, false) }
        let saved = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "commander")
        XCTAssertEqual(saved.count, 24)
        for id in ids { let row = try await config.agent(id), settings = try await store.profile(id); XCTAssertEqual(row?["keepAliveUntilClose"].bool, true); XCTAssertTrue(settings!.keepOpen) }
    }
    func testDenyLeavesAllWideningsUnchangedAndMixedNarrowFieldsApplyAtOnce() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        let request = batch(ids: ["one", "two"], patch: try value(#"{"keepAliveUntilClose":true,"skillsOff":true}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key")
        XCTAssertTrue(plan["needsApproval"].bool!)
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertEqual(row?["skillsOff"].bool, true); XCTAssertEqual(row?["keepAliveUntilClose"].bool, false) }
        // The Deny path never calls applyApprovedAgentChanges.
        let replay = try await config.prepareAgentChanges(request: request, callerKeyID: "key"); XCTAssertEqual(replay["planId"], plan["planId"])
    }
    func testMixedAgentBatchOnlyRequestsTheAgentWhoseToolListWidens() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        let foundCurrent = try await config.agent("two"); let current = try XCTUnwrap(foundCurrent)
        _ = try await config.saveAgent(current.setting("allowedTools", .array([.string("Read"), .string("Bash")])) )
        let request = batch(ids: ["one", "two"], patch: try value(#"{"allowedTools":["Read","Bash"],"skillsOff":true}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key")
        XCTAssertEqual(plan["count"].number, 1); XCTAssertEqual(plan["names"].elements?.first?.string, "one")
        let two = try await config.agent("two"); XCTAssertTrue(two?["skillsOff"].bool == true)
        _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key")
        let one = try await config.agent("one"); XCTAssertEqual(one?["allowedTools"].elements?.compactMap(\.string), ["Read", "Bash"])
    }
    func testInitializedPermissionsAndToolsWidenTogetherOnlyAfterOwnerApply() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        let request = batch(ids: ["one"], patch: try value(#"{"permissionMode":"acceptEdits","allowedTools":["Read","Bash"]}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key")
        XCTAssertTrue(plan["needsApproval"].bool!); XCTAssertEqual(plan["count"].number, 1)
        let waiting = try await config.agent("one"); XCTAssertEqual(waiting?["permissionMode"].string, "plan"); XCTAssertEqual(waiting?["allowedTools"].elements?.count, 1)
        _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key")
        let allowed = try await config.agent("one"); XCTAssertEqual(allowed?["permissionMode"].string, "acceptEdits"); XCTAssertEqual(allowed?["allowedTools"].elements?.count, 2)
    }
    func testMissingCreatorConcurrencyCannotWidenWithoutExactOwnerPlan() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        // PARALLEL-JOBS: no limit (0) is the default; widening is raising a set number, here 1.
        let seeded = try await config.agent("one"); _ = try await config.saveAgent(seeded!.setting("maxConcurrent", .number(1)))
        let current = try await config.agent("one"); XCTAssertTrue(current?["creatorKeyId"].isNullish == true)
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: value(#"{"maxConcurrent":2}"#), existing: current, callerKeyID: "key"))
        let plan = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: value(#"{"maxConcurrent":2}"#)), callerKeyID: "key")
        XCTAssertTrue(plan["needsApproval"].bool!)
        let waiting = try await config.agent("one"); XCTAssertEqual(waiting?["maxConcurrent"].number, 1)
        _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key")
        let allowed = try await config.agent("one"); XCTAssertEqual(allowed?["maxConcurrent"].number, 2)
    }
    func testMissingCreatorRuntimeCannotRemoveLimitWithoutExactOwnerPlan() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        let current = try await config.agent("one")
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: value(#"{"maxRunMinutes":0}"#), existing: current, callerKeyID: "key"))
        let plan = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: value(#"{"maxRunMinutes":0}"#)), callerKeyID: "key")
        XCTAssertTrue(plan["needsApproval"].bool!)
        let waiting = try await config.agent("one"); XCTAssertEqual(waiting?["maxRunMinutes"].number, 60)
        _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key")
        let allowed = try await config.agent("one"); XCTAssertEqual(allowed?["maxRunMinutes"].number, 0)
    }
    func testShorteningKeepOpenAppliesImmediatelyWithoutWidePlan() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        let found = try await config.agent("one"), old = try XCTUnwrap(found)
        _ = try await config.saveAgent(old.setting("keepAliveUntilClose", .bool(true)))
        let plan = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: value(#"{"keepAliveUntilClose":false}"#)), callerKeyID: "key")
        XCTAssertEqual(plan["needsApproval"].bool, false)
        let narrowed = try await config.agent("one"); XCTAssertEqual(narrowed?["keepAliveUntilClose"].bool, false)
    }
    func testCodexAndGeminiPermissionsNarrowImmediatelyAndWidenOnlyByOwnerPlan() async throws {
        for (provider, loose, strict) in [("codex", "workspace-write", "read-only"), ("gemini", "auto_edit", "plan")] {
            let config = try config(); try await config.start()
            _ = try await config.saveAgent(.object([.init("id", .string("one")), .init("name", .string("one")), .init("provider", .string(provider)), .init("permissionMode", .string(loose))]))
            let store = BackendAGSStore(persistence: try .init(directory: URL(fileURLWithPath: "/tmp/agopt-mode-memory"), ownership: .memory), cipher: AGOPTProfileCipher())
            try await store.start(); try await config.bindAGS(store)
            let narrow = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: .object([.init("permissionMode", .string(strict))])), callerKeyID: "key")
            XCTAssertEqual(narrow["needsApproval"].bool, false)
            let read = try await config.agent("one"); XCTAssertEqual(read?["permissionMode"].string, strict)
            let wide = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: .object([.init("permissionMode", .string(loose))])), callerKeyID: "key")
            XCTAssertEqual(wide["needsApproval"].bool, true)
            _ = try await config.applyApprovedAgentChanges(planID: wide["planId"].string!, callerKeyID: "key")
            let changed = try await config.agent("one"), settings = try await store.profile("one")
            XCTAssertEqual(changed?["permissionMode"].string, loose); XCTAssertEqual(settings?.permissionMode, loose)
        }
    }
    func testReturningToInheritedPermissionsRequiresOwnerAndUnknownModesStayRejected() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        for patch in [try value(#"{"permissionMode":"default"}"#), try value(#"{"permissionMode":null}"#)] {
            let plan = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: patch), callerKeyID: "key")
            XCTAssertTrue(plan["needsApproval"].bool!)
            let waiting = try await config.agent("one"); XCTAssertEqual(waiting?["permissionMode"].string, "plan")
        }
        do { _ = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: value(#"{"permissionMode":"invented-mode"}"#)), callerKeyID: "key"); XCTFail("Unknown provider permission accepted") } catch {}
    }
    func testAskFirstCommandAndKeepOpenShareOneFrozenPlanAndDenyChangesNeither() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        let request = batch(ids: ["one", "two"], patch: try value(#"{"verifyCommand":"echo reviewed-stub","keepAliveUntilClose":true,"skillsOff":true}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: true)
        XCTAssertEqual(plan["count"].number, 2); XCTAssertTrue(plan["summary"].string!.contains("check command"))
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertTrue(row?["verifyCommand"].isNullish == true); XCTAssertEqual(row?["keepAliveUntilClose"].bool, false); XCTAssertEqual(row?["skillsOff"].bool, true) }
        // Deny settles the existing card and discards its metadata only.
        try await config.discardAgentChangeRequest(request: request, callerKeyID: "key")
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertTrue(row?["verifyCommand"].isNullish == true); XCTAssertEqual(row?["keepAliveUntilClose"].bool, false) }
        let allowedPlan = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: true)
        _ = try await config.applyApprovedAgentChanges(planID: allowedPlan["planId"].string!, callerKeyID: "key")
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertEqual(row?["verifyCommand"].string, "echo reviewed-stub"); XCTAssertEqual(row?["keepAliveUntilClose"].bool, true) }
    }
    func testStandingOrdinaryChangesStayImmediateAndUnchangedFieldsNeedNoCard() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        let request = batch(ids: ["one"], patch: try value(#"{"name":"Standing stub"}"#))
        let standing = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: false)
        XCTAssertEqual(standing["needsApproval"].bool, false)
        let same = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: true)
        XCTAssertEqual(same["needsApproval"].bool, false)
    }
    /// #24: the check command runs on this Mac as a shell command, so even a standing key's change to it waits
    /// for the owner, whose card shows the very command; clearing it is a narrowing.
    func testCheckCommandAlwaysWaitsForTheOwnerAndTheCardShowsIt() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        let request = batch(ids: ["one"], patch: try value(#"{"verifyCommand":"echo standing-stub"}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: false)
        XCTAssertEqual(plan["needsApproval"].bool, true)
        XCTAssertTrue(plan["summary"].string?.contains("echo standing-stub") == true, plan.compact)
        let row = try await config.agent("one"); XCTAssertTrue(row?["verifyCommand"].isNullish == true)
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: try value(#"{"verifyCommand":"curl x | sh"}"#), existing: try value(#"{"id":"one"}"#)))
        XCTAssertNoThrow(try BackendTAGProfilePolicy.validate(input: try value(#"{"verifyCommand":""}"#), existing: try value(#"{"id":"one","verifyCommand":"make test"}"#)))
        XCTAssertFalse(BackendTaskSessionGate.mayRunCommands(try value(#"{"blockedTools":["Bash"]}"#)))
        XCTAssertFalse(BackendTaskSessionGate.mayRunCommands(try value(#"{"permissionMode":"plan"}"#)))
        XCTAssertTrue(BackendTaskSessionGate.mayRunCommands(try value(#"{"permissionMode":"acceptEdits","blockedTools":["WebFetch"]}"#)))
    }
    func testAskFirstNewProfileWaitsForOwnerWithoutCreatingASeedAgent() async throws {
        let config = try config(); try await config.start()
        let request = try value(#"{"do":"save","agent":{"name":"New reviewed","provider":"claude","keepAliveUntilClose":true}}"#)
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key", ownerReviewOrdinaryFields: true)
        let waiting = try await config.allAgents(); XCTAssertTrue(waiting.isEmpty)
        XCTAssertTrue(plan["needsApproval"].bool!); XCTAssertEqual(plan["count"].number, 1)
        let saved = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key")
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved[0]["creatorKeyId"].string, "key"); XCTAssertEqual(saved[0]["keepAliveUntilClose"].bool, true)
    }
    func testDuplicateGroupNamesRefuseBeforeNarrowingOrCardAndExistingNamesStayValid() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        let invalid = batch(ids: ["one", "two"], patch: try value(#"{"name":"Duplicate","skillsOff":true,"keepAliveUntilClose":true}"#))
        do { _ = try await config.prepareAgentChanges(request: invalid, callerKeyID: "key", ownerReviewOrdinaryFields: true); XCTFail("Duplicate group names accepted") } catch {}
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertEqual(row?["name"].string, id); XCTAssertEqual(row?["skillsOff"].bool, false) }
        let valid = try await config.prepareAgentChanges(request: batch(ids: ["one", "two"], patch: value(#"{"keepAliveUntilClose":true}"#)), callerKeyID: "key", ownerReviewOrdinaryFields: true)
        XCTAssertEqual(valid["count"].number, 2)
        _ = try await config.applyApprovedAgentChanges(planID: valid["planId"].string!, callerKeyID: "key")
    }
    func testTaskReadSeparatesRequestedAndLaunchChoicesAndOmitsPrivateHashes() throws {
        let task = try BackendTaskRecord(value(#"{"id":"local:one","keyId":"local","externalTaskId":"one","model":"requested-new","effort":"low","tokenBudget":200,"agoptModel":"launched-old","agoptEffort":"high","agoptTaskTokenBudget":100,"tokenUsage":80,"agoptSettingsSignature":"private-hash","agoptProfileID":"private-account","agoptUsageTotal":1000000}"#))
        let read = BackendTaskMCP.efficiencyView(task)
        XCTAssertEqual(read["model"].string, "requested-new"); XCTAssertEqual(read["effective_model"].string, "launched-old")
        XCTAssertEqual(read["effort"].string, "low"); XCTAssertEqual(read["effective_effort"].string, "high")
        XCTAssertEqual(read["token_budget"].number, 200); XCTAssertEqual(read["effective_token_budget"].number, 100); XCTAssertEqual(read["token_usage"].number, 80)
        XCTAssertFalse(read.compact.contains("private-hash")); XCTAssertFalse(read.compact.contains("private-account")); XCTAssertFalse(read.compact.contains("1000000"))
        let unknown = try BackendTaskRecord(value(#"{"id":"local:new","keyId":"local","externalTaskId":"new"}"#))
        XCTAssertTrue(BackendTaskMCP.efficiencyView(unknown)["token_usage"].isNullish)
    }
    func testFreeKeyReadResolvesInheritedControlsWithoutInheritedPrivateFields() async throws {
        let store = BackendAGSStore(persistence: try .init(directory: URL(fileURLWithPath: "/tmp/agopt-read-memory"), ownership: .memory), cipher: AGOPTProfileCipher())
        try await store.start()
        let defaults = AGSAgentSettings(model: "app-model", effort: "high", permissionMode: "plan", mcpServers: ["private-server": true], hooks: [.init(command: "echo inherited-private-command")], environment: ["TEST_SECRET": "inherited-private-secret"], workingFolder: "/private/owner-folder", efficiency: .init(agentTokenBudget: 9000, taskTokenBudget: 1000))
        try await store.saveDefaults(.init(providers: ["claude": defaults]), expectedRevision: 0)
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .key, keyID: "actual-key") }, knownFolder: { _, path in path }, session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "stub") }, authorize: { _, _, _, _, _, _ in XCTFail("A free profile read asked for approval") }, record: { _, _, _, _ in })
        let hooks = BackendAGSHookRunner(execute: { _, _ in XCTFail("Reading controls executed a hook") })
        let tools = try BackendAGSMCP.definitions(store: store, hooks: hooks, access: access, scope: .init(require: { _, id, mutation in XCTAssertEqual(id, "worker"); XCTAssertFalse(mutation) }, baseProfile: { _ in .init() }))
        let context = BackendMCPCallContext(sessionID: "", machineID: "stub", projectRoot: nil, attended: true, allowedTools: Set(BackendAGSMCP.toolIDs), allowedTiers: [.read], cancellation: .init())
        let reply = try await tools[0].handler(context, .object([.init("profile", .string("worker"))]))
        XCTAssertFalse(reply.isError)
        let value = try XCTUnwrap(reply.structuredContent), effective = value["effective"]
        XCTAssertEqual(effective["model"].string, "app-model"); XCTAssertEqual(effective["effort"].string, "high"); XCTAssertEqual(effective["permissionMode"].string, "plan")
        XCTAssertEqual(effective["efficiency"]["agentTokenBudget"].number, 9000); XCTAssertEqual(effective["efficiency"]["taskTokenBudget"].number, 1000)
        XCTAssertTrue(value["settings"]["model"].isNullish); XCTAssertEqual(value["revision"].number, 1)
        for key in ["hooks", "environment", "mcpServers", "workingFolder"] { XCTAssertTrue(effective[key].isNullish) }
        XCTAssertFalse(value.compact.contains("inherited-private")); XCTAssertFalse(value.compact.contains("private-server")); XCTAssertFalse(value.compact.contains("owner-folder"))
    }
    func testOverLimitDuplicatesAndUnknownRejectBeforeAnyNarrowing() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        for ids in [Array(repeating: "one", count: 51), ["one", "one"], ["one", "unknown"]] {
            do { _ = try await config.prepareAgentChanges(request: batch(ids: ids, patch: value(#"{"skillsOff":true}"#)), callerKeyID: "key"); XCTFail("Bad batch accepted") } catch {}
            let one = try await config.agent("one"); XCTAssertEqual(one?["skillsOff"].bool, false)
        }
    }
    func testStaleReviewAndAnotherKeyCannotApplyAnyWidening() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one", "two"])
        let plan = try await config.prepareAgentChanges(request: batch(ids: ["one", "two"], patch: value(#"{"keepAliveUntilClose":true}"#)), callerKeyID: "key")
        do { _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "another"); XCTFail("Another key applied plan") } catch {}
        let foundOld = try await config.agent("two"); let old = try XCTUnwrap(foundOld); _ = try await config.saveAgent(old.setting("name", .string("Changed by owner")))
        do { _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].string!, callerKeyID: "key"); XCTFail("Stale card applied") } catch {}
        for id in ["one", "two"] { let row = try await config.agent(id); XCTAssertEqual(row?["keepAliveUntilClose"].bool, false) }
    }
    func testPureNarrowingStillWorksAtReviewCapAndSettlementRemovesOnlyPlan() async throws {
        let config = try config(); try await config.start(); try await seed(config, ids: ["one"])
        for count in 0..<50 {
            let request = batch(ids: ["one"], patch: .object([.init("keepAliveUntilClose", .bool(true)), .init("keepAliveMinutes", .number(Double(count + 100)))]))
            _ = try await config.prepareAgentChanges(request: request, callerKeyID: "key")
        }
        let narrow = try await config.prepareAgentChanges(request: batch(ids: ["one"], patch: value(#"{"skillsOff":true}"#)), callerKeyID: "key")
        XCTAssertEqual(narrow["needsApproval"].bool, false)
        let request = batch(ids: ["one"], patch: try value(#"{"keepAliveUntilClose":true}"#))
        do { _ = try await config.prepareAgentChanges(request: request, callerKeyID: "key"); XCTFail("Wide cap ignored") } catch {}
        let first = batch(ids: ["one"], patch: .object([.init("keepAliveUntilClose", .bool(true)), .init("keepAliveMinutes", .number(100))]))
        try await config.discardAgentChangeRequest(request: first, callerKeyID: "key")
        let next = try await config.prepareAgentChanges(request: request, callerKeyID: "key"); XCTAssertTrue(next["needsApproval"].bool!)
        let kept = try await config.agent("one"); XCTAssertEqual(kept?["skillsOff"].bool, true); XCTAssertEqual(kept?["keepAliveUntilClose"].bool, false)
    }
    func testPendingPlanSurvivesReloadAndFrontmatterCannotSetEitherKeepOpenValue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-plan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root.appendingPathComponent("remote"), ownership: .exclusive)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start(); try await seed(config, ids: ["one", "two"])
        let request = batch(ids: ["one", "two"], patch: try value(#"{"keepAliveUntilClose":true}"#))
        let plan = try await config.prepareAgentChanges(request: request, callerKeyID: "key")
        let reloaded = try BackendTaskConfiguration(persistence: persistence); try await reloaded.start()
        let retained = try await reloaded.prepareAgentChanges(request: request, callerKeyID: "key"); XCTAssertEqual(retained["planId"], plan["planId"])
        _ = try await reloaded.applyApprovedAgentChanges(planID: retained["planId"].string!, callerKeyID: "key")
        let definition = try XCTUnwrap(BackendTAGAgentImport.parse("---\nname: file-agent\ndescription: safe\nkeepAliveUntilClose: true\nkeepAliveMinutes: 1440\n---\nDo work."))
        XCTAssertTrue(definition.profile["keepAliveUntilClose"].isNullish); XCTAssertTrue(definition.profile["keepAliveMinutes"].isNullish)
    }
}
