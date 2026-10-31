import Foundation
import TerminalDeckNativeCore

/// The one authority for task-engine session operations (start, send, stop, controls, checks).
/// Moved out of the app composition so it can be tested with the real engine.
///
/// HOOTFIX (2026-10-09): a finished local task is handed back to the person (assignee "me",
/// `handedFrom` = the agent) while its worker is kept open. The old gate looked the agent up
/// by the CURRENT assignee only, so every later `sessions.stop` of that kept-open worker was
/// refused ("no current configured task/agent owner"). The engine needs exactly that stop to
/// free the folder for the agent's next task; the refusal escaped `pump()` and every queued
/// task behind it stayed queued forever. The owner of a session is the agent that runs it:
/// the assignee, or — once handed back — the agent it was handed from. Stopping a task's own
/// worker only ever reduces what runs, so it is allowed for a paused/archived agent or a
/// closed project too; every other action keeps the original rules.
public struct BackendTaskSessionGate: Sendable {
    private let store: BackendTaskStore, config: BackendTaskConfiguration
    private let connectionKeyExists: @Sendable (String) async -> Bool
    private let openProjects: @Sendable () async -> [String]
    /// FORK-TASKS (11 Oct, real-app test): the folders of the person's registered projects. A task whose
    /// folder is one of them (or inside one) may start whether or not that project is open in the side
    /// panel, the way the Artifacts page already treats registered folders. nil: only open projects count.
    private let registeredFolders: (@Sendable () async -> [String])?
    public init(store: BackendTaskStore, config: BackendTaskConfiguration,
                connectionKeyExists: @escaping @Sendable (String) async -> Bool,
                openProjects: @escaping @Sendable () async -> [String],
                registeredFolders: (@Sendable () async -> [String])? = nil) {
        self.store = store; self.config = config; self.connectionKeyExists = connectionKeyExists; self.openProjects = openProjects
        self.registeredFolders = registeredFolders
    }
    /// The folder is one of these project folders or inside one (never the whole disk).
    public static func belongs(_ folder: String, toProjectFolders folders: [String]) -> Bool {
        let path = PROJProjects.normalize(folder)
        guard !path.isEmpty else { return false }
        return folders.contains { raw in
            let root = PROJProjects.normalize(raw)
            return !root.isEmpty && root != "/" && (path == root || path.hasPrefix(root + "/"))
        }
    }
    /// One clear sentence for a folder that is neither a registered project's nor open. (It used to say
    /// "The task's project is no longer open." of a folder that had never been open.)
    public static func notAProject(_ folder: String) -> String {
        "The folder \(folder) is not part of any of your projects. Open it as a project, or choose a project's folder for this task, then reply on the task."
    }
    public static let actions: Set<String> = ["sessions.start", "sessions.send", "sessions.stop", "agents.set_control", "tasks.check"]
    static let noOwner = NativeRPCError(code: "access-denied", message: "This operation has no current configured task/agent owner.")

    /// The agent that runs this task's worker: its assignee, else the agent it was handed back from.
    public static func ownerAgentID(_ task: BackendTaskRecord) -> String? {
        if task.assigneeKind == "agent" { return task.agentID }
        return task.value["handedFrom"].string
    }

    /// #24: the check command runs on this Mac as a shell command, so an agent that is blocked from running
    /// commands (Run commands blocked, or Plan only / read-only) never has one run for it.
    public static func mayRunCommands(_ agent: NativeRPCValue) -> Bool {
        let blocked = (agent["blockedTools"].elements ?? []).compactMap(\.string)
        if blocked.contains(where: { $0 == "Bash" || $0.hasPrefix("Bash(") }) { return false }
        return agent["permissionMode"].string.flatMap(BackendAGSPolicy.permissionRank) != 0
    }
    public static let commandsBlocked = "This agent is blocked from running commands, so its check command was not run."

    public func authorize(_ action: String, _ args: NativeRPCValue) async throws {
        guard Self.actions.contains(action) else { throw Self.noOwner }
        let rows = try await store.all()
        let task: BackendTaskRecord?
        if let id = args["task"].string { task = rows.first { $0.id == id } }
        else if let id = args["sessionId"].string { task = rows.first { $0.sessionID == id } }
        else if action == "tasks.check", let command = args["command"].string {
            var match: BackendTaskRecord?
            for row in rows {
                if let agent = try await config.agent(Self.ownerAgentID(row) ?? ""), agent["verifyCommand"].string == command, row.project == args["cwd"].string { match = row; break }
            }
            task = match
        } else { task = nil }
        guard let task, let ownerID = Self.ownerAgentID(task) else { throw Self.noOwner }
        if action == "sessions.stop" {
            // Only the task's own worker; the agent's later state cannot keep it running.
            guard let session = args["sessionId"].string, task.sessionID == session else { throw Self.noOwner }
            return
        }
        guard let agent = try await config.agent(ownerID), agent["status"].string != "paused", agent["status"].string != "archived" else { throw Self.noOwner }
        if action == "tasks.check", !Self.mayRunCommands(agent) { throw NativeRPCError(code: "access-denied", message: Self.commandsBlocked) }
        if !task.isLocal {
            guard let key = task.value["keyId"].string, await connectionKeyExists(key),
                  let connection = try await config.connection(key), connection["enabled"].bool == true else {
                throw NativeRPCError(code: "access-denied", message: "This task's connection grant was removed or disabled.")
            }
        }
        if !(await openProjects()).contains(task.project) {
            let registered = await registeredFolders?() ?? []
            guard Self.belongs(task.project, toProjectFolders: registered) else {
                throw NativeRPCError(code: "access-denied", message: Self.notAProject(task.project))
            }
        }
        if action == "sessions.start" {
            let chosen = BackendTaskEngine.playbookAgent(task, agent)
            // Validate the recorded playbook choice, retaining the account resolved for this run.
            let account = chosen["provider"] != agent["provider"]
                ? task.value["agoptProfileID"].string.map(NativeRPCValue.string) ?? chosen["account"] : chosen["account"]
            guard args["provider"] == chosen["provider"], args["account"] == account else {
                throw NativeRPCError(code: "access-denied", message: "This launch does not match the configured task agent.")
            }
        }
    }
}
