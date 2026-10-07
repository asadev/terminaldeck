import Foundation
import TerminalDeckNativeCore

/// One public session path. Root fans ordered PTY events into this actor and
/// the remote host; it never constructs another PTY or ledger owner.
public actor BackendSessionLifecycleCoordinator {
    public nonisolated let manager: BackendPTYManager
    private let launch: BackendCoordinatedSessionLaunch
    private let accounts: BackendAccountLaunchAdapter
    private let attribution: BackendAccountAttribution
    private let ledger: BackendNativeLedger
    private let store: NativeStateStore
    private let cleanup: BackendSessionLifecycleCleanup
    private let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
    private var statuses: [String: BackendSessionStatus] = [:]
    private var hookStatus: [String: (status: BackendSessionStatus, at: Date)] = [:]
    private var observedAgents: [String: (provider: String, conversationID: String?)] = [:]
    private struct LaunchFacts: Sendable { let input: BackendCreateSessionInput; let context: BackendLaunchContext }
    private var launchFacts: [String: LaunchFacts] = [:]
    private var observers: [UUID: @Sendable (BackendSessionEvent) async -> Void] = [:]
    private var failures: [String] = []
    private var accepting = true
    private var typingOwner: (@Sendable (String, String) async throws -> Void)?
    private var busy = false
    private var entrants: [CheckedContinuation<Void, Never>] = []

    public init(manager: BackendPTYManager, launch: BackendCoordinatedSessionLaunch, accounts: BackendAccountLaunchAdapter,
                attribution: BackendAccountAttribution, ledger: BackendNativeLedger, store: NativeStateStore,
                cleanup: BackendSessionLifecycleCleanup, emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) throws {
        guard ledger.readiness == .ready, accounts.readiness == .ready, cleanup.readiness == .ready else {
            throw BackendSessionFailure.missingCapability("active native ledger, account runtime and actual session resource cleanup")
        }
        self.manager = manager; self.launch = launch; self.accounts = accounts; self.attribution = attribution
        self.ledger = ledger; self.store = store; self.cleanup = cleanup; self.emit = emit
    }
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext(), holdOnFailure: Bool = true,
                       announce: Bool = true) async throws -> BackendSessionMeta {
        if input.replaces != nil, context.rememberTab, announce { return try await replace(input, context: context) }
        await enter(); defer { leave() }
        guard accepting else { throw BackendSessionFailure.closed }
        try Task.checkCancellation()
        let context = context.remembering(context.rememberTab && !context.isAppComposed && context.appFenceID == nil)
        var created: BackendSessionMeta?
        do {
            let result = try await launch.create(input, context: context)
            created = result.session
            launchFacts[result.session.id] = LaunchFacts(input: input, context: context)
            if let pid = manager.pidOf(result.session.id), await accounts.broker.seatSnapshot(sessionID: result.session.id) != nil {
                try await accounts.broker.bindProcess(sessionID: result.session.id, pid: pid)
            }
            if announce { emit(.created(result.session)) }
            return result.session
        } catch {
            if let created { manager.kill(created.id); await launch.removed(created.id, reason: .stopped) }
            if holdOnFailure, context.rememberTab, input.replaces == nil {
                var saved = BackendSessionSaved.from(input)
                if let boundary = context.deviceBoundary { saved = saved.setting("confineDeviceId", .string(boundary.deviceKey)) }
                _ = try await store.holdSession(saved, reason: "It could not be started: " + error.localizedDescription)
                emit(.held(try await store.heldSessions()))
            }
            throw error
        }
    }
    /// Retry/restart replacement is start, observe, remember, then stop. A
    /// failure keeps the outgoing tab and does not invent a held duplicate.
    public func replace(_ requested: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext()) async throws -> BackendSessionMeta {
        guard let oldID = requested.replaces, let old = manager.list().first(where: { $0.id == oldID }) else { throw BackendSessionFailure.missingSession }
        var raw = try await store.ledgerGet(oldID)
        if raw.isNullish, let facts = launchFacts[oldID], let oldDevice = facts.context.deviceBoundary, let newDevice = context.deviceBoundary,
           oldDevice.deviceKey == newDevice.deviceKey, NativeTranscriptPaths.canonical(oldDevice.folder) == NativeTranscriptPaths.canonical(newDevice.folder),
           !facts.context.isAppComposed, facts.context.appFenceID == nil {
            raw = BackendSessionSaved.from(facts.input).setting("confineDeviceId", .string(oldDevice.deviceKey))
        }
        guard !raw.isNullish else { throw BackendSessionFailure.unsupported("This app-composed session or unproven device boundary cannot be replaced as an ordinary tab.") }
        let saved = try BackendSessionSaved(raw)
        guard requested.cwd == saved.cwd, requested.provider == nil || requested.provider == saved.provider,
              requested.profileId == nil || requested.profileId == old.profileId else { throw BackendSessionFailure.unsupported("Changing a replacement's folder, provider or account requires its explicit launch/switch plan.") }
        var input = requested
        input.provider = saved.provider; input.profileId = old.profileId ?? saved.profileID; input.homeProfileId = old.homeProfileId ?? saved.homeProfileID
        input.tabKey = old.tabKey ?? saved.tabKey; input.model = requested.model ?? raw["model"].string
        input.deniedTools = (raw["deniedTools"].elements ?? []).compactMap(\.string)
        input.noSkills = raw["noSkills"].bool == true ? true : nil; input.agentInstructions = raw["agentInstructions"].string
        if input.resume == true, input.resumeConversationId == nil { input.resumeConversationId = old.agentSessionId ?? saved.conversationID }
        if input.resume == true, saved.provider == "claude", input.resumeConversationId == nil {
            throw BackendSessionFailure.unsupported("No exact conversation is known for this restart. Open the saved conversation chooser instead of guessing a new one.")
        }
        let born = try await create(input, context: context.remembering(false), holdOnFailure: false, announce: false)
        do {
            let ready = try await BackendSessionReplacementReadiness.awaitReady(sessionID: born.id, manager: manager)
            guard ready.outcome != .died, ready.outcome != .signedOut else {
                throw BackendSessionFailure.unsupported("The replacement did not start as a usable agent. " + (ready.said ?? "") + " The original tab was retained.")
            }
            var remembered = raw.merging(BackendSessionSaved.from(input))
            remembered = remembered.setting("profileId", born.profileId.map(NativeRPCValue.string) ?? .null)
                .setting("homeProfileId", born.homeProfileId.map(NativeRPCValue.string) ?? .missing)
                .setting("agentSessionId", born.agentSessionId.map(NativeRPCValue.string) ?? .missing)
            try await store.ledgerNote(born.id, saved: remembered)
            try await close(sessionID: oldID, reason: .replaced)
            emit(.replaced(oldID: oldID, session: born)); return born
        } catch { try? await close(sessionID: born.id); throw error }
    }
    public func write(sessionID: String, data: String) async throws {
        guard accepting else { throw BackendSessionFailure.closed }
        if let typingOwner { try await typingOwner(sessionID, data); return }
        try await writeDirect(sessionID: sessionID, data: data)
    }
    func writeDirect(sessionID: String, data: String) async throws {
        try manager.write(sessionID, data: data)
        try await ledger.activity(sessionID)
    }
    func setTypingOwner(_ owner: (@Sendable (String, String) async throws -> Void)?) { typingOwner = owner }
    public func resize(sessionID: String, cols: Int, rows: Int) async throws {
        try manager.resize(sessionID, cols: cols, rows: rows)
        try await store.ledgerUpdate(sessionID, patch: .object([.init("cols", .number(Double(cols))), .init("rows", .number(Double(rows)))]))
    }
    public func close(sessionID: String, reason: BackendRemovalReason = .stopped) async throws {
        // Forget before the process exit callback: a crash in the gap must not
        // restore a deliberately removed outgoing tab beside its replacement.
        try await store.ledgerForget(sessionID)
        manager.kill(sessionID, reason: reason)
    }
    public func rename(sessionID: String, title: String) throws -> Bool { manager.rename(sessionID, title: title) }
    public func setWatched(_ watched: Bool) { manager.setWatched(watched) }
    public func status(sessionID: String) -> BackendSessionStatus {
        if let session = manager.list().first(where: { $0.id == sessionID }), session.exitCode != nil { return .exited }
        return hookStatus[sessionID]?.status ?? statuses[sessionID] ?? .idle
    }
    public func noteHookStatus(sessionID: String, status: BackendSessionStatus, receivedAt: Date) {
        guard manager.list().contains(where: { $0.id == sessionID && $0.exitCode == nil }) else { return }
        hookStatus[sessionID] = (status, receivedAt); emit(.status(sessionID: sessionID, status: status, source: "hook"))
    }
    public func noteAgentObservation(sessionID: String, provider: String, conversationID: String?, ended: Bool) {
        observedAgents[sessionID] = ended ? nil : (provider, conversationID)
    }
    @discardableResult
    public func observe(_ callback: @escaping @Sendable (BackendSessionEvent) async -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    public func noteSessionEvent(_ event: BackendSessionEvent) async {
        switch event {
        case .data(let id, _):
            // New output is evidence of new work; stale Stop/Permission hook
            // status must not keep the row completed or blocked indefinitely.
            hookStatus[id] = nil
        case .status(let id, let status): statuses[id] = status; emit(.status(sessionID: id, status: hookStatus[id]?.status ?? status, source: hookStatus[id] == nil ? "screen" : "hook"))
        case .exit(let id, _):
            statuses[id] = .exited; hookStatus[id] = nil
            observedAgents[id] = nil
            await launch.processExited(id); await attribution.drop(sessionID: id)
            do { try await cleanup.release(id); try await store.ledgerFlush() } catch { failures.append(error.localizedDescription) }
        case .removed(let id, let reason):
            statuses[id] = nil; hookStatus[id] = nil
            observedAgents[id] = nil
            launchFacts[id] = nil
            await launch.removed(id, reason: reason); await attribution.drop(sessionID: id)
            do { try await cleanup.release(id) } catch { failures.append(error.localizedDescription) }
        }
        for observer in observers.values { await observer(event) }
        emit(.process(event))
    }
    public func sessionAccount(sessionID: String) async -> BackendAccountSessionReading {
        guard let session = manager.list().first(where: { $0.id == sessionID }) else { return .withheld("That session is not running on this computer.") }
        return await attribution.read(session, pid: manager.pidOf(sessionID))
    }
    public struct Metadata: Sendable {
        public let session: BackendSessionMeta
        public let status: BackendSessionStatus
        public let transcriptConfiguration: String?
        public let observedAgentProvider: String?
        public let observedCLIConversationID: String?
    }
    /// Usage/insights can consume this and the same ordered data/status events.
    /// They never need another terminal parser or session-process owner.
    public func metadata() async -> [Metadata] {
        var result: [Metadata] = []
        for session in manager.list() { result.append(Metadata(session: session, status: status(sessionID: session.id), transcriptConfiguration: await accounts.transcriptConfiguration(sessionID: session.id), observedAgentProvider: observedAgents[session.id]?.provider, observedCLIConversationID: observedAgents[session.id]?.conversationID)) }
        return result
    }
    public func cleanupFailures() -> [String] { failures }
    public func stopAccepting() { accepting = false }
    public func stopProcesses() async -> Bool { accepting = false; return await launch.stop() }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { entrants.append($0) } }
    private func leave() { if entrants.isEmpty { busy = false } else { entrants.removeFirst().resume() } }
}

