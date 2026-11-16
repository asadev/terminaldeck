import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// CLOUD-FILES-4 (look at his Mac mini, 14 Nov): the Cloud page on what his real Macs hold. A replaced note with another
/// title, a note put away with nothing that replaced it, instruction files at their real places (many with the same file
/// name), two cards of Hoot, the memory's own index records, a job's desk topic and seats' "Open items".
@Suite("Cloud files — his real data")
struct CloudFilesRealDataTests {
    typealias F = BackendCloudContentsFixture
    typealias R = BackendCloudContentsFixture.Real
    let now: Int64 = 1_794_100_000_000
    let hour: Int64 = 3_600_000

    func built(counts: BackendCloudPageCounts? = nil) throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        let fixture = F.realData(now: now)
        return try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: fixture.names,
                                                             counts: counts, memoryChanges: false, now: now))
    }

    // 1. A replaced note lives only inside the note that replaced it, with ITS OWN title and the time its text was
    // written; a put-away note with nothing that replaced it is not a row; the count follows.
    @Test func aReplacedNoteIsAnEarlierVersionWithItsOwnTitleAndDate() throws {
        let model = try built().model
        let memory = model.items(.memory)
        let defect = try #require(memory.first { $0.name == R.defectTitle })
        #expect(memory.filter { $0.name == R.defectTitle }.count == 1)
        #expect(!memory.contains { $0.name == R.defectOldTitle }, "the replaced note is never a row of its own")
        #expect(!memory.contains { $0.name == "A shelved thought" }, "put away with nothing that replaced it: not a note in use")
        #expect(!memory.contains { $0.state == .archived })
        #expect(!memory.contains { NativeRowState.said($0) == "Put away" })
        // Both copies of the same earlier text (this Mac's and the other Mac's "-2") are ONE earlier version.
        #expect(defect.versions.count == 1)
        let earlier = try #require(defect.versions.first)
        #expect(earlier.title == R.defectOldTitle)
        #expect(BackendCloudFilesWords.versionTitle(earlier) == "Earlier: " + R.defectOldTitle)
        #expect(earlier.at == now - 3 * hour, "when its text was written, never when it was replaced")
        // A reason with its why ("superseded: …") is still a replacement.
        let facts = F.realData(now: now).names.noteFacts
        let placed = BackendCloudNoteIdentity.resolve(paths: [], facts: facts)
        #expect(placed[R.defectOldTwin]?.role == .version && placed[R.defectOldTwin]?.key == R.defect)
        #expect(placed[R.shelved]?.role == .history)
        #expect(BackendCloudNoteIdentity.reasonWord("superseded: Note 13 corrects note 12") == "superseded")
        #expect(BackendCloudNoteIdentity.reasonWord("done: answered") == "done")
        // The count: Plan, the hand-off and the defect note (never the replaced copies, the shelved note or the index).
        let notes = BackendCloudNoteIdentity.itemCount(facts)
        #expect(notes == 3)
        let counted = try built(counts: BackendCloudPageCounts(here: [.notes: notes])).model
        #expect(counted.counts[.memory] == notes)
        // The note in use keeps no version with the same title (a conflict copy of the same note says no title).
        let plan = try #require(memory.first { $0.name == "Plan for the launch" })
        #expect(plan.versions.allSatisfy { $0.title == nil })
    }

    // 2 + 3. Instruction files: the path inside the project (the record's "project/<token>/" start left out) and a name
    // that says what each file is; never two identical rows.
    @Test func instructionFilesAreNamedByWhatTheyAreAndFoundInTheirFolder() throws {
        let (model, handles) = try built()
        let files = model.items(.instructionFiles)
        let names = Set(files.map(\.name))
        #expect(names.isSuperset(of: ["Instructions for Codex", "Instructions for Gemini", "ui-ux-pro-max · Skill", "deep-research · Skill",
                                      "deep-research · Codex skill", "Decker · Agent", "critic · Journal", "scribe · Journal", "Decker · Journal",
                                      "catchup · Command"]))
        #expect(!files.contains { $0.name.hasSuffix(".md") }, "no row is a bare file name")
        for item in files {
            let relative = try #require(handles[item.id]?.relative)
            #expect(!relative.hasPrefix("project/") && !relative.hasPrefix("home/"), "\(relative)")
        }
        let codex = try #require(files.first { $0.name == "Instructions for Codex" })
        #expect(handles[codex.id]?.relative == "AGENTS.md")
        #expect(codex.fileName == "AGENTS.md")
        #expect(codex.canOpen)
        // The path rule itself.
        let token = R.place
        #expect(BackendCloudContentsBuilder.bootRelative(token + "/CLAUDE.md") == "CLAUDE.md")
        #expect(BackendCloudContentsBuilder.bootRelative(token + "/.claude/agents/critic/journal.md") == ".claude/agents/critic/journal.md")
        let home = BackendCloudBootFiles.sourceId(kind: .claude, identity: "personal")
        #expect(BackendCloudContentsBuilder.bootRelative(home + "/skills/x/SKILL.md") == "skills/x/SKILL.md")
        #expect(BackendCloudContentsBuilder.bootRelative("CLAUDE.md") == "CLAUDE.md")
        #expect(BackendCloudContentsBuilder.instructionName("skills/x/SKILL.md", home: .claude) == "x · Skill")
        #expect(BackendCloudContentsBuilder.instructionName("CLAUDE.md") == "Instructions for Claude")
        #expect(BackendCloudContentsBuilder.instructionName("macos/CLAUDE.md") == "Instructions for Claude · macos")
        #expect(BackendCloudContentsBuilder.instructionName(".claude/agents/_retired/sheet-scout.md") == "sheet-scout · Retired agent")
        // CLOUD-FILES-6: a known agent by its real name, any other by the file's own name; a file inside a skill.
        #expect(BackendCloudContentsBuilder.instructionName(".claude/agents/ai-link.md") == "ai-link · Agent")
        #expect(BackendCloudContentsBuilder.instructionName(".claude/agents/ai-link.md", agents: ["ai-link": "AI Link"]) == "AI Link · Agent")
        #expect(BackendCloudContentsBuilder.instructionName(".claude/skills/meta-ground-rules/autonomy.md") == "meta-ground-rules · Skill · autonomy")
        #expect(BackendCloudContentsBuilder.instructionName(".agents/skills/meta-ground-rules/autonomy.md") == "meta-ground-rules · Codex skill · autonomy")
        #expect(BackendCloudContentsBuilder.instructionName("docs/notes.md") == "docs/notes.md", "no rule: the short path inside the project")
        try expectNoTwoIdenticalRows(model)
    }

    // 4. Hoot's own card and the card every new Hoot starts from are told apart.
    @Test func hootsTwoCardsAreToldApart() throws {
        let memory = try built().model.items(.memory)
        #expect(memory.filter { $0.name == "Card · Hoot" }.count == 1)
        #expect(memory.contains { $0.name == "Default card · Hoot" })
    }

    // 5. The memory's own index and list records are never listed or counted; a desk topic and seats' open items read
    // as things.
    @Test func internalFilesAreNeverListed() throws {
        let model = try built().model
        let memory = model.items(.memory)
        for hidden in ["Notes", "Topics", "Memory file list", "Handoffs", "Memory index", "Rewinds"] {
            #expect(!memory.contains { $0.name == hidden }, "\(hidden)")
        }
        #expect(!memory.contains { $0.name.lowercased() == "deck dev" || $0.name == "Imatch" })
        #expect(memory.contains { $0.name == "Desk · Deck Dev" })
        // CLOUD-FILES-6: a desk named after its project's folder reads as the registered project.
        #expect(memory.contains { $0.name == "Desk · CRM" } && !memory.contains { $0.name.contains("ClaudeCRM") })
        // The diary is ONE row that says what it is; the memory's questions are said plainly.
        let diary = try #require(memory.first { $0.name == "Diary" })
        #expect(diary.entries == 3 && diary.about?.isEmpty == false && !diary.canOpen)
        #expect(memory.filter { $0.name == "Diary" }.count == 1)
        #expect(memory.contains { $0.name == "Questions for you" && $0.about != nil })
        #expect(BackendCloudContentsWords.topicTitle("Desk snapshot: iMatch Backend (hand 1)") == "Desk · iMatch Backend")
        #expect(BackendCloudContentsWords.topicTitle("New chat-first iOS app (hand 1)") == "New chat-first iOS app")
        let openItems = memory.filter { $0.name == "Open items" }
        #expect(openItems.count == 2)
        #expect(Set(openItems.compactMap(\.place)) == ["Terminal Deck · release", "Terminal Deck · reviewer"]) // the folder's own name
        #expect(BackendCloudNoteIdentity.isInternal(R.memoryIndex) && BackendCloudNoteIdentity.isInternal(R.memoryIndexCopy))
        #expect(!BackendCloudNoteIdentity.isInternal(R.defect))
        try expectNoTwoIdenticalRows(model)
    }

    // 6 (the words under the row): a long title is kept whole (the row wraps it, the details show all of it).
    @Test func aLongTitleIsKeptWhole() throws {
        let long = String(repeating: "A decision about the pricing page ", count: 5).trimmingCharacters(in: .whitespaces)
        #expect(long.count > 120)
        #expect(BackendCloudContentsWords.noteName("notes/x.md", titles: ["notes/x.md": long]) == long)
    }

    // Never two identical rows: two of one kind with the same name and place get the folder that differs.
    @Test func keepApartAddsTheFolderThatDiffers() throws {
        func item(_ id: String) -> BackendCloudContents.Item {
            .init(id: id, kind: .memory, name: "Open items", place: "Terminal Deck", changedBy: "Studio Mac", changedAt: 1, presence: [], onDevices: [],
                  history: [], bytes: nil, entries: nil, note: nil, isText: true)
        }
        var items = [item("a"), item("b")]
        let handles: [String: BackendCloudContentsHandle] = [
            "a": .init(domain: "brain/memory/i01", projectId: nil, relative: "projects/p/roles/release/topics/open-items.md", home: nil),
            "b": .init(domain: "brain/memory/i01", projectId: nil, relative: "projects/p/roles/tester/topics/open-items.md", home: nil),
        ]
        BackendCloudContentsBuilder.keepApart(&items, handles: handles)
        #expect(items.map(\.place) == ["Terminal Deck · release", "Terminal Deck · tester"])
    }

    func expectNoTwoIdenticalRows(_ model: BackendCloudContents) throws {
        for kind in model.kinds {
            let rows = model.items(kind).map { $0.name + "|" + ($0.place ?? "") }
            #expect(rows.count == Set(rows).count, "\(kind): \(rows)")
        }
    }
}

