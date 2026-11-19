import Foundation
import CryptoKit
import os
import TerminalDeckNativeCore

/// ONE SETUP FOR EVERY AI (Asad, 19 Nov 2026: "Every time when we do some upgrade, all models should react same.
/// Everything should be same when we change the model."). Kept by the app, never by the person: no question, no setting.
///
/// For one project folder it makes Claude Code, Codex and Gemini see the same setup:
/// - Skills: `.claude/skills`, `.agents/skills` (Codex and Gemini read it) and `.gemini/skills` (when the project has it)
///   hold the same skills, file for file. The newest copy of a skill wins; the replaced copy goes to the Trash.
/// - Rule files: a missing `AGENTS.md` or `GEMINI.md` is made as a marked pointer to `CLAUDE.md`.
/// - Agents: every `.claude/agents/<name>.md` gets `.codex/agents/<name>.toml` and `.gemini/agents/<name>.md`.
/// - Guards: every hook in `.claude/settings.json` gets its entry in `.codex/hooks.json` and `.gemini/settings.json`
///   where that AI has the same event.
///
/// A person's own file is never overwritten: the app only rewrites files (and hook entries) it marked as its own.
/// Everything it writes depends on the project's files alone, never on this Mac, so two Macs make the same bytes and the
/// instruction-file sync (row I09) carries them without a ping-pong. Nothing here runs anything.
public enum BackendAISetupKeeper {
    static let log = Logger(subsystem: "dev.terminaldeck.app", category: "ai-setup")
    /// First line of every file the app keeps (Codex TOML comment, Gemini YAML comment, Markdown comment).
    public static let markerWords = "Terminal Deck keeps this file"
    /// Hook entries the app added: Codex `statusMessage`, Gemini `name`.
    public static let hookMarker = "Terminal Deck guard"

    // MARK: Entry points

