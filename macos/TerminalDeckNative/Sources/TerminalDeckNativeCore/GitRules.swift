import Foundation

/// Source control, the native screen's pure half — the Swift reading of
/// `components/GitPanel.tsx`, rule for rule. Status comes from `git:watch` /
/// `git:status` (and `git:status-changed` pushes), a file's change from
/// `git:diff`, a new repository from `git:init`.

public enum GitFileGroup: String, Sendable, Equatable, CaseIterable {
    case staged, unstaged, untracked, conflicted
}

public enum GitChangeKind: String, Sendable, Equatable {
    case added, modified, deleted, renamed, copied, typechange, untracked, conflicted, unknown
}

public struct GitFile: Equatable, Sendable, Identifiable {
    public var path: String
    public var origPath: String?
    public var group: GitFileGroup
    public var code: String
    public var kind: GitChangeKind
    public var insertions: Int?
    public var deletions: Int?
    public var binary: Bool
    public var id: String { "\(group.rawValue):\(path)" }

    public init(path: String, origPath: String? = nil, group: GitFileGroup, code: String = " M", kind: GitChangeKind,
                insertions: Int? = nil, deletions: Int? = nil, binary: Bool = false) {
        self.path = path
        self.origPath = origPath
        self.group = group
        self.code = code
        self.kind = kind
        self.insertions = insertions
        self.deletions = deletions
        self.binary = binary
    }

