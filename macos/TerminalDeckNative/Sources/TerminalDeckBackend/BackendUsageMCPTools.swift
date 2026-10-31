import Foundation
import TerminalDeckNativeCore

/// Required authenticated scope + actual consent/action-log callbacks. The
/// metrics factories do not create a MCP server, grant table or state store.
public struct BackendUsageToolAccess: Sendable {
    public let rpcContext: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public let authorize: @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void
    public let session: @Sendable (BackendMCPCallContext, String) async throws -> BackendSessionMeta
    public let machineUsage: @Sendable (BackendMCPCallContext) async throws -> Void
    public init(rpcContext: @escaping @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext,
                authorize: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void,
                session: @escaping @Sendable (BackendMCPCallContext, String) async throws -> BackendSessionMeta,
                machineUsage: @escaping @Sendable (BackendMCPCallContext) async throws -> Void) {
        self.rpcContext = rpcContext; self.authorize = authorize; self.session = session; self.machineUsage = machineUsage
    }
}
public enum BackendUsageMCPTools {
    private struct Definition: Sendable { let id: String, wire: String, description: String; let tier: BackendMCPTier; let properties: NativeRPCValue; let required: [String] }
    private static func costDefinition() -> Definition {
        let string = BackendUsageIO.object([("type", .string("string"))]), boolean = BackendUsageIO.object([("type", .string("boolean"))]), integer = BackendUsageIO.object([("type", .string("integer"))])
        return Definition(id: "usage.cost", wire: "usage_cost", description: "Token classes, requests and context use for an open project or one session record. Use summaryOnly for a quick cached project summary; partial totals are labelled and no full record list is read. Carries no inferred subscription price.", tier: .read, properties: BackendUsageIO.object([("projectPath", string), ("transcriptPath", string), ("limit", integer), ("summaryOnly", boolean)]), required: ["projectPath"])
    }
    /// The composition and focused tests register this same real read tool.
    /// No account process, session manager or AI call is needed for a summary.
    public static func costTool(cost: BackendCostService, projects: BackendProjectService, access: BackendUsageToolAccess) throws -> (tool: BackendMCPTool, handler: BackendNativeMCPServer.Handler) {
        let definition = costDefinition()
        let schema = BackendUsageIO.object([("type", .string("object")), ("properties", definition.properties), ("required", .array(definition.required.map(NativeRPCValue.string))), ("additionalProperties", .bool(false))])
        let spec = try BackendMCPTool(id: definition.id, wireName: definition.wire, description: definition.description, inputSchema: schema, tier: .read)
        return (spec, { caller, args in
            _ = try args.requireObject("metrics arguments")
            guard caller.allowedTiers.contains(.read), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "access-denied", message: "This caller cannot read Usage.") }
            let rpc = try await access.rpcContext(caller)
            try await access.authorize(caller, "usage.cost", args, .read)
            return try await cancellable(caller.cancellation) {
                let cwd = try await projects.requireKnown(args["projectPath"].requireString("project path", nonempty: true), restrictedTo: caller.projectRoot)
                if args["summaryOnly"].bool == true {
                    guard args["transcriptPath"].isNullish else { throw NativeRPCError.invalidArguments("Choose a quick project summary or an exact session record, not both.") }
                    return BackendMCPToolReply.value(BackendUsageIO.object([("project", try await cost.project(cwd, context: rpc, cancellation: caller.cancellation)),
                        ("transcriptsIncluded", .bool(false)), ("totalTranscripts", .null)]))
                }
                let files = try await cost.files(project: cwd, context: rpc)
                if let wanted = args["transcriptPath"].string {
                    guard let file = files.first(where: { NativeTranscriptPaths.canonical($0.path) == NativeTranscriptPaths.canonical(wanted) }) else { throw NativeRPCError(code: "access-denied", message: "That transcript does not belong to the named project.") }
                    return BackendMCPToolReply.value(BackendUsageIO.object([("session", try await cost.session(path: file.path, context: rpc, cancellation: caller.cancellation).summary)]))
                }
                let limit = try BackendUsageIO.integer(args["limit"], fallback: 20, range: 1...100)
                return BackendMCPToolReply.value(BackendUsageIO.object([("project", try await cost.project(cwd, context: rpc, cancellation: caller.cancellation)),
                    ("transcripts", .array(try files.prefix(limit).map { try NativeRPCValue.fromFoundation($0.wireValue) })), ("totalTranscripts", .number(Double(files.count)))]))
            }
        })
    }
    public static func register(server: BackendNativeMCPServer, usage: BackendUsageService, cost: BackendCostService,
                                alerts: BackendAlertsService,
                                readiness: BackendReadinessService, projects: BackendProjectService, access: BackendUsageToolAccess) async throws -> [String] {
        let string = BackendUsageIO.object([("type", .string("string"))]), boolean = BackendUsageIO.object([("type", .string("boolean"))]), integer = BackendUsageIO.object([("type", .string("integer"))])
        let definitions = [
            Definition(id: "usage.read", wire: "usage_read", description: "Reported account plan limits and context use. Omit sessionId for every permitted login; unknown figures remain missing.", tier: .read, properties: BackendUsageIO.object([("sessionId", string)]), required: []),
            Definition(id: "usage.refresh", wire: "usage_refresh", description: "Refresh one session's Claude account limits from cache or a short get_usage control-protocol process. Does not type into the terminal.", tier: .act, properties: BackendUsageIO.object([("sessionId", string), ("force", boolean)]), required: ["sessionId"]),
            costDefinition(),
            Definition(id: "alerts.list", wire: "alerts_list", description: "Evidence-based project alerts: blocked live sessions, context, repetitive tool outcomes, unusual token totals and uncommitted work. Includes missing-input coverage.", tier: .read, properties: BackendUsageIO.object([("projectPath", string)]), required: ["projectPath"])
        ]
        for definition in definitions {
            if definition.id == "usage.cost" {
                let cost = try costTool(cost: cost, projects: projects, access: access)
                try await server.registerTool(cost.tool, handler: cost.handler)
                continue
            }
            let schema = BackendUsageIO.object([("type", .string("object")), ("properties", definition.properties), ("required", .array(definition.required.map(NativeRPCValue.string))), ("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: definition.id, wireName: definition.wire, description: definition.description, inputSchema: schema, tier: definition.tier)
            try await server.registerTool(spec) { caller, args in
                _ = try args.requireObject("metrics arguments")
                guard caller.allowedTiers.contains(definition.tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "access-denied", message: "This caller cannot use the requested metrics tool tier.") }
                let rpc = try await access.rpcContext(caller)
                try await access.authorize(caller, definition.id, args, definition.tier)
                return try await cancellable(caller.cancellation) {
                    let value: NativeRPCValue
                    switch definition.id {
                    case "usage.read":
                        if let id = args["sessionId"].string {
                            let session = try await access.session(caller, id)
                            let limits = try await usage.read(sessionID: session.id), contextWindow = try await usage.contextWindow(sessionID: session.id, context: rpc)
                            value = BackendUsageIO.object([("sessionId", .string(session.id)), ("limits", limits.wireValue), ("contextWindow", contextWindow)])
                        } else { try await access.machineUsage(caller); value = BackendUsageIO.object([("limits", try await usage.read(sessionID: nil).wireValue)]) }
                    case "usage.refresh":
                        let session = try await access.session(caller, args["sessionId"].requireString("session id", nonempty: true)); value = try await usage.refresh(sessionID: session.id, force: args["force"].bool == true, cancellation: caller.cancellation).wireValue
                    case "alerts.list":
                        let cwd = try await projects.requireKnown(args["projectPath"].requireString("project path", nonempty: true), restrictedTo: caller.projectRoot); value = try await alerts.project(cwd, context: rpc, cancellation: caller.cancellation)
                    default: throw BackendSessionFailure.unsupported("The metrics tool is unsupported.")
                    }
                    return .value(value)
                }
            }
        }
        return definitions.map(\.id)
    }
    private static func cancellable<T: Sendable>(_ cancellation: BackendMCPCancellation, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if cancellation.isCancelled { throw CancellationError() }
        let work = Task { try await operation() }, id = cancellation.observe { work.cancel() }
        defer { cancellation.removeObserver(id) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
