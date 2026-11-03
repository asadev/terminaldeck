import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor HOOTSIMRoutingFixture {
    var identity = "hoot-scratch"
    var ledger: [NativeRPCValue] = []
    var allow = true
    var denyApproval = false
    var failDispatch = false
    var failSavingDispatch = false
    var failSavingSent = false
    var failedLoads = 0
    var approvals = 0
    var sends = 0
    var targetID = "portal-mechanic"
    var targetRevision = "profile-one"
    var approvalHook: (@Sendable () async throws -> Void)?
    var pause: CheckedContinuation<Void, Never>?
    var holdApproval = false
    func require() throws { if !allow { throw NativeRPCError(code: "not-granted", message: "Owner changed") } }
    func conversationID() -> String { identity }
    func values() -> [NativeRPCValue] { ledger }
    func load() throws -> [NativeRPCValue] {
        if failedLoads > 0 { failedLoads -= 1; throw NativeRPCError(code: "scratch-disk", message: "Hoot's chat is busy") }
        return ledger
    }
    func failingLoads(_ count: Int) { failedLoads = count }
    func failingSentSave() { failSavingSent = true }
    func append(_ row: NativeRPCValue) throws {
        if failSavingDispatch && row["status"].string == "dispatching" { throw NativeRPCError(code: "scratch-disk", message: "Cannot save") }
        if failSavingSent && row["status"].string == "sent" { throw NativeRPCError(code: "scratch-disk", message: "Cannot save") }
        ledger.append(row)
    }
    func resolve(_ request: NativeRPCValue) -> NativeRPCValue {
        let selected = request["target"]["id"].string ?? targetID
        let target = NativeRPCValue.object([.init("id", .string(selected)), .init("kind", .string("agent")),
            .init("name", .string("Portal mechanic")), .init("role", .string("Portal")), .init("projectId", .string("crm")),
            .init("projectName", .string("CRM")), .init("revision", .string(targetRevision)), .init("folder", .string("/scratch/crm"))])
        return .object([.init("target", target), .init("source", request["source"]), .init("reason", .string("Owns the portal.")),
            .init("evidence", .array([.string("Current agent role")]))])
    }
    func approve() async throws {
        approvals += 1
        if let approvalHook { try await approvalHook() }
        if holdApproval { await withCheckedContinuation(isolation: self) { pause = $0 } }
        if denyApproval { throw BackendDeckCoreSecurityRefusal(.declined, "Owner said no") }
    }
    func dispatch() throws -> NativeRPCValue {
        sends += 1
        if failDispatch { throw NativeRPCError(code: "lost-reply", message: "The result was lost after dispatch began") }
        return .object([.init("taskId", .string("local:scratch-task"))])
    }
    func changeTarget() { targetRevision = "profile-two" }
    func revoke() { allow = false }
    func rebind() { identity = "different-chat" }
    func setApprovalHook(_ hook: (@Sendable () async throws -> Void)?) { approvalHook = hook }
    func denied() { denyApproval = true }
    func failingDispatch() { failDispatch = true }
    func failingSave() { failSavingDispatch = true }
    func hold() { holdApproval = true }
    func release() { holdApproval = false; pause?.resume(); pause = nil }
    func counts() -> (Int, Int) { (approvals, sends) }
    func replaceLedger(_ rows: [NativeRPCValue]) { ledger = rows }
}
// Three HOOTSIM tests stay in macos/round7/HOOTSIM-routing-drafts/HOOTSIMRoutingTests.swift with
// the patches they prove (HOOTSIM-session-approval.patch, HOOTSIM-policy-tool-hook.patch): direct
// Hoot session starts/sends asking every time, and Hoot's MCP lease listing. They are not part of #90's
// routing cards, which these tests cover: a card never asks or sends until the owner approves it.
final class HOOTSIMRoutingTests: XCTestCase, @unchecked Sendable {
    typealias V = NativeRPCValue
    private func caller() -> BackendMCPCallContext {
        BackendDeckToolsMachinesPortNativeContext()
    }
    private var request: V {
        .object([.init("problem", .string("The portal login loops")), .init("source", .object([.init("kind", .string("browser")),
            .init("folder", .string("/scratch/crm")), .init("projectId", .string("crm")), .init("attachmentId", .string("saved-snip-one"))])),
            .init("attachments", .array([.object([.init("id", .string("saved-snip-one")), .init("name", .string("Login snip"))])]))])
    }
    private func routing(_ fixture: HOOTSIMRoutingFixture) -> BackendHOOTSIMRouting {
        BackendHOOTSIMRouting(.init(require: { _ in try await fixture.require() }, conversationID: { await fixture.conversationID() },
            load: { try await fixture.load() }, append: { try await fixture.append($0) },
            resolve: { _, request in await fixture.resolve(request) }, authorize: { _, _ in try await fixture.approve() },
            dispatch: { _, _ in try await fixture.dispatch() }))
    }
    private func dispatch(_ card: V, on routing: BackendHOOTSIMRouting) async throws -> V {
        try await routing.dispatch(try card["id"].requireString("id"), revision: card["revision"].requireString("revision"), caller: caller())
    }
    func testProposeAndReadPersistTheCardWithoutAskingOrSending() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        XCTAssertEqual(card["status"].string, "pending")
        XCTAssertEqual(card["problem"].string, "The portal login loops")
        let read = try await routing.read(caller())
        XCTAssertEqual(read["proposals"].elements?.count, 1)
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        let ledger = await fixture.values(); XCTAssertEqual(ledger.count, 1)
    }
    func testApprovedDispatchCallsOnceAndDuplicateRequestsReuseTheResult() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        let first = try await dispatch(card, on: routing), again = try await dispatch(card, on: routing)
        XCTAssertEqual(first["status"].string, "sent"); XCTAssertEqual(first, again)
        XCTAssertEqual(first["taskId"].string, "local:scratch-task")
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        let states = await fixture.values().compactMap { $0["status"].string }
        XCTAssertEqual(states, ["pending", "approving", "dispatching", "sent"])
    }
    func testDenialNeverDispatchesAndKeepsTheProblemAndAttachmentReference() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.denied()
        let card = try await routing.propose(request, caller: caller())
        do { _ = try await dispatch(card, on: routing); XCTFail("Denied proposal sent") } catch {}
        let rows = try await routing.read(caller())["proposals"].elements ?? []
        XCTAssertEqual(rows.first?["status"].string, "pending")
        XCTAssertEqual(rows.first?["request"]["attachments"], request["attachments"])
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 0)
    }
    func testTargetChangeDuringApprovalRefusesBeforeAnySend() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.setApprovalHook { await fixture.changeTarget() }
        let card = try await routing.propose(request, caller: caller())
        do { _ = try await dispatch(card, on: routing); XCTFail("Changed profile sent") } catch {}
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 0)
    }
    func testRevokedAuthorityAndReboundChatAreCheckedAfterApproval() async throws {
        for changesChat in [false, true] {
            let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
            await fixture.setApprovalHook { if changesChat { await fixture.rebind() } else { await fixture.revoke() } }
            let card = try await routing.propose(request, caller: caller())
            do { _ = try await dispatch(card, on: routing); XCTFail("Expired owner/chat sent") } catch {}
            let counts = await fixture.counts(); XCTAssertEqual(counts.1, 0)
        }
    }
    func testRetargetKeepsCardIDButRequiresNewRevisionAndNewConsent() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let first = try await routing.propose(request, caller: caller())
        let next = try await routing.retarget(try first["id"].requireString("id"), revision: first["revision"].requireString("revision"),
            target: .object([.init("kind", .string("agent")), .init("id", .string("other-current-agent"))]), caller: caller())
        XCTAssertEqual(first["id"], next["id"]); XCTAssertNotEqual(first["revision"], next["revision"])
        do { _ = try await dispatch(first, on: routing); XCTFail("Old revision accepted") } catch {}
        _ = try await dispatch(next, on: routing)
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }
    func testDismissDuringApprovalPreventsTheWaitingRequestFromSending() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.hold()
        let card = try await routing.propose(request, caller: caller())
        let job = Task { try await self.dispatch(card, on: routing) }
        for _ in 0..<1000 {
            if await fixture.counts().0 == 1 { break }
            await Task.yield()
        }
        let duplicate = try await dispatch(card, on: routing)
        XCTAssertEqual(duplicate["status"].string, "approving")
        _ = try await routing.dismiss(try card["id"].requireString("id"), revision: card["revision"].requireString("revision"), caller: caller())
        await fixture.release()
        do { _ = try await job.value; XCTFail("Dismissed request sent") } catch {}
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
    }
    func testDispatchingReceiptMustBeSavedBeforeCallingAnyMutation() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.failingSave()
        let card = try await routing.propose(request, caller: caller())
        do { _ = try await dispatch(card, on: routing); XCTFail("Unsaved dispatch accepted") } catch {}
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 0)
    }
    func testRestartNeverRepeatsAnUncertainOrSuccessfulDispatch() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.failingDispatch()
        let card = try await routing.propose(request, caller: caller())
        do { _ = try await dispatch(card, on: routing); XCTFail("Lost reply reported success") } catch {}
        let restarted = self.routing(fixture)
        let again = try await dispatch(card, on: restarted)
        XCTAssertEqual(again["status"].string, "uncertain")
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
        let sending = card.setting("state", .string("dispatching")).setting("status", .string("dispatching"))
        await fixture.replaceLedger([sending])
        let cutOff = self.routing(fixture)
        let blocked = try await dispatch(card, on: cutOff)
        XCTAssertEqual(blocked["status"].string, "uncertain")
        let finalCounts = await fixture.counts(); XCTAssertEqual(finalCounts.1, 1)
    }
    /// U41 (#99): one failed chat read is not kept; the next routing call reads again and works.
    func testOneFailedChatReadDoesNotBreakRoutingForTheSession() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        await fixture.failingLoads(1)
        do { _ = try await routing.read(caller()); XCTFail("The failed read was hidden.") } catch {}
        let read = try await routing.read(caller())
        XCTAssertEqual(read["proposals"].elements?.count, 0)
        let card = try await routing.propose(request, caller: caller())
        XCTAssertEqual(card["status"].string, "pending")
    }
    /// U41 (#386): delivered, then the chat note fails: still "sent", no error, and a second answer sends nothing.
    func testDeliveredSendStaysSentWhenTheChatNoteFails() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        await fixture.failingSentSave()
        let sent = try await dispatch(card, on: routing)
        XCTAssertEqual(sent["status"].string, "sent"); XCTAssertNil(sent["error"].string)
        let again = try await dispatch(card, on: routing)
        XCTAssertEqual(again["status"].string, "sent")
        let counts = await fixture.counts(); XCTAssertEqual(counts.1, 1)
    }
    func testProposalsAreBoundedAndRawImageDataIsRefused() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        for _ in 0..<BackendHOOTSIMRouting.maximumRows { _ = try await routing.propose(request, caller: caller()) }
        do { _ = try await routing.propose(request, caller: caller()); XCTFail("33 waiting rows accepted") } catch {}
        let rows = try await routing.read(caller())["proposals"].elements ?? []
        XCTAssertEqual(rows.count, 32)
        let raw = request.setting("attachments", .array([.object([.init("source", .object([.init("data", .string("large base64"))]))])]))
        do { _ = try await routing.propose(raw, caller: caller()); XCTFail("Raw image copied") } catch {}
    }
    func testCurrentRegistryAndProfilesOverrideCandidateNamesAndProjectClaims() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: ["/scratch/crm"]), PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/imatch"])]
        let agents: [V] = [.object([.init("id", .string("portal")), .init("name", .string("Actual portal owner")), .init("projectId", .string("crm")), .init("role", .string("Portal mechanic")), .init("instructions", .string("Owns Sources/Login.swift"))]),
            .object([.init("id", .string("imatch-agent")), .init("name", .string("Other project")), .init("projectId", .string("imatch")), .init("role", .string("Portal mechanic"))])]
        var request = self.request.setting("source", self.request["source"].setting("file", .string("Sources/Login.swift")))
            .setting("candidates", .array([.object([.init("kind", .string("agent")), .init("id", .string("portal")), .init("name", .string("Forged name"))])]))
        let proposed = try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: projects.flatMap(\.folders), agents: agents, sessions: [])
        XCTAssertEqual(proposed["target"]["name"].string, "Actual portal owner")
        XCTAssertEqual(proposed["target"]["projectName"].string, "CRM")
        request = request.setting("target", .object([.init("kind", .string("agent")), .init("id", .string("imatch-agent"))]))
        XCTAssertThrowsError(try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: projects.flatMap(\.folders), agents: agents, sessions: []))
    }
    func testAmbiguousOwnersProduceTaskOnlyInsteadOfGuessing() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: ["/scratch/crm"])]
        let agents: [V] = ["one", "two"].map { .object([.init("id", .string($0)), .init("name", .string($0)), .init("projectId", .string("crm")), .init("role", .string("Portal mechanic"))]) }
        let result = try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: projects.flatMap(\.folders), agents: agents, sessions: [])
        XCTAssertEqual(result["target"]["kind"].string, "task")
    }
}

