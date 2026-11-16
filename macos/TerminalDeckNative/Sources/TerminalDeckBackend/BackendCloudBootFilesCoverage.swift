import Foundation
import TerminalDeckNativeCore

/// What waits, in the sync core's coverage shape, and the same as one answer for the context-ready barrier.
extension BackendCloudBootFiles {
    func waiting(_ kinds: [BackendCloudBootFilesItem.Kind], sourceId: String?) throws -> Int {
        let db = try state()
        var total: Int64 = 0
        for kind in kinds {
            if let sourceId {
                total += try db.first("SELECT COUNT(*) FROM boot_items WHERE kind=? AND source_id=?", [.text(kind.rawValue), .text(sourceId)])?.int(0) ?? 0
            } else {
                total += try db.first("SELECT COUNT(*) FROM boot_items WHERE kind=?", [.text(kind.rawValue)])?.int(0) ?? 0
            }
        }
        return Int(total)
    }

    static func acceptLine(_ number: Int) -> String {
        count(number, "file can run a command or grant tools and waits for you to accept it on this Mac.",
              "files can run a command or grant tools and wait for you to accept them on this Mac.")
    }
    static func keptLine(_ number: Int) -> String {
        count(number, "file on this Mac differs from a version saved by another device. This Mac's file is in place; the other version is kept.",
              "files on this Mac differ from a version saved by another device. This Mac's files are in place; the other versions are kept.")
    }
    static func blockedLine(_ number: Int) -> String {
        count(number, "file could not be written: a link, a folder or a name differing only in letter case is in the way.",
              "files could not be written: a link, a folder or a name differing only in letter case is in the way.")
    }
    static func folderLine(_ number: Int) -> String {
        count(number, "boot file waits for a folder on this Mac.", "boot files wait for a folder on this Mac.")
    }

    /// What waits for one place on this Mac, and why. Each line makes the place's coverage incomplete.
    func waitLines(_ sourceId: String) throws -> [String] {
        var lines: [String] = []
        let accept = try waiting([.needsAccept], sourceId: sourceId)
        let kept = try waiting([.keptVersion, .otherVersion], sourceId: sourceId)
        let blocked = try waiting([.blocked], sourceId: sourceId)
        if accept > 0 { lines.append(Self.acceptLine(accept)) }
        if kept > 0 { lines.append(Self.keptLine(kept)) }
        if blocked > 0 { lines.append(Self.blockedLine(blocked)) }
        return lines
    }

    /// Boot files whose project has no folder here, or whose AI account is not on this Mac: one line for all.
    /// 13 Nov leftover: only files that really wait are counted. A file whose place is on this Mac now is not waiting
    /// for a folder any more, even before the next look has cleared its line.
    func notOnThisMac() throws -> CloudCoverage? {
        var number = 0, bytes: Int64 = 0
        for row in try state().rows("SELECT source_id, COUNT(*), COALESCE(SUM(bytes),0) FROM boot_items WHERE kind='waiting-folder' GROUP BY source_id")
        where places[row.text(0)] == nil {
            number += Int(row.int(1)); bytes += row.int(2)
        }
        guard number > 0 else { return nil }
        return CloudCoverage(sourceId: Self.coverageId("not-on-this-mac"), inventoryRow: CloudBootFilesFormat.inventoryRow, complete: false, items: number,
                             bytes: bytes, blockedReasons: [Self.folderLine(number)], exclusions: [])
    }

    /// For the context-ready barrier: not ready while a boot file is not in place (no folder, not accepted, or
    /// something in the way). A version kept beside this Mac's file is named but does not hold readiness back.
    public func readiness() async throws -> CloudVerification {
        let folder = try notOnThisMac()?.items ?? 0
        let accept = try waiting([.needsAccept], sourceId: nil)
        let blocked = try waiting([.blocked], sourceId: nil)
        let kept = try waiting([.keptVersion, .otherVersion], sourceId: nil)
        let rows = try state().first("SELECT COUNT(*) FROM boot_base")?.int(0) ?? 0
        let inPlace = Int(rows)
        var reasons: [String] = []
        if folder > 0 { reasons.append(Self.folderLine(folder)) }
        if accept > 0 { reasons.append(Self.acceptLine(accept)) }
        if blocked > 0 { reasons.append(Self.blockedLine(blocked)) }
        if kept > 0 { reasons.append(Self.keptLine(kept)) }
        let unsettled = folder + accept + blocked
        return CloudVerification(verified: unsettled == 0, counts: CloudCounts(domains: 1, records: inPlace, files: inPlace, bytes: 0, blocked: unsettled),
                                 reasons: reasons)
    }
}
