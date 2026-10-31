import Foundation
import TerminalDeckNativeCore

/// Only the four display fields sent by account-serve.ts; commands, paths and
/// checkedAt never leave the machine through this surface.
public struct BackendRemoteServeAccountSignIn: Sendable {
    public enum State: String, Sendable { case signedIn = "signed-in", signedOut = "signed-out", unknown, unsupported }
    public let state: State
    public let account: String?, plan: String?
    public let detail: String
    public init(state: State, account: String?, plan: String?, detail: String) {
        self.state = state; self.account = account; self.plan = plan; self.detail = detail
    }
    public var wireValue: NativeRPCValue { .object([.init("state", .string(state.rawValue)), .init("account", account.map(NativeRPCValue.string) ?? .null), .init("plan", plan.map(NativeRPCValue.string) ?? .null), .init("detail", .string(detail))]) }
}
/// Account/profile worker supplies the native equivalent of readSignIn and its
/// existing thirty-second cache. No new auth probe runs from this adapter.
public protocol BackendRemoteServeAccountSignInReader: Sendable {
    func readSignIn(_ profile: BackendAccountProfile) async throws -> BackendRemoteServeAccountSignIn
}
public struct BackendRemoteServeAccountOutcome: Equatable, Sendable {
    public let ok: Bool
    public let message: String
    public let session: String?
    public init(ok: Bool, message: String, session: String?) { self.ok = ok; self.message = message; self.session = session }
    public var fields: [NativeRPCValue.Field] { [.init("ok", .bool(ok)), .init("message", .string(message)), .init("session", session.map(NativeRPCValue.string) ?? .null)] }
}
/// Account/lifecycle worker supplies the same sign-in/sign-out runners as the
/// local Accounts screen. Gemini's missing logout must retain its own refusal.
public protocol BackendRemoteServeAccountLoginLifecycle: Sendable {
    func signIn(accountID: String) async throws -> BackendRemoteServeAccountOutcome
    func signOut(accountID: String) async throws -> BackendRemoteServeAccountOutcome
}

