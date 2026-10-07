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
    public init(profiles: @escaping Profiles, attribution: @escaping Attribution, probe: Probe? = nil,
                switchAccount: Switch? = nil, login: (any BackendRemoteServeAccountLoginLifecycle)? = nil) {
        list = profiles; self.attribution = attribution; self.probe = probe; self.switchAccount = switchAccount; self.login = login
    }
    public init(profiles: BackendAccountProfileStore, lifecycle: BackendSessionLifecycleCoordinator,
                signIn: (any BackendRemoteServeAccountSignInReader)? = nil, switcher: BackendSessionSwitchCoordinator? = nil,
                login: (any BackendRemoteServeAccountLoginLifecycle)? = nil) {
        list = { try await profiles.list() }
        attribution = { id in
            guard lifecycle.manager.list().contains(where: { $0.id == id }) else { return nil }
            return await lifecycle.sessionAccount(sessionID: id)
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
    public func everyAccount() async throws -> [NativeRPCValue] {
        let profiles = try await list(), probe = self.probe
        // Preserve listProfiles order even when probes finish in a different
        // order; a failing probe omits signIn instead of inventing unknown.
        return await withTaskGroup(of: (Int, NativeRPCValue).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask { (index, Self.wire(profile, signIn: await probeValue(probe, profile))) }
            }
            var rows = [(Int, NativeRPCValue)]()
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    public func read(_ sessionID: String) async throws -> (current: NativeRPCValue, accounts: [NativeRPCValue]) {
        let accounts = try await everyAccount()
        guard let reading = await attribution(sessionID), reading.reason == nil, let id = reading.profileId else { return (.null, accounts) }
        if let known = accounts.first(where: { $0["id"].string == id }) { return (known, accounts) }
        // A deleted profile can remain established on a running process. It
        // carries no signIn, because that profile was never probed in this list.
        return (.object([.init("id", .string(id)), .init("name", .string(reading.profileName ?? id)),
            .init("provider", reading.provider.map(NativeRPCValue.string) ?? .null), .init("color", .null), .init("system", .bool(false))]), accounts)
    }
    public func accountFeature(trust: BackendRemoteTrustStore, gate: BackendRemoteServeSessionGate) -> BackendRemoteHostFeature? {
        guard switchAccount != nil else { return nil }
        return .init(capability: "account", messageTypes: ["account.read", "account.switch"], policy: .grantedDevice) { message, context in
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
