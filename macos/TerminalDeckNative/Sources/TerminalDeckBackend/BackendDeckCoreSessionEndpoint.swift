import Foundation
import TerminalDeckNativeCore

/// Existing launch/lease callers reach the same deck-control door and gate.
/// This conforms to the existing MCP endpoint protocol instead of launching a
/// second server or maintaining a second set of tools.
public actor BackendDeckCoreSessionEndpoint: BackendMCPToolEndpoint {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private struct Entry: Sendable {
        let tableRegistration: UUID
        let table: BackendDeckCoreSecurityCallerTable
        let grant: BackendMCPCallerGrant
        let cancellation: BackendMCPCancellation
        var sessionID: String?
        var machineID = ""
    }
    private let server: BackendDeckCoreSecurityServer
    private let control: BackendDeckCoreSecurityControl
    private var entries: [UUID: Entry] = [:]
    public init(server: BackendDeckCoreSecurityServer, control: BackendDeckCoreSecurityControl) { self.server = server; self.control = control }
    public func description() async throws -> BackendMCPEndpointDescription? {
        guard let endpoint = await server.currentEndpoint() else { return nil }
        let mode: BackendMCPImplementation = await control.tools().contains { $0.tool.implementation == .suppliedSourceBridge } ? .suppliedSourceBridge : .native
        return try BackendMCPEndpointDescription(url: endpoint.url, implementation: mode)
    }
    public func catalogue() async throws -> [BackendMCPTool] { await control.tools().map(\.tool) }
    public func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration {
        guard let endpoint = await server.currentEndpoint(), token.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !grant.allowedTools.isEmpty else { throw BackendSessionFailure.invalidInput("The session MCP caller is not ready for registration.") }
        let id = UUID(), cancellation = BackendMCPCancellation()
        let registration = try await endpoint.callers.set(token: token, grant: .init(identity: "session:" + id.uuidString, attended: grant.attended,
            tools: grant.allowedTools, cancellation: cancellation, caller: { [weak self] in
                guard let self else { return .init(kind: .session, tiers: []) }
                return await self.caller(id)
            }))
        entries[id] = Entry(tableRegistration: registration, table: endpoint.callers, grant: grant, cancellation: cancellation)
        return .init(id: id)
    }
    private func caller(_ id: UUID) async -> BackendDeckCoreSecurityCaller {
        guard let entry = entries[id], let session = entry.sessionID, !entry.cancellation.isCancelled else { return .init(kind: .session, tiers: []) }
        // session-tools.ts mint caller() (L834-848): `allowed` is asked per call
        // and a withdrawn permission answers a caller that may do nothing
        // (NO_TIERS), so the very next call is refused as a tool result. It does
        // not cancel the token here; dropping the token is the revocation path's
        // job (servers/window-drive.ts → BackendServersWindowDrive drop()).
        let permitted = await entry.grant.permitted()
        guard permitted, let current = entries[id], current.sessionID == session, !current.cancellation.isCancelled else { return .init(kind: .session, tiers: []) }
        return .init(kind: .session, tiers: current.grant.allowedTiers, sessionID: session, machineID: current.machineID,
                     projectRoot: current.grant.projectRoot)
    }
    public func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) throws {
        guard !sessionID.isEmpty, var entry = entries[registration.id], !entry.cancellation.isCancelled else {
            throw BackendSessionFailure.invalidInput("The pending MCP caller expired before its session could bind.")
        }
        entry.sessionID = sessionID; entry.machineID = machineID; entries[registration.id] = entry
    }
    public func revoke(_ registration: BackendMCPRegistration) async {
        guard let entry = entries.removeValue(forKey: registration.id) else { return }
        entry.cancellation.cancel(); _ = await entry.table.revoke(entry.tableRegistration)
    }
    public func revokeAll() async {
        let registrations = entries.keys.map { BackendMCPRegistration(id: $0) }
        for registration in registrations { await revoke(registration) }
    }
}

/// Bridge for contributed BackendMCPTool handlers whose existing context has no
/// key/caller fields. A domain runtime resolves this exact per-call capability;
/// it must not infer ownership from attendance or accept identity from arguments.
public actor BackendDeckCoreToolContextAuthority {
    private var contexts: [ObjectIdentifier: BackendDeckCoreSecurityCallContext] = [:]
    public init() {}
    public func context(for native: BackendMCPCallContext) throws -> BackendDeckCoreSecurityCallContext {
        guard let context = contexts[ObjectIdentifier(native.cancellation)], !context.cancellation.isCancelled else {
            throw BackendSessionFailure.missingCapability("the credential-resolved deck-control call context")
        }
        return context
    }
    public func invoke(handler: BackendNativeMCPServer.Handler, arguments: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) async throws -> BackendMCPToolReply {
        // Direct routine calls may share one parent cancellation. Give each
        // domain invocation its own capability identity while linking its lifetime.
        let scope = BackendMCPCancellation()
        let observer = context.cancellation.observe { scope.cancel() }
        let native = BackendMCPCallContext(sessionID: context.native.sessionID, machineID: context.native.machineID,
            projectRoot: context.native.projectRoot, attended: context.native.attended, allowedTools: context.native.allowedTools,
            allowedTiers: context.native.allowedTiers, cancellation: scope)
        let scoped = BackendDeckCoreSecurityCallContext(native: native, caller: context.caller, callID: context.callID,
            attended: context.attended, granted: context.granted, sessionLimits: context.sessionLimits, now: context.now,
            startedByCopilot: context.startedByCopilot, noteStarted: context.noteStarted)
        let key = ObjectIdentifier(scope)
        contexts[key] = scoped
        defer { scope.cancel(); contexts[key] = nil; context.cancellation.removeObserver(observer) }
        return try await handler(native, arguments)
    }
}
