import Foundation
import TerminalDeckNativeCore

/// Recovery uses a recorded tab/session link and the same history owner and transcript location.
/// Folder, agent and recency alone never establish ownership of another conversation.
public enum BackendRestoreConversationHint {
    public struct Candidate: Sendable {
        let conversationID: String
        let sessionID: String
        let tabKey: String?
        let historyOwnerID: String?
        let transcriptPath: String

        func belongs(to saved: BackendSessionSaved, configDirectory: String) -> Bool {
            let linkedTab = saved.tabKey.flatMap { $0.isEmpty ? nil : $0 }.map { tabKey == $0 } ?? false
            let linkedSession = saved.raw["id"].string.flatMap { $0.isEmpty ? nil : $0 }.map { $0 == sessionID } ?? false
            guard linkedTab || linkedSession, let history = saved.homeProfileID ?? saved.profileID, !history.isEmpty,
                  historyOwnerID == history,
                  conversationID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return false }
            return NativeTranscriptPaths.projectSpellings(saved.cwd).contains {
                let expected = URL(fileURLWithPath: configDirectory).appendingPathComponent("projects")
                    .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath($0)).appendingPathComponent(conversationID + ".jsonl")
                return NativeTranscriptPaths.canonical(expected.path) == NativeTranscriptPaths.canonical(transcriptPath)
            }
        }
    }

    struct Record: Decodable {
        var provider: String?
        var tabKey: String?
        var historyOwnerID: String?
        var transcriptPath: String?
        var conversationID: String?
        var lastTurnAt: Double?
        var lastPromptAt: Double?
        var agentProfileID: String?
        var claudeAgent: String?
    }

    public static func make(dataRoot: URL) -> BackendSessionRestoreCoordinator.ConversationHint {
        let folder = DeckMemorySessionHook.root(dataRoot: dataRoot).appendingPathComponent("sessions", isDirectory: true)
        return { saved, claimed, config in
            await Task.detached(priority: .utility) { best(in: folder, for: saved, claimed: claimed, configDirectory: config) }.value
        }
    }

    static func best(in folder: URL, for saved: BackendSessionSaved, claimed: Set<String>, configDirectory: String,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Candidate? {
        guard saved.provider == "claude",
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let agent = (saved.raw["agentProfileID"].string ?? saved.raw["claudeAgent"].string).flatMap { $0.isEmpty ? nil : $0 }
        let projects = Set(NativeTranscriptPaths.projectSpellings(saved.cwd).map(NativeTranscriptPaths.encodeProjectPath))
        var best: (candidate: Candidate, at: Double)?
        for name in names where !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name).appendingPathComponent("state.json")
            guard let data = try? BackendAccountFiles.boundedRead(file, maximum: 1_048_576),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            guard record.provider == "claude", let id = record.conversationID, let path = record.transcriptPath,
                  id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, !claimed.contains(id) else { continue }
            let transcript = URL(fileURLWithPath: path)
            let candidate = Candidate(conversationID: id, sessionID: name, tabKey: record.tabKey,
                historyOwnerID: record.historyOwnerID, transcriptPath: path)
            guard candidate.belongs(to: saved, configDirectory: configDirectory) else { continue }
            guard transcript.lastPathComponent == id + ".jsonl",
                  projects.contains(transcript.deletingLastPathComponent().lastPathComponent) else { continue }
            let recordAgent = (record.agentProfileID ?? record.claudeAgent).flatMap { $0.isEmpty ? nil : $0 }
            guard recordAgent == agent, exists(path) else { continue }
            let at = record.lastTurnAt ?? record.lastPromptAt ?? 0
            if best == nil || at > best!.at { best = (candidate, at) }
        }
        return best?.candidate
    }
}
