import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class TAGConsent0202Tests: XCTestCase {
    private typealias V = NativeRPCValue
    private let clock = BackendDeckCoreTestPortSecurityClock()
    private let names = (1...24).map { "agent-\($0)" }
    private func batch(key: String = "key-A", items: [String] = ["inspector"]) -> BackendTAGProfileConsentBatch {
        .init(keyID: key, keyName: key == "key-A" ? "Commander" : "Other app", items: items)
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TAG-consent-0202-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func policy(_ id: String, consent: BackendDeckCoreSecurityConsentBroker) throws -> BackendDeckCoreSecurityToolPolicy {
        let properties: V = .object([.init("do", .object([.init("type", .string("string"))])), .init("agent", .object([.init("type", .string("object"))])), .init("folder", .object([.init("type", .string("string"))]))])
        return .init(tool: try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id,
            inputSchema: .object([.init("type", .string("object")), .init("properties", properties), .init("additionalProperties", .bool(false))]), tier: .alter),
            summary: { _, _ in "Save task agents" }, ownerMustAnswer: { _ in true }, run: { _, _ in .init(value: .bool(true)) })
    }
    private func save(_ name: String) -> V { .object([.init("do", .string("save")), .init("agent", .object([.init("id", .string(name)), .init("name", .string(name))]))]) }
    private func request(_ broker: BackendDeckCoreSecurityConsentBroker, key: String = "key-A", items: [String]) -> Task<BackendDeckCoreSecurityConsentOutcome, Never> {
        let descriptor = batch(key: key, items: items)
        return Task { await broker.request(tool: "tasks.agents", tier: .alter, summary: "Save", arguments: .object([]), origin: "key:" + key, profileBatch: descriptor) }
    }

    func testStandingKeyPreauthorizationSkipsProfileSaveAndImportBoxesButStillLogs() async throws {
        let asked = BackendDeckCoreSecurityTestBox<Int>(0)
        let clock = self.clock
        let broker = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: { _ in asked.edit { $0 += 1 }; return false })
        let log = BackendDeckCoreSecurityActionLog(directory: try temporary(), now: { clock.now() })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: broker,
            policies: [try policy("tasks.agents", consent: broker), try policy("tasks.agents_import", consent: broker)], now: { clock.now() })
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "key-A", keyName: "Commander", askFirst: false, tasks: true)
        let saved = await control.call(name: "tasks_agents", arguments: save("inspector"), options: .init(caller: caller))
        let imported = await control.call(name: "tasks_agents_import", arguments: .object([.init("folder", .string("/fixture/project"))]), options: .init(caller: caller))
        XCTAssertTrue(saved.ok); XCTAssertTrue(imported.ok); XCTAssertEqual(asked.get(), 0)
        XCTAssertEqual(saved.row["confirmed"]["by"], .string("standing:key:key-A"))
        XCTAssertEqual(imported.row["confirmed"]["by"], .string("standing:key:key-A"))
        let rows = await log.tail(); XCTAssertEqual(rows.count, 2)
    }

    func testReadTierProfileToolPreparedWriteHonorsStandingKeyWithoutWeakeningForcedOtherTools() async throws {
        let asked = BackendDeckCoreSecurityTestBox<Int>(0), owner = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityControl?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: { _ in asked.edit { $0 += 1 }; return false })
        let schema: V = .object([.init("type", .string("object")), .init("properties", .object([.init("do", .object([.init("type", .string("string"))])), .init("agent", .object([.init("type", .string("object"))]))])), .init("additionalProperties", .bool(false))])
        let profile = BackendDeckCoreSecurityToolPolicy(tool: try .init(id: "tasks.agents", wireName: "tasks_agents", description: "Profiles", inputSchema: schema, tier: .read), summary: { _, _ in "Save" }, run: { args, context in
            guard let gate = owner.get() else { throw NativeRPCError.invalidArguments("Missing test gate") }
            _ = try await gate.prepareEffect(context: context, tool: "tasks.agents", arguments: args, tier: .alter, sentence: "Save profile", ownerMustAnswer: true)
            return .init(value: .bool(true))
        })
        let forced = BackendDeckCoreSecurityToolPolicy(tool: try .init(id: "other.forced", wireName: "other_forced", description: "Forced owner", inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .alter), summary: { _, _ in "Other" }, ownerMustAnswer: { _ in true }, run: { _, _ in .init(value: .bool(true)) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try temporary()), consent: broker, policies: [profile, forced]); owner.set(control)
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "key-A", keyName: "Commander", askFirst: false, tasks: true)
        let saved = await control.call(name: "tasks_agents", arguments: save("inspector"), options: .init(caller: caller))
        XCTAssertTrue(saved.ok); XCTAssertEqual(saved.row["confirmed"]["by"], .string("standing:key:key-A")); XCTAssertEqual(asked.get(), 0)
        // Asad, 11 Oct: the app asks nothing itself, so a forced tool runs too (recorded), still with no card.
        let other = await control.call(name: "other_forced", arguments: .object([]), options: .init(caller: caller))
        XCTAssertTrue(other.ok, other.error ?? ""); XCTAssertEqual(asked.get(), 0)
    }

    func testConcurrentSavesShareOnePendingIDWithCountAndList() async throws {
        let shown = expectation(description: "group reaches24"); let seen = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentRequest?>(nil)
        let ids = BackendDeckCoreSecurityTestBox<Set<String>>([])
        let broker = BackendDeckCoreSecurityConsentBroker(maximumPending: 3, clock: clock, ask: { q in
            seen.set(q); ids.edit { $0.insert(q.id) }
            if q.profileBatch?.items.count == 24 { shown.fulfill() }; return true
        })
        let calls = names.map { request(broker, items: [$0]) }
        await fulfillment(of: [shown], timeout: 2)
        let pending = await broker.list(), question = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(question.profileBatch?.items.count, 24)
        XCTAssertEqual(Set(question.profileBatch?.items ?? []), Set(names)); XCTAssertEqual(ids.get().count, 1)
        XCTAssertTrue(question.summary.contains("Commander wants to save24 agents") || question.summary.contains("Commander wants to save 24 agents"))
        let tapped = await broker.respond(id: question.id, approved: true, by: "window"); XCTAssertTrue(tapped)
        for call in calls { let outcome = await call.value; XCTAssertTrue(outcome.granted) }
        await broker.stop()
    }

    func testOwnerBatchTapCoversSequentialNearbySavesButExpiresAndDoesNotCoverOtherKeysOrKinds() async throws {
        let shown = expectation(description: "firstbatch"), otherShown = expectation(description: "otherkey"), pausedShown = expectation(description: "otherkind"), laterShown = expectation(description: "expiredbatch")
        let offered = BackendDeckCoreSecurityTestBox<Int>(0)
        let broker = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: { _ in
            offered.edit { $0 += 1 }
            switch offered.get() { case 1: shown.fulfill(); case 2: otherShown.fulfill(); case 3: pausedShown.fulfill(); case 4: laterShown.fulfill(); default: break }
            return true
        })
        let first = request(broker, items: ["inspector"])
        await fulfillment(of: [shown], timeout: 1)
        let initial = await broker.list(), question = try XCTUnwrap(initial.first)
        _ = await broker.respond(id: question.id, approved: true, by: "window"); let approved = await first.value
        for name in names { let next = await request(broker, items: [name]).value; XCTAssertTrue(next.granted); XCTAssertEqual(next.by, approved.by) }
        XCTAssertEqual(offered.get(), 1)
        let other = request(broker, key: "key-B", items: ["other"])
        let paused = Task { await broker.request(tool: "tasks.agents", tier: .alter, summary: "Pause", arguments: .object([.init("do", .string("pause"))]), origin: "key:key-A") }
        await fulfillment(of: [otherShown, pausedShown], timeout: 1)
        let remaining = await broker.list(); XCTAssertEqual(remaining.count, 2)
        for q in remaining { _ = await broker.respond(id: q.id, approved: false, by: "window") }
        let otherOutcome = await other.value, pausedOutcome = await paused.value
        XCTAssertFalse(otherOutcome.granted); XCTAssertFalse(pausedOutcome.granted)
        clock.advance(5_001)
        let later = request(broker, items: ["late"])
        await fulfillment(of: [laterShown], timeout: 1)
        let laterPending = await broker.list(), last = try XCTUnwrap(laterPending.first)
        _ = await broker.respond(id: last.id, approved: false, by: "window"); let laterOutcome = await later.value; XCTAssertFalse(laterOutcome.granted)
        await broker.stop()
    }

    func testExplicitTenMinuteKindApprovalIsOwnerOnlyScopedAndSeparateFromShortBatch() async throws {
        let delivered = expectation(description: "ownerkindprompt"), expiredShown = expectation(description: "kindexpired")
        let offers = BackendDeckCoreSecurityTestBox<Int>(0)
        let live = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: { _ in offers.edit { $0 += 1 }; if offers.get() == 1 { delivered.fulfill() } else { expiredShown.fulfill() }; return true })
        let call = request(live, items: ["inspector"])
        await fulfillment(of: [delivered], timeout: 1)
        let initial = await live.list(), q = try XCTUnwrap(initial.first)
        let selfTap = await live.respond(id: q.id, approved: true, by: "key:key-A", allowKindMinutes: 10); XCTAssertFalse(selfTap)
        let owner = await live.respond(id: q.id, approved: true, by: "window", allowKindMinutes: 10); XCTAssertTrue(owner)
        let outcome = await call.value; XCTAssertTrue(outcome.granted)
        clock.advance(6_000)
        let followup = await request(live, items: ["laterwithin10min"]).value; XCTAssertTrue(followup.granted)
        clock.advance(594_001)
        let expired = request(live, items: ["after10min"])
        await fulfillment(of: [expiredShown], timeout: 1)
        let pending = await live.list(), next = try XCTUnwrap(pending.first)
        _ = await live.respond(id: next.id, approved: false, by: "window"); let expiredOutcome = await expired.value; XCTAssertFalse(expiredOutcome.granted)
        await live.stop()
    }

    func testActiveOwnerKeepsProfilePromptPendingWithoutApprovalOrTimerPolling() async throws {
        let shown = expectation(description: "activeprompt")
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 45_000, clock: clock, ask: { _ in shown.fulfill(); return true })
        await broker.noteOwnerActive(true)
        let call = request(broker, items: ["inspector"])
        await fulfillment(of: [shown], timeout: 1)
        clock.advance(120_000)
        let pending = await broker.list(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(clock.pending(), 0)
        let q = try XCTUnwrap(pending.first), allowed = await broker.respond(id: q.id, approved: true, by: "window"); XCTAssertTrue(allowed)
        let outcome = await call.value; XCTAssertTrue(outcome.granted)
        await broker.stop()
    }

    func testBatchReceiptCannotGrantScopeOrSkipEachProfileNarrowingCheck() throws {
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "key-A", keyName: "Commander", tasks: true)
        XCTAssertNil(BackendTAGProfileConsent.batch(tool: "access.request_scope", arguments: .object([.init("scope", .string("full"))]), caller: key))
        XCTAssertNil(BackendTAGProfileConsent.batch(tool: "tasks.agents", arguments: .object([.init("do", .string("remove"))]), caller: key))
        XCTAssertNil(BackendTAGProfileConsent.batch(tool: "tasks.agents", arguments: save("inspector"), caller: .local))
        let old: V = .object([.init("blockedTools", .array([.string("Edit")]))])
        XCTAssertThrowsError(try BackendTAGProfilePolicy.validate(input: old.setting("blockedTools", .array([])), existing: old))
    }
}
