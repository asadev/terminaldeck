import Foundation

/// The single command-name policy for skill writers, installers, discovery and prompts.
/// Keep aliases too: a command can claim a name even when hidden from the menu.
public enum SkillCommandNames {
    public static let ais = ["claude", "codex", "gemini"]
    // Updated 13 Oct 2026. Evidence and refresh instructions: macos/skills-command-names.md.
    public static let commands: [String: Set<String>] = [
        "claude": Set("add-dir advisor agents artifacts auto-mode-setup autocompact autofix-pr background branch brief btw bug cd chrome clear cloud-plugins color compact config context copy daemon design-consent design-login design-revoke desktop diff effort exit export extra-usage fast feedback focus fork goal heapdump help hooks ide import init insights install install-github-app install-slack-app keybindings list-agents login logout loops mcp memory mobile model output-style passes pause-memory permissions plan plugin powerup privacy-settings pro-trial-expired radio rate-limit-options recap release-notes reload-plugins reload-skills remote-control remote-env rename restart resume rewind sandbox scroll-speed session setup-bedrock setup-vertex skill-doctor skills status statusline stickers stop subtask tasks team-onboarding teleport terminal-setup theme tui ultraplan ultrareview upgrade usage usage-credits version voice web-setup wellbeing workflow-launch-exec workflows allowed-tools android app bashes bg break-reminder breaks checkpoint continue cost downtime ios marketplace memory-pause name new peers plugins quit rc remote reset settings share stats toggle-memory tp undo update batch code-review review doctor checkup schedule routines security-review workshop artifact-design artifact-diagramming commit cowork-plugin dataviz design explain-usage memory-types whiteboard prototype pr artifact-pr-review simplify verify workflow-authoring setup-claude setup-cowork loop proactive claude-api artifact-components claude-in-chrome debug design-sync fewer-permission-prompts keybindings-help update-config run run-skill-generator vim todos".split(separator: " ").map(String.init)),
        "codex": Set("model ide permissions keymap vim setup-default-sandbox experimental approve memories skills import hooks review rename new archive delete resume fork worktree app init compact recap plan voice goal agents side btw copy export raw tui diff mention status daemon warnings cd pwd cwd usage debug-config title statusline theme pets pet mcp apps plugins logout quit exit feedback rollout ps stop clean clear test-approval subagents debug-m-drop debug-m-update fast personality agent sandbox-add-read-dir".split(separator: " ").map(String.init)),
        "gemini": Set("about agents auth bug chat clear commands compress copy directory dir docs editor extensions help ? hooks ide init mcp memory model permissions plan policies privacy quit exit restore rewind resume settings shells bashes setup-github skills stats terminal-setup theme tools upgrade vim".split(separator: " ").map(String.init))
    ]
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
    public static func clashes(_ name: String, targets: [String] = ais) -> [String] {
        let key = normalized(name)
        return ais.filter { targets.contains($0) && commands[$0, default: []].contains(key) }
    }
    public static func note(_ name: String, targets: [String] = ais) -> String? {
        guard let ai = clashes(name, targets: targets).first else { return nil }
        let key = normalized(name)
        if ai == "claude" && (key == "vim" || key == "todos") {
            return "/\(key) is reserved for Claude skill names. Rename it?"
        }
        return "/\(key) is also a \(CodingAICatalog.label(ai)) command, so neither works. Rename it?"
    }
    public static func require(_ name: String, targets: [String] = ais) throws {
        if let note = note(name, targets: targets) { throw NativeRPCError(code: "reserved-skill-name", message: note) }
    }
    public static func suggestion(_ name: String) -> String {
        switch normalized(name) {
        case "resume": return "recover"
        case "status": return "where-are-we"
        default: return normalized(name) + "-skill"
        }
    }
    /// Names in .agents/skills are shared by Codex and Gemini; .claude/skills is Claude's.
    public static func targets(path input: String) -> [String] {
        let path = input.lowercased()
        if path.contains("/.claude/") { return ["claude"] }
        if path.contains("/.agents/") { return ["codex", "gemini"] }
        if path.contains("/.codex/") { return ["codex"] }
        if path.contains("/.gemini/") { return ["gemini"] }
        return ais
    }
    public static func protects(path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        for index in parts.indices where [".claude", ".codex", ".gemini", ".agents"].contains(parts[index]) && index + 2 < parts.count {
            if parts[index + 1] == "commands" { return true }
            if parts[index + 1] == "skills" && parts.last == "skill.md" { return true }
        }
        return false
    }
    /// Protect nested skills and slash-command files in installed archives, too.
    public static func requireFile(path: String, text: String, targets: [String]) throws {
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(where: { $0.lowercased() == "commands" }), index + 1 < parts.count {
            let command = parts[(index + 1)...].joined(separator: ":")
            try require((command as NSString).deletingPathExtension, targets: targets)
        }
        if parts.last?.lowercased() == "skill.md" {
            if parts.count > 1 { try require(parts[parts.count - 2], targets: targets) }
            for name in headerNames(text) {
                try require(name, targets: targets)
                guard ROUTINESSkillsRules.safeName(name) else { throw NativeRPCError.invalidArguments("Use a plain one-line skill name with letters, numbers, dots, dashes or underscores.") }
            }
        }
    }
    public static func isNameHeaderLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "name"
    }
    public static func headerName(_ text: String) -> String? {
        let names = headerNames(text)
        return names.first { !clashes($0).isEmpty } ?? names.last
    }
    private static func headerNames(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var result: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let clean = line.trimmingCharacters(in: .whitespaces)
            guard isNameHeaderLine(clean), let colon = clean.firstIndex(of: ":") else { continue }
            var raw = clean[clean.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let match = raw.range(of: #"\s+#.*$"#, options: .regularExpression) { raw.removeSubrange(match) }
            // YAML also allows two-digit hex escapes. Normalize these before JSON string decoding.
            raw = raw.replacingOccurrences(of: #"\\x([0-9a-fA-F]{2})"#, with: #"\\u00$1"#, options: .regularExpression)
            if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { result.append(decoded) }
            else { result.append(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
        }
        return result
    }
    public static var promptLine: String {
        "\n\nWhen writing or installing a skill or slash command, never use an AI's own command name. " +
        ais.map { "\(CodingAICatalog.label($0)): " + commands[$0, default: []].sorted().joined(separator: ", ") }.joined(separator: "; ") +
        ". Use recover instead of resume and where-are-we instead of status; for other clashes add -skill and say why in one line. " +
        "Use skills_create and skills_rename when available; they apply the same name guard. This also applies during project setup, agent creation and playbook work."
    }
}
