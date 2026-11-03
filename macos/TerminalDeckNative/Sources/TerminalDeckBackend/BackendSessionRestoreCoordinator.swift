import Foundation
import TerminalDeckNativeCore

#if TD_HOST_ACCOUNT_BRIDGE
public typealias BackendHOSTSessionRestoreCoordinatorProfiles = any BackendHOSTProfileViewReading
#else
public typealias BackendHOSTSessionRestoreCoordinatorProfiles = BackendAccountProfileStore
#endif

public actor BackendSessionRestorePlanner {
    private let profiles: BackendHOSTSessionRestoreCoordinatorProfiles
    private let providers: any BackendProviderLaunchResolver
    private let restoreContext: BackendSessionRestoreContext
    public init(profiles: BackendHOSTSessionRestoreCoordinatorProfiles, providers: any BackendProviderLaunchResolver, context: BackendSessionRestoreContext) {
        self.profiles = profiles; self.providers = providers; restoreContext = context
    }
    public init(accounts: BackendAccountLaunchAdapter, providers: any BackendProviderLaunchResolver, context: BackendSessionRestoreContext) {
        self.init(profiles: accounts.profiles, providers: providers, context: context)
    }
    public func accountFolder(_ saved: BackendSessionSaved) async throws -> BackendAccountProfile {
        if let home = saved.homeProfileID, let profile = try await profiles.find(home), profile.provider == saved.provider { return profile }
        return try await profiles.resolve(sessionProfileID: saved.profileID, projectPath: saved.cwd, provider: saved.provider)
    }
    public func configDirectory(_ saved: BackendSessionSaved) async throws -> String {
        let profile = try await accountFolder(saved)
        if profile.system, saved.provider == "claude", let device = saved.deviceID {
            let config = await profiles.configuration
            return config.dataDirectory.appendingPathComponent("remote/device-home").appendingPathComponent(device).appendingPathComponent(".claude").path
        }
        // #26: below Full a named account ran in the device's own folder for it (BackendMacConfinement), not the owner's.
        if !profile.system, let device = saved.deviceID, let variable = BackendAccountProfile.configEnvironment(saved.provider) {
            let config = await profiles.configuration
            let deviceHome = config.dataDirectory.appendingPathComponent("remote/device-home").appendingPathComponent(device).path
            return BackendMacConfinement.deviceAccountFolder(deviceHome: deviceHome, variable: variable, ownerFolder: profile.configDir)
        }
        return profile.configDir
    }
    public static func store(_ config: String) -> String { NativeTranscriptPaths.canonical(URL(fileURLWithPath: config).appendingPathComponent("projects").path) }
    public func conversation(_ saved: BackendSessionSaved, config: String) async throws -> BackendSessionRestoreDecision.Conversation {
        guard saved.provider == "claude" else { return .unknown }
        return try await Task.detached(priority: .utility) {
            let directories = NativeTranscriptPaths.projectSpellings(saved.cwd).map {
                URL(fileURLWithPath: config).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath($0))
            }
            if let id = saved.conversationID {
                guard id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { return .none }
                for directory in directories {
                    let file = directory.appendingPathComponent(id + ".jsonl")
                    if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                       values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 { return .found }
                }
                return .none
            }
            for directory in directories {
                guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
                for entry in entries where entry.pathExtension == "jsonl" {
                    let name = entry.deletingPathExtension().lastPathComponent
                    guard name.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil,
                          let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { continue }
                    return .found
                }
            }
            return .none
        }.value
    }
    public func plan(_ saved: [BackendSessionSaved], exact: Bool = true, claimedLive: [BackendSessionMeta] = []) async -> [BackendSessionRestoreDecision] {
        var decisions: [BackendSessionRestoreDecision] = [], configs: [Int: String] = [:], continuing: [Int: Bool] = [:]
        let path: String
        do { path = try await providers.loginPath() }
        catch { return saved.map { BackendSessionRestoreDecision(session: $0, outcome: .failed, reason: error.localizedDescription) } }
        for (index, session) in saved.enumerated() {
            do {
                let spec = try await providers.resolve(session.input(resume: false), loginPath: path)
                continuing[index] = !spec.resumeArgs.isEmpty
                configs[index] = try await configDirectory(session)
            } catch { decisions.append(BackendSessionRestoreDecision(session: session, outcome: .failed, reason: error.localizedDescription)) }
        }
        var latest: [String: Int] = [:]
        for (index, session) in saved.enumerated() where continuing[index] == true {
            let key = session.provider + "\0" + Self.store(configs[index] ?? "") + "\0" + session.cwd
            if let old = latest[key], saved[old].lastSeenAt >= session.lastSeenAt { continue }
            latest[key] = index
        }
        var claimed = Set(claimedLive.filter { $0.exitCode == nil }.compactMap { meta -> String? in
            guard let id = meta.agentSessionId else { return nil }; return meta.provider + "\0" + id
        })
        var ordered: [BackendSessionRestoreDecision?] = Array(repeating: nil, count: saved.count)
        for (index, session) in saved.enumerated() {
            if let failed = decisions.first(where: { $0.session == session }) { ordered[index] = failed; continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directory), directory.boolValue else {
                ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .skip, reason: "the folder it ran in is no longer on this machine"); continue
            }
            do { _ = try await restoreContext.context(for: session) }
            catch { ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .skip, reason: error.localizedDescription); continue }
            guard continuing[index] == true else {
                ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .fresh, reason: "this agent has no way to continue a previous conversation"); continue
            }
            if exact, session.provider == "codex", session.conversationID == nil {
                ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .fresh,
                    reason: "no conversation was recorded for this Codex tab; reopening it empty, not another tab's latest conversation")
                continue
            }
            let config = configs[index]!
            if exact && (session.provider == "claude" || session.conversationID != nil) {
                guard let id = session.conversationID else {
                    ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .skip, reason: "no conversation was saved for this tab — open it to choose one", pick: session.provider == "claude"); continue
                }
                guard ["claude", "codex"].contains(session.provider) else {
                    ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .skip, reason: "the exact conversation cannot be continued by this agent; kept for recovery"); continue
                }
                let found: BackendSessionRestoreDecision.Conversation
                do { found = try await conversation(session, config: config) }
                catch { ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .failed, reason: error.localizedDescription); continue }
                let key = session.provider + "\0" + id
                if found == .none || claimed.contains(key) {
                    ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .skip,
                        reason: found == .none ? "the saved conversation was not found; kept for recovery" : "another live tab already holds that conversation",
                        configDirectory: config, conversation: found, pick: session.provider == "claude"); continue
                }
                claimed.insert(key)
                ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .resume, reason: "continuing the saved conversation by its exact id", configDirectory: config, conversation: found)
            } else {
                let scope = session.provider + "\0" + Self.store(config) + "\0" + session.cwd
                if latest[scope] != index {
                    ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .fresh, reason: "another saved tab holds this conversation store", configDirectory: config); continue
                }
                let found: BackendSessionRestoreDecision.Conversation
                do { found = try await conversation(session, config: config) }
                catch { ordered[index] = BackendSessionRestoreDecision(session: session, outcome: .failed, reason: error.localizedDescription); continue }
                ordered[index] = BackendSessionRestoreDecision(session: session, outcome: found == .none ? .fresh : .resume,
                    reason: found == .none ? "no earlier conversation was found on disk for this folder" : (found == .found ? "continuing the conversation on disk" : "the agent owns this history; it will resolve its own latest conversation"),
                    configDirectory: config, conversation: found)
            }
        }
        return ordered.compactMap { $0 }
    }
}