/// The row's one state as the page says it (the same rule as `NativeCloudContentsRow.presence`, kept here so the
/// backend test needs no window).
enum NativeRowState {
    static func said(_ item: BackendCloudContents.Item) -> String {
        item.elsewhere ?? BackendCloudFilesWords.state(item.state) ?? BackendCloudContentsWords.presenceLine(item.presence)
    }
}

/// CLOUD-FILES-7: the desk title rule in the memory store's own read, on a scratch store (job "Deck Dev" with the title
/// "Deck dev" read as "Deck dev" on his Macs: the match was letter-case exact).
@Suite("Cloud files — desk titles from the store")
struct CloudFilesDeskTitleStoreTests {
    @Test func everyDeskReadsAsItsJobWhateverTheLetterCase() async throws {
        let f = try CloudBrainMemoryFixture()
        defer { Task { await f.close() } }
        func topic(_ id: String, title: String, job: String?) -> String {
            "---\nid: \(id)\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntitle: \(title)\n" + (job.map { "job: \($0)\nhand: 1\n" } ?? "") + "---\n# \(title)\nWork.\n"
        }
        try f.write("hoot/topics/deck-dev.md", topic("deck-dev", title: "Deck dev", job: "Deck Dev"))
        try f.write("hoot/topics/imatch.md", topic("imatch", title: "iMatch", job: "iMatch"))
        try f.write("hoot/topics/claudecrm.md", topic("claudecrm", title: "Desk snapshot: ClaudeCRM (hand 1)", job: "ClaudeCRM"))
        try f.write("hoot/topics/meta-campaign.md", topic("meta-campaign", title: "Palm Springs Meta campaign", job: "Meta Campaign"))
        try f.write("hoot/topics/open-items.md", topic("open-items", title: "Open items", job: nil))
        _ = try await f.store.reindex()
        let titles = try await f.store.cloudPageRead().titles
        #expect(titles["hoot/topics/deck-dev.md"] == "Desk snapshot: Deck Dev", "the job's own spelling")
        #expect(titles["hoot/topics/imatch.md"] == "Desk snapshot: iMatch")
        #expect(titles["hoot/topics/claudecrm.md"] == "Desk snapshot: ClaudeCRM")
        #expect(titles["hoot/topics/meta-campaign.md"] == "Palm Springs Meta campaign", "a desk with its own title keeps it")
        #expect(titles["hoot/topics/open-items.md"] == "Open items")
        // And on the page: every desk row reads "Desk · <job>".
        for path in ["hoot/topics/deck-dev.md", "hoot/topics/imatch.md", "hoot/topics/claudecrm.md"] {
            #expect(BackendCloudContentsWords.noteName(path, titles: titles)?.hasPrefix("Desk · ") == true, "\(path)")
        }
        #expect(BackendCloudContentsWords.noteName("hoot/topics/deck-dev.md", titles: titles) == "Desk · Deck Dev")
    }
}
