// Stage B resumed for managed agent survival; opt in with TD_HOST_ACCOUNT_BRIDGE.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// A faithful private transport of a context that remains retained and
/// reauthorized in the actual app. These fields alone confer no authority.
public struct BackendHOSTAccountControlContext: Codable, Equatable, Sendable {
    public let caller: String, ownerID: String, requestID: UUID, origin: String?, capabilities: [String]
    public init(_ original: NativeRPCContext) {
        caller = original.caller.rawValue; ownerID = original.ownerID; requestID = original.requestID
        origin = original.origin?.absoluteString; capabilities = original.capabilities.sorted()
    }
    func transported() throws -> NativeRPCContext {
        guard let caller = NativeRPCContext.Caller(rawValue: caller), !ownerID.isEmpty,
              Set(capabilities).count == capabilities.count,
              capabilities == capabilities.sorted(), origin == nil || URL(string: origin!) != nil else {
            throw BackendHOSTFailure.authentication
        }
        // No fixed caller, newly minted request id or additional capability.
        return .init(caller: caller, ownerID: ownerID, requestID: requestID,
                     origin: origin.flatMap(URL.init(string:)), capabilities: Set(capabilities))
    }
}
public struct BackendHOSTAccountControlRequest: Codable, Equatable, Sendable {
    public let nonce: UUID, hostInstance: UUID, attachment: UUID
    public let context: BackendHOSTAccountControlContext
    public let channel: String, argumentsJSON: Data
    public let issuedAt: Date
    public init(nonce: UUID = UUID(), hostInstance: UUID, attachment: UUID, context: NativeRPCContext,
                channel: String, arguments: [NativeRPCValue]) throws {
        self.nonce = nonce; self.hostInstance = hostInstance; self.attachment = attachment; self.context = .init(context)
        self.channel = channel; argumentsJSON = try NativeRPCValue.array(arguments).encodedJSON(); issuedAt = Date()
        guard argumentsJSON.count <= 2 * 1024 * 1024 else { throw BackendHOSTFailure.invalid("The private account request exceeds its supported size.") }
    }
    public var digest: Data { Data(SHA256.hash(data: argumentsJSON)) }
    func arguments() throws -> [NativeRPCValue] {
        guard argumentsJSON.count <= 2 * 1024 * 1024 else { throw BackendHOSTFailure.invalid("The private account request exceeds its supported size.") }
        return try NativeRPCValue.parseJSON(argumentsJSON, maximumBytes: 2 * 1024 * 1024).requireArray("original account arguments")
    }
    static let profileChannels: Set<String> = ["host.profiles.find", "host.profiles.list", "host.profiles.snapshot", "host.profiles.resolve", "host.profiles.managed"]
    static var channels: Set<String> { BackendAccountRPC.channels.union(BackendAppAccountSignInService.channels).union(BackendSessionHookRPC.channels).union(profileChannels).union(["host.usage.probe"]) }
    public var mutation: Bool {
        ["profiles:create", "profiles:rename", "profiles:delete", "profiles:remove-copy", "profiles:set-default", "profiles:set-project-default", "profiles:signout",
         // ACCOUNTS-SPEC: setting a level and the steps of a sign-in the app runs are changes too.
         "profiles:set-level", "profiles:signin-start", "profiles:signin-code", "profiles:signin-cancel", "profiles:add-signin", "profiles:signin-discard", "profiles:vault-recover",
         "profiles:api:add", "profiles:api:update", "profiles:api:check", "profiles:api:remove",
         "hooks:sync", "hooks:install", "hooks:remove", "hooks:offer-accept", "hooks:offer-decline"].contains(channel)
    }
}
public struct BackendHOSTAccountControlApproval: Codable, Equatable, Sendable {
    public let nonce: UUID, hostInstance: UUID, attachment: UUID
    public let context: BackendHOSTAccountControlContext
    public let channel: String, argumentsDigest: Data, mutation: Bool
    public init(_ request: BackendHOSTAccountControlRequest) {
        nonce = request.nonce; hostInstance = request.hostInstance; attachment = request.attachment
        context = request.context; channel = request.channel; argumentsDigest = request.digest; mutation = request.mutation
    }
    func validates(_ request: BackendHOSTAccountControlRequest) -> Bool { self == .init(request) }
}
public struct BackendHOSTAccountControlProviderRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case path, binary }
    public let operation: BackendHOSTAccountControlRequest
    public let kind: Kind, provider: String?, path: String?, refresh: Bool
    public init(operation: BackendHOSTAccountControlRequest, kind: Kind, provider: String? = nil, path: String? = nil, refresh: Bool = false) {
        self.operation = operation; self.kind = kind; self.provider = provider; self.path = path; self.refresh = refresh
    }
}
public struct BackendHOSTAccountControlProviderAnswer: Codable, Sendable {
    public let path: String?
    public let binary: Binary?
    public init(path: String) { self.path = path; binary = nil }
    public init(binary: BackendNativeProviders.Binary) { path = nil; self.binary = .init(binary) }
    public struct Binary: Codable, Sendable {
        public let id: String, onPath: String?, runnable: String?, version: String?, broken: Bool, said: String?, usedAlternate: Bool, checkedAt: Date
        public init(_ original: BackendNativeProviders.Binary) {
            id = original.id; onPath = original.onPath; runnable = original.runnable; version = original.version
            broken = original.broken; said = original.said; usedAlternate = original.usedAlternate; checkedAt = original.checkedAt
        }
        func original() -> BackendNativeProviders.Binary {
            .init(id: id, onPath: onPath, runnable: runnable, version: version, broken: broken, said: said, usedAlternate: usedAlternate, checkedAt: checkedAt)
        }
    }
}
struct BackendHOSTAccountControlProfiles: Codable, Sendable {
    let profiles: [BackendAccountProfile], defaultProfileID: String?, projectDefaults: [String: String], systemNames: [String: String]
    init(_ original: BackendAccountProfilesSnapshot) {
        profiles = original.profiles; defaultProfileID = original.defaultProfileID; projectDefaults = original.projectDefaults; systemNames = original.systemNames
    }
    var original: BackendAccountProfilesSnapshot { .init(profiles: profiles, defaultProfileID: defaultProfileID, projectDefaults: projectDefaults, systemNames: systemNames) }
}

#endif
