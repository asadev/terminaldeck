import Foundation
import TerminalDeckNativeCore

/// A session that runs AS a saved agent (Asad, 13 Oct: the New session dialog's Agent choice, "starts the session as
/// that agent: its seat, memory, AI and account"). The same mapping the task engine uses for a worker
/// (BackendTaskSessionDriver), without the task: the agent's AI, account, model, permission, tools and its own
/// instructions; the seat and its memory follow from the agent id (BackendAGTMemoryOwners reads `agentInstructions`).
///
/// For the Tasks seat (phase 2: Hoot → lead, lead → agents and task workers as chat sessions): build the input here,
/// add the task's own fields, set `chat = true`, start it with `lifecycle.create`, then talk to it through
/// BackendSessionChats (`say`, `turn`, `waitForTurn`).
public enum BackendAgentSessionInput {
    /// `agent`: a saved agent record (`tasks:state` agents / BackendTaskConfiguration.allAgents).
    /// `folder`: where it works (its project's folder). `chat`: nil lets the app choose (chat by default).
    public static func make(agent: NativeRPCValue, folder: String, projectID: String?, chat: Bool? = nil, specs: BackendTaskPersistence? = nil) throws -> BackendCreateSessionInput {
        guard let id = agent["id"].string, !id.isEmpty else { throw NativeRPCError.invalidArguments("That agent has no id.") }
        guard folder.hasPrefix("/") else { throw NativeRPCError.invalidArguments("An agent's session needs its project's folder.") }
        guard agent["status"].string != "archived", agent["status"].string != "paused" else {
            throw NativeRPCError.invalidArguments("That agent is not active. Choose an active agent.")
        }
        var input = BackendCreateSessionInput(cwd: folder, provider: agent["provider"].string)
        input.agentProfileID = id
        input.model = agent["model"].string
        input.effort = agent["effort"].string
        if !agent["agoptSettings"].isNullish {
            input.agentSettings = try BackendAGSCodec.decode(AGSAgentSettings.self, agent["agoptSettings"])
        }
        input.profileId = agent["account"].string
        input.deniedTools = agent["blockedTools"].elements?.compactMap(\.string)
        input.noSkills = (input.agentSettings?.provider ?? input.provider) == "claude"
            ? (input.agentSettings?.efficiency?.addonsOff == true ? true : agent["skillsOff"].bool) : nil
        input.claudeAgent = agent["claudeAgent"].string
        input.allowedTools = agent["allowedTools"].elements?.compactMap(\.string)
        input.permissionMode = agent["permissionMode"].string
        input.projectId = projectID ?? agent["projectId"].string
        if input.claudeAgent != nil { input.provider = "claude" }
        // Its own instructions, and with them its seat and memory, come from its id (the task engine's rule: Claude
        // or Codex with an instructions file). A lead without one still sits in its seat: the person opened it in
        // the lead's project (BackendAGTMemoryOwners, worksAsTheLead).
        if input.claudeAgent == nil, ["claude", "codex"].contains(input.provider ?? ""), agent["instructionsFile"].string != nil {
            input.agentInstructions = id
        }
        input.chat = chat
        if let specs { input.agentDefinitionsFile = try BackendTAGAgentDefinitionLaunch.prepare(agent: agent, specs: specs) }
        return input
    }
}
