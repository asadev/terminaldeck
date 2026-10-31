import Foundation
import TerminalDeckNativeCore

/// The org canvas's manager spelling. All authority and persistence stay in the
/// existing profile service; the legacy reports-to tools remain unchanged.
public enum BackendORGMCP {
    public static let owner = "org-manager"
    public static let toolID = "agents.set_manager"
    public static let ids = [toolID]

    public static func spec() throws -> BackendMCPTool {
        let schema = NativeRPCValue.object([
            .init("type", .string("object")),
            .init("properties", .object([
                .init("id", .object([.init("type", .string("string")), .init("minLength", .number(1))])),
                .init("managerId", .object([.init("type", .array([.string("string"), .string("null")])), .init("minLength", .number(1))]))
            ])),
            .init("required", .array([.string("id"), .string("managerId")])),
            .init("additionalProperties", .bool(false))
        ])
        return try BackendMCPTool(id: toolID, wireName: "agents_set_manager",
            description: "Set an agent's manager: an agent id, @hoot, or null for Independent. Runs at once when the calling AI's permission mode allows it; loops are refused and existing profile limits stay in place.",
            inputSchema: schema, tier: .alter)
    }

    public static func invoke(arguments: NativeRPCValue, caller: BackendMCPCallContext,
                              service: BackendAGTDirectoryService) async throws -> NativeRPCValue {
        let args = try arguments.requireObject("arguments")
        guard args.fields?.count == 2,
              args.fields?.allSatisfy({ ["id", "managerId"].contains($0.key) }) == true,
              args.has("id"), args.has("managerId") else {
            throw NativeRPCError.invalidArguments("Use id and managerId; managerId can be an agent id, @hoot, or null.")
        }
        let id = try args["id"].requireString("id", nonempty: true)
        let manager = args["managerId"]
        if manager != .null { _ = try manager.requireString("managerId", nonempty: true) }
        return try await service.invoke("agents.set_reports_to",
            arguments: .object([.init("id", .string(id)), .init("reportsTo", manager)]), caller: caller)
    }

    public static func install(service: BackendAGTDirectoryService, server: BackendNativeMCPServer,
                               ownerID: String = owner) async throws {
        let definition = try spec()
        try await server.registerTool(definition, ownerID: ownerID) { caller, arguments in
            .value(try await invoke(arguments: arguments, caller: caller, service: service))
        }
    }
}
