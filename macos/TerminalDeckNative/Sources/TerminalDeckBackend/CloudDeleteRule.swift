import Foundation

public enum CloudDeleteScope: String, Codable, Sendable, CaseIterable {
    case everywhere, cloud
}

public enum CloudDeleteBy: String, Codable, Sendable {
    case person, ai
}

/// Written BEFORE a kind changes its file/record. Reuse one group for the entire press, tool call or AI command.
/// `place` is the owner's stable path/record key; all times here are service milliseconds, not wall-clock seconds.
public struct CloudDeleteIntent: Codable, Sendable, Equatable {
    public let place: String
    public let scope: CloudDeleteScope
    public let by: CloudDeleteBy
    public let mac: String
    public let session: String?
    public let agent: String?
    public let at: Int64
    public let group: String

    public init(place: String, scope: CloudDeleteScope, by: CloudDeleteBy, mac: String,
                session: String? = nil, agent: String? = nil, at: Int64, group: String) {
        self.place = place; self.scope = scope; self.by = by; self.mac = mac
        self.session = session; self.agent = agent; self.at = at; self.group = group
    }
}

public enum CloudDeleteRuleError: Error, Sendable, Equatable {
    case invalidTravelFields
    case invalidState
}

public enum CloudDeleteTravelRemoval: Sendable, Equatable {
    /// No new-rule field: apply the existing removal as Everywhere, with the older-version Bin label.
    case olderVersion
    case intent(CloudDeleteIntent)
}

/// The SAME six fields in marker front matter and the file engines' sealed payload. The carrier already supplies
/// place, removing Mac and service time; do not invent another spelling for those existing fields here.
public enum CloudDeleteTravel {
    public static let rule = "td_delete_rule"
    public static let scope = "td_scope"
    public static let by = "td_by"
    public static let session = "td_session"
    public static let agent = "td_agent"
    public static let group = "td_group"
    public static let fields = [rule, scope, by, session, agent, group]

    public static func write(_ intent: CloudDeleteIntent, into fields: inout [String: String]) {
        fields[rule] = "1"
        fields[scope] = intent.scope.rawValue
        fields[by] = intent.by.rawValue
        fields[session] = intent.session
        fields[agent] = intent.agent
        fields[group] = intent.group
    }

    /// Malformed/unknown NEW fields are an error, never silently reinterpreted as an older Everywhere removal.
    public static func read(_ fields: [String: String], place: String, mac: String, at: Int64) throws -> CloudDeleteTravelRemoval {
        guard let version = fields[rule] else { return .olderVersion }
        guard version == "1", let scope = fields[Self.scope].flatMap(CloudDeleteScope.init(rawValue:)),
              let by = fields[Self.by].flatMap(CloudDeleteBy.init(rawValue:)),
              let group = fields[Self.group], UUID(uuidString: group) != nil else { throw CloudDeleteRuleError.invalidTravelFields }
        return .intent(.init(place: place, scope: scope, by: by, mac: mac, session: fields[session],
                             agent: fields[agent], at: at, group: group))
    }
}

public enum CloudLocalMark: String, Codable, Sendable, CaseIterable {
    case notOnThisMac = "not-on-this-mac"
    case onlyOnThisMac = "only-on-this-mac"

    public var title: String {
        switch self {
        case .notOnThisMac: CloudDeleteWords.notOnThisMac
        case .onlyOnThisMac: CloudDeleteWords.onlyOnThisMac
        }
    }
}

public struct CloudDeleteMark: Codable, Sendable, Equatable {
    public let place: String
    public let mark: CloudLocalMark
    public let at: Int64
    public init(place: String, mark: CloudLocalMark, at: Int64) {
        self.place = place; self.mark = mark; self.at = at
    }
}

/// Shares the owner's EXISTING connection and transaction, never opens a competing connection to its state file.
/// Memory: the attached `cloud` schema in memory-cloud.db. Folder/artifacts: main in folder.db.
/// Only called inside the owning actor. No changes to either database wrapper are needed.
struct CloudDeleteState {
    private enum Database {
        case memory(DeckMemoryDatabase)
        case files(BackendCloudBrainFilesDatabase)
    }
    private let database: Database
    private var prefix: String {
        if case .memory = database { return "cloud." }
        return ""
    }

