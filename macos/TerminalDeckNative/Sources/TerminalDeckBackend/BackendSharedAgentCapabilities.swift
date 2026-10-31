import Foundation
import TerminalDeckNativeCore

/// The exact build-capability matrix from shared/agent-capabilities.ts.
/// Evidence is the source's historical observation, not a new CLI check.
public typealias BackendSharedAgentCapabilities = SharedAgentCapabilities

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
