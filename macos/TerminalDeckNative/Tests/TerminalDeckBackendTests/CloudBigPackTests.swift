import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac-next 2 (d, f), 13 Nov: the owner's first copy (~56,500 records) went up in ~800 packs because this Mac capped a
/// pack at 180,000 plain bytes, while the service takes 256 records and 256 KiB sealed (feed.ts). Memory packs are now
/// filled up to that rule, measured after compression. A copy an older build prepared (and partly sealed) is sent as
/// it is: its sealed pack goes up unchanged, nothing is prepared again, and only what was not packed yet uses big packs.
@Suite("Cloud — memory packs up to the service's rule", .serialized)
struct CloudBigPackTests {
    struct Setup {
        let f: CloudBrainMemoryFixture
        let store: CloudSyncStore
        let engine: CloudSyncEngine
        let service: CloudUpgradeFixtureService
    }
    /// `olderBuild`: the build installed now prepares and starts sending (small packs; three go up, the fourth is
    /// sealed and kept when the connection drops).
    static func prepared(records: Int, olderBuild: Bool = false, incompressible: Bool = false, answerLost: Bool = false) async throws -> Setup {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        _ = try await f.store.appendDiary((1...records).map {
            // `incompressible`: text that gzip barely shrinks (like the owner's memory files), so a full pack of 256
            // records is over the sealed limit and the pack is cut smaller after sealing.
            .init(stamp: .hoot, role: .assistant, text: "Pack size record \($0): " + (incompressible
                ? (0..<24).map { _ in UUID().uuidString }.joined(separator: " ")
                : String(repeating: "words of a working day ", count: 20)), externalID: "pack-\($0)")
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
        if olderBuild {
            await engine.setBrainPackPlainCap(CloudSyncEngine.compatiblePackPlainBytes)
            if answerLost { await service.loseCommitAnswer(after: 3) } else { await service.dropCommit(after: 3) }
        }
        // Setup ends once every page is stored; its first send attempt runs inside (a failure there is recorded).
        _ = try await engine.bootstrap(sources: adapters, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1_000_125, watermarks: [:]))
        return .init(f: f, store: store, engine: engine, service: service)
    }
    static func drain(_ s: Setup) async throws {
        for _ in 0..<300 {
            _ = try? await s.engine.flush()
            if try await s.engine.restoreProgress().queued == 0 { return }
        }
        Issue.record("the queue did not drain")
    }
    /// Every record queued on this Mac (sent or not), counted once.
    static func recordCount(_ s: Setup) throws -> Int {
        Int(String(decoding: try s.store.rows("SELECT count(*) FROM outbox")[0][0], as: UTF8.self)) ?? -1
    }
    static var diaryDomain: String { CloudBrainMemoryFormat.domain("I02") }

    @Test func memoryPacksHoldUpTo256RecordsWithinTheSealedLimitAndAnotherMacReadsThem() async throws {
        let s = try await Self.prepared(records: 1_100)
        defer { try? FileManager.default.removeItem(at: s.f.base) }
        try await Self.drain(s)
        let queued = try Self.recordCount(s)
        let packs = await s.service.committed
        #expect(packs.allSatisfy { $0.descriptor.bytes <= 262_144 && (1...256).contains($0.descriptor.opCount) })
        #expect(packs.reduce(0) { $0 + $1.descriptor.opCount } == queued)
        let diary = packs.filter { $0.descriptor.domains == [Self.diaryDomain] }
        #expect(diary.filter { $0.descriptor.opCount == 256 }.count >= 4)
        // With the old 180,000 plain-byte cap the same diary needed about three times as many packs.
        #expect(diary.count <= 6)

        // The reading side (the same code the installed build runs): open, decode, and apply on another device's memory.
        let full = try #require(diary.first { $0.descriptor.opCount == 256 })
        let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSyncBytes.unbase64(full.ciphertext), maximumBytes: CloudWire.maximumBlobBytes)
        let plain = try await CloudUpgradeFromShip0220Tests.content().open(envelope)
        let operations = try CloudSyncPack.decode(plain)
        #expect(operations.count == 256)
        #expect(plain.count > CloudSyncEngine.compatiblePackPlainBytes)
        let other = try CloudBrainMemoryFixture()
        defer { try? FileManager.default.removeItem(at: other.base) }
        try await other.capture()
        let receipt = try await other.apply(operations, row: "I02")
        #expect(receipt.results.count == 256)
        await s.f.store.close(); await other.store.close()
    }

