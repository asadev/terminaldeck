import Foundation
import TerminalDeckNativeCore

/// Page-names lane (owner, 13 Nov): what the Cloud pages count for memory, read from this Mac's OWN memory, so "on this
/// Mac" is only ever said of what is really here. Read only: nothing is written, placed or sent by it.
public struct DeckMemoryCloudPageRead: Sendable, Equatable {
    /// Notes, diary entries, topics and shared settings in this Mac's memory now.
    public var here: [BackendCloudPageCounts.Unit: Int]
    /// Arrived from the Cloud, not added to this Mac's memory yet, and placeable here now (their project is here).
    public var arriving: [BackendCloudPageCounts.Unit: Int]
    /// A note's or hand-off's own title by its file's place in the memory folder, so a page names a note by its title,
    /// never by its file name.
    public var titles: [String: String]
    /// Page-names 2: notes and topics the memory still lists whose file is gone from this Mac (not counted as here).
    public var missing: [BackendCloudPageCounts.Unit: Int]
    /// Lane L4: what each note is (in use, replaced by which note, removed), by its place in the memory folder. The notes
    /// count is worked out from these by `BackendCloudNoteIdentity.itemCount`, the ONE definition both pages use.
    public var noteFacts: [String: BackendCloudNoteFacts] = [:]
    /// Lane L4: the dated earlier copies kept in `archive/versions/` (read with the titles).
    public var keptCopies: Set<String> = []
    /// CLOUD-FILES-2: places this Mac deleted by Clean up / Empty Bin and their former places.
    public var deletedHere: Set<String> = []
    /// One rule phase 2: the ONE Bin (the memory keeper's), the kept earlier texts by place, how many "Clean up" removes,
    /// and the one line while many notes are missing and nothing was sent.
    public var memoryBin: [DeckMemoryBinItem] = []
    public var memoryKept: [String: [DeckMemoryKeptVersion]] = [:]
    public var memoryKeptCount: Int = 0
    public var memoryMissingLine: String? = nil
    /// Review round 2: what waits for his answer (missing here, held from another device); shown with the switch off too.
    public var memoryAnswer: DeckMemoryAnswer? = nil
    public init(here: [BackendCloudPageCounts.Unit: Int] = [:], arriving: [BackendCloudPageCounts.Unit: Int] = [:], titles: [String: String] = [:],
                missing: [BackendCloudPageCounts.Unit: Int] = [:]) {
        self.here = here; self.arriving = arriving; self.titles = titles; self.missing = missing
    }
}

