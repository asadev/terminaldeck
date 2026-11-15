import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Kinds-state (14 Nov, Mac mini on 0.22.0): "Not ready yet" stood over "Everything on this Mac is saved to your Cloud."
/// and "This Mac has everything your Cloud holds.", the Settings row said "Not complete", and the side-panel Cloud page
/// said "Settings 86" where Settings → Cloud said 10. Pure page models; nothing is sent or read from disk.
@Suite("Cloud pages — tasks and settings state, one headline, one settings number")
struct CloudKindsStatePageTests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    /// Two chosen values that differ stay on each device (the lead's first-sync rule): the owner lists the record as
    /// kept on this Mac, which is an exclusion, never a gap.
    static let keptHere = "1 records from another device wait on this Mac."

    func coverage(_ row: String, items: Int, gaps: [String] = [], exclusions: [String] = []) -> CloudCoverage {
        CloudCoverage(sourceId: "s-" + row, inventoryRow: row, complete: gaps.isEmpty, items: items, bytes: 1, blockedReasons: gaps, exclusions: exclusions)
    }
    func input(settingsGaps: [String] = [], settingsExclusions: [String] = []) -> BackendCloudOverviewInput {
        let rows = [coverage("I01", items: 3), coverage("I12", items: 12), coverage("I21", items: 10, gaps: settingsGaps, exclusions: settingsExclusions)]
        var made = BackendCloudOverviewInput(snapshot: CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, coverage: rows,
                                                                          cloudHead: CloudSequence(400), fetched: CloudSequence(400)),
                                             memory: .init(included: true))
        made.tasks = .init()
        made.settings = .init()
        made.counts = BackendCloudPageCounts(here: [.notes: 3, .tasks: 12, .appSettings: 10, .settings: 76])
        return made
    }
    func row(_ overview: BackendCloudOverview, _ kind: BackendCloudOverview.Kind) throws -> BackendCloudOverview.Row {
        try #require(overview.rows.first { $0.kind == kind })
    }

    /// Two Macs, a different chosen value on each: both pages say all saved, and the state is "Up to date".
    @Test func differentChosenValuesOnTwoMacsAreAllSavedAndUpToDate() throws {
        for mac in ["Mac mini", "MacBook"] {
            let overview = try #require(BackendCloudOverviewBuilder.build(input(settingsExclusions: [Self.keptHere])), "\(mac)")
            let settings = try row(overview, .settings)
            #expect(settings.state == "All saved: 86 settings", "\(mac): \(settings.state)")
            #expect(settings.settled)
            #expect(!settings.notes.contains { $0.contains("wait") }, "nothing shows as waiting or differing: \(settings.notes)")
            #expect(overview.standing == .upToDate, "\(mac): \(overview.title)")
            #expect(overview.title == BackendCloudOverviewWords.upToDate)
            #expect(overview.lines == [BackendCloudOverviewWords.allSaved, BackendCloudOverviewWords.level], "\(overview.lines)")
        }
    }

    /// A real refusal: the Settings row shows it as one plain state, and the headline and sentences agree with it.
    /// The sync core's own sentences (they name "records" and carry the service's reason) are said in plain words on
    /// the row, never dropped: a "Not complete" row always says why.
    @Test(arguments: [
        ("2 edits could not be sent and are kept here: payload_rejected for records.", "2 changes were refused by your Cloud. They are kept on this Mac."),
        ("3 records could not be applied on this Mac and are kept for retry: The value is not one this Mac can use.",
         "3 changes could not be saved on this Mac yet. It is tried again by itself."),
        ("1 records could not be applied on this Mac and are kept for retry: disk full", "1 change could not be saved on this Mac yet. It is tried again by itself."),
    ])
    func aRealFailureShowsItsPlainReasonOnItsRowAndTheHeadlineAgrees(engine: String, said: String) throws {
        for kind in [BackendCloudOverview.Kind.settings, .tasks] {
            var made = input()
            let gapRow = kind == .settings ? "I21" : "I12"
            made.snapshot = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate,
                coverage: made.snapshot.coverage.map { $0.inventoryRow == gapRow ? coverage(gapRow, items: $0.items, gaps: [engine]) : $0 },
                cloudHead: CloudSequence(400), fetched: CloudSequence(400))
            let overview = try #require(BackendCloudOverviewBuilder.build(made))
            let failing = try row(overview, kind)
            #expect(failing.state == BackendCloudOverviewWords.notComplete)
            #expect(!failing.settled)
            #expect(failing.notes.contains(said), "\(kind): \(failing.notes)")
            #expect(failing.notes.allSatisfy(BackendCloudPageWords.isPlain), "\(failing.notes)")
            #expect(overview.waiting.isEmpty, "never a task for him")
            #expect(overview.standing == .notReady, "\(overview.title)")
            #expect(!overview.lines.contains(BackendCloudOverviewWords.allSaved), "never 'Everything is saved' under 'Not ready yet': \(overview.lines)")
            #expect(overview.lines.contains(BackendCloudOverviewWords.notAllSaved))
        }
    }

    /// The invariant itself: whenever both sentences say all is well, the headline is never "Not ready yet".
    @Test func theHeadlineNeverContradictsTheTwoSentences() throws {
        let cases = [input(), input(settingsExclusions: [Self.keptHere]), input(settingsGaps: ["Waiting for a verified snapshot."]),
                     input(settingsGaps: ["2 edits could not be sent and are kept here: refused."])]
        for made in cases {
            let overview = try #require(BackendCloudOverviewBuilder.build(made))
            let allWell = overview.lines.contains(BackendCloudOverviewWords.allSaved) && overview.lines.contains(BackendCloudOverviewWords.level)
            if allWell { #expect(overview.standing == .upToDate, "\(overview.title) over \(overview.lines)") }
            if overview.standing == .notReady { #expect(!allWell, "\(overview.lines)") }
        }
    }

    /// One number: the Settings count on Settings → Cloud and on the side-panel Cloud page is the same definition.
    @Test func settingsAreCountedOnceTheSameWayOnBothPages() throws {
        let counts = BackendCloudPageCounts(here: [.appSettings: 10, .settings: 76])
        #expect(counts.settingsCount == 86)
        #expect(counts.count(BackendCloudContents.Kind.settings) == counts.settingsCount)
        #expect(counts.savedLine(BackendCloudOverview.Kind.settings) == "All saved: 86 settings")
        #expect(counts.onThisMacLine(.settings) == "On this Mac: 86 settings")
        let appOnly = BackendCloudPageCounts(here: [.appSettings: 10])
        #expect(appOnly.count(BackendCloudContents.Kind.settings) == 10)
        #expect(appOnly.savedLine(BackendCloudOverview.Kind.settings) == "All saved: 10 settings")
        #expect(BackendCloudPageCounts().settingsCount == nil, "never a 0 that is not known")
    }
}
