import Foundation
import TerminalDeckNativeCore

/// One app-owned durable conversation. No CLI transcript or terminal fallback.
public actor BackendHootChatStore {
    private final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (provider: HootChatProvider, conversation: String)
        init(provider: HootChatProvider, conversation: String) { value = (provider, conversation) }
        func read() -> (provider: HootChatProvider, conversation: String) { lock.withLock { value } }
        func set(provider: HootChatProvider, conversation: String) { lock.withLock { value = (provider, conversation) } }
    }
    public nonisolated var conversationID: String { identity.read().conversation }
    public nonisolated var provider: HootChatProvider { identity.read().provider }
    private nonisolated let identity: Identity
    private let initialFile: URL
    private let initialProvider: HootChatProvider
    private var file: URL
    private var rebinding = false
    private var events: [HootChatEvent]
    public func setSeenSequence(_ value: Int, conversation: String) throws {
        guard conversation == conversationID, value >= 0, value <= sequence else {
            throw NativeRPCError.invalidArguments("Choose a message in the current conversation.")
        }
    }
    private var reportedModel: String?
    public var currentModel: String? { reportedModel }
    private var effectivePolicyReceipt: NativeRPCValue = .null
    private var instructionReceipt: NativeRPCValue = .null
    /// Current-process receipt of the instruction files the provider loaded for this conversation (F62).
    public var providerInstructionReceipt: NativeRPCValue {
        guard process?.alive == true, instructionReceipt["provider"].string == provider.rawValue,
              instructionReceipt["providerConversationId"].string == sessionID, sessionID != nil else { return .null }
        return instructionReceipt
    }
    private var executionEvidence: NativeRPCValue = .null
    private var ownedTerminalOwner: BackendChatOwnedTerminals?
    private var ownedTerminalCleanup: Task<NativeRPCValue, Never>?
    private var ownedTerminalScopeRevision = UUID()
    private var ownedTerminalCursor = 0
    private var ownedTerminalWriters = 0
    /// Current-process provider evidence only. Historical policy journal records never establish
    /// the boundary of a restarted, changed-account or newly attached process.
    public var effectiveProviderPolicy: NativeRPCValue {
        if let hostedSnapshot { return hostedSnapshot["alive"].bool == true ? hostedSnapshot["effectivePolicy"] : .null }
        guard process?.alive == true, effectivePolicyReceipt["provider"].string == provider.rawValue,
              effectivePolicyReceipt["providerConversationId"].string == sessionID, sessionID != nil else { return .null }
        return effectivePolicyReceipt
    }
    /// Atomic backend-only scope. Neither launch secrets nor complete execution evidence
    /// cross the window/MCP boundary; only the facade's opaque scopeID and handles do.
    public func ownedTerminalScope(sessionID chatID: String) throws -> BackendChatOwnedTerminals.Scope {
        guard provider == .codex, process?.alive == true, initialization == nil, !rebinding, stopping == 0,
              ownedTerminalCleanup == nil, let sessionID, !sessionID.isEmpty, !chatID.isEmpty,
              let launch = providerLaunch, effectiveProviderPolicy.fields != nil,
              executionEvidence["providerConversationId"].string == sessionID else {
            throw NativeRPCError(code: "unavailable", message: "This Chat has no current, fully confirmed provider execution scope for an app-approved terminal.")
        }
        return .init(sessionID: chatID, conversation: sessionID, generation: generation, cwd: launch.cwd, launch: launch,
            effectivePolicy: effectiveProviderPolicy, executionEvidence: executionEvidence.setting("helperScopeRevision", .string(ownedTerminalScopeRevision.uuidString)))
    }
    public func ownedTerminalFeature(sessionID chatID: String, operation: String, arguments: NativeRPCValue,
                                     approval: BackendChatOwnedTerminals.AppApproval?) async throws -> NativeRPCValue {
        guard BackendChatOwnedTerminals.operations.contains(operation), ownedTerminalCleanup == nil else {
            throw NativeRPCError(code: "busy", message: "This Chat's owned terminal scope is closing or the action is unsupported.")
        }
        let scope = try ownedTerminalScope(sessionID: chatID)
        let owner: BackendChatOwnedTerminals
        if let current = ownedTerminalOwner { owner = current }
        else {
            let token = generation, revision = ownedTerminalScopeRevision
            owner = try BackendChatOwnedTerminals(scope: scope, onChange: { [weak self] in
                await self?.ownedTerminalsChanged(generation: token, revision: revision)
            })
            ownedTerminalOwner = owner
        }
        let result = try await owner.invoke(operation: operation, arguments: arguments, approval: approval)
        guard generation == scope.generation, ownedTerminalCleanup == nil, ownedTerminalOwner === owner else {
            throw NativeRPCError(code: "terminal-owner-changed", message: "The Chat's terminal owner changed during this action. Inspect its current state before retrying input.")
        }
        if operation == "list", let values = result["terminals"].elements { return result.setting("items", .array(values)) }
        return result
    }
    private func ownedTerminalsChanged(generation token: UUID, revision: UUID) async {
        guard generation == token, ownedTerminalScopeRevision == revision, let owner = ownedTerminalOwner else { return }
        let active = await owner.activeTerminalCount
        guard generation == token, ownedTerminalScopeRevision == revision, ownedTerminalOwner === owner else { return }
        ownedTerminalWriters = active; ownedTerminalCursor += 1; publish(reset: false)
    }
    @discardableResult public func closeOwnedTerminals(reason: String) async -> NativeRPCValue {
        if let closing = ownedTerminalCleanup { return await closing.value }
        guard let owner = ownedTerminalOwner else { return .object([.init("closed", .bool(true)), .init("terminals", .array([]))]) }
        ownedTerminalScopeRevision = UUID()
        let closing = Task { await owner.closeAll(reason: reason) }
        ownedTerminalCleanup = closing
        let result = await closing.value
        ownedTerminalOwner = nil; ownedTerminalCleanup = nil; ownedTerminalWriters = 0
        ownedTerminalCursor += 1; publish(reset: false)
        return result
    }
    private var sessionID: String?
    private var generation = UUID()
    private var hostedOwner: BackendHOSTChatClient?
    public private(set) var hostedSessionID: String?
    private var hostedSnapshot: NativeRPCValue?
    public func connectHosted(_ client: BackendHOSTClient, sessionID: String) async throws {
        let owner = BackendHOSTChatClient(client: client)
        hostedOwner = owner; hostedSessionID = sessionID
        try await owner.attach { [weak self] id, snapshot in
            guard id == sessionID else { return }
            await self?.receiveHosted(snapshot)
        }
        receiveHosted(try await owner.call("read", id: sessionID, fields: [.init("limit", .number(500))]))
    }
    private func receiveHosted(_ snapshot: NativeRPCValue) {
        hostedSnapshot = snapshot; reportedModel = snapshot["model"].string
        events = (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
        sequence = Int(snapshot["sequence"].number ?? 0)
        busy = snapshot["busy"].bool == true
        turnID = events.last?.turnID ?? ""
        if let id = snapshot["conversationId"].string { identity.set(provider: provider, conversation: id) }
        // The host's figure is for the current turn only; the last one is kept here until its conversation changes.
        if let tokens = snapshot["contextReading"]["tokens"].number, tokens > 0, let session = snapshot["providerConversationId"].string {
            lastContext = (tokens: Int(tokens), at: snapshot["contextReading"]["reportedAt"].number ?? Date().timeIntervalSince1970 * 1000, session: session)
        }
        for observer in observers.values { observer.yield(snapshot) }
        noteContextChange()
    }
    private var process: BackendHootChatProcess?
    /// Backend-owned launch only; never returned over the app/MCP wire.
    public private(set) var providerLaunch: BackendHootChatLaunch?
    private var providerFeatureEvents: [NativeRPCValue] = []
    private var providerFeatureCursor = 0
    /// Voice PCM stays in this bounded transient buffer, never the conversation journal.
    public func providerEvents(after cursor: Int) -> NativeRPCValue {
        let first = providerFeatureEvents.first?["sequence"].number.map(Int.init) ?? providerFeatureCursor + 1
        return .object([.init("cursor", .number(Double(providerFeatureCursor))),
            .init("droppedBefore", .number(Double(first - 1))),
            .init("events", .array(providerFeatureEvents.filter { ($0["sequence"].number ?? 0) > Double(cursor) }))])
    }
    private var launchDirectory: String?
    private var consumer: Task<Void, Never>?
    private var busy = false, turnID = "", sequence: Int
    private var pending: [String: HootChatRecord] = [:]
    private var answered: Set<String> = []
    private var observers: [UUID: AsyncStream<NativeRPCValue>.Continuation] = [:]
    private var steeringResponses: [String: CheckedContinuation<NativeRPCValue, Error>] = [:]
    private var contextKey: String?
    /// The context window the CLI itself reported for this AI (Claude's result, Codex's token usage). Kept in the
    /// chat file, so the quick settings can show the window really in use after a restart.
    private var appliedWindow: Int?
    /// Hoot changed AI or account and the new one has not had a message yet: the next message carries the
    /// conversation so far, word for word (Asad, 12 Oct: "the new AI will read the whole message history and it will
    /// start right from there without feeling that there is a change"). The name of the AI (or account) it took over from.
    private var handover: String?
    /// The person's last message whose answer the app's end cut off (found when this store opened at launch): Hoot
    /// carries on with it by itself once it is awake, once. Cleared when the person sends something else.
    private var pendingContinuation: (turn: String, text: String)?
    /// Why the next stop happens ("person": the Stop button; "quit": the app is closing), written on its interrupted line.
    private var stopReason: String?
    private var lastError: String?
    private var initializationID: String?
    private var initialization: CheckedContinuation<Void, Error>?
    /// Why the CLI quit, in the person's words, when it quit before it was ready: its handshake, whenever it is asked
    /// for, fails with this, never with a pipe error or a generic line (27 Oct).
    private var exitedWhileStarting: NativeRPCError?
    private var initializationTimeout: Task<Void, Never>?
    /// Current process evidence, never inferred from a saved conversation or a live PID.
    private var startupReceipt: NativeRPCValue = .null
    private var deliveryReceipt: NativeRPCValue = .null
    private var backgroundTasks: Set<String> = []
    private var completedTurn = false
    private var cliStatus: String?
    /// The commands the AI itself offers for the "/" menu: Claude's handshake (names, descriptions, hints) or its
    /// session start (names), Gemini's `available_commands_update`. Never a list of the app's own.
    private var commands: NativeRPCValue = .array([])
    /// The models Claude Code itself offers this account, from its handshake (`models`: alias, name, the model it means).
    private var cliModels: NativeRPCValue = .array([])
    /// What the model box offers when no list came through a login the app keeps (this Mac's own Claude Code sign-in).
    public var currentCLIModels: NativeRPCValue { cliModels }
    private var stopping = 0
    private var rpc: BackendHootChatRPC?
    private let consent: BackendDeckCoreSecurityConsentBroker?
    private let consentNow: @Sendable () -> Double
    private var consentOrigin = "window"
    /// The person's permission choice for this launch (Hoot settings or this chat). Edit modes
    /// answer file-edit prompts, bypass modes answer every tool prompt, without a card.
    private var permissionPolicy: String?
    public func setPermissionPolicy(_ mode: String?) { permissionPolicy = mode }
    /// A change made while Hoot is working applies at once: prompts waiting now that the new
    /// mode covers are answered (their cards withdrawn), and Claude Code switches its own mode live.
    public func applyPermissionPolicyNow(_ mode: String?, cliMode: String?) async {
        permissionPolicy = mode
        for (id, record) in pending where Self.autoAllows(mode: mode, provider: provider, request: record.value) {
            consentBindings.removeValue(forKey: id)?.cancellation.cancel()
            try? await sendAnswer(id: id, allowed: true)
        }
        if provider == .claude, let child = process, let cliMode {
            invalidateEffectivePolicy("A permission-mode change is waiting for provider confirmation.")
            try? await child.send(.object([.init("type", .string("control_request")), .init("request_id", .string(UUID().uuidString)),
                .init("request", .object([.init("subtype", .string("set_permission_mode")), .init("mode", .string(cliMode))]))]))
        }
    }
    /// What happened to the @ mentions of one message (who it was sent to, or why it could not be). A record no
    /// chat row shows by itself: the chat draws it under the message of that turn.
    public func noteReceipts(_ receipts: [NativeRPCValue], turn: String) {
        guard !receipts.isEmpty, events.contains(where: { $0.turnID == turn && $0.record.kind == .user }) else { return }
        let keep = turnID
        // Filed under the message's own turn, whatever Hoot is doing by now.
        turnID = turn
        try? append(.init(.session, value: .object([.init("receipts", .array(receipts))])))
        turnID = keep
    }
    /// A mentioned agent answered (L8's signal). Filed with the message whose receipt it belongs to, once per answer.
    public func noteAnswer(_ answer: NativeRPCValue) {
        guard let key = answer["receiptID"].string, !key.isEmpty,
              let turn = events.last(where: { event in
                  event.record.kind == .session && (event.record.value["receipts"].elements ?? []).contains { $0["receiptID"].string == key }
              })?.turnID,
              !events.contains(where: { event in
                  event.record.kind == .session && (event.record.value["answered"].elements ?? []).contains { $0["receiptID"].string == key && $0["commentID"] == answer["commentID"] }
              }) else { return }
        let keep = turnID
        turnID = turn
        try? append(.init(.session, value: .object([.init("answered", .array([answer]))])))
        turnID = keep
    }
    /// The @ mention deliveries in this chat that have no "answered" line yet (their receipt ids), so an answer that
    /// arrived while the app was closed can be drawn after the next start.
    public func receiptsWithoutAnswer() -> [String] {
        let answered = Set(events.flatMap { ($0.record.kind == .session ? $0.record.value["answered"].elements : nil) ?? [] }.compactMap { $0["receiptID"].string })
        let sent = events.flatMap { ($0.record.kind == .session ? $0.record.value["receipts"].elements : nil) ?? [] }
            .filter { $0["outcome"].string != "failed" }.compactMap { $0["receiptID"].string }
        var seen = Set<String>()
        return sent.filter { !answered.contains($0) && seen.insert($0).inserted }
    }
    // MARK: Set aside (a rewound part, a builder's test exchange)
    /// Parts taken out of the visible conversation. Nothing is deleted: each part stays in the chat file
    /// ({id, at, reason, events}) and can be put back.
    private var setAside: [NativeRPCValue] = []
    private func takeOut(_ gone: [HootChatEvent], reason: String) throws -> String {
        let id = UUID().uuidString.lowercased(), sequences = Set(gone.map(\.sequence))
        let before = events, parts = setAside
        events.removeAll { sequences.contains($0.sequence) }
        setAside.append(.object([.init("id", .string(id)), .init("at", .number(Date().timeIntervalSince1970 * 1000)), .init("reason", .string(reason)),
                                 .init("events", .array(gone.map(\.wireValue)))]))
        if setAside.count > 40 { setAside.removeFirst(setAside.count - 40) }
        // The CLI still remembers what was taken out: its next start is a clean desk built from what is left.
        sessionID = nil; deskTokens = 0; deskMeasuredTurn = ""
        do { try persist() } catch { events = before; setAside = parts; throw error }
        publish(reset: true)
        return id
    }
    private func requireQuiet() throws {
        guard !busy, !rebinding, !changingProviderHistory, initialization == nil, stopping == 0 else {
            throw NativeRPCError(code: "busy", message: "Hoot is in the middle of an answer. Try again when it has finished.")
        }
    }
    /// Takes whole exchanges out of the visible chat (the person's message, Hoot's answer and its steps).
    /// Returns how many exchanges went.
    public func setAsideExchanges(reason: String, where matches: @Sendable (String) -> Bool) async throws -> Int {
        try requireQuiet()
        let turns = Set(events.filter { $0.record.kind == .user && matches($0.record.value["text"].string ?? "") }.map(\.turnID))
        guard !turns.isEmpty else { return 0 }
        await stop()
        _ = try takeOut(events.filter { turns.contains($0.turnID) }, reason: reason)
        return turns.count
    }
    /// Takes whole turns out of the visible chat by their turn id (a builders' background test and its compact line).
    public func setAsideTurns(reason: String, where matches: @Sendable (String) -> Bool) async throws -> Int {
        try requireQuiet()
        let turns = Set(events.map(\.turnID).filter { !$0.isEmpty && matches($0) })
        guard !turns.isEmpty else { return 0 }
        await stop()
        _ = try takeOut(events.filter { turns.contains($0.turnID) }, reason: reason)
        return turns.count
    }
    /// Rewind: everything from this point on is set aside. `sequence` is the event the person chose: a message
    /// of theirs goes too (its text comes back for the message box); one of Hoot's stays and what follows goes.
    private var claudeResumeAt: String?
    private var changingProviderHistory = false
    private var forkHistoryPrefix = false
    public var needsClaudeMessageIDs: Bool { provider == .claude && events.contains { $0.provider == .claude && $0.record.kind == .message && $0.record.value["providerMessageId"].string == nil } }
    public func adoptClaudeMessageIDs(_ ids: [String: String]) throws {
        guard provider == .claude, !ids.isEmpty else { return }
        events = events.map { event in
            guard event.provider == .claude, event.record.kind == .message, event.record.value["providerMessageId"].string == nil,
                  let uuid = ids[event.record.messageID] else { return event }
            return .init(conversationID: event.conversationID, turnID: event.turnID, sequence: event.sequence, provider: event.provider,
                record: .init(event.record.kind, id: event.record.messageID, value: event.record.value.setting("providerMessageId", .string(uuid))), at: event.at)
        }
        try persist()
    }
    public var messageActionRows: [NativeRPCValue] { BackendChatMessageActions.rows(events, provider: provider) }
    public func forkPrefix(through sequence: Int) throws -> [HootChatEvent] {
        let boundary = try BackendChatMessageActions.boundary(sequence, events: events, provider: provider, action: "fork")
        let end = provider == .codex ? (events.last { $0.turnID == boundary["turnId"].string && $0.record.kind == .completed }?.sequence ?? sequence) : sequence
        return events.filter { $0.sequence <= end }
    }
    public func seedForkHistory(_ prefix: [HootChatEvent]) throws {
        try requireQuiet()
        guard !events.contains(where: { $0.record.kind == .user }), prefix.count <= 100_000 else {
            throw NativeRPCError(code: "busy", message: "The new fork already has messages. Its history was kept.")
        }
        events = prefix.map { .init(conversationID: conversationID, turnID: $0.turnID, sequence: $0.sequence, provider: $0.provider, record: $0.record, at: $0.at) }
        sequence = prefix.last?.sequence ?? 0; forkHistoryPrefix = true
        pendingContinuation = nil; handover = nil
        try persist(); publish(reset: true)
    }
    /// Project Chats use the AI's durable history. Hoot keeps its own reversible desk history below.
    public func rewindProvider(to sequence: Int) async throws -> (id: String, text: String) {
        try requireQuiet()
        let boundary = try BackendChatMessageActions.boundary(sequence, events: events, provider: provider, action: "rewind")
        guard let chosen = events.first(where: { $0.sequence == sequence }), let conversation = sessionID else {
            throw NativeRPCError(code: "unavailable", message: "This AI has no saved conversation to rewind.")
        }
        changingProviderHistory = true
        defer { changingProviderHistory = false }
        let token = generation
        if provider == .codex {
            _ = try await childRequest(method: "thread/revert", params: .object([
                .init("threadId", .string(conversation)), .init("beforeTurnId", boundary["providerTurnId"])]))
            guard token == generation else { throw NativeRPCError(code: "interrupted", message: "The AI changed while rewinding. Read its history before continuing.") }
        } else if provider == .claude {
            let previous = events.last { $0.sequence < sequence && $0.provider == .claude && $0.record.kind == .message && $0.record.value["providerMessageId"].string.flatMap(UUID.init(uuidString:)) != nil }
            // A first-message rewind starts a fresh provider conversation; no synthetic summary is sent.
            guard previous != nil || !events.contains(where: { $0.sequence < sequence && $0.record.kind == .user }) else {
                throw NativeRPCError(code: "unavailable", message: "The earlier Claude message was saved before its checkpoint ID was recorded. This conversation was kept.")
            }
            claudeResumeAt = previous?.record.value["providerMessageId"].string
            if previous == nil { sessionID = UUID().uuidString.lowercased() }
        }
        // Codex replaces its live thread history through thread/revert. Keeping that process also keeps its
        // correctly owned command scope; only Claude needs a resume-at launch.
        if provider != .codex { await stop() }
        events.removeAll { $0.sequence >= sequence }
        undoable = nil; handover = nil; pendingContinuation = nil
        deskTokens = 0; deskMeasuredTurn = ""
        try persist(); publish(reset: true)
        return (UUID().uuidString, chosen.record.value["text"].string ?? "")
    }
    public func rewind(to sequence: Int) async throws -> (id: String, text: String) {
        try requireQuiet()
        guard let chosen = events.first(where: { $0.sequence == sequence }) else {
            throw NativeRPCError.invalidArguments("That message is not in this chat any more.")
        }
        let own = chosen.record.kind == .user
        let cut = own ? sequence : (events.last { $0.turnID == chosen.turnID }?.sequence ?? sequence) + 1
        let gone = events.filter { $0.sequence >= cut }
        guard !gone.isEmpty else { throw NativeRPCError.invalidArguments("There is nothing after that message to rewind.") }
        await stop()
        let id = try takeOut(gone, reason: "rewind")
        undoable = id
        return (id, own ? chosen.record.value["text"].string ?? "" : "")
    }
    public func time(ofSequence sequence: Int) -> Double? { events.first { $0.sequence == sequence }?.at }
    /// The last rewind can be undone until the next message is sent.
    private var undoable: String?
    public var rewindToUndo: String? { undoable }
    public func undoRewind() async throws {
        try requireQuiet()
        guard let id = undoable, let index = setAside.firstIndex(where: { $0["id"].string == id }) else {
            throw NativeRPCError(code: "stale", message: "There is no rewind to undo any more.")
        }
        let back = try (setAside[index]["events"].elements ?? []).map(HootChatEvent.init(wire:))
        await stop()
        let before = events, parts = setAside
        events = (events + back).sorted { $0.sequence < $1.sequence }
        setAside.remove(at: index); undoable = nil; sessionID = nil
        do { try persist() } catch { events = before; setAside = parts; undoable = id; throw error }
        publish(reset: true)
    }
    /// The deck tools' own tiers (set at start from the security server), for tools that are not on the known read list.
    private var toolTier: (@Sendable (String) async -> BackendMCPTier?)?
    public func setToolTier(_ lookup: (@Sendable (String) async -> BackendMCPTier?)?) { toolTier = lookup }
    /// The deck tool a Claude Code request is about (the inner tool for tools_run), by wire name.
    /// The arguments the deck tool itself gets (inside tools_run: its own arguments).
    static func deckToolArguments(_ request: NativeRPCValue) -> NativeRPCValue {
        (request["name"].string ?? "") == "mcp__deck-control__tools_run" ? request["input"]["arguments"] : request["input"]
    }
    /// Words that only read. A tool whose own tier is a read can still change things by its verb (tasks_agents with
    /// do=save, hoot_island do=set, tasks_goals do=create): the app shows no cards any more (Asad, 11 Oct: "app itself will
    /// not ask any permissions at all it all depends on ai model settings directly"), so in Ask first Claude's own
    /// prompt has to ask for such a call. A read verb (or no verb) still never asks.
    static let readingVerbs: Set<String> = ["list", "get", "read", "search", "describe", "show", "status", "preview", "progress", "comments",
        "activity", "routine", "trash", "history", "diff", "look", "find", "summary", "state", "snapshot", "fetch", "description_history"]
    static func readingCall(_ arguments: NativeRPCValue) -> Bool {
        for key in ["do", "action", "op", "verb", "operation"] {
            if let word = arguments[key].string, !readingVerbs.contains(word) { return false }
        }
        return true
    }
    static func deckTool(provider: HootChatProvider, request: NativeRPCValue) -> String? {
        guard provider == .claude, request["subtype"].string == "can_use_tool" else { return nil }
        let server = "mcp__deck-control__", name = request["name"].string ?? ""
        guard name.hasPrefix(server) else { return nil }
        let tool = String(name.dropFirst(server.count))
        return tool == "tools_run" ? (request["input"]["name"].string ?? "").replacingOccurrences(of: ".", with: "_") : tool
    }
    private func settleDeckTool(_ record: HootChatRecord, read: Bool, id: String) async {
        guard pending[id] != nil, !answered.contains(id) else { return }
        if read {
            quietAnswers.insert(id)
            try? await sendAnswer(id: id, allowed: true)
        } else {
            try? append(record)
            issueConsent(record)
        }
    }
    /// Questions the app answered by itself: not shown, not recorded.
    private var quietAnswers: Set<String> = []
    /// A deck tool that only reads, called directly or through tools_run: it never asks.
    public static func readsOnly(provider: HootChatProvider, request: NativeRPCValue) -> Bool {
        guard provider == .claude, request["subtype"].string == "can_use_tool" else { return false }
        let server = "mcp__deck-control__", name = request["name"].string ?? ""
        guard name.hasPrefix(server) else { return false }
        var tool = String(name.dropFirst(server.count))
        if tool == "tools_run" { tool = (request["input"]["name"].string ?? "").replacingOccurrences(of: ".", with: "_") }
        return BackendHootChatCLI.readOnlyDeckTools.contains(tool)
    }
    // MARK: Task turns
    /// The task Hoot is working right now and the turn it belongs to.
    private var taskScope: (turn: String, id: String)?
    public var activeTurnID: String { turnID }
    /// The owner assigned this task, and that is the consent for the task's own tools on THIS task
    /// while its turn runs. Anything else still asks on screen.
    private func taskAllows(_ request: NativeRPCValue) -> Bool {
        guard let scope = taskScope, scope.turn == turnID, provider == .claude, request["subtype"].string == "can_use_tool" else { return false }
        return Self.taskToolAllowed(name: request["name"].string ?? "", input: request["input"], taskID: scope.id)
    }
    public static func taskToolAllowed(name: String, input: NativeRPCValue, taskID: String) -> Bool {
        let server = "mcp__deck-control__"
        guard name.hasPrefix(server) else { return false }
        var tool = String(name.dropFirst(server.count)), arguments = input
        // Reading what a tool takes changes nothing.
        if tool == "tools_describe" { return true }
        if tool == "tools_run" { tool = (input["name"].string ?? "").replacingOccurrences(of: ".", with: "_"); arguments = input["arguments"] }
        if ["tasks_get", "tasks_progress"].contains(tool) { return true }
        guard ["tasks_comment", "tasks_delegate", "tasks_verify", "tasks_review"].contains(tool), let named = arguments["task"].string else { return false }
        func bare(_ id: String) -> String { id.hasPrefix("local:") ? String(id.dropFirst(6)) : id }
        return bare(named) == bare(taskID)
    }
    /// Returns when Hoot is not in the middle of an answer (at once when it is idle).
    public func waitUntilIdle() async {
        guard busy else { return }
        for await snapshot in subscribe() where snapshot["busy"].bool != true { break }
    }
    public static let bypassModes: Set<String> = ["bypassPermissions", "danger-full-access", "yolo"]
    public static let editModes: Set<String> = ["acceptEdits", "workspace-write", "auto_edit"]
    /// Genuine questions/sign-in always reach the person; tagged MCP permissions follow the chosen mode.
    public static func autoAllows(mode: String?, provider: HootChatProvider, request: NativeRPCValue) -> Bool {
        guard !BackendChatQuestions.isQuestion(request), !BackendChatPlans.isReview(request) else { return false }
        if BackendChatApproval.isApproval(request), !BackendChatApproval.canApproveOnce(request) { return false }
        guard let mode else { return false }
        if provider == .codex, BackendChatElicitation.isToolApproval(request) { return bypassModes.contains(mode) }
        let subtype = request["subtype"].string ?? ""
        let permissionPrompt = provider == .claude ? subtype == "can_use_tool"
            : ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "session/request_permission"].contains(subtype)
        guard permissionPrompt else { return false }
        if bypassModes.contains(mode) { return true }
        guard editModes.contains(mode) else { return false }
        switch provider {
        case .claude: return ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(request["name"].string ?? "")
        case .codex: return subtype == "item/fileChange/requestApproval"
        case .gemini: return request["input"]["toolCall"]["kind"].string == "edit"
        }
    }
    private struct ConsentBinding {
        let nonce: String, turn: String, generation: UUID, cancellation: BackendMCPCancellation
        var answers = NativeRPCValue.object([])
        var deciding = false
    }
    private var consentBindings: [String: ConsentBinding] = [:]
    // Deck Memory (Hoot's desk): the app's few lines for each message, and how full the desk is.
    private var deskLines: (@Sendable (String, NativeRPCValue) async -> String)?
    private var deskTokens = 0, deskWindow: Int?, deskMeasuredTurn = ""
    private var contextReportedAt: Double?
    /// Item 74 (phones' session ring): the newest context figure and the AI conversation it belongs to, kept across
    /// turns and in the chat file. It counts only while that conversation is still Hoot's (a refresh, rewind, account
    /// or AI change starts another one), so a figure from an older conversation is never shown.
    private var lastContext: (tokens: Int, at: Double, session: String)?
    private var contextObserver: (@Sendable () -> Void)?
    private var observedContext: BackendHootContextFacts?
    /// Called once each time the context figure, its window, model or conversation changes (`BackendHootUsage`).
    public func setContextObserver(_ observer: (@Sendable () -> Void)?) { contextObserver = observer; observedContext = nil }
    /// What this chat knows about its own context window now; no events, cheap enough for every publish.
    public func contextFacts() -> BackendHootContextFacts {
        let conversation = hostedSnapshot.map { $0["providerConversationId"].string } ?? sessionID
        let current = lastContext.flatMap { last in conversation == last.session ? last : nil }
        let window = hostedSnapshot.map { ($0["contextReading"]["window"].number ?? $0["window"].number).map(Int.init) } ?? (deskWindow ?? appliedWindow)
        return .init(provider: hostedSnapshot?["provider"].string ?? provider.rawValue,
                     model: hostedSnapshot.map { $0["appliedModel"].string ?? $0["model"].string } ?? reportedModel,
                     tokens: current?.tokens, window: window, reportedAt: current?.at, conversation: conversation,
                     alive: hostedSnapshot?["alive"].bool ?? (alive || deskRefreshing))
    }
    private func noteContextChange() {
        guard let contextObserver else { return }
        let facts = contextFacts()
        guard facts != observedContext else { return }
        observedContext = facts
        contextObserver()
    }
    /// A rebuild (a rewind, a part taken out) is restarting the CLI: the chat keeps saying Hoot is there, because it is.
    private var deskRefreshing = false
    /// Hoot is about to be restarted on purpose (the safety guard holds again): the chat keeps saying it is there.
    public func holdAlive() { deskRefreshing = true; publish(reset: false) }
    /// "Safety guard is off: retrying" in Hoot's header while the app's guard on its own records is not held.
    private var guardOff: String?
    public func setGuardOff(_ reason: String?) {
        guard guardOff != reason else { return }
        guardOff = reason; publish(reset: false)
    }
    public func deskRefreshEnded() {
        guard deskRefreshing else { return }
        deskRefreshing = false; publish(reset: false)
    }
    public func setDesk(lines: (@Sendable (String, NativeRPCValue) async -> String)?) {
        deskLines = lines
    }
    /// The last messages of the visible chat, oldest first, as the person and Hoot wrote them.
    /// Where the conversation stops when it is cut at one message (that message included): its event, who wrote
    /// it, its first words and the time its last part was written.
    public func cut(at sequence: Int) -> (fromPerson: Bool, words: String, at: Double)? {
        guard let chosen = events.first(where: { $0.sequence == sequence }), [.user, .message, .textDelta].contains(chosen.record.kind) else { return nil }
        let parts = events.filter { $0.sequence == sequence || (!chosen.record.messageID.isEmpty && $0.turnID == chosen.turnID && $0.record.messageID == chosen.record.messageID) }
        let text = HootChatProjection.snapshotEvents(parts).last?.record.value["text"].string ?? ""
        let words = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return (chosen.record.kind == .user, String(words.prefix(80)) + (words.count > 80 ? "\u{2026}" : ""), parts.map(\.at).max() ?? chosen.at)
    }
    /// `through`: only the conversation up to and including the message at this event (a handoff "up to here").
    public func recentMessages(limit: Int = BackendHootDesk.tailMessages, through sequence: Int? = nil) -> [BackendHootDeskMessage] {
        var result: [BackendHootDeskMessage] = []
        var kept = events
        if let sequence, let chosen = events.first(where: { $0.sequence == sequence }) {
            kept = events.filter { $0.sequence <= sequence || (!chosen.record.messageID.isEmpty && $0.turnID == chosen.turnID && $0.record.messageID == chosen.record.messageID) }
        }
        // A background turn (a task, a handoff) is its own topic, not part of the conversation with the person.
        for event in HootChatProjection.snapshotEvents(kept).reversed() where result.count < limit && !event.turnID.hasPrefix(BackendHootBackgroundTurn.turnPrefix) {
            let record = event.record, text = record.value["text"].string ?? ""
            if record.kind == .user {
                let count = Int(record.value["attachmentCount"].number ?? 0), shown = text.isEmpty && count > 0 ? "[\(count) attachment\(count == 1 ? "" : "s")]" : text
                // A message the app itself sent in (a task, a routine) is the app's, not the person's.
                let kind = record.value["context"]["source"]["kind"].string ?? ""
                result.append(kind.isEmpty ? .init(fromPerson: true, text: shown) : .init(fromPerson: false, text: shown, label: "The app (\(kind))"))
            } else if record.kind == .message, !record.messageID.isEmpty, !record.messageID.hasPrefix("routing:") {
                result.append(.init(fromPerson: false, text: text))
            }
        }
        return result.reversed()
    }
    private let retainAllHistory: Bool
    /// The conversation was saved with its pictures inline and they are now files: its next save keeps the original
    /// as `chat.json.pre-media` first and is written to the disk before it replaces the file (Reviewer 28 Oct).
    private var convertedInline = false
    public init(file: URL, provider: HootChatProvider = .claude, consent: BackendDeckCoreSecurityConsentBroker? = nil,
                consentNow: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, retainAllHistory: Bool = false) throws {
        self.retainAllHistory = retainAllHistory
        self.file = file; initialFile = file; initialProvider = provider
        self.consent = consent; self.consentNow = consentNow
        let history = try Self.readHistory(file: file, provider: provider, retainAllHistory: retainAllHistory)
        identity = Identity(provider: provider, conversation: history.id)
        // 28 Oct: pictures saved inline by an earlier build are kept as files beside the conversation from now on;
        // the file itself is rewritten small at its next save (nothing is written here but the pictures).
        let media = Self.mediaFolder(file)
        events = history.events.map { BackendChatMedia.keep($0, in: media) }; sequence = history.events.last?.sequence ?? 0
        convertedInline = events != history.events
        sessionID = history.sessionID; contextKey = history.contextKey; setAside = history.setAside
        let savedBoundary = try? NativeRPCValue.parseJSON(Data(contentsOf: file))
        claudeResumeAt = savedBoundary?["claudeResumeAt"].string
        forkHistoryPrefix = savedBoundary?["forkHistoryPrefix"].bool == true
        appliedWindow = history.window; handover = history.handover; lastContext = history.lastContext
        // Opened at launch: an answer the app's last end cut off is carried on by itself once Hoot is awake.
        pendingContinuation = forkHistoryPrefix ? nil : Self.cutOffTurn(history.events, before: Date().timeIntervalSince1970 * 1000)
    }
    struct History { var id: String, events: [HootChatEvent], sessionID: String?, contextKey: String?, setAside: [NativeRPCValue], window: Int?, handover: String?
        var lastContext: (tokens: Int, at: Double, session: String)? = nil }
    /// The file's own provider must match (a file is one AI's), but the events in it may come from several AIs: the
    /// conversation the person sees travels with Hoot when it changes AI (Asad, 12 Oct). The CLI's own id never does.
    static func readHistory(file: URL, provider: HootChatProvider, retainAllHistory: Bool = false) throws -> History {
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            let value = try NativeRPCValue.parseJSON(bytes, maximumBytes: retainAllHistory ? max(bytes.count, historyByteLimit) : historyByteLimit)
            guard value["provider"].string == provider.rawValue else { throw NativeRPCError.malformed("Hoot's saved conversation belongs to another provider.") }
            let savedID = try value["conversationId"].requireString("conversationId", nonempty: true)
            let events = try (value["events"].elements ?? []).map(HootChatEvent.init(wire:))
            guard (retainAllHistory || events.count <= 4000), events.allSatisfy({ $0.conversationID == savedID }),
                  zip(events, events.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else { throw NativeRPCError.malformed("Hoot's saved events are inconsistent.") }
            return .init(id: savedID, events: events, sessionID: value["sessionId"].string, contextKey: value["contextKey"].string,
                         setAside: value["setAside"].elements ?? [], window: value["window"].number.map { Int($0) }, handover: value["handover"].string,
                         lastContext: value["contextReading"]["tokens"].number.flatMap { tokens in
                             value["contextReading"]["sessionId"].string.map { (tokens: Int(tokens), at: value["contextReading"]["at"].number ?? 0, session: $0) } })
        }
        return .init(id: UUID().uuidString.lowercased(), events: [], sessionID: nil, contextKey: nil, setAside: [], window: nil, handover: nil)
    }
    /// The person's last message (not a background turn, not one the app sent in) when the app's end cut its answer
    /// off: no "completed", not stopped by the person, not carried on before, last written before `before` and less
    /// than a day ago. nil otherwise.
    static func cutOffTurn(_ events: [HootChatEvent], before: Double) -> (turn: String, text: String)? {
        guard let cut = unanswered(events) else { return nil }
        guard let last = events.filter({ $0.turnID == cut.turn }).map(\.at).max(), last < before, before - last < 86_400_000 else { return nil }
        return cut
    }
    /// The person's last message when its answer never finished and nobody chose that: no "completed", not stopped by
    /// the person, not carried on before.
    static func unanswered(_ events: [HootChatEvent]) -> (turn: String, text: String)? {
        guard let user = events.last(where: { $0.record.kind == .user && !$0.turnID.hasPrefix(BackendHootBackgroundTurn.turnPrefix)
                && ($0.record.value["context"]["source"]["kind"].string ?? "").isEmpty }) else { return nil }
        let turn = events.filter { $0.turnID == user.turnID }
        guard !turn.contains(where: { $0.record.kind == .completed }),
              !turn.contains(where: { $0.record.kind == .interrupted && $0.record.value["by"].string == "person" }),
              !turn.contains(where: { $0.record.kind == .session && !$0.record.value["continued"].isNullish }),
              // A turn the AI itself failed (a usage limit, an API error) is not carried on by itself; only a cut is.
              !turn.contains(where: { $0.record.kind == .error && !restartLines.contains($0.record.value["text"].string ?? "") }) else { return nil }
        return (user.turnID, user.record.value["text"].string ?? "")
    }
    /// The chat's own lines when Hoot's program ended under it (a cut, not a failure of the AI).
    static let restartLines: Set<String> = ["Hoot stopped before finishing that answer. It is starting again.",
                                            "Hoot stopped unexpectedly and is starting again."]

    /// Same writer/subscriptions, different provider's OWN validated history.
    /// A malformed history is refused before disturbing the current owner.
    /// One plain line in the chat, never the same line twice in a row.
    private func noteOnce(_ text: String) {
        if let last = events.last, last.record.kind == .error, last.record.value["text"].string == text { return }
        try? append(.text(.error, text))
    }
    public func rebindProvider(_ next: HootChatProvider) async throws {
        guard next != provider else { return }
        guard !busy, !rebinding, initialization == nil, stopping == 0 else {
            throw NativeRPCError(code: "busy", message: "Hoot is still answering. Its AI will change after this turn finishes.")
        }
        let nextFile = next == initialProvider ? initialFile : initialFile.deletingLastPathComponent()
            .appendingPathComponent(next == .claude ? "chat.json" : "chat-\(next.rawValue).json")
        // What that AI's own file held: its measured window stays; another conversation it held is kept beside it.
        let saved = try? Self.readHistory(file: nextFile, provider: next)
        rebinding = true
        defer { rebinding = false }
        await stop()
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: nextFile.path), saved?.id != conversationID {
            _ = try Self.archive(nextFile, conversation: saved?.id ?? "unreadable")
        }
        // The SAME conversation goes on with the new AI (Asad, 12 Oct). Only the visible conversation travels: the CLI's
        // own conversation id belongs to one AI and is never handed to another (Codex resuming a Claude id failed with
        // "no rollout found", 11 Oct), so the new AI starts a clean desk and its next message carries the conversation.
        let before = (file: file, provider: provider, session: sessionID, context: contextKey, window: appliedWindow, handover: handover)
        let from = provider
        file = nextFile; sessionID = nil; contextKey = nil; appliedWindow = saved?.window
        lastError = nil; turnID = ""; completedTurn = false; cliStatus = nil; pendingContinuation = nil
        identity.set(provider: next, conversation: conversationID)
        decoder = HootChatDecoder(provider: next)
        if !events.isEmpty { handover = from.rawValue }
        do { try persist() } catch {
            file = before.file; sessionID = before.session; contextKey = before.context; appliedWindow = before.window; handover = before.handover
            identity.set(provider: before.provider, conversation: conversationID); decoder = HootChatDecoder(provider: before.provider)
            throw error
        }
        invalidateEffectivePolicy("The provider changed. Previous boundary receipts are historical.")
        publish(reset: true)
    }
    public var cliSessionID: String? { sessionID }
    /// An existing terminal conversation entering chat for the first time. Existing chat history wins.
    public func seedSessionConversation(_ id: String?) throws {
        guard sessionID == nil, !busy, process == nil, !handoverPending, let id, !id.isEmpty else { return }
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The conversation id is invalid.")
        }
        sessionID = id
        try persist()
    }
    /// A terminal conversation opened as chat. Its words stay visible, and are available if ACP cannot resume.
    public func seedTerminalHistory(_ pieces: [DeckMemoryFlowPiece], conversation: String?) throws {
        guard process == nil, !busy else { throw NativeRPCError.invalidArguments("Stop the terminal before handing over its conversation.") }
        let messages = pieces.filter { $0.role == .user || $0.role == .assistant }
        if !messages.isEmpty {
            events = []; sequence = 0; turnID = ""
            for (index, piece) in messages.enumerated() {
                if piece.role == .user || turnID.isEmpty { turnID = "terminal-" + String(index) }
                let kind: HootChatKind = piece.role == .user ? .user : .message
                try append(.init(kind, id: "terminal-message-" + String(index), value: .object([.init("text", .string(piece.text))])))
            }
            try append(.init(.completed, value: .object([])))
            turnID = ""; pendingContinuation = nil
        }
        sessionID = conversation
        handover = conversation == nil && !events.isEmpty ? provider.rawValue : nil
        try persist()
    }
    public var historyFileURL: URL { file }
    public var alive: Bool { hostedSnapshot?["alive"].bool ?? (process?.alive == true) }
    /// Why Hoot's CLI last ended (exit, crash, or a settings change), for the log.
    private var endReason: String?
    private var exitObserver: (@Sendable (String) async -> Void)?
    /// The runtime's supervisor hears every UNPLANNED end (exit or failure), never a stop it asked for.
    public func setExitObserver(_ observer: (@Sendable (String) async -> Void)?) { exitObserver = observer }
    public func noteEndReason(_ reason: String) { endReason = reason }
    public func takeEndReason() -> String? { defer { endReason = nil }; return endReason }
    public var processPID: Int32? { process?.processPID }
    public var isBusy: Bool { busy }
    /// The account and folder the next launch runs with. Another account (or folder) never borrows the old one's CLI
    /// conversation (its own id belongs to that account's login): that id is dropped, and the visible conversation
    /// carries on, handed to the new account with the next message (Asad, 12 Oct). Never throws any more.
    public func requireContext(_ key: String) throws {
        if let current = contextKey, current != key {
            sessionID = nil; deskTokens = 0; deskMeasuredTurn = ""
            claudeResumeAt = nil; forkHistoryPrefix = false
            if handover == nil, !events.isEmpty { handover = "account" }
        }
        contextKey = key
    }
    /// Hoot changed AI or account and its next message carries the conversation so far.
    public var handoverPending: Bool { handover != nil }
    public func attach(_ originalLaunch: BackendHootChatLaunch) async throws {
        let launch: BackendHootChatLaunch
        if provider == .claude, let at = claudeResumeAt {
            launch = .init(command: originalLaunch.command, arguments: originalLaunch.arguments + ["--resume-session-at=" + at],
                cwd: originalLaunch.cwd, environment: originalLaunch.environment, setup: originalLaunch.setup)
        } else { launch = originalLaunch }
        let requestedGeneration = generation
        try await BackendPCDecisionDelivery.verify()
        guard generation == requestedGeneration else { throw NativeRPCError(code: "interrupted", message: "The AI owner changed during launch validation.") }
        reportedModel = launch.setup?.session["model"].string
        guard process == nil, stopping == 0, !rebinding else { throw NativeRPCError.invalidArguments("Hoot's previous CLI process is still stopping.") }
        guard ownedTerminalOwner == nil, ownedTerminalCleanup == nil else { throw NativeRPCError(code: "busy", message: "The previous Chat-owned terminal scope is still closing.") }
        invalidateEffectivePolicy("A new provider process is starting. Previous boundary receipts are historical.")
        startupReceipt = .null; deliveryReceipt = .null
        commands = .array([])
        if provider != .claude {
            guard let setup = launch.setup else { throw NativeRPCError.invalidArguments("Hoot's RPC launch needs its backend-owned setup.") }
            rpc = BackendHootChatRPC(provider: provider, setup: setup)
        }
        let child = BackendHootChatProcess(), token = UUID()
        let environment = provider == .claude ? BackendHootChatCLI.planningEnvironment(launch.environment) : launch.environment
        generation = token
        providerFeatureEvents = []
        try await BackendPCDecisionDelivery.verifyFinal(.spawn)
        guard generation == token, process == nil, stopping == 0, !rebinding,
              ownedTerminalOwner == nil, ownedTerminalCleanup == nil else {
            throw NativeRPCError(code: "interrupted", message: "The AI owner changed before the validated process could start.")
        }
        try child.start(.init(command: launch.command, arguments: launch.arguments, cwd: launch.cwd, environment: environment, setup: launch.setup))
        launchDirectory = launch.cwd
        process = child; deskRefreshing = false; exitedWhileStarting = nil
        providerLaunch = launch
        consumer = Task { [weak self] in
            var lines = HootChatJSONLines(), stderr = Data()
            for await output in child.output {
                guard !Task.isCancelled else { break }
                do {
                    switch output {
                    case .stdout(let bytes):
                        for row in try lines.append(bytes) {
                            try await self?.receive(row, token: token)
                        }
                    case .stderr(let bytes): if stderr.count < 16_384 { stderr.append(bytes.prefix(16_384 - stderr.count)) }
                    case .exit(let code):
                        for row in try lines.append(Data(), end: true) {
                            try await self?.receive(row, token: token)
                        }
                        await self?.exited(token: token, code: code, diagnostic: String(data: stderr, encoding: .utf8) ?? "")
                    }
                } catch { await self?.failed(token: token, error: error); child.stop(); break }
            }
        }
        publish(reset: false)
    }
    private var decoder = HootChatDecoder(provider: .claude)
    private func receive(_ row: NativeRPCValue, token: UUID) async throws {
        guard generation == token else { return }
        if let id = row["id"].string, let waiter = steeringResponses.removeValue(forKey: id) {
            waiter.resume(returning: row); return
        }
        if let id = row["response"]["request_id"].string, let waiter = steeringResponses.removeValue(forKey: id) {
            waiter.resume(returning: row["response"]); return
        }
        if let feature = BackendChatProviderControls.notification(row, conversation: sessionID) {
            providerFeatureCursor += 1
            providerFeatureEvents.append(.object([.init("sequence", .number(Double(providerFeatureCursor))), .init("value", feature)]))
            if providerFeatureEvents.count > 64 { providerFeatureEvents.removeFirst(providerFeatureEvents.count - 64) }
            publish(reset: false)
            return
        }
        let initializing = initializationID.map { id in [id, id + ":session", id + ":session-new"].contains(row["id"].string ?? row["response"]["request_id"].string ?? "") } == true
        let scoped = provider == .claude
            ? row["parent_tool_use_id"].isNullish && (row["session_id"].isNullish || row["session_id"].string == sessionID)
            : sessionID != nil && (row["params"]["threadId"].string == sessionID || row["params"]["sessionId"].string == sessionID || row["params"]["thread"]["id"].string == sessionID)
        let reported = initializing || scoped ? row["model"].string ?? row["result"]["model"].string ?? row["params"]["thread"]["model"].string ?? row["response"]["response"]["model"].string : nil
        if let reported, !["default", "auto", ""].contains(reported.lowercased().replacingOccurrences(of: "[1m]", with: "")) { reportedModel = reported }
        if provider == .claude {
            if row["type"].string == "control_response" { controlResponse(row, token: token); return }
            let previousSession = sessionID
            for record in try decoder.decode(row) { try accept(record, token: token) }
            if let scope = previousSession ?? sessionID, let policy = BackendChatProviderPolicy.resolvedClaude(row, conversation: scope) {
                try accept(.init(.session, value: .object([.init("effectivePolicy", policy)])), token: token)
            }
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            let update = try adapter.receive(row); rpc = adapter
            if let evidence = update.executionEvidence { executionEvidence = evidence }
            if update.carryHistory {
                if provider == .gemini, events.isEmpty {
                    throw NativeRPCError.invalidArguments("Gemini cannot resume this conversation and its saved words could not be read. Keep using its terminal until it saves the conversation.")
                }
                if !events.isEmpty { handover = provider.rawValue }
            }
            for record in update.records { try accept(record, token: token) }
            for message in update.send {
                guard generation == token, let child = process else { return }
                try await child.send(message)
            }
            if update.ready && generation == token { finishInitialization(error: nil) }
        }
    }
    public func initialize() async throws {
        if hostedOwner != nil { return }
        try Task.checkCancellation()
        guard let child = process, initialization == nil else {
            // A CLI that quit at once may be handled before its handshake is asked for: its own reason, then.
            if process == nil, initialization == nil, let exitedWhileStarting { throw exitedWhileStarting }
            throw NativeRPCError(code: "unavailable", message: "Hoot's CLI initialization is unavailable.")
        }
        let id = UUID().uuidString, token = generation
        let request: NativeRPCValue
        if provider == .claude {
            request = .object([.init("type", .string("control_request")), .init("request_id", .string(id)),
                .init("request", .object([.init("subtype", .string("initialize")), .init("hooks", .null), .init("perTaskStopAffordance", .bool(true))]))])
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            request = try adapter.begin(id: id, resume: sessionID); rpc = adapter
        }
        // HOOTFIX: pinned to this actor (see BackendDeckCoreEventsHub.wait, crash 10:39) — the
        // driver reads processPID synchronously right after this returns.
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation(isolation: self) { continuation in
            initializationID = id; initialization = continuation
            Task {
                do { try await child.send(request) }
                catch {
                    // A CLI that has already quit: its exit (with what it printed) answers the handshake, not this pipe.
                    if child.alive { self.finishInitialization(error: error) }
                }
            }
            initializationTimeout = Task {
                // Codex initializes its subscribed plugins and MCP catalogue before it is ready.
                // An unreachable optional server can use its own 10-second startup timeout.
                do { try await Task.sleep(for: .seconds(provider == .codex ? 60 : 10)) } catch { return }
                guard token == generation else { return }
                finishInitialization(error: NativeRPCError(code: "timeout", message: "Hoot's CLI did not complete its structured handshake."))
            }
          }
        }, onCancel: { [weak self] in Task { await self?.stop() } }, isolation: self)
    }
    private func controlResponse(_ row: NativeRPCValue, token: UUID) {
        guard generation == token, row["response"]["request_id"].string == initializationID else { return }
        if row["response"]["subtype"].string == "success" {
            let offered = Self.offeredCommands(row["response"]["response"]["commands"])
            if !offered.isEmpty { commands = .array(offered) }
            let models = Self.offeredCLIModels(row["response"]["response"]["models"])
            if !models.isEmpty { cliModels = .array(models) }
            finishInitialization(error: nil)
        }
        else { finishInitialization(error: NativeRPCError(code: "unavailable", message: row["response"]["error"].string ?? "Hoot's CLI handshake failed.")) }
    }
    private func finishInitialization(error: Error?) {
        let waiting = initialization; initialization = nil; initializationID = nil
        initializationTimeout?.cancel(); initializationTimeout = nil
        if waiting != nil, error == nil {
            startupReceipt = .object([.init("ready", .bool(true)), .init("provider", .string(provider.rawValue)),
                .init("evidence", .string(provider == .claude ? "initialize-control-response" : "structured-session-ready")),
                .init("at", .number(Date().timeIntervalSince1970 * 1000))])
        }
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
    /// `background`: a turn the app starts for Hoot (a task, a handoff). No user bubble; the turn's own
    /// records (turn id "bg:<reason>:<id>:…") stay out of the visible conversation, except its one compact line.
    /// The AI is answering in the foreground: its own turn, or a turn the CLI started by itself (after a background
    /// task's notification it reports "running"). Background tasks alone are not an answer to interrupt.
    var foregroundWorking: Bool { busy && (!completedTurn || cliStatus == "running" || cliStatus == "requires_action") }
    public func say(_ text: String, attachments: [NativeRPCValue] = [], consentCaller: BackendDeckCoreSecurityCaller = .local,
                    messageContext: NativeRPCValue = .object([]), background: BackendHootBackgroundTurn? = nil,
                    validateSource: (@Sendable () async throws -> Void)? = nil, besideBackgroundTasks: Bool = false, clientMessageID: String? = nil) async throws -> NativeRPCValue {
        if let hostedOwner, let hostedSessionID {
            let clientMessageID = BackendChatDeliveryQueue.identity(clientMessageID)
            try await validateSource?()
            try await BackendPCDecisionDelivery.verify()
            let result = try await hostedOwner.call("say", id: hostedSessionID, fields: [.init("text", .string(text)),
                .init("attachments", .array(attachments)), .init("context", messageContext), .init("clientMessageId", .string(clientMessageID))])
            receiveHosted(result); return result
        }
        guard !rebinding, !changingProviderHistory else { throw NativeRPCError(code: "busy", message: "The AI conversation is changing. Keep this draft and send it again.") }
        guard initialization == nil else {
            throw NativeRPCError(code: "starting", message: "The AI is still starting. Wait for it to finish starting, then send the brief again. Nothing was sent.")
        }
        // Send now may go in beside background tasks that are still running (the CLI takes a message then).
        guard !busy || (besideBackgroundTasks && !foregroundWorking && pending.isEmpty) else {
            throw NativeRPCError(code: "busy", message: "Hoot is still answering. Stop it before sending another message.")
        }
        guard let process, process.alive else { throw NativeRPCError(code: "unavailable", message: "Start Hoot before sending a message.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              text.utf8.count <= 262_144, attachments.count <= 4 else { throw NativeRPCError.invalidArguments("Hoot needs a message of at most 256 KiB or up to four attachments.") }
        if consentCaller.kind == .remote, consentCaller.deviceID?.isEmpty != false { throw NativeRPCError.invalidArguments("Hoot needs the authenticated device caller.") }
        if consentCaller.kind == .key, consentCaller.keyID?.isEmpty != false { throw NativeRPCError.invalidArguments("Hoot needs the authenticated key caller.") }
        // Only documented Claude content blocks cross stdin. No local paths/URLs.
        try (rpc?.attachmentLimits ?? ChatAttachmentLimits(provider: provider.rawValue)).validate(attachments)
        for attachment in attachments {
            let source = attachment["source"]
            guard ["image", "document"].contains(attachment["type"].string ?? ""), source["type"].string == "base64",
                  let data = source["data"].string, Data(base64Encoded: data) != nil,
                  let media = source["media_type"].string,
                  ["image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf"].contains(media) else {
                throw NativeRPCError.invalidArguments("Unsupported Hoot attachment.")
            }
        }
        let token = generation
        let nextTurn = (background?.turnPrefix ?? "") + UUID().uuidString.lowercased()
        let context = try BackendHOOTSIMChatContext(wire: messageContext)
        let writtenText = try context.message(text)
        // The CLI must be able to take a message now; the real one is built once the app's own lines are known.
        if provider != .claude {
            guard var probe = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            _ = try BackendHootChatProcess.inputData(probe.user(writtenText, attachments: attachments, id: nextTurn, commandText: text))
        } else { _ = try BackendHootChatProcess.inputData(BackendHootChatCLI.user(writtenText, attachments: attachments)) }
        let previous = (rpc: rpc, turnID: turnID, completedTurn: completedTurn, pending: pending, answered: answered,
            lastError: lastError, undoable: undoable, continuation: pendingContinuation, taskScope: taskScope,
            consentOrigin: consentOrigin, cliStatus: cliStatus)
        turnID = nextTurn; busy = true; pending = [:]; answered = []; lastError = nil
        if background == nil { undoable = nil; pendingContinuation = nil }
        taskScope = background.flatMap { $0.reason == "task" ? (nextTurn, $0.id) : nil }
        consentOrigin = consentCaller.consentSurface
        completedTurn = false; cliStatus = nil
        do {
            // Reserve this turn before the asynchronous source check. Another
            // message cannot pass it; a stopped/replaced source is never queued.
            try await validateSource?()
            try Task.checkCancellation()
            // Deck Memory: a few lines from the app go with the message. The chat keeps only what was written.
            var hidden = await deskLines?(text, context.value) ?? ""
            guard token == generation, process.alive else { throw NativeRPCError(code: "interrupted", message: "Hoot changed before the message was accepted.") }
            // Hoot changed AI or account: this first message hands the new one the conversation so far, word for word.
            let handingOver = handover.flatMap { BackendHootHandover.text(from: $0, messages: recentMessages(limit: BackendHootHandover.maximumMessages)) }
            if let handingOver { hidden = DeckMemoryBrief.wrap(handingOver) + (hidden.isEmpty ? "" : "\n\n" + hidden) }
            let deliveredText = BackendHootDesk.deliver(hidden: hidden, message: writtenText)
            try await BackendPCDecisionDelivery.verify()
            guard token == generation, process.alive else { throw NativeRPCError(code: "interrupted", message: "Hoot changed during final execution validation.") }
            guard turnID == nextTurn else { throw NativeRPCError(code: "provider-turn-started", message: "The provider started its own turn before this message was sent. Keep the draft and wait or use Send now.") }
            let message: NativeRPCValue
            var nextAdapter: BackendHootChatRPC?
            if provider == .claude { message = BackendHootChatCLI.user(deliveredText, attachments: attachments, uuid: nextTurn) }
            else {
                guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
                message = try adapter.user(deliveredText, attachments: attachments, id: nextTurn, commandText: text); nextAdapter = adapter
            }
            // Check the FINAL envelope, including hidden desk/handover text, before its
            // journal record or the live adapter acquires this message.
            _ = try BackendHootChatProcess.inputData(message)
            try await BackendPCDecisionDelivery.verifyFinal(.input)
            guard token == generation, process.alive else { throw NativeRPCError(code: "interrupted", message: "The AI changed during final input validation.") }
            guard turnID == nextTurn else { throw NativeRPCError(code: "provider-turn-started", message: "The provider started another turn while input validation waited. Keep the draft and wait.") }
            if let nextAdapter { rpc = nextAdapter }
            if let background {
                // What Hoot was given is kept for the diary in a record no chat shows; it is the app's, not the person's.
                let about = NativeRPCValue.object([.init("reason", .string(background.reason)), .init("id", .string(background.id)), .init("title", .string(background.title))])
                try append(.init(.session, value: .object([.init("background", about.setting("brief", .string(text)))])))
                // And at most one compact line in the chat.
                if let line = background.chatLine {
                    try append(.init(.message, value: .object([.init("text", .string(line)), .init("background", about)])))
                }
            } else {
                try append(.init(.user, id: turnID, value: .object([.init("text", .string(text)), .init("attachmentCount", .number(Double(attachments.count))), .init("context", context.value)])))
            }
            if provider == .claude { decoder.beginTurn(id: nextTurn) }
            try await process.send(message)
            guard token == generation else { throw NativeRPCError(code: "interrupted", message: "Hoot was stopped while sending this message.") }
            // The new AI (or account) has had its first message: what it was handed is in its own conversation now.
            handover = nil
            if claudeResumeAt != nil || forkHistoryPrefix {
                claudeResumeAt = nil; forkHistoryPrefix = false; try persist()
            }
            try confirmDelivery(clientMessageID, turn: nextTurn)
            return snapshot()
        } catch {
            // A server turn can take the idle pipe while a source/desk check is suspended.
            // Reject this unsent message without killing the provider's now-visible work.
            if token == generation, turnID != nextTurn { throw error }
            if token == generation, ["provider-input-limit", "decision-held"].contains((error as? NativeRPCError)?.code ?? "") {
                rpc = previous.rpc; turnID = previous.turnID; completedTurn = previous.completedTurn
                pending = previous.pending; answered = previous.answered; lastError = previous.lastError
                undoable = previous.undoable; pendingContinuation = previous.continuation; taskScope = previous.taskScope
                consentOrigin = previous.consentOrigin; cliStatus = previous.cliStatus; busy = false
                publish(reset: false)
                throw error
            }
            await failed(token: token, error: error)
            throw error
        }
    }
    public func steer(_ text: String, attachments: [NativeRPCValue] = [], messageContext: NativeRPCValue = .object([]), clientMessageID: String? = nil) async throws -> NativeRPCValue {
        if let hostedOwner, let hostedSessionID {
            let result = try await hostedOwner.steer(hostedSessionID, text: text, attachments: attachments, context: messageContext, clientMessageID: BackendChatDeliveryQueue.identity(clientMessageID))
            receiveHosted(result); return result
        }
        guard busy else { return try await say(text, attachments: attachments, messageContext: messageContext, clientMessageID: clientMessageID) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              text.utf8.count <= 262_144, attachments.count <= 4 else { throw NativeRPCError.invalidArguments("Send a message of at most 256 KiB or four attachments.") }
        let token = generation
        if provider == .codex {
            guard let child = process, let adapter = rpc else { throw NativeRPCError(code: "unavailable", message: "Codex is not running.") }
            let context = try BackendHOOTSIMChatContext(wire: messageContext)
            let selectedTurn = turnID
            let id = UUID().uuidString
            let request = try adapter.steer(context.message(text), attachments: attachments, id: id)
            _ = try BackendHootChatProcess.inputData(request)
            let response: NativeRPCValue = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    steeringResponses[id] = continuation
                    Task {
                        do { try await child.send(request) }
                        catch { settleSteering(id, error: error) }
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(10))
                        settleSteering(id, error: NativeRPCError(code: "uncertain-steer", message: "Codex has not confirmed delivery. The message is held in the queue to avoid sending it twice."))
                    }
                }
            } onCancel: { Task { await self.settleSteering(id, error: CancellationError()) } }
            guard response["error"].isNullish else {
                throw NativeRPCError(code: "steer-rejected", message: response["error"]["message"].string ?? "Codex rejected the steering message.")
            }
            guard token == generation, response["result"]["turnId"].string == request["params"]["expectedTurnId"].string else {
                throw NativeRPCError(code: "uncertain-steer", message: "Codex did not confirm the intended turn. Your message is held in the queue.")
            }
            try append(.init(.user, id: id, value: .object([.init("text", .string(text)), .init("attachmentCount", .number(Double(attachments.count))), .init("context", context.value)])), turn: selectedTurn)
            try confirmDelivery(clientMessageID, turn: selectedTurn, evidence: "provider-steer-acknowledged")
            return snapshot()
        }
        // The verified Claude stream and Gemini ACP adapter have no native steer acknowledgement.
        if provider == .claude {
            let context = try BackendHOOTSIMChatContext(wire: messageContext)
            try ChatAttachmentLimits(provider: provider.rawValue).validate(attachments)
            _ = try BackendHootChatProcess.inputData(BackendHootChatCLI.user(context.message(text), attachments: attachments))
        } else if provider == .gemini {
            guard let adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            let context = try BackendHOOTSIMChatContext(wire: messageContext)
            try adapter.attachmentLimits.validate(attachments)
            _ = try BackendHootChatProcess.inputData(adapter.previewUser(context.message(text), attachments: attachments,
                id: UUID().uuidString, commandText: text))
        }
        // 29 Oct (Asad, Send now: "POSIX status 60"): with only background tasks running there is no answer to stop;
        // the message goes in now and the tasks keep running.
        if !foregroundWorking, pending.isEmpty {
            return try await say(text, attachments: attachments, messageContext: messageContext, besideBackgroundTasks: true, clientMessageID: clientMessageID)
        }
        markStop("person")
        try await interrupt()
        let updates = subscribe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await value in updates { if value["foreground"].bool != true, value["pending"].elements?.isEmpty != false { return } }
                try Task.checkCancellation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw NativeRPCError(code: "busy", message: "The AI has not confirmed the interruption. Your message stays queued.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        try Task.checkCancellation()
        guard token == generation, !foregroundWorking else { throw NativeRPCError(code: "busy", message: "The AI changed before it could accept the message.") }
        return try await say(text, attachments: attachments, messageContext: messageContext, besideBackgroundTasks: true, clientMessageID: clientMessageID)
    }
    /// A user journal row precedes the pipe write and is not a delivery receipt. Only a completed
    /// write (or Codex's steer acknowledgement) earns this ID, kept in the saved conversation.
    private func confirmDelivery(_ id: String?, turn: String, evidence: String = "stdin-write-completed") throws {
        // A completed write proves transport delivery, not that the model followed the brief.
        deliveryReceipt = .object([.init("state", .string(evidence == "stdin-write-completed" ? "written" : "acknowledged")),
            .init("evidence", .string(evidence)), .init("turnId", .string(turn)),
            .init("provider", .string(provider.rawValue)), .init("providerConversationId", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("afterReady", .bool(startupReceipt["ready"].bool == true)),
            .init("at", .number(Date().timeIntervalSince1970 * 1000))])
        var value = NativeRPCValue.object([.init("delivery", deliveryReceipt)])
        if let id { value = value.setting("clientMessageId", .string(id)).setting("deliveryConfirmed", .bool(true)) }
        try append(.init(.session, value: value), turn: turn)
    }
    private func settleSteering(_ id: String, error: Error) {
        steeringResponses.removeValue(forKey: id)?.resume(throwing: error)
    }
    /// Why the next stop happens: "person" (the Stop button) or "quit" (the app is closing).
    public func markStop(_ reason: String) { stopReason = reason }
    /// The cut-off answer to carry on with, taken once (nil when there is none, or the person sent something since).
    public func takeContinuation() -> (turn: String, text: String)? {
        // Taken: "resuming" ends now, and the chat hears it (its "Send again" line may show again).
        defer { if pendingContinuation != nil { pendingContinuation = nil; publish(reset: false) } }
        guard let cut = pendingContinuation, Self.unanswered(events)?.turn == cut.turn else { return nil }
        return cut
    }
    /// After a restart: Hoot carries on with the person's message whose answer the app's end cut off, in that same
    /// turn (no new bubble; what Hoot does and says lands under the person's message), told so in one app line.
    /// Once per message: a "continued" record marks it.
    public func continueCutOff(turn: String, text: String) async throws {
        guard !rebinding else { throw NativeRPCError(code: "busy", message: "Hoot is changing its AI.") }
        guard !busy else { throw NativeRPCError(code: "busy", message: "Hoot is already answering.") }
        guard let process, process.alive else { throw NativeRPCError(code: "unavailable", message: "Hoot is not awake yet.") }
        // Still the person's last message, still without an answer (they may have sent something else meanwhile).
        guard Self.unanswered(events)?.turn == turn else { return }
        let token = generation
        let line = BackendHootHandover.restartLine(text)
        var delivered = line
        if let from = handover, let handingOver = BackendHootHandover.text(from: from, messages: recentMessages(limit: BackendHootHandover.maximumMessages)) {
            delivered = BackendHootDesk.deliver(hidden: DeckMemoryBrief.wrap(handingOver), message: line)
        }
        let message: NativeRPCValue
        if provider == .claude { message = BackendHootChatCLI.user(delivered, attachments: []) }
        else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.user(delivered, attachments: [], id: UUID().uuidString.lowercased(), ownerTurnID: turn); rpc = adapter
        }
        turnID = turn; busy = true; pending = [:]; answered = []; lastError = nil
        taskScope = nil; consentOrigin = "window"; completedTurn = false; cliStatus = nil
        do {
            try append(.init(.session, value: .object([.init("continued", .string("restart"))])))
            if provider == .claude { decoder.beginTurn(id: turn) }
            try await process.send(message)
            guard token == generation else { throw NativeRPCError(code: "interrupted", message: "Hoot was stopped while carrying on.") }
            handover = nil
        } catch { await failed(token: token, error: error); throw error }
    }
    /// The same writer starts a fresh conversation and keeps the exact old
    /// history beside it. No second chat store, process or background work.
    public func newConversation() async throws -> NativeRPCValue {
        guard !busy, !rebinding, initialization == nil, stopping == 0 else {
            throw NativeRPCError(code: "busy", message: "Finish or stop Hoot's answer before starting a new chat.")
        }
        rebinding = true
        defer { rebinding = false }
        try Task.checkCancellation()
        let previousID = conversationID
        // Words still waiting for their batched write go into the copy too.
        if streamUnsaved { try persist() }
        var archive = file.deletingLastPathComponent().appendingPathComponent("chat-archive-" + previousID + ".json")
        if FileManager.default.fileExists(atPath: file.path) { archive = try Self.archive(file, conversation: previousID) }
        await stop()
        try Task.checkCancellation()
        let previousEvents = events, previousSequence = sequence, previousSession = sessionID, previousContext = contextKey
        events = []; sequence = 0; sessionID = nil; contextKey = nil; setAside = []; undoable = nil; handover = nil; pendingContinuation = nil; claudeResumeAt = nil; forkHistoryPrefix = false
        turnID = ""; lastError = nil; pending = [:]; answered = []; completedTurn = false; cliStatus = nil
        identity.set(provider: provider, conversation: UUID().uuidString.lowercased())
        do {
            try append(.init(.session, value: .object([.init("newChat", .bool(true))])))
            return snapshot().setting("archivedPath", .string(archive.path))
        } catch {
            events = previousEvents; sequence = previousSequence; sessionID = previousSession; contextKey = previousContext
            identity.set(provider: provider, conversation: previousID)
            throw error
        }
    }
    /// Authority is checked by the registered app/device route before this call.
    public func answer(id: String, allowed: Bool, answers: NativeRPCValue = .object([])) async throws {
        if let hostedOwner, let hostedSessionID {
            receiveHosted(try await hostedOwner.call("answer", id: hostedSessionID, fields: [.init("request", .string(id)), .init("allowed", .bool(allowed)), .init("answers", answers)])); return
        }
        if let plan = BackendChatPlans.pending(events: events, busy: busy, provider: provider), plan["requestId"].string == id {
            let decision = try BackendChatPlans.decision(answers, allowed: allowed)
            let text = decision == "approve" ? "Implement the approved plan." : decision == "revise" ? "/plan Revise the plan: " + (answers["feedback"].string ?? "") : "/plan Keep planning; do not implement yet."
            _ = try await say(text, messageContext: .object([.init("source", .object([.init("title", .string(DeckOwner.messageTitle))]))]))
            return
        }
        if let request = pending[id], BackendChatQuestions.isQuestion(request.value) || BackendChatPlans.isReview(request.value) || BackendChatElicitation.isRequest(request.value) {
            try await sendAnswer(id: id, allowed: allowed, answers: answers)
            return
        }
        if let consent {
            guard let binding = consentBindings[id] else { throw NativeRPCError(code: "stale-approval", message: "Hoot has no current issued confirmation for this request.") }
            guard let question = await consent.list().first(where: { $0.tool == "hoot.cli" && $0.arguments["hootBinding"].string == binding.nonce }) else {
                throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation has not been issued or has expired.")
            }
            try await answerBroker(id: question.id, allowed: allowed, by: "window", answers: answers)
            return
        }
        try await sendAnswer(id: id, allowed: allowed, answers: answers)
    }
    /// Phone/native adapters supply their authenticated surface after checking
    /// current access. Only a live Core-issued ID can find this private binding.
    public func answerBroker(id: String, allowed: Bool, by: String, answers: NativeRPCValue = .object([])) async throws {
        guard let consent, let question = await consent.list().first(where: { $0.id == id }), question.tool == "hoot.cli",
              question.expiresAt > consentNow(), let nonce = question.arguments["hootBinding"].string,
              let (cliID, binding) = consentBindings.first(where: { $0.value.nonce == nonce }),
              binding.generation == generation, binding.turn == turnID, !binding.deciding, pending[cliID] != nil, !answered.contains(cliID),
              await consent.mayAnswer(id: id, by: by) else {
            throw NativeRPCError(code: "stale-approval", message: "This is not a current, authorized Hoot confirmation.")
        }
        try await validateAnswer(id: cliID, allowed: allowed, answers: answers)
        guard consentBindings[cliID]?.nonce == nonce, consentBindings[cliID]?.deciding == false,
              question.expiresAt > consentNow(), binding.generation == generation, pending[cliID] != nil else {
            throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation changed while validating the answer.")
        }
        consentBindings[cliID]?.answers = answers
        consentBindings[cliID]?.deciding = true
        guard await consent.respond(id: id, approved: allowed, by: by) else {
            throw NativeRPCError(code: "stale-approval", message: "Hoot's confirmation was already settled.")
        }
    }
    private func validateAnswer(id: String, allowed: Bool, answers: NativeRPCValue) async throws {
        guard let request = pending[id] else { throw NativeRPCError(code: "stale-approval", message: "Hoot is no longer asking this question.") }
        if allowed { try await BackendChatElicitation.validate(request.value, answers: answers) }
        try BackendChatApproval.validate(request.value, allowed: allowed, answers: answers)
        if provider != .claude { _ = try rpc?.answer(request, allowed: allowed, answers: answers) }
    }
    private func sendAnswer(id: String, allowed: Bool, answers: NativeRPCValue = .object([])) async throws {
        guard busy, let request = pending[id], !answered.contains(id), let child = process else {
            throw NativeRPCError(code: "stale-approval", message: "This Hoot question is no longer waiting for an answer.")
        }
        let token = generation
        if allowed, BackendChatElicitation.isRequest(request.value) {
            try await BackendChatElicitation.validate(request.value, answers: answers)
            guard token == generation, pending[id] != nil, !answered.contains(id) else {
                throw NativeRPCError(code: "stale-approval", message: "This form is no longer waiting for an answer.")
            }
        }
        let message: NativeRPCValue
        var planFeedback: String?
        if BackendChatPlans.isReview(request.value) {
            let decision = try BackendChatPlans.decision(answers, allowed: allowed)
            if decision == "revise" { planFeedback = "Revise the plan before implementing: " + (answers["feedback"].string ?? "") }
            if decision == "continue" { planFeedback = "Keep planning. Do not implement yet." }
            if decision == "approve", permissionPolicy == "plan" { await applyPermissionPolicyNow(nil, cliMode: "default") }
        }
        if allowed { try BackendChatQuestions.validate(request.value, answers: answers) }
        try BackendChatApproval.validate(request.value, allowed: allowed, answers: answers)
        if provider == .claude {
            guard ["can_use_tool", "elicitation"].contains(request.value["subtype"].string ?? ""), request.value["input"].fields != nil else {
                throw NativeRPCError.invalidArguments("This Hoot request cannot be approved as a tool call.")
            }
            if BackendChatElicitation.isRequest(request.value) {
                message = BackendHootChatCLI.elicitation(id: id, allowed: allowed,
                    content: allowed && request.value["input"]["mode"].string != "url" ? answers : nil)
            } else {
                let input = BackendChatQuestions.isQuestion(request.value) && allowed ? request.value["input"].setting("answers", answers) : request.value["input"]
                let comment = answers["comment"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let scope = answers["scope"].string ?? "once"
                let updates = BackendChatApproval.updates(request.value, scope: scope)
                message = BackendHootChatCLI.approval(id: id, allowed: allowed, input: input,
                    message: planFeedback ?? (comment?.isEmpty == false ? comment : nil),
                    updatedPermissions: allowed && BackendChatApproval.isApproval(request.value) && !updates.isEmpty ? .array(updates) : nil)
            }
        } else {
            guard let adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.answer(request, allowed: allowed, answers: answers)
        }
        answered.insert(id); pending[id] = nil
        do {
            try await child.send(message)
            guard token == generation else { throw NativeRPCError(code: "stale-approval", message: "Hoot stopped before this answer arrived.") }
            if quietAnswers.remove(id) == nil { try append(.init(.approvalResolved, id: id, value: .object([.init("allowed", .bool(allowed))]))) }
        } catch { await failed(token: token, error: error); throw error }
    }
    public func interrupt() async throws {
        if let hostedOwner, let hostedSessionID {
            if let snapshot = hostedSnapshot, snapshot["provider"].string == "claude", snapshot["foregroundStopPreservesChildren"].bool != true,
               ChatChildTasks.list((try? (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))) ?? []).contains(where: ChatChildTasks.running) {
                throw NativeRPCError(code: "helper-upgrade-required", message: "This helper needs an update before Stop can preserve background tasks. The helper was not restarted.")
            }
            receiveHosted(try await hostedOwner.call("interrupt", id: hostedSessionID)); return
        }
        guard foregroundWorking, let child = process else { return }
        // The CLI cancels only foreground permission requests and reports their cancellation;
        // denying every pending request here would also cancel a background agent's work.
        let message: NativeRPCValue
        if provider == .claude {
            message = .object([.init("type", .string("control_request")), .init("request_id", .string(UUID().uuidString)),
                .init("request", .object([.init("subtype", .string("interrupt"))]))])
        } else {
            guard var adapter = rpc else { throw NativeRPCError.malformed("Missing Hoot RPC adapter.") }
            message = try adapter.interrupt(); rpc = adapter
        }
        try await child.send(message)
    }
    public func stopChild(_ id: String) async throws -> NativeRPCValue {
        if let hostedOwner, let hostedSessionID { return try await hostedOwner.call("child-stop", id: hostedSessionID, fields: [.init("taskId", .string(id))]) }
        guard let task = ChatChildTasks.list(events).first(where: { $0["id"].string == id }), ChatChildTasks.running(task) else {
            throw NativeRPCError.invalidArguments("Choose a running task from this conversation.")
        }
        if provider == .claude {
            _ = try await childRequest(method: "stop_task", params: .object([.init("task_id", .string(id))]))
        } else if provider == .codex, let thread = task["threadId"].string {
            let read = try await childRequest(method: "thread/read", params: .object([.init("threadId", .string(thread)), .init("includeTurns", .bool(true))]))
            guard let turn = read["thread"]["turns"].elements?.last(where: { ["inProgress", "in_progress"].contains($0["status"].string ?? "") }), let turnID = turn["id"].string else {
                throw NativeRPCError.invalidArguments("That agent has no running turn.")
            }
            _ = try await childRequest(method: "turn/interrupt", params: .object([.init("threadId", .string(thread)), .init("turnId", .string(turnID))]))
        } else { throw NativeRPCError(code: "unavailable", message: "This AI has not exposed a separate stop for this task.") }
        // Keep the CLI's terminal notification authoritative, including a stop that raced completion.
        if let current = ChatChildTasks.list(events).first(where: { $0["id"].string == id }), ChatChildTasks.running(current) {
            try append(.init(.session, value: .object([.init("childTask", task.setting("status", .string("stopping")))])))
        }
        publish(reset: false)
        return snapshot()
    }
    /// Review owns a normal tracked foreground turn. A direct control RPC would lose the
    /// review's output because it would have no adapter turn ID when notifications arrive.
    public func startProviderReview(arguments: NativeRPCValue, cwd: String) async throws -> NativeRPCValue {
        try requireQuiet()
        guard provider == .codex, hostedOwner == nil, let child = process, child.alive, var adapter = rpc else {
            throw NativeRPCError(code: "unavailable", message: "Start this Codex conversation before reviewing it.")
        }
        let token = generation, nextTurn = UUID().uuidString.lowercased()
        let request = try adapter.review(arguments: arguments, id: nextTurn)
        rpc = adapter; turnID = nextTurn; busy = true; pending = [:]; answered = []
        lastError = nil; completedTurn = false; cliStatus = nil
        undoable = nil; pendingContinuation = nil; taskScope = nil
        do {
            try append(.init(.user, id: nextTurn, value: .object([.init("text", .string("/review")),
                .init("reviewTarget", request["params"]["target"]), .init("cwd", .string(cwd))])))
            try await child.send(request)
            guard generation == token else { throw NativeRPCError(code: "interrupted", message: "The AI changed while starting this review.") }
            return snapshot()
        } catch { await failed(token: token, error: error); throw error }
    }
    /// F29: the Claude messages this conversation sent with their own ID (the ID a file checkpoint is named by).
    public func fileCheckpointRows() -> [NativeRPCValue] {
        guard provider == .claude else { return [] }
        return events.compactMap { event -> NativeRPCValue? in
            guard event.provider == .claude, event.record.kind == .user, UUID(uuidString: event.turnID) != nil else { return nil }
            return .object([.init("turnId", .string(event.turnID)), .init("messageUuid", .string(event.turnID)),
                .init("text", .string(String((event.record.value["text"].string ?? "").prefix(400))))])
        }
    }
    /// F38: the turns that belong to this conversation, so a fork can only be cut at one of them. Each app turn ID
    /// maps to the provider's own turn ID recorded when that turn completed ("" when none was recorded), because
    /// Codex's thread/fork accepts only IDs Codex issued.
    public func forkTurnIDs() -> [String: String] {
        var turns: [String: String] = [:]
        for event in events where event.provider == provider && !event.turnID.isEmpty && (event.record.kind == .user || event.record.kind == .completed) {
            if turns[event.turnID] == nil { turns[event.turnID] = "" }
            if event.record.kind == .completed, let id = event.record.value["id"].string, !id.isEmpty { turns[event.turnID] = id }
        }
        return turns
    }
    /// True when nothing is being answered, restarted or stopped: file restores and forks wait for this.
    public var isQuietForFeatures: Bool { !busy && !rebinding && !changingProviderHistory && initialization == nil && stopping == 0 && process?.alive == true }
    /// A compact line in the chat saying which files were put back; the conversation itself is untouched.
    public func recordFileRestore(_ summary: String) {
        try? append(.init(.message, value: .object([.init("text", .string(summary)), .init("fileRestore", .bool(true))])))
    }
    /// Internal typed feature adapters share the live pipe and its generation-bound reply waiters.
    /// Public app doors expose named feature operations, never arbitrary provider methods.
    public func providerRequest(method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        let policyChange = provider == .codex && method == "thread/resume" || provider == .claude && method == "set_permission_mode"
        if provider == .codex, method == "thread/resume" {
            guard let sessionID, params["threadId"].string == sessionID else { throw NativeRPCError.invalidArguments("A policy change must target this exact provider conversation.") }
        }
        if policyChange {
            try requireQuiet()
            _ = await closeOwnedTerminals(reason: "The parent provider policy is changing")
            try requireQuiet()
            invalidateEffectivePolicy("A provider policy change is waiting for confirmation.")
        }
        // A real file restore (not its dry-run preview) must not overlap a turn, even one that began after the caller's own check.
        if provider == .claude, method == "rewind_files", params["dry_run"].bool == false { try requireQuiet() }
        let token = generation, scope = sessionID
        let result = try await childRequest(method: method, params: params)
        guard token == generation else { throw NativeRPCError(code: "interrupted", message: "The provider changed before its policy receipt could be recorded.") }
        if let scope, scope == sessionID {
            if provider == .codex, method == "thread/resume" {
                executionEvidence = BackendChatOwnedTerminals.executionEvidence(result, conversation: scope, source: method) ?? .null
            }
            let policy = provider == .codex && method == "thread/resume"
                ? BackendChatProviderPolicy.resolvedSession(result, provider: provider, conversation: scope, source: method)
                : provider == .claude && method == "set_permission_mode" ? BackendChatProviderPolicy.resolvedClaudeMode(result, conversation: scope) : nil
            if let policy { try accept(.init(.session, value: .object([.init("effectivePolicy", policy)])), token: token) }
        }
        return result
    }
    private func childRequest(method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        guard let child = process, child.alive else { throw NativeRPCError(code: "unavailable", message: "This AI is not running.") }
        let id = UUID().uuidString, token = generation
        let request: NativeRPCValue = provider == .claude
            ? .object([.init("type", .string("control_request")), .init("request_id", .string(id)), .init("request", params.setting("subtype", .string(method)))])
            : .object([.init("jsonrpc", .string("2.0")), .init("id", .string(id)), .init("method", .string(method)), .init("params", params)])
        let response: NativeRPCValue = try await withCheckedThrowingContinuation { continuation in
            steeringResponses[id] = continuation
            Task { do { try await child.send(request) } catch { settleSteering(id, error: error) } }
            Task {
                try? await Task.sleep(for: .seconds(10))
                settleSteering(id, error: NativeRPCError(code: "provider-request-timeout", message: "The AI has not confirmed this request. Read its current state before retrying a change."))
            }
        }
        guard generation == token else { throw NativeRPCError(code: "interrupted", message: "This AI changed during the task request.") }
        guard response["error"].isNullish, response["subtype"].string != "error" else {
            throw NativeRPCError(code: "task-request-failed", message: response["error"].string ?? response["error"]["message"].string ?? "The AI refused this task request.")
        }
        return provider == .claude ? response["response"] : response["result"]
    }
    public func stop() async {
        if let hostedOwner, let hostedSessionID {
            _ = try? await hostedOwner.call("close", id: hostedSessionID)
            hostedOwner.detach(); self.hostedOwner = nil; self.hostedSessionID = nil
            hostedSnapshot = hostedSnapshot?.setting("alive", .bool(false)).setting("busy", .bool(false)).setting("effectivePolicy", .null); busy = false
            publish(reset: false); return
        }
        _ = await closeOwnedTerminals(reason: "The parent Chat is stopping")
        cancelConsentBindings()
        finishInitialization(error: NativeRPCError(code: "interrupted", message: "Hoot's CLI initialization was stopped."))
        generation = UUID(); let child = process; process = nil
        startupReceipt = .null
        invalidateEffectivePolicy("The provider process stopped. No current boundary is confirmed.")
        rpc = nil; decoder = HootChatDecoder(provider: .claude)
        consumer?.cancel(); consumer = nil
        pending = [:]; answered = []; backgroundTasks = []; cliStatus = nil; let wasBusy = busy; busy = false
        // Who stopped it: the person (their Stop) or the app closing. A cut by the app carries on after the next start.
        let reason = stopReason; stopReason = nil
        if wasBusy { try? append(.init(.interrupted, value: reason.map { .object([.init("by", .string($0))]) } ?? .null)) }
        publish(reset: false)
        if let child { stopping += 1; await child.stopAndWait(); stopping -= 1 }
    }
    public func snapshot(after cursor: Int? = nil, limit: Int = 200) -> NativeRPCValue {
        if let hostedSnapshot { return hostedSnapshot }
        let bounded = min(500, max(1, limit))
        let reset = cursor == nil || (cursor ?? 0) < (events.first?.sequence ?? 1) - 1 || (cursor ?? 0) > sequence
        let slice = reset ? Array(Self.projectedRoutingHistory(events).suffix(bounded)) : Array(events.filter { $0.sequence > (cursor ?? 0) }.prefix(bounded))
        let plan = BackendChatPlans.pending(events: events, busy: busy, provider: provider)
        let applied = Self.appliedModelReceipt(events: events, provider: provider, sessionID: sessionID, turn: turnID)
        return .object([.init("conversationId", .string(conversationID)), .init("providerConversationId", sessionID.map(NativeRPCValue.string) ?? .null), .init("provider", .string(provider.rawValue)), .init("model", reportedModel.map(NativeRPCValue.string) ?? .null),
            .init("startup", startupReceipt), .init("delivery", deliveryReceipt),
            .init("appliedModel", applied["model"].string.map(NativeRPCValue.string) ?? .null), .init("appliedModelReceipt", applied),
            .init("effectivePolicy", effectiveProviderPolicy),
            .init("messageActions", .array(messageActionRows)), .init("forkPrefix", .bool(forkHistoryPrefix)),
            .init("ownedTerminalCursor", .number(Double(ownedTerminalCursor))), .init("ownedTerminalWriters", .number(Double(ownedTerminalWriters))),
            .init("attachmentLimits", (rpc?.attachmentLimits ?? ChatAttachmentLimits(provider: provider.rawValue)).wire),
            .init("foregroundStopPreservesChildren", .bool(true)),
            .init("providerFeatureCursor", .number(Double(providerFeatureCursor))),
            .init("answering", .bool(busy && !completedTurn)), .init("foreground", .bool(foregroundWorking)),
            .init("children", .array(ChatChildTasks.list(events))),
            .init("reset", .bool(reset)), .init("events", .array(slice.map(\.wireValue))),
            .init("cursor", .number(Double(slice.last?.sequence ?? cursor ?? sequence))), .init("sequence", .number(Double(sequence))),
            .init("hasMore", .bool((slice.last?.sequence ?? cursor ?? sequence) < (events.last?.sequence ?? 0))),
            .init("alive", .bool(alive || deskRefreshing)), .init("busy", .bool(busy)),
            .init("rewound", undoable.map(NativeRPCValue.string) ?? .null),
            .init("guardOff", guardOff.map(NativeRPCValue.string) ?? .null),
            // The context window the CLI reported for this AI, and whether a cut-off answer will carry on by itself.
            .init("window", appliedWindow.map { .number(Double($0)) } ?? .null),
            .init("contextReading", BackendCodexChatCommands.contextReading(tokens: deskMeasuredTurn == turnID ? deskTokens : 0,
                window: deskWindow ?? appliedWindow, reportedAt: contextReportedAt, sessionID: sessionID)),
            .init("resuming", .bool(pendingContinuation != nil)),
            .init("cliUsage", ChatReportedUsage.latest(events)),
            .init("pending", .array(pending.keys.sorted().compactMap { pending[$0]?.value }.map { request in
                BackendChatApproval.isApproval(request) ? request.setting("approvalDetails", BackendChatApproval.details(request)) : request
            } + (plan.map { [$0] } ?? []))),
            .init("todos", .array(BackendChatTodos.list(events))),
            .init("thoughts", .array(BackendChatThoughts.summaries(events))),
            .init("commands", commands),
            .init("problem", lastError.map(NativeRPCValue.string) ?? .null),
            .init("unread", ChatReadCompatibility.empty(sequence: sequence))])
    }
    /// The current (or restored latest) turn's provider receipt, never its saved selection.
    static func appliedModelReceipt(events: [HootChatEvent], provider: HootChatProvider, sessionID: String?, turn: String) -> NativeRPCValue {
        guard let sessionID else { return .null }
        let owner = turn.isEmpty ? events.last(where: { $0.record.kind == .user || $0.record.kind == .completed || $0.record.value["providerTurnStarted"].fields != nil })?.turnID : turn
        guard let owner, !owner.isEmpty else { return .null }
        return events.last(where: { event in
            event.provider == provider && event.turnID == owner && event.record.kind == .session &&
                event.record.value["appliedModelReceipt"]["providerSessionId"].string == sessionID &&
                event.record.value["appliedModelReceipt"]["model"].string != nil
        })?.record.value["appliedModelReceipt"] ?? .null
    }
    /// `[{name, description?, argumentHint?}]` from what a CLI reported (objects, or bare names), "/" dropped.
    /// Claude Code's own model choices from its handshake: its alias ("opus", taken back by `--model`), its name
    /// ("Opus"), the model it means now and its one line. "Default" is no choice (the box shows what is really used).
    static func offeredCLIModels(_ raw: NativeRPCValue) -> [NativeRPCValue] {
        var seen = Set<String>()
        return (raw.elements ?? []).prefix(64).compactMap { row in
            guard let id = row["value"].string, BackendSharedText.matches(id, #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,99}$"#),
                  !["default", "auto"].contains(id.lowercased().replacingOccurrences(of: "[1m]", with: "")), seen.insert(id).inserted else { return nil }
            let name = (row["displayName"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var model = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(name.isEmpty || name.count > 80 ? id : name))])
            if let resolved = row["resolvedModel"].string, BackendSharedText.matches(resolved, #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,119}$"#) {
                model = model.setting("resolvedModel", .string(resolved))
            }
            if let about = row["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                model = model.setting("description", .string(String(about.prefix(200))))
            }
            return model
        }
    }
    static func offeredCommands(_ raw: NativeRPCValue) -> [NativeRPCValue] {
        var seen = Set<String>()
        return (raw.elements ?? []).compactMap { row in
            let name = (row.string ?? row["name"].string ?? "").trimmingCharacters(in: .whitespaces)
            let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
            guard !bare.isEmpty, bare.count <= 80, seen.insert(bare).inserted else { return nil }
            var value = NativeRPCValue.object([.init("name", .string(bare))])
            if let description = row["description"].string, !description.isEmpty { value = value.setting("description", .string(String(description.prefix(200)))) }
            if let hint = row["argumentHint"].string ?? row["argument_hint"].string, !hint.isEmpty { value = value.setting("argumentHint", .string(String(hint.prefix(80)))) }
            return value
        }
    }
    public func subscribe() -> AsyncStream<NativeRPCValue> {
        let id = UUID(), pair = AsyncStream<NativeRPCValue>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(snapshot(limit: 500))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    nonisolated static func projectedRoutingHistory(_ events: [HootChatEvent]) -> [HootChatEvent] {
        let originals = Dictionary(uniqueKeysWithValues: events.compactMap { event -> (Int, HootChatEvent)? in
            // A routing card and a background turn's compact line carry more than their text: keep them whole.
            event.record.kind == .message && (event.record.value["routing"].fields != nil || event.record.value["background"].fields != nil) ? (event.sequence, event) : nil
        })
        return HootChatProjection.snapshotEvents(events).map { originals[$0.sequence] ?? $0 }
    }
    public func routingRecords() -> [NativeRPCValue] {
        events.compactMap { event in
            let row = event.record.value["routing"]
            return row.fields != nil && row["conversationId"].string == conversationID ? row : nil
        }
    }
    public func recordRouting(_ row: NativeRPCValue) throws {
        guard !rebinding, row.fields != nil, row["conversationId"].string == conversationID,
              let id = row["id"].string, UUID(uuidString: id) != nil,
              let revision = row["revision"].string, UUID(uuidString: revision) != nil,
              ["pending", "scheduled", "approving", "dispatching", "sent", "uncertain", "dismissed"].contains(row["status"].string ?? ""),
              try row.encodedJSON().count <= 32_768 else { throw NativeRPCError.invalidArguments("The routing card no longer belongs to this chat.") }
        try append(.init(.message, id: "routing:" + id, value: .object([.init("text", .string(row["report"]["text"].string ?? "")), .init("routing", row)])))
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(reset: Bool) {
        // Each observer receives a reset snapshot: dropping a buffered update is safe.
        let value = snapshot(limit: 500)
        streamUnpublished = false
        for observer in observers.values { observer.yield(value) }
        noteContextChange()
    }
    /// Streamed words are shown in batches every 0.1 s and written at most once a second; every other event is written
    /// and shown at once, with the words before it. A whole-file write and a full snapshot per streamed word heated the
    /// Mac and made the chat stutter in a long conversation (#181).
    private var streamFlush: Task<Void, Never>?
    private var streamUnsaved = false, streamUnpublished = false
    private var streamSavedAt = ContinuousClock.now
    static func streamed(_ record: HootChatRecord) -> Bool {
        record.kind == .textDelta || (record.kind == .session && record.value["reasoning"]["phase"].string == "delta")
    }
    private func scheduleStreamFlush() {
        guard streamFlush == nil else { return }
        streamFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            await self?.flushStream()
        }
    }
    private func flushStream() {
        streamFlush = nil
        if streamUnpublished { publish(reset: false) }
        guard streamUnsaved else { return }
        if ContinuousClock.now - streamSavedAt >= .seconds(1) { try? persist() } else { scheduleStreamFlush() }
    }
    /// Where a conversation's pictures are kept: `media/` beside its file.
    static func mediaFolder(_ file: URL) -> URL { file.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true) }
    private func append(_ record: HootChatRecord, turn: String? = nil) throws {
        sequence += 1
        // A picture in a tool's result is kept as a file, so the conversation file never grows with picture bytes.
        let record = BackendChatMedia.keep(record, in: Self.mediaFolder(file))
        let event = HootChatEvent(conversationID: conversationID, turnID: turn ?? turnID, sequence: sequence, provider: provider, record: record)
        events.append(event)
        if !retainAllHistory, events.count > 4000 {
            events = Self.projectedRoutingHistory(events)
            if events.count > 4000 { events.removeFirst(events.count - 4000) }
        }
        if Self.streamed(record) { streamUnsaved = true; streamUnpublished = true; scheduleStreamFlush(); return }
        try persist()
        publish(reset: false)
    }
    /// Hoot's own conversation file stays under this size (the reader refuses a bigger one).
    static let historyByteLimit = 16 * 1_048_576
    private func encodedHistory() throws -> Data {
        var value = NativeRPCValue.object([.init("version", .number(1)), .init("conversationId", .string(conversationID)),
            .init("provider", .string(provider.rawValue)), .init("sessionId", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("contextKey", contextKey.map(NativeRPCValue.string) ?? .null), .init("claudeResumeAt", claudeResumeAt.map(NativeRPCValue.string) ?? .null), .init("forkHistoryPrefix", .bool(forkHistoryPrefix)), .init("events", .array(events.map(\.wireValue)))])
        if !setAside.isEmpty { value = value.setting("setAside", .array(setAside)) }
        if let appliedWindow { value = value.setting("window", .number(Double(appliedWindow))) }
        if let handover { value = value.setting("handover", .string(handover)) }
        if let lastContext, lastContext.session == sessionID {
            value = value.setting("contextReading", .object([.init("tokens", .number(Double(lastContext.tokens))), .init("at", .number(lastContext.at)), .init("sessionId", .string(lastContext.session))]))
        }
        return try value.encodedJSON()
    }
    /// Whole-file writes so far (tests count them).
    private(set) var historyWrites = 0
    private func persist() throws {
        var bytes = try encodedHistory()
        if !retainAllHistory, bytes.count > Self.historyByteLimit { try shed(); bytes = try encodedHistory() }
        guard retainAllHistory || bytes.count <= Self.historyByteLimit else { throw NativeRPCError(code: "history-limit", message: "Hoot's conversation reached its storage limit.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if convertedInline {
            // The first save without the inline pictures: the original kept once, then this save made durable.
            try BackendChatMedia.keepOriginal(file)
            BackendChatMedia.syncFolder(Self.mediaFolder(file))
            try BackendChatMedia.durableWrite(bytes, to: file)
            convertedInline = false
        } else {
            try bytes.write(to: file, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        streamUnsaved = false; streamSavedAt = .now; historyWrites += 1
    }
    /// Over the size limit the conversation sheds its oldest parts by size, the way the 4,000-event cap sheds them by
    /// count: refusing the write cut every later answer off and restarted Hoot again and again until a New chat (#84).
    /// First a part too big to keep whole keeps only its small fields, then the oldest set-aside parts go, then the
    /// oldest events, down to three quarters of the limit so the next writes do not shed again.
    private func shed() throws {
        let target = Self.historyByteLimit / 4 * 3
        events = Self.projectedRoutingHistory(events).map(Self.slimmed)
        var total = try encodedHistory().count
        var dropped = 0
        for part in setAside where total > target {
            total -= Self.encodedSize(part) + 1; dropped += 1
        }
        if dropped > 0 {
            if let undoable, setAside.prefix(dropped).contains(where: { $0["id"].string == undoable }) { self.undoable = nil }
            setAside.removeFirst(dropped)
        }
        dropped = 0
        for event in events.dropLast() where total > target {
            total -= Self.encodedSize(event.wireValue) + 1; dropped += 1
        }
        events.removeFirst(dropped)
    }
    static func encodedSize(_ value: NativeRPCValue) -> Int { (try? value.encodedJSON().count) ?? 0 }
    /// An event too big to keep whole (a huge tool output) keeps its small fields; a long text keeps its start, and
    /// anything else big says how much it held.
    static func slimmed(_ event: HootChatEvent) -> HootChatEvent {
        guard encodedSize(event.record.value) > 1_048_576, let fields = event.record.value.fields else { return event }
        let kept = fields.map { field -> NativeRPCValue.Field in
            let size = encodedSize(field.value)
            guard size > 65_536 else { return field }
            let note = "(" + String(size / 1024) + " KB too large to keep)"
            if let text = field.value.string { return .init(field.key, .string(String(text.prefix(65_536)) + "\n" + note)) }
            return .init(field.key, .string(note))
        }
        return .init(conversationID: event.conversationID, turnID: event.turnID, sequence: event.sequence, provider: event.provider,
                     record: .init(event.record.kind, id: event.record.messageID, value: .object(kept)), at: event.at)
    }
    /// Each New chat or AI change keeps the old conversation beside the current one. Only the newest few copies stay,
    /// so disk use does not grow for ever (#186).
    static let keptArchives = 10
    static func archive(_ source: URL, conversation id: String) throws -> URL {
        let folder = source.deletingLastPathComponent()
        let archive = folder.appendingPathComponent("chat-archive-" + id + "-" + UUID().uuidString.lowercased() + ".json")
        try FileManager.default.copyItem(at: source, to: archive)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: archive.path)
        pruneArchives(in: folder)
        return archive
    }
    static func pruneArchives(in folder: URL, keep: Int = keptArchives) {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key]) else { return }
        let dated = files.filter { $0.lastPathComponent.hasPrefix("chat-archive-") && $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
    private func accept(_ incoming: HootChatRecord, token: UUID) throws {
        guard generation == token else { return }
        var record = incoming
        if record.kind == .approval, BackendChatApproval.isApproval(record.value) {
            var value = record.value.setting("cwd", launchDirectory.map(NativeRPCValue.string) ?? .null)
                .setting("approvalNonce", .string(UUID().uuidString))
            if let toolID = value["toolId"].string, let operation = events.last(where: {
                $0.turnID == turnID && $0.record.kind == .toolCall && $0.record.messageID == toolID
            })?.record.value["input"] { value = value.setting("operation", operation) }
            record = .init(.approval, id: record.messageID, value: value)
        }
        let instructions = record.value["instructionReceipt"]
        if record.kind == .session, instructions.fields != nil {
            guard instructions["provider"].string == provider.rawValue, instructions["providerConversationId"].string == sessionID, sessionID != nil else { return }
            instructionReceipt = instructions
            try append(record, turn: ""); return
        }
        let policy = record.value["effectivePolicy"]
        if record.kind == .session, policy.fields != nil {
            guard policy["provider"].string == provider.rawValue, policy["providerConversationId"].string == sessionID, sessionID != nil else { return }
            effectivePolicyReceipt = policy
            try append(record, turn: ""); return
        }
        let started = record.value["providerTurnStarted"]
        if record.kind == .session, started.fields != nil {
            guard provider == .codex, started["providerSessionId"].string == sessionID, sessionID != nil,
                  let owner = started["turnId"].string, !owner.isEmpty, !rebinding, stopping == 0 else { return }
            cancelConsentBindings()
            turnID = owner; busy = true; completedTurn = false; cliStatus = nil
            pending = [:]; answered = []; lastError = nil; taskScope = nil
            undoable = nil; pendingContinuation = nil
            // Keep the current session's permission policy and consent surface. A provider start
            // never borrows a previous one-shot task's permission scope or invents a user message.
            try append(record, turn: owner); return
        }
        let receipt = record.value["appliedModelReceipt"]
        if record.kind == .session, receipt.fields != nil {
            guard receipt["providerSessionId"].string == sessionID, sessionID != nil,
                  let model = receipt["model"].string else { return }
            // Codex carries its exact provider-turn/local-turn binding; Claude's main assistant
            // receipt belongs only to a live foreground answer on this process generation.
            let owner = record.value["eventTurnId"].string ?? turnID
            guard !owner.isEmpty, record.value["eventTurnId"].string != nil || busy && !completedTurn else { return }
            if owner == turnID { reportedModel = model }
            let accepted = receipt.setting("turnId", .string(owner)).setting("provider", .string(provider.rawValue))
            try append(.init(.session, id: record.messageID, value: record.value.setting("appliedModelReceipt", accepted)), turn: owner)
            return
        }
        if record.kind == .session, record.value["hook"].fields != nil || record.value["providerWarning"].fields != nil {
            let claimed = record.value["providerSessionId"].string ?? record.value["hook"]["session_id"].string
            guard claimed == nil || claimed == sessionID else { return }
            try append(record, turn: record.value["eventTurnId"].string)
            return
        }
        if let owner = record.value["eventTurnId"].string, [.session, .toolCall, .toolResult].contains(record.kind) {
            // Late provider diff payloads update their original turn, never the active answer.
            try append(record, turn: owner); return
        }
        if record.kind == .session, record.value["commands"].elements != nil {
            commands = .array(Self.offeredCommands(record.value["commands"])); publish(reset: false); return
        }
        if record.kind == .session, (commands.elements ?? []).isEmpty, record.value["slashCommands"].elements != nil {
            commands = .array(Self.offeredCommands(record.value["slashCommands"]))
        }
        let reading = record.value["deskUsage"]
        if record.kind == .session, reading.fields != nil {
            // How full the desk is after this step: a reading, not part of the conversation.
            if let tokens = reading["tokens"].number, tokens > 0 {
                deskTokens = Int(tokens); deskMeasuredTurn = turnID
                contextReportedAt = Date().timeIntervalSince1970 * 1000
                if let sessionID { lastContext = (tokens: Int(tokens), at: contextReportedAt ?? 0, session: sessionID) }
            }
            if let window = reading["window"].number, window > 0 { deskWindow = Int(window); appliedWindow = Int(window) }
            publish(reset: false)
            return
        }
        if let id = record.value["sessionId"].string { sessionID = id }
        if let task = record.value["taskStarted"].string { backgroundTasks.insert(task); busy = true }
        if let task = record.value["taskFinished"].string {
            backgroundTasks.remove(task)
            if completedTurn && backgroundTasks.isEmpty && pending.isEmpty { busy = false }
        }
        if let status = record.value["status"].string {
            cliStatus = status
            if status == "running" || status == "requires_action" { busy = true }
            if status == "idle" && backgroundTasks.isEmpty && pending.isEmpty { busy = false }
        }
        if record.kind == .approval {
            guard record.value["input"].fields != nil,
                  (provider != .claude && !record.value["rpcId"].isNullish) || ["can_use_tool", "elicitation"].contains(record.value["subtype"].string ?? "") else {
                throw NativeRPCError(code: "unsupported-request", message: "Hoot's CLI sent an unsupported question: \(record.value["subtype"].string ?? "unknown").")
            }
            guard !record.messageID.isEmpty, pending[record.messageID] == nil, !answered.contains(record.messageID) else { return }
            busy = true
            pending[record.messageID] = record
            if BackendChatElicitation.isToolApproval(record.value), Self.autoAllows(mode: permissionPolicy, provider: provider, request: record.value) {
                let id = record.messageID
                quietAnswers.insert(id)
                Task { [weak self] in try? await self?.sendAnswer(id: id, allowed: true) }
                return
            } else if BackendChatQuestions.isQuestion(record.value) || BackendChatPlans.isReview(record.value) || BackendChatElicitation.isRequest(record.value) {
                // A conversation question is answered in chat, not by a Boolean permission broker.
            } else if Self.autoAllows(mode: permissionPolicy, provider: provider, request: record.value) || taskAllows(record.value)
                || Self.readsOnly(provider: provider, request: record.value) {
                // Answered by the app itself (the mode the person chose, a task's own tools, a read): nothing for the
                // person to see, so neither the question nor its answer goes into the chat or the diary.
                let id = record.messageID
                quietAnswers.insert(id)
                Task { [weak self] in try? await self?.sendAnswer(id: id, allowed: true) }
                return
            } else if let toolTier, let inner = Self.deckTool(provider: provider, request: record.value) {
                // A deck tool not on the known list: its own tier decides (a read never asks; reads reached through
                // tools_run included, e.g. sessions_screen). Recorded only when it really asks the person.
                let id = record.messageID
                let reading = Self.readingCall(Self.deckToolArguments(record.value))
                Task { [weak self] in
                    let read = await toolTier(inner) == .read && reading
                    await self?.settleDeckTool(record, read: read, id: id)
                }
                return
            } else { issueConsent(record) }
        }
        if record.kind == .approvalResolved {
            consentBindings.removeValue(forKey: record.messageID)?.cancellation.cancel()
            pending[record.messageID] = nil; answered.insert(record.messageID)
        }
        if record.kind == .completed {
            completedTurn = true
            if let window = (record.value["modelUsage"].fields ?? []).compactMap({ $0.value["contextWindow"].number }).max(), window > 0 { deskWindow = Int(window); appliedWindow = Int(window) }
            busy = !backgroundTasks.isEmpty || !pending.isEmpty || cliStatus == "running" || cliStatus == "requires_action"
        }
        if record.kind == .error {
            if lastError == record.value["text"].string { return }
            lastError = record.value["text"].string
        }
        try append(record)
    }
    private func invalidateEffectivePolicy(_ reason: String) {
        effectivePolicyReceipt = .null; instructionReceipt = .null; executionEvidence = .null; ownedTerminalScopeRevision = UUID()
        let last = events.last { $0.record.kind == .session && $0.record.value["effectivePolicy"].fields != nil }
        guard let last else { return }
        let previous = last.record.value["effectivePolicy"]
        if previous["source"].string == "provider-policy-not-current", previous["provider"].string == provider.rawValue,
           previous["providerConversationId"].string == sessionID { return }
        let empty = NativeRPCValue.object([.init("provider", .string(provider.rawValue)),
            .init("providerConversationId", sessionID.map(NativeRPCValue.string) ?? .null),
            .init("source", .string("provider-policy-not-current")), .init("reason", .string(reason)),
            .init("authority", .string("not-current")), .init("sandbox", .null), .init("approval", .null),
            .init("workspaceTrust", .null), .init("network", .null)])
        do { try append(.init(.session, value: .object([.init("effectivePolicy", empty)])), turn: "") }
        catch { publish(reset: false) }
    }
    private func issueConsent(_ record: HootChatRecord) {
        guard let consent else { return }
        let binding = ConsentBinding(nonce: UUID().uuidString, turn: turnID, generation: generation, cancellation: .init())
        consentBindings[record.messageID] = binding
        let arguments = record.value.setting("hootBinding", .string(binding.nonce)).setting("conversationId", .string(conversationID)).setting("turnId", .string(turnID))
        let origin = consentOrigin
        Task { [weak self] in
            let outcome = await consent.request(tool: "hoot.cli", tier: .alter, summary: record.value["name"].string ?? "Hoot needs your answer",
                arguments: arguments, cancellation: binding.cancellation, origin: origin, label: "Hoot", askedBy: "Hoot")
            await self?.settleConsent(id: record.messageID, binding: binding, outcome: outcome)
        }
    }
    private func settleConsent(id: String, binding: ConsentBinding, outcome: BackendDeckCoreSecurityConsentOutcome) async {
        guard binding.generation == generation, binding.turn == turnID, let current = consentBindings[id], current.nonce == binding.nonce, pending[id] != nil else { return }
        consentBindings[id] = nil
        do { try await sendAnswer(id: id, allowed: outcome.granted, answers: current.answers) }
        catch {
            // A boolean-only approver cannot silently satisfy a structured form.
            try? await sendAnswer(id: id, allowed: false)
            try? append(.text(.error, error.localizedDescription))
        }
    }
    private func cancelConsentBindings() {
        for binding in consentBindings.values { binding.cancellation.cancel() }; consentBindings = [:]
    }
    private func exited(token: UUID, code: Int32, diagnostic: String) async {
        guard generation == token else { return }
        _ = await closeOwnedTerminals(reason: "The parent provider connection ended")
        guard generation == token else { return }
        cancelConsentBindings()
        process = nil; consumer = nil
        invalidateEffectivePolicy("The provider process exited. No current boundary is confirmed.")
        let detail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = "Hoot's CLI exited with code \(code)" + (busy ? " during a turn" : " while idle") + (detail.isEmpty ? "" : ": " + String(detail.suffix(400)))
        endReason = reason
        if let exitObserver { Task { await exitObserver(reason) } }
        // The CLI's own reason travels, in one short secret-free line (27 Oct: a phone said only "Hoot's CLI exited during
        // its handshake." while sandbox-exec had printed exactly why).
        let early = NativeRPCError(code: "unavailable", message: Self.stoppedWhileStarting(provider: provider, code: code,
            diagnostic: diagnostic, folder: launchDirectory, secrets: BackendSharedRedact.secretsFromEnv(providerLaunch?.environment ?? [:])))
        exitedWhileStarting = early
        finishInitialization(error: early)
        if busy || code != 0 {
            let text = lastError ?? (diagnostic.isEmpty ? "Hoot's CLI exited before completing its turn (\(code))." : String(diagnostic.prefix(2000)))
            let wasBusy = busy
            lastError = text; busy = false; pending = [:]
            noteOnce(wasBusy ? "Hoot stopped before finishing that answer. It is starting again."
                             : "Hoot stopped unexpectedly and is starting again.")
        }
        publish(reset: false)
    }
    /// What a person reads when the AI quit before it was ready: which AI, and the CLI's own reason in one short line.
    static func stoppedWhileStarting(provider: HootChatProvider, code: Int32, diagnostic: String, folder: String? = nil,
                                     secrets: [String] = []) -> String {
        let name = provider == .claude ? "Claude Code" : provider == .codex ? "Codex" : "Gemini"
        guard let reason = reasonLine(diagnostic, folder: folder, secrets: secrets) else { return name + " stopped while it was starting (exit code \(code))." }
        return name + " stopped while it was starting: " + reason
    }
    /// The CLI's reason from what it printed: the first line that names an error, else its first line. Terminal colours,
    /// control characters, secrets (known shapes and the launch's own secret values), every path outside the chat's own
    /// `folder` and the owner's home folder are taken out; at most 200 characters.
    static func reasonLine(_ diagnostic: String, folder: String? = nil, secrets: [String] = []) -> String? {
        let uncoloured = diagnostic.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let lines = uncoloured.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let picked = lines.first(where: { $0.range(of: "error", options: .caseInsensitive) != nil }) ?? lines.first else { return nil }
        let redacted = BackendSharedRedact.redact(outsidePathsHidden(picked, folder: folder), options: .init(extraSecrets: secrets))
        let printable = String(String.UnicodeScalarView(redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespaces)
        guard !printable.isEmpty else { return nil }
        return printable.count > 200 ? String(printable.prefix(199)) + "…" : printable
    }
    /// Every path the CLI named (`/…` or `~/…`), except one inside the chat's own folder, becomes "[path]": a guest
    /// whose phone may start chats only in its given folders never learns what lies outside them (Reviewer, 27 Oct).
    /// A path with spaces is taken whole (the words after it that go on with a "/"); `..` is resolved before the check.
    static func outsidePathsHidden(_ line: String, folder: String?) -> String {
        let stop = #"\s'"`<>()\[\]{},;:"#
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._~-])~?/[^"# + stop + #"]*(?:\s+[^"# + stop
                + #"/~][^"# + stop + #"/]*/[^"# + stop + #"]*)*"#) else { return "[path]" }
        let roots: [String] = folder.map { given in
            let plain = URL(fileURLWithPath: given).standardizedFileURL.path
            return Array(Set([plain, URL(fileURLWithPath: plain).resolvingSymlinksInPath().path])).filter { $0 != "/" }
        } ?? []
        let text = line as NSString, result = NSMutableString(string: line)
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)).reversed() {
            let token = text.substring(with: match.range)
            let expanded = token.hasPrefix("~") ? NSHomeDirectory() + String(token.dropFirst()) : token
            let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
            if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            result.replaceCharacters(in: match.range, with: "[path]")
        }
        return result as String
    }
    private func failed(token: UUID, error: Error) async {
        guard generation == token else { return }
        _ = await closeOwnedTerminals(reason: "The parent provider connection failed")
        guard generation == token else { return }
        cancelConsentBindings()
        let reason = "Hoot's CLI failed: " + error.localizedDescription
        endReason = reason
        if let exitObserver { Task { await exitObserver(reason) } }
        finishInitialization(error: error)
        lastError = error.localizedDescription; let child = process; process = nil
        invalidateEffectivePolicy("The provider process failed. No current boundary is confirmed.")
        busy = false; pending = [:]; generation = UUID(); consumer?.cancel(); consumer = nil
        // The raw CLI error goes to the log; the chat gets one plain line at most.
        noteOnce("Hoot stopped unexpectedly and is starting again."); publish(reset: false)
        if let child { stopping += 1; await child.stopAndWait(); stopping -= 1 }
    }
}
