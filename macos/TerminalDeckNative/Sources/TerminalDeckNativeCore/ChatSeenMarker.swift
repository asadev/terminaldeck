import Foundation

/// A durable high-water mark, scoped to the app-owned conversation, shared by every window.
public final class ChatSeenMarkers: @unchecked Sendable {
    private static let lock = NSLock()
    private let file: URL
    public init(file: URL) { self.file = file }
    private func load() throws -> [String: Int] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
    }
    public func sequence(for conversation: String) throws -> Int {
        try Self.lock.withLock { try load()[conversation] ?? 0 }
    }
    @discardableResult public func advance(_ sequence: Int, conversation: String) throws -> Int {
        try Self.lock.withLock {
            var markers = try load()
            let next = max(markers[conversation] ?? 0, sequence)
            markers[conversation] = next
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(markers).write(to: file, options: .atomic)
            return next
        }
    }
}

public struct ChatUnreadMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let sequence: Int
    public init(id: String, sequence: Int) { self.id = id; self.sequence = sequence }
}

public enum ChatUnreadMessages {
    /// Only words addressed to the person count. Own messages and hidden tool/background events do not.
    public static func messages(_ events: [HootChatEvent], showBackground: Bool = false) -> [ChatUnreadMessage] {
        let visible = showBackground ? events.map { event -> HootChatEvent in
            let turn = event.turnID.hasPrefix("bg:") ? "task:" + event.turnID.dropFirst(3) : event.turnID
            let record = event.record.value["background"]["brief"].string.map { HootChatRecord.text(.user, id: event.record.messageID, $0) } ?? event.record
            return .init(conversationID: event.conversationID, turnID: turn, sequence: event.sequence, provider: event.provider, record: record, at: event.at)
        } : events
        let rows = HootChatProjection.rows(HootChatProjection.snapshotEvents(visible)).filter {
            [.message, .textDelta, .error, .interrupted].contains($0.kind) && !$0.id.hasPrefix("bg:")
        }
        var result: [ChatUnreadMessage] = [], routes: [String: Int] = [:]
        for row in rows {
            if let route = row.value["routing"]["id"].string {
                if let index = routes[route] {
                    result[index] = .init(id: result[index].id, sequence: row.sequence)
                    continue
                }
                routes[route] = result.count
            }
            result.append(.init(id: row.id, sequence: row.sequence))
        }
        return result
    }
    public static func summary(_ events: [HootChatEvent], seen: Int, showBackground: Bool = false) -> NativeRPCValue {
        let unread = messages(events, showBackground: showBackground).filter { $0.sequence > seen }
        return .object([.init("seenSequence", .number(Double(seen))), .init("count", .number(Double(unread.count))),
            .init("firstSequence", unread.first.map { .number(Double($0.sequence)) } ?? .null),
            .init("firstMessageId", unread.first.map { .string($0.id) } ?? .null)])
    }
}

/// Time only accumulates during one uninterrupted, active, on-screen visit.
public struct ChatUnreadVisit: Equatable, Sendable {
    public private(set) var visibleSince: Double?
    public init() {}
    public mutating func update(active: Bool, visible: Bool, now: Double) {
        if !active || !visible { visibleSince = nil }
        else if visibleSince == nil { visibleSince = now }
    }
    public func ready(now: Double, delay: Double = 3) -> Bool {
        visibleSince.map { now - $0 >= delay } ?? false
    }
}
