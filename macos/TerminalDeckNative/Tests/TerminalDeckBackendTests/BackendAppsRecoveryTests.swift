import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APE sealed recovery: semantic Swift transport fakes, no servers")
struct BackendAppsRecoveryTests {
    @Test func sealedPrivateBeforeImageRecoversAfterReceiptCancellationButOrdinaryIOAndEnrollmentRemainDenied() async throws {
        let h = try await harness()
        let path = h.transaction.scope.appDirectory + "/.env"
        let original = Data("TOKEN=td-test-private-before-image\n".utf8)
        await h.fake.putFile(original, path: path)
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let handle = try await register(h, .restoreAppFile(path: path))
        await h.fake.putFile(Data("TOKEN=changed\n".utf8), path: path)
        await h.fake.revokeReceipt(h.context)
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) { try await h.runtime.run("td-test-server", "ordinary caller command") }
            Issue.record("An expired ordinary caller reused transport authority")
        } catch let error as NativeRPCError { #expect(["access-denied", "unavailable"].contains(error.code)) }
        let beforeEnrollment = await h.fake.snapshot()
        do {
            _ = try await register(h, .restoreAppFile(path: path))
            Issue.record("Cancellation minted a new recovery plan")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.snapshot()).rawCommands.count == beforeEnrollment.rawCommands.count)
        let outcome = try await Task { try await h.transaction.perform(handle) }.value
        #expect(outcome.completed)
        let state = await h.fake.snapshot()
        #expect(state.files[path] == original)
        #expect(state.audits.allSatisfy { !$0.value.compact.contains("td-test-private-before-image") })
        #expect(state.audits.allSatisfy { $0.ownerID == h.context.ownerID && $0.serverID == "td-test-server" && $0.appID == "td-test-app" })
        await h.kernel.finish(h.transaction)
        #expect((await h.fake.snapshot()).closed == 1)
    }

    @Test(arguments: [true, false])
    func lockReleaseMatchesOnlyThisTransactionToken(matching: Bool) async throws {
        let h = try await harness()
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: matching ? h.transaction.scope.ownerToken : "td-test-another-mac")
        await h.fake.revokeReceipt(h.context)
        let outcome = try await h.transaction.perform(handle)
        #expect(outcome.completed == matching)
        let state = await h.fake.snapshot()
        #expect(state.locks[path] == (matching ? nil : "td-test-another-mac"))
        await h.kernel.finish(h.transaction)
    }

    @Test func replayWrongTransactionAndFinishedHandlesPerformNoFurtherIO() async throws {
        let h = try await harness()
        let second = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
            try await h.kernel.begin(runtime: h.runtime, serverID: "td-test-server", appID: "td-test-app")
        }
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        let baseline = await h.fake.snapshot()
        do { _ = try await second.perform(handle); Issue.record("Another transaction accepted a sealed handle") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.snapshot()).rawCommands.count == baseline.rawCommands.count)
        #expect(try await h.transaction.perform(handle).completed)
        let afterFirst = await h.fake.snapshot()
        do { _ = try await h.transaction.perform(handle); Issue.record("A one-shot handle was replayed") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.snapshot()).rawCommands.count == afterFirst.rawCommands.count)
        await h.kernel.finish(h.transaction)
        do { _ = try await h.transaction.perform(handle); Issue.record("A finished transaction still had authority") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        await h.kernel.finish(second)
        #expect((await h.fake.snapshot()).closed == 2)
    }

    @Test(arguments: ["read-only", "unapproved", "revoked"])
    func copiedTaskLocalAndUnapprovedOrReadOnlyCallerCannotCapture(mode: String) async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock()
        let context = NativeRPCContext(caller: .page, ownerID: "td-test-owner",
                                       capabilities: mode == "read-only" ? ["apps.read"] : ["apps.write"])
        if mode != "unapproved" { await fake.approve(context) }
        if mode == "revoked" { await fake.revokeReceipt(context) }
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime()
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
            }
            Issue.record("An unapproved copied RPC context minted recovery authority")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        if mode == "read-only" {
            let forged = NativeRPCContext(caller: .page, ownerID: context.ownerID, requestID: context.requestID, capabilities: ["apps.write"])
            do {
                _ = try await NativeCompositionCallContext.$rpc.withValue(forged) {
                    try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
                }
                Issue.record("Edited capability fields upgraded a read receipt")
            } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        let state = await fake.snapshot()
        #expect(state.opened == 0 && state.rawCommands.isEmpty && state.dockerCalls.isEmpty)
        await kernel.shutdown()
    }

    @Test func otherServerAppCallerRequestAndPathsCannotExpandCapturedScope() async throws {
        let h = try await harness()
        for (server, app) in [("td-test-other-server", "td-test-app"), ("td-test-server", "td-test-other-app")] {
            do {
                _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
                    try await h.kernel.begin(runtime: h.runtime, serverID: server, appID: app)
                }
                Issue.record("A receipt changed its server or app")
            } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        for context in [
            NativeRPCContext(caller: .page, ownerID: "td-test-other-owner", requestID: h.context.requestID, capabilities: ["apps.write"]),
            NativeRPCContext(caller: .page, ownerID: h.context.ownerID, capabilities: ["apps.write"])
        ] {
            do {
                _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                    try await h.transaction.register(.restoreAppFile(path: h.transaction.scope.appDirectory + "/state.json"))
                }
                Issue.record("A different RPC owner or request expanded the transaction")
            } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        for path in ["/etc/passwd", "/var/lib/td-test-apps/td-test-other-app/state.json", h.transaction.scope.appDirectory + "/../outside"] {
            do { _ = try await register(h, .restoreAppFile(path: path)); Issue.record("An arbitrary recovery path was accepted") }
            catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        let state = await h.fake.snapshot()
        #expect(state.opened == 1 && state.rawCommands.isEmpty && state.dockerCalls.isEmpty)
        await h.kernel.finish(h.transaction)
    }

    @Test func serverGenerationChangeBlocksCapturedTransportWithoutContactingReplacement() async throws {
        let h = try await harness()
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        await h.fake.replaceServerGeneration()
        let baseline = await h.fake.snapshot()
        #expect(!(try await h.transaction.perform(handle)).completed)
        let state = await h.fake.snapshot()
        #expect(state.rawCommands.count == baseline.rawCommands.count)
        #expect(state.locks[path] == h.transaction.scope.ownerToken)
        await h.kernel.finish(h.transaction)
        #expect((await h.fake.snapshot()).closed == 1)
    }

    @Test func candidateCleanupUsesTransactionLabelAndPreservesOtherCandidatesAndVolumes() async throws {
        let h = try await harness()
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        try await seedStoppedState(h)
        let handle = try await register(h, .removeCreatedContainers)
        let own = String(repeating: "b", count: 64), other = String(repeating: "a", count: 64)
        await h.fake.putContainer(id: own, app: "td-test-app", transaction: h.transaction.scope.ownerToken, connected: true)
        await h.fake.putContainer(id: other, app: "td-test-app", transaction: "td-test-other-transaction")
        await h.fake.revokeReceipt(h.context)
        #expect(try await h.transaction.perform(handle).completed)
        let state = await h.fake.snapshot()
        #expect(state.containerIDs == [other])
        #expect(state.deleted == [own])
        #expect(state.volumes == ["td-test-original-volume", "td-test-recovery-volume"])
        #expect(state.dockerCalls.filter { $0.method == "DELETE" }.allSatisfy { $0.path.hasSuffix("?force=true&v=false") })
        #expect(state.dockerCalls.allSatisfy { !$0.path.hasPrefix("/volumes") })
        await h.kernel.finish(h.transaction)
    }

    @Test func untrustedEngineFilterResponseCannotRemoveAnotherTransactionsCandidate() async throws {
        let h = try await harness()
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        try await seedStoppedState(h)
        let handle = try await register(h, .removeCreatedContainers)
        let other = String(repeating: "a", count: 64)
        await h.fake.putContainer(id: other, app: "td-test-app", transaction: "td-test-other-transaction")
        await h.fake.ignoreEngineFilters()
        #expect(!(try await h.transaction.perform(handle)).completed)
        let state = await h.fake.snapshot()
        #expect(state.containerIDs == [other] && state.deleted.isEmpty)
        await h.kernel.finish(h.transaction)
    }

    @Test(arguments: ["state", "active-deployment", "route"])
    func candidateStillServingByAnyDurableSignalIsPreserved(signal: String) async throws {
        let h = try await harness()
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let id = String(repeating: "b", count: 64)
        var state = stoppedState()
        if signal == "state" { state = state.setting("containerId", .string(id)).setting("status", .string("running")) }
        if signal == "active-deployment" {
            state = state.setting("activeDeploymentId", .string("td-test-serving")).setting("deployments", .array([BackendAppsValidation.object([("id", .string("td-test-serving")), ("containerId", .string(id))])]))
        }
        await h.fake.putFile(try state.encodedJSON(), path: h.transaction.scope.appDirectory + "/state.json")
        if signal == "route" { await h.fake.serveRoute(ip: "172.25.0.12") }
        await h.fake.putContainer(id: id, app: "td-test-app", transaction: h.transaction.scope.ownerToken, running: true, connected: true)
        let handle = try await register(h, .removeCreatedContainers)
        #expect(!(try await h.transaction.perform(handle)).completed)
        let snapshot = await h.fake.snapshot()
        #expect(snapshot.containerIDs == [id] && snapshot.deleted.isEmpty)
        await h.kernel.finish(h.transaction)
    }

    @Test(arguments: [true, false])
    func workCleanupHonorsMarkerBeforeDeletingAnyFiles(matching: Bool) async throws {
        let h = try await harness()
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let path = h.transaction.scope.appDirectory + "/td-test-builds/td-test-work"
        await h.fake.putFile(Data((matching ? h.transaction.scope.ownerToken : "td-test-other-transaction").utf8), path: path + "/.recovery-owner")
        await h.fake.putFile(Data("td-test-important-work".utf8), path: path + "/source.txt")
        let handle = try await register(h, .removeAppWorkDirectory(path: path))
        #expect((try await h.transaction.perform(handle)).completed == matching)
        let state = await h.fake.snapshot()
        #expect((state.files[path + "/source.txt"] == nil) == matching)
        await h.kernel.finish(h.transaction)
    }

    @Test func receiptCancellationDuringSnapshotCannotSealANewHandle() async throws {
        let h = try await harness(), gate = BackendAppsRecoveryGate()
        let path = h.transaction.scope.appDirectory + "/state.json"
        await h.fake.putFile(Data("td-test-before".utf8), path: path)
        await h.fake.pauseNextFileRead(gate)
        let registration = NativeCompositionCallContext.$rpc.withValue(h.context) {
            Task { try await h.transaction.register(.restoreAppFile(path: path)) }
        }
        await gate.waitUntilEntered()
        await h.fake.revokeReceipt(h.context)
        await gate.release()
        do { _ = try await registration.value; Issue.record("A cancelled capture sealed a fresh recovery plan") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect(await h.transaction.registered(.restoreAppFile(path: path)) == nil)
        #expect(!(await h.fake.snapshot()).audits.contains { $0.event == "sealed" })
        await h.kernel.finish(h.transaction)
    }

    @Test func mandatoryBeforeAuditFailurePreventsEveryRemoteEffect() async throws {
        let h = try await harness()
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        await h.fake.failAudit("started")
        let baseline = await h.fake.snapshot()
        do { _ = try await h.transaction.perform(handle); Issue.record("A failed before-audit permitted recovery") }
        catch let error as NativeRPCError { #expect(error.code == "state-failed" || error.code == "access-denied") }
        let state = await h.fake.snapshot()
        #expect(state.rawCommands.count == baseline.rawCommands.count && state.dockerCalls.count == baseline.dockerCalls.count)
        #expect(state.locks[path] == h.transaction.scope.ownerToken)
        await h.kernel.finish(h.transaction)
    }

    @Test func mandatoryAfterAuditFailureNeverClaimsCompletedRecovery() async throws {
        let h = try await harness()
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        await h.fake.failAudit("finished")
        let outcome = try await h.transaction.perform(handle)
        #expect(!outcome.completed && outcome.reason != nil)
        #expect((await h.fake.snapshot()).locks[path] == nil)
        await h.kernel.finish(h.transaction)
    }

    @Test func failedIssueAuditClosesUnissuedTransport() async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller()
        await fake.approve(context); await fake.failAudit("issued")
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime()
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
            }
            Issue.record("An unaudited transaction was issued")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        let state = await fake.snapshot()
        #expect(state.opened == 1 && state.closed == 1 && state.rawCommands.isEmpty)
        await kernel.shutdown()
        #expect((await fake.snapshot()).closed == 1)
    }

    @Test(arguments: [0.0, 3901.0, Double.infinity])
    func invalidLifetimeCannotCaptureTransport(seconds: Double) async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller()
        await fake.approve(context)
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime()
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app", lifetimeSeconds: seconds)
            }
            Issue.record("An unbounded recovery lifetime was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await fake.snapshot()).opened == 0)
    }

    @Test func monotonicExpiryAndShutdownRevokeHandlesAndCloseLeases() async throws {
        let h = try await harness(lifetime: 2)
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        let baseline = await h.fake.snapshot()
        h.clock.advance(3)
        do { _ = try await h.transaction.perform(handle); Issue.record("An expired sealed handle remained usable") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        #expect((await h.fake.snapshot()).rawCommands.count == baseline.rawCommands.count)
        await h.kernel.shutdown()
        await h.kernel.finish(h.transaction)
        #expect((await h.fake.snapshot()).closed == 1)
        do { _ = try await h.transaction.perform(handle); Issue.record("Shutdown did not revoke a handle") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
    }

    @Test func capturedContainerRunningAndNetworkStateRecoverWithoutAnyVolumeMutation() async throws {
        let h = try await harness()
        let id = String(repeating: "a", count: 64)
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        await h.fake.putContainer(id: id, app: "td-test-app", transaction: "td-test-prior", running: true, connected: true)
        let handle = try await register(h, .restoreContainer(id: id))
        await h.fake.changeContainer(id, running: false, connected: false)
        await h.fake.revokeReceipt(h.context)
        #expect(try await h.transaction.perform(handle).completed)
        let state = await h.fake.snapshot()
        #expect(state.running[id] == true && state.connected[id] == true)
        #expect(state.volumes == ["td-test-original-volume", "td-test-recovery-volume"])
        #expect(state.deleted.isEmpty && state.dockerCalls.allSatisfy { !$0.path.hasPrefix("/volumes") })
        await h.kernel.finish(h.transaction)
    }

    @Test func expiryDuringBeforeAuditStopsTheFirstPrivateRequest() async throws {
        let h = try await harness(lifetime: 2)
        let path = h.transaction.scope.appDirectory + "/.lock"
        let handle = try await register(h, .releaseOwnedLock(path: path, ownerToken: h.transaction.scope.ownerToken))
        await h.fake.putLock(path, owner: h.transaction.scope.ownerToken)
        await h.fake.advanceClockOnStart(h.clock)
        let baseline = await h.fake.snapshot()
        let outcome = try await h.transaction.perform(handle)
        #expect(!outcome.completed)
        #expect((await h.fake.snapshot()).rawCommands.count == baseline.rawCommands.count)
        await h.kernel.finish(h.transaction)
    }

    @Test func nestedTransactionRejectsNilForeignControllerTargetAndCaddyNamespace() async throws {
        let h = try await harness()
        let other = h.fake.kernel(clock: h.clock)
        let attempts: [(BackendAppsRuntime, String, String)] = [
            (h.fake.runtime(), "td-test-server", "td-test-app"),
            (h.fake.runtime(recovery: h.kernel), "td-test-server", "td-test-other-app"),
            (h.fake.runtime(recovery: other), "td-test-server", "td-test-app"),
            (h.fake.runtime(recovery: h.kernel, caddyServerKey: "td-test-other-route-set"), "td-test-server", "td-test-app")
        ]
        for (runtime, server, app) in attempts {
            do {
                _ = try await NativeCompositionCallContext.$rpc.withValue(h.context) {
                    try await BackendAppsRecoveryContext.$current.withValue(h.transaction) {
                        try await runtime.withRecoveryTransaction(serverID: server, appID: app) { await h.fake.noteBody(); return true }
                    }
                }
                Issue.record("A nested body borrowed a mismatched recovery authority")
            } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        #expect((await h.fake.snapshot()).bodyCalls == 0)
        await h.kernel.finish(h.transaction)
        await other.shutdown()
    }

    @Test(arguments: [true, false])
    func approvedBindHasSeparateScopesAndRecoversNamedFilesInBothSortedOrders(databaseFirst: Bool) async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller()
        let database = databaseFirst ? "td-test-a-database" : "td-test-z-database"
        let target = databaseFirst ? "td-test-z-target" : "td-test-a-target"
        await fake.approve(context, allowedApps: [database, target])
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime(recovery: kernel), store = BackendAppsStore(runtime: runtime)
        let databasePath = try store.directory(database) + "/.env"
        let targetPath = try store.directory(target) + "/.env"
        let statePath = try store.directory(target) + "/state.json"
        let databaseBefore = Data("DB=td-test-database-before\n".utf8), targetBefore = Data("DATABASE_URL=td-test-target-before\n".utf8)
        let stateBefore = try BackendAppsValidation.object([("id", .string(target)), ("name", .string(target)), ("kind", .string("app")), ("status", .string("stopped"))]).encodedJSON()
        await fake.putFile(databaseBefore, path: databasePath); await fake.putFile(targetBefore, path: targetPath); await fake.putFile(stateBefore, path: statePath)
        let names = [database, target].sorted()
        do {
            let _: Bool = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await store.withLock("td-test-server", names[0]) {
                    try await store.withLock("td-test-server", names[1]) {
                        let dbScope = try #require(BackendAppsRecoveryContext.transaction(serverID: "td-test-server", appID: database))
                        let targetScope = try #require(BackendAppsRecoveryContext.transaction(serverID: "td-test-server", appID: target))
                        #expect(dbScope.scope.transactionID != targetScope.scope.transactionID)
                        #expect(dbScope.scope.ownerToken != targetScope.scope.ownerToken)
                        #expect(dbScope.scope.requestID == context.requestID && targetScope.scope.requestID == context.requestID)
                        #expect(BackendAppsRecoveryContext.active.count == 2)
                        // Target can be the OUTER app while the database is current.
                        try await store.writeFile("td-test-server", path: targetPath, contents: Data("DATABASE_URL=changed\n".utf8))
                        try await store.writeFile("td-test-server", path: statePath, contents: Data("{\"changed\":true}".utf8))
                        try await store.writeFile("td-test-server", path: databasePath, contents: Data("DB=changed\n".utf8))
                        await fake.revokeReceipt(context)
                        #expect(try await store.recoverFile("td-test-server", path: targetPath))
                        #expect(try await store.recoverFile("td-test-server", path: statePath))
                        #expect(try await store.recoverFile("td-test-server", path: databasePath))
                        throw CancellationError()
                    }
                }
            }
            Issue.record("A cancelled binding claimed ordinary success")
        } catch is CancellationError { }
        let snapshot = await fake.snapshot()
        #expect(snapshot.files[targetPath] == targetBefore && snapshot.files[statePath] == stateBefore)
        #expect(snapshot.files[databasePath] == databaseBefore)
        #expect(snapshot.locks.isEmpty && snapshot.opened == 2 && snapshot.closed == 2)
        #expect(Set(snapshot.audits.map(\.appID)) == [database, target])
        await kernel.shutdown()
    }

    @Test func bindCannotEnrollThirdAppOrSecondAppFromAnotherAcceptedRequest() async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller(), otherContext = caller()
        await fake.approve(context, allowedApps: ["td-test-app", "td-test-target"])
        await fake.approve(otherContext, allowedApps: ["td-test-app", "td-test-target"])
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime(recovery: kernel)
        try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await runtime.withRecoveryTransaction(serverID: "td-test-server", appID: "td-test-app") {
                do {
                    _ = try await NativeCompositionCallContext.$rpc.withValue(otherContext) {
                        try await runtime.withRecoveryTransaction(serverID: "td-test-server", appID: "td-test-target") { await fake.noteBody(); return true }
                    }
                    Issue.record("A different accepted request was merged into this bind")
                } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
                try await runtime.withRecoveryTransaction(serverID: "td-test-server", appID: "td-test-target") {
                    do {
                        _ = try await runtime.withRecoveryTransaction(serverID: "td-test-server", appID: "td-test-third") { await fake.noteBody(); return true }
                        Issue.record("A bind added a third app")
                    } catch let error as NativeRPCError { #expect(error.code == "access-denied") }
                }
            }
        }
        let snapshot = await fake.snapshot()
        #expect(snapshot.bodyCalls == 0 && snapshot.opened == 2 && snapshot.closed == 2)
        await kernel.shutdown()
    }

    @Test func anotherAppsRouteInAnotherHTTPServerPreservesCandidate() async throws {
        let h = try await harness()
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        try await seedStoppedState(h)
        let id = String(repeating: "b", count: 64)
        await h.fake.putContainer(id: id, app: "td-test-app", transaction: h.transaction.scope.ownerToken, running: true, connected: true)
        await h.fake.serveThirdPartyRoute(ip: "172.25.0.12")
        let handle = try await register(h, .removeCreatedContainers)
        #expect(!(try await h.transaction.perform(handle)).completed)
        let state = await h.fake.snapshot()
        #expect(state.containerIDs == [id] && state.deleted.isEmpty)
        #expect(state.caddyCalls.contains { $0.path == "/config/apps/http/servers" })
        await h.kernel.finish(h.transaction)
    }

    @Test(arguments: ["restart-failed", "unhealthy-original"])
    func runningDatabaseCandidateSurvivesFailedOrUnhealthyOriginalRecovery(mode: String) async throws {
        let h = try await harness(), original = String(repeating: "a", count: 64), candidate = String(repeating: "b", count: 64)
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let state = stoppedState().setting("kind", .string("postgres")).setting("containerId", .string(original)).setting("status", .string("failed"))
        await h.fake.putFile(try state.encodedJSON(), path: h.transaction.scope.appDirectory + "/state.json")
        await h.fake.putContainer(id: original, app: "td-test-app", transaction: "td-test-original", running: true, connected: true)
        let restoration = try await register(h, .restoreContainer(id: original))
        let cleanup = try await register(h, .removeCreatedContainers)
        await h.fake.changeContainer(original, running: false, connected: false)
        await h.fake.putContainer(id: candidate, app: "td-test-app", transaction: h.transaction.scope.ownerToken, running: true, connected: true)
        if mode == "restart-failed" { await h.fake.failStart(original) }
        else { await h.fake.setHealth(original, "unhealthy") }
        await h.fake.revokeReceipt(h.context)
        let recovered = try await h.transaction.perform(restoration)
        #expect(recovered.completed == (mode == "unhealthy-original"))
        #expect(!(try await h.transaction.perform(cleanup)).completed)
        let snapshot = await h.fake.snapshot()
        #expect(snapshot.running[candidate] == true && snapshot.connected[candidate] == true)
        #expect(snapshot.deleted.isEmpty && snapshot.volumes == ["td-test-original-volume", "td-test-recovery-volume"])
        await h.kernel.finish(h.transaction)
    }

    @Test func databaseCandidateCannotCaptureItselfAsRecoveredOriginal() async throws {
        let h = try await harness(), id = String(repeating: "b", count: 64)
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let state = stoppedState().setting("kind", .string("postgres")).setting("status", .string("failed"))
        await h.fake.putFile(try state.encodedJSON(), path: h.transaction.scope.appDirectory + "/state.json")
        await h.fake.putContainer(id: id, app: "td-test-app", transaction: h.transaction.scope.ownerToken, running: true, connected: true)
        do { _ = try await register(h, .restoreContainer(id: id)); Issue.record("A restore candidate became its own original-recovery proof") }
        catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        let cleanup = try await register(h, .removeCreatedContainers)
        #expect(!(try await h.transaction.perform(cleanup)).completed)
        #expect((await h.fake.snapshot()).containerIDs == [id])
        await h.kernel.finish(h.transaction)
    }

    @Test func disconnectedOriginalWithEmptyCapturedAliasesCannotAuthorizeDatabaseCandidateDeletion() async throws {
        let h = try await harness(), original = String(repeating: "a", count: 64), candidate = String(repeating: "b", count: 64)
        await h.fake.putLock(h.transaction.scope.appDirectory + "/.lock", owner: h.transaction.scope.ownerToken)
        let state = stoppedState().setting("kind", .string("postgres")).setting("status", .string("failed"))
        await h.fake.putFile(try state.encodedJSON(), path: h.transaction.scope.appDirectory + "/state.json")
        await h.fake.putContainer(id: original, app: "td-test-app", transaction: "td-test-prior", running: true, connected: true)
        await h.fake.setAliases(original, [])
        let restore = try await register(h, .restoreContainer(id: original))
        let cleanup = try await register(h, .removeCreatedContainers)
        await h.fake.changeContainer(original, running: false, connected: false)
        #expect(try await h.transaction.perform(restore).completed)
        await h.fake.changeContainer(original, running: true, connected: false)
        await h.fake.putContainer(id: candidate, app: "td-test-app", transaction: h.transaction.scope.ownerToken, running: true, connected: true)
        #expect(!(try await h.transaction.perform(cleanup)).completed)
        let snapshot = await h.fake.snapshot()
        #expect(snapshot.running[candidate] == true && snapshot.deleted.isEmpty)
        await h.kernel.finish(h.transaction)
    }

    @Test func firstBeforeImageSurvivesTwoLocksAndOutsideLockWritesInSameTransaction() async throws {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller()
        await fake.approve(context)
        let kernel = fake.kernel(clock: clock), runtime = fake.runtime(recovery: kernel), store = BackendAppsStore(runtime: runtime)
        let path = try store.directory("td-test-app") + "/.env"
        let absent = try store.directory("td-test-app") + "/data-binding-intent.json"
        let original = Data("VALUE=A\n".utf8)
        await fake.putFile(original, path: path)
        do {
            let _: Bool = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await runtime.withRecoveryTransaction(serverID: "td-test-server", appID: "td-test-app") {
                    try await store.withLock("td-test-server", "td-test-app") {
                        try await store.writeFile("td-test-server", path: path, contents: Data("VALUE=B\n".utf8))
                        try await store.writeFile("td-test-server", path: absent, contents: Data("{\"phase\":\"B\"}".utf8))
                        let writtenB = await fake.snapshot()
                        #expect(writtenB.files[path] == Data("VALUE=B\n".utf8))
                        #expect(writtenB.files[absent] == Data("{\"phase\":\"B\"}".utf8))
                    }
                    // A lock-span cache reset must not recapture B as the baseline.
                    try await store.writeFile("td-test-server", path: path, contents: Data("VALUE=C\n".utf8))
                    try await store.writeFile("td-test-server", path: absent, contents: Data("{\"phase\":\"C\"}".utf8))
                    let writtenC = await fake.snapshot()
                    #expect(writtenC.files[path] == Data("VALUE=C\n".utf8))
                    #expect(writtenC.files[absent] == Data("{\"phase\":\"C\"}".utf8))
                    return try await store.withLock("td-test-server", "td-test-app") {
                        await fake.revokeReceipt(context)
                        #expect(try await store.recoverFile("td-test-server", path: path))
                        #expect(try await store.recoverFile("td-test-server", path: absent))
                        throw CancellationError()
                    }
                }
            }
            Issue.record("A cancelled multi-span transaction returned ordinary success")
        } catch is CancellationError { }
        let state = await fake.snapshot()
        #expect(state.files[path] == original && state.files[absent] == nil)
        #expect(state.rawCommands.filter { $0.contains("cat --") && $0.contains(BackendAppsRuntime.quote(path)) }.count == 1)
        #expect(state.locks.isEmpty && state.opened == 1 && state.closed == 1)
        await kernel.shutdown()
    }

    @Test func bindingSnapshotBasenamesAreExactAndBadLookalikesNeverReachTransport() async throws {
        let h = try await harness()
        let directory = h.transaction.scope.appDirectory
        let nonce = "11111111-2222-4333-8444-555555555555"
        let valid = [
            directory + "/data-binding-intent.json",
            directory + "/.data-binding-" + nonce + ".env",
            directory + "/.data-binding-" + nonce + ".state.json"
        ]
        for path in valid {
            _ = try await register(h, .restoreAppFile(path: path))
            #expect(await h.transaction.registered(.restoreAppFile(path: path)) != nil)
        }
        let beforeInvalid = await h.fake.snapshot()
        #expect(beforeInvalid.files.isEmpty)
        let invalid = [
            directory + "/.data-binding-not-a-uuid.env",
            directory + "/.data-binding-" + nonce + "x.env",
            directory + "/.data-binding-" + nonce + ".env.extra",
            directory + "/.data-binding-" + nonce + ".state.json.extra",
            directory + "/.data-binding-" + nonce + "/.env",
            directory + "/.data-binding-" + nonce + "/snapshot.state.json",
            directory + "/data-binding-" + nonce + ".env",
            directory + "/.data-binding-" + nonce + ".state",
            directory + "/../.data-binding-" + nonce + ".env",
            h.transaction.scope.stateRoot + "/td-test-other-app/.data-binding-" + nonce + ".env"
        ]
        for path in invalid {
            do { _ = try await register(h, .restoreAppFile(path: path)); Issue.record("A lookalike or path-segment binding snapshot was admitted") }
            catch let error as NativeRPCError { #expect(error.code == "access-denied") }
        }
        let afterInvalid = await h.fake.snapshot()
        #expect(afterInvalid.rawCommands.count == beforeInvalid.rawCommands.count)
        #expect(afterInvalid.dockerCalls.isEmpty && afterInvalid.caddyCalls.isEmpty && afterInvalid.files.isEmpty)
        await h.kernel.finish(h.transaction)
    }

    @Test(arguments: ["verified", "env-unverified", "state-unverified"])
    func absentBindingNotesAreCleanedOnlyAfterEnvAndStateRecoveryAreVerified(mode: String) async throws {
        let h = try await harness()
        let directory = h.transaction.scope.appDirectory
        let env = directory + "/.env", state = directory + "/state.json"
        let nonce = "11111111-2222-4333-8444-555555555555"
        let notes = [directory + "/data-binding-intent.json", directory + "/.data-binding-" + nonce + ".env", directory + "/.data-binding-" + nonce + ".state.json"]
        let envBefore = Data("DATABASE_URL=td-test-before\n".utf8)
        let stateBefore = try stoppedState().encodedJSON()
        let pending = Data("td-test-protected-binding-note".utf8)
        await h.fake.putLock(directory + "/.lock", owner: h.transaction.scope.ownerToken)
        await h.fake.putFile(envBefore, path: env); await h.fake.putFile(stateBefore, path: state)
        let envHandle = try await register(h, .restoreAppFile(path: env))
        let stateHandle = try await register(h, .restoreAppFile(path: state))
        var cleanup: [BackendAppsRecoveryHandle] = []
        for path in notes { cleanup.append(try await register(h, .restoreAppFile(path: path))) }
        await h.fake.putFile(Data("DATABASE_URL=changed\n".utf8), path: env)
        await h.fake.putFile(Data("{\"pending\":true}".utf8), path: state)
        for path in notes { await h.fake.putFile(pending, path: path) }
        if mode == "env-unverified" { await h.fake.failDigest(env) }
        if mode == "state-unverified" { await h.fake.failDigest(state) }
        await h.fake.revokeReceipt(h.context)
        let envOutcome = try await h.transaction.perform(envHandle)
        let stateOutcome = try await h.transaction.perform(stateHandle)
        if envOutcome.completed && stateOutcome.completed {
            for handle in cleanup { #expect(try await h.transaction.perform(handle).completed) }
        }
        let snapshot = await h.fake.snapshot()
        #expect(snapshot.files[env] == envBefore && snapshot.files[state] == stateBefore)
        if mode == "verified" {
            #expect(envOutcome.completed && stateOutcome.completed)
            #expect(notes.allSatisfy { snapshot.files[$0] == nil })
            let lastVerification = try #require(snapshot.rawCommands.lastIndex { $0.contains("sha256sum") && ($0.contains(BackendAppsRuntime.quote(env)) || $0.contains(BackendAppsRuntime.quote(state))) })
            let firstCleanup = try #require(snapshot.rawCommands.firstIndex { command in command.contains("rm -f --") && notes.contains { command.contains(BackendAppsRuntime.quote($0)) } })
            #expect(firstCleanup > lastVerification)
        } else {
            #expect(!envOutcome.completed || !stateOutcome.completed)
            #expect(notes.allSatisfy { snapshot.files[$0] == pending })
            #expect(!snapshot.rawCommands.contains { command in command.contains("rm -f --") && notes.contains { command.contains(BackendAppsRuntime.quote($0)) } })
        }
        await h.kernel.finish(h.transaction)
    }

    private struct Harness: Sendable {
        let fake: BackendAppsRecoveryFixture, clock: BackendAppsRecoveryClock, kernel: BackendAppsRecovery
        let runtime: BackendAppsRuntime, context: NativeRPCContext, transaction: BackendAppsRecoveryTransaction
    }
    private func caller() -> NativeRPCContext { .init(caller: .page, ownerID: "td-test-owner", capabilities: ["apps.write"]) }
    private func harness(lifetime: Double = 3900) async throws -> Harness {
        let fake = BackendAppsRecoveryFixture(), clock = BackendAppsRecoveryClock(), context = caller()
        await fake.approve(context)
        let runtime = fake.runtime(), kernel = fake.kernel(clock: clock)
        let transaction = try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app", lifetimeSeconds: lifetime)
        }
        return Harness(fake: fake, clock: clock, kernel: kernel, runtime: runtime, context: context, transaction: transaction)
    }
    private func register(_ h: Harness, _ operation: BackendAppsRecoveryOperation) async throws -> BackendAppsRecoveryHandle {
        try await NativeCompositionCallContext.$rpc.withValue(h.context) { try await h.transaction.register(operation) }
    }
    private func stoppedState() -> NativeRPCValue {
        BackendAppsValidation.object([("id", .string("td-test-app")), ("name", .string("td-test-app")), ("kind", .string("app")), ("status", .string("stopped")), ("activeDeploymentId", .null), ("deployments", .array([]))])
    }
    private func seedStoppedState(_ h: Harness) async throws {
        await h.fake.putFile(try stoppedState().encodedJSON(), path: h.transaction.scope.appDirectory + "/state.json")
    }
}

