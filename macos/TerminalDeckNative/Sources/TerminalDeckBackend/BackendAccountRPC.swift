import Foundation
import SystemConfiguration
import TerminalDeckNativeCore

/// Register only this safe metadata facade. Vault.read, tickets and shim
/// bodies are deliberately absent from every page/MCP-facing channel.
public actor BackendAccountRPC {
    public static let channels: Set<String> = Set(["profiles:list", "profiles:account-providers", "profiles:create", "profiles:rename",
        "profiles:delete", "profiles:set-default", "profiles:set-project-default", "profiles:resolve", "profiles:status", "profiles:remove-copy",
        // App-owned operations stay available when a kept-session helper predates this UI.
        "profiles:add-signin", "profiles:signin-discard", "profiles:vault-status", "profiles:vault-recover",
        // ACCOUNTS-SPEC: every level (whole app, project, seat) per AI, and the effective account with its source.
        "profiles:levels", "profiles:set-level", "profiles:effective",
        // The live Claude model list, fetched here with a login the app keeps (never returned).
        "profiles:claude-models"]).union(BackendAPIAccountService.channels)
    public nonisolated let apiAccounts: BackendAPIAccountService
    private let accounts: BackendAccountLaunchAdapter
    private let configuration: BackendAccountConfiguration
    private let authorizeMutation: @Sendable (NativeRPCContext) throws -> Void
    private let sessionTitle: @Sendable (String) async -> String?
    /// `sessionTitle` answers a session's current title; without one the title it started under is used.
    public init(accounts: BackendAccountLaunchAdapter, configuration: BackendAccountConfiguration,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                sessionTitle: @escaping @Sendable (String) async -> String? = { _ in nil }) {
        self.accounts = accounts; self.configuration = configuration; self.authorizeMutation = authorizeMutation; self.sessionTitle = sessionTitle
        apiAccounts = BackendAPIAccountService(configuration: configuration, access: .init(
            find: { id, _ in try await accounts.profiles.find(id) },
            list: { _ in try await accounts.profiles.list() },
            create: { name, provider, directory, _ in try await accounts.createProfile(name: name, provider: provider, configDir: directory) },
            rename: { id, name, _ in try await accounts.profiles.rename(id: id, name: name) },
            remove: { id, _ in
                let result = try await accounts.deleteProfile(id: id, deleteFiles: false)
                return .object([.init("removed", .bool(result.removed)), .init("credentialsRetained", .bool(result.credentialsRetained))])
            }), authorizeMutation: authorizeMutation, inUse: { await Self.use($0, accounts: accounts, title: sessionTitle) })
    }
    /// 18 Oct (#89, #527): who is running as an account right now, by name. Tabs whose agent has ended do not count.
    static func use(_ id: String, accounts: BackendAccountLaunchAdapter, title: @Sendable (String) async -> String?) async -> BackendAccountUse {
        let use = await accounts.sessionsUsing(id)
        var names: [String] = []
        for session in use.sessions { names.append(await title(session.id) ?? session.title) }
        return BackendAccountUse(sessions: names, starting: use.starting)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw BackendAccountFailure("The native account facade does not handle this channel.") }
        if BackendAPIAccountService.channels.contains(channel) { return try await apiAccounts.invoke(channel, args: args, context: context) }
        if channel == "profiles:delete", let id = args.first?.string, BackendAPIAccountRecord.isAPIAccountID(id) {
            return try await apiAccounts.invoke("profiles:api:remove", args: [.object([.init("id", .string(id))])], context: context)
        }
        if ["profiles:create", "profiles:rename", "profiles:delete", "profiles:remove-copy", "profiles:set-default", "profiles:set-project-default", "profiles:set-level"].contains(channel) { try authorizeMutation(context) }
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
            // 18 Oct (#527): removing a signed-in account would sign its running agents out mid-task, so it is
            // refused while any session runs as it, naming them, as Remove copy and API accounts already were.
            let using = await Self.use(try id(0), accounts: accounts, title: sessionTitle)
            guard using.isEmpty else { throw BackendAccountFailure(using.refusal("This account")) }
            let removed = try await accounts.deleteProfile(id: id(0), deleteFiles: argument(1)["deleteFiles"].bool == true)
            var value = NativeRPCValue.object([.init("removed", .bool(removed.removed)), .init("filesDeleted", .bool(removed.filesDeleted)), .init("credentialsRetained", .bool(removed.credentialsRetained))])
            if let warning = removed.warning { value = value.setting("warning", .string(warning)) }
            return value
        case "profiles:remove-copy":
            let removed = try await accounts.removeCopy(id: id(0))
            return .object([.init("removed", .bool(removed.removed)), .init("backupPath", removed.backup.map(NativeRPCValue.string) ?? .null)])
        case "profiles:set-default":
            try await store.setDefault(argument(0).string.flatMap { $0.isEmpty ? nil : $0 }); return try await snapshot()
        case "profiles:set-project-default":
            try await store.setDefault(argument(1).string.flatMap { $0.isEmpty ? nil : $0 }, projectPath: argument(0).requireString("project path", nonempty: true)); return try await snapshot()
        case "profiles:resolve":
            let input = argument(0)
            return try encoded(try await store.resolve(sessionProfileID: input["sessionProfileId"].string, projectPath: input["projectPath"].string,
                provider: optionalProvider(input["provider"])))
        case "profiles:levels": return try await store.snapshot().levels.wire
        case "profiles:set-level":
            // [level {kind: app|project|seat, path?, key?}, provider, account id or null for "Same as above"]
            guard let level = BackendAccountLevel(wire: argument(0)) else { throw BackendAccountFailure("Choose the whole app, a project folder or a role.") }
            let provider = try argument(1).requireString("AI", nonempty: true)
            try await store.setLevel(level, provider: provider, id: argument(2).string.flatMap { $0.isEmpty ? nil : $0 })
            return try await snapshot()
        case "profiles:effective":
            let input = argument(0)
            return try await store.effective(sessionProfileID: input["sessionProfileId"].string, projectPath: input["projectPath"].string,
                provider: optionalProvider(input["provider"]), seat: input["seat"].string.flatMap { BackendAccountLevel.validSeatKey($0) ? $0 : nil }).wire
        case "profiles:claude-models": return try await claudeModels(seat: argument(0)["seat"].string)
        case "profiles:status":
            // TS profiles.ts:1662 -> profileStatus(profile): the Mac's isolation answer (credential-store.ts).
            let wanted = try id(0)
            guard let profile = try await store.find(wanted) else { throw BackendAccountFailure("no profile with id \(wanted)") }
            // 18 Oct (#525): the note says where this account's login really is (app store, API key, or the AI's own Keychain entry).
            let keptBy = BackendSessionSwitchKeptLogin.keptBy(profile, managed: await store.managed(profile), usable: await accounts.vault.openState() == .ready)
            return BackendAccountProfileStatus.status(profile, keptBy: keptBy)
        default: throw BackendAccountFailure("The native account channel has no implementation.")
        }
    }
    /// ACCOUNTS-SPEC 3: the model list is fetched HERE, beside the store, with a login the app keeps,
    /// so it no longer depends on this Mac's Claude Code sign-in. Only Anthropic's public list comes
    /// back. The login is never returned or logged and goes nowhere but Anthropic's own address.
    /// {source: "system"} = this Mac's own login is the account in effect, or the app keeps no
    /// Claude login at all; {source: "app", body} = the list; {source: "app", failure} = no list.
    private func claudeModels(seat: String?) async throws -> NativeRPCValue {
        let store = await accounts.profiles, vault = await accounts.vault
        func answer(_ source: String, _ fields: [NativeRPCValue.Field] = []) -> NativeRPCValue { .object([.init("source", .string(source))] + fields) }
        func failure(_ why: String) -> NativeRPCValue { answer("app", [.init("failure", .string(why))]) }
        let effective = try await store.effective(sessionProfileID: nil, projectPath: nil, provider: "claude",
            seat: seat.flatMap { BackendAccountLevel.validSeatKey($0) ? $0 : nil }).profile
        guard !effective.system else { return answer("system") }
        // The account in effect first; another kept Claude login only when that one cannot be used
        // (a kept login renews when one of its sessions next runs).
        let others = try await store.list(provider: "claude").filter { $0.id != effective.id }
        var kept: [BackendAccountProfile] = []
        for profile in [effective] + others where !profile.system && profile.promised {
            if await store.managed(profile) { kept.append(profile) }
        }
        guard !kept.isEmpty else { return answer("system") }
        guard await vault.openState() == .ready else { return failure("Terminal Deck's own login store is locked") }
        var token: String?, expired = 0
        search: for profile in kept {
            let extra = (profile.keptSlots ?? []).filter { BackendAccountProfile.loginSlot($0) && $0 != BackendAccountSwitchInPlace.loginSlot }
            for slot in [BackendAccountSwitchInPlace.loginSlot] + extra {
                guard let secret = try? await vault.read(accountID: profile.id, slot: slot),
                      let value = try? NativeRPCValue.parseJSON(Data(secret.utf8)),
                      let access = value["claudeAiOauth"]["accessToken"].string, !access.isEmpty else { continue }
                guard (value["claudeAiOauth"]["expiresAt"].number ?? 0) / 1000 > Date().timeIntervalSince1970 + 30 else { expired += 1; continue }
                token = access; break search
            }
        }
        guard let token else {
            return failure(expired > 0 ? "Open Settings › Coding AIs, choose the Claude account, then click Sign in again." : "Open Settings › Coding AIs, choose the Claude account, then click Sign in.")
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000") else { return failure("bad URL") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { return failure("network: " + error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return failure("HTTP \(status)") }
        guard data.count <= 2 * 1_048_576, let body = String(data: data, encoding: .utf8) else { return failure("unreadable reply") }
        return answer("app", [.init("body", .string(body))])
    }
    private func optionalProvider(_ raw: NativeRPCValue) -> String? { raw.string.flatMap { BackendAccountStrategies.hasSignIn($0) ? $0 : nil } }
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
        return BackendAPIAccountRecord.decorate(.object([.init("profiles", .array(try profiles.map(encoded))), .init("defaultProfileId", state.defaultProfileID.map(NativeRPCValue.string) ?? .null),
            .init("projectDefaults", .object(state.projectDefaults.map { .init($0.key, .string($0.value)) })), .init("inherited", .array(inherited)),
            .init("machine", .string(SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "")), .init("vault", .object(vaultViews)),
            .init("levels", state.levels.wire)]))
    }
}
