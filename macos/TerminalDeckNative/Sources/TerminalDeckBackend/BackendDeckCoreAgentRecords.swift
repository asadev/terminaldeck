import Foundation
import TerminalDeckNativeCore

/// 18 Oct (#151): Codex and Gemini keep their own conversation record (Codex under `<home>/sessions/`, Gemini under
/// `.gemini/tmp/<project>/chats/`). The session tools read it as the task engine and Deck Memory do: found strictly
/// by the task engine's locator (the session's own record, never "newest in folder") and read by Deck Memory's
/// reader. Before this only Claude counted as writing a transcript, so an AI got the raw screen for the others.
public struct BackendDeckCoreAgentRecord: Sendable {
    public let provider: String
    public let target: BackendTaskTranscriptTarget
    public let bytes: Double
    public let fromByte: Double
    /// {id, role ("user" | "agent"), at, text, truncated}, oldest first, from `fromByte` on.
    public let messages: [NativeRPCValue]

    /// The same fields as a Claude transcript match, so every caller reads it alike.
    public var match: NativeRPCValue {
        .object([.init("path", .string(target.path)), .init("basis", .string("own-record")), .init("ambiguous", .bool(false)),
            .init("otherSessions", .array([])), .init("note", .null)])
    }
    /// The newest thing the agent said, as {at, text, truncated}.
    public func lastAnswer(maximumChars: Int? = nil) -> NativeRPCValue? {
        for message in messages.reversed() where message["role"].string == "agent" {
            let text = BackendDeckCoreCatalogueRules.trim(message["text"].string ?? "")
            guard !text.isEmpty else { continue }
            let cut = maximumChars.map { text.utf16.count > $0 } ?? false
            let kept = cut ? String(decoding: text.utf16.prefix(maximumChars ?? 0), as: UTF16.self) + "…" : text
            return .object([.init("at", message["at"]), .init("text", .string(kept)), .init("truncated", .bool(cut))])
        }
        return nil
    }
    /// The report's spend fields. These records count tokens; they name no requests or prices.
    public func spend(maximumBytes: Int) -> NativeRPCValue {
        guard bytes <= Double(maximumBytes) else {
            return .object([.init("requests", .null), .init("usage", .null), .init("totalTokens", .null), .init("models", .array([])),
                .init("compactions", .null), .init("contextPercent", .null),
                .init("skipped", .string("This conversation record is \(Int(floor(bytes / 1_000_000 + 0.5))) MB, which is too large to total inside a report."))])
        }
        let total = try? BackendAGOPTTokenUsage.read(provider: provider, target: target)
        let fill = provider == "codex" ? DeckMemorySessionCenter.deskFill(provider: provider, transcriptPath: target.path, largeWindow: false) : nil
        return .object([.init("requests", .null), .init("usage", .null), .init("totalTokens", total.map(NativeRPCValue.number) ?? .null), .init("models", .array([])),
            .init("compactions", .null), .init("contextPercent", fill.map { .number(floor($0 * 100 + 0.5)) } ?? .null), .init("skipped", .null)])
    }
    /// The tool calls in the record's last `windowBytes` (Gemini: its whole bounded record), named as the progress
    /// check knows them: a file edit counts as a write.
    public func toolTrail(windowBytes: Int) -> BackendCostTranscript? {
        let canonical = NativeTranscriptPaths.canonical(target.path)
        let from = provider == "gemini" ? max(0, bytes - Double(DeckMemoryFlowTranscripts.geminiMaximumBytes)) : max(0, bytes - Double(max(0, windowBytes)))
        guard let handle = FileHandle(forReadingAtPath: canonical) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(from))) != nil,
              let data = try? handle.read(upToCount: provider == "gemini" ? DeckMemoryFlowTranscripts.geminiMaximumBytes : max(0, windowBytes)) else { return nil }
        var transcript = BackendCostTranscript(path: canonical, sessionID: URL(fileURLWithPath: canonical).deletingPathExtension().lastPathComponent, cwd: "")
        transcript.truncated = from > 0
        let writes = ["apply_patch": "Edit", "write_file": "Write", "replace": "Edit"]
        func call(_ id: String?, _ name: String?, _ at: String?, failed: Bool?) {
            guard let id, !id.isEmpty, let name, !name.isEmpty else { return }
            transcript.toolTrail.append(.init(id: id, name: writes[name] ?? name, at: at.flatMap(BackendTaskAgentTranscripts.milliseconds) ?? 0, failed: failed))
        }
        func rows() -> [NativeRPCValue] {
            data.split(separator: 0x0a).compactMap { try? NativeRPCValue.parseJSON(Data($0), maximumBytes: DeckMemoryFlowTranscripts.maximumLineBytes) }
        }
        if provider == "codex" {
            for row in rows() where row["type"].string == "response_item" {
                let payload = row["payload"], id = payload["call_id"].string ?? payload["id"].string
                switch payload["type"].string {
                case "function_call", "custom_tool_call": call(id, payload["name"].string, row["timestamp"].string, failed: nil)
                case "local_shell_call": call(id, "shell", row["timestamp"].string, failed: nil)
                default: continue
                }
            }
            return transcript
        }
        // Gemini rewrites a message in place as its tool calls finish: the last version of each counts.
        var order: [String] = [], messages: [String: NativeRPCValue] = [:]
        let found = canonical.hasSuffix(".json") ? (from == 0 ? (try? NativeRPCValue.parseJSON(data, maximumBytes: DeckMemoryFlowTranscripts.geminiMaximumBytes))?["messages"].elements ?? [] : []) : rows()
        for message in found {
            guard let id = message["id"].string, message["type"].string == "gemini" else { continue }
            if messages[id] == nil { order.append(id) }
            messages[id] = message
        }
        for id in order {
            for tool in messages[id]?["toolCalls"].elements ?? [] {
                call(tool["id"].string, tool["name"].string, tool["timestamp"].string ?? messages[id]?["timestamp"].string,
                     failed: tool["status"].string.map { $0 == "error" })
            }
        }
        return transcript
    }
}

