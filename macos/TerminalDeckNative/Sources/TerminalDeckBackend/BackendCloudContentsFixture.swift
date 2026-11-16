#if DEBUG
import Foundation
import TerminalDeckNativeCore

/// Debug builds only: one account with three devices for the contents page's tests and pictures. Items from two
/// devices, one going up, one not sent, one waiting here, a held device, a refused pack and a device never seen.
public enum BackendCloudContentsFixture {
    public static let mac = "33333333-3333-4333-8333-333333333333"
    public static let pro = "44444444-4444-4444-8444-444444444444"
    public static let imac = "66666666-6666-4666-8666-666666666666"
    public static let mini = "55555555-5555-4555-8555-555555555555"
    public static let project = "7d0c3b9e-1f4a-4c55-9e2b-3a6f8d1c2e40"
    public static let agent = "agent-profile-0f9e8d7c6b5a49382716"
    public static let password = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    public static let names = BackendCloudContentsNames(projects: [project: "Terminal Deck"], agents: [agent: "Decker"])
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "x", y: "y")

    public static func snapshot(now: Int64, behind: Int = 0) -> CloudAccountSnapshot {
        func device(_ id: String, _ label: String, seen: Int64) -> CloudDevice {
            CloudDevice(deviceId: id, label: label, platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                        lastSeenAt: seen, signPublicJwk: key, wrapPublicJwk: key, registeredAt: now - 30 * 86_400_000)
        }
        let trust = [
            CloudDeviceTrustRow(deviceId: mac, name: "Studio Mac", standing: .thisMac, code: "AAAA BBBB CCCC DDDD EEEE", keyId: "key-mac", signKey: key),
            CloudDeviceTrustRow(deviceId: pro, name: "MacBook Pro", standing: .trusted, code: "FFFF GGGG HHHH JJJJ KKKK", keyId: "key-pro", signKey: key),
            CloudDeviceTrustRow(deviceId: imac, name: "Office iMac", standing: .trusted, code: "LLLL MMMM NNNN PPPP QQQQ", keyId: "key-imac", signKey: key),
            CloudDeviceTrustRow(deviceId: mini, name: "Mac mini", standing: .new, code: "RRRR SSSS TTTT UUUU VVVV", keyId: "key-mini", signKey: key, waiting: 2),
        ]
        return CloudAccountSnapshot(phase: .signedIn, gate: gate, displayName: "Fixture person",
                                    devices: [device(mac, "Studio Mac", seen: now), device(pro, "MacBook Pro", seen: now - 60_000),
                                              device(imac, "Office iMac", seen: 0), device(mini, "Mac mini", seen: now - 3_600_000)],
                                    trust: trust, cloudHead: CloudSequence(UInt64(40 + behind)), fetched: CloudSequence(40))
    }

    public static func contents(now: Int64) -> CloudSyncContents {
        let minute: Int64 = 60_000
        typealias Key = CloudSyncContents.Key
        let claude = Key(domain: CloudBootFilesFormat.domain, sourceId: "files/I09/project/0a1b2c3d4e5f", recordId: "CLAUDE.md", projectId: project)
        let notesFile = Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/session-notes.md", projectId: project)
        let plan = Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/plan.md", projectId: project)
        let todo = Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/todo.md", projectId: project)
        let big = Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/big-export.md", projectId: nil)
        let rows = (1...4).map { Key(domain: "brain/memory/i05", sourceId: "memory/I05", recordId: "row/notes/" + String(repeating: "ab", count: 32) + "\($0)", projectId: nil) }
        let setting = Key(domain: "brain/memory/i05", sourceId: "memory/I05", recordId: "row/settings/" + String(repeating: "cd", count: 32), projectId: nil)
        let projectKey = Key(domain: "projects", sourceId: "task-config-projects", recordId: project, projectId: project)
        let agentKey = Key(domain: "agents", sourceId: "task-config-agents", recordId: agent, projectId: project)
        let passwordKey = Key(domain: "server", sourceId: "secrets/server", recordId: password, projectId: nil)
        func at(_ minutes: Int64) -> Int64 { now - minutes * minute }
        let items: [CloudSyncContents.Item] = [
            .init(key: claude, changes: [.init(deviceId: pro, at: at(20)), .init(deviceId: mac, at: at(180))], standing: .inCloud, bytes: 3_412),
            .init(key: notesFile, changes: [.init(deviceId: pro, at: at(45))], standing: .inCloud, bytes: 18_220),
            .init(key: plan, changes: [.init(deviceId: mac, at: at(1))], standing: .sending, bytes: 900),
            .init(key: todo, changes: [.init(deviceId: pro, at: at(5))], standing: .waitingHere, reason: "Its project is not on this Mac yet."),
            .init(key: big, changes: [.init(deviceId: mac, at: at(90))], standing: .notSent,
                  reason: "The service refused this edit (E_QUOTA_42); it is kept here and retried later."),
            .init(key: setting, changes: [.init(deviceId: mac, at: at(600))], standing: .inCloud),
            .init(key: projectKey, changes: [.init(deviceId: mac, at: at(2_000))], standing: .inCloud),
            .init(key: agentKey, changes: [.init(deviceId: pro, at: at(1_500))], standing: .inCloud),
            .init(key: passwordKey, changes: [.init(deviceId: mac, at: at(3_000))], standing: .inCloud),
        ] + rows.enumerated().map { index, key in
            .init(key: key, changes: [.init(deviceId: index % 2 == 0 ? mac : pro, at: at(Int64(30 + index)))], standing: .inCloud, bytes: 400)
        }
        let packs: [CloudSyncContents.Pack] = [
            .init(deviceId: pro, at: at(20), arrivedAt: at(19), keys: [claude], count: [CloudBootFilesFormat.domain: 1]),
            .init(deviceId: mac, at: at(30), arrivedAt: nil, keys: Array(rows.prefix(3)), count: ["brain/memory/i05": 4]),
            .init(deviceId: pro, at: at(45), arrivedAt: at(44), keys: [notesFile], count: ["brain/memory/i01": 1]),
        ]
        let held = CloudHeldDevice(deviceId: mini, firstHeldSeq: CloudSequence(38), firstHeldSecretsSeq: nil, packs: 1, operations: 2,
                                   byDomain: [], firstSeenAt: at(10), counting: false)
        let refused = CloudRefusedPack(sequence: CloudSequence(39), storageClass: .brain, deviceId: pro, reason: "signature", firstAt: at(12), checks: 1)
        return CloudSyncContents(thisDevice: mac, items: items, packs: packs, held: [held], refused: [refused],
                                 notSent: [.init(reason: "The service refused this edit (E_QUOTA_42); it is kept here and retried later.", count: 1, since: at(90))],
                                 queued: 1)
    }

    // MARK: Lane L4, the file manager

    /// Places in the memory folder of the file manager's fixture.
    public enum Files {
        static let lead = "projects/" + BackendCloudContentsFixture.project + "/lead/notes/"
        /// The note in use, replaced three times before ("Plan for the launch").
        public static let plan = lead + "2026-11-14-plan-for-the-launch-k3m9pq.md"
        /// Its three replaced copies, oldest first (each archived, replaced by the next one).
        public static let replaced = ["archive/" + lead + "2026-11-11-plan-for-the-launch-a1a1a1.md",
                                      "archive/" + lead + "2026-11-12-plan-for-the-launch-b2b2b2.md",
                                      "archive/" + lead + "2026-11-13-plan-for-the-launch-c3c3c3.md"]
        /// The place the newest replaced copy had before it was archived: the Cloud still lists it (the move sent no
        /// removal), with no file here: the unmarked "lowercase twin" of the walks.
        public static let oldPlace = lead + "2026-11-13-plan-for-the-launch-c3c3c3.md"
        /// A note and the copy another Mac's text was kept beside it as.
        public static let handoff = lead + "2026-11-14-handoff-to-design-h4h4h4.md"
        public static let sibling = lead + "2026-11-14-handoff-to-design-h4h4h4-cloud-0123456789abcdef.md"
        /// A note in the Bin, and where it was.
        public static let binned = "archive/" + lead + "2026-11-10-old-idea-z9z9z9.md"
        public static let binnedFrom = lead + "2026-11-10-old-idea-z9z9z9.md"
        /// Two agents' cards and a shared checklist: three different things named "Card"/"Checklist".
        public static let deckerCard = "roles/decker/card.md"
        public static let ritaCard = "roles/rita/card.md"
        public static let leadsChecklist = "templates/lead/checklist.md"
    }
    public static let removedAt: Int64 = 1_794_000_000_000
    /// One rule phase 2: the keeper ids of the plan's three kept earlier texts, oldest first.
    public enum Kept {
        public static let plan = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
    }

    /// The file manager's account: Plan with three earlier versions, a hand-off with a copy kept beside it, a note in the
    /// Bin, two agents' cards and the leads' checklist, plus everything of `contents(now:)`. `names` carries this Mac's
    /// memory index for those notes.
    public static func fileManager(now: Int64) -> (contents: CloudSyncContents, names: BackendCloudContentsNames) {
        let hour: Int64 = 3_600_000
        func key(_ path: String) -> CloudSyncContents.Key {
            .init(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/" + path, projectId: project)
        }
        func item(_ path: String, _ device: String, _ hoursAgo: Int64, bytes: Int64 = 1_200) -> CloudSyncContents.Item {
            .init(key: key(path), changes: [.init(deviceId: device, at: now - hoursAgo * hour)], standing: .inCloud, bytes: bytes)
        }
        let base = contents(now: now)
        let mine: [CloudSyncContents.Item] = [
            item(Files.plan, pro, 1),
            item(Files.replaced[0], mac, 72), item(Files.replaced[1], pro, 48), item(Files.replaced[2], mac, 24),
            item(Files.oldPlace, mac, 30),
            item(Files.handoff, mac, 3), item(Files.sibling, pro, 2),
            item(Files.binned, mac, 5), item(Files.binnedFrom, mac, 200),
            item(Files.deckerCard, mac, 400), item(Files.ritaCard, pro, 300), item(Files.leadsChecklist, mac, 500),
        ]
        var names = self.names
        names.agents["decker"] = "Decker"
        names.agents["rita"] = "Rita"
        names.notes = [Files.plan: "Plan for the launch", Files.handoff: "Hand-off to design", Files.sibling: "Hand-off to design",
                       Files.binned: "An old idea"] + Dictionary(uniqueKeysWithValues: Files.replaced.map { ($0, "Plan for the launch") })
        func fact(_ path: String, _ id: String, archived: Int64? = nil, reason: String? = nil, by: String? = nil, from: String? = nil, _ hoursAgo: Int64) -> BackendCloudNoteFacts {
            .init(path: path, id: id, archivedAt: archived, reason: reason, supersededBy: by, origin: from, changedAt: now - hoursAgo * hour)
        }
        let facts = [
            fact(Files.plan, "n-plan-4", 1),
            fact(Files.replaced[0], "n-plan-1", archived: now - 48 * hour, reason: "superseded", by: "n-plan-2", from: Files.replaced[0].replacingOccurrences(of: "archive/", with: ""), 72),
            fact(Files.replaced[1], "n-plan-2", archived: now - 24 * hour, reason: "superseded", by: "n-plan-3", from: Files.replaced[1].replacingOccurrences(of: "archive/", with: ""), 48),
            fact(Files.replaced[2], "n-plan-3", archived: now - 1 * hour, reason: "superseded", by: "n-plan-4", from: Files.oldPlace, 24),
            fact(Files.handoff, "n-handoff", 3),
            fact(Files.sibling, "n-handoff-copy", 2),
            fact(Files.binned, "n-old-idea", archived: removedAt, reason: BackendCloudNoteIdentity.removedReason, from: Files.binnedFrom, 5),
        ]
        names.noteFacts = Dictionary(uniqueKeysWithValues: facts.map { ($0.path, $0) })
        // One rule phase 2: the memory store's ONE Bin (the old idea, removed from its place) and the kept earlier texts
        // of the plan (its three replaced versions, kept by the keeper), as `cloudPageRead` hands them to the page.
        names.memoryBin = [DeckMemoryBinItem(path: Files.binnedFrom, name: "An old idea", place: project, removedAt: removedAt, device: mac,
                                             bytes: 1_200, keptUntil: removedAt + BackendCloudNoteIdentity.keptFor)]
        let kept: [(id: String, device: String, hoursAgo: Int64)] = [(Kept.plan[2], mac, 24), (Kept.plan[1], pro, 48), (Kept.plan[0], mac, 72)]
        names.memoryKept = [Files.plan: kept.map { entry in
            DeckMemoryKeptVersion(id: entry.id, at: now - entry.hoursAgo * hour, device: entry.device, bytes: 1_200,
                                  keptUntil: now - entry.hoursAgo * hour + BackendCloudNoteIdentity.keptFor)
        }]
        names.memoryKeptCount = 3
        let made = CloudSyncContents(thisDevice: base.thisDevice, items: base.items + mine, packs: base.packs, held: base.held, refused: base.refused,
                                     notSent: base.notSent, queued: base.queued)
        return (made, names)
    }

    // MARK: CLOUD-FILES-4: what his real Macs hold (14 Nov look at the Mac mini)

    /// Places of the real-data fixture, shaped as the records on his Mac mini are.
    public enum Real {
        static let lead = "projects/" + BackendCloudContentsFixture.project + "/lead/notes/"
        /// A note that replaced another one with a DIFFERENT title (the memory's own "superseded" link).
        public static let defect = lead + "2026-11-14-a-defect-stays-open-until-he-sees-it-cjq3ho.md"
        public static let defectTitle = "A defect stays open until he sees it fixed; Profile is the first Settings entry"
        /// The note it replaced (reason "superseded"), and the other Mac's copy of that same text, replaced there with a
        /// reason that carries its why ("superseded: …").
        public static let defectOld = "archive/" + lead + "2026-11-14-a-defect-stays-open-until-he-sees-it-cy24yo.md"
        public static let defectOldTwin = "archive/" + lead + "2026-11-14-a-defect-stays-open-until-he-sees-it-cy24yo-2.md"
        public static let defectOldTitle = "A defect stays open until he sees it fixed; phone sheets have a flat bottom"
        /// A note put away with nothing that replaced it.
        public static let shelved = "archive/" + lead + "2026-11-09-a-shelved-thought-s5s5s5.md"
        /// Hoot's own card and the card every new Hoot starts from.
        public static let hootCard = "hoot/card.md"
        public static let hootTemplate = "templates/orchestrator/card.md"
        /// The memory's own index of another AI's memory (imported), and the copy kept beside it.
        public static let memoryIndex = "hoot/notes/imported/hoot-memory/MEMORY.md"
        public static let memoryIndexCopy = "hoot/notes/imported/hoot-memory/MEMORY-cloud-c1af907e25dc44a2.md"
        /// A job's desk (a topic titled "Desk snapshot: Deck Dev (hand 1)") and two seats' "Open items" topics.
        public static let desk = "projects/" + BackendCloudContentsFixture.project + "/lead/topics/deck-dev.md"
        public static let releaseOpenItems = "projects/" + BackendCloudContentsFixture.project + "/roles/release/topics/open-items.md"
        public static let reviewerOpenItems = "projects/" + BackendCloudContentsFixture.project + "/roles/reviewer/topics/open-items.md"
        /// Instruction files inside the project, as their real records name them (`file/project/<token>/<path>`).
        public static let instructionFiles = ["AGENTS.md", "GEMINI.md",
                                              ".claude/skills/ui-ux-pro-max/SKILL.md", ".claude/skills/deep-research/SKILL.md",
                                              ".agents/skills/deep-research/SKILL.md",
                                              ".claude/agents/0-decker.md", ".claude/agents/critic/journal.md", ".claude/agents/scribe/journal.md",
                                              "team/decker/journal.md", ".claude/commands/catchup.md"]
        public static var place: String { BackendCloudBootFiles.sourceId(kind: .project, identity: BackendCloudContentsFixture.project) }
        /// The memory's own index tables: rows that only describe files listed already.
        public static let indexRows = ["row/files/" + String(repeating: "ef", count: 32), "row/topics/" + String(repeating: "fe", count: 32),
                                       // CLOUD-FILES-6: a rewind's undo record (bookkeeping).
                                       "row/rewinds/" + String(repeating: "dc", count: 32)]
        /// CLOUD-FILES-6: his diary (kept as ONE row) and the memory's questions for him.
        public static let diaryRows = (1...3).map { "row/diary/" + String(repeating: "ba", count: 31) + "0\($0)" }
        public static let questionRow = "row/questions/" + String(repeating: "ab", count: 32)
        /// A desk named after its project's folder ("Desk snapshot: ClaudeCRM"), whose project is called "CRM".
        public static let crmDesk = "projects/" + BackendCloudContentsFixture.project + "/lead/topics/claudecrm.md"
    }

    /// The file manager's fixture plus what the real data has (CLOUD-FILES-4).
    public static func realData(now: Int64) -> (contents: CloudSyncContents, names: BackendCloudContentsNames) {
        let hour: Int64 = 3_600_000
        var (base, names) = fileManager(now: now)
        func memory(_ path: String, _ device: String, _ hoursAgo: Int64) -> CloudSyncContents.Item {
            // His memory records carry no project of their own: the project is in the path.
            .init(key: .init(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/" + path, projectId: nil),
                  changes: [.init(deviceId: device, at: now - hoursAgo * hour)], standing: .inCloud, bytes: 900)
        }
        var items = base.items + [
            memory(Real.defect, mac, 2), memory(Real.defectOld, mac, 2), memory(Real.defectOldTwin, pro, 1),
            memory(Real.shelved, mac, 6),
            memory(Real.hootCard, mac, 7), memory(Real.hootTemplate, mac, 400),
            memory(Real.memoryIndex, mac, 8), memory(Real.memoryIndexCopy, pro, 8),
            memory(Real.desk, mac, 9), memory(Real.releaseOpenItems, mac, 10), memory(Real.reviewerOpenItems, pro, 11),
            memory(Real.crmDesk, mac, 13),
        ]
        for (index, path) in Real.instructionFiles.enumerated() {
            items.append(.init(key: .init(domain: CloudBootFilesFormat.domain, sourceId: "files/I09/" + Real.place, recordId: "file/" + Real.place + "/" + path,
                                          projectId: project),
                               changes: [.init(deviceId: mac, at: now - Int64(20 + index) * hour)], standing: .inCloud, bytes: 2_000))
        }
        for row in Real.indexRows + Real.diaryRows + [Real.questionRow] {
            items.append(.init(key: .init(domain: "brain/memory/i05", sourceId: "memory/I05", recordId: row, projectId: nil),
                               changes: [.init(deviceId: mac, at: now - 12 * hour)], standing: .inCloud, bytes: 300))
        }
        names.notes[Real.defect] = Real.defectTitle
        names.notes[Real.defectOld] = Real.defectOldTitle
        names.notes[Real.defectOldTwin] = Real.defectOldTitle
        names.notes[Real.shelved] = "A shelved thought"
        names.notes[Real.memoryIndex] = "Memory index"
        names.notes[Real.memoryIndexCopy] = "Memory index"
        names.notes[Real.desk] = "Desk snapshot: Deck Dev (hand 1)"
        names.notes[Real.releaseOpenItems] = "Open items"
        names.notes[Real.crmDesk] = "Desk snapshot: ClaudeCRM"
        names.projectFolders["ClaudeCRM"] = "CRM"
        names.notes[Real.reviewerOpenItems] = "Open items"
        let written = now - 3 * hour
        names.noteFacts[Real.defect] = .init(path: Real.defect, id: "n-defect-new", changedAt: now - 2 * hour, writtenAt: now - 2 * hour)
        names.noteFacts[Real.defectOld] = .init(path: Real.defectOld, id: "n-defect-old", archivedAt: now - 2 * hour, reason: "superseded",
                                                supersededBy: "n-defect-new", origin: String(Real.defectOld.dropFirst("archive/".count)),
                                                changedAt: now - 2 * hour, writtenAt: written)
        names.noteFacts[Real.defectOldTwin] = .init(path: Real.defectOldTwin, id: "n-defect-old-2", archivedAt: now - hour,
                                                    reason: "superseded: Note 13 corrects note 12", supersededBy: "n-defect-new",
                                                    origin: String(Real.defectOldTwin.dropFirst("archive/".count)), changedAt: now - hour, writtenAt: written)
        names.noteFacts[Real.shelved] = .init(path: Real.shelved, id: "n-shelved", archivedAt: now - 6 * hour, reason: "archived",
                                              origin: String(Real.shelved.dropFirst("archive/".count)), changedAt: now - 6 * hour, writtenAt: now - 50 * hour)
        names.noteFacts[Real.memoryIndex] = .init(path: Real.memoryIndex, id: "n-memory-index", changedAt: now - 8 * hour)
        names.agents["hoot"] = "Hoot"
        base = CloudSyncContents(thisDevice: base.thisDevice, items: items, packs: base.packs, held: base.held, refused: base.refused,
                                 notSent: base.notSent, queued: base.queued)
        return (base, names)
    }
}

private func + (left: [String: String], right: [String: String]) -> [String: String] { left.merging(right) { first, _ in first } }
#endif
