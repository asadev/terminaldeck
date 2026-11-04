import Foundation
import Darwin
import TerminalDeckNativeCore

/// Read-only provider discovery. Codex methods/fields were checked against the installed
/// 0.159.3 app-server JSON schema. No discovery operation resumes or starts a turn.
public enum BackendChatProviderCatalogue {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations: Set<String> = ["catalogue/list", "catalogue/read", "skills/list", "instructions/read"]

    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, appliedInstructions: NativeRPCValue = .null,
                              request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation) else { throw NativeRPCError.invalidArguments("Unknown provider catalogue operation.") }
        try project(cwd)
        guard provider == .codex else {
            return unavailable(provider, cwd: cwd, reason: provider == .claude
                ? "Claude does not expose this read-only manifest over its Chat control protocol. Its saved conversations use the account-scoped transcript catalogue."
                : "This provider has no verified catalogue or source-manifest protocol in this installation.")
        }
        switch operation {
        case "catalogue/list":
            var params = object([("cwd", .string(cwd)), ("limit", .number(Double(try limit(arguments)))),
                ("sortKey", .string("updated_at")), ("sortDirection", .string("desc")),
                ("archived", .bool(arguments["archived"].bool == true)), ("useStateDbOnly", .bool(true))])
            if let cursor = try cursor(arguments) { params = params.setting("cursor", .string(cursor)) }
            if let query = try optionalText(arguments["query"], name: "search", maximum: 512) {
                params = params.setting("searchTerm", .string(query))
            }
            let response = try await request("thread/list", params)
            let threads = try response["data"].requireArray("provider conversation catalogue")
            var seen = Set<String>()
            let rows = try threads.compactMap { thread -> NativeRPCValue? in
                guard thread["cwd"].string == cwd else { return nil }
                let id = try identifier(thread["id"])
                guard seen.insert(id).inserted else { return nil }
                return summary(thread, cwd: cwd, id: id)
            }
            return page(provider, cwd: cwd, items: rows, next: response["nextCursor"], source: "thread/list")
        case "catalogue/read":
            let id = try identifier(arguments["conversationId"])
            let metadata = try await request("thread/read", object([("threadId", .string(id)), ("includeTurns", .bool(false))]))
            guard metadata["thread"]["id"].string == id, metadata["thread"]["cwd"].string == cwd else {
                throw NativeRPCError(code: "access-denied", message: "The selected conversation does not belong to this provider and project.")
            }
            var params = object([("threadId", .string(id)), ("limit", .number(Double(try limit(arguments)))),
                ("itemsView", .string("full")), ("sortDirection", .string("asc"))])
            if let cursor = try cursor(arguments) { params = params.setting("cursor", .string(cursor)) }
            let response = try await request("thread/turns/list", params)
            let turns = try response["data"].requireArray("provider conversation turns")
            var clipped = false
            let messages = turns.flatMap { turn in
                (turn["items"].elements ?? []).compactMap { item -> NativeRPCValue? in
                    let role: String, text: String
                    switch item["type"].string {
                    case "userMessage":
                        role = "user"; text = (item["content"].elements ?? []).filter { $0["type"].string == "text" }
                            .compactMap { $0["text"].string }.joined(separator: "\n")
                    case "agentMessage": role = "assistant"; text = item["text"].string ?? ""
                    default: return nil
                    }
                    if text.count > 32_768 { clipped = true }
                    return object([("id", item["id"]), ("turnId", turn["id"]), ("role", .string(role)),
                        ("text", .string(String(text.prefix(32_768))))])
                }
            }
            return page(provider, cwd: cwd, items: messages, next: response["nextCursor"], source: "thread/turns/list")
                .setting("conversationId", .string(id)).setting("conversation", summary(metadata["thread"], cwd: cwd, id: id))
                .setting("textClipped", .bool(clipped)).setting("previewScope", .string("User and assistant text; tool payloads and non-text attachments are omitted."))
        case "skills/list":
            let response = try await request("skills/list", object([("cwds", .array([.string(cwd)]))]))
            let entries = try response["data"].requireArray("provider skills")
            let matching = entries.filter { $0["cwd"].string == cwd }
            guard !matching.isEmpty else { throw NativeRPCError.malformed("The provider returned no skill manifest for this project.") }
            var seen = Set<String>()
            let commands = BackendCodexChatCommands.skills(response, cwd: cwd)
            let reserved = Set(BackendCodexChatCommands.builtins(model: "known").compactMap { $0["name"].string })
            let skills = matching.flatMap { $0["skills"].elements ?? [] }.compactMap { skill -> NativeRPCValue? in
                guard let name = skill["name"].string, let path = skill["path"].string,
                      path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
                let enabled = skill["enabled"].bool == true
                let command = commands[name]?["path"].string == path && !reserved.contains(name) ? "/" + name : nil
                return object([("name", .string(name)), ("description", skill["description"]), ("shortDescription", skill["shortDescription"]),
                    ("path", .string(path)), ("scope", skill["scope"]), ("pluginId", skill["pluginId"]),
                    ("enabled", .bool(enabled)), ("invocable", .bool(enabled && command != nil)),
                    ("command", command.map(NativeRPCValue.string) ?? .null), ("invocationShape", .string("/skill-name [instructions]"))])
            }
            return page(provider, cwd: cwd, items: skills, next: .null, source: "skills/list")
                .setting("errors", .array(matching.flatMap { $0["errors"].elements ?? [] }))
        default:
            let response = try await request("config/read", object([("cwd", .string(cwd)), ("includeLayers", .bool(true))]))
            guard response["config"].fields != nil, response["origins"].fields != nil else {
                throw NativeRPCError.malformed("The provider returned no effective instruction configuration.")
            }
            // Do not forward the full config: it can include credentials, server headers and unrelated settings.
            let keys = ["instructions", "developer_instructions", "model_instructions_file", "project_doc_fallback_filenames", "project_doc_max_bytes"]
            let sources = keys.compactMap { key -> NativeRPCValue? in
                guard !response["config"][key].isNullish else { return nil }
                let origin = response["origins"][key]
                return object([("key", .string(key)), ("value", response["config"][key]),
                    ("origin", originSummary(origin)), ("basis", .string("provider-effective-config"))])
            }
            let layers = (response["layers"].elements ?? []).map { layer in
                object([("source", originSummary(layer)), ("disabledReason", layer["disabledReason"]),
                    ("instructionKeys", .array(keys.filter { !layer["config"][$0].isNullish }.map(NativeRPCValue.string)))])
            }
            // The provider's own list of instruction files loaded for THIS thread (start/resume/fork reply).
            // Only a receipt for the current conversation counts; settings files never stand in for it.
            let applied = appliedFiles(appliedInstructions, conversation: conversation)
            let loaded = (applied ?? []).map { path in
                object([("key", .string("instructionSource")), ("value", .string(path)), ("origin", .null),
                    ("basis", .string("provider-loaded-instruction-file"))])
            }
            return page(provider, cwd: cwd, items: loaded + sources, next: .null, source: applied == nil ? "config/read" : "thread-instruction-sources+config/read")
                .setting("layers", .array(layers)).setting("complete", .bool(applied != nil))
                .setting("appliedInstructionFiles", applied.map { .array($0.map(NativeRPCValue.string)) } ?? .null)
                .setting("appliedReceipt", applied == nil ? .null : object([("source", appliedInstructions["source"]),
                    ("providerConversationId", appliedInstructions["providerConversationId"]), ("reportedAt", appliedInstructions["reportedAt"])]))
                .setting("scope", .string(applied == nil
                    ? "Effective instruction configuration and its provider-reported origins. This chat has no current provider receipt of loaded instruction files yet (it appears after the AI starts or resumes this conversation). Saved memory is not enumerated by this RPC."
                    : "Instruction files the AI reported loading for this conversation, plus the effective instruction configuration and its provider-reported origins. Saved memory and per-reply memory citations are separate and are not listed here."))
        }
    }

    /// Absolute, bounded paths from a current-conversation receipt, else nil (never inferred from files on disk).
    static func appliedFiles(_ receipt: NativeRPCValue, conversation: String?) -> [String]? {
        guard let conversation, !conversation.isEmpty, receipt["providerConversationId"].string == conversation,
              receipt["provider"].string == HootChatProvider.codex.rawValue, let paths = receipt["paths"].elements else { return nil }
        let values = paths.compactMap(\.string).filter { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }
        guard values.count == paths.count, values.count <= 64 else { return nil }
        return values
    }

    /// Only the resolved backend launch environment is accepted here. Never inherit the helper's
    /// own HOME or add another account's store when a private CLAUDE_CONFIG_DIR was selected.
    public static func claudeScope(environment: [String: String], cwd: String) throws -> NativeTranscriptScope {
        try project(cwd)
        if let override = environment["CLAUDE_CONFIG_DIR"] {
            let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.hasPrefix("/"), !path.contains("\0") else {
                throw NativeRPCError(code: "account-scope-unavailable", message: "This launch has no valid Claude account transcript directory.")
            }
            return NativeTranscriptScope(configDirectory: NativeTranscriptPaths.resolved(path), projectFolders: [cwd])
        }
        guard let home = environment["HOME"], home.hasPrefix("/"), !home.contains("\0") else {
            throw NativeRPCError(code: "account-scope-unavailable", message: "The resolved Claude launch did not provide its account home.")
        }
        var scope = NativeTranscriptScope.environment(environment); scope.projectFolders = [cwd]
        return scope
    }

    /// Claude's adapter takes an assembly-owned account scope, never a caller's home/config path.
    /// The encoded project-directory name alone is insufficient: it can collide with another cwd.
    public static func claude(operation: String, arguments: NativeRPCValue, cwd: String,
                              scope: NativeTranscriptScope) async throws -> NativeRPCValue {
        try project(cwd)
        guard ["catalogue/list", "catalogue/read"].contains(operation) else {
            return unavailable(.claude, cwd: cwd, reason: "Claude does not expose a verified effective skills or instruction-source manifest over this Chat protocol.")
        }
        var scoped = scope; scoped.projectFolders = [cwd]
        // Intersect the requested project with the authority's grant before narrowing it.
        _ = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope)
        let directories = try NativeTranscriptPaths.projectDirectories(cwd, scope: scoped)
        var files: [NativeTranscriptFile] = []
        for directory in directories { files.append(contentsOf: try NativeTranscriptPaths.listTranscripts(directory, scope: scoped)) }
        files.sort { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt { return lhs.path < rhs.path }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        let roots = try NativeTranscriptPaths.approvedRoots(scoped)
        if operation == "catalogue/read" {
            let id = try identifier(arguments["conversationId"])
            guard let path = arguments["path"].string,
                  let file = files.first(where: { $0.path == path && $0.sessionID == id }) else {
                throw NativeRPCError(code: "access-denied", message: "Choose a recorded Claude conversation in this account and project.")
            }
            let metadata = try claudeChunk(file, roots: roots)
            guard metadata.cwd == cwd, metadata.sessionID == id else {
                throw NativeRPCError(code: "access-denied", message: "Claude's transcript metadata does not match the selected conversation and project.")
            }
            let offset = try byteCursor(arguments)
            guard offset <= file.bytes else { throw NativeRPCError.invalidArguments("The transcript cursor is no longer valid.") }
            let chunk: ClaudeChunk
            if offset == 0 { chunk = metadata } else { chunk = try claudeChunk(file, roots: roots, offset: offset) }
            guard chunk.cwd == nil || chunk.cwd == cwd, chunk.sessionID == nil || chunk.sessionID == id else {
                throw NativeRPCError(code: "transcript-identity", message: "The transcript changed its conversation or project identity during preview.")
            }
            let messages = chunk.messages.map { message in
                object([("id", .string(message.groupKey)), ("providerMessageId", message.providerMessageID.map(NativeRPCValue.string) ?? .null), ("role", .string(message.role == .you ? "user" : "assistant")), ("text", .string(message.text))])
            }
            return page(.claude, cwd: cwd, items: messages,
                next: chunk.complete ? .null : .string(String(chunk.cursor)), source: "account-scoped-transcript")
                .setting("conversationId", .string(id)).setting("path", .string(file.path))
                .setting("startedMidFile", .bool(offset > 0))
        }
        let start = try byteCursor(arguments), count = try limit(arguments)
        guard start <= Int64(files.count) else { throw NativeRPCError.invalidArguments("The catalogue cursor is no longer valid.") }
        let query = try optionalText(arguments["query"], name: "search", maximum: 512) ?? ""
        var rows: [NativeRPCValue] = [], offset = Int(start), scanned = 0
        while offset < files.count, rows.count < count, scanned < 200 {
            try Task.checkCancellation()
            let file = files[offset]; offset += 1; scanned += 1
            let metadata = try claudeChunk(file, roots: roots)
            guard metadata.cwd == cwd, metadata.sessionID == file.sessionID else { continue }
            let preview = String((metadata.messages.first?.text ?? "").prefix(1024))
            guard query.isEmpty || (file.sessionID + " " + preview).localizedStandardContains(query) else { continue }
            rows.append(object([("provider", .string("claude")), ("conversationId", .string(file.sessionID)),
                ("sessionId", .string(file.sessionID)), ("cwd", .string(cwd)), ("path", .string(file.path)),
                ("preview", .string(preview)), ("updatedAt", .number(file.modifiedAt)), ("canResume", .bool(true))]))
        }
        return page(.claude, cwd: cwd, items: rows, next: offset < files.count ? .string(String(offset)) : .null, source: "account-scoped-transcript")
    }

    /// Recover exact checkpoint IDs for journals written before the stream decoder kept them. The ordinary
    /// account/project transcript reader supplies the same no-follow and identity checks as Past chats.
    static func claudeMessageIDs(environment: [String: String], cwd: String, conversation: String) async throws -> [String: String] {
        let scope = try claudeScope(environment: environment, cwd: cwd)
        let directories = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope)
        for directory in directories {
            guard let file = try NativeTranscriptPaths.transcript(named: conversation, in: directory, scope: scope) else { continue }
            var args = object([("conversationId", .string(conversation)), ("path", .string(file.path))])
            var result: [String: String] = [:]
            for _ in 0..<32 {
                let page = try await claude(operation: "catalogue/read", arguments: args, cwd: cwd, scope: scope)
                for row in page["items"].elements ?? [] {
                    if let id = row["id"].string, let uuid = row["providerMessageId"].string, UUID(uuidString: uuid) != nil { result[id] = uuid }
                }
                guard let cursor = page["nextCursor"].string else { return result }
                args = args.setting("cursor", .string(cursor))
            }
            return result
        }
        return [:]
    }

    private struct ClaudeChunk {
        let messages: [NativeChatTranscriptParsing.Line]
        let cwd: String?, sessionID: String?, cursor: Int64, complete: Bool
    }
    private static func claudeChunk(_ file: NativeTranscriptFile, roots: [String], offset: Int64 = 0) throws -> ClaudeChunk {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NativeChatTranscriptError.fileRead(errno) }
        defer { Darwin.close(descriptor) }
        var info = stat(), opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fcntl(descriptor, F_GETPATH, &opened) != -1 else { throw NativeChatTranscriptError.fileRead(errno) }
        let openedPath = String(cString: opened)
        guard roots.contains(where: { NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(openedPath), of: $0) }) else {
            throw NativeChatTranscriptError.outsideStore
        }
        let size = Int64(info.st_size)
        guard offset >= 0, offset <= size else { throw NativeRPCError.invalidArguments("The transcript cursor is no longer valid.") }
        // A cursor must point after a complete line, never into JSON or a UTF-8 scalar.
        if offset > 0 {
            var preceding: UInt8 = 0
            guard pread(descriptor, &preceding, 1, off_t(offset - 1)) == 1, preceding == 10 else {
                throw NativeRPCError.invalidArguments("The transcript cursor is not at a message boundary.")
            }
        }
        var data = Data(count: min(512 * 1024, Int(size - offset)))
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
        guard count >= 0 else { throw NativeChatTranscriptError.fileRead(errno) }
        data = Data(data.prefix(count))
        let used: Int
        if offset + Int64(count) >= size { used = count }
        else if let newline = data.lastIndex(of: 10) { used = newline + 1 }
        else { throw NativeRPCError(code: "preview-limit", message: "This transcript line exceeds the bounded preview size.") }
        let lines = data.prefix(used).split(separator: 10).compactMap { NativeChatTranscriptParsing.parse(String(decoding: $0, as: UTF8.self)) }
        guard Set(lines.compactMap(\.cwd)).count <= 1, Set(lines.compactMap(\.sessionID)).count <= 1 else {
            throw NativeRPCError(code: "transcript-identity", message: "The transcript mixes different projects or conversation identities.")
        }
        return ClaudeChunk(messages: lines, cwd: lines.compactMap(\.cwd).first, sessionID: lines.compactMap(\.sessionID).first,
            cursor: offset + Int64(used), complete: offset + Int64(used) >= size)
    }
    private static func originSummary(_ origin: NativeRPCValue) -> NativeRPCValue {
        object([("type", origin["name"]["type"]), ("file", origin["name"]["file"]),
            ("projectDirectory", origin["name"]["dotCodexFolder"]), ("profile", origin["name"]["profile"]),
            ("version", origin["version"])])
    }
    private static func summary(_ thread: NativeRPCValue, cwd: String, id: String) -> NativeRPCValue {
        object([("provider", .string("codex")), ("conversationId", .string(id)), ("sessionId", .string(id)),
            ("cwd", .string(cwd)), ("title", thread["name"]), ("preview", thread["preview"]),
            ("modelProvider", thread["modelProvider"]), ("createdAt", .number((thread["createdAt"].number ?? 0) * 1000)),
            ("updatedAt", .number((thread["updatedAt"].number ?? 0) * 1000)), ("canResume", .bool(true))])
    }
    private static func project(_ cwd: String) throws {
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096, !cwd.contains("\0") else {
            throw NativeRPCError.invalidArguments("Choose an absolute project folder.")
        }
    }
    private static func identifier(_ value: NativeRPCValue) throws -> String {
        let id = try value.requireString("provider conversation id", nonempty: true)
        guard id.utf8.count <= 512, !id.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw NativeRPCError.invalidArguments("Choose an exact provider conversation id.")
        }; return id
    }
    private static func optionalText(_ value: NativeRPCValue, name: String, maximum: Int) throws -> String? {
        if value.isNullish { return nil }
        let text = try value.requireString(name)
        guard text.utf8.count <= maximum, !text.contains("\0") else { throw NativeRPCError.invalidArguments("The \(name) exceeds its limit.") }
        return text
    }
    private static func cursor(_ arguments: NativeRPCValue) throws -> String? {
        try optionalText(arguments["cursor"], name: "cursor", maximum: 8192)
    }
    private static func byteCursor(_ arguments: NativeRPCValue) throws -> Int64 {
        guard let text = try cursor(arguments) else { return 0 }
        guard let offset = Int64(text), offset >= 0 else { throw NativeRPCError.invalidArguments("Choose a valid catalogue cursor.") }
        return offset
    }
    private static func limit(_ arguments: NativeRPCValue) throws -> Int {
        if arguments["limit"].isNullish { return 30 }
        guard let value = arguments["limit"].number, value.isFinite, value.rounded() == value, value >= 1, value <= 100 else {
            throw NativeRPCError.invalidArguments("Choose a page size between 1 and 100.")
        }; return Int(value)
    }
    private static func page(_ provider: HootChatProvider, cwd: String, items: [NativeRPCValue], next: NativeRPCValue, source: String) -> NativeRPCValue {
        object([("available", .bool(true)), ("provider", .string(provider.rawValue)), ("cwd", .string(cwd)),
            ("items", .array(items)), ("nextCursor", next), ("readOnly", .bool(true)), ("source", .string(source))])
    }
    private static func unavailable(_ provider: HootChatProvider, cwd: String, reason: String) -> NativeRPCValue {
        page(provider, cwd: cwd, items: [], next: .null, source: "unavailable")
            .setting("available", .bool(false)).setting("reason", .string(reason))
    }
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }
}
