import Foundation
import TerminalDeckNativeCore

public enum BackendRemoteWorkerCall: Sendable { case app(NativeRPCContext), tool(BackendMCPCallContext) }

/// Who may do what. `configuration` is true for address/credential changes (alter).
public struct BackendRemoteWorkersAccess: Sendable {
    public let verify: @Sendable (BackendRemoteWorkerCall, _ configuration: Bool) async throws -> Void
    public init(verify: @escaping @Sendable (BackendRemoteWorkerCall, Bool) async throws -> Void) { self.verify = verify }
}

/// One operation table, used by the native settings screen (channel) and by the MCP tools,
/// so both reach exactly the same service actions. Nothing here ever returns a token.
public enum BackendRemoteWorkersMCP {
    public static let channel = "remote-workers:perform"
    public static let changedChannel = "remote-workers:changed"

    public struct Operation: Sendable { public let name: String; public let tier: BackendMCPTier; public let configuration: Bool; public let summary: String }
    public static let operations: [Operation] = [
        .init(name: "list", tier: .read, configuration: false, summary: "List remote worker connections and their runs (never shows tokens)."),
        .init(name: "get", tier: .read, configuration: false, summary: "Read one remote run (pass run) or one connection (pass connection)."),
        .init(name: "connection_set", tier: .alter, configuration: true, summary: "Save a remote worker connection: a name and its https address. Pass connection to edit one."),
        .init(name: "connection_remove", tier: .alter, configuration: true, summary: "Remove a remote worker connection that has no runs in progress."),
        .init(name: "credential_set", tier: .alter, configuration: true, summary: "Save a connection's access token in the Keychain (write-only; never shown again)."),
        .init(name: "credential_remove", tier: .alter, configuration: true, summary: "Remove a connection's saved access token."),
        .init(name: "check", tier: .act, configuration: false, summary: "Check the saved connection and read what the worker supports. Starts no run."),
        .init(name: "start", tier: .act, configuration: false, summary: "Start one explicit request on the remote worker. Local terminal sessions are not used."),
        .init(name: "refresh", tier: .act, configuration: false, summary: "Ask the worker for the current state of a run."),
        .init(name: "stop", tier: .act, configuration: false, summary: "Ask the worker to stop a run. Reported as unconfirmed until the worker confirms."),
        .init(name: "resume", tier: .act, configuration: false, summary: "Continue a finished or stopped run with a new message, as a new linked attempt."),
        .init(name: "abandon", tier: .alter, configuration: false, summary: "Give up on a run that can no longer be controlled: it is ended here only. Nothing is sent; the worker may still run it."),
    ]

