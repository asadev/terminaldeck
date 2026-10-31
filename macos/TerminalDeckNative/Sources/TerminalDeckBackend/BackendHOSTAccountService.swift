import Foundation
import Darwin
import TerminalDeckNativeCore

/// The existing account actors live in the helper. App attachment is only a
/// client; detaching it cannot close the broker, shim, vault or Codex leases.
public actor BackendHOSTAccountService {
    public nonisolated let accounts: BackendAccountLaunchAdapter
    public nonisolated let authority: NativeStateStore
    public nonisolated let configuration: BackendAccountConfiguration
    private struct Pending: Sendable {
        let account: BackendAccountLaunch
        let expiry: Task<Void, Never>
        let provider: String
        let externalAllowed: Bool
    }
    private var pending: [String: Pending] = [:]
    private var sessions: Set<String> = []
    private var bound: [String: String] = [:]
    private var boundAccounts: [String: BackendAccountLaunch] = [:]
    private let apiCredentialAvailable: @Sendable (BackendAPIAccountRecord) -> Bool
    private var stopped = false
    private var completedReleases: [String: BackendAccountCodexLease.Release] = [:]
    #if TD_HOST_ACCOUNT_BRIDGE
    private struct External {
        let meta: BackendSessionMeta
        let rootPID: Int32
        var identities: [Int32: BackendHOSTOrphanIdentity]
        var watches: [Int32: BackendHOSTOrphanWatch]
    }
    private var external: [String: External] = [:]
    private func externalIdentity(_ pid: Int32) throws -> BackendHOSTOrphanIdentity? {
        guard let info = try BackendHOSTOrphanDarwin.bsd(pid), info.pbi_uid == geteuid() else { return nil }
        return BackendHOSTOrphanDarwin.identity(info, words: [], zombie: info.pbi_status == UInt32(SZOMB))
    }
    private func belongs(_ child: BackendHOSTOrphanIdentity, appPID: Int32) throws -> Bool {
        var parent = child.parentPID, seen: Set<Int32> = []
        for _ in 0..<64 {
            if parent == appPID { return true }
            guard parent > 1, seen.insert(parent).inserted, let actual = try externalIdentity(parent), !actual.zombie else { return false }
            parent = actual.parentPID
        }
        return false
    }
    /// 18 Oct (#134): a process that has gone leaves the record (and its watch ends), and what is found is kept even when
    /// the walk stops early, so the 1,024 budget counts live processes, not every one a long session ever started; a
    /// session whose helpers have all ended is released instead of failing the budget for ever.
    private func inspectExternal(_ id: String) throws -> Bool {
        guard var value = external[id] else { return true }
        defer { external[id] = value }
        var pending = Array(value.identities.values), seen: Set<Int32> = [], alive = 0
        while let expected = pending.popLast() {
            guard seen.insert(expected.pid).inserted else { continue }
            guard let actual = try externalIdentity(expected.pid), actual.sameProcess(as: expected), !actual.zombie else {
                if value.identities[expected.pid] == expected {
                    value.identities[expected.pid] = nil; value.watches.removeValue(forKey: expected.pid)?.cancel()
                }
                continue
            }
            alive += 1
            guard alive <= 1_024 else { throw BackendHOSTOrphanFailure.budget }
            for pid in try BackendHOSTOrphanDarwin.children(actual.pid) {
                guard let child = try externalIdentity(pid), child.parentPID == actual.pid else { continue }
                if value.identities[pid] == nil {
                    value.identities[pid] = child
                    guard let watch = BackendHOSTOrphanKernel.live.watch(pid, { [weak self] in Task { await self?.externalChanged(id) } }) else { throw BackendHOSTFailure.unavailable }
                    value.watches[pid] = watch
                }
                pending.append(child)
            }
        }
        return alive == 0
    }
    private func externalChanged(_ id: String) async {
        guard (try? inspectExternal(id)) == true else { return }
        await exited(sessionID: id)
    }
    public func externalSessionsDrained() async throws -> Bool {
        var drained = true
        for id in Array(external.keys) {
            if try inspectExternal(id) { await exited(sessionID: id) } else { drained = false }
        }
        return drained
    }
    public func externalPID(_ id: String) throws -> Int32? {
        guard let row = external[id], let root = row.identities[row.rootPID] else { return nil }
        guard let actual = try externalIdentity(root.pid), actual.sameProcess(as: root), !actual.zombie else { return nil }; return root.pid
    }
    public func externalMetadata(_ id: String) -> BackendSessionMeta? { external[id]?.meta }
    #endif

    private init(accounts: BackendAccountLaunchAdapter, authority: NativeStateStore, configuration: BackendAccountConfiguration,
                 apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool) {
        self.accounts = accounts; self.authority = authority; self.configuration = configuration; self.apiCredentialAvailable = apiCredentialAvailable
    }

    public static func start(configuration: BackendAccountConfiguration, nativeAccountOwnerDisabled: Bool,
                             vaultCipher: (any BackendAccountVaultCipher)? = nil,
                             apiCredentialAvailable: @escaping @Sendable (BackendAPIAccountRecord) -> Bool = { BackendAPIAccountKeychain.contains($0) },
                             brokerFactory: (@Sendable (BackendAccountConfiguration, BackendAccountProfileStore, BackendAccountVault) async throws -> BackendAccountBroker)? = nil) async throws -> BackendHOSTAccountService {
        guard nativeAccountOwnerDisabled else { throw BackendSessionFailure.missingCapability("exclusive host account ownership") }
        // Separate helper authority record, never a second writer of state.json.
        // profiles.json/vault each retain their existing real single-writer lock.
        let file = configuration.dataDirectory.appendingPathComponent(".host-account-authority.json")
        let state = try NativeStateStore(file: file, ownership: .exclusive)
        var profiles: BackendAccountProfileStore?
        var vault: BackendAccountVault?
        var broker: BackendAccountBroker?
        do {
            let profileStore = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
            profiles = profileStore; _ = try await profileStore.snapshot()
            let actualCipher = vaultCipher ?? BackendAccountKeychainCipher(appName: configuration.appName)
            let accountVault = try BackendAccountVault(configuration: configuration, stateStore: state, vaultCipher: actualCipher)
            vault = accountVault
            let accountBroker: BackendAccountBroker
            do {
                if let brokerFactory { accountBroker = try await brokerFactory(configuration, profileStore, accountVault) }
                else { accountBroker = try await BackendAccountBroker.start(configuration: configuration, profiles: profileStore, vault: accountVault) }
            }
            catch {
                let locked = await accountVault.openState() == .locked
                let fresh = !FileManager.default.fileExists(atPath: accountVault.file.path)
                guard locked || fresh else { throw error }
                // Existing D11 behavior: unavailable kept logins never become
                // a substitute system login; agent-owned logins still work.
                // 12 Oct: off only until the saved logins open (reviveIfOff); a test-supplied factory has no
                // bundled helper to check when that happens.
                accountBroker = BackendAccountBroker.vaultOff(configuration: configuration, profiles: profileStore, vault: accountVault,
                    verifyHelperOnRevive: brokerFactory == nil)
            }
            broker = accountBroker
            let codex = BackendAccountCodexLease.wired(vault: accountVault, profiles: profileStore)
            let adapter = try BackendAccountLaunchAdapter(configuration: configuration, profiles: profileStore,
                vault: accountVault, broker: accountBroker, codex: codex)
            do { try await adapter.prepareExistingAccounts() }
            catch { _ = await adapter.shutdown(); throw error }
            return BackendHOSTAccountService(accounts: adapter, authority: state, configuration: configuration, apiCredentialAvailable: apiCredentialAvailable)
        } catch {
            await broker?.close(); await vault?.close(); await profiles?.close(); await state.close()
            throw error
        }
    }

    public func resolve(input: BackendCreateSessionInput, provider: BackendProviderSpec,
                        loginPath: String, scope: BackendHOSTProtocol.Scope?, environmentOverrides: [String: String] = [:], removeEnvironment: Set<String> = []) async throws -> BackendHOSTAccountWire {
        // 22 Oct (Asad): no count limit; each reservation expires after 60 s on its own.
        guard !stopped else { throw BackendSessionFailure.closed }
        let context = BackendLaunchContext(deviceBoundary: scope?.deviceBoundary, appFenceID: scope?.appFenceID,
            rememberTab: scope?.rememberTab ?? true, environmentOverrides: environmentOverrides,
            removeEnvironment: removeEnvironment, isAppComposed: scope?.isAppComposed ?? false)
        let account = try await accounts.resolve(input, provider: provider, loginPath: loginPath, context: context)
        guard !stopped else { await accounts.abandon(account); throw BackendSessionFailure.closed }
        let handle = UUID().uuidString.lowercased()
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)); await self?.abandon(handle) } catch {}
        }
        let externalAllowed = input.chat == true || input.origin.map { $0 != .user } == true || input.originApp != nil || input.taskID != nil || input.taskProject != nil || scope?.deviceBoundary != nil || scope?.appFenceID != nil || scope?.isAppComposed == true
        pending[handle] = Pending(account: account, expiry: expiry, provider: provider.id, externalAllowed: externalAllowed)
        return BackendHOSTAccountWire(handle: handle, account: account)
    }

    /// Can run before exec using the actual gated child pid, or after create
    /// for existing source-compatible launches. Binding never changes argv/env.
    public func bind(handle: String, session: BackendSessionMeta, pid: Int32?) async throws {
        guard !stopped else { throw BackendSessionFailure.closed }
        if bound[handle] == session.id { return }
        guard let value = pending.removeValue(forKey: handle) else { throw BackendAccountFailure("The host account reservation expired or was already bound.") }
        value.expiry.cancel()
        do {
            try Task.checkCancellation()
            try await accounts.bind(value.account, session: session)
            try Task.checkCancellation()
            if let pid, await accounts.broker.seatSnapshot(sessionID: session.id) != nil {
                try await accounts.broker.bindProcess(sessionID: session.id, pid: pid)
            }
            sessions.insert(session.id)
            bound[handle] = session.id
            boundAccounts[handle] = value.account
            if session.exitCode != nil { await exited(sessionID: session.id) }
        } catch { await accounts.abandon(value.account); throw error }
    }
    public func abandon(_ handle: String) async {
        if let value = pending.removeValue(forKey: handle) {
            value.expiry.cancel(); await accounts.abandon(value.account); return
        }
        if let account = boundAccounts.removeValue(forKey: handle) {
            if let id = bound.removeValue(forKey: handle) { sessions.remove(id) }
            await accounts.abandon(account)
        }
    }
    public func exited(sessionID: String) async {
        #if TD_HOST_ACCOUNT_BRIDGE
        if external[sessionID] != nil {
            await accounts.agentEnded(sessionID: sessionID)
            guard (try? inspectExternal(sessionID)) == true else { return }
            if let value = external.removeValue(forKey: sessionID) { for watch in value.watches.values { watch.cancel() } }
        }
        #endif
        sessions.remove(sessionID); await accounts.exited(sessionID: sessionID)
        // 18 Oct (#410): the ended session's handle goes too, so this list holds live sessions only.
        for handle in bound.filter({ $0.value == sessionID }).map(\.key) { boundAccounts[handle] = nil; bound[handle] = nil }
    }
    public func continuing(handle: String, input: BackendCreateSessionInput, live: [BackendSessionMeta]) async throws -> String? {
        guard let value = pending[handle] else { throw BackendAccountFailure("No pending host account reservation exists.") }
        return try await accounts.continuingConversationID(input, account: value.account, live: live)
    }
    /// The host's `switch.plan` answer (12 Oct). In place where the live session has a seat bound to its
    /// process; `reason: "no-seat"` for a Claude session started before switching was ready (the app offers a
    /// restart that resumes the conversation instead); every other answer a refusal in plain words. The broker
    /// is tried first, so a store that opened since the host started serves every launch from now on.
    public func switchPlan(sessionID: String, targetID: String, live: BackendSessionMeta?, pid: Int32?,
                           currentPID: @Sendable () -> Int32?) async throws -> NativeRPCValue {
        func refused(_ sentence: String) -> NativeRPCValue {
            .object([.init("verified", .bool(false)), .init("mode", .string("refused")), .init("pid", .null), .init("refusal", .string(sentence))])
        }
        guard let live, live.exitCode == nil, let pid else { return refused("That session is not running any more, so there is nothing to switch.") }
        guard live.provider == "claude" else { return refused("Only a Claude session can change account while it runs. Open a new session on that account instead.") }
        guard let target = try await accounts.profiles.find(targetID), target.provider == "claude" else {
            return refused("That account is not a Claude account on this Mac any more. Pick another one.")
        }
        if let why = BackendSessionSwitchCoordinator.apiTargetRefusal(target, configuration: configuration, credentialAvailable: apiCredentialAvailable) { return refused(why) }
        if BackendSessionSwitchCoordinator.requiresAccountReplacement(sourceID: live.profileId, targetID: target.id) {
            guard currentPID() == pid else { return refused("This session changed while it was being checked, so it was left as it is. Try again.") }
            // Existing app fallback carries the conversation and verifies the new process before stopping this one.
            return .object([.init("verified", .bool(false)), .init("mode", .string("restart")), .init("reason", .string("no-seat")),
                .init("pid", .number(Double(pid))), .init("refusal", .null), .init("notice", .string(SwitchAccountRestartOffer.notReady))])
        }
        await accounts.reviveVault()
        guard let seat = await accounts.broker.seatSnapshot(sessionID: sessionID), seat.processPID == pid, let serving = seat.servingAccountID else {
            return .object([.init("verified", .bool(false)), .init("mode", .string("restart")), .init("reason", .string("no-seat")),
                .init("pid", .number(Double(pid))), .init("refusal", .null), .init("notice", .string(SwitchAccountRestartOffer.notReady))])
        }
        guard serving != targetID else { return refused("This session is already running as that account.") }
        guard currentPID() == pid else { return refused("This session changed while it was being checked, so it was left as it is. Try again.") }
        return .object([.init("verified", .bool(true)), .init("mode", .string("in-place")), .init("pid", .number(Double(pid))), .init("refusal", .null)])
    }
    public func retarget(sessionID: String, accountID: String) async throws -> Bool {
        guard sessions.contains(sessionID) else { throw BackendSessionFailure.missingSession }
        return try await accounts.retargetSeat(sessionID: sessionID, accountID: accountID)
    }
    public func detachApp() {} // Deliberately retains the existing live actors.
    public func counts() -> (pending: Int, live: Int) { (pending.count, sessions.count) }
    public func liveSessionIDs() -> [String] { Array(sessions) }
    public func stop(afterProcessDrain drained: Bool) async throws {
        guard drained else { throw BackendHOSTFailure.remote("Session processes have not drained; their account leases remain open.") }
        #if TD_HOST_ACCOUNT_BRIDGE
        guard try await externalSessionsDrained() else { throw BackendHOSTFailure.remote("App-owned sessions still hold their original account reservations.") }
        #endif
        guard !stopped else { return }; stopped = true
        for handle in Array(pending.keys) { await abandon(handle) }
        for session in Array(sessions) { await exited(sessionID: session) }
        completedReleases = await accounts.shutdown(); await authority.close()
    }
    public func shutdownReleases() -> [String: BackendAccountCodexLease.Release] { completedReleases }

    /// Internal authenticated socket dispatcher, never a renderer/MCP channel.
    public func invoke(_ method: String, payload: Data, manager: BackendPTYManager, appPID: Int32? = nil) async throws -> Data {
        let args = try NativeRPCValue.parseJSON(payload, maximumBytes: BackendHOSTProtocol.maximumRequestBytes)
        let probe = BackendHOSTSessionProbe(manager: manager)
        let value: NativeRPCValue
        func decode<T: Decodable>(_ type: T.Type, _ field: String) throws -> T { try JSONDecoder().decode(type, from: args[field].encodedJSON()) }
        switch method {
        case "account.status": value = .object([.init("ready", .bool(!stopped)), .init("apiKeyAccounts", .bool(true)), .init("pending", .number(Double(pending.count))), .init("live", .number(Double(sessions.count)))])
        case "account.resolve", "account.chat.resolve":
            let input = try decode(BackendCreateSessionInput.self, "input")
            guard method != "account.chat.resolve" || input.chat == true else { throw BackendHOSTFailure.authentication }
            let provider = BackendProviderSpec(id: try args["provider"]["id"].requireString("provider"),
                command: try args["provider"]["command"].requireString("command"),
                args: (args["provider"]["args"].elements ?? []).compactMap(\.string), resumeArgs: (args["provider"]["resumeArgs"].elements ?? []).compactMap(\.string))
            let scope = args["scope"].isNullish ? nil : try decode(BackendHOSTProtocol.Scope.self, "scope")
            let overrides = Dictionary(uniqueKeysWithValues: (args["privateContext"]["environmentOverrides"].fields ?? []).compactMap { field in field.value.string.map { (field.key, $0) } })
            let removals = Set((args["privateContext"]["removeEnvironment"].elements ?? []).compactMap(\.string))
            let loginPath = try args["path"].requireString("login PATH")
            let answer = try await resolve(input: input, provider: provider, loginPath: loginPath, scope: scope,
                environmentOverrides: overrides, removeEnvironment: removals)
            value = try NativeRPCValue.parseJSON(JSONEncoder().encode(answer))
        case "account.bind":
            let offered = try decode(BackendSessionMeta.self, "session"), found = await probe.session(offered.id)
            guard let actual = found.meta, actual.provider == offered.provider else { throw BackendSessionFailure.missingSession }
            try await bind(handle: args["handle"].requireString("account reservation"), session: actual, pid: found.pid); value = .null
        case "account.pid-bound":
            let id = try args["id"].requireString("hosted session id")
            #if TD_HOST_ACCOUNT_BRIDGE
            if let registered = external[id] {
                let pid = try externalPID(id)
                guard registered.meta.createdAt == args["expectedCreatedAt"].number, pid.map(Double.init) == args["pid"].number else { throw BackendHOSTFailure.authentication }
                value = .bool(true); break
            }
            #endif
            let found = await probe.session(id)
            guard let actual = found.meta, sessions.contains(id),
                  let pid = found.pid, args["pid"].number == Double(pid),
                  args["expectedCreatedAt"].number == actual.createdAt else { throw BackendHOSTFailure.authentication }
            if let seat = await accounts.broker.seatSnapshot(sessionID: id), seat.processPID != pid { throw BackendHOSTFailure.authentication }
            // The helper already bound this reservation at the gated child PID.
            // No new app-side seat or mutation is made by this acknowledgment.
            value = .bool(true)
        #if TD_HOST_ACCOUNT_BRIDGE
        case "account.external.bind":
            let handle = try args["handle"].requireString("original app account reservation"), meta = try decode(BackendSessionMeta.self, "session")
            let hosted = await probe.session(meta.id).meta != nil
            if bound[handle] == meta.id, let actual = external[meta.id] {
                guard actual.meta == meta, args["pid"].number == (try externalPID(meta.id)).map(Double.init) else { throw BackendHOSTFailure.authentication }
                value = .null; break
            }
            guard let appPID, appPID > 1, let number = args["pid"].number, number.isFinite, let pid = Int32(exactly: number), pid > 1,
                  !hosted, let reservation = pending[handle], reservation.externalAllowed,
                  reservation.provider == meta.provider, meta.profileId == reservation.account.profile?.id,
                  let child = try externalIdentity(pid), !child.zombie, try belongs(child, appPID: appPID) else { throw BackendHOSTFailure.authentication }
            guard let watch = BackendHOSTOrphanKernel.live.watch(pid, { [weak self] in Task { await self?.externalChanged(meta.id) } }) else { throw BackendHOSTFailure.unavailable }
            external[meta.id] = External(meta: meta, rootPID: pid, identities: [pid: child], watches: [pid: watch])
            do {
                try await bind(handle: handle, session: meta, pid: pid)
                guard let current = try externalIdentity(pid), current.sameProcess(as: child), !current.zombie else { throw BackendHOSTFailure.authentication }
                _ = try inspectExternal(meta.id); value = .null
            } catch {
                if let row = external.removeValue(forKey: meta.id) { for watch in row.watches.values { watch.cancel() } }
                await abandon(handle); throw error
            }
        #endif
        case "account.abandon": await abandon(try args["handle"].requireString("account reservation")); value = .null
        case "account.exited":
            let id = try args["id"].requireString("session id")
            guard await probe.session(id).pid == nil else { throw BackendHOSTFailure.invalid("A running session's account lease cannot be released.") }
            await exited(sessionID: id); value = .null
        case "account.continuing":
            let id = try await continuing(handle: args["handle"].requireString("account reservation"), input: decode(BackendCreateSessionInput.self, "input"), live: await probe.rows())
            value = id.map(NativeRPCValue.string) ?? .null
        case "account.retarget": value = .bool(try await retarget(sessionID: args["id"].requireString("session id"), accountID: args["account"].requireString("account id")))
        case "account.transcript":
            let id = try args["id"].requireString("session id")
            value = await accounts.transcriptConfiguration(sessionID: id).map(NativeRPCValue.string) ?? .null
        default: throw BackendHOSTFailure.invalid("Unknown persistent account operation.")
        }
        return try value.encodedJSON()
    }
}

