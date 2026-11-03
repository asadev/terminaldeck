import Foundation
import TerminalDeckNativeCore

/// F35: a Chat's background shells, monitors and subagent tasks, fenced by the task IDs this Chat itself
/// emitted (a caller never names a provider task it was not shown). Claude Code answers the control
/// requests below; Codex 0.159 exposes no background-shell output or stop request, so for Codex only the
/// recorded task list is offered and every other action says so. Tasks stay linked to Tasks by `appTaskId`
/// when the provider reported one; nothing here duplicates a Tasks record.
public enum BackendChatBackground {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["background/list", "background/output", "background/stop", "background/detach"]
    /// Reads do not change anything; stop and detach do.
    public static func changes(_ operation: String) -> Bool { ["background/stop", "background/detach"].contains(operation) }
    static let maximumOutput = 16_384

    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private static func invalid(_ text: String) -> NativeRPCError { .invalidArguments(text) }

    public static func invoke(operation: String, args: NativeRPCValue, provider: HootChatProvider,
                              ownedTasks: [NativeRPCValue], request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation), args.fields != nil, try args.encodedJSON().count <= 8_192 else {
            throw invalid("Choose a supported background-task action with bounded arguments.")
        }
        let allowed: Set<String> = operation == "background/list" ? [] : operation == "background/detach" ? ["toolUseId", "all"] : ["taskId"]
        guard Set(args.fields?.map(\.key) ?? []).isSubset(of: allowed) else {
            throw invalid("Use a task ID shown by background/list; provider paths and launch settings are not accepted.")
        }
        let tasks = ownedTasks.filter { $0["id"].string?.isEmpty == false }
        if operation == "background/list" {
            return object([("provider", .string(provider.rawValue)), ("items", .array(tasks.prefix(200).map(row))),
                ("total", .number(Double(tasks.count))), ("source", .string("chat-emitted-task-records")),
                ("outputAvailable", .bool(provider == .claude)), ("lifecycleAvailable", .bool(provider == .claude)),
                ("note", provider == .claude ? .null : .string(unsupported(provider)))])
        }
        guard provider == .claude else { throw NativeRPCError(code: "unavailable", message: unsupported(provider)) }
        if operation == "background/detach" {
            // No ID means "every foreground task" (Ctrl+B). That must be asked for by name, never by omission.
            if args.has("toolUseId") {
                let tool = try identifier(args["toolUseId"], "tool call ID")
                guard tasks.contains(where: { $0["toolUseId"].string == tool && $0["status"].string == "running" }) else {
                    throw NativeRPCError(code: "access-denied", message: "That tool call has no running task recorded in this Chat.")
                }
                return reply(operation, try await request("background_tasks", object([("tool_use_id", .string(tool))])), task: nil)
            }
            guard args["all"].bool == true else { throw invalid("Name one toolUseId, or pass all: true to move every foreground task to the background.") }
            return reply(operation, try await request("background_tasks", .object([])), task: nil)
        }
        let id = try identifier(args["taskId"], "task ID")
        guard let task = tasks.first(where: { $0["id"].string == id }) else {
            throw NativeRPCError(code: "access-denied", message: "That task was not emitted by this Chat.")
        }
        if operation == "background/stop" {
            guard task["status"].string == "running" else { throw NativeRPCError(code: "not-running", message: "That task is not running.") }
            return reply(operation, try await request("stop_task", object([("task_id", .string(id))])), task: task)
        }
        let response = try await request("get_task_output", object([("task_id", .string(id))]))
        let text = ["output", "tail", "text", "content"].lazy.compactMap { response[$0].string }.first
        var clipped = false
        let bounded = text.map { value -> String in
            guard value.utf8.count > maximumOutput else { return value }
            clipped = true
            return String(decoding: Array(value.utf8.suffix(maximumOutput)), as: UTF8.self)
        }
        return object([("taskId", .string(id)), ("task", row(task)), ("output", bounded.map(NativeRPCValue.string) ?? .null),
            ("tailOnly", .bool(true)), ("clipped", .bool(clipped)),
            ("provider", bounded == nil ? bound(response) : .null),
            ("scope", .string("The end of what this task wrote (at most 8 KiB from the provider), read without a model turn."))])
    }

    private static func row(_ task: NativeRPCValue) -> NativeRPCValue {
        let status = task["status"].string ?? "unknown"
        return object([("id", task["id"]), ("title", task["title"]), ("kind", task["kind"]), ("status", .string(status)),
            ("running", .bool(status == "running")), ("toolUseId", task["toolUseId"]), ("appTaskId", task["appTaskId"]),
            ("source", task["source"])])
    }
    private static func reply(_ operation: String, _ response: NativeRPCValue, task: NativeRPCValue?) -> NativeRPCValue {
        object([("operation", .string(operation)), ("requested", .bool(true)), ("task", task.map(row) ?? .null),
            ("provider", bound(response)),
            ("note", .string("The provider acknowledged the request. The task's own finish notice, shown in this list, confirms the result."))])
    }
    /// Provider replies are small objects; bound them anyway before they reach a window or an MCP caller.
    private static func bound(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let bytes = try? value.encodedJSON(), bytes.count <= 65_536 else { return .string("The provider reply was larger than 64 KiB and was not forwarded.") }
        return value
    }
    private static func identifier(_ value: NativeRPCValue, _ label: String) throws -> String {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= 256,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid("Choose a valid \(label).") }
        return text
    }
    private static func unsupported(_ provider: HootChatProvider) -> String {
        provider == .codex
            ? "Codex's app-server (0.159) has no request to read or stop a background shell. Its recorded tasks are listed; use Chat-owned terminals for commands the app runs itself."
            : "This provider exposes no background-task protocol in this installation."
    }
}
