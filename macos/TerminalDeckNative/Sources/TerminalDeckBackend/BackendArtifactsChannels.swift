import Foundation
import TerminalDeckNativeCore

public enum BackendArtifactsChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, artifacts: BackendArtifactsIndex,
                                projects: BackendProjectService) async throws -> [String] {
        for operation in ["list", "changes"] {
            try await registry.register("artifacts:" + operation, ownerID: ownerID) { context, args in
                try context.require("files.read")
                let request = context.argument(0, in: args)
                let refused = NativeRPCValue.object([.init("ok", .bool(false)), .init("error", .string("invalid-project")), .init("message", .string("An open project folder is required."))])
                guard let cwd = request["cwd"].string, cwd.hasPrefix("/") else { return refused }
                // A folder open in the side panel, or a registered project's own folder (the projects registry):
                // the Artifacts page lists a project's work whether or not a session is open there. A folder that
                // is neither is still refused, and the filesystem authority still decides what this caller may read.
                if (try? await projects.requireKnown(cwd)) == nil {
                    guard await artifacts.isRegisteredFolder(cwd) else { return refused }
                }
                if operation == "changes" && (request["relPath"].string ?? "").isEmpty { return .object([.init("ok", .bool(false)), .init("error", .string("invalid-project")), .init("message", .string("A file is required."))]) }
                var options = BackendArtifactScanOptions()
                options.scope = request["scope"].string == "all" ? .all : .project
                options.maxSessions = Int(min(max(request["maxSessions"].number ?? 40, 1), 400))
                options.maxArtifacts = Int(min(max(request["maxArtifacts"].number ?? 400, 1), 2_000))
                options.maxChanges = Int(min(max(request["maxChanges"].number ?? 60, 1), 500))
                // The Artifacts page asks for artifacts alone, so notes and source cannot use up the row budget.
                options.onlyArtifacts = request["only"].string == "artifacts"
                do {
                    let value = operation == "list" ? try await artifacts.list(project: cwd, options: options, context: context)
                        : try await artifacts.history(project: cwd, relative: request["relPath"].string ?? "", options: options, context: context)
                    // The index already used the current registry. A missing id
                    // must not replace its identity with the built-in defaults.
                    var scoped = value
                    if let projectID = request["projectId"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !projectID.isEmpty {
                        scoped = scoped.setting("projectId", .string(projectID))
                        for key in ["artifacts", "sessions", "changes"] {
                            if let rows = value[key].elements {
                                scoped = scoped.setting(key, .array(rows.map { $0.setting("projectId", .string(projectID)) }))
                            }
                        }
                    }
                    return scoped.setting("ok", .bool(true))
                } catch {
                    return .object([.init("ok", .bool(false)), .init("error", .string(error is CancellationError ? "cancelled" : "failed")),
                        .init("message", .string(error is CancellationError ? "Scan cancelled." : operation == "list" ? "Could not read this project's history." : "Could not read this file's history."))])
                }
            }
        }
        try await registry.register("artifacts:cancel", ownerID: ownerID) { context, _ in await artifacts.cancel(ownerID: context.ownerID); return .missing }
        return ["artifacts:list", "artifacts:changes", "artifacts:cancel"]
    }
}
