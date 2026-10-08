import Foundation
import TerminalDeckNativeCore

/// MCP actions over CONTRACT-docker.md v1. The existing channel owner resolves
/// targets, owns SSH/socket connections and enforces resource/session ownership.
public enum BackendDockerMCP {
    public static let ownerID = "native-docker-mcp"
    private struct Definition: Sendable {
        let id: String, channel: String, description: String
        let tier: BackendMCPTier
        let destructive: Bool
        let schema: NativeRPCValue
    }

    private static func property(_ type: String, minimum: Double? = nil, maximum: Double? = nil) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("type", .string(type))])
        if let minimum { value = value.setting(type == "string" ? "minLength" : "minimum", .number(minimum)) }
        if let maximum { value = value.setting(type == "string" ? "maxLength" : "maximum", .number(maximum)) }
        return value
    }
    private static func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
        .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                 .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
    }
    private static func catalogue() -> [Definition] {
        let text = property("string", minimum: 1, maximum: 512), boolean = property("boolean")
        let labels = NativeRPCValue.object([.init("type", .string("object")), .init("additionalProperties", property("string"))])
        let strings = NativeRPCValue.object([.init("type", .string("array")), .init("items", property("string")), .init("maxItems", .number(256))])
        let filters = NativeRPCValue.object([.init("type", .string("object")), .init("additionalProperties", strings)])
        let timeout = property("integer", minimum: 0, maximum: 300)
        let dimension = property("integer", minimum: 1, maximum: 4096)
        func d(_ suffix: String, _ description: String, _ fields: [(String, NativeRPCValue)] = [],
               _ required: [String] = [], write: Bool = false, destructive: Bool = false, targetRequired: Bool = true) -> Definition {
            Definition(id: "docker." + suffix, channel: "docker:" + suffix.replacingOccurrences(of: ".", with: ":"), description: description,
                       tier: write ? .alter : .read, destructive: destructive,
                       schema: schema([("target", text)] + fields, required: (targetRequired ? ["target"] : []) + required))
        }
        return [
            d("targets", "List saved server targets and locally available Docker engines. Connections are discovered only for this request.", targetRequired: false),
            d("status", "Read the Docker engine version and availability on a saved server or This Mac."),
            d("containers.list", "List containers with their actual state, names, image and ports.", [("all", boolean), ("filters", filters)]),
            d("containers.inspect", "Read one container's safe details. Environment values and command arguments are masked.", [("id", text)], ["id"]),
            d("containers.start", "Start one named container. The person must approve this server change.", [("id", text)], ["id"], write: true),
            d("containers.stop", "Stop one named container. The person must approve this server change.", [("id", text), ("timeoutSeconds", timeout)], ["id"], write: true),
            d("containers.restart", "Restart one named container. The person must approve this server change.", [("id", text), ("timeoutSeconds", timeout)], ["id"], write: true),
            d("containers.remove", "Remove one container after explicit approval. confirmName must match its current name; removing volumes can delete data.", [("id", text), ("confirmName", text), ("force", boolean), ("removeVolumes", boolean)], ["id", "confirmName"], write: true, destructive: true),
            d("images.list", "List images and their tags, size and creation time."),
            d("images.remove", "Remove one image after explicit approval. confirmName must match the current image name supplied by the engine.", [("id", text), ("confirmName", text), ("force", boolean)], ["id", "confirmName"], write: true, destructive: true),
            d("volumes.list", "List stored Docker volumes and their drivers."),
            d("volumes.create", "Create one named volume after the person approves.", [("name", text), ("driver", text), ("labels", labels)], ["name"], write: true),
            d("volumes.remove", "Delete a volume and its data after explicit approval naming it. confirmName must match its current name.", [("name", text), ("confirmName", text), ("force", boolean)], ["name", "confirmName"], write: true, destructive: true),
            d("networks.list", "List networks and whether they are internal."),
            d("networks.create", "Create one named network after the person approves.", [("name", text), ("driver", text), ("internal", boolean), ("labels", labels)], ["name"], write: true),
            d("networks.remove", "Remove one network after explicit approval. confirmName must match its current name.", [("id", text), ("confirmName", text)], ["id", "confirmName"], write: true, destructive: true),
            d("compose.list", "List Compose projects from the engine's official project and service labels."),
            d("compose.inspect", "Read one Compose project's containers, services and running count.", [("name", text)], ["name"]),
            d("logs.open", "Read a bounded window from the owned log stream, then close it before this tool returns. The native screen provides continuous logs.", [("id", text), ("tail", property("integer", minimum: 0, maximum: 5000)), ("timestamps", boolean)], ["id"]),
            d("stats.open", "Read one CPU and memory sample from the owned stats stream, then close it before this tool returns.", [("id", text)], ["id"]),
            d("events.open", "Read a bounded window from the owned event stream, then close it before this tool returns. No background alerts are enabled.", [("filters", filters), ("since", property("string", maximum: 128))]),
            d("stream.close", "Close only a Docker stream owned by this caller on this target.", [("streamId", text)], ["streamId"]),
            d("exec.open", "Open a terminal in one container after explicit approval. Uses the existing session bridge and the caller's ownership.", [("id", text), ("command", strings.setting("minItems", .number(1))), ("columns", dimension), ("rows", dimension)], ["id"], write: true),
            d("exec.write", "Send base64 terminal bytes to an owned container terminal. Input is masked in approvals and logs.", [("sessionId", text), ("data", property("string", minimum: 1, maximum: 65536))], ["sessionId", "data"], write: true),
            d("exec.resize", "Resize an owned container terminal.", [("sessionId", text), ("columns", dimension), ("rows", dimension)], ["sessionId", "columns", "rows"], write: true),
            d("exec.close", "Close an owned container terminal connection. This does not claim the remote process exited.", [("sessionId", text)], ["sessionId"], write: true),
            d("install.preview", "Show the fixed official Docker installer command before asking the person to run it."),
            d("install", "Install Docker on a Linux server using the official installer, after explicit approval. Requires the existing administrator runner.", write: true),
            Definition(id: "docker.logs", channel: "docker:logs:open", description: "Read a bounded window of actual, masked container logs, then close the temporary stream. Never follows in the background.", tier: .read, destructive: false,
                       schema: schema([("target", text), ("id", text), ("tail", property("integer", minimum: 0, maximum: 5000)), ("timestamps", boolean), ("limit", property("integer", minimum: 1, maximum: 256)), ("waitMilliseconds", property("integer", minimum: 1, maximum: 5000))], required: ["target", "id"])),
            Definition(id: "docker.stats", channel: "docker:stats:open", description: "Read one actual CPU and memory sample, then close the temporary stream. An absent sample returns unavailable.", tier: .read, destructive: false,
                       schema: schema([("target", text), ("id", text), ("waitMilliseconds", property("integer", minimum: 1, maximum: 5000))], required: ["target", "id"])),
            Definition(id: "docker.events", channel: "docker:events:open", description: "Read a short, bounded window of actual Docker events, then close the temporary stream. Opens no background watcher.", tier: .read, destructive: false,
                       schema: schema([("target", text), ("filters", filters), ("since", property("string", maximum: 128)), ("limit", property("integer", minimum: 1, maximum: 256)), ("waitMilliseconds", property("integer", minimum: 1, maximum: 5000))], required: ["target"]))
        ]
    }

    public static func definitions() throws -> [BackendMCPTool] {
        try catalogue().map { try BackendMCPTool(id: $0.id, wireName: $0.id.replacingOccurrences(of: ".", with: "_"), description: $0.description, inputSchema: $0.schema, tier: $0.tier) }
    }
    public static func specifications() throws -> [BackendMCPTool] { try definitions() }
    public static func isDestructive(tool: String) -> Bool { catalogue().first { $0.id == tool }?.destructive == true }
    public static func channel(tool: String) throws -> String { try definition(tool).channel }
    public static func preflight(tool: String, arguments: NativeRPCValue, registry: NativeChannelRegistry) async throws {
        try validate(tool: tool, arguments: arguments)
        if tool.hasPrefix("docker.exec.") {
            throw NativeRPCError(code: "unavailable", message: "Container terminals need a stable session owner across calls. Open the terminal in the native Advanced screen; this MCP caller cannot keep a terminal session between tool calls yet.")
        }
        if tool == "docker.install", arguments["target"].string == "local" {
            throw NativeRPCError(code: "unavailable", message: "The official Linux Docker installer cannot run on This Mac.")
        }
        let channel = try channel(tool: tool)
        guard await registry.has(channel) else { throw NativeRPCError(code: "unavailable", message: "The Docker engine operation is unavailable: " + channel + ".") }
        if isBoundedRead(tool), !(await registry.has("docker:stream:close")) {
            throw NativeRPCError(code: "unavailable", message: "Temporary Docker streams cannot be closed, so this read is unavailable.")
        }
    }
    private static func isBoundedRead(_ tool: String) -> Bool {
        ["docker.logs", "docker.logs.open", "docker.stats", "docker.stats.open", "docker.events", "docker.events.open"].contains(tool)
    }
    /// Root's async core precheck supplies its read-only metadata ticket before
    /// consent. The engine checks this name again immediately before mutation.
    public static func validateConfirmation(tool: String, arguments: NativeRPCValue,
                                            registry: NativeChannelRegistry, context: NativeRPCContext) async throws {
        guard isDestructive(tool: tool) else { return }
        try validate(tool: tool, arguments: arguments)
        let target = arguments["target"]
        let id = arguments["id"].string ?? arguments["name"].string ?? ""
        let read: String
        switch tool {
        case "docker.containers.remove": read = "docker:containers:inspect"
        case "docker.images.remove": read = "docker:images:list"
        case "docker.volumes.remove": read = "docker:volumes:list"
        case "docker.networks.remove": read = "docker:networks:list"
        default: return
        }
        guard await registry.has(read) else { throw NativeRPCError(code: "unavailable", message: "The resource's current name cannot be checked before approval.") }
        let request = tool == "docker.containers.remove" ? NativeRPCValue.object([.init("target", target), .init("id", .string(id))]) : .object([.init("target", target)])
        let value = try await registry.invoke(read, context: context, arguments: [request])
        let name: String?
        switch tool {
        case "docker.containers.remove": name = value["name"].string
        case "docker.images.remove":
            let row = value["images"].elements?.first { $0["id"].string == id || $0["tags"].elements?.contains(.string(id)) == true }
            name = row?["tags"].elements?.compactMap(\.string).first { !$0.hasPrefix("<none>") } ?? row?["id"].string
        case "docker.volumes.remove": name = value["volumes"].elements?.first { $0["name"].string == id }?["name"].string
        case "docker.networks.remove": name = value["networks"].elements?.first { $0["id"].string == id || $0["name"].string == id }?["name"].string
        default: name = nil
        }
        guard let name, !name.isEmpty else { throw NativeRPCError(code: "docker-resource-missing", message: "The resource's exact current name is unavailable. Read the current resource list first.") }
        guard arguments["confirmName"].string == name else { throw NativeRPCError(code: "confirmation-required", message: "Type the resource's exact current name to confirm this destructive action.") }
    }
    public static func validate(tool: String, arguments: NativeRPCValue) throws {
        let definition = try definition(tool)
        try BackendDockerMCPArguments.validate(arguments, schema: definition.schema)
        for key in ["target", "id", "name", "confirmName", "sessionId", "streamId"] where arguments.has(key) {
            guard !(arguments[key].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("\(key) must not be blank.") }
        }
        if tool == "docker.volumes.remove", arguments["confirmName"] != arguments["name"] {
            throw NativeRPCError(code: "confirmation-required", message: "confirmName must exactly name the volume being deleted.")
        }
        if tool == "docker.exec.write", let input = arguments["data"].string, Data(base64Encoded: input) == nil {
            throw NativeRPCError.invalidArguments("data must be valid base64 terminal bytes.")
        }
    }
    public static func summary(tool: String, arguments: NativeRPCValue) throws -> String {
        try validate(tool: tool, arguments: arguments)
        let target = arguments["target"].string ?? "available targets"
        let resource = arguments["confirmName"].string ?? arguments["name"].string ?? arguments["id"].string ?? arguments["sessionId"].string ?? arguments["streamId"].string
        if tool == "docker.install" {
            return "Install Docker on \(target) using Docker's official installer: \(BackendDockerInstall.command). Administrator access is required."
        }
        let action = tool.dropFirst("docker.".count).replacingOccurrences(of: ".", with: " ")
        var sentence = "Docker \(action)" + (resource.map { " “\($0)”" } ?? "") + " on \(target)."
        if isDestructive(tool: tool) { sentence += " This removes the named resource" + (tool == "docker.volumes.remove" || arguments["removeVolumes"].bool == true ? " and can delete its data." : ".") }
        return BackendDockerMCPMasker.text(sentence)
    }
    private static func definition(_ id: String) throws -> Definition {
        guard let definition = catalogue().first(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("There is no Docker tool with that name.") }
        return definition
    }

    public static func contribution(registry: NativeChannelRegistry, access: BackendDockerMCPAccess) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        try definitions().map { tool in
            let handler: BackendNativeMCPServer.Handler = { caller, arguments in
                do {
                    return try await BackendDockerMCPAccess.cancellable(caller.cancellation) {
                        .value(try await invoke(tool: tool.id, arguments: arguments, caller: caller, registry: registry, access: access))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let error = NativeRPCError.wrapping(error)
                    // A dependency's error may contain raw Engine bodies or
                    // SSH stderr. Only locally authored messages go on wire.
                    let safeCodes: Set<String> = ["unavailable", "invalid-arguments", "approval-required", "confirmation-required", "forbidden", "docker-not-found", "docker-permission", "docker-api", "docker-protocol", "docker-api-version", "docker-stream-overflow", "docker-resource-missing", "cancelled"]
                    let code = safeCodes.contains(error.code) ? error.code : "unavailable"
                    let message: String
                    switch code {
                    case "invalid-arguments": message = "The Docker request has invalid or unexpected arguments. Check the tool's input fields."
                    case "approval-required": message = "The person's approval is required before this Docker change can run."
                    case "confirmation-required": message = "Type the resource's exact current name to confirm this destructive action."
                    case "forbidden": message = "This caller cannot access that Docker action or owned resource."
                    case "docker-not-found": message = "Docker is not available on this target."
                    case "docker-permission": message = "The existing server connection cannot access Docker on this target."
                    case "docker-protocol", "docker-api-version": message = "The Docker engine returned an unsupported response."
                    case "docker-stream-overflow": message = "The bounded Docker read exceeded its supported size. Request fewer log lines."
                    case "docker-resource-missing": message = "The requested Docker resource no longer exists."
                    case "cancelled": message = "The Docker request was cancelled."
                    case "docker-api": message = "The Docker engine could not complete the requested operation."
                    default: message = "The requested Docker operation is unavailable. Container terminals require the native Advanced screen until stable MCP session ownership is wired."
                    }
                    return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(message))])],
                                               structuredContent: .object([.init("error", .object([.init("code", .string(code)), .init("message", .string(message))]))]), isError: true)
                }
            }
            return (tool, handler)
        }
    }
    public static func register(server: BackendNativeMCPServer, registry: NativeChannelRegistry, access: BackendDockerMCPAccess) async throws -> [String] {
        let entries = try contribution(registry: registry, access: access)
        try await server.replaceTools(ownerID: ownerID, tools: entries)
        return entries.map { $0.0.id }
    }
    public static func invoke(tool: String, arguments: NativeRPCValue, caller: BackendMCPCallContext,
                              registry: NativeChannelRegistry, access: BackendDockerMCPAccess) async throws -> NativeRPCValue {
        let definition = try definition(tool)
        try validate(tool: tool, arguments: arguments)
        guard caller.allowedTools.contains(tool) || caller.allowedTools.contains(tool.replacingOccurrences(of: ".", with: "_")), caller.allowedTiers.contains(definition.tier) else {
            throw NativeRPCError(code: "forbidden", message: "This caller has not been granted that Docker action.")
        }
        guard !caller.cancellation.isCancelled else { throw CancellationError() }
        try await preflight(tool: tool, arguments: arguments, registry: registry)
        let bounded = isBoundedRead(tool)
        try await access.authorize(caller, tool, BackendDockerMCPMasker.arguments(arguments), definition.tier, summary(tool: tool, arguments: arguments), definition.destructive)
        guard !caller.cancellation.isCancelled else { throw CancellationError() }
        let rpc = try await access.rpcContext(caller)
        let result: NativeRPCValue
        if bounded { result = try await BackendDockerMCPReadWindow.read(tool: tool, arguments: arguments, channel: definition.channel, rpc: rpc, registry: registry) }
        else { result = try await registry.invoke(definition.channel, context: rpc, arguments: [arguments]) }
        try validateResult(tool: tool, result: result, bounded: bounded)
        let masked = BackendDockerMCPMasker.value(result)
        await access.noteResult(caller, masked)
        return masked
    }

    private static func validateResult(tool: String, result: NativeRPCValue, bounded: Bool) throws {
        let valid: Bool
        if bounded { valid = result["records"].elements != nil && result["streamClosed"].bool == true }
        else {
            switch tool {
            case "docker.targets": valid = result["targets"].elements != nil
            case "docker.status": valid = result["available"].bool == true
            case "docker.containers.list": valid = result["containers"].elements != nil
            case "docker.containers.inspect", "docker.networks.create": valid = !(result["id"].string ?? "").isEmpty
            case "docker.images.list": valid = result["images"].elements != nil
            case "docker.volumes.list": valid = result["volumes"].elements != nil
            case "docker.networks.list": valid = result["networks"].elements != nil
            case "docker.compose.list": valid = result["projects"].elements != nil
            case "docker.compose.inspect", "docker.volumes.create": valid = !(result["name"].string ?? "").isEmpty
            case "docker.install.preview": valid = result["command"].string == BackendDockerInstall.command && result["source"].string == BackendDockerInstall.source && result["requiresApproval"].bool == true && result["requiresAdministrator"].bool == true
            case "docker.install": valid = result["ok"].bool == true && result["status"]["available"].bool == true
            default: valid = result["ok"].bool == true
            }
        }
        guard valid else { throw NativeRPCError(code: "unavailable", message: "The Docker operation did not return its required result.") }
    }
}
