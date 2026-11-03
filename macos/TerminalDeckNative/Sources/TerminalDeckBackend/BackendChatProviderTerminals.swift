import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The installed app-server schema exposes thread/backgroundTerminals/{list,terminate,clean}
/// and commandExecution items through thread/items/list. Its command/exec/* and process/* IDs
/// are connection-scoped, and cannot control these terminals. thread/shellCommand explicitly
/// runs unsandboxed/full-access, so it is excluded from this approved-thread terminal door.
public enum BackendChatProviderTerminals {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["terminals/capabilities", "terminals/list", "terminals/read", "terminals/stop", "terminals/clean",
                                    "terminals/create", "terminals/write", "terminals/resize", "terminals/foreground"]
    private static let supported = ["terminals/list", "terminals/read", "terminals/stop", "terminals/clean"]
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func capabilities(provider: HootChatProvider) -> NativeRPCValue {
        object([("provider", .string(provider.rawValue)), ("scope", .string("provider-thread-terminals")),
            ("availability", .string(provider == .codex ? "partial" : "unavailable")),
            ("supportedOperations", .array((provider == .codex ? supported : []).map(NativeRPCValue.string))),
            ("unavailableOperations", .array((provider == .codex ? ["terminals/create", "terminals/write", "terminals/resize", "terminals/foreground"] : operations.filter { $0 != "terminals/capabilities" }).map(NativeRPCValue.string))),
            ("reason", .string(provider == .codex
                ? "Existing Codex thread terminals support inventory, recorded output and targeted termination/cleanup. No approved thread-owned create, input, resize or foreground RPC is exposed. Standalone connection processes and unsandboxed shellCommand are excluded."
                : "This provider's inspected structured Chat protocol has no dedicated thread-owned terminal transport. Background task controls remain separate."))])
    }
    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation), arguments.fields != nil, try arguments.encodedJSON().count <= 131_072 else {
            throw invalid("Choose a supported terminal action with bounded arguments.")
        }
        if operation == "terminals/capabilities" { return capabilities(provider: provider) }
        guard provider == .codex, supported.contains(operation) else {
            return capabilities(provider: provider).setting("availability", .string("unavailable"))
                .setting("operation", .string(operation)).setting("performed", .bool(false))
        }
        guard let conversation, !conversation.isEmpty, conversation.utf8.count <= 512 else { throw invalid("The owning provider thread is not ready.") }
        let allowed: Set<String> = operation == "terminals/list" ? ["cursor", "limit"] : operation == "terminals/clean" ? [] : ["processId", "itemId"]
        guard Set(arguments.fields?.map(\.key) ?? []).isSubset(of: allowed) else {
            throw invalid("Use only this Chat's terminal processId/itemId pair. Provider thread IDs, OS PIDs, paths, approval overrides and commands are not accepted.")
        }
        let thread = object([("threadId", .string(conversation))])
        if operation == "terminals/list" {
            var params = thread.setting("limit", .number(Double(try pageLimit(arguments))))
            if let cursor = try pageCursor(arguments["cursor"]) { params = params.setting("cursor", .string(cursor)) }
            let reply = try await request("thread/backgroundTerminals/list", params)
            let rows = try terminalPage(reply)
            return object([("provider", .string("codex")), ("conversationId", .string(conversation)),
                ("scope", .string("provider-thread-terminals")), ("availability", .string("available")),
                ("terminals", .array(try rows.map(summary))), ("nextCursor", try nextCursor(reply["nextCursor"])),
                ("source", .string("thread/backgroundTerminals/list"))])
        }
        if operation == "terminals/clean" {
            _ = try await request("thread/backgroundTerminals/clean", thread)
            return object([("provider", .string("codex")), ("conversationId", .string(conversation)),
                ("action", .string("clean")), ("requested", .bool(true)), ("requiresRefresh", .bool(true)),
                ("scope", .string("all-background-terminals-in-owning-thread"))])
        }
        let process = try identifier(arguments["processId"], "processId"), item = try identifier(arguments["itemId"], "itemId")
        if operation == "terminals/stop" {
            // The list is provider-owned and freshly read. Neither a caller-supplied PID nor
            // an item from another thread can target a provider process through this door.
            let rows = try await allTerminals(thread: conversation, request: request)
            let matches = rows.filter { $0["processId"].string == process }
            guard matches.count == 1, matches[0]["itemId"].string == item else {
                throw denied("This process/item pair is not a unique current terminal of this Chat. Refresh the inventory before trying again.")
            }
            _ = try await request("thread/backgroundTerminals/terminate", thread.setting("processId", .string(process)))
            return object([("provider", .string("codex")), ("conversationId", .string(conversation)),
                ("processId", .string(process)), ("itemId", .string(item)), ("terminationRequested", .bool(true)),
                ("stoppedConfirmed", .bool(false)), ("requiresRefresh", .bool(true))])
        }
        return try await read(thread: conversation, process: process, item: item, request: request)
    }
    private static func allTerminals(thread: String, request: Request) async throws -> [NativeRPCValue] {
        var cursor: String?, seen = Set<String>(), values: [NativeRPCValue] = []
        repeat {
            var params = object([("threadId", .string(thread)), ("limit", .number(100))])
            if let cursor { params = params.setting("cursor", .string(cursor)) }
            let reply = try await request("thread/backgroundTerminals/list", params)
            values += try terminalPage(reply)
            cursor = try pageCursor(reply["nextCursor"])
            if let cursor {
                guard seen.count < 20, seen.insert(cursor).inserted else { throw invalid("The provider terminal inventory could not be completely verified.") }
            }
        } while cursor != nil
        return values
    }
    private static func read(thread: String, process: String, item: String, request: Request) async throws -> NativeRPCValue {
        var cursor: String?, seen = Set<String>()
        repeat {
            var params = object([("threadId", .string(thread)), ("limit", .number(100)), ("sortDirection", .string("desc"))])
            if let cursor { params = params.setting("cursor", .string(cursor)) }
            let reply = try await request("thread/items/list", params)
            guard let rows = reply["data"].elements, rows.count <= 100, try reply.encodedJSON().count <= 4_194_304 else {
                throw invalid("The provider terminal output page exceeds the bounded read limit.")
            }
            let matches = rows.filter { $0["item"]["id"].string == item }
            guard matches.count <= 1 else { throw denied("The provider returned ambiguous terminal item identity.") }
            if let entry = matches.first {
                let value = entry["item"]
                guard value["type"].string == "commandExecution", value["processId"].string == process else {
                    throw denied("This recorded item does not belong to the selected thread terminal process.")
                }
                let output = value["aggregatedOutput"].string
                let bytes = Data((output ?? "").utf8), visible = tail(bytes, maximum: 131_072)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                return object([("provider", .string("codex")), ("conversationId", .string(thread)),
                    ("processId", .string(process)), ("itemId", .string(item)), ("turnId", text(entry["turnId"])),
                    ("command", text(value["command"])), ("cwd", text(value["cwd"])), ("status", text(value["status"])),
                    ("output", output == nil ? .null : .string(visible)), ("outputAvailable", .bool(output != nil)),
                    ("outputBytes", .number(Double(bytes.count))), ("displayedBytes", .number(Double(visible.utf8.count))),
                    ("truncated", .bool(bytes.count > visible.utf8.count)), ("outputSHA256", output == nil ? .null : .string(digest)),
                    ("exitCode", value["exitCode"].number.map(NativeRPCValue.number) ?? .null),
                    ("durationMs", value["durationMs"].number.map(NativeRPCValue.number) ?? .null),
                    ("source", .string("thread/items/list")), ("outputScope", .string("provider-recorded-command-output")),
                    ("limitation", .string("This is the provider's recorded output snapshot. Live output is available only when the provider records or emits it; this read does not attach an interactive terminal."))])
            }
            cursor = try pageCursor(reply["nextCursor"])
            if let cursor {
                guard seen.count < 20, seen.insert(cursor).inserted else { throw invalid("The bounded provider output search did not finish.") }
            }
        } while cursor != nil
        throw denied("That process/item pair was not recorded in this Chat's provider thread.")
    }
    private static func terminalPage(_ reply: NativeRPCValue) throws -> [NativeRPCValue] {
        guard let rows = reply["data"].elements, rows.count <= 100, try reply.encodedJSON().count <= 1_048_576 else { throw invalid("The provider returned an invalid terminal inventory page.") }
        for row in rows { _ = try identifier(row["processId"], "provider processId"); _ = try identifier(row["itemId"], "provider itemId") }
        return rows
    }
    private static func summary(_ value: NativeRPCValue) throws -> NativeRPCValue {
        object([("id", .string(try identifier(value["processId"], "processId"))),
            ("processId", .string(try identifier(value["processId"], "processId"))),
            ("itemId", .string(try identifier(value["itemId"], "itemId"))),
            ("command", text(value["command"])), ("cwd", text(value["cwd"])),
            ("cpuPercent", value["cpuPercent"].number.map(NativeRPCValue.number) ?? .null),
            ("rssKb", value["rssKb"].number.map(NativeRPCValue.number) ?? .null),
            ("canRead", .bool(true)), ("canStop", .bool(true)), ("canWrite", .bool(false)), ("canResize", .bool(false)), ("canForeground", .bool(false))])
    }
    private static func pageLimit(_ arguments: NativeRPCValue) throws -> Int {
        if arguments["limit"].isNullish { return 50 }
        guard let limit = arguments["limit"].number, limit.rounded() == limit, (1...100).contains(limit) else { throw invalid("Choose a terminal page size from 1 to 100.") }
        return Int(limit)
    }
    private static func pageCursor(_ value: NativeRPCValue) throws -> String? { value.isNullish ? nil : try identifier(value, "cursor", maximum: 8192) }
    private static func nextCursor(_ value: NativeRPCValue) throws -> NativeRPCValue { try pageCursor(value).map(NativeRPCValue.string) ?? .null }
    private static func identifier(_ value: NativeRPCValue, _ label: String, maximum: Int = 512) throws -> String {
        guard let result = value.string, !result.isEmpty, result.utf8.count <= maximum,
              !result.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { throw invalid("Choose a valid provider terminal \(label).") }
        return result
    }
    private static func text(_ value: NativeRPCValue) -> NativeRPCValue { value.string.map { .string(String($0.prefix(4096))) } ?? .null }
    private static func tail(_ data: Data, maximum: Int) -> String {
        var value = Data(data.suffix(maximum))
        while !value.isEmpty, String(data: value, encoding: .utf8) == nil { value.removeFirst() }
        return String(data: value, encoding: .utf8) ?? ""
    }
    private static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }
    private static func denied(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }
}
