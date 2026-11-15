import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane L4, slice 1 (owner, 14 Nov: "a proper file manager"): one row per thing, its earlier versions inside it, the
/// Bin, the counts, the words and the tools' approval lines. Fixtures and scratch folders only.
@Suite("Cloud files — one row per thing, versions, Bin, tools")
struct CloudFilesTests {
    typealias F = BackendCloudContentsFixture
    let now: Int64 = 1_794_100_000_000
    let hour: Int64 = 3_600_000

    /// `changes`: the switch for changes to memory notes (off in the app until removals travel; on to test that side).
    func built(counts: BackendCloudPageCounts? = nil, changes: Bool = true, deleted: Set<String> = [])
        throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        let fixture = F.fileManager(now: now)
        var names = fixture.names
        names.deletedHere = deleted
        return try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names, counts: counts,
                                                             memoryChanges: changes, now: now))
    }

    // 1. A note with three replaced copies is ONE row with three earlier versions, newest first, by Mac name. One rule
    // phase 2: with changes offered, those versions are the memory keeper's kept texts (the fixture's `memoryKept`).
    @Test func aNoteWithThreeReplacedCopiesIsOneRowWithThreeVersions() throws {
        let model = try built().model
        let plans = model.items(.memory).filter { $0.name == "Plan for the launch" }
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.versions.count == 3)
        #expect(plan.versions.map(\.at) == plan.versions.map(\.at).sorted(by: >))
        #expect(plan.versions.map(\.device) == ["Studio Mac", "MacBook Pro", "Studio Mac"])
        #expect(plan.versions.allSatisfy { $0.deletable && !$0.different })
        #expect(plan.state == .live && plan.canRemove && plan.canOpen)
        // Its history still has every change (the old place too).
        #expect(plan.history.count == 5)
    }

    // 2. Why the unmarked twins existed: an archived note's old place stays listed (its move sent no removal). It is
    // the same note (its own record's former place), never a row.
    @Test func theOldPlaceOfAMovedNoteIsNeverARow() throws {
        let fixture = F.fileManager(now: now)
        let placed = BackendCloudNoteIdentity.resolve(paths: [F.Files.oldPlace], facts: fixture.names.noteFacts, newest: [F.Files.oldPlace: now - 30 * hour])
        #expect(placed[F.Files.oldPlace]?.role == .history)
        #expect(placed[F.Files.oldPlace]?.key == F.Files.plan)
        #expect(try built().model.items(.memory).filter { $0.name.lowercased().hasPrefix("plan for the launch") }.count == 1)
        // Two notes that truly are two (same title, different notes) stay two rows: told apart by their place.
        let twins = BackendCloudNoteIdentity.resolve(paths: [], facts: [
            "hoot/notes/a.md": .init(path: "hoot/notes/a.md", id: "n-a", changedAt: 1),
            "roles/rita/notes/a.md": .init(path: "roles/rita/notes/a.md", id: "n-b", changedAt: 2),
        ])
        #expect(twins.values.filter { $0.role == .item }.count == 2)
    }

    // B1. A conflict copy is another Mac's text, not an old version: shown inside its note, never counted, an earlier
    // version only when older than the note, and never deleted by Clean up when it is newer.
    @Test func aConflictCopyIsNotAnOldVersion() throws {
        // Read side (changes waiting): the copy is shown inside its note as another Mac's text.
        let made = try built(changes: false)
        let handoff = try #require(made.model.items(.memory).first { $0.name == "Hand-off to design" })
        #expect(made.model.items(.memory).filter { $0.name == "Hand-off to design" }.count == 1)
        let copy = try #require(handoff.versions.first)
        #expect(copy.different && !copy.deletable) // the copy (2 h ago) is newer than the note (3 h ago)
        #expect(BackendCloudFilesWords.version(copy).hasPrefix("Different text from MacBook Pro · "))
        // One rule phase 2: Clean up counts the keeper's kept texts only (the store's own number), never a file copy.
        let changing = try built()
        #expect(changing.model.versionsToClean == 3)
        #expect(changing.model.items(.memory).first { $0.name == "Hand-off to design" }?.versions.isEmpty == true)
        // Older than its note: an earlier version. Its note gone: it is the note (never an orphan version).
        func one(_ copyAt: Int64, noteHere: Bool) -> BackendCloudNoteIdentity.Placement? {
            var facts: [String: BackendCloudNoteFacts] = [F.Files.sibling: .init(path: F.Files.sibling, id: "n-copy", changedAt: copyAt)]
            if noteHere { facts[F.Files.handoff] = .init(path: F.Files.handoff, id: "n-handoff", changedAt: now) }
            return BackendCloudNoteIdentity.resolve(paths: [], facts: facts)[F.Files.sibling]
        }
        #expect(one(now - hour, noteHere: true)?.role == .version)
        #expect(one(now + hour, noteHere: true)?.role == .different)
        #expect(one(now, noteHere: false) == .init(key: F.Files.sibling, role: .item, state: .live))
        // A card's conflict copy under archive/cloud-conflicts follows the same rule.
        let card = "archive/cloud-conflicts/store-1/abc123/roles/decker/card.md"
        let cardFacts: [String: BackendCloudNoteFacts] = ["roles/decker/card.md": .init(path: "roles/decker/card.md", id: "c", changedAt: now)]
        #expect(BackendCloudNoteIdentity.resolve(paths: [card], facts: cardFacts, newest: [card: now + hour])[card]?.role == .different)
        #expect(BackendCloudNoteIdentity.itemCount([F.Files.sibling: .init(path: F.Files.sibling, id: "n", changedAt: now),
                                                    F.Files.handoff: .init(path: F.Files.handoff, id: "m", changedAt: now - hour)]) == 1)
    }

    // B2. No ghost rows after Empty Bin / Clean up (one rule phase 2): the Cloud's records stay; the places this Mac's
    // Bin held are history (`cloudFilesDeleted`), the keeper is empty, and both pages say the same number.
    @Test func noGhostRowsAfterCleanUpOrEmptyBin() throws {
        let before = try built()
        let fixture = F.fileManager(now: now)
        var names = fixture.names
        names.deletedHere = [F.Files.binnedFrom]
        names.memoryBin = []
        names.memoryKept = [:]
        names.memoryKeptCount = 0
        let counts = BackendCloudPageCounts(here: [.notes: BackendCloudNoteIdentity.itemCount(names.noteFacts, deleted: names.deletedHere)])
        let after = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names, counts: counts,
                                                                  memoryChanges: true, now: now)).model
        #expect(Set(after.items(.memory).map(\.name)).isSubset(of: Set(before.model.items(.memory).map(\.name))))
        #expect(after.items(.memory).count == before.model.items(.memory).count)
        #expect(after.bin.isEmpty)
        #expect(after.versionsToClean == 0)
        #expect(after.counts[.memory] == counts.count(.memory))
        #expect(after.counts[.memory] == BackendCloudNoteIdentity.itemCount(F.fileManager(now: now).names.noteFacts))
    }

    // B3. A file in its own place is never a version, on any Mac: on the other Mac a note removed here stays a live row
    // there, saying so, and stays counted; Clean up never counts it.
    @Test func aFileInItsOwnPlaceIsNeverAVersion() throws {
        let other: [String: BackendCloudNoteFacts] = [
            F.Files.binnedFrom: .init(path: F.Files.binnedFrom, id: "n-old-idea", changedAt: now - 200 * hour),
            F.Files.binned: .init(path: F.Files.binned, id: "n-old-idea-2", archivedAt: F.removedAt, reason: BackendCloudNoteIdentity.removedReason,
                                  origin: F.Files.binnedFrom, changedAt: now - 5 * hour),
        ]
        let there = BackendCloudNoteIdentity.resolve(paths: [], facts: other)
        #expect(there[F.Files.binnedFrom] == .init(key: F.Files.binnedFrom, role: .item, state: .live, elsewhere: F.Files.binned))
        #expect(there[F.Files.binned]?.role == .history)
        #expect(BackendCloudNoteIdentity.itemCount(other) == 1)
        // The page on that Mac: one live row "Removed on Studio Mac", nothing to clean, no Bin row.
        let fixture = F.fileManager(now: now)
        var names = fixture.names
        names.noteFacts = other
        names.memoryBin = []   // that Mac's own Bin is empty
        let model = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names,
                                                                  memoryChanges: true, now: now)).model
        let row = try #require(model.items(.memory).first { $0.name.contains("Old idea") || $0.name == "An old idea" })
        #expect(row.elsewhere == "Removed on Studio Mac")
        #expect(row.versions.isEmpty)
        #expect(model.bin.isEmpty)
        // Put back on the other Mac: the note is at its place again, newer than the copy in the archive.
        let back: [String: Int64] = [F.Files.binnedFrom: now, F.Files.binned: now - 5 * hour]
        let afterOnThisMac = BackendCloudNoteIdentity.resolve(paths: Array(back.keys), facts: F.fileManager(now: now).names.noteFacts, newest: back)
        #expect(afterOnThisMac[F.Files.binnedFrom] == .init(key: F.Files.binnedFrom, role: .item, state: .live))
        #expect(afterOnThisMac[F.Files.binned]?.key == F.Files.binnedFrom)
    }

    // A. Delete rule (no switch any more): the rows are the same whatever the gate says, and the bin buttons follow the
    // gate. Closed (an older Mac has not said it knows the rule): no "Cloud" button, saved passwords none, and "Cloud"
    // is refused with the fixed words. Open: "Cloud" and "Everywhere".
    actor OneOwner: CloudDeleteOwning {
        var scopes: [CloudDeleteScope] = []
        func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by: CloudDeleteActor) async throws -> CloudBinGroup {
            scopes.append(scope)
            return CloudBinGroup(id: by.group, by: by.by, macName: by.macName, session: by.session, agent: by.agent, at: by.at, items: items)
        }
        func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] { items }
        func notHere() async throws -> [CloudNotHereItem] { [] }
        func binGroups() async throws -> [CloudBinGroup] { [] }
        func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] { [] }
        func deleteForGood(_ items: [CloudDeleteItem]) async throws {}
    }
    @Test func theBinButtonsFollowTheGate() async throws {
        // The rows do not depend on the gate (or on the old memory switch): the plan is removable either way.
        for changes in [false, true] {
            let plan = try #require(try built(changes: changes).model.items(.memory).first { $0.name == "Plan for the launch" })
            #expect(plan.canRemove && plan.deleteItems.first?.kind == "memory")
        }
        // The gate: closed until every Mac of the account has said it knows the rule (or said "none").
        let macs = ["mac-a", "mac-b"]
        var told = [CloudDeleteGate.key(device: "mac-a"): CloudDeleteGate.value(at: now - hour)]
        #expect(!CloudDeleteGate.isOpen(computers: macs, announcements: told, now: now))
        told[CloudDeleteGate.key(device: "mac-b")] = CloudDeleteGate.none
        #expect(CloudDeleteGate.isOpen(computers: macs, announcements: told, now: now))
        // The buttons.
        let page = BackendCloudDeletePage.self
        #expect(page.scopes(for: [.memory], gateOpen: false) == [.everywhere])
        #expect(page.scopes(for: [.passwords], gateOpen: false).isEmpty)
        #expect(page.scopes(for: [.memory], gateOpen: true) == [.cloud, .everywhere])
        #expect(page.scopes(for: [.passwords], gateOpen: true) == [.cloud, .everywhere])
        // "Cloud" while it is closed: refused with the fixed words, nothing removed; open: done.
        let owner = OneOwner()
        let target = BackendCloudDeleteDoor.Target(item: .init(id: "memory:" + F.Files.plan, kind: "memory", name: "Plan for the launch", place: F.Files.plan))
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder }, session: { _, _ in .null },
            runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
            authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: "/scratch", attended: false,
                                            allowedTools: BackendCloudManagerTools.pageIDs, allowedTiers: [.read, .act], cancellation: .init())
        func cloud(gate: Bool) async throws -> BackendMCPToolReply {
            let door = BackendCloudDeleteDoor(targets: { [target] }, owners: { ["memory": owner] },
                                              thisMac: { .init(id: "device-1", name: "Mac mini") }, gateOpen: { gate }, now: { 1_794_100_000_000 })
            let tools = try BackendCloudManagerTools.definitions(access: access, actions: .none, door: door)
            let delete = try #require(tools.first { $0.spec.id == BackendCloudManagerTools.deleteID })
            return try await delete.handler(context, .object([.init("items", .array([.object([.init("kind", .string("Memory")), .init("name", .string("Plan for the launch"))])])),
                                                              .init("scope", .string("cloud"))]))
        }
        let refused = try await cloud(gate: false)
        #expect(refused.isError && refused.structuredContent?["error"].string == CloudDeleteWords.cloudNeedsUpdatedMacs)
        #expect(CloudDeleteWords.cloudNeedsUpdatedMacs == "Cloud only works once your other devices are updated")
        #expect(await owner.scopes.isEmpty)
        #expect(!(try await cloud(gate: true)).isError)
        #expect(await owner.scopes == [.cloud])
    }

    // B7. "N notes" (this Mac's memory index) and the page's Memory number agree on his kind of data: replaced copies,
    // conflict copies, removed notes, old places.
    @Test func theCountsOnBothPagesAgree() throws {
        let facts = F.fileManager(now: now).names.noteFacts
        let notes = BackendCloudNoteIdentity.itemCount(facts)
        #expect(notes == 2) // Plan and the hand-off
        let counts = BackendCloudPageCounts(here: [.notes: notes])
        let made = try built(counts: counts)
        #expect(made.model.counts[.memory] == notes)
        #expect(counts.line([.notes]) == "2 notes") // Settings → Cloud's "N notes" reads the same number
        // The rows built from the Cloud's records that are notes on this Mac: the same number.
        let fromFacts = made.model.items(.memory).filter { facts[made.handles[$0.id]?.relative ?? ""] != nil }
        #expect(fromFacts.count == notes)
    }

    @Test func aRemovedNoteIsInTheBinOnThisMac() throws {
        let model = try built().model
        let binned = try #require(model.bin.first)
        #expect(model.bin.count == 1)
        #expect(binned.name == "An old idea" && binned.canPutBack && !binned.canRemove)
        #expect(!model.items(.memory).contains { $0.name == "An old idea" })
    }

    // 5. Every row says what it is: the agent's name for its card, the leads' checklist, the title in full.
    @Test func everyRowSaysWhatItIs() throws {
        let names = Set(try built().model.items(.memory).map(\.name))
        #expect(names.isSuperset(of: ["Card · Decker", "Card · Rita", "Checklist · All Leads"]))
        let long = "A decision about the website's pricing page and the free plan that every new person sees first"
        #expect(BackendCloudContentsWords.noteName("notes/x.md", titles: ["notes/x.md": long]) == long)
        for name in names { #expect(BackendCloudPageWords.isPlain(name), "\(name)") }
    }

    // 6. Delete rule (section F; J wins): what can be removed, by whom, and what never. Memory notes, projects, agents,
    // saved passwords, instruction files (real records: `file/<place>/<path>`) and tasks can be removed, by him on the
    // page and by an AI through the same tool; tasks and agents only everywhere. Settings never. A Bin row is put back,
    // never removed again.
    @Test func whatCanBeRemovedFollowsTheDeleteRule() throws {
        let model = try built().model
        for kind in [BackendCloudContents.Kind.memory, .projects, .agents] {
            let removable = model.items(kind).contains { $0.canRemove }; #expect(removable, "\(kind)")
        }
        for item in model.items where item.canRemove { #expect(item.kind != .settings && !item.deleteItems.isEmpty, "\(item.name)") }
        #expect(!model.items(.settings).contains { $0.canRemove })
        func handle(_ domain: String, source: String, record: String, relative: String? = nil) -> BackendCloudContentsHandle {
            var made = BackendCloudContentsHandle(domain: domain, projectId: F.project, relative: relative, home: nil)
            made.sourceId = source; made.recordId = record
            return made
        }
        let page = BackendCloudDeletePage.self
        #expect(page.targets(kind: .projects, name: "Terminal Deck", handle: handle("projects", source: "task-config-projects", record: F.project))
                == [.init(id: "project:" + F.project, kind: "project", name: "Terminal Deck", place: nil)])
        #expect(page.targets(kind: .agents, name: "Decker", handle: handle("agents", source: "task-config-agents", record: F.agent)).first?.id == "agent:" + F.agent)
        #expect(page.targets(kind: .passwords, name: "Server login", handle: handle("server", source: "secrets/server", record: F.password)).first?.kind == "saved-passwords")
        #expect(page.targets(kind: .tasks, name: "Write docs", handle: handle("tasks", source: "tasks", record: "local:1")).first?.kind == "task")
        let place = BackendCloudBootFiles.sourceId(kind: .project, identity: F.project)
        #expect(page.targets(kind: .instructionFiles, name: "Instructions for Claude",
                             handle: handle(CloudBootFilesFormat.domain, source: "files/I09/" + place, record: "file/" + place + "/CLAUDE.md", relative: "CLAUDE.md"))
                .first?.id == place + "\nCLAUDE.md")
        #expect(page.targets(kind: .settings, name: "Settings", handle: handle("brain/memory/i05", source: "memory/I05", record: "row/settings/x")).isEmpty)
        // Tasks and agents go everywhere only; the rest offer "Cloud" too while the gate is open.
        #expect(page.scopes(for: [.tasks], gateOpen: true) == [.everywhere] && page.scopes(for: [.agents], gateOpen: true) == [.everywhere])
        #expect(page.scopes(for: [.memory, .projects, .instructionFiles], gateOpen: true) == [.cloud, .everywhere])
        // One rule phase 2: the only handle "Use this version" takes is a keeper id; a file path never is one.
        #expect(BackendCloudFilesPlan.keptId("kept:" + F.Kept.plan[0]) == F.Kept.plan[0])
        #expect(BackendCloudFilesPlan.keptId("archive/hoot/notes/a.md") == nil)
        #expect(BackendCloudFilesPlan.keptId("kept:../x") == nil)
        // The ONE Bin: the keeper's item, removed from its own place, can be put back and not removed again.
        #expect(model.bin.map(\.name) == ["An old idea"] && model.bin.allSatisfy { $0.canPutBack && !$0.canRemove })
    }

    // B4. True words: the travelling lines once removals travel; the honest ones until then.
    @Test func wordsAndApprovalLines() throws {
        let model = try built().model
        #expect(BackendCloudFilesWords.oneRule == "The newest version is used on all your devices. Earlier ones are kept for 30 days.")
        #expect(BackendCloudFilesWords.cleanUp(389) == "Clean up 389 earlier versions")
        let plan = try #require(model.items(.memory).first { $0.name == "Plan for the launch" })
        #expect(BackendCloudFilesWords.approveRemove(plan, travels: true)
                == "Remove the memory note “Plan for the launch” (Terminal Deck) from your devices: it goes to the Bin and can be put back for 30 days")
        #expect(BackendCloudFilesWords.approveRemove(plan, travels: false)
                == "Remove the memory note “Plan for the launch” (Terminal Deck) from this Mac's memory: it goes to this Mac's Bin; your other devices follow later")
        let utc = TimeZone(identifier: "UTC")!
        #expect(BackendCloudFilesWords.goesOn(F.removedAt, travels: true, timeZone: utc).hasPrefix("Leaves your devices on "))
        #expect(BackendCloudFilesWords.goesOn(F.removedAt, travels: false, timeZone: utc).hasPrefix("Removed "))
        #expect(!BackendCloudFilesWords.removeToolDescription(travels: false).contains("every device"))
        let lines = [BackendCloudFilesWords.approvePutBack(model.bin[0]), BackendCloudFilesWords.approveUseVersion(plan, plan.versions[0]),
                     BackendCloudFilesWords.approveEmptyBin(model.bin), BackendCloudFilesWords.approveCleanUp(model.versionsToClean),
                     BackendCloudFilesWords.emptied(1), BackendCloudFilesWords.cleaned(3), BackendCloudFilesWords.removedBy(device: "Mac mini", byAI: true)]
        #expect(lines[2] == "Empty the Bin: 1 item, “An old idea”, removed from your devices now. They can no longer be put back")
        #expect(lines[3] == "Remove 3 earlier versions from your devices now instead of after 30 days. Nothing in use is touched")
        #expect(lines[6] == "Removed by an AI on Mac mini")
        // One rule phase 2 (point 6): no line he sees says "deleted" or "for good"; the Cloud keeps every version.
        for line in lines + [BackendCloudFilesWords.removeToolDescription(travels: true), BackendCloudFilesWords.goesOn(F.removedAt, travels: true)] {
            #expect(!line.lowercased().contains("delete") && !line.contains("for good"), "\(line)")
        }
        for line in lines {
            #expect(!BackendCloudContentsWords.looksLikeCode(line), "\(line)")
            #expect(!line.contains("/") && !line.contains(".md"), "\(line)")
        }
    }

    // B5 + 8, delete rule (L6): reads never ask; Use this version asks no question and sends exactly the dated version;
    // there is no tool for the Bin (no Remove, Put back, Empty Bin or Clean up); a saved password's value is never read.
    @Test func theToolsReadFreelyAndUseAVersionWithoutAQuestion() async throws {
        let made = try built()
        final class Asked: @unchecked Sendable { let lock = NSLock(); var lines: [String] = []; var owner: [Bool] = []; var changes: [BackendCloudManagerTools.Change] = [] }
        let asked = Asked()
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, folder in folder }, session: { _, _ in .null },
            runnableProject: { _, folder in folder }, rpc: { _ in throw NativeRPCError.invalidArguments("Unused") },
            authorize: { _, _, _, tier, sentence, ownerMustAnswer in
                if tier != .read { asked.lock.withLock { asked.lines.append(sentence); asked.owner.append(ownerMustAnswer) } }
            },
            record: { _, _, _, _ in })
        let actions = BackendCloudManagerTools.Actions(
            contents: { .init(contents: made.model, handles: made.handles) },
            read: { ref, _ in
                let item = try BackendCloudManagerTools.find(made.model, ref)
                return .init(item: item, versions: item.versions, text: item.kind == .passwords ? "never" : "text")
            },
            change: { change in asked.lock.withLock { asked.changes.append(change) }; return "done" })
        let tools = try BackendCloudManagerTools.definitions(access: access, actions: actions)
        #expect(Set(tools.map(\.spec.id)) == BackendCloudManagerTools.pageIDs)
        #expect(Set(tools.map(\.spec.id)).isDisjoint(with: BackendCloudManagerTools.retiredIDs))
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "fixture", projectRoot: "/scratch", attended: false,
                                            allowedTools: BackendCloudManagerTools.pageIDs, allowedTiers: [.read, .act], cancellation: .init())
        func call(_ id: String, _ fields: [NativeRPCValue.Field] = []) async throws -> BackendMCPToolReply {
            try await #require(tools.first { $0.spec.id == id }).handler(context, .object(fields))
        }
        _ = try await call(BackendCloudManagerTools.itemsID)
        let versions = try await call(BackendCloudManagerTools.versionsID, [.init("name", .string("Plan for the launch"))])
        #expect(asked.lines.isEmpty)
        let usable = versions.structuredContent?["versions"].elements?.first { $0["canUse"].bool == true }?["at"].string
        if let usable {
            let used = try await call(BackendCloudManagerTools.useVersionID, [.init("name", .string("Plan for the launch")), .init("version", .string(usable))])
            #expect(!used.isError)
            #expect(asked.owner.allSatisfy { !$0 }, "no question")
            #expect(asked.changes == [.restore(.init(kind: nil, name: "Plan for the launch", place: nil), at: usable)])
        }
        // An item in the Bin is not an item for the tools: no put back, no use of its versions.
        if let binned = made.model.bin.first {
            #expect(try await call(BackendCloudManagerTools.useVersionID, [.init("name", .string(binned.name)), .init("version", .string("2026-01-01T00:00:00Z"))]).isError)
        }
        let password = try await call(BackendCloudManagerTools.openID, [.init("kind", .string("Saved passwords")), .init("name", .string("Server login"))])
        #expect(password.structuredContent?["text"] == .null)
        for line in asked.lines { #expect(!BackendCloudContentsWords.looksLikeCode(line)) }
    }
}

