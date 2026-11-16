import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Proof 3 (13 Nov), defect 3: "Your Cloud" said "On every device" for what this Mac holds, and listed dated archive
/// copies of a topic as items (checklist.20261113-104443.md three times).
@Suite("Cloud contents — on this Mac, and earlier copies only in the item's history")
struct CloudContentsEarlierCopiesTests {
    let now: Int64 = 1_794_000_000_000
    typealias F = BackendCloudContentsFixture
    typealias Key = CloudSyncContents.Key

    func item(_ domain: String, _ record: String, at: Int64, seq: UInt64) -> CloudSyncContents.Item {
        .init(key: Key(domain: domain, sourceId: "memory-" + domain, recordId: record, projectId: nil),
              changes: [.init(deviceId: F.mac, at: at)], standing: .inCloud, seq: CloudSequence(seq))
    }
    @Test func anItemThisMacHoldsSaysOnThisMac() {
        #expect(BackendCloudContentsWords.presenceLine(["On this Mac", "On MacBook Pro", "On Mac mini"]) == "On this Mac")
        #expect(BackendCloudContentsWords.presenceLine(["On this Mac", "Waiting on MacBook Pro"]) == "On this Mac")
        #expect(BackendCloudContentsWords.presenceLine(["On this Mac", "Waiting on A", "Waiting on B"]) == "On this Mac")
        #expect(BackendCloudContentsWords.presenceLine(["Sending from this Mac", "Waiting on MacBook Pro"]) == "Sending from this Mac")
        #expect(BackendCloudContentsWords.presenceLine(["Waiting on this Mac", "On MacBook Pro"]) == "Waiting on this Mac")
    }
    @Test func earlierCopiesAreNamedByTheirLiveFile() {
        #expect(BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: "archive/versions/topics/proof3-shared.20261113-105810.md") == "topics/proof3-shared.md")
        #expect(BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: "archive/versions/hoot/checklist.20261113-104443-2.md") == "hoot/checklist.md")
        #expect(BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: "archive/cloud-conflicts/store-1/abc123/topics/proof3-shared.md") == "topics/proof3-shared.md")
        #expect(BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: "topics/proof3-shared.md") == nil)
        #expect(BackendCloudContentsWords.liveMemoryPath(ofEarlierCopy: "notes/report.20261113-105810.md") == nil)
    }
    @Test func datedArchiveCopiesAreHistoryNeverItemsAndNothingIsListedTwice() throws {
        let t = now - 60_000
        let items: [CloudSyncContents.Item] = [
            item("brain/memory/i06", "file/topics/proof3-shared.md", at: t, seq: 10),
            item("brain/memory/i06", "file/archive/versions/topics/proof3-shared.20261113-105810.md", at: t - 5_000, seq: 9),
            item("brain/memory/i06", "file/archive/cloud-conflicts/store-1/abc123/topics/proof3-shared.md", at: t - 9_000, seq: 8),
            // The same live file through two kinds, and earlier copies of it in both.
            item("brain/memory/i06", "file/hoot/checklist.md", at: t - 20_000, seq: 7),
            item("brain/files/i08", "file/hoot/checklist.md", at: t - 20_000, seq: 7),
            item("brain/memory/i06", "file/archive/versions/hoot/checklist.20261113-104443.md", at: t - 30_000, seq: 6),
            item("brain/files/i08", "file/archive/versions/hoot/checklist.20261113-104443.md", at: t - 30_000, seq: 6),
            // A file of the same name in another folder is another item, said with its folder.
            item("brain/memory/i06", "file/team/decker/checklist.md", at: t - 40_000, seq: 5),
            // An earlier copy whose live file is not in the list is not an item either.
            item("brain/memory/i06", "file/archive/versions/old/gone.20261101-090000.md", at: t - 50_000, seq: 4),
        ]
        let contents = CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
        let built = try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: F.snapshot(now: now), now: now))
        let memory = built.model.items(.memory)
        #expect(!memory.contains { $0.name.range(of: "\\.[0-9]{8}-[0-9]{6}", options: .regularExpression) != nil })
        #expect(!memory.contains { $0.name == "Gone" })
        let shared = memory.filter { $0.name == "Proof3 shared" }
        #expect(shared.count == 1)
        #expect(shared.first?.history.count == 3)
        #expect(shared.first?.changedAt == t)
        // Lane L4 (owner: three rows named "Checklist" with nothing to tell them apart): whose it is is in its name.
        let checklists = memory.filter { $0.name.hasPrefix("Checklist") }
        #expect(checklists.count == 2)
        #expect(Set(checklists.map(\.name)) == ["Checklist · Hoot", "Checklist · Decker"]) // item 5a: Hoot by name, never the folder word
        let lines = memory.map { $0.name + "|" + ($0.place ?? "") }
        #expect(lines.count == Set(lines).count)
        // Counted once each in the sidebar.
        #expect(built.model.counts[.memory] == memory.count)
    }
}
