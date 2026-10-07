import Foundation
import TerminalDeckNativeCore

public enum BackendArtifactsChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, artifacts: BackendArtifactsIndex,
                                projects: BackendProjectService) async throws -> [String] {
        for operation in ["list", "changes"] {
            try await registry.register("artifacts:" + operation, ownerID: ownerID) { context, args in
                try context.require("files.read")
                let request = context.argument(0, in: args)
                guard let cwd = request["cwd"].string, cwd.hasPrefix("/"), (try? await projects.requireKnown(cwd)) != nil else {
                    return .object([.init("ok", .bool(false)), .init("error", .string("invalid-project")), .init("message", .string("An open project folder is required."))])
                }
                if operation == "changes" && (request["relPath"].string ?? "").isEmpty { return .object([.init("ok", .bool(false)), .init("error", .string("invalid-project")), .init("message", .string("A file is required."))]) }
                var options = BackendArtifactScanOptions()
                options.scope = request["scope"].string == "all" ? .all : .project
                options.maxSessions = Int(min(max(request["maxSessions"].number ?? 40, 1), 400))
                options.maxArtifacts = Int(min(max(request["maxArtifacts"].number ?? 400, 1), 2_000))
                options.maxChanges = Int(min(max(request["maxChanges"].number ?? 60, 1), 500))
                do {
                    let value = operation == "list" ? try await artifacts.list(project: cwd, options: options, context: context)
                        : try await artifacts.history(project: cwd, relative: request["relPath"].string ?? "", options: options, context: context)
                    return value.setting("ok", .bool(true))
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