    /// Aligns the project that holds `cwd` (the folder itself or the nearest folder above it with `CLAUDE.md` or `.claude`),
    /// never the home folder or anything above it. Returns the log lines written (one per change).
    @discardableResult
    public static func align(cwd: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [String] {
        guard let root = projectRoot(containing: cwd, home: home) else { return [] }
        return align(project: root, now: now)
    }

    /// Session starts in the same project within a few seconds (a tab restore) align it once.
    private static let recent = OSAllocatedUnfairLock(initialState: [String: Date]())
    /// For a session start: aligned on a background thread, at most once per project every 5 seconds.
    public static func alignSoon(cwd: String) {
        guard let root = projectRoot(containing: cwd, home: FileManager.default.homeDirectoryForCurrentUser) else { return }
        let key = root.standardizedFileURL.path, now = Date()
        let due = recent.withLock { seen -> Bool in
            if let last = seen[key], now.timeIntervalSince(last) < 5 { return false }
            seen[key] = now
            return true
        }
        guard due else { return }
        Task.detached(priority: .utility) { align(project: root, now: now) }
    }

    /// Every part, in an order where each one sees the others' results. Returns the log lines (one per change).
    @discardableResult
    public static func align(project root: URL, now: Date = Date(), discard: Discard = toTrash) -> [String] {
        var lines: [String] = []
        lines += alignSkills(root, discard: discard)
        lines += alignRuleFiles(root)
        lines += alignAgents(root, discard: discard)
        lines += alignGuards(root).lines
        for line in lines { log.notice("\(line, privacy: .public)") }
        return lines
    }

    /// The project folder for a session's folder: the nearest folder (itself first) holding `CLAUDE.md` or `.claude`,
    /// strictly below the home folder. nil when there is none.
    public static func projectRoot(containing cwd: String, home: URL) -> URL? {
        guard cwd.hasPrefix("/") else { return nil }
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        var url = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        while url.path.hasPrefix(homePath + "/") {
            if regularFile(url.appendingPathComponent("CLAUDE.md")) || realFolder(url.appendingPathComponent(".claude")) { return url }
            url = url.deletingLastPathComponent()
        }
        _ = fm
        return nil
    }

    /// Where a replaced or retired copy goes. The app: the Trash, where the person can take it back. Tests: a folder.
    public typealias Discard = @Sendable (URL) throws -> Void
    public static let toTrash: Discard = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    // MARK: 3a Skills

    static let skillRoots = [".claude/skills", ".agents/skills", ".gemini/skills"]

    /// The skill folders of every root are made identical. A root that is a link is left alone, and two roots that are
    /// the same folder count once. `.gemini/skills` takes part only when the project already has it.
    static func alignSkills(_ root: URL, discard: Discard = toTrash) -> [String] {
        let fm = FileManager.default
        var roots: [URL] = []
        var seen = Set<String>()
        for relative in skillRoots {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            if isLink(url) || isLink(url.deletingLastPathComponent()) { continue }
            let exists = realFolder(url)
            if !exists && relative == ".gemini/skills" { continue }
            if exists, !seen.insert(url.resolvingSymlinksInPath().path).inserted { continue }
            roots.append(url)
        }
        guard roots.count > 1 else { return [] }
        var names = Set<String>()
        for url in roots where realFolder(url) {
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where !name.hasPrefix(".") {
                let folder = url.appendingPathComponent(name, isDirectory: true)
                if realFolder(folder), regularFile(folder.appendingPathComponent("SKILL.md")) { names.insert(name) }
            }
        }
        var lines: [String] = []
        for name in names.sorted() {
            // Each root's copy: fingerprint and newest time. A link or a non-folder under the name is left alone.
            var copies: [(root: URL, print: String?, newest: Date)] = []
            var blocked = false
            for url in roots {
                let folder = url.appendingPathComponent(name, isDirectory: true)
                if isLink(folder) || (exists(folder) && !realFolder(folder)) { blocked = true; break }
                if let scan = fingerprint(folder) { copies.append((url, scan.print, scan.newest)) }
                else { copies.append((url, nil, .distantPast)) }
            }
            if blocked { continue }
            let present = copies.filter { $0.print != nil }
            guard let winner = present.max(by: { $0.newest == $1.newest ? rank($0.root) > rank($1.root) : $0.newest < $1.newest }) else { continue }
            let behind = copies.filter { $0.print != winner.print }
            guard !behind.isEmpty else { continue }
            let source = winner.root.appendingPathComponent(name, isDirectory: true)
            var done: [String] = []
            for copy in behind where replaceSkill(from: source, to: copy.root.appendingPathComponent(name, isDirectory: true), discard: discard) {
                done.append(relativeName(copy.root, in: root))
            }
            if !done.isEmpty {
                lines.append("AI setup: skill \"" + name + "\" made the same for every AI (newest copy from " + relativeName(winner.root, in: root)
                             + ", copied to " + done.joined(separator: ", ") + ").")
            }
        }
        return lines
    }

    /// `.claude/skills` wins an exact tie, then `.agents/skills`.
    private static func rank(_ url: URL) -> Int {
        let path = url.path
        if path.hasSuffix("/.claude/skills") { return 0 }
        if path.hasSuffix("/.agents/skills") { return 1 }
        return 2
    }

    /// What a skill folder holds (paths and contents, the app's own marker and Finder files left out) and its newest
    /// file time. nil when the folder is absent.
    static func fingerprint(_ folder: URL) -> (print: String, newest: Date)? {
        guard realFolder(folder) else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return nil }
        var entries: [String] = []
        var newest = Date.distantPast
        let base = folder.standardizedFileURL.path
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == BackendSkillsMirror.marker || name == ".DS_Store" { continue }
            guard let info = try? url.resourceValues(forKeys: Set(keys)), info.isSymbolicLink != true, info.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            let runnable = FileManager.default.isExecutableFile(atPath: url.path) ? "x" : "-"
            entries.append(relative + "\t" + runnable + "\t" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            if let date = info.contentModificationDate, date > newest { newest = date }
        }
        return (entries.sorted().joined(separator: "\n"), newest)
    }

