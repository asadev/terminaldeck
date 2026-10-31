import Foundation
import TerminalDeckNativeCore

/// Reads the same profile folders the importer uses. Task and folder grants
/// remain with the existing task authority; a scan never imports a profile.
public enum BackendPROJAgentScanning {
    public static let id = "tasks.agents_scan"
    public typealias Projects = @Sendable () async throws -> [PROJProject]
    public static func scan(_ request: NativeRPCValue, projects: [PROJProject],
                            configuration: BackendTaskConfiguration,
                            authorizeFolder: @Sendable (String) async throws -> Void) async throws -> NativeRPCValue {
        guard request.isNullish || request.fields?.allSatisfy({ $0.key == "folders" }) == true else {
            throw NativeRPCError.invalidArguments("Choose agent folders to scan.")
        }
        let explicit = request.has("folders")
        let folders: [String]
        if explicit {
            guard let values = request["folders"].elements, values.count <= 32 else { throw NativeRPCError.invalidArguments("Choose at most 32 folders.") }
            folders = try values.map { try $0.requireString("folder", nonempty: true) }
        } else { folders = projects.flatMap(\.folders) }
        var approved: [String] = [], seen = Set<String>()
        for folder in folders {
            guard seen.insert(folder).inserted else { continue }
            guard folder.hasPrefix("/"), !folder.contains("\0") else { throw NativeRPCError.invalidArguments("Choose a full folder path.") }
            do {
                try await authorizeFolder(folder)
                // A missing agents folder is normal for a registered project.
                let directory: URL
                do { directory = try BackendTAGAgentImport.directory(folder) }
                catch { if explicit { throw error }; continue }
                try await authorizeFolder(directory.path)
                approved.append(folder)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let code = (error as? NativeRPCError)?.code
                if explicit || !["access-denied", "not-granted"].contains(code ?? "") { throw error }
            }
        }
        return try BackendPROJAgentBatches.scan(folders: approved, projects: projects, agents: await configuration.allAgents())
    }
    public static func register(server: BackendNativeMCPServer, ownerID: String,
                                configuration: BackendTaskConfiguration, projects: @escaping Projects,
                                authority: BackendTaskToolAuthority) async throws -> BackendMCPTool {
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("folders", .object([.init("type", .string("array")), .init("maxItems", .number(32)), .init("items", text)]))])),
            .init("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: id, wireName: "tasks_agents_scan",
            description: "Read agent definitions grouped by folder and project, with already imported profiles marked. Omit folders for registered projects. No files or profiles change.", inputSchema: schema, tier: .read)
        try await server.registerTool(tool, ownerID: ownerID) { caller, args in
            guard caller.allowedTiers.contains(.read) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot read agents.") }
            try await authority.requireTasks(caller)
            try await authority.authorize(caller, id, args, .read)
            try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
            let result = try await scan(args, projects: projects(), configuration: configuration,
                authorizeFolder: { try await authority.project(caller, $0) })
            try await authority.requireTasks(caller)
            try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
            return .value(result)
        }
        return tool
    }
}
