import Foundation
import XCTest
@testable import TerminalDeckBackend

final class DKTLiveSafetyHarnessTests: XCTestCase {
    func testStoreMutationsAreRefusedBeforeTransport() async throws {
        let counter = DKTLiveAttemptCounter()
        let resource = DKTLiveResourceProof(kind: .container, id: "id-test", name: "td-test-web")
        let actualWrites = BackendDockerChannels.writeChannels.union(BackendAppsChannels.writeChannels).union(BackendAppsDataChannels.writeChannels)
            .union(DKTLiveSafetyHarness.mutationChannels)
        for channel in actualWrites {
            do {
                _ = try await DKTLiveSafetyHarness.perform(target: .store, operation: .mutation(channel: channel, resources: [resource])) {
                    await counter.increment()
                    return true
                }
                XCTFail("Store mutation was accepted.")
            } catch is DKTLiveSafetyRefusal {} // Must fail at the harness, before any adapter.
        }
        let count = await counter.value
        XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .store, operation: .caddyRouteMutation(method: "DELETE", path: "/id/td-test-route", routeID: "td-test-route", body: nil)))
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .store, operation: .filesystemMutation(paths: ["/tmp/td-test-run"])))
        for channel in actualWrites {
            XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .store, operation: .read(channel: channel)))
        }
    }

    func testUnknownHostsAndRelayAreRefused() throws {
        for host in ["terminaldeck-relay", "relay", "178.105.239.176", "example.com", "terminaldeck-store; restart", "-oProxyCommand=anything"] {
            XCTAssertThrowsError(try DKTLiveTarget.resolve(host))
        }
        XCTAssertEqual(try DKTLiveTarget.resolve("terminaldeck-server"), .demo)
        XCTAssertEqual(try DKTLiveTarget.resolve("terminaldeck-store"), .store)
    }

    func testDemoRefusesUnownedMixedAndInstallMutations() throws {
        let owned = DKTLiveResourceProof(kind: .container, id: "owned", name: "td-test-web")
        let other = DKTLiveResourceProof(kind: .container, id: "real", name: "supabase-db")
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .mutation(channel: "docker:containers:remove", resources: [owned])))
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .mutation(channel: "docker:containers:remove", resources: [owned, other])))
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .mutation(channel: "docker:containers:remove", resources: [])))
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .mutation(channel: "docker:images:remove", resources: [owned])))
        for channel in ["docker:install", "docker:images:pull", "docker:images:build", "apps:caddy:install", "apps:auto-deploy:apply", "unknown:write"] {
            XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .mutation(channel: channel, resources: [owned])))
        }
    }

    func testCaddyOnlyAddsAndRemovesOwnedRoutesByID() throws {
        let route = Data(#"{"@id":"td-test-route","match":[{"host":["td-test-web.178-105-239-176.sslip.io"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"172.18.0.2:8080"}]}]}"#.utf8)
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "POST", path: "/config/apps/http/servers/srv0/routes", routeID: "td-test-route", body: route)))
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "PUT", path: "/config/apps/http/servers/srv0/routes/0", routeID: "td-test-route", body: route)))
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "DELETE", path: "/id/td-test-route", routeID: "td-test-route", body: nil)))
        for path in ["/load", "/config/", "/config/apps/http/servers/srv0/routes/0", "/id/protected", "/id/td-test-route/../protected"] {
            XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "DELETE", path: path, routeID: "td-test-route", body: nil)))
        }
        let protected = Data(#"{"@id":"td-test-route","match":[{"host":["178-105-239-176.sslip.io"]}]}"#.utf8)
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "POST", path: "/config/apps/http/servers/srv0/routes", routeID: "td-test-route", body: protected)))
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "PATCH", path: "/id/td-test-route", routeID: "td-test-route", body: route)))
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "PATCH", path: "/config/", routeID: "td-test-route", body: route)))
        let nested = Data(#"{"@id":"td-test-route","match":[{"host":["td-test-web.178-105-239-176.sslip.io"]}],"handle":[{"@id":"protected","handler":"reverse_proxy","upstreams":[{"dial":"172.18.0.2:8080"}]}]}"#.utf8)
        XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .caddyRouteMutation(method: "POST", path: "/config/apps/http/servers/srv0/routes", routeID: "td-test-route", body: nested)))
    }

    func testFilesystemWritesStayInsideNamedTestFolders() throws {
        XCTAssertNoThrow(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .filesystemMutation(paths: ["/var/lib/terminaldeck/apps/td-test-app/state.json", "/tmp/td-test-installer/plan.txt"])))
        for path in ["/etc/caddy/Caddyfile", "/var/lib/terminaldeck/apps/real/state.json", "/tmp/td-test-run/../real", "/tmp/td-test-", "/var/lib/terminaldeck/apps"] {
            XCTAssertThrowsError(try DKTLiveSafetyHarness.authorize(target: .demo, operation: .filesystemMutation(paths: [path])))
        }
    }

    func testSymlinkResolvedFileWriteIsRefusedBeforeMutation() async throws {
        let counter = DKTLiveAttemptCounter()
        let operation = DKTLiveOperation.filesystemMutation(paths: ["/tmp/td-test-link/state.json"])
        do {
            _ = try await DKTLiveSafetyHarness.perform(target: .demo, operation: operation,
                resolvePaths: { _ in ["/etc/caddy/state.json"] }, transport: { await counter.increment(); return true })
            XCTFail("Symlink ancestry reached a filesystem mutation.")
        } catch is DKTLiveSafetyRefusal {}
        do {
            _ = try await DKTLiveSafetyHarness.perform(target: .demo, operation: operation,
                transport: { await counter.increment(); return true })
            XCTFail("Absent server path verification reached a filesystem mutation.")
        } catch is DKTLiveSafetyRefusal {}
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testCleanupProofDetectsResidueRemovalAndCaddyChanges() throws {
        let protected = DKTLiveResourceProof(kind: .container, id: "real", name: "supabase-db")
        let test = DKTLiveResourceProof(kind: .container, id: "test", name: "td-test-web")
        let config = Data(#"{"apps":{"http":{"servers":{"srv0":{"routes":[{"@id":"protected"}]}}}}}"#.utf8)
        let baseline = try DKTLiveInventory(resources: [protected], caddyConfig: config)
        let identical = try DKTLiveInventory(resources: [protected], caddyConfig: config)
        XCTAssertTrue(try baseline.cleanupProof(after: identical).listBeforeEqualsListAfter)
        XCTAssertThrowsError(try baseline.cleanupProof(after: DKTLiveInventory(resources: [protected, test], caddyConfig: config)))
        XCTAssertThrowsError(try baseline.cleanupProof(after: DKTLiveInventory(resources: [], caddyConfig: config)))
        XCTAssertThrowsError(try baseline.cleanupProof(after: DKTLiveInventory(resources: [protected], caddyConfig: Data(#"{"apps":{}}"#.utf8))))
        XCTAssertThrowsError(try DKTLiveInventory(resources: [protected, protected], caddyConfig: config))
    }

    func testCleanupInventoryIgnoresOrderingButNotIdentity() throws {
        let first = DKTLiveResourceProof(kind: .container, id: "a", name: "existing")
        let second = DKTLiveResourceProof(kind: .volume, id: "b", name: "data")
        let before = try DKTLiveInventory(resources: [first, second], caddyConfig: Data(#"{"a":1,"b":2}"#.utf8))
        let after = try DKTLiveInventory(resources: [second, first], caddyConfig: Data(#"{"b":2,"a":1}"#.utf8))
        XCTAssertTrue(try before.cleanupProof(after: after).listBeforeEqualsListAfter)
    }

    func testLiveRequiresFreshCompleteDKAFakeEvidence() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let suites: Set<String> = ["DKTHTTPServerTests", "DKTDockerContractTests", "DKTDockerSafetyTests", "DKTDockerServerApprovalTests", "DKTAppsMCPSafetyTests", "DKTCaddyFixtureTests",
            "DKTAppsDataContractTests", "DKTCaddyAppsContractTests", "DKTCaddyAppsBackupLogTests", "DKTLiveSafetyHarnessTests", "DKTLiveInventoryCollectorTests"]
        XCTAssertNoThrow(try DKTFakeSuiteEvidence(runner: "DKA", completedAt: now, passed: 20, failed: 0, skipped: 0, suites: suites, logPath: "DKA-fake-suite.log").validate(now: now))
        for evidence in [
            DKTFakeSuiteEvidence(runner: "DKT", completedAt: now, passed: 20, failed: 0, skipped: 0, suites: suites, logPath: "log"),
            DKTFakeSuiteEvidence(runner: "DKA", completedAt: now, passed: 20, failed: 1, skipped: 0, suites: suites, logPath: "log"),
            DKTFakeSuiteEvidence(runner: "DKA", completedAt: now, passed: 20, failed: 0, skipped: 1, suites: suites, logPath: "log"),
            DKTFakeSuiteEvidence(runner: "DKA", completedAt: now.addingTimeInterval(-3601), passed: 20, failed: 0, skipped: 0, suites: suites, logPath: "log"),
            DKTFakeSuiteEvidence(runner: "DKA", completedAt: now, passed: 20, failed: 0, skipped: 0, suites: ["DKTCaddyFixtureTests"], logPath: "log"),
        ] { XCTAssertThrowsError(try evidence.validate(now: now)) }
    }

    func testFailedLiveBodyStillCleansUpAndRecordsEqualLists() async throws {
        let state = DKTLiveRunFixture()
        let before = try DKTLiveInventory(resources: [], caddyConfig: Data(#"{"apps":{}}"#.utf8))
        do {
            let _: Bool = try await DKTLiveRunHarness.run(target: .demo, evidence: evidence(), inventory: { before },
                body: { _ in throw DKTLiveSafetyRefusal("synthetic body failure") },
                cleanup: { _ in await state.markCleanup() }, record: { await state.record($0) })
            XCTFail("The failed body returned success.")
        } catch let failure as DKTLiveSafetyRefusal { XCTAssertEqual(failure.message, "synthetic body failure") }
        let cleaned = await state.cleaned
        let records = await state.records
        XCTAssertTrue(cleaned)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.cleanupPassed, true)
        XCTAssertEqual(records.first?.outcome, "test-failed")
        XCTAssertEqual(records.first?.before, records.first?.after)
    }

    func testLiveResidueRecordsFailureAndNeverClaimsSuccess() async throws {
        let state = DKTLiveRunFixture()
        let before = try DKTLiveInventory(resources: [], caddyConfig: Data(#"{"apps":{}}"#.utf8))
        let residue = DKTLiveResourceProof(kind: .volume, id: "td-test-data", name: "td-test-data")
        let after = try DKTLiveInventory(resources: [residue], caddyConfig: Data(#"{"apps":{}}"#.utf8))
        do {
            let _: Bool = try await DKTLiveRunHarness.run(target: .demo, evidence: evidence(),
                inventory: { await state.nextInventory(before: before, after: after) }, body: { _ in true },
                cleanup: { _ in await state.markCleanup() }, record: { await state.record($0) })
            XCTFail("Leftover test resources returned a successful run.")
        } catch is DKTLiveSafetyRefusal {}
        let records = await state.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.cleanupPassed, false)
        XCTAssertEqual(records.first?.outcome, "cleanup-proof-failed")
    }

    func testUnavailableAfterInventoryStillRecordsUnprovedCleanup() async throws {
        let state = DKTLiveRunFixture()
        let before = try DKTLiveInventory(resources: [], caddyConfig: Data(#"{"apps":{}}"#.utf8))
        do {
            let _: Bool = try await DKTLiveRunHarness.run(target: .store, evidence: evidence(), inventory: {
                let index = await state.inventoryCall()
                if index == 1 { return before }
                throw DKTLiveSafetyRefusal("synthetic final inventory failure")
            }, body: { session in
                try await session.perform(.read(channel: "docker:containers:list")) { true }
            }, cleanup: { _ in }, record: { await state.record($0) })
            XCTFail("Missing after inventory returned success.")
        } catch is DKTLiveSafetyRefusal {}
        let records = await state.records
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.after)
        XCTAssertEqual(records.first?.cleanupPassed, false)
        XCTAssertEqual(records.first?.whatRan, ["docker:containers:list"])
    }

    func testUnavailableBaselineRecordsAttemptAndStartsNoBodyOrCleanup() async throws {
        let state = DKTLiveRunFixture()
        let counter = DKTLiveAttemptCounter()
        do {
            let _: Bool = try await DKTLiveRunHarness.run(target: .demo, evidence: evidence(), inventory: {
                throw DKTLiveSafetyRefusal("synthetic inventory failure")
            }, body: { _ in await counter.increment(); return true }, cleanup: { _ in await counter.increment() },
                record: { try Task.checkCancellation(); await state.record($0) })
            XCTFail("Missing baseline allowed a live run.")
        } catch is DKTLiveSafetyRefusal {}
        let attempts = await counter.value
        let records = await state.records
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.before)
        XCTAssertNil(records.first?.after)
        XCTAssertEqual(records.first?.outcome, "baseline-unavailable")
        XCTAssertEqual(records.first?.cleanupPassed, false)
    }

    func testCancelledLiveBodyStillUsesUncancelledCleanupAndFinalRead() async throws {
        let state = DKTLiveRunFixture()
        let before = try DKTLiveInventory(resources: [], caddyConfig: Data(#"{"apps":{}}"#.utf8))
        let passingEvidence = evidence()
        let running = Task {
            let _: Bool = try await DKTLiveRunHarness.run(target: .demo, evidence: passingEvidence,
                inventory: { try Task.checkCancellation(); return before }, body: { _ in
                    await state.bodyStarted()
                    try await Task.sleep(for: .seconds(10))
                    return true
                }, cleanup: { _ in try Task.checkCancellation(); await state.markCleanup() },
                record: { try Task.checkCancellation(); await state.record($0) })
        }
        await state.waitForBody()
        running.cancel()
        do { try await running.value; XCTFail("Cancelled live body returned success.") }
        catch is CancellationError {}
        let cleaned = await state.cleaned
        let records = await state.records
        XCTAssertTrue(cleaned)
        XCTAssertEqual(records.first?.cleanupPassed, true)
        XCTAssertNotNil(records.first?.after)
        XCTAssertEqual(records.first?.outcome, "test-failed")
    }

    private func evidence() -> DKTFakeSuiteEvidence {
        .init(runner: "DKA", completedAt: Date().addingTimeInterval(-1), passed: 20, failed: 0, skipped: 0,
              suites: ["DKTHTTPServerTests", "DKTDockerContractTests", "DKTDockerSafetyTests", "DKTDockerServerApprovalTests", "DKTAppsMCPSafetyTests", "DKTCaddyFixtureTests",
                "DKTAppsDataContractTests", "DKTCaddyAppsContractTests", "DKTCaddyAppsBackupLogTests", "DKTLiveSafetyHarnessTests", "DKTLiveInventoryCollectorTests"], logPath: "DKA-fake-suite.log")
    }
}

private actor DKTLiveAttemptCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor DKTLiveRunFixture {
    var cleaned = false
    var records: [DKTLiveRunRecord] = []
    private var inventoryCalls = 0
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func markCleanup() { cleaned = true }
    func record(_ record: DKTLiveRunRecord) { records.append(record) }
    func inventoryCall() -> Int { inventoryCalls += 1; return inventoryCalls }
    func nextInventory(before: DKTLiveInventory, after: DKTLiveInventory) -> DKTLiveInventory {
        inventoryCalls += 1
        return inventoryCalls == 1 ? before : after
    }
    func bodyStarted() { started = true; waiter?.resume(); waiter = nil }
    func waitForBody() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
