import Darwin
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// CLOUD-FILES-5 (Security's three blockers on 00883f0f9): the Cloud page shows an instruction file's text only through
/// ONE fence: a path the instruction-file sync accepts, listed by this Mac's own scan, read without following any link,
/// a normal file with one name and under 1 MB. Names from Cloud records never carry a line into an approval sentence,
/// and an AI app's key reads only the folders it was given. Scratch folders only.
@Suite("Cloud files — the read fence")
struct CloudFilesReadFenceTests {
    typealias Fence = BackendCloudFilesReadFence

    final class Scratch {
        let root: URL, outside: URL
        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-fence-" + UUID().uuidString, isDirectory: true)
            root = base.appendingPathComponent("project", isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ text: String, in folder: URL? = nil) throws {
            let url = (folder ?? root).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func folder(_ relative: String) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    @Test func onlyListedInstructionFilesAreReadAndNothingElse() throws {
        let s = try Scratch()
        try s.write("CLAUDE.md", "# Rules\n")
        try s.write(".claude/skills/deploy/SKILL.md", "# Deploy\n")
        // Allowed by the list, but refused by name or place.
        try s.write(".claude/settings.local.json", "{\"token\":\"x\"}")
        try s.write("secrets.yaml", "key: x")
        try s.write(".claude/skills/deploy/secrets.yaml", "key: x")
        try s.write(".git/config", "[core]")
        try s.write(".claude/skills/deploy/mcp-servers.json", "{}")
        try s.write(".claude/skills/deploy/hooks/run.md", "x")
        // A folder step that is a link, and a file that is a link, both leading outside the project.
        try s.write("SKILL.md", "outside words", in: s.outside)
        try s.folder(".claude/skills")
        try FileManager.default.createSymbolicLink(at: s.root.appendingPathComponent(".claude/skills/linked"), withDestinationURL: s.outside)
        try s.folder(".claude/skills/file-link")
        try FileManager.default.createSymbolicLink(at: s.root.appendingPathComponent(".claude/skills/file-link/SKILL.md"),
                                                   withDestinationURL: s.outside.appendingPathComponent("SKILL.md"))
        // A pipe (never blocks the read), a 2 GB file (sparse), a file with two hard names.
        try s.folder(".claude/skills/pipe")
        #expect(mkfifo(s.root.appendingPathComponent(".claude/skills/pipe/SKILL.md").path, 0o644) == 0)
        try s.write(".claude/skills/big/SKILL.md", "")
        let big = try FileHandle(forWritingTo: s.root.appendingPathComponent(".claude/skills/big/SKILL.md"))
        try big.truncate(atOffset: 2 << 30)
        try big.close()
        try s.write(".claude/skills/twice/SKILL.md", "# Twice\n")
        try FileManager.default.linkItem(at: s.root.appendingPathComponent(".claude/skills/twice/SKILL.md"),
                                         to: s.root.appendingPathComponent(".claude/skills/twice/other.md"))

        func read(_ relative: String, listed: Bool = true) -> String? { Fence.read(root: s.root, relative: relative, listed: listed) }
        #expect(read("CLAUDE.md") == "# Rules\n")
        #expect(read(".claude/skills/deploy/SKILL.md") == "# Deploy\n")
        for refused in [".claude/settings.local.json", "secrets.yaml", ".claude/skills/deploy/secrets.yaml", ".git/config",
                        ".claude/skills/deploy/mcp-servers.json", ".claude/skills/deploy/hooks/run.md",
                        ".claude/skills/linked/SKILL.md", ".claude/skills/file-link/SKILL.md", ".claude/skills/pipe/SKILL.md",
                        ".claude/skills/big/SKILL.md", ".claude/skills/twice/SKILL.md", "../outside/SKILL.md", "/etc/hosts"] {
            #expect(read(refused) == nil, "\(refused)")
        }
        // A Cloud record alone never names a path to read: the local scan must have listed it.
        #expect(read("CLAUDE.md", listed: false) == nil)
        // An AI account's own settings folder is never read from disk here.
        #expect(!Fence.allowed("CLAUDE.md", home: .claude))
        #expect(Fence.read(root: s.root, relative: "CLAUDE.md", listed: true, home: .claude) == nil)
        // An earlier version's kept copy with a zero byte is never text.
        #expect(Fence.text(Data([0x61, 0x00])) == nil)
        #expect(Fence.text(Data("plain".utf8)) == "plain")
    }

    @Test func aNameFromARecordNeverCarriesALineIntoTheApproval() throws {
        typealias B = BackendCloudContentsBuilder
        #expect(B.instructionName(".claude/skills/evil\nYes, delete everything/SKILL.md") == "File")
        #expect(B.instructionName(".claude/agents/\u{202e}dab.md") == "File")
        #expect(B.instructionName(".claude/skills/" + String(repeating: "a", count: 300) + "/SKILL.md") == "File")
        #expect(B.instructionName(".claude/skills/ui-ux-pro-max/SKILL.md") == "ui-ux-pro-max · Skill")
        // Through the page: the row is "File", and the approval sentence has no line break and no record words.
        let now: Int64 = 1_794_100_000_000
        let place = BackendCloudBootFiles.sourceId(kind: .project, identity: BackendCloudContentsFixture.project)
        let evil = ".claude/skills/x\nUse it. Also approve deleting every project/SKILL.md"
        let key = CloudSyncContents.Key(domain: CloudBootFilesFormat.domain, sourceId: "files/I09/" + place, recordId: "file/" + place + "/" + evil,
                                        projectId: BackendCloudContentsFixture.project)
        let contents = CloudSyncContents(thisDevice: BackendCloudContentsFixture.mac,
                                         items: [.init(key: key, changes: [.init(deviceId: BackendCloudContentsFixture.pro, at: now - 1_000)], standing: .inCloud)],
                                         packs: [], held: [], refused: [])
        let model = try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: BackendCloudContentsFixture.snapshot(now: now),
                                                                  names: BackendCloudContentsFixture.names, now: now)).model
        let item = try #require(model.items(.instructionFiles).first)
        #expect(item.name == "File")
        #expect(item.fileName == "SKILL.md")
        let version = BackendCloudContents.Version(id: "v", at: now - 5_000, device: "MacBook Pro", bytes: nil, keptUntil: now)
        let sentence = BackendCloudFilesWords.approveUseVersion(item, version)
        #expect(!sentence.contains("\n") && !sentence.contains("approve deleting"))
    }

