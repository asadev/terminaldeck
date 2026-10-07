import Foundation
import TerminalDeckNativeCore

public actor BackendSessionRestorePlanner {
    private let profiles: BackendAccountProfileStore
    private let providers: any BackendProviderLaunchResolver
    private let restoreContext: BackendSessionRestoreContext
    public init(profiles: BackendAccountProfileStore, providers: any BackendProviderLaunchResolver, context: BackendSessionRestoreContext) {
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
    func liveSessions() async -> [BackendSessionMeta]
}

extension BackendSessionLifecycleCoordinator: BackendRestoreSessionStarting {
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure, announce: true)
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
        let raw = await store.getOpenSessions()
        var saved: [BackendSessionSaved] = []
        for record in raw {
            let session: BackendSessionSaved
            do { session = try BackendSessionSaved(record) }
            catch { if record.fields != nil { _ = try await store.holdSession(record, reason: "the saved session has invalid launch fields: " + error.localizedDescription) }; continue }
            if excluded.contains(where: { NativeTranscriptPaths.isDescendant(session.cwd, of: $0) || NativeTranscriptPaths.canonical(session.cwd) == NativeTranscriptPaths.canonical($0) }) { continue }
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
                let meta = try await starter.create(decision.session.input(resume: decision.outcome == .resume), context: restoredContext, holdOnFailure: false)
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
                _ = try await starter.create(saved.input(resume: decision.outcome == .resume || decision.pick, pick: decision.pick), context: restoredContext, holdOnFailure: false)
                _ = try await store.releaseHeldSession(key)
            } catch { try await store.failHeldSession(key, reason: "it could not be started again: " + error.localizedDescription) }
        }
        let remaining = try await store.heldSessions(); emit(.held(remaining)); return remaining
    }
    public func forgetHeld(_ key: String) async throws -> [NativeHeldSession] {
        _ = try await store.releaseHeldSession(key); let held = try await store.heldSessions(); emit(.held(held)); return held
    }
}
