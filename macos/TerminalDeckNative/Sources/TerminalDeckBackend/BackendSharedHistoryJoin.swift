import Foundation
import Darwin
import TerminalDeckNativeCore

/// 10 Nov (Asad: "/resume can't see past chats when I switch account"). Every account folder the app made keeps its
/// own chat history (`<folder>/projects` for Claude, `<folder>/sessions` for Codex), so a session on another account
/// sees none of the chats of the folder. At every app start, before the saved tabs come back, each such folder joins
/// ONE history: the AI's own install's (`~/.claude/projects`, `~/.codex/sessions`), the same place
/// BackendAppSharedProjects' "share history" uses. The account's own history is merged into it and its folder
/// becomes a link to it.
///
/// Merge only: nothing is deleted or overwritten. A file already there with the same bytes is the same file (the
/// account's copy goes); on a name clash the newer one is the one shown and the other is kept beside it as
/// `<name>.kept-<time>` (a name the AIs do not list). The newer is not swapped in while the shown one was written in the
/// last ten minutes (a session may be writing it): the account's copy is kept beside it instead.
///
/// Left alone: folders the person pointed the app at (not the app's), a folder already linked somewhere else, and any
/// account a running session uses right now, or whose history was written in the last ten minutes (it joins at a
/// later start). Gemini keeps one login, so it has no
/// per-account history.
public enum BackendSharedHistoryJoin {
    public struct Outcome: Equatable, Sendable {
        public var joined: [String] = [], already: [String] = [], skipped: [String] = [], failed: [String] = []
        public var keptBeside = 0
    }
    /// The history folder of an account folder, per AI (nil: that AI keeps no per-account history the app shares).
    public static func historyFolder(_ provider: String) -> String? {
        switch provider { case "claude": "projects"; case "codex": "sessions"; default: nil }
    }
    public static let busyWindow: TimeInterval = 600

    /// `managed`: the account folder is one the app made (never one the person pointed it at). `inUse`: account ids a
    /// running session uses (as its login or its folder).
    public static func joinAll(_ accounts: [BackendAccountProfile], configuration: BackendAccountConfiguration,
                               managed: (BackendAccountProfile) async -> Bool, inUse: Set<String>, now: Date = Date()) async -> Outcome {
        var outcome = Outcome()
        for account in accounts where !account.system {
            guard let name = historyFolder(account.provider) else { continue }
            let root = URL(fileURLWithPath: configuration.systemDirectory(account.provider)).appendingPathComponent(name).standardizedFileURL
            guard await managed(account) else { outcome.skipped.append(account.id + ": not a folder the app made"); continue }
            if inUse.contains(account.id) { outcome.skipped.append(account.id + ": in use by a running session"); continue }
            do {
                switch try join(folder: URL(fileURLWithPath: account.configDir).appendingPathComponent(name), root: root, now: now) {
                case .already: outcome.already.append(account.id)
                case .joined(let kept): outcome.joined.append(account.id); outcome.keptBeside += kept
                case .elsewhere: outcome.skipped.append(account.id + ": its history is already a link to another place")
                case .busy: outcome.skipped.append(account.id + ": in use (its history was written in the last ten minutes)")
                }
            } catch { outcome.failed.append(account.id + ": " + error.localizedDescription) }
        }
        return outcome
    }

    enum Result: Equatable { case already, joined(kept: Int), elsewhere, busy }

    static func join(folder: URL, root: URL, now: Date) throws -> Result {
        let files = FileManager.default
        var info = stat()
        if Darwin.lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            let value = try files.destinationOfSymbolicLink(atPath: folder.path)
            let target = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : folder.deletingLastPathComponent().appendingPathComponent(value)).standardizedFileURL
            return target.path == root.path ? .already : .elsewhere
        }
        guard folder.standardizedFileURL.path != root.path else { return .already }
        // Something outside the app's sessions may be writing there (Hoot, a terminal `claude`): it joins later.
        if writtenRecently(folder, since: now.addingTimeInterval(-busyWindow)) { return .busy }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var kept = 0
        if files.fileExists(atPath: folder.path) {
            kept = try merge(from: folder, into: root, now: now)
            // Only an empty folder is removed; anything that could not move keeps the folder and the join waits.
            guard (try files.contentsOfDirectory(atPath: folder.path)).isEmpty else {
                throw BackendAccountFailure("part of this account's history could not be moved; it was left where it is")
            }
            try files.removeItem(at: folder)
        }
        try files.createSymbolicLink(at: folder, withDestinationURL: root)
        return .joined(kept: kept)
    }

    /// Moves everything under `from` into `into`. Answers how many clashing files were kept beside the shown one.
    static func merge(from: URL, into: URL, now: Date) throws -> Int {
        let files = FileManager.default
        var kept = 0
        for name in try files.contentsOfDirectory(atPath: from.path) {
            let source = from.appendingPathComponent(name), destination = into.appendingPathComponent(name)
            var origin = stat(), target = stat()
            guard Darwin.lstat(source.path, &origin) == 0 else { continue }
            guard Darwin.lstat(destination.path, &target) == 0 else {
                try files.moveItem(at: source, to: destination); continue
            }
            let a = origin.st_mode & S_IFMT, b = target.st_mode & S_IFMT
            if a == S_IFDIR, b == S_IFDIR {
                kept += try merge(from: source, into: destination, now: now)
                if (try files.contentsOfDirectory(atPath: source.path)).isEmpty { try files.removeItem(at: source) }
                continue
            }
            if a == S_IFREG, b == S_IFREG, origin.st_size == target.st_size,
               let mine = try? Data(contentsOf: source), let theirs = try? Data(contentsOf: destination), mine == theirs {
                try files.removeItem(at: source); continue   // the same file: nothing is lost
            }
            let stamp = String(Int64(now.timeIntervalSince1970 * 1000))
            let sourceTime = Double(origin.st_mtimespec.tv_sec), shownTime = Double(target.st_mtimespec.tv_sec)
            let shownBusy = now.timeIntervalSince1970 - shownTime < busyWindow
            if a == S_IFREG, b == S_IFREG, sourceTime > shownTime, !shownBusy {
                // The account's copy is newer: it is shown, the older one is kept beside it.
                try files.moveItem(at: destination, to: free(into.appendingPathComponent(name + ".kept-" + stamp)))
                try files.moveItem(at: source, to: destination)
            } else {
                try files.moveItem(at: source, to: free(into.appendingPathComponent(name + ".kept-" + stamp)))
            }
            kept += 1
        }
        return kept
    }
    static func writtenRecently(_ folder: URL, since: Date) -> Bool {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return false }
        for case let item as URL in walk {
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            if let date = values.contentModificationDate, date > since { return true }
        }
        return false
    }
    private static func free(_ url: URL) -> URL {
        var candidate = url, index = 2
        while FileManager.default.fileExists(atPath: candidate.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            candidate = URL(fileURLWithPath: url.path + "-\(index)"); index += 1
        }
        return candidate
    }
}
