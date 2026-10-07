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
    private var closed = false

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
            guard await profiles.managed(profile) else { continue }
            try await codex.settle(profile)
            if try await vault.read(accountID: profile.id, slot: "file:auth.json") != nil { try await profiles.markSlotKept(id: profile.id, slot: "file:auth.json") }
        }
    }
    public func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                        loginPath: String, context: BackendLaunchContext) async throws -> BackendAccountLaunch {
        guard !closed else { throw BackendAccountFailure("The native account runtime has stopped.") }
        // D11 / TS wire.ts:151/163 (`return null`): with the vault off there is no vault runtime,
        // and sessions still start: a shell or an agent's own login launches as it would with no
        // vault at all; only app-kept accounts are refused (their vault.open below fails).
        let vaultRuntime = await broker.isActive()
        var remove = configuration.vaultVariables
        remove.insert("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        guard BackendAccountProfile.signInProviders.contains(provider.id) else {
            return BackendAccountLaunch(profile: nil, environment: [:], removeEnvironment: remove, path: loginPath)
        }
        let login = try await profiles.resolve(sessionProfileID: input.profileId, projectPath: input.cwd, provider: provider.id)
        guard login.provider == provider.id else { throw BackendAccountFailure("This account belongs to a different agent.") }
        let loginManaged = await profiles.managed(login)
        if login.promised, !loginManaged, !login.system {
            throw BackendAccountFailure("An account marked as kept by the app points outside its managed account directories. It cannot silently fall back to an agent login.")
        }
        if loginManaged {
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
        let seated = vaultRuntime && provider.id == "claude" && context.deviceBoundary == nil && context.appFenceID == nil && !context.isAppComposed
        var home = login
        if seated, let id = input.homeProfileId, !id.isEmpty, id != login.id,
           let candidate = try await profiles.find(id), candidate.provider == "claude" {
            if await profiles.managed(candidate) { try await vault.open() }
            home = candidate
        }
        var environment: [String: String] = [:]
        if !home.system { environment.merge(BackendAccountStrategies.accountEnv(provider: provider.id, account: (home.provider, home.configDir))) { _, new in new } }
        if provider.id == "codex", loginManaged {
            try await codex.settle(login)
            if try await vault.read(accountID: login.id, slot: "file:auth.json") != nil { try await profiles.markSlotKept(id: login.id, slot: "file:auth.json") }
        }
        // A device-confined launch cannot use this host's vault socket. Do not
        // start a kept Claude login under stale agent-owned keychain names
        // instead. The app records fence is `(allow default)` with denies only
        // on the records paths, so the vault socket stays reachable and the
        // managed login keeps working there, as in TS (Hoot request 8, O1-R3).
        if provider.id == "claude", loginManaged, context.deviceBoundary != nil {
            throw BackendAccountFailure("This app-kept Claude login needs the native vault handoff. A fenced or device launch cannot use that host socket; provide a separately established confined login.")
        }
        let reservationID = try BackendAccountFiles.randomHex(bytes: 24)
        var ticket: String?, ticketIsSeat = false
        if seated {
            let seat = try await broker.allocate(home: home, serving: login)
            ticket = seat.ticket; ticketIsSeat = true
            environment.merge(seat.environment) { _, replacement in replacement }
        } else if provider.id == "claude", loginManaged {
            let probe = try await broker.allocateAccount(login)
            ticket = probe.ticket; environment.merge(probe.environment) { _, replacement in replacement }
        }
        var transcriptConfiguration = home.configDir
        var identity = ["claude", "codex"].contains(provider.id) ? login.identity : nil
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
        boundReservations[id] = session.id
        try await profiles.markUsed(id: reservation.login.id)
    }
    public func abandon(_ account: BackendAccountLaunch) async {
        guard let id = account.reservationID else { return }
        if let reservation = reservations.removeValue(forKey: id), let ticket = reservation.ticket, reservation.ticketIsSeat { await broker.abandon(ticket: ticket) }
        // bind may have completed before a later launch dependency failed.
        if let sessionID = boundReservations.removeValue(forKey: id) { sessions[sessionID] = nil; await broker.release(sessionID: sessionID) }
    }
    public func exited(sessionID: String) async {
        sessions[sessionID] = nil; boundReservations = boundReservations.filter { $0.value != sessionID }; await broker.release(sessionID: sessionID)
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
            if await profiles.managed(draft) {
                await broker.revoke(accountID: draft.id)
                try await vault.forget(accountID: draft.id)
                if draft.provider == "codex" { try await codex.forget(draft) }
            }
        }
        if await profiles.managed(profile) {
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
    /// Root stops owned CLI children first, then calls this, then closes the
    /// shared NativeStateStore. A foreign Codex user retains its live lease.
    public func shutdown() async -> [String: BackendAccountCodexLease.Release] {
        closed = true
        let releases = await codex.releaseAll()
        await broker.close(); await codex.dispose(); await vault.close(); await profiles.close()
        reservations.removeAll(); sessions.removeAll(); boundReservations.removeAll()
        return releases
    }
}
