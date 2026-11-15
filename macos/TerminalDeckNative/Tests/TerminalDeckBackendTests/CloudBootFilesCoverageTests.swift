import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud boot files: coverage (what travels, what is left out on purpose, what waits and why)")
struct CloudBootFilesCoverageTests {
    typealias F = CloudBootFilesFixture

    @Test func aPlaceInStepIsCompleteAndNamesWhatIsLeftOutOnPurpose() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/p/CLAUDE.md", "rules\n")
        try f.write("a/p/.claude/skills/s/SKILL.md", "skill\n")
        // Left out on purpose, one of each kind.
        try f.write("a/p/.claude/skills/s/icon.png", data: Data([0x89, 0x50, 0x00, 0x01]))
        try f.write("a/p/.claude/skills/s/.hidden.md", "hidden\n")
        try f.write("a/p/.claude/skills/s/settings.json", "{}")
        try f.write("a/p/.claude/skills/s/node_modules/pkg/readme.md", "installed\n")
        try f.write("a/p/.claude/skills/s/big.md", data: Data(repeating: 0x61, count: CloudBootFilesFormat.maximumFileBytes + 1))
        try f.write("a/outside.md", "outside\n")
        try FileManager.default.createSymbolicLink(at: f.url("a/p/.claude/skills/s/linked.md"), withDestinationURL: f.url("a/outside.md"))
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/p")])
        let coverage = try await a.coverage()
        #expect(coverage.count == 1)
        let place = try #require(coverage.first)
        #expect(place.sourceId == "files/I09/project/" + BackendCloudBrainFilesNames.token("p") && place.inventoryRow == "I09")
        #expect(place.complete && place.blockedReasons.isEmpty)
        #expect(place.items == 2 && place.bytes == 12)
        // The rules, by name, always; then what this folder holds of each.
        for rule in CloudBootFilesRules.exclusions { #expect(place.exclusions.contains(rule), "\(rule)") }
        let held = ["1 file that is not text stays on this Mac.", "1 linked item stays on this Mac.", "1 file larger than 1 MB stays on this Mac.",
                    "1 hidden item stays on this Mac.", "1 settings, hooks or sign-in item stays on this Mac.",
                    "1 folder of installed packages stays on this Mac."]
        for line in held { #expect(place.exclusions.contains(line), "\(line)") }
        #expect(place.exclusions.count == CloudBootFilesRules.exclusions.count + held.count)
        // The same in the sync core's inventory shape, and as the last page of a snapshot.
        let inventory = try await a.sourceInventory()
        #expect(inventory.count == 1)
        let row = try #require(inventory.first)
        #expect(row.domain == "brain/files/i09" && row.sourceId == place.sourceId && row.complete && row.items == 2 && row.exclusions == place.exclusions)
        let snapshot = try await F.snapshot(a)
        #expect(snapshot.coverage == coverage)
        let ready = try await a.readiness()
        #expect(ready.verified && ready.counts.blocked == 0 && ready.counts.files == 2 && ready.reasons.isEmpty)
    }

    @Test func whatWaitsIsSaidWithItsReasonAndMakesThePlaceIncomplete() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/p/CLAUDE.md", "from a\n", at: F.past)
        try f.write("a/p/.claude/skills/s/run.sh", "#!/bin/sh\necho hi\n")
        try f.write("a/p/.claude/commands/ok.md", "ok\n")
        try f.write("a/q/CLAUDE.md", "another project\n")
        // On B: a newer CLAUDE.md of its own, a link where the commands folder would be, and no folder for project q.
        try f.write("b/p/CLAUDE.md", "from b\n", at: F.past + 1_000)
        try f.folder("b/p/.claude")
        try f.folder("b/outside")
        try FileManager.default.createSymbolicLink(at: f.url("b/p/.claude/commands"), withDestinationURL: f.url("b/outside"))
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/p"), f.project("q", "a/q")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/p")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        let coverage = try await b.coverage()
        #expect(coverage.count == 2)
        let place = try #require(coverage.first), elsewhere = try #require(coverage.last)
        #expect(!place.complete && place.items == 1)
        // The one rule: B's own CLAUDE.md is newer, so it stays and nothing is "kept beside" to say.
        #expect(place.blockedReasons == [BackendCloudBootFiles.acceptLine(1), BackendCloudBootFiles.blockedLine(1)])
        #expect(place.blockedReasons[0].contains("accept") && place.blockedReasons[1].contains("in the way"))
        #expect(elsewhere.sourceId == "files/I09/not-on-this-mac" && !elsewhere.complete && elsewhere.items == 1)
        #expect(elsewhere.blockedReasons == ["1 boot file waits for a folder on this Mac."])
        let ready = try await b.readiness()
        #expect(!ready.verified && ready.counts.blocked == 3 && ready.reasons.count == 3)
        // The folder for q is chosen, the link is removed, the script is accepted: nothing is left to say.
        try f.folder("b/q")
        try FileManager.default.removeItem(at: f.url("b/p/.claude/commands"))
        try await b.setPlaces([f.project("p", "b/p"), f.project("q", "b/q")])
        let lines = try await b.items()
        let script = lines.filter { $0.kind == .needsAccept }.map { $0.id }
        try await b.accept(script)
        let later = try await b.coverage()
        #expect(later.count == 2)
        let first = try #require(later.first), second = try #require(later.last)
        #expect(first.blockedReasons.isEmpty && first.complete && second.complete && second.items == 1)
        let readyLater = try await b.readiness()
        #expect(readyLater.verified && readyLater.reasons.isEmpty)
    }

    @Test func aFileThatCannotBeReadOrAFolderThatIsGoneIsAGapAndNeverReadAsARemoval() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/p/.claude/skills/s/SKILL.md", "ok\n")
        try f.write("a/p/.claude/skills/s/locked.md", "cannot be read\n")
        let sealed = ["a/p/.claude/skills/s/locked.md"]
        try f.seal(sealed)
        defer { f.unseal(sealed) }
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/p")])
        let coverage = try await a.coverage()
        let place = try #require(coverage.first)
        #expect(!place.complete && place.items == 1 && place.blockedReasons == ["1 item could not be read."])
        // The project's folder is gone (a disk unplugged, a folder moved).
        try await a.setPlaces([f.project("p", "a/missing")])
        try await a.refresh()
        try await a.refresh()
        let gone = try await a.coverage()
        let missing = try #require(gone.first)
        #expect(!missing.complete && missing.items == 0 && missing.blockedReasons == ["This folder is not reachable on this Mac."])
        let sent = try await F.local(a)
        #expect(sent.operations.count == 1 && sent.operations.allSatisfy { $0.kind == .put })
    }

    /// Release fix R3 (16 Nov): a place with something unreadable still receives its readable files, and an arriving
    /// file is never written over what this Mac could not read, nor is the unreadable file ever sent as removed.
    @Test func anArrivalNeverReplacesAFileThatCannotBeReadAndTheRestStillArrives() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/p/.claude/skills/s/SKILL.md", "from a\n")
        try f.write("a/p/.claude/skills/s/locked.md", "from a, newer\n")
        try f.write("b/p/.claude/skills/s/locked.md", "his own, cannot be read\n")
        let sealed = ["b/p/.claude/skills/s/locked.md"]
        try f.seal(sealed)
        defer { f.unseal(sealed) }
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/p")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/p")])
        try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        try await b.refresh()
        try await b.refresh()
        #expect(f.text("b/p/.claude/skills/s/SKILL.md") == "from a\n", "the readable file arrives")
        let sentB = try await F.local(b)
        #expect(sentB.operations.allSatisfy { $0.kind == .put }, "nothing unreadable is sent as removed")
        f.unseal(sealed)
        #expect(f.text("b/p/.claude/skills/s/locked.md") == "his own, cannot be read\n", "never written over")
    }
}
