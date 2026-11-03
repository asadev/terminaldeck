import Foundation
import TerminalDeckNativeCore

/// Chat sessions. Asad, 13 Oct: "give a switch on each new session if they want to use chat vs terminal; whatever
/// they choose stays for next time", and "instead of building new screens give same as Hoot, just use same".
///
/// A chat session is an ordinary session of its project (its row, name, project, account, tools, saved launch and
/// restore all come from the same launcher a terminal uses), but its AI runs in the structured app mode Hoot's chat
/// uses (Claude `--print` stream-json, Codex `app-server`, Gemini `--acp`), through Hoot's own conversation engine
/// (BackendHootChatStore: the process, the decoder, approvals, history). Its window is Hoot's chat screen.
///
/// - A capable session helper owns its AI, stream and permission waiters across app restarts.
///   Older helpers keep the in-app path until a later install.
/// - The conversation on disk is the CLI's own, the same as a terminal's, so it can be opened in either mode later.
/// - It is reached as `session:chat:*` (the window) and through the session manager (list, rename, close, a tool's
///   sessions_send, sessions_screen) like any session.
public actor BackendSessionChats {
    private var hosted: BackendHOSTChatClient?
    public func useHost(_ client: BackendHOSTClient) async throws {
        guard client.hello.chatService == 1 else { return }
        hosted?.detach()
        let remote = BackendHOSTChatClient(client: client)
        hosted = remote
        try await remote.attach { [weak self] id, snapshot in await self?.hostChanged(id, snapshot) }
    }
    public func adoptHostedSession(_ meta: BackendSessionMeta) async throws {
        guard meta.chat == true, let hosted else { throw BackendHOSTFailure.unavailable }
        try await hosted.refreshInventory()
    }
    private func hostChanged(_ id: String, _ snapshot: NativeRPCValue) async {
        await publish(id, snapshot)
        if let job = hosted?.conversation(id) {
            var cursor = diaryCursors[id] ?? 0
            while let page = try? await hosted?.call("read", id: id, fields: [.init("cursor", .number(Double(cursor))), .init("limit", .number(500))]) {
                do { try await diary(job, page) } catch { break }
                let next = Int(page["cursor"].number ?? 0)
                guard next > cursor else { break }
                diaryCursors[id] = next; cursor = next
                if page["hasMore"].bool != true { break }
            }
            if job.isFinished { await notifyHostedFinished(id, job: job); retireOnce(id) }
        }
    }
    private func notifyHostedFinished(_ id: String, job: BackendTeamChatRecord) async {
        guard !notifiedJobs.contains(id), job.job.taskID == nil || activeTaskJobs.contains(id) else { return }
        notifiedJobs.insert(id)
        let observed = Turn(state: job.failed ? .failed(reason: job.result ?? "Failed") : .done(answer: job.result ?? ""), turnID: job.turnID, cursor: job.cursor ?? 0)
        await jobTurn?(id, observed)
        // Not jobClosed: the helper already keeps the finished job listed with its history (finishChat). Closing it here
        // removed the row, and the helper's reopened history reached this app only at its next start (17 Oct).
    }
    public static let channels = ["hoot:chat:provider", "session:chat:terminal", "session:chat:diffs", "session:chat:children", "session:chat:provider", "session:chat:read", "session:chat:say", "session:chat:steer", "session:chat:queued", "session:chat:stop", "session:chat:child-stop", "session:chat:answer", "session:chat:ensure", "session:chat:turn", "session:chat:options", "session:chat:draft", "session:chat:rewind", "session:chat:undo-rewind", "session:chat:handoff", "session:chat:fork"]
    public static let event = "session:chat:changed"

    /// How its AI starts: the session's own resolved launch (program, arguments, environment, folder).
    struct Recipe: Sendable {
        let provider: HootChatProvider
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let cwd: String
        let conversation: String?
        var sessionTools = false
        var preparedChat = false
        var setup: BackendHootChatSetup?
        /// A confined launch's own words before the CLI (`-p <profile> <cli>` for `sandbox-exec`), kept apart from the
        /// CLI's `arguments` so the chat mode's flags go to the CLI, never to the launcher. Empty for a plain launch.
        var wrapper: [String] = []
    }
    /// What the manager reads without waiting (a session's screen, its process).
    final class Mirror: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "", pid: Int32?
        func set(text: String) { lock.withLock { self.text = text } }
        func set(pid: Int32?) { lock.withLock { self.pid = pid } }
        var currentText: String { lock.withLock { text } }
        var currentPID: Int32? { lock.withLock { pid } }
    }
    private final class Live: @unchecked Sendable {
        let store: BackendHootChatStore
        let recipe: Recipe
        let mirror: Mirror
        /// The tab it belongs to (its saved launch's key): its conversation folder.
        let key: String
        let id: String
        var watcher: Task<Void, Never>?
        var status: BackendSessionStatus = .idle
        var conversation: String?
        var starting: Task<Void, Error>?
        /// The person's picks under the box (CLI values: "permission", "model", "effort"), over the launch's own.
        var choices: [String: String] = [:]
        var draft = ""
        var draftRevision = 0
        /// A model or effort pick waits for the next message: the AI starts again with it, in the same conversation.
        var ready = false
        var relaunch = false
        /// A 1M pick under the box ("opus[1m]") waits for its first answer: whether this account has the 1M window
        /// cannot be read beforehand, so a failed first answer puts the chat back on the same model without it.
        var millionTrial: String?
        var millionTrialTurn: String?
        /// A plain sentence shown in the chat until the person's next message (the 1M fallback).
        var notice: String?
        var externalRuntime: BackendCopilotSessionRuntime?
        var steering = false
        var queuedCount = 0
        var personStopped = false
        var sideConversation: BackendChatSideConversation?
        var sideOpeningTask: Task<BackendChatSideConversation, Error>?
        var sideCleanupTask: Task<NativeRPCValue, Never>?
        var openingSide = false
        var sideGeneration = UUID()
        var featuresClosed = false
        /// A lost start/stop reply leaves provider audio uncertain until a stop is acknowledged.
        var voiceActiveOrUncertain = false
        var voiceConversation: String?
        var voiceStartTask: Task<NativeRPCValue, Error>?
        var voiceStopTask: Task<NativeRPCValue, Never>?
        var voiceCleanupError: String?
        init(store: BackendHootChatStore, recipe: Recipe, mirror: Mirror, key: String, id: String) {
            self.store = store; self.recipe = recipe; self.mirror = mirror; self.key = key; self.id = id
        }
    }

    private let manager: BackendPTYManager
    private let directory: URL
    private let publishOut: @Sendable (String, NativeRPCValue) async -> Void
    /// 28 Oct (CPU, Asad: every terminal slow): what each chat last said about its unread messages, so the team-chat
    /// list does not read every chat again (through the session helper, which loads a finished chat's whole history
    /// from disk) each time it is drawn (`BackendChatUnreadCache`).
    private var unread = BackendChatUnreadCache()
    private let noteConversation: @Sendable (String, String) async -> Void
    private var live: [String: Live] = [:]
    private var diaryCursors: [String: Int] = [:]
    private var jobs: [String: BackendTeamChatRecord] = [:]
    private var historyActions: [String: BackendHootChatStore] = [:]
    private var historyOrder: [String] = []
    static let historyCacheLimit = 8
    private var changingHistory: Set<String> = []
    private var finishing: [String: Task<Void, Error>] = [:]
    private var jobClosed: (@Sendable (String) async -> Void)?
    private var activeTaskJobs: Set<String> = []
    private var notifiedJobs: Set<String> = []
    private var jobTurn: (@Sendable (String, Turn) async -> Void)?
    /// 22 Oct (Asad, "remove this 128 limit"): a finished team job leaves the session list once (the app closes it
    /// unless it is on screen); its record and history stay and `openJobHistory` brings it back on demand.
    private var retireFinished: (@Sendable (String) async throws -> Void)?
    private var retiredJobs: Set<String> = []
    /// 22 Oct (Reviewer, finding 5): finished jobs are closed one at a time, never one background close each
    /// (about 95 at a first start or after a helper restart against the helper's 16 connections).
    private var retireQueue: [String] = []
    private var retireDraining = false
    private let diary: @Sendable (BackendTeamChatRecord, NativeRPCValue) async throws -> Void
    private let usageReport: @Sendable (String) async throws -> NativeRPCValue
    private let processStarted: @Sendable (String, Int32) async throws -> Void
    private let modelCatalogue: @Sendable () async -> NativeRPCValue

    /// `directory`: where each tab's conversation is kept (`<data>/session-chats/<tab>/`). `publish`:
    /// `session:chat:changed`. `noteConversation`: the CLI's own conversation id, for the saved launch.
    public init(manager: BackendPTYManager, directory: URL, publish: @escaping @Sendable (String, NativeRPCValue) async -> Void,
                noteConversation: @escaping @Sendable (String, String) async -> Void = { _, _ in },
                diary: @escaping @Sendable (BackendTeamChatRecord, NativeRPCValue) async throws -> Void = { _, _ in },
                usageReport: @escaping @Sendable (String) async throws -> NativeRPCValue = { _ in .null },
                processStarted: @escaping @Sendable (String, Int32) async throws -> Void = { _, _ in },
                modelCatalogue: @escaping @Sendable () async -> NativeRPCValue = { await BackendHootModelSource.liveCatalogue() }) {
        self.manager = manager; self.directory = directory; self.publishOut = publish; self.noteConversation = noteConversation; self.diary = diary
        self.usageReport = usageReport; self.modelCatalogue = modelCatalogue; self.processStarted = processStarted
    }

    // MARK: Starting

    /// The launcher's chat dispatch: the session's own resolved launch, started in its chat mode.
    public func launch(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec, hostLaunch: BackendHOSTProtocol.Launch? = nil) async throws -> BackendSessionMeta {
        guard let provider = HootChatProvider(rawValue: spawn.provider) else {
            throw BackendSessionFailure.unsupported("Only Claude Code, Codex and Gemini can run as a chat.")
        }
        let id = hostLaunch?.id ?? UUID().uuidString.lowercased(), cwd = spawn.hostCwd ?? input.cwd, key = input.teamJob == nil ? (spawn.tabKey ?? id) : id
        let prepared = try manager.chatLaunch(id: id, spawn: spawn, cwd: cwd)
        // A phone's chat runs inside its device's folder boundary: `sandbox-exec -p <profile> <cli> <args…>`. The chat
        // mode's flags belong to the CLI (27 Oct, live: they went before `-p`, so sandbox-exec printed its usage and
        // quit, and every Claude and Codex chat started from the phone died "during its handshake").
        let cli = try Self.confinedCLI(executable: prepared.executable, arguments: spawn.args)
        // One conversation, one place: this tab's chat that is still live (an account or AI switch, a reopen) ends first.
        for other in live.filter({ $0.value.key == key }).map(\.key) { await close(other) }
        let store = try await Self.openStore(folder: Self.tabFolder(directory, key: key), provider: provider, retainAllHistory: input.teamJob != nil || hostLaunch != nil)
        // Another account (or folder) than the conversation's last one: its next message carries the conversation.
        try await store.requireContext((spawn.profile?.id ?? "system") + ":" + URL(fileURLWithPath: cwd).standardizedFileURL.path)
        if provider != .claude { try await store.seedSessionConversation(spawn.agentSessionId) }
        // Saved agent settings own the mode's flags and clear it from the input (BackendAGSLaunchBinding): the mode they
        // launched with is still this chat's approval policy, so Ask first is never silently run as bypass (2 Nov, web v1).
        let chosenPermission = input.permissionMode ?? BackendAGSLaunchScope.prepared?.settings.permissionMode
        await store.setPermissionPolicy(chosenPermission ?? Self.permissionPolicy(provider: provider, arguments: cli.arguments))
        var recipe = Recipe(provider: provider, executable: prepared.executable, arguments: cli.arguments,
                            environment: prepared.environment, cwd: cwd, conversation: spawn.agentSessionId, sessionTools: input.teamJob != nil)
        recipe.preparedChat = hostLaunch?.preparedChat == true; recipe.setup = hostLaunch?.chatSetup; recipe.wrapper = cli.wrapper
        let item = Live(store: store, recipe: recipe, mirror: Mirror(), key: key, id: id)
        // An explicit New chat mode must override inherited launch flags in both
        // the actual CLI arguments and the composer's reported choice.
        if let permission = chosenPermission { item.choices["permission"] = permission }
        var meta = hostLaunch?.metadata ?? BackendSessionMeta(id: id, input: input, spawn: spawn)
        meta.chat = true
        if let job = input.teamJob {
            meta.title = job.sessionTitle
            jobs[id] = BackendTeamChatRecord(session: meta, job: job, key: key)
            do { try saveJob(id) } catch { jobs[id] = nil; await store.stop(); throw error }
        }
        let mirror = item.mirror
        do {
            try manager.registerChat(meta, controls: .init(
                send: { [weak self] text in
                    // #442: a key the composer refuses is refused here, so the phone is not told it was typed.
                    if let refused = Self.keyRefusal(text) { throw refused }
                    Task { _ = try? await self?.type(id, data: text) }
                },
                stop: { [weak self] in Task { await self?.close(id) } },
                text: { mirror.currentText }, pid: { mirror.currentPID }))
        } catch { await store.stop(); throw error }
        live[id] = item
        watch(id, item)
        do { try await start(item, again: false); item.ready = true }
        catch {
            if input.teamJob != nil { try? await finishJob(id, result: error.localizedDescription, failed: true) }
            else { await close(id) }
            throw error
        }
        return meta
    }

    public func prepareGeminiHandover(key: String, pieces: [DeckMemoryFlowPiece], conversation: String?) async throws {
        let store = try await Self.openStore(folder: Self.tabFolder(directory, key: key), provider: .gemini)
        try await store.seedTerminalHistory(pieces, conversation: conversation)
    }

    private func start(_ item: Live, again: Bool) async throws {
        let cli = await item.store.cliSessionID, carrying = await item.store.handoverPending
        var arguments = Self.withChoices(item.recipe.arguments, provider: item.recipe.provider, choices: item.choices)
        if let fast = item.choices["fastMode"].map({ $0 == "true" }) {
            arguments = try BackendSessionChatComposer.applyingFastMode(arguments, on: fast,
                directory: Self.tabFolder(directory, key: item.key))
        }
        let recipe = Recipe(provider: item.recipe.provider, executable: item.recipe.executable,
                            arguments: arguments,
                            environment: item.recipe.environment, cwd: item.recipe.cwd, conversation: item.recipe.conversation, sessionTools: item.recipe.sessionTools)
        if item.recipe.preparedChat {
            guard !again else { throw BackendSessionFailure.unsupported("Restart this task as a new job to change its launch settings.") }
            try await item.store.attach(.init(command: item.recipe.executable, arguments: item.recipe.wrapper + item.recipe.arguments, cwd: item.recipe.cwd,
                environment: item.recipe.environment, setup: item.recipe.setup))
            if let pid = await item.store.processPID { try await processStarted(item.id, pid); item.mirror.set(pid: pid) }
            try await item.store.initialize()
            return
        }
        let plan = try Self.plan(recipe, cliSession: cli, again: again, carrying: carrying)
        try await item.store.attach(.init(command: item.recipe.executable, arguments: item.recipe.wrapper + plan.arguments, cwd: item.recipe.cwd,
                                          environment: item.recipe.environment, setup: plan.setup))
        item.mirror.set(pid: await item.store.processPID)
        if let pid = await item.store.processPID {
            do { try await processStarted(item.id, pid) } catch { await item.store.stop(); item.mirror.set(pid: nil); throw error }
        }
        do { try await item.store.initialize() } catch { await item.store.stop(); throw error }
    }

    /// Its AI is running (started again, in the same conversation, after it ended or the app restarted it).
    public func ensure(_ id: String) async throws {
        if hosted?.owns(id) == true { _ = try await hosted!.call("ensure", id: id); return }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        guard !item.featuresClosed else { throw BackendSessionFailure.missingSession }
        if let runtime = item.externalRuntime { _ = try await runtime.ensure(); return }
        if await item.store.alive { return }
        if let starting = item.starting { try await starting.value; return }
        let task = Task { try await self.start(item, again: true) }
        item.starting = task
        defer { item.starting = nil }
        try await task.value
    }

    // MARK: The window's calls

    /// Separate from generic provider RPCs: approvals arrive only from the authenticated app
    /// terminal door after an actual native action or the app's owner/act consent gate.
    public func ownedTerminalFeature(_ id: String, operation: String, arguments: NativeRPCValue,
                                     approval: BackendChatOwnedTerminals.AppApproval?) async throws -> NativeRPCValue {
        guard BackendChatOwnedTerminals.operations.contains(operation), arguments.fields != nil,
              try arguments.encodedJSON().count <= 131_072 else { throw NativeRPCError.invalidArguments("Choose a bounded Chat-owned terminal operation.") }
        if let hosted, !hosted.owns(id), live[id] == nil { try await hosted.refreshInventory() }
        if let hosted, hosted.owns(id) {
            return try await hosted.call("terminal", id: id, fields: [.init("operation", .string(operation)),
                .init("arguments", arguments), .init("appApproval", approval?.wireValue ?? .null)])
        }
        try requireOpenJob(id)
        guard let item = live[id], !item.featuresClosed else { throw BackendSessionFailure.missingSession }
        return try await item.store.ownedTerminalFeature(sessionID: id, operation: operation, arguments: arguments, approval: approval)
    }

    /// One typed service door shared by the helper, app controls and MCP.
    public func providerFeature(_ id: String, operation: String, arguments: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        try BackendChatProviderFeaturePolicy.validate(operation, arguments: arguments)
        if let hosted, !hosted.owns(id), live[id] == nil { try await hosted.refreshInventory() }
        if let hosted, hosted.owns(id) {
            if BackendChatProviderFeaturePolicy.sessionFeatureOperations.contains(operation), hosted.sessionFeatureLevel < 1 {
                throw NativeRPCError(code: "helper-upgrade-required", message: "This running helper predates file checkpoints, background tasks, forks and location. The helper and its sessions were kept running; install the new helper at the next agreed restart.")
            }
            return try await hosted.call("provider", id: id, fields: [.init("operation", .string(operation)), .init("arguments", arguments)])
        }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        if jobs[id] != nil, ["goals/set", "goals/edit", "goals/resume"].contains(operation) {
            throw NativeRPCError(code: "unsupported-job-feature", message: "One-shot jobs cannot start or reactivate autonomous provider goals. Use an ordinary Chat; pause, clear and read remain available here.")
        }
        if operation == "capabilities" {
            return BackendChatProviderControls.capabilities(provider: item.recipe.provider)
                .setting("featureOperations", .array(BackendChatProviderFeaturePolicy.operations.map(NativeRPCValue.string)))
        }
        if operation == "voice/events" { return await item.store.providerEvents(after: Int(arguments["cursor"].number ?? 0)) }
        if operation == "voice/stop", item.recipe.provider == .codex {
            let result = await stopTransientVoice(id)
            guard result["stopped"].bool == true else {
                throw NativeRPCError(code: "voice-stop-unconfirmed", message: result["sessions"].elements?.first?["error"].string ?? "The provider has not confirmed that realtime voice stopped.")
            }
            return result
        }
        if operation == "side/close" {
            return await closeSideConversation(item)
        }
        if operation == "side/read" {
            guard let side = item.sideConversation else { throw NativeRPCError.invalidArguments("Open a side conversation first.") }
            return await side.read(after: arguments["cursor"].number.map(Int.init), limit: Int(arguments["limit"].number ?? 100))
        }
        if item.recipe.provider == .claude, operation.hasPrefix("catalogue/") {
            let scope = try BackendChatProviderCatalogue.claudeScope(environment: item.recipe.environment, cwd: item.recipe.cwd)
            return try await BackendChatProviderCatalogue.claude(operation: operation, arguments: arguments, cwd: item.recipe.cwd, scope: scope)
        }
        let request: @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue = { method, params in
            try await item.store.providerRequest(method: method, params: params)
        }
        if operation.hasPrefix("terminals/"), item.recipe.provider != .codex || ["terminals/capabilities", "terminals/create", "terminals/write", "terminals/resize", "terminals/foreground"].contains(operation) {
            return try await BackendChatProviderTerminals.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider, conversation: await item.store.cliSessionID, cwd: item.recipe.cwd, request: request)
        }
        if operation == "children/list" {
            let snapshot = await item.store.snapshot()
            return try await BackendChatProviderChildren.invoke(operation: operation, args: arguments, provider: item.recipe.provider,
                conversation: snapshot["providerConversationId"].string, cwd: item.recipe.cwd,
                ownedTasks: snapshot["children"].elements ?? [], request: request)
        }
        if operation == "policy/read" {
            return try await BackendChatProviderPolicy.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider,
                conversation: await item.store.cliSessionID, cwd: item.recipe.cwd, receipt: await item.store.effectiveProviderPolicy,
                busy: await item.store.isBusy, request: request)
        }
        if operation == "voice/start", item.recipe.provider == .codex {
            guard !item.featuresClosed, !item.voiceActiveOrUncertain, item.voiceStartTask == nil, item.voiceStopTask == nil else {
                throw NativeRPCError(code: "voice-state-uncertain", message: "Stop the existing provider voice session before starting another one.")
            }
            // Own the whole startup barrier, including lazy CLI initialization. A frontend may
            // disappear while ensure is suspended, before realtime/start has been sent.
            let starting = Task {
                try await ensure(id)
                guard live[id] === item, !item.featuresClosed, let conversation = await item.store.cliSessionID, !conversation.isEmpty else {
                    throw NativeRPCError(code: "unavailable", message: "The provider conversation is not ready for voice.")
                }
                item.voiceActiveOrUncertain = true; item.voiceConversation = conversation; item.voiceCleanupError = nil
                return try await BackendChatProviderControls.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider,
                    conversation: conversation, cwd: item.recipe.cwd, request: { method, params in try await item.store.providerRequest(method: method, params: params) })
            }
            item.voiceStartTask = starting
            defer { item.voiceStartTask = nil }
            return try await starting.value
        }
        // A passive inventory/policy request must not resume a persisted active goal. Normal
        // Chat sends and the explicit voice startup keep their existing reconnect paths.
        guard await item.store.alive else {
            throw NativeRPCError(code: "provider-not-running", message: "This provider is stopped. Reconnect the Chat explicitly before using this live provider feature; it was not restarted for inspection.")
        }
        guard live[id] === item, !item.featuresClosed else { throw BackendSessionFailure.missingSession }
        let conversation = await item.store.cliSessionID
        if operation == "policy/change" {
            let snapshot = await item.store.snapshot()
            let writers = (snapshot["children"].elements ?? []).contains(where: ChatChildTasks.running)
            let busy = snapshot["busy"].bool == true || !(snapshot["pending"].elements ?? []).isEmpty || writers || item.voiceActiveOrUncertain || item.voiceStartTask != nil || item.voiceStopTask != nil
            return try await BackendChatProviderPolicy.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider,
                conversation: conversation, cwd: item.recipe.cwd, receipt: await item.store.effectiveProviderPolicy, busy: busy, request: request)
        }
        if operation == "side/open" {
            guard item.sideConversation == nil, item.sideOpeningTask == nil, !item.openingSide else { throw NativeRPCError.invalidArguments("A side conversation is already open.") }
            // Claim the opening before the first await: a second side/open arriving while the launch is
            // being read would otherwise pass the guard and start a second, leaked Codex process.
            item.openingSide = true
            let generation = item.sideGeneration
            guard let conversation, let launch = await item.store.providerLaunch else {
                if item.sideGeneration == generation { item.openingSide = false }
                throw NativeRPCError(code: "unavailable", message: "The AI has no confirmed conversation to branch.")
            }
            let provider = item.recipe.provider
            let opening = Task { try await BackendChatSideConversation.open(provider: provider, conversation: conversation, launch: launch) }
            item.sideOpeningTask = opening
            defer {
                if item.sideGeneration == generation { item.sideOpeningTask = nil; item.openingSide = false }
            }
            let side = try await withTaskCancellationHandler(operation: { try await opening.value }, onCancel: { opening.cancel() })
            guard live[id] === item, item.sideGeneration == generation, !item.featuresClosed else { _ = await side.close(); throw BackendSessionFailure.missingSession }
            item.sideConversation = side
            return await side.read(after: nil, limit: 100)
        }
        if operation == "side/send" {
            guard let side = item.sideConversation else { throw NativeRPCError.invalidArguments("Open a side conversation first.") }
            return try await side.send(text: arguments["text"].requireString("question", nonempty: true))
        }
        if operation.hasPrefix("children/") {
            let owned = await item.store.snapshot()["children"].elements ?? []
            return try await BackendChatProviderChildren.invoke(operation: operation, args: arguments, provider: item.recipe.provider, conversation: conversation, cwd: item.recipe.cwd, ownedTasks: owned, request: request)
        }
        if operation.hasPrefix("terminals/") {
            return try await BackendChatProviderTerminals.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider, conversation: conversation, cwd: item.recipe.cwd, request: request)
        }
        if operation.hasPrefix("mcp/") {
            return try await BackendChatProviderMCP.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider, conversation: conversation, cwd: item.recipe.cwd, request: request)
        }
        if operation.hasPrefix("checkpoints/") {
            let rows = await item.store.fileCheckpointRows(), quiet = await item.store.isQuietForFeatures
            let result = try await BackendChatFileCheckpoints.invoke(operation: operation, args: arguments, provider: item.recipe.provider,
                checkpoints: rows, quiet: quiet, quietNow: { await item.store.isQuietForFeatures }, request: request)
            if operation == "checkpoints/restore", result["restored"].bool == true {
                let count = result["files"].elements?.count ?? 0
                await item.store.recordFileRestore("Restored \(count) file\(count == 1 ? "" : "s") to how they were before an earlier message. The conversation was not changed.")
            }
            return result
        }
        if operation.hasPrefix("background/") {
            let owned = await item.store.snapshot()["children"].elements ?? []
            return try await BackendChatBackground.invoke(operation: operation, args: arguments, provider: item.recipe.provider, ownedTasks: owned, request: request)
        }
        if operation == "fork/create" || operation == "location/read" {
            let turns = await item.store.forkTurnIDs(), quiet = await item.store.isQuietForFeatures
            var isolatedFork: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)?
            if let launch = await item.store.providerLaunch {
                isolatedFork = { @Sendable (params: NativeRPCValue) async throws -> NativeRPCValue in
                    try await BackendChatForkProcess.fork(launch: launch, params: params)
                }
            }
            return try await BackendChatFork.invoke(operation: operation, args: arguments, provider: item.recipe.provider, conversation: conversation,
                cwd: item.recipe.cwd, knownTurns: turns, quiet: quiet, request: request, isolatedFork: isolatedFork)
        }
        if operation.hasPrefix("catalogue/") || operation.hasPrefix("skills/") || operation.hasPrefix("instructions/") {
            let applied = await item.store.providerInstructionReceipt
            return try await BackendChatProviderCatalogue.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider, conversation: conversation, cwd: item.recipe.cwd, appliedInstructions: applied, request: request)
        }
        if operation.hasPrefix("review/") {
            return try await item.store.startProviderReview(arguments: arguments, cwd: item.recipe.cwd)
        }
        return try await BackendChatProviderControls.invoke(operation: operation, arguments: arguments, provider: item.recipe.provider, conversation: conversation, cwd: item.recipe.cwd, request: request)
    }

    /// Audio belongs to the attached frontend. Losing it stops only realtime transport, while
    /// the helper keeps the conversation and CLI alive. This never initializes a stopped AI.
    public func stopTransientVoice(_ id: String? = nil) async -> NativeRPCValue {
        if let hosted {
            return await hosted.stopTransientVoice(id)
        }
        let selected = live.values.filter { id == nil || $0.id == id }
        var outcomes: [NativeRPCValue] = []
        for item in selected {
            if let stopping = item.voiceStopTask { outcomes.append(await stopping.value); continue }
            guard item.voiceActiveOrUncertain || item.voiceStartTask != nil else { continue }
            let starting = item.voiceStartTask
            let stopping = Task { () -> NativeRPCValue in
                // Sending Stop before a pending Start is accepted could leave a late transport open.
                if let starting { _ = await starting.result }
                guard item.voiceActiveOrUncertain else {
                    return .object([.init("id", .string(item.id)), .init("stopped", .bool(true))])
                }
                do {
                    guard let conversation = item.voiceConversation, !conversation.isEmpty else {
                        throw NativeRPCError(code: "voice-state-uncertain", message: "The provider voice conversation is unknown; its stop could not be confirmed.")
                    }
                    _ = try await item.store.providerRequest(method: "thread/realtime/stop", params: .object([.init("threadId", .string(conversation))]))
                    item.voiceActiveOrUncertain = false; item.voiceConversation = nil; item.voiceCleanupError = nil
                    return .object([.init("id", .string(item.id)), .init("stopped", .bool(true))])
                } catch {
                    item.voiceCleanupError = error.localizedDescription
                    return .object([.init("id", .string(item.id)), .init("stopped", .bool(false)),
                        .init("activeOrUncertain", .bool(true)), .init("error", .string(error.localizedDescription))])
                }
            }
            item.voiceStopTask = stopping
            let result = await stopping.value
            item.voiceStopTask = nil
            outcomes.append(result)
            await publish(item.id, draftSnapshot(await item.store.snapshot(), item))
        }
        return .object([.init("stopped", .bool(outcomes.allSatisfy { $0["stopped"].bool == true })),
            .init("sessions", .array(outcomes))])
    }

    /// A side factory owns a child before it can return a conversation. Keep that task until
    /// cancellation has closed and reaped its child, before releasing the parent's leases.
    /// Concurrent close/quit calls await the same barrier and cannot reopen during cleanup.
    private func closeSideConversation(_ item: Live) async -> NativeRPCValue {
        if let cleanup = item.sideCleanupTask { return await cleanup.value }
        item.sideGeneration = UUID(); item.openingSide = true
        let opening = item.sideOpeningTask, side = item.sideConversation
        let cleanup = Task { () -> NativeRPCValue in
            opening?.cancel()
            var result = NativeRPCValue.object([.init("closed", .bool(true))])
            if let opening, case .success(let opened) = await opening.result { result = await opened.close() }
            if let side { result = await side.close() }
            return result
        }
        item.sideCleanupTask = cleanup
        let result = await cleanup.value
        item.sideOpeningTask = nil; item.sideConversation = nil
        item.sideCleanupTask = nil; item.openingSide = false
        return result
    }

    /// Every change of a chat goes out here; the unread the list shows follows it (`BackendChatUnreadCache`).
    private func publish(_ id: String, _ snapshot: NativeRPCValue) async {
        unread.noteChange(id, snapshot)
        await publishOut(id, snapshot)
    }
    /// What the team-chat list shows for one chat's unread messages: remembered from its last read or change, read
    /// (once) only when nothing is known since it last changed.
    public func unreadEntry(_ id: String) async throws -> BackendChatUnreadCache.Entry {
        if let known = unread.entry(id) { return known }
        let snapshot = try await read(id, cursor: nil, limit: 1)
        return .init(unread: snapshot["unread"], conversationID: snapshot["conversationId"])
    }
    public func read(_ id: String, cursor: Int?, limit: Int, seen: Int? = nil, conversation: String? = nil) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true {
            let value = try await hosted!.call("read", id: id, fields: [.init("cursor", cursor.map { .number(Double($0)) } ?? .null), .init("limit", .number(Double(limit))), .init("seen", seen.map { .number(Double($0)) } ?? .null), .init("conversation", conversation.map(NativeRPCValue.string) ?? .null)])
            unread.noteRead(id, value)
            return value
        }
        // 18 Oct (#424): a finished job's history is parsed once and kept in the small cache below.
        let store = try actionStore(id)
        if let seen { try await store.setSeenSequence(seen, conversation: conversation ?? store.conversationID) }
        let adopted = jobs[id]?.historyPath != nil
        var snapshot = Self.visibleJobSnapshot(await store.snapshot(after: cursor, limit: limit), adopted: adopted)
        if adopted { snapshot = snapshot.setting("unread", await store.unreadSummary(showBackground: true)) }
        if let job = jobs[id] {
            snapshot = snapshot.setting("job", job.wire).setting("readOnly", .bool(job.isFinished))
            if job.isFinished { snapshot = snapshot.setting("alive", .bool(false)).setting("busy", .bool(false)).setting("pending", .array([])) }
        }
        if let item = live[id] {
            snapshot = draftSnapshot(snapshot, item)
            if let chosen = item.choices["model"], !["default", "auto", ""].contains(chosen.lowercased().replacingOccurrences(of: "[1m]", with: "")) { snapshot = snapshot.setting("model", .string(chosen)) }
        }
        snapshot = BackendChatMedia.slim(snapshot)
        if seen != nil { await publish(id, snapshot) }
        unread.noteRead(id, snapshot)
        return snapshot
    }
    private func actionStore(_ id: String) throws -> BackendHootChatStore {
        if let item = live[id] { return item.store }
        if let cached = historyActions[id] { return cached }
        guard let job = jobs[id] else { throw BackendSessionFailure.missingSession }
        let provider = HootChatProvider(rawValue: job.session.provider) ?? .claude
        let store = try BackendHootChatStore(file: job.historyPath.map { URL(fileURLWithPath: $0) } ?? Self.historyFile(Self.tabFolder(directory, key: job.key), provider: provider), provider: provider, retainAllHistory: true)
        // 18 Oct (#444): whole conversations, so only the few most recently opened stay in memory.
        historyOrder.removeAll { $0 == id }; historyOrder.append(id)
        while historyOrder.count > Self.historyCacheLimit { historyActions[historyOrder.removeFirst()] = nil }
        historyActions[id] = store; return store
    }
    private func forgetHistory(_ id: String) { historyActions[id] = nil; historyOrder.removeAll { $0 == id }; unread.forget(id) }
    public func rewind(_ id: String, sequence: Int?) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true { return try await hosted!.call(sequence == nil ? "undo-rewind" : "rewind", id: id, fields: [.init("sequence", sequence.map { .number(Double($0)) } ?? .null)]) }
        let store = try actionStore(id)
        changingHistory.insert(id); live[id]?.ready = false
        defer { changingHistory.remove(id) }
        let text: String
        if let sequence { text = try await store.rewind(to: sequence).text }
        else { try await store.undoRewind(); text = "" }
        if jobs[id]?.isFinished != true, live[id] != nil { try await ensure(id) }
        let snapshot = try await read(id, cursor: nil, limit: 500)
        await publish(id, snapshot)
        return .object([.init("text", .string(text)), .init("snapshot", snapshot)])
    }
    public func handoffPrompt(_ id: String, sequence: Int) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true { return try await hosted!.call("handoff", id: id, fields: [.init("sequence", .number(Double(sequence)))]) }
        let store = try actionStore(id)
        guard let cut = await store.cut(at: sequence) else { throw NativeRPCError.invalidArguments("That message is not in this conversation.") }
        let said = BackendHootDesk.said(await store.recentMessages(through: sequence))
        let title = jobs[id]?.job.sessionTitle ?? manager.list().first(where: { $0.id == id })?.title ?? "Chat"
        let prompt = "Write a context handoff of the supplied conversation \(title), not your own chat. Its transcript follows.\n\n" + BackendHootTaskTurns.handoffRequest(upTo: cut, said: said)
        guard prompt.utf8.count <= 240_000 else { throw NativeRPCError.invalidArguments("This conversation is too large for one handoff request.") }
        return .object([.init("prompt", .string(prompt))])
    }
    public func say(_ id: String, text: String, attachments: [NativeRPCValue] = [], context: NativeRPCValue = .object([]), clientMessageID: String? = nil) async throws -> NativeRPCValue {
        // Current phone/tool callers may omit the optional ID; the app still names their one
        // attempt on the keeper wire. Old binaries send no ID and are safely refused there.
        if hosted?.owns(id) == true { return try await hosted!.call("say", id: id, fields: [.init("text", .string(text)), .init("attachments", .array(attachments)), .init("context", context), .init("clientMessageId", .string(BackendChatDeliveryQueue.identity(clientMessageID)))]) }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        item.personStopped = false
        item.notice = nil
        let draft = item.draft
        if jobs[id] != nil, await item.store.isBusy {
            guard !item.steering else { throw NativeRPCError(code: "busy", message: "This chat is accepting your interruption. Keep the draft and try again.") }
            item.steering = true
            defer { item.steering = false }
            await item.store.markStop("person")
            try await item.store.interrupt()
            for _ in 0..<200 {
                if !(await item.store.isBusy) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !(await item.store.isBusy) else { throw NativeRPCError(code: "busy", message: "The AI has not confirmed the interruption yet. Your draft is kept.") }
            let steered = try await item.store.say(text, attachments: attachments, messageContext: context, clientMessageID: clientMessageID)
            item.steering = false
            await changed(id, item, steered)
            return draftSnapshot(steered, item)
        }
        // A model or effort picked under the box: the AI starts again with it now, in the same conversation.
        var relaunched = false
        if item.relaunch, !(await item.store.isBusy) {
            item.relaunch = false; relaunched = true; _ = await closeSideConversation(item); await item.store.stop()
        }
        try await ensure(id)
        let result: NativeRPCValue
        if let runtime = item.externalRuntime { result = try await runtime.sayValidated(text, attachments: attachments, context: context, clientMessageID: clientMessageID) }
        else { result = try await item.store.say(text, attachments: attachments, messageContext: context, clientMessageID: clientMessageID) }
        if item.draft == draft, !draft.isEmpty {
            item.draft = ""; item.draftRevision += 1
            await publish(id, draftSnapshot(await item.store.snapshot(), item))
        }
        // After the box is cleared, so a fallback can put the message back in it.
        if relaunched, item.millionTrial != nil, item.millionTrialTurn == nil {
            item.millionTrialTurn = await item.store.activeTurnID
            await checkMillionTrial(id, item, snapshot: await item.store.snapshot())
        }
        return draftSnapshot(result, item)
    }
    public func setQueuedCount(_ id: String, count: Int) async throws {
        guard (0...1_000_000).contains(count) else { throw NativeRPCError.invalidArguments("Invalid queued message count.") }
        if hosted?.owns(id) == true { try await hosted!.queued(id, count: count); return }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        item.queuedCount = count
        if count == 0 { await changed(id, item, await item.store.snapshot()) }
    }
    public func steer(_ id: String, text: String, attachments: [NativeRPCValue] = [], context: NativeRPCValue = .object([]), clientMessageID: String? = nil) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true { return try await hosted!.steer(id, text: text, attachments: attachments, context: context, clientMessageID: BackendChatDeliveryQueue.identity(clientMessageID)) }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        guard !item.steering else { throw NativeRPCError(code: "busy", message: "This chat is already accepting a Send now message.") }
        item.steering = true
        do {
            let result: NativeRPCValue
            do { result = try await item.store.steer(text, attachments: attachments, messageContext: context, clientMessageID: clientMessageID) }
            catch let error as NativeRPCError where Self.ignoredInterrupt(error) {
                // 29 Oct (Asad: Send now must work every time): the AI did not stop when asked. Its process is stopped
                // (the conversation stays and resumes), then the message goes in at once, as the old interrupt-and-send.
                item.personStopped = true
                await item.store.stop()
                try await ensure(id)
                result = try await item.store.say(text, attachments: attachments, messageContext: context, clientMessageID: clientMessageID)
                item.personStopped = false
            }
            item.steering = false
            await changed(id, item, result)
            return draftSnapshot(result, item)
        } catch { item.steering = false; throw error }
    }
    static func ignoredInterrupt(_ error: NativeRPCError) -> Bool {
        error.code == "busy" && error.message.contains("has not confirmed the interruption")
    }
    /// The Stop button: this answer stops; the session and its AI stay.
    public func stop(_ id: String) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true { return try await hosted!.call("stop", id: id) }
        if jobs[id] != nil {
            try await finishJob(id, result: "Stopped", failed: true)
            return try await read(id, cursor: nil, limit: 500)
        }
        return try await stopAnswer(id)
    }
    public func stopAnswer(_ id: String) async throws -> NativeRPCValue {
        if let hosted, hosted.owns(id) {
            let before = try await hosted.call("read", id: id, fields: [.init("limit", .number(500))])
            let events = try (before["events"].elements ?? []).map(HootChatEvent.init(wire:))
            guard before["provider"].string != "claude" || before["foregroundStopPreservesChildren"].bool == true || !ChatChildTasks.list(events).contains(where: ChatChildTasks.running) else {
                throw NativeRPCError(code: "helper-upgrade-required", message: "This helper needs an update before Stop can preserve its background tasks. Use each task's own Stop; the helper was not restarted.")
            }
            return try await hosted.call("interrupt", id: id)
        }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        item.personStopped = true
        await item.store.markStop("person")
        try await item.store.interrupt()
        return await item.store.snapshot()
    }
    public func stopChild(_ id: String, task: String) async throws -> NativeRPCValue {
        if let hosted, hosted.owns(id) { return try await hosted.call("child-stop", id: id, fields: [.init("taskId", .string(task))]) }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        return try await item.store.stopChild(task)
    }
    public func interruptTurn(_ id: String) async throws -> NativeRPCValue {
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        item.personStopped = true
        await item.store.markStop("person"); try await item.store.interrupt()
        return await item.store.snapshot()
    }
    public func answer(_ id: String, request: String, allowed: Bool, answers: NativeRPCValue) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true { return try await hosted!.call("answer", id: id, fields: [.init("request", .string(request)), .init("allowed", .bool(allowed)), .init("answers", answers)]) }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        let snapshot = await item.store.snapshot()
        let plan = snapshot["pending"].elements?.first { $0["requestId"].string == request && BackendChatPlans.isReview($0) }
        try await item.store.answer(id: request, allowed: allowed, answers: answers)
        if plan?["name"].string == "ExitPlanMode", allowed, item.choices["permission"] == "plan" { item.choices["permission"] = "default" }
        return await item.store.snapshot()
    }
    /// Explicitly closing a session ends its AI. App quit detaches hosted chats separately.
    public func close(_ id: String) async {
        if hosted?.owns(id) == true { _ = try? await hosted!.call("close", id: id); return }
        if let job = jobs[id] {
            if let item = live[id] { item.featuresClosed = true; _ = await closeSideConversation(item) }
            if !job.isFinished { try? await finishJob(id, result: "Closed before the job finished", failed: true) }
            live.removeValue(forKey: id)?.watcher?.cancel(); forgetHistory(id)
            return
        }
        guard let item = live.removeValue(forKey: id) else { return }
        item.featuresClosed = true
        _ = await closeSideConversation(item)
        item.watcher?.cancel()
        await item.store.markStop("quit")
        await item.store.stop()
        manager.kill(id)
    }
    public func setDraft(_ id: String, text: String) async throws {
        if hosted?.owns(id) == true { _ = try await hosted!.call("draft", id: id, fields: [.init("text", .string(text))]); return }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        if item.draft != text { item.draft = text; item.draftRevision += 1 }
    }
    /// Tool typing edits the composer. Only Return submits it.
    /// The keys type() refuses, split the way type() splits them; checked before a typed send is accepted.
    nonisolated static func keyRefusal(_ data: String) -> NativeRPCError? {
        if data.count > 1, data.contains("\r") || data.contains("\n") {
            var text = ""
            for char in data {
                if char == "\r" || char == "\n" { if let refused = keyRefusal(text) { return refused }; text = "" } else { text.append(char) }
            }
            return keyRefusal(text)
        }
        switch data {
        case "\r", "\n", "\u{7f}", "\u{8}", "\u{15}", "\u{3}", "\u{1b}": return nil
        default:
            guard !data.hasPrefix("\u{1b}"), data.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }) else {
                return NativeRPCError.invalidArguments("That key does not edit a chat composer. Use text, Backspace, Ctrl-U or Enter.")
            }
            return nil
        }
    }
    public func type(_ id: String, data: String) async throws {
        if hosted?.owns(id) == true { _ = try await hosted!.call("type", id: id, fields: [.init("text", .string(data))]); return }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        if data.count > 1, data.contains("\r") || data.contains("\n") {
            var text = ""
            for char in data {
                if char == "\r" || char == "\n" {
                    if !text.isEmpty { try await type(id, data: text); text = "" }
                    try await type(id, data: "\r")
                } else { text.append(char) }
            }
            if !text.isEmpty { try await type(id, data: text) }
            return
        }
        switch data {
        case "\r", "\n":
            guard !item.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let text = item.draft
            _ = try await say(id, text: text)
            return
        case "\u{7f}", "\u{8}": if !item.draft.isEmpty { item.draft.removeLast() }
        case "\u{15}": item.draft = ""
        // 18 Oct (#433): Ctrl-C interrupts the answer, as in a terminal; only the Stop action finishes a team job.
        case "\u{3}": _ = try await stopAnswer(id); return
        case "\u{1b}": return
        default:
            if let refused = Self.keyRefusal(data) { throw refused }
            item.draft += data
        }
        item.draftRevision += 1
        await publish(id, draftSnapshot(await item.store.snapshot(), item))
    }
    private func draftSnapshot(_ snapshot: NativeRPCValue, _ item: Live) -> NativeRPCValue {
        // Pictures' bytes stay in the conversation; what goes to a window or a phone carries stand-ins (BackendChatMedia).
        let shown = BackendChatMedia.slim(snapshot).setting("draft", .string(item.draft)).setting("draftRevision", .number(Double(item.draftRevision)))
            .setting("transientVoice", .object([.init("activeOrUncertain", .bool(item.voiceActiveOrUncertain)),
                .init("error", item.voiceCleanupError.map(NativeRPCValue.string) ?? .null)]))
        if let notice = item.notice { return shown.setting("problem", .string(notice)) }
        return Self.plainSignInProblem(shown)
    }
    /// 29 Oct: Claude Code's own "Not logged in · Please run /login" says what it lacks, not what to do here. The chat
    /// says it plainly and where to fix it; the conversation is untouched.
    static let signedOutNotice = "This session's Claude login is signed out, so it cannot answer. Use the account menu to Switch to a signed-in account, or sign this login in (Settings \u{203A} Coding AIs \u{203A} Sign in). Your conversation stays."
    static func plainSignInProblem(_ snapshot: NativeRPCValue) -> NativeRPCValue {
        guard let problem = snapshot["problem"].string, isNotLoggedIn(problem) else { return snapshot }
        return snapshot.setting("problem", .string(signedOutNotice))
    }
    static func isNotLoggedIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in") && lower.contains("/login")
    }
    /// The first answer after a 1M pick: an answer keeps the pick; a failed one (not a Stop) puts the chat back on the
    /// same model without the 1M window, says so in plain words and lets the next message run (Reviewer 28 Oct, 3).
    private func checkMillionTrial(_ id: String, _ item: Live, snapshot: NativeRPCValue) async {
        guard let chosen = item.millionTrial, let trialTurn = item.millionTrialTurn, !trialTurn.isEmpty else { return }
        guard item.choices["model"] == chosen else { item.millionTrial = nil; item.millionTrialTurn = nil; return }
        let turn = await turnOfStore(item, snapshot: snapshot)
        guard turn.turnID == trialTurn else { return }
        switch turn.state {
        case .done: item.millionTrial = nil; item.millionTrialTurn = nil
        case .failed(let reason):
            item.millionTrial = nil; item.millionTrialTurn = nil
            // Only a refusal of the model or its 1M window: a usage limit, an overload, the network or a sign-in
            // problem keeps his pick (Reviewer 28 Oct, MUST). A Stop is never a refusal.
            guard !item.personStopped, Self.isMillionRefusal(reason) else { return }
            let base = String(chosen.dropLast("[1m]".count))
            item.choices["model"] = base; item.relaunch = true
            item.notice = Self.millionFallbackNotice(base, provider: item.recipe.provider, reason: reason)
            // His message goes back in the box when it is empty, so sending it again is one tap.
            if item.draft.isEmpty, let said = (snapshot["events"].elements ?? []).last(where: {
                $0["turnId"].string == trialTurn && $0["kind"].string == HootChatKind.user.rawValue
            })?["value"]["text"].string, !said.isEmpty {
                item.draft = said; item.draftRevision += 1
            }
            await publish(id, draftSnapshot(snapshot, item))
        default: break
        }
    }
    /// Whether a failed answer is the AI refusing the model or its 1M window and nothing else: "[1m]", "1M context",
    /// "context-1m", "long context", "context window", or a sentence that says a model is not available / supported /
    /// allowed / enabled or has no access, or names an "invalid model" / "unknown model". Usage and rate limits,
    /// overloads, network and sign-in problems are never a refusal. Matched on plain text: terminal colour codes and
    /// control characters in raw crash output are removed first (Reviewer 28 Oct, MUST).
    static func isMillionRefusal(_ reason: String) -> Bool {
        var text = reason.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-_]", with: " ", options: .regularExpression)
        text = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" ? " " : $0
        })).lowercased()
        let other = [#"usage limit"#, #"rate.?limit"#, #"\b429\b"#, #"\b529\b"#, #"overload"#, #"quota"#, #"limit (reached|exceeded)"#,
                     #"credit"#, #"billing"#, #"network"#, #"connection"#, #"timed? ?out"#, #"econn"#, #"enotfound"#, #"offline"#,
                     #"sign(ed)? ?in"#, #"log(ged)? ?(in|out)"#, #"login"#, #"oauth"#, #"authenticat"#, #"unauthori[sz]ed"#, #"\b401\b"#,
                     #"token (has )?expired"#, #"expired token"#]
        guard !other.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else { return false }
        let window = [#"\[1m\]"#, #"\b1m context"#, #"context-1m"#, #"long[ -]?context"#, #"context[ -]?window"#]
        if window.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
        if text.range(of: #"\b(invalid|unknown|unsupported) model\b"#, options: .regularExpression) != nil { return true }
        // A model and its availability in the same sentence.
        let availability = #"not (available|supported|allowed|permitted|enabled)|no access|(does not|doesn't) have access"#
        return text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).contains { sentence in
            sentence.range(of: #"\bmodel\b"#, options: .regularExpression) != nil && sentence.range(of: availability, options: .regularExpression) != nil
        }
    }
    static func millionFallbackNotice(_ base: String, provider: HootChatProvider, reason: String) -> String {
        let name = BackendHootReadyDefaults.shortModelName(base, provider: provider)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
        return "The 1M choice did not work for this account, so this chat is back on \(name) without it. Send your message again."
            + (why.isEmpty ? "" : " (\(why))")
    }
    /// Removing an ordinary tab removes its history, including a tab currently in Terminal mode.
    /// Team jobs keep their separate entry when their tab is closed.
    public func removeSession(_ meta: BackendSessionMeta) async throws {
        if hosted?.owns(meta.id) == true { _ = try await hosted!.call("remove", id: meta.id); return }
        if jobs[meta.id] != nil { await close(meta.id); return }
        let key = live[meta.id]?.key ?? meta.tabKey ?? meta.id
        await close(meta.id)
        guard !key.isEmpty else { throw NativeRPCError.invalidArguments("This session has no chat folder to remove.") }
        let folder = Self.tabFolder(directory, key: key)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try BackendChatDeliveryQueue(directory: directory.appendingPathComponent("delivery-requests")).forgetConversation(meta.id)
    }
    /// Only an explicit deletion of the finished entry removes a kept team history.
    public func deleteJobHistory(_ id: String) async throws {
        if hosted?.owns(id) == true { _ = try await hosted!.call("delete", id: id); return }
        guard let job = jobs[id], job.isFinished else { throw NativeRPCError.invalidArguments("Finish the job before deleting its history.") }
        await close(id)
        let folder = Self.tabFolder(directory, key: job.key)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try BackendChatDeliveryQueue(directory: directory.appendingPathComponent("delivery-requests")).forgetConversation(id)
        jobs[id] = nil; diaryCursors[id] = nil; activeTaskJobs.remove(id); notifiedJobs.remove(id); forgetHistory(id)
        manager.kill(id)
    }
    public func isChat(_ id: String) -> Bool { live[id] != nil || hosted?.owns(id) == true }
    /// Quit detaches the hosted client. Only legacy in-app chats and adopted task runtimes end here.
    public func endAllForQuit() async {
        for item in live.values { item.featuresClosed = true }
        _ = await stopTransientVoice()
        hosted?.detach()
        for (id, item) in live {
            item.featuresClosed = true
            _ = await closeSideConversation(item)
            if jobs[id] != nil { try? await finishJob(id, result: "The app closed before this job finished", failed: true) }
            else { await item.store.markStop("quit"); await item.store.stop() }
        }
    }

    /// Every change goes to the window (`session:chat:changed`), the session's status dot, and what a tool reads.
    private func watch(_ id: String, _ item: Live) {
        let stream = AsyncStream<NativeRPCValue> { continuation in
            let task = Task { for await value in await item.store.subscribe() { continuation.yield(value) }; continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
        item.watcher = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                await self.changed(id, item, snapshot)
            }
        }
    }
    private func changed(_ id: String, _ item: Live, _ raw: NativeRPCValue) async {
        var snapshot = Self.visibleJobSnapshot(raw, adopted: item.externalRuntime != nil)
        if item.externalRuntime != nil { snapshot = snapshot.setting("unread", await item.store.unreadSummary(showBackground: true)) }
        guard live[id] === item, !changingHistory.contains(id), !item.steering else { return }
        let status: BackendSessionStatus = !(snapshot["pending"].elements ?? []).isEmpty ? .input : snapshot["busy"].bool == true ? .working : .idle
        if status != item.status { item.status = status; manager.chatStatus(id, status: status) }
        // The CLI's own conversation id (Codex and Gemini tell it once started; a carried conversation gets a new one).
        if let cli = await item.store.cliSessionID, cli != item.conversation {
            item.conversation = cli
            manager.setAgentSessionId(id, conversationId: cli)
            await noteConversation(id, cli)
        }
        item.mirror.set(text: Self.plainText(snapshot))
        item.mirror.set(pid: await item.store.processPID)
        if item.millionTrialTurn != nil { await checkMillionTrial(id, item, snapshot: snapshot) }
        await publish(id, draftSnapshot(snapshot, item).setting("readOnly", .bool(jobs[id]?.isFinished == true)))
        if let job = jobs[id], !job.isFinished, finishing[id] == nil, !item.steering, !item.personStopped, item.queuedCount == 0 {
            do { try await captureDiary(id) }
            catch { await publish(id, snapshot.setting("problem", .string("Could not save this chat to the diary: " + error.localizedDescription))) }
            let turn = await turnOfStore(item, snapshot: snapshot)
            // An idle or partially streamed answer is not a finished job.
            let ended = (snapshot["events"].elements ?? []).contains { $0["turnId"].string == turn.turnID && ["completed", "error", "interrupted"].contains($0["kind"].string ?? "") }
            if item.externalRuntime != nil { return } // The task runtime delivers its result before closing the job.
            // 30 Oct (Decker): a job kept open (background builds still running) is not closed by a turn's end;
            // its starter ends it with finish or stop.
            if ended, jobs[id]?.job.keepOpen == true { return }
            if ended {
                switch turn.state {
                case .done(let answer):
                    try? await finishJob(id, result: answer, failed: false)
                case .failed(let reason):
                    try? await finishJob(id, result: reason, failed: true)
                default: break
                }
            } else if item.ready, snapshot["alive"].bool == false, turn.state == .idle {
                try? await finishJob(id, result: "The AI stopped before receiving its brief", failed: true)
            }
        }
    }

    // MARK: One job, one visible chat, one kept history

    @discardableResult
    public func exposeTaskRuntime(_ runtime: BackendCopilotSessionRuntime, folder: String, projectID: String?, job: BackendTeamChatJob) async throws -> BackendSessionMeta {
        guard let store = runtime.structuredChat else { throw BackendSessionFailure.missingCapability("the task's structured chat") }
        if let remoteID = await store.hostedSessionID, let hosted {
            _ = try await hosted.call("job", id: remoteID, fields: [.init("job", try NativeRPCValue.parseJSON(JSONEncoder().encode(job))), .init("projectID", projectID.map(NativeRPCValue.string) ?? .null)])
            try await hosted.refreshInventory()
            guard let meta = hosted.conversation(remoteID)?.session else { throw BackendSessionFailure.missingSession }
            return meta
        }
        let id = UUID().uuidString.lowercased()
        let provider = await store.provider.rawValue
        var input = BackendCreateSessionInput(cwd: folder, provider: provider)
        input.chat = true; input.projectId = projectID; input.origin = .copilot
        let spawn = BackendSpawnSpec(provider: provider, command: "", args: [], path: "", tabKey: id)
        var meta = BackendSessionMeta(id: id, input: input, spawn: spawn)
        meta.title = job.sessionTitle
        let mirror = Mirror(), recipe = Recipe(provider: HootChatProvider(rawValue: provider) ?? .claude,
            executable: "", arguments: [], environment: [:], cwd: folder, conversation: nil)
        let item = Live(store: store, recipe: recipe, mirror: mirror, key: id, id: id)
        item.externalRuntime = runtime; item.ready = true
        var record = BackendTeamChatRecord(session: meta, job: job, key: id)
        record.historyPath = await store.historyFileURL.path
        jobs[id] = record; try saveJob(id)
        live[id] = item
        try manager.registerChat(meta, controls: .init(send: { [weak self] text in Task { _ = try? await self?.type(id, data: text) } },
            stop: { [weak self] in Task { await self?.close(id) } }, text: { mirror.currentText }, pid: { mirror.currentPID }))
        watch(id, item)
        return meta
    }
    /// Background turns are hidden in the person's Hoot chat, but shown in their OWN task session.
    static func visibleJobSnapshot(_ snapshot: NativeRPCValue, adopted: Bool) -> NativeRPCValue {
        guard adopted else { return snapshot }
        let events = (snapshot["events"].elements ?? []).map { event -> NativeRPCValue in
            var event = event
            if let turn = event["turnId"].string, turn.hasPrefix("bg:") { event = event.setting("turnId", .string("task:" + turn.dropFirst(3))) }
            if let brief = event["value"]["background"]["brief"].string {
                event = event.setting("kind", .string("user")).setting("value", .object([.init("text", .string(brief))]))
            }
            return event
        }
        return snapshot.setting("events", .array(events))
    }
    public func setHostedJob(_ id: String, job: BackendTeamChatJob, projectID: String?) throws {
        guard var row = jobs[id], !row.isFinished else { throw BackendSessionFailure.missingSession }
        row.job = job; row.session.title = job.sessionTitle; row.session.projectId = projectID; jobs[id] = row
        try saveJob(id); manager.chatProject(id, projectID: projectID); _ = manager.rename(id, title: job.sessionTitle)
    }
    public func setJobObservers(turn: @escaping @Sendable (String, Turn) async -> Void,
                                closed: @escaping @Sendable (String) async -> Void) {
        jobTurn = turn; jobClosed = closed
    }
    /// The app's rule for a finished job still in the session list (production: close it unless it is on screen).
    /// A close that fails (the helper busy or gone) is tried again at the next sweep.
    public func setFinishedJobRetirement(_ retire: @escaping @Sendable (String) async throws -> Void) { retireFinished = retire }
    /// Every finished job still listed (after the app attaches or reattaches to its helper) leaves the list once.
    public func retireFinishedJobs() {
        for meta in manager.list() where meta.chat == true { retireOnce(meta.id) }
    }
    /// Once per job and only while it is listed: one the person opens again afterwards stays until they close it.
    private func retireOnce(_ id: String) {
        guard let retire = retireFinished, !retiredJobs.contains(id), conversation(id)?.isFinished == true,
              manager.list().contains(where: { $0.id == id }) else { return }
        retiredJobs.insert(id); retireQueue.append(id)
        guard !retireDraining else { return }
        retireDraining = true
        // Separately: closing goes back through this engine (removeSession) and the helper.
        Task { await drainRetirements(retire) }
    }
    private func drainRetirements(_ retire: @Sendable (String) async throws -> Void) async {
        while !retireQueue.isEmpty {
            let id = retireQueue.removeFirst()
            do { try await retire(id) } catch { retiredJobs.remove(id) }
        }
        retireDraining = false
    }
    public func conversation(_ id: String) -> BackendTeamChatRecord? { hosted?.conversation(id) ?? jobs[id] }
    public func conversations(project: String? = nil, agent: String? = nil, state: String? = nil) -> [BackendTeamChatRecord] {
        var records = jobs
        for remote in hosted?.conversations() ?? [] { records[remote.session.id] = remote }
        return Array(records.values).filter { row in
            (project == nil || row.session.resolvedProjectID == project) &&
            (agent == nil || row.job.agentID == agent || row.job.fromID == agent) &&
            (state == nil || (row.isFinished ? "finished" : "open") == state)
        }.sorted { $0.session.createdAt > $1.session.createdAt }
    }
    private func captureDiary(_ id: String) async throws {
        guard let job = jobs[id], let item = live[id] else { return }
        var cursor = diaryCursors[id] ?? 0
        while true {
            let page = Self.visibleJobSnapshot(await item.store.snapshot(after: cursor, limit: 500), adopted: item.externalRuntime != nil)
            try await diary(job, page)
            let next = Int(page["cursor"].number ?? 0)
            guard next > cursor else { return }
            diaryCursors[id] = next; cursor = next
            if page["hasMore"].bool != true { return }
        }
    }
    private func requireOpenJob(_ id: String) throws {
        if jobs[id]?.isFinished == true || finishing[id] != nil {
            throw NativeRPCError.invalidArguments("This job is finished. Start a new conversation for new work.")
        }
    }
    private func saveJob(_ id: String) throws {
        guard let job = jobs[id] else { return }
        let folder = Self.tabFolder(directory, key: job.key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("job.json")
        try JSONEncoder().encode(job).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Called at startup. Only the small job records are loaded; conversations are read when opened.
    /// An app exit closes unfinished jobs too. Nothing starts a CLI during history restoration.
    /// 21 Oct (Asad): a finished job is NOT put on the bar at startup; it stays in the Agents page's chat list
    /// and is registered as a chat only when the person opens it (`openJobHistory`). Registering all of them
    /// (114 that morning) opened a tab per finished task and froze the app at launch.
    public func restoreJobHistory() async throws {
        if hosted != nil { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let file = folder.appendingPathComponent("job.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            // U1: one record that does not read is skipped (and kept as a .damaged copy); it never stops the others.
            guard var job = try? JSONDecoder().decode(BackendTeamChatRecord.self, from: Data(contentsOf: file)) else {
                DamagedFile.keepCopy(of: file)
                NSLog("[chats] a saved chat record could not be read and was skipped: %@", folder.lastPathComponent); continue
            }
            if job.historyPath != nil { continue }
            if !job.isFinished {
                job.finishedAt = Date(); job.failed = true; job.result = "The app closed before this job finished"
                job.session.exitCode = 1
            }
            jobs[job.session.id] = job
            do { try saveJob(job.session.id) }
            catch { NSLog("[chats] a saved chat record could not be restored: %@", error.localizedDescription) }
        }
    }
    @discardableResult
    public func openJobHistory(_ id: String) async throws -> BackendSessionMeta {
        if let hosted, hosted.owns(id) {
            #if TD_HOST_INTEGRATED
            // 22 Oct: a finished job that left the list comes back into this app's list too (not only at its next start).
            if !manager.list().contains(where: { $0.id == id }) { manager.readmitHosted(id) }
            #endif
            return try await hosted.metadata(id)
        }
        guard let job = jobs[id] else { throw BackendSessionFailure.missingSession }
        if manager.list().contains(where: { $0.id == id }) { return job.session }
        guard job.isFinished else { throw NativeRPCError.invalidArguments("That job is still running.") }
        let text = job.result ?? ""
        try manager.registerChat(job.session, controls: .init(send: { _ in
            throw NativeRPCError.invalidArguments("This job is finished. Start a new conversation.")
        }, stop: {}, text: { text }, pid: { nil }))
        manager.chatStatus(id, status: .completed)
        return job.session
    }
    /// A very fast answer can finish before the task's launch finishes binding it. Deliver after that binding.
    public func activateTaskJob(_ id: String) async {
        if let job = hosted?.conversation(id) { activeTaskJobs.insert(id); if job.isFinished { await notifyHostedFinished(id, job: job) }; return }
        activeTaskJobs.insert(id)
        if jobs[id]?.isFinished == true, let observed = try? await turn(id) { await notifyFinishedJob(id, observed: observed) }
    }
    private func notifyFinishedJob(_ id: String, observed: Turn) async {
        guard let job = jobs[id], job.historyPath == nil, job.isFinished, !notifiedJobs.contains(id),
              job.job.taskID == nil || activeTaskJobs.contains(id) else { return }
        notifiedJobs.insert(id)
        let observer = jobTurn, closed = retireFinished == nil ? jobClosed : nil
        Task {
            await observer?(id, observed)
            await closed?(id)
        }
    }
    /// 30 Oct (Decker): keep an open job open past the end of its turns (true), or let the next turn's end close it (false).
    public func keepJobOpen(_ id: String, _ keep: Bool) async throws {
        if hosted?.owns(id) == true {
            do { _ = try await hosted!.call("keep", id: id, fields: [.init("keepOpen", .bool(keep))]) }
            catch let error where error.localizedDescription.contains("Unknown chat service operation") {
                throw NativeRPCError(code: "helper-upgrade-required", message: "The running session helper predates keeping a job open. The job was not changed; it needs the next helper update.")
            }
            return
        }
        guard var job = jobs[id] else { throw BackendSessionFailure.missingSession }
        guard !job.isFinished else { throw NativeRPCError.invalidArguments("This job has already finished.") }
        job.job.keepOpen = keep ? true : nil
        jobs[id] = job
        try saveJob(id)
    }
    public func finishJob(_ id: String, result: String, failed: Bool) async throws {
        if hosted?.owns(id) == true { _ = try await hosted!.call("finish", id: id, fields: [.init("result", .string(result)), .init("failed", .bool(failed))]); return }
        if let task = finishing[id] { try await task.value; return }
        guard let job = jobs[id], !job.isFinished else { return }
        let task = Task { try await self.finishJobNow(id, result: result, failed: failed) }
        finishing[id] = task
        defer { finishing[id] = nil }
        try await task.value
    }
    private func finishJobNow(_ id: String, result: String, failed: Bool) async throws {
        guard var job = jobs[id], !job.isFinished else { return }
        let before = try await read(id, cursor: nil, limit: 500)
        do { try await captureDiary(id); try await diary(job, before) }
        catch { await publish(id, before.setting("problem", .string("Could not save this chat to the diary: " + error.localizedDescription))) }
        let observed = live[id] == nil ? Self.turn(of: before) : await turnOfStore(live[id]!, snapshot: before)
        if let item = live[id] {
            item.featuresClosed = true
            _ = await closeSideConversation(item)
            await item.store.markStop("job-finished")
            await item.store.stop() // stopAndWait: no process survives the finished record
            item.mirror.set(pid: nil); item.mirror.set(text: Self.plainText(before))
            await item.externalRuntime?.rest()
        }
        job.session = manager.list().first { $0.id == id } ?? job.session
        job.finishedAt = Date(); job.result = result; job.failed = failed; job.session.exitCode = failed ? 1 : 0
        job.turnID = observed.turnID; job.cursor = observed.cursor
        jobs[id] = job
        try saveJob(id)
        manager.finishChat(id, failed: failed)
        await publish(id, try await read(id, cursor: nil, limit: 500))
        // Queue the delivery separately: task completion can close this session through the same lifecycle.
        // It must not wait on the finish operation that is delivering it.
        await notifyFinishedJob(id, observed: .init(state: failed ? .failed(reason: result) : .done(answer: result), turnID: observed.turnID, cursor: observed.cursor))
        if job.historyPath != nil { live.removeValue(forKey: id)?.watcher?.cancel() }
        retireOnce(id)
    }

    // MARK: Under the box: permission, model and effort (the session's own, from its real AI and account)

    /// The same shape Hoot's composer reads (`hoot:chat:options`): the mode, this AI's live models, the model and
    /// effort in effect, its effort levels. Nothing hard-coded: the live catalogue, the CLI's own defaults.
    public func options(_ id: String) async throws -> NativeRPCValue {
        // 28 Oct (Asad: "no other models in the list"): the session host keeps no account store, so its own answer
        // has no Claude list, only the launch model. The app's live list goes in before the Mac or a phone sees it.
        if hosted?.owns(id) == true { return Self.withLiveModels(try await hosted!.call("options", id: id), catalogue: await modelCatalogue()) }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        let provider = item.recipe.provider
        let arguments = Self.withChoices(item.recipe.arguments, provider: provider, choices: item.choices)
        let configDir = item.recipe.environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : provider == .codex ? "CODEX_HOME" : "GEMINI_CLI_HOME"]
        let real = BackendHootReadyDefaults.cliDefaults(provider: provider, configDir: configDir)
        var model = Self.value(after: ["--model", "-m"], in: arguments) ?? real.model
        let effort = Self.effort(provider: provider, arguments: arguments) ?? real.effort
        let mode = BackendHootReadyDefaults.chatMode(Self.permissionPolicy(provider: provider, arguments: arguments))
        let catalog = await modelCatalogue()
        let fast = BackendSessionChatComposer.fastMode(provider: provider, configDir: configDir,
            catalogue: catalog[provider.rawValue], arguments: arguments, choice: item.choices["fastMode"])
        var liveSection = catalog[provider.rawValue]
        if provider == .claude, (liveSection["models"].elements ?? []).isEmpty {
            // No list through a login the app keeps (this Mac's own Claude Code sign-in, or this is the session host,
            // which keeps no account store): Claude Code's own choices for this account, from its handshake.
            liveSection = Self.cliSection(await item.store.currentCLIModels, base: liveSection)
        }
        let available = (liveSection["models"].elements ?? []).filter { !["default", "auto", ""].contains(($0["id"].string ?? "").lowercased().replacingOccurrences(of: "[1m]", with: "")) }
        if ["default", "auto", ""].contains(model.lowercased().replacingOccurrences(of: "[1m]", with: "")) {
            let reported = await item.store.currentModel
            let candidates = [reported, liveSection["defaultModel"].string, liveSection["current"].string]
                + (liveSection["featured"].elements ?? []).compactMap(\.string).map(Optional.some)
                + available.compactMap { $0["id"].string }.map(Optional.some)
            model = candidates.compactMap { $0 }.first { candidate in
                !["default", "auto", ""].contains(candidate.lowercased().replacingOccurrences(of: "[1m]", with: "")) && (candidate == reported || available.contains { $0["id"].string == candidate })
            } ?? ""
        }
        let section = Self.withMillionChoices(liveSection.setting("fastMode", fast.map {
            .object([.init("available", .bool(true)), .init("on", .bool($0))])
        } ?? .null), provider: provider)
        let usage = try await usageReport(id)
        var offered = Self.offeredModels(section, provider: provider)
        let name = Self.providerName(provider)
        let modelID = provider.rawValue + ":" + model
        if !["default", "auto", ""].contains(model), !offered.contains(where: { $0["id"].string == modelID }) {
            offered.append(.object([.init("id", .string(modelID)), .init("provider", .string(name)),
                                    .init("name", .string(BackendHootReadyDefaults.shortModelName(model, provider: provider)))]))
        }
        return .object([.init("permissionMode", .string(mode.rawValue)),
            .init("catalog", .object([.init(provider.rawValue, section)])), .init("fastMode", fast.map(NativeRPCValue.bool) ?? .null),
            .init("usage", usage), .init("usageSummary", SessionChatUsageSummary.wire(usage)),
            .init("model", .string(modelID)), .init("models", .array(offered)), .init("ready", .bool(true)),
            .init("effort", .string(effort)),
            .init("efforts", .array(AGSCapabilities.efforts(provider: provider.rawValue).map(NativeRPCValue.string))),
            .init("recommendedEffort", AGSCapabilities.recommendedEffort(provider: provider.rawValue, model: model).map(NativeRPCValue.string) ?? .null)])
    }
    static func providerName(_ provider: HootChatProvider) -> String {
        provider == .claude ? "Claude Code" : provider == .codex ? "Codex" : "Gemini"
    }
    /// The box's choices from one AI's live section: the featured ones (newest of each line), then the older ones.
    static func offeredModels(_ section: NativeRPCValue, provider: HootChatProvider) -> [NativeRPCValue] {
        let rows = section["models"].elements ?? [], name = providerName(provider)
        var offered: [NativeRPCValue] = []
        for listed in ((section["featured"].elements ?? []) + (section["more"].elements ?? [])).compactMap(\.string)
        where !offered.contains(where: { $0["id"].string == provider.rawValue + ":" + listed }) {
            guard let row = rows.first(where: { $0["id"].string == listed }) else { continue }
            offered.append(.object([.init("id", .string(provider.rawValue + ":" + listed)), .init("provider", .string(name)), .init("name", .string(row["name"].string ?? listed))]))
        }
        return offered
    }
    /// A chat the session host keeps: the host's answer with the app's live list for its AI when the host has none
    /// (the host keeps no account store, so it never fetches the Claude list and offered only the launch model).
    /// The host's own reading of the session stays: the model in use, effort, Fast mode, permission.
    static func withLiveModels(_ answer: NativeRPCValue, catalogue: NativeRPCValue) -> NativeRPCValue {
        guard let key = answer["model"].string?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? answer["catalog"].fields?.first?.key,
              let provider = HootChatProvider(rawValue: key) else { return answer }
        let hostSection = answer["catalog"][key], appSection = catalogue[key]
        let hostListed = !(hostSection["models"].elements ?? []).isEmpty, appListed = !(appSection["models"].elements ?? []).isEmpty
        guard hostListed || appListed else { return answer }
        // The account's list (through a login the app keeps) wins over the CLI's short one a newer host gives.
        let useApp = appListed && (!hostListed || hostSection["source"].string == "cli")
        let fast = hostSection["fastMode"].isNullish ? NativeRPCValue.null : hostSection["fastMode"]
        let section = useApp ? withMillionChoices(appSection.setting("fastMode", fast), provider: provider) : withMillionChoices(hostSection, provider: provider)
        var offered = offeredModels(section, provider: provider)
        // The model the host reports in use, when the list does not have it (a CLI alias such as "opus[1m]"), stays offered.
        if let current = answer["model"].string, !offered.contains(where: { $0["id"].string == current }),
           let row = (answer["models"].elements ?? []).first(where: { $0["id"].string == current }) {
            let tail = current.split(separator: ":", maxSplits: 1).last.map(String.init) ?? current
            offered.append(row.setting("name", .string(BackendHootReadyDefaults.shortModelName(tail, provider: provider))))
        }
        let catalog = answer["catalog"].fields == nil ? NativeRPCValue.object([]) : answer["catalog"]
        return answer.setting("catalog", catalog.setting(key, section)).setting("models", .array(offered))
    }
    /// Claude Code's own choices (its handshake) as a catalogue section, in its order; marked "source": "cli".
    static func cliSection(_ models: NativeRPCValue, base: NativeRPCValue) -> NativeRPCValue {
        guard let rows = models.elements, !rows.isEmpty else { return base }
        return (base.fields == nil ? NativeRPCValue.object([]) : base).setting("models", .array(rows))
            .setting("featured", .array(rows.map { $0["id"] })).setting("more", .array([])).setting("source", .string("cli"))
    }
    /// Claude Code takes "[1m]" after a model for its 1M-token window (its own /model offers "Opus (1M context)" beside
    /// "Opus"). The newest model of each line that has that window gets the choice right after it, so a chat started on
    /// "opus[1m]" is listed, ticked and kept when he switches back. From the live list's own facts, or the lines Claude
    /// Code gives the window (the rule Hoot's 1M setting uses); never a written list of models.
    static func withMillionChoices(_ section: NativeRPCValue, provider: HootChatProvider) -> NativeRPCValue {
        guard provider == .claude, var rows = section["models"].elements, !rows.isEmpty else { return section }
        var featured: [NativeRPCValue] = []
        for listed in section["featured"].elements ?? [] where !featured.contains(listed) {
            featured.append(listed)
            guard let id = listed.string, !id.hasSuffix("[1m]"), let row = rows.first(where: { $0["id"].string == id }),
                  row["oneMillion"].bool == true || HootModelCatalog.supportsOneMillion(provider: .claude, model: id) else { continue }
            let million = id + "[1m]"
            if !rows.contains(where: { $0["id"].string == million }) {
                var choice = row.setting("id", .string(million)).setting("name", .string((row["name"].string ?? id) + " 1M"))
                    .setting("contextWindow", .number(1_000_000)).setting("oneMillion", .bool(true))
                if let resolved = row["resolvedModel"].string { choice = choice.setting("resolvedModel", .string(resolved + "[1m]")) }
                if let about = row["description"].string { choice = choice.setting("description", .string(about + " · 1M context")) }
                rows.append(choice)
            }
            if !featured.contains(.string(million)) { featured.append(.string(million)) }
        }
        return section.setting("models", .array(rows)).setting("featured", .array(featured))
    }
    /// The row of this section a model in use stands for, when it is not listed by that id: Claude Code's alias
    /// ("opus", "sonnet[1m]", "opusplan") is the newest of that line (its 1M choice when it asks for the 1M window);
    /// a full id ("claude-opus-5-5") is the CLI's own choice that means it. nil when nothing matches.
    public static func liveModel(forAlias raw: String, in section: NativeRPCValue) -> String? {
        if let row = (section["models"].elements ?? []).first(where: { $0["resolvedModel"].string == raw }), let id = row["id"].string { return id }
        let lower = raw.lowercased(), million = lower.hasSuffix("[1m]")
        let base = lower.replacingOccurrences(of: "[1m]", with: "")
        guard !base.isEmpty, !base.contains("-"), !["default", "auto"].contains(base) else { return nil }
        let family = base == "opusplan" ? "opus" : base
        let line = ((section["featured"].elements ?? []) + (section["more"].elements ?? [])).compactMap(\.string)
            .filter { $0.lowercased().contains("-" + family + "-") || $0.lowercased().hasSuffix("-" + family) }
        return line.first { $0.lowercased().hasSuffix("[1m]") == million } ?? line.first { !$0.hasSuffix("[1m]") }
    }
    /// A pick under the box. The permission takes effect at once (a running Claude switches its live mode; the app
    /// answers prompts by it); a model or effort from the next message.
    public func setOptions(_ id: String, _ patch: NativeRPCValue) async throws -> NativeRPCValue {
        if hosted?.owns(id) == true {
            return Self.withLiveModels(try await hosted!.call("options", id: id, fields: [.init("patch", patch)]), catalogue: await modelCatalogue())
        }
        try requireOpenJob(id)
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        let provider = item.recipe.provider
        // Validate Fast mode before any part of this patch changes the session.
        if !patch["fastMode"].isNullish {
            guard let on = patch["fastMode"].bool else { throw NativeRPCError.invalidArguments("Fast mode is on or off.") }
            guard try await options(id)["fastMode"].bool != nil else {
                throw NativeRPCError.invalidArguments("This AI account does not offer Fast mode.")
            }
            item.choices["fastMode"] = on ? "true" : "false"; item.relaunch = true
        }
        if let raw = patch["permissionMode"].string {
            guard let mode = BackendHOOTSIMPermissionMode(rawValue: raw) else { throw NativeRPCError.invalidArguments("Unknown permission mode.") }
            let cli = mode.cliMode(provider: provider)
            item.choices["permission"] = cli
            await item.store.setPermissionPolicy(cli == "default" ? nil : cli)
            await item.store.applyPermissionPolicyNow(cli == "default" ? nil : cli, cliMode: cli)
            if provider != .claude { item.relaunch = true }   // Codex's sandbox and Gemini's mode are launch settings
        }
        if let raw = patch["model"].string, !raw.isEmpty {
            let model = raw.hasPrefix(provider.rawValue + ":") ? String(raw.dropFirst(provider.rawValue.count + 1)) : raw
            guard !["default", "auto"].contains(model.lowercased().replacingOccurrences(of: "[1m]", with: "")), model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,99}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Unknown model.") }
            item.choices["model"] = model; item.relaunch = true
            // Whether this account has the 1M window cannot be read beforehand: its first answer decides.
            item.millionTrial = provider == .claude && model.hasSuffix("[1m]") ? model : nil; item.millionTrialTurn = nil
        }
        if let effort = patch["effort"].string, !effort.isEmpty {
            guard provider != .gemini, AGSCapabilities.efforts(provider: provider.rawValue).contains(effort) else {
                throw NativeRPCError.invalidArguments("This AI has no such effort level.")
            }
            item.choices["effort"] = effort; item.relaunch = true
        }
        return try await options(id)
    }

    /// The session's launch with the picks made under the box in place of its own.
    static func withChoices(_ arguments: [String], provider: HootChatProvider, choices: [String: String]) -> [String] {
        var args = arguments
        func drop(_ flags: Set<String>, pair: Bool = true) {
            var kept: [String] = [], index = 0
            while index < args.count {
                if flags.contains(args[index]) { index += pair ? 2 : 1; continue }
                kept.append(args[index]); index += 1
            }
            args = kept
        }
        func dropConfig(_ prefix: String) {
            var kept: [String] = [], index = 0
            while index < args.count {
                if ["-c", "--config"].contains(args[index]), index + 1 < args.count, args[index + 1].hasPrefix(prefix) { index += 2; continue }
                kept.append(args[index]); index += 1
            }
            args = kept
        }
        if let model = choices["model"] { drop(["--model", "-m"]); args += [provider == .codex ? "-m" : "--model", model] }
        if let effort = choices["effort"] {
            switch provider {
            case .claude: drop(["--effort"]); args += ["--effort", effort]
            case .codex: dropConfig("model_reasoning_effort="); args += ["-c", "model_reasoning_effort=\"" + effort + "\""]
            case .gemini: break
            }
        }
        if let permission = choices["permission"] {
            switch provider {
            case .claude:
                drop(["--dangerously-skip-permissions"], pair: false); drop(["--permission-mode"])
                if permission != "default" { args += ["--permission-mode", permission] }
            case .codex:
                drop(["--sandbox", "-s", "--ask-for-approval", "-a"])
                if permission != "default" { args += ["--sandbox", permission, "--ask-for-approval", "on-request"] }
            case .gemini:
                drop(["--yolo", "-y"], pair: false); drop(["--approval-mode"])
                if permission == "yolo" { args += ["--yolo"] } else if permission != "default" { args += ["--approval-mode", permission] }
            }
        }
        return args
    }
    static func value(after flags: Set<String>, in arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(where: flags.contains), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    static func effort(provider: HootChatProvider, arguments: [String]) -> String? {
        switch provider {
        case .claude: return value(after: ["--effort"], in: arguments)
        case .codex:
            guard let line = Array(zip(arguments, arguments.dropFirst())).last(where: { ["-c", "--config"].contains($0.0) && $0.1.hasPrefix("model_reasoning_effort=") })?.1 else { return nil }
            return String(line.dropFirst("model_reasoning_effort=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        case .gemini: return nil
        }
    }

    // MARK: A program driving a chat session (the Tasks seat's phase 2: Hoot → lead, lead → agents, task workers)

    /// Where the session's latest turn is: what a program waits on instead of reading a terminal's screen.
    public enum TurnState: Equatable, Sendable {
        /// Nothing asked yet.
        case idle
        /// Its AI is answering.
        case working
        /// It is waiting for the person (or the driver) to allow or deny: the requests, as the chat shows them.
        case needsPermission([NativeRPCValue])
        /// The turn finished: its answer (the last thing the AI said in it).
        case done(answer: String)
        /// The turn ended in an error, or the AI stopped before finishing.
        case failed(reason: String)
    }
    /// The state, the id of the turn it is about, and the cursor to read its events from (`read(after:)`).
    public struct Turn: Equatable, Sendable {
        public let state: TurnState
        public let turnID: String?
        public let cursor: Int
    }
    /// The session's latest turn, now.
    public func turn(_ id: String) async throws -> Turn {
        if hosted?.owns(id) == true { return try await hosted!.turn(id) }
        if let job = jobs[id], job.isFinished {
            return .init(state: job.failed ? .failed(reason: job.result ?? "Failed") : .done(answer: job.result ?? ""),
                turnID: job.turnID, cursor: job.cursor ?? 0)
        }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        return await turnOfStore(item, snapshot: Self.visibleJobSnapshot(await item.store.snapshot(limit: 500), adopted: item.externalRuntime != nil))
    }
    /// Waits (pushed, never polled) until the latest turn is no longer working: done, failed, or waiting for an
    /// answer. Gives back the state as it is when `timeout` runs out.
    public func waitForTurn(_ id: String, timeout: Duration) async throws -> Turn {
        if hosted?.owns(id) == true { return try await hosted!.waitForTurn(id, timeout: timeout) }
        if jobs[id]?.isFinished == true { return try await turn(id) }
        guard let item = live[id] else { throw BackendSessionFailure.missingSession }
        let updates = await item.store.subscribe()
        let reached: Turn? = try await withThrowingTaskGroup(of: Turn?.self) { group in
            group.addTask {
                for await snapshot in updates {
                    let turn = await self.turnOfStore(item, snapshot: Self.visibleJobSnapshot(snapshot, adopted: item.externalRuntime != nil))
                    if turn.state != .working { return turn }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let reached {
            if jobs[id] != nil, jobs[id]?.job.keepOpen != true, !item.personStopped {
                switch reached.state {
                case .done(let answer): try await finishJob(id, result: answer, failed: false)
                case .failed(let reason): try await finishJob(id, result: reason, failed: true)
                default: break
                }
            }
            return reached
        }
        return try await turn(id)
    }
    /// A long tool-heavy turn can push its first user event out of the 500-event live window.
    /// The store owns its active turn id; a driver must never mistake that for an idle session.
    private func turnOfStore(_ item: Live, snapshot: NativeRPCValue) async -> Turn {
        if item.steering { return .init(state: .working, turnID: await item.store.activeTurnID, cursor: Int(snapshot["sequence"].number ?? 0)) }
        let rawID = await item.store.activeTurnID
        let id = item.externalRuntime != nil && rawID.hasPrefix("bg:") ? "task:" + rawID.dropFirst(3) : rawID
        var snapshot = snapshot
        if !id.isEmpty, !(snapshot["events"].elements ?? []).contains(where: {
            $0["turnId"].string == id && ($0["kind"].string == "user" || $0["value"]["providerTurnStarted"].fields != nil)
        }) {
            let user = NativeRPCValue.object([.init("kind", .string("user")), .init("turnId", .string(id))])
            snapshot = snapshot.setting("events", .array([user] + (snapshot["events"].elements ?? [])))
        }
        let result = Self.turn(of: snapshot)
        if item.queuedCount > 0 {
            switch result.state {
            case .done, .failed: return .init(state: .working, turnID: result.turnID, cursor: result.cursor)
            default: break
            }
        }
        return result
    }
    /// The turn read off a snapshot (pure, tested).
    static func turn(of snapshot: NativeRPCValue) -> Turn {
        let events = snapshot["events"].elements ?? []
        let cursor = Int(snapshot["sequence"].number ?? 0)
        guard let anchor = events.last(where: { $0["kind"].string == HootChatKind.user.rawValue || $0["value"]["providerTurnStarted"].fields != nil }),
              let turnID = anchor["turnId"].string else {
            return .init(state: snapshot["busy"].bool == true ? .working : .idle, turnID: nil, cursor: cursor)
        }
        let pending = snapshot["pending"].elements ?? []
        if !pending.isEmpty { return .init(state: .needsPermission(pending), turnID: turnID, cursor: cursor) }
        if snapshot["busy"].bool == true { return .init(state: .working, turnID: turnID, cursor: cursor) }
        let inTurn = events.filter { $0["turnId"].string == turnID }
        if let error = inTurn.last(where: { $0["kind"].string == HootChatKind.error.rawValue }) {
            return .init(state: .failed(reason: error["value"]["text"].string ?? "The turn failed."), turnID: turnID, cursor: cursor)
        }
        if inTurn.contains(where: { $0["kind"].string == HootChatKind.interrupted.rawValue }),
           !inTurn.contains(where: { $0["kind"].string == HootChatKind.completed.rawValue }) {
            return .init(state: .failed(reason: "The turn was stopped before it finished."), turnID: turnID, cursor: cursor)
        }
        let answer = inTurn.last(where: { $0["kind"].string == HootChatKind.message.rawValue })?["value"]["text"].string ?? ""
        return .init(state: .done(answer: answer), turnID: turnID, cursor: cursor)
    }
    public static func wire(_ turn: Turn) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("turnId", turn.turnID.map(NativeRPCValue.string) ?? .null), .init("cursor", .number(Double(turn.cursor)))])
        switch turn.state {
        case .idle: value = value.setting("state", .string("idle"))
        case .working: value = value.setting("state", .string("working"))
        case .needsPermission(let requests): value = value.setting("state", .string("needs-permission")).setting("requests", .array(requests))
        case .done(let answer): value = value.setting("state", .string("done")).setting("answer", .string(answer))
        case .failed(let reason): value = value.setting("state", .string("failed")).setting("reason", .string(reason))
        }
        return value
    }

    // MARK: Rules (pure, tested)

    /// One folder per tab: its conversation as each AI held it (`chat.json` for Claude, `chat-codex.json`, `chat-gemini.json`:
    /// the names Hoot's own conversation engine moves between when the AI changes).
    static func tabFolder(_ directory: URL, key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(String(safe.prefix(80)), isDirectory: true)
    }
    static func historyFile(_ folder: URL, provider: HootChatProvider) -> URL {
        folder.appendingPathComponent(provider == .claude ? "chat.json" : "chat-\(provider.rawValue).json")
    }
    /// The tab's conversation for this AI. When the tab last talked to another AI (a Claude → Codex switch), that
    /// conversation is moved over (Hoot's own `rebindProvider`): the new AI's next message carries it, word for word.
    static func openStore(folder: URL, provider: HootChatProvider, retainAllHistory: Bool = false) async throws -> BackendHootChatStore {
        let saved: [(HootChatProvider, Date)] = [HootChatProvider.claude, .codex, .gemini].compactMap { other in
            let file = historyFile(folder, provider: other)
            guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (other, date)
        }
        guard let latest = saved.max(by: { $0.1 < $1.1 })?.0, latest != provider else {
            return try BackendHootChatStore(file: historyFile(folder, provider: provider), provider: provider, retainAllHistory: retainAllHistory)
        }
        let store = try BackendHootChatStore(file: historyFile(folder, provider: latest), provider: latest, retainAllHistory: retainAllHistory)
        try await store.rebindProvider(provider)
        return store
    }

    /// A session's launch split into a confinement launcher's own words and the CLI's arguments. BackendMacConfinement
    /// starts a device-boundary or records-fenced session as `/usr/bin/sandbox-exec -p <profile> <cli> <args…>`; the
    /// chat plan rewrites only the CLI's part, and the launcher's words go back in front of it. A plain launch has none.
    /// Any other `sandbox-exec` shape is refused before anything starts, never guessed at.
    static func confinedCLI(executable: String, arguments: [String]) throws -> (wrapper: [String], arguments: [String]) {
        guard URL(fileURLWithPath: executable).lastPathComponent == "sandbox-exec" else { return ([], arguments) }
        guard arguments.count >= 3, ["-p", "-f"].contains(arguments[0]), !arguments[2].isEmpty, !arguments[2].hasPrefix("-") else {
            throw BackendSessionFailure.unsupported("This chat's folder boundary launch has an unexpected shape, so its AI was not started.")
        }
        return (Array(arguments.prefix(3)), Array(arguments.dropFirst(3)))
    }

    /// Whether Claude Code saved conversation `id` for this chat's folder (its `projects/<folder>/<id>.jsonl`);
    /// nil when that cannot be told, so the caller keeps resuming.
    static func claudeSaved(_ id: String, recipe: Recipe) -> Bool? {
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let configured = recipe.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let config = configured ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let name = String(recipe.cwd.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-" })
        let folder = URL(fileURLWithPath: config).appendingPathComponent("projects").appendingPathComponent(name)
        // A chat with its own config folder (every app-managed login) whose projects list lacks this folder saved
        // nothing here. Claude shortens very long folder names its own way; those, and the default home, stay unknown.
        guard FileManager.default.fileExists(atPath: folder.path) else {
            let projects = folder.deletingLastPathComponent().path
            return configured != nil && name.count <= 200 && FileManager.default.fileExists(atPath: projects) ? false : nil
        }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".jsonl").path)
    }

    /// The structured launch for the session's own arguments. A fresh Claude chat keeps the id the app gave the
    /// conversation; starting again resumes it (the CLI's own id when it has told us one).
    static func plan(_ recipe: Recipe, cliSession: String?, again: Bool, carrying: Bool = false) throws -> BackendHootChatLaunchPlan {
        switch recipe.provider {
        case .claude:
            var extra = claudeExtra(recipe.arguments)
            // A conversation carried over from another account or AI starts a clean CLI conversation; its first
            // message carries what was said (that account's own conversation files are not this one's).
            if carrying {
                return try BackendHootChatLaunchPlan(provider: .claude, cwd: recipe.cwd, sessionID: nil,
                                                     extra: withoutConversation(extra), pageServers: [], privateDirectory: nil)
            }
            // A fork Chat that has not yet recorded its own conversation ID must start again as the same fork
            // (--resume <parent> --fork-session). Resuming nothing would bring it back blank, losing the copied history.
            if again, let parent = forkParent(extra), cliSession == nil || cliSession == parent {
                return try BackendHootChatLaunchPlan(provider: .claude, cwd: recipe.cwd, sessionID: nil, extra: extra,
                                                     pageServers: [], privateDirectory: nil)
            }
            if again {
                extra = withoutConversation(extra)
                let resume = cliSession ?? recipe.conversation
                // 2 Nov (web v1): Claude saves a conversation only after its first message. A new chat restarted before
                // that (a model, mode or account change) has nothing to resume ("No conversation found with session ID"),
                // so it starts again under the same id instead of failing every later message.
                if let resume, claudeSaved(resume, recipe: recipe) == false {
                    return try BackendHootChatLaunchPlan(provider: .claude, cwd: recipe.cwd, sessionID: nil, extra: extra + ["--session-id", resume],
                                                         pageServers: [], privateDirectory: nil)
                }
                return try BackendHootChatLaunchPlan(provider: .claude, cwd: recipe.cwd, sessionID: resume, extra: extra,
                                                     pageServers: [], privateDirectory: nil)
            }
            return try BackendHootChatLaunchPlan(provider: .claude, cwd: recipe.cwd, sessionID: nil, extra: extra,
                                                 pageServers: [], privateDirectory: nil)
        case .codex, .gemini:
            // The thread or session to continue travels in the conversation's own handshake (its saved CLI id).
            return try BackendHootChatLaunchPlan(provider: recipe.provider, cwd: recipe.cwd, sessionID: nil,
                                                 extra: rpcExtra(recipe.arguments, provider: recipe.provider, keepSessionTools: recipe.sessionTools),
                                                 pageServers: [], privateDirectory: nil, sessionTools: recipe.sessionTools)
        }
    }

    /// Claude's terminal arguments in print mode: a skip-all-permissions launch becomes the same choice by name.
    static func claudeExtra(_ arguments: [String]) -> [String] {
        guard arguments.contains("--dangerously-skip-permissions") else { return arguments }
        var result = arguments.filter { $0 != "--dangerously-skip-permissions" }
        if let index = result.firstIndex(of: "--permission-mode"), index + 1 < result.count { result.removeSubrange(index...(index + 1)) }
        return result + ["--permission-mode", "bypassPermissions"]
    }
    /// The parent conversation of a Claude fork launch (`--resume <id> --fork-session`), or nil for any other launch.
    static func forkParent(_ arguments: [String]) -> String? {
        guard arguments.contains("--fork-session"),
              let index = arguments.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    /// Without the conversation it was started in (`--session-id`, `--resume`, `--continue`): a restart names it.
    static func withoutConversation(_ arguments: [String]) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if ["--session-id", "--resume", "-r"].contains(flag) { index += 2; continue }
            if ["--continue", "-c", "--fork-session"].contains(flag) { index += 1; continue }
            result.append(flag); index += 1
        }
        return result
    }
    /// Codex and Gemini: only the settings their app modes take (model, approvals, sandbox, instructions, tools);
    /// the terminal-only words (`resume --last`, a conversation id) stay out.
    static func rpcExtra(_ arguments: [String], provider: HootChatProvider, keepSessionTools: Bool = false) -> [String] {
        let paired: Set<String> = provider == .codex
            ? ["--model", "-m", "--sandbox", "-s", "--ask-for-approval", "-a", "--config", "-c", "--mcp-config", "--append-system-prompt", "--append-system-prompt-file"]
            : ["--model", "-m", "--approval-mode", "--policy", "--admin-policy", "--allowed-tools", "--allowed-mcp-server-names",
               "--mcp-config", "--append-system-prompt", "--append-system-prompt-file"]
        let single: Set<String> = provider == .gemini ? ["--sandbox", "-s", "--yolo", "-y"] : []
        var result: [String] = [], index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if single.contains(flag) { result.append(flag); index += 1; continue }
            if paired.contains(flag), index + 1 < arguments.count {
                let value = arguments[index + 1]
                // A team worker keeps the launcher's native tool lease and its per-tool restrictions.
                // Hoot's own launch still supplies its separate lease over the conversation pipe.
                if keepSessionTools || !(["--config", "-c"].contains(flag) && value.hasPrefix("mcp_servers")) { result += [flag, value] }
                index += 2; continue
            }
            index += 1
        }
        return result
    }
    /// The permission choice the session was started with, as the conversation engine answers prompts by it.
    static func permissionPolicy(provider: HootChatProvider, arguments: [String]) -> String? {
        func value(after flags: Set<String>) -> String? {
            guard let index = arguments.firstIndex(where: flags.contains), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        switch provider {
        case .claude:
            if arguments.contains("--dangerously-skip-permissions") { return "bypassPermissions" }
            return value(after: ["--permission-mode"])
        case .codex:
            return value(after: ["--sandbox", "-s"])
        case .gemini:
            if arguments.contains("--yolo") || arguments.contains("-y") { return "yolo" }
            return value(after: ["--approval-mode"])
        }
    }
    /// The conversation as plain lines, for whatever reads a session's screen (the newest 12 000 characters).
    static func plainText(_ snapshot: NativeRPCValue) -> String {
        var lines: [String] = []
        for event in snapshot["events"].elements ?? [] {
            let kind = event["kind"].string ?? event["record"]["kind"].string ?? ""
            let value = event["value"].fields != nil ? event["value"] : event["record"]["value"]
            guard let text = value["text"].string, !text.isEmpty else { continue }
            if kind == HootChatKind.user.rawValue { lines.append("You: " + text) }
            else if kind == HootChatKind.message.rawValue { lines.append(text) }
            else if kind == HootChatKind.error.rawValue { lines.append("! " + text) }
        }
        let joined = lines.joined(separator: "\n\n")
        return joined.count > 12_000 ? String(joined.suffix(12_000)) : joined
    }
}
