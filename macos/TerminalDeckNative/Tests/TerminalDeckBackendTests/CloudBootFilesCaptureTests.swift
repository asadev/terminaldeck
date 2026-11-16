import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud boot files: capture (this Mac's files become records)")
struct CloudBootFilesCaptureTests {
    typealias F = CloudBootFilesFixture

    @Test func onlyTheListedTextFilesBecomeRecordsKeyedByProjectIdAndRelativePath() async throws {
        let f = try F(); defer { f.close() }
        let travels = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", ".claude/agents/reviewer.md", ".claude/skills/review/SKILL.md",
                       ".claude/skills/review/scripts/check.sh", ".claude/commands/ship.md", ".agents/skills/x/SKILL.md",
                       ".codex/skills/y/SKILL.md", ".gemini/skills/z/SKILL.md"]
        for path in travels { try f.write("a/work/app/" + path, "text of " + path + "\n") }
        let never = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/skills/review/settings.json",
                     ".claude/skills/review/hooks/pre.md", ".claude/skills/review/.env", ".claude/skills/review/node_modules/pkg/index.md",
                     ".claude/agents/credentials.md", ".claude/agent-memory/reviewer/MEMORY.md", "src/CLAUDE.md", "README.md"]
        for path in never { try f.write("a/work/app/" + path, "never " + path + "\n") }
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-app", "a/work/app")])
        let snapshot = try await F.snapshot(a)
        let prefix = F.prefix(project: "p-app")
        #expect(F.keys(snapshot.operations) == Set(travels.map { prefix + $0 }))
        #expect(snapshot.operations.count == travels.count)
        // A lower-case domain of the row's own; the project id travels, the folder never does.
        #expect(CloudBootFilesFormat.domain == "brain/files/i09")
        #expect(snapshot.operations.allSatisfy { $0.domain == CloudBootFilesFormat.domain && $0.projectId == "p-app" && $0.rootId == "primary" })
        for operation in snapshot.operations {
            let part = try F.part(operation)
            let named = [part.key, operation.source.recordId, operation.source.sourceId].joined(separator: "\n")
            #expect(!named.contains(f.base.path) && !named.contains("work/app") && !named.contains("/Users/"))
            #expect(part.key == operation.source.recordId)
            let body = try F.body(operation)
            let expected = "text of " + String(part.key.dropFirst(prefix.count)) + "\n"
            #expect(body == expected)
        }
    }

    @Test func aFolderThisMacHasNotMappedToAProjectIsNotCaptured() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/mapped/CLAUDE.md", "mapped\n")
        try f.write("a/unmapped/CLAUDE.md", "not a project on this Mac\n")
        try f.write("a/unmapped/.claude/skills/s/SKILL.md", "skill\n")
        let before = f.listing("a/unmapped")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p-mapped", "a/mapped")])
        let snapshot = try await F.snapshot(a)
        #expect(F.keys(snapshot.operations) == [F.prefix(project: "p-mapped") + "CLAUDE.md"])
        let bodies = try snapshot.operations.map { try F.body($0) }
        #expect(bodies == ["mapped\n"])
        #expect(f.listing("a/unmapped") == before)
    }

    @Test func changesAreDetectedPerFileAndAHandRemovalNeverTravels() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "one\n")
        try f.write("a/app/.claude/commands/a.md", "a\n")
        try f.write("a/app/.claude/commands/b.md", "b\n")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let prefix = F.prefix(project: "p")
        let first = try await F.local(a)
        #expect(F.keys(first.operations) == [prefix + "CLAUDE.md", prefix + ".claude/commands/a.md", prefix + ".claude/commands/b.md"])
        // One file edited: one record, a successor of that file's earlier version.
        try f.write("a/app/.claude/commands/b.md", "b, changed\n")
        try await a.refresh()
        let second = try await F.local(a, after: first.cursor)
        #expect(second.operations.count == 1)
        let edited = try #require(second.operations.first)
        #expect(edited.source.recordId == prefix + ".claude/commands/b.md" && edited.kind == .put && edited.parents.count == 1)
        let editedBody = try F.body(edited)
        #expect(editedBody == "b, changed\n")
        // Nothing changed: nothing is recorded.
        try await a.refresh()
        let third = try await F.local(a, after: second.cursor)
        #expect(third.operations.isEmpty)
        // A file missing at one look is not yet a removal (an editor may be rewriting it).
        try FileManager.default.removeItem(at: f.url("a/app/.claude/commands/a.md"))
        try await a.refresh()
        let once = try await F.local(a, after: second.cursor)
        #expect(once.operations.isEmpty)
        try await a.refresh()
        let removed = try await F.local(a, after: second.cursor)
        #expect(removed.operations.isEmpty)
        // Default witness cannot know: by hand, never a travelling removal (new timed cases live in BootFilesDeleteRuleTests).
        #expect(try await a.binGroups().isEmpty)
    }

    @Test func globalFilesAreKeyedByTheAccountHomesIdentityAndAProvidersMemoryChatsSettingsAndSignInAreNeverOpened() async throws {
        let f = try F(); defer { f.close() }
        let travels = ["a/claude/CLAUDE.md", "a/claude/skills/review/SKILL.md", "a/claude/agents/helper.md", "a/claude/commands/go.md",
                       "a/codex/AGENTS.md", "a/codex/skills/build/SKILL.md", "a/gemini/GEMINI.md", "a/gemini/skills/g/SKILL.md"]
        for path in travels { try f.write(path, "global " + path + "\n") }
        let never = ["a/claude/settings.json", "a/claude/.credentials.json", "a/claude/.claude.json", "a/claude/history.jsonl",
                     "a/claude/projects/-Users-x-app/memory/MEMORY.md", "a/claude/projects/-Users-x-app/chat.jsonl",
                     "a/codex/skills/.system/own/SKILL.md", "a/codex/memories/m.md", "a/codex/sessions/2026/s.jsonl", "a/codex/auth.json", "a/codex/config.toml",
                     "a/gemini/tmp/abc/chats/session-1.json", "a/gemini/oauth_creds.json", "a/gemini/settings.json"]
        for path in never { try f.write(path, "never " + path + "\n") }
        // Sealed: opening any of these would fail and show as "could not be read". The walk must not even try.
        let sealed = ["a/claude/projects", "a/codex/memories", "a/codex/sessions", "a/gemini/tmp", "a/claude/settings.json", "a/claude/.credentials.json",
                      "a/claude/.claude.json", "a/claude/history.jsonl", "a/codex/auth.json", "a/codex/config.toml", "a/gemini/oauth_creds.json",
                      "a/gemini/settings.json"]
        try f.seal(sealed)
        defer { f.unseal(sealed) }
        let a = try await f.mac("a", device: f.deviceA,
                                places: [f.home(.claude, "a/claude"), f.home(.codex, "a/codex"), f.home(.gemini, "a/gemini")])
        let snapshot = try await F.snapshot(a)
        let claude = F.prefix(home: .claude), codex = F.prefix(home: .codex), gemini = F.prefix(home: .gemini)
        let expected: Set<String> = [claude + "CLAUDE.md", claude + "skills/review/SKILL.md", claude + "agents/helper.md", claude + "commands/go.md",
                                     codex + "AGENTS.md", codex + "skills/build/SKILL.md", gemini + "GEMINI.md", gemini + "skills/g/SKILL.md"]
        #expect(F.keys(snapshot.operations) == expected)
        #expect(snapshot.operations.allSatisfy { $0.projectId == nil })
        let bodies = try snapshot.operations.map { try F.body($0) }
        #expect(bodies.allSatisfy { $0.hasPrefix("global ") })
        // Complete and nothing unreadable: the sealed folders and files were never opened.
        let inventory = try await a.sourceInventory()
        #expect(inventory.count == 3)
        #expect(inventory.allSatisfy { $0.complete && $0.blockedReasons.isEmpty })
        #expect(inventory.map { $0.items } == [4, 2, 2])
    }

    @Test func linksASecondHardNameBinaryOversizeAndHiddenFilesStayOnThisMac() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/.claude/skills/s/SKILL.md", "ok\n")
        try f.write("a/app/.claude/skills/s/icon.png", data: Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02]))
        try f.write("a/app/.claude/skills/s/big.md", data: Data(repeating: 0x61, count: CloudBootFilesFormat.maximumFileBytes + 1))
        try f.write("a/app/.claude/skills/s/.hidden.md", "hidden\n")
        try f.write("a/outside/secret.md", "outside the project\n")
        try FileManager.default.createSymbolicLink(at: f.url("a/app/.claude/skills/s/linked.md"), withDestinationURL: f.url("a/outside/secret.md"))
        try FileManager.default.createSymbolicLink(at: f.url("a/app/.claude/commands"), withDestinationURL: f.url("a/outside"))
        try FileManager.default.linkItem(at: f.url("a/outside/secret.md"), to: f.url("a/app/.claude/skills/s/hard.md"))
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let snapshot = try await F.snapshot(a)
        #expect(F.keys(snapshot.operations) == [F.prefix(project: "p") + ".claude/skills/s/SKILL.md"])
        let bodies = try snapshot.operations.map { try F.body($0) }
        #expect(bodies == ["ok\n"])
        // Nothing of this Mac's copy holds the outside file's text either.
        let copy = f.listing("a/cloud/boot-files/copy")
        let leaked = copy.filter { $0.hasSuffix("secret.md") || $0.hasSuffix("linked.md") || $0.hasSuffix("hard.md") || $0.hasSuffix(".png") }
        #expect(leaked.isEmpty)
        // A file at exactly the cap travels.
        try f.write("a/app/.claude/skills/s/full.md", data: Data(repeating: 0x61, count: CloudBootFilesFormat.maximumFileBytes))
        try await a.refresh()
        let again = try await F.snapshot(a)
        #expect(F.keys(again.operations) == [F.prefix(project: "p") + ".claude/skills/s/SKILL.md", F.prefix(project: "p") + ".claude/skills/s/full.md"])
    }
}
