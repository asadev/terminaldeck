import Foundation
import TerminalDeckNativeCore

/// Supplied by the existing core composition. Read tools use its real read
/// gate/log. The service's mandatory approval supplier owns the alter effect.
public struct BackendAIRReadinessToolAccess: Sendable {
    public let rpcContext: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public let knownFolder: @Sendable (BackendMCPCallContext, String) async throws -> String
    public let authorizeRead: @Sendable (BackendMCPCallContext, String, NativeRPCValue) async throws -> Void
    public let noteResult: @Sendable (BackendMCPCallContext, NativeRPCValue) async -> Void
    /// Original MCP arguments stay bound to the running core call; the fresh
    /// launch request supplies the concrete sentence shown by that same gate.
    public let authorizeLaunch: @Sendable (BackendMCPCallContext, NativeRPCValue, NativeRPCValue) async throws -> Void
    /// Keep the original credential-resolved core context for trusted session
    /// limits and origin. They must never come from the request JSON.
    public let launchAI: @Sendable (BackendMCPCallContext, NativeRPCContext, NativeRPCValue) async throws -> NativeRPCValue
    public init(rpcContext: @escaping @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext,
                knownFolder: @escaping @Sendable (BackendMCPCallContext, String) async throws -> String,
                authorizeRead: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue) async throws -> Void,
                noteResult: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async -> Void,
                authorizeLaunch: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue, NativeRPCValue) async throws -> Void,
                launchAI: @escaping @Sendable (BackendMCPCallContext, NativeRPCContext, NativeRPCValue) async throws -> NativeRPCValue) {
        self.rpcContext = rpcContext; self.knownFolder = knownFolder
        self.authorizeRead = authorizeRead; self.noteResult = noteResult
        self.authorizeLaunch = authorizeLaunch; self.launchAI = launchAI
    }
}

