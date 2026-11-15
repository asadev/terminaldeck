import Foundation
import TerminalDeckNativeCore

/// Fixed allow-list, never SQL identifiers supplied by the network. The owning memory actor performs every write.
enum DeckMemoryCloudSchema {
    struct Table: Sendable {
        let name: String
        let row: String
        let columns: [String]
        let keys: [String]
        let integerKey: Bool
        init(_ name: String, _ row: String, _ columns: String, keys: [String] = ["id"], integerKey: Bool = false) {
            self.name = name; self.row = row; self.columns = columns.components(separatedBy: ",")
            self.keys = keys; self.integerKey = integerKey
        }
    }
    static let tables: [Table] = [
        .init("diary", "I02", "id,owner,project,session,agent,role,text,conversation,turn,external_id,at,saved,meta,hand,job,author,rewound,rewind_id", integerKey: true),
        .init("board", "I03", "id,kind,title,owner,project,session,agent,doing,last_result,waiting,state,proof,updated,archived,hand,job"),
        .init("board_history", "I03", "id,row_id,at,fields,snapshot", integerKey: true),
        .init("handoffs", "I04", "id,path,owner,topic,title,project,session,agent,hand,job,author,date,updated,archived,archive_reason,origin_path"),
        .init("rewinds", "I04", "id,owner,conversation,after_row,at,rows,notes,topics,undo,undone", integerKey: true),
        .init("settings", "I05", "owner,key,value,updated", keys: ["owner", "key"]),
        .init("questions", "I05", "id,owner,text,context,refs,asked,answer,answered,dismissed", integerKey: true),
        .init("notes", "I05", "id,path,title,type,owner,project,session,agent,date,source,supersedes,superseded_by,archived,archive_reason,origin_path,updated,hand,job,valid_from,valid_until,diary_first,diary_last,author"),
        .init("topics", "I05", "owner,id,title,path,open,project,session,agent,date,hand,job", keys: ["owner", "id"]),
        .init("files", "I05", "path,kind,owner", keys: ["path"]),
        .init("meta", "I05", "key,value", keys: ["key"])
    ]
    /// MAC-NEXT-8 (Decker, 13 Nov): the board and its history are this Mac's live status (who is working, idle or quiet
    /// here now). Never captured, never in a first copy, never journaled or reconciled; an arrival from an older build
    /// is acknowledged and ignored (not placed, not kept, not waiting, not "arriving").
    static func isLocalOnly(_ t: Table) -> Bool { CloudBrainMemoryFormat.localOnlyRows.contains(t.row) }
    static func isLocalOnlyKey(_ key: String) -> Bool {
        tables.contains { isLocalOnly($0) && key.hasPrefix("row/" + $0.name + "/") }
    }
    /// The tables that travel.
    static var travellingTables: [Table] { tables.filter { !isLocalOnly($0) } }
    /// M3 (Decker): an ALLOW-LIST of shared memory settings. Only these known preferences travel; every other key
    /// (helper reading positions, last-run and tidy stamps, backups, migrations, the local index model, unknown keys)
    /// stays on this Mac and unknown keys are named in coverage. The `meta` table holds only local bookkeeping.
    static let sharedSettingKeys: [String] = ["card.limit", "seat.title", "seat.parent", "seat.folded-into",
                                              "helper.ai", "helper.model", "helper.on", "helper.parallel", "helper.pause-seconds",
                                              "tidy.hour", "tidy.on",
                                              // The one rule: "Clean up now" and "Empty Bin" times, applied on every Mac.
                                              // An older build keeps these unknown keys as history only (isMachineLocal).
                                              "cleanup.versions-before", "cleanup.bin-before"]
    /// Keys that are known to be this Mac's own bookkeeping (not named as unknown in coverage).
    static func isKnownLocalSetting(_ key: String) -> Bool {
        ["backup.last", "board.history.settled", "helper.last-run", "tidy.last-run", "tidy.last-day", "tidy.last-day.at"].contains(key)
            || key.hasPrefix("helper.cursor") || key.hasPrefix("migration.") || key.hasPrefix("embedding.")
    }
    /// SQL condition (column `key`, optional row alias) selecting rows that TRAVEL. `meta` never travels.
    static func travellingSettingCondition(_ prefix: String = "") -> String {
        "(\(prefix)key IN (" + sharedSettingKeys.map { "'" + $0 + "'" }.joined(separator: ",") + ") OR \(prefix)key LIKE '" + sharedSettingPrefix + "%')"
    }
    /// One shared key per device: "this Mac understands removal records" (lane memory-one-rule, phase switch).
    static let sharedSettingPrefix = "onerule.understands."
    static let metaFilter = "0"
    static var machineLocalSettingFilter: String { travellingSettingCondition() }
    static func isMachineLocalSetting(_ key: String) -> Bool { !sharedSettingKeys.contains(key) && !key.hasPrefix(sharedSettingPrefix) }
    static func isMachineLocal(_ t: Table, _ values: [DeckMemorySQL]) -> Bool {
        if t.name == "meta" { return true }
        guard t.name == "settings", let i = t.columns.firstIndex(of: "key"), case .text(let key) = values[i] else { return false }
        return isMachineLocalSetting(key)
    }
    /// A deleted or reset shared setting travels as the same row shape with `value` null (the live column is NOT NULL,
    /// so a null value can only mean "removed"); `updated` carries the removal time.
    static func isSettingTombstone(_ t: Table, _ values: [DeckMemorySQL]) -> Bool {
        t.name == "settings" && values[t.columns.firstIndex(of: "value")!] == .null
    }
    static func table(_ name: String) throws -> Table {
        guard let t = tables.first(where: { $0.name == name }) else { throw CloudFailure.unsupportedFormat }; return t
    }
    static func cell(_ value: DeckMemorySQL) -> CloudBrainMemoryCell {
        switch value {
        case .null: return .init(type: "null", value: nil)
        case .text(let s): return .init(type: "text", value: s)
        case .int(let n): return .init(type: "integer", value: String(n))
        case .real(let n): return .init(type: "real", value: String(n))
        case .blob(let b): return .init(type: "blob", value: b.base64EncodedString())
        }
    }
    static func sql(_ cell: CloudBrainMemoryCell) throws -> DeckMemorySQL {
        switch cell.type {
        case "null": guard cell.value == nil else { throw CloudFailure.invalidRequest }; return .null
        case "text": guard let s = cell.value else { throw CloudFailure.invalidRequest }; return .text(s)
        case "integer": guard let s = cell.value, let n = Int64(s), String(n) == s else { throw CloudFailure.invalidRequest }; return .int(n)
        case "real": guard let s = cell.value, let n = Double(s), n.isFinite else { throw CloudFailure.invalidRequest }; return .real(n)
        case "blob": guard let s = cell.value, let b = Data(base64Encoded: s) else { throw CloudFailure.invalidRequest }; return .blob(b)
        default: throw CloudFailure.invalidRequest
        }
    }
    static func encodeRow(_ t: Table, _ values: [DeckMemorySQL]) throws -> Data {
        try CloudWire.canonical(CloudBrainMemoryRow(table: t.name, columns: t.columns, cells: values.map(cell)))
    }
    static func decodeRow(_ bytes: Data) throws -> (Table, [DeckMemorySQL]) {
        let row = try CloudWire.decode(CloudBrainMemoryRow.self, from: bytes, allowedKeys: ["table","columns","cells","references"], maximumBytes: bytes.count), t = try table(row.table)
        guard row.columns == t.columns, row.cells.count == t.columns.count else { throw CloudFailure.unsupportedFormat }
        return (t, try row.cells.map(sql))
    }
    static func nativeKey(_ t: Table, _ values: [DeckMemorySQL]) throws -> String {
        String(decoding: try CloudWire.canonical(t.keys.map { cell(values[t.columns.firstIndex(of: $0)!]) }), as: UTF8.self)
    }
    static func referenceColumns(_ table: String) -> [String:String] {
        switch table {
        case "diary": return ["rewind_id":"rewinds"]
        case "rewinds": return ["after_row":"diary"]
        case "notes": return ["diary_first":"diary","diary_last":"diary","supersedes":"notes","superseded_by":"notes"]
        case "board_history": return ["row_id":"board"]
        default: return [:]
        }
    }
    static func key(_ t: Table, _ values: [DeckMemorySQL]) throws -> String {
        let cells = t.keys.compactMap { key in t.columns.firstIndex(of: key).map { cell(values[$0]) } }
        return "row/" + t.name + "/" + DeckMemoryFiles.hash(try CloudWire.canonical(cells))
    }
    /// Which inventory row a memory-folder file belongs to. nil only for the intentional local-only exclusions:
    /// the live database and its side files, local database backups (Decker, finding 8), Cloud's own and Finder files.
    /// Every other regular file travels (finding 20), so nothing is skipped silently.
    static func fileRow(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        if path.hasPrefix("memory.db") || parts.contains(where: { $0.hasPrefix(".cloud") || $0 == ".DS_Store" }) { return nil }
        if isLocalDatabaseBackup(path) { return nil }
        if path.hasPrefix("archive/") { return "I06" }
        if path.contains("/handoffs/"), path.hasSuffix(".md") { return "I04" }
        return "I01"
    }
    /// `archive/backups/memory-*.db` and its side files, and any database copy inside a previous memory folder's backups.
    static func isLocalDatabaseBackup(_ path: String) -> Bool {
        guard path.hasPrefix("archive/backups/") || path.contains("/archive/backups/") else { return false }
        return [".db", ".db-wal", ".db-shm", ".db-journal", "-wal", "-shm", "-journal"].contains { path.hasSuffix($0) }
    }
    /// Named, intentional exclusions shown with a row's coverage; they never make it incomplete.
    static let intentionalExclusions: [String: String] = ["I06": "Local database backups: kept on this Mac only."]
    /// The app writes these at the memory root on every Mac; they are app-owned help, not memory (review round 2, M6).
    static let appHelpFiles: Set<String> = ["START-HERE.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md"]
    /// M5/M6: named exclusions for files that never travel (hidden files and folders, links, the app's own help files).
    static func fileExclusions(hidden: Int, links: Int, appHelp: Int) -> [String] {
        var notes: [String] = []
        if hidden > 0 { notes.append("Hidden files and folders (such as .git or .obsidian) stay on this Mac: \(hidden).") }
        if links > 0 { notes.append("Linked files and folders are not followed and stay on this Mac: \(links).") }
        if appHelp > 0 { notes.append("The app's own help files (START-HERE and pointer files) are written on each device: \(appHelp).") }
        return notes
    }
    /// Memory settings that are neither shared preferences nor known local bookkeeping are named, never sent (M3).
    static func unknownSettingNotes(_ keys: [String]) -> [String] {
        let unknown = Array(Set(keys.filter { !sharedSettingKeys.contains($0) && !isKnownLocalSetting($0) })).sorted()
        var notes = unknown.prefix(20).map { "Memory setting kept on this Mac: " + $0 }
        if unknown.count > 20 { notes.append("Memory settings kept on this Mac: \(unknown.count - 20) more.") }
        return notes
    }
    static func safePath(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".cloud") }) else { throw CloudFailure.invalidRequest }
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            if let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeSymbolicLink { throw CloudFailure.unsafeConfiguration }
        }
        return url
    }
}