public enum BackendSessionReplacementReadiness {
    public enum Outcome: String, Sendable { case ready, started, died, signedOut = "signed-out" }
    public struct Result: Sendable { public let outcome: Outcome; public let said: String?; public let waitedMilliseconds: Int }
    private static let signedOut = [#"not logged in"#, #"please run /login"#, #"select login method"#, #"invalid api key"#, #"oauth (?:session|token) (?:has )?expired"#, #"could not be refreshed"#]
    public static func lastLine(_ text: String, limit: Int = 160) -> String? {
        guard let line = text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { !$0.isEmpty }) else { return nil }
        return line.count > limit ? String(line.prefix(max(0, limit - 1))) + "…" : line
    }
    /// TS SWITCH_GRACE_MS: how long a replacement with no readable screen is
    /// given before "still alive" counts as started (session-switch.ts).
    public static let graceMilliseconds = 1_500
    /// What the wait reads, injected so a test drives a fake clock (REQ S5-6).
    public struct Probe: Sendable {
        public var alive: @Sendable () -> Bool
        public var screen: @Sendable () -> String?
        public var scrollback: @Sendable () -> String
        public var sleep: @Sendable (Int) async throws -> Void
        public init(alive: @escaping @Sendable () -> Bool, screen: @escaping @Sendable () -> String?,
                    scrollback: @escaping @Sendable () -> String, sleep: @escaping @Sendable (Int) async throws -> Void) {
            self.alive = alive; self.screen = screen; self.scrollback = scrollback; self.sleep = sleep
        }
    }
    /// Bounded source readiness check; two consecutive prompt/question frames
    /// prove ready. Alive at the ceiling is explicitly `started`, not `ready`.
    public static func awaitReady(sessionID: String, manager: BackendPTYManager, ceilingMilliseconds: Int = 15_000,
                                  intervalMilliseconds: Int = 150) async throws -> Result {
        let probe = Probe(alive: { manager.list().contains { $0.id == sessionID && $0.exitCode == nil } },
                          screen: { manager.screen(sessionID) }, scrollback: { manager.scrollback(sessionID) },
                          sleep: { milliseconds in try await Task.sleep(for: .milliseconds(milliseconds)) })
        return try await awaitReady(sessionID: sessionID, probe: probe, ceilingMilliseconds: ceilingMilliseconds, intervalMilliseconds: intervalMilliseconds)
    }
    /// TS awaitReplacement. With no screen to read there is no readiness signal,
    /// so the survival rule applies (TS survivedStart): one grace wait, then
    /// alive counts as started and gone reports the agent's own last line.
    public static func awaitReady(sessionID: String, probe: Probe, ceilingMilliseconds: Int = 15_000,
                                  intervalMilliseconds: Int = 150) async throws -> Result {
        var waited = 0, streak = 0
        while true {
            try Task.checkCancellation()
            guard probe.alive() else {
                return Result(outcome: .died, said: lastLine(probe.scrollback()), waitedMilliseconds: waited)
            }
            guard let screen = probe.screen() else {
                if waited < graceMilliseconds {
                    let rest = graceMilliseconds - waited
                    try await probe.sleep(rest); waited += rest; continue
                }
                return Result(outcome: .started, said: nil, waitedMilliseconds: waited)
            }
            if signedOut.contains(where: { screen.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
                return Result(outcome: .signedOut, said: lastLine(screen), waitedMilliseconds: waited)
            }
            let status = BackendSessionClassifier.classify(viewport: screen)
            streak = status == .waiting || status == .input ? streak + 1 : 0
            if streak >= 2 { return Result(outcome: .ready, said: nil, waitedMilliseconds: waited) }
            if waited >= ceilingMilliseconds { return Result(outcome: .started, said: nil, waitedMilliseconds: waited) }
            let interval = max(1, intervalMilliseconds)
            try await probe.sleep(interval); waited += interval
        }
    }
}