extension HOOTSIMRoutingTests {
    func testAssistantRoutingMetadataSurvivesTheRealChatWriterAndResetProjection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-chat-cards-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat.json"), chat = try BackendHootChatStore(file: file)
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let proposal = try await routing.propose(request, caller: caller())
        let row = proposal.setting("conversationId", .string(chat.conversationID))
        try await chat.recordRouting(row)
        let snapshot = await chat.snapshot()
        let records = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertEqual(records.first?.record.kind, .message)
        XCTAssertEqual(records.first?.record.value["routing"], row)
        let reopened = try BackendHootChatStore(file: file)
        let saved = await reopened.routingRecords()
        XCTAssertEqual(saved, [row])
        let cursor = Int(snapshot["cursor"].number ?? 0)
        let states = [row.setting("status", .string("approving")), row.setting("status", .string("sent"))]
        for state in states { try await chat.recordRouting(state) }
        let delta = await chat.snapshot(after: cursor)
        XCTAssertEqual(delta["reset"].bool, false)
        XCTAssertEqual(delta["events"].elements?.last?["value"]["routing"]["status"].string, "sent")
        let final = await chat.snapshot()
        let finalEvents = try (final["events"].elements ?? []).map(HootChatEvent.init(wire:))
        let visible = HootChatProjection.rows(finalEvents)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.value["routing"]["status"].string, "sent")
    }
    func testCurrentWorkingStateBreaksAnOwnershipTieWithoutInventingAnOwner() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: ["/scratch/crm"])]
        let agents: [V] = ["busy", "free"].map { .object([.init("id", .string($0)), .init("name", .string($0)), .init("projectId", .string("crm")), .init("role", .string("Portal mechanic"))]) }
        let tasks: [V] = [.object([.init("process", .string("running")), .init("assignee", .object([.init("agentId", .string("busy"))]))])]
        let result = try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: projects.flatMap(\.folders), agents: agents, sessions: [], tasks: tasks)
        XCTAssertEqual(result["target"]["id"].string, "free")
        let noOwner = request.setting("problem", .string("An unrelated thing is wrong"))
        let unassigned = try BackendHOOTSIMRoutingResolver.resolve(noOwner, projects: projects, openFolders: projects.flatMap(\.folders), agents: agents, sessions: [], tasks: tasks)
        XCTAssertEqual(unassigned["target"]["kind"].string, "task")
    }
}

