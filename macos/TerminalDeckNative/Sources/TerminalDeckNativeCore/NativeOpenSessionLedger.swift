import Foundation

public struct NativeHeldSession: Equatable, Sendable {
    public let key: String
    public let saved: NativeRPCValue
    public var reason: String
    public var pick: Bool
    public var at: Double
    public var recoveryAction: String? = nil

    public var wireValue: NativeRPCValue {
        saved.setting("key", .string(key)).setting("reason", .string(reason)).setting("at", .number(at))
            .setting("pick", pick ? .bool(true) : .missing)
            .setting("recoveryAction", recoveryAction.map(NativeRPCValue.string) ?? (pick ? .string("choose-conversation") : .missing))
    }
}

/// Value-domain port of host-core's OpenSessionLedger and HeldSessions. Its
/// owner persists snapshot() through NativeStateStore; the ledger never opens a
/// second writer or writes on touch/typing.
public struct NativeOpenSessionLedger: Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let saved: NativeRPCValue
        public var wireValue: NativeRPCValue { .object([.init("id", .string(id)), .init("saved", saved)]) }
    }
    private var records: [Entry] = []
    private var pending: [NativeRPCValue]
    private var held: [NativeHeldSession] = []
    private var recoveryOrder: [String: Int] = [:]
    private var counter = 0
    public private(set) var isFrozen = false
    /// 10 Nov (Asad: "a restart brings back exactly the tabs that were open"): when each saved tab was last open, as
    /// the previous run wrote it (`openTabs` in state.json, ms since 1970). nil: a state.json from before this rule
    /// (the one-time clean-up decides). Live and held tabs are still open and are stamped with every write;
    /// a pending row keeps its previous stamp until restore decides what it is.
    public let previousOpenStamps: [String: Double]?

    public init(saved: [NativeRPCValue], openStamps: [String: Double]? = nil,
                makeTabKey: @Sendable () -> String = { UUID().uuidString.lowercased() }) throws {
        pending = try saved.map { record in
            _ = try record.requireObject("saved session")
            return record["tabKey"].isNullish ? record.setting("tabKey", .string(makeTabKey())) : record
        }
        previousOpenStamps = openStamps
        for (index, record) in pending.enumerated() { recoveryOrder[Self.key(record)] = index }
    }

    public mutating func note(_ id: String, saved: NativeRPCValue) throws {
        _ = try saved.requireObject("saved session")
        let key = Self.key(saved)
        // A name the person gave the session (`title`, written only by a rename) outlives a re-note of its launch:
        // the helper's sessions are noted again at every app start, a restored tab at its new start (Asad, 12 Oct).
        var saved = saved
        if saved["title"] == .missing,
           let earlier = records.first(where: { $0.id == id })?.saved ?? pending.first(where: { Self.key($0) == key }),
           earlier["title"].string?.isEmpty == false {
            saved = saved.setting("title", earlier["title"])
        }
        // 1 Nov (item 58): when the session last really did something outlives a re-note too (every app start
        // re-notes the helper's sessions; that is not activity).
        if let earlier = records.first(where: { $0.id == id })?.saved ?? pending.first(where: { Self.key($0) == key }),
           let at = earlier[Self.activityKey].number, at > (saved[Self.activityKey].number ?? 0) {
            saved = saved.setting(Self.activityKey, .number(at))
        }
        if let earlier = records.first(where: { $0.id == id })?.saved ?? pending.first(where: { Self.key($0) == key })
            ?? held.first(where: { Self.key($0.saved) == key })?.saved {
            saved = Self.carryingOver(earlier, into: saved)
        }
        pending.removeAll { Self.key($0) == key }
        let entry = Entry(id: id, saved: saved)
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = entry }
        else { records.append(entry) }
    }
    public mutating func update(_ id: String, patch: NativeRPCValue) throws {
        _ = try patch.requireObject("saved session patch")
        if let record = records.first(where: { $0.id == id }) { try note(id, saved: record.saved.merging(patch)) }
    }
    public mutating func forget(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func dropPending() { pending = [] }
    public func get(_ id: String) -> NativeRPCValue? {
        records.first { $0.id == id && $0.saved["confineDeviceId"] == .missing }?.saved
    }
    public func entries() -> [Entry] { records.filter { $0.saved["confineDeviceId"] == .missing } }
    /// 1 Nov (item 58): the saved field for when the session last really did something (ms since 1970).
    public static let activityKey = "activityAt"
    /// Moves `activityAt` forward only. False when the session is not remembered or the time is not newer.
    @discardableResult
    public mutating func markActivity(_ id: String, at: Double) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), at > (records[index].saved[Self.activityKey].number ?? 0) else { return false }
        records[index] = Entry(id: id, saved: records[index].saved.setting(Self.activityKey, .number(at)))
        return true
    }
    public mutating func touch(_ id: String, at: Double) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = Entry(id: id, saved: records[index].saved.setting("lastSeenAt", .number(at)))
        }
    }
    public mutating func freeze() { isFrozen = true }

    /// 10 Nov: the conversations a tab was in before its current one, newest first (at most this many). A restart
    /// whose saved conversation is not on disk continues the newest of these that is, instead of dropping the tab
    /// (Asad's Decker tab: a background session's id was followed and the real conversation was lost).
    public static let knownConversationsKey = "knownConversations"
    public static let knownConversationsLimit = 5
    /// Who opened the tab this time (person, hoot, agent or restore), who opened it first, and when this process
    /// started: what a re-note of the same live process must not change.
    public static let openedByKey = "openedBy", firstOpenedByKey = "firstOpenedBy", startedAtKey = "startedAt"

    /// What a new note of a tab keeps from its earlier record: the conversations it was in before, who first opened
    /// it, and — for the same process noted again (an app start re-notes the helper's sessions) — who opened it.
    static func carryingOver(_ earlier: NativeRPCValue, into saved: NativeRPCValue) -> NativeRPCValue {
        var saved = saved
        let known = [earlier["agentSessionId"].string].compactMap { $0 } + (earlier[knownConversationsKey].elements ?? []).compactMap(\.string)
            + (saved[knownConversationsKey].elements ?? []).compactMap(\.string)
        let current = saved["agentSessionId"].string
        var seen = Set<String>(), kept: [NativeRPCValue] = []
        for id in known where !id.isEmpty && id != current && seen.insert(id).inserted && kept.count < knownConversationsLimit { kept.append(.string(id)) }
        if !kept.isEmpty { saved = saved.setting(knownConversationsKey, .array(kept)) }
        else if saved.has(knownConversationsKey) { saved = saved.removing(knownConversationsKey) }
        if let first = earlier[firstOpenedByKey].string ?? earlier[openedByKey].string, saved[firstOpenedByKey] == .missing {
            saved = saved.setting(firstOpenedByKey, .string(first))
        }
        if let started = earlier[startedAtKey].number, saved[startedAtKey].number == started, let by = earlier[openedByKey].string {
            saved = saved.setting(openedByKey, .string(by))
        }
        return saved
    }

    /// The `openTabs` map to write with this snapshot: live and held tabs are stamped `now`. Holding a tab
    /// must not age its saved record out of the next restore; only pending rows retain their previous stamp.
    /// nil while the stamps are not ready (a state.json from before this rule, until the clean-up has run): nothing
    /// is written then, so a crash before the clean-up never turns "no stamps yet" into "no tab was open".
    public func openStamps(now: Double) -> [String: Double]? {
        guard stampsReady else { return nil }
        var stamps: [String: Double] = [:]
        for saved in pending { if let at = openStamp(saved) { stamps[Self.stampKey(saved)] = at } }
        for entry in held { stamps[Self.stampKey(entry.saved)] = now }
        for record in records { stamps[Self.stampKey(record.saved)] = now }
        return stamps
    }
    public var stampsReady: Bool { previousOpenStamps != nil || cleanedUp }
    private var cleanedUp = false
    /// Stamps the one-time clean-up gives the tabs it keeps (a state.json written before `openTabs` existed).
    private var assignedStamps: [String: Double] = [:]
    public mutating func assignOpenStamp(_ saved: NativeRPCValue, at: Double) { assignedStamps[Self.stampKey(saved)] = at }
    public mutating func markStampsReady() { cleanedUp = true }
    /// The stamp a saved tab had at the end of the previous run, or the one the clean-up gave it.
    public func openStamp(_ saved: NativeRPCValue) -> Double? { assignedStamps[Self.stampKey(saved)] ?? previousOpenStamps?[Self.stampKey(saved)] }
    /// Removes pending (not yet restored) tabs for good: the restore found them closed, stale or never open.
    public mutating func discardPending(_ keys: Set<String>) { pending.removeAll { keys.contains(Self.stampKey($0)) } }
    /// The keys of the tabs live in this run (noted since this start).
    public func liveKeys() -> Set<String> { Set(records.map { Self.stampKey($0.saved) }) }
    /// The key `openTabs` uses: the tab's own key (every saved tab has one after the first start).
    public static func stampKey(_ saved: NativeRPCValue) -> String { saved["tabKey"].string ?? key(saved) }

    public func snapshot() -> [NativeRPCValue] {
        // Map replacement retains first insertion position; newer values win.
        // Recovery order then restores old tabs ahead of this launch's new tabs.
        var result: [NativeRPCValue] = []
        var indices: [String: Int] = [:]
        for saved in pending + held.map(\.saved) + records.map(\.saved) {
            let key = Self.key(saved)
            if let index = indices[key] { result[index] = saved }
            else { indices[key] = result.count; result.append(saved) }
        }
        return result.enumerated().sorted {
            let a = recoveryOrder[Self.key($0.element)] ?? Int.max
            let b = recoveryOrder[Self.key($1.element)] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    public func heldSessions() -> [NativeHeldSession] { held }
    public func heldSession(_ key: String) -> NativeHeldSession? { held.first { $0.key == key } }
    public var heldEmpty: Bool { held.isEmpty }

    @discardableResult
    public mutating func hold(_ session: NativeRPCValue, reason: String, pick: Bool = false, at: Double, recoveryAction: String? = nil) throws -> NativeHeldSession {
        _ = try session.requireObject("held saved session")
        counter += 1
        // Failure-only fields live beside the original saved record, preserving
        // future session fields without writing reason/at/pick back to disk.
        let entry = NativeHeldSession(key: "held-\(counter)", saved: Self.savedForHold(session), reason: reason, pick: pick, at: at, recoveryAction: recoveryAction)
        // Preserve a first stamp for an unstamped row. openStamps keeps held tabs open until recovery or Forget.
        if openStamp(entry.saved) == nil { assignedStamps[Self.stampKey(entry.saved)] = at }
        held.append(entry)
        removeHeldFromPending()
        return entry
    }
    public mutating func failHeld(_ key: String, reason: String, at: Double, pick: Bool? = nil, recoveryAction: String? = nil) {
        guard let index = held.firstIndex(where: { $0.key == key }) else { return }
        held[index].reason = reason; held[index].at = at
        if let pick { held[index].pick = pick }
        if let recoveryAction { held[index].recoveryAction = recoveryAction }
        removeHeldFromPending()
    }
    @discardableResult
    public mutating func releaseHeld(_ key: String) -> Bool {
        guard let index = held.firstIndex(where: { $0.key == key }) else { return false }
        held.remove(at: index)
        removeHeldFromPending()
        return true
    }
    private mutating func removeHeldFromPending() {
        let keys = Set(held.map { Self.key($0.saved) })
        pending.removeAll { keys.contains(Self.key($0)) }
    }
    private static func key(_ saved: NativeRPCValue) -> String {
        saved["tabKey"].isNullish ? "anonymous:" + saved.compact : "tab:" + saved["tabKey"].compact
    }
    private static func savedForHold(_ raw: NativeRPCValue) -> NativeRPCValue {
        var saved = raw
        for name in ["agentSessionId", "model"] where saved[name].string?.isEmpty != false { saved = saved.removing(name) }
        if saved["deniedTools"].elements?.isEmpty != false { saved = saved.removing("deniedTools") }
        if saved["noSkills"].bool != true { saved = saved.removing("noSkills") }
        if saved["agentInstructions"].string?.isEmpty != false { saved = saved.removing("agentInstructions") }
        return saved
    }
}
