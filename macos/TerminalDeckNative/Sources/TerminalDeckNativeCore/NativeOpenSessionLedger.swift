import Foundation

public struct NativeHeldSession: Equatable, Sendable {
    public let key: String
    public let saved: NativeRPCValue
    public var reason: String
    public let pick: Bool
    public var at: Double

    public var wireValue: NativeRPCValue {
        saved.setting("key", .string(key)).setting("reason", .string(reason)).setting("at", .number(at))
            .setting("pick", pick ? .bool(true) : .missing)
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

    public init(saved: [NativeRPCValue], makeTabKey: @Sendable () -> String = { UUID().uuidString.lowercased() }) throws {
        pending = try saved.map { record in
            _ = try record.requireObject("saved session")
            return record["tabKey"].isNullish ? record.setting("tabKey", .string(makeTabKey())) : record
        }
        for (index, record) in pending.enumerated() { recoveryOrder[Self.key(record)] = index }
    }

    public mutating func note(_ id: String, saved: NativeRPCValue) throws {
        _ = try saved.requireObject("saved session")
        pending.removeAll { Self.key($0) == Self.key(saved) }
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
    public mutating func touch(_ id: String, at: Double) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = Entry(id: id, saved: records[index].saved.setting("lastSeenAt", .number(at)))
        }
    }
    public mutating func freeze() { isFrozen = true }

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
    public mutating func hold(_ session: NativeRPCValue, reason: String, pick: Bool = false, at: Double) throws -> NativeHeldSession {
        _ = try session.requireObject("held saved session")
        counter += 1
        // Failure-only fields live beside the original saved record, preserving
        // future session fields without writing reason/at/pick back to disk.
        let entry = NativeHeldSession(key: "held-\(counter)", saved: Self.savedForHold(session), reason: reason, pick: pick, at: at)
        held.append(entry)
        removeHeldFromPending()
        return entry
    }
    public mutating func failHeld(_ key: String, reason: String, at: Double) {
        guard let index = held.firstIndex(where: { $0.key == key }) else { return }
        held[index].reason = reason; held[index].at = at
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
