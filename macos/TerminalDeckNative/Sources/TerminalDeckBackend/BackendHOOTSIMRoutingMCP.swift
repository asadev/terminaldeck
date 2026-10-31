import Foundation
import TerminalDeckNativeCore

public enum BackendHOOTSIMRoutingMCP {
    public static func definitions(routing: BackendHOOTSIMRouting, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let object = NativeRPCValue.object([.init("type", .string("object"))])
        let descriptions: [(String, String, [NativeRPCValue.Field], [String])] = [
            ("read", "Read Hoot's routing cards.", [], []),
            ("propose", "Propose who should handle a problem. This only makes a card; it never starts or messages anyone.",
             [.init("problem", string.setting("maxLength", .number(8000))), .init("source", object),
              .init("candidates", .object([.init("type", .string("array")), .init("maxItems", .number(16)), .init("items", object)])),
              .init("attachments", .object([.init("type", .string("array")), .init("maxItems", .number(4)), .init("items", object)])), .init("target", object)], ["problem", "source"]),
            ("dispatch", "Send exactly the current routing proposal; it runs when your permission mode allows it. Each session start or message still goes through its own checks.", [.init("id", string), .init("revision", string)], ["id", "revision"]),
            ("dismiss", "Dismiss this routing card without sending anything.", [.init("id", string), .init("revision", string)], ["id", "revision"]),
            ("retarget", "Make a fresh routing card for a different target. An old approval never applies to this new card.", [.init("id", string), .init("revision", string), .init("target", object)], ["id", "revision", "target"])
        ]
        return try descriptions.map { action, description, fields, required in
            let id = "hoot.route." + action
            let spec = try BackendMCPTool(id: id, wireName: "hoot_route_" + action, description: description,
                inputSchema: .object([.init("type", .string("object")), .init("properties", .object(fields)),
                    .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))]), tier: .read, advertised: false)
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description, audience: "copilot") { caller, args in
                do {
                    guard caller.allowedTools.contains(spec.id) || caller.allowedTools.contains(spec.wireName), caller.allowedTiers.contains(.read) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use this routing tool.")
                    }
                    try BackendDeckCoreCatalogueSchema.check(schema: spec.inputSchema, arguments: args)
                    guard try await access.caller(caller).kind == .local else { throw NativeRPCError(code: "not-granted", message: "These routing cards belong to Hoot and the person on this Mac.") }
                    // The actor dispatch's dedicated callback asks at .alter with
                    // ownerMustAnswer=true. Read/propose/dismiss are bookkeeping.
                    if action != "dispatch" { try await access.authorize(caller, id, args, .read, description, false) }
                    let value: NativeRPCValue
                    switch action {
                    case "read": value = try await routing.read(caller)
                    case "propose": value = try await routing.propose(args, caller: caller)
                    case "dismiss": value = try await routing.dismiss(try args["id"].requireString("id"), revision: args["revision"].requireString("revision"), caller: caller)
                    case "retarget": value = try await routing.retarget(try args["id"].requireString("id"), revision: args["revision"].requireString("revision"), target: args["target"], caller: caller)
                    default: value = try await routing.dispatch(try args["id"].requireString("id"), revision: args["revision"].requireString("revision"), caller: caller)
                    }
                    try await access.record(caller, id, args, .object([.init("id", value["id"]), .init("state", value["state"])]))
                    return .value(value)
                } catch { return BackendDeckToolsMachinesFactory.failureReply(error) }
            }
        }
    }
}
