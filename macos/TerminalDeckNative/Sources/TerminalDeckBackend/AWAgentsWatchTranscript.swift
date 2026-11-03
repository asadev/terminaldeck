import Foundation
import TerminalDeckNativeCore

/// A display projection over the existing bounded transcript tail reader.
/// Chat text uses the shared chat parser; only public tool traffic is added.
public enum AWAgentsWatchTranscript {
    public struct Read: Sendable {
        public let entries: [AWWatchEntry]
        public let updatedAt: Double
        public let bounded: Bool
    }
    public static func read(path: String, scope: NativeTranscriptScope, cancellation: BackendMCPCancellation? = nil) async throws -> Read {
        let approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        guard try await BackendCompositionAuthorityTranscripts.belongs(approved, scope: scope, cancellation: cancellation) else {
            throw NativeRPCError(code: "access-denied", message: "This conversation belongs to another project")
        }
        let roots = try NativeTranscriptPaths.approvedRoots(scope)
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            let (tail, updated) = try BackendUsageIO.tail(path: approved, roots: roots, bytes: 2 * 1024 * 1024)
            var entries: [AWWatchEntry] = [], seen = Set<String>(), tools: [String: String] = [:]
            for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
                try Task.checkCancellation()
                if cancellation?.isCancelled == true { throw CancellationError() }
                for entry in project(String(line), tools: &tools) where seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            }
            return Read(entries: Array(entries.suffix(1000)), updatedAt: updated, bounded: true)
        }.value
    }

    public static func project(_ line: String, tools: inout [String: String]) -> [AWWatchEntry] {
        guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 2 * 1024 * 1024),
              ["user", "assistant"].contains(raw["type"].string),
              raw["isSidechain"].bool != true, raw["isMeta"].bool != true,
              raw["isCompactSummary"].bool != true, raw["isVisibleInTranscriptOnly"].bool != true,
              raw["isApiErrorMessage"].bool != true, raw["message"]["model"].string != "<synthetic>" else { return [] }
        let stamp = BackendUsageIO.timestamp(raw["timestamp"])
        let key = raw["uuid"].string ?? raw["message"]["id"].string
        // Without an evidenced identity, do not manufacture a durable stream cursor.
        guard let key else { return [] }
        var answer: [AWWatchEntry] = []
        if let chat = NativeChatTranscriptParsing.parse(line) {
            answer.append(AWWatchEntry(id: "message:" + key, kind: .message,
                speaker: chat.role == .you ? "You" : "Agent", title: "", text: chat.text, at: chat.at))
        }
        for (index, block) in (raw["message"]["content"].elements ?? []).enumerated() {
            switch block["type"].string {
            case "tool_use":
                guard let use = block["id"].string, let name = block["name"].string else { continue }
                tools[use] = name
                answer.append(AWWatchEntry(id: "tool:" + use, kind: .tool, speaker: "Agent",
                    title: AWWatchProjection.action(name), text: describe(BackendDeckCoreSecurityActionLog.scrubArguments(block["input"])), at: stamp))
            case "tool_result":
                guard let use = block["tool_use_id"].string else { continue }
                let failed = block["is_error"].bool == true
                let content = block["content"].string ?? (block["content"].elements ?? []).compactMap { item in
                    item["type"].string == "text" ? item["text"].string : nil
                }.joined(separator: "\n")
                answer.append(AWWatchEntry(id: "result:\(key):\(use):\(index)", kind: .result, speaker: "Tool",
                    title: (failed ? "Failed · " : "Result · ") + (tools[use] ?? "Tool"),
                    text: BackendGitHubSecretRedaction.redact(content, home: ""), at: stamp, failed: failed))
            default: break // Private reasoning and opaque attachments are not chat.
            }
        }
        return answer
    }
    private static func describe(_ value: NativeRPCValue) -> String {
        (value.fields ?? []).prefix(12).map { field in
            let text: String
            if let string = field.value.string { text = string }
            else if let elements = field.value.elements { text = elements.compactMap(\.string).joined(separator: ", ") }
            else if let number = field.value.number { text = String(number) }
            else if let flag = field.value.bool { text = flag ? "Yes" : "No" }
            else { text = "Details omitted" }
            return field.key + ": " + text
        }.joined(separator: "\n")
    }
}
