import Foundation
import TerminalDeckNativeCore

/// Complete launch-account composition: selection, the account-owned home,
/// encrypted login handoff, per-launch ticket binding and failure cleanup.
public actor BackendAccountLaunchAdapter: BackendAccountLaunchResolver {
    /// Join evidence for Hoot: an app records fence keeps the managed login.
    public static let recordsFenceKeepsManagedLogin = true
    public nonisolated let readiness: BackendLaunchReadiness
    public let profiles: BackendAccountProfileStore
    public let vault: BackendAccountVault
    public let broker: BackendAccountBroker
    public let codex: BackendAccountCodexLease
    private let configuration: BackendAccountConfiguration
    private struct Reservation: Sendable {
        let home: BackendAccountProfile
        let login: BackendAccountProfile
        let ticket: String?
        let ticketIsSeat: Bool
        let transcriptConfiguration: String
    }
    private var reservations: [String: Reservation] = [:]
    private var sessions: [String: Reservation] = [:]
    private var boundReservations: [String: String] = [:]
    private var sessionTitles: [String: String] = [:]
    private var endedSessions = Set<String>()
    private var closed = false
    public func apiProfileInUse(_ id: String) -> Bool {
        let use = sessionsUsing(id)
        return use.starting || !use.sessions.isEmpty
    }
    /// 18 Oct (#89, #527): the sessions running as this account (its login or its home), with the title they started
    /// under, and whether a launch with it is still starting. A session whose agent has ended no longer counts, even
    /// while its helpers finish and before its seat is released.
    public func sessionsUsing(_ id: String) -> (sessions: [(id: String, title: String)], starting: Bool) {
        let running = sessions.filter { !endedSessions.contains($0.key) && ($0.value.login.id == id || $0.value.home.id == id) }
        return (running.keys.sorted().map { (id: $0, title: sessionTitles[$0] ?? "") },
                reservations.values.contains { $0.login.id == id || $0.home.id == id })
    }
    /// The agent of a bound session has ended; its seat stays until `exited` releases it.
    public func agentEnded(sessionID: String) {
        if sessions[sessionID] != nil { endedSessions.insert(sessionID) }
    }

    /// Production assembly, called only after the full facade has stopped Node
    /// and owns this exact state directory. No account subsystem is activated
    /// independently against a live Node store.
    public static func start(configuration: BackendAccountConfiguration, stateStore: NativeStateStore,
                             cipher: BackendAccountKeychainCipher) async throws -> BackendAccountLaunchAdapter {
        let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: stateStore)
        _ = try await profiles.snapshot()
        let vault = try BackendAccountVault(configuration: configuration, stateStore: stateStore, cipher: cipher)
        let broker: BackendAccountBroker
        do { broker = try await BackendAccountBroker.start(configuration: configuration, profiles: profiles, vault: vault) }
        catch {
            // D11 / TS wire.ts:163: saved logins that will not unlock stop only the vault, never the
            // session system. The file is left exactly as it is; app-kept accounts read "unavailable".
            // TS wire.ts:151/163: no secure store for a vault that does not exist yet, or saved logins
            // that will not unlock, stop only the vault. Anything else still fails the start.
            let locked = await vault.openState() == .locked
            let fresh = !FileManager.default.fileExists(atPath: vault.file.path)
            guard locked || fresh else { await vault.close(); await profiles.close(); throw error }
            NSLog("%@", locked ? "account vault off: the saved logins would not unlock; the file is left exactly as it is"
                : "account vault off: no secure store on this computer")
            broker = BackendAccountBroker.vaultOff(configuration: configuration, profiles: profiles, vault: vault)
        }
        let codex = BackendAccountCodexLease.wired(vault: vault, profiles: profiles)
        let adapter = try BackendAccountLaunchAdapter(configuration: configuration, profiles: profiles, vault: vault, broker: broker, codex: codex)
        do { try await adapter.prepareExistingAccounts(); return adapter }
        catch { _ = await adapter.shutdown(); throw error }
    }

    public init(configuration: BackendAccountConfiguration, profiles: BackendAccountProfileStore,
                vault: BackendAccountVault, broker: BackendAccountBroker, codex: BackendAccountCodexLease) throws {
        for capability in [profiles.readiness, vault.readiness, broker.readiness, codex.readiness] {
            guard capability == .ready else { if case .unavailable(let message) = capability { throw BackendAccountFailure(message) }; throw BackendAccountFailure("A required native account dependency is not ready.") }
        }
        self.configuration = configuration; self.profiles = profiles; self.vault = vault; self.broker = broker; self.codex = codex
        readiness = .ready
    }
    public func prepareExistingAccounts() async throws {
        // D11 / TS wire.ts:163: with the saved logins locked there is no vault runtime to settle against.
        guard await vault.openState() == .ready else { return }
        for profile in try await profiles.list(provider: "codex") {
            guard !BackendAPIAccountRecord.isAPIAccountID(profile.id) else { continue }
            guard await profiles.managed(profile) else { continue }
            try await codex.settle(profile)
            if try await vault.read(accountID: profile.id, slot: "file:auth.json") != nil { try await profiles.markSlotKept(id: profile.id, slot: "file:auth.json") }
        }
    }
    /// 12 Oct: a broker that started with the vault off comes up as soon as the saved logins open
    /// (BackendAccountBroker.reviveIfOff), and then the existing logins are settled exactly as a start
    /// with the store open settles them. Quiet and throttled while the store still will not open.
    @discardableResult
    public func reviveVault() async -> Bool {
        guard !closed else { return false }
        switch await broker.reviveIfOff() {
        case .on: return true
        case .off: return false
        case .revived:
            try? await prepareExistingAccounts()
            return true
        }
    }
    /// The sign-in state of a login ("signed-in", "signed-out", or anything else when it cannot be told), from the
    /// app's own sign-in reader (cached; the agent's own status command for its own login, the vault for a kept one).
    public typealias SignInCheck = @Sendable (_ login: BackendAccountProfile, _ fresh: Bool) async -> String?
    private var signInCheck: SignInCheck?
    public func setSignInCheck(identity: BackendDefaultClaudeLogin.IdentityCheck? = nil, _ check: SignInCheck?) async {
        signInCheck = check
        guard let check else { await profiles.setDefaultLoginResolver(nil); return }
        let configuration = self.configuration
        await profiles.setDefaultLoginResolver { login, saved, preferred in
            try await BackendDefaultClaudeLogin.resolve(login, saved: saved, preferred: preferred, configuration: configuration, check: check, identity: identity)
        }
    }
    /// 29 Oct (Asad: "when I start new sessions it says login again"): a Claude login that is definitely signed out
    /// never starts a session that can only answer "Not logged in". The person is told plainly and offered Sign in.
    /// Only a definite "signed-out" refuses; a state that cannot be told starts as before.
    public static let notSignedInMarker = "is not signed in, so no session was started"
    /// Reviewer 29 Oct (MUST): another way in counts. Claude Code also starts with an API key, a token, Bedrock,
    /// Vertex or Foundry, from the session's own environment or its settings file; `claude auth status` may still
    /// say "not logged in" then. Any of them present: never refused.
    public static let otherCredentialVariables: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_BASE_URL"]
    public static let otherCredentialSettings: Set<String> = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport"]
    public static func hasOtherCredential(environment: [String: String], settings: [NativeRPCValue]) -> Bool {
        func set(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if otherCredentialVariables.contains(where: { set(environment[$0]) }) { return true }
        for file in settings {
            if otherCredentialSettings.contains(where: { set(file[$0].string) }) { return true }
            if otherCredentialVariables.contains(where: { set(file["env"][$0].string) }) { return true }
        }
        return false
    }
    /// The refusal, decided in order: the cached state says signed out; no other way in is present; a fresh read
    /// (never the cache) still says signed out.
    public static func refusal(_ login: BackendAccountProfile, check: SignInCheck, environment: [String: String],
                               settings: [NativeRPCValue]) async -> BackendAccountFailure? {
        guard await check(login, false) == "signed-out", !hasOtherCredential(environment: environment, settings: settings) else { return nil }
        return signedOutRefusal(login, state: await check(login, true))
    }
    public static func signedOutRefusal(_ login: BackendAccountProfile, state: String?) -> BackendAccountFailure? {
        guard state == "signed-out" else { return nil }
        let who = login.system ? "This Mac's own Claude Code login" : "The Claude login \u{201C}\(login.name)\u{201D}"
        return BackendAccountFailure("\(who) \(notSignedInMarker). Sign in to it (Settings \u{203A} Coding AIs \u{203A} Sign in), or choose a signed-in account for this session.")
    }
    public func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                        loginPath: String, context: BackendLaunchContext) async throws -> BackendAccountLaunch {
        guard !closed else { throw BackendAccountFailure("The native account runtime has stopped.") }
        // A Claude launch is when a seat matters: a store that opened since the start is used from now on.
        if BackendAccountProfile.signInProviders.contains(provider.id) { await reviveVault() }
        // D11 / TS wire.ts:151/163 (`return null`): with the vault off there is no vault runtime,
        // and sessions still start: a shell or an agent's own login launches as it would with no
        // vault at all; only app-kept accounts are refused (their vault.open below fails).
        let vaultRuntime = await broker.isActive()
        var remove = configuration.vaultVariables
        remove.insert("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        guard BackendAccountProfile.signInProviders.contains(provider.id) else {
            return BackendAccountLaunch(profile: nil, environment: [:], removeEnvironment: remove, path: loginPath)
        }
        // ACCOUNTS-SPEC: this session's own choice, else its project's, the whole app's. A seat's account
        // is applied earlier, where the launcher picks the agent's account (it must be the SAME account
        // the agent-settings step prepared for, or BackendAGSLaunchBinding.requireAccount refuses the launch).
        let login = try await BackendDefaultClaudeLogin.$environmentOverrides.withValue(context.environmentOverrides) {
            try await profiles.resolve(sessionProfileID: input.profileId, projectPath: input.cwd, provider: provider.id)
        }
        guard login.provider == provider.id else { throw BackendAccountFailure("This account belongs to a different agent.") }
        let api = try BackendAPIAccountRecord.read(login)
        guard api != nil || !BackendAPIAccountRecord.isAPIAccountID(login.id) else { throw BackendAccountFailure("This API account's settings are incomplete. No subscription login was used.") }
        if let api {
            guard BackendAccountSignInStorage.ownsFolder(login, configuration: configuration), api.appName == configuration.appName else {
                throw BackendAccountFailure("This API account belongs to another copy of the app.")
            }
            try await BackendAPIAccountCLI.prepare(api, path: loginPath, inherited: configuration.inheritedEnvironment)
            if api.requiresKey { _ = try BackendAPIAccountKeychain.read(api) }
            remove.formUnion(BackendAPIAccountEnvironment.stripped)
        }
        if api == nil, provider.id == "claude", let check = signInCheck {
            // What this session's Claude Code will see: the app's inherited environment and the launch's overrides
            // (the login shell adds only display settings, BackendSessionEnvironment.loginShellSettings), and the
            // account's own settings files plus the machine's managed settings.
            let seen = configuration.inheritedEnvironment.merging(context.environmentOverrides) { _, override in override }
            let folder = login.system ? configuration.systemDirectory("claude") : login.configDir
            let settings = [folder + "/settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json"].map { path -> NativeRPCValue in
                guard let data = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: path), maximum: 1_048_576),
                      let value = try? NativeRPCValue.parseJSON(data), value.fields != nil else { return .object([]) }
                return value
            }
            if let refused = await Self.refusal(login, check: check, environment: seen, settings: settings) { throw refused }
        }
        let loginManaged = await profiles.managed(login)
        if login.promised, !loginManaged, !login.system {
            throw BackendAccountFailure("An account marked as kept by the app points outside its managed account directories. It cannot silently fall back to an agent login.")
        }
        if api == nil, loginManaged {
            do { try await vault.open() }
            catch {
                // REQ P1-2 (host-core.kept-unavailable.test.ts:42): an app-kept login whose
                // store this process cannot open is refused with the source sentence; nothing starts.
                if BackendSessionSwitchKeptLogin.keptBy(login, managed: true, usable: false) == .unavailable {
                    throw BackendAccountFailure(BackendSessionSwitchKeptLogin.unavailableSentence)
                }
                throw error
            }
        }
        // The caller's app-composed flag is kept distinct from MCP/project args
        // appended by launch composition; those ordinary sessions get seats.
        let seated = api == nil && vaultRuntime && provider.id == "claude" && context.deviceBoundary == nil && context.appFenceID == nil && !context.isAppComposed
        var home = login
        if seated, let id = input.homeProfileId, !id.isEmpty, id != login.id,
           let candidate = try await profiles.find(id), candidate.provider == "claude" {
            if await profiles.managed(candidate) { try await vault.open() }
            home = candidate
        }
        var environment: [String: String] = [:]
        if !home.system { environment.merge(BackendAccountStrategies.accountEnv(provider: provider.id, account: (home.provider, home.configDir))) { _, new in new } }
        if let api { environment.merge(BackendAPIAccountEnvironment.reference(api)) { _, new in new } }
        if api == nil, provider.id == "codex", loginManaged {
            try await codex.settle(login)
            if try await vault.read(accountID: login.id, slot: "file:auth.json") != nil { try await profiles.markSlotKept(id: login.id, slot: "file:auth.json") }
        }
        // A device-confined launch cannot use this host's vault socket. Do not
        // start a kept Claude login under stale agent-owned keychain names
        // instead. The app records fence is `(allow default)` with denies only
        // on the records paths, so the vault socket stays reachable and the
        // managed login keeps working there, as in TS (Hoot request 8, O1-R3).
        if api == nil, provider.id == "claude", loginManaged, context.deviceBoundary != nil {
            throw BackendAccountFailure("This app-kept Claude login needs the native vault handoff. A fenced or device launch cannot use that host socket; provide a separately established confined login.")
        }
        let reservationID = try BackendAccountFiles.randomHex(bytes: 24)
        var ticket: String?, ticketIsSeat = false
        if seated {
            let seat = try await broker.allocate(home: home, serving: login)
            ticket = seat.ticket; ticketIsSeat = true
            environment.merge(seat.environment) { _, replacement in replacement }
        } else if api == nil, provider.id == "claude", loginManaged {
            let probe = try await broker.allocateAccount(login)
            ticket = probe.ticket; environment.merge(probe.environment) { _, replacement in replacement }
        }
        var transcriptConfiguration = home.configDir
        var identity = api != nil || ["claude", "codex"].contains(provider.id) ? login.identity : nil
        if let key = BackendAccountProfile.configEnvironment(provider.id), let override = context.environmentOverrides[key], !override.isEmpty {
            let expected = URL(fileURLWithPath: home.configDir).standardizedFileURL.path
            let actual = URL(fileURLWithPath: override).standardizedFileURL.path
            if actual != expected {
                if seated { if let ticket { await broker.abandon(ticket: ticket) }; throw BackendAccountFailure("Launch composition would redirect the selected account to another directory. No session was started.") }
                transcriptConfiguration = actual
                identity = (try await profiles.list(provider: provider.id)).first { URL(fileURLWithPath: $0.configDir).standardizedFileURL.path == actual }?.identity
            }
        }
        if home.system, provider.id == "claude", let device = context.deviceBoundary {
            transcriptConfiguration = configuration.dataDirectory.appendingPathComponent("remote/device-home").appendingPathComponent(device.deviceKey).appendingPathComponent(".claude").path
            identity = nil
        }
        reservations[reservationID] = Reservation(home: home, login: login, ticket: ticket, ticketIsSeat: ticketIsSeat, transcriptConfiguration: transcriptConfiguration)
        // PTY composition applies removals last. Keep only the keys this launch
        // explicitly reassigns, including its fresh secure-store directory.
        remove.subtract(Set(environment.keys))
        let path = ticket == nil ? loginPath : ([broker.shimDirectory] + loginPath.split(separator: ":").map(String.init).filter { $0 != broker.shimDirectory }).joined(separator: ":")
        return BackendAccountLaunch(profile: identity,
            homeProfileID: home.id == login.id ? nil : home.id, environment: environment,
            removeEnvironment: remove, path: path, reservationID: reservationID)
    }
    #if TD_HOST_INTEGRATED
    /// Backend reservation truth only; renderer flags cannot make a kept login independent.
    public func hostIndependent(_ account: BackendAccountLaunch) async -> Bool {
        guard !closed else { return false }
        guard let id = account.reservationID else {
            return account.profile == nil && account.homeProfileID == nil && account.environment.isEmpty
        }
        guard let value = reservations[id], value.ticket == nil, !value.home.promised, !value.login.promised else { return false }
        guard !(await profiles.managed(value.home)), !(await profiles.managed(value.login)) else { return false }
        return true
    }
    #endif
    public func continuingConversationID(_ input: BackendCreateSessionInput, account: BackendAccountLaunch,
                                          live: [BackendSessionMeta]) async throws -> String? {
        guard let id = account.reservationID, let reservation = reservations[id], reservation.home.provider == "claude" else { return nil }
        let directories = NativeTranscriptPaths.projectSpellings(input.cwd).map {
            URL(fileURLWithPath: reservation.transcriptConfiguration).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath($0))
        }
        let claimed = Set(live.filter { $0.exitCode == nil && $0.provider == "claude" && $0.id != input.replaces }.compactMap(\.agentSessionId))
        return try await Task.detached(priority: .utility) {
            try BackendConversationRecovery.read(directories: directories, startedAt: Date(), claimed: claimed)
        }.value
    }
    public func bind(_ account: BackendAccountLaunch, session: BackendSessionMeta) async throws {
        guard let id = account.reservationID, let reservation = reservations[id] else {
            if account.profile == nil { return }
            throw BackendAccountFailure("The native account launch reservation is missing.")
        }
        if let ticket = reservation.ticket, reservation.ticketIsSeat { try await broker.bind(ticket: ticket, sessionID: session.id) }
        sessions[session.id] = reservation; reservations[id] = nil
        sessionTitles[session.id] = session.title; endedSessions.remove(session.id)
        boundReservations[id] = session.id
        try await profiles.markUsed(id: reservation.login.id, projectPath: session.cwd)
    }
    public func abandon(_ account: BackendAccountLaunch) async {
        guard let id = account.reservationID else { return }
        if let reservation = reservations.removeValue(forKey: id), let ticket = reservation.ticket, reservation.ticketIsSeat { await broker.abandon(ticket: ticket) }
        // bind may have completed before a later launch dependency failed.
        if let sessionID = boundReservations.removeValue(forKey: id) { forget(sessionID); await broker.release(sessionID: sessionID) }
    }
    public func exited(sessionID: String) async {
        forget(sessionID); boundReservations = boundReservations.filter { $0.value != sessionID }; await broker.release(sessionID: sessionID)
    }
    private func forget(_ sessionID: String) {
        sessions[sessionID] = nil; sessionTitles[sessionID] = nil; endedSessions.remove(sessionID)
    }

    /// The configuration directory governing settings/transcripts may remain
    /// the launch account's while the seat serves a switched login.
    public func transcriptConfiguration(sessionID: String) -> String? { sessions[sessionID]?.transcriptConfiguration }
    public func sessionHomeProfile(sessionID: String) -> BackendAccountProfile? { sessions[sessionID]?.home }
    public func retargetSeat(sessionID: String, accountID: String) async throws -> Bool { try await broker.retarget(sessionID: sessionID, accountID: accountID) }
    public func accountHomeScopes() -> [NativeTranscriptHomeScope] {
        configuration.homeScopes
    }
    public func createProfile(name: String, provider: String = "claude", configDir: String? = nil) async throws -> BackendAccountProfile {
        let broker = self.broker, vault = self.vault, codex = self.codex, profiles = self.profiles
        let profile = try await profiles.create(name: name, provider: provider, configDir: configDir, vaultManaged: true) { draft in
            if await profiles.managed(draft), draft.promised {
                await broker.revoke(accountID: draft.id)
                try await vault.forget(accountID: draft.id)
                if draft.provider == "codex" { try await codex.forget(draft) }
            }
        }
        if !BackendAPIAccountRecord.isAPIAccountID(profile.id), await profiles.managed(profile), profile.promised {
            if provider == "codex" { try await codex.settle(profile) }
        }
        return profile
    }
    public struct DeleteResult: Sendable { public let removed: Bool; public let filesDeleted: Bool; public let credentialsRetained: Bool; public let warning: String? }
    public func deleteProfile(id: String, deleteFiles: Bool = false) async throws -> DeleteResult {
        guard let profile = try await profiles.find(id), !profile.system else {
            _ = try await profiles.removeMetadata(id: id)   // throws the TS sentence (profiles.ts:1226 own install / :1234 no profile)
            throw BackendAccountFailure("no profile with id \(id)")
        }
        let managed = await profiles.managed(profile)
        // TS profiles.ts:1243: isolation is read before the files go; keptInApp = profileKeptBy(profile) === 'app'.
        let isolation = BackendAccountProfileStatus.isolation(credentialsInConfigDir: BackendAccountProfileStatus.hasCredentialFile(profile))
        let keptInApp = BackendSessionSwitchKeptLogin.keptBy(profile, managed: managed, usable: await vault.openState() == .ready) == .app
        await broker.revoke(accountID: id)
        var warning: String?
        if managed {
            if profile.provider == "codex" { try await codex.forget(profile) }
            do { try await vault.forget(accountID: id) } catch { warning = error.localizedDescription }
        }
        _ = try await profiles.removeMetadata(id: id)
        let deleted = deleteFiles ? try await profiles.deleteManagedDirectory(profile) : false
        let retained = BackendAccountProfileStatus.credentialsRetained(keptInApp: keptInApp, forgot: warning == nil, filesDeleted: deleted, isolation: isolation)
        return DeleteResult(removed: true, filesDeleted: deleted, credentialsRetained: retained, warning: warning)
    }
    /// A folded copy is removed only after its folder can be kept in a backup.
    /// A failed vault forget leaves the entry and folder in place.
    public func removeCopy(id: String) async throws -> (removed: Bool, backup: String?) {
        guard let profile = try await profiles.find(id), !profile.system else {
            throw BackendAccountFailure("This Mac's own account cannot be removed. Choose Remove copy beside the saved copy.")
        }
        guard !apiProfileInUse(id) else {
            throw BackendAccountFailure("This copy is in use. Keep it for now, or finish its sessions before choosing Remove copy.")
        }
        try BackendAccountCopyBackup.validate(profile, configuration: configuration)
        var heldSlots: [(slot: String, value: String)] = []
        if profile.promised {
            try await vault.open()
            for slot in await vault.summary(id)?.slots ?? [] {
                if let value = try await vault.read(accountID: id, slot: slot) { heldSlots.append((slot, value)) }
            }
        }
        let backup = try BackendAccountCopyBackup.archive(profile, configuration: configuration)
        do {
            if profile.promised { try await vault.forget(accountID: id) }
            if profile.provider == "codex" { try await codex.forget(profile) }
            _ = try await profiles.removeMetadata(id: id)
            await broker.revoke(accountID: id)
            return (true, backup?.path)
        } catch {
            // Only this account's old slots are restored; another account's
            // concurrent refresh is never overwritten by a whole-vault rollback.
            for held in heldSlots {
                _ = try? await vault.put(accountID: id, provider: profile.provider, slot: held.slot,
                                        value: held.value, source: "remove-copy-rollback")
            }
            do { try BackendAccountCopyBackup.restore(backup, profile: profile) }
            catch {
                throw BackendAccountFailure("The copy was not removed completely. Its history is safe in \(backup?.path ?? profile.configDir). Open that folder in Finder to restore it before trying Remove copy again.")
            }
            throw error
        }
    }

    /// Root stops owned CLI children first, then calls this, then closes the
    /// shared NativeStateStore. A foreign Codex user retains its live lease.
    public func shutdown() async -> [String: BackendAccountCodexLease.Release] {
        closed = true
        let releases = await codex.releaseAll()
        await broker.close(); await codex.dispose(); await vault.close(); await profiles.close()
        reservations.removeAll(); sessions.removeAll(); boundReservations.removeAll(); sessionTitles.removeAll(); endedSessions.removeAll()
        return releases
    }
}
