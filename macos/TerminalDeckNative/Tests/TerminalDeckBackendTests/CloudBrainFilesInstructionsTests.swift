import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud I09 — provider memory, instructions and skills")
struct CloudBrainFilesInstructionsTests {
    typealias F = CloudBrainFilesFixture

    @Test func onlyAllowListedTextTravelsAndLandsInThisMacsOwnFolders() async throws {
        let f = try F(); defer { f.close() }
        let rootId = UUID().uuidString.lowercased()
        let claudeA = f.url("a/claude"), codexA = f.url("a/codex"), projectA = f.url("a/work/app")
        let claudeB = f.url("b/claude"), codexB = f.url("b/codex"), projectB = f.url("b/code/app")
        for folder in [claudeA, codexA, projectA, claudeB, projectB] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let encodedA = NativeTranscriptPaths.encodeProjectPath(projectA.path), encodedB = NativeTranscriptPaths.encodeProjectPath(projectB.path)
        try f.write("a/claude/CLAUDE.md", "global rules\n")
        try f.write("a/claude/skills/review/SKILL.md", "review skill\n")
        try f.write("a/claude/skills/review/icon.png", data: Data([0, 1, 2, 255]))      // binary: blocked, not uploaded
        try f.write("a/claude/projects/\(encodedA)/memory/MEMORY.md", "project memory\n")
        try f.write("a/claude/projects/\(encodedA)/chat.jsonl", "{}\n")                  // a transcript: row I17, not here
        try f.write("a/claude/.credentials.json", "{\"token\":\"fixture\"}")              // sign-in: never read
        try f.write("a/claude/settings.json", "{}")
        try f.write("a/codex/memories/m.md", "codex memory\n")
        try f.write("a/codex/auth.json", "{}")
        try f.write("a/work/app/CLAUDE.md", "project rules\n")
        try f.write("a/work/app/.claude/agents/reviewer.md", "agent\n")
        try f.write("a/work/app/.claude/settings.local.json", "{}")
        try f.write("a/work/app/src/CLAUDE.md", "nested\n")
        let homesA = [BackendCloudBrainProviderHome(provider: "claude", profileId: "default", home: claudeA),
                      BackendCloudBrainProviderHome(provider: "codex", profileId: "default", home: codexA)]
        let a = try BackendCloudBrainInstructions.adapter(homes: homesA, projects: [.init(projectId: "p-app", rootId: rootId, path: projectA)],
                                                          deviceId: f.deviceA, stateRoot: f.url("a/state"),
                                                          resolveHome: { provider, _ in provider == "claude" ? claudeA : codexA }, resolveProject: { _, _ in projectA })
        let inventory = try await a.sourceInventory()
        #expect(inventory.map { $0.items } == [3, 1, 2])
        #expect(!inventory[0].complete && inventory[0].blockedReasons.contains { $0.contains("non-text") })
        #expect(inventory[1].complete && inventory[2].complete)
        let snapshot = try await F.snapshot(a)
        let keys = Set(try snapshot.operations.map { try F.part($0).key })
        #expect(keys.count == 6)
        #expect(!keys.contains { $0.contains("credentials") || $0.contains("settings") || $0.contains("auth.json") || $0.hasSuffix(".jsonl") || $0.contains("/src/") || $0.hasSuffix(".png") })

        // Mac B has the Claude account and the project at another path, but not the Codex account yet.
        let make: @Sendable (Bool) throws -> BackendCloudBrainFiles = { withCodex in
            var homes = [BackendCloudBrainProviderHome(provider: "claude", profileId: "default", home: claudeB)]
            if withCodex { homes.append(.init(provider: "codex", profileId: "default", home: codexB)) }
            return try BackendCloudBrainInstructions.adapter(homes: homes, projects: [.init(projectId: "p-app", rootId: rootId, path: projectB)],
                                                             deviceId: f.deviceB, stateRoot: f.url("b/state"),
                                                             resolveHome: { provider, _ in provider == "claude" ? claudeB : (withCodex ? codexB : nil) },
                                                             resolveProject: { id, root in id == "p-app" && root == rootId ? projectB : nil })
        }
        let b = try make(false)
        _ = try await F.apply(b, snapshot.operations, device: f.deviceA)
        #expect(try f.read("b/claude/CLAUDE.md") == Data("global rules\n".utf8))
        #expect(try f.read("b/claude/skills/review/SKILL.md") == Data("review skill\n".utf8))
        #expect(try f.read("b/claude/projects/\(encodedB)/memory/MEMORY.md") == Data("project memory\n".utf8))
        #expect(!f.exists("b/claude/projects/\(encodedA)"))
        #expect(try f.read("b/code/app/CLAUDE.md") == Data("project rules\n".utf8))
        #expect(try f.read("b/code/app/.claude/agents/reviewer.md") == Data("agent\n".utf8))
        // The Codex memory waits, retained, without creating a provider home.
        #expect(!f.exists("b/codex"))
        let waiting = try await b.readiness()
        #expect(!waiting.verified && waiting.counts.blocked == 1)
        try FileManager.default.createDirectory(at: codexB, withIntermediateDirectories: true)
        let later = try make(true)
        #expect(try await later.reproject() == 1)
        #expect(try f.read("b/codex/memories/m.md") == Data("codex memory\n".utf8))
        #expect(try await later.readiness().verified)
        #expect(try await later.reconcile().journaled == 0)
    }

    @Test func aCloudRecordCannotPlaceAFileOutsideTheAllowList() async throws {
        let f = try F(); defer { f.close() }
        let claudeA = f.url("a/claude"), claudeB = f.url("b/claude")
        try f.write("a/claude/CLAUDE.md", "rules\n")
        try FileManager.default.createDirectory(at: claudeB, withIntermediateDirectories: true)
        let a = try BackendCloudBrainInstructions.adapter(homes: [.init(provider: "claude", profileId: "default", home: claudeA)], projects: [],
                                                          deviceId: f.deviceA, stateRoot: f.url("a/state"), resolveHome: { _, _ in claudeA }, resolveProject: { _, _ in nil })
        let b = try BackendCloudBrainInstructions.adapter(homes: [.init(provider: "claude", profileId: "default", home: claudeB)], projects: [],
                                                          deviceId: f.deviceB, stateRoot: f.url("b/state"), resolveHome: { _, _ in claudeB }, resolveProject: { _, _ in nil })
        let op = try #require(try await F.snapshot(a).operations.first)
        let p = try F.part(op)
        let key = p.key.replacingOccurrences(of: "CLAUDE.md", with: ".credentials.json")
        let forged = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: key, version: p.version, resourceHash: p.resourceHash,
                                          bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: p.data)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(forged))
        let op2 = CloudOperation(v: 1, opId: op.opId, originDevice: op.originDevice, domain: op.domain,
                                 entityId: BackendCloudBrainMemoryHash.uuid(p.storeId + "\n" + key + "\n0"), revision: op.revision, parents: op.parents, kind: .put,
                                 source: .init(sourceId: op.source.sourceId, recordId: key), createdAt: op.createdAt, payload: value,
                                 payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        await #expect(throws: CloudFailure.invalidRequest) { _ = try await b.validateIncoming([op2], files: []) }
        #expect(!f.exists("b/claude/.credentials.json"))
    }
}
