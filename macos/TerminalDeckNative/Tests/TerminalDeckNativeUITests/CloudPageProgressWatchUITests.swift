import AppKit
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Proof 3 (13 Nov), defects 1 and 4: with the Cloud page open, this Mac's own progress is read again every two
/// seconds while something moves (the first copy, a queue, a fetch), every ten otherwise, and never with the page shut.
/// Sync now waits while the first copy is prepared.
@Suite("Cloud page — its own progress is read again while it is open")
@MainActor
struct CloudPageProgressWatchUITests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    func snapshot(baseline: CloudBaselineProgress? = nil, head: UInt64 = 7, fetched: UInt64 = 7, phase: CloudAccountSnapshot.Phase = .signedIn) -> CloudAccountSnapshot {
        CloudAccountSnapshot(phase: phase, gate: Self.gate, baseline: baseline, cloudHead: CloudSequence(head), fetched: CloudSequence(fetched))
    }
    @Test func theProgressIsReadOftenWhileSomethingMovesAndOnlyWithThePageOpen() {
        let preparing = CloudBaselineProgress(total: 56_500, sent: 31_400, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)
        let second: UInt64 = 1_000_000_000
        #expect(NativeCloudAccount.progressCheckDue(snapshot: snapshot(baseline: preparing), pageOpen: true, sinceLast: 2 * second))
        #expect(NativeCloudAccount.progressCheckDue(snapshot: snapshot(head: 40, fetched: 21), pageOpen: true, sinceLast: 2 * second))
        #expect(!NativeCloudAccount.progressCheckDue(snapshot: snapshot(), pageOpen: true, sinceLast: 2 * second))
        #expect(NativeCloudAccount.progressCheckDue(snapshot: snapshot(), pageOpen: true, sinceLast: 10 * second))
        #expect(!NativeCloudAccount.progressCheckDue(snapshot: snapshot(baseline: preparing), pageOpen: false, sinceLast: 60 * second))
        #expect(!NativeCloudAccount.progressCheckDue(snapshot: snapshot(phase: .signedOut), pageOpen: true, sinceLast: 60 * second))
        #expect(NativeCloudSettings.syncNowWaits(snapshot(baseline: preparing)))
        #expect(!NativeCloudSettings.syncNowWaits(snapshot()))
    }
}
