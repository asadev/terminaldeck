import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// One of Terminal Deck's own events, posted into the Receiver by another feature.
public struct BackendRCVInternalEvent: Sendable, Equatable {
    public var kind: String, severity: RCVSeverity, title: String, text: String, fields: [String: String], id: String?
    public init(kind: String, severity: RCVSeverity = .info, title: String, text: String = "", fields: [String: String] = [:], id: String? = nil) {
        self.kind = kind; self.severity = severity; self.title = title; self.text = text; self.fields = fields; self.id = id
    }
}

/// The Receiver. Event-driven: work happens when a delivery arrives, an owner or
/// tool acts, or the one wake-up for held events comes due. No polling.
public actor BackendRCVService {
    public typealias Send = @Sendable (UInt8, Data, Data) async throws -> Void
    public static let maxRepliesPerEvent = 10, maxRepliesPerSourcePerMinute = 30, maxRelaySources = 64

    let store: BackendRCVStore
    let dispatch: any BackendRCVDispatching
    private let relayBase: @Sendable () async -> String?
    private let now: @Sendable () -> Double
    private let changed: @Sendable () async -> Void
    private let hook: @Sendable (RCVEvent) async -> Void
    private var send: Send?
    private var active: Set<String> = []
    private var wake: Task<Void, Never>?
    private var replyHits: [String: [Double]] = [:]
    private var started = false
    /// Why the Receiver could not start (its storage or key), shown with a Retry on the page.
    public private(set) var unavailableReason: String?

    public init(store: BackendRCVStore, dispatch: any BackendRCVDispatching, relayBase: @escaping @Sendable () async -> String?,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                changed: @escaping @Sendable () async -> Void = {}, hook: @escaping @Sendable (RCVEvent) async -> Void = { _ in }) {
        self.store = store; self.dispatch = dispatch; self.relayBase = relayBase; self.now = now; self.changed = changed; self.hook = hook
    }

    /// Opens the store on first real use, never at app launch. A failure here (the
    /// Keychain locked, denied or missing a key) leaves only the Receiver unavailable,
    /// with the reason; the next call tries again (the page's "Try again").
    public func start() async throws {
        guard !started else { return }
        do {
            try await store.start()
            let at = now()
            try await store.seed { state in
                for (id, name) in RCVPresets.internalSources where !state.sources.contains(where: { $0.id == id }) {
                    let preset = RCVPresets.terminalDeck
                    state.sources.append(RCVSource(id: id, name: name, preset: preset.id, origin: .terminalDeck, auth: preset.auth,
                                                   mapping: preset.mapping, createdAt: at))
                }
            }
        } catch {
            let reason = (error as? NativeRPCError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "Its storage could not be opened."
            unavailableReason = reason
            throw NativeRPCError(code: "receiver-unavailable", message: reason.hasPrefix("The Receiver") ? reason : "The Receiver is unavailable: \(reason)")
        }
        unavailableReason = nil
        started = true
        await scheduleWake()
    }

    /// Every entry point: start on first use, or say clearly why the Receiver is unavailable.
    func ready() async throws { if !started { try await start() } }

    public func stop() { wake?.cancel(); wake = nil; send = nil; active = []; started = false }

    // MARK: - Relay link

    public func relayOpened(_ send: @escaping Send) async {
        self.send = send
        await syncRelay()
    }

    public func relayClosed() async { send = nil; active = []; await changed() }

    public func relayFrame(type: UInt8, channel: Data, payload: Data) async {
        if type == BackendRCVWire.synced, let synced = BackendRCVWire.decodeSynced(payload) {
            active = Set(synced.accepted); await changed(); return
        }
        guard type == BackendRCVWire.deliver else { return }
        guard let delivery = BackendRCVWire.decodeDeliver(channel: channel, payload: payload) else {
            // Unreadable: refuse it so the relay does not offer it forever.
            if channel.count == 16 { try? await send?(BackendRCVWire.ack, channel, Data([BackendRCVWire.ackRefused])) }
            return
        }
        // Not saved: no acknowledgement, so the relay offers it again.
        guard let result = await ingest(delivery) else { return }
        try? await send?(BackendRCVWire.ack, delivery.id, Data([result.0]))
        await route(result.1)
    }

    func syncRelay() async {
        guard (try? await ready()) != nil else { return }
        guard let send, let state = try? await store.read(), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.receiverKey) else { return }
        let declarations = state.sources.filter { $0.origin == .relay }.prefix(Self.maxRelaySources).map {
            BackendRCVWire.declaration($0, secret: state.secrets[$0.id]?.secret ?? "")
        }
        guard let payload = try? BackendRCVWire.syncPayload(sealKey: key.publicKey, sources: Array(declarations)) else { return }
        try? await send(BackendRCVWire.sync, BackendRCVWire.noChannel, payload)
    }

    /// Open, verify, normalize, save. Returns the acknowledgement and the ids to route, or nil when nothing could be saved.
    func ingest(_ delivery: BackendRCVWire.Delivery) async -> (UInt8, [String])? {
        guard (try? await ready()) != nil, let state = try? await store.read() else { return nil }
        if state.deliveries[delivery.key] != nil { return (BackendRCVWire.ackKept, []) }
        guard let source = state.sources.first(where: { $0.id == delivery.sourceID && $0.origin == .relay }) else { return (BackendRCVWire.ackUnknown, []) }
        let at = now(), received = Double(delivery.receivedAt)
        let opened: BackendRCVWire.Opened
        do {
            opened = try BackendRCVWire.openDelivery(delivery, key: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.receiverKey))
        } catch {
            return await reject(source, delivery: delivery, words: "It could not be opened with this Mac’s Receiver key.", at: at)
        }
        if let failure = BackendRCVAuth.verify(opened, source: source, secret: state.secrets[source.id]?.secret ?? "", now: at) {
            return await reject(source, delivery: delivery, words: failure.words, at: at)
        }
        let meta = ["clientIp": opened.clientIP ?? "", "method": opened.method, "receivedAt": String(delivery.receivedAt), "source": source.id]
        let events = RCVEngine.normalize(body: opened.body, headers: opened.headers, meta: meta, source: source, receivedAt: received)
        let key = delivery.key
        guard let fresh = try? await store.update({ state -> [String] in
            state.deliveries[key] = at
            return Self.admit(events, source: source, into: &state, at: at)
        }) else { return nil }
        await changed()
        return (BackendRCVWire.ackKept, fresh)
    }

    /// Mark repeats and echoes, append, and return the ids that still need routing.
    static func admit(_ events: [RCVEvent], source: RCVSource, into state: inout BackendRCVState, at: Double) -> [String] {
        var fresh: [String] = []
        for var event in events {
            event.trail = [.init(at: at, "Received from \(source.name).")]
            if event.status == .ignored {
                event.trail.append(.init(at: at, "The source’s ignore list matched, so it is kept but not routed."))
            } else if let upstream = event.upstreamId, state.seen[source.id + "|" + upstream] != nil {
                event.status = .duplicate; event.trail.append(.init(at: at, "Already received: the sender used the same id before."))
            } else if !event.text.isEmpty, state.sentReplies[Self.digest(event.text)] != nil {
                event.status = .ignored; event.trail.append(.init(at: at, "This is our own reply coming back, so it is not routed."))
            } else {
                if let upstream = event.upstreamId { state.seen[source.id + "|" + upstream] = at }
                fresh.append(event.id)
            }
            state.events.append(event)
        }
        return fresh
    }

    private func reject(_ source: RCVSource, delivery: BackendRCVWire.Delivery, words: String, at: Double) async -> (UInt8, [String])? {
        var event = RCVEvent(sourceId: source.id, receivedAt: Double(delivery.receivedAt), kind: "rejected", title: "Delivery refused", text: words)
        event.status = .rejected
        event.trail = [.init(at: at, "Received from \(source.name)."), .init(at: at, "Refused: \(words) Nothing from it was kept.")]
        let key = delivery.key, refused = event
        do { try await store.update { state in state.deliveries[key] = at; state.events.append(refused) } } catch { return nil }
        await changed()
        return (BackendRCVWire.ackRefused, [])
    }

    // MARK: - Terminal Deck's own events

    public func post(internal sourceID: String, _ item: BackendRCVInternalEvent) async {
        guard (try? await ready()) != nil, let state = try? await store.read(), let source = state.sources.first(where: { $0.id == sourceID && $0.origin == .terminalDeck }),
              source.enabled else { return }
        var payload: [String: Any] = ["kind": item.kind, "severity": item.severity.rawValue, "title": item.title, "text": item.text]
        for (key, value) in item.fields where payload[key] == nil { payload[key] = value }
        if let id = item.id { payload["id"] = id }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let at = now()
        let events = RCVEngine.normalize(body: body, headers: ["content-type": "application/json"], meta: ["source": sourceID], source: source, receivedAt: at)
        guard let fresh = try? await store.update({ state in Self.admit(events, source: source, into: &state, at: at) }) else { return }
        await changed()
        await route(fresh)
    }

    /// A delivery that skips the relay (tests, and "send a test event" on the page). Same checks as the relay path.
    public func receiveLocally(sourceID: String, opened: BackendRCVWire.Opened) async throws -> [RCVEvent] {
        try await ready()
        let state = try await store.read()
        guard let source = state.sources.first(where: { $0.id == sourceID }) else { throw Self.noSource() }
        let at = now()
        if source.origin == .relay, let failure = BackendRCVAuth.verify(opened, source: source, secret: state.secrets[source.id]?.secret ?? "", now: at) {
            throw NativeRPCError(code: "receiver-refused", message: failure.words)
        }
        let events = RCVEngine.normalize(body: opened.body, headers: opened.headers, meta: ["clientIp": opened.clientIP ?? "", "source": sourceID], source: source, receivedAt: at)
        let fresh = try await store.update { state in Self.admit(events, source: source, into: &state, at: at) }
        await changed()
        await route(fresh)
        let after = try await store.read()
        return events.compactMap { e in after.events.first { $0.id == e.id } }
    }

    // MARK: - Routing and delivery

    func route(_ ids: [String]) async {
        for id in ids { await routeOne(id) }
        await scheduleWake()
        if !ids.isEmpty { await changed() }
    }

    private func routeOne(_ id: String) async {
        let at = now()
        let decided = try? await store.update { state -> (RCVEvent, RCVDecision, RCVRule?)? in
            guard let index = state.events.firstIndex(where: { $0.id == id }) else { return nil }
            let event = state.events[index]
            let name = state.sources.first { $0.id == event.sourceId }?.name ?? event.sourceId
            let decision = RCVRouter.decide(event, rules: state.rules, sourceName: name, memory: &state.memory, now: at, commit: true)
            var next = event
            next.ruleId = decision.ruleId; next.target = decision.target; next.instruction = decision.instruction; next.resumeAt = decision.resumeAt
            next.status = decision.status == .delivered ? event.status : decision.status
            next.trail.append(.init(at: at, decision.reason))
            state.events[index] = next
            return (next, decision, state.rules.first { $0.id == decision.ruleId })
        }
        guard let found = decided ?? nil else { return }
        let (event, decision, rule) = found
        if decision.status == .delivered, let target = decision.target, let instruction = decision.instruction {
            await deliver(event, to: target, instruction: instruction, rule: rule)
        } else {
            await hook(event)
        }
    }

    private func deliver(_ event: RCVEvent, to target: RCVTarget, instruction: String, rule: RCVRule?) async {
        let title = event.title.isEmpty ? event.kind : event.title
        var taskID: String?, sessionID: String?, words = ""
        let agentName = (target.kind == .agent || target.kind == .newTask) ? await name(ofAgent: target.id) : ""
        do {
            switch target.kind {
            case .newTask:
                taskID = try await dispatch.createTask(assignee: target.id, title: title, instructions: instruction, project: rule?.project ?? "")
                words = "Started a new task for \(agentName)."
            case .hoot:
                taskID = try await dispatch.createTask(assignee: "hoot", title: title, instructions: instruction, project: rule?.project ?? "")
                words = "Gave Hoot a task."
            case .session:
                try await dispatch.typeIntoSession(target.id, text: instruction)
                sessionID = target.id; words = "Typed into the session."
            case .agent:
                let conversation = (try? RCVEngine.render(target.threadKey ?? "{{source}}", in: .of(event), limit: 300)) ?? event.sourceId
                let key = (rule?.id ?? "by-hand") + "|" + conversation
                if let existing = try await store.read().threads[key] {
                    do { try await dispatch.continueTask(existing, text: instruction); taskID = existing; words = "Added to the ongoing task for \(agentName)." }
                    catch { taskID = nil }
                }
                if taskID == nil {
                    let created = try await dispatch.createTask(assignee: target.id, title: title, instructions: instruction, project: rule?.project ?? "")
                    taskID = created
                    try await store.update { state in state.threads[key] = created }
                    words = "Started an ongoing task for \(agentName)."
                }
            }
            await finish(event.id, status: .delivered, taskID: taskID, sessionID: sessionID, words: words)
        } catch {
            await finish(event.id, status: .failed, taskID: nil, sessionID: nil, words: "Could not hand it over: \(Self.words(error))", failed: true)
        }
    }

    private func finish(_ id: String, status: RCVStatus, taskID: String?, sessionID: String?, words: String, failed: Bool = false) async {
        let at = now()
        let event = try? await store.update { state -> RCVEvent? in
            guard let index = state.events.firstIndex(where: { $0.id == id }) else { return nil }
            state.events[index].status = status
            if let taskID { state.events[index].taskId = taskID }
            if let sessionID { state.events[index].sessionId = sessionID }
            state.events[index].outcome = words
            state.events[index].resumeAt = nil
            if failed { state.events[index].attempt += 1 }
            state.events[index].trail.append(.init(at: at, words))
            return state.events[index]
        }
        if let event = event ?? nil { await hook(event) }
    }

    private func name(ofAgent id: String) async -> String { await dispatch.agents().first { $0.id == id }?.name ?? id }

    /// One wake-up, at the earliest held event. Nothing runs while nothing is held.
    func scheduleWake() async {
        wake?.cancel(); wake = nil
        guard started, let state = try? await store.read(), let next = state.events.filter({ $0.status == .held }).compactMap(\.resumeAt).min() else { return }
        let delay = max(0, next - now())
        wake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(min(delay, 86_400_000)) + 50))
            guard !Task.isCancelled else { return }
            await self?.wakeHeld()
        }
    }

    func wakeHeld() async {
        guard let state = try? await store.read() else { return }
        let at = now()
        let due = state.events.filter { $0.status == .held && ($0.resumeAt ?? 0) <= at }.map(\.id)
        await route(due)
    }

    // MARK: - Reading

    public func overview(limit: Int = 200) async throws -> RCVOverview {
        try await ready()
        let state = try await store.read()
        let base = await relayBase()
        let events = Array(state.events.suffix(max(1, min(limit, 500))).reversed())
        return RCVOverview(sources: state.sources.map { view($0, state: state, base: base) }, rules: state.rules, events: events,
                           unrouted: state.events.filter { $0.status == .unrouted }.count, held: state.events.filter { $0.status == .held }.count,
                           relayConnected: send != nil, relayBase: base, presets: RCVPresets.all + state.customPresets,
                           agents: await dispatch.agents(), sessions: await dispatch.sessions())
    }

    func view(_ source: RCVSource, state: BackendRCVState, base: String?) -> RCVSourceView {
        let mine = state.events.filter { $0.sourceId == source.id }
        return RCVSourceView(source: source, address: source.origin == .relay ? base.map { $0 + "/in/" + source.id } : nil,
                             active: source.origin == .terminalDeck || active.contains(source.id),
                             hasReplyCredential: state.secrets[source.id]?.reply?.isEmpty == false,
                             lastEventAt: mine.last?.receivedAt, eventCount: mine.count, rejectedCount: mine.filter { $0.status == .rejected }.count)
    }

    public func events(sourceID: String? = nil, status: RCVStatus? = nil, query: String = "", limit: Int = 100) async throws -> [RCVEvent] {
        try await ready()
        let state = try await store.read()
        let words = query.trimmingCharacters(in: .whitespaces)
        return Array(state.events.reversed().filter { event in
            (sourceID == nil || event.sourceId == sourceID) && (status == nil || event.status == status) &&
            (words.isEmpty || [event.title, event.text, event.kind].contains { $0.localizedCaseInsensitiveContains(words) } ||
             event.fields.values.contains { $0.localizedCaseInsensitiveContains(words) })
        }.prefix(max(1, min(limit, 500))))
    }

    public func event(_ id: String) async throws -> RCVEvent {
        try await ready()
        guard var event = try await store.read().events.first(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That Receiver event no longer exists.") }
        if let task = event.taskId, let outcome = await dispatch.taskOutcome(task) { event.outcome = (event.outcome.map { $0 + " " } ?? "") + "Task: \(outcome)." }
        return event
    }

    public func sources() async throws -> [RCVSourceView] {
        try await ready()
        let state = try await store.read(); let base = await relayBase()
        return state.sources.map { view($0, state: state, base: base) }
    }

    public func rules() async throws -> [RCVRule] { try await ready(); return try await store.read().rules }

    // MARK: - Sources

    public func createSource(preset presetID: String, name: String, auth: RCVAuth? = nil) async throws -> (RCVSourceView, RCVSecretReveal?) {
        try await ready()
        let state = try await store.read()
        guard let preset = RCVPresets.named(presetID, custom: state.customPresets), preset.origin == .relay else {
            throw NativeRPCError.invalidArguments("Choose one of the Receiver’s presets for a new source.")
        }
        guard state.sources.filter({ $0.origin == .relay }).count < Self.maxRelaySources else { throw NativeRPCError.invalidArguments("A computer can have at most \(Self.maxRelaySources) Receiver sources.") }
        let source = RCVSource(id: BackendRCVWire.mintSourceID(), name: name.trimmingCharacters(in: .whitespaces), preset: preset.id,
                               auth: auth ?? preset.auth, mapping: preset.mapping, reply: preset.reply, createdAt: now())
        try RCVEngine.validate(source)
        let secret = BackendRCVWire.mintSecret()
        let examples = preset.examples.map { example -> RCVRule in
            var rule = example; rule.id = UUID().uuidString.lowercased(); rule.sourceIds = [source.id]; rule.enabled = false; return rule
        }
        try await store.update { state in
            state.sources.append(source); state.secrets[source.id] = .init(secret: secret)
            state.rules.append(contentsOf: examples)
        }
        await syncRelay(); await changed()
        let base = await relayBase()
        return (view(source, state: try await store.read(), base: base), reveal(source, secret: secret, base: base))
    }

    func reveal(_ source: RCVSource, secret: String, base: String?) -> RCVSecretReveal? {
        guard source.origin == .relay, source.auth.scheme != .none else { return nil }
        let withSecret = source.auth.scheme == .token ? base.map { "\($0)/in/\(source.id)/\(secret)" } : nil
        return RCVSecretReveal(sourceId: source.id, secret: secret, addressWithSecret: withSecret)
    }

    public func saveSource(_ incoming: RCVSource) async throws -> RCVSourceView {
        try await ready()
        let state = try await store.read()
        guard let current = state.sources.first(where: { $0.id == incoming.id }) else { throw Self.noSource() }
        var next = incoming
        next.origin = current.origin; next.createdAt = current.createdAt; next.preset = current.preset
        if current.origin == .terminalDeck { next.auth = current.auth; next.reply = nil }
        try RCVEngine.validate(next)
        let saved = next
        try await store.update { state in
            if let index = state.sources.firstIndex(where: { $0.id == saved.id }) { state.sources[index] = saved }
        }
        await syncRelay(); await changed()
        return view(saved, state: try await store.read(), base: await relayBase())
    }

    public func deleteSource(_ id: String) async throws {
        try await ready()
        guard !RCVPresets.isInternal(id) else { throw NativeRPCError.invalidArguments("Terminal Deck’s own sources can be paused but not deleted.") }
        guard try await store.read().sources.contains(where: { $0.id == id }) else { throw Self.noSource() }
        try await store.update { state in
            state.sources.removeAll { $0.id == id }; state.secrets[id] = nil
            for index in state.rules.indices where state.rules[index].sourceIds.contains(id) {
                state.rules[index].sourceIds.removeAll { $0 == id }
                // A rule left with no source would match every source: switch it off instead.
                if state.rules[index].sourceIds.isEmpty { state.rules[index].enabled = false }
            }
        }
        await syncRelay(); await changed()
    }

    /// Owner's own screen only. Never offered to tools.
    public func revealSecret(_ id: String) async throws -> RCVSecretReveal {
        try await ready()
        let state = try await store.read()
        guard let source = state.sources.first(where: { $0.id == id }), let secret = state.secrets[id]?.secret,
              let shown = reveal(source, secret: secret, base: await relayBase()) else { throw NativeRPCError.invalidArguments("This source has no secret to show.") }
        return shown
    }

    public func rotateSecret(_ id: String) async throws -> RCVSecretReveal {
        try await ready()
        let state = try await store.read()
        guard let source = state.sources.first(where: { $0.id == id }), source.origin == .relay else { throw Self.noSource() }
        let secret = BackendRCVWire.mintSecret()
        try await store.update { state in state.secrets[id] = .init(secret: secret, reply: state.secrets[id]?.reply) }
        await syncRelay(); await changed()
        guard let shown = reveal(source, secret: secret, base: await relayBase()) else { throw NativeRPCError.invalidArguments("This source has no secret to replace.") }
        return shown
    }

    /// Owner's own screen only: use the sender's secret (e.g. Sentry's Client Secret) instead of the one minted here.
    public func setSecret(_ id: String, value: String) async throws -> RCVSecretReveal {
        try await ready()
        let clean = value.trimmingCharacters(in: .whitespaces)
        guard (8...4_096).contains(clean.count), !clean.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw NativeRPCError.invalidArguments("Paste a secret of 8 to 4,096 characters, on one line.")
        }
        let state = try await store.read()
        guard let source = state.sources.first(where: { $0.id == id }), source.origin == .relay else { throw Self.noSource() }
        // A token in the address path must keep the address-safe shape the relay accepts.
        if source.auth.scheme == .token, clean.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("A secret token must be 32 to 128 letters, digits, - or _.")
        }
        try await store.update { state in state.secrets[id] = .init(secret: clean, reply: state.secrets[id]?.reply) }
        await syncRelay(); await changed()
        guard let shown = reveal(source, secret: clean, base: await relayBase()) else { throw NativeRPCError.invalidArguments("This source does not use a secret.") }
        return shown
    }

    public func setReplyCredential(_ id: String, value: String) async throws -> RCVSourceView {
        try await ready()
        guard value.count <= 4_096, !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { throw NativeRPCError.invalidArguments("That reply credential is not valid.") }
        guard try await store.read().sources.contains(where: { $0.id == id && $0.origin == .relay }) else { throw Self.noSource() }
        try await store.update { state in
            var secrets = state.secrets[id] ?? .init(secret: "")
            secrets.reply = value.isEmpty ? nil : value
            state.secrets[id] = secrets
        }
        await changed()
        let state = try await store.read()
        return view(state.sources.first { $0.id == id }!, state: state, base: await relayBase())
    }

    public func learn(sourceID: String, eventID: String? = nil, sample: String? = nil, headers: [String: String] = [:]) async throws -> RCVMapping {
        try await ready()
        if let sample { return RCVEngine.learn(body: Data(sample.utf8), headers: headers) }
        let state = try await store.read()
        let candidates = state.events.reversed().filter { $0.sourceId == sourceID && $0.status != .rejected && $0.raw.count > 2 }
        guard let event = eventID.flatMap({ id in candidates.first { $0.id == id } }) ?? candidates.first else {
            throw NativeRPCError.invalidArguments("Nothing has arrived from this source yet. Send one, or paste a sample.")
        }
        return RCVEngine.learn(body: event.raw, headers: event.headers)
    }

    public func savePreset(sourceID: String, name: String) async throws -> RCVPreset {
        try await ready()
        let state = try await store.read()
        guard let source = state.sources.first(where: { $0.id == sourceID }), source.origin == .relay else { throw Self.noSource() }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= 80 else { throw NativeRPCError.invalidArguments("Give the preset a name of up to 80 characters.") }
        let preset = RCVPreset(id: "custom-" + UUID().uuidString.lowercased(), name: clean, help: "Saved from the source “\(source.name)”.",
                               symbol: "square.and.arrow.down", auth: source.auth, mapping: source.mapping, reply: source.reply, builtIn: false)
        try await store.update { state in
            guard state.customPresets.count < 50 else { throw NativeRPCError.invalidArguments("At most 50 saved presets.") }
            state.customPresets.append(preset)
        }
        await changed()
        return preset
    }

    // MARK: - Rules

    /// `byOwner` false (a tool): auto-approved replies may be turned off but never on.
    public func saveRule(_ incoming: RCVRule, byOwner: Bool) async throws -> RCVRule {
        try await ready()
        var rule = incoming
        try RCVEngine.validate(rule)
        let state = try await store.read()
        let existing = state.rules.first { $0.id == rule.id }
        if !byOwner, rule.autoApproveReplies, existing?.autoApproveReplies != true {
            throw NativeRPCError(code: "owner-only", message: "Only the owner can turn on sending replies without asking, on the Receiver page.")
        }
        let known = Set(state.sources.map(\.id))
        rule.sourceIds = rule.sourceIds.filter(known.contains)
        if !incoming.sourceIds.isEmpty, rule.sourceIds.isEmpty { throw NativeRPCError.invalidArguments("None of the rule’s sources exist any more.") }
        let saved = rule
        try await store.update { state in
            if let index = state.rules.firstIndex(where: { $0.id == saved.id }) { state.rules[index] = saved }
            else {
                guard state.rules.count < 200 else { throw NativeRPCError.invalidArguments("At most 200 rules.") }
                state.rules.append(saved)
            }
        }
        await changed()
        return saved
    }

    public func deleteRule(_ id: String) async throws {
        try await ready()
        guard try await store.read().rules.contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That rule no longer exists.") }
        try await store.update { state in state.rules.removeAll { $0.id == id }; state.threads = state.threads.filter { !$0.key.hasPrefix(id + "|") } }
        await changed()
    }

    public func moveRule(_ id: String, to index: Int) async throws -> [RCVRule] {
        try await ready()
        let rules = try await store.update { state -> [RCVRule] in
            guard let from = state.rules.firstIndex(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That rule no longer exists.") }
            let rule = state.rules.remove(at: from)
            state.rules.insert(rule, at: max(0, min(index, state.rules.count)))
            return state.rules
        }
        await changed()
        return rules
    }

    /// Dry run: what would happen, with nothing sent and no limits spent.
    public func test(rule draft: RCVRule?, eventID: String?, sourceID: String?, sample: String?) async throws -> (RCVDecision, RCVEvent) {
        try await ready()
        let state = try await store.read()
        var event: RCVEvent
        if let eventID {
            guard let found = state.events.first(where: { $0.id == eventID }) else { throw NativeRPCError.invalidArguments("That Receiver event no longer exists.") }
            event = found; event.status = .unrouted
        } else {
            let sourceID = sourceID ?? draft?.sourceIds.first
            guard let sourceID, let source = state.sources.first(where: { $0.id == sourceID }) else { throw NativeRPCError.invalidArguments("Choose a source or an event to test with.") }
            let body = sample.map { Data($0.utf8) } ?? state.events.last(where: { $0.sourceId == sourceID && $0.raw.count > 2 })?.raw
            guard let body else { throw NativeRPCError.invalidArguments("Nothing has arrived from this source yet. Paste a sample to test with.") }
            guard let first = RCVEngine.normalize(body: body, headers: ["content-type": "application/json"], meta: ["source": sourceID], source: source, receivedAt: now()).first else {
                throw NativeRPCError.invalidArguments("The sample could not be read.")
            }
            event = first
        }
        if let draft { try RCVEngine.validate(draft) }
        var memory = state.memory
        let name = state.sources.first { $0.id == event.sourceId }?.name ?? event.sourceId
        let decision = RCVRouter.decide(event, rules: draft.map { [$0] } ?? state.rules, sourceName: name, memory: &memory, now: now(), commit: false)
        return (decision, event)
    }

    // MARK: - Retry, replay, route by hand

    public func retry(_ id: String) async throws -> RCVEvent {
        try await ready()
        let event = try await self.event(id)
        guard [.failed, .held, .unrouted].contains(event.status) else { throw NativeRPCError.invalidArguments("Only a failed, waiting or unrouted event can be retried. Use replay to run it again.") }
        let at = now()
        try await store.update { state in
            if let index = state.events.firstIndex(where: { $0.id == id }) {
                state.events[index].status = .unrouted; state.events[index].resumeAt = nil
                state.events[index].trail.append(.init(at: at, "Retried."))
            }
        }
        await route([id])
        return try await self.event(id)
    }

    public func replay(_ id: String) async throws -> RCVEvent {
        try await ready()
        let original = try await self.event(id)
        guard original.status != .rejected else { throw NativeRPCError.invalidArguments("A refused delivery cannot be replayed; nothing from it was kept.") }
        let at = now()
        var copy = RCVEvent(sourceId: original.sourceId, receivedAt: at, time: original.time, kind: original.kind, severity: original.severity,
                            title: original.title, text: original.text, fields: original.fields, raw: original.raw, headers: original.headers,
                            upstreamId: original.upstreamId)
        copy.replayOf = original.id
        copy.trail = [.init(at: at, "Replayed from an event received \(Self.clock(original.receivedAt)).")]
        let made = copy
        try await store.update { state in state.events.append(made) }
        await route([made.id])
        return try await self.event(made.id)
    }

    public func route(_ id: String, to target: RCVTarget, instruction: String?) async throws -> RCVEvent {
        try await ready()
        let original = try await self.event(id)
        guard original.status != .rejected else { throw NativeRPCError.invalidArguments("A refused delivery cannot be routed; nothing from it was kept.") }
        var probe = RCVRule(name: "By hand", target: target, instruction: instruction ?? "{{title}}\n{{text}}")
        probe.perMinute = 120
        try RCVEngine.validate(probe)
        let state = try await store.read()
        let name = state.sources.first { $0.id == original.sourceId }?.name ?? original.sourceId
        let filled = RCVRouter.framing(original, sourceName: name) + (try RCVEngine.render(probe.instruction, in: .of(original)))
        let at = now()
        try await store.update { state in
            if let index = state.events.firstIndex(where: { $0.id == id }) {
                state.events[index].target = target; state.events[index].instruction = filled; state.events[index].ruleId = nil
                state.events[index].trail.append(.init(at: at, "Routed by hand to \(target.kind.title.lowercased())."))
            }
        }
        await deliver(try await self.event(id), to: target, instruction: filled, rule: nil)
        await changed()
        return try await self.event(id)
    }

    public func suggest(_ id: String) async throws -> RCVRule {
        try await ready()
        let event = try await self.event(id)
        let name = try await store.read().sources.first { $0.id == event.sourceId }?.name ?? event.sourceId
        return RCVRouter.suggestion(for: event, sourceName: name)
    }

    /// Hoot gets a task to propose a rule; it saves one through receiver_rule_change, which asks the owner first.
    public func askHoot(_ id: String) async throws -> String {
        try await ready()
        let event = try await self.event(id)
        let name = try await store.read().sources.first { $0.id == event.sourceId }?.name ?? event.sourceId
        let fields = event.fields.keys.sorted().map { "fields.\($0)" }.joined(separator: ", ")
        let text = "An event from \(name) matched no Receiver rule (event \(event.id), type “\(event.kind)”, title “\(event.title.prefix(120))”). " +
            "Its fields: \(fields.isEmpty ? "none" : fields). Read it with receiver_event, then propose a rule with receiver_rule_change " +
            "(sources: [\"\(event.sourceId)\"]) that sends events like it to the right agent. The owner is asked before it is saved."
        return try await dispatch.createTask(assignee: "hoot", title: "Suggest a Receiver rule for \(name)", instructions: text, project: "")
    }

    // MARK: - Replies out

    /// Whether a reply to this event must ask the owner first.
    public func replyNeedsApproval(_ id: String) async throws -> Bool {
        try await ready()
        let state = try await store.read()
        guard let event = state.events.first(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That Receiver event no longer exists.") }
        guard let ruleID = event.ruleId, let rule = state.rules.first(where: { $0.id == ruleID }) else { return true }
        return !(rule.enabled && rule.autoApproveReplies)
    }

    /// What the owner is shown before approving: where it goes, never the credential.
    public func replyPreview(_ id: String) async throws -> String {
        try await ready()
        let state = try await store.read()
        guard let event = state.events.first(where: { $0.id == id }), let source = state.sources.first(where: { $0.id == event.sourceId }),
              let channel = source.reply else { throw NativeRPCError.invalidArguments("This source has no way to reply set up.") }
        switch channel.via {
        case .github:
            let context = RCVEngine.Context.of(event)
            return "a comment on \(try RCVEngine.render(channel.repository ?? "", in: context, limit: 200)) #\(try RCVEngine.render(channel.number ?? "", in: context, limit: 40)) through your GitHub sign-in"
        case .http:
            let host = channel.url.dropFirst("https://".count).prefix { $0 != "/" }
            return "\(source.name) (\(host))"
        }
    }

    public func reply(_ id: String, text: String, by: String, autoApproved: Bool) async throws -> RCVEvent {
        try await ready()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 8_000 else { throw NativeRPCError.invalidArguments("Write a reply of up to 8,000 characters.") }
        let state = try await store.read()
        guard let event = state.events.first(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That Receiver event no longer exists.") }
        guard event.status != .rejected, let source = state.sources.first(where: { $0.id == event.sourceId }), let channel = source.reply else {
            throw NativeRPCError.invalidArguments("This source has no way to reply set up.")
        }
        guard event.replies.filter({ $0.state == .sent }).count < Self.maxRepliesPerEvent else { throw NativeRPCError.invalidArguments("This event already has \(Self.maxRepliesPerEvent) replies.") }
        let at = now()
        let window = (replyHits[source.id] ?? []).filter { $0 > at - 60_000 }
        guard window.count < Self.maxRepliesPerSourcePerMinute else { throw NativeRPCError(code: "rate-limited", message: "Too many replies through \(source.name) this minute. Try again shortly.") }
        replyHits[source.id] = window + [at]
        var outcome = RCVReply(at: at, text: clean, state: .sent, by: by, autoApproved: autoApproved)
        do {
            switch channel.via {
            case .github:
                let context = RCVEngine.Context.of(event)
                let repository = try RCVEngine.render(channel.repository ?? "", in: context, limit: 200)
                guard repository.range(of: #"^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$"#, options: .regularExpression) != nil,
                      let number = Int(try RCVEngine.render(channel.number ?? "", in: context, limit: 20)), number > 0 else {
                    throw NativeRPCError.invalidArguments("This event has no repository and number to answer on.")
                }
                let body = try RCVEngine.render(channel.body.isEmpty ? "{{reply}}" : channel.body, in: RCVEngine.Context.of(event, extra: ["reply": clean]), limit: 65_000)
                try await dispatch.githubComment(repository: repository, number: number, body: body)
            case .http:
                let request = try BackendRCVReplySender.request(for: channel, event: event, text: clean, credential: state.secrets[source.id]?.reply)
                let status = try await dispatch.send(request)
                guard (200...299).contains(status) else { throw NativeRPCError(code: "reply-failed", message: "\(source.name) answered \(status), so the reply may not have arrived.") }
            }
        } catch {
            outcome.state = .failed; outcome.detail = Self.words(error)
        }
        let saved = outcome
        try await store.update { state in
            if let index = state.events.firstIndex(where: { $0.id == id }) {
                state.events[index].replies.append(saved)
                state.events[index].trail.append(.init(at: at, saved.state == .sent ? "Replied through \(source.name)\(saved.autoApproved ? " (allowed by the rule)" : "")." : "Reply failed: \(saved.detail ?? "")"))
            }
            if saved.state == .sent { state.sentReplies[Self.digest(clean)] = at }
        }
        await changed()
        if saved.state == .failed { throw NativeRPCError(code: "reply-failed", message: saved.detail ?? "The reply was not sent.") }
        return try await self.event(id)
    }

    // MARK: - Helpers

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func words(_ error: Error) -> String { (error as? NativeRPCError)?.message ?? (error as? RCVEngine.TemplateError)?.message ?? "Something went wrong." }
    static func noSource() -> NativeRPCError { .invalidArguments("That Receiver source no longer exists.") }
    static func clock(_ ms: Double) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// Lets any feature post Terminal Deck's own events without holding the service.
/// Before the Receiver starts, a few are kept and handed over when it does.
public actor BackendRCVFeed {
    public static let shared = BackendRCVFeed()
    private var sink: BackendRCVService?
    private var pending: [(String, BackendRCVInternalEvent)] = []
    public func install(_ service: BackendRCVService?) async {
        sink = service
        guard let service else { return }
        let queued = pending; pending = []
        for (source, event) in queued { await service.post(internal: source, event) }
    }
    /// `source`: one of `RCVPresets.internalSources` ids, e.g. "terminaldeck.servers".
    public func post(_ source: String, _ event: BackendRCVInternalEvent) async {
        if let sink { await sink.post(internal: source, event); return }
        pending.append((source, event)); if pending.count > 50 { pending.removeFirst(pending.count - 50) }
    }
    /// Opt-in stream publishers must not retain events before Receiver exists.
    public func postIfAvailable(_ source: String, _ event: BackendRCVInternalEvent) async {
        guard let sink else { return }
        await sink.post(internal: source, event)
    }
}

/// The one door between the existing relay connection and the Receiver (see RCV.md "For INT2").
public actor BackendRCVRelayLink {
    public static let shared = BackendRCVRelayLink()
    private var service: BackendRCVService?
    private var send: BackendRCVService.Send?
    public func install(_ service: BackendRCVService?) async {
        self.service = service
        if let service, let send { await service.relayOpened(send) }
    }
    public func opened(_ send: @escaping BackendRCVService.Send) async { self.send = send; await service?.relayOpened(send) }
    public func closed() async { send = nil; await service?.relayClosed() }
    public func frame(type: UInt8, channel: Data, payload: Data) async { await service?.relayFrame(type: type, channel: channel, payload: payload) }
}
