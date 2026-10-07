import Foundation
import TerminalDeckNativeCore

/// The exact build-capability matrix from shared/agent-capabilities.ts.
/// Evidence is the source's historical observation, not a new CLI check.
public enum BackendSharedAgentCapabilities {
    public enum Support: String, CaseIterable, Sendable { case enforced, advisory, unsupported }
    public enum Setting: String, CaseIterable, Sendable { case model, effort, instructions, toolAdvice, blockedTools, skillsOff, skillSelection, mcpConfig, resumeById }
    public enum Family: String, CaseIterable, Sendable { case claude, codex, gemini, shell, custom }
    public struct Capability: Equatable, Sendable {
        public let support: Support
        public let how: String
        public let evidence: String
    }
    public static let checkedAgainst = ["claude": "Claude Code 2.1.289", "codex": "codex-cli 0.159.3", "gemini": "Gemini CLI — not installed on this Mac; its documentation only"]
    public static let supportTag: [Support: String] = [.enforced: "Enforced", .advisory: "Advice only", .unsupported: "Not available"]
    public static let capabilities: [Family: [Setting: Capability]] = [
        .claude: [
            .model: .init(support: .enforced, how: "Set in the session right after it starts, the way a person types /model.", evidence: "`claude --help` (2.1.289): `--model <model>`. The typed /model command and its confirmations are measured in `main/agent-controls.ts`; a refusal is said on the task."),
            .effort: .init(support: .enforced, how: "Set in the session right after it starts, the way a person types /effort.", evidence: "`claude --help` (2.1.289): `--effort <level>`. /effort is measured in `main/agent-controls.ts`."),
            .instructions: .init(support: .enforced, how: "Claude Code is started with the file added to its own system prompt, and the brief repeats it.", evidence: "`--append-system-prompt-file <file>`: not printed by `--help` in 2.1.289, but named there under `--bare` (\"--append-system-prompt[-file]\"), present in the binary’s option table, and Hoot is launched with it (`main/copilot-layer.ts`)."),
            .toolAdvice: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it. Claude Code’s own permission settings still decide.", evidence: "No flag prefers a tool. `--allowedTools` pre-approves, which is a permission, not a preference."),
            .blockedTools: .init(support: .enforced, how: "Claude Code refuses these tools itself.", evidence: "`claude --help` (2.1.289): `--disallowedTools <tools...>` \"Comma or space-separated list of tool names to deny\"."),
            .skillsOff: .init(support: .enforced, how: "Claude Code starts with no skills at all.", evidence: "`claude --help` (2.1.289): `--disable-slash-commands` \"Disable all skills\"."),
            .skillSelection: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it. Claude Code cannot be limited to only these.", evidence: "Investigated for 2.1.289: no flag limits the skills to a chosen set. `--disable-slash-commands` switches off every skill, including those in a folder added for one run with `--add-dir`, so a per-run skills folder cannot be the only one on; a `Skill(name)` deny rule refuses one named skill, not the built-in ones or any added later."),
            .mcpConfig: .init(support: .enforced, how: "Given its MCP servers on the command line.", evidence: "`claude --help` (2.1.289): `--mcp-config <configs...>` and `--strict-mcp-config`; every session this app starts gets its own tools this way."),
            .resumeById: .init(support: .enforced, how: "A reply continues the exact conversation, by its id.", evidence: "`claude --help` (2.1.289): `-r, --resume [value]` \"Resume a conversation by session ID\"."),
        ],
        .codex: [
            .model: .init(support: .unsupported, how: "Not set for Codex by this app yet: the model is changed by typing Claude Code’s command, which Codex does not take.", evidence: "`codex --help` (0.159.3): `-m, --model <MODEL>` exists at launch; this app does not pass it."),
            .effort: .init(support: .unsupported, how: "Not set for Codex by this app yet.", evidence: "Codex 0.159.3 has a `model_reasoning_effort` config key (in its `-c` schema) with levels of its own; this app does not pass it."),
            .instructions: .init(support: .enforced, how: "Codex is started with the file’s text as its developer instructions, and the brief repeats it.", evidence: "`codex --help` (0.159.3): `-c, --config <key=value>`. Measured 2026-10-05 with an empty CODEX_HOME and HOME: `codex debug prompt-input -c developer_instructions=\"…\"` put the text first in the developer message, and a `-c` before a subcommand reaches it. `model_instructions_file` is not used: it stands in for Codex’s own base instructions rather than adding to them."),
            .toolAdvice: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "Codex has sandbox and approval modes, not a preferred-tool list."),
            .blockedTools: .init(support: .unsupported, how: "Codex cannot refuse a named tool, so an agent with blocked tools is not started on it.", evidence: "`codex --help` (0.159.3) offers `--sandbox` and `--ask-for-approval`, not a per-tool deny list. `mcp_servers.<name>.disabled_tools` switches off an MCP server’s tools only, never Codex’s own."),
            .skillsOff: .init(support: .unsupported, how: "Not offered for Codex: switching every skill off could not be proven.", evidence: "Measured on 0.159.3: `-c skills.include_instructions=false` drops the skills list from the prompt, but whether a skill can still be found by its skill search was not established, so it is not called \"off\"."),
            .skillSelection: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it. Codex cannot be limited to only these.", evidence: "Measured on 0.159.3: `-c skills.config=[{path=…,enabled=false}]` hides one skill by its file, so Codex can switch off skills that were found, never limit itself to a chosen set. Skills are read from `$CODEX_HOME/skills`, `~/.agents/skills` and the project’s `.agents/skills`."),
            .mcpConfig: .init(support: .unsupported, how: "This app does not hand Codex an MCP configuration; it uses its own.", evidence: "Codex reads `[mcp_servers]` from its config.toml and takes `-c mcp_servers.<name>…` overrides; not passed by this app."),
            .resumeById: .init(support: .enforced, how: "A reply continues the exact conversation, by its id.", evidence: "`codex resume --help` (0.159.3): `[SESSION_ID]` \"Session id (UUID) or session name\"."),
        ],
        .gemini: [
            .model: .init(support: .unsupported, how: "Not set for Gemini by this app.", evidence: "Not installed on this Mac, so unverified here. The Gemini CLI documents `-m, --model`; this app does not pass it."),
            .effort: .init(support: .unsupported, how: "Gemini has no effort setting.", evidence: "Not installed on this Mac, so unverified here. No effort or reasoning-level option in the Gemini CLI documentation."),
            .instructions: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it. Gemini has no way to add standing instructions at the start.", evidence: "Not installed on this Mac, so unverified here. Its documented `GEMINI_SYSTEM_MD` replaces the whole system prompt instead of adding to it, so it is not used."),
            .toolAdvice: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "Nothing to check: the brief is plain text."),
            .blockedTools: .init(support: .unsupported, how: "Gemini cannot be started with tools refused, so an agent with blocked tools is not started on it.", evidence: "Not installed on this Mac, so unverified here. Gemini documents `excludeTools` in its settings file, not as a launch option."),
            .skillsOff: .init(support: .unsupported, how: "Not offered for Gemini.", evidence: "Not installed on this Mac, so unverified here. No launch option that switches skills off."),
            .skillSelection: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "Nothing to check: the brief is plain text."),
            .mcpConfig: .init(support: .unsupported, how: "This app does not hand Gemini an MCP configuration.", evidence: "Not installed on this Mac, so unverified here. Gemini documents `--allowed-mcp-server-names`; not used."),
            .resumeById: .init(support: .unsupported, how: "A reply after the session closed starts a new conversation.", evidence: "Gemini documents `--resume`, but resuming into an empty history was never exercised (`shared/agent-catalog.ts`), so it is not used."),
        ],
        .shell: [
            .model: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .effort: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .instructions: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .toolAdvice: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .blockedTools: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .skillsOff: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .skillSelection: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .mcpConfig: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
            .resumeById: .init(support: .unsupported, how: "A shell reads no brief and takes no agent settings.", evidence: "The platform’s own login shell."),
        ],
        .custom: [
            .model: .init(support: .unsupported, how: "Not set for an added agent.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .effort: .init(support: .unsupported, how: "Not set for an added agent.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .instructions: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .toolAdvice: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .blockedTools: .init(support: .unsupported, how: "An added agent cannot be started with tools refused.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .skillsOff: .init(support: .unsupported, how: "Not offered for an added agent.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .skillSelection: .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .mcpConfig: .init(support: .unsupported, how: "Not handed to an added agent.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
            .resumeById: .init(support: .unsupported, how: "A reply after the session closed starts afresh.", evidence: "An agent added on this Mac is a command and fixed arguments; nothing is known about its options."),
        ],
    ]
    public static func familyOf(_ provider: String?) -> Family {
        guard let provider else { return .claude }
        return ["claude", "codex", "gemini", "shell"].contains(provider) ? Family(rawValue: provider)! : .custom
    }
    public static func capabilityFor(_ provider: String?, setting: Setting) -> Capability {
        if provider == nil && setting == .instructions {
            return .init(support: .advisory, how: "Written into the brief this agent is given. A request: nothing makes it follow it. Choose Claude Code or Codex to have them given at the start as standing instructions.", evidence: "Which agent the app default is cannot be known when the agent is saved.")
        }
        return capabilities[familyOf(provider)]![setting]!
    }
    public static func enforces(_ provider: String?, setting: Setting) -> Bool { capabilityFor(provider, setting: setting).support == .enforced }
    public static func familiesEnforcing(_ setting: Setting) -> [Family] { Family.allCases.filter { capabilities[$0]![setting]!.support == .enforced } }
    public static func agentLabel(_ provider: String?) -> String {
        guard let provider else { return "The app’s default coding agent" }
        return CodingAICatalog.agent(provider)?.label ?? "An added agent"
    }
}

public enum BackendSharedAgentTools {
    public struct Tool: Equatable, Sendable { public let name: String; public let label: String }
    public static let claude: [Tool] = [
        .init(name: "Bash", label: "Run commands"), .init(name: "Read", label: "Read files"), .init(name: "Write", label: "Write new files"), .init(name: "Edit", label: "Edit files"), .init(name: "MultiEdit", label: "Several edits at once"), .init(name: "NotebookEdit", label: "Edit notebooks"), .init(name: "Glob", label: "Find files by name"), .init(name: "Grep", label: "Search inside files"), .init(name: "WebFetch", label: "Open web pages"), .init(name: "WebSearch", label: "Search the web"), .init(name: "Task", label: "Start helper agents"), .init(name: "TodoWrite", label: "Keep a to-do list"),
    ]
    public static let toolNamePattern = #"^(?:[A-Z][A-Za-z0-9]{0,63}|mcp__[A-Za-z0-9_-]{1,64}(?:__[A-Za-z0-9_-]{1,64})?)$"#
    public static func isToolName(_ name: String) -> Bool { BackendSharedText.matches(name, toolNamePattern) }
    public static func mcpServerTool(_ server: String) -> String? {
        let name = "mcp__" + server.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return isToolName(name) ? name : nil
    }
}
