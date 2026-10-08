import Foundation
import TerminalDeckNativeCore

public extension AWAgentsWatchNativeSource {
    /// Resolve ONLY the session's established conversation id. Two sessions in
    /// one folder must never watch whichever transcript happened to write last.
    static func establishedTranscript(authority: BackendCompositionAuthority) -> ResolveTranscript {
        { agent, caller in
            guard agent.machineID.isEmpty, let id = agent.sessionID else { return nil }
            let context: NativeRPCContext
            switch caller {
            case .app(let app): try authority.requireLocalUI(app); context = app
            case .mcp(let mcp): _ = try await authority.requireSession(id, native: mcp); context = try await authority.rpc(mcp)
            }
            let graph = try authority.sessions()
            guard let meta = await graph.lifecycle.metadata().first(where: { $0.session.id == id }),
                  meta.observedAgentProvider == nil || meta.observedAgentProvider == "claude",
                  let conversationID = meta.observedCLIConversationID ?? meta.session.agentSessionId else { return nil }
            let scope = try await authority.transcriptScope(project: nil, context: context)
            return try await Task.detached(priority: .utility) {
                for directory in try NativeTranscriptPaths.projectDirectories(meta.session.cwd, scope: scope) {
                    let files = try NativeTranscriptPaths.listTranscripts(directory, scope: scope)
                    if let file = files.first(where: { $0.sessionID == conversationID }) {
                        return (file.path, scope)
                    }
                }
                return nil
            }.value
        }
    }
}