extension HOOTSIMRoutingTests {
    func testRoutingMetadataSurvivesBackendHistoryCompactionWithoutCoreChanges() {
        let id = UUID().uuidString
        let card = V.object([.init("id", .string(id)), .init("status", .string("pending"))])
        let events = (1...4001).map { index in
            HootChatEvent(conversationID: "scratch", turnID: "turn", sequence: index, provider: .claude,
                record: index == 1 ? .init(.message, id: "routing:" + id, value: .object([.init("text", .string("")), .init("routing", card)]))
                    : .text(.textDelta, id: "answer", "a"))
        }
        let reduced = BackendHootChatStore.projectedRoutingHistory(events)
        XCTAssertEqual(reduced.count, 2)
        XCTAssertEqual(reduced.first?.record.value["routing"], card)
        XCTAssertEqual(reduced.last?.record.value["text"].string?.count, 4000)
    }
}

extension HOOTSIMRoutingTests {
    func testReusedTaskReportsAreEventDrivenPersistedAndNeverClaimUnverifiedWorkFixed() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        _ = try await dispatch(card, on: routing)
        let task = V.object([.init("id", .string("local:scratch-task")), .init("title", .string("Portal login")),
            .init("requestedBy", .string("me")), .init("lastTurn", .string("accepted-turn-one")), .init("verified", .bool(false)),
            .init("result", .object([.init("at", .number(1000)), .init("answer", .string("I changed the login flow.")), .init("verified", .bool(false))]))])
        try await routing.observeTaskOutcomes([task], conversationID: "hoot-scratch")
        try await routing.observeTaskOutcomes([task], conversationID: "hoot-scratch")
        let saved = await fixture.values()
        XCTAssertEqual(saved.count, 5)
        XCTAssertEqual(saved.last?["report"]["verified"].bool, false)
        XCTAssertTrue(saved.last?["report"]["text"].string?.contains("needs review") == true)
        let restarted = self.routing(fixture)
        _ = try await restarted.read(caller())
        try await restarted.observeTaskOutcomes([task], conversationID: "hoot-scratch")
        let replayed = await fixture.values()
        XCTAssertEqual(replayed.count, saved.count)
        let checked = task.setting("verified", .bool(true)).setting("result", task["result"].setting("verified", .bool(true)))
        try await restarted.observeTaskOutcomes([checked], conversationID: "hoot-scratch")
        let revised = await fixture.values()
        XCTAssertEqual(revised.count, 6)
        XCTAssertEqual(revised.last?["report"]["verified"].bool, true)
    }
    func testEngineOwnedHootReportsAreNotDuplicatedByTheProjection() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        _ = try await dispatch(card, on: routing)
        let task = V.object([.init("id", .string("local:scratch-task")), .init("requestedBy", .string("hoot")),
            .init("lastTurn", .string("one")), .init("result", .object([.init("at", .number(1000)), .init("answer", .string("Finished")), .init("verified", .bool(false))]))])
        try await routing.observeTaskOutcomes([task], conversationID: "hoot-scratch")
        let saved = await fixture.values()
        XCTAssertEqual(saved.count, 4)
        XCTAssertNil(saved.last?["report"]["text"].string)
    }
}

