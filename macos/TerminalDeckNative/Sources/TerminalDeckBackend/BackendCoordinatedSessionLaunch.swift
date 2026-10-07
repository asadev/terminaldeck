import Foundation

public protocol BackendBrowserToolReach: BackendLaunchCapability {
    func reachesDeviceWindows(_ deviceKey: String) async -> Bool
    func hostHoldsWindows() async -> Bool
}
public struct BackendBrowserToolReachAdapter: BackendBrowserToolReach, Sendable {
    public let readiness: BackendLaunchReadiness
    private let device: @Sendable (String) async -> Bool
    private let host: @Sendable () async -> Bool
    public init(readiness: BackendLaunchReadiness, reachesDeviceWindows: @escaping @Sendable (String) async -> Bool,
                hostHoldsWindows: @escaping @Sendable () async -> Bool) {
        self.readiness = readiness; device = reachesDeviceWindows; host = hostHoldsWindows
    }
    public func reachesDeviceWindows(_ deviceKey: String) async -> Bool { await device(deviceKey) }
    public func hostHoldsWindows() async -> Bool { await host() }
}

/// The actual ready session-tools/project-tools seam. Prepare, compose, spawn,
/// bind and unwind are one transaction; root sends process events here so a
/// fast child exit cannot race binding into a leaked caller/seat/config.
public actor BackendCoordinatedSessionLaunch {
    public struct Result: Sendable {
        public let session: BackendSessionMeta
        public let notices: [String]
        public let browserTools: Bool
        public let projectTools: Bool
        public let implementations: Set<BackendMCPImplementation>
    }
    private let launcher: BackendSessionLauncher
    private let providers: any BackendProviderLaunchResolver
    private let sessionTools: BackendSessionToolLeases
    private let projectTools: BackendProjectToolComposition
    private let reach: any BackendBrowserToolReach
    private var busy = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    /// session-verbs.ts noteNoVerbs: why a session was launched without the browser verbs,
    /// for the "cannot drive" line its agent is told (host-core.ts:1779).
    private var verbs: BackendAppSessionVerbsRegistry?
    public func setVerbsRegistry(_ registry: BackendAppSessionVerbsRegistry?) { verbs = registry }
    public init(launcher: BackendSessionLauncher, providers: any BackendProviderLaunchResolver,
                sessionTools: BackendSessionToolLeases, projectTools: BackendProjectToolComposition,
                reach: any BackendBrowserToolReach) throws {
        for (name, state) in [("provider resolution", providers.readiness), ("session MCP endpoint", sessionTools.readiness),
                              ("project MCP composition", projectTools.readiness), ("browser window reach", reach.readiness)] {
            guard state == .ready else { throw BackendSessionFailure.missingCapability(name) }
        }
        self.launcher = launcher; self.providers = providers; self.sessionTools = sessionTools
        self.projectTools = projectTools; self.reach = reach
    }

    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext()) async throws -> Result {
        await enter(); defer { leave() }
        guard !stopped else { throw BackendSessionFailure.closed }
        try Task.checkCancellation()
        let path = try await providers.loginPath()
        let provider = try await providers.resolve(input, loginPath: path)
        var resolvedInput = input
        resolvedInput.provider = provider.id
        let forDevice = context.deviceBoundary != nil
        let hostWindows = await reach.hostHoldsWindows()
        let deviceWindows: Bool
        if let device = context.deviceBoundary?.deviceKey { deviceWindows = await reach.reachesDeviceWindows(device) }
        else { deviceWindows = false }
        var browser: BackendPreparedToolLease?
        var project: BackendPreparedProjectTools?
        var created: BackendSessionMeta?
        var notices: [String] = []
        do {
            if !context.isAppComposed && provider.id == "claude" && (!forDevice || hostWindows || deviceWindows) {
                do { browser = try await sessionTools.prepareOrdinary() }
                catch { notices.append("Browser/session tools are unavailable for this launch because their real endpoint or registered tools are not ready.") }
            } else if !context.isAppComposed {
                notices.append(forDevice && !hostWindows && !deviceWindows
                    ? "The device that started this session cannot serve browser windows."
                    : "This provider has no measured ordinary-session browser MCP override.")
            }
            if !forDevice && !context.isAppComposed && ["claude", "codex", "gemini"].contains(provider.id) {
                do { project = try await projectTools.prepare(provider: provider.id, cwd: input.cwd, loginPath: path) }
                catch { notices.append("Project tools could not be supplied; the project's existing agent settings were kept. \(Self.safeError(error))") }
            }
            var environment = context.environmentOverrides
            for (name, value) in project?.environment ?? [:] { environment[name] = value }
            for (name, value) in browser?.environment ?? [:] { environment[name] = value }
            let files = (browser?.readableFiles ?? []) + (project?.readableFiles ?? [])
            let boundary = context.deviceBoundary.map {
                BackendDeviceBoundary(deviceKey: $0.deviceKey, folder: $0.folder,
                    writableDirectories: $0.writableDirectories, readableFiles: $0.readableFiles + files,
                    readOnlyProjects: $0.readOnlyProjects)
            }
            let composed = BackendLaunchContext(deviceBoundary: boundary, appFenceID: context.appFenceID,
                extraArguments: context.extraArguments + (browser?.arguments ?? []) + (project?.arguments ?? []),
                rememberTab: context.rememberTab, environmentOverrides: environment,
                removeEnvironment: context.removeEnvironment, isAppComposed: context.isAppComposed,
                beforeExposure: context.beforeExposure)
            let session = try await launcher.create(resolvedInput, context: composed)
            created = session
            if let browser { try await sessionTools.bind(browser.id, sessionID: session.id) }
            if let project { try await projectTools.bind(project.id, sessionID: session.id) }
            var implementations: Set<BackendMCPImplementation> = []
            if let browser { implementations.insert(browser.implementation) }
            if let project { implementations.insert(project.implementation) }
            // host-core.ts noVerbs: an ordinary session that got no browser tools says why.
            if browser == nil, !context.isAppComposed, context.extraArguments.isEmpty, let verbs {
                let reason: BackendAppSessionNoVerbsReason = forDevice && !hostWindows && !deviceWindows ? .device
                    : provider.id != "claude" ? .provider : .endpoint
                await verbs.note(session.id, reason: reason)
            }
            let current = launcher.manager.list().first { $0.id == session.id } ?? session
            return Result(session: current, notices: notices, browserTools: browser != nil,
                projectTools: project != nil, implementations: implementations)
        } catch {
            if let browser { await sessionTools.abandon(browser.id) }
            if let project { await projectTools.abandon(project.id) }
            if let created { launcher.manager.kill(created.id); await launcher.removed(created.id, reason: .stopped) }
            throw error
        }
    }

    public func processExited(_ id: String) async {
        await enter(); defer { leave() }
        await sessionTools.release(sessionID: id); await projectTools.release(sessionID: id)
        await launcher.processExited(id)
    }
    public func removed(_ id: String, reason: BackendRemovalReason) async {
        await enter(); defer { leave() }
        // Revoke immediately even when it is a replacement. The replacement's
        // new token/key is independent, while its tab/conversation ids persist.
        await sessionTools.release(sessionID: id); await projectTools.release(sessionID: id)
        await verbs?.forget(id)
        await launcher.removed(id, reason: reason)
    }
    public func stop() async -> Bool {
        await enter(); defer { leave() }
        stopped = true
        let ids = launcher.manager.list().map(\.id)
        launcher.manager.beginShutdown()
        await sessionTools.stop(); await projectTools.stop()
        let drained = await launcher.manager.drain()
        if drained { for id in ids { await launcher.processExited(id) } }
        return drained
    }
    private func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { entrants.append($0) }
    }
    private func leave() {
        if entrants.isEmpty { busy = false } else { entrants.removeFirst().resume() }
    }
    private static func safeError(_ error: any Error) -> String {
        (error as? BackendSessionFailure)?.localizedDescription ?? "The registered project tool source could not complete launch composition."
    }
}
