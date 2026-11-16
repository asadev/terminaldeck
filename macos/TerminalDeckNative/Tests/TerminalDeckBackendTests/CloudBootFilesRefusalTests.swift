import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud boot files: every refusal of the apply half")
struct CloudBootFilesRefusalTests {
    typealias F = CloudBootFilesFixture

    /// Mac B with one project folder that already holds one skill from Mac A.
    func synced(_ f: F) async throws -> BackendCloudBootFiles {
        try f.write("a/app/.claude/skills/review/SKILL.md", "review\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        return b
    }

    @Test func aRecordThatIsNotABootFileIsRefusedBeforeAnythingIsKeptOrWritten() async throws {
        let f = try F(); defer { f.close() }
        let b = try await synced(f)
        #expect(f.text("b/app/.claude/skills/review/SKILL.md") == "review\n")
        let folder = f.listing("b/app"), copy = f.listing("b/cloud/boot-files/copy"), kept = f.listing("b/cloud/boot-files/engine/retained")
        let project = F.prefix(project: "p"), home = F.prefix(home: .claude)
        let bad: [(String, String)] = [
            // A way out of the folder.
            (project + ".claude/skills/../../../outside.md", "plain path"), (project + "../outside.md", "plain path"),
            (project + "/etc/passwd", "plain path"), (project + ".claude/skills/x/..", "plain path"),
            // Settings, hooks, MCP and sign-in files.
            (project + ".claude/settings.json", "not a boot file"), (project + ".claude/settings.local.json", "not a boot file"),
            (project + ".mcp.json", "not a boot file"), (project + ".claude/skills/review/settings.json", "never travel"),
            (project + ".claude/skills/review/hooks/pre.md", "never travel"), (project + ".claude/agents/hooks.json", "never travel"),
            (project + ".claude/skills/review/mcp.json", "never travel"), (project + ".claude/skills/review/auth.json", "never travel"),
            (project + ".claude/skills/review/.env", "hidden"),
            // A provider's own memory, chats, settings and sign-in.
            (home + "projects/-Users-x-app/memory/MEMORY.md", "not a boot file"), (home + "projects/-Users-x-app/chat.jsonl", "not a boot file"),
            (home + ".credentials.json", "not a boot file"), (home + "settings.json", "not a boot file"),
            // Not a key of this row at all.
            ("file/idle/idle", "not a boot file"), ("file/project/NOT-A-TOKEN/CLAUDE.md", "not a boot file"), ("notes/x.md", "not a boot file"),
            ("file/home/project/" + BackendCloudBrainFilesNames.token("x") + "/CLAUDE.md", "not a boot file")
        ]
        for (key, why) in bad {
            let operation = try F.forged(key: key, text: "planted\n", device: f.deviceA)
            let refusal = await F.refusal(b, [operation])
            #expect(refusal?.operationIds == [operation.opId], "\(key)")
            #expect(refusal?.reason.contains(why) == true, "\(key)")
        }
        // Nothing was written, nothing entered this Mac's copy, and the engine kept no bytes of any of them.
        #expect(f.listing("b/app") == folder)
        #expect(f.listing("b/cloud/boot-files/copy") == copy)
        #expect(f.listing("b/cloud/boot-files/engine/retained") == kept)
        let lines = try await b.items()
        #expect(lines.isEmpty)
    }

    @Test func oneBadRecordIsNamedAndTheGoodOnesBesideItAreNotBlamed() async throws {
        let f = try F(); defer { f.close() }
        let b = try await synced(f)
        let project = F.prefix(project: "p")
        let good = try F.forged(key: project + ".claude/commands/ok.md", text: "fine\n", device: f.deviceA)
        let bad = try F.forged(key: project + ".claude/settings.json", text: "{}", device: f.deviceA)
        let refusal = await F.refusal(b, [good, bad])
        #expect(refusal?.operationIds == [bad.opId])
        // Applied alone (as the sync core does after parking the bad one), the good record is written.
        try await F.apply(b, [good], device: f.deviceA)
        #expect(f.text("b/app/.claude/commands/ok.md") == "fine\n")
        #expect(!f.exists("b/app/.claude/settings.json"))
    }

    @Test func anOverSizeOrBinaryRecordAndARecordOfAnotherRowAreRefused() async throws {
        let f = try F(); defer { f.close() }
        let b = try await synced(f)
        let folder = f.listing("b/app"), project = F.prefix(project: "p")
        // The record says the file is larger than the cap (its first part is all one record carries).
        let big = try F.forged(key: project + ".claude/skills/review/big.md", data: Data(repeating: 0x61, count: CloudBrainFilesFormat.partBytes),
                               declaredBytes: CloudBootFilesFormat.maximumFileBytes + 1, device: f.deviceA)
        let bigRefusal = await F.refusal(b, [big])
        #expect(bigRefusal?.reason.contains("1 MB") == true)
        let binary = try F.forged(key: project + ".claude/skills/review/blob.md", data: Data([0x41, 0x00, 0x42]), device: f.deviceA)
        let binaryRefusal = await F.refusal(b, [binary])
        #expect(binaryRefusal?.reason.contains("not a text") == true)
        let foreign = try F.forged(key: project + "CLAUDE.md", data: Data("x\n".utf8), domain: "brain/files/i08", device: f.deviceA)
        let foreignRefusal = await F.refusal(b, [foreign])
        #expect(foreignRefusal?.operationIds == [foreign.opId])
        // A record whose bytes do not match its own fingerprint is refused by the engine, as a refusal (not a retry for ever).
        let honest = try F.forged(key: project + "CLAUDE.md", text: "rules\n", device: f.deviceA)
        let part = try F.part(honest)
        let lying = CloudBrainMemoryPart(storeId: part.storeId, inventoryRow: part.inventoryRow, key: part.key, version: part.version,
                                         resourceHash: String(repeating: "0", count: 64), bytes: part.bytes, index: 0, count: 1, parents: [], data: part.data)
        let encoded = try CloudWire.canonical(lying)
        let value = try JSONDecoder().decode(CloudValue.self, from: encoded)
        let payload = try CloudWire.canonical(value)
        let tampered = CloudOperation(v: 1, opId: honest.opId, originDevice: honest.originDevice, domain: honest.domain, entityId: honest.entityId,
                                      revision: honest.revision, parents: [], kind: .put, source: honest.source, createdAt: honest.createdAt,
                                      payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(payload))
        var refused = false
        do {
            let prepared = try await b.validateIncoming([tampered], files: [])
            _ = try await b.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1)))
        } catch is CloudRecordRefusal { refused = true }
        #expect(refused)
        #expect(f.listing("b/app") == folder)
    }

    @Test func aNameThatDiffersOnlyInLetterCaseFromAFileThisMacHoldsIsRefused() async throws {
        let f = try F(); defer { f.close() }
        let b = try await synced(f)
        let folder = f.listing("b/app"), project = F.prefix(project: "p")
        for key in [project + ".claude/skills/Review/SKILL.md", project + ".claude/skills/review/skill.md"] {
            let operation = try F.forged(key: key, text: "twin\n", device: f.deviceA)
            let refusal = await F.refusal(b, [operation])
            #expect(refusal?.operationIds == [operation.opId], "\(key)")
            #expect(refusal?.reason.contains("letter case") == true, "\(key)")
        }
        #expect(f.text("b/app/.claude/skills/review/SKILL.md") == "review\n")
        #expect(f.listing("b/app") == folder)
    }

    @Test func aLinkOnTheWayOrUnderTheNameStopsTheWriteAndNothingGoesThroughIt() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        try f.write("a/app/.claude/skills/review/SKILL.md", "review\n")
        try f.write("a/app/.claude/commands/ship.md", "Ship.\n")
        // On B the skills folder is a link to a folder outside the project, and CLAUDE.md is a link to a file outside.
        try f.folder("b/app/.claude")
        try f.folder("b/outside/skills")
        try f.write("b/outside/target.md", "outside\n")
        try FileManager.default.createSymbolicLink(at: f.url("b/app/.claude/skills"), withDestinationURL: f.url("b/outside/skills"))
        try FileManager.default.createSymbolicLink(at: f.url("b/app/CLAUDE.md"), withDestinationURL: f.url("b/outside/target.md"))
        let outside = f.listing("b/outside")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        // Capture did not read through the links either.
        let own = try await F.local(b)
        #expect(own.operations.isEmpty)
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        // The one file with a clean way in is written.
        #expect(f.text("b/app/.claude/commands/ship.md") == "Ship.\n")
        // Nothing went through either link.
        #expect(f.listing("b/outside") == outside)
        #expect(f.text("b/outside/target.md") == "outside\n")
        var lines = try await b.items()
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.kind == .blocked && $0.reasons == ["link"] && !$0.canAccept })
        // The folder link is removed: the next look writes that file. The other stays stopped.
        try FileManager.default.removeItem(at: f.url("b/app/.claude/skills"))
        try await b.refresh()
        #expect(f.text("b/app/.claude/skills/review/SKILL.md") == "review\n")
        #expect(f.listing("b/outside") == outside)
        lines = try await b.items()
        #expect(lines.count == 1)
        let left = try #require(lines.first)
        #expect(left.relative == "CLAUDE.md" && left.kind == .blocked)
    }

    @Test func aTwinFolderOrAFolderUnderTheFilesNameStopsTheWrite() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/.claude/skills/review/SKILL.md", "review\n")
        try f.write("a/app/AGENTS.md", "agents\n")
        // On B: a folder `Skills` (capital S) with a skill of its own, and a FOLDER named AGENTS.md.
        try f.write("b/app/.claude/Skills/mine/SKILL.md", "mine\n")
        try f.folder("b/app/AGENTS.md")
        let before = f.listing("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        #expect(f.listing("b/app") == before)
        #expect(f.text("b/app/.claude/Skills/mine/SKILL.md") == "mine\n")
        let lines = try await b.items()
        #expect(lines.count == 2)
        var why: [String: [String]] = [:]
        for line in lines where line.kind == .blocked { why[line.relative] = line.reasons }
        #expect(why[".claude/skills/review/SKILL.md"] == ["twin"])
        #expect(why["AGENTS.md"] == ["in-the-way"])
    }
}
