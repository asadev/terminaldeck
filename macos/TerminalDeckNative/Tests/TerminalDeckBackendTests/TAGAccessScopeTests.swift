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
        let requests: BackendTAGAccessScope
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
        let requests = BackendTAGAccessScope(keys: keys, serverScopeEnabled: true, now: { clock.now() })
        let log = BackendDeckCoreSecurityActionLog(directory: root, now: { clock.now() })
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: try requests.bundle().policies, now: { clock.now() })
        return Rig(root: root, id: id, keys: keys, consent: consent, control: control, log: log, clock: clock, requests: requests)
    }
    private func arguments(_ scope: String = "tasks") -> NativeRPCValue {
        .object([.init("scope", .string(scope)), .init("reason", .string("Need task agents"))])
    }
    private func caller(_ r: Rig) async -> BackendDeckCoreSecurityCaller { await r.keys.caller(id: r.id, nameAtArrival: "Commander") }

    /// Asad, 11 Oct: "app itself will not ask any permissions at all". A key asking for MORE access than it was granted
    /// (tasks, work, full, or one saved server) is refused at once, with no card, and nothing about the key changes:
    /// only the person changes a key's access, in Settings → AI apps.
    func testEveryScopeRequestIsRefusedWithoutACardAndChangesNothing() async throws {
        let r = try await rig { _ in XCTFail("no card may be shown"); return true }
        let servers = BackendServersStore(dataRoot: r.root.appendingPathComponent("servers"), policy: .init(mayRead: true, mayWrite: true))
        let server = try servers.add(.init(name: "iMatch", address: "100.86.183.128", username: "admin"))
        try await r.requests.setServerStore(servers)
        let c = await caller(r)
        XCTAssertEqual(c.tiers, [.read]); XCTAssertFalse(c.tasks); XCTAssertEqual(c.askFirst, false)
        let policy = await r.control.policy(named: "access.request_scope")
        XCTAssertEqual(policy?.tool.tier, .read); XCTAssertEqual(policy?.keyRequiresTasks, false)
        XCTAssertTrue(policy?.visible(to: nil, caller: c) == true)
        let asks = [arguments("tasks"), arguments("work"), arguments("full"),
                    NativeRPCValue.object([.init("scope", .string("server")), .init("serverId", .string(server.id)), .init("reason", .string("Read my iMatch Docker status"))])]
        for (index, args) in asks.enumerated() {
            if index > 0 { r.clock.advance(600_000) }   // past the request guard
            let result = await r.control.call(name: "access_request_scope", arguments: args, options: .init(caller: c))
            XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .notGranted)
            XCTAssertTrue(result.error?.contains("Settings → AI apps") == true, result.error ?? "")
        }
        let key = await r.keys.get(id: r.id)
        XCTAssertEqual(key?["level"], .string("look")); XCTAssertEqual(key?["tasks"], .bool(false))
        XCTAssertEqual(key?["folders"], .array([.string("/work/project")]))
        XCTAssertEqual(try servers.get(server.id)?.aiKeyIDs ?? [], [])
        let pending = await r.consent.list(); XCTAssertTrue(pending.isEmpty)
        let rows = await r.log.tail(); XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0["outcome"] == .string("refused") && $0["tool"] == .string("access.request_scope") })
        await r.consent.stop()
    }

    func testUnknownServerScopeFailsWithoutOwnerPromptOrPermission() async throws {
        let r = try await rig { _ in XCTFail("An unknown server must not prompt"); return false }
        let servers = BackendServersStore(dataRoot: r.root.appendingPathComponent("servers"), policy: .init(mayRead: true, mayWrite: true))
        try await r.requests.setServerStore(servers)
        let args = NativeRPCValue.object([.init("scope", .string("server")), .init("serverId", .string("unknown")), .init("reason", .string("Read status"))])
        let c = await caller(r)
        let result = await r.control.call(name: "access_request_scope", arguments: args, options: .init(caller: c))
        XCTAssertFalse(result.ok); XCTAssertEqual(try servers.list().count, 0)
        await r.consent.stop()
    }

    func testDedicatedBudgetCountsDeniedRequestsAndResetsAfterWindow() async throws {
        let offered = BackendDeckCoreSecurityTestBox<Int>(0)
        let r = try await rig { _ in offered.edit { $0 += 1 }; return false }, c = await caller(r)
        let first = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(first.refusal, .notGranted)
        let immediate = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(immediate.refusal, .rateLimited)
        for _ in 0..<2 {
            r.clock.advance(60_000)
            let refused = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(refused.refusal, .notGranted)
        }
        r.clock.advance(60_000)
        let capped = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(capped.refusal, .rateLimited)
        XCTAssertEqual(offered.get(), 0, "no card, ever")
        r.clock.advance(600_000)
        let later = await r.control.call(name: "access_request_scope", arguments: arguments(), options: .init(caller: c)); XCTAssertEqual(later.refusal, .notGranted)
        XCTAssertEqual(offered.get(), 0)
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
}
