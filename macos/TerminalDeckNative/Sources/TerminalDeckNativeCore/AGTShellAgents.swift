import Foundation

// AGT: an AI started by hand inside one of Terminal Deck's own shell tabs (e.g. typing
// `claude --resume …` in a plain zsh tab). Terminal Deck remembers its conversation on
// that tab so a restore reopens the shell AND resumes the conversation, like an agent tab.

/// What a shell tab is running, remembered by its tab key (stable across restores).
public struct AGTShellAgent: Equatable, Sendable {
    public var provider: String
    public var conversationID: String
    public var cwd: String
    /// Milliseconds since 1970.
    public var updatedAt: Double
    public init(provider: String, conversationID: String, cwd: String, updatedAt: Double) {
        self.provider = provider; self.conversationID = conversationID; self.cwd = cwd; self.updatedAt = updatedAt
    }
    public var wireValue: NativeRPCValue {
        .object([.init("provider", .string(provider)), .init("conversationId", .string(conversationID)),
                 .init("cwd", .string(cwd)), .init("updatedAt", .number(updatedAt))])
    }
    public static func decode(_ value: NativeRPCValue) -> AGTShellAgent? {
        guard let provider = value["provider"].string, let id = value["conversationId"].string,
              AGTShellAgents.resumeCommand(provider: provider, conversationID: id) != nil else { return nil }
        return AGTShellAgent(provider: provider, conversationID: id, cwd: value["cwd"].string ?? "", updatedAt: value["updatedAt"].number ?? 0)
    }
}

public enum AGTShellAgents {
    public static let providers = ["claude", "codex", "gemini"]

    /// The command that continues a conversation; nil for anything that is not a plain id.
    public static func resumeCommand(provider: String, conversationID: String) -> String? {
        guard conversationID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        switch provider {
        case "claude": return "claude --resume " + conversationID
        case "codex": return "codex resume " + conversationID
        case "gemini": return "gemini --resume " + conversationID
        default: return nil
        }
    }

    /// Only commands this file makes may be run by a restored shell.
    public static func isResumeCommand(_ command: String) -> Bool {
        command.range(of: #"^(claude --resume|codex resume|gemini --resume) [A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    /// The restored shell's arguments: an interactive login shell goes to the AI's folder and
    /// resumes it; when the AI ends, the tab carries on as the same plain login shell it was.
    public static func shellArguments(shell: String, agent: AGTShellAgent?) -> [String] {
        guard let agent, let resume = resumeCommand(provider: agent.provider, conversationID: agent.conversationID),
              shell.hasPrefix("/"), !shell.contains("\0") else { return ["-l"] }
        let folder = agent.cwd.hasPrefix("/") && !agent.cwd.contains("\0") ? "cd " + AGTDeviceDetect.shellQuote(agent.cwd) + " && " : ""
        return ["-l", "-i", "-c", folder + resume + "; exec " + AGTDeviceDetect.shellQuote(shell) + " -l"]
    }

    /// Every process below a session's own process (its shell).
    public static func descendants(of root: Int32, in processes: [AGTProcess]) -> [AGTProcess] {
        var children: [Int32: [AGTProcess]] = [:]
        for process in processes { children[process.ppid, default: []].append(process) }
        var out: [AGTProcess] = [], frontier = [root], seen: Set<Int32> = [root]
        while let next = frontier.popLast(), out.count < 512 {
            for child in children[next] ?? [] where seen.insert(child.pid).inserted { out.append(child); frontier.append(child.pid) }
        }
        return out
    }

    /// The AI running inside a shell session now, with its conversation id when it is known.
    /// The newest one wins when several run (for example Claude running Codex).
    public static func innerAgent(root: Int32, processes: [AGTProcess], files: AGTDeviceDetect.Files, now: Double) -> AGTDeviceAgent? {
        let below = descendants(of: root, in: processes)
        guard !below.isEmpty else { return nil }
        let rootProcess = processes.first { $0.pid == root }
        let agents = AGTDeviceDetect.agents((rootProcess.map { [$0] } ?? []) + below, files: files, now: now)
            .filter { $0.pid != root }
        return agents.filter { $0.sessionID != nil }.max { $0.startedAt < $1.startedAt } ?? agents.max { $0.startedAt < $1.startedAt }
    }

    /// What a scan of a live shell means for the record: keep, replace or forget.
    public enum Change: Equatable, Sendable { case keep, set(AGTShellAgent), clear }
    public static func change(current: AGTShellAgent?, found: AGTDeviceAgent?, shellAlive: Bool, cwd: String, now: Double) -> Change {
        guard shellAlive else { return .keep } // the tab died with its AI: resume it next time
        guard let found else { return current == nil ? .keep : .clear } // the AI ended; the shell lives on
        guard let id = found.sessionID, resumeCommand(provider: found.ai, conversationID: id) != nil else { return .keep }
        if current?.provider == found.ai && current?.conversationID == id { return .keep }
        return .set(AGTShellAgent(provider: found.ai, conversationID: id, cwd: found.project.isEmpty ? cwd : found.project, updatedAt: now * 1000))
    }
}
