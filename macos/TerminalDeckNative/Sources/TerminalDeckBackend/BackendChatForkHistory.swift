import Foundation
import TerminalDeckNativeCore

/// Passed only by the app over its authenticated keeper connection, never from tool arguments.
/// The app fills this from its worktree ledger after creating the workspace and destination session.
public struct BackendChatForkWorktree: Codable, Sendable {
    public let key: String
    public let sessionID: String
    public let parentSessionID: String
    public let folder: String
    public init(key: String, sessionID: String, parentSessionID: String, folder: String) {
        self.key = key; self.sessionID = sessionID; self.parentSessionID = parentSessionID; self.folder = folder
    }
}

public enum BackendChatForkHistory {
    public static func authorize(parent: BackendSessionMeta, target: BackendSessionMeta, worktree: BackendChatForkWorktree?) throws {
        let recordedWorktree = worktree.map {
            !$0.key.isEmpty && $0.sessionID == target.id && $0.parentSessionID == parent.id && $0.folder == target.cwd
                && parent.provider == "codex"
        } ?? false
        guard parent.id != target.id, parent.chat == true, target.chat == true,
              parent.provider == target.provider, let profile = parent.profileId, !profile.isEmpty,
              profile == target.profileId, parent.homeProfileId == target.homeProfileId,
              parent.cwd == target.cwd || recordedWorktree else {
            throw NativeRPCError(code: "not-granted", message: "A fork must keep the source AI and login, in its folder or its recorded Codex worktree.")
        }
    }

    static func seed(parent: BackendSessionMeta, target: BackendSessionMeta, worktree: BackendChatForkWorktree?,
                     through sequence: Int, source: BackendHootChatStore, destination: BackendHootChatStore) async throws {
        try authorize(parent: parent, target: target, worktree: worktree)
        let prefix = try await source.forkPrefix(through: sequence)
        try await destination.seedForkHistory(prefix)
    }
}
