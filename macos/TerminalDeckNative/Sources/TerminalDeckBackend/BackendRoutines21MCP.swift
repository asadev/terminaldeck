import Foundation
import TerminalDeckNativeCore

public enum BackendRoutines21MCP {
    public static func definitions(api: BackendRoutinesAPI, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let entries: [(String, String, BackendMCPTier, String)] = [
            ("reports", "Read a routine's reports and separate follow-up answers, oldest first.", .read, ""),
            ("reports-chat", "Read a routine report chat with unread counts and its saved seen-marker. Optional seenSequence advances the marker.", .read, ""),
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
                    _ = try await access.caller(context)
                    let routineID = args["routineId"].string ?? ""
                    let routine = api.store.list().first { $0.id == routineID }?.routine
                    if !global {
                        guard let routine else { throw NativeRPCError.invalidArguments("Choose an existing routine.") }
                        _ = try await access.knownFolder(context, routine.folder)
                    }
                    // Consent and activity records contain no URL, bot token, header secret, question, or report text.
                    let safe = NativeRPCValue.object([.init("routineId", .string(routineID)), .init("destinationId", args["destinationId"]),
                        .init("count", .number(Double(args["destinations"].elements?.count ?? 0)))])
                    try await access.authorize(context, id, safe, tier, description, tier != .read)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    if let routine {
                        _ = try await access.knownFolder(context, routine.folder)
                        guard api.store.list().first(where: { $0.id == routineID })?.routine == routine else {
                            throw NativeRPCError(code: "routine-changed", message: "The routine changed while this action was being checked. Read it and try again.")
                        }
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
                    try await access.record(context, id, safe, .object([.init("ok", .bool(true))]))
                    return .value(result)
                }
            }
        }
    }
}
