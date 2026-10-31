import Foundation
import TerminalDeckNativeCore

public enum BackendPROJSettings {
    /// Supplied by the live credential/session owner, never by tool arguments.
    public typealias ProjectIdentity = @Sendable (BackendMCPCallContext) async throws -> String?
    public static let ids = ["project_settings.get", "project_settings.set"]
    public static func register(server: BackendNativeMCPServer, registry: BackendPROJRegistry,
                                settings: BackendAppSettingsStore, ownerID: String,
                                authorize: @escaping BackendPROJMCP.Authorize,
                                projectIdentity: @escaping ProjectIdentity = { _ in nil }) async throws {
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        for id in ids {
            let write = id == ids[1], tier: BackendMCPTier = write ? .alter : .read
            var properties: [NativeRPCValue.Field] = [.init("projectId", text)]
            if write { properties.append(.init("values", .object([.init("type", .string("object"))]))) }
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties)),
                .init("required", .array((write ? ["projectId", "values"] : ["projectId"]).map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: write ? "Change settings for one named project. Runs at once when the calling AI's permission mode allows it; the action is logged. Other projects keep their own values." : "Read settings for one named project, including its project id. Read-only.", inputSchema: schema, tier: tier)
            try await server.registerTool(spec, ownerID: ownerID) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot change project settings.") }
                let projectID = try args["projectId"].requireString("project id", nonempty: true)
                guard try await registry.projects().contains(where: { $0.id == projectID }) else { throw NativeRPCError.invalidArguments("Choose a registered project.") }
                let explicit = try await projectIdentity(caller)
                let bound: String?
                if let explicit { bound = explicit }
                else if let root = caller.projectRoot { bound = try await registry.resolve(projectID: nil, folder: root) }
                else { bound = nil }
                if let bound, bound != projectID {
                    throw NativeRPCError(code: "access-denied", message: "That project is outside this caller's project.")
                }
                try await authorize(caller, id, args, tier)
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                if write {
                    guard args["values"].fields != nil else { throw NativeRPCError.invalidArguments("Settings must be named values.") }
                    return .value(try await settings.patchProject(projectID, values: args["values"]))
                }
                return .value(await settings.projectSettings(projectID))
            }
        }
    }
}
