import Foundation
import TerminalDeckNativeCore

/// The WhatsApp agents engine (DESIGN-WHATSAPP.md second version): the profiles, their keys, where each is received,
/// which computer reads it, and one `BackendWhatsAppLink` per agent this computer reads. What the screens and the tools
/// call (`WhatsAppAgentsControlling`). One engine per app; never two polls of one agent from one app.
public actor BackendWhatsAppAgents: WhatsAppAgentsControlling {
    /// A computer that has been off this long gives its Hoot and agent receivers to one that is on (design section 5).
    public static let takeOverAfter: TimeInterval = 10 * 60
    /// The reader decision is looked at again this often (take-over, a key that arrived, a session that ended).
    public static let lookEvery: TimeInterval = 60

    private let transport: any WhatsAppTransport
    private let settings: any WhatsAppSettingsPort
    private let keys: any WhatsAppKeyKeeping
    private let presence: any WhatsAppPresencePort
    private let receivers: any WhatsAppReceiverPort
    private let clock: BackendWhatsAppLink.Clock
    /// A key removed in the app goes everywhere through the saved passwords' delete rule; false = not handled there
    /// (saved passwords off) and the key is removed here only.
    private let removeEverywhere: @Sendable (_ id: String) async -> Bool

    private var links: [String: BackendWhatsAppLink] = [:]
    private var changed: (@Sendable ([WhatsAppAgentProfile]) -> Void)?
    private var ticking: Task<Void, Never>?
    private var started = false
    /// Tells the saved passwords a key was added or replaced here, so it travels at once.
    private var keysChanged: (@Sendable () -> Void)?
    public func setKeysChanged(_ handler: (@Sendable () -> Void)?) { keysChanged = handler }

    public init(transport: any WhatsAppTransport, settings: any WhatsAppSettingsPort, keys: any WhatsAppKeyKeeping,
                presence: any WhatsAppPresencePort, receivers: any WhatsAppReceiverPort,
                removeEverywhere: @escaping @Sendable (String) async -> Bool = { _ in false }) {
        self.init(transport: transport, settings: settings, keys: keys, presence: presence, receivers: receivers, clock: .live, removeEverywhere: removeEverywhere)
    }
    init(transport: any WhatsAppTransport, settings: any WhatsAppSettingsPort, keys: any WhatsAppKeyKeeping,
         presence: any WhatsAppPresencePort, receivers: any WhatsAppReceiverPort, clock: BackendWhatsAppLink.Clock,
         removeEverywhere: @escaping @Sendable (String) async -> Bool = { _ in false }) {
        self.transport = transport; self.settings = settings; self.keys = keys; self.presence = presence
        self.receivers = receivers; self.clock = clock; self.removeEverywhere = removeEverywhere
    }

    /// Starts following the settings and reading the agents this computer reads. Safe to call twice.
    public func start() async {
        guard !started else { return }
        started = true
        await settings.observe { [weak self] in Task { await self?.reconcile() } }
        let every = Self.lookEvery, clock = clock
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                await clock.sleep(every)
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }
        await reconcile()
    }
    public func stop() {
        ticking?.cancel(); ticking = nil
        for link in links.values { Task { await link.stop() } }
        links = [:]; started = false
    }

    // MARK: Records

    private func live() async -> [WhatsAppAgentRecord] {
        await settings.records().filter { !$0.removed }.sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
    }
    func record(_ id: String) async -> WhatsAppAgentRecord? { await settings.records().first { $0.id == id } }
    private func change(_ id: String, _ edit: (inout WhatsAppAgentRecord) -> Void) async throws {
        guard var record = await record(id), !record.removed else { throw WhatsAppProblem.notFound }
        edit(&record)
        try await settings.save(record)
    }

    // MARK: WhatsAppAgentsControlling

    public func agents() async -> [WhatsAppAgentProfile] {
        let me = await presence.thisComputer()
        var output: [WhatsAppAgentProfile] = []
        for record in await live() {
            let state: WhatsAppAgentState = record.refused ? .refused : record.creator != nil ? .connected : .waiting
            var reader: String?
            if let id = record.readerID { reader = id == me.id ? me.name : (await presence.name(id) ?? record.readerName) }
            output.append(.init(id: record.id, name: record.name, state: state, receiver: record.receiver,
                                answeringComputerName: record.receiver == .nowhere ? nil : reader,
                                answeredHere: record.readerID == me.id && record.receiver != .nowhere, takenOver: record.takenOver,
                                lastMessageAt: record.lastMessageAt.map { Date(timeIntervalSince1970: $0 / 1000) }, sending: record.isSending))
        }
        return output
    }
    public func observe(_ changed: (@Sendable ([WhatsAppAgentProfile]) -> Void)?) { self.changed = changed }

    private func checked(_ key: String) async throws -> String {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WhatsAppAgentIDs.plausibleKey(clean) else { throw WhatsAppProblem.keyRefused }
        switch await transport.check(key: clean) {
        case .accepted: return clean
        case .refused: throw WhatsAppProblem.keyRefused
        case .unreachable: throw WhatsAppProblem.unreachable
        }
    }
    static func cleanName(_ name: String, taken: [String]) -> String {
        let line = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? WhatsAppAgentsLimits.defaultName(taken: taken) : String(line.prefix(WhatsAppAgentsLimits.maximumNameLength))
    }

    @discardableResult public func add(name: String, key: String) async throws -> WhatsAppAgentProfile {
        let existing = await live()
        // The same key added twice is the same agent: the one row it already has. Looked at BEFORE the check, because
        // WhatsApp's key check replaces a reader already running for that key (one reader per agent).
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        for record in existing where (try? await keys.key(record.id)) == typed {
            if let profile = await agents().first(where: { $0.id == record.id }) { return profile }
        }
        let clean = try await checked(key)
        let me = await presence.thisComputer()
        let id = WhatsAppAgentIDs.make()
        // The first agent he adds is received by Hoot; later ones wait for him to choose.
        let receiver: WhatsAppReceiver = existing.isEmpty ? .hoot : .nowhere
        let record = WhatsAppAgentRecord(id: id, name: Self.cleanName(name, taken: existing.map(\.name)), receiver: receiver,
                                         readerID: receiver == .nowhere ? nil : me.id, readerName: receiver == .nowhere ? nil : me.name,
                                         addedAt: clock.now().timeIntervalSince1970 * 1000)
        var keyed = record; keyed.keyID = WhatsAppAgentIDs.fingerprint(clean)
        do { try await keys.setKey(clean, for: id) } catch { throw WhatsAppProblem.notReady }
        try await settings.save(keyed)
        keysChanged?()
        await reconcile()
        return await agents().first { $0.id == id } ?? .init(id: id, name: record.name, state: .waiting, receiver: receiver)
    }
    public func rename(_ id: String, to name: String) async throws {
        let taken = await live().filter { $0.id != id }.map(\.name)
        try await change(id) { $0.name = Self.cleanName(name, taken: taken) }
        await tell()
    }
    public func replaceKey(_ id: String, key: String) async throws {
        guard await record(id) != nil else { throw WhatsAppProblem.notFound }
        // This computer stops reading it first: the check replaces any reader of that key. Another computer reading the
        // old key is not touched (a new key is another reader); one reading this very key gets a 409 and re-reads.
        await links.removeValue(forKey: id)?.stop()
        let clean: String
        do { clean = try await checked(key) } catch { await reconcile(); throw error }
        do { try await keys.setKey(clean, for: id) } catch { throw WhatsAppProblem.notReady }
        // A new key may be another agent: its creator and head are learned again; nothing of its backlog is answered.
        // A new key: its own fingerprint; sender and position start fresh (every computer drops the old reader).
        let print = WhatsAppAgentIDs.fingerprint(clean)
        try await change(id) { $0.refused = false; $0.offset = nil; $0.creator = nil; $0.lastMessageAt = nil; $0.keyID = print }
        keysChanged?()
        await reconcile()
    }
    public func remove(_ id: String) async throws {
        await links.removeValue(forKey: id)?.stop()
        try await change(id) { $0.removed = true; $0.receiver = .nowhere; $0.readerID = nil }
        if !(await removeEverywhere(id)) { _ = try? await keys.remove(id, expecting: nil) }
        await tell()
    }
    public func setReceiver(_ id: String, _ receiver: WhatsAppReceiver) async throws {
        let me = await presence.thisComputer()
        // A session's Cloud id travels with the record, so the agent follows the session if it moves to another computer.
        var cloud: String?
        if case .session(let sessionID, _) = receiver { cloud = await receivers.cloudSessionID(sessionID) }
        try await change(id) { record in
            record.receiver = receiver
            record.cloudSessionID = cloud
            // Moving the receiver moves the reader: the computer where he attached it (a session's own computer).
            record.readerID = receiver == .nowhere ? nil : me.id
            record.readerName = receiver == .nowhere ? nil : me.name
            record.takenOver = false; record.endedSession = false
            // Attaching turns the switch on.
            record.sending = true
        }
        await links.removeValue(forKey: id)?.stop()
        await reconcile()
    }
    public func setSending(_ on: Bool, for agentID: String) async throws {
        try await change(agentID) { $0.sending = on }
        await tell()
    }
    public func off(_ receiver: WhatsAppReceiver) async throws {
        for record in await live() where record.receiver.sameTarget(receiver) { try await setReceiver(record.id, .nowhere) }
    }

    // MARK: Sessions and tools

    /// A session that ended or was closed: its WhatsApp agents go to "Nowhere"; the next message is answered once.
    public func sessionEnded(_ sessionID: String) async {
        for record in await live() where record.receiver.sameTarget(.session(id: sessionID, name: "")) {
            // A session that closed because it moved is not ended (the taker rewrites the record).
            if await leaving(record) { continue }
            try? await change(record.id) { $0.receiver = .nowhere; $0.endedSession = true }
        }
        await reconcile()
    }

    /// "Switch to this Mac" succeeded HERE (DESIGN-WHATSAPP.md section 5, "a session that moves takes its WhatsApp agent
    /// with it"): every WhatsApp agent at that session (found by its Cloud id, also after an old computer sent it Nowhere
    /// as ended) is received by the session here and read by this computer. Its position, creator, key fingerprint and
    /// switch are carried unchanged; nothing is asked. A key that has not arrived yet is read as soon as it is here.
    public func sessionArrived(cloudSessionID: String, sessionID: String, name: String? = nil) async {
        guard !cloudSessionID.isEmpty, !sessionID.isEmpty else { return }
        let me = await presence.thisComputer()
        for record in await live() where record.cloudSessionID == cloudSessionID {
            let kept: String
            switch record.receiver {
            case .session(_, let old): kept = old.isEmpty ? (name ?? "") : old
            case .nowhere where record.endedSession: kept = name ?? ""
            default: continue                                   // he chose another place meanwhile: his choice stands
            }
            if record.receiver.sameTarget(.session(id: sessionID, name: "")), record.readerID == me.id, !record.endedSession { continue }
            try? await change(record.id) { moved in
                moved.receiver = .session(id: sessionID, name: kept)
                moved.readerID = me.id; moved.readerName = me.name
                moved.takenOver = false; moved.endedSession = false
            }
            await links.removeValue(forKey: record.id)?.stop()
        }
        await reconcile()
    }

    /// True while the record's session is moving away from this computer (or was handed over from here).
    private func leaving(_ record: WhatsAppAgentRecord) async -> Bool {
        guard case .session = record.receiver, let cloud = record.cloudSessionID, !cloud.isEmpty else { return false }
        return await receivers.leaving(cloudSessionID: cloud)
    }
    /// The WhatsApp agents attached to this session (the tools' "the calling session is the attached one").
    public func attached(sessionID: String) async -> [String] {
        await live().filter { $0.receiver.sameTarget(.session(id: sessionID, name: "")) }.map(\.id)
    }
    /// True when a tool call carrying `sessionID` comes from the place this WhatsApp agent is received (its session, or
    /// Hoot's or the agent's lasting conversation for it): then `whatsapp.receive` and `whatsapp.send` do not ask.
    public func isFrom(sessionID: String, agent id: String) async -> Bool {
        guard !sessionID.isEmpty, let record = await record(id), !record.removed else { return false }
        if record.receiver.sameTarget(.session(id: sessionID, name: "")) { return true }
        guard let target = await links[id]?.currentTarget else { return false }
        if target.sessionID == sessionID { return true }
        return await receivers.isToolSession(target, sessionID)
    }

    /// One text to him on that WhatsApp agent (`whatsapp.send`). Only ever to its creator.
    public func send(_ id: String, text: String) async throws {
        guard let record = await record(id), !record.removed else { throw WhatsAppProblem.notFound }
        guard let creator = record.creator else {
            throw WhatsAppProblem("He has not written to this WhatsApp agent yet, and WhatsApp only lets an agent answer its creator.")
        }
        guard !record.refused, let key = try? await keys.key(id) else { throw WhatsAppProblem.keyRefused }
        if let link = links[id] { await link.send(text, to: creator); await link.flushed(); return }
        // Read by another computer: one send from here, in pieces, one after another.
        for piece in WhatsAppText.split(WhatsAppText.format(text)) {
            switch await transport.send(key: key, to: creator, text: piece) {
            case .sent: continue
            case .keyRefused: throw WhatsAppProblem.keyRefused
            case .backOff: throw WhatsAppProblem("WhatsApp asked to slow down. Try again in a minute.")
            case .notCreator, .failed: throw WhatsAppProblem("WhatsApp did not take this message.")
            }
        }
    }

    // MARK: One reader per agent

    /// Whether THIS computer reads the agent now, taking it over from a computer that has been off for 10 minutes.
    func decide(_ record: WhatsAppAgentRecord, me: WhatsAppComputer) async -> Bool {
        guard !record.removed, !record.refused, record.receiver != .nowhere || record.endedSession else { return false }
        if record.readerID == me.id { return true }
        guard record.receiver.canMoveComputer else { return false }
        let off: Bool
        if let reader = record.readerID {
            guard let seen = await presence.lastSeen(reader) else { return false }
            off = clock.now().timeIntervalSince(seen) > Self.takeOverAfter
        } else { off = true }
        guard off else { return false }
        try? await change(record.id) { $0.readerID = me.id; $0.readerName = me.name; $0.takenOver = true }
        return true
    }

    private var reconciling = false, again = false
    /// One decision at a time: a change arriving meanwhile runs one more pass after it (never two passes at once).
    func reconcile() async {
        if reconciling { again = true; return }
        reconciling = true
        repeat { again = false; await pass() } while again
        reconciling = false
    }
    private func pass() async {
        let me = await presence.thisComputer()
        var wanted: Set<String> = []
        for record in await live() {
            guard await decide(record, me: me) else { continue }
            // A session receiver read here without its Cloud id yet (attached before it was known): learned now.
            if case .session(let sessionID, _) = record.receiver, record.cloudSessionID == nil, record.readerID == me.id,
               let cloud = await receivers.cloudSessionID(sessionID) {
                try? await change(record.id) { $0.cloudSessionID = cloud }
            }
            // Fault 1: only with the key this record belongs to (a replaced key that has not arrived here: not yet).
            guard let key = try? await keys.key(record.id) else { continue }
            let print = WhatsAppAgentIDs.fingerprint(key)
            guard record.keyID == print else { continue }
            wanted.insert(record.id)
            if let running = links[record.id], running.keyID != print { await running.stop(); links[record.id] = nil }
            if links[record.id] == nil {
                let id = record.id, meID = me.id
                let link = BackendWhatsAppLink(agentID: id, key: key, transport: transport, receivers: receivers, clock: clock,
                    read: { [weak self] in await self?.record(id) },
                    update: { [weak self] edit in await self?.linkChange(id, keyID: print, edit) },
                    stopped: { [weak self] why in await self?.linkStopped(id, why) },
                    stillReader: { [weak self] in
                        // Fault 2: messages are handled only while the record still names THIS computer with this key.
                        guard let record = await self?.record(id) else { return false }
                        return !record.removed && record.readerID == meID && record.keyID == print
                    },
                    holding: { [weak self] in
                        guard let self, let record = await self.record(id) else { return false }
                        return await self.leaving(record)
                    })
                links[id] = link
                await link.start()
            }
        }
        for (id, link) in links where !wanted.contains(id) { await link.stop(); links[id] = nil }
        await tell()
    }
    /// A link's write is dropped once the record belongs to another key (fault 1: an old reader never writes the old
    /// agent's sender or position back).
    private func linkChange(_ id: String, keyID: String, _ edit: @Sendable (inout WhatsAppAgentRecord) -> Void) async {
        guard let current = await record(id), current.keyID == keyID else { return }
        // Security (aabe9266c): while this computer is giving the session away, its reader writes nothing. Decided HERE,
        // at the moment of writing (also for a batch begun before the move): a late save of the old copy would undo the
        // new computer's claim. A cancelled move ends this at once (the journal says cancelled).
        if await leaving(current) { return }
        try? await change(id, edit)
        await tell()
    }
    /// The link stopped (no longer the reader, or the key refused): the settings decide again.
    private func linkStopped(_ id: String, _ why: BackendWhatsAppLink.StopReason) async {
        await links.removeValue(forKey: id)?.stop()
        await reconcile()
    }
    private func tell() async {
        guard let changed else { return }
        changed(await agents())
    }
    /// Test seam: the link reading this agent here, if any.
    func link(_ id: String) -> BackendWhatsAppLink? { links[id] }
    /// Test seam: the agents read here now.
    func readHere() -> [String] { links.keys.sorted() }
}

