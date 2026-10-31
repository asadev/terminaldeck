import Foundation
import TerminalDeckNativeCore

/// One public session path. Root fans ordered PTY events into this actor and
/// the remote host; it never constructs another PTY or ledger owner.
public actor BackendSessionLifecycleCoordinator {
    public nonisolated let manager: BackendPTYManager
    private let launch: BackendCoordinatedSessionLaunch
    #if TD_HOST_ACCOUNT_BRIDGE
    private let accounts: any BackendHOSTSessionAccountLifecycle
    private let attribution: any BackendHOSTSessionAccountAttributing
    #else
    private let accounts: BackendAccountLaunchAdapter
    private let attribution: BackendAccountAttribution
    #endif
    private let ledger: BackendNativeLedger
    private let store: NativeStateStore
    private let cleanup: BackendSessionLifecycleCleanup
    private let emit: @Sendable (BackendSessionLifecycleEvent) -> Void
    private var statuses: [String: BackendSessionStatus] = [:]
    private var acceptedStatuses: [String: BackendSessionStatus] = [:]
    private var hookStatus: [String: (status: BackendSessionStatus, at: Date)] = [:]
    private var observedAgents: [String: (provider: String, conversationID: String?)] = [:]
    private struct LaunchFacts: Sendable { let input: BackendCreateSessionInput; let context: BackendLaunchContext }
    private var launchFacts: [String: LaunchFacts] = [:]
    /// #425: each observer has its own ordered line, so a slow one holds back only itself.
    private var observers: [UUID: BackendSessionObserverLine] = [:]
    /// Observers that hear no output chunks (`observe(output: false)`).
    private var outputless: Set<UUID> = []
    private var failures: [String] = []
    private var accepting = true
    #if TD_HOST_ACCOUNT_BRIDGE
    private var admissionGeneration: UInt64 = 0
    private var processStopStarted = false
    #endif
    private var typingOwner: (@Sendable (String, String) async throws -> Void)?
    private let gate = BackendSessionAsyncGate()

    public init(manager: BackendPTYManager, launch: BackendCoordinatedSessionLaunch, accounts: BackendAccountLaunchAdapter,
                attribution: BackendAccountAttribution, ledger: BackendNativeLedger, store: NativeStateStore,
                cleanup: BackendSessionLifecycleCleanup, emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) throws {
        guard ledger.readiness == .ready, accounts.readiness == .ready, cleanup.readiness == .ready else {
            throw BackendSessionFailure.missingCapability("active native ledger, account runtime and actual session resource cleanup")
        }
        self.manager = manager; self.launch = launch
        #if TD_HOST_ACCOUNT_BRIDGE
        self.accounts = BackendHOSTLocalSessionAccountLifecycle(accounts: accounts)
        #else
        self.accounts = accounts
        #endif
        self.attribution = attribution
        self.ledger = ledger; self.store = store; self.cleanup = cleanup; self.emit = emit
    }
    #if TD_HOST_ACCOUNT_BRIDGE
    public init(manager: BackendPTYManager, launch: BackendCoordinatedSessionLaunch,
                accounts: any BackendHOSTSessionAccountLifecycle, attribution: any BackendHOSTSessionAccountAttributing,
                ledger: BackendNativeLedger, store: NativeStateStore, cleanup: BackendSessionLifecycleCleanup,
                emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void) throws {
        guard ledger.readiness == .ready, accounts.readiness == .ready, cleanup.readiness == .ready else {
            throw BackendSessionFailure.missingCapability("actual hosted account, ledger and session cleanup owners")
        }
        self.manager = manager; self.launch = launch; self.accounts = accounts; self.attribution = attribution
        self.ledger = ledger; self.store = store; self.cleanup = cleanup; self.emit = emit
    }
    #endif
    /// `named`: the name the person gave this tab before (its saved `title`), put on the new session before it is
    /// announced, so a restart or restore shows it under that name everywhere at once.
    public func create(_ requested: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext(), holdOnFailure: Bool = true,
                       announce: Bool = true, named: String? = nil) async throws -> BackendSessionMeta {
        if requested.replaces != nil, context.rememberTab, announce { return try await replace(requested, context: context) }
        var input = requested
        if Self.choosesMode(input, context: context, restoring: BackendAGSLaunchScope.restoring) {
            let remembered = context.fromWindow ? await store.getPreferences()[Self.newSessionModeKey].string : nil
            if Self.startsAsChat(context: context, remembered: remembered) { input.chat = true }
        }
        if context.fromAI, context.deviceBoundary == nil, input.chat == true, input.teamJob == nil {
            input.teamJob = BackendTeamChatJob(fromID: "hoot", fromName: "Hoot", agentID: input.agentProfileID ?? input.provider ?? "agent",
                agentName: input.agentProfileID ?? input.provider ?? "Agent", title: named ?? URL(fileURLWithPath: input.cwd).lastPathComponent)
            input.origin = .copilot
        }
        await gate.enter(); defer { gate.leave() }
        guard accepting else { throw BackendSessionFailure.closed }
        try Task.checkCancellation()
        let context = context.remembering(context.rememberTab && input.teamJob == nil && !context.isAppComposed && context.appFenceID == nil)
        var created: BackendSessionMeta?
        do {
            let result = try await launch.create(input, context: context)
            var session = result.session
            created = session
            launchFacts[session.id] = LaunchFacts(input: input, context: context)
            #if TD_HOST_ACCOUNT_BRIDGE
            if let pid = manager.pidOf(session.id) {
                try await accounts.bindProcessIfNeeded(sessionID: session.id, pid: pid, createdAt: session.createdAt)
            }
            #else
            if let pid = manager.pidOf(session.id), await accounts.broker.seatSnapshot(sessionID: session.id) != nil {
                try await accounts.broker.bindProcess(sessionID: session.id, pid: pid)
            }
            #endif
            if let name = named?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, session.title != name,
               manager.rename(session.id, title: name) {
                await rememberName(session.id, name)
                session = manager.list().first(where: { $0.id == session.id }) ?? session
            }
            if announce { emit(.created(session)) }
            return session
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
    /// The start choice belongs to the session. Reject a conflicting restart before touching its process.
    static func replacementMode(requested: Bool?, original: Bool?) throws -> Bool {
        let chat = original == true
        guard requested == nil || requested == chat else {
            throw BackendSessionFailure.unsupported("This session keeps its starting mode. Start a new session to choose Chat or Terminal.")
        }
        return chat
    }
    /// Retry/restart replacement is start, observe, remember, then stop. A
    /// failure keeps the outgoing tab and does not invent a held duplicate.
    public func replace(_ requested: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext()) async throws -> BackendSessionMeta {
        guard let oldID = requested.replaces, let old = manager.list().first(where: { $0.id == oldID }) else { throw BackendSessionFailure.missingSession }
        let mode = try Self.replacementMode(requested: requested.chat, original: old.chat)
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
        input.effort = requested.effort ?? raw["effort"].string
        input.deniedTools = (raw["deniedTools"].elements ?? []).compactMap(\.string)
        input.agentProfileID = raw["agentProfileID"].string
        input.noSkills = raw["noSkills"].bool == true ? true : nil; input.agentInstructions = raw["agentInstructions"].string
        input.claudeAgent = raw["claudeAgent"].string
        input.allowedTools = raw["allowedTools"].elements?.compactMap(\.string)
        input.permissionMode = raw["permissionMode"].string
        input.taskID = raw["taskID"].string
        input.taskProject = raw["taskProject"].string
        input.agentDefinitionsFile = raw["agentDefinitionsFile"].string
        // Restarting keeps the session's original mode, including a terminal's explicit false.
        input.chat = mode
        if input.resume == true, input.resumeConversationId == nil { input.resumeConversationId = old.agentSessionId ?? saved.conversationID }
        if input.resume == true, saved.provider == "claude", input.resumeConversationId == nil {
            throw BackendSessionFailure.unsupported("No exact conversation is known for this restart. Open the saved conversation chooser instead of guessing a new one.")
        }
        let born = try await create(input, context: context.remembering(false), holdOnFailure: false, announce: false, named: saved.title)
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
        if let chatTypingOwner, manager.list().contains(where: { $0.id == sessionID && $0.chat == true }) {
            try await chatTypingOwner(sessionID, data)
            try await ledger.activity(sessionID)
            return
        }
        if BackendPCDecisionDelivery.required {
            try await manager.writeAsync(sessionID, bytes: Data(data.utf8))
        } else {
            try manager.write(sessionID, data: data)
        }
        hookStatus[sessionID] = nil
        if data.contains("\n") || data.contains("\r") { emitStatus(sessionID, .working, source: "input") }
        try await ledger.activity(sessionID)
    }
    func setTypingOwner(_ owner: (@Sendable (String, String) async throws -> Void)?) { typingOwner = owner }
    private var chatTypingOwner: (@Sendable (String, String) async throws -> Void)?
    private var chatRemovalOwner: (@Sendable (BackendSessionMeta) async throws -> Void)?
    public func setChatOwners(typing: @escaping @Sendable (String, String) async throws -> Void,
                              removal: @escaping @Sendable (BackendSessionMeta) async throws -> Void) {
        chatTypingOwner = typing; chatRemovalOwner = removal
    }
    public func resize(sessionID: String, cols: Int, rows: Int) async throws {
        try manager.resize(sessionID, cols: cols, rows: rows)
        try await store.ledgerUpdate(sessionID, patch: .object([.init("cols", .number(Double(cols))), .init("rows", .number(Double(rows)))]))
    }
    /// 28 Oct: the session was chosen on this Mac (its session list or tab strip, or "Move back here"): this Mac
    /// owns its size from now on. When that gave the program a new size, this answers once its redraw has settled
    /// (quiet for 120 ms, at most 600 ms), so what this Mac's terminal reads next is drawn for it. True then.
    public func use(sessionID: String, cols: Int, rows: Int) async throws -> Bool {
        let resized = try manager.macUsed(sessionID, cols: cols, rows: rows)
        try await store.ledgerUpdate(sessionID, patch: .object([.init("cols", .number(Double(cols))), .init("rows", .number(Double(rows)))]))
        if resized { await manager.settle(sessionID) }
        return resized
    }
    public func close(sessionID: String, reason: BackendRemovalReason = .stopped) async throws {
        let meta = reason == .stopped ? manager.list().first(where: { $0.id == sessionID }) : nil
        if let meta { try await chatRemovalOwner?(meta) }
        // Forget before the process exit callback: a crash in the gap must not
        // restore a deliberately removed outgoing tab beside its replacement.
        try await store.ledgerForget(sessionID)
        manager.kill(sessionID, reason: reason)
        // U144 (#423): a removed tab takes the conversation copies of its AI handovers with it.
        if let meta, let data = store.file?.deletingLastPathComponent() { BackendSessionAIHandover.forget(tab: meta.tabKey ?? meta.id, data: data) }
    }
    /// A name the person gave the session (side panel, session bar, phone, a tool): on the session itself (in the
    /// helper when it runs there; an older helper takes it too) and in its saved launch, so an app restart, a helper
    /// crash or a restore brings it back under the same name. A blank puts the folder's name back and forgets the saved one.
    public func rename(sessionID: String, title: String) async throws -> Bool {
        guard manager.rename(sessionID, title: title) else { return false }
        await rememberName(sessionID, title)
        return true
    }
    private func rememberName(_ sessionID: String, _ title: String) async {
        let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await store.ledgerUpdate(sessionID, patch: .object([.init("title", given.isEmpty ? .null : .string(given))])) }
        catch { failures.append("The name of session \(sessionID) was not kept for a restart: " + error.localizedDescription) }
    }
    public func setWatched(_ watched: Bool) { manager.setWatched(watched) }
    /// The app preference that holds the person's last Chat / Terminal choice ("chat" or "terminal").
    public static let newSessionModeKey = "newSessionMode"
    /// Whether the app picks Chat or Terminal for this start (the request said neither). Asad, 13 Oct ~01:30: chat is
    /// the default everywhere; a terminal only when the person opens one. Only the person's window and an AI's tools
    /// pick: a restart, a restore or a replacement keeps the session's own mode, a phone's start stays a terminal
    /// (the phone has no chat screen yet), and a task's worker stays as the task engine starts it (the Tasks seat
    /// moves workers to chat sessions next).
    public static func choosesMode(_ input: BackendCreateSessionInput, context: BackendLaunchContext, restoring: Bool) -> Bool {
        input.chat == nil && (context.fromWindow || context.fromAI) && input.replaces == nil && !restoring
            && input.taskID == nil && input.taskProject == nil && context.deviceBoundary == nil
    }
    /// The pick: the person's last choice in their window (chat until they choose a terminal), always chat for an AI.
    public static func startsAsChat(context: BackendLaunchContext, remembered: String?) -> Bool {
        context.fromWindow ? remembered != "terminal" : context.fromAI
    }
    public func status(sessionID: String) -> BackendSessionStatus {
        if let session = manager.list().first(where: { $0.id == sessionID }), session.exitCode != nil { return .exited }
        return hookStatus[sessionID]?.status ?? statuses[sessionID] ?? .idle
    }
    public func noteHookStatus(sessionID: String, status: BackendSessionStatus, receivedAt: Date) {
        guard manager.list().contains(where: { $0.id == sessionID && $0.exitCode == nil }) else { return }
        hookStatus[sessionID] = (status, receivedAt); emitStatus(sessionID, status, source: "hook")
    }
    private func emitStatus(_ id: String, _ status: BackendSessionStatus, source: String) {
        guard acceptedStatuses[id] != status else { return }
        acceptedStatuses[id] = status
        emit(.status(sessionID: id, status: status, source: source))
    }
    public func noteAgentObservation(sessionID: String, provider: String, conversationID: String?, ended: Bool) {
        observedAgents[sessionID] = ended ? nil : (provider, conversationID)
    }
    public func acceptedAlertBaseline() -> [BackendAGSAlertSession] {
        manager.list().filter { $0.exitCode == nil }.map {
            BackendAGSAlertSession(id: $0.id, status: acceptedStatuses[$0.id])
        }
    }
    public func acceptedAlertStatus(sessionID: String) -> BackendSessionStatus? {
        guard manager.list().contains(where: { $0.id == sessionID && $0.exitCode == nil }) else { return nil }
        return acceptedStatuses[sessionID]
    }
    /// `output: false` skips every output chunk; such an observer still hears, as a status,
    /// the one change output can make (a working hook yielding to the screen).
    @discardableResult
    public func observe(output: Bool = true, _ callback: @escaping @Sendable (BackendSessionEvent) async -> Void) -> UUID {
        let id = UUID(); observers[id] = BackendSessionObserverLine(callback)
        if !output { outputless.insert(id) }
        return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.remove(); outputless.remove(id) }
    public func noteSessionEvent(_ event: BackendSessionEvent) async {
        var yielded: BackendSessionStatus?
        switch event {
        case .data(let id, _):
            // Completed/input hooks remain authoritative through TUI redraws.
            // New input or the next work hook starts another turn. A work hook
            // can still yield to the screen if its matching Stop never arrives.
            if hookStatus[id]?.status == .working {
                hookStatus[id] = nil
                yielded = status(sessionID: id)
            }
        case .status(let id, let status):
            guard let session = manager.list().first(where: { $0.id == id }) else { break }
            if session.exitCode != nil || status == .exited { hookStatus[id] = nil; statuses[id] = .exited }
            else { statuses[id] = status }
            emitStatus(id, hookStatus[id]?.status ?? statuses[id] ?? .idle, source: hookStatus[id] == nil ? "screen" : "hook")
        case .exit(let id, _):
            statuses[id] = .exited; hookStatus[id] = nil
            if manager.list().contains(where: { $0.id == id }) { emitStatus(id, .exited, source: "exit") }
            else { acceptedStatuses[id] = nil }
            observedAgents[id] = nil
            await launch.processExited(id); await attribution.drop(sessionID: id)
            do { try await cleanup.release(id); try await store.ledgerFlush() } catch { failures.append(error.localizedDescription) }
        case .removed(let id, let reason):
            statuses[id] = nil; hookStatus[id] = nil
            acceptedStatuses[id] = nil
            observedAgents[id] = nil
            launchFacts[id] = nil
            await launch.removed(id, reason: reason); await attribution.drop(sessionID: id)
            do { try await cleanup.release(id) } catch { failures.append(error.localizedDescription) }
        }
        // Every observer hears events in order, on its own line. Output and status are handed
        // over without waiting; an exit or removal waits until each observer has handled it.
        for (key, observer) in observers {
            if case .data(let id, _) = event, outputless.contains(key) {
                if let yielded { observer.post(.status(id: id, status: yielded)) }
                continue
            }
            observer.post(event)
        }
        switch event {
        case .exit, .removed: for observer in Array(observers.values) { await observer.drained() }
        case .data, .status: break
        }
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
    /// 22 Oct (Asad "Fix the host"): a row's transcript setting is one request to the session host, so a full list costs one
    /// request per session. Hoot's island asked for it on every status change of every session. Ask only for what is read:
    /// `transcripts: false` when no transcript is opened, `metadata(sessionID:)` for one session.
    public func metadata(transcripts: Bool = true) async -> [Metadata] {
        var result: [Metadata] = []
        for session in manager.list() { result.append(await row(session, transcript: transcripts)) }
        return result
    }
    public func metadata(sessionID: String) async -> Metadata? {
        guard let session = manager.list().first(where: { $0.id == sessionID }) else { return nil }
        return await row(session, transcript: true)
    }
    public func transcriptConfiguration(sessionID: String) async -> String? { await accounts.transcriptConfiguration(sessionID: sessionID) }
    private func row(_ session: BackendSessionMeta, transcript: Bool) async -> Metadata {
        Metadata(session: session, status: status(sessionID: session.id),
                 transcriptConfiguration: transcript ? await accounts.transcriptConfiguration(sessionID: session.id) : nil,
                 observedAgentProvider: observedAgents[session.id]?.provider, observedCLIConversationID: observedAgents[session.id]?.conversationID)
    }
    public func conversationSender(_ caller: BackendDeckCoreSecurityCaller) async -> BackendTeamChatSender {
        let id = caller.sessionID ?? ""
        let projects = (try? await BackendPROJRegistry.installed?.projects()) ?? []
        return BackendTeamChatSender.resolve(caller: caller, input: launchFacts[id]?.input,
            session: manager.list().first { $0.id == id }, owner: DeckMemorySessionCenter.shared?.owner(sessionID: id), projects: projects)
    }
    public func launchInput(_ id: String) -> BackendCreateSessionInput? { launchFacts[id]?.input }
    public func cleanupFailures() -> [String] { failures }
    public func stopAccepting() {
        #if TD_HOST_ACCOUNT_BRIDGE
        admissionGeneration &+= 1
        #endif
        accepting = false
    }
    #if TD_HOST_ACCOUNT_BRIDGE
    /// Only a failed Keep may undo its own pause; a later quit/Stop invalidates it.
    public func pauseForHostedKeep() -> UInt64? {
        let wasAccepting = accepting
        admissionGeneration &+= 1; accepting = false
        return wasAccepting && !processStopStarted ? admissionGeneration : nil
    }
    public func resumeAfterBlockedHostedKeep(_ generation: UInt64?) {
        guard let generation, generation == admissionGeneration, !processStopStarted else { return }
        accepting = true
    }
    #endif
    public func stopProcesses() async -> Bool {
        #if TD_HOST_ACCOUNT_BRIDGE
        processStopStarted = true; admissionGeneration &+= 1
        #endif
        accepting = false; return await launch.stop()
    }
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
        /// 18 Oct (#446): waits until the session says something (output, a status, its end) or the time is up,
        /// and answers the milliseconds really waited. Never a timer that reads the screen while nothing happens.
        public var wait: @Sendable (Int) async throws -> Int
        public init(alive: @escaping @Sendable () -> Bool, screen: @escaping @Sendable () -> String?,
                    scrollback: @escaping @Sendable () -> String, wait: @escaping @Sendable (Int) async throws -> Int) {
            self.alive = alive; self.screen = screen; self.scrollback = scrollback; self.wait = wait
        }
        /// A probe whose session says nothing: every wait lasts its whole time (the fake-clock tests).
        public init(alive: @escaping @Sendable () -> Bool, screen: @escaping @Sendable () -> String?,
                    scrollback: @escaping @Sendable () -> String, sleep: @escaping @Sendable (Int) async throws -> Void) {
            self.init(alive: alive, screen: screen, scrollback: scrollback, wait: { milliseconds in try await sleep(milliseconds); return milliseconds })
        }
    }
    /// Bounded source readiness check; two consecutive prompt/question frames
    /// prove ready. Alive at the ceiling is explicitly `started`, not `ready`.
    /// 18 Oct (#446): woken by the session's own events, not by reading its screen several times a second.
    public static func awaitReady(sessionID: String, manager: BackendPTYManager, ceilingMilliseconds: Int = 15_000,
                                  intervalMilliseconds: Int = 150) async throws -> Result {
        // A chat's AI has finished its handshake before the session exists: it is ready.
        if manager.isChat(sessionID) { return .init(outcome: .ready, said: nil, waitedMilliseconds: 0) }
        let bell = Bell()
        let subscription = manager.remoteServeObserve { value in
            switch value.event {
            case .data(let id, _), .status(let id, _), .exit(let id, _), .removed(let id, _): if id == sessionID { bell.ring() }
            }
        }
        defer { subscription.cancel() }
        let probe = Probe(alive: { manager.list().contains { $0.id == sessionID && $0.exitCode == nil } },
                          screen: { manager.screen(sessionID) }, scrollback: { manager.scrollback(sessionID) },
                          wait: { milliseconds in await bell.wait(milliseconds: milliseconds) })
        return try await awaitReady(sessionID: sessionID, probe: probe, ceilingMilliseconds: ceilingMilliseconds, intervalMilliseconds: intervalMilliseconds)
    }
    /// TS awaitReplacement. With no screen to read there is no readiness signal,
    /// so the survival rule applies (TS survivedStart): one grace wait, then
    /// alive counts as started and gone reports the agent's own last line.
    /// A screen that shows no prompt yet waits for the session's next event (up to the ceiling); a prompt is
    /// confirmed by one short wait with no new output (`intervalMilliseconds`).
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
                    waited += try await probe.wait(graceMilliseconds - waited); continue
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
            let rest = ceilingMilliseconds - waited
            let slept = try await probe.wait(streak > 0 ? min(max(1, intervalMilliseconds), rest) : rest)
            // New output while a prompt was being confirmed: it is judged again from the start.
            if streak > 0, slept < min(max(1, intervalMilliseconds), rest) { streak = 0 }
            waited += max(1, slept)
        }
    }
    /// Rung by the replacement's own events; `wait` returns at the first ring or when its time is up.
    final class Bell: @unchecked Sendable {
        private let lock = NSLock()
        private var rung = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var generation: UInt64 = 0
        private var expired: UInt64 = 0
        func ring() {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                guard let waiter else { rung = true; return nil }
                self.waiter = nil; return waiter
            }
            next?.resume()
        }
        func wait(milliseconds: Int) async -> Int {
            let start = ContinuousClock.now
            let token: UInt64? = lock.withLock {
                if rung { rung = false; return nil }
                generation &+= 1; return generation
            }
            guard let token else { return 0 }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(milliseconds)); self?.expire(token)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if rung || expired == token { rung = false; return true }
                    waiter = continuation; return false
                }
                if now { continuation.resume() }
            }
            timer.cancel()
            let elapsed = ContinuousClock.now - start
            return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
        private func expire(_ token: UInt64) {
            let next: CheckedContinuation<Void, Never>? = lock.withLock {
                guard token == generation else { return nil }
                guard let waiter else { expired = token; return nil }
                self.waiter = nil; return waiter
            }
            next?.resume()
        }
    }
}

