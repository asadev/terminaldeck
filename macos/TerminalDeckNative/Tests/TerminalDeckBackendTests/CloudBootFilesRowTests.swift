import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 13 Nov leftover (sync fixer): the Cloud page's "Boot files" row could still say "Starting" or "2 boot files wait for
/// a folder" after the files had arrived and been written. The row is the sync core's coverage of the boot files
/// adapter; it now follows what really waits, through a real sync core and a fake service, both Macs.
@Suite("Cloud boot files — the Cloud page row says what is true now", .serialized)
struct CloudBootFilesRowTests {
    typealias U = CloudUpgradeFromShip0220Tests

    @Test func theRowSaysWhatReallyWaitsAndThenLevel() async throws {
        let f = try CloudBootFilesFixture(); defer { f.close() }
        let service = CloudUpgradeFixtureService(device: f.deviceA)
        let keyA = P256.Signing.PrivateKey(), keyB = P256.Signing.PrivateKey()
        func entry(_ id: String, _ key: P256.Signing.PrivateKey, _ how: String) -> BackendCloudTrustedList.Entry {
            .init(deviceId: id, signKey: U.jwk(key), keyId: BackendCloudDeviceCode.keyId(U.jwk(key))!, name: id == f.deviceA ? "A" : "B",
                  trust: "trusted", how: how, trustedAt: 1)
        }
        let slotA = CloudTrustFixtureSlot(), slotB = CloudTrustFixtureSlot()
        slotA.put(try CloudWire.canonical(BackendCloudTrustedList(subject: U.subject, revision: 1, devices: [entry(f.deviceA, keyA, "self"), entry(f.deviceB, keyB, "click")])))
        slotB.put(try CloudWire.canonical(BackendCloudTrustedList(subject: U.subject, revision: 1, devices: [entry(f.deviceB, keyB, "self"), entry(f.deviceA, keyA, "click")])))
        let domains: Set<String> = [CloudBootFilesFormat.domain]
        let storeA = try CloudSyncStore(root: f.url("a/cloud/sync"), subject: U.subject)
        let storeB = try CloudSyncStore(root: f.url("b/cloud/sync"), subject: U.subject)
        let engineA = try U.engine(storeA, service: service, deviceId: f.deviceA, key: keyA,
                                   trust: BackendCloudTrustStore(subject: U.subject, slot: slotA.port(), pressRefused: { false }), domains: domains)
        let engineB = try U.engine(storeB, service: service, deviceId: f.deviceB, key: keyB,
                                   trust: BackendCloudTrustStore(subject: U.subject, slot: slotB.port(), pressRefused: { false }), domains: domains)

        // Mac A sends a project's two boot files.
        try f.write("a/p/CLAUDE.md", "rules from a\n")
        try f.write("a/p/.claude/commands/go.md", "go\n")
        let bootA = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/p")])
        try await bootA.start(outbox: engineA, subjectHash: U.subjectHash)
        for _ in 0..<200 {
            _ = try? await engineA.flush()
            if await service.operationCount() >= 2, try await engineA.restoreProgress().queued == 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await service.operationCount() >= 2)

        // Mac B signed in before choosing the project's folder: the files arrive and wait.
        await service.switchDevice(f.deviceB)
        let bootB = try BackendCloudBootFiles(deviceId: f.deviceB, stateRoot: f.url("b/cloud/boot-files"))
        try await bootB.start(outbox: engineB, subjectHash: U.subjectHash)
        _ = try await engineB.pull()
        func row() async throws -> BackendCloudOverview.Row {
            let progress = try await engineB.restoreProgress()
            let head = await service.head
            let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), coverage: progress.coverage,
                                                waitingRecords: progress.queued, cloudHead: CloudSequence(head), fetched: progress.brainSeq)
            let page = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot, bootFiles: .init())))
            return try #require(page.rows.first { $0.kind == .bootFiles })
        }
        let waiting = try await engineB.restoreProgress().coverage.filter { $0.inventoryRow == "I09" }
        #expect(waiting.flatMap(\.blockedReasons).contains("2 boot files wait for a folder on this Mac."))
        // Page-names 2 (decided 13 Nov): files that wait for their project's folder are already in the Cloud, so the row
        // says what waits ("Adding 2 instruction files from your Cloud"), never "Not complete" and never level.
        let waitingRow = try await row()
        #expect(waitingRow.state == BackendCloudPageCounts(waitingForFolder: 2).folderLine, "\(waitingRow.state)")
        #expect(waitingRow.state != BackendCloudOverviewWords.notComplete)
        #expect(waitingRow.state != BackendCloudPageWords.allSaved && waitingRow.state != BackendCloudOverviewWords.noBootFiles)

        // The folder is chosen: both files are written, and the row says so at once (no pull, no restart).
        try f.folder("b/p")
        try await bootB.setPlaces([f.project("p", "b/p")])
        #expect(f.text("b/p/CLAUDE.md") == "rules from a\n")
        #expect(f.text("b/p/.claude/commands/go.md") == "go\n")
        let now = try await engineB.restoreProgress().coverage.filter { $0.inventoryRow == "I09" }
        #expect(!now.isEmpty)
        #expect(now.allSatisfy { $0.complete && $0.blockedReasons.isEmpty }, "\(now.map { ($0.sourceId, $0.complete, $0.blockedReasons) })")
        #expect(!now.flatMap(\.blockedReasons).contains { $0.contains("wait for a folder") || $0.contains("verified snapshot") })
        // Whatever this Mac journals of the written files goes up; then the row is settled.
        for _ in 0..<200 {
            if try await engineB.restoreProgress().queued == 0 { break }
            _ = try? await engineB.flush()
            try await Task.sleep(for: .milliseconds(25))
        }
        let settled = try await row()
        // Page-names (decided 13 Nov): with no page counts read the row says "All saved" and never a count of sync records.
        #expect(settled.state == BackendCloudPageWords.allSaved, "\(settled.state)")
        #expect(settled.settled)
        await bootA.stop(); await bootB.stop()
    }

    @Test func aBootFilesLaneWithNothingToListIsNotStarting() throws {
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true),
                                            cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        let page = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot, bootFiles: .init())))
        let row = try #require(page.rows.first { $0.kind == .bootFiles })
        #expect(row.state == BackendCloudOverviewWords.noBootFiles)
        #expect(row.settled)
        #expect(page.standing == .upToDate)
    }

    /// Proof 2 (13 Nov): while two files waited for their project's folder, B's row said "No boot files to save".
    @Test func filesThatWaitAreCountedOnTheRowNeverNoBootFiles() throws {
        let snapshot = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true),
                                            cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        let waiting = BackendCloudOverviewInput.Feature(waitingSummary: "2 boot files wait for a project folder on this Mac")
        let page = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot, bootFiles: waiting)))
        let row = try #require(page.rows.first { $0.kind == .bootFiles })
        #expect(row.state == "2 boot files wait for a project folder on this Mac")
        #expect(!row.settled)
        #expect(page.standing != .upToDate)
    }
}
