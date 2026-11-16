import Foundation
import TerminalDeckNativeCore

/// Sessions in the Cloud, step 1 (Sessions seat design 2026-11-15, part B): the `read` stream of a session's chat, the
/// readable messages as the SAME event lines the phones already draw (`HootChatEvent` wire, one JSON object per line,
/// each line ending in "\n"). The service never parses a history; phones and the web reuse their chat view with no
/// AI-specific reader.
/// - Claude Code (`.jsonl`): the existing transcript rules (`NativeChatTranscriptParsing`: no tool traffic, no private
///   reasoning, no CLI tags, no side chains).
/// - Codex (`rollout-*.jsonl`): `response_item` messages of the person and the assistant only; the context Codex puts in
///   front of the first message (environment, instructions) is not a message.
/// - Gemini (one JSON file, rewritten whole): its `messages`, the person's and Gemini's.
/// - The app's own chats and Hoot (`chat.json`): their own events, as the phones get them (pictures as stand-ins).
public enum BackendCloudChatsReadable {
    public enum Format: String, Sendable, Codable, Equatable { case claude, codex, gemini, appChat }

    /// The largest line of a line-based history read into memory at once; a bigger line (a huge pasted file) is skipped.
    public static let maximumLineBytes = 8 * 1_048_576
    /// A message's text as phones take it (`BackendPhoneChats.conversation`).
    public static let maximumTextBytes = 65_536

    /// One readable message before it becomes an event line.
    public struct Message: Sendable, Equatable {
        public enum Role: Sendable, Equatable { case person, ai }
        public let role: Role
        public let id: String
        public let text: String
        public let at: Double
        public init(role: Role, id: String, text: String, at: Double) { self.role = role; self.id = id; self.text = text; self.at = at }
    }

    /// The event line for one message: `sequence` counts from 1 within the stream's generation.
    public static func line(_ message: Message, conversation: String, sequence: Int, provider: HootChatProvider) -> Data? {
        var text = message.text
        if text.utf8.count > maximumTextBytes { text = String(decoding: Data(text.utf8.prefix(maximumTextBytes)), as: UTF8.self) }
        let record = HootChatRecord.text(message.role == .person ? .user : .message, id: message.id, text)
        let event = HootChatEvent(conversationID: conversation.isEmpty ? "chat" : conversation, turnID: "", sequence: sequence,
                                  provider: provider, record: record, at: message.at)
        guard var data = try? event.wireValue.encodedJSON() else { return nil }
        data.append(0x0a)
        return data
    }

    // MARK: Line-based histories (Claude Code, Codex)

    /// The messages of ONE history line (nil or empty: nothing readable in it).
    public static func messages(line: Data, format: Format) -> [Message] {
        switch format {
        case .claude: return claude(line)
        case .codex: return codex(line)
        case .gemini, .appChat: return []
        }
    }

    static func claude(_ line: Data) -> [Message] {
        guard let text = String(data: line, encoding: .utf8), NativeChatTranscriptParsing.mayCarryChat(text),
              let parsed = NativeChatTranscriptParsing.parse(text) else { return [] }
        let id = parsed.providerMessageID ?? parsed.groupKey
        return [Message(role: parsed.role == .you ? .person : .ai, id: id, text: parsed.text, at: parsed.at)]
    }

    /// What Codex puts in front of the person's first message: context, not something he wrote.
    static let codexContextPrefixes = ["<environment_context>", "<user_instructions>", "<permissions instructions>",
                                       "# AGENTS.md instructions", "<user_shell_command>", "<turn_aborted>"]