    init(memory: DeckMemoryDatabase) throws {
        database = .memory(memory)
        // Without the attachment, SQLite must not create these local Cloud tables in memory.db by accident.
        guard try memory.rows("PRAGMA database_list").contains(where: { $0.text(1) == "cloud" }) else {
            throw CloudDeleteRuleError.invalidState
        }
        try createTables()
    }
    init(files: BackendCloudBrainFilesDatabase) throws {
        database = .files(files)
        try createTables()
    }
    private func createTables() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS \(prefix)cloud_delete_intents(
            place TEXT PRIMARY KEY, scope TEXT NOT NULL CHECK(scope IN ('everywhere','cloud')),
            by_who TEXT NOT NULL CHECK(by_who IN ('person','ai')), mac TEXT NOT NULL,
            session TEXT, agent TEXT, at INTEGER NOT NULL, group_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS \(prefix)cloud_delete_marks(
            place TEXT PRIMARY KEY, mark TEXT NOT NULL CHECK(mark IN ('not-on-this-mac','only-on-this-mac')),
            at INTEGER NOT NULL);
        """)
    }
    func putIntent(_ intent: CloudDeleteIntent) throws {
        guard UUID(uuidString: intent.group) != nil else { throw CloudDeleteRuleError.invalidState }
        try run("INSERT OR REPLACE INTO \(prefix)cloud_delete_intents(place,scope,by_who,mac,session,agent,at,group_id) VALUES (?,?,?,?,?,?,?,?)",
                [.text(intent.place), .text(intent.scope.rawValue), .text(intent.by.rawValue), .text(intent.mac),
                 .optional(intent.session), .optional(intent.agent), .int(intent.at), .text(intent.group)])
    }
    func intent(at place: String) throws -> CloudDeleteIntent? {
        guard let row = try rows("SELECT place,scope,by_who,mac,session,agent,at,group_id FROM \(prefix)cloud_delete_intents WHERE place=?", [.text(place)]).first else { return nil }
        guard let scope = CloudDeleteScope(rawValue: row.text(1)), let by = CloudDeleteBy(rawValue: row.text(2)),
              UUID(uuidString: row.text(7)) != nil else { throw CloudDeleteRuleError.invalidState }
        return .init(place: row.text(0), scope: scope, by: by, mac: row.text(3), session: row.string(4),
                     agent: row.string(5), at: row.int(6), group: row.text(7))
    }
    /// Clear only AFTER the removal was journaled (or the explicit action was cancelled); reads never consume it.
    func clearIntent(at place: String) throws {
        try run("DELETE FROM \(prefix)cloud_delete_intents WHERE place=?", [.text(place)])
    }
    func putMark(_ mark: CloudDeleteMark) throws {
        try run("INSERT OR REPLACE INTO \(prefix)cloud_delete_marks(place,mark,at) VALUES (?,?,?)",
                [.text(mark.place), .text(mark.mark.rawValue), .int(mark.at)])
    }
    func mark(at place: String) throws -> CloudDeleteMark? {
        try marks(where: " WHERE place=?", args: [.text(place)]).first
    }
    func marks() throws -> [CloudDeleteMark] { try marks(where: " ORDER BY at,place", args: []) }
    func clearMark(at place: String) throws {
        try run("DELETE FROM \(prefix)cloud_delete_marks WHERE place=?", [.text(place)])
    }
    private func marks(where suffix: String, args: [DeckMemorySQL]) throws -> [CloudDeleteMark] {
        try rows("SELECT place,mark,at FROM \(prefix)cloud_delete_marks" + suffix, args).map { row in
            guard let mark = CloudLocalMark(rawValue: row.text(1)) else { throw CloudDeleteRuleError.invalidState }
            return .init(place: row.text(0), mark: mark, at: row.int(2))
        }
    }
    private func exec(_ sql: String) throws {
        switch database {
        case .memory(let db): try db.exec(sql)
        case .files(let db): try db.exec(sql)
        }
    }
    private func run(_ sql: String, _ args: [DeckMemorySQL]) throws {
        switch database {
        case .memory(let db): _ = try db.run(sql, args)
        case .files(let db): _ = try db.run(sql, args)
        }
    }
    private func rows(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> [DeckMemoryRow] {
        switch database {
        case .memory(let db): try db.rows(sql, args)
        case .files(let db): try db.rows(sql, args)
        }
    }
}

public enum CloudDeleteWitnessAnswer: Sendable, Equatable {
    /// Names, captured at command time. L7 resolves the existing witness's session id before returning it here.
    /// `command` is the command's start time, NOT its text. One command uses the same group for every target.
    case ai(session: String, agent: String?, command: Date, group: String)
    case notAI
    case cannotKnow

    public var by: CloudDeleteBy {
        if case .ai = self { return .ai }
        return .person
    }
}

public protocol CloudDeleteWitness: Sendable {
    func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer
}

public struct CloudDeleteUnknownWitness: CloudDeleteWitness {
    public init() {}
    public func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer { .cannotKnow }
}

/// L7 installs its adapter ONCE during composition, before engines start. Until then a gone file is by hand.
public final class CloudDeleteWitnessSlot: @unchecked Sendable {
    public static let shared = CloudDeleteWitnessSlot()
    private let lock = NSLock()
    private var witness: (any CloudDeleteWitness)?
    public init() {}
    @discardableResult public func installOnce(_ witness: any CloudDeleteWitness) -> Bool {
        lock.withLock {
            guard self.witness == nil else { return false }
            self.witness = witness
            return true
        }
    }
    public func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
        guard path.isFileURL, lastSeen <= seenGoneAt else { return .cannotKnow }
        let current = lock.withLock { witness ?? CloudDeleteUnknownWitness() }
        return await current.who(removed: path, lastSeen: lastSeen, seenGoneAt: seenGoneAt)
    }
}

public enum CloudDeleteGate {
    public static let feature = "deleterule"
    public static let format = 1
    public static let freshFor: Int64 = 3 * 24 * 60 * 60 * 1000
    public static let renewAfter: Int64 = 12 * 60 * 60 * 1000
    public static let none = "none"
    public static func key(device: String) -> String { "onerule.understands.deleterule." + device.lowercased() }
    public static func value(at: Int64) -> String { "v1:" + String(at) }

    /// `computers` comes from oneRuleAccountMacs; nil/empty or an unknown service clock fails closed.
    /// `announcements` is keyed by the FULL setting key. J-1: `none` is an explicit opt-out, never waited for.
    public static func isOpen(computers: [String]?, announcements: [String: String], now: Int64?) -> Bool {
        guard let computers, !computers.isEmpty, let now, now > 0 else { return false }
        return computers.allSatisfy { device in
            guard !device.isEmpty, let raw = announcements[key(device: device)] else { return false }
            if raw == none { return true }
            guard raw.hasPrefix("v1:"), let at = Int64(raw.dropFirst(3)), at > 0, at <= now else { return false }
            return now - at <= freshFor
        }
    }
}

extension DeckMemoryStore {
    /// The delete-rule gate, including J-1's `none` opt-out. Other feature gates keep their existing semantics.
    public func cloudDeleteRuleIsOpen() -> Bool {
        guard cloudMemoryEnabled, let macs = cloudAccountMacs, let me = cloudDeviceId,
              macs.contains(me.lowercased()) else { return false }
        var announcements: [String: String] = [:]
        for device in macs {
            let key = CloudDeleteGate.key(device: device)
            if let raw = try? setting(key, owner: nil) { announcements[key] = raw }
        }
        return CloudDeleteGate.isOpen(computers: Array(macs), announcements: announcements,
                                      now: DeckMemoryCloudClocks.shared.now(for: self))
    }
}

/// Shared page/tool input. `id` and `place` are routing values; pages show ONLY name and dates.
public struct CloudDeleteItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String
    public let place: String?
    public init(id: String, kind: String, name: String, place: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.place = place
    }
}

/// One call's attribution. The caller creates ONE UUID group and reuses this value across all kind owners involved.
public struct CloudDeleteActor: Codable, Sendable, Equatable {
    public let by: CloudDeleteBy
    public let mac: String
    public let macName: String
    public let session: String?
    public let agent: String?
    public let at: Int64
    public let group: String
    public init(by: CloudDeleteBy, mac: String, macName: String, session: String? = nil, agent: String? = nil, at: Int64, group: String) {
        self.by = by; self.mac = mac; self.macName = macName; self.session = session; self.agent = agent
        self.at = at; self.group = group
    }
    public func intent(place: String, scope: CloudDeleteScope) -> CloudDeleteIntent {
        .init(place: place, scope: scope, by: by, mac: mac, session: session, agent: agent, at: at, group: group)
    }
}

public enum CloudBringBackDestination: String, Codable, Sendable {
    case thisMac = "this-mac"
    case cloud
}

public struct CloudNotHereItem: Sendable, Equatable {
    public let item: CloudDeleteItem
    public let mark: CloudLocalMark
    public let at: Int64
    public init(item: CloudDeleteItem, mark: CloudLocalMark, at: Int64) {
        self.item = item; self.mark = mark; self.at = at
    }
}

public enum CloudBinEra: String, Codable, Sendable {
    case current, olderVersion, beforeNewRule
}

public struct CloudBinGroup: Codable, Sendable, Equatable, Identifiable {
    public static let retentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1000
    /// Routing only, never a page label. For current removals this is the intent's UUID group.
    public let id: String
    public let by: CloudDeleteBy
    public let macName: String
    public let session: String?
    public let agent: String?
    public let at: Int64
    public let items: [CloudDeleteItem]
    public let era: CloudBinEra
    public var count: Int { items.count }
    public var title: String {
        switch era {
        case .beforeNewRule: CloudDeleteWords.beforeNewRule
        case .olderVersion: CloudDeleteWords.removedOlderVersion(on: macName)
        case .current: by == .ai ? CloudDeleteWords.removedByAI(on: macName) : CloudDeleteWords.removed(on: macName)
        }
    }
    public init(id: String, by: CloudDeleteBy, macName: String, session: String? = nil, agent: String? = nil,
                at: Int64, items: [CloudDeleteItem], era: CloudBinEra = .current) {
        self.id = id; self.by = by; self.macName = macName; self.session = session; self.agent = agent
        self.at = at; self.items = items; self.era = era
    }
}

/// Every kind's owner adopts this contract. Tasks/agents force Everywhere. Cloud scope requires the gate.
/// Store the intent and keeper bytes BEFORE removal. Bin retention is 30 days, including AI removals.
/// binGroups/putBackGroup/deleteForGood belong to the person's UI ONLY; never expose them to an AI tool.
public protocol CloudDeleteOwning: Sendable {
    func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by: CloudDeleteActor) async throws -> CloudBinGroup
    func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem]
    func notHere() async throws -> [CloudNotHereItem]
    func binGroups() async throws -> [CloudBinGroup]
    func putBackGroup(_ group: String) async throws -> [CloudDeleteItem]
    func deleteForGood(_ items: [CloudDeleteItem]) async throws
    /// Whether a delete can be honoured right now (the secret kinds: false while an older Mac exists, saved passwords
    /// are locked, or there is no sealed Bin). Pages hide both delete buttons when false. Default: yes.
    func canDeleteEverywhere() async -> Bool
}

public extension CloudDeleteOwning {
    func canDeleteEverywhere() async -> Bool { true }
}

public enum CloudDeleteWords {
    public static let notOnThisMac = "Not on this Mac"
    public static let bringBack = "Bring back"
    public static let bringAllBack = "Bring all back"
    public static let onlyOnThisMac = "Only on this Mac"
    public static let putInCloudAgain = "Put in Cloud again"
    public static func removedByAI(on mac: String) -> String { "Removed by an AI on " + mac }
    public static func removed(on mac: String) -> String { "Removed on " + mac }
    public static func removedOlderVersion(on mac: String) -> String { removed(on: mac) + " (older version)" }
    public static let beforeNewRule = "Before the new rule"
    public static let putBackAll = "Put back all"
    public static let cloud = "Cloud"
    public static let everywhere = "Everywhere"
    public static let cloudNeedsUpdatedMacs = "Cloud only works once your other devices are updated"
}
