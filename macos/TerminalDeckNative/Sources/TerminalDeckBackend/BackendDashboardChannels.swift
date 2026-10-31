import Foundation
import TerminalDeckNativeCore

public enum BackendDashboardChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, dashboards: BackendDashboardStore,
                                projects: BackendProjectService) async throws -> [String] {
        for operation in ["load", "save", "clear"] {
            try await registry.register("dashboard:" + operation, ownerID: ownerID) { context, args in
                try context.require(operation == "load" ? "projects.read" : "projects.write")
                let path = try context.argument(0, in: args).requireString("project path")
                _ = try await projects.requireKnown(path)
                _ = try await projects.files.authority.authorize(path, context: context)
                if operation == "load" { return try await dashboards.load(projectPath: path) }
                if operation == "save" { try await dashboards.save(projectPath: path, layout: context.argument(1, in: args)) }
                else { try await dashboards.clear(projectPath: path) }
                return .missing
            }
        }
        return ["dashboard:load", "dashboard:save", "dashboard:clear"]
    }
}
