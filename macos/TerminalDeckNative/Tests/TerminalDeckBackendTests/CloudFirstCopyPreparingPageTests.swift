import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Proof 3 (13 Nov), defect 1: on a real first copy the page said "busy with another Cloud step", "Sending is held up"
/// and "7556 changes on this Mac are still going up" (the records prepared so far, queued page by page), never
/// "Preparing the first copy: n of m". The page read the sync core's progress only at a full status read.
@Suite("Cloud — the first copy says how far it is prepared, and nothing else")
struct CloudFirstCopyPreparingPageTests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    let preparing = CloudBaselineProgress(total: 56_500, sent: 31_400, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)

    func snapshot(baseline: CloudBaselineProgress?, queued: Int = 31_400, blocked: Int = 1, head: UInt64 = 7, fetched: UInt64 = 7) -> CloudAccountSnapshot {
        CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, displayName: "Fixture",
                             coverage: [CloudCoverage(sourceId: "fixture-I01", inventoryRow: "I01", complete: false, items: 0, bytes: 0,
                                                      blockedReasons: ["The first saved copy is not finished."])],
                             waitingRecords: queued, blockedRecords: blocked, baseline: baseline,
                             cloudHead: CloudSequence(head), fetched: CloudSequence(fetched))
    }

    @Test func whilePreparingTheHeadlineIsTheProgressWithNoHeldUpLineAndNothingThatNeedsYou() throws {
        let input = BackendCloudOverviewInput(snapshot: snapshot(baseline: preparing), memory: .init(included: true))
        let page = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(page.title == "Preparing the first copy: 31,400 of 56,500 changes")
        #expect(page.standing == .saving)
        #expect(page.waiting.isEmpty)
        #expect(!page.lines.contains(BackendCloudOverviewWords.heldUp))
        #expect(!page.lines.contains { $0.contains("still going up") })
        #expect(!page.lines.contains { $0.contains("busy") })
        #expect(!page.lines.contains(page.title))
        // One true number: the queue (records prepared so far) is never said as changes going up.
        #expect(!(page.lines + page.rows.map(\.state)).contains { $0.contains("changes on this Mac") })
    }
    @Test func somethingElseThatNeedsYouKeepsItsHeadlineAndTheProgressIsALine() throws {
        var input = BackendCloudOverviewInput(snapshot: snapshot(baseline: preparing), memory: .init(included: true))
        input.projects = .init(waiting: [.init(id: "p", text: "A project needs a folder on this Mac.")])
        let page = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(page.title == BackendCloudOverviewWords.needsYou(1))
        #expect(page.lines.contains("Preparing the first copy: 31,400 of 56,500 changes"))
    }
    @Test func syncNowWaitsWithTheSameSentence() {
        #expect(BackendCloudOverviewWords.syncNowWhilePreparing(preparing).hasPrefix("Preparing the first copy: 31,400 of 56,500 changes"))
        #expect(BackendCloudOverviewWords.syncNowWhilePreparing(nil) == BackendCloudOverviewWords.busyHere)
    }
    @Test func theContentsPageSaysPreparingNotSendingTheQueue() throws {
        let f = BackendCloudContentsFixture.self
        let base = f.snapshot(now: 1_794_000_000_000)
        let snap = CloudAccountSnapshot(phase: .signedIn, gate: base.gate, displayName: base.displayName, devices: base.devices, trust: base.trust,
                                        baseline: preparing, cloudHead: base.cloudHead, fetched: base.fetched)
        let contents = CloudSyncContents(thisDevice: f.mac, items: [], packs: [], held: [], refused: [], queued: 7_556)
        let built = try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: snap, now: 1_794_000_000_000))
        #expect(built.model.devices.first?.state == "Preparing the first copy: 31,400 of 56,500 changes")
    }
    @Test func theAccountReadsTheFirstCopysProgressBetweenStatusReads() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        #expect(await f.account.state().baseline == nil)
        await f.outbox.setBaseline(preparing)
        // No request to the service: only this Mac's own progress is read again.
        let calls = await f.transport.stateCalls
        #expect(await f.account.refreshLocalProgress())
        #expect(await f.transport.stateCalls == calls)
        #expect(await f.account.state().baseline == preparing)
        await f.outbox.setBaseline(.init(total: 56_500, sent: 40_000, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true))
        await f.account.refreshLocalProgress()
        #expect(await f.account.state().baseline?.sent == 40_000)
    }
}
