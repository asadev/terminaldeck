import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// One message found in a session's own record, ready for the diary.
public struct DeckMemoryFlowPiece: Sendable, Equatable {
    public var role: DeckMemoryDiaryRole
    /// Word for word.
    public var text: String
    public var at: Date?
    /// Identity of the source record; the diary stores a key once.
    public var key: String
    /// Who really wrote it. A record only knows "user"; the capture decides whether that was the
    /// person, Hoot, a lead or the app, from what the app itself knows about the session.
    public var author: DeckMemoryAuthor
    public init(role: DeckMemoryDiaryRole, text: String, at: Date?, key: String, author: DeckMemoryAuthor? = nil) {
        self.role = role; self.text = text; self.at = at; self.key = key
        self.author = author ?? Self.usual(role)
    }
    static func usual(_ role: DeckMemoryDiaryRole) -> DeckMemoryAuthor {
        switch role {
        case .user: return .person
        case .assistant: return .agent
        case .tool: return .tool
        case .system, .event: return .app
        }
    }
}

/// Where a session's own conversation record is, and the account folders it must sit under.
public struct DeckMemoryFlowRecordTarget: Sendable, Equatable {
    public var path: String
    public var roots: [String]
    public var provider: String
    public var conversation: String
    /// When the app's session started (ms). Older lines belong to an earlier, resumed stretch and are not copied.
    public var notBefore: Double?
    public init(path: String, roots: [String], provider: String, conversation: String, notBefore: Double? = nil) {
        self.path = path; self.roots = roots; self.provider = provider; self.conversation = conversation; self.notBefore = notBefore
    }
}

/// Copies a session's conversation into diary pieces, reading ONLY what was added since the
/// last read. Claude Code and Codex append to their record, so the reader keeps a byte
/// position at a line start; Gemini rewrites its record, so the reader keeps the last
/// message id. No AI, no screen scraping, no timer: the caller asks when a signal arrives.
public enum DeckMemoryFlowTranscripts {
    public struct Read: Sendable, Equatable {
        public var pieces: [DeckMemoryFlowPiece]
        public var record: DeckMemoryFlowState.Record
        /// The file was replaced or cut, so it was read from its start.
        public var restarted: Bool
    }
    public static let chunkBytes = 4 * 1024 * 1024
    public static let maximumLineBytes = 16 * 1024 * 1024
    /// A record first seen when it is already huge is read from this far before its end.
    public static let maximumFirstReadBytes: Int64 = 64 * 1024 * 1024
    static let geminiMaximumBytes = 8 * 1024 * 1024