    /// Copies the winning skill over one other root's copy: staged beside it, the old copy to the Trash, then moved in.
    /// The app's marker (`BackendSkillsMirror.marker`) is kept when the old copy had it. False when nothing changed.
    static func replaceSkill(from source: URL, to target: URL, discard: Discard = toTrash) -> Bool {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".terminaldeck-stage-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: stage)
            let ownMarker = stage.appendingPathComponent(BackendSkillsMirror.marker)
            let hadMarker = regularFile(target.appendingPathComponent(BackendSkillsMirror.marker))
            if hadMarker, !regularFile(ownMarker) {
                try Data(("A copy Terminal Deck keeps of " + source.lastPathComponent + " for every AI.\n").utf8).write(to: ownMarker)
            } else if !hadMarker, regularFile(ownMarker) {
                try fm.removeItem(at: ownMarker)
            }
            if exists(target) {
                // The replaced copy is never destroyed: it goes to the Trash, where the person can take it back.
                try discard(target)
            }
            try fm.moveItem(at: stage, to: target)
            return true
        } catch {
            log.error("AI setup: a skill copy could not be made the same: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: 3b Rule files

    static func pointer(for file: String) -> String {
        let ai = file == "GEMINI.md" ? "Gemini" : "Codex"
        var text = "<!-- " + markerWords + " for " + ai + ": it points to CLAUDE.md. Write your own text here and Terminal Deck leaves it alone. -->\n"
        text += "# " + file + "\n\nRead `CLAUDE.md` in this folder: it holds this project's rules for every AI.\n"
        // Gemini reads the rules in directly with its import line.
        if file == "GEMINI.md" { text += "\n@./CLAUDE.md\n" }
        return text
    }

    /// A missing `AGENTS.md` / `GEMINI.md` beside a `CLAUDE.md` is made as a pointer. An existing file (his, or a link)
    /// is never touched.
    static func alignRuleFiles(_ root: URL) -> [String] {
        guard regularFile(root.appendingPathComponent("CLAUDE.md")) else { return [] }
        var lines: [String] = []
        for file in ["AGENTS.md", "GEMINI.md"] {
            let url = root.appendingPathComponent(file)
            guard !exists(url), !isLink(url) else { continue }
            if createOnly(url, Data(pointer(for: file).utf8)) { lines.append("AI setup: " + file + " made, pointing to CLAUDE.md.") }
        }
        return lines
    }

    // MARK: 3c Agents

    struct ClaudeAgent: Equatable {
        let file: String
        let name: String
        let description: String
        let body: String
    }

    /// `---` front matter with one-line `key: value` pairs, then the body. nil when the file has no front matter.
    static func parseAgent(file: String, text: String) -> ClaudeAgent? {
        var body = Substring(text)
        if body.unicodeScalars.first == "\u{FEFF}" { body = body.dropFirst() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var end: Int?
        for index in 1..<lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" { end = index; break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            fields[key] = value
        }
        guard let end else { return nil }
        let stem = (file as NSString).deletingPathExtension
        let rest = lines[(end + 1)...].joined(separator: "\n")
        let trimmed = rest.hasPrefix("\n") ? String(rest.dropFirst()) : rest
        return ClaudeAgent(file: stem, name: (fields["name"]?.isEmpty == false ? fields["name"]! : stem),
                           description: fields["description"] ?? "", body: trimmed)
    }

    static func tomlBasic(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return "\"" + out + "\""
    }
    static func tomlMultiline(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""   // never three quotes in a row
            case "\n", "\t": out.unicodeScalars.append(scalar)
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return "\"\"\"\n" + out + "\"\"\""
    }

    /// Codex: a role file. Its name may hold only ASCII letters, digits, spaces, hyphens and underscores, and its
    /// instructions may not be blank.
    static func codexAgent(_ agent: ClaudeAgent) -> String {
        let cleaned = String(agent.name.unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == " " || s == "-" || s == "_")) ? Character(s) : "-"
        })
        let body = agent.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? agent.description : agent.body
        var text = "# " + markerWords + " for Codex, the same as .claude/agents/" + agent.file + ".md. Change that file; this one follows it.\n"
        text += "name = " + tomlBasic(cleaned) + "\n"
        text += "description = " + tomlBasic(agent.description) + "\n"
        text += "developer_instructions = " + tomlMultiline(body.isEmpty ? agent.name : body) + "\n"
        return text
    }

    static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    /// Gemini: a local agent. Its name is a slug (lower-case letters, digits, hyphens and underscores). Model and tools
    /// are not copied: Claude's names mean nothing to Gemini, so the agent uses Gemini's own model and every tool.
    static func geminiAgent(_ agent: ClaudeAgent) -> String {
        var slug = String(agent.name.lowercased().unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_")) ? Character(s) : "-"
        })
        if slug.isEmpty { slug = "agent" }
        var text = "---\n# " + markerWords + " for Gemini, the same as .claude/agents/" + agent.file + ".md. Change that file; this one follows it.\n"
        text += "name: " + slug + "\n"
        text += "description: " + yamlQuoted(agent.description.isEmpty ? agent.name : agent.description) + "\n"
        text += "---\n\n" + agent.body
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// True when the file at `url` is one the app made (its marker in the first lines).
    static func appMade(_ url: URL) -> Bool {
        guard regularFile(url), let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data.prefix(400), as: UTF8.self).contains(markerWords)
    }

    static func alignAgents(_ root: URL, discard: Discard = toTrash) -> [String] {
        let fm = FileManager.default
        let claude = root.appendingPathComponent(".claude/agents", isDirectory: true)
        var agents: [ClaudeAgent] = []
        if realFolder(claude), !isLink(claude) {
            for file in ((try? fm.contentsOfDirectory(atPath: claude.path)) ?? []).sorted() where file.hasSuffix(".md") && !file.hasPrefix(".") {
                let url = claude.appendingPathComponent(file)
                guard regularFile(url), let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                      let agent = parseAgent(file: file, text: text) else { continue }
                agents.append(agent)
            }
        }
        var lines: [String] = []
        let targets: [(folder: String, ext: String, ai: String, make: (ClaudeAgent) -> String)] = [
            (".codex/agents", "toml", "Codex", codexAgent), (".gemini/agents", "md", "Gemini", geminiAgent)]
        for target in targets {
            let folder = root.appendingPathComponent(target.folder, isDirectory: true)
            if isLink(folder) || isLink(folder.deletingLastPathComponent()) { continue }
            var made = 0, removed = 0
            var wanted = Set<String>()
            for agent in agents {
                let url = folder.appendingPathComponent(agent.file + "." + target.ext)
                wanted.insert(url.lastPathComponent)
                let bytes = Data(target.make(agent).utf8)
                if exists(url) || isLink(url) {
                    // His own file under that name: left exactly as it is.
                    guard appMade(url), (try? Data(contentsOf: url)) != bytes else { continue }
                    if replaceFile(url, bytes) { made += 1 }
                } else if createOnly(url, bytes) { made += 1 }
            }
            // The app's own copy of an agent that is no longer in `.claude/agents` goes (his own files never do).
            if realFolder(folder) {
                for file in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix("." + target.ext) && !wanted.contains(file) {
                    let url = folder.appendingPathComponent(file)
                    if appMade(url), (try? discard(url)) != nil { removed += 1 }
                }
            }
            if made > 0 { lines.append("AI setup: \(made) agent\(made == 1 ? "" : "s") made the same for " + target.ai + ".") }
            if removed > 0 { lines.append("AI setup: \(removed) " + target.ai + " agent\(removed == 1 ? "" : "s") removed (gone from .claude/agents).") }
        }
        return lines
    }

    // MARK: 3d Guards

    /// Claude's hook events and their name for each AI, from each AI's own schema on this Mac (Codex 0.159.3: its
    /// built-in hook schemas; Gemini CLI 0.63.0: `docs/hooks/reference.md`). Absent = that AI has no such event.
    public static let codexEvents: [String: String] = [
        "PreToolUse": "PreToolUse", "PostToolUse": "PostToolUse", "PermissionRequest": "PermissionRequest", "UserPromptSubmit": "UserPromptSubmit",
        "Stop": "Stop", "SessionStart": "SessionStart", "SessionEnd": "SessionEnd", "PreCompact": "PreCompact", "PostCompact": "PostCompact",
        "SubagentStart": "SubagentStart", "SubagentStop": "SubagentStop"]
    public static let geminiEvents: [String: String] = [
        "PreToolUse": "BeforeTool", "PostToolUse": "AfterTool", "UserPromptSubmit": "BeforeAgent", "Stop": "AfterAgent",
        "SessionStart": "SessionStart", "SessionEnd": "SessionEnd", "Notification": "Notification", "PreCompact": "PreCompress"]
    /// Claude tool names and Gemini's built-in names for the same tools (Gemini `docs/reference/tools.md`).
    public static let geminiTools: [String: String] = [
        "Bash": "run_shell_command", "Edit": "replace", "MultiEdit": "replace", "Write": "write_file", "Read": "read_file", "Glob": "glob",
        "Grep": "grep_search", "LS": "list_directory", "WebFetch": "web_fetch", "WebSearch": "google_web_search"]
    /// Codex's names for its shell tool, matched beside Claude's `Bash` (Codex's hook input follows Claude's shape; which
    /// name its shell tool reports is not proven on this Mac, so every known one is matched and told to the guard as Bash).
    public static let codexShellNames = ["shell", "local_shell", "exec_command"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    /// The guard is told what Claude would tell it: tool and event names in Claude's words, so a guard written for Claude
    /// works unchanged (the input fields of the shell, write and edit tools have the same names in all three).
    static func translator(_ pairs: [(String, String)], field: String) -> [String] {
        pairs.map { "-e 's/\"" + field + "\"[[:space:]]*:[[:space:]]*\"" + $0.0 + "\"/\"" + field + "\":\"" + $0.1 + "\"/g'" }
    }
    static func wrap(_ command: String, translate: [String], findProject: Bool) -> String {
        var out = ""
        if findProject {
            // Codex gives hooks no project folder: the nearest folder holding `.codex/hooks.json` is it (portable: no path of this Mac).
            out += "d=\"$PWD\"; while [ \"$d\" != / ] && [ ! -f \"$d/.codex/hooks.json\" ]; do d=\"$(dirname \"$d\")\"; done; export CLAUDE_PROJECT_DIR=\"$d\"; "
        }
        if translate.isEmpty { return out + command }
        return out + "sed -E " + translate.joined(separator: " ") + " | { " + command + "\n}"
    }

    static func matcherFor(gemini matcher: String, event: String) -> String? {
        guard toolEvents.contains(event) else { return matcher.isEmpty ? "*" : matcher }
        if matcher.isEmpty || matcher == "*" { return "*" }
        var mapped: [String] = []
        for token in matcher.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let name = geminiTools[token] { if !mapped.contains(name) { mapped.append(name) } }
            else if token.hasPrefix("mcp__") {
                // Claude `mcp__server__tool` is Gemini `mcp_server_tool`.
                let name = "mcp_" + token.dropFirst(5).replacingOccurrences(of: "__", with: "_")
                if !mapped.contains(name) { mapped.append(name) }
            }
        }
        return mapped.isEmpty ? nil : mapped.joined(separator: "|")
    }
    static func matcherFor(codex matcher: String, event: String) -> String {
        guard toolEvents.contains(event), !matcher.isEmpty, matcher != "*" else { return matcher }
        var tokens = matcher.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.contains("Bash") { for name in codexShellNames where !tokens.contains(name) { tokens.append(name) } }
        return tokens.joined(separator: "|")
    }

    public struct GuardResult: Sendable, Equatable {
        public var lines: [String] = []
        /// "<AI>: <Claude event>" for each hook event that AI has no equivalent for.
        public var noEquivalent: [String] = []
    }

    /// The hook groups for one AI, built from Claude's settings.
    static func groups(claude hooks: [String: Any], ai: String, result: inout GuardResult) -> [String: [[String: Any]]] {
        var out: [String: [[String: Any]]] = [:]
        for event in hooks.keys.sorted() {
            guard let list = hooks[event] as? [[String: Any]] else { continue }
            let mapped = ai == "Codex" ? codexEvents[event] : geminiEvents[event]
            guard let target = mapped else { result.noEquivalent.append(ai + ": " + event); continue }
            for group in list {
                let matcher = group["matcher"] as? String ?? ""
                let targetMatcher: String
                if ai == "Codex" { targetMatcher = matcherFor(codex: matcher, event: event) }
                else {
                    guard let m = matcherFor(gemini: matcher, event: event) else { result.noEquivalent.append(ai + ": " + event + " " + matcher); continue }
                    targetMatcher = m
                }
                var handlers: [[String: Any]] = []
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    guard (handler["type"] as? String ?? "command") == "command", let command = handler["command"] as? String, !command.isEmpty else { continue }
                    var made: [String: Any] = ["type": "command"]
                    let timeout = (handler["timeout"] as? NSNumber)?.doubleValue
                    if ai == "Codex" {
                        var translate: [String] = []
                        if toolEvents.contains(event) { translate = translator(codexShellNames.map { ($0, "Bash") }, field: "tool_name") }
                        made["command"] = wrap(command, translate: translate, findProject: command.contains("CLAUDE_PROJECT_DIR"))
                        if let timeout { made["timeout"] = Int(timeout.rounded()) }
                        made["statusMessage"] = hookMarker
                    } else {
                        var pairs: [(String, String)] = []
                        if toolEvents.contains(event) { pairs = geminiTools.sorted { $0.key < $1.key }.filter { $0.key != "MultiEdit" }.map { ($0.value, $0.key) } }
                        var translate = translator(pairs, field: "tool_name")
                        translate += translator(geminiEvents.sorted { $0.key < $1.key }.filter { $0.key != $0.value }.map { ($0.value, $0.key) }, field: "hook_event_name")
                        made["command"] = wrap(command, translate: translate, findProject: false)
                        // Gemini counts milliseconds; Claude seconds.
                        if let timeout { made["timeout"] = Int((timeout * 1000).rounded()) }
                        made["name"] = hookMarker
                    }
                    handlers.append(made)
                }
                guard !handlers.isEmpty else { continue }
                var made: [String: Any] = ["hooks": handlers]
                if !targetMatcher.isEmpty { made["matcher"] = targetMatcher }
                out[target, default: []].append(made)
            }
        }
        return out
    }

    /// Removes the app's own handlers (by marker) from a hooks object, then adds `generated`. His entries stay as they are.
    static func merged(_ existing: [String: Any], generated: [String: [[String: Any]]], markerKey: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, value) in existing {
            guard let list = value as? [Any] else { hooks[event] = value; continue }
            var kept: [Any] = []
            for item in list {
                guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else { kept.append(item); continue }
                let left = handlers.filter { (($0 as? [String: Any])?[markerKey] as? String) != hookMarker }
                if left.count == handlers.count { kept.append(item); continue }
                if left.isEmpty { continue }
                group["hooks"] = left
                kept.append(group)
            }
            if !kept.isEmpty { hooks[event] = kept }
        }
        for (event, groups) in generated { hooks[event] = (hooks[event] as? [Any] ?? []) + groups.map { $0 as Any } }
        return hooks
    }

    static func readJSONObject(_ url: URL) -> (exists: Bool, object: [String: Any]?) {
        guard exists(url) || isLink(url) else { return (false, [:]) }
        guard regularFile(url), let data = try? Data(contentsOf: url) else { return (true, nil) }
        if data.isEmpty { return (true, [:]) }
        return (true, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    static func alignGuards(_ root: URL) -> GuardResult {
        var result = GuardResult()
        let settings = root.appendingPathComponent(".claude/settings.json")
        var claudeHooks: [String: Any] = [:]
        if regularFile(settings) {
            guard let data = try? Data(contentsOf: settings), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                result.lines.append("AI setup: .claude/settings.json could not be read; the guards of Codex and Gemini are left as they are.")
                return result
            }
            claudeHooks = object["hooks"] as? [String: Any] ?? [:]
        }
        let targets: [(path: String, ai: String, marker: String)] = [(".codex/hooks.json", "Codex", "statusMessage"), (".gemini/settings.json", "Gemini", "name")]
        for target in targets {
            let url = root.appendingPathComponent(target.path)
            if isLink(url) || isLink(url.deletingLastPathComponent()) { continue }
            let generated = groups(claude: claudeHooks, ai: target.ai, result: &result)
            let current = readJSONObject(url)
            guard var object = current.object else {
                result.lines.append("AI setup: " + target.path + " is not plain settings; its guards are left as they are.")
                continue
            }
            // Nothing to add and nothing of the app's there: an absent file stays absent.
            if !current.exists && generated.isEmpty { continue }
            let hooks = merged(object["hooks"] as? [String: Any] ?? [:], generated: generated, markerKey: target.marker)
            if hooks.isEmpty { object.removeValue(forKey: "hooks") } else { object["hooks"] = hooks }
            guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { continue }
            let out = bytes + Data("\n".utf8)
            if current.exists {
                // Unchanged in meaning: his file is not rewritten (not even reformatted).
                if let old = try? Data(contentsOf: url), let before = try? JSONSerialization.jsonObject(with: old) as? NSDictionary,
                   before.isEqual(to: object) { continue }
                if replaceFile(url, out) { result.lines.append("AI setup: the guards in " + target.path + " made the same as Claude's.") }
            } else if createOnly(url, out) {
                result.lines.append("AI setup: " + target.path + " made with Claude's guards.")
            }
        }
        return result
    }

    // MARK: Files

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
    static func regularFile(_ url: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return info.isSymbolicLink != true && info.isRegularFile == true
    }
    static func realFolder(_ url: URL) -> Bool {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return info.isSymbolicLink != true && info.isDirectory == true
    }
    static func relativeName(_ url: URL, in root: URL) -> String {
        let base = root.standardizedFileURL.path + "/", path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }
    /// A new file: written beside, then linked into place; never over anything that appeared meanwhile.
    static func createOnly(_ url: URL, _ bytes: Data) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".terminaldeck-" + UUID().uuidString)
            try bytes.write(to: temporary, options: .withoutOverwriting)
            defer { try? fm.removeItem(at: temporary) }
            guard link(temporary.path, url.path) == 0 else { return false }
            return true
        } catch {
            log.error("AI setup: \(url.lastPathComponent, privacy: .public) could not be made: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    /// Replaces a file the app may change, keeping its permissions; atomic.
    static func replaceFile(_ url: URL, _ bytes: Data) -> Bool {
        guard regularFile(url) else { return false }
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        do {
            try bytes.write(to: url, options: .atomic)
            if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
            return true
        } catch {
            log.error("AI setup: \(url.lastPathComponent, privacy: .public) could not be updated: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