    @Test func aCopyAnOlderBuildPreparedIsSentAsItIsAndOnlyTheRestUsesBigPacks() async throws {
        let s = try await Self.prepared(records: 1_100, olderBuild: true)
        defer { try? FileManager.default.removeItem(at: s.f.base) }
        #expect(try await s.engine.restoreProgress().queued > 0)
        #expect(await s.service.committed.count == 3)
        let waiting = try #require(try s.store.unacknowledged().first?.0)
        #expect(waiting.descriptor.opCount < 256)

        // This build: the sealed pack goes up unchanged and first; the rest in big packs; nothing twice.
        await s.engine.setBrainPackPlainCap(CloudSyncEngine.brainPackPlainBytes)
        try await Self.drain(s)
        let queued = try Self.recordCount(s)
        let packs = await s.service.committed
        #expect(packs.count > 4)
        #expect(packs[3] == waiting)
        #expect(packs.reduce(0) { $0 + $1.descriptor.opCount } == queued)
        let later = packs.dropFirst(4).filter { $0.descriptor.domains == [Self.diaryDomain] }
        #expect(later.contains { $0.descriptor.opCount == 256 })
        await s.f.store.close()
    }

    /// MAC-NEXT-4 (13 Nov, the owner's Mac after MAC-NEXT-3): his 28th pack (small cut) was stored by the service but
    /// its answer was lost; the new build then read it back from the feed, and its first big pack (memory files,
    /// little compression) was cut smaller after sealing and re-sealed under the SAME id: `send failed: idReused`
    /// on every try, nothing sent. Now: the in-flight pack is not sent again, every smaller pack has its own id, and
    /// the upload completes with every record exactly once.
    @Test func aLostAnswerThenPacksThatCompressLittleStillDrainEveryRecordOnce() async throws {
        let s = try await Self.prepared(records: 900, olderBuild: true, incompressible: true, answerLost: true)
        defer { try? FileManager.default.removeItem(at: s.f.base) }
        #expect(await s.service.committed.count == 4)       // the 4th was stored, its answer lost
        #expect(try s.store.unacknowledged().first != nil)  // ... and this Mac still holds it as in flight
        // A relaunch of the new build: same store, big packs.
        await s.engine.setBrainPackPlainCap(CloudSyncEngine.brainPackPlainBytes)
        _ = try? await s.engine.pull()
        try await Self.drain(s)
        let packs = await s.service.committed
        var seen = Set<String>(), twice = 0
        for pack in packs {
            let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSyncBytes.unbase64(pack.ciphertext), maximumBytes: CloudWire.maximumBlobBytes)
            for op in try CloudSyncPack.decode(try await CloudUpgradeFromShip0220Tests.content().open(envelope)) where !seen.insert(op.opId).inserted { twice += 1 }
        }
        #expect(twice == 0)
        #expect(seen.count == (try Self.recordCount(s)))
        #expect(Set(packs.map(\.descriptor.segmentId)).count == packs.count)
        #expect(packs.allSatisfy { $0.descriptor.bytes <= 262_144 })
        // The shrink really ran: some later diary pack is under 256 records although more were queued behind it.
        #expect(packs.dropFirst(4).contains { $0.descriptor.domains == [Self.diaryDomain] && $0.descriptor.opCount < 256 })
        #expect(try await s.engine.restoreProgress().queued == 0)
        await s.f.store.close()
    }

    /// 14 Nov (owner: "remove this counter thing completely"): the page never speaks of a day's share again; a
    /// wait is the plain slow-down with the time it goes on by itself.
    @Test func thePageNeverSpeaksOfADaysShare() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        let now = Date(timeIntervalSince1970: 1_794_816_000) // 16 Nov 2026 08:00 UTC, 12:00 in Dubai
        let resume = Int64(1_794_816_180) * 1000              // three minutes later, 12:03 in Dubai
        let progress = CloudBaselineProgress(total: 56_500, sent: 31_400, filesWaiting: 0, waitingUntil: resume, reason: CloudSyncEngine.baselineRateReason)
        let line = BackendCloudOverviewWords.baseline(progress, now: now, calendar: calendar)
        #expect(line.hasPrefix("31,400 of 56,500 changes saved; continues by itself at "))
        #expect(line.contains("12:03"))
        #expect(line.hasSuffix(". " + CloudSyncEngine.baselineRateReason))
        for word in ["today", "tomorrow", "allowance", "share"] { #expect(!line.localizedCaseInsensitiveContains(word), "\(word)") }
    }
}