public enum BackendDeckCoreAgentRecords {
    /// Session id → that session's own record, confined to its account's folders. Composition supplies the task engine's locator.
    public typealias Locate = @Sendable (String) async throws -> BackendTaskTranscriptTarget?

    public static func keepsOwnRecord(_ provider: String?) -> Bool { provider == "codex" || provider == "gemini" }

    /// The last `windowBytes` of the record as messages (0 locates only). Gemini rewrites one file, so it is read
    /// whole within Deck Memory's own bound. Nil when the session is not Codex or Gemini or its record is not found.
    public static func read(session: NativeRPCValue, locate: Locate?, windowBytes: Int) async -> BackendDeckCoreAgentRecord? {
        guard let provider = session["provider"].string, keepsOwnRecord(provider), let locate, let id = session["id"].string,
              let target = try? await locate(id) else { return nil }
        let canonical = NativeTranscriptPaths.canonical(target.path)
        guard target.roots.contains(where: { NativeTranscriptPaths.isDescendant(canonical, of: NativeTranscriptPaths.canonical($0)) }) else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: canonical))?[.size] as? NSNumber)?.doubleValue ?? 0
        let fromByte = provider == "gemini" ? 0 : max(0, bytes - Double(max(0, windowBytes)))
        guard windowBytes > 0 else { return .init(provider: provider, target: target, bytes: bytes, fromByte: fromByte, messages: []) }
        let source = DeckMemoryFlowRecordTarget(path: target.path, roots: target.roots, provider: provider, conversation: id)
        guard let read = try? DeckMemoryFlowTranscripts.readNew(source, record: .init(path: canonical, offset: Int64(fromByte))) else { return nil }
        let messages: [NativeRPCValue] = read.pieces.compactMap { piece in
            let role: String
            switch piece.role {
            case .user: role = "user"
            case .assistant: role = "agent"
            default: return nil
            }
            return .object([.init("id", .string(piece.key)), .init("role", .string(role)), .init("at", .number((piece.at?.timeIntervalSince1970 ?? 0) * 1_000)),
                .init("text", .string(piece.text)), .init("truncated", .bool(false))])
        }
        return .init(provider: provider, target: target, bytes: bytes, fromByte: fromByte, messages: messages)
    }
}
