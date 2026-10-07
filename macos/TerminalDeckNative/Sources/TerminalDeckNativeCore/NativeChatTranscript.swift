import Foundation
import Darwin

/// Readable chat deliberately excludes tool traffic and private reasoning.
/// These are the existing chat-transcript.ts rules, not an insights parser.
public enum NativeChatTranscriptParsing {
    public struct Line: Sendable {
        public let role: ChatMessage.Role
        public let text: String
        public let at: Double
        public let groupKey: String
        public let dedupeKey: String
        public let sessionID: String?
        public let cwd: String?
    }

    private static let cliTag = try! NSRegularExpression(pattern:
        #"^\s*<(?:command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr|bash-input|bash-stdout|bash-stderr|task-notification|user-prompt-submit-hook|system-reminder|user-memory-input|ide-opened-file|ide-selection)[\s>]"#)
    private static let reminders = try! NSRegularExpression(pattern: #"<system-reminder>[\s\S]*?</system-reminder>"#)
    private static let spacedType = try! NSRegularExpression(pattern: #""type"\s*:\s*"(?:user|assistant)""#)
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))

    private static func nonempty(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func cleanPrompt(_ text: String) -> String {
        reminders.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: trimCharacters)
    }

    private static func isCLI(_ text: String) -> Bool {
        cliTag.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func textBlocks(_ content: [Any]) -> String {
        content.compactMap { raw -> String? in
            guard let block = raw as? [String: Any], block["type"] as? String == "text",
                  let text = block["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: trimCharacters)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
    }

    /// Avoid decoding large tool-result JSON, while also accepting whitespace
    /// in valid JSON written by callers other than the compact CLI serializer.
    public static func mayCarryChat(_ line: String) -> Bool {
        if line.contains("\"tool_use_id\"") { return false }
        if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") { return true }
        return spacedType.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    public static func parse(_ line: String) -> Line? {
        guard let data = line.trimmingCharacters(in: trimCharacters).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String, ["user", "assistant"].contains(type),
              let message = raw["message"] as? [String: Any] else { return nil }
        for flag in ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"] {
            if raw[flag] as? Bool == true { return nil }
        }
        let uuid = nonempty(raw["uuid"])
        var at: Double = 0
        if let stamp = raw["timestamp"] as? String,
           let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
                ?? (try? Date.ISO8601FormatStyle().parse(stamp)) {
            at = date.timeIntervalSince1970 * 1000
        }
        let sessionID = nonempty(raw["sessionId"]), cwd = nonempty(raw["cwd"])
        if type == "assistant" {
            guard message["model"] as? String != "<synthetic>", raw["isApiErrorMessage"] as? Bool != true,
                  let content = message["content"] as? [Any] else { return nil }
            let text = textBlocks(content)
            guard !text.isEmpty else { return nil }
            let key = nonempty(message["id"]) ?? uuid ?? ""
            return Line(role: .agent, text: text, at: at, groupKey: key,
                dedupeKey: "agent\u{0}\(key)\u{0}\(text)", sessionID: sessionID, cwd: cwd)
        }
        let origin = (raw["origin"] as? [String: Any]).flatMap { nonempty($0["kind"]) }
        if let origin, origin != "human" { return nil }
        let text: String
        if let content = message["content"] as? String {
            guard !isCLI(content) else { return nil }
            text = cleanPrompt(content)
        } else if let content = message["content"] as? [Any] {
            guard origin == "human", !content.contains(where: { ($0 as? [String: Any])?["type"] as? String == "tool_result" }) else { return nil }
            let joined = textBlocks(content)
            guard !isCLI(joined) else { return nil }
            text = cleanPrompt(joined)
        } else { return nil }
        guard !text.isEmpty else { return nil }
        let key = uuid ?? String(format: "%.0f", at)
        return Line(role: .you, text: text, at: at, groupKey: key,
            dedupeKey: "you\u{0}\(key)", sessionID: sessionID, cwd: cwd)
    }
}

public struct NativeChatTranscriptLimits: Sendable {
    public var chunkBytes = 4 * 1024 * 1024
    public var maximumLineBytes = 8 * 1024 * 1024
    public var maximumFileBytes: Int64 = 512 * 1024 * 1024
    public var maximumResidentTextBytes = 16 * 1024 * 1024
    public var maximumMessages = 20_000
    public var maximumDedupeKeys = 100_000
    public init() {}
}

public struct NativeChatTranscriptRead: Sendable {
    public let path: String
    public let sessionID: String
    public let cwd: String
    public let messages: [ChatMessage]
    public let reset: Bool
    public let cursor: Int64
    public let found: Bool
    public let complete: Bool
    public let startedMidFile: Bool
    public let skippedOversizedLines: Int
    public let updatedAt: Double

    public var wireValue: [String: Any] {
        ["transcriptPath": path, "sessionId": sessionID, "cwd": cwd,
         "messages": messages.map { ["id": $0.id, "role": $0.role.rawValue, "text": $0.text, "at": $0.at] as [String: Any] },
         "reset": reset, "cursor": cursor, "found": found, "complete": complete,
         "startedMidFile": startedMidFile, "skippedOversizedLines": skippedOversizedLines, "updatedAt": updatedAt]
    }

    public static func absent() -> NativeChatTranscriptRead {
        NativeChatTranscriptRead(path: "", sessionID: "", cwd: "", messages: [], reset: false,
            cursor: 0, found: false, complete: true, startedMidFile: false, skippedOversizedLines: 0,
            updatedAt: Date().timeIntervalSince1970 * 1000)
    }
}

public enum NativeChatTranscriptError: Error, LocalizedError {
    case fileRead(Int32), outsideStore, fileBudget, residentBudget
    public var errorDescription: String? {
        switch self {
        case .fileRead(let code): return "The transcript could not be read (filesystem error \(code))."
        case .outsideStore: return "The opened transcript is outside the approved transcript stores."
        case .fileBudget: return "The transcript exceeds this reader's 512 MiB file budget. Use a bounded tail or a smaller transcript."
        case .residentBudget: return "The readable conversation exceeds this reader's memory budget. Close it and use a bounded transcript tail."
        }
    }
}

/// Actor-owned byte cursor. Keeping incomplete lines as bytes preserves UTF-8
/// across chunk boundaries without repeatedly decoding a partial character.
/// Every read descriptor closes before the actor yields its result.
public actor NativeChatTranscriptReader {
    public nonisolated let path: String
    private let allowedRoots: [String]
    private let limits: NativeChatTranscriptLimits
    private var offset: Int64
    private var startedMidFile: Bool
    private var pending = Data()
    private var discardingLine = false
    private var skippedOversizedLines = 0
    private var identity: String?
    private var messages: [ChatMessage] = []
    private var openAgentIndex: Int?
    private var seen = Set<String>()
    private var ordinal = 0
    private var residentTextBytes = 0
    private var sessionID: String
    private var cwd = ""

    public init(path: String, sessionID: String? = nil, startAt: Int64 = 0,
                allowedRoots: [String] = [], limits: NativeChatTranscriptLimits = NativeChatTranscriptLimits()) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.sessionID = sessionID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.offset = max(0, startAt)
        self.startedMidFile = startAt > 0
        self.allowedRoots = allowedRoots
        self.limits = limits
    }

    public var conversation: [ChatMessage] { messages }
    public var position: Int64 { offset }

    private func rewind() {
        offset = 0; pending.removeAll(); discardingLine = false; skippedOversizedLines = 0
        messages.removeAll(); openAgentIndex = nil; seen.removeAll(); ordinal = 0; residentTextBytes = 0
        cwd = ""; startedMidFile = false
    }

    private func result(_ changed: [ChatMessage], reset: Bool, found: Bool, complete: Bool) -> NativeChatTranscriptRead {
        NativeChatTranscriptRead(path: path, sessionID: sessionID, cwd: cwd, messages: changed, reset: reset,
            cursor: offset, found: found, complete: complete, startedMidFile: startedMidFile,
            skippedOversizedLines: skippedOversizedLines, updatedAt: Date().timeIntervalSince1970 * 1000)
    }

    public func readChunk() throws -> NativeChatTranscriptRead {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT || errno == ENOTDIR { return result([], reset: false, found: false, complete: true) }
            throw NativeChatTranscriptError.fileRead(errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NativeChatTranscriptError.fileRead(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return result([], reset: false, found: false, complete: true) }
        if !allowedRoots.isEmpty {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { throw NativeChatTranscriptError.fileRead(errno) }
            let openedPath = String(cString: buffer)
            guard allowedRoots.contains(where: { NativeTranscriptPaths.isDescendant(openedPath, of: $0) }) else {
                throw NativeChatTranscriptError.outsideStore
            }
        }
        let currentIdentity = "\(info.st_dev):\(info.st_ino)"
        let size = Int64(info.st_size)
        var reset = false
        if size < offset || identity.map({ $0 != currentIdentity }) == true { rewind(); reset = true }
        identity = currentIdentity
        if size == offset { return result([], reset: reset, found: true, complete: true) }
        guard size - offset <= limits.maximumFileBytes else { throw NativeChatTranscriptError.fileBudget }
        let length = min(max(1, limits.chunkBytes), Int(size - offset))
        var chunk = Data(count: length)
        let consumed = chunk.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(offset)) }
        guard consumed >= 0 else { throw NativeChatTranscriptError.fileRead(errno) }
        guard consumed > 0 else { return result([], reset: reset, found: true, complete: true) }
        chunk = Data(chunk.prefix(consumed))

        // Work on snapshots so a budget refusal cannot advance past unread prose.
        var nextPending = pending, nextDiscarding = discardingLine, nextSkipped = skippedOversizedLines
        var nextMessages = messages, nextSeen = seen, nextOpen = openAgentIndex
        var nextOrdinal = ordinal, nextResident = residentTextBytes, nextCwd = cwd, nextSession = sessionID
        var changed: [String: ChatMessage] = [:], changedOrder: [String] = []
        func consumeLine(_ bytes: Data) throws {
            let line = String(decoding: bytes, as: UTF8.self)
            guard NativeChatTranscriptParsing.mayCarryChat(line), let parsed = NativeChatTranscriptParsing.parse(line),
                  !nextSeen.contains(parsed.dedupeKey) else { return }
            guard nextSeen.count < limits.maximumDedupeKeys, nextResident + parsed.text.utf8.count + 2 <= limits.maximumResidentTextBytes else {
                throw NativeChatTranscriptError.residentBudget
            }
            nextSeen.insert(parsed.dedupeKey)
            if nextSession.isEmpty, let value = parsed.sessionID { nextSession = value }
            if nextCwd.isEmpty, let value = parsed.cwd { nextCwd = value }
            let changedMessage: ChatMessage
            if parsed.role == .agent, let index = nextOpen {
                let old = nextMessages[index]
                changedMessage = ChatMessage(id: old.id, role: .agent,
                    text: old.text.isEmpty ? parsed.text : old.text + "\n\n" + parsed.text,
                    at: old.at == 0 ? parsed.at : old.at)
                nextMessages[index] = changedMessage
            } else {
                guard nextMessages.count < limits.maximumMessages else { throw NativeChatTranscriptError.residentBudget }
                nextOrdinal += 1
                changedMessage = ChatMessage(id: "\(parsed.role.rawValue):\(parsed.groupKey.isEmpty ? "line-\(nextOrdinal)" : parsed.groupKey)",
                    role: parsed.role, text: parsed.text, at: parsed.at)
                nextMessages.append(changedMessage)
                nextOpen = parsed.role == .agent ? nextMessages.count - 1 : nil
            }
            nextResident += parsed.text.utf8.count + 2
            if changed[changedMessage.id] == nil { changedOrder.append(changedMessage.id) }
            changed[changedMessage.id] = changedMessage
        }
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 0x0a)
            let end = newline ?? chunk.endIndex
            if !nextDiscarding {
                if nextPending.count + end - start <= max(1, limits.maximumLineBytes) { nextPending.append(contentsOf: chunk[start..<end]) }
                else { nextPending.removeAll(); nextDiscarding = true; nextSkipped += 1 }
            }
            if let newline {
                if !nextDiscarding { try consumeLine(nextPending) }
                nextPending.removeAll(keepingCapacity: true); nextDiscarding = false
                start = newline + 1
            } else { break }
        }
        offset += Int64(consumed)
        pending = nextPending; discardingLine = nextDiscarding; skippedOversizedLines = nextSkipped
        messages = nextMessages; seen = nextSeen; openAgentIndex = nextOpen; ordinal = nextOrdinal
        residentTextBytes = nextResident; cwd = nextCwd; sessionID = nextSession
        return result(changedOrder.compactMap { changed[$0] }, reset: reset, found: true, complete: offset >= size)
    }

    /// Whole reads still use 4 MiB chunks, with a fixed per-call byte budget so
    /// an actively growing file cannot keep a request alive indefinitely.
    public func readAll(wholeConversation: Bool = false, forceReset: Bool = false) async throws -> NativeChatTranscriptRead {
        var changed: [ChatMessage] = [], reset = forceReset, spent: Int64 = 0, chunks = 0
        let maximumChunks = max(1, Int(limits.maximumFileBytes / Int64(max(1, limits.chunkBytes))) + 1)
        while true {
            try Task.checkCancellation()
            let before = offset
            let chunk = try readChunk()
            chunks += 1
            spent += max(0, offset - before)
            if chunk.reset { changed.removeAll(); reset = true }
            changed = ChatRules.merge(changed, chunk.messages)
            if chunk.complete || spent >= limits.maximumFileBytes || chunks >= maximumChunks {
                return result(wholeConversation ? messages : changed, reset: reset, found: chunk.found, complete: chunk.complete)
            }
            await Task.yield()
        }
    }
}
