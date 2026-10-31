import Foundation
import TerminalDeckNativeCore

// CONNECT-SKILLS (Asad "go", 11 Oct): a starter set of skills ships inside the app, for every person and every
// project: recover, save-session, deep-research, options-gallery, overnight-run, review-recording. They live in the
// app's Resources (built-in-skills/<name>/SKILL.md, sealed by the app's signature like the memory model), show on
// the Skills page as "Terminal Deck · built in", can be given to agents, and are named to every Claude and Codex
// session. A skill of the same name in the project (or the person's own skills folder) wins over the built-in one.
// Codex's own skills (~/.codex/skills/.system) are Codex's, labelled "Codex · built in".

public enum BackendBuiltInSkills {
    public static let folderName = "built-in-skills"
    public static let environmentKey = NativeLaunchSwitches.builtInSkillsFolder
    public static let source = "Terminal Deck · built in"
    public static let codexSource = "Codex · built in"

    /// The bundled folder (or the one `TD_BUILT_IN_SKILLS_DIR` names, for tests and the dev copy); nil when absent.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        let url: URL?
        if let custom = environment[environmentKey], custom.hasPrefix("/") { url = URL(fileURLWithPath: custom, isDirectory: true) }
        else { url = bundle.resourceURL?.appendingPathComponent(folderName, isDirectory: true) }
        guard let url else { return nil }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }

    /// The skills in the folder: folder name → name from its header (else the folder name), sorted.
    public static func names(in folder: URL?) -> [String] {
        guard let folder, let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return entries.sorted().compactMap { entry in
            guard !entry.hasPrefix(".") else { return nil }
            let file = folder.appendingPathComponent(entry).appendingPathComponent("SKILL.md")
            guard let data = FileManager.default.contents(atPath: file.path), data.count <= 262_144 else { return nil }
            let text = String(decoding: data.prefix(16_384), as: UTF8.self)
            let name = SkillCommandNames.headerName(text) ?? entry
            guard SkillCommandNames.clashes(name).isEmpty, SkillCommandNames.clashes(entry).isEmpty else { return nil }
            return name
        }
    }

    /// Does this project (or the person's own skills folder) have its own skill by that name? Then it wins.
    public static func ownCopy(_ name: String, projectFolder: String?, home: String = NSHomeDirectory()) -> Bool {
        var roots = [home + "/.claude/skills", home + "/.agents/skills"]
        if let projectFolder, projectFolder.hasPrefix("/") { roots = [projectFolder + "/.claude/skills", projectFolder + "/.agents/skills"] + roots }
        return roots.contains { FileManager.default.fileExists(atPath: $0 + "/" + name + "/SKILL.md") }
    }

    /// One line for an agent's brief: where the built-in skills it was given are, unless its project has its own.
    public static func briefLine(_ skills: [String], projectFolder: String?, folder: URL? = BackendBuiltInSkills.folder(),
                                 home: String = NSHomeDirectory()) -> String? {
        guard let folder else { return nil }
        let builtIn = Set(names(in: folder))
        let wanted = skills.filter { builtIn.contains($0) && !ownCopy($0, projectFolder: projectFolder, home: home) }
        guard !wanted.isEmpty else { return nil }
        let places = wanted.map { "\($0): " + folder.appendingPathComponent($0).appendingPathComponent("SKILL.md").path }
        return "Terminal Deck's built-in skills among them are read from the app, not from your skills folder. When one fits, read its file and follow it: " + places.joined(separator: "; ") + "."
    }

    /// The line every Claude and Codex session is given: the built-in skills and where to read them.
    public static func sessionLine(folder: URL? = BackendBuiltInSkills.folder()) -> String {
        let names = names(in: folder)
        guard let folder, !names.isEmpty else { return flowLine + SkillCommandNames.promptLine }
        return "\n\nTerminal Deck also ships its own skills (\(names.joined(separator: ", "))) in \(folder.path)/<name>/SKILL.md. " +
            "When a request fits one and this project has no skill of that name, read that SKILL.md and follow it." + flowLine + SkillCommandNames.promptLine
    }

    /// HOOT-FLOW (Asad, 12 Oct): the person follows each job live, with the rules applied (green tick) and each skill step.
    /// Only what the AI reports shows, so every session is told how to report it.
    public static let flowLine = "\n\nThe person follows your work live in Terminal Deck. If you have its deck-control tools, call " +
        "\(JobFlowWords.toolWire) (directly, or through tools_run) at the moment you apply one of your rules (rule: the note's id or the rule's " +
        "own words) and as you reach each step of a skill you follow (skill, step 1, 2, 3…, stepTitle). It changes nothing and asks nobody."
}
