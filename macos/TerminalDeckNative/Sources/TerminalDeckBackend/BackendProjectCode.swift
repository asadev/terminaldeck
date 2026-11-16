import Foundation
import Darwin

/// Which Git repository is a project folder's code (14 Nov, CODE-PARENT). One rule for the Code page, the project
/// page (its header and Code card, the Code tab, the phone's Changes, the git.* tools), task workspaces (and the Chat
/// worktrees and parallel jobs built on them), the GitHub card, Readiness and the file list.
///
/// A repository is the folder's code when its top folder IS the project folder or lies INSIDE it (a worktree's or a
/// submodule's top is its own folder, so those are this case). A repository whose top lies ABOVE the folder is used
/// only for a folder inside his own checkout (a monorepo's sub-folder), and only when:
/// - its top is not the home folder or above it, nor the Terminal Deck folder or above it;
/// - no folder the app made (a project from his Cloud) lies between the folder and that top, the folder included;
/// - that repository already TRACKS files inside the folder (`ls-files -- <folder>`): a big unrelated repository at
///   `~/Documents` does not make `~/Documents/Foo` its code. A new, empty sub-folder of a real monorepo reads as a
///   plain folder until something in it is committed.
/// So a Mac whose home folder (or `~/Documents`) is itself a repository never shows, counts, commits, pushes, merges
/// or backs up that repository as a project's code.
public enum BackendProjectCode {
    public struct Bounds: Sendable {
        /// The home folders (the real one and, in tests, a scratch one); a repository at or above any is never used.
        public var homes: [String]
        /// The Terminal Deck folder (Settings, else `~/Terminal Deck`); a repository at or above it is never used.
        public var base: String?
        /// True for a folder the app made for a project from the Cloud.
        public var madeByApp: @Sendable (String) -> Bool

        public init(homes: [String], base: String?, madeByApp: @escaping @Sendable (String) -> Bool) {
            self.homes = homes; self.base = base; self.madeByApp = madeByApp
        }

        /// This Mac's: the real home folder, the installed project-folders owner's home and Terminal Deck folder.
        public static func live() -> Bounds {
            let folders = BackendProjectFolders.installed
            var homes = [NSHomeDirectory()]
            if let home = folders?.homeFolder, !homes.contains(home) { homes.append(home) }
            let base = folders?.terminalDeckFolder ?? BackendProjectFolders.defaultBase().path
            return Bounds(homes: homes, base: base, madeByApp: { BackendProjectFolders.installed?.madeByApp($0) == true })
        }
    }

    /// Runs one read-only Git command in `cwd` and answers what it printed (even when cut off by an output cap), or
    /// nil when Git could not run.
    public typealias Probe = @Sendable (_ cwd: String, _ arguments: [String]) async -> String?

    /// The hard part of the rule, answered without Git: false when the repository whose top Git named can never be
    /// this folder's code. True for its own repository, and for a parent repository that still needs `tracksInside`.
    public static func belongs(top: String, folder: String, bounds: Bounds) -> Bool {
        let top = resolved(top), place = resolved(folder)
        if inside(top, place) { return true }
        // Git's top always holds the folder; anything else (a core.worktree elsewhere) is not taken as his code.
        guard inside(place, top) else { return false }
        if bounds.madeByApp(folder) { return false }
        // Any folder the app made between the folder and the repository's top (the folder included).
        var step = place
        while step != top && step.count > top.count {
            if bounds.madeByApp(step) { return false }
            step = (step as NSString).deletingLastPathComponent
        }
        for home in bounds.homes where !home.isEmpty && inside(resolved(home), top) { return false }
        if let base = bounds.base, !base.isEmpty, inside(resolved(base), top) { return false }
        return true
    }

    /// The whole rule: `belongs`, and for a repository above the folder, that it already tracks files inside it.
    public static func owns(top: String, folder: String, bounds: Bounds, probe: Probe) async -> Bool {
        guard belongs(top: top, folder: folder, bounds: bounds) else { return false }
        let top = resolved(top), place = resolved(folder)
        if inside(top, place) { return true }
        return await tracksInside(top: top, folder: place, probe: probe)
    }

    /// The app made this folder for a project from the Cloud and it still holds only what the Cloud puts there:
    /// "Code not on this Mac yet". Anything else in it is his work.
    public static func waitingForCode(_ folder: String, bounds: Bounds) -> Bool {
        (bounds.madeByApp(folder) || bounds.madeByApp(resolved(folder))) && BackendProjectFolders.holdsOnlyCloudFiles(folder)
    }

    /// The folder Git would take as the repository's top without being asked: the nearest folder from `folder`
    /// upward (the folder itself first) that holds a `.git`. For callers whose Git calls are not changed by the rule.
    public static func nearestTop(_ folder: String) -> String? {
        var path = resolved(folder)
        for _ in 0..<128 {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return path }
            guard path != "/" else { return nil }
            path = (path as NSString).deletingLastPathComponent
            if path.isEmpty { return nil }
        }
        return nil
    }

    /// The same rule for callers that do not ask Git for the top themselves: true when the folder's code is not on
    /// this Mac yet, or the repository Git would use for it is not its code. No repository at all is not refused.
    /// Git is asked (once, cached) only when a repository sits above the folder.
    public static func refuses(_ folder: String, bounds: Bounds, probe: Probe) async -> Bool {
        if waitingForCode(folder, bounds: bounds) { return true }
        guard let top = nearestTop(folder) else { return false }
        return !(await owns(top: top, folder: folder, bounds: bounds, probe: probe))
    }

    /// Only the hard part, for a caller that cannot wait for Git (Stays Fixed's "has Git", which runs no Git and
    /// writes only inside the project folder).
    public static func refusesOutright(_ folder: String, bounds: Bounds) -> Bool {
        if waitingForCode(folder, bounds: bounds) { return true }
        guard let top = nearestTop(folder) else { return false }
        return !belongs(top: top, folder: folder, bounds: bounds)
    }

    // MARK: does the repository above already keep files in the folder

    /// Answers kept for a minute and until the repository's staging area changes (a commit, an add), so pages
    /// redrawing do not run Git each time.
    static let keepSeconds: TimeInterval = 60
    private static let lock = NSLock()
    nonisolated(unsafe) private static var kept: [String: (answer: Bool, mark: String, at: Date)] = [:]

    static func tracksInside(top: String, folder: String, probe: Probe) async -> Bool {
        let key = top + "\u{0}" + folder, mark = indexMark(top), now = Date()
        if let old = lock.withLock({ kept[key] }), old.mark == mark, now.timeIntervalSince(old.at) < keepSeconds { return old.answer }
        let relative = String(folder.dropFirst(top.hasSuffix("/") ? top.count : top.count + 1))
        // One tracked path is enough; a cut-off listing still proves it.
        let listed = await probe(top, ["ls-files", "-z", "--", ":(literal)" + relative])
        let answer = !(listed ?? "").isEmpty
        lock.withLock {
            if kept.count > 500 { kept = [:] }
            kept[key] = (answer, mark, now)
        }
        return answer
    }

    private static func indexMark(_ top: String) -> String {
        var info = stat()
        for path in [top + "/.git/index", top + "/.git"] where lstat(path, &info) == 0 {
            return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec).\(info.st_size)"
        }
        return "-"
    }

    static func forgetAnswers() { lock.withLock { kept = [:] } }

    /// The reason word and plain title the project page shows for such a folder.
    public static let notHereReason = "code-not-here"
    public static let notHereTitle = "Code not on this Mac yet"

    static func resolved(_ path: String) -> String {
        guard let real = Darwin.realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    /// `path` is `folder` or lies inside it.
    static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
