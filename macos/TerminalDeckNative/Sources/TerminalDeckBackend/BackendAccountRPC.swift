import Foundation
import SystemConfiguration
import TerminalDeckNativeCore

/// Register only this safe metadata facade. Vault.read, tickets and shim
/// bodies are deliberately absent from every page/MCP-facing channel.
public actor BackendAccountRPC {
    public static let channels: Set<String> = ["profiles:list", "profiles:account-providers", "profiles:create", "profiles:rename",
        "profiles:delete", "profiles:set-default", "profiles:set-project-default", "profiles:resolve", "profiles:status"]
    private let accounts: BackendAccountLaunchAdapter
    private let configuration: BackendAccountConfiguration
    private let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
    public init(accounts: BackendAccountLaunchAdapter, configuration: BackendAccountConfiguration,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.accounts = accounts; self.configuration = configuration; self.authorizeMutation = authorizeMutation
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendAccountFailure("The native account facade does not handle this channel.") }
        if ["profiles:create", "profiles:rename", "profiles:delete", "profiles:set-default", "profiles:set-project-default"].contains(channel) { try authorizeMutation(context) }
        let store = await accounts.profiles
        func argument(_ index: Int) -> NativeRPCValue { args.indices.contains(index) ? args[index] : .missing }
        func id(_ index: Int) throws -> String { try argument(index).requireString("account id", nonempty: true) }
        switch channel {
        case "profiles:list": return try await snapshot(provider: optionalProvider(argument(0)))
        case "profiles:account-providers": return Self.accountProvidersView()
        case "profiles:create":
            let profile = try await accounts.createProfile(name: argument(0).requireString("account name"),
                provider: argument(1)["provider"].string ?? "claude", configDir: argument(1)["configDir"].string)
            return try encoded(profile)
        case "profiles:rename": return try encoded(try await store.rename(id: id(0), name: argument(1).requireString("account name")))
        case "profiles:delete":
            let removed = try await accounts.deleteProfile(id: id(0), deleteFiles: argument(1)["deleteFiles"].bool == true)
            var value = NativeRPCValue.object([.init("removed", .bool(removed.removed)), .init("filesDeleted", .bool(removed.filesDeleted)), .init("credentialsRetained", .bool(removed.credentialsRetained))])
            if let warning = removed.warning { value = value.setting("warning", .string(warning)) }
            return value
        case "profiles:set-default":
            try await store.setDefault(argument(0).string.flatMap { $0.isEmpty ? nil : $0 }); return try await snapshot()
        case "profiles:set-project-default":
            try await store.setDefault(argument(1).string.flatMap { $0.isEmpty ? nil : $0 }, projectPath: argument(0).requireString("project path", nonempty: true)); return try await snapshot()
        case "profiles:resolve":
            let input = argument(0)
            return try encoded(try await store.resolve(sessionProfileID: input["sessionProfileId"].string, projectPath: input["projectPath"].string,
                provider: optionalProvider(input["provider"])))
        case "profiles:status":
            // TS profiles.ts:1662 -> profileStatus(profile): the Mac's isolation answer (credential-store.ts).
            let wanted = try id(0)
            guard let profile = try await store.find(wanted) else { throw BackendAccountFailure("no profile with id \(wanted)") }
            return BackendAccountProfileStatus.status(profile)
        default: throw BackendAccountFailure("The native account channel has no implementation.")
        }
    }
    private func optionalProvider(_ raw: NativeRPCValue) -> String? { raw.string.flatMap { BackendAccountStrategies.supportsAccounts($0) ? $0 : nil } }
    /// `accountProvidersView`: built from the one strategy table, shell excluded.
    public static func accountProvidersView() -> NativeRPCValue {
        .object([.init("providers", .array(BackendAccountStrategies.all.filter { $0.provider != "shell" }.map { strategy in
            let supported = BackendAccountStrategies.supportsAccounts(strategy.provider)
            return .object([.init("id", .string(strategy.provider)), .init("label", .string(strategy.label)),
                .init("supported", .bool(supported)), .init("canSignIn", .bool(BackendAccountStrategies.hasSignIn(strategy.provider))),
                .init("configEnv", strategy.configEnv.map(NativeRPCValue.string) ?? .null),
                .init("reason", supported ? .null : .string(BackendAccountStrategies.unsupportedReason(strategy.provider)))])
        }))])
    }
    private func encoded<T: Encodable>(_ value: T) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(value)) }
    public func snapshot(provider: String? = nil) async throws -> NativeRPCValue {
        let store = await accounts.profiles, vault = await accounts.vault
        let state = try await store.snapshot(), profiles = try await store.list(provider: provider)
        // TS profiles.ts profilesSnapshot: a vault that will not unlock leaves the list readable and its
        // kept accounts "unavailable" (vault-profiles.test.ts:337); the rule is runtime.ts keptBy/vaultSignedIn.
        let active = await vault.openState() == .ready
        var summaries: [BackendAccountVaultSummary] = []
        if active { summaries = await vault.allSummaries() }
        var vaultViews: [NativeRPCValue.Field] = []
        for profile in profiles {
            let managed = await store.managed(profile), summary = summaries.first { $0.accountId == profile.id }
            let keptBy = BackendSessionSwitchKeptLogin.keptBy(profile, managed: managed, usable: active)
            let kept = keptBy.rawValue
            let signedIn: NativeRPCValue = BackendSessionSwitchKeptLogin.signedIn(profile, kept: keptBy, held: summary?.held == true).map(NativeRPCValue.bool) ?? .null
            vaultViews.append(.init(profile.id, .object([.init("keptBy", .string(kept)), .init("signedIn", signedIn),
                .init("updatedAt", summary.map { .number($0.updatedAt) } ?? .null), .init("plan", summary?.plan.map(NativeRPCValue.string) ?? .null)])))
        }
        let inherited = BackendAccountProfile.inheritedSystemInstalls(environment: configuration.inheritedEnvironment).map(\.wireValue)
        return .object([.init("profiles", .array(try profiles.map(encoded))), .init("defaultProfileId", state.defaultProfileID.map(NativeRPCValue.string) ?? .null),
            .init("projectDefaults", .object(state.projectDefaults.map { .init($0.key, .string($0.value)) })), .init("inherited", .array(inherited)),
            .init("machine", .string(SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "")), .init("vault", .object(vaultViews))])
    }
}
