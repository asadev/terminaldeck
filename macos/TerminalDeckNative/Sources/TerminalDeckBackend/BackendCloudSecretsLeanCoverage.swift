import Foundation
import TerminalDeckNativeCore

/// The lean first version's own account of what saved passwords cover (cloud-lean-v1.md item 3). A source whose
/// owner cannot be bound safely in this version is not registered, and is NAMED here as not saved, in plain
/// words, so the page and the status tool never leave it silently missing.
public enum BackendCloudSecretsLeanCoverage {
    public struct Line: Sendable, Equatable {
        public let sourceId: String
        /// What the person calls it.
        public let title: String
        /// nil: saved in Cloud from this Mac. Otherwise the plain sentence saying it is not, and why.
        public let notSaved: String?
    }
    /// Every source of the lean list, in the order Asad named them.
    /// 14 Nov (owner): project secret files joined the lean list (`BackendCloudSecretsLean.sources`), so they are named too.
    public static let order = ["servers", "api", "ssh", "tasks", "receiver", "voice", "mcp-user", BackendProjectSecretFilesRules.sourceId]
    static func title(_ sourceId: String) -> String {
        switch sourceId {
        case "servers": return "Server passwords and saved SSH keys"
        case "api": return "API keys"
        case "ssh": return "Server keys from your SSH settings"
        case "tasks": return "Connected-task tokens"
        case "receiver": return "Receiver secrets"
        case "voice": return "The voice key"
        case "mcp-user": return "MCP servers"
        case BackendProjectSecretFilesRules.sourceId: return "Project secret files"
        default: return sourceId
        }
    }
    /// Why a source of the lean list is not saved when it is not registered on this Mac right now.
    /// Keys travel (15 Nov 2026): API keys, connected-task tokens, Receiver secrets and MCP servers travel like every saved
    /// password; their sentence only says the part of the app that holds them is not ready yet on this Mac.
    static func reason(_ sourceId: String) -> String {
        switch sourceId {
        case "api": return "API keys are saved in Cloud as soon as this Mac's API accounts are ready."
        case "ssh": return "Keys and settings of servers that sign in through your SSH settings are saved in Cloud as soon as this Mac's servers are ready."
        case "tasks": return "Connected-task tokens are saved in Cloud as soon as this Mac's task connections are ready."
        case "receiver": return "Receiver secrets are saved in Cloud as soon as this Mac's Receiver is ready."
        case "servers": return "Server passwords and saved SSH keys are not being saved in Cloud from this Mac. They stay on this Mac."
        case "voice": return "The voice key is not being saved in Cloud from this Mac. It stays on this Mac."
        case "mcp-user": return "MCP servers are saved in Cloud as soon as this Mac's MCP settings are ready."
        case BackendProjectSecretFilesRules.sourceId: return "Project secret files are not being saved in Cloud from this Mac. They stay in their project folders on this Mac."
        default: return title(sourceId) + " is saved in Cloud as soon as it is ready on this Mac."
        }
    }
    /// One line per source of the lean list; `registered` are the source ids that really joined on this Mac.
    public static func lines(registered: Set<String>) -> [Line] {
        order.map { Line(sourceId: $0, title: title($0), notSaved: registered.contains($0) ? nil : reason($0)) }
    }
    /// Only the sentences for what is not saved, for the page and the status tool.
    public static func notSaved(registered: Set<String>) -> [String] {
        lines(registered: registered).compactMap(\.notSaved)
    }
}
