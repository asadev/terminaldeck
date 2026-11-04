import Foundation

/// Older clients still decode these fields. They describe no unread state, write no markers,
/// and never choose a scroll target. Keeping the empty wire shape lets those clients upgrade safely.
public enum ChatReadCompatibility {
    public static func empty(sequence: Int) -> NativeRPCValue {
        .object([.init("seenSequence", .number(Double(sequence))), .init("count", .number(0)),
                 .init("firstSequence", .null), .init("firstMessageId", .null)])
    }
}

public enum RoutineChatSnapshot {
    public static func sequence(_ entry: NativeRPCValue, at index: Int) -> Int {
        entry["sequence"].number.map { Int($0) } ?? index + 1
    }
    public static func snapshot(_ entries: [NativeRPCValue], routineID: String, limit: Int = .max) -> NativeRPCValue {
        .object([.init("conversationId", .string("routine:" + routineID)),
            .init("entries", .array(entries.enumerated().suffix(limit).map { $0.element.setting("sequence", .number(Double(sequence($0.element, at: $0.offset)))) })),
            .init("unread", ChatReadCompatibility.empty(sequence: entries.indices.last.map { sequence(entries[$0], at: $0) } ?? 0))])
    }
}
