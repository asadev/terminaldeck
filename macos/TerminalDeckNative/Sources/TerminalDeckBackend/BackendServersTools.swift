import Foundation
import TerminalDeckNativeCore

/// Exact three tools from servers/tools.ts. Unrestricted terminal tools belong
/// to the separate, always-alter server-room adapter, never this grant surface.
public enum BackendServersTools {
    public static let names = ["servers.look", "servers.logs", "servers.control"]
    public typealias Resolve = @Sendable (BackendMCPCallContext) async throws -> BackendServersCaller
    public static func definitions() throws -> [BackendMCPTool] {
        let look = #"{"type":"object","properties":{"serverId":{"type":"string","description":"Which server. Leave it out to get the list of servers instead."}},"additionalProperties":false}"#
        let logs = #"{"type":"object","properties":{"serverId":{"type":"string"},"cardId":{"type":"string","description":"The id from servers.look."},"lines":{"type":"integer","description":"How many lines from the end. Default 200, max 2000."}},"required":["serverId","cardId"],"additionalProperties":false}"#
        let actions = NativeRPCValue.array(BackendServersActionID.control.map { .string($0.rawValue) })
        let control = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("serverId", .object([.init("type", .string("string"))])), .init("cardId", .object([.init("type", .string("string"))])),
            .init("action", .object([.init("type", .string("string")), .init("enum", actions)]))])),
            .init("required", .array([.string("serverId"), .string("cardId"), .string("action")])), .init("additionalProperties", .bool(false))])
        return [
            try .init(id: names[0], wireName: "servers_look", description: "List servers or look at one: its measured facts and cards, including what could not be checked. No credentials or coding-account addresses. Look before control.", inputSchema: NativeRPCValue.parseJSON(Data(look.utf8)), tier: .read),
            try .init(id: names[1], wireName: "servers_logs", description: "Read one bounded window of recent output from a named site, app or database. No follow loop.", inputSchema: NativeRPCValue.parseJSON(Data(logs.utf8)), tier: .read),
            // The concrete coordinator's mandatory policy enforces alter, or
            // act only for the current per-server local grant. This transport
            // base must not prevent an otherwise-authorized act-only caller.
            try .init(id: names[2], wireName: "servers_control", description: "Do a named start/restart/stop/update/go-back/backup action. No arbitrary command. Exact server grant, cached facts, consequence and recovery checks apply; access keys always use alter.", inputSchema: control, tier: .act)
        ]
    }
    public static func register(on server: BackendNativeMCPServer, ownerID: String, room: BackendServersCoordinator, resolve: @escaping Resolve) async throws {
      do {
        for spec in try definitions() {
            try await server.registerTool(spec, ownerID: ownerID) { context, arguments in
                do {
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    return .value(try await invoke(spec.id, arguments: arguments, caller: resolve(context), room: room))
                } catch is CancellationError { throw CancellationError() }
                catch { return .failure(error.localizedDescription) }
            }
        }
      } catch { await server.removeTools(ownerID: ownerID); throw error }
    }
    public static func invoke(_ id: String, arguments: NativeRPCValue, caller: BackendServersCaller, room: BackendServersCoordinator) async throws -> NativeRPCValue {
        guard let fields = arguments.fields else { throw NativeRPCError.invalidArguments("Tool arguments must be an object.") }
        let allowed: Set<String>
        switch id { case "servers.look": allowed = ["serverId"]; case "servers.logs": allowed = ["serverId", "cardId", "lines"]; case "servers.control": allowed = ["serverId", "cardId", "action"]; default: throw NativeRPCError.invalidArguments("No such server tool.") }
        guard fields.allSatisfy({ allowed.contains($0.key) }) else { throw NativeRPCError.invalidArguments("That server tool has an argument it does not accept.") }
        if id == "servers.control", !caller.actsAsOwner { throw BackendServersActionRefused("Changing anything on a server only works for the person at this machine, or an AI app they gave an access key to. A paired device cannot do it and cannot be given permission to. Say what you would have done and let them do it.") }
        if id == "servers.look" {
            if arguments["serverId"].isNullish || arguments["serverId"].string == "" { return .object([.init("servers", try await room.list(caller))]) }
            let serverId = try required(arguments, "serverId")
            guard try await room.knows(serverId) else { throw BackendServersActionRefused("There is no server with the id \(serverId) in this app.") }
            return withoutAccounts(try await room.look(serverId, caller: caller).wireValue())
        }
        let serverId = try required(arguments, "serverId"), cardId = try required(arguments, "cardId")
        guard try await room.knows(serverId) else { throw BackendServersActionRefused("There is no server with the id \(serverId) in this app.") }
        if id == "servers.logs" {
            if !arguments["lines"].isNullish, arguments["lines"].number == nil { throw NativeRPCError.invalidArguments("lines must be a number") }
            return try await room.logs(serverId, cardId: cardId, lines: arguments["lines"].number ?? 200, caller: caller)
        }
        guard caller.actsAsOwner else { throw BackendServersActionRefused("Changing anything on a server only works for the person at this machine, or an AI app they gave an access key to. A paired device cannot do it and cannot be given permission to. Say what you would have done and let them do it.") }
        let action = try required(arguments, "action")
        guard let actionId = BackendServersActionID(rawValue: action), BackendServersActionID.control.contains(actionId) else {
            throw BackendServersActionRefused("action must be one of: \(BackendServersActionID.control.map(\.rawValue).joined(separator: ", "))")
        }
        guard let view = await room.cached(serverId) else { throw BackendServersActionRefused("Call servers.look on \(serverId) first. Nothing on this server can be changed before this app has seen what is on it.") }
        guard let card = view.cards.first(where: { $0.id == cardId }) else { throw BackendServersActionRefused("There is nothing called \(cardId) on that server.") }
        if let absent = view.absent[cardId]?.first(where: { $0.actionId == actionId }) { throw BackendServersActionRefused(absent.because) }
        guard view.offered[cardId]?.contains(actionId) == true else { throw BackendServersActionRefused("\(action) is not something this app can do to \(card.name).") }
        return try await room.act(serverId, cardId: cardId, action: actionId, caller: caller, requireCached: true).wireValue
    }
    private static func required(_ args: NativeRPCValue, _ key: String) throws -> String {
        guard let value = args[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("\(key) is required and must be a non-empty string") }; return value
    }
    public static func withoutAccounts(_ value: NativeRPCValue) -> NativeRPCValue {
        guard value["facts"]["agents"]["known"].string == "yes", let agents = value["facts"]["agents"]["value"].elements else { return value }
        return value.setting("facts", value["facts"].setting("agents", value["facts"]["agents"].setting("value", .array(agents.map { $0.setting("account", .null) }))))
    }
}
