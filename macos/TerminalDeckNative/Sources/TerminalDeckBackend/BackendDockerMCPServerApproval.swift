import Foundation
import TerminalDeckNativeCore

/// One approval adapter for both engines. The native window uses the existing
/// consent broker; an MCP invocation must carry the core's accepted receipt.
/// There is no payload flag, standing server grant or default allow path.
public struct BackendDockerMCPServerApproval: Sendable {
    private let authority: BackendCompositionAuthority
    private let consent: BackendDeckCoreSecurityConsentBroker
    private let knownServer: @Sendable (String) async throws -> Bool
    public init(authority: BackendCompositionAuthority, consent: BackendDeckCoreSecurityConsentBroker,
                knownServer: @escaping @Sendable (String) async throws -> Bool) {
        self.authority = authority; self.consent = consent; self.knownServer = knownServer
    }

    /// Called by the actual core policy before consent, and again at dispatch.
    public func checkScope(caller: BackendDeckCoreSecurityCaller, target: String?) async throws {
        guard caller.kind != .remote, caller.machineID?.isEmpty != false else {
            throw NativeRPCError(code: "access-denied", message: "This caller cannot use the Mac's saved server connections.")
        }
        if caller.kind == .key, caller.folders != nil {
            throw NativeRPCError(code: "access-denied", message: "A folder-scoped key has no saved-server grant.")
        }
        if let target, !target.isEmpty, target != "local", !(try await knownServer(target)) {
            throw NativeRPCError(code: "access-denied", message: "That server is not saved in this app.")
        }
    }

    public func authorize(context: NativeRPCContext, channel: String, target: String?,
                          changing: Bool, summary: String, arguments: NativeRPCValue) async throws {
        try Task.checkCancellation()
        if let target, target != "local" {
            guard try await knownServer(target) else {
                throw NativeRPCError(code: "access-denied", message: "That server is not saved in this app.")
            }
        }
        if context.caller == .nativeApp {
            try authority.requireLocalUI(context)
            guard changing else { return }
            let cancellation = BackendMCPCancellation()
            let outcome = await withTaskCancellationHandler {
                await consent.request(tool: channel, tier: .alter,
                    summary: BackendDockerMCPMasker.text(summary),
                    arguments: BackendDockerMCPMasker.arguments(arguments),
                    cancellation: cancellation, origin: "window")
            } onCancel: { cancellation.cancel() }
            try Task.checkCancellation()
            try authority.requireLocalUI(context)
            guard outcome.granted else {
                throw NativeRPCError(code: "approval-required", message: "The person did not approve this server change.")
            }
            // Consent can remain open while the person removes this server.
            // Recheck the saved target and window after the awaited answer;
            // that answer must never authorize a now-revoked connection.
            if let target, target != "local", !(try await knownServer(target)) {
                throw NativeRPCError(code: "access-denied", message: "That server is not saved in this app.")
            }
            try Task.checkCancellation()
            try authority.requireLocalUI(context)
            return
        }
        // Resolve the actual core caller again at dispatch, never project it
        // into the Mac owner's identity or allow a paired caller to hop servers.
        try authority.authorizeMetadata(context)
        let caller = try await authority.rpcCaller(context)
        try await checkScope(caller: caller, target: target)
        if changing { try authority.authorizeMutation(context) }
        try Task.checkCancellation()
    }
}