    public static func schema() throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"connection":{"type":"string"},"run":{"type":"string"},"label":{"type":"string"},"url":{"type":"string"},"agent":{"type":"string"},"token":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"model":{"type":"string"},"workspace":{"type":"string"}},"additionalProperties":false}"#.utf8))
    }

    public static func definitions(service: BackendRemoteWorkers, access: BackendRemoteWorkersAccess) throws -> [BackendDeckToolsDefinition] {
        let schema = try schema()
        return try operations.map { operation in
            let id = "agents.remote_" + operation.name
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: operation.summary, inputSchema: schema, tier: operation.tier)
            return BackendDeckToolsDefinition(spec: spec, title: operation.summary, index: operation.summary) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(operation.tier), BackendMCPToolNames.permits(id, granted: context.allowedTools) || BackendMCPToolNames.permits(spec.wireName, granted: context.allowedTools) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use that remote worker control.")
                    }
                    try await access.verify(.tool(context), operation.configuration)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    return .value(try await perform(operation.name, args: args, service: service))
                }
            }
        }
    }

    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendRemoteWorkers, requireOwnerUI: @escaping NativeChannelRegistry.Policy) async throws {
        try await registry.register(channel, ownerID: ownerID, policy: requireOwnerUI) { context, args in
            let input = context.argument(0, in: args)
            let name = try input["op"].requireString("op")
            guard let operation = operations.first(where: { $0.name == name }) else { throw NativeRPCError.invalidArguments("Unknown remote worker action.") }
            _ = operation
            return try await perform(name, args: input.removing("op"), service: service)
        }
    }

    /// Redacts the token before the central action log sees it.
    public static func safeArguments(_ args: NativeRPCValue) -> NativeRPCValue {
        args.has("token") ? args.setting("token", .string("[hidden]")) : args
    }

    private static func text(_ args: NativeRPCValue, _ key: String) -> String? { args[key].string }
    private static func required(_ args: NativeRPCValue, _ key: String, _ label: String) throws -> String { try args[key].requireString(label, nonempty: true) }

    public static func perform(_ name: String, args: NativeRPCValue, service: BackendRemoteWorkers) async throws -> NativeRPCValue {
        do {
            switch name {
            case "list":
                var connections: [NativeRPCValue] = []
                for connection in await service.connections() { connections.append(await project(connection, service: service)) }
                return .object([.init("connections", .array(connections)), .init("runs", .array(await service.runs().map(project)))])
            case "get":
                if let run = text(args, "run") { return project(try await service.run(run)) }
                if let connection = text(args, "connection") {
                    let value = try await service.connection(connection)
                    return .object([.init("connection", await project(value, service: service)), .init("runs", .array(await service.runs(connection: connection).map(project)))])
                }
                throw NativeRPCError.invalidArguments("Say which run or connection to read.")
            case "connection_set":
                let saved = try await service.saveConnection(id: text(args, "connection"), label: try required(args, "label", "label"), baseURL: try required(args, "url", "url"), profile: text(args, "agent"))
                return await project(saved, service: service)
            case "connection_remove":
                try await service.removeConnection(try required(args, "connection", "connection")); return .object([.init("removed", .bool(true))])
            case "credential_set":
                let id = try required(args, "connection", "connection")
                try await service.setCredential(id, token: try required(args, "token", "token"))
                return .object([.init("credential", .string("saved"))])
            case "credential_remove":
                try await service.removeCredential(try required(args, "connection", "connection")); return .object([.init("credential", .string("none"))])
            case "check":
                let id = try required(args, "connection", "connection")
                let check = try await service.check(id)
                return projectCheck(check)
            case "start":
                return project(try await service.start(connectionID: try required(args, "connection", "connection"), prompt: try required(args, "prompt", "prompt"), model: text(args, "model"), workspace: text(args, "workspace")))
            case "refresh": return project(try await service.refresh(try required(args, "run", "run")))
            case "stop": return project(try await service.stop(try required(args, "run", "run")))
            case "resume": return project(try await service.resume(try required(args, "run", "run"), message: try required(args, "message", "message")))
            case "abandon": return project(try await service.abandon(try required(args, "run", "run")))
            default: throw NativeRPCError.invalidArguments("Unknown remote worker action.")
            }
        } catch let failure as RemoteWorkerFailure { throw NativeRPCError(code: "remote-worker", message: failure.message) }
    }

    // MARK: Safe projections (no tokens, no raw server text beyond bounded result/error)

    private static func date(_ value: Date) -> NativeRPCValue { .string(value.formatted(.iso8601)) }
    private static func optional(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }

    static func projectCheck(_ check: RemoteWorkerCheck) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("at", date(check.at)), .init("ok", .bool(check.ok)), .init("error", optional(check.error))]
        if let caps = check.capabilities {
            fields.append(.init("capabilities", .object([.init("service", .string(caps.service)), .init("start", .bool(caps.start)), .init("status", .bool(caps.status)), .init("stop", .bool(caps.stop)),
                .init("resume", .bool(caps.resume)), .init("tokens", .bool(caps.tokens)), .init("models", .array(caps.models.map(NativeRPCValue.string)))])))
        }
        return .object(fields)
    }

    static func project(_ connection: RemoteWorkerConnection, service: BackendRemoteWorkers) async -> NativeRPCValue {
        .object([.init("id", .string(connection.id)), .init("label", .string(connection.label)), .init("url", .string(connection.baseURL)), .init("agent", optional(connection.profile)),
                 .init("revision", .number(Double(connection.revision))), .init("credential", .string(await service.hasCredential(connection.id) ? "saved" : "none")),
                 .init("check", connection.lastCheck.map(projectCheck) ?? .null)])
    }

    static func project(_ run: RemoteWorkerRun) -> NativeRPCValue {
        let usage: NativeRPCValue
        if let u = run.usage {
            usage = .object([.init("reported", .bool(true)), .init("source", .string("remote_reported")), .init("input", u.input.map { .number(Double($0)) } ?? .null), .init("output", u.output.map { .number(Double($0)) } ?? .null),
                             .init("total", u.shownTotal.map { .number(Double($0)) } ?? .null), .init("revision", .number(Double(u.revision)))])
        } else { usage = .object([.init("reported", .bool(false)), .init("text", .string("Not reported"))]) }
        let active = run.state.isActive
        return .object([.init("id", .string(run.id)), .init("executionKind", .string(run.executionKind)), .init("connection", .string(run.connectionID)), .init("endpoint", .string(run.endpoint)),
            .init("requestId", .string(run.requestID)), .init("remoteRunId", optional(run.remoteID)), .init("title", .string(run.title)), .init("model", optional(run.model)),
            .init("state", .string(run.state.rawValue)), .init("revision", .number(Double(run.revision))), .init("result", optional(run.result)), .init("resultTruncated", .bool(run.resultTruncated)),
            .init("error", optional(run.error)), .init("note", optional(run.note)), .init("tokens", usage), .init("attempt", .number(Double(run.attempt))), .init("previous", optional(run.previous)),
            .init("stopConfirmed", .bool(run.stopConfirmed)), .init("canRefresh", .bool(active)), .init("canStop", .bool(active && run.remoteID != nil)), .init("canAbandon", .bool(active)),
            .init("canResume", .bool(run.state.isTerminal && run.remoteID != nil)), .init("created", date(run.created)), .init("updated", date(run.updated))])
    }
}
