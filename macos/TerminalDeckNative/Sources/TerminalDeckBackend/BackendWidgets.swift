import Foundation
import TerminalDeckNativeCore

/// Both the read tool and paired-phone stream ask the same state reader. The reader applies the caller's reach.
public actor BackendWidgets {
    public typealias Reader = @Sendable (_ deviceID: String?, _ project: String?) async -> DeckWidgetSnapshot
    private let read: Reader
    private let send: @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void
    private var watchers: [UUID: String] = [:]
    /// What each phone was last sent, and when (post-24: a frame went to every phone on every status change).
    private var sent: [UUID: (snapshot: DeckWidgetSnapshot, at: Double, metricsAt: Double)] = [:]
    private let clock: @Sendable () -> Double
    /// CPU and memory move all the time; they are sent at most this often (seconds).
    public static let metricsInterval: TimeInterval = 15
    /// Nothing shown changed: still sent this often, so the phone's "updated … ago" stays true.
    public static let unchangedInterval: TimeInterval = 60
    public init(read: @escaping Reader, send: @escaping @Sendable (UUID, BackendRemoteServerMessage) async throws -> Void,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.read = read; self.send = send; self.clock = clock
    }
    public func snapshot(deviceID: String? = nil, project: String? = nil) async -> DeckWidgetSnapshot { await read(deviceID, project) }
    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "widgets", messageTypes: ["widgets.read"], policy: .grantedDevice) { [weak self] message, context in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "Widgets are unavailable.") }
            return try await self.handle(message, context: context)
        }
    }
    func handle(_ message: BackendRemoteClientMessage, context: BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage] {
        watchers[context.connectionID] = context.deviceID
        let snapshot = await read(context.deviceID, nil), now = clock()
        sent[context.connectionID] = (snapshot, now, now)
        return [try Self.frame(snapshot, rid: message["rid"].string)]
    }
    public func changed() async {
        // Several phones of one device share one read; the reader shares its inputs across devices (one refresh).
        var byDevice: [String: DeckWidgetSnapshot] = [:]
        for (connection, device) in watchers {
            let snapshot: DeckWidgetSnapshot
            if let known = byDevice[device] { snapshot = known } else { snapshot = await read(device, nil); byDevice[device] = snapshot }
            let now = clock(), last = sent[connection]
            let decision = Self.sendDecision(previous: last?.snapshot, sentAt: last?.at, metricsAt: last?.metricsAt, next: snapshot, now: now)
            guard decision != .skip else { continue }
            do {
                try await send(connection, Self.frame(snapshot))
                sent[connection] = (snapshot, now, decision == .withMetrics ? now : (last?.metricsAt ?? now))
            } catch { watchers[connection] = nil; sent[connection] = nil }
        }
    }
    public func disconnected(_ connection: UUID) { watchers[connection] = nil; sent[connection] = nil }
    public func stop() { watchers.removeAll(); sent.removeAll() }

    public enum SendDecision: Equatable { case skip, shown, withMetrics }
    /// Whether a phone gets this snapshot: at once when something it shows changed (needs you, tasks, weekly limit,
    /// connection, the machine); CPU or memory alone at most every 15 s; nothing changed, once a minute.
    public static func sendDecision(previous: DeckWidgetSnapshot?, sentAt: Double?, metricsAt: Double?, next: DeckWidgetSnapshot, now: Double) -> SendDecision {
        guard let previous, let sentAt else { return .withMetrics }
        func shown(_ s: DeckWidgetSnapshot) -> DeckWidgetSnapshot {
            var s = s; s.updatedAt = 0; s.cpuPercent = nil; s.memoryPercent = nil; return s
        }
        let metricsDue = now - (metricsAt ?? sentAt) >= metricsInterval
        if shown(previous) != shown(next) { return metricsDue ? .withMetrics : .shown }
        let metricsMoved = previous.cpuPercent != next.cpuPercent || previous.memoryPercent != next.memoryPercent
        if metricsMoved && metricsDue { return .withMetrics }
        if now - sentAt >= unchangedInterval { return .withMetrics }
        return .skip
    }
    public static func wire(_ snapshot: DeckWidgetSnapshot) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(JSONEncoder().encode(snapshot))
    }
    static func frame(_ snapshot: DeckWidgetSnapshot, rid: String? = nil) throws -> BackendRemoteServerMessage {
        var fields: [NativeRPCValue.Field] = [.init("snapshot", try wire(snapshot))]
        if let rid { fields.append(.init("rid", .string(rid))) }
        return try .init(.widgetsSnapshot, fields: fields)
    }
    public static func definitions(reader: @escaping Reader, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "widgets.snapshot", wireName: "widgets_snapshot",
            description: "Read the same snapshot as the home-screen widgets: Needs you, CPU and memory, weekly limit left and tasks due. Missing values are not reported. Widgets open sessions through the existing session tools.",
            inputSchema: NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8)), tier: .read)
        return [.init(spec: spec, title: "Read widgets", index: "Home-screen widget snapshot and freshness.", audience: "hoot") { context, args in
            guard context.allowedTiers.contains(.read), !context.cancellation.isCancelled else { throw CancellationError() }
            try await access.authorize(context, "widgets.snapshot", args, .read, "Read widgets", false)
            let rpc = try await access.rpc(context)
            let snapshot = await reader(rpc.caller == .pairedDevice ? rpc.ownerID : nil, context.projectRoot)
            try await access.record(context, "widgets.snapshot", args, .object([.init("updatedAt", .number(snapshot.updatedAt))]))
            return .value(try wire(snapshot))
        }]
    }
    /// A task is due by the end of today. Completed, archived and deleted rows never count.
    public static func dueTasks(_ tasks: [NativeRPCValue], at date: Date) -> [NativeRPCValue] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: date)
        return tasks.filter {
            guard $0["local"].bool == true, let due = $0["dueDate"].string, due.count == 10, let parsed = formatter.date(from: due), formatter.string(from: parsed) == due, due <= today,
                  $0["deletedAt"].isNullish, $0["archivedAt"].isNullish, $0["completedAt"].isNullish else { return false }
            return !["done", "cancelled", "canceled"].contains(($0["crmStatus"].string ?? "").lowercased())
        }.sorted { ($0["dueDate"].string ?? "", $0["id"].string ?? "") < ($1["dueDate"].string ?? "", $1["id"].string ?? "") }
    }
    public static func weeklyRemaining(_ report: BackendUsageReport?, at date: Date) -> Double? {
        guard let row = report?.readings.first(where: { $0.window == .weekly }),
              row.freshness(now: date.timeIntervalSince1970 * 1000).drawable,
              case .reported(let fraction) = row.used else { return nil }
        return max(0, min(100, (1 - fraction) * 100))
    }
}
extension BackendRemoteProtocol {
    static func parseWidgets(_ reader: BackendRemoteReader) throws -> NativeRPCValue? {
        guard reader.type == "widgets.read" else { return nil }
        var message = reader.base
        if let rid = reader["rid"].string { message = message.setting("rid", .string(String(rid.prefix(120)))) }
        return message
    }
}