/// The synced settings door on the app settings file: one setting `whatsapp.agent.<id>` per agent (a JSON text, newest
/// change wins on every computer). Every key of the settings file travels unless it names this device (15 Nov rule).
public actor BackendWhatsAppSettingsStore: WhatsAppSettingsPort {
    public static let prefix = "whatsapp.agent."
    private let store: BackendAppSettingsStore
    private var subscription: NativeRPCSubscription?
    public init(store: BackendAppSettingsStore) { self.store = store }
    public func records() async -> [WhatsAppAgentRecord] {
        let all = await store.get()["values"].fields ?? []
        return all.compactMap { field in
            guard field.key.hasPrefix(Self.prefix), let text = field.value.string,
                  let record = try? JSONDecoder().decode(WhatsAppAgentRecord.self, from: Data(text.utf8)),
                  Self.prefix + record.id == field.key, WhatsAppAgentIDs.valid(record.id) else { return nil }
            return record
        }
    }
    public func save(_ record: WhatsAppAgentRecord) async throws {
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        guard text.utf16.count <= BackendAppSettingsStore.maxStringLength else { throw WhatsAppProblem("That name is too long.") }
        _ = try await store.patch(.object([.init(Self.prefix + record.id, .string(text))]))
    }
    public func observe(_ changed: @escaping @Sendable () -> Void) async {
        subscription = await store.observeSnapshot { _ in changed() }
    }
}
