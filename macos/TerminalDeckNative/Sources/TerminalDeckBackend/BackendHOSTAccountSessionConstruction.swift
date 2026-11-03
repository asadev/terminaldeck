#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import TerminalDeckNativeCore

/// Actual common session components for the hosted branch. This factory
/// NEVER starts a local account adapter, profile/vault writer, broker, hook
/// server or MCP lease namespace. Publish only with the shared seams patch.
public struct BackendHOSTAccountSessionConstruction: Sendable {
    public let manager: BackendPTYManager
    public let ledger: BackendNativeLedger
    public let accounts: BackendHOSTSessionAccountAccess
    public let profiles: BackendHOSTProfileView
    public let accountRPC: BackendHOSTAccountControlFrontend
    public let signIn: BackendHOSTAccountControlFrontend
    public let launcher: BackendSessionLauncher
    public let launch: BackendCoordinatedSessionLaunch
    public let lifecycle: BackendSessionLifecycleCoordinator
    public let sessionTools: any BackendHOSTOrdinaryToolLeaseOwner
    public let projectTools: any BackendHOSTProjectToolLeaseOwner
    public let planner: BackendSessionRestorePlanner
    public let restore: BackendSessionRestoreCoordinator
    public let sharedHistory: BackendAppSharedProjects

    public static func make(manager: BackendPTYManager, state: NativeStateStore,
        providers: BackendNativeProviders, parts: BackendHOSTAccountSessionParts,
        dependencies: BackendCompositionSessions.Dependencies,
        ordinaryTools: any BackendHOSTOrdinaryToolLeaseOwner,
        projectTools: any BackendHOSTProjectToolLeaseOwner, machineID: String,
        createResolved: @escaping BackendSessionLauncher.HostedDispatch,
        emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) async throws -> Self {
        guard state.ownership == .exclusive, parts.accounts.readiness == .ready,
              state.file?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() ==
                dependencies.accounts.dataDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              manager.localSessionCount() == 0 else {
            throw BackendSessionFailure.missingCapability("exclusive hosted account ownership before local session construction")
        }
        // The app keeps its ORIGINAL Store/ledger owner. Helper profiles.json,
        // vault and broker ownership was configured separately before this call.
        BackendMcpPolicy.configure(dataDirectory: dependencies.accounts.dataDirectory)   // TRUTH-B: the MCP page's switches reach hosted launches
        let ledger = try await BackendNativeLedger.activate(store: state)
        let launchDependencies = try BackendSessionLaunchDependencies(providers: providers, accounts: parts.resolver,
            confinement: dependencies.confinement, instructions: dependencies.instructions, ledger: ledger)
        let launcher = BackendSessionLauncher(manager: manager, dependencies: launchDependencies, hostedDispatch: { input, spawn, account, context in
            let hosted = try await createResolved(input, spawn, account, context)
            guard hosted != nil || !BackendHOSTMixedLeaseRoute.eligible(input, context) else {
                throw BackendSessionFailure.missingCapability("this ordinary managed launch's actual helper namespace")
            }
            // Deferred requests keep the original app PTY/tool endpoint. The
            // same remote account resolver binds its verified external child.
            return hosted
        })
        let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: providers,
            sessionTools: ordinaryTools, projectTools: projectTools, reach: dependencies.browserReach, machineID: machineID)
        let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch,
            accounts: parts.accounts, attribution: parts.accounts, ledger: ledger, store: state,
            cleanup: dependencies.cleanup, emit: emit)
        let planner = BackendSessionRestorePlanner(profiles: parts.profiles, providers: providers, context: dependencies.restoreContext)
        let restore = BackendSessionRestoreCoordinator(lifecycle: lifecycle, planner: planner, store: state,
            context: dependencies.restoreContext, excludedAppWorkingDirectories: dependencies.excludedAppWorkingDirectories, emit: emit)
        let shared = BackendAppSharedProjects(systemConfig: URL(fileURLWithPath: dependencies.accounts.systemDirectory("claude")),
            managedRoot: dependencies.accounts.profilesRoot, writable: true, changed: {})
        return .init(manager: manager, ledger: ledger, accounts: parts.accounts, profiles: parts.profiles,
            accountRPC: parts.channels, signIn: parts.channels, launcher: launcher, launch: launch, lifecycle: lifecycle,
            sessionTools: ordinaryTools, projectTools: projectTools, planner: planner, restore: restore, sharedHistory: shared)
    }
}
#endif
