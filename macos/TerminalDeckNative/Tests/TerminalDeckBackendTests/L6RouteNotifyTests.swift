import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// #90 "Do it and tell me": stub chat, stub resolver, stub senders and a fake
/// clock. No real task, session, AI or timer is used.
private actor L6RouteNotifyFixture {
    var ledger: [NativeRPCValue] = []
    var policy = HootPolicySnapshot(routingMode: "notify")
    var kind = "agent", folder = "/scratch/crm"
    var approvals = 0, cardSends = 0, automaticSends = 0
    var waiting: [CheckedContinuation<Void, Error>] = []
    var waits = 0
    var failSavingDispatch = false
    func append(_ row: NativeRPCValue) throws {
        if failSavingDispatch && row["status"].string == "dispatching" { throw NativeRPCError(code: "scratch-disk", message: "Cannot save") }
        ledger.append(row)
    }
    func failingDispatchSave() { failSavingDispatch = true }
    func savingWorks() { failSavingDispatch = false }
    func values() -> [NativeRPCValue] { ledger }
    func setPolicy(_ next: HootPolicySnapshot) { policy = next }
    func currentPolicy() -> HootPolicySnapshot { policy }
    func setTarget(kind: String, folder: String) { self.kind = kind; self.folder = folder }
    func resolve(_ request: NativeRPCValue) -> NativeRPCValue {
        let target = NativeRPCValue.object([.init("id", .string(kind == "session" ? "session-one" : "portal-mechanic")), .init("kind", .string(kind)),
            .init("name", .string("Portal mechanic")), .init("projectId", .string("crm")), .init("projectName", .string("CRM")),
            .init("revision", .string("profile-one")), .init("folder", .string(folder))])
        return .object([.init("target", target), .init("source", request["source"]), .init("reason", .string("Owns the portal.")),
            .init("evidence", .array([.string("Current agent role")]))])
    }
    func approve() { approvals += 1 }
    func cardSend() -> NativeRPCValue { cardSends += 1; return .object([.init("taskId", .string("local:card"))]) }
    func automaticSend() -> NativeRPCValue { automaticSends += 1; return .object([.init("taskId", .string("local:auto"))]) }
    func counts() -> (approvals: Int, card: Int, automatic: Int) { (approvals, cardSends, automaticSends) }
    /// The fake clock: the Undo window waits here until the test lets time pass.
    func sleep() async throws {
        waits += 1
        try await withCheckedThrowingContinuation(isolation: self) { waiting.append($0) }
    }
    func pass() { let all = waiting; waiting = []; for one in all { one.resume() } }
    func waitCount() -> Int { waits }
}

