import Foundation
import TerminalDeckNativeCore
#if TD_HOST_ACCOUNT_BRIDGE
public typealias BackendHOSTCopilotProfileReader = any BackendHOSTProfileViewReading
public typealias BackendHOSTCopilotSignInInvoker = any BackendHOSTAccountChannelInvoking
#else
public typealias BackendHOSTCopilotProfileReader = BackendAccountProfileStore
public typealias BackendHOSTCopilotSignInInvoker = BackendAppAccountSignInService
#endif

/// The actual app graph adapter. This calls the existing launcher once; it owns
/// no provider/account state and no second PTY or transcript implementation.
public struct BackendCopilotSessionNativeDriver: BackendCopilotSessionDriving {
    private let providers: BackendNativeProviders
    private let profiles: BackendHOSTCopilotProfileReader
    private let signIns: BackendHOSTCopilotSignInInvoker
    private let launcher: BackendSessionLauncher
    private let ptys: BackendPTYManager
    private let exposure: (@Sendable (String) -> Void)?
    /// O1-R2 applied: the launcher carries `BackendLaunchContext.beforeExposure`
    /// into `BackendSpawnSpec`. If the PTY manager has not invoked it by the time
    /// the launch returns (its one-line patch is O2's), the ID is hidden then.
    public static let launcherCarriesExposure = true
    public init(providers: BackendNativeProviders, profiles: BackendHOSTCopilotProfileReader,
                signIns: BackendHOSTCopilotSignInInvoker, launcher: BackendSessionLauncher, ptys: BackendPTYManager,
                exposure: (@Sendable (String) -> Void)? = nil) {
        self.providers = providers; self.profiles = profiles; self.signIns = signIns; self.launcher = launcher; self.ptys = ptys
        self.exposure = exposure
    }
    /// Join evidence: this driver's launches hide the assistant ID at spawn.
    public var hidesAtSpawn: Bool { exposure != nil && Self.launcherCarriesExposure }
    public func hasClaude() async throws -> Bool {
        let path = try await providers.loginPath()
        return await providers.resolveBinary("claude", path: path).runnable != nil
    }
    public func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        // ACCOUNTS: Hoot's own row (seat "orchestrator"), not just the project's account.
        #if TD_HOST_ACCOUNT_BRIDGE
        // The bridged reader knows no seat; the account channel does. If it cannot be asked, the answer without the seat stands, as before.
        if let context = try? BackendHOSTProfileScope.requireCurrent(),
           let id = try? await signIns.invoke("profiles:effective", args: [BackendHootAccountSeat.input(ownPick: nil, projectPath: projectPath, provider: "claude")],
                                              context: context)["accountId"].string, !id.isEmpty {
            return try await profiles.resolve(sessionProfileID: id, projectPath: projectPath, provider: "claude")
        }
        return try await profiles.resolve(sessionProfileID: nil, projectPath: projectPath, provider: "claude")
        #else
        return try await profiles.resolve(sessionProfileID: nil, projectPath: projectPath, provider: "claude", seat: BackendHootAccountSeat.key)
        #endif
    }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) {
        #if TD_HOST_ACCOUNT_BRIDGE
        let original = try BackendHOSTProfileScope.requireCurrent()
        let value = try await signIns.invoke("profiles:signin", args: [.string(profile.id)], context: original)
        return (try value["state"].requireString("original sign-in state"), value["account"].string, value["plan"].string)
        #else
        let result = await signIns.read(profile)
        return (result.state, result.account, result.plan)
        #endif
    }
    public func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        let fired = BackendCopilotSessionExposureMark()
        var hook: (@Sendable (String) -> Void)? = nil
        if let exposure { hook = { @Sendable (id: String) -> Void in fired.mark(); exposure(id) } }
        do {
            let meta = try await launcher.create(input, context: .init(appFenceID: fence?.id, extraArguments: extraArguments, beforeExposure: hook))
            if let exposure, !fired.marked { exposure(meta.id) }
            return meta
        }
        catch let failure as BackendSessionFailure where fence != nil {
            // The confinement owner's records proof (Seatbelt launcher absent,
            // canary refused or not held) fails before any child is spawned.
            switch failure {
            case .unsupported, .missingCapability: throw BackendCopilotSessionFenceLost(reason: failure.localizedDescription)
            default: throw failure
            }
        }
    }
    public func isAlive(_ sessionID: String) async -> Bool { ptys.list().contains { $0.id == sessionID && $0.exitCode == nil } }
    public func stop(_ sessionID: String) async throws { ptys.kill(sessionID) }
}

/// Records whether the PTY manager invoked the spawn hook itself.
final class BackendCopilotSessionExposureMark: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var marked: Bool { lock.withLock { value } }
}
