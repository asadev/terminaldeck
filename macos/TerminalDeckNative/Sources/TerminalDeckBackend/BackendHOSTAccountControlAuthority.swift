// Stage B resumed for managed agent survival; opt in with TD_HOST_ACCOUNT_BRIDGE.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// App-owned, short-lived original request contexts. There is no default
/// authorizer, fixed local caller, or authority derived from a wire context.
public final class BackendHOSTAccountControlAuthority: @unchecked Sendable {
    public typealias AuthorizeRPC = @Sendable (NativeRPCContext, String, [NativeRPCValue]) async throws -> Void
    private struct Pending: Sendable {
        let request: BackendHOSTAccountControlRequest, context: NativeRPCContext, expires: Date
        var approved = false
    }
    /// The CURRENT host instance (it changes when a crashed host is replaced; L8, 11 Oct).
    private var hostInstanceNow: @Sendable () -> UUID
    private var hostInstance: UUID { hostInstanceNow() }
    private let currentAttachment: @Sendable () -> UUID?
    private let authorizeRPC: AuthorizeRPC
    private let authorizeMetadata: @Sendable (NativeRPCContext) throws -> Void
    private let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
    private let providers: BackendNativeProviders?
    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var closed = false
    public init(hostInstance: UUID, currentAttachment: @escaping @Sendable () -> UUID?,
                authorizeRPC: @escaping AuthorizeRPC,
                authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                providers: BackendNativeProviders? = nil) {
        self.hostInstanceNow = { hostInstance }; self.currentAttachment = currentAttachment
        self.authorizeRPC = authorizeRPC; self.authorizeMetadata = authorizeMetadata; self.authorizeMutation = authorizeMutation
        self.providers = providers
    }
    /// Follows the host the given client talks to now.
    public convenience init(hostInstance: @escaping @Sendable () -> UUID, currentAttachment: @escaping @Sendable () -> UUID?,
                            authorizeRPC: @escaping AuthorizeRPC,
                            authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                            authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                            providers: BackendNativeProviders? = nil) {
        self.init(hostInstance: hostInstance(), currentAttachment: currentAttachment, authorizeRPC: authorizeRPC,
                  authorizeMetadata: authorizeMetadata, authorizeMutation: authorizeMutation, providers: providers)
        self.hostInstanceNow = hostInstance
    }
    public func begin(channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) throws -> BackendHOSTAccountControlRequest {
        guard BackendHOSTAccountControlRequest.channels.contains(channel), let attachment = currentAttachment() else { throw BackendHOSTFailure.unavailable }
        let request = try BackendHOSTAccountControlRequest(hostInstance: hostInstance, attachment: attachment, context: context, channel: channel, arguments: arguments)
        try lock.withLock {
            pending = pending.filter { $0.value.expires > Date() }
            guard !closed, pending.count < 128 else { throw BackendHOSTFailure.unavailable }
            pending[request.nonce] = .init(request: request, context: context, expires: Date().addingTimeInterval(60))
        }
        return request
    }
    public func complete(_ nonce: UUID) { lock.withLock { pending[nonce] = nil } }
    public func close() { lock.withLock { closed = true; pending.removeAll() } }
    /// Private frontend controls use the same original request authority as
    /// profile operations. No wire context is promoted to local ownership.
    public func recheckExternal(channel: String, args: [NativeRPCValue], context: NativeRPCContext, mutation: Bool) async throws {
        guard lock.withLock({ !closed }), currentAttachment() != nil, !Task.isCancelled else { throw BackendHOSTFailure.unavailable }
        try await authorizeRPC(context, channel, args)
        guard lock.withLock({ !closed }), currentAttachment() != nil, !Task.isCancelled else { throw BackendHOSTFailure.unavailable }
        if mutation { try authorizeMutation(context) } else { try authorizeMetadata(context) }
    }
    private func original(_ request: BackendHOSTAccountControlRequest, cancellation: BackendMCPCancellation) throws -> Pending {
        guard !cancellation.isCancelled, !Task.isCancelled, request.hostInstance == hostInstance,
              request.attachment == currentAttachment() else { throw BackendHOSTFailure.authentication }
        return try lock.withLock {
            guard !closed, let value = pending[request.nonce], value.expires > Date(), value.request == request,
                  BackendHOSTAccountControlContext(value.context) == request.context else { throw BackendHOSTFailure.authentication }
            return value
        }
    }
    private func recheck(_ request: BackendHOSTAccountControlRequest, cancellation: BackendMCPCancellation) async throws -> Pending {
        let value = try original(request, cancellation: cancellation)
        try await authorizeRPC(value.context, request.channel, request.arguments())
        _ = try original(request, cancellation: cancellation)
        if request.mutation { try authorizeMutation(value.context) } else { try authorizeMetadata(value.context) }
        return try original(request, cancellation: cancellation)
    }
    public func authorize(request: BackendHOSTAccountControlRequest, cancellation: BackendMCPCancellation) async throws -> BackendHOSTAccountControlApproval {
        _ = try await recheck(request, cancellation: cancellation)
        try lock.withLock {
            guard var value = pending[request.nonce], !closed else { throw BackendHOSTFailure.authentication }
            value.approved = true; pending[request.nonce] = value
        }
        _ = try original(request, cancellation: cancellation)
        return .init(request)
    }
    /// Called only by the helper's original sign-in dependency methods. Uses
    /// the retained APP provider actor and its actual prefs/environment/caches.
    public func resolveProvider(request: BackendHOSTAccountControlProviderRequest, cancellation: BackendMCPCancellation) async throws -> BackendHOSTAccountControlProviderAnswer {
        // Resolving the default Claude login checks its sign-in state too. These
        // read paths retain the same original-call approval as explicit sign-in.
        let resolution = ["host.profiles.resolve", "profiles:resolve", "profiles:effective"].contains(request.operation.channel)
        guard resolution || ["profiles:signin", "profiles:signout", "host.usage.probe"].contains(request.operation.channel) else {
            throw BackendHOSTFailure.remote("The app cannot resolve a provider for this account operation.")
        }
        guard let providers else { throw BackendHOSTFailure.remote("The app's provider resolver is not connected.") }
        let value = try await recheck(request.operation, cancellation: cancellation)
        guard value.approved else { throw BackendHOSTFailure.authentication }
        let answer: BackendHOSTAccountControlProviderAnswer
        switch request.kind {
        case .path:
            answer = .init(path: try await providers.loginPath())
        case .binary:
            guard let provider = request.provider, ["claude", "codex", "gemini"].contains(provider), let path = request.path,
                  path == (try await providers.loginPath()) else { throw BackendHOSTFailure.authentication }
            guard !resolution || provider == "claude" else { throw BackendHOSTFailure.authentication }
            let arguments = try request.operation.arguments()
            if request.operation.channel == "profiles:signin", arguments.count > 1,
               let wanted = arguments[1]["provider"].string, ["claude", "codex", "gemini", "shell"].contains(wanted), wanted != provider {
                throw BackendHOSTFailure.authentication
            }
            answer = .init(binary: await providers.resolveBinary(provider, path: path, refresh: request.refresh))
        }
        _ = try await recheck(request.operation, cancellation: cancellation)
        return answer
    }
    /// Root installs this behind the authenticated account.authorize control
    /// whitelist. It is distinct from the public MCP tool catalogue.
    public func control(arguments: NativeRPCValue, cancellation: BackendMCPCancellation) async throws -> NativeRPCValue {
        let kind = try arguments["kind"].requireString("account control kind")
        let payload = try arguments["request"].encodedJSON()
        switch kind {
        case "authorize":
            let value = try await authorize(request: JSONDecoder().decode(BackendHOSTAccountControlRequest.self, from: payload), cancellation: cancellation)
            return try NativeRPCValue.parseJSON(JSONEncoder().encode(value))
        case "provider":
            let value = try await resolveProvider(request: JSONDecoder().decode(BackendHOSTAccountControlProviderRequest.self, from: payload), cancellation: cancellation)
            return try NativeRPCValue.parseJSON(JSONEncoder().encode(value))
        default: throw BackendHOSTFailure.invalid("Unknown private account control.")
        }
    }
}

#endif
