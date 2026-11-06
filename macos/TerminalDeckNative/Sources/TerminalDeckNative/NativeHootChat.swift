import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Whose conversation Hoot's chat screen shows (Asad, 13 Oct: "instead of building new screens give same as Hoot,
/// just use same"): Hoot's own, with every call exactly as it always was, or a chat session's, through its own
/// `session:chat:*` calls (the same verbs, the session's id first).
struct HootChatSource: Equatable, Sendable {
    /// Nil: Hoot.
    let sessionID: String?
    /// Who answers, as the chat says it ("Hoot", "Claude Code").
    let agentName: String
    static let hoot = HootChatSource(sessionID: nil, agentName: "Hoot")
    static func session(_ id: String, provider: String) -> HootChatSource {
        HootChatSource(sessionID: id, agentName: ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"][provider] ?? provider)
    }
    var isHoot: Bool { sessionID == nil }
    /// The push that carries a new snapshot.
    var event: String { isHoot ? "hoot:chat:changed" : "session:chat:changed" }
    func channel(_ verb: String) -> String { (isHoot ? "hoot:chat:" : "session:chat:") + verb }
    func arguments(_ arguments: [Any?]) -> [Any?] { sessionID.map { [$0] + arguments } ?? arguments }
}

@MainActor @Observable final class NativeHootChatModel {
    static let shared = NativeHootChatModel()
    struct QueuedMessage: Identifiable {
        // The saved queue ID follows this operation through the keeper and its delivery receipt.
        var id = UUID().uuidString.lowercased()
        var draft: HootComposerDraft
        var context: NativeRPCValue?
        var editing = false
        var originalText = ""
        var held = false
        var problem: String?
        var deliveryPending = false
    }
    /// A crash during an edit must not let the old operation's receipt discard the changed draft.
    static func restoreQueuedMessage(_ entry: NativeChatOutbox.Entry) -> QueuedMessage {
        let edited = entry.editedPendingDelivery == true
        // Older outboxes did not distinguish a held draft from an unknown send. Keep both safe.
        let pending = !edited && (entry.deliveryPending ?? (entry.held || entry.problem != nil))
        return QueuedMessage(id: edited ? UUID().uuidString.lowercased() : entry.id, draft: entry.draft,
            context: entry.context.flatMap { try? NativeRPCValue.parseJSON($0) }, held: entry.held || pending || edited,
            problem: pending ? notSentYet("The earlier delivery was not confirmed.") : entry.problem, deliveryPending: pending)
    }
    fileprivate final class QueueOwner {
        weak var model: NativeHootChatModel?
        var pending: NativeHootChatModel?
        var searching: NativeHootChatModel?
        init(_ model: NativeHootChatModel) { self.model = model }
    }
    @Observable fileprivate final class QueueRegistry {
        var owners: [String: QueueOwner] = [:]
    }
    private static let queueRegistry = QueueRegistry()
    // Sidebar rows must also refresh when their model is first attached, not just when an existing model changes.
    private static var queueOwners: [String: QueueOwner] {
        get { queueRegistry.owners }
        set { queueRegistry.owners = newValue }
    }
    static func queueOwner(_ id: String) -> NativeHootChatModel? { id == "hoot" ? .shared : queueOwners[id]?.model }
    static func forSession(_ id: String, name: String) -> NativeHootChatModel {
        queueOwners[id]?.model ?? NativeHootChatModel(source: .init(sessionID: id, agentName: name))
    }
    private struct FeatureOwner {
        let model: NativeHootChatModel
        let ready: Task<Void, Never>
        var used: Date
        var expiry: Task<Void, Never>?
    }
    private static var featureOwners: [String: FeatureOwner] = [:]
    static func featureModel(_ id: String, name: String) async -> NativeHootChatModel {
        let now = Date()
        featureOwners = featureOwners.filter { now.timeIntervalSince($0.value.used) < 60 }
        if var cached = featureOwners[id] {
            cached.used = now; featureOwners[id] = cached
            expireFeatureModel(id, model: cached.model)
            await cached.ready.value
            return cached.model
        }
        let model = queueOwner(id) ?? forSession(id, name: name)
        let ready = Task { await model.start() }
        if featureOwners.count >= 8, let oldest = featureOwners.min(by: { $0.value.used < $1.value.used })?.key { featureOwners[oldest] = nil }
        featureOwners[id] = FeatureOwner(model: model, ready: ready, used: now)
        expireFeatureModel(id, model: model)
        await ready.value
        return model
    }
    private static func expireFeatureModel(_ id: String, model: NativeHootChatModel) {
        featureOwners[id]?.expiry?.cancel()
        featureOwners[id]?.expiry = Task { [weak model] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if let cached = featureOwners[id], cached.model === model, Date().timeIntervalSince(cached.used) >= 60 { featureOwners[id] = nil }
        }
    }
    static func restoreOutboxes() async {
        let sessions = try? await EngineBridge.shared.invoke("session:list")
        for id in NativeChatOutbox.sessions {
            guard let saved = NativeChatOutbox.load(id) else { continue }
            var target = id
            if id != "hoot", let sessions,
               TerminalSessionInfo.find(id, in: sessions).map({ $0.exitCode != nil }) ?? true {
                guard let key = saved.tabKey, let rows = sessions as? [[String: Any]],
                      let row = rows.first(where: { $0["tabKey"] as? String == key && TerminalSessionInfo.decode($0)?.exitCode == nil }), let next = row["id"] as? String else { NativeChatOutbox.remove(id); continue }
                guard NativeChatOutbox.load(next) == nil else { continue }
                do {
                    try NativeChatOutbox.save(next, name: saved.name, entries: saved.entries, draft: saved.draft, tabKey: key)
                    NativeChatOutbox.remove(id)
                    target = next
                } catch { continue }
            }
            guard !saved.entries.isEmpty else { continue } // Draft-only chats restore when opened.
            let model = target == "hoot" ? shared : forSession(target, name: saved.name)
            if target != id, let previous = queueOwner(id) { model.carryDisplay(from: previous) }
            await model.start()
        }
    }
    private(set) var rows: [HootChatRow] = [] { didSet { if findVisible { updateFind() } } }
    var findVisible = false {
        didSet { Self.queueOwners[source.sessionID ?? "hoot"]?.searching = findVisible ? self : nil }
    }
    var findQuery = ""
    var findIndex = 0
    var findRevision = 0
    var findMatches: [NativeChatFindMatch] = []
    var attachmentCapabilities: NativeRPCValue = .null
    private(set) var childTasks: [NativeRPCValue] = []
    var runningTasksExpanded = false
    private(set) var answering = false
    var foregroundAnswerActive: Bool { answering || sending }
    private(set) var stoppingChild: String?
    func stopChild(_ id: String) async throws -> NativeRPCValue {
        guard stoppingChild == nil, childTasks.contains(where: { $0["id"].string == id && ChatChildTasks.running($0) }) else { throw NativeRPCError.invalidArguments("Choose a running task from this chat.") }
        stoppingChild = id; defer { stoppingChild = nil }
        let result = try await invokeChat("child-stop", [id]); accept(result)
        return .array(childTasks)
    }
    func requestChildStop(_ id: String) {
        Task { do { _ = try await stopChild(id) } catch { problem = error.localizedDescription } }
    }
    func runningTaskOutput(_ id: String) async throws -> NativeRPCValue {
        guard runningTasks.contains(where: { $0["id"].string == id }) else {
            throw NativeRPCError.invalidArguments("Choose a running task from this chat.")
        }
        return try NativeRPCValue.fromFoundation(await invokeChat("provider", ["background/output", ["taskId": id]]))
    }
    func retainAttachmentDraft() { Self.queueOwners[source.sessionID ?? "hoot"]?.pending = self }
    private(set) var pending: [NativeRPCValue] = []
    private(set) var todos: [NativeRPCValue] = []
    private(set) var taskProgress: NativeRPCValue = .null
    @ObservationIgnored var chatViewports: [UUID: NativeChatFollowViewport] = [:]
    @ObservationIgnored private var progressCursor = -1
    @ObservationIgnored private var progressConversation = ""
    @ObservationIgnored private var progressChildren: [NativeRPCValue] = []
    private func updateTaskProgress(_ events: [HootChatEvent]) {
        let cursor = events.last { event in
            let value = event.record.value
            switch event.record.kind {
            case .user, .interrupted: return true
            case .toolResult: return value["partial"].bool != true
            case .toolCall:
                return ["TaskCreate", "TaskUpdate", "TodoWrite", "Agent", "Task"].contains(value["name"].string ?? "") ||
                    ["subAgentActivity", "collabAgentToolCall"].contains(value["input"]["type"].string ?? "")
            case .session:
                return value["todoPlan"].elements != nil || value["childTask"].fields != nil ||
                    value["taskStarted"].string != nil || value["taskFinished"].string != nil || value["sessionId"].string != nil
            default: return false
            }
        }?.sequence ?? 0
        guard fixtureMode || progressConversation != conversationID || progressCursor != cursor || progressChildren != childTasks else { return }
        progressCursor = cursor; progressConversation = conversationID; progressChildren = childTasks
        let progress = BackendChatTodos.progress(events, children: childTasks)
        todos = progress.rows; taskProgress = progress.wire
    }
    private(set) var thoughts: [NativeRPCValue] = []
    private(set) var fileDiffs: [BackendChatDiffs.Card] = []
    @ObservationIgnored private var diffInputs: [HootChatRow] = []
    func thought(for rowID: String) -> NativeRPCValue? { thoughts.first { rowID.hasPrefix(($0["turnId"].string ?? "") + ":") } }
    private(set) var workingState = ChatWorkingState.idle
    private(set) var busy = false
    private(set) var alive = false
    private(set) var readOnly = false
    @ObservationIgnored private var sessionEvents: [HootChatEvent] = []
    var chatShortcutsVisible = false
    @ObservationIgnored lazy var chatDraftEditor = NativeChatDraftEditor()
    var chatRequestedModel: String?
    var chatAppliedModelReceipt: NativeRPCValue = .null
    var chatCurrentEffectiveProviderPolicy: NativeRPCValue = .null
    private var chatSavingModel: String?
    var chatModelTimingState: NativeRPCValue { NativeChatModelTiming.state(requested: queuedOptions["model"] ?? chatRequestedModel, selected: confirmedModel, applied: chatAppliedModelReceipt, queued: queuedOptions["model"] != nil, saving: chatSavingModel != nil, busy: busy || sending) }
    var chatFeaturePanels: Set<String> = []
    var chatFeatureRevision = 0
    var chatCommandsVisible = false
    var chatReportedCommands: NativeRPCValue = .array([])
    var chatControlTarget: String?
    var chatVoiceVisible = false
    @ObservationIgnored lazy var chatVoice = NativeChatVoice(dictation: HootComposerVoice(available: fixtureMode ? false : nil, observeHardware: !fixtureMode))
    var chatRoutinesVisible = false
    var chatRoutineDraft: ROUTINESDraft?
    var chatRoutinePreparing = false
    var chatGoalsVisible = false
    var chatEditorContextVisible = false
    var chatEditorContextReceipt: NativeRPCValue = .null
    var chatSideVisible = false
    var chatSideQuestion = ""
    var chatSideBrief = ""
    var chatSidePreparedQuestion = ""
    var chatSideSource: NativeRPCValue = .null
    var chatReviewVisible = false
    var chatLimitsVisible = false
    var chatContextVisible = false
    private(set) var chatContextReadingWire: NativeRPCValue = .null
    private(set) var chatReportedUsage: NativeRPCValue = .null
    var chatDiagnosticsVisible = false
    var chatAccountVisible = false
    var chatAccountProblem: String?
    var chatArtifactsVisible = false
    private(set) var transcriptRevision = 0
    var chatConnectionsVisible = false
    var chatSkillsVisible = false
    var chatSourcesVisible = false
    var chatMemoryVisible = false
    var chatDetailsVisible = false
    var chatDetailQuery = ""
    var chatDetailIndex = 0
    var transcriptExportEvents: [HootChatEvent] {
        _ = transcriptRevision // Stream updates refresh inspectors without observing/copying the full journal.
        return sessionEvents
    }
    @ObservationIgnored private var inspectorRevision = -1
    @ObservationIgnored private var artifactIndex: [NativeChatArtifact] = []
    @ObservationIgnored private var detailIndex: [(event: HootChatEvent, text: String)] = []
    @ObservationIgnored private var reviewIndex: [NativeChatReviewFinding] = []
    @ObservationIgnored private var diagnosticIndex: [NativeChatDiagnostic] = []
    @ObservationIgnored private var detailTextIndex: [String: String] = [:]
    private func refreshInspectorIndexes() {
        guard inspectorRevision != transcriptRevision else { return }
        artifactIndex = NativeChatArtifact.index(sessionEvents)
        detailIndex = sessionEvents.map { ($0, NativeChatDetail.text($0)) }
        reviewIndex = NativeChatReview.findings(sessionEvents)
        diagnosticIndex = NativeChatDiagnostics.records(sessionEvents)
        detailTextIndex = Dictionary(detailIndex.map { ($0.event.id, $0.text) }, uniquingKeysWith: { _, latest in latest })
        inspectorRevision = transcriptRevision
    }
    var chatArtifacts: [NativeChatArtifact] { refreshInspectorIndexes(); return artifactIndex }
    var chatDetailRecords: [(event: HootChatEvent, text: String)] { refreshInspectorIndexes(); return detailIndex }
    func chatDetailText(_ event: HootChatEvent) -> String { refreshInspectorIndexes(); return detailTextIndex[event.id] ?? NativeChatDetail.text(event) }
    var chatDiagnostics: [NativeChatDiagnostic] { refreshInspectorIndexes(); return diagnosticIndex }
    var chatReviewFindings: [NativeChatReviewFinding] { refreshInspectorIndexes(); return reviewIndex }
    var transcriptExportReady: Bool { initialHistoryLoaded && !initialHistoryLoading && replacedHistoryComplete && !loading }
    private(set) var sending = false
    private(set) var stopping = false
    private(set) var queuedMessages: [QueuedMessage] = [] {
        didSet {
            Self.queueOwners[source.sessionID ?? "hoot"]?.pending = queuedMessages.isEmpty && !composerDraft.canSend ? nil : self
            persistQueue()
            if oldValue.count != queuedMessages.count { syncQueueDepth(queuedMessages.count) }
        }
    }
    var queuedMessageCount: Int { queuedMessages.count }
    private(set) var steeringQueuedID: String?
    @ObservationIgnored private var steeringTask: Task<Void, Never>?
    @ObservationIgnored private var queueDepthSync: Task<Void, Never>?
    @ObservationIgnored private var outgoingSend: Task<Void, Never>?
    @ObservationIgnored private var stopRevision = 0
    private(set) var loading = true
    private var carriedDisplay = false
    private var carriedAgent: AGTAgent?
    var replyAgent: AGTAgent? {
        guard let id = source.sessionID else { return nil }
        return carriedAgent ?? NativeSessionRailContinuity.shared.agent(id)
            ?? AGTAgentsStore.shared.sender(of: id) ?? SIDEBARSessionAgents.all()[id]
            ?? AGTAgentsStore.shared.agent(AGTTeamChatHistory.shared.rows.first { $0["session"]["id"].string == id }?["job"]["agentID"].string)
    }
    var displayState: NativeRPCValue {
        .object([.init("loading", .bool(loading)), .init("rows", .number(Double(rows.count))),
            .init("agentID", replyAgent.map { .string($0.id) } ?? .null),
            .init("senderName", .string(replyAgent?.name ?? source.agentName)),
            .init("agentAvatar", .bool(replyAgent != nil))])
    }
    @ObservationIgnored private var optionsTask: Task<Void, Never>?
    private(set) var changingOptions = false
    private(set) var changingConversation = false
    private(set) var problem: String? {
        didSet {
            if let problem {
                let safe = NativeChatDisplayError.text(problem)
                if safe != problem { self.problem = safe.isEmpty ? nil : safe }
            }
        }
    }
    private(set) var readyToSend: Bool?
    private(set) var catalogue = HootComposerCatalogue()
    @ObservationIgnored private var referenceSearch: Task<Void, Never>?
    /// The pushes after which the @ list and "N sessions available" are read again (#42).
    static let mentionEvents = ["session:created", "session:exit", "session:removed", "session:renamed", "tasks:changed"]
    @ObservationIgnored private var mentionFeed: [EngineSubscription] = []
    @ObservationIgnored private var mentionReload: Task<Void, Never>?
    private(set) var referenceRoot = ""
    @ObservationIgnored private var outboxTabKey: String?
    @ObservationIgnored private var outboxTransferred = false
    var composerDraft = HootComposerDraft() {
        didSet {
            guard !fixtureMode, oldValue != composerDraft else { return }
            Self.queueOwners[source.sessionID ?? "hoot"]?.pending = composerDraft.canSend || !queuedMessages.isEmpty ? self : nil
            persistDraftSoon()
        }
    }
    func setDraftText(_ text: String) throws {
        guard !readOnly, text.utf8.count <= 262_144 else { throw NativeRPCError.invalidArguments("An editable draft supports at most 256 KiB.") }
        composerDraft.text = text
        syncSessionDraft()
    }
    @ObservationIgnored private var promptRecall = NativeChatPromptHistory()
    private var promptHistory: [String] {
        rows.filter { $0.kind == .user && ($0.value["context"]["source"]["kind"].string ?? "").isEmpty }
            .compactMap { $0.value["text"].string }.filter { !$0.isEmpty }
    }
    var promptRecallState: NativeRPCValue {
        .object([.init("count", .number(Double(promptHistory.count))),
                 .init("cursor", promptRecall.cursor.map { .number(Double($0)) } ?? .null),
                 .init("draft", .string(composerDraft.text))])
    }
    @discardableResult func recallPrompt(previous: Bool) -> Bool {
        guard !readOnly, !loading, !changingConversation,
              let text = promptRecall.move(previous: previous, current: composerDraft.text, history: promptHistory, conversation: conversationID) else { return false }
        composerDraft.text = text
        if let id = source.sessionID { Self.queueOwners[id]?.pending = text.isEmpty && queuedMessages.isEmpty ? nil : self }
        syncSessionDraft()
        return true
    }
    @ObservationIgnored private var toolDraftRevision: Int?
    @ObservationIgnored private var localDraftEchoes: [String] = []
    /// The person's last message never got a finished answer (a restart cut it off): its turn id.
    private(set) var unfinishedTurn: String?
    private(set) var forkPrefix = false
    private var retryTurn: String? {
        guard !forkPrefix else { return nil }
        guard let user = sessionEvents.last(where: { $0.record.kind == .user && !$0.turnID.hasPrefix("bg:") && ($0.record.value["context"]["source"]["kind"].string ?? "").isEmpty }) else { return nil }
        let turn = sessionEvents.filter { $0.turnID == user.turnID }
        return turn.contains { $0.record.kind == .error || $0.record.kind == .interrupted } || !turn.contains { $0.record.kind == .completed } ? user.turnID : nil
    }
    var retryRow: HootChatRow? {
        guard let turn = retryTurn else { return nil }
        return rows.last { $0.kind == .user && $0.id.hasPrefix(turn + ":") }
    }
    private static func isCompact(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first == "/compact" }
    private var startingCompact = false
    var compacting: Bool {
        if startingCompact { return true }
        guard busy || sending, let user = sessionEvents.last(where: { $0.record.kind == .user && !$0.turnID.hasPrefix("bg:") }),
              Self.isCompact(user.record.value["text"].string ?? "") else { return false }
        return !sessionEvents.contains { $0.turnID == user.turnID && [.completed, .error, .interrupted].contains($0.record.kind) }
    }
    func compactStatus(_ row: HootChatRow) -> String? {
        guard row.kind == .user, Self.isCompact(row.value["text"].string ?? ""),
              let user = sessionEvents.first(where: { row.id.hasPrefix($0.turnID + ":") && $0.record.kind == .user }) else { return nil }
        let records = sessionEvents.filter { $0.turnID == user.turnID }
        if records.contains(where: { $0.record.kind == .error }) { return "Compaction failed." }
        if records.contains(where: { $0.record.kind == .interrupted }) { return "Compaction interrupted." }
        if records.contains(where: { $0.record.kind == .completed }) { return "Conversation compacted." }
        return busy || sending ? "Compacting…" : "Compaction interrupted."
    }
    var recoveryState: NativeRPCValue {
        .object([.init("compacting", .bool(compacting)),
                 .init("compactions", .array(rows.compactMap { row in compactStatus(row).map { .object([.init("id", .string(row.id)), .init("status", .string($0))]) } })),
                 .init("retry", retryRow.flatMap { row in interrupted(row) ? .object([.init("id", .string(row.id)), .init("needsAttachments", .bool((row.value["attachmentCount"].number ?? 0) > 0))]) : nil } ?? .null)])
    }
    func recover(_ action: String) throws -> NativeRPCValue {
        if action != "read" {
            guard !readOnly, !busy, !sending, !stopping, !resuming, !changingConversation else { throw NativeRPCError.invalidArguments("Wait until this chat is idle.") }
            if action == "retry" {
                guard let row = retryRow, interrupted(row) else { throw NativeRPCError.invalidArguments("There is no failed or interrupted turn to retry.") }
                sendAgain(row)
            } else if action == "compact" {
                guard catalogue.commands.contains(where: { $0.name == "compact" }) else { throw NativeRPCError.invalidArguments("This AI has not offered /compact.") }
                var draft = composerDraft; draft.text = "/compact"; draft.attachments = []; draft.mentions = []; send(draft)
            } else { throw NativeRPCError.invalidArguments("Choose read, retry or compact.") }
        }
        return recoveryState
    }
    /// The turn of the person's last message (not one the app sent in, not a background turn) when it has no "completed".
    static func unfinishedTurn(_ events: [HootChatEvent]) -> String? {
        let last = events.last { $0.record.kind == .user && !$0.turnID.hasPrefix("bg:") && ($0.record.value["context"]["source"]["kind"].string ?? "").isEmpty }
        // The person's own Stop is not "interrupted by a restart".
        return last.flatMap { user in events.contains { $0.turnID == user.turnID && ($0.record.kind == .completed || ($0.record.kind == .interrupted && $0.record.value["by"].string == "person")) } ? nil : user.turnID }
    }
    /// The rows the chat shows: never an approval, never anything of a background turn.
    static func chatRows(_ events: [HootChatEvent]) -> [HootChatRow] {
        HootChatProjection.rows(events).filter { $0.kind != .approval && !$0.id.hasPrefix("bg:") }
    }
    @ObservationIgnored private var resent: Set<String> = []
    /// The app is about to carry the person's cut-off message on by itself (restart continuity): no "Send again".
    private(set) var resuming = false
    /// "Interrupted by a restart · Send again" under this message: only the person's last message, only when Hoot is
    /// not working on it, once per message, and never after anything else was sent.
    func interrupted(_ row: HootChatRow) -> Bool {
        guard !readOnly, !fixtureMode, !resuming, let turn = retryTurn, row.kind == .user, row.id.hasPrefix(turn + ":"), !resent.contains(turn) else { return false }
        return !busy && !sending
    }
    /// Sends that same message once more, exactly as it was written, with the same mentions (pictures are not kept,
    /// so a message with pictures says so instead). Through the chat's one incoming path, like the message box.
    func sendAgain(_ row: HootChatRow) {
        guard interrupted(row), let turn = retryTurn, readyToSend != false, !changingConversation else { return }
        if row.value["attachmentCount"].number ?? 0 > 0 {
            guard !composerDraft.canSend else { problem = "Keep or send your current draft before retrying this message."; return }
            composerDraft.text = row.value["text"].string ?? ""
            problem = "Attach the original files again, then send."
            return
        }
        resent.insert(turn)
        let text = row.value["text"].string ?? ""
        let context = row.value["context"].fields == nil ? NativeRPCValue.object([]) : row.value["context"]
        sending = true; problem = nil
        outgoingSend = Task {
            defer { sending = false; outgoingSend = nil; if !busy { flushOptions() } }
            do {
                try Task.checkCancellation()
                let receipt = try await invokeChat("say", [text, [Any](), context.foundation ?? [String: Any]()])
                accept(receipt)
            } catch { resent.remove(turn); if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
    /// What happened to each message's @ mentions (turn id → receipts), drawn under that message.
    private(set) var receipts: [String: [NativeRPCValue]] = [:]
    func receipts(for row: HootChatRow) -> [NativeRPCValue] {
        receipts.first { row.id.hasPrefix($0.key + ":") }?.value ?? []
    }
    /// The agents that have answered a message's @ mentions (turn id → answers).
    private(set) var answered: [String: [NativeRPCValue]] = [:]
    func answers(for row: HootChatRow) -> [NativeRPCValue] {
        answered.first { row.id.hasPrefix($0.key + ":") }?.value ?? []
    }
    /// A rewind was just made and no message has been sent since: it can still be put back.
    private(set) var canUndoRewind = false
    private(set) var rewindProblem: String?
    var messageActions: [NativeRPCValue] = []
    var changingMessageHistory = false
    var messageActionProblem: String?
    private(set) var providerConversationMissing = false
    /// Back to this message: what came after is set aside, a message of the person's returns to the box.
    func rewind(to row: HootChatRow) {
        guard !fixtureMode || chatInvoke != nil, !busy, row.sequence > 0 else { return }
        rewindProblem = nil
        changingMessageHistory = true
        Task {
            defer { changingMessageHistory = false }
            do {
                let text: String
                if source.isHoot {
                    guard let rewind = HootChatActions.rewind else { return }; text = try await rewind(row.sequence)
                } else {
                    let result = try NativeRPCValue.fromFoundation(await invokeChat("rewind", [row.sequence]))
                    text = result["text"].string ?? ""
                }
                try await finishRewind(text)
            } catch { rewindProblem = error.localizedDescription }
        }
    }
    /// The button and the tool replace the visible transcript as well as the AI's history.
    func finishRewind(_ text: String) async throws {
        try await reloadConversation()
        composerDraft.text = text
    }
    func undoRewind() {
        guard !fixtureMode || chatInvoke != nil else { return }
        rewindProblem = nil
        Task {
            do {
                if source.isHoot { try await HootChatActions.undoRewind?() }
                else { _ = try await invokeChat("undo-rewind", []) }
                try await reloadConversation(); composerDraft.text = ""
            }
            catch { rewindProblem = error.localizedDescription }
        }
    }
    var canRewind: Bool { !fixtureMode && (!source.isHoot || HootChatActions.rewind != nil) }
    /// The app's guard on its own records is not held for this run of Hoot (why, in one sentence). Shown in the header.
    private(set) var guardOff: String?
    var canHandoff: Bool { !fixtureMode && (source.isHoot ? HootChatActions.handoffUpTo != nil : HootChatActions.handoffConversation != nil) }
    /// The message's own Context handoff: a handoff of the conversation up to and including this message, written in
    /// the background and shown in the handoff panel beside Hoot's chat (from the island, Hoot's page comes forward).
    func handoff(upTo row: HootChatRow, fromIsland: Bool) {
        guard canHandoff, row.sequence > 0 else { return }
        let ask: @MainActor (Int, @escaping @MainActor (String) -> Void) async throws -> Void
        if source.isHoot { guard let action = HootChatActions.handoffUpTo else { return }; ask = action }
        else {
            guard let action = HootChatActions.handoffConversation, let id = source.sessionID else { return }
            ask = { [self] sequence, progress in
                let request = try NativeRPCValue.fromFoundation(await invokeChat("handoff", [sequence]))
                try await action(id, request["prompt"].requireString("handoff request"), progress)
            }
        }
        let first = (row.value["text"].string ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = first.count > 60 ? String(first.prefix(60)) + "\u{2026}" : first
        if fromIsland || !source.isHoot {
            NSApp.activate(ignoringOtherApps: true) // front-ok: the person's own press on a message's Handoff in the island
            AppModel.shared.select("hoot"); HootProfileRoute.close()
        }
        let panel = NativeHandoffModel.of(.hoot)
        let start = "Hoot is writing a handoff up to \u{201C}\(words)\u{201D}\u{2026}"
        panel.isOpen = true; panel.editing = false
        panel.upTo = words
        panel.phase = .writing(start)
        var lastLine = start
        Task {
            do {
                try await ask(row.sequence) { line in
                    guard panel.isWriting, !line.isEmpty else { return }
                    lastLine = line; panel.phase = .writing(line)
                }
                // The document normally arrived before this (M1's event opens it); give that a moment.
                try? await Task.sleep(for: .seconds(1.5))
                if panel.phase == .writing(lastLine) { panel.phase = .failed("Hoot finished without writing the handoff.") }
            } catch {
                if panel.isWriting { panel.phase = .failed(error.localizedDescription) }
            }
        }
    }
    var requestFocus = 0
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var queueRemoval: EngineSubscription?
    @ObservationIgnored private var initialHistoryLoaded = false
    @ObservationIgnored private var initialHistoryLoading = false
    /// False while a rewind's replacement history is still paging in (or stopped part-way): Export waits for all of it.
    @ObservationIgnored private var replacedHistoryComplete = true
    /// The one shared, observed copy of Hoot's chat choices (the gear popover uses the same one).
    @ObservationIgnored let choices: HootChatChoices
    @ObservationIgnored private var choicesObserver: UUID?
    @ObservationIgnored private var sequence = -1
    private(set) var conversationID = ""
    @ObservationIgnored private var activeTurnID = ""
    @ObservationIgnored private var checkingReadiness = false
    @ObservationIgnored let fixtureMode: Bool
    @ObservationIgnored private var fixtureProjects: [PROJProject] = []
    @ObservationIgnored private var fixtureImages: [String: NSImage] = [:]
    @ObservationIgnored private let optionsInvoke: NativeHOOTSIMFeedback.Invoke?
    /// For checks: answers the chat's own verbs (say, ensure, stop) in place of the engine.
    @ObservationIgnored private let chatInvoke: NativeHOOTSIMFeedback.Invoke?
    @ObservationIgnored private var fixtureTasks: [TaskRow] = []
    @ObservationIgnored private var fixtureReports: [JobFlowEntry] = []
    /// For checks: the task list a fixture carries.
    var fixtureTasksForChecks: [TaskRow] { fixtureTasks }
    /// The agents Hoot handed work to in one job (its steps), from the app's task records and their own reports.
    func flowAgents(_ steps: [HootChatRow]) -> [HootFlowAgent] {
        let tasks = fixtureMode ? fixtureTasks : (TasksStore.shared.state?.tasks ?? [])
        return HootFlow.agents(steps: steps, tasks: tasks, reports: fixtureMode ? fixtureReports : HootFlowReports.shared.entries)
    }
    func openTask(_ id: String) {
        guard !fixtureMode else { return }
        TasksStore.shared.openTask(id); AppModel.shared.select("tasks")
    }
    /// A Needs-you box's "Reply by number": the numbers go into the message box, ready to answer.
    func replyByNumber(_ prefill: String) {
        composerDraft.text = composerDraft.text.isEmpty ? prefill : composerDraft.text + "\n" + prefill
        requestFocus += 1
    }
    /// Hoot's own conversation, or a chat session's (HootChatSource).
    @ObservationIgnored let source: HootChatSource
    @ObservationIgnored private var confirmedPermission: HootPermissionMode = .ask
    @ObservationIgnored private var confirmedModel = ""
    var projectRecords: [PROJProject] { fixtureMode ? fixtureProjects : NativePROJLabels.shared.projects }

    init(fixture: NativeRPCValue? = nil, optionsInvoke: NativeHOOTSIMFeedback.Invoke? = nil, chatInvoke: NativeHOOTSIMFeedback.Invoke? = nil,
         choices: HootChatChoices = .shared, source: HootChatSource = .hoot) {
        self.source = source
        fixtureMode = fixture != nil
        self.optionsInvoke = optionsInvoke
        self.chatInvoke = chatInvoke
        self.choices = choices
        // F50: nothing in here may save. Setting the session's default permission mode below used to save an
        // empty composer and queue over the stored ones, so every reopened chat lost them (text came back from the helper).
        restoringOutbox = true
        defer { restoringOutbox = false }
        if !source.isHoot {
            confirmedPermission = .bypass
            composerDraft.permissionMode = .bypass
        }
        if let fixture {
            fixtureProjects = (fixture["projects"].elements ?? []).compactMap { try? JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
            for field in fixture["images"].fields ?? [] {
                if let encoded = field.value.string, let bytes = Data(base64Encoded: encoded),
                   let image = NativeHOOTSIMFeedback.previewImage(bytes) { fixtureImages[field.key] = image }
            }
            accept(fixture.foundation ?? [:]); readyToSend = true
            if fixture["options"].fields != nil { applyOptions(fixture["options"]) }
            catalogue.mentions = (fixture["mentions"].elements ?? []).compactMap { row in
                guard let id = row["id"].string, let name = row["name"].string,
                      let kind = row["kind"].string.flatMap(HootMention.Kind.init(rawValue:)) else { return nil }
                return .init(id: id, kind: kind, name: name, project: row["project"].string ?? "", group: row["group"].string ?? "")
            }
            if let text = fixture["draft"].string { composerDraft.text = text }
            fixtureTasks = (fixture["tasks"].elements ?? []).compactMap { TasksDecode.task($0.foundation) }
            fixtureReports = (fixture["flowReports"].elements ?? []).compactMap { try? JSONDecoder().decode(JobFlowEntry.self, from: $0.encodedJSON()) }
        }
        if !fixtureMode {
            let id = source.sessionID ?? "hoot"
            Self.queueOwners[id] = QueueOwner(self)
            if let saved = NativeChatOutbox.load(id) {
                outboxTabKey = saved.tabKey
                if let draft = saved.draft {
                    var restored = composerDraft
                    restored.text = draft.text; restored.mentions = draft.mentions; restored.attachments = draft.attachments
                    composerDraft = restored
                }
                queuedMessages = saved.entries.map { Self.restoreQueuedMessage($0) }
                Self.queueOwners[id]?.pending = queuedMessages.isEmpty && !composerDraft.canSend ? nil : self
            }
        }
    }
    @ObservationIgnored private var draftSync: Task<Void, Never>?
    @ObservationIgnored private var draftSyncSoon: Task<Void, Never>?
    /// Typing sends the draft to the session once it pauses for 0.3 s, not once per key press (#174).
    func syncSessionDraftSoon() {
        guard !fixtureMode, !source.isHoot, !readOnly else { return }
        draftSyncSoon?.cancel()
        draftSyncSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.syncSessionDraft()
        }
    }
    func syncSessionDraft() {
        guard !fixtureMode, !source.isHoot, !readOnly else { return }
        draftSyncSoon?.cancel(); draftSyncSoon = nil
        let text = composerDraft.text, previous = draftSync
        localDraftEchoes.append(text)
        if localDraftEchoes.count > 256 { localDraftEchoes.removeFirst(localDraftEchoes.count - 256) }
        draftSync = Task {
            await previous?.value
            do { _ = try await invokeChat("draft", [text]) }
            catch { problem = error.localizedDescription }
        }
    }
    var draft: String {
        get { composerDraft.text }
        set { composerDraft.text = newValue }
    }
    /// Other screens (Routines → Fix it) hand Hoot text context. The composer
    /// carries files only, so text context joins the draft, where it can be read and edited.
    var attachments: [(name: String, value: NativeRPCValue)] {
        get { [] }
        set {
            for block in newValue {
                guard let text = block.value["text"].string, !text.isEmpty else { continue }
                composerDraft.text += (composerDraft.text.isEmpty ? "" : "\n\n") + text
            }
        }
    }
    var avatarState: HootAvatar.State {
        if readOnly { return .stopped }
        if !pending.isEmpty || pendingRoutes.count > 0 { return .waiting }
        if changingConversation { return .thinking }
        if busy || sending { return toolStep == nil ? .thinking : .working }
        // Stopped only when Hoot really cannot start; otherwise it is waking up on its own.
        if readyToSend == false || startProblem != nil { return .stopped }
        if !alive, waking { return .thinking }
        return .awake
    }
    /// Hoot wakes itself: opening the page (or a quiet backend restart) starts it, so
    /// nobody has to press Start. A real failure still shows its reason and the link.
    private(set) var startProblem: String?
    private var waking = false
    func wakeIfNeeded() {
        guard !readOnly, !fixtureMode, !loading, !alive, readyToSend != false, !waking else { return }
        waking = true
        Task {
            defer { waking = false }
            if !source.isHoot {
                // A chat session's AI starts with its window (in the same conversation after a restart).
                do { accept(try await invokeChat("ensure", [])); startProblem = nil } catch { startProblem = error.localizedDescription }
                return
            }
            do {
                let state = CopilotState.from(CodingAIJSON(try await EngineBridge.shared.invoke("hoot:ensure")))
                startProblem = state?.status == .running ? nil : (state?.problem ?? "Hoot could not start.")
                if state?.status == .running {
                    alive = true
                    if let fresh = try? await invokeChat("read", [nil, 500]) { accept(fresh) }
                }
            } catch { startProblem = error.localizedDescription }
        }
    }
    var toolStep: String? {
        activeTool.map(HootStep.name)
    }
    private var activeTool: HootChatRow? {
        guard busy, !activeTurnID.isEmpty else { return nil }
        return rows.last { $0.id.hasPrefix(activeTurnID + ":") && $0.kind == .toolCall && $0.value["finished"].bool != true }
    }
    var activityLabel: String {
        if sending { return "Reading" }
        guard let tool = activeTool else { return "Thinking" }
        switch HootStep.kind(tool) {
        case .read, .memory, .search, .web: return "Reading"
        case .plumbing, .tool:
            let words = HootStep.title(tool, live: true).lowercased()
            return ["reading", "looking", "recalling", "searching", "listing"].contains(where: words.hasPrefix) ? "Reading" : "Working"
        default: return "Working"
        }
    }
    var pendingRoutes: [NativeRPCValue] {
        currentRoutes.filter { $0["status"].string == "pending" }
    }
    /// Keep each proposal where it first appeared; later revisions replace its
    /// value in place. A later reply never moves before its proposal.
    var displayRows: [HootChatRow] {
        var latest: [String: NativeRPCValue] = [:]
        for row in rows {
            if let id = row.value["routing"]["id"].string { latest[id] = row.value["routing"] }
        }
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let id = row.value["routing"]["id"].string else { return row }
            guard seen.insert(id).inserted, let route = latest[id] else { return nil }
            var shown = row; shown.value = shown.value.setting("routing", route)
            return shown
        }
    }
    var currentRoutes: [NativeRPCValue] { displayRows.compactMap { $0.value["routing"].fields == nil ? nil : $0.value["routing"] } }
    func attachmentPreview(for row: HootChatRow) -> NSImage? {
        fixtureMode ? fixtureImages[row.id] : NativeHOOTSIMFeedback.preview(conversation: conversationID, rowID: row.id)
    }
    var status: String {
        if readOnly { return "Finished · Saved history" }
        if avatarState == .waiting { return "Waiting for your OK — \(pending.count + pendingRoutes.count) request\(pending.count + pendingRoutes.count == 1 ? "" : "s")" }
        if changingConversation { return "Starting a new chat…" }
        if let activeTool { return activityLabel + " · " + HootStep.title(activeTool, live: true) }
        if stopping { return "Stopping…" }
        if sending { return "Reading your message…" }
        if busy { return "Thinking…" }
        if readyToSend == false || startProblem != nil { return "Stopped" }
        if !alive { return waking ? "Waking up…" : "Ready" }
        let count = catalogue.mentions.filter { $0.kind == .session }.count
        return count == 0 ? "Awake · Every project" : "Awake · \(count) session\(count == 1 ? "" : "s") available"
    }
    func start() async {
        guard !fixtureMode else { return }
        guard !initialHistoryLoaded, !initialHistoryLoading else { return }
        initialHistoryLoading = true
        defer { initialHistoryLoading = false }
        if let session = source.sessionID {
            AGTAgentsStore.shared.start()
            await AGTTeamChatHistory.shared.start()
            if queueRemoval == nil {
                queueRemoval = EngineBridge.shared.on("session:removed") { [weak self] values in
                    guard values.first as? String == session, let self else { return }
                    self.readOnly = true
                    self.workingState = .idle
                    self.outgoingSend?.cancel(); self.steeringTask?.cancel()
                    self.holdQueuedMessages("Session ended. Review before sending in its replacement.")
                    self.persistQueue()
                    Self.queueOwners[session] = nil
                    Self.featureOwners[session] = nil
                }
            }
            // A chat session: its own pushes (the session's id first), its own conversation; no Hoot choices.
            if subscription == nil {
                subscription = EngineBridge.shared.on(source.event) { [weak self] values in
                    guard values.count > 1, values[0] as? String == session else { return }
                    self?.accept(values[1])
                }
            }
            readyToSend = true
            do {
                if let rows = try? await EngineBridge.shared.invoke("session:list") as? [[String: Any]],
                   let row = rows.first(where: { $0["id"] as? String == session }) {
                    outboxTabKey = row["tabKey"] as? String
                    persistQueue()
                }
                if composerDraft.canSend { _ = try await invokeChat("draft", [composerDraft.text]) }
                var cursor = 0
                repeat {
                    let raw = try await invokeChat("read", [cursor, 500])
                    accept(raw)
                    let value = try NativeRPCValue.fromFoundation(raw)
                    let next = Int(value["cursor"].number ?? 0)
                    guard value["hasMore"].bool == true, next > cursor else { break }
                    cursor = next
                } while true
                initialHistoryLoaded = true
            }
            catch { problem = error.localizedDescription; loading = false }
            // Clear a previous app attachment's queue hold when this conversation has no pending outbox.
            if !readOnly { syncQueueDepth(queuedMessages.count) }
            wakeIfNeeded()
            await loadCatalogue()
            return
        }
        if subscription == nil {
            subscription = EngineBridge.shared.on("hoot:chat:changed") { [weak self] values in
                if let value = values.first { self?.accept(value) }
            }
        }
        observeChoices()
        // HOOT-FLOW: the job flow names the agents from the task list and shows their own reports.
        TasksStore.shared.start(); HootFlowReports.shared.start()
        await refreshReadiness()
        do {
            var cursor = 0
            repeat {
                let raw = try await EngineBridge.shared.invoke("hoot:chat:read", [cursor, 500])
                accept(raw)
                let value = try NativeRPCValue.fromFoundation(raw)
                let next = Int(value["cursor"].number ?? 0)
                guard value["hasMore"].bool == true, next > cursor else { break }
                cursor = next
            } while true
            initialHistoryLoaded = true
        }
        catch { problem = error.localizedDescription; loading = false }
        wakeIfNeeded()
        await loadCatalogue()
    }
    func refreshReadiness(force: Bool = false) async {
        guard !fixtureMode, HootReadyDefaults.enabled(), !checkingReadiness else { return }
        checkingReadiness = true
        defer { checkingReadiness = false }
        do {
            let value = try await EngineBridge.shared.invoke("hoot:ready:read", [force]) as? [String: Any]
            readyToSend = value?["ready"] as? Bool
        } catch { problem = error.localizedDescription }
    }
    /// The simulator or emulator given to Hoot: shown in a phone panel beside Hoot's chat
    /// (the same device view a session's phone panel uses) until it is taken back.
    private(set) var phoneDevices: [DeviceEntry] = []
    var phoneDevice: DeviceEntry? { phoneDevices.first }
    /// The device chosen in Hoot's phone panel (the sessions' own panel) is the one Hoot uses.
    func attachPhone(_ entry: DeviceEntry?) { attachPhones(entry.map { [$0] } ?? []) }
    func attachPhones(_ entries: [DeviceEntry]) { var seen = Set<String>(); phoneDevices = Array(entries.filter { seen.insert($0.id).inserted }.prefix(2)) }
    /// Offscreen fixtures only: feed the same snapshot shape a hoot:chat:changed push carries.
    func acceptFixtureUpdate(_ value: NativeRPCValue) {
        guard fixtureMode else { return }
        accept(value.foundation ?? [:])
    }
    private func accept(_ raw: Any) {
        do {
            let value = try NativeRPCValue.fromFoundation(raw)
            if !value["attachmentLimits"].isNullish { attachmentCapabilities = value["attachmentLimits"].setting("provider", value["provider"]) }
            let id = value["conversationId"].string ?? "", next = Int(value["sequence"].number ?? 0)
            let same = conversationID == id, stale = same && next < sequence
            guard !source.isHoot || !stale else { return }
            if !same { sessionEvents = []; chatContextReadingWire = .null; chatAppliedModelReceipt = .null; chatCurrentEffectiveProviderPolicy = .null; chatReportedUsage = .null }
            chatCurrentEffectiveProviderPolicy = value["effectivePolicy"]
            chatAppliedModelReceipt = value["appliedModel"].string.map(NativeRPCValue.string) ?? .null
            if value.has("contextReading") { chatContextReadingWire = value["contextReading"] }
            conversationID = id; sequence = same ? max(sequence, next) : next
            if !source.isHoot, let revision = value["draftRevision"].number.map({ Int($0) }), revision > (toolDraftRevision ?? -1) {
                let initial = toolDraftRevision == nil
                toolDraftRevision = revision
                let incoming = value["draft"].string ?? ""
                // Revision zero is uninitialized, not an explicit user clear.
                if initial, revision == 0, incoming.isEmpty, !composerDraft.text.isEmpty { syncSessionDraft() }
                else if !sending && !localDraftEchoes.contains(incoming) { composerDraft.text = incoming }
            }
            readOnly = value["readOnly"].bool == true || (!source.isHoot && same && readOnly)
            if !source.isHoot, queuedOptions["model"] == nil, !changingOptions,
               let actual = value["model"].string, !["default", "auto", ""].contains(actual.lowercased().replacingOccurrences(of: "[1m]", with: "")), let provider = value["provider"].string {
                var shown = provider + ":" + actual
                if confirmedMillion, !actual.hasSuffix("[1m]"), catalogue.resolved[shown + "[1m]"] != nil
                    || catalogue.sections.contains(where: { section in (section.featured + section.more).contains(where: { $0.id == shown + "[1m]" }) }) { shown += "[1m]" }
                confirmedModel = shown; composerDraft.modelID = confirmedModel
            }
            var events = try (value["events"].elements ?? []).map(HootChatEvent.init(wire:))
            do {
                var kept = Dictionary(sessionEvents.map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
                for event in events { kept[event.sequence] = event }
                sessionEvents = kept.values.sorted { $0.sequence < $1.sequence }
                reconcileQueuedDeliveries()
                transcriptRevision += 1
                events = sessionEvents
                if stale { if !carriedDisplay { rows = Self.chatRows(events) }; return }
            }
            activeTurnID = events.last(where: { $0.record.kind == .user })?.turnID ?? events.last?.turnID ?? ""
            // The live model list was not there when the box read its choices (the account store answers a moment
            // after the app starts): read them again once when a new turn starts, never on a timer.
            if missingLiveList, !source.isHoot, !fixtureMode, !readOnly, !activeTurnID.isEmpty, optionsRetryTurn != activeTurnID,
               optionsTask == nil, !changingOptions {
                optionsRetryTurn = activeTurnID
                Task { [weak self] in
                    guard let raw = try? await self?.invokeOptions([]), let next = try? NativeRPCValue.fromFoundation(raw),
                          let self, self.queuedOptions.isEmpty, !self.changingOptions else { return }
                    self.applyOptions(next)
                }
            }
            thoughts = BackendChatThoughts.summaries(events)
            chatReportedUsage = value.has("cliUsage") ? value["cliUsage"] : ChatReportedUsage.latest(events)
            childTasks = value["children"].elements ?? ChatChildTasks.list(events)
            // Who an @ mention was sent to, by the turn of the message it belongs to.
            var sent: [String: [NativeRPCValue]] = [:]
            for event in events where event.record.kind == .session { if let list = event.record.value["receipts"].elements { sent[event.turnID, default: []] += list } }
            receipts = sent
            // The person's last message: did its turn ever finish? (A restart cuts a turn off with no "completed".)
            forkPrefix = value["forkPrefix"].bool == true
            providerConversationMissing = value.has("providerConversationId") && value["providerConversationId"].string?.isEmpty != false
            unfinishedTurn = forkPrefix ? nil : Self.unfinishedTurn(events)
            resuming = value["resuming"].bool == true
            var replied: [String: [NativeRPCValue]] = [:]
            for event in events where event.record.kind == .session { if let list = event.record.value["answered"].elements { replied[event.turnID, default: []] += list } }
            answered = replied
            // Asad (12 Oct): "comments will stay as the place of comments and chat will stay as a chat". A background
            // turn (a task thread, a handoff) shows NOTHING here, not even a compact line: its reply goes to the task
            // thread (or the handoff panel), and the job flow shows only the person's own chat turns.
            let nextRows = Self.chatRows(events)
            // Replacement history can arrive in pages, or as an empty startup push.
            // Keep the old display until the replacement has a complete, seeded page.
            if !carriedDisplay || (value["hasMore"].bool != true && !nextRows.isEmpty) {
                rows = nextRows
                carriedDisplay = false
            }
            if !carriedDisplay { updateTaskProgress(events) }
            let edits = rows.filter(BackendChatDiffs.isEdit)
            if edits != diffInputs { diffInputs = edits; fileDiffs = BackendChatDiffs.cards(edits) }
            if !fixtureMode { NativeHOOTSIMFeedback.retainPreviews(conversation: id, rowIDs: Set(rows.filter { $0.kind == .user }.map(\.id))) }
            pending = value["pending"].elements ?? []; busy = BackendHootChatStore.foreground(in: value)
            answering = busy
            workingState = ChatWorkingState.read(value.setting("readOnly", .bool(readOnly)), events: events)
            // The "/" menu: the commands this AI itself offers.
            if value.has("commands") { chatReportedCommands = value["commands"]; catalogue.commands = HootSlashCommand.offered(value["commands"]) }
            canUndoRewind = value["rewound"].string != nil
            if value["earlierEngine"].bool == true {
                messageActions = BackendEarlierChatMove.offeringActions(value.setting("messageActions", .null).setting("events", .array(events.map(\.wireValue))))["messageActions"].elements ?? []
            } else { messageActions = value["messageActions"].elements ?? [] }
            guardOff = value["guardOff"].string
            alive = value["alive"].bool == true
            if !busy, !sending { flushOptions() }
            if alive { startProblem = nil }
            problem = value["problem"].string; loading = rows.isEmpty && !carriedDisplay && value["hasMore"].bool == true
            flushMessages()
        } catch { problem = error.localizedDescription; loading = false }
    }
    var acceptingMessages: Bool { fixtureMode || (!stopping && !waking && (source.isHoot || alive) && startProblem == nil) }
    /// Paint the known conversation while the replacement's own catalogue/history attaches.
    /// This is UI state only; the backend owns the account and AI handover.
    func carryDisplay(from previous: NativeHootChatModel) {
        guard !source.isHoot, !previous.source.isHoot, !previous.outboxTransferred else { return }
        rows = previous.rows
        todos = previous.todos; taskProgress = previous.taskProgress
        carriedDisplay = !rows.isEmpty
        carriedAgent = previous.replyAgent
        composerDraft.text = previous.composerDraft.text
        composerDraft.mentions = previous.composerDraft.mentions
        composerDraft.attachments = previous.composerDraft.attachments
        outboxTabKey = previous.outboxTabKey
        if queuedMessages.isEmpty { queuedMessages = previous.queuedMessages }
        holdQueuedMessages("Session changed. Review before sending this queued message.")
        if !fixtureMode {
            do {
                try saveOutbox()
                if let old = previous.source.sessionID, old != source.sessionID {
                    previous.outboxTransferred = true
                    Self.queueOwners[old]?.pending = nil
                    NativeChatOutbox.remove(old)
                }
            } catch { problem = "Could not move saved drafts. " + error.localizedDescription }
        } else { previous.outboxTransferred = true }
        syncSessionDraft()
        loading = false
    }

    func statusText(_ text: String) -> String {
        let safe = NativeChatDisplayError.text(text)
        guard !source.isHoot else { return safe }
        var shown = safe.replacingOccurrences(of: "Hoot", with: source.agentName)
        if let id = source.sessionID { shown = shown.replacingOccurrences(of: id, with: "this chat") }
        return shown
    }

    var canSteerTeamChat: Bool {
        !source.isHoot && AGTTeamChatHistory.shared.rows.contains { $0["session"]["id"].string == source.sessionID && $0["finishedAt"].isNullish }
    }
    func send(_ draft: HootComposerDraft? = nil, context queuedContext: NativeRPCValue? = nil, queuedID: String? = nil) {
        guard !readOnly else { return }
        guard !fixtureMode || chatInvoke != nil, acceptingMessages, !changingConversation, readyToSend != false else { return }
        let saved = draft ?? composerDraft
        guard saved.canSend else { return }
        // Only text the person just typed can open an app control. A queued message (a mark's note, an agent's
        // queued text, an edited row) is plain text: it must never re-route on every flush or block the queue.
        if queuedID == nil {
            do { if let command = try NativeChatCommands.appControl(in: saved.text, offered: catalogue.commands) { routeSlashCommand(command); return } }
            catch { problem = error.localizedDescription; return }
        }
        do { try attachmentLimits.validateFiles(saved.attachments.map(\.url)) }
        catch { problem = error.localizedDescription; return }
        for viewport in chatViewports.values { viewport.latest() }
        if busy || sending || changingOptions || !pending.isEmpty || steeringQueuedID != nil {
            queuedMessages.append(.init(draft: saved, context: queuedContext))
            clearDraft(saved)
            return
        }
        sending = true; startingCompact = Self.isCompact(saved.plainText); problem = nil; rewindProblem = nil
        if let queuedID, let index = queuedMessages.firstIndex(where: { $0.id == queuedID }) {
            queuedMessages[index].held = true
            queuedMessages[index].problem = nil
        }
        clearDraft(saved)
        outgoingSend = Task {
            defer { sending = false; startingCompact = false; outgoingSend = nil; if !busy { flushOptions() }; flushMessages() }
            var handedOver = false
            do {
                try attachmentLimits.validateFiles(saved.attachments.map(\.url))
                let blocks = try saved.attachments.map { try NativeHOOTSIMFeedback.attachment(url: $0.url) }
                try attachmentLimits.validate(blocks)
                // The device given to Hoot rides along with every message, so Hoot's device
                // tools act on it; nothing is typed into the box.
                var mentions = saved.activeMentions.filter { !$0.isReference }
                for phone in phoneDevices where !mentions.contains(where: { $0.id == phone.id }) {
                    mentions.append(HootMention(id: phone.id, kind: .simulator, name: phone.name))
                }
                var humanContext: [String: Any] = ["mentions": mentions.map { $0.wire.foundation ?? [:] }, "source": ["title": DeckOwner.messageTitle]]
                let references = try await referenceContent(saved)
                if !references.isEmpty { humanContext["files"] = references.map { $0.foundation ?? [:] } }
                let context = try NativeCapturedFeedback.deliveryContext(queuedContext)?.foundation ?? humanContext
                if !source.isHoot { accept(try await invokeChat("ensure", [])) }
                try Task.checkCancellation()
                if let queuedID, !queuedMessages.contains(where: { $0.id == queuedID }) { return }
                handedOver = true
                if let queuedID, let index = queuedMessages.firstIndex(where: { $0.id == queuedID }) { queuedMessages[index].deliveryPending = true }
                let receipt = try await invokeChat("say", [saved.plainText, blocks.map { $0.foundation ?? NSNull() }, context, queuedID])
                NativeHOOTSIMFeedback.rememberPreview(receipt: receipt, message: saved.plainText, attachments: blocks, source: .object([]))
                accept(receipt)
                if let queuedID, queuedMessages.contains(where: { $0.id == queuedID }) {
                    throw NativeRPCError(code: "uncertain-delivery", message: "The keeper did not confirm this message's delivery.")
                }
                clearDraft(saved)
                HootPastedFiles.discard(saved.attachments.map(\.url))   // U144 (#535): sent, so its pasted pictures go
                if source.isHoot { NativeHootModel.shared.refresh() }
            } catch {
                // Stop before `say` took the message: nothing was sent, so the typed text goes back in the box
                // (a queued message stays in the queue, held by Stop). Once `say` has it, Stop never brings it back.
                let stoppedBeforeSay = Task.isCancelled && !handedOver
                if !Task.isCancelled || stoppedBeforeSay {
                    if let queuedID, let index = queuedMessages.firstIndex(where: { $0.id == queuedID }) {
                        queuedMessages[index].held = true
                        if Self.definitivelyRejected(error) { queuedMessages[index].deliveryPending = false }
                        if !stoppedBeforeSay { queuedMessages[index].problem = Self.notSentYet(error.localizedDescription) }
                    } else {
                        // 28 Oct (his pictures sat in the box with only "JSON body is too large"): say plainly that
                        // the message was not sent and where it is, never leave it silently in the box.
                        let restored = !composerDraft.canSend
                        if restored {
                            composerDraft.text = saved.text
                            composerDraft.mentions = saved.mentions
                            composerDraft.attachments = saved.attachments
                        }
                        if !stoppedBeforeSay { problem = Self.notSent(error.localizedDescription, restored: restored, pictures: saved.attachments.count) }
                    }
                }
            }
        }
    }
    /// A failed send in plain words: that it was not sent, why, and where the message is now.
    static func notSent(_ reason: String, restored: Bool, pictures: Int) -> String {
        let what = pictures == 0 ? "Your message" : pictures == 1 ? "Your message and its attachment" : "Your message and its \(pictures) attachments"
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = trimmed.isEmpty ? "" : " " + (trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
        return "Not sent." + why + (restored ? " \(what) \(pictures > 0 ? "are" : "is") back in the box; send again when ready." : "")
    }
    private func clearDraft(_ saved: HootComposerDraft) {
        if composerDraft == saved {
            composerDraft.text = ""; composerDraft.mentions = []; composerDraft.attachments = []
        }
    }
    private func syncQueueDepth(_ count: Int) {
        guard !fixtureMode, !source.isHoot else { return }
        let previous = queueDepthSync
        queueDepthSync = Task {
            await previous?.value
            do { _ = try await invokeChat("queued", [count]) }
            catch {
                if count > 0 {
                    for index in queuedMessages.indices where queuedMessages[index].problem == nil {
                        queuedMessages[index].problem = error.localizedDescription
                    }
                }
            }
        }
    }
    @ObservationIgnored private var restoringOutbox = false
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    /// Typing saves the draft once it pauses for 0.3 s, not on every key press (#174). A queue change saves at once,
    /// the draft with it.
    private func persistDraftSoon() {
        guard !fixtureMode, !outboxTransferred, !restoringOutbox else { return }
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistQueue()
        }
    }
    private func persistQueue() {
        draftSave?.cancel(); draftSave = nil
        guard !fixtureMode, !outboxTransferred, !restoringOutbox else { return }
        do { try saveOutbox() }
        catch { problem = "Could not save queued messages. " + error.localizedDescription }
    }
    private func saveOutbox() throws {
            let entries = try queuedMessages.map {
                NativeChatOutbox.Entry(id: $0.id, draft: $0.draft, context: try $0.context?.encodedJSON(), held: $0.held || $0.editing,
                    problem: $0.editing ? "Editing was interrupted. Review before sending after restart." : $0.problem, deliveryPending: $0.deliveryPending, editedPendingDelivery: $0.deliveryPending && $0.editing && $0.draft.text != $0.originalText)
            }
            try NativeChatOutbox.save(source.sessionID ?? "hoot", name: source.agentName, entries: entries,
                draft: composerDraft, tabKey: outboxTabKey)
    }
    func holdQueuedMessages(_ reason: String) {
        for index in queuedMessages.indices {
            queuedMessages[index].held = true
            queuedMessages[index].problem = reason
        }
    }
    @discardableResult func moveQueued(_ id: String, before target: String?) -> Bool {
        guard steeringQueuedID == nil, !sending, !stopping, id != target,
              let from = queuedMessages.firstIndex(where: { $0.id == id }),
              target == nil || queuedMessages.contains(where: { $0.id == target }) else { return false }
        var next = queuedMessages
        let item = next.remove(at: from)
        let to = target.flatMap { target in next.firstIndex { $0.id == target } } ?? next.count
        next.insert(item, at: to)
        queuedMessages = next
        return true
    }
    private func flushMessages() {
        guard !busy, !sending, !stopping, !readOnly, !changingOptions, pending.isEmpty, problem == nil,
              !changingConversation, readyToSend != false, steeringQueuedID == nil,
              acceptingMessages, let first = queuedMessages.first, !first.editing, !first.held, !first.deliveryPending else { return }
        send(first.draft, context: first.context, queuedID: first.id)
    }
    func editQueued(_ id: String, editing: Bool) {
        guard steeringQueuedID == nil, let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        if editing, !queuedMessages[index].editing { queuedMessages[index].originalText = queuedMessages[index].draft.text }
        queuedMessages[index].editing = editing
        if !editing {
            guard queuedMessages[index].draft.canSend else { queuedMessages[index].editing = true; return }
            if queuedMessages[index].deliveryPending, queuedMessages[index].draft.text != queuedMessages[index].originalText {
                queuedMessages[index].id = UUID().uuidString.lowercased()
                queuedMessages[index].deliveryPending = false
            }
            if !queuedMessages[index].deliveryPending {
                queuedMessages[index].held = false; queuedMessages[index].problem = nil
            }
            reconcileQueuedDeliveries()
            flushMessages()
        }
    }
    func cancelQueuedEdit(_ id: String) {
        guard steeringQueuedID == nil, let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        queuedMessages[index].draft.text = queuedMessages[index].originalText
        queuedMessages[index].editing = false
        reconcileQueuedDeliveries()
        flushMessages()
    }
    func queuedText(_ id: String) -> String { queuedMessages.first { $0.id == id }?.draft.text ?? "" }
    func setQueuedText(_ id: String, text: String) {
        guard steeringQueuedID == nil, text.utf8.count <= 262_144, let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        queuedMessages[index].draft.text = text
    }
    func removeQueued(_ id: String) {
        guard steeringQueuedID == nil else { return }
        queuedMessages.removeAll { $0.id == id }; flushMessages()
    }
    func sendQueuedNow(_ id: String) {
        guard steeringTask == nil else { return }
        steeringTask = Task {
            defer { steeringTask = nil }
            do { try await steerQueued(id) } catch { /* The row keeps its delivery error and its message. */ }
        }
    }
    func steerQueued(_ id: String) async throws {
        guard steeringQueuedID == nil, !sending, !stopping, !changingOptions, !readOnly, acceptingMessages,
              let item = queuedMessages.first(where: { $0.id == id }), !item.editing else {
            throw NativeRPCError(code: "busy", message: "Finish editing or sending this chat's message first.")
        }
        steeringQueuedID = id
        if let index = queuedMessages.firstIndex(where: { $0.id == id }) {
            queuedMessages[index].held = true
            queuedMessages[index].problem = nil
        }
        defer { steeringQueuedID = nil; flushMessages() }
        if item.deliveryPending {
            if let fresh = try? await invokeChat("read", [nil, 500]) { accept(fresh) }
            guard queuedMessages.contains(where: { $0.id == id }) else { return }
            let reason = Self.notSentYet("The keeper has not confirmed the earlier attempt.")
            if let index = queuedMessages.firstIndex(where: { $0.id == id }) { queuedMessages[index].problem = reason }
            throw NativeRPCError(code: "uncertain-delivery", message: reason)
        }
        do {
            let blocks = try item.draft.attachments.map { try NativeHOOTSIMFeedback.attachment(url: $0.url) }
            try attachmentLimits.validate(blocks)
            var humanContext: [String: Any] = ["mentions": item.draft.activeMentions.filter { !$0.isReference }.map { $0.wire.foundation ?? [:] }, "source": ["title": DeckOwner.messageTitle]]
            let references = try await referenceContent(item.draft)
            if !references.isEmpty { humanContext["files"] = references.map { $0.foundation ?? [:] } }
            let context = try NativeCapturedFeedback.deliveryContext(item.context)?.foundation ?? humanContext
            guard queuedMessages.contains(where: { $0.id == id }) else { return }
            if let index = queuedMessages.firstIndex(where: { $0.id == id }) { queuedMessages[index].deliveryPending = true }
            let receipt = try await invokeChat("steer", [item.draft.plainText, blocks.map { $0.foundation ?? NSNull() }, context, id])
            try Task.checkCancellation()
            accept(receipt)
            guard !queuedMessages.contains(where: { $0.id == id }) else {
                throw NativeRPCError(code: "uncertain-delivery", message: "The keeper did not confirm this message's delivery.")
            }
        } catch {
            // A read can race the original send. Absence, even in a successful read, never releases it.
            if Self.deliveryUnknown(error), let fresh = try? await invokeChat("read", [nil, 500]) { accept(fresh) }
            if !queuedMessages.contains(where: { $0.id == id }) { return }
            if let index = queuedMessages.firstIndex(where: { $0.id == id }) {
                queuedMessages[index].problem = Self.notSentYet(error.localizedDescription)
                queuedMessages[index].held = true
                if Self.definitivelyRejected(error) { queuedMessages[index].deliveryPending = false }
            }
            throw error
        }
    }
    /// These rejections happen before input is written. Other failures remain uncertain.
    private static func definitivelyRejected(_ error: Error) -> Bool {
        ["busy", "invalid-arguments", "provider-input-limit", "decision-held", "steer-rejected", "chat-steering-unavailable"]
            .contains((error as? NativeRPCError)?.code ?? "")
    }
    /// The reply never came (a connection that failed or timed out), so whether the message arrived is unknown.
    static func deliveryUnknown(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return ["uncertain-delivery", "uncertain-steer"].contains((error as? NativeRPCError)?.code ?? "") || text.contains("connection failed") || text.contains("POSIX status") || text.contains("timed out")
    }
    /// Only the keeper's post-write receipt proves delivery. The earlier user row does not.
    static func arrived(_ id: String, in events: [HootChatEvent]) -> Bool {
        !id.isEmpty && events.contains { $0.record.kind == .session
            && $0.record.value["clientMessageId"].string == id && $0.record.value["deliveryConfirmed"].bool == true }
    }
    private func reconcileQueuedDeliveries() {
        let delivered = queuedMessages.filter { !$0.editing && Self.arrived($0.id, in: sessionEvents) }
        guard !delivered.isEmpty else { return }
        let ids = Set(delivered.map(\.id))
        queuedMessages.removeAll { ids.contains($0.id) }
        HootPastedFiles.discard(delivered.flatMap { $0.draft.attachments.map(\.url) })
    }
    static func notSentYet(_ reason: String) -> String {
        "Not sent. " + reason + " Your message is back in the box. Delivery is unconfirmed; it will not send again automatically."
    }
    func queueTool(_ operation: String, id: String?, text: String?, before: String? = nil, context: NativeRPCValue) async throws -> NativeRPCValue {
        if operation == "queue" {
            guard !readOnly, acceptingMessages, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 262_144 else { throw NativeRPCError.invalidArguments("This chat needs a nonempty message of at most 256 KiB.") }
            var draft = composerDraft; draft.text = text; draft.mentions = []; draft.attachments = []
            queuedMessages.append(.init(draft: draft, context: context)); flushMessages()
        } else if operation != "list" {
            guard let id, queuedMessages.contains(where: { $0.id == id }), steeringQueuedID == nil else {
                throw NativeRPCError(code: "not-found", message: "That queued message is no longer available.")
            }
            switch operation {
            case "edit":
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 262_144 else { throw NativeRPCError.invalidArguments("Supply nonempty text of at most 256 KiB.") }
                editQueued(id, editing: true)
                setQueuedText(id, text: text); editQueued(id, editing: false)
            case "remove": removeQueued(id)
            case "reorder":
                guard moveQueued(id, before: before) else { throw NativeRPCError.invalidArguments("Choose another queued message to move before, or omit beforeId to move to the end.") }
            case "send-now": try await steerQueued(id)
            default: throw NativeRPCError.invalidArguments("Unknown queue action.")
            }
        }
        return .array(queuedMessages.map { .object([.init("id", .string($0.id)), .init("text", .string($0.draft.plainText)),
            .init("draft", $0.draft.wire), .init("context", $0.context ?? .null),
            .init("editing", .bool($0.editing)), .init("held", .bool($0.held)), .init("deliveryPending", .bool($0.deliveryPending)), .init("problem", $0.problem.map(NativeRPCValue.string) ?? .null)]) })
    }
    func queueCapture(text: String, paths: [String], source capture: NativeRPCValue,
                      validate: @MainActor () async throws -> Void = {}) async throws -> String {
        guard !readOnly, acceptingMessages, !changingConversation, text.utf8.count <= 262_144 else {
            throw NativeRPCError.invalidArguments("This chat cannot accept the capture yet. Keep it and try again.")
        }
        var draft = composerDraft
        draft.text = text; draft.mentions = []; draft.attachments = paths.map { .init(url: URL(fileURLWithPath: $0)) }
        guard draft.canSend else { throw NativeRPCError.invalidArguments("There is no capture or note to send.") }
        try attachmentLimits.validateFiles(draft.attachments.map(\.url))
        try attachmentLimits.validate(draft.attachments.map { try NativeHOOTSIMFeedback.attachment(url: $0.url) })
        try await validate()
        let tagged = try NativeCapturedFeedback.chatSource(capture)
        let item = QueuedMessage(draft: draft, context: .object([.init("source", tagged)]))
        // Hold a team chat before acknowledging the capture; its answer may finish while the picture is prepared.
        if !fixtureMode, !source.isHoot { _ = try await invokeChat("queued", [queuedMessages.count + 1]) }
        do {
            try await validate()
            guard !readOnly else { throw NativeRPCError.invalidArguments("That chat closed. The capture was not sent.") }
            let next = queuedMessages + [item]
            if !fixtureMode {
                let entries = try next.map { NativeChatOutbox.Entry(id: $0.id, draft: $0.draft,
                    context: try $0.context?.encodedJSON(), held: $0.held || $0.editing, problem: $0.problem, deliveryPending: $0.deliveryPending, editedPendingDelivery: $0.deliveryPending && $0.editing && $0.draft.text != $0.originalText) }
                try NativeChatOutbox.save(source.sessionID ?? "hoot", name: source.agentName, entries: entries,
                    draft: composerDraft, tabKey: outboxTabKey)
            }
            queuedMessages = next
        } catch {
            if !fixtureMode, !source.isHoot { _ = try? await invokeChat("queued", [queuedMessages.count]) }
            throw error
        }
        flushMessages()
        return item.id
    }
    /// Bypass included: hoot:chat:options saves it as Hoot's choice, so Settings → Hoot and the
    /// quick popover show the same Bypass (U91: no second write beside the shared one).
    func changePermission(_ mode: HootPermissionMode) { changeOptions(permission: mode.rawValue) }
    func changeModel(_ id: String) {
        guard !fixtureMode || optionsInvoke != nil else { return }
        chatRequestedModel = id; composerDraft.modelID = id; chatFeatureRevision += 1
        changeOptions(model: id)
    }
    func changeEffort(_ effort: String) { changeOptions(effort: effort) }
    /// Fast mode is a saved Coding AI setting; it applies on Hoot's next message, silently, like
    /// effort and permissions. Hoot's goes through the shared choices, so every view shows it (U91).
    func changeFastMode(_ on: Bool) {
        guard !fixtureMode || optionsInvoke != nil else { return }
        if let index = catalogue.sections.firstIndex(where: { $0.fastMode != nil }) { catalogue.sections[index].fastMode = on }
        changeOptions(fastMode: on)
    }
    /// Setting changes apply in the background; nothing greys out or blocks. A permission change
    /// goes through at once, even while Hoot is thinking or typing (the backend answers waiting
    /// prompts and switches Claude's live mode). A model or effort change made mid-turn shows at
    /// once and is applied when the turn ends (Hoot's CLI restarts with it).
    @ObservationIgnored private var queuedOptions: [String: String] = [:]
    private func changeOptions(permission: String? = nil, model: String? = nil, effort: String? = nil, fastMode: Bool? = nil) {
        guard !fixtureMode || optionsInvoke != nil else { return }
        if let permission { queuedOptions["permissionMode"] = permission }
        if let model { queuedOptions["model"] = model }
        if let effort { queuedOptions["effort"] = effort }
        if let fastMode { queuedOptions["fastMode"] = fastMode ? "true" : "false" }
        problem = nil
        flushOptions()
    }
    private func flushOptions() {
        guard !changingOptions, !changingConversation, !queuedOptions.isEmpty else { return }
        var patch = queuedOptions
        if busy || sending {
            guard let permission = patch["permissionMode"] else { return }
            patch = ["permissionMode": permission]
        }
        for key in patch.keys { queuedOptions[key] = nil }
        changingOptions = true; chatSavingModel = patch["model"]; chatFeatureRevision += 1
        optionsTask = Task {
            defer { optionsTask = nil; changingOptions = false; chatSavingModel = nil; chatFeatureRevision += 1; flushOptions(); flushMessages() }
            do {
                var wire: [String: Any] = patch
                if let fast = patch["fastMode"] { wire["fastMode"] = fast == "true" }
                if optionsInvoke != nil || !source.isHoot { applyOptions(try NativeRPCValue.fromFoundation(await invokeOptions([wire]))) }
                else { try await choices.change(wire) }   // every observer (popover included) updates
            }
            catch {
                restoreConfirmedOptions()
                problem = error.localizedDescription
                await loadCatalogue()
            }
        }
    }
    func newChat() {
        // A setting saving in the background never blocks New chat: start it right after.
        if changingOptions, !fixtureMode {
            let saving = optionsTask
            Task { await saving?.value; newChat() }
            return
        }
        guard source.isHoot, !fixtureMode, !busy, !sending, !changingConversation else { return }
        changingConversation = true
        rewindProblem = nil; problem = nil
        Task {
            defer { changingConversation = false }
            do {
                let fresh = try await EngineBridge.shared.invoke("hoot:chat:new")
                replaceConversation(fresh)
                composerDraft.text = ""; composerDraft.mentions = []; composerDraft.attachments = []
                await loadCatalogue()
            }
            catch { problem = error.localizedDescription }
        }
    }
    /// A rewind or undo replaces history with the whole conversation, paged from the start like the first load, so an
    /// Export afterwards still holds every event (one newest page kept at most 500).
    private func reloadConversation() async throws {
        replacedHistoryComplete = false
        var cursor = 0
        repeat {
            let raw = try await invokeChat("read", [cursor, 500])
            if cursor == 0 { replaceConversation(raw) } else { accept(raw) }
            let value = try NativeRPCValue.fromFoundation(raw)
            let next = Int(value["cursor"].number ?? 0)
            guard value["hasMore"].bool == true, next > cursor else { break }
            cursor = next
        } while true
        replacedHistoryComplete = true
    }
    /// A rewind or new chat replaces history; ordinary stream packets merge it.
    private func replaceConversation(_ raw: Any) {
        sessionEvents = []; transcriptRevision += 1; rows = []; sequence = -1
        progressCursor = -1; progressConversation = ""
        receipts = [:]; answered = [:]; pending = []; resent = []
        unfinishedTurn = nil; resuming = false; canUndoRewind = false
        rewindProblem = nil; problem = nil
        accept(raw)
    }
    func stop() {
        guard !fixtureMode || chatInvoke != nil, !stopping else { return }
        stopRevision += 1; stopping = true
        steeringTask?.cancel()
        holdQueuedMessages("Stopped. Review before sending this queued message.")
        let outbound = outgoingSend ?? steeringTask
        outbound?.cancel()
        Task {
            defer { stopping = false }
            do {
                accept(try await invokeChat("stop", []))
                if let outbound {
                    await outbound.value
                    // A send already accepted while Stop crossed it is still ours.
                    if busy, !readOnly { accept(try await invokeChat("stop", [])) }
                }
                if source.isHoot { NativeHootModel.shared.refresh() }
            } catch { problem = error.localizedDescription }
        }
    }
    private(set) var answeringRequestID: String?
    func answer(_ id: String, allowed: Bool, answers: NativeRPCValue = .object([])) {
        guard !fixtureMode, answeringRequestID == nil else { return }
        answeringRequestID = id
        Task {
            defer { answeringRequestID = nil }
            do { accept(try await invokeChat("answer", [id, allowed, answers.foundation ?? [:]])) }
            catch { problem = error.localizedDescription }
        }
    }
    func routeAnswer(_ route: NativeRPCValue, decision: String, target: NativeRPCValue = .null) {
        guard !fixtureMode else { return }
        Task {
            do {
                _ = try await EngineBridge.shared.invoke("hoot:route:answer", [route["id"].foundation ?? "", route["revision"].foundation ?? 1, decision, target.foundation ?? NSNull()])
            } catch { problem = error.localizedDescription }
        }
    }
    /// One source of truth: whoever changes Hoot's model, effort, permission or Fast mode (this
    /// box, the island's box, the gear popover, Settings → Hoot) writes through the shared
    /// HootChatChoices, and this box redraws at once from it.
    func observeChoices() {
        guard choicesObserver == nil else { return }
        choicesObserver = choices.addObserver { [weak self] value in self?.applyOptions(value) }
    }
    private func loadCatalogue() async {
        guard !readOnly else { return }
        if !source.isHoot, !fixtureMode {
            do { applyOptions(try NativeRPCValue.fromFoundation(await invokeOptions([]))); await loadContextMentionCatalogue() }
            catch { problem = error.localizedDescription }
            return
        }
        if fixtureMode {
            guard optionsInvoke != nil else { return }
            do { applyOptions(try NativeRPCValue.fromFoundation(await invokeOptions([]))) }
            catch { problem = error.localizedDescription }
            return // A fixture never reads accounts, projects, sessions or devices.
        }
        await choices.reload()
        await loadContextMentionCatalogue()
    }
    private func loadContextMentionCatalogue() async {
        guard !fixtureMode else { return }
        if mentionFeed.isEmpty {
            // A session started, ended or renamed, or an agent changed: read the list again, once per burst.
            mentionFeed = Self.mentionEvents.map { event in
                EngineBridge.shared.on(event) { [weak self] _ in
                    guard let self else { return }
                    self.mentionReload?.cancel()
                    self.mentionReload = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        await self?.loadContextMentionCatalogue()
                    }
                }
            }
        }
        do {
            let sessions = BrowserSessionChoice.read(try await EngineBridge.shared.invoke("session:list"))
            let labels = NativePROJLabels.shared
            labels.start()
            var mentions = sessions.map {
                let projectID = PROJProjects.resolve(projectID: nil, folder: $0.cwd, projects: labels.projects)
                return HootMention(id: $0.id, kind: .session, name: $0.label, project: labels.name(for: projectID), group: projectID)
            }
            for (id, name) in [("agents-all", "Agents"), ("tasks", "Tasks"), ("artifacts", "Artifacts"), ("servers", "Servers")] {
                mentions.append(.init(id: id, kind: .page, name: name))
            }
            if let raw = try? await EngineBridge.shared.invoke("tasks:state"), let rows = (try? NativeRPCValue.fromFoundation(raw))?["agents"].elements {
                mentions += rows.compactMap { row in
                    guard let id = row["id"].string, let name = row["name"].string, row["status"].string != "archived" else { return nil }
                    let projectID = PROJProjects.resolve(projectID: row["projectId"].string, folder: row["defaultProject"].string, projects: labels.projects)
                    return HootMention(id: id, kind: .agent, name: name, project: labels.name(for: projectID), group: projectID)
                }
            }
            if let raw = try? await EngineBridge.shared.invoke("devices:list"), let devices = (try? NativeRPCValue.fromFoundation(raw))?["devices"].elements {
                mentions += devices.compactMap { row in
                    guard let id = row["id"].string, let name = row["name"].string else { return nil }
                    return HootMention(id: id, kind: .simulator, name: name)
                }
            }
            catalogue.mentions = mentions
        } catch { problem = error.localizedDescription }
    }
    func projectReferenceRoot() async throws -> String {
        if !referenceRoot.isEmpty { return referenceRoot }
        if let id = source.sessionID {
            let raw = try await EngineBridge.shared.invoke("session:list")
            referenceRoot = TerminalSessionInfo.find(id, in: raw)?.cwd ?? ""
        } else {
            let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("hoot:state"))
            referenceRoot = raw["cwd"].string ?? raw["folder"].string ?? ""
        }
        guard !referenceRoot.isEmpty else { throw NativeRPCError.invalidArguments("Choose a project's chat before adding file context.") }
        return referenceRoot
    }
    func searchReferences(_ query: String?) {
        referenceSearch?.cancel()
        guard !fixtureMode, let query else { catalogue.referenceLoading = false; return }
        catalogue.referenceLoading = true; catalogue.referenceProblem = nil
        referenceSearch = Task {
            defer { if !Task.isCancelled { catalogue.referenceLoading = false } }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let root = try await projectReferenceRoot()
                let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("search:files", [["root": root, "limit": 10_000]]))
                try Task.checkCancellation()
                guard raw["ok"].bool == true else { return }
                let candidates = BackendChatReferences.candidates(raw["files"].elements?.compactMap(\.string) ?? [], query: query)
                catalogue.mentions = catalogue.mentions.filter { !$0.isReference } + candidates.compactMap { row in
                    guard let path = row["path"].string, let kind = row["kind"].string.flatMap(HootMention.Kind.init(rawValue:)), let name = row["name"].string else { return nil }
                    return HootMention(id: path, kind: kind, name: name, project: path, group: "Project files")
                }
            } catch { if !Task.isCancelled { catalogue.referenceProblem = error.localizedDescription } }
        }
    }
    func addReference(path: String, kind: String, root: String) throws -> NativeRPCValue {
        guard !readOnly, ["file", "folder"].contains(kind), let kind = HootMention.Kind(rawValue: kind) else { throw NativeRPCError.invalidArguments("Choose a file or folder in this chat's project.") }
        let path = try BackendChatReferences.relative(path)
        referenceRoot = root
        composerDraft.insert(.init(id: path, kind: kind, name: (path as NSString).lastPathComponent, project: path, group: "Project files"))
        Self.queueOwners[source.sessionID ?? "hoot"]?.pending = self
        syncSessionDraft()
        return .object([.init("draft", .string(composerDraft.text)), .init("references", .array(composerDraft.activeMentions.filter(\.isReference).map(\.wire)))])
    }
    private func referenceContent(_ draft: HootComposerDraft) async throws -> [NativeRPCValue] {
        let references = draft.activeMentions.filter(\.isReference)
        guard references.count <= 8 else { throw NativeRPCError.invalidArguments("Attach up to eight file or folder references.") }
        if references.isEmpty { return [] }
        let root = try await projectReferenceRoot()
        var result: [NativeRPCValue] = []
        for reference in references {
            let path = try BackendChatReferences.relative(reference.id)
            let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke(reference.kind == .folder ? "fs:list" : "fs:read", reference.kind == .folder ? [root, path] : [root, path, true]))
            result.append(try BackendChatReferences.content(path: path, kind: reference.kind.rawValue, value: raw))
        }
        return result
    }
    /// One of the chat's own calls (say, read, stop, answer, ensure) for whoever's conversation this is. For Hoot the
    /// channel and arguments are exactly the ones it always sent.
    func invokeChat(_ verb: String, _ arguments: [Any?]) async throws -> Any {
        if let chatInvoke { return try await chatInvoke(source.channel(verb), source.arguments(arguments)) }
        return try await EngineBridge.shared.invoke(source.channel(verb), source.arguments(arguments))
    }
    private func invokeOptions(_ arguments: [Any?]) async throws -> Any {
        if let optionsInvoke { return try await optionsInvoke("hoot:chat:options", arguments) }
        // A chat session's own permission, model and effort (`session:chat:options`).
        if !source.isHoot { return try await invokeChat("options", arguments) }
        return try await EngineBridge.shared.invoke("hoot:chat:options", arguments)
    }
    private func restoreConfirmedOptions() {
        composerDraft.permissionMode = confirmedPermission
        composerDraft.modelID = confirmedModel
        composerDraft.effort = confirmedEffort
    }
    @ObservationIgnored private var confirmedEffort = ""
    /// The chat runs on Claude Code's 1M window ("opus[1m]"): the model it reports (named without "[1m]") shows as that choice.
    @ObservationIgnored private var confirmedMillion = false
    /// The AI in use has a live model list (Claude, Codex) and it was not loaded at the last read; tried again per turn.
    @ObservationIgnored private var missingLiveList = false
    @ObservationIgnored private var optionsRetryTurn = ""
    private func applyOptions(_ value: NativeRPCValue) {
        if let ready = value["ready"].bool { readyToSend = ready }
        if let mode = value["permissionMode"].string.flatMap(HootPermissionMode.init(rawValue:)) {
            confirmedPermission = mode; composerDraft.permissionMode = mode
        }
        if let model = value["model"].string { confirmedModel = model; composerDraft.modelID = model; confirmedMillion = model.hasPrefix("claude:") && model.hasSuffix("[1m]") }
        if let effort = value["effort"].string { confirmedEffort = effort; composerDraft.effort = effort }
        catalogue.efforts = (value["efforts"].elements ?? []).compactMap(\.string)
        // L5's live catalogue, EVERY installed Coding AI at once (one section each), so he can
        // always switch back: featured (newest of each line), more (older), Fast mode.
        let names = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"]
        let currentID = value["model"].string ?? ""
        let currentProvider = currentID.split(separator: ":").first.map(String.init) ?? ""
        var sections: [HootModelSection] = []
        for provider in ["claude", "codex", "gemini"] {
            let live = value["catalog"][provider], rows = (live["models"].elements ?? []).filter { !["default", "auto", ""].contains(($0["id"].string ?? "").lowercased().replacingOccurrences(of: "[1m]", with: "")) }
            let name = names[provider] ?? provider
            func models(_ key: String) -> [HootComposerModel] {
                (live[key].elements ?? []).compactMap(\.string).compactMap { id in
                    rows.first(where: { $0["id"].string == id }).map {
                        HootComposerModel(id: provider + ":" + id, provider: name, name: $0["name"].string ?? id)
                    }
                }
            }
            var section = HootModelSection(id: provider, name: name, featured: models("featured"), more: models("more"))
            if provider == currentProvider { missingLiveList = provider != "gemini" && section.featured.isEmpty && section.more.isEmpty }
            if section.featured.isEmpty && section.more.isEmpty {
                // No live list for this AI: just its current model (installed AIs only).
                let offered = (value["models"].elements ?? []).compactMap { row -> HootComposerModel? in
                    guard let id = row["id"].string, id.hasPrefix(provider + ":"), !["default", "auto", ""].contains((id.split(separator: ":").last.map(String.init) ?? "").lowercased().replacingOccurrences(of: "[1m]", with: "")) else { return nil }
                    let tail = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
                    let shown = row["name"].string ?? tail
                    // A bare CLI alias ("opus") reads as a name ("Opus") when no live list loaded.
                    return HootComposerModel(id: id, provider: name, name: shown == tail ? tail.replacingOccurrences(of: "[1m]", with: "").capitalized : shown)
                }
                if let current = offered.first(where: { $0.id == currentID }) ?? offered.first {
                    section.featured = [current]
                } else if let configured = live["current"].string, !["default", "auto", ""].contains(configured.lowercased().replacingOccurrences(of: "[1m]", with: "")) {
                    section.featured = [HootComposerModel(id: provider + ":" + configured, provider: name, name: configured)]
                } else { continue }
            }
            // Fast mode is a setting of the AI in use (saved choices belong to the selected AI).
            if provider == currentProvider, live["fastMode"]["available"].bool == true {
                section.fastMode = value["fastMode"].bool ?? (live["fastMode"]["on"].bool == true)
            }
            sections.append(section)
        }
        catalogue.sections = sections
        // A CLI alias in use (opus / sonnet / haiku / fable / opusplan, maybe with [1m]) means the
        // newest live model of that line: show and tick that one.
        // "opus[1m]" ticks the 1M choice of that line when the list has one (chat sessions do).
        catalogue.resolved = [:]
        let rawModel = currentID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        if let section = sections.first(where: { $0.id == currentProvider }),
           !(section.featured + section.more).contains(where: { $0.id == currentID }),
           let live = BackendSessionChats.liveModel(forAlias: rawModel, in: value["catalog"][currentProvider]),
           (section.featured + section.more).contains(where: { $0.id == currentProvider + ":" + live }) {
            catalogue.resolved[currentID] = currentProvider + ":" + live
        }
        // Claude Code's own list names a choice by its alias ("opus"); the model it reports in use ("claude-opus-5-5")
        // is that choice.
        let listed = sections.first(where: { $0.id == currentProvider }).map { $0.featured + $0.more } ?? []
        for row in value["catalog"][currentProvider]["models"].elements ?? [] {
            guard let id = row["id"].string, let means = row["resolvedModel"].string, catalogue.resolved[currentProvider + ":" + means] == nil,
                  !listed.contains(where: { $0.id == currentProvider + ":" + means }) else { continue }
            catalogue.resolved[currentProvider + ":" + means] = currentProvider + ":" + id
        }
        // A choice still waiting for the turn to end keeps showing.
        if let mode = queuedOptions["permissionMode"].flatMap(HootPermissionMode.init(rawValue:)) { composerDraft.permissionMode = mode }
        if let model = queuedOptions["model"] { composerDraft.modelID = model }
        if let effort = queuedOptions["effort"] { composerDraft.effort = effort }
        catalogue.recommendedEffort = value["recommendedEffort"].string
        catalogue.models = (value["models"].elements ?? []).compactMap { row in
            guard let id = row["id"].string, let provider = row["provider"].string, let name = row["name"].string,
                  !["default", "auto", ""].contains((id.split(separator: ":").last.map(String.init) ?? "").lowercased().replacingOccurrences(of: "[1m]", with: "")), !["default", "auto"].contains(name.lowercased()) else { return nil }
            return .init(id: id, provider: provider, name: name)
        }
        if ["default", "auto", ""].contains((confirmedModel.split(separator: ":").last.map(String.init) ?? "").lowercased().replacingOccurrences(of: "[1m]", with: "")),
           let section = sections.first(where: { $0.id == currentProvider }) ?? sections.first,
           let real = section.featured.first ?? section.more.first {
            confirmedModel = real.id; composerDraft.modelID = real.id
        }
    }
}