final class L6RouteNotifyTests: XCTestCase, @unchecked Sendable {
    typealias V = NativeRPCValue
    private let request = V.object([.init("problem", .string("The portal login loops")),
        .init("source", .object([.init("kind", .string("browser")), .init("folder", .string("/scratch/crm")), .init("projectId", .string("crm"))]))])
    private func routing(_ fixture: L6RouteNotifyFixture) -> BackendHOOTSIMRouting {
        BackendHOOTSIMRouting(.init(require: { _ in }, conversationID: { "hoot-scratch" },
            load: { await fixture.values() }, append: { try await fixture.append($0) },
            resolve: { _, request in await fixture.resolve(request) }, authorize: { _, _ in await fixture.approve() },
            dispatch: { _, _ in await fixture.cardSend() },
            policy: { await fixture.currentPolicy() },
            autoDispatch: { _ in await fixture.automaticSend() },
            sleep: { _ in try await fixture.sleep() }, undoSeconds: 10))
    }
    private func caller() -> BackendMCPCallContext {
        .init(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init())
    }
    /// Lets the actor's Undo-window task reach the fake clock, or finish after it.
    private func settle(_ fixture: L6RouteNotifyFixture, waits: Int? = nil) async {
        for _ in 0..<200 {
            if let waits, await fixture.waitCount() >= waits { return }
            await Task.yield(); try? await Task.sleep(for: .milliseconds(2))
        }
    }
    private func waitFor(_ routing: BackendHOOTSIMRouting, _ id: String, status: String) async throws {
        for _ in 0..<500 {
            if try await state(routing, id)["status"].string == status { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    private func state(_ routing: BackendHOOTSIMRouting, _ id: String) async throws -> V {
        try await routing.read(caller())["proposals"].elements?.first { $0["id"].string == id } ?? .null
    }

    func testNotifySendsAfterTheUndoWindowWithoutAskingAndReportsSent() async throws {
        let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        let id = try card["id"].requireString("id")
        XCTAssertEqual(card["status"].string, "scheduled")
        XCTAssertEqual(card["undoSeconds"].number, 10)
        await settle(fixture, waits: 1)
        var counts = await fixture.counts()
        XCTAssertEqual(counts.automatic, 0, "Nothing is sent inside the Undo window")
        await fixture.pass(); await settle(fixture)
        try await waitFor(routing, id, status: "sent")
        let sent = try await state(routing, id)
        XCTAssertEqual(sent["status"].string, "sent"); XCTAssertEqual(sent["taskId"].string, "local:auto"); XCTAssertEqual(sent["automatic"].bool, true)
        counts = await fixture.counts()
        XCTAssertEqual(counts.automatic, 1); XCTAssertEqual(counts.approvals, 0, "The person's setting is the approval"); XCTAssertEqual(counts.card, 0)
        let states = await fixture.values().compactMap { $0["status"].string }
        XCTAssertEqual(states, ["scheduled", "dispatching", "sent"])
    }

    func testUndoInsideTheWindowSendsNothing() async throws {
        let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        await settle(fixture, waits: 1)
        let undone = try await routing.dismiss(try card["id"].requireString("id"), revision: card["revision"].requireString("revision"), caller: caller())
        XCTAssertEqual(undone["status"].string, "dismissed"); XCTAssertEqual(undone["undone"].bool, true)
        await fixture.pass(); await settle(fixture)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.automatic, 0); XCTAssertEqual(counts.card, 0); XCTAssertEqual(counts.approvals, 0)
        // A late approve on the undone card sends nothing either.
        let again = try await routing.dispatch(try card["id"].requireString("id"), revision: card["revision"].requireString("revision"), caller: caller())
        XCTAssertEqual(again["status"].string, "dismissed")
        let after = await fixture.counts(); XCTAssertEqual(after.card + after.automatic, 0)
    }

    func testAskModeAndUnknownTargetsStillAsk() async throws {
        let cases: [(HootPolicySnapshot, String, String)] = [
            (HootPolicySnapshot(routingMode: "notify"), "machine", "/scratch/crm"),
            (HootPolicySnapshot(routingMode: "ask"), "agent", "/scratch/crm"),
            (HootPolicySnapshot(routingMode: "ask"), "session", "/scratch/other"),
        ]
        for (policy, kind, folder) in cases {
            let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
            await fixture.setPolicy(policy); await fixture.setTarget(kind: kind, folder: folder)
            let card = try await routing.propose(request, caller: caller())
            XCTAssertEqual(card["status"].string, "pending", "\(policy) \(kind)")
            await settle(fixture)
            var counts = await fixture.counts()
            let waits = await fixture.waitCount()
            XCTAssertEqual(counts.automatic, 0); XCTAssertEqual(waits, 0)
            _ = try await routing.dispatch(try card["id"].requireString("id"), revision: card["revision"].requireString("revision"), caller: caller())
            counts = await fixture.counts()
            XCTAssertEqual(counts.approvals, 1, "The normal approval path still asks"); XCTAssertEqual(counts.card, 1); XCTAssertEqual(counts.automatic, 0)
        }
        // Hoot may always run sessions and work in any folder (Asad, 12 Oct): a session anywhere sends under "notify".
        XCTAssertTrue(BackendHOOTSIMRouting.sendsWithoutAsking(.object([.init("kind", .string("session")), .init("folder", .string("/anywhere"))]),
            policy: HootPolicySnapshot(routingMode: "notify")))
    }

    func testSwitchTurnedOffDuringTheWindowFallsBackToAsking() async throws {
        let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        let id = try card["id"].requireString("id")
        await settle(fixture, waits: 1)
        await fixture.setPolicy(HootPolicySnapshot(routingMode: "ask"))
        await fixture.pass()
        try await waitFor(routing, id, status: "pending")
        let row = try await state(routing, id)
        XCTAssertEqual(row["status"].string, "pending")
        let counts = await fixture.counts(); XCTAssertEqual(counts.automatic, 0)
    }

    /// U41 (#385): the chat write fails as the Undo window ends: nothing is sent and the card asks, never stuck at "0 s".
    func testFailedSaveAtTheEndOfTheWindowTurnsTheCardIntoAQuestion() async throws {
        let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
        let card = try await routing.propose(request, caller: caller())
        let id = try card["id"].requireString("id")
        await settle(fixture, waits: 1)
        await fixture.failingDispatchSave()
        await fixture.pass()
        try await waitFor(routing, id, status: "pending")
        let row = try await state(routing, id)
        XCTAssertEqual(row["status"].string, "pending"); XCTAssertTrue(row["autoAt"].isNullish)
        var counts = await fixture.counts(); XCTAssertEqual(counts.automatic, 0)
        await fixture.savingWorks()
        let sent = try await routing.dispatch(id, revision: try row["revision"].requireString("revision"), caller: caller())
        XCTAssertEqual(sent["status"].string, "sent")
        counts = await fixture.counts(); XCTAssertEqual(counts.approvals, 1); XCTAssertEqual(counts.card, 1); XCTAssertEqual(counts.automatic, 0)
    }

    /// "Never" is gone with the "What Hoot may do" switches (Asad, 12 Oct): Hoot always hands problems out.
    func testThereIsNoNeverAnyMore() async throws {
        let fixture = L6RouteNotifyFixture(), routing = routing(fixture)
        await fixture.setPolicy(HootPolicySnapshot(routingMode: "never"))
        let card = try await routing.propose(request, caller: caller())
        XCTAssertEqual(card["status"].string, "pending", "A card is made and asks, as the default always did")
    }

    func testRestartTurnsAWaitingAutomaticCardIntoAQuestion() async throws {
        let fixture = L6RouteNotifyFixture(), first = routing(fixture)
        let card = try await first.propose(request, caller: caller())
        await first.stop()
        let restarted = routing(fixture)
        let row = try await state(restarted, try card["id"].requireString("id"))
        XCTAssertEqual(row["status"].string, "pending", "After a restart nothing sends by itself")
        let counts = await fixture.counts(); XCTAssertEqual(counts.automatic, 0)
    }
}