/// One rule phase 2: the page's store actions are the memory store's one-rule functions (one Bin, one delete path);
/// the page's "deleted places" list is saved BEFORE a removal and a removal is refused when it cannot be saved. Real
/// stores on scratch folders (the two-Mac exchange is in `CloudMemoryPhase2Tests`).
@Suite("Cloud files — the memory store's actions")
struct CloudFilesStoreTests {
    @Test func removePutBackUseVersionEmptyBinAndCleanUpGoThroughTheStore() async throws {
        let a = try CloudBrainMemoryFixture()
        defer { Task { await a.close() } }
        try await a.seed()
        for row in ["I01", "I05", "I06"] { _ = try await a.snapshot(row) }   // capture on, as the activation does
        await a.store.cloudSetDevice(a.deviceId)
        await a.store.cloudSetOneRuleSending(false)
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        await a.store.cloudSetClock { clock.now }
        try await a.store.oneRuleFixtureCaptureAll()
        let note = "hoot/notes/a.md"
        let original = try String(contentsOf: a.root.appendingPathComponent(note), encoding: .utf8)
        // Remove: remembered first, then out of the folder and into the ONE Bin; the page's list names it.
        let binned = try await a.store.cloudFileRemove(note, fromAI: false)
        #expect(binned.path == note && !binned.byAI)
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent(note).path))
        #expect(await a.store.cloudFilesDeleted().contains(note))
        var read = try await a.store.cloudPageRead()
        #expect(read.memoryBin.map(\.path) == [note])
        #expect(try await a.store.memoryBinText(path: note) == original)
        // Put back: in use again, out of the Bin and out of the list.
        let back = try await a.store.cloudFilePutBack(note)
        #expect(!back.replacedAnother)
        #expect(try String(contentsOf: a.root.appendingPathComponent(note), encoding: .utf8) == original)
        let listed = await a.store.cloudFilesDeleted()
        #expect(!listed.contains(note))
        read = try await a.store.cloudPageRead()
        #expect(read.memoryBin.isEmpty)
        // Use this version: a kept text by its keeper id; the text it replaces is kept (nothing lost).
        try await a.store.oneRuleFixtureKeepText(note, original.replacingOccurrences(of: "A retained decision.", with: "An earlier decision."))
        // Integration run 0220z: Put back also kept the Bin's text as a version, with the same time on this test's fixed
        // clock, so "the first version" was either text (sorted by fingerprint). The version chosen is the earlier text.
        var earlier: DeckMemoryKeptVersion?
        for version in try await a.store.memoryVersions(path: note) where try await a.store.memoryVersionText(path: note, versionId: version.id)?.contains("An earlier decision.") == true {
            earlier = version
        }
        let kept = try #require(earlier)
        try await a.store.cloudFileUseVersion(item: note, versionId: kept.id)
        #expect(try String(contentsOf: a.root.appendingPathComponent(note), encoding: .utf8).contains("An earlier decision."))
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(original))
        read = try await a.store.cloudPageRead()
        let toClean = try await a.store.memoryCleanUpCount()
        #expect(read.memoryKeptCount == toClean && toClean >= 1)
        // An AI's removal is attributed truthfully for notes and seat files alike.
        let byAI = try await a.store.cloudFileRemove(note, fromAI: true)
        #expect(byAI.byAI)
        let cardByAI = try await a.store.cloudFileRemove("hoot/card.md", fromAI: true)
        #expect(cardByAI.byAI)
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent("hoot/card.md").path))
        // Empty Bin and Clean up: the store's own functions (the owner's answer is the page's press or the tool's
        // owner-only approval); kept texts and Bin items go, a text in use never does.
        let inUse = try await a.store.oneRuleFixtureAllTexts().subtracting(try await a.store.oneRuleFixtureKeptTexts())
        clock.advance(days: 0, hours: 1)
        _ = try await a.store.cloudFileEmptyBin()
        _ = try await a.store.cloudFileCleanUp()
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await a.store.memoryCleanUpCount() == 0)
        #expect(await a.store.cloudFilesDeleted().contains(note), "an emptied place stays history on the page")
        // Only kept texts and Bin items went: every text in use is still there, byte for byte.
        let after = try await a.store.oneRuleFixtureAllTexts()
        for text in inUse { #expect(after.contains(text)) }
    }

    /// The "deleted places" list is saved BEFORE the removal: when it cannot be saved, nothing is removed.
    @Test func aRemovalIsRefusedWhenTheDeletedPlacesListCannotBeSaved() async throws {
        let a = try CloudBrainMemoryFixture()
        defer { Task { await a.close() } }
        try await a.seed()
        _ = try await a.snapshot("I01")
        await a.store.cloudSetDevice(a.deviceId)
        await a.store.cloudSetOneRuleSending(false)
        try await a.store.oneRuleFixtureCaptureAll()
        let list = try #require(await a.store.cloudFilesDeletedFile)
        // A folder where the list's file should be: it cannot be written.
        try FileManager.default.createDirectory(at: list, withIntermediateDirectories: true)
        await #expect(throws: DeckMemoryError.self) { _ = try await a.store.cloudFileRemove("hoot/notes/a.md", fromAI: false) }
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("hoot/notes/a.md").path))
        #expect(try await a.store.memoryBin().isEmpty)
    }
}
