import Foundation

/// Shared, deliberately small, read-only state for all home-screen widgets. Dates are Unix milliseconds.
public struct DeckWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var agent: String
        public var seat: String?
        public init(id: String, name: String, agent: String, seat: String? = nil) {
            self.id = id; self.name = name; self.agent = agent; self.seat = seat
        }
    }
    public struct TaskItem: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var projectPath: String?
        public init(id: String, title: String, projectPath: String? = nil) { self.id = id; self.title = title; self.projectPath = projectPath }
    }
    public var v: Int
    public var updatedAt: Double
    public var connected: Bool
    public var machineId: String?
    public var machineName: String?
    public var needsYouCount: Int?
    public var needsYou: [Session]
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var weeklyLimitRemainingPercent: Double?
    public var usageSessionId: String?
    public var tasksDueCount: Int?
    public var nextTask: TaskItem?
    public init(v: Int = 1, updatedAt: Double = 0, connected: Bool = false, machineId: String? = nil,
                machineName: String? = nil, needsYouCount: Int? = nil, needsYou: [Session] = [],
                cpuPercent: Double? = nil, memoryPercent: Double? = nil, weeklyLimitRemainingPercent: Double? = nil,
                tasksDueCount: Int? = nil, nextTask: TaskItem? = nil, usageSessionId: String? = nil) {
        self.v = v; self.updatedAt = updatedAt; self.connected = connected; self.machineId = machineId; self.machineName = machineName
        self.needsYouCount = needsYouCount; self.needsYou = Array(needsYou.prefix(3)); self.cpuPercent = Self.percent(cpuPercent)
        self.memoryPercent = Self.percent(memoryPercent); self.weeklyLimitRemainingPercent = Self.percent(weeklyLimitRemainingPercent)
        self.tasksDueCount = tasksDueCount; self.nextTask = nextTask; self.usageSessionId = usageSessionId
    }
    public static let empty = DeckWidgetSnapshot()
    public static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }; return value
    }
    public func isStale(at date: Date = Date()) -> Bool {
        !connected || updatedAt <= 0 || date.timeIntervalSince1970 * 1000 - updatedAt >= 15 * 60 * 1000
    }
    public var asOf: Date? { updatedAt > 0 ? Date(timeIntervalSince1970: updatedAt / 1000) : nil }
    /// How old the reading is at `date`: "just now", "1 min ago" (item 72: the footer ages between writes, so the
    /// widget never looks frozen and never claims to be newer than it is). Nil with no reading.
    public func age(at date: Date) -> String? {
        guard let asOf else { return nil }
        let minutes = Int(max(0, date.timeIntervalSince(asOf)) / 60)
        return minutes < 1 ? "just now" : "\(minutes) min ago"
    }
    /// The timeline's moments: now, every whole minute of the reading's age until it goes stale, and the moment it
    /// does (item 72). At most 16 entries; WidgetKit draws each at its time with no reload.
    public func timelineDates(from now: Date) -> [Date] {
        var dates = [now]
        guard let asOf else { return dates }
        let staleAt = asOf.addingTimeInterval(15 * 60)
        if connected {
            var next = asOf.addingTimeInterval(60)
            while next < staleAt { if next > now { dates.append(next) }; next.addTimeInterval(60) }
        }
        if staleAt > now { dates.append(staleAt) }
        return dates
    }
    public func url(session: String? = nil, content: String = "needsYou") -> URL {
        var parts = URLComponents()
        parts.scheme = Bundle.main.object(forInfoDictionaryKey: "TDWidgetURLScheme") as? String ?? "terminaldeck"; parts.host = session == nil ? "widget" : "session"
        var pathAllowed = CharacterSet.urlPathAllowed
        pathAllowed.remove(charactersIn: "/?#%")
        parts.percentEncodedPath = "/" + ((session ?? content).addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? "needsYou")
        if let machineId { parts.queryItems = [URLQueryItem(name: "host", value: machineId)] }
        if content == "week", session == nil, let usageSessionId {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "session", value: usageSessionId)]
        }
        return parts.url ?? URL(string: "terminaldeck://widget/needsYou")!
    }
    public static func decode(_ data: Data) throws -> DeckWidgetSnapshot {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.v == 1, value.updatedAt.isFinite, value.updatedAt >= 0, value.needsYou.count <= 3,
              value.needsYouCount.map({ $0 >= value.needsYou.count }) ?? value.needsYou.isEmpty,
              value.tasksDueCount.map({ $0 >= 0 }) ?? true,
              [value.cpuPercent, value.memoryPercent, value.weeklyLimitRemainingPercent].allSatisfy({ $0 == nil || percent($0) != nil }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }
}