    public static func readNew(_ target: DeckMemoryFlowRecordTarget, record: DeckMemoryFlowState.Record?) throws -> Read {
        let canonical = NativeTranscriptPaths.canonical(target.path)
        guard target.roots.contains(where: { NativeTranscriptPaths.isDescendant(canonical, of: NativeTranscriptPaths.canonical($0)) }) else {
            throw NativeRPCError(code: "access-denied", message: "That conversation record is outside the session's own account folder.")
        }
        var start = record ?? .init(path: canonical)
        if start.path != canonical { start = .init(path: canonical) }
        if target.provider == "gemini" { return try readGemini(target, canonical: canonical, record: start) }

        let descriptor = Darwin.open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT || errno == ENOTDIR { return Read(pieces: [], record: start, restarted: false) }
            throw NativeRPCError(code: "unavailable", message: "The conversation record could not be opened (\(errno)).")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NativeRPCError(code: "unavailable", message: "The conversation record is not a plain file.")
        }
        let size = Int64(info.st_size), inode = UInt64(info.st_ino)
        var next = start, restarted = false
        if (start.inode != 0 && start.inode != inode) || size < start.offset {
            next.offset = 0; next.family = nil; restarted = true
        }
        next.inode = inode
        var skipFirstLine = false
        if next.offset == 0, size > maximumFirstReadBytes { next.offset = size - maximumFirstReadBytes; skipFirstLine = true }
        var pieces: [DeckMemoryFlowPiece] = [], offset = next.offset, carry = Data(), family = next.family
        while offset + Int64(carry.count) < size {
            let position = offset + Int64(carry.count)
            let want = Int(min(Int64(chunkBytes), size - position))
            var buffer = Data(count: want)
            let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, want, off_t(position)) }
            guard got > 0 else { break }
            carry.append(buffer.subdata(in: 0..<got))
            var lineStart = 0
            while let newline = carry[lineStart...].firstIndex(of: 0x0A) {
                if skipFirstLine { skipFirstLine = false }
                else if newline > lineStart, newline - lineStart <= maximumLineBytes {
                    parse(carry.subdata(in: lineStart..<newline), target: target, lineOffset: offset + Int64(lineStart),
                          family: &family, into: &pieces)
                }
                lineStart = newline + 1
            }
            offset += Int64(lineStart)
            carry = carry.subdata(in: lineStart..<carry.count)
            // A line longer than the cap is never a chat message: step over what is held of it.
            if carry.count > maximumLineBytes { offset += Int64(carry.count); carry = Data(); skipFirstLine = true }
        }
        next.offset = offset; next.family = family
        return Read(pieces: pieces, record: next, restarted: restarted)
    }

    static func parse(_ line: Data, target: DeckMemoryFlowRecordTarget, lineOffset: Int64, family: inout String?,
                      into pieces: inout [DeckMemoryFlowPiece]) {
        var found: [DeckMemoryFlowPiece] = []
        switch target.provider {
        case "claude": claude(line, conversation: target.conversation, into: &found)
        case "codex": codex(line, conversation: target.conversation, lineOffset: lineOffset, family: &family, into: &found)
        default: return
        }
        if let floor = target.notBefore {
            found.removeAll { piece in piece.at.map { $0.timeIntervalSince1970 * 1000 < floor } ?? false }
        }
        pieces += found
    }

    // MARK: Claude Code (one JSON line per record; the app's own chat rules decide what is a message)

    static func claude(_ line: Data, conversation: String, into pieces: inout [DeckMemoryFlowPiece]) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        // Tool results are large and are not something anyone said.
        if text.contains("\"tool_use_id\"") { return }
        if NativeChatTranscriptParsing.mayCarryChat(text), let chat = NativeChatTranscriptParsing.parse(text) {
            pieces.append(.init(role: chat.role == .you ? .user : .assistant, text: chat.text,
                at: chat.at > 0 ? Date(timeIntervalSince1970: chat.at / 1000) : nil,
                key: "claude:" + conversation + ":" + digest(chat.dedupeKey)))
        }
        guard text.contains("\"tool_use\""), let row = try? NativeRPCValue.parseJSON(line, maximumBytes: maximumLineBytes),
              row["type"].string == "assistant", row["isSidechain"].bool != true, row["isMeta"].bool != true else { return }
        let at = row["timestamp"].string.flatMap(BackendTaskAgentTranscripts.milliseconds).map { Date(timeIntervalSince1970: $0 / 1000) }
        for block in row["message"]["content"].elements ?? [] where block["type"].string == "tool_use" {
            guard let id = block["id"].string, let name = block["name"].string else { continue }
            pieces.append(.init(role: .tool, text: toolLine(name: name, input: block["input"]), at: at, key: "claude:" + conversation + ":tool:" + id))
        }
    }

    /// "Bash: npm test": the tool's name and the one argument that says what it did. Secrets are scrubbed.
    static func toolLine(name: String, input: NativeRPCValue) -> String {
        let scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(input)
        let telling = ["description", "command", "file_path", "path", "notebook_path", "pattern", "query", "url", "prompt", "skill", "subject"]
        var detail = ""
        for key in telling {
            if let value = scrubbed[key].string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { detail = value; break }
        }
        detail = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
        return detail.isEmpty ? name : name + ": " + detail
    }

    // MARK: Codex (rollout: one JSON line per record; a file uses ONE of two message shapes)

    static func codex(_ line: Data, conversation: String, lineOffset: Int64, family: inout String?, into pieces: inout [DeckMemoryFlowPiece]) {
        guard let text = String(data: line, encoding: .utf8), text.contains("\"event_msg\""),
              text.contains("\"user_message\"") || text.contains("\"agent_message\"") || text.contains("\"UserMessage\"") || text.contains("\"AgentMessage\""),
              let row = try? NativeRPCValue.parseJSON(line, maximumBytes: maximumLineBytes), row["type"].string == "event_msg" else { return }
        let payload = row["payload"]
        var role: DeckMemoryDiaryRole?, body = "", shape = ""
        switch payload["type"].string {
        case "user_message": role = .user; body = payload["message"].string ?? ""; shape = "legacy"
        case "agent_message": role = .assistant; body = payload["message"].string ?? ""; shape = "legacy"
        case "item_completed":
            let item = payload["item"]
            switch item["type"].string {
            case "UserMessage": role = .user
            case "AgentMessage": role = .assistant
            default: return
            }
            shape = "items"
            body = (item["content"].elements ?? []).compactMap { $0["text"].string }.joined()
        default: return
        }
        if family == nil { family = shape }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard family == shape, let role, !trimmed.isEmpty else { return }
        // Codex's own housekeeping prompts are not something anyone said.
        if role == .user, isInternalPrompt(trimmed) { return }
        let at = row["timestamp"].string.flatMap(BackendTaskAgentTranscripts.milliseconds).map { Date(timeIntervalSince1970: $0 / 1000) }
        pieces.append(.init(role: role, text: trimmed, at: at, key: "codex:" + conversation + ":" + String(lineOffset)))
    }

    /// A "user" message the CLI wrote to itself or the app wrapped around the desk: context blocks,
    /// instruction blocks, notices. FIRST VERSION, by the wrapper tags seen in rollouts on this Mac;
    /// Codex's title-writing and memory-consolidation prompts are not separately recognised yet.
    static func isInternalPrompt(_ text: String) -> Bool {
        let head = text.prefix(80).lowercased()
        return ["<environment_context", "<user_instructions", "<system-reminder", "<subagent_notification", "<turn_aborted", "<deck-memory",
                "<task-notification", "<command-name", "<command-message", "<local-command-stdout", "<local-command-stderr"]
            .contains { head.hasPrefix($0) }
    }

    // MARK: Gemini (messages are rewritten in place by id; `$rewindTo` drops what followed)

    static func readGemini(_ target: DeckMemoryFlowRecordTarget, canonical: String, record: DeckMemoryFlowState.Record) throws -> Read {
        let file = URL(fileURLWithPath: canonical)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return Read(pieces: [], record: record, restarted: false)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NativeRPCError(code: "unavailable", message: "The conversation record is not a plain file.")
        }
        let size = values.fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let start = max(0, size - geminiMaximumBytes)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: geminiMaximumBytes) ?? Data()
        var order: [String] = [], messages: [String: NativeRPCValue] = [:]
        func take(_ message: NativeRPCValue) {
            guard let id = message["id"].string, message["type"].string != nil else { return }
            if messages[id] == nil { order.append(id) }
            messages[id] = message
        }
        if canonical.hasSuffix(".json") {
            guard start == 0, let whole = try? NativeRPCValue.parseJSON(data, maximumBytes: geminiMaximumBytes) else {
                return Read(pieces: [], record: record, restarted: false)
            }
            for message in whole["messages"].elements ?? [] { take(message) }
        } else {
            if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data.subdata(in: (newline + 1)..<data.count) }
            for line in data.split(separator: 0x0A) {
                guard let row = try? NativeRPCValue.parseJSON(Data(line), maximumBytes: geminiMaximumBytes) else { continue }
                if let rewind = row["$rewindTo"].string {
                    if let index = order.firstIndex(of: rewind) { for id in order[index...] { messages[id] = nil }; order.removeSubrange(index...) }
                    continue
                }
                take(row)
            }
        }
        var next = record
        let from = record.lastMessageID.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        var pieces: [DeckMemoryFlowPiece] = []
        for id in order[min(from, order.count)...] {
            guard let message = messages[id] else { continue }
            let role: DeckMemoryDiaryRole
            switch message["type"].string {
            case "user": role = .user
            case "gemini": role = .assistant
            default: continue
            }
            let text = BackendTaskAgentTranscripts.geminiText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let at = message["timestamp"].string.flatMap(BackendTaskAgentTranscripts.milliseconds)
            if let floor = target.notBefore, let at, at < floor { continue }
            pieces.append(.init(role: role, text: text, at: at.map { Date(timeIntervalSince1970: $0 / 1000) }, key: "gemini:" + target.conversation + ":" + id))
        }
        if let last = order.last { next.lastMessageID = last }
        return Read(pieces: pieces, record: next, restarted: false)
    }

    // MARK: When there is no record to read: what the turn-end signal itself carried

    /// The person's prompt and the agent's final words, as the CLI's own turn-end hook reported them.
    public static func fromSignal(_ turn: DeckMemoryFlowTurn) -> [DeckMemoryFlowPiece] {
        let base = turn.provider + ":" + (turn.conversationID ?? turn.sessionID) + ":signal:" + String(Int64(turn.at))
        var pieces: [DeckMemoryFlowPiece] = []
        let at = Date(timeIntervalSince1970: turn.at / 1000)
        if let prompt = turn.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            pieces.append(.init(role: .user, text: prompt, at: at, key: base + ":user"))
        }
        if let answer = turn.lastAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            pieces.append(.init(role: .assistant, text: answer, at: at, key: base + ":assistant"))
        }
        return pieces
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
