import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor PCDecisionFleet {
    var live: [BackendSessionMeta] = []
    var starts = 0
    var sends = 0
    var hoot = 0
    var beforeStart: (@Sendable () async throws -> Void)?
    func setBeforeStart(_ effect: @escaping @Sendable () async throws -> Void) { beforeStart = effect }
    func start(_ task: BackendTaskRecord, agent: NativeRPCValue, folder: String) async throws -> BackendSessionMeta {
        try await beforeStart?()
        try await BackendPCDecisionDelivery.verify() // advertised final execution owner seam
        starts += 1
        let input = BackendCreateSessionInput(cwd: folder, provider: "claude")
        let session = BackendSessionMeta(id: UUID().uuidString, input: input, spawn: .init(provider: "claude", command: "/fixture/no-process", args: [], path: "/fixture", agentSessionId: UUID().uuidString))
        live.append(session); return session
    }
    func send() async throws { try await BackendPCDecisionDelivery.verify(); sends += 1 }
    func tell() { hoot += 1 }
    func stop(_ id: String) { if let index = live.firstIndex(where: { $0.id == id }) { live[index].exitCode = 0 } }
}
actor PCDecisionPending {
    private var task: Task<NativeRPCValue, Error>?
    func start(_ work: @escaping @Sendable () async throws -> NativeRPCValue) { task = Task { try await work() } }
    func value() async throws -> NativeRPCValue { guard let task else { throw NativeRPCError(code: "fixture", message: "The second decision never started.") }; return try await task.value }
}
actor PCDecisionLatch {
    private(set) var entered = false
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if open { return }; await withCheckedContinuation { waiting.append($0) } }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
}
final class PCDecisionWriter: @unchecked Sendable {
    let persistence: BackendTaskPersistence
    private let lock = NSLock()
    private var remaining: Int?
    init(_ persistence: BackendTaskPersistence) { self.persistence = persistence }
    func fail(after writes: Int = 1) { lock.withLock { remaining = writes } }
    func write(_ value: NativeRPCValue) throws {
        let refuse = lock.withLock { () -> Bool in
            guard let count = remaining else { return false }
            if count <= 1 { remaining = nil; return true }; remaining = count - 1; return false
        }
        if refuse { throw NativeRPCError(code: "fixture-write-failed", message: "Decision write failed") }
        try persistence.write("pc-decisions.json", value: value)
    }
}
actor PCDecisionAuthority {
    var allow = true
    var consent = true
    var confirmations = 0
    var changeAtVerify: (@Sendable () async throws -> Void)?
    var remainingVerifies = 0
    func revoke() { allow = false }
    func requireConfirmation(_ value: Bool) { consent = value }
    func changeOnVerify(_ body: @escaping @Sendable () async throws -> Void) { changeAtVerify = body; remainingVerifies = 2 }
    func verify(_ call: BackendPCDecisionCall) async throws -> String {
        guard allow else { throw NativeRPCError(code: "not-granted", message: "Scope revoked") }
        if let changeAtVerify {
            remainingVerifies -= 1
            if remainingVerifies <= 0 { self.changeAtVerify = nil; try await changeAtVerify() }
        }
        switch call { case .app: return "owner"; case .tool: return "key:fixture" }
    }
    var ownerGate: (@Sendable () async -> Void)?
    func setOwnerGate(_ gate: (@Sendable () async -> Void)?) { ownerGate = gate }
    func owner(_ call: BackendPCDecisionCall) async throws {
        if let gate = ownerGate { ownerGate = nil; await gate() }
        switch call { case .app: return; case .tool: confirmations += 1; guard consent else { throw NativeRPCError(code: "owner-not-answered", message: "The person has not answered") } }
    }
}

