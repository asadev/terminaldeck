import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud boot files: off costs nothing; in step it writes nothing; two Macs end up equal")
struct CloudBootFilesQuietTests {
    typealias F = CloudBootFilesFixture

    func stamps(_ f: F, _ folder: String) -> [String: Date] {
        var found: [String: Date] = [:]
        for name in f.files(folder) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: f.url(folder + "/" + name).path)
            found[name] = attributes?[.modificationDate] as? Date
        }
        return found
    }

    @Test func withCloudOffNothingIsOpenedReadOrMade() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/skills/s/run.sh", "#!/bin/sh\n")
        try f.write("a/claude/CLAUDE.md", "global\n")
        let before = f.listing("a"), dates = stamps(f, "a")
        // A build with the row off never makes this object. Even made, it opens nothing until it is given places.
        let adapter = try BackendCloudBootFiles(deviceId: f.deviceA, stateRoot: f.url("a/cloud/boot-files"))
        #expect(adapter.inventoryRows == ["I09"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.listing("a") == before)
        #expect(stamps(f, "a") == dates)
        #expect(!f.exists("a/cloud"))
        // The row is one of lane A's file rows; its domain is admitted only when that row is switched on.
        #expect(CloudBrainFilesFormat.inventoryRows.contains(CloudBootFilesFormat.inventoryRow))
        #expect(CloudWire.isValidDomainName(CloudBootFilesFormat.domain) && CloudBootFilesFormat.domain == CloudBootFilesFormat.domain.lowercased())
    }

    @Test func aMacInStepWritesNothingIntoAPersonsFolderHoweverOftenItLooks() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/skills/s/SKILL.md", "---\nname: s\nallowed-tools: Bash\n---\n")
        try f.write("a/app/.claude/skills/s/run.sh", "#!/bin/sh\necho hi\n")
        try f.write("a/app/.claude/settings.json", "{}")
        try f.write("a/app/src/main.swift", "print(1)\n")
        let before = f.listing("a/app"), dates = stamps(f, "a/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        for _ in 0..<3 { try await a.refresh() }
        _ = try await a.coverage()
        _ = try await a.sourceInventory()
        _ = try await a.readiness()
        _ = try await F.snapshot(a)
        // Same names (no new folder, no temporary file) and no file was rewritten.
        #expect(f.listing("a/app") == before)
        #expect(stamps(f, "a/app") == dates)
        // This Mac's own files never wait for its own accept.
        let lines = try await a.items()
        #expect(lines.isEmpty)
    }

    @Test func twoMacsMeetAndEachKeepsItsFolderEqualToTheOthers() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "one\n")
        try f.write("a/app/.claude/skills/s/SKILL.md", "skill\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        #expect(f.files("b/app") == f.files("a/app"))
        // Mac B edits one file and adds another; Mac A has not touched its copy since.
        try f.write("b/app/CLAUDE.md", "two\n")
        try f.write("b/app/.claude/commands/new.md", "new\n")
        try await b.refresh()
        let fromB = try await F.local(b)
        #expect(fromB.operations.count == 2)
        try await F.apply(a, fromB.operations, device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "two\n")
        #expect(f.text("a/app/.claude/commands/new.md") == "new\n")
        #expect(f.files("a/app") == f.files("b/app"))
        for name in f.files("a/app") { #expect(f.text("a/app/" + name) == f.text("b/app/" + name), "\(name)") }
        // Nothing waits anywhere and nothing goes round again.
        let waitingA = try await a.items(), waitingB = try await b.items()
        #expect(waitingA.isEmpty && waitingB.isEmpty)
        try await a.refresh()
        try await b.refresh()
        let backA = try await F.local(a, after: first.cursor), backB = try await F.local(b, after: fromB.cursor)
        #expect(backA.operations.isEmpty && backB.operations.isEmpty)
        let changes = try await a.changedFromOtherDevices()
        #expect(changes.count == 2 && changes.allSatisfy { $0.originDevice == f.deviceB })
        #expect(Set(changes.map { $0.how }) == ["updated", "created"])
    }
}
