import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-5 (13 Nov, the joining MacBook): its own first copy was prepared in a second ("56 of 56") and then sat
/// unsent for 13+ minutes while it downloaded ~300 packs: it waited behind the whole download, and the sends the
/// scheduler asked for meanwhile were refused "busy" and dropped. Now its records go up by themselves, with no local
/// change, no restart and no button; and its first copy waits for the download instead of failing "busy".
@Suite("Cloud sync — a joining Mac sends its own records by itself while it catches up", .serialized)
struct CloudSyncJoiningMacTests {
    struct Mac {
        let f: CloudBrainMemoryFixture
        let store: CloudSyncStore
        let engine: CloudSyncEngine
        let adapters: [BackendCloudBrainMemory]
    }
    static func entry(_ device: String, _ key: P256.Signing.PrivateKey, how: String) -> BackendCloudTrustedList.Entry {
        let jwk = CloudUpgradeFromShip0220Tests.jwk(key)
        return .init(deviceId: device, signKey: jwk, keyId: BackendCloudDeviceCode.keyId(jwk)!, name: "a Mac", trust: "trusted", how: how, trustedAt: 1_000)
    }
    static func mac(_ f: CloudBrainMemoryFixture, key: P256.Signing.PrivateKey, others: [(String, P256.Signing.PrivateKey)], service: CloudUpgradeFixtureService) async throws -> Mac {
        let rows = CloudBrainMemoryFormat.inventoryRows
        let syncRoot = f.base.appendingPathComponent("Data/cloud/" + CloudUpgradeFromShip0220Tests.subjectHash, isDirectory: true)
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: CloudUpgradeFromShip0220Tests.subject, revision: 1,
            devices: [entry(f.deviceId, key, how: "self")] + others.map { entry($0.0, $0.1, how: "account") })))
        let store = try CloudSyncStore(root: syncRoot, subject: CloudUpgradeFromShip0220Tests.subject)
        let trust = BackendCloudTrustStore(subject: CloudUpgradeFromShip0220Tests.subject, slot: slot.port(), pressRefused: { false })
        let engine = try CloudUpgradeFromShip0220Tests.engine(store, service: service, deviceId: f.deviceId, key: key, trust: trust)
        try await f.store.cloudResumeCapture(stateRoot: f.stateRoot, rows: rows)
        let adapters = try rows.map { try f.adapter($0) }
        for adapter in adapters { try await engine.register(adapter: adapter) }
        return .init(f: f, store: store, engine: engine, adapters: adapters)
    }
    static func diary(_ f: CloudBrainMemoryFixture, _ count: Int, _ tag: String) async throws {
        _ = try await f.store.appendDiary((1...count).map {
            .init(stamp: .hoot, role: .assistant, text: "\(tag) \($0): " + (0..<6).map { _ in UUID().uuidString }.joined(separator: " "), externalID: "\(tag)-\($0)")
        })
    }

    @Test func aJoiningMacsOwnRecordsGoUpByThemselvesWhileItDownloadsAboutThreeHundredPacks() async throws {
        // The Mac that was first: its memory goes up in about 300 small packs.
        let fa = try CloudBrainMemoryFixture(); try await fa.seed()
        let keyA = P256.Signing.PrivateKey(), keyB = P256.Signing.PrivateKey()
        let service = CloudUpgradeFixtureService(device: fa.deviceId)
        try await Self.diary(fa, 1_500, "first-mac")
        let a = try await Self.mac(fa, key: keyA, others: [], service: service)
        await a.engine.setBrainPackPlainCap(6_000)
        _ = try await a.engine.bootstrap(sources: a.adapters, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1_000_125, watermarks: [:]))
        for _ in 0..<50 where try await a.engine.restoreProgress().queued > 0 { _ = try? await a.engine.flush() }
        let fromA = await service.segmentCount()
        #expect(fromA >= 200, "the joining Mac has about 300 packs to fetch (\(fromA))")

        // The joining Mac: 56 records of its own, the other Mac trusted with the account.
        let fb = try CloudBrainMemoryFixture()
        try await Self.diary(fb, 56, "joining-mac")
        await service.switchDevice(fb.deviceId)
        let b = try await Self.mac(fb, key: keyB, others: [(fa.deviceId, keyA)], service: service)
        await b.engine.startEvents()   // the fixture's event stream ends at once: no "hello", no "changed"
        // As the app does it: the catch-up and the first copy start together; the first copy WAITS for the catch-up.
        async let download: [CloudImportReceipt] = b.engine.pull()
        async let firstCopy: CloudCheckpointReceipt = b.engine.bootstrap(sources: b.adapters, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1_000_200, watermarks: [:]))
        // The catch-up may be refused "busy" (the launch catch-up already runs): the app ignores that (`try?`), the
        // scheduler fetches by itself. The first copy never fails "busy": it waits.
        _ = try? await download
        _ = try await firstCopy
        // Nothing injected from here on: its own records end up in Cloud, and it is level.
        let deadline = Date().addingTimeInterval(120)
        // MAC-NEXT-6: its own records go first and the download continues in slices after them, so "nothing queued"
        // comes before "level": wait for both.
        while Date() < deadline {
            let now = try await b.engine.restoreProgress(), packs = await service.segmentCount()
            if now.queued == 0, now.brainSeq == CloudSequence(UInt64(packs)) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await b.engine.restoreProgress().queued == 0)
        let total = await service.segmentCount()
        #expect(total > fromA, "the joining Mac's own packs are in Cloud")
        let progress = try await b.engine.restoreProgress()
        #expect(progress.brainSeq == CloudSequence(UInt64(total)), "and it applied everything the first Mac sent")
        #expect(try await b.engine.baselineProgress() == nil, "its first copy is settled")
        #expect(try b.store.value("blocked") as Bool? == false)
        await b.engine.stop()
        await fa.close(); await fb.close()
    }
}
