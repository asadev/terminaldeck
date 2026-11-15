import Foundation
import TerminalDeckNativeCore

/// Sessions in the Cloud, step 1 (owner, 15 Nov: "I want to keep all the chat histories, no matter how big they are ...
/// inside the cloud"): the chats of Terminal Deck's OWN past sessions on this Mac, which no side panel lists any more.
/// They go up in the background after the listed sessions' catch-up and become "Earlier chats" of their project.
/// - Where: every AI login folder Terminal Deck made (`<data>/account-logins/*`, a copy's `<data>/agent-homes/*`) and the
///   app's saved chats (`<data>/session-chats/*`) that are no longer open. Never the plain `~/.claude`, `~/.codex`,
///   `~/.gemini` homes (AI chats run outside Terminal Deck).
/// - A HISTORY vs a HELPER-AGENT history (left out of step 1):
///   - Claude Code: a history is a `.jsonl` file DIRECTLY in `projects/<folder>/`, named by its conversation id. A helper
///     agent's history lives one level deeper (`projects/<folder>/<conversation>/subagents/agent-*.jsonl`) or, in older
///     Claude versions, is named `agent-*.jsonl` and its lines say `"isSidechain": true`. Only the first is taken.
///   - Codex: a history is `sessions/**/rollout-*.jsonl` (or `archived_sessions/`) whose first line, `session_meta`, does
///     NOT name a parent thread (`payload.source.subagent`); a helper thread's rollout names one and is left out.
///   - Gemini: `tmp/<project>/chats/*.json` (Gemini keeps no helper-agent files).
/// - Its project: from the folder the history belongs to (the `cwd` the AI wrote in it), resolved like every session's.
///   Its name: what the app still knows about that session (its kept title), else the first words he typed. Its dates:
///   from the history itself (first and last real turn), never the file's copy time.
/// Sizes and the first lines only are read to find this; the copying itself is the uploader's.
public enum BackendCloudChatsArchive {
    public struct Found: Codable, Sendable, Equatable {
        public var path: String
        public var format: BackendCloudChatsReadable.Format
        public var provider: String
        public var conversation: String?
        public var cwd: String?
        public var name: String
        public var startedAt: Int64?
        public var lastUsedAt: Int64
        public init(path: String, format: BackendCloudChatsReadable.Format, provider: String, conversation: String?, cwd: String?,
                    name: String, startedAt: Int64?, lastUsedAt: Int64) {
            self.path = path; self.format = format; self.provider = provider; self.conversation = conversation; self.cwd = cwd
            self.name = name; self.startedAt = startedAt; self.lastUsedAt = lastUsedAt
        }
    }
    /// How much of a history's start is read to learn its folder, its first words and when it began.
    public static let headBytes = 256 * 1024

    /// True for a Claude Code history the person had (not a helper agent's): directly in `projects/<folder>/`.
    public static func isClaudeHistory(_ file: URL, projects: URL) -> Bool {
        guard file.pathExtension == "jsonl", !file.lastPathComponent.hasPrefix("agent-") else { return false }
        return file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == projects.standardizedFileURL.path
    }