private final class BackendAppsRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

/// This fake enforces a receipt registry for ordinary I/O, but a pinned private
/// transport uses only its captured generation and finite kernel authority.
private actor BackendAppsRecoveryFixture {
    struct DockerCall: Sendable { let method: String, path: String }
    struct Snapshot: Sendable {
        let opened: Int, closed: Int, bodyCalls: Int
        let files: [String: Data], locks: [String: String], containerIDs: [String], deleted: [String]
        let running: [String: Bool], connected: [String: Bool], volumes: Set<String>
        let rawCommands: [String], dockerCalls: [DockerCall], caddyCalls: [DockerCall], audits: [BackendAppsRecoveryAudit]
    }
    private struct Container: Sendable {
        let app: String, transaction: String
        var running: Bool, connected: Bool, health: String
        var aliases: [String]
    }
    private struct Receipt: Sendable { let owner: String; let caller: NativeRPCContext.Caller; let writeAccepted: Bool; let allowedApps: Set<String> }
    private var receipts: [UUID: Receipt] = [:]
    private var leases: [UUID: Int] = [:]
    private var generation = 1, opened = 0, closed = 0, bodyCalls = 0
    private var files: [String: Data] = [:], locks: [String: String] = [:]
    private var containers: [String: Container] = [:], deleted: [String] = []
    private var rawCommands: [String] = [], dockerCalls: [DockerCall] = [], caddyCalls: [DockerCall] = [], audits: [BackendAppsRecoveryAudit] = []
    private var auditFailure: String?, startClock: BackendAppsRecoveryClock?, readGate: BackendAppsRecoveryGate?
    private var ignoreFilters = false
    private var routeIP: String?
    private var thirdPartyRoute = false
    private var failedStarts: Set<String> = []
    private var failedDigests: Set<String> = []
    private let volumes: Set<String> = ["td-test-original-volume", "td-test-recovery-volume"]
    func approve(_ context: NativeRPCContext, allowedApps: Set<String> = ["td-test-app"]) { receipts[context.requestID] = Receipt(owner: context.ownerID, caller: context.caller, writeAccepted: context.capabilities.contains("apps.write"), allowedApps: allowedApps) }
    func revokeReceipt(_ context: NativeRPCContext) { receipts[context.requestID] = nil }
    func replaceServerGeneration() { generation += 1 }
    func putFile(_ data: Data, path: String) { files[path] = data }
    func putLock(_ path: String, owner: String) { locks[path] = owner }
    func putContainer(id: String, app: String, transaction: String, running: Bool = false, connected: Bool = false) {
        containers[id] = Container(app: app, transaction: transaction, running: running, connected: connected, health: "healthy", aliases: ["td-test-database"])
    }
    func changeContainer(_ id: String, running: Bool, connected: Bool) { containers[id]?.running = running; containers[id]?.connected = connected }
    func ignoreEngineFilters() { ignoreFilters = true }
    func failAudit(_ event: String) { auditFailure = event }
    func advanceClockOnStart(_ clock: BackendAppsRecoveryClock) { startClock = clock }
    func pauseNextFileRead(_ gate: BackendAppsRecoveryGate) { readGate = gate }
    func serveRoute(ip: String) { routeIP = ip }
    func serveThirdPartyRoute(ip: String) { routeIP = ip; thirdPartyRoute = true }
    func failStart(_ id: String) { failedStarts.insert(id) }
    func setHealth(_ id: String, _ health: String) { containers[id]?.health = health }
    func setAliases(_ id: String, _ aliases: [String]) { containers[id]?.aliases = aliases }
    func failDigest(_ path: String) { failedDigests.insert(path) }
    func noteBody() { bodyCalls += 1 }
    func snapshot() -> Snapshot {
        Snapshot(opened: opened, closed: closed, bodyCalls: bodyCalls, files: files, locks: locks, containerIDs: containers.keys.sorted(), deleted: deleted,
                 running: containers.mapValues(\.running), connected: containers.mapValues(\.connected), volumes: volumes,
                 rawCommands: rawCommands, dockerCalls: dockerCalls, caddyCalls: caddyCalls, audits: audits)
    }
    nonisolated func runtime(recovery: BackendAppsRecovery? = nil, caddyServerKey: String? = nil) -> BackendAppsRuntime {
        .init(execute: { [self] server, command, input, _, maximum in
            let current = BackendAppsRecoveryContext.current, active = BackendAppsRecoveryContext.active
            return try await ordinaryExecute(server, command, input, maximum, NativeCompositionCallContext.rpc, active: active, current: current)
        }, privateNetwork: "td-test-apps", resourcePrefix: "td-test", caddyServerKey: caddyServerKey, stateRoot: "/var/lib/td-test-apps", recovery: recovery)
    }
    nonisolated func kernel(clock: BackendAppsRecoveryClock) -> BackendAppsRecovery {
        BackendAppsRecovery(capture: { [self] scope, context in try await capture(scope, context) },
                            audit: { [self] event in try await audit(event) }, monotonic: { clock.now() })
    }
    private func ordinary(_ context: NativeRPCContext?) throws {
        guard let context, let receipt = receipts[context.requestID], receipt.owner == context.ownerID, receipt.caller == context.caller,
              receipt.writeAccepted, context.capabilities.contains("apps.write") else {
            throw NativeRPCError(code: "access-denied", message: "The original write receipt is no longer live.")
        }
    }
    private func authorize(_ context: NativeRPCContext?, scope: BackendAppsRecoveryScope) throws {
        try ordinary(context)
        guard let context, scope.ownerID == context.ownerID, scope.requestID == context.requestID,
              scope.serverID == "td-test-server", receipts[context.requestID]?.allowedApps.contains(scope.appID) == true,
              scope.resourcePrefix == "td-test", scope.stateRoot == "/var/lib/td-test-apps" else {
            throw NativeRPCError(code: "access-denied", message: "The receipt does not authorize this target.")
        }
    }
    private func capture(_ scope: BackendAppsRecoveryScope, _ context: NativeRPCContext?) throws -> BackendAppsRecoveryTransport {
        try authorize(context, scope: scope)
        leases[scope.transactionID] = generation; opened += 1
        return .init(execute: { [self] server, command, input, _, maximum in try await execute(server, command, input, maximum, scope) },
                     docker: { [self] server, method, path, body in try await docker(server, method, path, body, scope) },
                     caddy: { [self] server, method, path, _ in try await caddy(server, method, path, scope) },
                     authorizeRegistration: { [self] context in try await authorize(context, scope: scope) },
                     validateBinding: { [self] in try await pinned(scope.serverID, scope) },
                     close: { [self] in await close(scope.transactionID) })
    }
    private func close(_ transaction: UUID) { if leases.removeValue(forKey: transaction) != nil { closed += 1 } }
    private func pinned(_ server: String, _ scope: BackendAppsRecoveryScope) throws {
        guard server == scope.serverID, leases[scope.transactionID] == generation else {
            throw NativeRPCError(code: "access-denied", message: "The captured server generation is no longer available.")
        }
    }
    private func audit(_ event: BackendAppsRecoveryAudit) throws {
        audits.append(event)
        if event.event == "started" { startClock?.advance(4000) }
        if auditFailure == event.event { throw NativeRPCError(code: "state-failed", message: "The mandatory audit is unavailable.") }
    }
    private func ordinaryExecute(_ server: String, _ command: String, _ input: Data?, _ maximum: Int, _ context: NativeRPCContext?,
                                 active: [BackendAppsRecoveryTransaction], current: BackendAppsRecoveryTransaction?) async throws -> BackendServersRunResult {
        try ordinary(context)
        let scopes = active.isEmpty ? current.map { [$0] } ?? [] : active
        let selected = scopes.first { command.contains($0.scope.appDirectory) } ?? current
        guard let selected else { return .init(code: 0, stdout: "") }
        return try await execute(server, command, input, maximum, selected.scope)
    }
    private func execute(_ server: String, _ command: String, _ input: Data?, _ maximum: Int, _ scope: BackendAppsRecoveryScope) async throws -> BackendServersRunResult {
        try pinned(server, scope)
        let outer = Self.words(command)
        let script = outer.count == 3 && outer[0] == "sh" && outer[1] == "-c" ? outer[2] : command
        let tokens = Self.words(script)
        rawCommands.append(script)
        if script.contains("/.lock"), script.contains("/owner") {
            let path = script.contains(scope.caddyLockPath) ? scope.caddyLockPath : scope.appDirectory + "/.lock"
            if let input, script.contains("mkdir --") {
                guard locks[path] == nil else { return .init(code: 73, stdout: "") }
                locks[path] = String(decoding: input, as: UTF8.self)
                return .init(code: 0, stdout: "")
            }
            let matched = locks[path] == scope.ownerToken
            if matched && script.contains("rmdir --") { locks[path] = nil }
            return .init(code: matched ? 0 : 1, stdout: "")
        }
        if let at = tokens.firstIndex(of: "sha256sum"), let path = Self.argument(tokens, after: at), let data = files[path] {
            if failedDigests.contains(path) { return .init(code: 0, stdout: String(repeating: "0", count: 64) + "\n") }
            return .init(code: 0, stdout: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\n")
        }
        if script.contains("rm -rf --"), let at = tokens.firstIndex(of: "rm"), let path = Self.argument(tokens, after: at) {
            let owner = files[path + "/.recovery-owner"].map { String(decoding: $0, as: UTF8.self) }
            // Model POSIX fail-fast semantics: without the barrier, a failed test
            // followed by '; rm' still deletes. This catches the actual script bug.
            if owner != scope.ownerToken, script.contains("set -e") { return .init(code: 1, stdout: "") }
            for key in files.keys.filter({ $0 == path || $0.hasPrefix(path + "/") }) { files[key] = nil }
            return .init(code: 0, stdout: "")
        }
        if let input, let line = script.components(separatedBy: CharacterSet(charactersIn: ";\n")).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("mv -f -- ") }),
           let path = Self.words(line).last {
            files[path] = input
            return .init(code: 0, stdout: "")
        }
        if script.contains("rm -f --"), let at = tokens.lastIndex(of: "rm"), let path = Self.argument(tokens, after: at) {
            files[path] = nil
            return .init(code: 0, stdout: "")
        }
        if let at = tokens.lastIndex(of: "cat"), let path = Self.argument(tokens, after: at) {
            if let gate = readGate { readGate = nil; await gate.pause() }
            guard let data = files[path] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data.prefix(maximum), as: UTF8.self), truncated: data.count > maximum)
        }
        throw NativeRPCError(code: "unavailable", message: "The recovery fake received an unknown bounded command.")
    }
    private func docker(_ server: String, _ method: String, _ path: String, _ body: Data?, _ scope: BackendAppsRecoveryScope) throws -> BackendAppsHTTPResponse {
        try pinned(server, scope); dockerCalls.append(.init(method: method, path: path))
        if method == "GET", path.hasPrefix("/containers/json?") {
            let rows = containers.keys.sorted().compactMap { id -> NativeRPCValue? in
                let value = containers[id]!
                if !ignoreFilters && (value.app != scope.appID || value.transaction != scope.ownerToken) { return nil }
                return BackendAppsValidation.object([("Id", .string(id)), ("Labels", labels(value))])
            }
            return .init(status: 200, body: try NativeRPCValue.array(rows).encodedJSON())
        }
        if path.hasPrefix("/networks/"), let body {
            let value = try NativeRPCValue.parseJSON(body), id = try value["Container"].requireString("container")
            if path.hasSuffix("/disconnect") { containers[id]?.connected = false }
            if path.hasSuffix("/connect") { containers[id]?.connected = true; containers[id]?.aliases = (value["EndpointConfig"]["Aliases"].elements ?? []).compactMap(\.string) }
            return .init(status: 200)
        }
        let component = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        let id = component.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard let value = containers[id] else { return .init(status: 404) }
        if method == "DELETE" { containers[id] = nil; deleted.append(id); return .init(status: 204) }
        if method == "POST" {
            if path.hasSuffix("/start"), failedStarts.contains(id) { return .init(status: 500) }
            if path.hasSuffix("/start") { containers[id]?.running = true }
            if path.contains("/stop?") { containers[id]?.running = false }
            return .init(status: 204)
        }
        let ip = id.hasPrefix("a") ? "172.25.0.11" : "172.25.0.12"
        let networks = value.connected ? BackendAppsValidation.object([(scope.privateNetwork, BackendAppsValidation.object([("Aliases", .array(value.aliases.map(NativeRPCValue.string))), ("IPAddress", .string(ip))]))]) : .object([])
        let inspected = BackendAppsValidation.object([("Id", .string(id)), ("Config", BackendAppsValidation.object([("Labels", labels(value))])), ("State", BackendAppsValidation.object([("Running", .bool(value.running)), ("Health", BackendAppsValidation.object([("Status", .string(value.health))]))])), ("NetworkSettings", BackendAppsValidation.object([("Networks", networks)]))])
        return .init(status: 200, body: try inspected.encodedJSON())
    }
    private func labels(_ container: Container) -> NativeRPCValue {
        BackendAppsValidation.object([("io.terminaldeck.app", .string(container.app)), ("io.terminaldeck.managed", .string("true")), ("io.terminaldeck.transaction", .string(container.transaction))])
    }
    private func caddy(_ server: String, _ method: String, _ path: String, _ scope: BackendAppsRecoveryScope) throws -> BackendAppsHTTPResponse {
        try pinned(server, scope); caddyCalls.append(.init(method: method, path: path))
        guard method == "GET", path == "/id/" + scope.caddyRouteID || path == "/config/apps/http/servers" else { throw NativeRPCError(code: "unavailable", message: "The fake received an unknown route operation.") }
        let rows: [NativeRPCValue]
        if let routeIP {
            rows = [BackendAppsValidation.object([("@id", .string(thirdPartyRoute ? "td-test-third-party-route" : scope.caddyRouteID)), ("handle", .array([BackendAppsValidation.object([("handler", .string("reverse_proxy")), ("upstreams", .array([BackendAppsValidation.object([("dial", .string(routeIP + ":3000"))])]))])]))])]
        } else { rows = [] }
        if path == "/config/apps/http/servers" {
            let key = thirdPartyRoute ? "td-test-other-http-server" : scope.caddyServerKey ?? "terminaldeck"
            return .init(status: 200, body: try BackendAppsValidation.object([(key, BackendAppsValidation.object([("routes", .array(rows))]))]).encodedJSON())
        }
        guard !thirdPartyRoute, let own = rows.first else { return .init(status: 404) }
        return .init(status: 200, body: try own.encodedJSON())
    }
    private static func argument(_ tokens: [String], after index: Int) -> String? {
        var next = index + 1
        while next < tokens.count && tokens[next].hasPrefix("-") { next += 1 }
        return next < tokens.count ? tokens[next].trimmingCharacters(in: CharacterSet(charactersIn: ";")) : nil
    }
    private static func words(_ text: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let held = quote {
                if character == held { quote = nil } else { current.append(character) }
                started = true; continue
            }
            if character == "'" || character == "\"" { quote = character; started = true; continue }
            if character.isWhitespace || character == ";" {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        if started { result.append(current) }
        return result
    }
}

private actor BackendAppsRecoveryGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; let waiting = observers; observers.removeAll(); waiting.forEach { $0.resume() }
        await withCheckedContinuation { paused = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { paused?.resume(); paused = nil }
}
