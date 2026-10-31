import Foundation
import TerminalDeckNativeCore

private final class BackendCopilotSessionIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    func set(_ value: String?) { lock.withLock { id = value } }
    func contains(_ value: String) -> Bool { lock.withLock { id != nil && id == value } }
}

public enum BackendCopilotSessionStatus: String, Sendable { case stopped, starting, running }
public struct BackendCopilotSessionSignIn: Sendable {
    public let state: String
    public let account: String?
    public let plan: String?
    public let profileId: String
    public let profileName: String
    public let checkedAt: Double
    public var wireValue: NativeRPCValue {
        BackendCopilotInspect.object([("state", .string(state)), ("account", BackendCopilotInspect.optional(account)), ("plan", BackendCopilotInspect.optional(plan)),
            ("profileId", .string(profileId)), ("profileName", .string(profileName)), ("checkedAt", .number(checkedAt))])
    }
}
public struct BackendCopilotSessionRecords: Sendable {
    public let kind: String
    public let enforced: Bool
    public let reason: String?
    public let paths: [String]
    public var wireValue: NativeRPCValue { BackendCopilotInspect.object([("kind", .string(kind)), ("enforced", .bool(enforced)), ("reason", BackendCopilotInspect.optional(reason)), ("paths", .array(paths.map(NativeRPCValue.string)))]) }
}
public struct BackendCopilotSessionState: Sendable {
    public let status: BackendCopilotSessionStatus
    public let sessionId: String?
    public let paths: BackendCopilotPaths
    public let folder: BackendCopilotFolderReport
    public let home: String
    public let startedAt: Double?
    public let problem: String?
    public let records: BackendCopilotSessionRecords
    public let profile: BackendAccountIdentity?
    public let instructionsAreDefault: Bool
    public let instructions: BackendCopilotInstructionsState
    public let startupFiles: [BackendCopilotStartupFile]
    public let layerFiles: [BackendCopilotStartupFile]
    public var wireValue: NativeRPCValue {
        let identity = profile.map { BackendCopilotInspect.object([("id", .string($0.id)), ("name", .string($0.name))]) } ?? .null
        return BackendCopilotInspect.object([("status", .string(status.rawValue)), ("sessionId", BackendCopilotInspect.optional(sessionId)), ("paths", paths.wireValue),
            ("folder", folder.wireValue), ("home", .string(home)), ("startedAt", startedAt.map(NativeRPCValue.number) ?? .null), ("problem", BackendCopilotInspect.optional(problem)),
            ("records", records.wireValue), ("profile", identity), ("instructionsAreDefault", .bool(instructionsAreDefault)), ("instructions", .string(instructions.rawValue)),
            ("startupFiles", .array(startupFiles.map(\.wireValue))), ("layerFiles", .array(layerFiles.map(\.wireValue)))])
    }
}
public struct BackendCopilotSessionFence: Sendable {
    /// Existing BackendMacConfinement.recordsFenceID, never renderer input.
    public let id: String
    public let kind: String
    public init(id: String = BackendMacConfinement.recordsFenceID, kind: String = "seatbelt") { self.id = id; self.kind = kind }
}
public struct BackendCopilotSessionFenceMeasurement: Sendable {
    public let fence: BackendCopilotSessionFence?
    public let reason: String?
    public init(fence: BackendCopilotSessionFence?, reason: String?) { self.fence = fence; self.reason = reason }
}
/// A fenced launch whose records proof failed again at spawn time. Source
/// measures once and wraps the spawn; the native launcher re-proves, so this
/// second failure gets the same visible fail-open result, never a Hoot outage.
public struct BackendCopilotSessionFenceLost: Error, LocalizedError, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}
/// The existing macOS confinement owner must expose its one canonical resolver
/// and its per-start proof. Missing proof is a visible, fail-open records result.
public protocol BackendCopilotSessionRecordsProviding: Sendable {
    func paths(userData: String) async throws -> BackendCopilotLayerRecords
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement
}
public struct BackendCopilotSessionUnavailableRecords: BackendCopilotSessionRecordsProviding {
    public init() {}
    public func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        throw NativeRPCError(code: "unavailable", message: "Hoot's canonical records fence resolver is unavailable.")
    }
    public func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement {
        .init(fence: nil, reason: "This app’s own routines and action log could not be held against Hoot on this machine: the native records fence proof is unavailable.")
    }
}
/// Reuse the app's profile, sign-in and launcher graph. Local Hoot passes no
/// guest Git environment and no paired-device confinement, exactly as TS does.
public protocol BackendCopilotSessionDriving: Sendable {
    func hasClaude() async throws -> Bool
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?)
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta
    func isAlive(_ sessionID: String) async -> Bool
    func stop(_ sessionID: String) async throws
    /// Just before a message is sent: apply a changed model/effort/context/permission silently
    /// (the live child is replaced; the conversation resumes with the new flags).
    func prepareForSend() async
}
public extension BackendCopilotSessionDriving { func prepareForSend() async {} }
public struct BackendCopilotSessionUnavailableDriver: BackendCopilotSessionDriving {
    public init() {}
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "Hoot's native session/profile driver is unavailable.") }
    public func hasClaude() async throws -> Bool { throw unavailable() }
    public func resolveProfile(projectPath: String) async throws -> BackendAccountProfile { throw unavailable() }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { throw unavailable() }
    public func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta { throw unavailable() }
    public func isAlive(_ sessionID: String) async -> Bool { false }
    public func stop(_ sessionID: String) async throws { throw unavailable() }
}
public struct BackendCopilotSessionTools: Sendable {
    public let configPath: String
    public let tools: [BackendCopilotLayerTool]
    public let leaseID: UUID
    public init(configPath: String, tools: [BackendCopilotLayerTool], leaseID: UUID) { self.configPath = configPath; self.tools = tools; self.leaseID = leaseID }
}
public protocol BackendCopilotSessionToolProviding: Sendable {
    /// Nil is an actually absent server, never a guessed/stale config path.
    func catalogue() async throws -> [BackendCopilotLayerTool]?
    func prepare() async throws -> BackendCopilotSessionTools?
    func bind(_ tools: BackendCopilotSessionTools, sessionID: String) async throws
    func abandon(_ tools: BackendCopilotSessionTools) async
    func release(sessionID: String) async
}
public extension BackendCopilotSessionToolProviding {
    func catalogue() async throws -> [BackendCopilotLayerTool]? {
        throw BackendSessionFailure.missingCapability("a catalogue-only session tool source")
    }
}
public struct BackendCopilotSessionDependencies: Sendable {
    public let userData: String
    public let storageDir: String
    public let chosenFolder: @Sendable () async throws -> NativeRPCValue
    public let driver: any BackendCopilotSessionDriving
    public let records: any BackendCopilotSessionRecordsProviding
    public let tools: (any BackendCopilotSessionToolProviding)?
    public let chat: BackendHootChatStore?
    public let cols: Int
    public let rows: Int
    /// "Pick up where you left off" (preferences `restoreSessions`, on unless the person turned it off): when off, an
    /// answer cut off by the app's restart is not carried on by itself. Read when the first start of a run happens.
    public let picksUpAfterRestart: @Sendable () async -> Bool
    public init(userData: String, storageDir: String? = nil,
                chosenFolder: @escaping @Sendable () async throws -> NativeRPCValue = { .null },
                driver: any BackendCopilotSessionDriving, records: any BackendCopilotSessionRecordsProviding,
                tools: (any BackendCopilotSessionToolProviding)? = nil, chat: BackendHootChatStore? = nil, cols: Int = 120, rows: Int = 30,
                picksUpAfterRestart: @escaping @Sendable () async -> Bool = { true }) {
        self.userData = userData; self.storageDir = storageDir ?? URL(fileURLWithPath: userData).appendingPathComponent("remote").path
        self.chosenFolder = chosenFolder; self.driver = driver; self.records = records; self.tools = tools; self.chat = chat; self.cols = cols; self.rows = rows
        self.picksUpAfterRestart = picksUpAfterRestart
    }
    /// The same reading as the app's own restart continuation: on unless `restoreSessions` is false.
    public static func picksUpAfterRestart(_ preferences: NativeRPCValue) -> Bool { preferences["restoreSessions"].bool != false }
}

