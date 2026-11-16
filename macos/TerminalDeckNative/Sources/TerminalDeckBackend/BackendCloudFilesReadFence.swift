import Foundation
import TerminalDeckNativeCore

/// CLOUD-FILES-5 (Security, 14 Nov: three blockers on reading an instruction file's text). THE one rule for showing the
/// text of an instruction file on the Cloud page, used by the page and by `cloud.item_open` alike (the same for the
/// person and for an AI):
/// - only a path the instruction-file sync itself accepts from a project folder (`CloudBootFilesRules.refusal(kind:
///   .project)` = nil: CLAUDE.md / AGENTS.md / GEMINI.md at the top; `.claude/agents|skills|commands/…`,
///   `.agents|.codex|.gemini/skills/…`; never settings, hooks, MCP, permission, sign-in, key or secret-named files,
///   hidden names, a `hooks` folder), plus the few page-only refusals below;
/// - and only a path THIS Mac's own scan of that folder listed as an instruction file (a Cloud record alone, which any
///   signed-in device can write, never names a path to read);
/// - read only through `BackendCloudBootFilesDisk.read` (no link followed at any folder step, a normal file only, one
///   hard name only, size checked before reading, opened without blocking), at most 1 MB;
/// - never anything in an AI account's own settings folder (not read from disk here).
/// Refused = no text, and the page says `refusedLine`.
public enum BackendCloudFilesReadFence {
    public static let refusedLine = "This file's text is not shown here."
    /// The most of a file's text the page shows; the rest is said with "…".
    public static let shownLimit = 262_144

    /// Page-only refusals the sync's list does not spell out (Security's list; gaps reported to the Security seat):
    /// any `mcp*.json`, any `.keychain*` ending, a `.git` folder step.
    static func pageRefuses(_ pieces: [String]) -> Bool {
        guard let last = pieces.last?.lowercased() else { return true }
        if last.hasPrefix("mcp") && last.hasSuffix(".json") { return true }
        if last.contains(".keychain") { return true }
        return pieces.contains { $0.lowercased() == ".git" || $0.lowercased() == "hooks" }
    }
    /// True when `relative` (a path inside a project folder) may ever have its text shown. `home` = an AI account's
    /// settings folder: never.
    public static func allowed(_ relative: String, home: CloudBootFilesPlaceKind? = nil) -> Bool {
        guard home == nil || home == .project else { return false }
        guard CloudBootFilesRules.refusal(kind: .project, relative: relative) == nil, let pieces = CloudBootFilesRules.parts(relative) else { return false }
        return !pageRefuses(pieces)
    }
    /// The text of `relative` inside `root` (the project's folder the sync uses on this Mac), or nil (refused, absent,
    /// a link, not a normal file, too large, not text). `listed`: this Mac's own scan of that folder listed the path.
    public static func read(root: URL, relative: String, listed: Bool, home: CloudBootFilesPlaceKind? = nil) -> String? {
        guard listed, allowed(relative, home: home) else { return nil }
        guard case .file(let bytes) = BackendCloudBootFilesDisk.read(root: root, relative: relative, cap: CloudBootFilesFormat.maximumFileBytes) else { return nil }
        return text(bytes, limit: shownLimit)
    }
    /// The text of the first `limit` bytes: nil for anything with a zero byte or that is not UTF-8 (a letter cut at the
    /// end is left out, and "…" says there is more). Also the guard for an earlier version's kept copy.
    public static func text(_ data: Data, limit: Int = shownLimit) -> String? {
        let more = data.count > limit
        var part = data.prefix(limit)
        if part.contains(0) { return nil }
        for _ in 0..<4 {
            if let text = String(data: part, encoding: .utf8) { return more ? text + "\n…" : text }
            guard !part.isEmpty else { break }
            part = part.dropLast()
        }
        return nil
    }
}

extension BackendCloudBootFiles {
    /// CLOUD-FILES-5: true when this Mac's own scan of the project's chosen folder listed `relative` as an instruction
    /// file (the folder and this Mac's copy agreed on it: `boot_base`). Read only.
    public func listedHere(projectId: String, relative: String) -> Bool {
        let source = BackendCloudBootFiles.sourceId(kind: .project, identity: projectId)
        return (try? state().first("SELECT 1 FROM boot_base WHERE source_id=? AND path=?", [.text(source), .text(relative)])) != nil
    }
}
