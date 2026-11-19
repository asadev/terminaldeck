import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

extension CloudBootFilesFixture {
    /// Regular files under a folder (no folders, no links), sorted.
    func files(_ path: String) -> [String] {
        listing(path).filter { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url(path + "/" + name).path)
            return attributes?[.type] as? FileAttributeType == .typeRegular
        }
    }
    func mode(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(path).path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// What the sync core does with a pack: check, apply, verify. `device` is the VERIFIED signer.
    @discardableResult
    static func apply(_ adapter: BackendCloudBootFiles, _ operations: [CloudOperation], device: String) async throws -> CloudImportReceipt {
        let prepared = try await adapter.validateIncoming(operations, files: [])
        let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .init(1)))
        let verification = try await adapter.verify(receipt)
        guard verification.verified else { throw CloudFailure.checksumMismatch }
        return receipt
    }
    /// The refusal a record gets, or nil when it was let in (or failed some other way).
    static func refusal(_ adapter: BackendCloudBootFiles, _ operations: [CloudOperation]) async -> CloudRecordRefusal? {
        do {
            _ = try await adapter.validateIncoming(operations, files: [])
            return nil
        } catch let refusal as CloudRecordRefusal {
            return refusal
        } catch {
            return nil
        }
    }
    /// A record as a broken or hostile sender could make it: any key, any bytes, internally consistent ids and hashes.
    static func forged(key: String, data: Data, declaredBytes: Int? = nil, domain: String = CloudBootFilesFormat.domain, device: String,
                       projectId: String? = nil, createdAt: Int64 = 1_000) throws -> CloudOperation {
        let storeId = UUID().uuidString.lowercased(), version = UUID().uuidString.lowercased()
        let total = declaredBytes ?? data.count
        let count = max(1, (total + CloudBrainFilesFormat.partBytes - 1) / CloudBrainFilesFormat.partBytes)
        let hash = BackendCloudBrainMemoryHash.bytes(data)
        let part = CloudBrainMemoryPart(storeId: storeId, inventoryRow: CloudBootFilesFormat.inventoryRow, key: key, version: version, resourceHash: hash,
                                        bytes: String(total), index: 0, count: count, parents: [], data: data.base64EncodedString())
        let encoded = try CloudWire.canonical(part)
        let value = try JSONDecoder().decode(CloudValue.self, from: encoded)
        let payload = try CloudWire.canonical(value)
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        return CloudOperation(v: 1, opId: revision, originDevice: device, domain: domain, entityId: BackendCloudBrainMemoryHash.uuid(storeId + "\n" + key + "\n0"),
                              revision: revision, parents: [], kind: .put, projectId: projectId, rootId: projectId == nil ? nil : CloudBootFilesFormat.projectRoot,
                              source: .init(sourceId: "files/I09/forged", recordId: key, offset: 0, rawHash: hash), createdAt: createdAt, payload: value,
                              payloadHash: BackendCloudBrainMemoryHash.bytes(payload))
    }
    static func forged(key: String, text: String, device: String) throws -> CloudOperation {
        try forged(key: key, data: Data(text.utf8), device: device)
    }
}

@Suite("Cloud boot files: apply (a file from another device reaches this Mac's folder)")
struct CloudBootFilesApplyTests {
    typealias F = CloudBootFilesFixture

