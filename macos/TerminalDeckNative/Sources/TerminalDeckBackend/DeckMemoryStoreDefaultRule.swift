import Foundation
import TerminalDeckNativeCore

/// His own text beats an untouched app default (Decker, 14 Nov, under the owner's one rule).
///
/// On 14 Nov 09:26 Dubai the one-time settling of second copies (`cloudSettleTwin`) on the owner's Mac mini put the
/// MacBook's untouched default Hoot playbook and "lead" template settings in use over his own texts: both were first
/// copies with no common history, and the default's first-copy stamp was two minutes later. The MacBook had rightly
/// taken his texts when it joined (the arrival path never lets a shipped default stand against an arrival), so each
/// Mac held the other's text. Now every place that decides between two unrelated texts asks this rule first, and a
/// one-time repair puts his text back in use where the settling had displaced it.
extension DeckMemoryStore {
    static let defaultRepairKey = "oneRule:defaultRepair"

    /// Between two texts for `path` that are not built on each other: true = `first` is used, false = `second` is used,
    /// nil = this rule does not decide (both or neither is the app's shipped default; then the Cloud's history does).
    /// "Is it the default" is the arrival path's own test (`cloudShippedSeedHashes`, finding 19 / M6), never a second list.
    func cloudDefaultRule(_ path: String, first: String, second: String) throws -> Bool? {
        guard first != second else { return nil }
        let seeds = try cloudShippedSeedHashes(path)
        switch (seeds.contains(first), seeds.contains(second)) {
        case (true, false): return false
        case (false, true): return true
        default: return nil
        }
    }

    /// The one-time repair, once per Mac (control `oneRule:defaultRepair`), after the phase-1 safety copy.
    /// It acts ONLY on files the settling decided: the text in use at `path` is the version of a former second copy
    /// (its recorded version was placed at `archive/cloud-conflicts/...`: the settling's own record), that text is the
    /// app's default, and exactly one kept version of the same record is not a default and was the text in use at
    /// `path` (its revision was placed at `path` with exactly those bytes; the settling kept it with that revision).
    /// That one is made the text in use through `memoryUseVersion`'s own body: an ordinary edit on top of what the
    /// Cloud holds (the default stays a kept version), so the other Mac, already on that text, simply lines up.
    /// Returns the number of files put back.
    func cloudRepairDefaultInUse() throws -> Int {
        guard try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.defaultRepairKey)])?.string(0) != "done" else { return 0 }
        let keeper = try cloudKeeper()
        var repaired = 0
        let settled = try db.rows("""
            SELECT o.path,o.resource_key FROM cloud_memory_file_origins o
            JOIN cloud_memory_versions v ON v.store_id=o.store_id AND v.resource_key=o.resource_key AND v.revision=o.version
            WHERE v.projection LIKE 'archive/cloud-conflicts/%' AND o.path NOT LIKE 'archive/%' ORDER BY o.path
            """)
        var failed: [String] = []
        for row in settled {
            let path = row.text(0), resourceKey = row.text(1)
            guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), FileManager.default.fileExists(atPath: file.path) else { continue }
            // Review (14 Nov): one file that fails never stops the repair. Before, the error left before it was marked
            // done, so it ran again on every pass, failed on the same file, and (one step a pass) the archived settling
            // after it never ran. Now the failure is logged with its path and plain cause and the next file goes on.
            do {
                let current = try cloudHashFile(file), seeds = try cloudShippedSeedHashes(path)
                guard seeds.contains(current) else { continue }
                let item = Self.oneRuleItemKey(path)
                var own: Set<String> = []
                for kept in try keeper.versions(itemKey: item) where kept.sha256 != current && !seeds.contains(kept.sha256) {
                    guard let rev = try keeper.revision(itemKey: item, sha256: kept.sha256), rev.resourceKey == resourceKey,
                          let was = try db.first("SELECT projection,content_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?",
                                                 [.text(rev.storeId), .text(rev.resourceKey), .text(rev.revision)]),
                          was.string(0) == path, was.text(1) == kept.sha256 else { continue }
                    own.insert(kept.sha256)
                }
                // Never a guess: one candidate or nothing.
                guard own.count == 1, let sha = own.first else { continue }
                try cloudUseKeptVersion(path: path, versionId: sha)
            } catch {
                failed.append(path)
                let cause = (error as? DeckMemoryError)?.message ?? CloudSyncDiagnostics.kind(error)
                CloudSyncDiagnostics.shared.info("memory one rule: your own \(path) could not be put back on this Mac (\(cause)); it is left as it is")
                continue
            }
            repaired += 1
            CloudSyncDiagnostics.shared.info("memory one rule: your own \(path) is in use again on this Mac (the app's default had replaced it on 14 Nov)")
        }
        if repaired == 0, failed.isEmpty { CloudSyncDiagnostics.shared.info("memory one rule: nothing to put back on this Mac (no app default had replaced your own text)") }
        if !failed.isEmpty { CloudSyncDiagnostics.shared.info("memory one rule: put back \(repaired); could not put back: " + failed.joined(separator: ", ")) }
        // Always marked done, failures included: a failed file is named above, never retried on every pass.
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'done')", [.text(Self.defaultRepairKey)])
        return repaired
    }
}
