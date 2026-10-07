import Foundation
import TerminalDeckNativeCore

/// fleet-diff.ts: every changed row remains present; only diff text is bounded.
/// Attribution is evidence from modification time and actual session views,
/// with ambiguity preserved rather than claiming who wrote a shared file.
public struct BackendGitReview: Sendable {
    private let git: BackendGitService
    private let sessions: @Sendable () async -> [NativeRPCValue]
    public init(git: BackendGitService, sessionViews: @escaping @Sendable () async -> [NativeRPCValue]) { self.git = git; sessions = sessionViews }
    public func collect(cwd: String, path: String? = nil, maxFiles: Int = 25, context: NativeRPCContext) async throws -> NativeRPCValue {
        let status = try await git.status(cwd: cwd, context: context)
        let root = status["root"].string ?? cwd
        let here = await sessions().filter {
            guard let folder = $0["cwd"].string else { return false }
            return folder == cwd || folder == root || folder.hasPrefix(root + "/")
        }.sorted { ($0["createdAt"].number ?? 0) > ($1["createdAt"].number ?? 0) }
        let descriptions = here.map { session in NativeRPCValue.object(["id", "title", "provider", "attention", "createdAt", "startedByCopilot"].map { .init($0, session[$0]) }) }
        if status["repo"].bool != true {
            return .object([.init("cwd", .string(cwd)), .init("repo", .bool(false)), .init("root", .null), .init("branch", .null),
                .init("ahead", .number(0)), .init("behind", .number(0)), .init("files", .array([])), .init("changedFiles", .number(0)),
                .init("withDiff", .number(0)), .init("diffChars", .number(0)), .init("bound", .string("none")), .init("sessions", .array(descriptions)),
                .init("attributionNote", .string("This folder is not a git repository, so there is nothing to diff.")), .init("reason", status["message"])])
        }
        var changed: [NativeRPCValue] = []
        for group in ["conflicted", "staged", "unstaged", "untracked"] {
            for row in status[group].elements ?? [] {
                changed.append(.object(["path", "group", "kind", "insertions", "deletions", "binary"].map { .init($0, row[$0]) }))
            }
        }
        if let path { changed = changed.filter { $0["path"].string == path } }
        let cap = min(max(maxFiles, 1), 100)
        var rows: [NativeRPCValue] = [], chars = 0, withDiff = 0, bound = "none", certain = 0, shared = 0
        for (index, file) in changed.enumerated() {
            try Task.checkCancellation()
            let relative = file["path"].string ?? ""
            var modified: Double?
            if let target = try? await git.authority.resolve(root: root, relative: relative, context: context),
               let date = try? target.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { modified = date.timeIntervalSince1970 * 1_000 }
            let candidates = modified.map { at in here.filter { ($0["createdAt"].number ?? .infinity) <= at }.compactMap { $0["id"].string } } ?? []
            if candidates.count == 1 { certain += 1 }; if candidates.count > 1 { shared += 1 }
            let attribution = NativeRPCValue.object([.init("candidates", .array(candidates.map(NativeRPCValue.string))),
                .init("sessionId", candidates.count == 1 ? .string(candidates[0]) : .null), .init("modifiedAt", modified.map(NativeRPCValue.number) ?? .null),
                .init("reason", modified == nil ? .string(file["kind"].string == "deleted" ? "The file is gone, so there is no time on it to compare against." : "That file could not be read, so nothing can be said about when it changed.") : candidates.isEmpty ? .string("Written before any session in this folder started, so it is yours or an older one.") : .null)])
            var row = file.setting("attribution", attribution).setting("diff", .null).setting("diffTruncated", .bool(false)).setting("omitted", .null)
            if file["binary"].bool == true { row = row.setting("omitted", .string("binary")) }
            else if index >= cap { bound = "file-limit"; row = row.setting("omitted", .string("file-limit")) }
            else if chars >= 60_000 { bound = "byte-limit"; row = row.setting("omitted", .string("byte-limit")) }
            else {
                let raw = try await git.diff(cwd: cwd, path: relative,
                    options: .init(staged: file["group"].string == "staged", untracked: file["group"].string == "untracked"), context: context)
                if raw.isEmpty { row = row.setting("omitted", .string("empty")) }
                else {
                    let room = min(12_000, 60_000 - chars), cut = raw.utf16.count > room
                    let text = String(decoding: raw.utf16.prefix(room), as: UTF16.self)
                    if cut && bound != "file-limit" { bound = "byte-limit" }
                    chars += text.utf16.count; withDiff += 1
                    row = row.setting("diff", .string(text)).setting("diffTruncated", .bool(cut))
                }
            }
            rows.append(row)
        }
        let note: String
        if rows.isEmpty { note = "Nothing has changed in this folder." }
        else if here.isEmpty { note = "No session is running in this folder, so these changes are yours or an earlier one." }
        else {
            var parts: [String] = []
            if certain > 0 { parts.append("\(certain) traceable to one session") }
            if shared > 0 { parts.append("\(shared) that could be any of \(here.count) sessions here") }
            if rows.count - certain - shared > 0 { parts.append("\(rows.count - certain - shared) written before any of them started") }
            note = "\(rows.count) changed files: " + parts.joined(separator: ", ") + "."
        }
        return .object([.init("cwd", .string(cwd)), .init("repo", .bool(true)), .init("root", .string(root)), .init("branch", status["branch"]["name"]),
            .init("ahead", status["branch"]["ahead"]), .init("behind", status["branch"]["behind"]), .init("files", .array(rows)),
            .init("changedFiles", .number(Double(rows.count))), .init("withDiff", .number(Double(withDiff))), .init("diffChars", .number(Double(chars))),
            .init("bound", .string(bound)), .init("sessions", .array(descriptions)), .init("attributionNote", .string(note)), .init("reason", .null)])
    }
}