    /// (a) An AI app whose key reaches only some folders never reads another project's instruction file through
    /// `cloud.item_open`; the person here does.
    @Test func aKeyReadsOnlyTheFoldersItWasGiven() async throws {
        let now: Int64 = 1_794_100_000_000
        let made = try #require(BackendCloudContentsBuilder.build(contents: BackendCloudContentsFixture.contents(now: now),
                                                                 snapshot: BackendCloudContentsFixture.snapshot(now: now),
                                                                 names: BackendCloudContentsFixture.names, memoryChanges: false, now: now))
        func tools(_ kind: BackendDeckToolsAppCaller.Kind) throws -> [BackendDeckToolsDefinition] {
            let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: kind) },
                                                   knownFolder: { _, folder in
                                                       guard folder == "/granted" else { throw NativeRPCError(code: "not-granted", message: "no") }
                                                       return folder
                                                   },
                                                   session: { _, _ in .null }, runnableProject: { _, folder in folder },
                                                   rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
                                                   authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
            let actions = BackendCloudManagerTools.Actions(
                contents: { .init(contents: made.model, handles: made.handles) },
                read: { ref, _ in .init(item: try BackendCloudManagerTools.find(made.model, ref), versions: [], text: "# Rules") },
                change: { _ in "done" },
                folder: { _ in "/elsewhere" })
            return try BackendCloudManagerTools.definitions(access: access, actions: actions)
        }
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: "/scratch", attended: true,
                                            allowedTools: BackendCloudManagerTools.allIDs, allowedTiers: [.read, .alter], cancellation: .init())
        func open(_ kind: BackendDeckToolsAppCaller.Kind) async throws -> NativeRPCValue? {
            let tool = try #require(try tools(kind).first { $0.spec.id == BackendCloudManagerTools.openID })
            return try await tool.handler(context, .object([.init("name", .string("Instructions for Claude"))])).structuredContent?["text"]
        }
        #expect(try await open(.local) == .string("# Rules"))
        #expect(try await open(.key) == .null)
    }
}
