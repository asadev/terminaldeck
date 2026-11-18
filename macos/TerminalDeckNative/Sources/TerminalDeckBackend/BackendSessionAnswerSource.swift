import Foundation
import TerminalDeckNativeCore

/// The existing sessions_result record reader, shared with terminal WhatsApp replies.
/// Composition supplies its real caller scope; no synthetic MCP caller or second transcript parser.
public struct BackendSessionAnswerSource: Sendable {
    public let transcripts: @Sendable (String) async throws -> [NativeRPCValue]
    public let transcriptBytes: @Sendable (String) async throws -> Int
    public let transcriptMessages: @Sendable (String, Int) async throws -> [NativeRPCValue]
    public let agentRecord: @Sendable (NativeRPCValue) async -> BackendDeckCoreAgentRecord?

    public init(transcripts: @escaping @Sendable (String) async throws -> [NativeRPCValue],
                transcriptBytes: @escaping @Sendable (String) async throws -> Int,
                transcriptMessages: @escaping @Sendable (String, Int) async throws -> [NativeRPCValue],
                agentRecord: @escaping @Sendable (NativeRPCValue) async -> BackendDeckCoreAgentRecord?) {
        self.transcripts = transcripts; self.transcriptBytes = transcriptBytes
        self.transcriptMessages = transcriptMessages; self.agentRecord = agentRecord
    }

    public static func native(cost: BackendCostService, context: NativeRPCContext,
                              locate: BackendDeckCoreAgentRecords.Locate?, mergeAgentTurn: Bool = true) -> Self {
        .init(transcripts: { cwd in
            try await cost.files(project: cwd, context: context).map { file in
                BackendDeckToolsSupport.object([("path", .string(file.path)), ("sessionId", .string(file.sessionID)),
                    ("createdAt", .number(file.createdAt)), ("modifiedAt", .number(file.modifiedAt)), ("bytes", .number(Double(file.bytes)))])
            }
        }, transcriptBytes: { path in
            let scope = try await cost.scope(project: nil, context: context)
            _ = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let size = attributes[.size] as? NSNumber else { throw BackendDeckToolsSupport.unavailable("The transcript byte count") }
            return size.intValue
        }, transcriptMessages: { path, fromByte in
            let scope = try await cost.scope(project: nil, context: context)
            _ = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
            return try await messages(path: path, fromByte: fromByte, roots: NativeTranscriptPaths.approvedRoots(scope), mergeAgentTurn: mergeAgentTurn)
        }, agentRecord: { session in
            await BackendDeckCoreAgentRecords.read(session: session, locate: locate, windowBytes: 256 * 1_024)
        })
    }

    /// Kept here so both callers and fixture checks use the same existing chat reader and message shapes.
    static func messages(path: String, fromByte: Int, roots: [String], mergeAgentTurn: Bool = false) async throws -> [NativeRPCValue] {
        let reader = NativeChatTranscriptReader(path: path, startAt: Int64(max(0, fromByte)), allowedRoots: roots, mergeAgentTurn: mergeAgentTurn)
        let result = try await reader.readAll(wholeConversation: true)
        guard result.found else { throw BackendDeckToolsSupport.unavailable("The conversation record") }
        return result.messages.map { BackendDeckToolsSupport.object([("id", .string($0.id)), ("role", .string($0.role.rawValue)),
            ("at", .number($0.at)), ("text", .string($0.text)), ("truncated", .bool(false))]) }
    }
}
