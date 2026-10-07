import Foundation

/// The actual app graph adapter. This calls the existing launcher once; it owns
/// no provider/account state and no second PTY or transcript implementation.
public struct BackendCopilotSessionNativeDriver: BackendCopilotSessionDriving {
    private let providers: BackendNativeProviders
    private let profiles: BackendAccountProfileStore
    private let signIns: BackendAppAccountSignInService
    private let launcher: BackendSessionLauncher
    private let ptys: BackendPTYManager
    private let exposure: (@Sendable (String) -> Void)?
    /// O1-R2 applied: the launcher carries `BackendLaunchContext.beforeExposure`
    /// into `BackendSpawnSpec`. If the PTY manager has not invoked it by the time
    /// the launch returns (its one-line patch is O2's), the ID is hidden then.
    public static let launcherCarriesExposure = true
    public init(providers: BackendNativeProviders, profiles: BackendAccountProfileStore,
                signIns: BackendAppAccountSignInService, launcher: BackendSessionLauncher, ptys: BackendPTYManager,
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
        try await profiles.resolve(sessionProfileID: nil, projectPath: projectPath, provider: "claude")
    }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) {
        let result = await signIns.read(profile)
        return (result.state, result.account, result.plan)
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
