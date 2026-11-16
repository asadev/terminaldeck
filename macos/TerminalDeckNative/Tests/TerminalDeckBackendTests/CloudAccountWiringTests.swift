import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud account wiring — lazy real ports and closed gates")
struct CloudAccountWiringTests {
    @Test func outboxConstructionWaitsForRegistrationAndCoalescesCallers() async throws {
        let factory = Factory(), port = BackendCloudAccountOutboxFactory(make: { try await factory.make() })
        #expect(await factory.calls == 0)
        try await port.setPaused(true)
        #expect(await factory.calls == 0)
        async let one = port.restoreProgress()
        async let two = port.restoreProgress()
        _ = try await (one,two)
        #expect(await factory.calls == 1)
        #expect(await factory.outbox.paused)
        try await port.setPaused(false)
        #expect(!(await factory.outbox.paused))
    }
    @Test func aFailedFactoryCanBeRetriedWithoutAnAutomaticLoop() async throws {
        let factory = Factory(); await factory.failNext()
        let port = BackendCloudAccountOutboxFactory(make: { try await factory.make() })
        await #expect(throws: CloudFailure.unavailable) { _ = try await port.restoreProgress() }
        #expect(await factory.calls == 1)
        _ = try await port.restoreProgress()
        #expect(await factory.calls == 2)
    }
    @Test func signoutClosesToolsEvenWhenProtectedStorageRefusesTheTombstone_S18() async throws {
        let f = try CloudAccountFixture.make(); _ = try await f.signin()
        f.store.failWrites = true
        await #expect(throws: (any Error).self) { try await f.account.signOut() }
        #expect(!(await f.account.state().visible(at: f.clock.now())))
        #expect(await f.transport.stopped)
        #expect(await f.server.logouts == 1)
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).isEmpty)
    }
    @Test func theEngineSignerSignsOnlyForThisMacsCurrentRegistration() async throws {
        let f = try CloudAccountFixture.make(); _ = try await f.signin()
        let registration = try await f.account.identity.deviceRegistration(), payload = Data("fixture pack".utf8)
        let signature = try await f.account.identity.signDevicePayload(payload, deviceId: registration.deviceId)
        let x = try #require(BackendCloudAccountIdentity.unbase64(registration.signPublicJwk.x)), y = try #require(BackendCloudAccountIdentity.unbase64(registration.signPublicJwk.y ?? ""))
        let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: payload))
        await #expect(throws: CloudFailure.unsafeConfiguration) {
            _ = try await f.account.identity.signDevicePayload(payload, deviceId: UUID().uuidString.lowercased())
        }
    }
    @Test func everyNewOutboxMethodReachesTheEngine_S9() async throws {
        let engine = Recorder(), port = BackendCloudAccountOutboxFactory(make: { engine })
        try await port.abandonUnpublishedSetup()
        try await port.retryParked(domains: ["brain/memory/i01"])
        let receipt = try await port.cloudReceipt(operationId: "op-1")
        let identity = try await port.outboxIdentity()
        let ready = try await port.contextReady(projectId: "p", sources: ["memory/I01"])
        #expect(await engine.calls == ["abandon", "retry:brain/memory/i01", "receipt:op-1", "identity", "ready:p:memory/I01"])
        #expect(receipt?.operationId == "op-1")
        #expect(identity == "fixture-queue")
        #expect(ready.projectId == "p")
    }
    @Test func theServiceClockReachesTheEngineOnlyOnceItExists() async throws {
        let engine = Recorder(), port = BackendCloudAccountOutboxFactory(make: { engine })
        #expect(port.serviceTime() == nil)
        _ = try await port.outboxIdentity()
        #expect(port.serviceTime() == 1_700_000_000_000)
    }
    /// Fixture-only engine stand-in that records each forwarded call.
    actor Recorder: CloudOutboxPort {
        var calls: [String] = []
        func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt { throw CloudFailure.unsupportedFormat }
        func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
        func flush() async throws -> [CloudReceipt] { [] }
        func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
        func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
        func register(adapter: any CloudDomainAdapter) async throws {}
        func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
        func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
        func pull() async throws -> [CloudImportReceipt] { [] }
        func setPaused(_ paused: Bool) async throws {}
        func abandonUnpublishedSetup() async throws { calls.append("abandon") }
        func retryParked(domains: Set<String>) async throws { calls.append("retry:" + domains.sorted().joined(separator: ",")) }
        func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt? {
            calls.append("receipt:" + operationId); return .init(operationId: operationId, sequence: CloudSequence(7), committedAt: 1)
        }
        func outboxIdentity() async throws -> String { calls.append("identity"); return "fixture-queue" }
        nonisolated func serviceTime() -> Int64? { 1_700_000_000_000 }
        func contextReady(projectId: String, sources: Set<String>) async throws -> CloudContextReady {
            calls.append("ready:" + projectId + ":" + sources.sorted().joined(separator: ","))
            return .init(projectId: projectId, throughSeq: .zero, sourceCounts: .init(domains: 0, records: 0, files: 0, bytes: 0, blocked: 0), verified: false, missingSources: [])
        }
    }
    @Test func theOutboxFactoryForwardsTheDeviceTrustCallsToTheEngine() async throws {
        let factory = Factory(), port = BackendCloudAccountOutboxFactory(make: { try await factory.make() })
        let id = "10000000-0000-4000-8000-00000000000a"
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "fixture-x", y: "fixture-y")
        await factory.outbox.setHeld([.init(deviceId: id, firstHeldSeq: CloudSequence(2), firstHeldSecretsSeq: nil, packs: 1, operations: 5, byDomain: [], firstSeenAt: 1, counting: false)])
        await factory.outbox.setRefused([.init(sequence: CloudSequence(4), storageClass: .brain, deviceId: nil, reason: CloudPackVerdict.noDevice, firstAt: 1, checks: 1)])
        // Without forwarding these would answer "nothing waits" and refuse the three actions.
        #expect(try await port.heldDevices().count == 1)
        #expect(try await port.refusedPacks().count == 1)
        _ = try await port.trustDevice(deviceId: id, signKey: key)
        #expect(await factory.outbox.trustedKeys[id] == key)
        _ = try await port.releaseHeld(deviceIds: [id])
        #expect(await factory.outbox.released == [[id]])
        _ = try await port.checkRefusedAgain(sequence: nil)
        #expect(await factory.outbox.checkCalls == 1)
        #expect(try await port.refusedPacks().isEmpty)
        // The first save's progress reaches the account too (without forwarding it would always read "done").
        let going = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 3, waitingUntil: 1_794_100_000_000, reason: "Cloud asked this Mac to slow down for a moment.")
        await factory.outbox.setBaseline(going)
        #expect(try await port.baselineProgress() == going)
    }
    @Test func theAccountShowsHowFarThisMacsFirstSaveIs() async throws {
        let f = try CloudAccountFixture.make()
        let going = CloudBaselineProgress(total: 5_000, sent: 1_200, filesWaiting: 0, waitingUntil: nil, reason: nil)
        await f.outbox.setBaseline(going)
        _ = try await f.signin()
        #expect(await f.account.state().baseline == going)
        await f.outbox.setBaseline(nil)
        try await f.account.refresh()
        #expect(await f.account.state().baseline == nil)
    }
    @Test func brainKeysAreSharedAndDiscardedWithoutAKeyFile() async throws {
        let fetcher = Keys(), cache = BackendCloudAccountBrainKeys(fetch: { try await fetcher.fetch($0) })
        async let one = cache.key(epoch: 1)
        async let two = cache.key(epoch: 1)
        let keys = try await (one,two)
        #expect(keys.0 == keys.1)
        #expect(await fetcher.calls == 1)
        await cache.discard()
        _ = try await cache.key(epoch: 1)
        #expect(await fetcher.calls == 2)
    }
    actor Factory {
        let outbox = CloudAccountFixtureOutbox()
        var calls = 0, failing = false
        func failNext() { failing = true }
        func make() async throws -> any CloudOutboxPort { calls += 1; if failing { failing = false; throw CloudFailure.unavailable }; await Task.yield(); return outbox }
    }
    actor Keys {
        var calls = 0
        func fetch(_ epoch: Int) async throws -> Data { calls += 1; await Task.yield(); return Data(repeating: UInt8(epoch), count: 32) }
    }
}