    /// Every past history under Terminal Deck's own homes and every saved app chat, minus `skip` (paths already copied or
    /// listed). `knownNames`: the app's kept titles by conversation id. Folders only; at most 20,000 files looked at.
    public static func scan(homes: [URL], chats: URL?, skip: Set<String>, knownNames: [String: String] = [:]) -> [Found] {
        var found: [Found] = []
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        }
        func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var looked = 0
        for home in homes where isDirectory(home) {
            // Claude Code: projects/<folder>/<conversation>.jsonl
            let projects = home.appendingPathComponent("projects", isDirectory: true)
            for folder in children(projects) where isDirectory(folder) {
                for file in children(folder) where isClaudeHistory(file, projects: projects) && !skip.contains(file.path) {
                    looked += 1; guard looked <= 20_000 else { return found }
                    if let made = claude(file, knownNames: knownNames) { found.append(made) }
                }
            }
            // Codex: sessions/**/rollout-*.jsonl and archived_sessions/**.
            for name in ["sessions", "archived_sessions"] {
                let root = home.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(root), let cursor = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in cursor where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" && !skip.contains(file.path) {
                    looked += 1; guard looked <= 20_000 else { return found }
                    if let made = codex(file, knownNames: knownNames) { found.append(made) }
                }
            }
            // Gemini: tmp/<project>/chats/*.json
            for project in children(home.appendingPathComponent("tmp", isDirectory: true)) {
                for file in children(project.appendingPathComponent("chats", isDirectory: true)) where file.pathExtension == "json" && !skip.contains(file.path) {
                    looked += 1; guard looked <= 20_000 else { return found }
                    if let made = gemini(file, knownNames: knownNames) { found.append(made) }
                }
            }
        }
        // The app's saved chats that no open session holds (their newest saved file each).
        if let chats {
            for folder in children(chats) where isDirectory(folder) && folder.lastPathComponent != "delivery-requests" {
                let engine = folder.appendingPathComponent("new-engine", isDirectory: true)
                let place = manager.fileExists(atPath: engine.appendingPathComponent("active").path) ? engine : folder
                guard let file = BackendCloudChatsLocator.newestChat(in: place), !skip.contains(file.path) else { continue }
                looked += 1; guard looked <= 20_000 else { return found }
                if let made = appChat(file, knownNames: knownNames) { found.append(made) }
            }
        }
        return found
    }

    /// The first words he typed, as a name: at most 8 words and 60 characters.
    public static func name(firstWords text: String?) -> String? {
        let words = (text ?? "").split(whereSeparator: { $0.isWhitespace }).prefix(8).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count <= 60 ? words : String(words.prefix(59)) + "…"
    }
    static func head(_ file: URL) -> Data? { BackendCloudChats.read(file, from: 0, count: headBytes) }
    static func modified(_ file: URL) -> Int64 { Int64((BackendCloudChats.look(file)?.mtime ?? 0) * 1000) }

    static func claude(_ file: URL, knownNames: [String: String]) -> Found? {
        guard let head = head(file), !head.isEmpty else { return nil }
        var cwd: String?, started: Int64?, first: String?, title: String?
        let conversation = file.deletingPathExtension().lastPathComponent
        for line in head.split(separator: 0x0a).prefix(4_000) {
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = raw["type"] as? String
            // A helper agent's history written beside the person's (older Claude): its lines are side chains.
            if (type == "user" || type == "assistant"), raw["isSidechain"] as? Bool == true, first == nil { return nil }
            if cwd == nil, let value = raw["cwd"] as? String, !value.isEmpty { cwd = value }
            if started == nil, let stamp = raw["timestamp"] as? String, let at = BackendCloudChatsReadable.isoMs(stamp) { started = Int64(at) }
            if title == nil, type == "summary" || type == "custom-title" { title = (raw["summary"] as? String) ?? (raw["customTitle"] as? String) }
            if first == nil, let text = String(data: Data(line), encoding: .utf8), NativeChatTranscriptParsing.mayCarryChat(text),
               let parsed = NativeChatTranscriptParsing.parse(text), parsed.role == .you { first = parsed.text }
            if cwd != nil, started != nil, first != nil { break }
        }
        guard first != nil || title != nil else { return nil } // nothing he wrote: not a chat
        let last = BackendSessionActivity.lastTurn(file.path).map { Int64($0) } ?? modified(file)
        let name = knownNames[conversation] ?? clean(title) ?? self.name(firstWords: first) ?? "Chat"
        return .init(path: file.path, format: .claude, provider: "claude", conversation: conversation, cwd: cwd, name: name,
                     startedAt: started, lastUsedAt: last)
    }

    static func codex(_ file: URL, knownNames: [String: String]) -> Found? {
        guard let head = head(file), let metaLine = head.split(separator: 0x0a).first,
              let meta = (try? JSONSerialization.jsonObject(with: Data(metaLine))) as? [String: Any], meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any] else { return nil }
        // A helper thread started by another Codex thread names its parent: left out.
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return nil }
        let conversation = payload["id"] as? String
        let started = (payload["timestamp"] as? String ?? meta["timestamp"] as? String).flatMap(BackendCloudChatsReadable.isoMs).map { Int64($0) }
        var first: String?, last: Int64?
        for line in head.split(separator: 0x0a).dropFirst().prefix(4_000) {
            if first == nil, let message = BackendCloudChatsReadable.messages(line: Data(line), format: .codex).first, message.role == .person { first = message.text }
            if first != nil { break }
        }
        guard first != nil else { return nil }
        // The last real turn: the newest timestamped line in the file's last 512 KB.
        if let size = BackendCloudChats.look(file)?.size, let tail = BackendCloudChats.read(file, from: max(0, size - 512 * 1024), count: 512 * 1024) {
            for line in tail.split(separator: 0x0a).reversed().prefix(2_000) {
                if let raw = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], raw["type"] as? String == "response_item",
                   let stamp = raw["timestamp"] as? String, let at = BackendCloudChatsReadable.isoMs(stamp) { last = Int64(at); break }
            }
        }
        let name = conversation.flatMap { knownNames[$0] } ?? self.name(firstWords: first) ?? "Chat"
        return .init(path: file.path, format: .codex, provider: "codex", conversation: conversation, cwd: payload["cwd"] as? String, name: name,
                     startedAt: started, lastUsedAt: last ?? modified(file))
    }

    static func gemini(_ file: URL, knownNames: [String: String]) -> Found? {
        guard let size = BackendCloudChats.look(file)?.size, size <= 64 * 1_048_576, let data = BackendCloudChats.read(file, from: 0, count: Int(size)),
              let parsed = BackendCloudChatsReadable.gemini(data), let first = parsed.messages.first(where: { $0.role == .person }) else { return nil }
        let conversation = parsed.conversation.isEmpty ? nil : parsed.conversation
        let times = parsed.messages.map(\.at).filter { $0 > 0 }
        let name = conversation.flatMap { knownNames[$0] } ?? self.name(firstWords: first.text) ?? "Chat"
        return .init(path: file.path, format: .gemini, provider: "gemini", conversation: conversation, cwd: nil, name: name,
                     startedAt: times.min().map { Int64($0) }, lastUsedAt: times.max().map { Int64($0) } ?? modified(file))
    }

    static func appChat(_ file: URL, knownNames: [String: String]) -> Found? {
        guard let size = BackendCloudChats.look(file)?.size, size <= 512 * 1_048_576, let data = BackendCloudChats.read(file, from: 0, count: Int(size)),
              let snapshot = try? NativeRPCValue.parseJSON(data, maximumBytes: 512 * 1_048_576), snapshot.fields != nil,
              let conversation = snapshot["conversationId"].string else { return nil }
        let events = (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }.filter { $0.conversationID == conversation }
        guard let first = events.first(where: { $0.record.kind == .user }) else { return nil }
        let times = events.map(\.at).filter { $0 > 0 }
        let name = knownNames[conversation] ?? clean(snapshot["title"].string) ?? self.name(firstWords: first.record.value["text"].string) ?? "Chat"
        let provider = file.deletingPathExtension().lastPathComponent == "chat" ? "claude" : String(file.deletingPathExtension().lastPathComponent.dropFirst(5))
        return .init(path: file.path, format: .appChat, provider: provider, conversation: conversation, cwd: snapshot["cwd"].string, name: name,
                     startedAt: times.min().map { Int64($0) }, lastUsedAt: times.max().map { Int64($0) } ?? modified(file))
    }
    static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…"
    }

    /// The list row an earlier chat is put with: its project from its folder, its name and dates, "ended".
    public static func row(_ found: Found, id: String, projects: [PROJProject]) -> BackendCloudChats.Row {
        var project: BackendCloudChats.Project?
        if let cwd = found.cwd {
            let projectID = PROJProjects.resolve(projectID: nil, folder: cwd, projects: projects)
            if projectID != PROJProjects.independentID, let entry = projects.first(where: { $0.id == projectID }) {
                project = .init(cloudRef: BackendCloudChats.clip(entry.id, 128) ?? entry.id, name: BackendCloudChats.clip(entry.name, 120) ?? "")
            }
        }
        return .init(sessionId: id, name: BackendCloudChats.clip(found.name, 200) ?? "Chat", lastUsedAt: found.lastUsedAt, project: project,
                     cwd: BackendCloudChats.clip(found.cwd, 512), ai: found.provider, kind: found.format == .appChat ? "chat" : "terminal",
                     status: "ended", startedAt: found.startedAt, conversationId: BackendCloudChats.clip(found.conversation, 128))
    }
    /// The source the uploader copies an earlier chat from (no tool-results side files: only the history itself).
    public static func source(_ found: Found) -> BackendCloudChats.Source {
        let url = URL(fileURLWithPath: found.path)
        let provider = HootChatProvider(rawValue: found.provider) ?? .claude
        if found.format == .appChat { return .init(readable: .appChat, snap: url, provider: provider) }
        return .init(raw: url, readable: found.format, provider: provider)
    }
}
