import Foundation
import TerminalDeckNativeCore

// TRUTH-B (12 Oct, SETTINGS-TRUTH.md): a skill added on the Skills page went only into `.claude/skills`, which Claude
// Code reads and Codex and Gemini do not. Both of those read the shared `.agents/skills` folder (the project's, and
// ~/.agents/skills for every project), so the page now puts a copy there too, marked as Terminal Deck's copy, and
// removes that copy (only a marked one) when the skill is removed.

public enum BackendSkillsMirror {
    public static let marker = ".terminaldeck-copy"

    /// `<base>/.claude/skills/<name>` → `<base>/.agents/skills/<name>`; nil for anything else.
    public static func counterpart(of skillFolder: URL) -> URL? {
        let skills = skillFolder.deletingLastPathComponent(), claude = skills.deletingLastPathComponent()
        guard skills.lastPathComponent == "skills", claude.lastPathComponent == ".claude" else { return nil }
        return claude.deletingLastPathComponent().appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(skillFolder.lastPathComponent, isDirectory: true)
    }

    private static func safeCounterpart(_ target: URL) -> Bool {
        let skills = target.deletingLastPathComponent(), agents = skills.deletingLastPathComponent()
        return [agents, skills, target].allSatisfy { url in
            !FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        } && URL(fileURLWithPath: BackendROUTINESSkillsScope.canonical(agents.path)).deletingLastPathComponent().path == BackendROUTINESSkillsScope.canonical(agents.deletingLastPathComponent().path)
    }
    /// Copies the skill for Codex and Gemini. A folder of the same name that is not ours is left alone.
    @discardableResult
    public static func mirror(_ skillFolder: URL) -> URL? {
        guard let target = counterpart(of: skillFolder),
              (try? skillFolder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              FileManager.default.fileExists(atPath: skillFolder.appendingPathComponent("SKILL.md").path) else { return nil }
        let fm = FileManager.default
        let skillFile = skillFolder.appendingPathComponent("SKILL.md")
        guard let data = try? Data(contentsOf: skillFile),
              (try? SkillCommandNames.requireFile(path: skillFile.path, text: String(decoding: data, as: UTF8.self), targets: SkillCommandNames.ais)) != nil,
              safeCounterpart(target) else { return nil }
        if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: target.appendingPathComponent(marker).path) { return nil }
        let parent = target.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".terminaldeck-stage-" + UUID().uuidString)
        let backup = parent.appendingPathComponent(".terminaldeck-backup-" + UUID().uuidString)
        var keptOld = false
        defer { try? fm.removeItem(at: stage) }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: skillFolder, to: stage)
            try Data(("A copy Terminal Deck keeps of " + skillFolder.path + " for Codex and Gemini. Removing the skill in Terminal Deck removes it.\n").utf8)
                .write(to: stage.appendingPathComponent(marker))
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: backup); keptOld = true }
            do { try fm.moveItem(at: stage, to: target) }
            catch {
                if keptOld { try? fm.moveItem(at: backup, to: target) }
                return nil
            }
            if keptOld { try? fm.removeItem(at: backup) }
            return target
        } catch { return nil }
    }

    /// Compare instructions on discovery so edits made outside the app reach the other AIs too.
    static func instructionsDiffer(_ source: URL) -> Bool {
        guard let target = counterpart(of: source), safeCounterpart(target),
              let original = try? Data(contentsOf: source.appendingPathComponent("SKILL.md")) else { return true }
        return (try? Data(contentsOf: target.appendingPathComponent("SKILL.md"))) != original
    }

    /// Removes Terminal Deck's copy (only one it marked).
    public static func unmirror(_ skillFolder: URL) {
        guard let target = counterpart(of: skillFolder),
              safeCounterpart(target), FileManager.default.fileExists(atPath: target.appendingPathComponent(marker).path) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// The skill folders under a `.claude/skills` root (to find what an install added).
    public static func folders(in root: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") })
    }
}