/// #425: one observer's own ordered line. Posting never waits for the observer, so a slow
/// one (a phone on a slow link, a disk write) delays only its own later events.
final class BackendSessionObserverLine: @unchecked Sendable {
    private enum Item: Sendable { case event(BackendSessionEvent), drained(CheckedContinuation<Void, Never>) }
    private let input: AsyncStream<Item>.Continuation
    private let lock = NSLock()
    private var removed = false

    init(_ callback: @escaping @Sendable (BackendSessionEvent) async -> Void) {
        let (items, input) = AsyncStream<Item>.makeStream()
        self.input = input
        Task { [self] in
            for await item in items {
                switch item {
                case .event(let event): if !isRemoved { await callback(event) }
                case .drained(let waiter): waiter.resume()
                }
            }
        }
    }
    func post(_ event: BackendSessionEvent) { input.yield(.event(event)) }
    /// Returns once everything posted before it has been handled (or the line was removed).
    func drained() async {
        await withCheckedContinuation { waiter in
            if case .terminated = input.yield(.drained(waiter)) { waiter.resume() }
        }
    }
    /// Nothing more reaches the observer; anyone waiting on the line is let go.
    func remove() { lock.withLock { removed = true }; input.finish() }
    private var isRemoved: Bool { lock.withLock { removed } }
}
