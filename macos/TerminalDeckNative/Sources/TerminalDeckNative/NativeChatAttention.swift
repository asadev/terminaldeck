import AppKit
import Observation
import TerminalDeckNativeCore

struct NativeChatNoticeTracker {
    struct Notice: Sendable { let source: String; let conversation: String; let kind: String }
    private struct Completion { var turn: String; var sequence: Int }
    private struct Cursor {
        var conversation: String; var sequence: Int; var requests: Set<String>
        var foreground: String?; var completion: Completion?
    }
    private var cursors: [String: Cursor] = [:]
    private func events(_ snapshot: NativeRPCValue) -> [HootChatEvent] { (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) } }
    private func reportedSequence(_ snapshot: NativeRPCValue) -> Int {
        guard let n = snapshot["sequence"].number, n.isFinite, n >= 0, n < Double(Int.max), n.rounded(.towardZero) == n else { return 0 }; return Int(n)
    }
    private func isForeground(_ event: HootChatEvent, conversation: String) -> Bool {
        event.conversationID == conversation && !event.turnID.isEmpty && !event.turnID.hasPrefix("bg:")
    }
    private func startsTurn(_ event: HootChatEvent) -> Bool {
        event.record.kind == .user || event.record.kind == .session && event.record.value["providerTurnStarted"].fields != nil
    }
    private func initialCursor(_ snapshot: NativeRPCValue, conversation: String) -> Cursor {
        let records = events(snapshot)
        let foreground = records.filter { isForeground($0, conversation: conversation) && startsTurn($0) }.max { $0.sequence < $1.sequence }?.turnID
        return .init(conversation: conversation, sequence: max(reportedSequence(snapshot), records.map(\.sequence).max() ?? 0), requests: [], foreground: foreground)
    }
    mutating func prime(_ snapshot: NativeRPCValue, source: String) {
        guard let conversation = snapshot["conversationId"].string, !conversation.isEmpty, cursors[source]?.conversation != conversation else { return }
        cursors[source] = initialCursor(snapshot, conversation: conversation)
    }
    mutating func consume(_ snapshot: NativeRPCValue, source: String, complete: Bool, input: Bool, visible: Bool) -> [Notice] {
        guard let conversation = snapshot["conversationId"].string, !conversation.isEmpty else { return [] }
        let records = events(snapshot), latest = max(reportedSequence(snapshot), records.map(\.sequence).max() ?? 0)
        let initial = cursors[source]?.conversation != conversation
        var cursor = initial ? initialCursor(snapshot, conversation: conversation) : cursors[source]!
        let requests = Set((snapshot["pending"].elements ?? []).compactMap { request -> String? in
            let id = request["requestId"].string ?? request["id"].string
            guard let id, !id.isEmpty else { return nil }
            if let nonce = request["approvalNonce"].string, !nonce.isEmpty {
                return NativeRPCValue.array([.string(id), .string(nonce)]).compact
            }
            return id
        })
        let freshRequests = requests.subtracting(cursor.requests)
        if !initial {
            for event in records.filter({ $0.sequence > cursor.sequence && isForeground($0, conversation: conversation) }).sorted(by: { $0.sequence < $1.sequence }) {
                if startsTurn(event) {
                    cursor.foreground = event.turnID; cursor.completion = nil
                } else if event.record.kind == .completed, cursor.foreground == nil || cursor.foreground == event.turnID {
                    // Keep the actual foreground receipt while background tasks or a permission
                    // keep the helper busy. A later idle snapshot need not repeat this record.
                    cursor.completion = .init(turn: event.turnID, sequence: event.sequence)
                } else if [.interrupted, .error].contains(event.record.kind), cursor.completion?.turn == event.turnID {
                    cursor.completion = nil
                }
            }
        }
        let finished = cursor.completion != nil && snapshot["busy"].bool == false && requests.isEmpty
        if finished || visible || !complete { cursor.completion = nil }
        cursor.sequence = max(cursor.sequence, latest); cursor.requests.formUnion(requests); cursors[source] = cursor
        guard !visible else { return [] }
        if input && !freshRequests.isEmpty { return [.init(source: source, conversation: conversation, kind: "input-needed")] }
        if complete && finished { return [.init(source: source, conversation: conversation, kind: "completed")] }
        return []
    }
}
@MainActor @Observable final class NativeChatAttention {
    typealias Notice = NativeChatNoticeTracker.Notice
    static let shared = NativeChatAttention { notice in
        let result = await NativeCompositionBanners.shared.post(title: notice.kind == "completed" ? "Chat reply ready" : "Chat needs your input", body: "Open this conversation in Terminal Deck.", silent: true, clicked: {
            AppModel.shared.select(notice.source)
            NSApp.activate() // front-ok: only the person's explicit click on this Chat banner.
        })
        return result.delivered ? "macOS accepted the notification request" : "macOS did not accept the notification request"
    }
    private(set) var last: [String: String] = [:]
    @ObservationIgnored private var tracker = NativeChatNoticeTracker()
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var deferred: [String: NativeRPCValue] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var preferencesStarted = false
    @ObservationIgnored private let send: @MainActor (Notice) async -> String
    init(send: @escaping @MainActor (Notice) async -> String) { self.send = send }
    func start() {
        guard !started else { return }; started = true; observePreferences()
        subscriptions = [EngineBridge.shared.on("hoot:chat:changed") { [weak self] args in
            guard let raw = args.first, let value = try? NativeRPCValue.fromFoundation(raw) else { return }; self?.handle(value, source: "hoot")
        }, EngineBridge.shared.on("session:chat:changed") { [weak self] args in
            guard args.count > 1, let id = args[0] as? String, let value = try? NativeRPCValue.fromFoundation(args[1]) else { return }; self?.handle(value, source: id)
        }]
    }
    func stop() { started = false; preferencesStarted = false; subscriptions.forEach { $0.cancel() }; subscriptions = []; deferred = [:] }
    private func observePreferences() {
        guard started else { return }
        withObservationTracking { _ = NativeSettingsValues.shared.loading; _ = NativeSettingsValues.shared.values } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }; self.observePreferences()
                if !NativeSettingsValues.shared.loading { let waiting = self.deferred; self.deferred = [:]; for (id, value) in waiting { self.handle(value, source: id) } }
            }
        }
    }
    private func handle(_ value: NativeRPCValue, source: String) {
        let store = NativeSettingsValues.shared
        if !preferencesStarted { preferencesStarted = true; if store.loading { store.start() } }
        if store.loading { tracker.prime(value, source: source); deferred[source] = value; return }
        let visible = NSApp.isActive && AppModel.shared.sidebar?.selectedId == source
        let complete = store.bool("notifications.onComplete"), input = store.bool("notifications.onNeedsInput")
        Task { await receive(value, source: source, complete: complete, input: input, visible: visible) }
    }
    func receive(_ value: NativeRPCValue, source: String, complete: Bool, input: Bool, visible: Bool) async {
        let notices = tracker.consume(value, source: source, complete: complete, input: input, visible: visible)
        for notice in notices {
            last[source] = "Notification pending"
            NativeHootChatModel.queueOwner(source)?.chatFeatureRevision += 1
            last[source] = await send(notice)
            NativeHootChatModel.queueOwner(source)?.chatFeatureRevision += 1
        }
    }
}
extension NativeHootChatModel {
    func attentionTool(_ action: String) -> NativeRPCValue {
        featurePanel("notifications", action)
        if action == "manage", !fixtureMode { AppModel.shared.openSettings(section: "notifications") }
        return NativeChatPanel.state("Chat notifications", "Completion and input-needed notices reuse the app's banner owner and notification preferences. Initial completion history is silent; repeated events are deduplicated. macOS acceptance does not prove a visible banner. Live OS delivery remains a main-builder check.", [NativeChatPanel.row("last", "Last attempt in this app attachment", NativeChatAttention.shared.last[source.sessionID ?? "hoot"] ?? "No delivery attempt recorded")], [NativeChatPanel.action("Open notification settings", "manage")])
    }
}
