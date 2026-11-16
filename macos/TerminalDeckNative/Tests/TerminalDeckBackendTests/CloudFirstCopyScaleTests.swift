import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac-next 2 (13 Nov): after the update the owner's Mac mini spent over ten minutes at one full core building the
/// first saved copy (~56,500 records), and the Cloud page said "Sending is held up right now". Each exported record
/// looked up parts, versions and journal versions by columns no key covered (each read the whole, growing table:
/// quadratic at his size, negligible at this test's), and the sync core counted and summed its whole queue for every
/// page. Here a first copy of a few thousand records is built within a bound, and while it is built the page says how
/// far it is. The remaining cost is linear (one save step per record): batching it is the follow-up.
@Suite("Cloud — a large first copy", .serialized)
struct CloudFirstCopyScaleTests {
    @Test func aFirstCopyOfThousandsOfRecordsIsBuiltQuicklyAndSaysHowFarItIs() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let count = 3_000
        _ = try await f.store.appendDiary((1...count).map {
            .init(stamp: .hoot, role: .assistant, text: "First copy scale record \($0).", externalID: "scale-\($0)")
        })
        let rows = CloudBrainMemoryFormat.inventoryRows
        let syncRoot = f.base.appendingPathComponent("Data/cloud/" + CloudUpgradeFromShip0220Tests.subjectHash, isDirectory: true)
        let service = CloudUpgradeFixtureService(device: f.deviceId)
        let mine = P256.Signing.PrivateKey()
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: CloudUpgradeFromShip0220Tests.subject, revision: 1, devices: [
            .init(deviceId: f.deviceId, signKey: CloudUpgradeFromShip0220Tests.jwk(mine), keyId: BackendCloudDeviceCode.keyId(CloudUpgradeFromShip0220Tests.jwk(mine))!,
                  name: "this Mac", trust: "trusted", how: "self", trustedAt: 1_000)])))
        let store = try CloudSyncStore(root: syncRoot, subject: CloudUpgradeFromShip0220Tests.subject)
        let trust = BackendCloudTrustStore(subject: CloudUpgradeFromShip0220Tests.subject, slot: slot.port(), pressRefused: { false })
        let engine = try CloudUpgradeFromShip0220Tests.engine(store, service: service, deviceId: f.deviceId, key: mine, trust: trust)
        try await f.store.cloudResumeCapture(stateRoot: f.stateRoot, rows: rows)
        let adapters = try rows.map { try f.adapter($0) }
        for adapter in adapters { try await engine.register(adapter: adapter) }
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1_000_125, watermarks: [:])

        // While it is built, the page reads how far it is (the sync core answers between pages).
        let watcher = Task { () -> [CloudBaselineProgress] in
            var seen: [CloudBaselineProgress] = []
            while !Task.isCancelled {
                if let progress = try? await engine.baselineProgress(), progress.preparing == true { seen.append(progress) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return seen
        }
        let started = Date()
        _ = try await engine.bootstrap(sources: adapters, cut: cut)
        let elapsed = Date().timeIntervalSince(started)
        watcher.cancel()
        let seen = await watcher.value

        // Before the fix this grew with the square of the records; a debug build now needs well under this.
        #expect(elapsed < 150, "first copy of \(count) records took \(elapsed) s")
        #expect(!seen.isEmpty)
        if let last = seen.last {
            #expect(last.total >= count)
            #expect(last.sent <= last.total)
            // Page-names lane: prepared in full (n = m) says what happens next, never "Preparing".
            #expect(BackendCloudOverviewWords.baseline(last).hasPrefix(BackendCloudOverviewWords.preparingNow(last) ? "Preparing the first copy: " : "Sending "))
        }
        #expect(seen.contains { $0.sent > 0 && $0.sent < $0.total })
        // Done preparing: the page no longer says it is preparing.
        #expect(try await engine.baselineProgress()?.preparing != true)
    }

    @Test func thePageSaysPreparingWithGroupedNumbers() {
        let progress = CloudBaselineProgress(total: 7_556, sent: 2_300, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)
        #expect(BackendCloudOverviewWords.baseline(progress) == "Preparing the first copy: 2,300 of 7,556 changes")
        let saving = CloudBaselineProgress(total: 7_556, sent: 2_300, filesWaiting: 0, waitingUntil: nil, reason: nil)
        #expect(BackendCloudOverviewWords.baseline(saving) == "2,300 of 7,556 changes saved")
    }
}
