import Foundation

/// Reports append in file order. Questions are the person's own words and never unread.
/// An entry's number is its own `sequence` once saved (older files: its place in the file).
public enum RoutineChatUnread {
    public static func sequence(_ entry: NativeRPCValue, at index: Int) -> Int { entry["sequence"].number.map { Int($0) } ?? index + 1 }
    public static func messages(_ entries: [NativeRPCValue]) -> [ChatUnreadMessage] {
        messages(entries, id: { $0["id"].string }, kind: { $0["kind"].string }, sequence: { $0["sequence"].number.map { Int($0) } ?? 0 })
    }
    public static func messages<Entry>(_ entries: [Entry], id: (Entry) -> String?, kind: (Entry) -> String?, sequence: (Entry) -> Int) -> [ChatUnreadMessage] {
        entries.enumerated().compactMap { index, entry in
            guard kind(entry) != "question", let id = id(entry) else { return nil }
            let number = sequence(entry)
            return .init(id: id, sequence: number > 0 ? number : index + 1)
        }
    }
    /// `limit` sends only the newest entries; the unread count still covers them all.
    public static func snapshot(_ entries: [NativeRPCValue], routineID: String, seen: Int, limit: Int = .max) -> NativeRPCValue {
        let pending = messages(entries).filter { $0.sequence > seen }
        return .object([.init("conversationId", .string("routine:" + routineID)),
            .init("entries", .array(entries.enumerated().suffix(limit).map { $0.element.setting("sequence", .number(Double(sequence($0.element, at: $0.offset)))) })),
            .init("unread", .object([.init("seenSequence", .number(Double(seen))), .init("count", .number(Double(pending.count))),
                .init("firstSequence", pending.first.map { .number(Double($0.sequence)) } ?? .null),
                .init("firstMessageId", pending.first.map { .string($0.id) } ?? .null)]))])
    }
}
