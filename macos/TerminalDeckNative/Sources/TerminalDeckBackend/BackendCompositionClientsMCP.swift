import Foundation
import TerminalDeckNativeCore

/// The credential/caller owner rechecks its live key/device/session/Hoot grant.
/// The native projection must carry that same identity into the real filesystem
/// scope provider; a key, guest or worker cannot become an app-owned caller.
public protocol BackendCompositionClientsMCPContextAuthority: Sendable {
    func revalidate(_ context: BackendDeckCoreSecurityCallContext, tool: String) async throws
    func filesystemContext(_ context: BackendDeckCoreSecurityCallContext) async throws -> NativeRPCContext
}

/// Real third-party MCP configuration operations over the retained client graph.
/// The source protocol omits context from operations, so policies() wraps the
/// source policies in one task-local call capability instead of inventing a UI
/// caller or storing a global "current caller" that concurrent calls could steal.
public struct BackendCompositionClientsMCPProvider: BackendDeckCoreEventsMCPProvider, Sendable {
    private struct Invocation: Sendable {
        let providerID: UUID
        let tool: String
        let context: BackendDeckCoreSecurityCallContext
    }
    private enum CallScope {
        @TaskLocal static var invocation: Invocation?
    }
    private let id = UUID()
    private let service: BackendMcpClientService
    private let surface: any BackendDeckCoreCatalogueSurface
    private let filesystem: BackendFilesystemAuthority
    private let authority: any BackendCompositionClientsMCPContextAuthority
    public init(service: BackendMcpClientService, surface: any BackendDeckCoreCatalogueSurface,
                filesystem: BackendFilesystemAuthority, authority: any BackendCompositionClientsMCPContextAuthority) {
        self.service = service; self.surface = surface; self.filesystem = filesystem; self.authority = authority
    }

    /// Supply these policies to the central control gate. Its summary, audience,
    /// redaction, consent tier, budget and logging contract remain unchanged.
    public func policies() throws -> [BackendDeckCoreSecurityToolPolicy] {
        try BackendDeckCoreEventsTools.mcpPolicies(provider: self).map { original in
            let providerID = id, tool = original.tool.id, authority = authority
            let scopedPrecheck: (@Sendable (NativeRPCValue, BackendDeckCoreSecurityCallContext) throws -> Void)?
            if let check = original.precheck {
                scopedPrecheck = { arguments, context in
                    try CallScope.$invocation.withValue(.init(providerID: providerID, tool: tool, context: context)) {
                        try check(arguments, context)
                    }
                }
            } else { scopedPrecheck = nil }
            return BackendDeckCoreSecurityToolPolicy(tool: original.tool, aliases: original.aliases, audience: original.audience,
                keyRequiresTasks: original.keyRequiresTasks, spendsDeviceInput: original.spendsDeviceInput,
                summary: original.summary, precheck: scopedPrecheck,
                precheckAsync: { arguments, context in
                    try await CallScope.$invocation.withValue(.init(providerID: providerID, tool: tool, context: context)) {
                        try await authority.revalidate(context, tool: tool)
                        try await original.precheckAsync?(arguments, context)
                    }
                }, escalate: original.escalate,
                ownerMustAnswer: original.ownerMustAnswer, redactArgs: original.redactArgs,
                run: { arguments, context in
                    try await CallScope.$invocation.withValue(.init(providerID: providerID, tool: tool, context: context)) {
                        try await BackendKnowledgeMCP.cancellable(context.cancellation) {
                            try await authority.revalidate(context, tool: tool)
                            return try await original.run(arguments, context)
                        }
                    }
                })
        }
    }