extension HOOTSIMRoutingTests {
    private func toolAccess(_ kind: BackendDeckToolsAppCaller.Kind) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: kind) }, knownFolder: { _, folder in folder },
            session: { _, _ in throw NativeRPCError(code: "fixture", message: "No session needed") },
            runnableProject: { _, folder in folder }, rpc: { _ in .init(caller: .nativeApp, ownerID: "scratch") },
            authorize: { _, _, _, tier, _, owner in
                XCTAssertEqual(tier, .read); XCTAssertFalse(owner)
            }, record: { _, _, _, _ in })
    }
    private func toolCaller(_ tools: [BackendDeckToolsDefinition]) -> BackendMCPCallContext {
        .init(sessionID: "hoot-scratch", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(tools.flatMap { [$0.spec.id, $0.spec.wireName] }), allowedTiers: [.read, .act, .alter], cancellation: .init())
    }
    func testRouteToolsRejectAnInventedApprovalAndUnrelatedKeyBeforeSending() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let definitions = try BackendHOOTSIMRoutingMCP.definitions(routing: routing, access: toolAccess(.local))
        let propose = try XCTUnwrap(definitions.first { $0.spec.id == "hoot.route.propose" })
        let forged = try await propose.handler(toolCaller(definitions), request.setting("approved", .bool(true)))
        XCTAssertTrue(forged.isError)
        let keyDefinitions = try BackendHOOTSIMRoutingMCP.definitions(routing: routing, access: toolAccess(.key))
        let keyPropose = try XCTUnwrap(keyDefinitions.first { $0.spec.id == "hoot.route.propose" })
        let keyReply = try await keyPropose.handler(toolCaller(keyDefinitions), request)
        XCTAssertTrue(keyReply.isError)
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        let ledger = await fixture.values(); XCTAssertTrue(ledger.isEmpty)
    }
    func testDispatchToolCannotUseAnApprovedBoolAsOwnerConsent() async throws {
        let fixture = HOOTSIMRoutingFixture(), routing = routing(fixture)
        let definitions = try BackendHOOTSIMRoutingMCP.definitions(routing: routing, access: toolAccess(.local))
        let card = try await routing.propose(request, caller: caller())
        let dispatch = try XCTUnwrap(definitions.first { $0.spec.id == "hoot.route.dispatch" })
        let args = V.object([.init("id", card["id"]), .init("revision", card["revision"]), .init("approved", .bool(true))])
        let forged = try await dispatch.handler(toolCaller(definitions), args)
        XCTAssertTrue(forged.isError)
        let counts = await fixture.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
}

