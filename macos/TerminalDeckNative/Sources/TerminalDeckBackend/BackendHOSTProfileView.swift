#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// The original read surface without its writer lease or mutation methods.
public protocol BackendHOSTProfileViewReading: Sendable {
    var configuration: BackendAccountConfiguration { get }
    func snapshot() async throws -> BackendAccountProfilesSnapshot
    func find(_ id: String) async throws -> BackendAccountProfile?
    func list(provider: String?) async throws -> [BackendAccountProfile]
    func resolve(sessionProfileID: String?, projectPath: String?, provider: String?) async throws -> BackendAccountProfile
    func managed(_ profile: BackendAccountProfile) async throws -> Bool
}
extension BackendAccountProfileStore: BackendHOSTProfileViewReading {}

/// Every public channel/tool enters this with the actual request context.
/// Missing scope refuses; it never constructs a nativeApp context for a key.
public enum BackendHOSTProfileScope {
    @TaskLocal public static var context: NativeRPCContext?
    /// HOOTFIX: an explicit scope wins; otherwise the registry's own
    /// authenticated dispatcher context for THIS request (set by
    /// NativeChannelRegistry.invoke/send for every channel) is the original
    /// context. Nothing is minted: with neither, the read still refuses.
    public static func requireCurrent() throws -> NativeRPCContext {
        guard let context = context ?? NativeCompositionCallContext.rpc else {
            throw BackendSessionFailure.missingCapability("the original authorized profile-read context")
        }
        return context
    }
    public static func withContext<T: Sendable>(_ context: NativeRPCContext,
        operation: @Sendable () async throws -> T) async rethrows -> T {
        try await $context.withValue(context, operation: operation)
    }
}
public struct BackendHOSTProfileView: BackendHOSTProfileViewReading {
    public let configuration: BackendAccountConfiguration
    private let reader: any BackendHOSTProfileReading
    private let context: @Sendable () async throws -> NativeRPCContext
    /// The supplied callback must retrieve the actual operation's context.
    /// Production channel/tool views pass requireCurrent; a recovery owner may
    /// supply its explicitly authorized internal operation, never a default.
    public init(configuration: BackendAccountConfiguration, reader: any BackendHOSTProfileReading,
                context: @escaping @Sendable () async throws -> NativeRPCContext) {
        self.configuration = configuration; self.reader = reader; self.context = context
    }
    public func snapshot() async throws -> BackendAccountProfilesSnapshot { try await reader.snapshot(context: context()) }
    public func find(_ id: String) async throws -> BackendAccountProfile? { try await reader.find(id, context: context()) }
    public func list(provider: String? = nil) async throws -> [BackendAccountProfile] { try await reader.list(provider: provider, context: context()) }
    public func resolve(sessionProfileID: String?, projectPath: String?, provider: String?) async throws -> BackendAccountProfile {
        try await reader.resolve(sessionProfileID: sessionProfileID, projectPath: projectPath, provider: provider, context: context())
    }
    public func managed(_ profile: BackendAccountProfile) async throws -> Bool { try await reader.managed(profile.id, context: context()) }
}

/// Startup preparation starts no adapter, profile/vault store or Keychain
/// owner in the app. managedClient is the distinct agents namespace; core's
/// existing client and pid are not consulted, replaced or stopped here.
public struct BackendHOSTAccountSessionParts: Sendable {
    public let resolver: BackendHOSTAccountResolver
    public let accounts: BackendHOSTSessionAccountAccess
    public let profiles: BackendHOSTProfileView
    public let channels: BackendHOSTAccountControlFrontend
    public init(managedClient: BackendHOSTClient, configuration: BackendAccountConfiguration,
                app: BackendHOSTAccountControlApp,
                externalPID: (@Sendable (String) -> Int32?)? = nil,
                profileContext: @escaping @Sendable () async throws -> NativeRPCContext) async throws {
        accounts = try await BackendHOSTSessionAccountAccess(client: managedClient)
        resolver = try await BackendHOSTAccountResolver(client: managedClient, externalPID: externalPID)
        profiles = .init(configuration: configuration, reader: app.facade, context: profileContext)
        channels = app.facade
    }
}
#endif