    init?(json: Any?, group fallback: GitFileGroup) {
        guard let row = json as? [String: Any], let path = row["path"] as? String, !path.isEmpty else { return nil }
        func count(_ key: String) -> Int? { row[key] is NSNumber ? Int(DeviceJSON.number(row[key])) : nil }
        self.init(path: path, origPath: (row["origPath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  group: GitFileGroup(rawValue: row["group"] as? String ?? "") ?? fallback,
                  code: row["code"] as? String ?? "", kind: GitChangeKind(rawValue: row["kind"] as? String ?? "") ?? .unknown,
                  insertions: count("insertions"), deletions: count("deletions"), binary: row["binary"] as? Bool ?? false)
    }
}

public struct GitBranch: Equatable, Sendable {
    public var name: String?
    public var detached: Bool
    public var oid: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int

    public init(name: String?, detached: Bool = false, oid: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.name = name
        self.detached = detached
        self.oid = oid
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    /// `main`, `detached at 1a2b3c4`, or `no branch`.
    public var label: String {
        if detached { return "detached at \(oid.map { String($0.prefix(7)) } ?? "unknown")" }
        return name ?? "no branch"
    }
}

public enum GitUnavailableReason: String, Sendable, Equatable {
    case notARepo = "not-a-repo", gitMissing = "git-missing", noSuchFolder = "no-such-folder", error
}

public struct GitRepoStatus: Equatable, Sendable {
    public var cwd: String
    public var root: String
    public var branch: GitBranch
    public var staged: [GitFile]
    public var unstaged: [GitFile]
    public var untracked: [GitFile]
    public var conflicted: [GitFile]
    public var clean: Bool

    public init(cwd: String = "", root: String = "", branch: GitBranch, staged: [GitFile] = [], unstaged: [GitFile] = [],
                untracked: [GitFile] = [], conflicted: [GitFile] = [], clean: Bool? = nil) {
        self.cwd = cwd
        self.root = root
        self.branch = branch
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.clean = clean ?? (staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty)
    }

    public var changeCount: Int { staged.count + unstaged.count + untracked.count + conflicted.count }
}

public enum GitStatusResult: Equatable, Sendable {
    case repo(GitRepoStatus)
    case notRepo(cwd: String, reason: GitUnavailableReason, message: String, canInit: Bool)

    public init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        let cwd = row["cwd"] as? String ?? ""
        if row["repo"] as? Bool == true {
            let b = row["branch"] as? [String: Any] ?? [:]
            let branch = GitBranch(name: b["name"] as? String, detached: b["detached"] as? Bool ?? false, oid: b["oid"] as? String,
                                   upstream: b["upstream"] as? String, ahead: Int(DeviceJSON.number(b["ahead"])),
                                   behind: Int(DeviceJSON.number(b["behind"])))
            func files(_ key: String, _ group: GitFileGroup) -> [GitFile] {
                (row[key] as? [Any] ?? []).compactMap { GitFile(json: $0, group: group) }
            }
            let status = GitRepoStatus(cwd: cwd, root: row["root"] as? String ?? cwd, branch: branch,
                                       staged: files("staged", .staged), unstaged: files("unstaged", .unstaged),
                                       untracked: files("untracked", .untracked), conflicted: files("conflicted", .conflicted),
                                       clean: row["clean"] as? Bool)
            self = .repo(status)
        } else {
            self = .notRepo(cwd: cwd, reason: GitUnavailableReason(rawValue: row["reason"] as? String ?? "") ?? .error,
                            message: row["message"] as? String ?? "", canInit: row["canInit"] as? Bool == true)
        }
    }

    public var repo: GitRepoStatus? {
        if case .repo(let status) = self { return status }
        return nil
    }
}

public struct GitGroup: Equatable, Sendable, Identifiable {
    public var key: GitFileGroup
    public var label: String
    public var files: [GitFile]
    public var id: String { key.rawValue }
}

public enum GitDiffLineKind: String, Sendable, Equatable { case add, del, hunk, meta, context }

public struct GitDiffLine: Equatable, Sendable {
    public var kind: GitDiffLineKind
    public var text: String
}

/// What the page shows instead of the list when there is no repository to read.
public struct GitUnavailableView: Equatable, Sendable {
    public var title: String
    public var message: String
    public var canInit: Bool
}

public enum GitRules {
    public static let maxRowsPerGroup = 500
    public static let maxDiffLines = 2000
    public static let watchDeadlineSeconds = 15.0
    public static let diffDeadlineSeconds = 10.0

    /// `Added`, `Modified` … or git's own letters when the kind is one this app does not know.
    public static func changeLabel(_ kind: GitChangeKind, code: String) -> String {
        let word: String = switch kind {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typechange: "Type"
        case .untracked: "Untracked"
        case .conflicted: "Conflict"
        case .unknown: ""
        }
        if !word.isEmpty { return word }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : trimmed
    }

    public static func groupState(_ group: GitFileGroup) -> String {
        switch group {
        case .conflicted: "needs resolving"
        case .staged: "ready to commit"
        case .unstaged: "not staged yet"
        case .untracked: "not tracked yet"
        }
    }

    static func unavailableTitle(_ reason: GitUnavailableReason) -> String {
        switch reason {
        case .notARepo: "Nothing to track here"
        case .gitMissing: "git is not installed"
        case .noSuchFolder: "That folder is gone"
        case .error: "Source control is unavailable"
        }
    }

    /// The title, the sentence, and whether "Create a repository" is offered.
    public static func unavailable(_ status: GitStatusResult?, hasInit: Bool = true) -> GitUnavailableView {
        guard case let .notRepo(_, reason, message, canInitHere)? = status else {
            return GitUnavailableView(title: unavailableTitle(.error), message: "git could not read this folder", canInit: false)
        }
        let canInit = canInitHere && hasInit
        return GitUnavailableView(title: unavailableTitle(reason),
                                  message: canInit ? "This folder is not a git repository." : message, canInit: canInit)
    }

    /// The four headings, in the Overview tile's order, only those with files.
    public static func groups(_ status: GitRepoStatus) -> [GitGroup] {
        [GitGroup(key: .conflicted, label: "Conflicts", files: status.conflicted),
         GitGroup(key: .staged, label: "Staged", files: status.staged),
         GitGroup(key: .unstaged, label: "Changes", files: status.unstaged),
         GitGroup(key: .untracked, label: "Untracked", files: status.untracked)].filter { !$0.files.isEmpty }
    }

    public static func baseName(_ path: String) -> String {
        let folder = path.hasSuffix("/")
        let trimmed = folder ? String(path.dropLast()) : path
        guard let cut = trimmed.lastIndex(of: "/") else { return path }
        return String(trimmed[trimmed.index(after: cut)...]) + (folder ? "/" : "")
    }

    public static func dirName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let cut = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[..<cut])
    }

