import Foundation
import TerminalDeckNativeCore

/// Agents and Hoot enter the same Apps channels as the native page. The
/// composition supplies the one existing consent gate and authenticated scope.
public enum BackendAppsMCP {
    public typealias Definition = BackendAppsMCPCatalogue.Definition

    public static func definitions() -> [Definition] { BackendAppsMCPCatalogue.definitions() }
    public static func specifications() throws -> [BackendMCPTool] { try definitions().map { try $0.specification() } }
    public static func isDestructive(tool: String) -> Bool { definition(tool)?.destructive == true }

    public static func validate(tool: String, arguments: NativeRPCValue) throws {
        guard let entry = definition(tool) else { throw unavailable("This app tool is unavailable.") }
        try BackendDockerMCPArguments.validate(arguments, schema: entry.inputSchema)
        if entry.id == "apps.backups.policy", arguments.has("upload") {
            try BackendAppsDataTools.validateBackupUpload(arguments["upload"])
        }
        if entry.id == "apps.backups.policy", arguments["enabled"].bool == true {
            guard arguments.has("schedule"), arguments.has("retention") else {
                throw NativeRPCError.invalidArguments("Enabled scheduled backups need both schedule and retention.")
            }
        }
        for key in ["env", "set"] where arguments.has(key) {
            let environment = try BackendAppsValidation.environment(arguments[key])
            guard !environment.values.contains(where: { ["••••••••", "••••••", "[redacted]"].contains($0) }) else {
                throw NativeRPCError.invalidArguments("Masked settings cannot be used as real values. Leave them unchanged.")
            }
        }
        for field in ["appId", "targetAppId"] {
            guard let appID = arguments[field].string else { continue }
            let bytes = Array(appID.utf8)
            guard (1...48).contains(bytes.count), let first = bytes.first, (97...122).contains(first),
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw NativeRPCError.invalidArguments("\(field) must be a lowercase app name of 1 to 48 letters, digits or hyphens, starting with a letter.")
            }
        }
        if entry.id == "apps.databases.bind" {
            guard arguments["appId"] != arguments["targetAppId"] else {
                throw NativeRPCError.invalidArguments("Choose an ordinary target app distinct from the database.")
            }
            if let key = arguments["key"].string {
                let bytes = Array(key.utf8)
                func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
                guard (1...128).contains(bytes.count), bytes.first.map(letter) == true,
                      bytes.allSatisfy({ letter($0) || (48...57).contains($0) }) else {
                    throw NativeRPCError.invalidArguments("key must be a valid setting name of letters, digits and underscores, starting with a letter or underscore.")
                }
            }
        }
        for key in ["serverId", "name", "confirmation", "deploymentId", "backupId", "streamId", "templateId", "domain", "schedule"] {
            if let text = arguments[key].string, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw NativeRPCError.invalidArguments("\(key) must not be blank.")
            }
        }
    }

    /// Plain approval text, deliberately excluding env values and upload keys.
    /// The exact destructive target is the confirmation name, checked against
    /// apps:read before authorize is called and again by the engine.
    public static func summary(tool: String, arguments: NativeRPCValue) -> String {
        guard let entry = definition(tool) else { return "Use an unavailable app tool." }
        let server = arguments["serverId"].string ?? "connected server"
        let name = entry.destructive ? arguments["confirmation"].string : arguments["name"].string
        let target = name.map { "app \"\($0)\"" } ?? arguments["appId"].string.map { "app \"\($0)\"" } ?? "the server"
        let action: String
        switch entry.id {
        case "apps.create": action = "Create \(target) from its GitHub repository"
        case "apps.deploy": action = "Deploy \(target)"
        case "apps.rollback": action = "Roll back \(target) to deployment \"\(arguments["deploymentId"].string ?? "")\""
        case "apps.restart": action = "Restart \(target)"
        case "apps.remove": action = "Remove \(target)"
        case "apps.env.apply": action = "Replace all settings for \(target)"
        case "apps.env.patch": action = "Change or remove selected settings for \(target), keeping untouched values"
        case "apps.domains.apply": action = "Set the addresses for \(target)"
        case "apps.caddy.install": action = "Install automatic HTTPS"
        case "apps.databases.create": action = "Create \(target) as a \(arguments["kind"].string ?? "database") database"
        case "apps.databases.bind":
            let destination = arguments["targetAppId"].string ?? ""
            let setting = arguments["key"].string.map { "setting \"\($0)\"" } ?? "the default database setting"
            action = "Connect database \(target) to app \"\(destination)\" and replace \(setting); deploy the target app afterward to apply it"
        case "apps.backups.create": action = "Create a backup of \(target)"
        case "apps.backups.policy": action = arguments["enabled"].bool == true ? "Enable scheduled backups and set retention and upload settings for \(target)" : "Disable scheduled backups for \(target)"
        case "apps.backups.restore": action = "Restore backup \"\(arguments["backupId"].string ?? "")\" over the current data in \(target)"
        case "apps.templates.deploy": action = "Create \(target) from template \"\(arguments["templateId"].string ?? "")\""
        case "apps.auto-deploy.apply": action = "\(arguments["enabled"].bool == true ? "Enable" : "Disable") automatic deployment for \(target)"
        default: action = "Read \(target)"
        }
        return BackendDockerMCPMasker.text(action + " on server \"\(server)\".", extraSecrets: BackendDockerMCPMasker.secrets(in: arguments))
    }

    public static func register(server: BackendNativeMCPServer, registry: NativeChannelRegistry,
                                access: BackendDockerMCPAccess) async throws -> [String] {
        let entries = try contribution(registry: registry, access: access)
        try await server.replaceTools(ownerID: "native-apps-mcp", tools: entries)
        return entries.map { $0.0.id }
    }

    public static func contribution(registry: NativeChannelRegistry, access: BackendDockerMCPAccess,
                                    logWindowMilliseconds: Int = 5_000) throws
        -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        try definitions().map { entry in
            let spec = try entry.specification()
            let handler: BackendNativeMCPServer.Handler = { caller, arguments in
                do {
                    try checkCancellation(caller)
                    guard caller.allowedTiers.contains(entry.tier) else {
                        throw NativeRPCError(code: "access-denied", message: "This caller cannot perform this app action.")
                    }
                    try validate(tool: entry.id, arguments: arguments)
                    if entry.id == "apps.logs.unwatch" {
                        return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string("AI live-log reads close their streams before returning; there is no active call-owned stream to stop."))])],
                                                   structuredContent: .object([.init("error", .object([.init("code", .string("unavailable")), .init("message", .string("No active call-owned log stream remains."))]))]), isError: true)
                    }
                    guard await registry.has(entry.channel) else { throw unavailable("The requested app operation is unavailable on this server.") }
                    var inspectionContext: NativeRPCContext?
                    if entry.destructive {
                        let rpc = try await access.rpcContext(caller)
                        inspectionContext = rpc
                        try checkCancellation(caller)
                        guard await registry.has("apps:read") else { throw unavailable("The app name cannot be checked because app details are unavailable.") }
                        let record = try await registry.invoke("apps:read", context: rpc, arguments: [identity(arguments)])
                        guard let name = record["name"].string, !name.isEmpty else { throw unavailable("The app's exact name is unavailable; removal or restore is blocked.") }
                        guard arguments["confirmation"].string == name else {
                            throw NativeRPCError(code: "confirmation-required", message: "Type the app's exact name to confirm this action.")
                        }
                    }
                    if entry.tier != .read {
                        try await access.authorize(caller, entry.id, BackendDockerMCPMasker.arguments(arguments), entry.tier,
                                                   summary(tool: entry.id, arguments: arguments), entry.destructive)
                    }
                    try checkCancellation(caller)
                    // An inspected destructive target keeps its existing
                    // ticket, updated by authorize. Other mutations project
                    // their authenticated RPC scope after receiving approval.
                    let rpc: NativeRPCContext
                    if let inspectionContext { rpc = inspectionContext }
                    else { rpc = try await access.rpcContext(caller) }
                    try checkCancellation(caller)
                    let value: NativeRPCValue
                    if entry.id == "apps.logs.watch" {
                        value = try await BackendAppsMCPLogRead.read(registry: registry, context: rpc, caller: caller,
                                                                   arguments: arguments, windowMilliseconds: logWindowMilliseconds)
                    } else {
                        value = try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                            try await registry.invoke(entry.channel, context: rpc, arguments: [arguments])
                        }
                    }
                    try checkCancellation(caller)
                    guard value.elements != nil || value.fields?.isEmpty == false else {
                        throw unavailable("The app operation returned no contract result.")
                    }
                    let masked = BackendDockerMCPMasker.value(value, extraSecrets: BackendDockerMCPMasker.secrets(in: arguments))
                    await access.noteResult(caller, masked)
                    if entry.id == "apps.logs.watch", masked["failed"].bool == true {
                        return BackendMCPToolReply(content: BackendMCPToolReply.value(masked).content,
                                                   structuredContent: masked, isError: true)
                    }
                    return .value(masked)
                } catch {
                    return failure(error)
                }
            }
            return (spec, handler)
        }
    }

    private static func definition(_ tool: String) -> Definition? { definitions().first { $0.id == tool || $0.wireName == tool } }
    private static func identity(_ arguments: NativeRPCValue) -> NativeRPCValue {
        .object([.init("serverId", arguments["serverId"]), .init("appId", arguments["appId"])])
    }
    private static func checkCancellation(_ caller: BackendMCPCallContext) throws {
        try Task.checkCancellation()
        guard !caller.cancellation.isCancelled else { throw CancellationError() }
    }
    private static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
    private static func failure(_ error: Error) -> BackendMCPToolReply {
        let code: String
        let message: String
        if error is CancellationError { code = "cancelled"; message = "The app request was cancelled." }
        else if let rpc = error as? NativeRPCError {
            code = safeCodes.contains(rpc.code) ? rpc.code : "unavailable"
            // Even an invalid-arguments message from a dependency may contain
            // server stderr or previously stored secrets. Keep errors local.
            message = failureMessage(code)
        } else { code = "unavailable"; message = "The app operation is unavailable." }
        let value = NativeRPCValue.object([.init("code", .string(code)), .init("message", .string(message))])
        return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(message))])],
                                   structuredContent: .object([.init("error", value)]), isError: true)
    }
    private static let safeCodes: Set<String> = ["invalid-arguments", "not-found", "unavailable", "access-denied", "approval-required", "confirmation-required", "conflict", "busy", "build-failed", "health-failed", "route-failed", "state-failed", "backup-failed", "restore-failed", "dns-mismatch", "cancelled"]
    private static func failureMessage(_ code: String) -> String {
        switch code {
        case "invalid-arguments": "The app request has invalid or unexpected arguments. Check the tool's input fields."
        case "confirmation-required": "Type the app's exact name to confirm this action."
        case "not-found": "The app or requested record was not found."
        case "access-denied": "This caller cannot access this app action."
        case "approval-required": "The person's approval is required before this app action can run."
        case "conflict", "busy": "The app is busy or its saved state changed. Read its current state and try again."
        case "build-failed": "The app build failed. Check the masked app logs."
        case "health-failed": "The new deployment did not pass its health check."
        case "route-failed": "The app address could not be updated."
        case "state-failed": "The app state could not be saved."
        case "backup-failed": "The backup did not complete."
        case "restore-failed": "The backup restore did not complete."
        case "dns-mismatch": "The address does not point to this server. Read the DNS instructions and check again."
        case "cancelled": "The app request was cancelled."
        default: "The requested app operation is unavailable."
        }
    }
}