@MainActor final class PCDecisionsTests: XCTestCase {
    func testLiveCredentialIntersectionRefusesRevokedTasksTierFolderAndCRMOnly() throws {
        let original = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "key", tasks: true, folders: ["/work/allowed"])
        let key = NativeRPCValue.object([.init("id", .string("key")), .init("level", .string("full")), .init("tasks", .bool(true)), .init("folders", .array([.string("/work/allowed")]))])
        func check(_ snapshot: NativeRPCValue, _ ceiling: BackendDeckCoreSecurityCaller? = nil) throws {
            try BackendPCDecisionGrant.require(original: ceiling ?? original, current: original, key: snapshot, tool: "decisions.owner", folder: "/work/allowed/project", mutation: true)
        }
        XCTAssertNoThrow(try check(key))
        XCTAssertThrowsError(try check(key.setting("tasks", .bool(false))))
        XCTAssertThrowsError(try check(key.setting("level", .string("work"))))
        XCTAssertThrowsError(try check(key.setting("folders", .array([.string("/elsewhere")]))))
        XCTAssertThrowsError(try check(key.setting("crmOnly", .bool(true))))
        XCTAssertThrowsError(try check(.null))
        let limited = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "key", tasks: true, folders: ["/work/allowed"])
        XCTAssertThrowsError(try check(key, limited))
        let session = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "s", machineID: "m", projectRoot: "/work/allowed")
        let revoked = BackendDeckCoreSecurityCaller(kind: .session, tiers: [], sessionID: "s", machineID: "m", projectRoot: "/work/allowed")
        XCTAssertThrowsError(try BackendPCDecisionGrant.require(original: session, current: revoked, tool: "decisions.proposal", folder: "/work/allowed", mutation: true))
    }
    struct Rig {
        let root: URL, folder: String, persistence: BackendTaskPersistence, store: BackendTaskStore, config: BackendTaskConfiguration
        let engine: BackendTaskEngine, local: BackendTaskLocalService, service: BackendPCDecisions, fleet: PCDecisionFleet, writer: PCDecisionWriter, authority: PCDecisionAuthority
        let call = BackendPCDecisionCall.app(.init(caller: .nativeApp, ownerID: "fixture"))
        func source() async throws -> BackendTaskRecord { try await local.create(.object([.init("title", .string("Choose a launch approach")), .init("instructions", .string("Read the proposal and implement the approved approach.")), .init("project", .string(folder))])) }
        func get(_ id: String) async throws -> NativeRPCValue { try await service.perform("get", args: .object([.init("task", .string(id))]), call: call) }
        func act(_ id: String, _ action: String, _ extra: [NativeRPCValue.Field] = [], request: String = UUID().uuidString) async throws -> NativeRPCValue {
            let state = try await get(id)
            return try await service.perform(action, args: .object([.init("task", .string(id)), .init("expected", state["decision"]["revision"].number.map(NativeRPCValue.number) ?? .number(0)), .init("request", .string(request))] + extra), call: call)
        }
        func policy(_ source: String) async throws -> String {
            let value = try await act(source, "policy", [.init("name", .string("Owner reviews approach")), .init("mode", .string("owner-before-start")), .init("policyExpected", .number(0))])
            return try (value["policies"].elements?.last ?? .null)["id"].requireString("policy")
        }
        func bound(assigned: Bool = true) async throws -> String {
            let source = try await source(), policy = try await policy(source.id)
            _ = try await act(source.id, "bind", [.init("policy", .string(policy))])
            if assigned { _ = try await local.update(source.id, input: .object([.init("assignee", .string("worker"))])) }
            return source.id
        }
        func submit(_ id: String) async throws {
            _ = try await act(id, "draft", [.init("title", .string("Proposed approach")), .init("body", .string("Implement the requested local work.")), .init("rationale", .string("Small and reviewable."))])
            _ = try await act(id, "submit")
        }
    }
    func rig(capable: Bool = true, hootCapable: Bool = false, leadCapable: Bool = false, seed: NativeRPCValue? = nil) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-decisions-" + UUID().uuidString).resolvingSymlinksInPath()
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        let store = BackendTaskStore(persistence: persistence), config = try BackendTaskConfiguration(persistence: persistence), goals = BackendGoalStore(persistence: persistence)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(.object([.init("id", .string("worker")), .init("name", .string("Worker")), .init("provider", .string("claude"))]))
        let fleet = PCDecisionFleet(), writer = PCDecisionWriter(persistence), authority = PCDecisionAuthority()
        var access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.live }, start: { task, agent, folder, _, _ in try await fleet.start(task, agent: agent, folder: folder) }, send: { _, _ in try await fleet.send() }, stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "") }, tellHoot: { _ in await fleet.tell() })
        access.decisionSafeStart = capable; access.decisionSafeSend = capable
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access, workspace: { $0.project }, problem: { _ in })
        await engine.setDecisionExecutionOwners(hoot: hootCapable, lead: leadCapable)
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
        var decisionAccess = BackendPCDecisionAccess(verify: { call, _, _ in try await authority.verify(call) }, owner: { call, _, _ in try await authority.owner(call) })
        decisionAccess.project = { call, _, _ in _ = try await authority.verify(call) }
        let service = BackendPCDecisions(persistence: persistence, tasks: store, local: local, access: decisionAccess, writer: writer.write, finalWorkerValidation: capable, finalHootValidation: hootCapable, finalLeadValidation: leadCapable, nudge: { try await engine.releaseDecision($0, token: $1) })
        if let seed { try persistence.write("pc-decisions.json", value: seed) }
        await service.start(); await engine.setBusinessDecision { await service.heldReason($0) }; try await engine.start()
        addTeardownBlock { try? await engine.stop(); try? FileManager.default.removeItem(at: root) }
        return .init(root: root, folder: "/work/" + root.lastPathComponent, persistence: persistence, store: store, config: config, engine: engine, local: local, service: service, fleet: fleet, writer: writer, authority: authority)
    }
    func testProjectWorkflowNeedsNoTaskAndUsesOnlyItsOwnRevision() async throws {
        let r = try await rig()
        let args = NativeRPCValue.object([.init("project", .string(r.folder)), .init("name", .string("Project plan")), .init("mode", .string("off")), .init("policyExpected", .number(0)), .init("expected", .number(999)), .init("request", .string("project-create"))])
        let created = try await r.service.perform("policy", args: args, call: r.call)
        let policy = try XCTUnwrap(created["policies"].elements?.first)
        let tasks = try await r.store.all(); XCTAssertTrue(tasks.isEmpty)
        let replay = try await r.service.perform("policy", args: args, call: r.call)
        XCTAssertEqual(replay["replayed"], .bool(true))
        let edit = args.setting("policy", policy["id"]).setting("policyExpected", .number(1)).setting("request", .string("project-edit"))
        let edited = try await r.service.perform("policy", args: edit, call: r.call)
        XCTAssertEqual(edited["policies"].elements?.first?["revision"], .number(2))
        do { _ = try await r.service.perform("policy", args: edit.setting("request", .string("stale")), call: r.call); XCTFail("stale workflow") } catch {}
        do { _ = try await r.service.perform("policy", args: edit.setting("project", .string("/other")).setting("policyExpected", .number(2)).setting("request", .string("outside")), call: r.call); XCTFail("outside project") } catch {}
    }
    func testRealEngineHoldsUntilOwnerReleaseAndDeduplicatesIt() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.engine.accept(id); try await r.engine.pump()
        var count = await r.fleet.starts; XCTAssertEqual(count, 0)
        try await r.submit(id); _ = try await r.act(id, "approve")
        try await r.engine.pump(); count = await r.fleet.starts; XCTAssertEqual(count, 0)
        let before = try await r.get(id), args = NativeRPCValue.object([.init("task", .string(id)), .init("expected", before["decision"]["revision"]), .init("request", .string("release-one"))])
        let released = try await r.service.perform("release", args: args, call: r.call)
        XCTAssertEqual(released["started"], .bool(true))
        let repeated = try await r.service.perform("release", args: args, call: r.call)
        XCTAssertEqual(repeated["replayed"], .bool(true)); count = await r.fleet.starts; XCTAssertEqual(count, 1)
    }
    func testConcurrentOwnerReleasesStartOnlyOneWorker() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id); _ = try await r.act(id, "approve")
        let state = try await r.get(id), service = r.service, call = r.call
        let base = NativeRPCValue.object([.init("task", .string(id)), .init("expected", state["decision"]["revision"]), .init("request", .string("concurrent-release"))])
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask { do { _ = try await service.perform("release", args: base, call: call); return true } catch { return false } } }
            for await _ in group {}
        }
        let count = await r.fleet.starts; XCTAssertEqual(count, 1)
    }
    func testLastAuthorityAwaitTaskChangeAndRevocationRefuseEffects() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id)
        let state = try await r.get(id), store = r.store
        await r.authority.changeOnVerify { _ = try await store.update(id, patch: .object([.init("instructions", .string("Changed during the final authority await"))])) }
        do {
            _ = try await r.service.perform("approve", args: .object([.init("task", .string(id)), .init("expected", state["decision"]["revision"]), .init("request", .string("stale-owner"))]), call: r.call)
            XCTFail("stale authority await")
        } catch {}
        await r.authority.revoke()
        do { _ = try await r.service.perform("get", args: .object([.init("task", .string(id))]), call: r.call); XCTFail("revoked read") } catch {}
        let count = await r.fleet.starts; XCTAssertEqual(count, 0)
    }
    func testProductionCapabilityHoldsApprovedWorkWithoutLatentRelease() async throws {
        let r = try await rig(capable: false), id = try await r.bound()
        try await r.submit(id)
        let result = try await r.act(id, "approve-start")
        XCTAssertEqual(result["started"], .bool(false)); XCTAssertTrue(result["held"].string?.contains("NEEDS-HELPER") == true)
        XCTAssertEqual(result["decision"]["state"], .string("approved")); XCTAssertEqual(result["decision"]["released"], .bool(false))
        try await r.engine.accept(id); try await r.engine.pump(); let count = await r.fleet.starts; XCTAssertEqual(count, 0)
    }
    func testDefaultOffAndCRMFullPutsKeepExistingBehavior() async throws {
        let r = try await rig(), source = try await r.source()
        _ = try await r.store.put(source.value.removing("decisionEligible")) // full put may omit server-only eligibility
        let crmValue = source.value.removing("decisionEligible").setting("id", .string("crm:one")).setting("keyId", .string("crm")).setting("externalTaskId", .string("one")).setting("local", .bool(false))
        let crm = try await r.store.put(crmValue); _ = try await r.store.put(crm.value)
        XCTAssertFalse(crm.value.has("decisionEligible"))
        let hidden = try await r.service.perform("get", args: .object([.init("task", .string(crm.id))]), call: r.call)
        XCTAssertEqual(hidden["eligible"], .bool(false))
        _ = try await r.local.update(source.id, input: .object([.init("assignee", .string("worker"))]))
        let count = await r.fleet.starts; XCTAssertEqual(count, 1)
        let threaded = try await r.store.update(source.id, patch: .object([.init("crmThreadOf", .string("crm:one"))]))
        let view = try await r.service.perform("get", args: .object([.init("task", .string(threaded.id))]), call: r.call)
        XCTAssertEqual(view["eligible"], .bool(false))
    }
    func testMarkerCannotBeClearedAndCorruptStateHoldsOnlyRequiredTasks() async throws {
        let r = try await rig(), id = try await r.bound()
        do { _ = try await r.store.update(id, patch: .object([.init("decisionRequired", .bool(false)), .init("decisionPolicyID", .null)])); XCTFail("marker") } catch {}
        try Data("bad state".utf8).write(to: r.root.appendingPathComponent("pc-decisions.json"))
        let unavailable = BackendPCDecisions(persistence: r.persistence, tasks: r.store, local: r.local, access: .init(verify: { _, _, _ in "owner" }, owner: { _, _, _ in }), nudge: { _, _ in false })
        await unavailable.start(); await r.engine.setBusinessDecision { await unavailable.heldReason($0) }
        try await r.engine.accept(id); let count = await r.fleet.starts; XCTAssertEqual(count, 0)
        let normal = try await r.source(); _ = try await r.local.update(normal.id, input: .object([.init("assignee", .string("worker"))]))
        let after = await r.fleet.starts; XCTAssertEqual(after, 1)
    }
    func testDiscussionChangesRejectResubmitAndScopeInvalidation() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id); _ = try await r.act(id, "changes", [.init("text", .string("Explain the rollback."))])
        let changes = try await r.get(id); XCTAssertEqual(changes["decision"]["state"], .string("changes-requested"))
        try await r.submit(id); _ = try await r.act(id, "comment", [.init("text", .string("Ready for review."))]); _ = try await r.act(id, "reject", [.init("text", .string("Use another approach."))])
        try await r.submit(id); _ = try await r.act(id, "approve")
        _ = try await r.store.update(id, patch: .object([.init("instructions", .string("Changed scope"))]))
        do { _ = try await r.act(id, "release"); XCTFail("stale scope") } catch {}
        let count = await r.fleet.starts; XCTAssertEqual(count, 0)
        let state = try await r.get(id); XCTAssertGreaterThan(state["decision"]["history"].elements?.count ?? 0, 6)
    }
    func testStopAndLateScopeChangeAfterPreparationDoNotStart() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id); _ = try await r.act(id, "approve")
        let store = r.store
        await r.fleet.setBeforeStart { _ = try await store.update(id, patch: .object([.init("stopped", .bool(true))])) }
        _ = try await r.act(id, "release")
        let count = await r.fleet.starts; XCTAssertEqual(count, 0)
        let task = try await r.store.byID(id); XCTAssertEqual(task?.value["stopped"], .bool(true))
        do { _ = try await r.engine.reply(id, text: "Try again"); XCTFail("stopped decision") } catch {}
        let sends = await r.fleet.sends; XCTAssertEqual(sends, 0)
    }
    func testFailedUnbindWriteLeavesRequiredMarkerAndFailedReleaseStartsNothing() async throws {
        let r = try await rig(), id = try await r.bound(assigned: false)
        r.writer.fail()
        do { _ = try await r.act(id, "bind", [.init("policy", .null)]); XCTFail("write") } catch {}
        let marked = try await r.store.byID(id); XCTAssertEqual(marked?.value["decisionRequired"], .bool(true))
        _ = try await r.local.update(id, input: .object([.init("assignee", .string("worker"))])); try await r.submit(id); _ = try await r.act(id, "approve")
        r.writer.fail()
        do { _ = try await r.act(id, "release"); XCTFail("write") } catch {}
        try await r.engine.pump(); let count = await r.fleet.starts; XCTAssertEqual(count, 0)
    }
    func testCreateReceiptRetryReturnsSameBoundUnassignedTaskEvenAfterWriteFailure() async throws {
        let r = try await rig(), source = try await r.source(), policy = try await r.policy(source.id)
        let args = NativeRPCValue.object([.init("task", .string(source.id)), .init("expected", .number(0)), .init("request", .string("create-one")), .init("policy", .string(policy))])
        r.writer.fail(after: 2)
        var target: String?
        do { _ = try await r.service.perform("create", args: args, call: r.call); XCTFail("write") } catch let error as NativeRPCError { target = error.details["task"].string }
        XCTAssertNotNil(target)
        let repaired = try await r.service.perform("create", args: args, call: r.call)
        let repeated = try await r.service.perform("create", args: args, call: r.call)
        XCTAssertEqual(repaired["task"].string, target); XCTAssertEqual(repeated["task"].string, target)
        let tasks = try await r.store.all(); XCTAssertEqual(tasks.count, 2)
        let created = try XCTUnwrap(tasks.first { $0.id == target }); XCTAssertEqual(created.assigneeKind, "none"); XCTAssertEqual(created.value["decisionRequired"], .bool(true))
        let count = await r.fleet.starts; XCTAssertEqual(count, 0)
    }
    func testPersistenceReopenAndHootLeadCannotBypassHold() async throws {
        let r = try await rig(), id = try await r.bound(assigned: false)
        try await r.submit(id); _ = try await r.act(id, "approve")
        let reopened = BackendPCDecisions(persistence: r.persistence, tasks: r.store, local: r.local, access: .init(verify: { _, _, _ in "owner" }, owner: { _, _, _ in }), nudge: { _, _ in false })
        await reopened.start(); let value = try await reopened.perform("get", args: .object([.init("task", .string(id))]), call: r.call)
        XCTAssertEqual(value["decision"]["state"], .string("approved"))
        for kind in ["hoot", BackendAGTLeadSeats.kind] {
            _ = try await r.store.update(id, patch: .object([.init("assignee", BackendTaskLocalService.assignment(kind == "hoot" ? "hoot" : "lead:p", kind: kind))]))
            try await r.engine.accept(id)
            do { try await r.engine.reply(id, text: "Go anyway"); XCTFail("held") } catch {}
        }
        let starts = await r.fleet.starts, hoot = await r.fleet.hoot; XCTAssertEqual(starts, 0); XCTAssertEqual(hoot, 0)
    }
    func testActualMCPFactoryRequiresOwnerProofAndUsesSameNativeChannel() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id)
        let definitions = try BackendPCDecisionsMCP.definitions(service: r.service)
        let owner = try XCTUnwrap(definitions.first { $0.spec.id == "decisions.owner" })
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: nil, attended: true, allowedTools: ["decisions.owner"], allowedTiers: [.read, .act, .alter], cancellation: .init())
        let state = try await r.get(id)
        let args = NativeRPCValue.object([.init("action", .string("approve")), .init("task", .string(id)), .init("expected", state["decision"]["revision"]), .init("request", .string("mcp-approve")), .init("review", state["ownerReview"]), .init("owner", .bool(true))])
        await r.authority.requireConfirmation(false)
        let refused = try await owner.handler(context, args); XCTAssertTrue(refused.isError)
        var current = try await r.get(id); XCTAssertEqual(current["decision"]["state"], .string("submitted"))
        await r.authority.requireConfirmation(true)
        let accepted = try await owner.handler(context, args); XCTAssertFalse(accepted.isError)
        current = try await r.get(id); XCTAssertEqual(current["decision"]["state"], .string("approved")); XCTAssertEqual(current["decision"]["released"], .bool(false))
        let registry = NativeChannelRegistry()
        try await BackendPCDecisionsMCP.register(registry: registry, ownerID: "fixture", service: r.service, requireOwnerUI: { _ in })
        let read = try await registry.invoke("decisions:perform", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.object([.init("action", .string("get")), .init("task", .string(id))])])
        XCTAssertEqual(read["decision"], current["decision"])
    }

    func testCompletionDuringAuthoritativeDecisionAwaitCannotReleaseWork() async throws {
        let r = try await rig(), id = try await r.bound(), store = r.store
        await r.engine.setBusinessDecision { task in
            // Simulate an accepted authority read that was suspended while the task completed.
            _ = try? await store.update(task.id, patch: .object([.init("result", .object([.init("answer", .string("Finished while validation waited"))]))]))
            return nil
        }
        let reason = await r.engine.decisionReason(id)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("finished") == true)
        let starts = await r.fleet.starts; XCTAssertEqual(starts, 0)
    }

    /// Review paperclip #1: production turns on every owner whose final delivery revalidates (9d209a92).
    func testProductionTurnsOnTheValidatedExecutionOwners() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative")
        let decisions = try String(contentsOf: sources.appendingPathComponent("NativeCompositionPCDecisions.swift"), encoding: .utf8)
        XCTAssertTrue(decisions.contains("finalWorkerValidation: true, finalHootValidation: true, finalLeadValidation: true"))
        XCTAssertTrue(decisions.contains("engine.setDecisionExecutionOwners(hoot: true, lead: true)"))
        let tasks = try String(contentsOf: sources.appendingPathComponent("NativeCompositionProductionTasks.swift"), encoding: .utf8)
        XCTAssertTrue(tasks.contains("access.decisionSafeStart = true; access.decisionSafeSend = true"))
    }
    /// Review paperclip #8: "every task you handed on has finished" is not typed into a held decision-required worker.
    func testFinishedChildrenAreNotToldToAHeldDecisionParent() async throws {
        let r = try await rig(), id = try await r.bound()
        try await r.submit(id)
        let started = try await r.act(id, "approve-start")
        XCTAssertEqual(started["started"], .bool(true))
        _ = try await r.act(id, "changes", [.init("text", .string("Hold: change the approach first."))])
        let parent = try await r.store.byID(id)
        let live = await r.fleet.live
        XCTAssertTrue(live.contains { $0.id == parent?.sessionID && $0.exitCode == nil }, "the worker stays open while held")
        let child = NativeRPCValue.object([.init("id", .string("crm:child")), .init("title", .string("Handed-on part")), .init("instructions", .string("Do the handed-on part.")),
            .init("project", .string(r.folder)), .init("local", .bool(false)), .init("keyId", .string("crm")), .init("externalTaskId", .string("child")),
            .init("parentTaskId", .string(id)), .init("parentExternalTaskId", .string("parent")),
            .init("assignee", .object([.init("kind", .string(BackendAGTLeadSeats.kind)), .init("agentId", .string("seat:fixture"))])), .init("createdAt", .number(1))])
        _ = try await r.store.put(child)
        let before = await r.fleet.sends
        try await r.engine.seatSpoke("crm:child", kind: "completion", text: "The handed-on part is finished.")
        let after = await r.fleet.sends
        XCTAssertEqual(after, before)
    }
    /// Review paperclip #6: an owner prompt that waits for the person no longer blocks other decisions.
    func testWaitingOwnerPromptDoesNotBlockOtherDecisions() async throws {
        let r = try await rig(), first = try await r.bound(), second = try await r.bound()
        try await r.submit(first)
        let latch = PCDecisionLatch()
        await r.authority.setOwnerGate { await latch.wait() }
        let state = try await r.get(first), service = r.service, call = r.call
        let args = NativeRPCValue.object([.init("task", .string(first)), .init("expected", state["decision"]["revision"]), .init("request", .string("owner-waits"))])
        let pending = Task { try await service.perform("approve", args: args, call: call) }
        while !(await latch.entered) { await Task.yield() }
        let drafted = try await r.act(second, "draft", [.init("title", .string("Second approach")), .init("body", .string("Other local work.")), .init("rationale", .string("Independent."))])
        XCTAssertEqual(drafted["decision"]["state"], .string("draft"))
        await latch.release()
        let approved = try await pending.value
        XCTAssertEqual(approved["decision"]["state"], .string("approved"))
    }
    /// #338: a decision saved while another one saves waits its turn instead of being refused.
    func testDecisionsSavedAtOnceWaitTheirTurn() async throws {
        let r = try await rig(), first = try await r.bound(), second = try await r.bound()
        try await r.submit(first); try await r.submit(second)
        let service = r.service, call = r.call, one = try await r.get(first), two = try await r.get(second)
        let waiting = PCDecisionPending()
        let secondArgs = NativeRPCValue.object([.init("task", .string(second)), .init("expected", two["decision"]["revision"]), .init("request", .string("second-at-once"))])
        // The second arrives while the first holds the save (its check under the lock).
        await r.authority.changeOnVerify {
            await waiting.start { try await service.perform("approve", args: secondArgs, call: call) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let approved = try await service.perform("approve", args: .object([.init("task", .string(first)), .init("expected", one["decision"]["revision"]), .init("request", .string("first-at-once"))]), call: call)
        let alsoApproved = try await waiting.value()
        XCTAssertEqual(approved["decision"]["state"], .string("approved"))
        XCTAssertEqual(alsoApproved["decision"]["state"], .string("approved"))
    }
    /// Review paperclip #7: full receipt and record caps drop finished/missing tasks' entries instead of refusing forever.
    func testFullDecisionHistoryPrunesEntriesOfMissingTasks() async throws {
        var receipts: [NativeRPCValue.Field] = [], decisions: [NativeRPCValue.Field] = []
        for index in 0..<5000 { receipts.append(.init("gone-\(index % 2000):comment:\(index)", .object([.init("args", .object([.init("task", .string("gone-\(index % 2000)"))])), .init("result", .object([]))]))) }
        for index in 0..<2000 {
            decisions.append(.init("gone-\(index)", .object([.init("task", .string("gone-\(index)")), .init("revision", .number(1)), .init("proposalRevision", .number(1)),
                .init("state", .string("draft")), .init("history", .array([]))])))
        }
        let seed = NativeRPCValue.object([.init("v", .number(1)), .init("policies", .object([])), .init("decisions", .object(decisions)), .init("receipts", .object(receipts))])
        let r = try await rig(seed: seed), id = try await r.bound()
        let state = try await r.get(id)
        XCTAssertEqual(state["decision"]["state"], .string("draft"))
        let saved = try XCTUnwrap(try r.persistence.read("pc-decisions.json", maximumBytes: 16 * 1024 * 1024))
        XCTAssertLessThanOrEqual(saved["receipts"].spreadFields.count, 5000)
        XCTAssertEqual(saved["decisions"].spreadFields.count, 1)
    }
    func testExplicitProvenHootOwnerStartsOnlyAfterCurrentOwnerRelease() async throws {
        let r = try await rig(hootCapable: true), id = try await r.bound(assigned: false), fleet = r.fleet
        _ = try await r.local.update(id, input: .object([.init("assignee", .string("hoot"))]))
        await r.engine.setHootTaskTurns({ _, _ in
            try await BackendPCDecisionDelivery.verifyFinal(.input)
            await fleet.tell()
            return .init(answer: "Fixture finished", finished: true)
        })
        try await r.submit(id)
        _ = try await r.act(id, "approve")
        await r.engine.settleHootTurns()
        var count = await fleet.hoot; XCTAssertEqual(count, 0)
        let result = try await r.act(id, "release")
        XCTAssertEqual(result["decision"]["released"].bool, true)
        await r.engine.settleHootTurns()
        count = await fleet.hoot; XCTAssertEqual(count, 1)
    }
}
