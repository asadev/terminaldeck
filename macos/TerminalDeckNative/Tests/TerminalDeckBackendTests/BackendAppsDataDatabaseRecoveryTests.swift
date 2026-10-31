import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APD per-app sealed recovery adoption: semantic fakes")
struct BackendAppsDataDatabaseRecoveryTests {
    @Test(arguments: ["td-test-above", "td-test-zebra"])
    func bindingIssuesIndependentScopesForBothLockOrders(targetID: String) async throws {
        let h = try await setup(targetID: targetID)
        let result = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
            try await BackendAppsDataDatabaseBinding(runtime: h.runtime, store: h.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: targetID, key: nil)
        }
        #expect(result["bound"].bool == true)
        let scopes = await h.fake.recoveryScopes
        #expect(scopes.map(\.appID) == ["td-test-data", targetID].sorted())
        #expect(Set(scopes.map(\.transactionID)).count == 2)
        #expect(Set(scopes.map(\.ownerToken)).count == 2)
        #expect(scopes.allSatisfy { $0.requestID == h.context.requestID && $0.ownerID == h.context.ownerID })
        #expect(await h.fake.closedRecoveryScopes == Set(scopes.map(\.transactionID)))
        #expect((await h.fake.heldLocks()).isEmpty)
        let audits = await h.fake.recoveryAudits
        #expect(audits.filter { $0.operation == "restore-captured-file" }.allSatisfy { $0.appID == targetID })
        #expect(audits.allSatisfy { !$0.value.compact.contains("postgresql://") })
        await h.kernel.shutdown()
    }

    @Test(arguments: ["td-test-above", "td-test-zebra"])
    func cancelledBindingRestoresOnlyTargetFilesAndReleasesBothTokens(targetID: String) async throws {
        let h = try await setup(targetID: targetID), pause = BackendAppsDataDatabaseRecoveryPause()
        let beforeEnv = try await NativeCompositionCallContext.$rpc.withValue(h.context) { try await h.store.environment("fake-server", targetID) }
        let beforeRecord = try await NativeCompositionCallContext.$rpc.withValue(h.context) { try await h.store.read("fake-server", targetID) }
        await h.fake.pauseBindingAtEnvironmentWrite(pause)
        let task = NativeCompositionCallContext.$rpc.withValue(h.context) {
            Task { try await BackendAppsDataDatabaseBinding(runtime: h.runtime, store: h.store)
                .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: targetID, key: nil) }
        }
        let completion = Task { _ = try? await task.value; await pause.finished() }
        try #require(await pause.waitUntilEntered())
        task.cancel(); await h.fake.revokeRecoveryReceipt(); await pause.release()
        do { _ = try await task.value; Issue.record("Cancelled binding became success") }
        catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(error.message.contains("previous settings were restored"))
        }
        let envBytes = try #require(await h.fake.savedFile("/var/lib/td-test-apps/" + targetID + "/.env"))
        #expect(String(decoding: envBytes, as: UTF8.self) == beforeEnv.keys.sorted().map { $0 + "=" + beforeEnv[$0]! + "\n" }.joined())
        let recordBytes = try #require(await h.fake.savedFile("/var/lib/td-test-apps/" + targetID + "/state.json"))
        #expect(try NativeRPCValue.parseJSON(recordBytes) == beforeRecord)
        #expect(await h.fake.savedFile("/var/lib/td-test-apps/" + targetID + "/data-binding-intent.json") == nil)
        #expect((await h.fake.heldLocks()).isEmpty)
        #expect((await h.fake.closedRecoveryScopes).count == 2)
        let events = await h.fake.recoveryAudits
        #expect(events.filter { $0.event == "finished" && $0.operation == "restore-captured-file" }.allSatisfy { $0.appID == targetID && $0.successful == true })
        await completion.value
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) { try await h.runtime.run("fake-server", "ordinary call") }
            Issue.record("Sealed recovery renewed ordinary receipt authority")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        await h.kernel.shutdown()
    }

    @Test func issuerRefusesAnUnapprovedThirdAppBeforeEitherLockIsTaken() async throws {
        let h = try await setup(targetID: "td-test-zebra")
        let beforeCommands = (await h.fake.commands).count
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
                try await BackendAppsDataDatabaseBinding(runtime: h.runtime, store: h.store)
                    .bind(serverID: "fake-server", appID: "td-test-data", targetAppID: "td-test-third", key: nil)
            }
            Issue.record("The approved pair expanded to a third app")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.commands).count == beforeCommands)
        #expect((await h.fake.heldLocks()).isEmpty)
        #expect((await h.fake.closedRecoveryScopes).count == (await h.fake.recoveryScopes).count)
        await h.kernel.shutdown()
    }

    @Test func approvedPairStillCannotBorrowAnotherAppsFileOrHandle() async throws {
        let h = try await setup(targetID: "td-test-zebra")
        let source = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
            try await h.kernel.begin(runtime: h.runtime, serverID: "fake-server", appID: "td-test-data")
        }
        let target = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
            try await h.kernel.begin(runtime: h.runtime, serverID: "fake-server", appID: "td-test-zebra")
        }
        let before = (await h.fake.commands).count
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
                try await source.register(.restoreAppFile(path: target.scope.appDirectory + "/.env"))
            }
            Issue.record("One approved app captured the other app's file")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.commands).count == before)
        let handle = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
            try await source.register(.restoreAppFile(path: source.scope.appDirectory + "/.env"))
        }
        let captured = (await h.fake.commands).count
        do { _ = try await target.perform(handle); Issue.record("A handle moved between approved app scopes") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.commands).count == captured)
        await h.kernel.finish(target); await h.kernel.finish(source)
    }

    @Test func cancelledProvisioningRetainsCreatedDatabaseAndDurableSetupJournal() async throws {
        let fake = BackendAppsDataDatabaseFixture(), context = approvedContext(), pause = BackendAppsDataDatabaseRecoveryPause()
        await fake.approveRecovery(context, apps: ["td-test-data"])
        let kernel = fake.recoveryKernel(), runtime = fake.runtime(recovery: kernel), store = BackendAppsStore(runtime: runtime)
        await fake.pauseProvisioningAtStart(pause)
        let task = NativeCompositionCallContext.$rpc.withValue(context) {
            Task { try await BackendAppsDataDatabases(runtime: runtime, store: store)
                .create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil) }
        }
        let completion = Task { _ = try? await task.value; await pause.finished() }
        try #require(await pause.waitUntilEntered())
        task.cancel(); await fake.revokeRecoveryReceipt(); await pause.release()
        do { _ = try await task.value; Issue.record("Cancelled setup became success") }
        catch let error as NativeRPCError { #expect(error.code == "state-failed") }
        let bytes = try #require(await fake.savedFile("/var/lib/td-test-apps/td-test-data/state.json"))
        let record = try NativeRPCValue.parseJSON(bytes)
        #expect(record["status"].string == "deploying")
        #expect(record["database"]["provisionPhase"].string == "service-created")
        #expect(record["database"]["containerId"].string == BackendAppsDataDatabaseFixture.containerID)
        #expect(await fake.containerBody != nil)
        #expect(!(await fake.events).contains { $0.hasPrefix("DELETE:") })
        #expect((await fake.heldLocks()).isEmpty)
        #expect((await fake.closedRecoveryScopes).count == 1)
        #expect(!(await fake.recoveryAudits).contains { $0.operation == "remove-transaction-candidates" })
        await completion.value
        await kernel.shutdown()
    }

    private func setup(targetID: String) async throws -> (fake: BackendAppsDataDatabaseFixture, kernel: BackendAppsRecovery, runtime: BackendAppsRuntime, store: BackendAppsStore, context: NativeRPCContext) {
        let fake = BackendAppsDataDatabaseFixture(), initial = fake.runtime(), initialStore = BackendAppsStore(runtime: initial)
        _ = try await BackendAppsDataDatabases(runtime: initial, store: initialStore)
            .create(serverID: "fake-server", appID: "td-test-data", name: "Test data", kind: "postgres", version: nil)
        let target = BackendAppsValidation.object([("id", .string(targetID)), ("name", .string("Website")), ("kind", .string("app")),
            ("status", .string("stopped")), ("envKeys", .array([.string("UNRELATED")])), ("updatedAt", .number(1))])
        try await initialStore.write("fake-server", targetID, target)
        try await initialStore.applyEnvironment("fake-server", targetID, ["UNRELATED": "keep-me"])
        let context = approvedContext()
        await fake.approveRecovery(context, apps: ["td-test-data", targetID])
        let kernel = fake.recoveryKernel(), runtime = fake.runtime(recovery: kernel), store = BackendAppsStore(runtime: runtime)
        return (fake, kernel, runtime, store, context)
    }
    private func approvedContext() -> NativeRPCContext { .init(caller: .page, ownerID: "binding-test-owner", capabilities: ["apps.write"]) }
}
