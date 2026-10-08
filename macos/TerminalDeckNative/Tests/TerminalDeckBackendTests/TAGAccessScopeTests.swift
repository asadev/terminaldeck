import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class TAGAccessScopeTests: XCTestCase {
    private struct Rig {
        let root: URL, id: String
        let keys: BackendDeckCoreSecurityAccessKeys, consent: BackendDeckCoreSecurityConsentBroker
        let control: BackendDeckCoreSecurityControl, log: BackendDeckCoreSecurityActionLog
        let clock: BackendDeckCoreTestPortSecurityClock
    }
    private func rig(ask: @escaping BackendDeckCoreSecurityConsentBroker.Ask) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TAG-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock = BackendDeckCoreTestPortSecurityClock(1_000)
        let keys = BackendDeckCoreSecurityAccessKeys(directory: root, now: { clock.now() })
        let created = try await keys.create(.object([.init("name", .string("Commander")), .init("level", .string("look")),
            .init("askFirst", .bool(false)), .init("folders", .array([.string("/work/project")]))]))
        let id = try XCTUnwrap(created["view"]["id"].string)
        let consent = BackendDeckCoreSecurityConsentBroker(clock: clock, ask: ask)
        let requests = BackendTAGAccessScope(keys: keys, now: { clock.now() })
        let log = BackendDeckCoreSecurityActionLog(directory: root, now: { clock.now() })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: try requests.bundle().policies, now: { clock.now() })
        return Rig(root: root, id: id, keys: keys, consent: consent, control: control, log: log, clock: clock)
    }
    private func arguments(_ scope: String = "tasks") -> NativeRPCValue {
        .object([.init("scope", .string(scope)), .init("reason", .string("Need task agents"))])
    }
    private func caller(_ r: Rig) async -> BackendDeckCoreSecurityCaller { await r.keys.caller(id: r.id, nameAtArrival: "Commander") }

    func testReadOnlyKeyWithAskFirstOffNeedsOwnerTapAndCannotAnswerItself() async throws {
        let delivered = expectation(description: "owner scope prompt")
        let seen = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentRequest?>(nil)
        let r = try await rig { question in seen.set(question); delivered.fulfill(); return true }
        let c = await caller(r)
        XCTAssertEqual(c.tiers, [.read]); XCTAssertFalse(c.tasks); XCTAssertEqual(c.askFirst, false)
        let policy = await r.control.policy(named: "access.request_scope")
        XCTAssertEqual(policy?.tool.tier, .read); XCTAssertEqual(policy?.keyRequiresTasks, false)
        XCTAssertTrue(policy?.visible(to: nil, caller: c) == true)
        let call = Task { await r.control.call(name: "access_request_scope", arguments: self.arguments(), options: .init(caller: c)) }
        await fulfillment(of: [delivered], timeout: 1)
        let question = try XCTUnwrap(seen.get())
        XCTAssertTrue(question.summary.contains("Commander asks for Your tasks: Need task agents"))
        let before = await r.keys.get(id: r.id); XCTAssertEqual(before?["tasks"], .bool(false))
        let selfAllowed = await r.consent.respond(id: question.id, approved: true, by: "key:" + r.id)
        XCTAssertFalse(selfAllowed)
        let pending = await r.consent.list(); XCTAssertEqual(pending.count, 1)
        let tapped = await r.consent.respond(id: question.id, approved: true, by: "window"); XCTAssertTrue(tapped)
        let result = await call.value; XCTAssertTrue(result.ok)
        XCTAssertEqual(result.row["confirmed"]["by"], .string("window"))
        XCTAssertEqual(result.row["confirmed"]["required"], .bool(true))
        let after = await r.keys.get(id: r.id)
        XCTAssertEqual(after?["tasks"], .bool(true)); XCTAssertEqual(after?["level"], .string("look"))
        XCTAssertEqual(after?["folders"], .array([.string("/work/project")]))
        XCTAssertEqual(after?["askFirst"], .bool(false))
        XCTAssertEqual(after?["grantedScopes"], .array([.string("look"), .string("tasks")]))
        XCTAssertTrue(result.value["key"]["hash"].isNullish)
        let rows = await r.log.tail(); XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["tool"], .string("access.request_scope"))
        await r.consent.stop()
    }

    func testDenyAndNoApproverLeaveScopesUnchangedAndLogRefusal() async throws {
        let delivered = expectation(description: "owner deny prompt")
        let retryDelivered = expectation(description: "owner retry after cooldown")
        let offers = BackendDeckCoreSecurityTestBox<Int>(0)
        let seen = BackendDeckCoreSecurityTestBox<String?>(nil)
        let r = try await rig { question in
            seen.set(question.id); offers.edit { $0 += 1 }
            if offers.get() == 1 { delivered.fulfill() } else { retryDelivered.fulfill() }
            return true
        }
        let c = await caller(r)
        let call = Task { await r.control.call(name: "access_request_scope", arguments: self.arguments(), options: .init(caller: c)) }
        await fulfillment(of: [delivered], timeout: 1)
        let responded = await r.consent.respond(id: seen.get() ?? "missing", approved: false, by: "device:owner-phone"); XCTAssertTrue(responded)
        let result = await call.value; XCTAssertEqual(result.refusal, .declined)
        let key = await r.keys.get(id: r.id); XCTAssertEqual(key?["tasks"], .bool(false))
        let rows = await r.log.tail(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["outcome"], .string("refused"))
        let immediate = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c))
        XCTAssertEqual(immediate.refusal, .rateLimited)
        XCTAssertTrue(immediate.error?.contains("Wait a minute") == true)
        r.clock.advance(60_000)
        let retry = Task { await r.control.call(name: "access_request_scope", arguments: self.arguments(), options: .init(caller: c)) }
        await fulfillment(of: [retryDelivered], timeout: 1)
        _ = await r.consent.respond(id: seen.get() ?? "missing", approved: false, by: "window")
        let second = await retry.value; XCTAssertEqual(second.refusal, .declined)
        XCTAssertEqual(offers.get(), 2)
        let none = try await rig { _ in false }, nc = await caller(none)
        let missing = await none.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: nc))
        XCTAssertEqual(missing.refusal, .noApprover)
        let unchanged = await none.keys.get(id: none.id); XCTAssertEqual(unchanged?["tasks"], .bool(false))
        await r.consent.stop(); await none.consent.stop()
    }

    func testTimeoutAndRevokedKeyCannotGrantOrAcceptLateTap() async throws {
        let delivered = expectation(description: "owner timeout prompt")
        let seen = BackendDeckCoreSecurityTestBox<String?>(nil)
        let r = try await rig { question in seen.set(question.id); delivered.fulfill(); return true }
        let c = await caller(r)
        let call = Task { await r.control.call(name: "access_request_scope", arguments: self.arguments(), options: .init(caller: c)) }
        await fulfillment(of: [delivered], timeout: 1)
        await r.clock.scheduled.wait(1)
        r.clock.advance(45_001)
        let timed = await call.value; XCTAssertEqual(timed.refusal, .timeout)
        let late = await r.consent.respond(id: seen.get() ?? "missing", approved: true, by: "window"); XCTAssertFalse(late)
        let key = await r.keys.get(id: r.id); XCTAssertEqual(key?["tasks"], .bool(false))
        await r.consent.stop()

        let revokePrompt = expectation(description: "owner revoke prompt")
        let revokedID = BackendDeckCoreSecurityTestBox<String?>(nil)
        let revoked = try await rig { question in revokedID.set(question.id); revokePrompt.fulfill(); return true }
        let rc = await caller(revoked)
        let active = Task { await revoked.control.call(name: "access_request_scope", arguments: self.arguments(), options: .init(caller: rc)) }
        await fulfillment(of: [revokePrompt], timeout: 1)
        _ = try await revoked.keys.revoke(id: revoked.id)
        _ = await revoked.consent.respond(id: revokedID.get() ?? "missing", approved: true, by: "window")
        let stopped = await active.value; XCTAssertFalse(stopped.ok); XCTAssertEqual(stopped.refusal, .callerGone)
        let gone = await revoked.keys.get(id: revoked.id); XCTAssertNil(gone)
        await revoked.consent.stop()
    }

    func testDedicatedBudgetCountsDeniedRequestsAndResetsAfterWindow() async throws {
        let offered = BackendDeckCoreSecurityTestBox<Int>(0)
        let r = try await rig { _ in offered.edit { $0 += 1 }; return false }, c = await caller(r)
        let first = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(first.refusal, .noApprover)
        let immediate = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(immediate.refusal, .rateLimited)
        for _ in 0..<2 {
            r.clock.advance(60_000)
            let refused = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(refused.refusal, .noApprover)
        }
        r.clock.advance(60_000)
        let capped = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(capped.refusal, .rateLimited)
        XCTAssertEqual(offered.get(), 3)
        r.clock.advance(600_000)
        let later = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(later.refusal, .noApprover)
        XCTAssertEqual(offered.get(), 4)
        let rows = await r.log.tail(); XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.filter { $0["confirmed"]["reason"] == .string("rate-limited") }.count, 2)
        await r.consent.stop()
    }

    func testWrongCallerBadScopeAndArgumentApprovalFlagsNeverReachConsent() async throws {
        let offered = BackendDeckCoreSecurityTestBox<Int>(0)
        let r = try await rig { _ in offered.edit { $0 += 1 }; return false }
        for c in [BackendDeckCoreSecurityCaller.local, .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "agent"), .init(kind: .key, tiers: [.read], keyID: "missing-key")] {
            let result = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertFalse(result.ok)
        }
        let c = await caller(r)
        for args in [arguments("unknown"), arguments().setting("approved", .bool(true)), arguments().setting("keyId", .string("other-key")), arguments().setting("reason", .string("  "))] {
            let result = await r.control.call(name: "access_request_scope", arguments: args, options: .init(caller: c)); XCTAssertFalse(result.ok)
        }
        XCTAssertEqual(offered.get(), 0)
        let key = await r.keys.get(id: r.id); XCTAssertEqual(key?["level"], .string("look")); XCTAssertEqual(key?["tasks"], .bool(false))
        await r.consent.stop()
    }

    func testWorkAndFullOnlyGrantedAfterAuthenticatedPhoneTap() async throws {
        for scope in ["work", "full"] {
            let delivered = expectation(description: scope + " prompt")
            let seen = BackendDeckCoreSecurityTestBox<String?>(nil)
            let r = try await rig { question in seen.set(question.id); delivered.fulfill(); return true }
            let c = await caller(r)
            let call = Task { await r.control.call(name: "access_request_scope", arguments: self.arguments(scope), options: .init(caller: c)) }
            await fulfillment(of: [delivered], timeout: 1)
            let before = await r.keys.get(id: r.id); XCTAssertEqual(before?["level"], .string("look"))
            _ = await r.consent.respond(id: seen.get() ?? "missing", approved: true, by: "device:owner-phone")
            let result = await call.value; XCTAssertTrue(result.ok)
            let after = await r.keys.get(id: r.id); XCTAssertEqual(after?["level"], .string(scope))
            XCTAssertEqual(after?["folders"], .array([.string("/work/project")]))
            XCTAssertEqual(after?["tasks"], .bool(false))
            XCTAssertEqual(after?["grantedScopes"].elements?.compactMap(\.string), scope == "work" ? ["look", "work"] : ["look", "work", "full"])
            await r.consent.stop()
        }
    }
}
