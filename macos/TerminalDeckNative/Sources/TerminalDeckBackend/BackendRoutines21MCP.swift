import Foundation
import TerminalDeckNativeCore

public enum BackendRoutines21MCP {
    public static func definitions(api: BackendRoutinesAPI, access: BackendDeckToolsAppAccess,
                                   chatView: (@Sendable (String, String) async throws -> NativeRPCValue)? = nil) throws -> [BackendDeckToolsDefinition] {
        let entries: [(String, String, BackendMCPTier, String)] = [
            ("reports", "Read a routine's reports and separate follow-up answers, oldest first.", .read, ""),
            ("chat-view", "Read or scroll an open Mac routine chat. do: read, latest, earlier or later. Sending resumes following automatically.", .read, ""),
            ("reports-chat", "Read a routine report chat, oldest first. The open view follows its newest content. seenSequence remains an ignored compatibility field.", .read, ""),
            ("destinations", "Read where a routine sends results. Secrets stay hidden.", .read, ""),
            ("set-destinations", "Choose none, one or several report destinations. Omitted secrets keep saved values.", .alter, #",\"destinations\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\"}}"#),
            ("test-destination", "Send one test report to a saved destination and show whether it arrived.", .act, #",\"destinationId\":{\"type\":\"string\"}"#),
            ("follow-up", "Ask the routine's agent about a report in a fresh job. History is kept.", .act, #",\"text\":{\"type\":\"string\",\"maxLength\":20000},\"reportId\":{\"type\":\"string\"}"#),
            ("connections", "List existing WhatsApp and Telegram connections without tokens.", .read, ""),
            ("add-connection", "Add a Telegram bot connection. Its token goes into the app's secret store and is never returned.", .alter, #",\"connection\":{\"type\":\"object\"}"#)
        ]
        return try entries.map { operation, description, tier, extra in
            let id = "routines." + operation.replacingOccurrences(of: "-", with: "_"), wire = id.replacingOccurrences(of: ".", with: "_")
            let global = ["connections", "add-connection"].contains(operation)
            var required = global ? [] : ["routineId"]
            if operation == "set-destinations" { required.append("destinations") }
            if operation == "test-destination" { required.append("destinationId") }
            if operation == "follow-up" { required.append("text") }
            if operation == "add-connection" { required.append("connection") }
            // Construct the schema as values so no escaping can turn a field into literal backslashes.
            var properties: [NativeRPCValue.Field] = [.init("routineId", .object([.init("type", .string("string"))]))]
            if operation == "chat-view" {
                required.append("do")
                properties.append(.init("do", .object([.init("type", .string("string")), .init("enum", .array(["read", "latest", "earlier", "later"].map(NativeRPCValue.string)))])))
            }
            if operation == "reports-chat" {
                properties.append(.init("seenSequence", .object([.init("type", .string("integer")), .init("minimum", .number(0))])))
            }
            if !extra.isEmpty {
                let decoded = try NativeRPCValue.parseJSON(Data(("{" + String(extra.dropFirst()).replacingOccurrences(of: "\\\"", with: "\"") + "}").utf8))
                properties += decoded.fields ?? []
            }
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties)),
                .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description, inputSchema: schema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: description) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(tier), context.allowedTools.contains(id) || context.allowedTools.contains(wire) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use that routine control.")
                    }
                    let caller = try await access.caller(context)
                    let viewAction = operation == "chat-view" ? try args["do"].requireString("action") : "read"
                    if operation == "chat-view" {
                        guard caller.kind == .local, ["read", "latest", "earlier", "later"].contains(viewAction) else {
                            throw NativeRPCError(code: "not-granted", message: "These chat controls belong to the Mac owner.")
                        }
                    }
                    let actualTier: BackendMCPTier = operation == "chat-view" && viewAction != "read" ? .act : tier
                    guard context.allowedTiers.contains(actualTier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot scroll this chat.") }
                    let routineID = args["routineId"].string ?? ""
                    let routine = api.store.list().first { $0.id == routineID }?.routine
                    if !global {
                        guard let routine else { throw NativeRPCError.invalidArguments("Choose an existing routine.") }
                        _ = try await access.knownFolder(context, routine.folder)
                    }
                    // Consent and activity records contain no URL, bot token, header secret, question, or report text.
                    let safe = NativeRPCValue.object([.init("routineId", .string(routineID)), .init("do", operation == "chat-view" ? .string(viewAction) : .null), .init("destinationId", args["destinationId"]),
                        .init("count", .number(Double(args["destinations"].elements?.count ?? 0)))])
                    try await access.authorize(context, id, safe, actualTier, description, actualTier != .read)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    if let routine {
                        _ = try await access.knownFolder(context, routine.folder)
                        guard api.store.list().first(where: { $0.id == routineID })?.routine == routine else {
                            throw NativeRPCError(code: "routine-changed", message: "The routine changed while this action was being checked. Read it and try again.")
                        }
                    }
                    if operation == "chat-view" {
                        guard let chatView else { throw NativeRPCError(code: "unavailable", message: "The Mac chat view is not connected.") }
                        let result = try await chatView(routineID, viewAction)
                        try await access.record(context, id, safe, .object([.init("ok", .bool(true))]))
                        return .value(result)
                    }
                    guard let reports = api.reports else { throw NativeRPCError(code: "unavailable", message: "Routine reports are not ready.") }
                    let arguments: [NativeRPCValue]
                    switch operation {
                    case "add-connection": arguments = [args["connection"]]
                    case "connections": arguments = []
                    case "set-destinations": arguments = [.string(routineID), args["destinations"]]
                    case "test-destination": arguments = [.string(routineID), args["destinationId"]]
                    case "reports-chat": arguments = [.string(routineID), args["seenSequence"]]
                    case "follow-up": arguments = [.string(routineID), args["text"], args["reportId"]]
                    default: arguments = [.string(routineID)]
                    }
                    let result = try await reports.invoke("routines:" + operation, arguments: arguments, routine: routine)
                    if operation == "follow-up", result["ok"].bool == true { _ = try await chatView?(routineID, "latest") }
                    try await access.record(context, id, safe, .object([.init("ok", .bool(true))]))
                    return .value(result)
                }
            }
        }
    }
}
