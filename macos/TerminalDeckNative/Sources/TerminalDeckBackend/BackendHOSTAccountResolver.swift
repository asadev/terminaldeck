import Foundation
import TerminalDeckNativeCore

/// Existing launch policy still runs in the app; only the account runtime
/// allocation/binding crosses into the persistent helper.
public struct BackendHOSTAccountResolver: BackendAccountLaunchResolver, Sendable {
    public let readiness: BackendLaunchReadiness
    private let client: BackendHOSTClient
    private let externalPID: (@Sendable (String) -> Int32?)?
    public init(client: BackendHOSTClient, externalPID: (@Sendable (String) -> Int32?)? = nil) async throws {
        let status = try await client.resource("account.status", arguments: .object([]))
        guard status["ready"].bool == true else { throw BackendSessionFailure.missingCapability("the live host account runtime") }
        self.client = client; self.externalPID = externalPID; readiness = .ready
    }
    public func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                        loginPath: String, context: BackendLaunchContext) async throws -> BackendAccountLaunch {
        if let id = input.profileId, BackendAPIAccountRecord.isAPIAccountID(id) {
            let status = try await client.resource("account.status", arguments: .object([]))
            guard status["apiKeyAccounts"].bool == true else { throw BackendAccountFailure("This API-key account needs the updated session service. Existing sessions are unchanged.") }
        }
        let args = NativeRPCValue.object([.init("input", try encoded(input)), .init("scope", try encoded(BackendHOSTProtocol.Scope(context))),
            .init("provider", .object([.init("id", .string(provider.id)), .init("command", .string(provider.command)),
                .init("args", .array(provider.args.map(NativeRPCValue.string))), .init("resumeArgs", .array(provider.resumeArgs.map(NativeRPCValue.string)))])),
            .init("path", .string(loginPath)),
            .init("privateContext", .object([.init("environmentOverrides", .object(context.environmentOverrides.map { .init($0.key, .string($0.value)) })),
                .init("removeEnvironment", .array(context.removeEnvironment.sorted().map(NativeRPCValue.string)))]))])
        let value = try await BackendHOSTChatAccountCompatibility.resolve(chat: input.chat == true, arguments: args) { method, arguments in
            try await client.resource(method, arguments: arguments)
        }
        let account = try JSONDecoder().decode(BackendHOSTAccountWire.self, from: value.encodedJSON()).launch
        if let variable = BackendAccountProfile.configEnvironment(provider.id), let folder = account.environment[variable], let identity = account.profile {
            let profile = BackendAccountProfile(id: identity.id, name: identity.name, provider: provider.id, configDir: folder,
                system: false, color: "--accent", createdAt: 0)
            if try BackendAPIAccountRecord.read(profile) != nil, account.environment[BackendAPIAccountRecord.referenceVariable] == nil {
                if let handle = account.reservationID { _ = try? await client.resource("account.abandon", arguments: .object([.init("handle", .string(handle))])) }
                throw BackendAccountFailure("This API-key account needs the updated session service. Existing sessions are unchanged.")
            }
        }
        return account
    }
    public func continuingConversationID(_ input: BackendCreateSessionInput, account: BackendAccountLaunch, live: [BackendSessionMeta]) async throws -> String? {
        guard let handle = account.reservationID else { return nil }
        return try await client.resource("account.continuing", arguments: .object([.init("handle", .string(handle)), .init("input", try encoded(input))])).string
    }
    public func bind(_ account: BackendAccountLaunch, session: BackendSessionMeta) async throws {
        guard let handle = account.reservationID else { return }
        #if TD_HOST_ACCOUNT_BRIDGE
        if try client.snapshot(session.id) == nil, let pid = externalPID?(session.id) {
            return try await bindExternal(account, session: session, pid: pid)
        }
        #endif
        _ = try await client.resource("account.bind", arguments: .object([.init("handle", .string(handle)), .init("session", try encoded(session))]))
    }
    public func abandon(_ account: BackendAccountLaunch) async {
        guard let handle = account.reservationID else { return }
        _ = try? await client.resource("account.abandon", arguments: .object([.init("handle", .string(handle))]))
    }
    public func exited(sessionID: String) async {
        _ = try? await client.resource("account.exited", arguments: .object([.init("id", .string(sessionID))]))
    }
    private func encoded<T: Encodable>(_ value: T) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(value)) }
}

#if TD_HOST_ACCOUNT_BRIDGE
extension BackendHOSTAccountResolver: BackendHOSTExternalAccountBinding {
    public func bindExternal(_ account: BackendAccountLaunch, session: BackendSessionMeta, pid: Int32) async throws {
        guard let handle = account.reservationID else { return }
        _ = try await client.resource("account.external.bind", arguments: .object([.init("handle", .string(handle)),
            .init("session", try encoded(session)), .init("pid", .number(Double(pid)))]))
    }
}
#endif
