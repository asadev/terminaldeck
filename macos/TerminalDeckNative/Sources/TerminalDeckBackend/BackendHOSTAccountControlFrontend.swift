// Stage B resumed for managed agent survival; opt in with TD_HOST_ACCOUNT_BRIDGE.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Shared invocation seam for the original channel facades and host proxy.
/// Conformance of existing concrete actors is an INT2-owned wiring edit.
public protocol BackendHOSTAccountChannelInvoking: Sendable {
    func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue
}
/// Narrow reads of the helper's actual profile owner. The original request
/// context is explicit; no local caller is minted for context-free consumers.
public protocol BackendHOSTProfileReading: Sendable {
    func find(_ id: String, context: NativeRPCContext) async throws -> BackendAccountProfile?
    func list(provider: String?, context: NativeRPCContext) async throws -> [BackendAccountProfile]
    func snapshot(context: NativeRPCContext) async throws -> BackendAccountProfilesSnapshot
    func resolve(sessionProfileID: String?, projectPath: String?, provider: String?, context: NativeRPCContext) async throws -> BackendAccountProfile
    func managed(_ id: String, context: NativeRPCContext) async throws -> Bool
}
public actor BackendHOSTAccountControlFrontend: BackendHOSTAccountChannelInvoking, BackendHOSTProfileReading {
    private let client: BackendHOSTClient
    public nonisolated let authority: BackendHOSTAccountControlAuthority
    private var closed = false
    public typealias LocalHandler = @Sendable (String, [NativeRPCValue], NativeRPCContext, Bool) async throws -> NativeRPCValue?
    private var localHandler: LocalHandler?
    public static let appAccountChannels: Set<String> = Set(["profiles:add-signin", "profiles:signin-prepare", "profiles:signin-discard", "profiles:vault-status", "profiles:vault-recover"]).union(BackendAPIAccountService.channels)
    public func installLocalAccountHandler(_ handler: @escaping LocalHandler) { localHandler = handler }
    public init(client: BackendHOSTClient, authority: BackendHOSTAccountControlAuthority) {
        self.client = client; self.authority = authority
    }
    /// Account questions added after the first hosted builds. A session host is never replaced while it holds
    /// sessions, so after an app update the RUNNING host can be older than the app and not know these; it
    /// refuses them ("could not be authenticated" from those builds). L8 (11 Oct): that refusal stopped the
    /// whole app from starting (Hoot asks "profiles:effective" at launch) and every agent task from starting.
    static let newerChannels: Set<String> = ["profiles:effective", "profiles:levels", "profiles:set-level", "profiles:claude-models",
        "profiles:account-providers", "profiles:signin-start", "profiles:signin-code", "profiles:signin-cancel", "profiles:signin-state", "profiles:remove-copy"]
    /// 18 Oct (#107): a host that answers the typed `unknown-channel` code (`typed`) is older only when it says so;
    /// every other refusal from it is real and reported, never answered with this Mac's own login. A host from
    /// before that code can say it only in words, so for it the words are still read.
    static func refusedByOlderHost(_ error: Error, typed: Bool) -> Bool {
        if error is BackendHOSTUnknownChannel { return true }
        guard !typed else { return false }
        let text = error.localizedDescription
        return text.contains("could not complete account.facade") || text.contains("does not know") || text.contains("could not be authenticated")
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        if channel == "profiles:signin", let id = args.first?.string, BackendAPIAccountRecord.isAPIAccountID(id) {
            try await authority.recheckExternal(channel: channel, args: args, context: context, mutation: false)
            guard let profile = try await find(id, context: context) else { throw BackendAccountFailure("Choose a saved API account.") }
            let record = try BackendAPIAccountRecord.read(profile)
            let configured = record.map { !$0.requiresKey || BackendAPIAccountKeychain.contains($0) } ?? false
            return .object([.init("profileId", .string(id)), .init("provider", .string(profile.provider)),
                .init("state", .string(configured ? "signed-in" : "signed-out")), .init("plan", .string("API key")),
                .init("detail", .string(configured ? "API credential configured" : "Enter the API key in this account's secure field")),
                .init("command", .string("")), .init("checkedAt", .number(Date().timeIntervalSince1970 * 1000))])
        }
        if channel == "profiles:delete", !BackendAPIAccountDeletion.insideCleanup,
           let id = args.first?.string, BackendAPIAccountRecord.isAPIAccountID(id) {
            return try await invoke("profiles:api:remove", args: [.object([.init("id", .string(id))])], context: context)
        }
        let selected: String?
        switch channel {
        case "profiles:set-default": selected = args.first?.string
        case "profiles:set-project-default": selected = args.count > 1 ? args[1].string : nil
        case "profiles:set-level": selected = args.count > 2 ? args[2].string : nil
        default: selected = nil
        }
        if let selected, BackendAPIAccountRecord.isAPIAccountID(selected) {
            let status = try await client.resource("account.status", arguments: .object([]))
            guard status["apiKeyAccounts"].bool == true else { throw BackendAccountFailure("API-key account defaults need the updated session service. Existing defaults are unchanged.") }
        }
        if Self.appAccountChannels.contains(channel) || channel.hasPrefix("profiles:signin-") {
            if let value = try await local(channel, args: args, context: context, olderHost: false) { return value }
            if Self.appAccountChannels.contains(channel) { throw BackendHOSTFailure.remote("Open Settings › Coding AIs in the desktop app to add or repair this login.") }
        }
        guard Self.newerChannels.contains(channel) else { return try await ask(channel, args: args, context: context) }
        do { return try await ask(channel, args: args, context: context) }
        catch is CancellationError { throw CancellationError() }
        catch where Self.refusedByOlderHost(error, typed: client.hello.accountUnknownChannel != nil) {
            if let value = try await local(channel, args: args, context: context, olderHost: true) { return value }
            // Answer from what every host knows, or say plainly what has to wait. Never a wrong "yes".
            switch channel {
            case "profiles:effective":
                // No levels exist on a host that does not know them: the session's own pick, else the project's
                // default, else this Mac's login, which is exactly what its resolve already answers.
                let input = args.first ?? .object([])
                let profile = try await resolve(sessionProfileID: input["sessionProfileId"].string, projectPath: input["projectPath"].string,
                                                provider: input["provider"].string, context: context)
                let picked = input["sessionProfileId"].string == profile.id
                return BackendAccountEffective(profile: profile, source: picked ? .session : .system, sourceKey: nil).wire
            case "profiles:levels":
                // An older host keeps only the old default and per-folder defaults. Show those and say it
                // is the older one ("olderHelper"), so the page explains instead of going blank (11 Oct, 32/53).
                var levels = BackendAccountLevelsSnapshot()
                if let old = try? await snapshot(context: context) {
                    func ai(_ id: String) -> String? { old.profiles.first { $0.id == id }?.provider }
                    if let id = old.defaultProfileID, let provider = ai(id) { levels.app[provider] = id }
                    for (folder, id) in old.projectDefaults { if let provider = ai(id) { levels.projects[folder, default: [:]][provider] = id } }
                }
                return levels.wire.setting("olderHelper", .bool(true))
            case "profiles:claude-models":
                // Item 51 (real app, 11 Oct): the list is only model names, and an older host cannot fetch it.
                // Answer in the question's own words instead of throwing (a throw was logged as
                // "ERROR [ipc] profiles:claude-models failed" at every start): this Mac's own login in
                // effect → "system", the app reads the list itself as before; a kept login → a plain
                // reason, and the app's own fetch is used (BackendHootModelSource, L5).
                let profile = try await resolve(sessionProfileID: nil, projectPath: nil, provider: "claude", context: context)
                return profile.system ? .object([.init("source", .string("system"))])
                    : .object([.init("source", .string("app")), .init("failure", .string("the session host running now is from before this update and cannot fetch the list with a kept login"))])
            default:
                throw BackendHOSTFailure.remote("Use the account menu in New session to choose a login for a new session. To sign in to another login, open Settings › Coding AIs and click Add account.")
            }
        }
    }
    private func local(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext, olderHost: Bool) async throws -> NativeRPCValue? {
        guard Self.appAccountChannels.contains(channel) || channel.hasPrefix("profiles:signin-") || channel == "profiles:remove-copy",
              !closed, let localHandler else { return nil }
        let mutation = !["profiles:signin-prepare", "profiles:signin-state", "profiles:vault-status", "profiles:api:list"].contains(channel)
        try await authority.recheckExternal(channel: channel, args: args, context: context, mutation: mutation)
        return try await BackendHOSTProfileScope.withContext(context) { try await localHandler(channel, args, context, olderHost) }
    }
    private func ask(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard !closed else { throw BackendHOSTFailure.unavailable }
        let request = try authority.begin(channel: channel, arguments: args, context: context)
        defer { authority.complete(request.nonce) }
        let scope = BackendMCPCancellation()
        return try await withTaskCancellationHandler {
            _ = try await authority.authorize(request: request, cancellation: scope)
            guard !closed, !scope.isCancelled else { throw BackendHOSTFailure.unavailable }
            let payload = try NativeRPCValue.parseJSON(JSONEncoder().encode(request))
            let reply = try await client.resource("account.facade", arguments: payload)
            // Recheck the ORIGINAL context after the helper awaited its actors.
            // A copied caller/context returned by transport is never authority.
            _ = try await authority.authorize(request: request, cancellation: scope)
            guard !closed, !scope.isCancelled else { throw BackendHOSTFailure.unavailable }
            return channel == "profiles:list" ? BackendAPIAccountRecord.decorate(reply) : reply
        } onCancel: { scope.cancel(); self.authority.complete(request.nonce) }
    }
    public func find(_ id: String, context: NativeRPCContext) async throws -> BackendAccountProfile? {
        let value = try await invoke("host.profiles.find", args: [.string(id)], context: context)
        return value.isNullish ? nil : try JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON())
    }
    public func list(provider: String? = nil, context: NativeRPCContext) async throws -> [BackendAccountProfile] {
        let value = try await invoke("host.profiles.list", args: [provider.map(NativeRPCValue.string) ?? .null], context: context)
        return try JSONDecoder().decode([BackendAccountProfile].self, from: value.encodedJSON())
    }
    public func snapshot(context: NativeRPCContext) async throws -> BackendAccountProfilesSnapshot {
        let value = try await invoke("host.profiles.snapshot", args: [], context: context)
        return try JSONDecoder().decode(BackendHOSTAccountControlProfiles.self, from: value.encodedJSON()).original
    }
    public func resolve(sessionProfileID: String?, projectPath: String?, provider: String?, context: NativeRPCContext) async throws -> BackendAccountProfile {
        let args: NativeRPCValue = .object([.init("sessionProfileId", sessionProfileID.map(NativeRPCValue.string) ?? .null),
            .init("projectPath", projectPath.map(NativeRPCValue.string) ?? .null), .init("provider", provider.map(NativeRPCValue.string) ?? .null),
            .init("environmentOverrides", .object(BackendDefaultClaudeLogin.environmentOverrides.map { .init($0.key, .string($0.value)) }))])
        let value = try await invoke("host.profiles.resolve", args: [args], context: context)
        return try JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON())
    }
    public func managed(_ id: String, context: NativeRPCContext) async throws -> Bool {
        let value = try await invoke("host.profiles.managed", args: [.string(id)], context: context)
        guard let managed = value.bool else { throw BackendHOSTFailure.invalid("The actual host profile owner returned no managed-account answer.") }
        return managed
    }
    public func close() { closed = true; localHandler = nil; authority.close() }
}
public struct BackendHOSTAccountControlApp: Sendable {
    public let authority: BackendHOSTAccountControlAuthority
    public let facade: BackendHOSTAccountControlFrontend
    public init(client: BackendHOSTClient, currentAttachment: @escaping @Sendable () -> UUID?,
                authorizeRPC: @escaping BackendHOSTAccountControlAuthority.AuthorizeRPC,
                authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                originalProviders: BackendNativeProviders? = nil) {
        let authority = BackendHOSTAccountControlAuthority(hostInstance: { client.hello.instance }, currentAttachment: currentAttachment,
            authorizeRPC: authorizeRPC, authorizeMetadata: authorizeMetadata, authorizeMutation: authorizeMutation, providers: originalProviders)
        self.authority = authority; facade = BackendHOSTAccountControlFrontend(client: client, authority: authority)
    }
}

#endif