    @Test func bootFilesArriveInTheFolderThisMacChoseForTheSameProject() async throws {
        let f = try F(); defer { f.close() }
        let files = ["CLAUDE.md": "project rules\n", "AGENTS.md": "codex rules\n", "GEMINI.md": "gemini rules\n",
                     ".claude/skills/review/SKILL.md": "---\nname: review\n---\nSteps.\n", ".claude/commands/ship.md": "Ship it.\n",
                     ".claude/agents/reader.md": "---\nname: reader\ndescription: Reads\n---\nRead.\n", ".agents/skills/x/SKILL.md": "x\n"]
        for (path, text) in files { try f.write("a/work/app/" + path, text) }
        try f.folder("b/elsewhere/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/work/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p-app", "b/elsewhere/app")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        for (path, text) in files { #expect(f.text("b/elsewhere/app/" + path) == text, "\(path)") }
        // Exactly those files: nothing else, and nothing left behind.
        #expect(f.files("b/elsewhere/app") == files.keys.sorted())
        let waiting = try await b.items()
        #expect(waiting.isEmpty)
        // Each written file is on record with the device whose signature brought it.
        let changes = try await b.changedFromOtherDevices()
        #expect(changes.count == files.count)
        #expect(changes.allSatisfy { $0.originDevice == f.deviceA && $0.how == "created" && $0.identity == "p-app" && $0.place == .project })
        // Nothing arrives twice, and an arrival is never sent back as this Mac's own change.
        try await F.apply(b, operations, device: f.deviceA)
        try await b.refresh()
        let echo = try await F.local(b)
        #expect(echo.operations.isEmpty)
        let again = try await b.changedFromOtherDevices()
        #expect(again.count == files.count)
    }

    /// Proof 2 (13 Nov): arrived files waited for the Cloud page to be opened. Lane F now tells the composition after
    /// every applied pack, so the page and the places are looked at again by themselves.
    @Test func anAppliedPackTellsTheCompositionWithoutAPageVisit() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [])
        let told = CloudBootArrivalCount()
        await b.setArrivalNotice { told.add() }
        try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        for _ in 0..<100 where told.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told.value == 1)
        // The project's folder chosen later: the waiting file is placed when the places are given (no page needed).
        try f.folder("b/app")
        try await b.setPlaces([f.project("p-app", "b/app")])
        #expect(f.text("b/app/CLAUDE.md") == "rules\n")
        #expect(try await b.items().isEmpty)
    }

    @Test func aFileWaitsUntilItsProjectHasAFolderOnThisMacAndIsThenPlaced() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/commands/ship.md", "Ship.\n")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        var waiting = try await b.items()
        #expect(waiting.count == 2)
        #expect(waiting.allSatisfy { $0.kind == .waitingFolder && $0.identity == "p-app" && $0.originDevice == f.deviceA && !$0.canAccept })
        // Nothing outside this Mac's own Cloud folder exists: no folder was guessed or made.
        #expect(f.listing("b").allSatisfy { $0 == "cloud" || $0.hasPrefix("cloud/") })
        // A waiting line cannot be accepted or waved away.
        let ids = waiting.map { $0.id }
        let accepted = try await b.accept(ids)
        #expect(accepted.isEmpty)
        try await b.dismiss(ids)
        waiting = try await b.items()
        #expect(waiting.count == 2)
        // The person chooses a folder for the project on this Mac.
        try f.folder("b/chosen")
        try await b.setPlaces([f.project("p-app", "b/chosen")])
        #expect(f.text("b/chosen/CLAUDE.md") == "rules\n")
        #expect(f.text("b/chosen/.claude/commands/ship.md") == "Ship.\n")
        waiting = try await b.items()
        #expect(waiting.isEmpty)
        let changes = try await b.changedFromOtherDevices()
        #expect(changes.count == 2 && changes.allSatisfy { $0.originDevice == f.deviceA })
    }

    /// The one rule (owner, 14 Nov): an edit here and a newer version from another device: the newer one is used here
    /// too, this Mac's version is kept 30 days, one line says so, and Restore puts it back as the newest.
    @Test func aLocalEditAndANewerArrivalTheNewerIsUsedAndThisMacsVersionIsKept() async throws {
        let f = try F(); defer { f.close() }
        let t = F.past
        try f.write("a/app/CLAUDE.md", "v1\n", at: t)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        #expect(f.text("b/app/CLAUDE.md") == "v1\n")
        // Unchanged here since this Mac last saw Cloud's version: the next version replaces it.
        try f.write("a/app/CLAUDE.md", "v2\n", at: t + 5_000)
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        try await F.apply(b, second.operations, device: f.deviceA)
        #expect(f.text("b/app/CLAUDE.md") == "v2\n")
        var lines = try await b.items()
        #expect(lines.isEmpty)
        // Edited here at :10, and a third version made at :20 arrives: the newer (Mac A's) is used here.
        try f.write("b/app/CLAUDE.md", "mine\n", at: t + 10_000)
        try f.write("a/app/CLAUDE.md", "v3\n", at: t + 20_000)
        try await a.refresh()
        let third = try await F.local(a, after: second.cursor)
        let receipt = try await F.apply(b, third.operations, device: f.deviceA)
        #expect(receipt.results.contains { $0.status == .keptBoth })
        #expect(f.text("b/app/CLAUDE.md") == "v3\n")
        lines = try await b.items()
        #expect(lines.isEmpty)
        // This Mac's edit was recorded as its own version before the arrival was looked at, then the used one.
        let mine = try await F.local(b)
        let bodies = try mine.operations.map(F.body)
        #expect(bodies == ["mine\n", "v3\n"])
        // One line: the newer version replaced this Mac's own, which is kept and can be read.
        let changes = try await b.changedFromOtherDevices()
        let newer = try #require(changes.first)
        #expect(newer.how == "newer" && newer.originDevice == f.deviceA && newer.previousHash == BackendCloudBrainMemoryHash.bytes(Data("mine\n".utf8)))
        let old = try await b.keptLocal(hash: try #require(newer.previousHash))
        #expect(old == Data("mine\n".utf8))
        let kept = try await b.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        #expect(kept.contains { $0.hash == newer.previousHash && $0.device == f.deviceB && $0.name == "CLAUDE.md" })
        // Restore: the kept text is in the file again, as an ordinary edit that travels as the newest.
        let restored = try await b.putBackEarlierVersion(newer)
        #expect(restored == .putBack)
        #expect(f.text("b/app/CLAUDE.md") == "mine\n")
        let sent = try await F.local(b, after: mine.cursor)
        let sentBodies = try sent.operations.map(F.body)
        #expect(sentBodies == ["mine\n"])
    }

    @Test func identicalBytesAreAlreadyPresentAndANewerFileOfThisMacsOwnStays() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "same\n", at: F.past)
        try f.write("a/app/AGENTS.md", "from a\n", at: F.past + 1_000)
        try f.write("b/app/CLAUDE.md", "same\n", at: F.past)
        try f.write("b/app/AGENTS.md", "from b\n", at: F.past + 2_000)
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let operations = try await F.snapshot(a).operations
        let receipt = try await F.apply(b, operations, device: f.deviceA)
        #expect(receipt.results.contains { $0.status == .alreadyPresent })
        #expect(f.text("b/app/CLAUDE.md") == "same\n")
        // The one rule: both are first copies, and this Mac's is newer, so it stays; Mac A's is kept 30 days.
        #expect(f.text("b/app/AGENTS.md") == "from b\n")
        let lines = try await b.items()
        #expect(lines.isEmpty)
        let kept = try await b.keptVersions(place: .project, identity: "p", relative: "AGENTS.md")
        #expect(kept.count == 1 && kept.first?.device == f.deviceA)
        // Nothing was written into the folder.
        let changes = try await b.changedFromOtherDevices()
        #expect(changes.isEmpty)
        #expect(f.files("b/app") == ["AGENTS.md", "CLAUDE.md"])
    }

    @Test func aFileThatCanRunACommandOrGrantToolsIsListedAndWrittenOnlyWhenAccepted() async throws {
        let f = try F(); defer { f.close() }
        let skill = ".claude/skills/deploy/SKILL.md", script = ".claude/skills/deploy/scripts/run.sh"
        let agent = ".claude/agents/builder.md", command = ".claude/commands/status.md"
        let runs = [skill: "---\nname: deploy\nallowed-tools: Bash(git:*)\n---\nDeploy.\n", script: "#!/bin/sh\necho deployed\n",
                    agent: "---\nname: builder\ntools: Bash, Read\n---\nBuild.\n", command: "Now: !`git status`\n"]
        let plain = [".claude/skills/deploy/notes.md": "Plain notes.\n", "CLAUDE.md": "rules\n"]
        for (path, text) in runs { try f.write("a/app/" + path, text) }
        for (path, text) in plain { try f.write("a/app/" + path, text) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url("a/app/" + script).path)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        // Plain text is in place; nothing that can run was written.
        for (path, text) in plain { #expect(f.text("b/app/" + path) == text, "\(path)") }
        for path in runs.keys { #expect(!f.exists("b/app/" + path), "\(path)") }
        let lines = try await b.items()
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.kind == .needsAccept && $0.canAccept && $0.originDevice == f.deviceA })
        var why: [String: [String]] = [:]
        for line in lines { why[line.relative] = line.reasons }
        #expect(why[skill] == ["header:allowed-tools"])
        #expect(why[script] == ["script-or-settings", "script"])
        #expect(why[agent] == ["header:tools"])
        #expect(why[command] == ["inline-command"])
        // Looking again changes nothing.
        try await b.refresh()
        for path in runs.keys { #expect(!f.exists("b/app/" + path), "\(path)") }
        // The person accepts the skill and its script on this Mac.
        let chosen = lines.filter { $0.relative == skill || $0.relative == script }.map { $0.id }
        let done = try await b.accept(chosen)
        #expect(Set(done) == Set(chosen))
        #expect(f.text("b/app/" + skill) == runs[skill])
        #expect(f.text("b/app/" + script) == runs[script])
        // A script (it starts with #!) keeps working on every Mac: written runnable. Anything else never is.
        #expect(f.mode("b/app/" + script) & 0o111 != 0)
        #expect(f.mode("b/app/" + skill) & 0o111 == 0)
        // The other two still wait.
        #expect(!f.exists("b/app/" + agent) && !f.exists("b/app/" + command))
        let left = try await b.items()
        #expect(left.count == 2 && left.allSatisfy { $0.kind == .needsAccept })
        // Accepting sends nothing: this Mac now holds exactly what Cloud holds.
        let sent = try await F.local(b)
        #expect(sent.operations.isEmpty)
        // Acceptance is for those exact bytes: a newer version of the accepted skill waits again.
        try f.write("a/app/" + skill, "---\nname: deploy\nallowed-tools: Bash\n---\nDeploy everything.\n")
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        try await F.apply(b, second.operations, device: f.deviceA)
        #expect(f.text("b/app/" + skill) == runs[skill])
        let again = try await b.items()
        #expect(again.contains { $0.kind == .needsAccept && $0.relative == skill })
    }

    @Test func anExplicitRemovalOnAnotherMacAppliesIntoTheBootBin() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/commands/ship.md", "Ship.\n")
        try f.folder("b/app")
        let place = f.project("p", "a/app")
        let a = try await f.mac("a", device: f.deviceA, places: [place])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        let actor = CloudDeleteActor(by: .person, mac: f.deviceA, macName: "Mac mini", at: F.past, group: UUID().uuidString)
        let item = CloudDeleteItem(id: place.sourceId + "\n.claude/commands/ship.md", kind: "boot", name: "ship.md")
        _ = try await a.deleteItems([item], scope: .everywhere, by: actor)
        let removal = try await F.local(a, after: first.cursor)
        #expect(removal.operations.contains { $0.kind == .archive })
        try await F.apply(b, removal.operations, device: f.deviceA)
        #expect(f.text("b/app/.claude/commands/ship.md") == nil)
        #expect(try await b.binGroups().count == 1)
        #expect(!(try await b.items()).contains { $0.kind == .removedElsewhere })
        #expect(try await F.local(b).operations.isEmpty)
    }

    @Test func twoMacsThatEachRecordedTheSameFileBeforeTheyMetStillPassLaterEditsOn() async throws {
        let f = try F(); defer { f.close() }
        let skill = ".claude/skills/s/SKILL.md"
        for mac in ["a", "b"] {
            try f.write(mac + "/app/CLAUDE.md", "same\n")
            try f.write(mac + "/app/" + skill, "---\nname: s\nallowed-tools: Read\n---\nSame.\n")
        }
        // Both Macs read their folders before either sees the other (a new Mac waits for its Trust click).
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let fromA = try await F.local(a), fromB = try await F.local(b)
        try await F.apply(b, fromA.operations, device: f.deviceA)
        try await F.apply(a, fromB.operations, device: f.deviceB)
        var linesA = try await a.items(), linesB = try await b.items()
        #expect(linesA.isEmpty && linesB.isEmpty)
        // Mac A edits. Its version names B's version of the same bytes as its parent, which B's engine does not hold.
        try f.write("a/app/CLAUDE.md", "edited on a\n")
        try f.write("a/app/" + skill, "---\nname: s\nallowed-tools: Bash\n---\nChanged.\n")
        try await a.refresh()
        let edit = try await F.local(a, after: fromA.cursor)
        #expect(edit.operations.count == 2)
        try await F.apply(b, edit.operations, device: f.deviceA)
        // Plain text: the next version of the very bytes B holds is written.
        #expect(f.text("b/app/CLAUDE.md") == "edited on a\n")
        // A file that grants tools: the same, but only when the person accepts it.
        #expect(f.text("b/app/" + skill) == "---\nname: s\nallowed-tools: Read\n---\nSame.\n")
        linesB = try await b.items()
        #expect(linesB.count == 1)
        let waits = try #require(linesB.first)
        #expect(waits.relative == skill && waits.canAccept && waits.reasons == ["newer-version", "header:allowed-tools"])
        try await b.accept([waits.id])
        #expect(f.text("b/app/" + skill) == "---\nname: s\nallowed-tools: Bash\n---\nChanged.\n")
        linesB = try await b.items()
        #expect(linesB.isEmpty)
        // B records both as its newest versions; A finds them already present; from then on both name the same versions.
        let echo = try await F.local(b, after: fromB.cursor)
        #expect(echo.operations.count == 2)
        try await F.apply(a, echo.operations, device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "edited on a\n")
        try f.write("b/app/CLAUDE.md", "edited on b\n")
        try await b.refresh()
        let next = try await F.local(b, after: echo.cursor)
        let receipt = try await F.apply(a, next.operations, device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "edited on b\n")
        #expect(!receipt.results.contains { $0.status == .keptBoth })
        linesA = try await a.items()
        #expect(linesA.isEmpty)
        // A version whose parent this Mac never saw is NOT a next version. It is a first saved copy (no history), so
        // rule J lets this Mac's version stay; the arrived one is kept 30 days and nothing is listed.
        let branch = try F.forged(key: F.prefix(project: "p") + "CLAUDE.md", text: "an unrelated branch\n", device: f.deviceB)
        try await F.apply(a, [branch], device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "edited on b\n")
        linesA = try await a.items()
        #expect(linesA.isEmpty)
        let kept = try await a.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        #expect(kept.contains { $0.hash == BackendCloudBrainMemoryHash.bytes(Data("an unrelated branch\n".utf8)) })
    }

    @Test func aFileMadeAgainAfterItsRemovalElsewhereIsTheNextVersionHere() async throws {
        let f = try F(); defer { f.close() }
        let command = ".claude/commands/ship.md"
        try f.write("a/app/" + command, "Ship.\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        let item = CloudDeleteItem(id: f.project("p", "a/app").sourceId + "\n" + command, kind: "boot", name: "ship.md")
        let actor = CloudDeleteActor(by: .person, mac: f.deviceA, macName: "Mac mini", at: F.past, group: UUID().uuidString)
        _ = try await a.deleteItems([item], scope: .everywhere, by: actor)
        let removal = try await F.local(a, after: first.cursor)
        try await F.apply(b, removal.operations, device: f.deviceA)
        #expect(f.text("b/app/" + command) == nil)
        var lines = try await b.items()
        #expect(lines.isEmpty)
        // Made again on Mac A: Mac B still holds exactly the removed bytes, so this is its next version.
        try f.write("a/app/" + command, "Ship again.\n")
        try await a.refresh()
        let again = try await F.local(a, after: removal.cursor)
        #expect(again.operations.count == 1)
        try await F.apply(b, again.operations, device: f.deviceA)
        #expect(f.text("b/app/" + command) == "Ship again.\n")
        lines = try await b.items()
        #expect(lines.isEmpty)
    }

    @Test func aNewerFileOfThisMacsOwnBecomesTheNewestVersionAndTheWaitingOneIsKept() async throws {
        let f = try F(); defer { f.close() }
        let script = ".claude/skills/s/run.sh"
        try f.write("a/app/" + script, "#!/bin/sh\necho theirs\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        #expect(!f.exists("b/app/" + script))
        // The person writes a file of their own at that path, later, while the arrived one still waits.
        try f.write("b/app/" + script, "#!/bin/sh\necho mine\n", at: F.past + 60_000)
        try await b.refresh()
        #expect(f.text("b/app/" + script) == "#!/bin/sh\necho mine\n")
        let lines = try await b.items()
        #expect(lines.isEmpty)
        // It is this Mac's newest version, made BESIDE the arrived one (same parents: none here), so the other Mac uses it
        // by the one rule and gets the line; the arrived one is kept 30 days here.
        let sent = try await F.local(b)
        #expect(sent.operations.count == 1)
        let version = try #require(sent.operations.first)
        let body = try F.body(version)
        #expect(body == "#!/bin/sh\necho mine\n" && version.parents.isEmpty)
        let kept = try await b.keptVersions(place: .project, identity: "p", relative: script)
        #expect(kept.count == 1 && kept.first?.device == f.deviceA)
    }

    @Test func aProjectWithoutAChosenFolderHereWaitsAndIsPlacedOnlyInTheChosenOne() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.folder("b/aaa-first")
        try f.folder("b/chosen")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        // The project has a folder here, but nobody chose it for boot files (as when lane A takes "the first one").
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/aaa-first", chosen: false)])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        #expect(f.listing("b/aaa-first").isEmpty)
        var waiting = try await b.items()
        #expect(waiting.count == 1)
        let line = try #require(waiting.first)
        #expect(line.kind == .waitingFolder && line.reasons == ["no-chosen-folder"] && !line.canAccept)
        // Nothing is read from an unchosen folder either.
        try f.write("b/aaa-first/AGENTS.md", "local\n")
        try await b.refresh()
        let sent = try await F.local(b)
        #expect(sent.operations.isEmpty)
        // The person chooses a folder: the file lands there and nowhere else.
        try await b.setPlaces([f.project("p", "b/chosen")])
        #expect(f.text("b/chosen/CLAUDE.md") == "rules\n")
        #expect(!f.exists("b/aaa-first/CLAUDE.md"))
        waiting = try await b.items()
        #expect(waiting.isEmpty)
    }

    @Test func aProjectWhoseFolderIsTheHomeFolderOrHoldsAnAccountHomeIsRefused() async throws {
        let f = try F(); defer { f.close() }
        let home = f.url("b/home"), claude = f.url("b/home/.claude")
        func why(_ path: String) -> String? {
            BackendCloudBootFiles.placeRefusal(f.project("p", path), accountHomes: [home, claude])
        }
        #expect(why("b/home") == "home-folder")
        #expect(why("b/home/.claude") == "home-folder")
        #expect(why("b") == "home-folder")
        #expect(why("B/Home") == "home-folder")
        #expect(why("b/home/work/app") == nil)
        let root = BackendCloudBootFilesPlace(kind: .project, identity: "p", root: URL(fileURLWithPath: "/"), chosen: true)
        #expect(BackendCloudBootFiles.placeRefusal(root, accountHomes: []) == "home-folder")
        let realHome = BackendCloudBootFilesPlace(kind: .project, identity: "p", root: FileManager.default.homeDirectoryForCurrentUser, chosen: true)
        #expect(BackendCloudBootFiles.placeRefusal(realHome, accountHomes: BackendCloudBootFiles.defaultAccountHomes()) == "home-folder")
        // An account home itself is a place of its own kind, not refused here.
        #expect(BackendCloudBootFiles.placeRefusal(f.home(.claude, "b/home/.claude"), accountHomes: [home, claude]) == nil)
        // A link to the home folder is the home folder.
        try f.folder("b/home/.claude")
        try FileManager.default.createSymbolicLink(at: f.url("b/link"), withDestinationURL: home)
        #expect(why("b/link") == "home-folder")

        // End to end: nothing is written into such a folder; the files wait with the reason.
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/agents/r.md", "---\nname: r\n---\nRead.\n")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try BackendCloudBootFiles(deviceId: f.deviceB, stateRoot: f.url("b/state/cloud/boot-files"))
        try await b.setPlaces([f.project("p", "b/home")], accountHomes: [claude])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        #expect(!f.exists("b/home/CLAUDE.md") && !f.exists("b/home/.claude/agents"))
        let waiting = try await b.items()
        #expect(waiting.count == 2)
        #expect(waiting.allSatisfy { $0.kind == .waitingFolder && $0.reasons == ["home-folder"] })
    }

    @Test func theSheetIsShownTheExactBytesAcceptWritesAndTheLinesThatMatter() async throws {
        let f = try F(); defer { f.close() }
        let skill = ".claude/skills/deploy/SKILL.md", command = ".claude/commands/status.md"
        let skillText = "---\nname: deploy\nallowed-tools: Bash(*)\n---\nDeploy.\nMore prose.\n"
        let commandText = "Intro\nNow: !`git status`\nEnd\n"
        try f.write("a/app/" + skill, skillText)
        try f.write("a/app/" + command, commandText)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        let lines = try await b.items()
        let skillLine = try #require(lines.first { $0.relative == skill })
        let commandLine = try #require(lines.first { $0.relative == command })
        let shownFound = try await b.review(skillLine.id)
        let shown = try #require(shownFound)
        #expect(shown.bytes == Data(skillText.utf8) && shown.hash == skillLine.hash && shown.reasons == ["header:allowed-tools"])
        let numbers = shown.lines.map { $0.number }
        let texts = shown.lines.map { $0.text }
        #expect(numbers == [1, 2, 3, 4])
        #expect(texts == ["---", "name: deploy", "allowed-tools: Bash(*)", "---"])
        let commandShownFound = try await b.review(commandLine.id)
        let commandShown = try #require(commandShownFound)
        let commandTexts = commandShown.lines.map { $0.text }
        #expect(commandTexts == ["Now: !`git status`"])
        // A newer version replaces the line: the old id shows nothing and accepts nothing.
        try f.write("a/app/" + skill, "---\nname: deploy\nallowed-tools: Read\n---\nDeploy.\n")
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        try await F.apply(b, second.operations, device: f.deviceA)
        let gone = try await b.review(skillLine.id)
        #expect(gone == nil)
        let none = try await b.accept([skillLine.id])
        #expect(none.isEmpty && !f.exists("b/app/" + skill))
        // What the sheet shows for the new line is exactly what accept writes.
        let now = try await b.items()
        let newer = try #require(now.first { $0.relative == skill })
        let newerShownFound = try await b.review(newer.id)
        let newerShown = try #require(newerShownFound)
        let done = try await b.accept([newer.id])
        #expect(done == [newer.id])
        let written = try Data(contentsOf: f.url("b/app/" + skill))
        #expect(written == newerShown.bytes)
        // A line that only informs (waiting for a folder, removed elsewhere) has nothing to review.
        let missing = try await b.review("no-such-line")
        #expect(missing == nil)
    }

    @Test func aFileAppliedByItselfIsListedAndTheVersionItReplacedCanBeRead() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        #expect(f.text("b/app/CLAUDE.md") == "v1\n")
        try f.write("a/app/CLAUDE.md", "v2\n")
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        try await F.apply(b, second.operations, device: f.deviceA)
        #expect(f.text("b/app/CLAUDE.md") == "v2\n")
        let changes = try await b.changedFromOtherDevices()
        #expect(changes.count == 2)
        let newest = try #require(changes.first)
        let oldest = try #require(changes.last)
        #expect(newest.how == "updated" && newest.relative == "CLAUDE.md" && newest.originDevice == f.deviceA)
        #expect(newest.previousHash == BackendCloudBrainMemoryHash.bytes(Data("v1\n".utf8)))
        #expect(oldest.how == "created" && oldest.previousHash == nil)
        let previous = try #require(newest.previousHash)
        let earlier = try await b.earlierVersion(hash: previous)
        #expect(earlier == Data("v1\n".utf8))
        // Only a version some change replaced can be read.
        await #expect(throws: CloudFailure.invalidRequest) {
            _ = try await b.earlierVersion(hash: newest.hash)
        }
        await #expect(throws: CloudFailure.invalidRequest) {
            _ = try await b.earlierVersion(hash: "../../etc/passwd")
        }
    }

    @Test func theEarlierVersionIsPutBackKeepingTheReplacedFileAndNeverOverAnEditMadeSince() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let first = try await F.local(a)
        try await F.apply(b, first.operations, device: f.deviceA)
        try f.write("a/app/CLAUDE.md", "v2\n")
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        try await F.apply(b, second.operations, device: f.deviceA)
        let changes = try await b.changedFromOtherDevices()
        let newest = try #require(changes.first)
        // Edited on this Mac since that change: refused, and the file is left exactly as it is.
        try f.write("b/app/CLAUDE.md", "mine\n")
        let refused = try await b.putBackEarlierVersion(newest)
        #expect(refused == .changedSince)
        #expect(f.text("b/app/CLAUDE.md") == "mine\n")
        // Back to the bytes the change wrote: the earlier version is put back and the replaced file is kept.
        try f.write("b/app/CLAUDE.md", "v2\n")
        let done = try await b.putBackEarlierVersion(newest)
        #expect(done == .putBack)
        #expect(f.text("b/app/CLAUDE.md") == "v1\n")
        let kept = try await b.keptLocal(hash: BackendCloudBrainMemoryHash.bytes(Data("v2\n".utf8)))
        #expect(kept == Data("v2\n".utf8))
        let lines = try await b.items()
        #expect(lines.contains { $0.kind == .replacedLocal && $0.relative == "CLAUDE.md" })
        // It is an ordinary local edit: captured to be sent like any other.
        let sent = try await F.local(b)
        #expect(!sent.operations.isEmpty)
    }
}

final class CloudBootArrivalCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
