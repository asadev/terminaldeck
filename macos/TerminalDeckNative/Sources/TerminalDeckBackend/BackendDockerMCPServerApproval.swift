import Foundation
import TerminalDeckNativeCore

/// One approval adapter for both engines. The native window uses the existing
/// consent broker; an MCP invocation must carry the core's accepted receipt.
/// There is no payload flag, standing server grant or default allow path.
public struct BackendDockerMCPServerApproval: Sendable {
    private let authority: BackendCompositionAuthority
    private let consent: BackendDeckCoreSecurityConsentBroker
    private let knownServer: @Sendable (String) async throws -> Bool
    private let keyAllowed: @Sendable (String, String) async throws -> Bool
    private let lookOnly: @Sendable (String) async throws -> Bool
    private let enforceKeyScope: Bool
    public static let lookOnlyRefusal = BackendServersCoordinator.lookOnlyRefusal
    public init(authority: BackendCompositionAuthority, consent: BackendDeckCoreSecurityConsentBroker,
                knownServer: @escaping @Sendable (String) async throws -> Bool,
                keyAllowed: @escaping @Sendable (String, String) async throws -> Bool = { _, _ in false },
                lookOnly: @escaping @Sendable (String) async throws -> Bool = { _ in false },
                enforceKeyScope: Bool = BackendDockerMCPServerKeyScope.enabled) {
        self.authority = authority; self.consent = consent; self.knownServer = knownServer
        self.keyAllowed = keyAllowed; self.lookOnly = lookOnly
        self.enforceKeyScope = enforceKeyScope
    }

    /// Called by the actual core policy before consent, and again at dispatch.
    /// A look-only server refuses every change, from every caller, before
    /// anyone is asked to approve it.
    public func checkLookOnly(target: String?, changing: Bool) async throws {
        try await Self.refuseIfLookOnly(target: target, changing: changing, lookOnly: lookOnly)
    }
    /// The one Look only rule, shared by the approval adapter and the live proof.
    public static func refuseIfLookOnly(target: String?, changing: Bool,
                                        lookOnly: @Sendable (String) async throws -> Bool) async throws {
        guard changing, let target, !target.isEmpty, target != "local", try await lookOnly(target) else { return }
        throw NativeRPCError(code: "look-only", message: lookOnlyRefusal)
    }
    /// IOS2: the owner's own paired phone may READ Docker (its read-only Docker page; the
    /// panel itself is owner-device only). Every change still refuses every phone.
    public static func ownerPhoneRead(_ caller: BackendDeckCoreSecurityCaller, changing: Bool) -> Bool {
        !changing && caller.kind == .remote && caller.deviceID?.isEmpty == false && caller.machineID?.isEmpty != false
            && caller.tiers.contains(.read)
    }
    public func checkScope(caller: BackendDeckCoreSecurityCaller, target: String?, changing: Bool = false) async throws {
        try await checkLookOnly(target: target, changing: changing)
        if Self.ownerPhoneRead(caller, changing: changing) {
            if let target, !target.isEmpty, target != "local", !(try await knownServer(target)) {
                throw NativeRPCError(code: "access-denied", message: "That server is not saved in this app.")
            }
            return
        }
        guard caller.kind != .remote, caller.machineID?.isEmpty != false else {
            throw NativeRPCError(code: "access-denied", message: "This caller cannot use the Mac's saved server connections.")
        }
        if caller.kind == .key, caller.folders != nil {
            throw NativeRPCError(code: "access-denied", message: "A folder-scoped key has no saved-server grant.")
        }
        if let target, !target.isEmpty, target != "local", !(try await knownServer(target)) {
            throw NativeRPCError(code: "access-denied", message: caller.kind == .key && enforceKeyScope
                ? BackendDockerMCPServerKeyScope.refusal : "That server is not saved in this app.")
        }
        if enforceKeyScope, caller.kind == .key {
            guard let key = caller.keyID, !key.isEmpty else {
                throw NativeRPCError(code: "access-denied", message: BackendDockerMCPServerKeyScope.refusal)
            }
            if let target, !target.isEmpty, !(try await keyAllowed(key, target)) {
                throw NativeRPCError(code: "access-denied", message: BackendDockerMCPServerKeyScope.refusal)
            }
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
        try await checkLookOnly(target: target, changing: changing)
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
            // The owner may have chosen Look only while this approval was open.
            try await checkLookOnly(target: target, changing: changing)
            try Task.checkCancellation()
            try authority.requireLocalUI(context)
            return
        }
        // Resolve the actual core caller again at dispatch, never project it
        // into the Mac owner's identity or allow a paired caller to hop servers.
        try authority.authorizeMetadata(context)
        let caller = try await authority.rpcCaller(context)
        try await checkScope(caller: caller, target: target, changing: changing)
        if changing { try authority.authorizeMutation(context) }
        try Task.checkCancellation()
    }
}