extension DeckWidgetSnapshot {
    /// What a person acts on. CPU and memory are left out: they change all the time and wait for the idle refresh.
    public var contentKey: String {
        let weekly = weeklyLimitRemainingPercent.map { String(Int($0.rounded())) } ?? "-"
        return [String(connected), machineId ?? "-", machineName ?? "-", needsYouCount.map(String.init) ?? "-",
                needsYou.map(\.id).joined(separator: ","), tasksDueCount.map(String.init) ?? "-", nextTask?.id ?? "-",
                weekly].joined(separator: "|")
    }
}

/// When to ask WidgetKit to redraw. A change in who needs you, tasks, the weekly limit or the connection redraws
/// at once (at most once a minute; a change inside that minute redraws when it ends). CPU/memory-only changes keep
/// WidgetKit's 15-minute budget.
public struct DeckWidgetReloadGate: Sendable {
    public static let contentInterval: TimeInterval = 60
    public static let loadInterval: TimeInterval = 15 * 60
    public private(set) var lastReload: Date?
    private var shownContent: String?
    public init() {}
    /// nil: no redraw. 0: redraw now (already recorded). Otherwise: redraw once after this many seconds, then call `reloaded`.
    public mutating func decide(_ snapshot: DeckWidgetSnapshot, now: Date = Date(), force: Bool = false) -> TimeInterval? {
        let content = snapshot.contentKey
        let changed = content != shownContent
        let since = lastReload.map { now.timeIntervalSince($0) } ?? .infinity
        if force || since >= Self.loadInterval || (changed && since >= Self.contentInterval) {
            lastReload = now; shownContent = content; return 0
        }
        return changed ? Self.contentInterval - since : nil
    }
    public mutating func reloaded(_ snapshot: DeckWidgetSnapshot, now: Date = Date()) {
        lastReload = now; shownContent = snapshot.contentKey
    }
}

public enum DeckWidgetStore {
    /// iPhone App Group (needs its provisioning profile).
    public static let appGroup = "group.dev.terminaldeck.widgets"
    /// Mac App Group: team-prefixed, so the Developer ID app and its widget need no provisioning profile.
    public static let macAppGroup = "6U4VNX5W87.dev.terminaldeck.widgets"
    #if os(macOS)
    static let defaultGroup = macAppGroup
    #else
    static let defaultGroup = appGroup
    #endif
    public static let fileName = "widget-snapshot-v1.json"
    public static func fileURL() -> URL? {
        // A separately signed scratch app supplies a distinct group; it must never publish into the installed app's group.
        let group = Bundle.main.object(forInfoDictionaryKey: "TDWidgetAppGroup") as? String ?? defaultGroup
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent(fileName)
    }
    public static func read(url: URL? = nil) -> DeckWidgetSnapshot {
        guard let file = url ?? fileURL(), let data = try? Data(contentsOf: file), let value = try? DeckWidgetSnapshot.decode(data) else { return .empty }
        return value
    }
    public static func write(_ value: DeckWidgetSnapshot, url: URL? = nil) throws {
        guard let file = url ?? fileURL() else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(value)
        _ = try DeckWidgetSnapshot.decode(data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path)
    }
}