extension HOOTSIMRoutingTests {
    private func originTask(_ name: String, requester: String, parent: String? = nil) throws -> BackendTaskRecord {
        try BackendTaskRecord(.object([.init("id", .string("local:" + name)), .init("keyId", .string("local")),
            .init("externalTaskId", .string(name)), .init("local", .bool(true)), .init("requestedBy", .string(requester)),
            .init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("worker"))])),
            .init("parentTaskId", parent.map(V.string) ?? .null), .init("project", .string("/scratch/crm")),
            .init("sessionId", .string("worker-" + name)), .init("agoptRunID", .string("run-" + name))]))
    }
    func testResolverUsesTheExactCurrentSourceSessionBeforeWeakRoleMatches() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: ["/scratch/crm"])]
        let agent = V.object([.init("id", .string("portal")), .init("name", .string("Portal")), .init("projectId", .string("crm")), .init("role", .string("Portal mechanic"))])
        let session = V.object([.init("id", .string("source-session")), .init("title", .string("CRM login")), .init("cwd", .string("/scratch/crm")),
            .init("createdAt", .number(1000)), .init("exitCode", .null), .init("status", .string("running")), .init("provider", .string("codex"))])
        let source = request.setting("source", request["source"].setting("sessionId", .string("source-session")))
        let result = try BackendHOOTSIMRoutingResolver.resolve(source, projects: projects, openFolders: ["/scratch/crm"], agents: [agent], sessions: [session])
        XCTAssertEqual(result["target"]["kind"].string, "session")
        XCTAssertEqual(result["target"]["id"].string, "source-session")
        let exited = session.setting("exitCode", .number(0)).setting("status", .string("exited"))
        let fallback = try BackendHOOTSIMRoutingResolver.resolve(source, projects: projects, openFolders: ["/scratch/crm"], agents: [agent], sessions: [exited])
        XCTAssertEqual(fallback["target"]["kind"].string, "agent")
    }
    func testRegisteredClosedProjectAndClosedTargetFoldersCannotBeRouted() throws {
        let projects = [PROJProject(id: "crm", name: "CRM", folders: ["/scratch/crm", "/scratch/crm-closed"])]
        let agent = V.object([.init("id", .string("portal")), .init("projectId", .string("crm")),
            .init("defaultProject", .string("/scratch/crm-closed")), .init("role", .string("Portal mechanic"))])
        XCTAssertThrowsError(try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: [], agents: [agent], sessions: []))
        let session = V.object([.init("id", .string("closed-session")), .init("cwd", .string("/scratch/crm-closed")), .init("exitCode", .null), .init("status", .string("running"))])
        let chosen = request.setting("target", .object([.init("kind", .string("session")), .init("id", .string("closed-session"))]))
        XCTAssertThrowsError(try BackendHOOTSIMRoutingResolver.resolve(chosen, projects: projects, openFolders: ["/scratch/crm"], agents: [agent], sessions: [session]))
        let proposal = try BackendHOOTSIMRoutingResolver.resolve(request, projects: projects, openFolders: ["/scratch/crm"], agents: [agent], sessions: [session])
        XCTAssertEqual(proposal["target"]["kind"].string, "task")
    }
}