public protocol BackendRestoreSessionStarting: Sendable {
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta
    /// The same start under the name the person gave the tab before (its saved `title`; nil: none).
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool, named: String?) async throws -> BackendSessionMeta
    func liveSessions() async -> [BackendSessionMeta]
}

extension BackendRestoreSessionStarting {
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool, named: String?) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure)
    }
}

extension BackendSessionLifecycleCoordinator: BackendRestoreSessionStarting {
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure, announce: true)
    }
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool, named: String?) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure, announce: true, named: named)
    }
    public func liveSessions() async -> [BackendSessionMeta] { manager.list() }
}

public actor BackendSessionRestoreCoordinator {
    public struct Result: Sendable { public let started: [BackendSessionMeta]; public let decisions: [BackendSessionRestoreDecision] }
    private let starter: any BackendRestoreSessionStarting
    private let planner: BackendSessionRestorePlanner
    private let store: NativeStateStore
    private let context: BackendSessionRestoreContext
    private let excluded: [String]
    private let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
    private var restoring = false
    private var hostedClaims: @Sendable () -> [BackendSessionMeta] = { [] }
    public func setHostedClaims(_ claims: @escaping @Sendable () -> [BackendSessionMeta]) { hostedClaims = claims }
    /// Capture before stopping the helper: its final exit packets can erase the live rows and ledger.
    /// `strict` (the deliberate restart) refuses when a live session has no saved launch, so the helper is left
    /// running. After a crash the helper is already gone: a session with no saved launch (for example a tab being
    /// replaced that is not noted yet) is skipped, as before, so the rest are still put back (review sessions-security #1).
    /// `live` (FIXRESTART 4b): for the deliberate restart, the launch the running helper itself recorded for a live
    /// session the ledger never remembered (an AI-started chat, for example an idle Codex chat with no turns yet). It
    /// is used only when the ledger has no record, so that session is put back instead of blocking the restart.
    public func snapshotForHostRestart(_ ids: [String], strict: Bool = true, live: [String: NativeRPCValue] = [:]) async throws -> [NativeRPCValue] {
        var launches: [NativeRPCValue] = []
        for id in ids {
            guard strict else {
                guard let saved = try? await store.ledgerGet(id), saved.fields != nil else { continue }
                launches.append(saved); continue
            }
            var saved = try await store.ledgerGet(id)
            if saved.fields == nil, let recorded = live[id] { saved = recorded }
            guard saved.fields != nil else { throw BackendSessionFailure.invalidInput("A live session has no saved launch; the helper was left running.") }
            _ = try BackendSessionSaved(saved)
            launches.append(saved)
        }
        return launches
    }
    public func holdAfterHostRestart(_ launches: [NativeRPCValue]) async throws -> [String] {
        var keys: [String] = []
        for saved in launches {
            keys.append(try await store.holdSession(saved, reason: "the session helper stopped; starting it again").key)
        }
        return keys
    }
    public init(lifecycle: BackendSessionLifecycleCoordinator, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                context: BackendSessionRestoreContext, excludedAppWorkingDirectories: [String], emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) {
        self.init(starter: lifecycle, planner: planner, store: store, context: context, excludedAppWorkingDirectories: excludedAppWorkingDirectories, emit: emit)
    }
    public init(starter: any BackendRestoreSessionStarting, planner: BackendSessionRestorePlanner, store: NativeStateStore,
                context: BackendSessionRestoreContext, excludedAppWorkingDirectories: [String], emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) {
        self.starter = starter; self.planner = planner; self.store = store; self.context = context; excluded = excludedAppWorkingDirectories; self.emit = emit
    }
    public func restore() async throws -> Result {
        guard !restoring else { throw BackendSessionFailure.invalidInput("Session restoration is already running.") }
        restoring = true; defer { restoring = false }
        guard await store.getPreferences()["restoreSessions"].bool != false else { return Result(started: [], decisions: []) }
        let live = hostedClaims()
        let raw = await store.getOpenSessions().filter { record in
            !BackendHOSTPolicy.claimed(savedID: record["id"].string, tabKey: record["tabKey"].string,
                provider: record["provider"].string ?? "", conversation: record["agentSessionId"].string, attached: live)
        }
        var saved: [BackendSessionSaved] = []
        for record in raw {
            let session: BackendSessionSaved
            do { session = try BackendSessionSaved(record) }
            catch { if record.fields != nil { _ = try await store.holdSession(record, reason: "the saved session has invalid launch fields: " + error.localizedDescription) }; continue }
            if excluded.contains(where: { NativeTranscriptPaths.isDescendant(session.cwd, of: $0) || NativeTranscriptPaths.canonical(session.cwd) == NativeTranscriptPaths.canonical($0) }) { continue }
            // L8 (11 Oct, Asad: "no session lost on an app restart"): a task's worker is carried on by its TASK (the
            // task engine resumes its conversation and tells it the app restarted). Restoring the tab here as well
            // would start a second, unbound copy of the same conversation, or hold a finished one as "recoverable".
            if record["taskID"].string.map({ !$0.isEmpty }) == true { continue }
            saved.append(session)
        }
        let planned = await planner.plan(saved, exact: true, claimedLive: await starter.liveSessions())
        var started: [BackendSessionMeta] = [], decisions: [BackendSessionRestoreDecision] = []
        for decision in planned {
            try Task.checkCancellation()
            if decision.outcome == .skip || decision.outcome == .failed {
                _ = try await store.holdSession(decision.session.raw, reason: decision.reason, pick: decision.pick); decisions.append(decision); continue
            }
            do {
                let restoredContext = try await context.context(for: decision.session)
                var input = decision.session.input(resume: decision.outcome == .resume)
                BackendAGTShellAgents.applyResume(to: &input) // AGT: a shell tab's own AI resumes with it
                let meta = try await Self.startingAgain(alreadyRunning: { await self.running(decision.session) }) {
                    try await BackendAGSLaunchScope.$restoring.withValue(true) {
                        try await starter.create(input, context: restoredContext, holdOnFailure: false, named: decision.session.title)
                    }
                }
                started.append(meta); decisions.append(decision)
            } catch {
                let failed = BackendSessionRestoreDecision(session: decision.session, outcome: .failed, reason: "it could not be started again: " + error.localizedDescription)
                _ = try await store.holdSession(decision.session.raw, reason: failed.reason); decisions.append(failed)
            }
        }
        try await store.ledgerDropPending(); try await store.ledgerFlush()
        emit(.held(try await store.heldSessions())); emit(.restored(decisions))
        return Result(started: started, decisions: decisions)
    }
    /// 29 Oct: sessions coming back together (a keeper restart, an app start) can catch each other's start-up writes
    /// between a launch's two reads of its configuration. One fresh attempt follows that one refusal, so a restart
    /// brings every chat back without an app relaunch; any other failure is reported as before.
    /// Before that attempt: when the session is already running again (another restore got there in the 2 s), that
    /// one is the answer and nothing starts twice (Reviewer 29 Oct).
    static func startingAgain<T>(isolation: isolated (any Actor)? = #isolation, pause: Duration = .seconds(2),
                                 alreadyRunning: () async -> T? = { nil }, _ start: () async throws -> T) async throws -> T {
        do { return try await start() }
        catch where raced(error) {
            try await Task.sleep(for: pause)
            if let running = await alreadyRunning() { return running }
            return try await start()
        }
    }
    /// The live session that is this saved one again: same AI, same conversation, still running.
    private func running(_ saved: BackendSessionSaved) async -> BackendSessionMeta? {
        guard let conversation = saved.conversationID else { return nil }
        return await starter.liveSessions().first { $0.exitCode == nil && $0.provider == saved.provider && $0.agentSessionId == conversation }
    }
    static func raced(_ error: Error) -> Bool { error.localizedDescription.contains("changed during launch") }
    public func retryHeld(_ key: String) async throws -> [NativeHeldSession] {
        guard let held = try await store.heldSessions().first(where: { $0.key == key }) else { return try await store.heldSessions() }
        let saved = try BackendSessionSaved(held.saved)
        let plan = await planner.plan([saved], exact: true, claimedLive: await starter.liveSessions())
        guard let decision = plan.first else { throw BackendSessionFailure.invalidInput("The held session could not be planned.") }
        if (decision.outcome == .skip && !decision.pick) || decision.outcome == .failed {
            try await store.failHeldSession(key, reason: decision.reason)
        } else {
            do {
                let restoredContext = try await context.context(for: saved)
                var input = saved.input(resume: decision.outcome == .resume || decision.pick, pick: decision.pick)
                BackendAGTShellAgents.applyResume(to: &input) // AGT
                _ = try await Self.startingAgain(alreadyRunning: { await self.running(saved) }) {
                    try await BackendAGSLaunchScope.$restoring.withValue(true) {
                        try await starter.create(input, context: restoredContext, holdOnFailure: false, named: saved.title)
                    }
                }
                _ = try await store.releaseHeldSession(key)
            } catch { try await store.failHeldSession(key, reason: "it could not be started again: " + error.localizedDescription) }
        }
        let remaining = try await store.heldSessions(); emit(.held(remaining)); return remaining
    }
    public func forgetHeld(_ key: String) async throws -> [NativeHeldSession] {
        _ = try await store.releaseHeldSession(key); let held = try await store.heldSessions(); emit(.held(held)); return held
    }
}