/// Remote projections over the one profile, attribution and switch owner.
public struct BackendRemoteServeAccountService: Sendable {
    public typealias Switch = @Sendable (String, String) async throws -> BackendRemoteServeAccountOutcome
    public typealias Profiles = @Sendable () async throws -> [BackendAccountProfile]
    public typealias Attribution = @Sendable (String) async -> BackendAccountSessionReading?
    public typealias Probe = @Sendable (BackendAccountProfile) async throws -> BackendRemoteServeAccountSignIn
    private let list: Profiles
    private let attribution: Attribution
    private let probe: Probe?
    private let switchAccount: Switch?
    private let login: (any BackendRemoteServeAccountLoginLifecycle)?
    /// The owner's own context: a phone's Switch and its login list run under it, at Full control only (27 Oct, D3).
    private let owner: BackendRemoteOwnerScope.Owner?
    public init(profiles: @escaping Profiles, attribution: @escaping Attribution, probe: Probe? = nil,
                switchAccount: Switch? = nil, login: (any BackendRemoteServeAccountLoginLifecycle)? = nil,
                owner: BackendRemoteOwnerScope.Owner? = nil) {
        list = profiles; self.attribution = attribution; self.probe = probe; self.switchAccount = switchAccount; self.login = login
        self.owner = owner
    }
    public init(profiles: BackendAccountProfileStore, lifecycle: BackendSessionLifecycleCoordinator,
                signIn: (any BackendRemoteServeAccountSignInReader)? = nil, switcher: BackendSessionSwitchCoordinator? = nil,
                login: (any BackendRemoteServeAccountLoginLifecycle)? = nil, owner: BackendRemoteOwnerScope.Owner? = nil) {
        self.owner = owner
        list = { try await profiles.list() }
        attribution = { id in
            guard let meta = lifecycle.manager.list().first(where: { $0.id == id }) else { return nil }
            let reading = await lifecycle.sessionAccount(sessionID: id)
            // 31 Oct: what this Mac's chip shows (`session:account`), the switched-to account at once included.
            guard let switcher, meta.exitCode == nil else { return reading }
            return BackendAccountSessionReading.decode(BackendSessionLifecycleRPC.account(reading, meta: meta, pending: await switcher.pendingAccount(sessionID: id)))
        }
        if let signIn { probe = { try await signIn.readSignIn($0) } } else { probe = nil }
        if let switcher {
            switchAccount = { id, account in
                do {
                    let result = try await switcher.perform(sessionID: id, accountID: account)
                    // The source switchAccount answers acceptance of perform,
                    // not account attribution. Current remains evidence-led on
                    // the next read, including an in-place reread still pending.
                    return .init(ok: true, message: "", session: result.session.id)
                } catch { return .init(ok: false, message: error.localizedDescription, session: id) }
            }
        } else { switchAccount = nil }
        self.login = login
    }
    public static func wire(_ profile: BackendAccountProfile, signIn: BackendRemoteServeAccountSignIn?) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(profile.id)), .init("name", .string(profile.name)),
            .init("provider", .string(profile.provider)), .init("color", profile.color.isEmpty ? .null : .string(profile.color)), .init("system", .bool(profile.system))]
        if let signIn { fields.append(.init("signIn", signIn.wireValue)) }
        return .object(fields)
    }
    /// Every login, one row per login (`prefer`: the one a session runs as stays when it has a copy).
    public func everyAccount(prefer: String? = nil) async throws -> [NativeRPCValue] {
        let profiles = try await list(), probe = self.probe
        // Preserve listProfiles order even when probes finish in a different
        // order; a failing probe omits signIn instead of inventing unknown.
        let rows = await withTaskGroup(of: (Int, NativeRPCValue).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask { (index, Self.wire(profile, signIn: await probeValue(probe, profile))) }
            }
            var rows = [(Int, NativeRPCValue)]()
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Self.oneRowPerLogin(rows, profiles: profiles, prefer: prefer)
    }
    /// 28 Oct (phone review: one address listed twice in Switch account): the rule this Mac's own lists use
    /// (`CodingAILogins.oneRowPerEmail`), so a phone and the Mac show the same rows. Two rows of one AI that hold the
    /// same address are one login (this Mac's own sign-in and a copy the app keeps, or one login kept twice): the one
    /// in use stays, else a signed-in one, else this Mac's own, else the latest used. An API key is its own kind and is
    /// never folded into a login; the same address under two AIs (a Claude login and a Codex login) stays two rows.
    static func oneRowPerLogin(_ rows: [NativeRPCValue], profiles: [BackendAccountProfile], prefer: String?) -> [NativeRPCValue] {
        var signIn: [String: CodingAISignIn] = [:]
        let accounts: [CodingAIAccount] = rows.compactMap { row in
            guard let id = row["id"].string else { return nil }
            let profile = profiles.first { $0.id == id }
            if row["signIn"].fields != nil { signIn[id] = CodingAIAccountsParse.signIn(CodingAIJSON(row["signIn"].foundation)) }
            return CodingAIAccount(id: id, name: row["name"].string ?? id, provider: row["provider"].string, system: row["system"].bool == true,
                                   lastUsedAt: profile?.lastUsedAt, keptBy: profile.map { $0.promised ? .app : .agent })
        }
        let copies = CodingAILogins.duplicates(accounts, signIn: signIn, prefer: prefer)
        return rows.filter { copies[$0["id"].string ?? ""] == nil }
    }
    public func read(_ sessionID: String) async throws -> (current: NativeRPCValue, accounts: [NativeRPCValue]) {
        let reading = await attribution(sessionID)
        let accounts = try await everyAccount(prefer: reading?.reason == nil ? reading?.profileId : nil)
        guard let reading, reading.reason == nil, let id = reading.profileId else { return (.null, accounts) }
        if let known = accounts.first(where: { $0["id"].string == id }) { return (known, accounts) }
        // A deleted profile can remain established on a running process. It
        // carries no signIn, because that profile was never probed in this list.
        return (.object([.init("id", .string(id)), .init("name", .string(reading.profileName ?? id)),
            .init("provider", reading.provider.map(NativeRPCValue.string) ?? .null), .init("color", .null), .init("system", .bool(false))]), accounts)
    }
    public func accountFeature(trust: BackendRemoteTrustStore, gate: BackendRemoteServeSessionGate) -> BackendRemoteHostFeature? {
        guard switchAccount != nil else { return nil }
        return .init(capability: "account", messageTypes: ["account.read", "account.switch"], policy: .grantedDevice) { message, context in
            // Full control only, refused in plain words below it (27 Oct, D3); then run as this Mac's own screens run it.
            guard BackendRemoteOwnerScope.permits(context) else { return [try .error(code: "unauthorized", message: BackendRemoteOwnerScope.switchNeedsFull)] }
            return try await BackendRemoteOwnerScope.run(owner, fallback: context.rpcContext) { _ in try await answer(message, context, trust: trust, gate: gate) }
        }
    }
    private func answer(_ message: BackendRemoteClientMessage, _ context: BackendRemoteHostContext, trust: BackendRemoteTrustStore,
                        gate: BackendRemoteServeSessionGate) async throws -> [BackendRemoteServerMessage] {
        guard await trust.hasAnyAccount(context.deviceID) else { return [try .error(code: "unavailable", message: "This Mac cannot change a session’s account from here.")] }
        let id = try message["id"].requireString("session id")
        guard await gate.visible(deviceID: context.deviceID, sessionID: id) else { return [try .error(code: "unknown-session", message: BackendRemoteServeSessionPolicy.noSuchSession(id))] }
        let common: [NativeRPCValue.Field] = [.init("rid", message["rid"]), .init("id", .string(id))]
        if message.type == "account.read" {
            let state = try await read(id)
            var filtered: [NativeRPCValue] = []
            for row in state.accounts { if await trust.accountAllowed(context.deviceID, account: row["id"].string ?? "") { filtered.append(row) } }
            return [try .init(.accountState, fields: common + [.init("current", state.current), .init("accounts", .array(filtered))])]
        }
        let accountID = try message["accountId"].requireString("account id")
        guard await trust.accountAllowed(context.deviceID, account: accountID) else {
            return [try .init(.accountSwitched, fields: common + BackendRemoteServeAccountOutcome(ok: false, message: "That login is not one this machine offers here.", session: id).fields)]
        }
        guard let switchAccount else { return [try .error(code: "unavailable", message: "This Mac cannot change a session’s account from here.")] }
        return [try .init(.accountSwitched, fields: common + (try await switchAccount(id, accountID)).fields)]
    }
    public func loginFeature() -> BackendRemoteHostFeature? {
        guard let login else { return nil }
        // Handle the owner gate here to retain the source's unavailable refusal
        // rather than the host's generic unauthorized policy sentence. Host
        // capability projection must still advertise logins only to mine.
        return .init(capability: "logins", messageTypes: ["logins.read", "logins.signin", "logins.signout"], policy: .grantedDevice) { message, context in
            guard context.kind == .mine else { return [try .error(code: "unavailable", message: "This Mac does not manage its logins from here.")] }
            if message.type == "logins.read" { return [try .init(.loginState, fields: [.init("rid", message["rid"]), .init("accounts", .array(try await everyAccount()))])] }
            let id = try message["accountId"].requireString("account id")
            let outcome = message.type == "logins.signout" ? try await login.signOut(accountID: id) : try await login.signIn(accountID: id)
            return [try .init(message.type == "logins.signout" ? .loginSignedOut : .loginSignedIn, fields: [.init("rid", message["rid"])] + outcome.fields)]
        }
    }
}
private func probeValue(_ probe: BackendRemoteServeAccountService.Probe?, _ profile: BackendAccountProfile) async -> BackendRemoteServeAccountSignIn? {
    guard let probe else { return nil }
    return try? await probe(profile)
}