public struct BackendHOSTAccountWire: Codable, Sendable {
    public var handle: String
    public var profile: BackendAccountIdentity?
    public var homeProfileID: String?
    public var environment: [String: String]
    public var removeEnvironment: [String]
    public var path: String
    public init(handle: String, account: BackendAccountLaunch) {
        self.handle = handle; profile = account.profile; homeProfileID = account.homeProfileID
        environment = account.environment; removeEnvironment = account.removeEnvironment.sorted(); path = account.path
    }
    public var launch: BackendAccountLaunch {
        .init(profile: profile, homeProfileID: homeProfileID, environment: environment,
              removeEnvironment: Set(removeEnvironment), path: path, reservationID: handle)
    }
}

extension BackendHOSTProtocol.Scope {
    public var context: BackendLaunchContext {
        .init(deviceBoundary: deviceBoundary, appFenceID: appFenceID, rememberTab: rememberTab, isAppComposed: isAppComposed)
    }
}

/// What one host request names, read off the asking actor: the manager may be waiting on that actor at a child's
/// pre-exec gate. 22 Oct (Asad "Fix the host"): every request used to read every session and every session's process
/// first, whatever it asked. With 115 sessions and the app asking once per session, that kept the host on 1.5–2.5 cores.
struct BackendHOSTSessionProbe: Sendable {
    let manager: BackendPTYManager
    /// The named session as listed, and its running process.
    func session(_ id: String) async -> (meta: BackendSessionMeta?, pid: Int32?) {
        await Task.detached { [manager] () -> (meta: BackendSessionMeta?, pid: Int32?) in
            guard let meta = manager.list().first(where: { $0.id == id }) else { return (nil, nil) }
            return (meta, manager.pidOf(id))
        }.value
    }
    /// Every listed session, without asking any for its process.
    func rows() async -> [BackendSessionMeta] { await Task.detached { [manager] in manager.list() }.value }
}
