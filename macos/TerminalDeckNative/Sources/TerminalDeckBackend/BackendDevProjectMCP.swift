import Foundation
import TerminalDeckNativeCore

/// Actual project-tools.ts dev.servers/dashboard.layout/artifacts.list handlers.
/// The existing actual consent/action-log gate is required; conditional effects
/// check the caller's real tier before starting a process or saving a layout.
public enum BackendDevProjectMCP {
    public static func register(server: BackendNativeMCPServer, projects: BackendProjectService, dev: BackendDevServers,
                                ports: BackendDevPortDiscovery, dashboards: BackendDashboardStore, artifacts: BackendArtifactsIndex,
                                access: BackendProjectFilesToolAccess) async throws -> [String] {
        let text = NativeRPCValue.object([.init("type", .string("string"))]), bool = NativeRPCValue.object([.init("type", .string("boolean"))]), integer = NativeRPCValue.object([.init("type", .string("integer"))])
        let rows: [(String, String, [(String, NativeRPCValue)], [String])] = [
            ("dev.servers", "The real development servers of open projects: list, start a declared script in a visible shell, or inspect listening ports.", [("action", text), ("cwd", text), ("refresh", bool)], ["action"]),
            ("dashboard.layout", "Read, save or reset an open project's editable Overview tile arrangement.", [("action", text), ("cwd", text), ("layout", .object([.init("type", .string("object"))]))], ["action", "cwd"]),
            ("artifacts.list", "Project-scoped files agents wrote/edited, or one file's recorded history. Counts and truncation report the evidence scanned.", [("cwd", text), ("path", text), ("scope", text), ("limit", integer)], ["cwd"]),
        ]
        for (id, description, properties, required) in rows {
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })), .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            try await server.registerTool(BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: schema, tier: .read)) { caller, args in
                let rpc = try await access.rpcContext(caller)
                try Task.checkCancellation()
                let action = args["action"].string ?? "", tier: BackendMCPTier = id == "dev.servers" && action == "start" ? .act : id == "dashboard.layout" && action != "read" ? .alter : .read
                guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "access-denied", message: "This caller cannot perform the requested development action") }
                if id == "dev.servers" { guard ["list", "start", "ports"].contains(action) else { throw NativeRPCError.invalidArguments("action must be list, start or ports") } }
                if id == "dashboard.layout" { guard ["read", "save", "reset"].contains(action) else { throw NativeRPCError.invalidArguments("action must be read, save or reset") } }
                let cwd = args["cwd"].string
                if let cwd { _ = try await projects.requireKnown(cwd, restrictedTo: caller.projectRoot); _ = try await projects.files.authority.authorize(cwd, context: rpc) }
                try await access.authorize(caller, id, args, tier)
                let value: NativeRPCValue
                if id == "dev.servers" {
                    if action == "ports" { value = .object([.init("ports", .array(try await ports.scan(force: args["refresh"].bool == true).map(\.wireValue)))]) }
                    else if action == "start" { guard let cwd else { throw NativeRPCError.invalidArguments("Starting a development server requires cwd") }; value = .object([.init("server", try await dev.start(folder: cwd, context: rpc))]) }
                    else {
                        var states: [NativeRPCValue] = []
                        for row in await projects.list().elements ?? [] {
                            if let folder = row["path"].string, (try? await projects.requireKnown(folder, restrictedTo: caller.projectRoot)) != nil,
                               (try? await projects.files.authority.authorize(folder, context: rpc)) != nil { states.append(try await dev.status(folder: folder, context: rpc)) }
                        }
                        value = .object([.init("servers", .array(states))])
                    }
                } else if id == "dashboard.layout" {
                    guard let cwd else { throw NativeRPCError.invalidArguments("Dashboard layout requires cwd") }
                    if action == "read" { value = .object([.init("cwd", .string(cwd)), .init("layout", try await dashboards.load(projectPath: cwd))]) }
                    else if action == "reset" { try await dashboards.clear(projectPath: cwd); value = .object([.init("cwd", .string(cwd)), .init("reset", .bool(true))]) }
                    else { try await dashboards.save(projectPath: cwd, layout: args["layout"]); value = .object([.init("cwd", .string(cwd)), .init("saved", .bool(true))]) }
                } else {
                    guard let cwd else { throw NativeRPCError.invalidArguments("Artifacts require cwd") }
                    var options = BackendArtifactScanOptions(); options.scope = args["scope"].string == "all" ? .all : .project
                    let limit = min(max(args["limit"].number ?? 50, 1), 300)
                    options.maxArtifacts = Int(limit); options.maxChanges = Int(limit)
                    if let relative = args["path"].string { value = try await artifacts.history(project: cwd, relative: relative, options: options, context: rpc) }
                    else { value = try await artifacts.list(project: cwd, options: options, context: rpc) }
                }
                guard !caller.cancellation.isCancelled else { throw CancellationError() }
                return .value(value)
            }
        }
        return rows.map { $0.0 }
    }
}