    /// `old → new` for a rename, else the path.
    public static func describe(_ file: GitFile) -> String {
        file.origPath.map { "\($0) → \(file.path)" } ?? file.path
    }

    /// The row's second, quieter text: where it came from, or its folder.
    public static func rowDetail(_ file: GitFile) -> String {
        file.origPath.map { "← \($0)" } ?? dirName(file.path)
    }

    /// The row's hover.
    public static func rowTitle(_ file: GitFile) -> String {
        let code = file.code.trimmingCharacters(in: .whitespaces)
        return "\(describe(file)) — git status \(code.isEmpty ? "?" : code)"
    }

    /// The question `git:diff` is asked for a file in this group.
    public static func diffMode(_ group: GitFileGroup) -> [String: Bool] {
        switch group {
        case .staged: ["staged": true]
        case .untracked: ["untracked": true]
        default: [:]
        }
    }

    /// Why a file has no diff to show, or nil when it should have one.
    public static func noDiffReason(_ file: GitFile) -> String? {
        if file.path.hasSuffix("/") {
            return "This is a folder git has not looked inside yet — it lists the whole folder as one untracked entry. Commit or ignore it and the files inside get their own rows."
        }
        if file.binary { return "A binary file. There is no text to line up side by side." }
        return nil
    }

    /// The file chosen when nothing is, or the choice left the list: the first that has a diff.
    public static func firstChoice(_ groups: [GitGroup]) -> String? {
        let rows = groups.flatMap(\.files)
        return (rows.first { noDiffReason($0) == nil } ?? rows.first)?.path
    }

    /// `Modified · not staged yet · +3 −1`, or `… · binary`.
    public static func diffMeta(_ file: GitFile, group: GitFileGroup) -> String {
        var parts = ["\(changeLabel(file.kind, code: file.code)) · \(groupState(group))"]
        if file.binary {
            parts.append("binary")
        } else {
            let counts = [file.insertions.flatMap { $0 > 0 ? "+\($0)" : nil }, file.deletions.flatMap { $0 > 0 ? "−\($0)" : nil }]
                .compactMap { $0 }.joined(separator: " ")
            if !counts.isEmpty { parts.append(counts) }
        }
        return parts.joined(separator: " · ")
    }

    /// git's unified diff as lines: headers are meta (never painted red and green), the hunk line kept.
    public static func parseUnifiedDiff(_ text: String) -> [GitDiffLine] {
        guard !text.isEmpty else { return [] }
        var raw = text.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        return raw.map { line in
            if line.hasPrefix("@@") { return GitDiffLine(kind: .hunk, text: line) }
            for prefix in ["+++", "---", "diff ", "index ", "\\", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode"]
            where line.hasPrefix(prefix) {
                return GitDiffLine(kind: .meta, text: line)
            }
            if line.hasPrefix("+") { return GitDiffLine(kind: .add, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return GitDiffLine(kind: .del, text: String(line.dropFirst())) }
            return GitDiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)
        }
    }

    /// `1,234 more lines not shown.`
    public static func moreLines(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: count)) ?? String(count)) more lines not shown."
    }

    /// The note when git reports no text change for a file where it is.
    public static func noTextChange(_ group: GitFileGroup) -> String {
        "git reports no text change for this file where it is — \(groupState(group)). Its counterpart in another group may hold the change."
    }
}