/// Feed these definitions and metadata into the SAME deck-tools/core catalogue.
/// Do not also register BackendDeckToolsAppSetup's old readiness.scan/fix.
public enum BackendAIRReadinessTools {
    public static let toolIDs: Set<String> = ["readiness.scan", "readiness.list_checks", "readiness.explain", "readiness.preview_fix", "readiness.fix", "readiness.recheck", "readiness.ask_ai"]
    public static func definitions(service: BackendAIRReadinessService,
                                   access: BackendAIRReadinessToolAccess) throws -> [BackendDeckToolsDefinition] {
        struct Row: Sendable { let id: String, title: String, description: String; let required: [String], optional: [String] }
        let rows = [
            Row(id: "readiness.scan", title: "Check AI readiness", description: "Read the existing readiness scan, unfinished checks, per-agent results and progress toward Ready. Read-only.", required: ["projectPath"], optional: []),
            Row(id: "readiness.list_checks", title: "List AI readiness checks", description: "List all project readiness checks and progress, including checks that could not run. Use readiness.explain for plain steps and a ready AI prompt. Read-only.", required: ["projectPath"], optional: []),
            Row(id: "readiness.explain", title: "Explain a readiness check", description: "Explain one readiness check: what is missing, why it matters, exact next steps, whether a safe local fix can be previewed, and an AI prompt. agent selects Claude, Codex or Gemini instructions; shared checks keep the same project scope. Read-only.", required: ["projectPath", "checkId"], optional: ["agent"]),
            Row(id: "readiness.preview_fix", title: "Preview a readiness fix", description: "Create a five-minute, one-use, caller-bound preview of exact added file text for a currently offered safe fix. Does not write or grant consent. Git changes, package scripts, installs and CLI upgrades return clear manual guidance. Existing credential contents are never read or shown.", required: ["projectPath", "checkId"], optional: ["agent"]),
            Row(id: "readiness.fix", title: "Approve and apply a readiness preview", description: "Apply an unused previewId only after the person approves the concrete preview through the existing core alter gate. Requires an alter grant. Rechecks caller, folder grants, check and exact file bytes after approval; then automatically scans again. A fixId or a boolean consent flag grants nothing. The base read tier intentionally defers the alter effect until the concrete preview is available.", required: ["previewId"], optional: []),
            Row(id: "readiness.recheck", title: "Re-check AI readiness", description: "Run the existing project scan again and show actual progress toward Ready. A created draft remains unfinished until its project details and commands are filled in. Read-only.", required: ["projectPath"], optional: []),
            Row(id: "readiness.ask_ai", title: "Ask an AI to complete a readiness check", description: "Open an existing-provider session in this project with a fresh ready prompt for one check, then deliver that prompt through the shared observed brief path. Requires the person's existing alter approval for the exact launch. Does not guess PTY readiness or create a second session owner. The base read tier defers the alter effect until the prompt is available.", required: ["projectPath", "checkId"], optional: ["agent", "provider", "profileId"])
        ]
        return try rows.map { row in
            let keys = row.required + row.optional
            let properties: NativeRPCValue = .object(keys.map { key in
                .init(key, .object([.init("type", .string("string"))]))
            })
            let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", properties),
                .init("required", .array(row.required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            // A base alter tier would ask about the opaque previewId before
            // the handler can retrieve its exact text. The only mutation path
            // below requires .alter and the real service approval supplier.
            let spec = try BackendMCPTool(id: row.id, wireName: row.id.replacingOccurrences(of: ".", with: "_"),
                description: row.description, inputSchema: schema, tier: .read)
            return BackendDeckToolsDefinition(spec: spec, title: row.title, index: row.description) { caller, args in
                await BackendDeckToolsSupport.reply {
                    try await cancellable(caller.cancellation) {
                        guard let fields = args.fields, fields.allSatisfy({ keys.contains($0.key) && $0.value.string != nil }),
                              row.required.allSatisfy({ args[$0].string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
                            throw NativeRPCError.invalidArguments("The readiness tool needs exactly the listed text arguments. Consent flags are not accepted.")
                        }
                        guard caller.allowedTiers.contains(.read), !caller.cancellation.isCancelled else {
                            throw NativeRPCError(code: "access-denied", message: "This caller cannot read readiness checks.")
                        }
                        if ["readiness.fix", "readiness.ask_ai"].contains(row.id), !caller.allowedTiers.contains(.alter) {
                            throw NativeRPCError(code: "access-denied", message: "This caller has no alter grant for this readiness action.")
                        }
                        let rpc = try await access.rpcContext(caller)
                        let value: NativeRPCValue
                        if row.id == "readiness.fix" {
                            let id = try args["previewId"].requireString("preview id", nonempty: true)
                            let preview = try await service.pendingPreview(previewID: id, context: rpc)
                            _ = try await access.knownFolder(caller, preview.projectPath)
                            // No read-effect preparation here: the service
                            // issues the one real alter prepareEffect with the
                            // concrete preview and ownerMustAnswer=true.
                            value = AIRReadinessWire.wire(try await service.fixApproved(previewID: id, context: rpc))
                        } else {
                            let project = try await access.knownFolder(caller, args["projectPath"].requireString("project path", nonempty: true))
                            if row.id != "readiness.ask_ai" { try await access.authorizeRead(caller, row.id, args) }
                            let agent = args["agent"].string
                            switch row.id {
                            case "readiness.scan", "readiness.list_checks", "readiness.recheck":
                                value = AIRReadinessWire.wire(try await service.listChecks(project: project, context: rpc))
                            case "readiness.explain":
                                value = AIRReadinessWire.wire(try await service.explain(project: project,
                                    checkID: args["checkId"].requireString("check id", nonempty: true), agent: agent, context: rpc))
                            case "readiness.preview_fix":
                                value = AIRReadinessWire.wire(try await service.previewFix(project: project,
                                    checkID: args["checkId"].requireString("check id", nonempty: true), agent: agent, context: rpc))
                            case "readiness.ask_ai":
                                let plan = try await service.explain(project: project,
                                    checkID: args["checkId"].requireString("check id", nonempty: true), agent: agent, context: rpc)
                                guard plan.aiPrompt.utf16.count <= BackendDeckCoreBrief.maxBriefChars,
                                      !(args["provider"].string == "shell") else {
                                    throw NativeRPCError.invalidArguments("Choose an AI for a ready prompt of at most 8000 characters.")
                                }
                                for key in ["provider", "profileId"] where args[key] != .missing {
                                    let text = try args[key].requireString(key, nonempty: true)
                                    guard text.utf16.count <= 200,
                                          !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                                        throw NativeRPCError.invalidArguments("\(key) must be printable text of at most 200 characters.")
                                    }
                                }
                                var request: NativeRPCValue = .object([.init("cwd", .string(project)),
                                    .init("firstPrompt", .string(plan.aiPrompt)), .init("title", .string("AI readiness · " + plan.title)),
                                    .init("resume", .bool(false)), .init("cols", .number(100)), .init("rows", .number(30))])
                                if let provider = args["provider"].string { request = request.setting("provider", .string(provider)) }
                                if let profile = args["profileId"].string { request = request.setting("profileId", .string(profile)) }
                                try await access.authorizeLaunch(caller, args, request)
                                try Task.checkCancellation()
                                _ = try await access.knownFolder(caller, project)
                                value = try await access.launchAI(caller, rpc, request)
                            default: throw NativeRPCError(code: "missing-handler", message: "This readiness tool is unavailable.")
                            }
                        }
                        let projectValue = value["projectPath"].isNullish
                            ? (value["report"]["projectPath"].isNullish ? value["cwd"] : value["report"]["projectPath"])
                            : value["projectPath"]
                        var summary: NativeRPCValue = .object([.init("projectPath", projectValue),
                            .init("ok", value["result"]["ok"]), .init("checks", .number(Double(value["checks"].elements?.count ?? value["report"]["checks"].elements?.count ?? 0)))])
                        if row.id == "readiness.ask_ai" {
                            summary = summary.setting("sessionId", value["id"]).setting("promptDelivered", value["promptDelivered"])
                        }
                        await access.noteResult(caller, summary)
                        return BackendMCPToolReply.value(value)
                    }
                }
            }
        }
    }
    private static func cancellable<T: Sendable>(_ cancellation: BackendMCPCancellation,
                                               operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let task = Task { try await operation() }
        let observer = cancellation.observe { task.cancel() }
        defer { cancellation.removeObserver(observer) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