    static func codex(_ line: Data) -> [Message] {
        guard line.count <= maximumLineBytes, let raw = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              raw["type"] as? String == "response_item", let payload = raw["payload"] as? [String: Any],
              payload["type"] as? String == "message", let role = payload["role"] as? String,
              role == "user" || role == "assistant", let content = payload["content"] as? [Any] else { return [] }
        let wanted = role == "user" ? "input_text" : "output_text"
        let text = content.compactMap { part -> String? in
            guard let part = part as? [String: Any], part["type"] as? String == wanted, let text = part["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return [] }
        if role == "user", codexContextPrefixes.contains(where: { text.hasPrefix($0) }) { return [] }
        let at = (raw["timestamp"] as? String).flatMap(isoMs) ?? 0
        let id = (payload["id"] as? String) ?? String(format: "codex-%.0f", at)
        return [Message(role: role == "user" ? .person : .ai, id: id, text: text, at: at)]
    }

    /// One window of a line-based history: the event lines for every WHOLE line in `window` (bytes from the stream's
    /// source offset), and how many bytes those whole lines took. A line still being written stays for the next look.
    public struct Window: Sendable, Equatable {
        public var lines: Data
        public var events: Int
        public var consumed: Int
    }
    public static func window(_ window: Data, format: Format, conversation: String, provider: HootChatProvider,
                              nextSequence: Int, maxOutput: Int = 1_048_576, atEnd: Bool = false) -> Window {
        var out = Window(lines: Data(), events: 0, consumed: 0)
        func take(_ line: Data, _ consumedTo: Int) {
            // A line too big to be a message (a huge tool result) is passed over unread.
            if line.count <= maximumLineBytes {
                for message in messages(line: line, format: format) {
                    if let made = Self.line(message, conversation: conversation, sequence: nextSequence + out.events, provider: provider) {
                        out.lines.append(made); out.events += 1
                    }
                }
            }
            out.consumed = consumedTo
        }
        var start = window.startIndex
        while start < window.endIndex {
            guard let newline = window[start...].firstIndex(of: 0x0a) else {
                // A last line with no newline is whole only when the file has not grown for a while (`atEnd`).
                if atEnd { take(Data(window[start...]), window.count) }
                break
            }
            take(Data(window[start..<newline]), newline - window.startIndex + 1)
            start = newline + 1
            if out.lines.count >= maxOutput { break }
        }
        return out
    }

    // MARK: Whole-file histories (Gemini, the app's chats)

    /// Gemini's chat file: its messages in order (the person's and Gemini's), with their ids.
    public static func gemini(_ file: Data) -> (conversation: String, messages: [Message])? {
        guard let raw = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any], let list = raw["messages"] as? [Any] else { return nil }
        let conversation = raw["sessionId"] as? String ?? ""
        var made: [Message] = []
        for (index, entry) in list.enumerated() {
            guard let entry = entry as? [String: Any], let type = entry["type"] as? String, type == "user" || type == "gemini" else { continue }
            let text: String
            if let plain = entry["content"] as? String { text = plain }
            else if let parts = entry["content"] as? [Any] {
                text = parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n\n")
            } else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let at = (entry["timestamp"] as? String).flatMap(isoMs) ?? 0
            made.append(Message(role: type == "user" ? .person : .ai, id: entry["id"] as? String ?? "gemini-\(index)", text: trimmed, at: at))
        }
        return (conversation, made)
    }

    /// An app chat's / Hoot's saved file: its conversation id and its events as the phones get them (pictures as their
    /// stand-ins, streamed pieces left out because the finished message carries the whole text), oldest first, each
    /// with its own `sequence`.
    public static func appChat(_ file: Data) -> (conversation: String, events: [(sequence: Int, line: Data)])? {
        guard let snapshot = try? NativeRPCValue.parseJSON(file, maximumBytes: 512 * 1_048_576), snapshot.fields != nil else { return nil }
        let conversation = snapshot["conversationId"].string ?? ""
        var made: [(Int, Data)] = []
        for raw in snapshot["events"].elements ?? [] {
            guard let event = try? HootChatEvent(wire: raw), event.conversationID == conversation,
                  event.record.kind != .textDelta, event.record.kind != .session else { continue }
            let phone = ChatRenderedContent.phoneEvent(BackendChatMedia.slimEvent(raw))
            guard (phone["value"]["text"].string?.utf8.count ?? 0) <= maximumTextBytes,
                  var data = try? phone.encodedJSON(), data.count <= 1_048_576 else { continue }
            data.append(0x0a)
            made.append((event.sequence, data))
        }
        return (conversation, made)
    }

    static func isoMs(_ stamp: String) -> Double? {
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)) ?? (try? Date.ISO8601FormatStyle().parse(stamp))
        return date.map { $0.timeIntervalSince1970 * 1000 }
    }
}