    public func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String {
        let call = try invocation()
        guard call.context.callID == context.callID, call.context.cancellation === context.cancellation else {
            throw NativeRPCError(code: "access-denied", message: "The MCP project request has no matching authenticated call context.")
        }
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        let known = try BackendDeckCoreCatalogueBuiltins.requireKnownFolder(surface, path: path)
        let target = try BackendFilesystemAuthority.canonical(URL(fileURLWithPath: known))
        let roots: [String]?
        switch context.caller.kind {
        case .local: roots = nil
        case .key: roots = context.caller.folders
        case .remote:
            guard let device = context.caller.deviceID, !device.isEmpty, let granted = surface.deviceFolders(device) else {
                throw BackendDeckCoreSecurityRefusal(.notPermitted, "This device has no current folder grant on this computer.")
            }
            roots = granted
        case .session:
            guard (context.caller.machineID ?? "").isEmpty, let root = context.caller.projectRoot, !root.isEmpty else {
                throw BackendDeckCoreSecurityRefusal(.notPermitted, "This session has no current local project grant for MCP configuration.")
            }
            roots = [root]
        }
        if let roots {
            guard roots.contains(where: { root in
                guard root.hasPrefix("/"), let real = try? BackendFilesystemAuthority.canonical(URL(fileURLWithPath: root)) else { return false }
                return BackendFilesystemAuthority.within(target, real)
            }) else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "The MCP project is outside this caller’s current folder grant.") }
        }
        return known
    }

    public func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue { try BackendMcpClientCommands.validateAdd(request) }
    public func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue { try BackendMcpClientCommands.validateRemove(request) }
    /// The original edit resolver is kept here because the writer currently
    /// exposes it only inside edit(). No configuration is read or mutated.
    public func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue {
        guard request.fields != nil || request.elements != nil else { throw BackendMcpClientValue.error("Nothing to change.") }
        let name = BackendMcpClientValue.text(request["name"])
        guard !name.isEmpty else { throw BackendMcpClientValue.error("Name the server to change.") }
        guard let scope = request["scope"].string, McpAddScope(rawValue: scope) != nil else { throw BackendMcpClientValue.error("Say which scope the server is in.") }
        let next = try BackendMcpClientCommands.validateAdd(request["next"]), project = next["projectPath"]
        if scope != "user", project.isNullish { throw BackendMcpClientValue.error("Open the project this server belongs to first.") }
        return .object([.init("name", .string(name)), .init("scope", .string(scope)), .init("projectPath", project), .init("next", next)])
    }
    /// Source mcp-store.ts resolveInstall: optional strings only, default user
    /// scope, and trimmed supplied values. Catalogue/runtime checks stay in the
    /// real store actor immediately before the actual CLI-owned mutation.
    public func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue {
        guard request.fields != nil || request.elements != nil else { throw BackendMcpClientValue.error("Nothing to install.") }
        guard let id = request["id"].string, !id.isEmpty else { throw BackendMcpClientValue.error("Nothing to install.") }
        let scope = ["project", "local"].contains(request["scope"].string ?? "") ? request["scope"].string! : "user"
        let project = request["projectPath"].string.flatMap { $0.isEmpty ? nil : $0 }
        let values = NativeRPCValue.object((request["values"].fields ?? []).compactMap { field in
            guard let value = field.value.string else { return nil }
            return .init(field.key, .string(BackendMcpClientValue.text(.string(value))))
        })
        return .object([.init("id", .string(id)), .init("scope", .string(scope)), .init("projectPath", BackendMcpClientValue.optional(project)), .init("values", values)])
    }

    private func invocation(tool: String? = nil) throws -> Invocation {
        guard let call = CallScope.invocation, call.providerID == id, tool == nil || call.tool == tool,
              !call.context.cancellation.isCancelled else {
            throw BackendSessionFailure.missingCapability("the authenticated MCP configuration policy call context")
        }
        return call
    }
    private func checked(tool: String, projectPath: String?, intent: BackendFilesystemAuthority.Intent = .read) async throws {
        let call = try invocation(tool: tool)
        try await authority.revalidate(call.context, tool: tool)
        if let projectPath {
            let path = try knownFolder(projectPath, context: call.context)
            let native = try await authority.filesystemContext(call.context)
            guard native.caller != .nativeApp,
                  call.context.caller.kind == .local || native.caller != .internalEngine else {
                throw NativeRPCError(code: "access-denied", message: "An authenticated MCP caller cannot impersonate the app’s own window or owner engine.")
            }
            _ = try await filesystem.authorize(path, context: native, intent: intent)
            // Neither a removed grant during path resolution nor a cancelled
            // question can become a retained permission for a later operation.
            try await authority.revalidate(call.context, tool: tool)
        }
        guard !call.context.cancellation.isCancelled else { throw CancellationError() }
    }
    public func list(projectPath: String?) async throws -> [NativeRPCValue] {
        try await checked(tool: "mcp.list", projectPath: projectPath)
        return try await service.list(BackendMcpClientValue.optional(projectPath)).requireArray("MCP servers")
    }
    public func add(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        let resolved = try resolveAdd(request)
        try await checked(tool: "mcp.add", projectPath: resolved["projectPath"].string, intent: .write)
        return await service.writer.add(resolved)
    }
    public func edit(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        let resolved = try resolveEdit(request)
        try await checked(tool: "mcp.edit", projectPath: resolved["projectPath"].string, intent: .write)
        return await service.writer.edit(resolved)
    }
    public func remove(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        let resolved = try resolveRemove(request)
        try await checked(tool: "mcp.remove", projectPath: resolved["projectPath"].string, intent: .write)
        return await service.writer.remove(resolved)
    }
    public func inventory(id: String, projectPath: String?) async throws -> NativeRPCValue {
        try await checked(tool: "mcp.connect", projectPath: projectPath)
        return try await service.inventory(.string(id), project: BackendMcpClientValue.optional(projectPath))
    }
    public func disconnect(id: String) async throws -> NativeRPCValue? {
        try await checked(tool: "mcp.disconnect", projectPath: nil)
        let value = try await service.disconnect(.string(id)); return value.isNullish ? nil : value
    }
    public func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async throws -> NativeRPCValue {
        try await checked(tool: "mcp.call", projectPath: projectPath)
        return try await service.call(.string(id), name: .string(tool), arguments: arguments, project: BackendMcpClientValue.optional(projectPath))
    }
    public func store(projectPath: String?) async throws -> NativeRPCValue {
        try await checked(tool: "mcp.store", projectPath: projectPath)
        return await service.store.view(project: projectPath)
    }
    public func install(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        let resolved = try resolveInstall(request)
        try await checked(tool: "mcp.install", projectPath: resolved["projectPath"].string, intent: .write)
        return await service.store.install(resolved)
    }
    public func toolFile(name: String, scope: String, projectPath: String?) async throws -> NativeRPCValue? {
        try await checked(tool: "mcp.export", projectPath: projectPath)
        return try await service.toolFile(name: .string(name), scope: .string(scope), project: BackendMcpClientValue.optional(projectPath))
    }
}

public extension BackendCompositionClients {
    nonisolated func mcpProvider(surface: any BackendDeckCoreCatalogueSurface, filesystem: BackendFilesystemAuthority,
                                authority: any BackendCompositionClientsMCPContextAuthority) throws -> BackendCompositionClientsMCPProvider {
        guard let mcpClients else { throw BackendSessionFailure.missingCapability("the retained native MCP client graph") }
        return BackendCompositionClientsMCPProvider(service: mcpClients, surface: surface, filesystem: filesystem, authority: authority)
    }
}
