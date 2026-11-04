import Foundation
import TerminalDeckNativeCore

/// Both agent-start tools use this choice. A provider name is also a useful
/// fallback for older job rows which recorded `codex` without a saved profile.
public struct BackendAgentStartSelection: Sendable {
    public let agent: NativeRPCValue?
    public let provider: String
    public var id: String { agent?["id"].string ?? provider }
    public var name: String { agent?["name"].string ?? CodingAICatalog.label(provider) }

    public init(arguments: NativeRPCValue, agents: [NativeRPCValue]) throws {
        let wanted = arguments["agent"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = arguments["provider"].string?.lowercased()
        let providers = ["claude", "codex", "gemini"]
        if let chosen, !providers.contains(chosen) {
            throw NativeRPCError.invalidArguments("Choose claude, codex or gemini as provider.")
        }
        let saved = wanted.flatMap { name in
            agents.first { $0["id"].string == name }
                ?? agents.first { ($0["name"].string ?? "").caseInsensitiveCompare(name) == .orderedSame }
        }
        if let saved {
            let ai = saved["agoptSettings"]["provider"].string ?? saved["provider"].string ?? "claude"
            guard chosen == nil || chosen == ai else {
                throw NativeRPCError.invalidArguments("This saved agent uses \(CodingAICatalog.label(ai)). Choose that provider, or leave agent out to start another AI.")
            }
            guard providers.contains(ai) else { throw NativeRPCError.invalidArguments("Choose an agent that uses Claude Code, Codex or Gemini for a chat.") }
            agent = saved; provider = ai
        } else if let wanted, !wanted.isEmpty {
            guard providers.contains(wanted.lowercased()), chosen == nil || chosen == wanted.lowercased() else {
                throw NativeRPCError.invalidArguments("Choose a saved agent from agents_directory or agents_profile, or pass provider: claude, codex or gemini.")
            }
            agent = nil; provider = wanted.lowercased()
        } else if let chosen { agent = nil; provider = chosen }
        else { throw NativeRPCError.invalidArguments("Pass a saved agent (id or name), or provider: claude, codex or gemini.") }
        try Self.requireAuto(arguments["permissionMode"].string)
    }

    public func input(folder: String, projectID: String?, specs: BackendTaskPersistence) throws -> BackendCreateSessionInput {
        var input: BackendCreateSessionInput
        if let agent { input = try BackendAgentSessionInput.make(agent: agent, folder: folder, projectID: projectID, chat: true, specs: specs) }
        else { input = BackendCreateSessionInput(cwd: folder, provider: provider); input.projectId = projectID; input.chat = true }
        input.permissionMode = BackendTAGLaunchArguments.newSessionPermission(provider: provider)
        return input
    }

    public static func requireAuto(_ permission: String?) throws {
        guard permission == nil || permission?.lowercased() == "auto" else {
            throw NativeRPCError.invalidArguments("Every new session starts in AUTO. Start it first, then use sessions_chat with do: options to change its permission mode within your seat's access.")
        }
    }

    public static func requireSafeFolder(_ folder: String, storageRoot: String, workspaceFolders: [String] = []) throws {
        // The existing app-owned workspaces are allowed after the caller’s folder grant was checked.
        let workspace = workspaceFolders.contains { BackendAgentProjectAccess.within(folder, $0) }
        guard !BackendAgentProjectAccess.within(folder, storageRoot) || workspace else {
            throw NativeRPCError.invalidArguments("A session cannot start inside this app's storage. Choose a project folder instead.")
        }
    }

    /// Discovery exposes identity and AI choices, never another agent's notes,
    /// instructions, environment, tools, account details or private settings.
    public static func publicProfile(_ profile: NativeRPCValue) -> NativeRPCValue {
        let settings = profile["agoptSettings"]
        let provider = settings["provider"].string ?? profile["provider"].string ?? "claude"
        return .object([.init("id", profile["id"]), .init("name", profile["name"]),
            .init("ai", .string(provider)), .init("provider", .string(provider)),
            .init("model", settings["model"].isNullish ? profile["model"].isNullish ? .null : profile["model"] : settings["model"]),
            .init("coverage", .string("public-agent-identity"))])
    }
}