extension DeckMemoryStore {
    /// One read for both Cloud views. `withTitles` = false skips the title list (the count part is cheap enough to read
    /// every few seconds while the window is open; titles change rarely).
    public func cloudPageRead(withTitles: Bool = true, titleLimit: Int = 20_000, includeBin: Bool = true) throws -> DeckMemoryCloudPageRead {
        var read = DeckMemoryCloudPageRead()
        func count(_ sql: String) -> Int? {
            guard let row = try? db.first(sql) else { return nil }
            return Int(row.int(0))
        }
        // Lane L4 (owner: one row per thing): a note counts once however many replaced copies of it exist; a copy kept
        // beside it and a note in the Bin are not counted. The same definition decides the Your Cloud rows.
        read.noteFacts = cloudNoteFacts()
        read.deletedHere = cloudFilesDeleted()
        cloudReadOneRuleBin(into: &read, includeBin: includeBin)
        read.here[.notes] = read.noteFacts.isEmpty ? count("SELECT COUNT(*) FROM main.notes WHERE missing = 0 AND archived IS NULL")
                                                   : BackendCloudNoteIdentity.itemCount(read.noteFacts, deleted: read.deletedHere)
        read.here[.diary] = count("SELECT COUNT(*) FROM main.diary")
        read.here[.topics] = count("SELECT COUNT(*) FROM main.topics WHERE missing = 0")
        if let gone = count("SELECT COUNT(*) FROM main.notes WHERE missing <> 0"), gone > 0 { read.missing[.notes] = gone }
        if let gone = count("SELECT COUNT(*) FROM main.topics WHERE missing <> 0"), gone > 0 { read.missing[.topics] = gone }
        read.here[.settings] = count("SELECT COUNT(*) FROM main.settings WHERE " + DeckMemoryCloudSchema.travellingSettingCondition())
        // Arrivals that wait for their project on this Mac, by what they are. A resource is "row/<table>/<hash>" for a
        // database row and "file/<path>" for a file; every revision of one resource counts once.
        // Strictly read-only: the waiting table is read only if it exists; nothing is created from the page.
        if cloudMemoryEnabled, let table = try? cloudWaitingTableForReading() {
            // MAC-NEXT-7 (A): only rows this Mac CAN place now (their project is here) are "arriving". Rows kept for a
            // project that no device has are not arriving and are not counted anywhere on the page: with nothing
            // placeable left, the page says "Up to date" / "All saved".
            let rows = (try? db.rows("""
                SELECT CASE WHEN resource_key LIKE 'row/%' THEN substr(resource_key, 5, instr(substr(resource_key, 5), '/') - 1) ELSE 'file' END,
                       COUNT(DISTINCT resource_key), project_id, store_id FROM \(table) GROUP BY 1, 3, 4
                """)) ?? []
            let localOnly = Set(DeckMemoryCloudSchema.tables.filter(DeckMemoryCloudSchema.isLocalOnly).map(\.name))
            for row in rows {
                // MAC-NEXT-8: the live board does not travel; a board row an older build kept waiting is not arriving.
                guard !localOnly.contains(row.text(0)) else { continue }
                guard (try? cloudProjectTarget(row.text(2), origin: row.text(3))) != nil else { continue }
                let kind = row.text(0), number = Int(row.int(1))
                let unit: BackendCloudPageCounts.Unit = kind == "file" ? .memoryFiles : (BackendCloudPageCounts.unit(memoryTable: kind) ?? .otherMemory)
                read.arriving[unit, default: 0] += number
            }
        }
        if withTitles {
            read.keptCopies = cloudKeptCopies()
            for sql in ["SELECT path, title FROM main.notes WHERE missing = 0 AND title IS NOT NULL AND title <> '' LIMIT \(titleLimit)",
                        "SELECT path, title FROM main.handoffs WHERE title IS NOT NULL AND title <> '' LIMIT \(titleLimit)",
                        // CLOUD-FILES-4: topics too ("Imatch", "Deck dev" were topics named from their file names).
                        // CLOUD-FILES-6: a job's desk (a topic with a job whose title is the job's name, or the app's
                        // "Desk snapshot: …") is titled the same way for every desk: "Desk snapshot: <job>".
                        // CLOUD-FILES-7: compared without regard to letter case (job "Deck Dev", title "Deck dev"); the
                        // JOB's own spelling is what is shown.
                        """
                        SELECT path, CASE WHEN job IS NOT NULL AND job <> '' AND (title = job COLLATE NOCASE OR title LIKE 'Desk snapshot:%')
                                          THEN 'Desk snapshot: ' || job ELSE title END
                        FROM main.topics WHERE missing = 0 AND title IS NOT NULL AND title <> '' LIMIT \(titleLimit)
                        """] {
                for row in (try? db.rows(sql)) ?? [] where read.titles[row.text(0)] == nil { read.titles[row.text(0)] = row.text(1) }
            }
        }
        return read
    }
    /// One rule phase 2: the keeper's Bin and kept texts for the page. Read only.
    func cloudReadOneRuleBin(into read: inout DeckMemoryCloudPageRead, includeBin: Bool = true) {
        guard cloudStateRoot != nil, let keeper = try? cloudKeeper() else { return }
        read.memoryBin = includeBin ? ((try? memoryBin()) ?? []) : []
        let kept = (try? keeper.versions(kind: Self.oneRuleKind)) ?? []
        read.memoryKeptCount = kept.count
        for version in kept where version.itemKey.hasPrefix("memory:") {
            read.memoryKept[String(version.itemKey.dropFirst("memory:".count)), default: []].append(
                DeckMemoryKeptVersion(id: version.sha256, at: version.at, device: version.device, bytes: version.bytes, keptUntil: version.keptUntil))
        }
    }
    /// Every note's identity facts (path, id, archived, why, replaced by, former place, change time). Read only.
    func cloudNoteFacts() -> [String: BackendCloudNoteFacts] {
        let rows = (try? db.rows("SELECT path, id, archived, archive_reason, superseded_by, origin_path, mtime, date FROM main.notes WHERE missing = 0")) ?? []
        var facts: [String: BackendCloudNoteFacts] = [:]
        for row in rows {
            func ms(_ date: Date?) -> Int64? { date.map { Int64($0.timeIntervalSince1970 * 1000) } }
            let path = row.text(0)
            facts[path] = BackendCloudNoteFacts(path: path, id: row.text(1), archivedAt: row.isNull(2) ? nil : ms(row.date(2)) ?? 0,
                                                reason: row.string(3), supersededBy: row.string(4), origin: row.string(5),
                                                changedAt: Int64((row.double(6) ?? 0) * 1000),
                                                // CLOUD-FILES-4: when its text was written (an earlier version is dated by it).
                                                writtenAt: row.double(7).map { Int64($0 * 1000) })
        }
        return facts
    }
    /// The dated earlier copies in `archive/versions/` (never indexed as notes), by their place in the memory folder.
    func cloudKeptCopies(limit: Int = 50_000) -> Set<String> {
        let folder = url("archive/versions")
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: Set<String> = []
        let base = folder.resolvingSymlinksInPath().path + "/"
        for case let file as URL in walk where found.count < limit {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = file.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            found.insert("archive/versions/" + String(full.dropFirst(base.count)))
        }
        return found
    }
}
