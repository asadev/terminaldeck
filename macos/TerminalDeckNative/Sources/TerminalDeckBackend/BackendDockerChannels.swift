import Foundation
import TerminalDeckNativeCore

public enum BackendDockerChannels {
    public static let invokeChannels: Set<String> = [
        "docker:targets", "docker:status", "docker:containers:list", "docker:containers:inspect",
        "docker:containers:start", "docker:containers:stop", "docker:containers:restart", "docker:containers:remove",
        "docker:images:list", "docker:images:remove", "docker:volumes:list", "docker:volumes:create", "docker:volumes:remove",
        "docker:networks:list", "docker:networks:create", "docker:networks:remove", "docker:compose:list", "docker:compose:inspect",
        "docker:logs:open", "docker:stats:open", "docker:events:open", "docker:stream:close",
        "docker:exec:open", "docker:exec:write", "docker:exec:resize", "docker:exec:close", "docker:install:preview", "docker:install",
    ]
    public static let eventChannels: Set<String> = ["docker:logs:data", "docker:stats:data", "docker:events:data", "docker:stream:end", "docker:exec:data", "docker:exec:end"]
    public static let writeChannels: Set<String> = ["docker:containers:start", "docker:containers:stop", "docker:containers:restart", "docker:containers:remove",
        "docker:images:remove", "docker:volumes:create", "docker:volumes:remove", "docker:networks:create", "docker:networks:remove", "docker:exec:open", "docker:install"]
    public static let destructiveChannels: Set<String> = ["docker:containers:remove", "docker:images:remove", "docker:volumes:remove", "docker:networks:remove"]

    /// Reject connection, credential and shell override fields at the boundary.
    public static func requestFields(_ channel: String) -> Set<String> {
        let fields: [String]
        switch channel {
        case "docker:containers:list": fields = ["all", "filters"]
        case "docker:containers:inspect", "docker:containers:start": fields = ["id"]
        case "docker:containers:stop", "docker:containers:restart": fields = ["id", "timeoutSeconds"]
        case "docker:containers:remove": fields = ["id", "confirmName", "force", "removeVolumes"]
        case "docker:images:remove": fields = ["id", "confirmName", "force"]
        case "docker:volumes:create": fields = ["name", "driver", "labels"]
        case "docker:volumes:remove": fields = ["name", "confirmName", "force"]
        case "docker:networks:create": fields = ["name", "driver", "internal", "labels"]
        case "docker:networks:remove": fields = ["id", "confirmName"]
        case "docker:compose:inspect": fields = ["name"]
        case "docker:logs:open": fields = ["id", "tail", "timestamps"]
        case "docker:stats:open": fields = ["id"]
        case "docker:events:open": fields = ["filters", "since"]
        case "docker:stream:close": fields = ["streamId"]
        case "docker:exec:open": fields = ["id", "command", "columns", "rows"]
        case "docker:exec:write": fields = ["sessionId", "data"]
        case "docker:exec:resize": fields = ["sessionId", "columns", "rows"]
        case "docker:exec:close": fields = ["sessionId"]
        default: fields = []
        }
        return Set(fields).union(["target"])
    }

    /// DKA must retain the service and invoke disconnect/shutdown on teardown.
    @discardableResult public static func register(registry: NativeChannelRegistry, service: BackendDockerService,
                                                   ownerID: String = "native-docker") async throws -> [String] {
        try await service.attach(registry: registry)
        var installed: [String] = []
        do {
            for channel in invokeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { context, arguments in
                    try await service.handle(channel, context: context, arguments: arguments)
                }
                installed.append(channel)
            }
            return installed
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }
}