/// The one desk Hoot. Construct one actor for the assembled app, never one per
/// window. A Task latch survives actor reentrancy across every startup await.
public actor BackendCopilotSessionRuntime {
    public static let homeKey = "copilot"
    public static let signInTTLMilliseconds: Double = 60_000
    public static let channels = ["hoot:ensure", "hoot:state", "hoot:files", "hoot:stop", "hoot:signin", "hoot:read-instructions", "hoot:read-contract", "hoot:read-composed", "hoot:write-instructions", "hoot:read-folder-instructions", "hoot:write-folder-instructions", "hoot:reset-instructions"] + BackendHootChatChannels.invokes
    public nonisolated let structuredChat: BackendHootChatStore?
    private struct Live: Sendable {
        let sessionID: String
        let startedAt: Double
        let root: String
        let fenced: Bool
        let profile: BackendAccountIdentity
    }
    private let deps: BackendCopilotSessionDependencies
    private nonisolated let identity = BackendCopilotSessionIdentity()
    private var live: Live? { didSet { identity.set(live?.sessionID) } }
    private var starting: Task<BackendCopilotSessionState, Error>?
    private var problem: String?
    private var fenceProblem: String?
    private var signInCache: BackendCopilotSessionSignIn?
    private var closing = false
    /// The first start of this run looks once for an answer the app's last end cut off, and carries on with it.
    private var continuationChecked = false
    private var changingConversation = false
    /// Keeps Hoot available: an unplanned end is logged and Hoot restarts quietly.
    private var reporter: (@Sendable (String) -> Void)?
    private var restartTask: Task<Void, Never>?
    private var restarts: [Date] = []
    public static let restartBackoff: [Double] = [1, 5, 15, 60]
    /// The app's log line writer; also arms the supervisor on Hoot's chat.
    public func setReporter(_ reporter: @escaping @Sendable (String) -> Void) async {
        self.reporter = reporter
        await structuredChat?.setExitObserver { [weak self] reason in await self?.ended(reason) }
    }
    private func ended(_ reason: String) async {
        guard !closing else { return }
        _ = await structuredChat?.takeEndReason()
        if let paths = try? await layerPaths() {
            BackendCopilotHome.appendAction(paths, .init(action: "session.ended", detail: reason, sessionId: live?.sessionID))
        }
        reporter?("Hoot stopped: " + reason)
        scheduleRestart(after: reason)
    }
    private func scheduleRestart(after reason: String) {
        guard !closing, restartTask == nil else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 600 }
        guard restarts.count < Self.restartBackoff.count + 1 else {
            reporter?("Hoot stopped \(restarts.count) times in 10 minutes; it starts again when Hoot is opened or sent a message.")
            return
        }
        let delay = Self.restartBackoff[min(restarts.count, Self.restartBackoff.count - 1)]
        restarts.append(now)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.restartNow()
        }
    }
    private func restartNow() async {
        restartTask = nil
        guard !closing, !changingConversation else { return }
        do {
            let state = try await ensure()
            reporter?(state.status == .running ? "Hoot is awake again (restarted quietly)"
                      : "Hoot could not restart: " + (state.problem ?? "it stopped"))
        } catch { reporter?("Hoot could not restart: " + error.localizedDescription) }
    }
    // MARK: The safety guard (records fence) when it could not be switched on
    public static let guardRetrySeconds: Double = 30
    private var guardRetry: Task<Void, Never>?
    private var guardAttempts = 0
    private func guardStarted(held: Bool, reason: String?) async {
        if held {
            guardRetry?.cancel(); guardRetry = nil
            if guardAttempts > 0 { reporter?("Hoot's safety guard holds again (after \(guardAttempts) retr\(guardAttempts == 1 ? "y" : "ies"))") }
            guardAttempts = 0
            await structuredChat?.setGuardOff(nil)
            return
        }
        await structuredChat?.setGuardOff(reason ?? "The app's guard on its own records could not be switched on.")
        reporter?("Hoot started WITHOUT its safety guard: " + (reason ?? "unknown reason") + ". Trying again every \(Int(Self.guardRetrySeconds)) s.")
        guard guardRetry == nil, !closing else { return }
        guardRetry = Task { [weak self] in
            while !Task.isCancelled {
                let attempt = await self?.guardAttempts ?? 0
                // Soon after a start (a miss there is usually a busy moment), then every 30 s.
                let wait = attempt == 0 ? 5.0 : attempt == 1 ? 15.0 : BackendCopilotSessionRuntime.guardRetrySeconds
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                guard let self, await self.guardAttempt() else { continue }
                return
            }
        }
    }
    /// One retry: measure the guard; when it holds, restart Hoot with it at the next quiet moment. True = done.
    private func guardAttempt() async -> Bool {
        guard !closing, live != nil else { guardRetry = nil; return true }
        guardAttempts += 1
        let measured = await deps.records.measure(userData: deps.userData)
        guard measured.fence != nil else {
            reporter?("Hoot's safety guard, attempt \(guardAttempts): still off. " + (measured.reason ?? ""))
            return false
        }
        reporter?("Hoot's safety guard, attempt \(guardAttempts): it can be switched on now; Hoot restarts with it when it is not answering.")
        if let chat = structuredChat { await chat.waitUntilIdle(); await chat.holdAlive() }
        guardRetry = nil
        do {
            // Same conversation: only the CLI is restarted, so it resumes with the guard in place.
            _ = try await rebuildDesk(reason: "safety guard") { _ in "safety guard: Hoot restarted with the app's guard on its own records (same conversation)." }
        } catch {
            await structuredChat?.deskRefreshEnded()
            reporter?("Hoot's safety guard could not be put back yet: " + error.localizedDescription)
            if live != nil, guardRetry == nil { await guardStarted(held: false, reason: "Hoot could not restart with the guard: " + error.localizedDescription) }
        }
        return true
    }
    // MARK: Task turns (BackendHootTaskTurn.swift)
    private var taskLine: Task<Void, Never>?
    /// One task at a time, in the order they were handed over.
    func taskSlot() -> (wait: Task<Void, Never>?, done: AsyncStream<Void>.Continuation) {
        let previous = taskLine, pair = AsyncStream<Void>.makeStream()
        taskLine = Task { await previous?.value; for await _ in pair.stream {} }
        return (previous, pair.continuation)
    }
    /// Background turns cancelled while they waited their turn (by turn prefix).
    private var cancelledTurns: [String: Int] = [:], waitingTurns: [String: Int] = [:]
    func noteWaiting(_ prefix: String, _ change: Int) { waitingTurns[prefix] = max(0, (waitingTurns[prefix] ?? 0) + change) }
    /// Every copy of this turn that is waiting right now is cancelled (M25, 11 Oct: a Stop was undone by a second copy of
    /// the same handoff waiting behind it). A later request for the same thing is never caught by an old cancel.
    func noteCancelled(_ prefix: String) { if let waiting = waitingTurns[prefix], waiting > 0 { cancelledTurns[prefix] = waiting } }
    func waitingPrefixes(startingWith start: String) -> [String] { waitingTurns.filter { $0.key.hasPrefix(start) && $0.value > 0 }.map(\.key) }
    func takeCancelled(_ prefix: String) -> Bool {
        guard let left = cancelledTurns[prefix], left > 0 else { return false }
        cancelledTurns[prefix] = left > 1 ? left - 1 : nil
        return true
    }
    /// Turns that were interrupted on purpose (a task stopped or given to someone else): never reported as finished.
    private var interruptedTurns: Set<String> = []
    func noteInterrupted(_ turn: String) { interruptedTurns.insert(turn) }
    func takeInterrupted(_ turn: String) -> Bool { interruptedTurns.remove(turn) != nil }
    /// What Hoot is working in the background: the turn running now (reason and what it is about) and how many wait.
    public func backgroundStatus() async -> NativeRPCValue {
        var running = NativeRPCValue.null
        if let chat = structuredChat, await chat.isBusy {
            let turn = await chat.activeTurnID
            if turn.hasPrefix(BackendHootBackgroundTurn.turnPrefix) {
                let parts = turn.dropFirst(BackendHootBackgroundTurn.turnPrefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                running = .object([.init("reason", .string(parts.first ?? "")), .init("id", .string(parts.dropFirst().dropLast().joined(separator: ":")))])
            }
        }
        return .object([.init("running", running), .init("waiting", .number(Double(waitingTurns.values.reduce(0, +))))])
    }
    // MARK: Deck Memory: Hoot's desk
    /// The card at the top and the few lines with each message. The app never restarts Hoot on a fresh
    /// conversation to empty his desk (28 Oct 2026: the planned refresh is gone).
    public nonisolated let desk = BackendHootDesk()
    private var deskWired = false
    private func wireDesk() async {
        guard !deskWired, let chat = structuredChat else { return }
        deskWired = true
        var hooks = BackendHootDesk.Hooks()
        hooks.log = { [weak self] line in
            NSLog("[native Hoot] desk: %@", line)
            Task { await self?.deskReport(line) }
        }
        await desk.bind(hooks)
        let desk = desk
        await chat.setDesk(lines: { text, context in await desk.lines(for: text, context: context) })
    }
    private func deskReport(_ line: String) { reporter?("Hoot's desk: " + line) }
    /// Stops Hoot, changes its chat (a rewind, a part taken out) and starts it again on a clean desk
    /// built from what the chat now holds. `change` returns the line for Hoot's action log.
    private func rebuildDesk(reason: String, change: @escaping @Sendable (BackendHootChatStore) async throws -> String) async throws -> String {
        guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's chat is unavailable.") }
        guard !closing, !changingConversation else { throw NativeRPCError(code: "busy", message: "Hoot is starting a new chat.") }
        // A rebuild still settling (an Undo pressed right after its Rewind) is waited for, not refused.
        for _ in 0..<20 { guard let pending = starting else { break }; _ = try? await pending.value; await Task.yield() }
        guard starting == nil, !(await chat.isBusy) else { throw NativeRPCError(code: "busy", message: "Hoot is in the middle of an answer.") }
        // The CLI restarts behind the scenes: the header keeps saying Hoot is there (H14, 11 Oct).
        await chat.holdAlive()
        let attempt = Task { try await self.rebuildDeskNow(chat: chat, change: change) }
        starting = attempt
        defer { starting = nil }
        let state: BackendCopilotSessionState
        do { state = try await attempt.value } catch { await chat.deskRefreshEnded(); throw error }
        await chat.deskRefreshEnded()
        guard state.status == .running else { throw NativeRPCError(code: "unavailable", message: state.problem ?? "Hoot could not start again.") }
        return chat.conversationID
    }
    private func rebuildDeskNow(chat: BackendHootChatStore, change: @Sendable (BackendHootChatStore) async throws -> String) async throws -> BackendCopilotSessionState {
        let paths = try await layerPaths()
        if let existing = live {
            live = nil
            try await deps.driver.stop(existing.sessionID)
            await deps.tools?.release(sessionID: existing.sessionID)
        }
        let line = try await change(chat)
        BackendCopilotHome.appendAction(paths, .init(action: "desk.rebuilt", detail: line, sessionId: chat.conversationID))
        return try await start()
    }

    // MARK: Rewind (the chat goes back to a message; Hoot's desk is rebuilt up to there; memory keeps the rest as history)
    private var lastRewind: (chat: String, memory: Int64?)?
    private var rewinding: Task<String, Error>?
    /// Returns the text to put back in the message box ("" when the chosen message was Hoot's).
    public func rewindChat(to sequence: Int) async throws -> String {
        let job = Task { try await self.rewindChatNow(to: sequence) }
        rewinding = job
        defer { rewinding = nil }
        return try await job.value
    }
    private func rewindChatNow(to sequence: Int) async throws -> String {
        guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's chat is unavailable.") }
        // What is about to go, to tell memory which diary rows it covers.
        let conversation = chat.conversationID, cut = await chat.time(ofSequence: sequence)
        let taken = BackendHootRewindBox()
        _ = try await rebuildDesk(reason: "rewind") { chat in
            let result = try await chat.rewind(to: sequence)
            taken.set(id: result.id, text: result.text)
            return "rewind: the chat went back to an earlier message; what came after is set aside and can be put back until the next message."
        }
        var memoryID: Int64?
        if let cut, DeckMemory.isReady {
            let memory = DeckMemory.store, at = Date(timeIntervalSince1970: cut / 1000)
            // Everything written before the chosen message stays; memory sets the rest aside (and can undo it).
            let stays = try? await memory.diary(.init(conversation: conversation, until: at.addingTimeInterval(-0.001), limit: 1, newestFirst: true)).first?.id
            memoryID = try? await memory.markRewound(owner: .hoot, conversation: conversation, after: stays ?? 0).id
        }
        lastRewind = (taken.id, memoryID)
        return taken.text
    }
    public func undoRewindChat() async throws {
        // An Undo pressed while its Rewind is still settling waits for it instead of being lost (H20, 11 Oct).
        if let rewinding { _ = try? await rewinding.value }
        guard let last = lastRewind else { throw NativeRPCError(code: "stale", message: "There is no rewind to undo any more.") }
        _ = try await rebuildDesk(reason: "rewind undone") { chat in
            try await chat.undoRewind()
            return "rewind undone: the chat is back as it was."
        }
        if let id = last.memory, DeckMemory.isReady { _ = try? await DeckMemory.store.undoRewind(id: id) }
        lastRewind = nil
    }
    /// Takes whole turns out of the visible chat by turn id (the builders' background tests) and rebuilds the desk without them.
    public func setAsideTurns(reason: String, where matches: @escaping @Sendable (String) -> Bool) async throws -> Int {
        let count = BackendHootRewindBox()
        _ = try await rebuildDesk(reason: reason) { chat in
            let gone = try await chat.setAsideTurns(reason: reason, where: matches)
            count.set(id: String(gone), text: "")
            return "\(gone) turn(s) taken out of the chat (\(reason)); kept in the chat file."
        }
        return Int(count.id) ?? 0
    }
    /// Takes whole exchanges out of the visible chat (a builder's test messages) and rebuilds the desk without them.
    public func setAsideExchanges(reason: String, where matches: @escaping @Sendable (String) -> Bool) async throws -> Int {
        let count = BackendHootRewindBox()
        _ = try await rebuildDesk(reason: reason) { chat in
            let gone = try await chat.setAsideExchanges(reason: reason, where: matches)
            count.set(id: String(gone), text: "")
            return "\(gone) exchange(s) taken out of the chat (\(reason)); kept in the chat file."
        }
        return Int(count.id) ?? 0
    }
    /// The records supplier this one runtime actually measures with (join
    /// evidence for request 8; never re-supplied separately).
    public nonisolated let installedRecords: any BackendCopilotSessionRecordsProviding
    public init(dependencies: BackendCopilotSessionDependencies) { deps = dependencies; installedRecords = dependencies.records; structuredChat = dependencies.chat }
    public static func legacyHome(storageDir: String) -> String { URL(fileURLWithPath: storageDir).appendingPathComponent("device-home").appendingPathComponent(homeKey).path }
    /// Register this at transcript-reader boot, even after the old jail is gone.
    public static func homeScope(userData: String, storageDir: String? = nil) -> NativeTranscriptHomeScope {
        let storage = storageDir ?? URL(fileURLWithPath: userData).appendingPathComponent("remote").path
        return .init(home: legacyHome(storageDir: storage), folder: BackendCopilotPaths(userData: userData).root)
    }
    /// Cheap ID-only answer for remote fanout list/attach/input/resize fences.
    /// It intentionally still names a dead ID until state is recomputed.
    public nonisolated func isCopilotSession(_ id: String) -> Bool { identity.contains(id) }
    private func resolve() async throws -> (paths: BackendCopilotPaths, folder: BackendCopilotFolderReport) {
        let folder = BackendCopilotFolder.report(stored: try await deps.chosenFolder(), userData: deps.userData, runningIn: live?.root)
        return (BackendCopilotPaths(userData: deps.userData, home: folder.home), folder)
    }
    public func layerPaths() async throws -> BackendCopilotPaths { try await resolve().paths }
    public func state() async throws -> BackendCopilotSessionState {
        let resolved = try await resolve()
        let paths = resolved.paths
        let report = BackendCopilotHome.report(paths)
        let observed = live
        let alive = if let observed { await deps.driver.isAlive(observed.sessionID) } else { false }
        if let observed, !alive, live?.sessionID == observed.sessionID {
            live = nil
            await deps.tools?.release(sessionID: observed.sessionID)
            // Found ended (a settings change, or an exit the chat already reported).
            let reason = await structuredChat?.takeEndReason() ?? "Hoot's session ended."
            if restartTask == nil, !closing {
                BackendCopilotHome.appendAction(paths, .init(action: "session.ended", detail: reason, sessionId: observed.sessionID))
                reporter?("Hoot stopped: " + reason)
            }
            scheduleRestart(after: reason)
        }
        let canonical = try await deps.records.paths(userData: deps.userData)
        let current = live
        let running = alive && current?.sessionID == observed?.sessionID && current != nil
        let status: BackendCopilotSessionStatus = running ? .running : problem != nil ? .stopped : starting != nil ? .starting : .stopped
        let folder = BackendCopilotFolderReport(home: resolved.folder.home, chosen: resolved.folder.chosen,
            isDefault: resolved.folder.isDefault, problem: resolved.folder.problem, runningIn: running ? current?.root : nil,
            restartNeeded: running && current?.root != resolved.folder.home)
        return .init(status: status, sessionId: running ? current?.sessionID : nil, paths: paths, folder: folder,
            home: Self.legacyHome(storageDir: deps.storageDir), startedAt: running ? current?.startedAt : nil, problem: problem,
            records: .init(kind: "seatbelt", enforced: running && current?.fenced == true, reason: fenceProblem, paths: canonical.list),
            profile: running ? current?.profile : nil, instructionsAreDefault: report.instructionsAreDefault, instructions: report.instructions,
            startupFiles: report.startupFiles, layerFiles: report.layerFiles)
    }
    public func ensure() async throws -> BackendCopilotSessionState {
        guard !closing else { throw NativeRPCError(code: "unavailable", message: "Hoot is shutting down.") }
        guard !changingConversation else { throw NativeRPCError(code: "busy", message: "Hoot is starting a new chat. Keep this message and send again.") }
        if let starting { return try await starting.value }
        // Install the latch BEFORE asking liveness. Another window may enter
        // while isAlive awaits; it must await this same attempt.
        let attempt = Task { try await self.startOrRead() }
        starting = attempt
        defer { starting = nil }
        return try await attempt.value
    }
    private func startOrRead() async throws -> BackendCopilotSessionState {
        if let existing = live, await deps.driver.isAlive(existing.sessionID) { return try await state() }
        if let existing = live { live = nil; await deps.tools?.release(sessionID: existing.sessionID) }
        return try await start()
    }
    private func start() async throws -> BackendCopilotSessionState {
        let resolved = try await resolve()
        let paths = resolved.paths
        let folder = resolved.folder
        problem = nil
        if let reason = folder.problem {
            BackendCopilotHome.appendAction(paths, .init(action: "folder.unusable", detail: "\(folder.chosen ?? "the chosen folder") — \(reason) Starting in \(paths.root) instead."))
        }
        let scaffold = BackendCopilotHome.scaffold(paths)
        if let error = scaffold.error { return try await refuse("Hoot's folder could not be created: \(error)") }
        if !scaffold.created.isEmpty { BackendCopilotHome.appendAction(paths, .init(action: "home.created", detail: scaffold.created.joined(separator: ", "))) }
        var prepared: BackendCopilotSessionTools?
        do {
            var selectedProvider = structuredChat?.provider.rawValue ?? "claude"
            guard try await deps.driver.hasClaude() else { return try await refuse("Hoot runs on \(CodingAICatalog.label(selectedProvider)), which is not installed on this Mac yet. Settings › Coding AI installs it with one click.") }
            var measured = await deps.records.measure(userData: deps.userData)
            fenceProblem = measured.reason
            let profile = try await deps.driver.resolveProfile(projectPath: paths.root)
            selectedProvider = structuredChat?.provider.rawValue ?? profile.provider
            prepared = try await deps.tools?.prepare()
            if let receiver = deps.driver as? any BackendHootChatToolRequirementsReceiving { await receiver.toolRequirements(prepared) }
            let canonical = try await deps.records.paths(userData: deps.userData)
            // Deck Memory: the card, open topics and board go at the top of the desk; a clean desk
            // (no CLI conversation to continue) also gets the last messages word for word.
            await wireDesk()
            var deskStart: BackendHootDeskStart?
            if let chat = structuredChat {
                let fresh = await chat.cliSessionID == nil
                // After a change of AI or account the first message carries the whole conversation so far
                // (BackendHootHandover), so the desk does not lay down the last messages a second time.
                let handingOver = await chat.handoverPending
                deskStart = await desk.start(fresh: fresh, recent: fresh && !handingOver ? await chat.recentMessages() : [])
            }
            let layer = BackendCopilotLayer.write(paths.layer, input: .init(root: paths.root, actionsLog: paths.actions,
                chosenFolder: !paths.ownFolder, userData: deps.userData, tools: prepared?.tools ?? [], toolsAttached: prepared != nil, records: canonical),
                desk: deskStart?.text ?? "")
            if layer.deskCut > 0 {
                BackendCopilotHome.appendAction(paths, .init(action: "desk.shortened", detail: "\(layer.deskCut) characters of memory did not fit in the start instructions and were left out; Hoot was told and can read the rest with its memory tools."))
            }
            if let left = deskStart?.leftOut, !left.isEmpty {
                BackendCopilotHome.appendAction(paths, .init(action: "desk.left-out", detail: "Not shown at the top of Hoot's desk because it did not fit (Hoot was told and can read it with its memory tools): " + left.joined(separator: "; ")))
            }
            if let over = deskStart?.cardOverBy, over > 0 {
                BackendCopilotHome.appendAction(paths, .init(action: "card.over", detail: "Hoot's card is over its size by \(over) characters. It was still given whole."))
            }
            guard let composed = layer.composed else {
                if let prepared { await deps.tools?.abandon(prepared) }
                return try await refuse("Hoot's instructions could not be prepared: \(layer.error ?? "unavailable")")
            }
            var input = BackendCreateSessionInput(cwd: paths.root, cols: deps.cols, rows: deps.rows, provider: selectedProvider)
            input.resume = false; input.profileId = profile.id
            let mcp = prepared.map { ["--mcp-config", $0.configPath, "--strict-mcp-config"] } ?? []
            let launchArguments = mcp + BackendCopilotLayer.args(composed: composed)
            let meta: BackendSessionMeta
            do { meta = try await deps.driver.start(input, fence: measured.fence, extraArguments: launchArguments) }
            catch let lost as BackendCopilotSessionFenceLost where measured.fence != nil {
                // Request 8 correction: the records fence fails open, visibly.
                measured = .init(fence: nil, reason: "This app’s own routines and action log could not be held against Hoot on this machine: " + lost.reason)
                fenceProblem = measured.reason
                meta = try await deps.driver.start(input, fence: nil, extraArguments: launchArguments)
            }
            guard meta.provider == selectedProvider else {
                try await deps.driver.stop(meta.id)
                if let prepared { await deps.tools?.abandon(prepared) }
                return try await refuse("Hoot started as a \(meta.provider) session rather than an agent.")
            }
            if let prepared {
                do { try await deps.tools?.bind(prepared, sessionID: meta.id) }
                catch {
                    try await deps.driver.stop(meta.id)
                    await deps.tools?.abandon(prepared)
                    return try await refuse(error.localizedDescription)
                }
            }
            live = .init(sessionID: meta.id, startedAt: meta.createdAt, root: paths.root, fenced: measured.fence != nil, profile: profile.identity)
            // The app's guard on its own records: when it could not be switched on, Hoot runs anyway but says so in its
            // header, and the guard is tried again every 30 s until it holds (then Hoot restarts with it, same chat).
            await guardStarted(held: measured.fence != nil, reason: measured.reason)
            let folderNote = paths.ownFolder ? "" : " (your folder — nothing of this app’s was written into it)"
            let recordsNote = if let fence = measured.fence { ", as \(profile.name), routines and this log held against it (\(fence.kind))" }
                else { ", as \(profile.name), routines and this log NOT held against it" + (measured.reason.map { " — " + $0 } ?? "") }
            let toolNote = prepared.map { ", with this app’s tools from \($0.configPath)" } ?? ", with none of this app’s tools — no deck-control server is running"
            BackendCopilotHome.appendAction(paths, .init(action: "session.started", detail: "cwd \(paths.root)\(folderNote)\(recordsNote)\(toolNote)", sessionId: meta.id))
            if !continuationChecked {
                continuationChecked = true
                Task { [weak self] in await self?.carryOnAfterRestart() }
            }
            return try await state()
        } catch {
            if let prepared { await deps.tools?.abandon(prepared) }
            return try await refuse(error.localizedDescription)
        }
    }
    /// L8 restart continuity for Hoot's own chat (Asad, 11 Oct: "everything for Hoot as well, so Hoot can continue after
    /// that"): the person's message whose answer the app's last end cut off is carried on once, in the same turn.
    /// Tasks are carried on by NativeCompositionRestartContinuation; this is the chat.
    func carryOnAfterRestart() async {
        guard let chat = structuredChat else { return }
        // "Pick up where you left off" is off: the cut-off answer stays as it is ("Send again" under it).
        guard await deps.picksUpAfterRestart() else { _ = await chat.takeContinuation(); return }
        guard let cut = await chat.takeContinuation() else { return }
        // A task turn the restart also continued may be running first: wait for Hoot to be free (a few tries at most).
        for attempt in 1...3 {
            await chat.waitUntilIdle()
            do {
                try await chat.continueCutOff(turn: cut.turn, text: cut.text)
                if let paths = try? await layerPaths() {
                    BackendCopilotHome.appendAction(paths, .init(action: "turn.continued", detail: "the app restarted while Hoot was answering; it carried on with that message by itself"))
                }
                return
            } catch let error as NativeRPCError where error.code == "busy" && attempt < 3 {
                continue
            } catch {
                reporter?("Hoot could not carry on its cut-off answer by itself: " + error.localizedDescription + " (Send again under the message continues it).")
                return
            }
        }
    }
    private func refuse(_ reason: String) async throws -> BackendCopilotSessionState {
        problem = reason
        BackendCopilotHome.appendAction(try await layerPaths(), .init(action: "session.refused", detail: reason))
        return try await state()
    }
    /// Graph shutdown: refuse new starts, await the one pending launch latch
    /// (its outcome is irrelevant), then stop the same desk Hoot. After this
    /// returns no desk assistant can still spawn from this runtime.
    public func quiesceAndStop() async throws -> BackendCopilotSessionState {
        closing = true
        // An answer cut by the app closing carries on by itself after the next start.
        await structuredChat?.markStop("quit")
        guardRetry?.cancel(); guardRetry = nil
        if let starting { _ = try? await starting.value }
        return try await stop()
    }
    public var isClosing: Bool { closing }
    public func stop() async throws -> BackendCopilotSessionState {
        if let starting {
            starting.cancel()
            _ = try? await starting.value
        }
        let paths = try await layerPaths()
        if let existing = live {
            try await deps.driver.stop(existing.sessionID)
            BackendCopilotHome.appendAction(paths, .init(action: "session.stopped", sessionId: existing.sessionID))
            if live?.sessionID == existing.sessionID { live = nil }
            await deps.tools?.release(sessionID: existing.sessionID)
        }
        return try await state()
    }
    public func readSignIn(now: Double = Date().timeIntervalSince1970 * 1000) async throws -> BackendCopilotSessionSignIn {
        let profile = try await deps.driver.resolveProfile(projectPath: try await layerPaths().root)
        if let cached = signInCache, cached.profileId == profile.id, now - cached.checkedAt < Self.signInTTLMilliseconds { return cached }
        let answer = try await deps.driver.signIn(profile: profile)
        let result = BackendCopilotSessionSignIn(state: answer.state == "unsupported" ? "unknown" : answer.state, account: answer.account, plan: answer.plan,
            profileId: profile.id, profileName: profile.name, checkedAt: now)
        signInCache = result; return result
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        if BackendHootChatChannels.invokes.contains(channel) {
            guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's structured chat is unavailable.") }
            switch channel {
            case "hoot:chat:read":
                guard arguments.count <= 4 else { throw NativeRPCError.invalidArguments("Expected cursor, limit and an optional seen-marker and conversation.") }
                if arguments.count > 2, let seen = try BackendHootChatChannels.integer(arguments[2], maximum: Int.max - 1) {
                    try await chat.setSeenSequence(seen, conversation: arguments.count > 3 ? (arguments[3].string ?? chat.conversationID) : chat.conversationID)
                }
                let cursor = try BackendHootChatChannels.integer(arguments.first ?? .null, maximum: Int.max - 1)
                let limit = try BackendHootChatChannels.integer(arguments.count > 1 ? arguments[1] : .null, maximum: 500) ?? 200
                return await chat.snapshot(after: cursor, limit: limit)
            case "hoot:chat:say":
                guard (1...4).contains(arguments.count) else { throw NativeRPCError.invalidArguments("Expected message, optional attachments and optional context.") }
                let text = try arguments[0].requireString("message")
                let attachments = arguments.count >= 2 ? try arguments[1].requireArray("attachments") : []
                return try await sayValidated(text, attachments: attachments, context: arguments.count >= 3 ? arguments[2] : .object([]), clientMessageID: arguments.count > 3 ? arguments[3].string : nil)
            case "hoot:chat:steer":
                guard (1...4).contains(arguments.count) else { throw NativeRPCError.invalidArguments("Expected message, optional attachments and optional context.") }
                return try await chat.steer(arguments[0].requireString("message"), attachments: arguments.count >= 2 ? arguments[1].requireArray("attachments") : [],
                    messageContext: arguments.count >= 3 ? arguments[2] : .object([]), clientMessageID: arguments.count > 3 ? arguments[3].string : nil)
            case "hoot:chat:options":
                guard !changingConversation else { throw NativeRPCError(code: "busy", message: "Hoot is starting a new chat.") }
                guard arguments.count <= 1, let options = deps.driver as? any BackendHOOTSIMConversationOptions else {
                    throw NativeRPCError(code: "unavailable", message: "Hoot's chat options are unavailable.")
                }
                return try await options.conversationOptions(arguments.first)
            case "hoot:chat:new":
                guard arguments.isEmpty, !changingConversation, !(await chat.isBusy), let options = deps.driver as? any BackendHOOTSIMConversationOptions else {
                    throw NativeRPCError(code: "busy", message: "Finish or stop Hoot before starting a new chat.")
                }
                changingConversation = true
                defer { changingConversation = false }
                let checkpoint = try await options.checkpointConversationOptions()
                do {
                    _ = try await stop()
                    try await options.resetConversationOptions()
                    return try await chat.newConversation()
                } catch {
                    try await options.restoreConversationOptions(checkpoint)
                    throw error
                }
            case "hoot:chat:stop":
                guard arguments.isEmpty else { throw NativeRPCError.invalidArguments("Expected no stop arguments.") }
                // The person's own Stop: that answer stays stopped (no "Send again", never carried on by itself).
                await chat.markStop("person")
                try await chat.interrupt(); return await chat.snapshot()
            case "hoot:chat:child-stop":
                guard arguments.count == 1 else { throw NativeRPCError.invalidArguments("Choose one task.") }
                return try await chat.stopChild(arguments[0].requireString("taskId", nonempty: true))
            case "hoot:chat:answer":
                guard (2...3).contains(arguments.count), let approved = arguments[1].bool else { throw NativeRPCError.invalidArguments("Expected request ID, approve/deny and optional structured answers.") }
                try await chat.answer(id: try arguments[0].requireString("requestId", nonempty: true), allowed: approved,
                    answers: arguments.count == 3 ? try arguments[2].requireObject("answers") : .object([]))
                return await chat.snapshot()
            default: throw NativeRPCError.invalidArguments("Unknown Hoot chat channel.")
            }
        }
        switch channel {
        case "hoot:ensure": return try await ensure().wireValue
        case "hoot:state": return try await state().wireValue
        case "hoot:files": return .array(try await state().startupFiles.map(\.wireValue))
        case "hoot:stop": return try await stop().wireValue
        case "hoot:signin": return try await readSignIn().wireValue
        case "hoot:read-instructions": return BackendCopilotHome.readInstructions(try await layerPaths()).wireValue
        case "hoot:read-contract": return BackendCopilotLayer.readFile(try await layerPaths().layer.contract).wireValue
        case "hoot:read-composed": return BackendCopilotLayer.readComposed(try await layerPaths().layer).wireValue
        case "hoot:read-folder-instructions": return BackendCopilotHome.readFolderInstructions(try await layerPaths()).wireValue
        case "hoot:write-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.writeInstructions(paths, text: arguments.first ?? .missing)
            if result.saved, let backup = result.backup {
                BackendCopilotHome.appendAction(paths, .init(action: "instructions.edited", detail: "you edited its instructions from Settings; the previous file is at \(backup)"))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        case "hoot:write-folder-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.writeFolderInstructions(paths, text: arguments.first ?? .missing)
            if result.saved {
                let detail = result.created ? "you created the folder’s own instructions from Settings at \(paths.root)" : result.backup.map { "you edited the folder’s own instructions from Settings; the previous file is at \($0)" } ?? "you saved the folder’s own instructions from Settings; nothing changed"
                BackendCopilotHome.appendAction(paths, .init(action: "folder-instructions.edited", detail: detail))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        case "hoot:reset-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.resetInstructions(paths)
            if result.error == nil {
                BackendCopilotHome.appendAction(paths, .init(action: "instructions.reset", detail: result.backup.map { "restored the instructions this build ships; the previous file is at \($0)" } ?? "restored the instructions this build ships"))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        default: throw NativeRPCError(code: "unavailable", message: "Unknown Hoot session channel.")
        }
    }
    /// Every source uses this one incoming message path. The source check runs
    /// after startup and again at the chat actor's actual enqueue boundary.
    public func sayValidated(_ text: String, attachments: [NativeRPCValue] = [], context: NativeRPCValue = .object([]), clientMessageID: String? = nil,
                             background: BackendHootBackgroundTurn? = nil,
                             validateSource: (@Sendable () async throws -> Void)? = nil) async throws -> NativeRPCValue {
        _ = try BackendHOOTSIMChatContext(wire: context)
        guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's chat is unavailable.") }
        let clientMessageID = BackendChatDeliveryQueue.identity(clientMessageID)
        await deps.driver.prepareForSend()
        if let observed = live, !(await deps.driver.isAlive(observed.sessionID)) {
            // A silent relaunch for a changed choice: no "stopped"/"restarted" report, no backoff.
            live = nil; await deps.tools?.release(sessionID: observed.sessionID); _ = await chat.takeEndReason()
        }
        let state = try await ensure()
        guard state.status == .running else { throw NativeRPCError(code: "unavailable", message: state.problem ?? "Hoot could not start.") }
        let accepted = try await chat.say(text, attachments: attachments, messageContext: context, background: background, validateSource: validateSource, clientMessageID: clientMessageID)
        // An @ mention of an agent or a seat wakes it (L8's delivery, the same path Tasks uses). Only for a
        // message the person wrote; the receipt goes under that message.
        if background == nil, (context["source"]["kind"].string ?? "").isEmpty, let delivery = BackendHootMentionDelivery.shared,
           text.contains("@") || !(context["mentions"].elements ?? []).isEmpty {
            let turn = await chat.activeTurnID
            Task {
                let receipts = await delivery.deliver(text: text, context: context, by: "me")
                if !receipts.isEmpty { await chat.noteReceipts(receipts.map(\.wireValue), turn: turn) }
            }
        }
        return accepted
    }
    public func register(registry: NativeChannelRegistry, ownerID: String) async throws {
        for channel in Self.channels {
            try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                guard context.caller == .nativeApp || context.caller == .internalEngine else {
                    throw NativeRPCError(code: "access-denied", message: "Hoot's desk session is available on this computer only.")
                }
                return try await invoke(channel, arguments: args)
            }
        }
    }
}

/// Carries a rewind's answer out of the desk rebuild.
final class BackendHootRewindBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = (id: "", text: "")
    func set(id: String, text: String) { lock.withLock { value = (id, text) } }
    var id: String { lock.withLock { value.id } }
    var text: String { lock.withLock { value.text } }
}
