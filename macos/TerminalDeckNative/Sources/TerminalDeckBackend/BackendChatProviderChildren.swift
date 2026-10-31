import Foundation
import TerminalDeckNativeCore

/// Provider child inspection is fenced by this Chat's emitted task IDs. A caller never supplies
/// a provider thread ID or transcript path. Resume preparation performs reads only; a new Chat
/// owner must subsequently acquire its own account/permission leases and confirm exact resume.
public enum BackendChatProviderChildren {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["children/list", "children/read", "children/resume"]

    public static func invoke(operation: String, args: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, ownedTasks: [NativeRPCValue], request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation), args.fields != nil, try args.encodedJSON().count <= 32_768 else { throw invalid("Choose a supported child action with bounded arguments.") }
        let allowed: Set<String> = operation == "children/list" ? ["cursor", "limit"] : operation == "children/resume" ? ["taskId"] : ["taskId", "cursor", "limit"]
        guard Set(args.fields?.map(\.key) ?? []).isSubset(of: allowed) else { throw invalid("Use a recorded taskId; provider thread IDs, paths and launch settings are not accepted.") }
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4096 else { throw invalid("The owning Chat has no valid project folder.") }
        let tasks = try owned(ownedTasks)
        if operation == "children/list" {
            let offset: Int
            if let cursor = try cursor(args) {
                guard let value = Int(cursor), value >= 0, value <= tasks.count else { throw invalid("Choose a current child-list cursor.") }; offset = value
            } else { offset = 0 }
            let limit = try limit(args, maximum: 200, defaultValue: 50)
            var page: [NativeRPCValue] = [], bytes = 0
            for task in tasks.dropFirst(offset).prefix(limit) {
                let entry = summary(task, provider: provider, ready: conversation?.isEmpty == false)
                let size = try entry.encodedJSON().count
                guard bytes + size <= 262_144 else { break }
                page.append(entry); bytes += size
            }
            let next = offset + page.count
            return object([("provider", .string(provider.rawValue)), ("parentConversationId", conversation.map(NativeRPCValue.string) ?? .null),
                ("cwd", .string(cwd)), ("items", .array(page)), ("total", .number(Double(tasks.count))),
                ("nextCursor", next < tasks.count ? .string(String(next)) : .null), ("source", .string("chat-emitted-child-records"))])
        }
        let pageLimit = operation == "children/read" ? try limit(args, maximum: 50, defaultValue: 20) : 20
        let pageCursor = operation == "children/read" ? try cursor(args) : nil
        let taskID = try identifier(args["taskId"], label: "recorded child task ID")
        guard let task = tasks.first(where: { $0["id"].string == taskID }) else { throw denied("That task was not emitted by this Chat.") }
        guard provider == .codex else {
            throw NativeRPCError(code: "unavailable", message: "This provider has no verified structured child transcript/resume operation in this helper. Recorded summaries remain available; transcript paths are not trusted.")
        }
        guard let root = conversation, !root.isEmpty else { throw invalid("Start the owning provider conversation before inspecting its children.") }
        let child = try childThread(task)
        guard child != root else { throw denied("The selected task points to the parent conversation.") }
        let metadata = try await request("thread/read", object([("threadId", .string(child)), ("includeTurns", .bool(false))]))
        let thread = metadata["thread"]
        guard thread["id"].string == child else { throw denied("The provider returned a different child conversation.") }
        guard thread["cwd"].string == cwd else { throw denied("This child uses another folder. No wider project grant or local fallback was applied.") }
        let rootMetadata = try await request("thread/read", object([("threadId", .string(root)), ("includeTurns", .bool(false))]))
        guard rootMetadata["thread"]["id"].string == root, rootMetadata["thread"]["cwd"].string == cwd else { throw denied("The owning provider conversation changed during child verification.") }
        if let tree = thread["sessionId"].string, let rootTree = rootMetadata["thread"]["sessionId"].string, tree != rootTree {
            throw denied("The provider child belongs to a different session tree.")
        }
        let parent = try reportedParent(thread)
        let ownedThreads = Set(tasks.compactMap { try? childThread($0) })
        if let parent {
            guard parent != child, parent == root || ownedThreads.contains(parent) else { throw denied("The provider reports a parent outside this Chat's owned children.") }
            if let expected = emittedParent(task, tasks: tasks), parent != expected { throw denied("The child's provider parent differs from its emitted parent record.") }
        }
        let status = thread["status"]["type"].string ?? thread["status"].string
        let resumable = ["idle", "notLoaded"].contains(status ?? "") && thread["ephemeral"].bool == false
        var result = object([("provider", .string(provider.rawValue)), ("taskId", .string(taskID)),
            ("conversationId", .string(child)), ("parentConversationId", .string(root)), ("cwd", .string(cwd)),
            ("task", summary(task, provider: provider, ready: true)), ("thread", threadSummary(thread)),
            ("parentThreadId", parent.map(NativeRPCValue.string) ?? .null),
            ("parentVerification", .string(parent == nil ? "not-reported; emitted-task-ownership-checked" : "provider-parent-and-emitted-ownership-checked")),
            ("canResume", .bool(resumable)), ("source", .string("provider-thread-read"))])
        if operation == "children/resume" {
            guard resumable else { throw NativeRPCError(code: "unavailable", message: "This child is active, temporary, in an error state, or its durable idle state was not reported. It was not resumed or interrupted.") }
            return result.setting("prepared", .bool(true)).setting("resumed", .bool(false))
                .setting("resume", object([("provider", .string("codex")), ("conversationId", .string(child)),
                    ("cwd", .string(cwd)), ("taskId", .string(taskID)), ("parentConversationId", .string(root)),
                    ("requiresOwnedLaunch", .bool(true)), ("requiresConfirmedResume", .bool(true)),
                    ("permissionSource", .string("new-chat-owner")), ("accountSource", .string("validated-parent-account"))]))
        }
        var params = object([("threadId", .string(child)), ("itemsView", .string("full")),
            ("sortDirection", .string("asc")), ("limit", .number(Double(pageLimit)))])
        if let pageCursor { params = params.setting("cursor", .string(pageCursor)) }
        let response = try await request("thread/turns/list", params)
        guard let turns = response["data"].elements, turns.count <= 50 else { throw NativeRPCError.malformed("The provider child transcript page is not bounded.") }
        let preview = try messages(turns)
        result = result.setting("messages", .array(preview.values)).setting("items", .array(preview.values))
            .setting("textClipped", .bool(preview.clipped)).setting("transcriptIncomplete", .bool(preview.incomplete))
            .setting("nextCursor", try nextCursor(response["nextCursor"]))
            .setting("previewScope", .string("This child only: user and assistant text. Tool payloads and non-text attachments are omitted; clipped text is explicitly marked."))
        return result
    }

    private static func owned(_ values: [NativeRPCValue]) throws -> [NativeRPCValue] {
        guard values.count <= 1024 else { throw NativeRPCError(code: "unavailable", message: "This Chat's child index exceeds the bounded inspection limit.") }
        var result: [NativeRPCValue] = [], seen: [String: NativeRPCValue] = [:]
        for task in values {
            guard let id = task["id"].string, !id.isEmpty else { continue }
            if let prior = seen[id] {
                guard prior["threadId"] == task["threadId"] else { throw denied("This Chat has conflicting child identity records.") }
                continue
            }
            seen[id] = task; result.append(task)
        }
        return result
    }
    private static func childThread(_ task: NativeRPCValue) throws -> String {
        let thread = try identifier(task["threadId"], label: "owned child thread")
        guard task["kind"].string == "agent", task["id"].string == "codex:" + thread else { throw denied("This task has no verified provider conversation identity.") }
        return thread
    }
    private static func emittedParent(_ task: NativeRPCValue, tasks: [NativeRPCValue]) -> String? {
        if let parent = task["parentThreadId"].string { return parent }
        if let parent = task["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].string { return parent }
        if let id = task["parentTaskId"].string ?? task["parentId"].string { return tasks.first { $0["id"].string == id }?["threadId"].string }
        return nil
    }
    private static func reportedParent(_ thread: NativeRPCValue) throws -> String? {
        let values = [thread["parentThreadId"], thread["source"]["subAgent"]["thread_spawn"]["parent_thread_id"]]
        var parents = Set<String>()
        for value in values where !value.isNullish { parents.insert(try identifier(value, label: "provider parent thread")) }
        guard parents.count <= 1 else { throw denied("The provider returned conflicting child parent metadata.") }
        return parents.first
    }
    private static func summary(_ task: NativeRPCValue, provider: HootChatProvider, ready: Bool) -> NativeRPCValue {
        let keys = ["id", "threadId", "kind", "title", "summary", "status", "turnId", "parentId", "parentTaskId", "parentThreadId",
                    "appTaskId", "agentPath", "agentRole", "agentNickname", "senderThreadId", "toolUseId", "canStop", "limitation"]
        var value = NativeRPCValue.object((task.fields ?? []).filter { keys.contains($0.key) }.map { .init($0.key, metadataValue($0.value)) })
        if !task["source"].isNullish { value = value.setting("source", sourceSummary(task["source"])) }
        let child = provider == .codex && (try? childThread(task)) != nil && ready
        value = value.setting("canRead", .bool(child)).setting("canResume", .bool(child && !ChatChildTasks.running(task)))
            .setting("resumeRequiresVerification", .bool(true)).setting("parentMetadataSource", .string("reported-only"))
            .setting("metadataClipped", .bool((task.fields ?? []).contains { keys.contains($0.key) && ($0.value.string?.count ?? 0) > 1024 }))
        if !child { value = value.setting("transcriptLimitation", .string("No confirmed structured child transcript/resume capability for this emitted task.")) }
        return value
    }
    private static func threadSummary(_ thread: NativeRPCValue) -> NativeRPCValue {
        let keys = ["id", "name", "cwd", "parentThreadId", "sessionId", "agentNickname", "agentRole", "ephemeral", "createdAt", "updatedAt", "modelProvider"]
        var value = NativeRPCValue.object((thread.fields ?? []).filter { keys.contains($0.key) }.map { .init($0.key, metadataValue($0.value)) })
        let status = thread["status"].fields == nil ? metadataValue(thread["status"]) : object([("type", metadataValue(thread["status"]["type"]))])
        value = value.setting("source", sourceSummary(thread["source"]))
            .setting("status", status).setting("configuredModel", metadataValue(thread["model"]))
        return value
    }
    private static func sourceSummary(_ source: NativeRPCValue) -> NativeRPCValue {
        if source.string != nil { return metadataValue(source) }
        let spawn = source["subAgent"]["thread_spawn"]
        if spawn.fields != nil {
            let keys = ["parent_thread_id", "depth", "agent_nickname", "agent_role", "agent_path"]
            return object([("subAgent", object([("thread_spawn", .object((spawn.fields ?? []).filter { keys.contains($0.key) }.map { .init($0.key, metadataValue($0.value)) }))]))])
        }
        if source["subAgent"].string != nil { return object([("subAgent", metadataValue(source["subAgent"]))]) }
        return .null
    }
    private static func metadataValue(_ value: NativeRPCValue) -> NativeRPCValue {
        if let text = value.string { return .string(String(text.prefix(1024))) }
        return value.bool != nil || value.number?.isFinite == true ? value : .null
    }
    private static func messages(_ turns: [NativeRPCValue]) throws -> (values: [NativeRPCValue], clipped: Bool, incomplete: Bool) {
        var values: [NativeRPCValue] = [], clipped = false, incomplete = false, budget = 262_144
        for turn in turns {
            let id = try identifier(turn["id"], label: "provider child turn")
            if let view = turn["itemsView"].string, view != "full" { incomplete = true }
            for item in turn["items"].elements ?? [] {
                let role: String, text: String
                switch item["type"].string {
                case "userMessage": role = "user"; text = (item["content"].elements ?? []).filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
                case "agentMessage": role = "assistant"; text = item["text"].string ?? ""
                default: continue
                }
                guard values.count < 128, budget > 0 else { clipped = true; continue }
                var data = Data(text.utf8.prefix(min(32_768, budget)))
                while String(data: data, encoding: .utf8) == nil, !data.isEmpty { data.removeLast() }
                let part = String(data: data, encoding: .utf8) ?? ""
                let truncated = data.count < text.utf8.count; clipped = clipped || truncated; budget -= data.count
                let itemID = item["id"].isNullish ? NativeRPCValue.null : .string(try identifier(item["id"], label: "provider child item"))
                values.append(object([("id", itemID), ("turnId", .string(id)),
                    ("role", .string(role)), ("text", .string(part)), ("truncated", .bool(truncated))]))
            }
        }
        return (values, clipped, incomplete)
    }
    private static func limit(_ args: NativeRPCValue, maximum: Int, defaultValue: Int) throws -> Int {
        if args["limit"].isNullish { return defaultValue }
        guard let count = args["limit"].number, count.isFinite, count.rounded() == count, count >= 1, count <= Double(maximum) else { throw invalid("Choose a bounded whole child page size.") }
        return Int(count)
    }
    private static func cursor(_ args: NativeRPCValue) throws -> String? {
        if args["cursor"].isNullish { return nil }
        return try identifier(args["cursor"], label: "child page cursor", maximum: 8192)
    }
    private static func nextCursor(_ value: NativeRPCValue) throws -> NativeRPCValue { value.isNullish ? .null : .string(try identifier(value, label: "provider child page cursor", maximum: 8192)) }
    private static func identifier(_ value: NativeRPCValue, label: String, maximum: Int = 512) throws -> String {
        let id = try value.requireString(label, nonempty: true)
        guard id.utf8.count <= maximum, !id.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw invalid("Choose a valid \(label).") }; return id
    }
    private static func object(_ values: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(values.map { .init($0.0, $0.1) }) }
    private static func invalid(_ text: String) -> NativeRPCError { .invalidArguments(text) }
    private static func denied(_ text: String) -> NativeRPCError { .init(code: "access-denied", message: text) }
}
