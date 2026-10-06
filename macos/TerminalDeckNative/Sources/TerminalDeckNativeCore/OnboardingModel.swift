import Foundation

/// components/Onboarding.tsx's words and rules: the first-run screen, shown only
/// when no coding agent can run. The tool list is `prereq:check`, read with lane
/// G's `CodingAIPrerequisites.parse`.
public enum Onboarding {
    public static let agentIds: Set<String> = ["claude", "codex", "gemini"]

    public static func title(_ appName: String) -> String { "Welcome to \(appName)" }
    public static func lede(_ appName: String) -> String {
        "\(appName) runs coding agents in real terminals, and never sees your logins."
    }
    public static let agentsHeading = "Coding agents"
    public static let agentsNote = "You need at least one."
    public static let checking = "Checking what you have…"
    public static let extrasHeading = "Optional"
    public static let extrasNote = "Missing these only disables the matching view."
    public static let needsLogin = "An agent is installed but not signed in. Start a session and it will ask."
    public static let getIt = "Get it"
    public static let openProject = "Open a project"
    public static let recheck = "Re-check"
    public static let skip = "Skip for now"

    public static func stateLabel(_ state: CodingAITool.State) -> String {
        switch state {
        case .ready: return "Ready"
        case .installedNotAuthed: return "Sign in needed"
        case .missing: return "Not installed"
        case .unknown: return "Unknown"
        }
    }

    /// The agents first (Claude, Codex, Gemini), everything else under "Optional", in the order sent.
    public static func split(_ tools: [CodingAITool]) -> (agents: [CodingAITool], extras: [CodingAITool]) {
        (tools.filter { agentIds.contains($0.id) }, tools.filter { !agentIds.contains($0.id) })
    }

    /// The agent's purpose line: its remedy when it has one. Extras always show the purpose.
    public static func agentLine(_ tool: CodingAITool) -> String { tool.remedy ?? tool.purpose }

    /// `toolVersionLabel` with `trimRepeatedName`: "2.1.233 (Claude Code)" under
    /// "Claude Code" reads "2.1.233"; any other parenthetical stays.
    public static func versionLabel(_ tool: CodingAITool) -> String? {
        if let version = tool.version, !version.isEmpty { return trimRepeatedName(version, label: tool.label) }
        if tool.state == .missing { return nil }
        return CodingAITool.noVersion
    }

    public static func trimRepeatedName(_ version: String, label: String?) -> String {
        guard let label, !label.isEmpty, version.hasSuffix(")"), let open = version.lastIndex(of: "(") else { return version }
        let inner = version[version.index(after: open)..<version.index(before: version.endIndex)]
        if inner.contains("(") || inner.contains(")") { return version }
        func normalise(_ text: Substring) -> String {
            String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
        }
        guard normalise(inner) == normalise(Substring(label)) else { return version }
        let head = version[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? version : head
    }
}
