import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// HOOTFIX (2026-10-09): the task engine reads "the last thing the agent said" from the
/// agent's OWN conversation record, for every agent a task can be given to — not only
/// Claude. Codex keeps a rollout per thread under `<CODEX_HOME>/sessions/YYYY/MM/DD/`;
/// Gemini keeps one JSONL per session under `<home>/.gemini/tmp/<project>/chats/`.
/// Both are found strictly: the known conversation ID, else exactly one record for this
/// folder that started with the session. Ambiguity answers nil (the screen is used), never
/// another session's words. Reads are bounded to the file's last 4 MB.
public enum BackendTaskAgentTranscripts {
    public static let maximumTailBytes = 4 * 1024 * 1024
    private static let maximumScan = 20_000

    // MARK: Production locator

    /// The task engine's one locator for all three agents. Session events carry no
    /// request, so account reads run under the app-owner context composition supplies
    /// (HOST builds refuse a profile read without one); a request's own context wins.
    public static func locator(
        claude: @escaping @Sendable (BackendSessionMeta, String?) async throws -> BackendTaskTranscriptTarget?,
        metadata: @escaping @Sendable () async -> [BackendSessionLifecycleCoordinator.Metadata],
        systemDirectory: @escaping @Sendable (String) -> String,
        ownerContext: (@Sendable () throws -> NativeRPCContext)? = nil,
        transcriptConfiguration: (@Sendable (String) async -> String?)? = nil
    ) -> @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget? {
        { meta in
            let find: @Sendable () async throws -> BackendTaskTranscriptTarget? = {
                // 22 Oct: with `transcriptConfiguration`, only this session's setting is asked of the session host;
                // `metadata` then lists rows without theirs.
                let rows = await metadata(), row = rows.first { $0.session.id == meta.id }
                let configured: String?
                if let transcriptConfiguration { configured = await transcriptConfiguration(meta.id) } else { configured = row?.transcriptConfiguration }
                if meta.provider == "claude" { return try await claude(meta, configured) }
                guard ["codex", "gemini"].contains(meta.provider) else { return nil }
                let known = meta.agentSessionId ?? row?.observedCLIConversationID
                let claimed = Set(rows.filter { $0.session.id != meta.id && $0.session.provider == meta.provider }
                    .compactMap { $0.session.agentSessionId ?? $0.observedCLIConversationID })
                return try target(provider: meta.provider, configDirectory: configured ?? systemDirectory(meta.provider),
                                  cwd: meta.cwd, createdAt: meta.createdAt, knownID: known, claimed: claimed)
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            if BackendHOSTProfileScope.context == nil, NativeCompositionCallContext.rpc == nil, let owner = try? ownerContext?() {
                return try await BackendHOSTProfileScope.withContext(owner, operation: find)
            }
            #endif
            return try await find()
        }
    }

    // MARK: Locate

    /// The record for a running Codex/Gemini session, confined to that account's home.
    public static func target(provider: String, configDirectory: String, cwd: String, createdAt: Double,
                              knownID: String?, claimed: Set<String> = []) throws -> BackendTaskTranscriptTarget? {
        switch provider {
        case "codex":
            guard let thread = try BackendSessionSwitchCodexCarry.find(home: configDirectory, cwd: cwd, startedAt: createdAt,
                                                                      knownID: knownID, claimed: claimed) else { return nil }
            let root = URL(fileURLWithPath: configDirectory).appendingPathComponent("sessions").path
            return .init(path: thread.file.path, roots: [root])
        case "gemini":
            let roots = geminiRoots(configDirectory: configDirectory)
            guard let path = try locateGemini(roots: roots, cwd: cwd, createdAt: createdAt, knownID: knownID, claimed: claimed) else { return nil }
            return .init(path: path, roots: roots)
        default: return nil
        }
    }

    /// `GEMINI_CLI_HOME` names the home that holds `.gemini`; the system profile's directory
    /// IS `~/.gemini`. Under sandbox-exec Gemini keeps its runtime in `~/.cache/.gemini`.
    public static func geminiRoots(configDirectory: String) -> [String] {
        let configured = URL(fileURLWithPath: configDirectory).standardizedFileURL
        let home = configured.lastPathComponent == ".gemini" ? configured.deletingLastPathComponent() : configured
        return [home.appendingPathComponent(".gemini/tmp").path, home.appendingPathComponent(".cache/.gemini/tmp").path]
    }

    static func locateGemini(roots: [String], cwd: String, createdAt: Double, knownID: String?, claimed: Set<String>) throws -> String? {
        let hashes = Set([cwd, NativeTranscriptPaths.canonical(cwd)].map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() })
        var found: [String: String] = [:], scanned = 0
        for root in roots where FileManager.default.fileExists(atPath: root) {
            let projects = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for project in projects {
                let chats = URL(fileURLWithPath: root).appendingPathComponent(project).appendingPathComponent("chats")
                for name in (try? FileManager.default.contentsOfDirectory(atPath: chats.path)) ?? [] {
                    scanned += 1
                    guard scanned <= maximumScan else { throw BackendSessionFailure.invalidInput("The Gemini conversation search exceeded its file budget.") }
                    guard name.hasPrefix("session-"), name.hasSuffix(".jsonl") || name.hasSuffix(".json") else { continue }
                    let file = chats.appendingPathComponent(name)
                    guard regular(file), NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(file.path), of: NativeTranscriptPaths.canonical(root)),
                          let meta = geminiMetadata(file), let id = meta["sessionId"].string, !claimed.contains(id) else { continue }
                    if let knownID {
                        if id == knownID { found[id] = file.path }
                        continue
                    }
                    guard let hash = meta["projectHash"].string, hashes.contains(hash),
                          let started = meta["startTime"].string.flatMap(milliseconds), started >= createdAt - 2_000 else { continue }
                    found[id] = file.path
                }
            }
        }
        return found.count == 1 ? found.values.first : nil
    }

    static func geminiConversationID(_ target: BackendTaskTranscriptTarget) -> String? {
        guard let file = try? confined(target) else { return nil }
        return geminiMetadata(file)?["sessionId"].string
    }
    private static func geminiMetadata(_ file: URL) -> NativeRPCValue? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
        if file.pathExtension == "jsonl" {
            return try? NativeRPCValue.parseJSON(Data(head.prefix { $0 != 0x0a }), maximumBytes: 1024 * 1024)
        }
        // Older Gemini wrote one JSON object; the metadata sits at its top.
        guard let whole = try? Data(contentsOf: file, options: .mappedIfSafe), whole.count <= maximumTailBytes else { return nil }
        return try? NativeRPCValue.parseJSON(whole, maximumBytes: maximumTailBytes)
    }

    // MARK: Read

    /// The newest assistant message in a Codex rollout (`response_item` assistant
    /// `output_text`, or the `agent_message` event), with its own timestamp.
    public static func codexAnswer(_ target: BackendTaskTranscriptTarget) throws -> BackendTaskAnswer? {
        var latest: BackendTaskAnswer?
        for row in try lines(target) {
            let payload = row["payload"]
            var text = ""
            if row["type"].string == "response_item", payload["type"].string == "message", payload["role"].string == "assistant" {
                text = (payload["content"].elements ?? []).filter { ["output_text", "text"].contains($0["type"].string ?? "") }
                    .compactMap { $0["text"].string }.joined()
            } else if row["type"].string == "event_msg", payload["type"].string == "agent_message" {
                text = payload["message"].string ?? ""
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let at = row["timestamp"].string.flatMap(milliseconds) else { continue }
            latest = .init(text: trimmed, at: at)
        }
        return latest
    }

    /// The newest `gemini` message in a Gemini session record. Messages are rewritten in
    /// place by ID (tokens/tool calls arrive later) and `$rewindTo` drops what followed.
    public static func geminiAnswer(_ target: BackendTaskTranscriptTarget) throws -> BackendTaskAnswer? {
        var order: [String] = [], messages: [String: NativeRPCValue] = [:]
        func take(_ message: NativeRPCValue) {
            guard let id = message["id"].string, message["type"].string != nil else { return }
            if messages[id] == nil { order.append(id) }
            messages[id] = message
        }
        if target.path.hasSuffix(".json") {
            let whole = try bounded(target)
            for message in (try NativeRPCValue.parseJSON(whole, maximumBytes: maximumTailBytes))["messages"].elements ?? [] { take(message) }
        } else {
            for row in try lines(target) {
                if let rewind = row["$rewindTo"].string {
                    if let index = order.firstIndex(of: rewind) { for id in order[index...] { messages[id] = nil }; order.removeSubrange(index...) }
                    continue
                }
                take(row)
            }
        }
        for id in order.reversed() {
            guard let message = messages[id], message["type"].string == "gemini" else { continue }
            let text = geminiText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let at = message["timestamp"].string.flatMap(milliseconds) else { continue }
            return .init(text: text, at: at)
        }
        return nil
    }

    static func geminiText(_ content: NativeRPCValue) -> String {
        if let text = content.string { return text }
        if let parts = content.elements { return parts.filter { $0["thought"].bool != true }.map { geminiText($0) }.joined() }
        return content["text"].string ?? ""
    }

    // MARK: Bounded IO

    private static func regular(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private static func confined(_ target: BackendTaskTranscriptTarget) throws -> URL {
        let file = URL(fileURLWithPath: target.path), canonical = NativeTranscriptPaths.canonical(target.path)
        guard regular(file), target.roots.contains(where: { NativeTranscriptPaths.isDescendant(canonical, of: NativeTranscriptPaths.canonical($0)) }) else {
            throw BackendSessionFailure.invalidInput("That conversation record is outside the session's own account folder.")
        }
        return file
    }
    private static func bounded(_ target: BackendTaskTranscriptTarget) throws -> Data {
        let file = try confined(target)
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let start = max(0, size - maximumTailBytes)
        try handle.seek(toOffset: UInt64(start))
        var data = try handle.read(upToCount: maximumTailBytes) ?? Data()
        // A tail that starts mid-line drops that partial first line.
        if start > 0, let newline = data.firstIndex(of: 0x0a) { data = data.subdata(in: data.index(after: newline)..<data.endIndex) }
        return data
    }
    private static func lines(_ target: BackendTaskTranscriptTarget) throws -> [NativeRPCValue] {
        try bounded(target).split(separator: 0x0a).compactMap { try? NativeRPCValue.parseJSON(Data($0), maximumBytes: maximumTailBytes) }
    }
    static func milliseconds(_ iso: String) -> Double? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date.timeIntervalSince1970 * 1_000 }
        return ISO8601DateFormatter().date(from: iso).map { $0.timeIntervalSince1970 * 1_000 }
    }
}