struct NativeHootChat: View {
    @Bindable var model: NativeHootChatModel = .shared
    var compact = false
    var notices: AnyView? = nil
    static let columnWidth: CGFloat = 760
    /// Build only the newest page until the person asks for earlier history.
    static let pageSize = 60
    @State private var toolDetail: HootChatRow?
    @State private var shownCount = NativeHootChat.pageSize
    @State private var followViewport = NativeChatFollowViewport()
    @State private var richChatHeight: CGFloat = 700
    @Environment(\.nativeScreenActive) private var screenActive
    @Environment(\.agkitOffscreenSolid) private var inheritedSolid
    private var side: CGFloat { compact ? 12 : 20 }
    private var composerEnabled: Bool {
        !model.readOnly && !model.loading && model.acceptingMessages && !model.changingConversation && model.readyToSend != false
    }
    var body: some View {
        let all = model.displayRows
        let shown = all.suffix(shownCount)
        let progressAnchor = model.taskProgress["anchorRowId"].string
        let progressAnchorVisible = shown.contains { $0.id == progressAnchor }
        VStack(spacing: 6) {
            if model.findVisible { NativeChatFindBar(model: model) }
            VStack(spacing: 0) {
            ScrollView {
                // A plain stack: only the latest page of messages is built (see pageSize), so
                // the bottom is laid out exactly and the chat opens there without a jump.
                VStack(alignment: .leading, spacing: 20) {
                    if let notices { notices }
                    if model.loading { skeleton }
                    else if model.rows.isEmpty { empty }
                    if all.count > shown.count {
                        Button("Show earlier messages") { shownCount += Self.pageSize }
                            .buttonStyle(.link).frame(maxWidth: .infinity)
                    }
                    // HOOT-FLOW: each job is one reply beside Hoot's avatar, there the moment a message is sent
                    // ("Thinking…"). While Hoot works its steps are a live list (tools in plain words, rules with a
                    // green tick, skill steps, agents); after, one folded line whose drop-down is the job as a table.
                    let live = model.foregroundAnswerActive && !model.compacting
                    let items = HootChatItem.thinking(HootChatItem.page(all, count: shownCount), live: live)
                    ForEach(items) { item in
                        Group { switch item {
                        case .row(let row):
                            if row.value["routing"].isNullish { chatRow(row) }
                            else {
                                VStack(alignment: .leading, spacing: 6) {
                                    replyName(.awake, animated: false)
                                    routingCard(row.value["routing"])
                                }
                            }
                        case .reply(let key, let answer, let steps, let open):
                            replyRow(answer, steps: steps, live: live && open, latest: open, key: key)
                        } }.id(item.id)
                        .background(model.findVisible && model.findMatch?.id == item.id ? Color.yellow.opacity(0.08) : Color.clear)
                        if item.id == progressAnchor, !model.todos.isEmpty {
                            NativeChatTaskCard(todos: model.todos).id("task-progress")
                        }
                    }
                    if !progressAnchorVisible, !model.todos.isEmpty { NativeChatTaskCard(todos: model.todos).id("task-progress") }
                    ForEach(model.queuedMessages) { item in
                        NativeQueuedMessageRow(model: model, item: item, bubble: true).id("queued:" + item.id)
                    }
                    if let problem = model.messageActionProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if model.changingMessageHistory { ProgressView("Updating conversation…").controlSize(.small) }
                    if let problem = model.problem {
                        Label(model.statusText(problem), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                }
                // The whole chat column, avatars included, sits inside the message box's width,
                // centred with it, so nothing peeks out at either side of the box.
                // Same inset left and right, lined up with the text inside the box (16 pt).
                .scrollTargetLayout()
                .padding(.horizontal, side + 16).padding(.top, compact ? 6 : 20).hootColumn(compact)
                .background(NativeChatFollowScroll(viewport: followViewport))
            }
            // Like any chat app: open at the latest message, stay pinned while replies stream
            // in, and leave a person who scrolled up to read where they are.
            .environment(\.nativeChatFolder, model.referenceRoot)
            .environment(\.nativeChatToolSessionID, model.source.sessionID ?? "hoot")
            .environment(\.nativeChatVisualMaximumHeight, richChatHeight * 0.7)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .scrollPosition($followViewport.position)
            .onScrollPhaseChange { _, phase in
                followViewport.interacting = phase == .interacting || phase == .decelerating
            }
            // No rectangular scroll-edge blur behind the box (Asad: "its not hitting with round shape of text box"); only the box's own rounded glass.
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .overlay(alignment: .top) {
                LinearGradient(colors: [model.source.isHoot ? DeckTokens.page : DeckTokens.chatPage, (model.source.isHoot ? DeckTokens.page : DeckTokens.chatPage).opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
            }
                VStack(spacing: 8) {
                    if (compact && !model.fixtureMode) || model.canUndoRewind || model.rewindProblem != nil || model.compacting || !model.pending.isEmpty {
                    VStack(spacing: 8) {
                    if compact, !model.fixtureMode {
                        // The island has no room for the handoff panel, so its button works like "Give to Hoot" there:
                        // it brings up Hoot's page with the panel open and starts the handoff (a background turn).
                        HStack {
                            Spacer()
                            Button {
                                let handoff = NativeHandoffModel.of(.hoot)
                                NSApp.activate(ignoringOtherApps: true) // front-ok: the person's own press on the island's handoff button
                                // The panel lives beside the chat: if Hoot's profile was open, go back to the chat (H27).
                                AppModel.shared.select("hoot"); HootProfileRoute.close()
                                handoff.isOpen = true
                                handoff.generate()
                            } label: {
                                Label("Context handoff", systemImage: "doc.text").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Context handoff: opens Hoot's page and writes a handoff of this conversation in the side panel")
                        }.padding(.trailing, 4)
                    }
                    if model.canUndoRewind || model.rewindProblem != nil {
                        HStack(spacing: 6) {
                            if let problem = model.rewindProblem { Text(problem).lineLimit(2) }
                            else {
                                Text("Rewound to here ·")
                                Button("Undo") { model.undoRewind() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            }
                        }.font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    if model.compacting { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Compacting…").font(.callout) }.frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(model.pending, id: \.compact) { request in approvalCard(request) }
                    }
                    .frame(maxWidth: .infinity)
                    .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.readOnly {
                        Label("Finished · Saved history", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).background(DeckTokens.card)
                    } else { composer(.box)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { followViewport.composer = $0 }
                    }
                }
                .padding(.horizontal, side).hootColumn(compact)
                // In the island panel the box is a solid card in the panel's own light or dark
                // colours (the Reduce Transparency fallback), so nothing shows through it.
                .environment(\.agkitOffscreenSolid, inheritedSolid)
                .zIndex(1)
            }
            if !model.source.isHoot && !model.readOnly {
                composer(.meta).padding(.horizontal, side).hootColumn(compact)
            }
        }
        .padding(.bottom, compact ? 10 : 12)
        .background { NativeChatMenu(model: model) }
        .environment(\.nativeChatFindQuery, model.findVisible ? model.findQuery : "")
        .background(NativeChatFindTarget(model: model))
        .onChange(of: model.findRevision) { _, _ in revealFind() }
        .onChange(of: model.loading) { _, loading in if !loading { followViewport.latest() } }
        .onChange(of: model.conversationID) { _, _ in followViewport.latest() }
        .onChange(of: model.composerDraft.text) { _, _ in model.syncSessionDraftSoon() }
        // Sending always brings the newest into view and follows it (the sent message lands after this, and the
        // follow keeps it and the answer in view as they arrive).
        .onChange(of: model.sending) { _, sending in if sending { followViewport.latest() } }
        // A cached chat shown again (a switch back to it) opens at its newest message.
        .onChange(of: screenActive) { _, shown in if shown { followViewport.latest() } }
        .onAppear {
            model.chatViewports[followViewport.id] = followViewport
            followViewport.latest()
        }
        .onDisappear { model.chatViewports[followViewport.id] = nil }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { richChatHeight = $0 }
        .task { await model.start(); if !model.fixtureMode { _ = try? await model.projectReferenceRoot() } }
        .background(model.source.isHoot ? Color.clear : DeckTokens.chatBody)
    }
    private func revealFind() {
        guard let match = model.findMatch else { return }
        let all = model.displayRows
        if let index = all.firstIndex(where: { $0.id == match.firstRow }) { shownCount = max(shownCount, all.count - index) }
        Task { @MainActor in
            await Task.yield()
            followViewport.pause()
            followViewport.position.scrollTo(id: match.id, anchor: .center)
        }
    }
    private var composerStatus: AnyView? {
        guard model.workingState.active || !model.runningTasks.isEmpty else { return nil }
        return AnyView(VStack(spacing: DeckTokens.Spacing.s4) {
            NativeChatWorkingLine(state: model.workingState, active: screenActive)
            NativeChatChildRows(model: model).id("\(model.source.sessionID ?? "hoot"):\(model.conversationID)")
        })
    }
    private func composer(_ part: HootComposerPart) -> some View {
        // The island uses the very same box as the page: glass, and the permission/model/effort row.
        HootComposer(draft: model.ownedComposerBinding, ownerID: model.source.sessionID ?? "hoot", catalogue: model.catalogue, showMeta: true, part: part,
                     busy: model.busy || model.sending || model.stopping || model.steeringQueuedID != nil, allowsSteering: !model.stopping, enabled: composerEnabled,
                     placeholder: model.source.isHoot ? "Ask Hoot — type @ to mention a session, page, agent or app"
                                                      : "Message \(model.source.agentName) — type / for its commands",
                     agentName: model.source.agentName, plainMeta: !model.source.isHoot,
                     microphoneAvailable: model.fixtureMode ? false : nil,
                     onSend: { followViewport.latest(); model.send($0) }, onStop: { model.stop() },
                     onManageTools: { if !model.fixtureMode { AppModel.shared.select("mcp") } },
                     onPermissionChange: { model.changePermission($0) }, onModelChange: { model.changeModel($0) },
                     onEffortChange: { model.changeEffort($0) }, onFastModeChange: { model.changeFastMode($0) },
                     onAppCommand: { model.routeSlashCommand($0) },
                     onReferenceQuery: { model.searchReferences($0) }, onRecall: { model.recallPrompt(previous: $0) }, attachmentLimits: model.attachmentLimits, canStop: model.answering || model.sending, stopping: model.stopping,
                     dictationOwner: model.chatVoice.dictation, onDictationStart: { model.chatVoice.beginDictation() },
                     onExpandLongPrompt: { _ = try? model.longDraftTool("open", text: nil) },
                     status: part == .meta ? nil : composerStatus)
    }
    /// Who answers: Hoot's owl, or a chat session's own AI.
    private var replyAgent: AGTAgent? {
        model.replyAgent
    }
    private var replySenderName: String {
        if model.source.isHoot { return "Hoot" }
        return replyAgent?.name
            ?? AGTTeamChatHistory.shared.rows.first { $0["session"]["id"].string == model.source.sessionID }?["job"]["agentName"].string
            ?? model.source.agentName
    }
    @ViewBuilder private func avatar(_ state: HootAvatar.State, animated: Bool, size: CGFloat = 26) -> some View {
        if model.source.isHoot { HootAvatar(state: state, size: size, animated: animated, showsStatus: false) }
        else if let agent = replyAgent {
            AgentAvatar(agent: agent, size: size)
        } else {
            NativeCodingAIProviderMark(provider: model.source.agentName.lowercased().contains("claude") ? "claude"
                : model.source.agentName.lowercased().contains("codex") ? "codex" : "gemini", size: size)
                .accessibilityLabel(model.source.agentName)
        }
    }
    private func incomingAgentName(_ row: HootChatRow) -> String? {
        let source = row.value["context"]["source"]
        if DeckOwner.isOwn(title: source["title"].string) { return nil }
        let team = AGTTeamChatHistory.shared.rows.first { $0["session"]["id"].string == model.source.sessionID }
        let id = source["agentId"].string ?? source["senderId"].string ?? team?["job"]["fromID"].string
        if ["me", "user", "person"].contains(id ?? "") { return nil }
        let name = AGTAgentsStore.shared.agent(id)?.name ?? source["senderName"].string ?? team?["job"]["fromName"].string
        return name.flatMap { DeckOwner.isOwn(sender: $0) ? nil : $0 }
    }
    @ViewBuilder private func senderAvatar(_ row: HootChatRow, name: String, team: NativeRPCValue?) -> some View {
        let source = row.value["context"]["source"]
        let own = DeckOwner.isOwn(title: source["title"].string, sender: name)
        let id = own ? "me" : source["agentId"].string ?? source["senderId"].string ?? team?["job"]["fromID"].string
        if id == "hoot" || name == "Hoot" { HootAvatar(size: 22, animated: false, showsStatus: false) }
        else if let agent = AGTAgentsStore.shared.agent(id) ?? AGTAgentsStore.shared.agents.first(where: { $0.name == name }) {
            AgentAvatar(agent: agent, size: 22)
        } else {
            AgentAvatar(icon: .symbol("person.crop.circle"), size: 22, id: id ?? name).accessibilityLabel(name)
        }
    }
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 18).fill(.quaternary).frame(width: 320, height: 70).frame(maxWidth: .infinity, alignment: .trailing)
            HStack { avatar(.thinking, animated: false); RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 84) }
        }.redacted(reason: .placeholder).accessibilityLabel("Loading \(model.source.agentName) conversation")
    }
    private var empty: some View {
        VStack(spacing: 16) {
            if model.source.isHoot {
                HootAvatar(size: compact ? 36 : 64, animated: !model.fixtureMode, showsStatus: false)
                Text("Ask Hoot anything about your projects.").font(.headline)
            } else {
                // A chat session: its own AI, in this session's folder.
                avatar(.awake, animated: false, size: compact ? 36 : 64)
                Text("Ask \(model.source.agentName) anything in this session.").font(.headline)
            }
            if !model.source.isHoot {
                EmptyView()
            } else if model.readyToSend == false {
                Text("Hoot needs a Coding AI signed in.").foregroundStyle(.secondary)
                Button("Open Coding AIs") { if !model.fixtureMode { AppModel.shared.requestSettings() } }.buttonStyle(.bordered)
            } else {
                HStack {
                    ForEach(["What needs me?", "What did the agents do overnight?", "Check a problem"], id: \.self) { suggestion in
                        Button(suggestion) { model.composerDraft.text = suggestion }.buttonStyle(.bordered)
                    }
                }
            }
        // Compact (the island panel): fit the space above the message box.
        }.frame(maxWidth: .infinity).padding(.top, compact ? 8 : 100).padding(.bottom, compact ? 8 : 28)
    }
    @ViewBuilder private func chatRow(_ row: HootChatRow) -> some View {
        if let about = row.value["background"]["id"].string {
            Button {
                guard !model.fixtureMode, row.value["background"]["reason"].string == "task" else { return }
                TasksStore.shared.openTask(about); AppModel.shared.select("tasks")
            } label: {
                Label(row.value["text"].string ?? "Working on a task", systemImage: "checklist")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary.opacity(0.6), in: .capsule)
            }.buttonStyle(.plain).help("Open the task").frame(maxWidth: .infinity, alignment: .center)
            HootHoverTime(at: row.at).frame(maxWidth: .infinity, alignment: .center)
        } else if row.kind == .toolCall, HootHandoffLine.matches(row) {
            // A handoff asked for in plain words: one line that reopens the panel, never the whole document.
            Button { if !model.fixtureMode { NativeHandoffModel.of(.hoot).isOpen = true } } label: {
                Label(HootHandoffLine.text(row), systemImage: "doc.text")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary.opacity(0.6), in: .capsule)
            }.buttonStyle(.plain).help("Open the handoff").frame(maxWidth: .infinity, alignment: .center)
        } else if row.kind == .toolCall {
            Button { toolDetail = row } label: {
                Label(row.value["name"].string?.replacingOccurrences(of: "_", with: " ") ?? "Tool step", systemImage: row.value["finished"].bool == true ? "checkmark" : "gearshape")
                    .font(.system(size: 11.5)).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: .rect(cornerRadius: 6))
            }.buttonStyle(.plain).popover(item: $toolDetail) { detail in
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    Text(detail.value["name"].string ?? "Tool step").font(.headline)
                    Text(detail.value["input"].compact).font(.caption.monospaced()).textSelection(.enabled)
                    if detail.value.has("output") { NativeChatToolResultContent(output: detail.value["output"]).environment(\.nativeChatToolRowID, detail.id) }
                }.padding(16) }.frame(width: 320, height: 280)
            }
            if !model.fixtureMode { NativeChatMCPAppView(sessionID: model.source.sessionID ?? "hoot", row: row) }
        } else if row.kind == .user {
            HootMessageFrame(row: row, trailing: true, onRewind: model.messageAction("rewind", row: row) ? { model.rewind(to: row) } : nil,
                             onFork: model.messageAction("fork", row: row) ? { model.fork(from: row) } : nil,
                             actionsBusy: model.busy || model.changingMessageHistory,
                             onHandoff: model.canHandoff ? { model.handoff(upTo: row, fromIsland: compact) } : nil) {
            VStack(alignment: .leading, spacing: 10) {
                let team = AGTTeamChatHistory.shared.rows.first { $0["session"]["id"].string == model.source.sessionID }
                if let sender = incomingAgentName(row) {
                    HStack(spacing: 7) {
                        senderAvatar(row, name: sender, team: team)
                        Text(sender).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                if row.value["attachmentCount"].number ?? 0 > 0 { attachmentCard(row) }
                NativeChatMarkdown(text: row.value["text"].string ?? "")
            }
                .padding(14).frame(maxWidth: 520, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Who an @ mention reached, or why it could not: one small line each; a click opens the task that carries the answer.
            ForEach(Array(model.receipts(for: row).enumerated()), id: \.offset) { _, receipt in
                let failed = receipt["outcome"].string == "failed", task = receipt["taskID"].string ?? receipt["taskId"].string
                Button {
                    guard !model.fixtureMode, let task else { return }
                    TasksStore.shared.openTask(task); AppModel.shared.select("tasks")
                } label: {
                    // The agent gets at most 1,900 characters of a message; a longer one is shortened for it, and the receipt says so.
                    let shortened = !failed && (row.value["text"].string?.count ?? 0) > 1_900 ? " Your message was long, so the agent got a shortened copy." : ""
                    Label((receipt["detail"].string ?? ("Sent to " + (receipt["name"].string ?? "the agent"))) + shortened, systemImage: failed ? "exclamationmark.circle" : "paperplane")
                        .font(.system(size: 11)).foregroundStyle(failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)).lineLimit(2)
                }.buttonStyle(.plain).help(task == nil ? "" : "Open the task that carries the answer").frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let status = model.compactStatus(row), status != "Compacting…" {
                Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if model.interrupted(row) {
                HStack(spacing: 4) {
                    Button { model.sendAgain(row) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    if row.value["attachmentCount"].number ?? 0 > 0 {
                        Text("Original files needed")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            // The agent answered: one line under the message; a click opens its answer in the task.
            ForEach(Array(model.answers(for: row).enumerated()), id: \.offset) { _, answer in
                // The seat by the name the person knows (the receipt's), never its inner key (H28).
                let sentTo = model.receipts(for: row).first { $0["receiptID"].string == answer["receiptID"].string }?["name"].string
                let who = [sentTo, answer["name"].string].compactMap { $0 }.first { !$0.isEmpty && !$0.contains(":") } ?? "The agent"
                let preview = answer["preview"].string ?? ""
                Button {
                    guard !model.fixtureMode, let task = answer["taskID"].string else { return }
                    TasksStore.shared.openTask(task); AppModel.shared.select("tasks")
                } label: {
                    Label(who + " answered" + (preview.isEmpty ? "" : ": " + preview), systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain).help("Open the answer").frame(maxWidth: 520, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HootMessageFrame(row: row, trailing: false, onRewind: nil,
                             onFork: model.messageAction("fork", row: row) ? { model.fork(from: row) } : nil,
                             actionsBusy: model.busy || model.changingMessageHistory,
                             onHandoff: model.canHandoff && [.message, .textDelta].contains(row.kind) ? { model.handoff(upTo: row, fromIsland: compact) } : nil) {
            VStack(alignment: .leading, spacing: 6) {
                    replyName(row.kind == .error ? .stopped : .awake, animated: false)
                    if row.kind == .error || row.kind == .interrupted {
                        Text(model.statusText(row.value["text"].string ?? (row.kind == .interrupted ? "Stopped." : "")))
                            .font(NativeChatMarkdown.bodyType).lineSpacing(5).textSelection(.enabled)
                    } else {
                        // Hoot writes markdown: the sessions' own renderer (bold, italics, code, lists, tables,
                        // headings, links, code blocks), with its marked parts (Needs you, Done, Waiting on,
                        // Heads-up) drawn as boxes.
                        HootReplyText(text: row.value["text"].string ?? "", streaming: row.kind == .textDelta,
                                      onReply: model.fixtureMode ? nil : { model.replyByNumber($0) })
                    }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func toolExpansion(_ key: String) -> Binding<Bool> {
        Binding(get: { followViewport.expandedCards.contains(key) }, set: { expanded in
            if expanded { _ = followViewport.expandedCards.insert(key) } else { _ = followViewport.expandedCards.remove(key) }
        })
    }
    private func replyName(_ state: HootAvatar.State, animated: Bool) -> some View {
        NativeChatSenderLine(name: replySenderName) { avatar(state, animated: animated) }
    }
    /// One job's reply: the avatar and name, then steps and the answer on the same left edge. With no
    /// answer yet it says "Thinking…" where the answer will be, so the first words take its place without a jump.
    @ViewBuilder private func replyRow(_ answer: HootChatRow?, steps: [HootChatRow], live: Bool, latest: Bool, key: String) -> some View {
        let column = VStack(alignment: .leading, spacing: 10) {
            replyName(live ? model.avatarState : .awake, animated: live && !model.fixtureMode)
            if let thought = model.thought(for: key) { NativeChatThoughtRow(thought: thought) }
            if !steps.isEmpty {
                HootStepsView(rows: steps, live: live, agents: model.flowAgents(steps), openTask: { task in model.openTask(task) }, indent: 0, expansion: toolExpansion(key))
            }
            ForEach(steps.filter { $0.kind == .toolCall }) { row in
                if !model.fixtureMode { NativeChatMCPAppView(sessionID: model.source.sessionID ?? "hoot", row: row) }
            }
            ForEach(model.fileDiffs.filter { card in steps.contains { $0.id == card.rowID } }) { card in
                NativeChatDiffCard(card: card)
            }
            if let answer {
                HootReplyText(text: answer.value["text"].string ?? "", streaming: answer.kind == .textDelta,
                              onReply: model.fixtureMode ? nil : { model.replyByNumber($0) })
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        let current = model.rows.last(where: { $0.kind == .user })?.id ?? model.rows.first?.id ?? "pending"
                        if latest, key == current { followViewport.latestLine = frame }
                    }
            } else if live {
                HootThinkingLabel(title: model.activityLabel, animated: !model.fixtureMode)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { followViewport.latestLine = $0 }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        let reply = column
        if let answer {
            HootMessageFrame(row: answer, trailing: false, onRewind: nil,
                             onFork: model.messageAction("fork", row: answer) ? { model.fork(from: answer) } : nil,
                             actionsBusy: model.busy || model.changingMessageHistory,
                             onHandoff: model.canHandoff ? { model.handoff(upTo: answer, fromIsland: compact) } : nil) { reply }
        } else if live {
            VStack(spacing: 0) { Color.clear.frame(height: 18); reply }
        } else if !steps.isEmpty {
            // Stopped before it answered: only the folded steps.
            HootStepsView(rows: steps, live: false, agents: model.flowAgents(steps), openTask: { task in model.openTask(task) }, expansion: toolExpansion(key))
            ForEach(steps.filter { $0.kind == .toolCall }) { row in
                if !model.fixtureMode { NativeChatMCPAppView(sessionID: model.source.sessionID ?? "hoot", row: row) }
            }
        }
    }
    private func attachmentCard(_ row: HootChatRow) -> some View {
        let source = row.value["context"]["source"]
        let title = source["title"].string.flatMap { DeckOwner.isOwn(title: $0, sender: $0) ? nil : $0 }
        let count = Int(row.value["attachmentCount"].number ?? 1)
        return HStack(spacing: 10) {
            Group {
                if let image = model.attachmentPreview(for: row) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }.frame(width: 84, height: 54).background(.quaternary, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? "\(count) attachment\(count == 1 ? "" : "s")").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let detail = source["url"].string ?? source["deviceId"].string {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }.padding(8).background(.background, in: .rect(cornerRadius: 10))
    }
    @ViewBuilder private func approvalCard(_ request: NativeRPCValue) -> some View {
        if BackendChatPlans.isReview(request) {
            let plan = request["input"]["plan"].string ?? rowsPlanText
            NativeChatPlanCard(plan: plan, disabled: model.answeringRequestID != nil) { decision, feedback in
                model.answer(request["requestId"].string ?? "", allowed: decision == "approve",
                    answers: .object([.init("decision", .string(decision)), .init("feedback", .string(feedback))]))
            }
        } else if BackendChatElicitation.isRequest(request) {
            NativeChatElicitationCard(request: request, disabled: model.answeringRequestID != nil) { allowed, answers in
                model.answer(request["requestId"].string ?? "", allowed: allowed, answers: answers)
            }.id(request["requestId"].string ?? request.compact)
        } else if BackendChatQuestions.isQuestion(request) {
            NativeChatQuestionsCard(request: request, disabled: model.answeringRequestID != nil) { allowed, answers in
                model.answer(request["requestId"].string ?? "", allowed: allowed, answers: answers)
            }
        } else {
            NativeChatApprovalCard(request: request, disabled: model.answeringRequestID != nil) { allowed, answers in
                model.answer(request["requestId"].string ?? "", allowed: allowed, answers: answers)
            }.id(request["requestId"].string ?? request.compact)
        }
    }
    private func routingCard(_ route: NativeRPCValue) -> some View {
        NativeHOOTSIMRoutingCard(route: route, fixtureMode: model.fixtureMode, choices: model.catalogue.mentions, projects: model.projectRecords) { decision, target in model.routeAnswer(route, decision: decision, target: target) }
    }
    private var rowsPlanText: String {
        model.displayRows.last(where: { [.message, .textDelta].contains($0.kind) && !($0.value["text"].string ?? "").isEmpty })?.value["text"].string ?? ""
    }
}

private extension View {
    @ViewBuilder func hootColumn(_ compact: Bool) -> some View {
        if compact { self } else { frame(maxWidth: NativeHootChat.columnWidth).frame(maxWidth: .infinity) }
    }
}

/// What the chat's message buttons call. Set once at launch by the app (Hoot's runtime); nil in pictures and checks.
@MainActor
enum HootChatActions {
    /// Takes the chat back to the message at this event; returns the text to put back in the box.
    static var rewind: (@MainActor (Int) async throws -> String)?
    static var fork: (@MainActor (Int) async throws -> NativeRPCValue)?
    static var handoffConversation: (@MainActor (String, String, @escaping @MainActor (String) -> Void) async throws -> Void)?
    static var undoRewind: (@MainActor () async throws -> Void)?
    /// A handoff up to and including the message at this event; `progress` gets short plain lines. Returns at the end of the turn.
    static var handoffUpTo: (@MainActor (Int, _ progress: @escaping @MainActor (String) -> Void) async throws -> Void)?
}

/// The small time under a message: today's as "2:41 AM", older ones with the day; the exact date and time on hover.
enum HootMessageTime {
    static func short(_ at: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: at / 1000), calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday, " + time }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
    }
    static func exact(_ at: Double) -> String { Date(timeIntervalSince1970: at / 1000).formatted(date: .complete, time: .standard) }
    @ViewBuilder static func label(_ at: Double) -> some View {
        if at > 0 { Text(short(at)).font(.system(size: 10.5)).foregroundStyle(.tertiary).help(exact(at)) }
    }
}

/// A `handoff_present` tool step in the chat (called directly or through tools_run).
enum HootHandoffLine {
    static func matches(_ row: HootChatRow) -> Bool {
        let name = row.value["name"].string ?? ""
        return name.hasSuffix("handoff_present") || (name.hasSuffix("tools_run") && (row.value["input"]["name"].string ?? "").replacingOccurrences(of: ".", with: "_") == "handoff_present")
    }
    static func text(_ row: HootChatRow) -> String {
        if let said = row.value["output"].string, said.hasPrefix("Handoff ready") { return String(said.prefix(120)) }
        let input = row.value["input"]["arguments"].fields != nil ? row.value["input"]["arguments"] : row.value["input"]
        let topic = input["topic"].string ?? input["title"].string ?? ""
        return row.value["finished"].bool == true ? (topic.isEmpty ? "Handoff ready" : "Handoff ready: " + topic) : "Writing the handoff\u{2026}"
    }
}

/// Reply actions stay above the text so the newest line reaches the composer, including code blocks.
/// Their height stays fixed while streaming and hovering, so the conversation does not reflow.
struct HootMessageFrame<Content: View>: View {
    let row: HootChatRow
    let trailing: Bool
    var onRewind: (() -> Void)?
    var onFork: (() -> Void)? = nil
    var actionsBusy = false
    var onHandoff: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false
    @State private var copied = false
    @State private var confirmRewind = false
    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            content
            actions
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .contentShape(Rectangle()).onHover { hovering = $0 }
        .alert("Rewind to here?", isPresented: $confirmRewind) {
            Button("Cancel", role: .cancel) {}
            Button("Rewind", role: .destructive) { onRewind?() }
        } message: {
            Text("Later messages in this chat are removed from the conversation. Your message returns to the box for editing. Files are kept as they are.")
        }
    }
    private var actions: some View {
        HStack(spacing: 4) {
            if row.at > 0 && hovering {
                Text(HootMessageTime.short(row.at)).foregroundStyle(.tertiary).hootQuickTip(HootMessageTime.exact(row.at)).padding(.trailing, 4)
            }
            if !trailing, let onHandoff, !copied, hovering { HootMessageIcon(symbol: "doc.text", tip: "Handoff: everything up to this message", action: onHandoff) }
            Group {
                HootMessageIcon(symbol: copied ? "checkmark" : "doc.on.doc", tip: copied ? "Copied" : "Copy this message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HootCallout.plain(row.value["text"].string ?? ""), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
            }
            if let onRewind {
                HootMessageIcon(symbol: "arrow.uturn.backward",
                                tip: trailing ? "Rewind: go back to this message and put it back in the box" : "Rewind: go back to here",
                                action: { confirmRewind = true }).disabled(actionsBusy)
            }
            if let onFork {
                HootMessageIcon(symbol: "arrow.triangle.branch", tip: "Fork from here", action: onFork).disabled(actionsBusy)
            }
            if trailing, let onHandoff, !copied, hovering {
                HootMessageIcon(symbol: "doc.text", tip: "Handoff: everything up to this message", action: onHandoff)
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary).buttonStyle(.plain)
        .frame(height: 18).padding(.leading, trailing ? 0 : 38)
    }
}

/// One icon-only message button with its quick tip.
struct HootMessageIcon: View {
    let symbol: String
    let tip: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 22, height: 18).contentShape(.rect)
        }
        .buttonStyle(.plain).hootQuickTip(tip).accessibilityLabel(tip)
    }
}

/// The time under a compact line (a background task), shown only while the pointer is on it.
struct HootHoverTime: View {
    let at: Double
    @State private var hovering = false
    var body: some View {
        Group {
            if at > 0 {
                Text(HootMessageTime.short(at)).font(.system(size: 10.5)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
                    .hootQuickTip(HootMessageTime.exact(at))
            }
        }
        .frame(height: 14).contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

/// A short tip that comes almost at once (the system's own takes about a second and a half).
struct HootQuickTip: ViewModifier {
    let text: String
    static let delay = 120
    @State private var shown = false
    @State private var waiting: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                if inside {
                    waiting = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(Self.delay))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.08)) { shown = true } }
                    }
                } else { shown = false }
            }
            .onDisappear { waiting?.cancel(); shown = false }
            .overlay(alignment: .top) {
                if shown {
                    Text(text).font(.system(size: 11)).foregroundStyle(.primary).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .offset(y: -24).allowsHitTesting(false).transition(.opacity)
                }
            }
    }
}

extension View {
    func hootQuickTip(_ text: String) -> some View { modifier(HootQuickTip(text: text)) }
}

/// "Thinking…" beside Hoot's avatar until the first words or steps arrive.
struct HootThinkingLabel: View {
    var title = "Thinking"
    var animated = true
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let dots = animated ? Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1 : 3
            Text(title + String(repeating: ".", count: dots) + String(repeating: " ", count: 3 - dots))
                .font(NativeChatMarkdown.bodyType).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityLabel(title)
    }
}
