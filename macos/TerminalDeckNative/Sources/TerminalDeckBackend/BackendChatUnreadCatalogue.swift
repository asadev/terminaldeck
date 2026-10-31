import Foundation
import TerminalDeckNativeCore

/// 28 Oct (Asad, ~09:45: "Mac app is not responding for all terminals, it's super slow"; the app and the session
/// helper each at ~100% CPU for hours). The side panel's team-chat list re-read EVERY team chat on every session
/// status change (several per turn of every working session) to show its unread count, and for a finished chat the
/// helper answers by loading that chat's whole history from disk (it keeps only 8 in memory; there were ~156). The
/// helper never caught up, so every kept terminal's typing and output queued behind it.
///
/// Now the unread a chat last reported (on a read, or with any change it publishes) is remembered: the list reads a
/// chat only when nothing is known since it last changed. A finished chat never changes, so it is read once.
public struct BackendChatUnreadCache: Sendable {
    public struct Entry: Sendable, Equatable {
        public let unread: NativeRPCValue
        public let conversationID: NativeRPCValue
        public init(unread: NativeRPCValue, conversationID: NativeRPCValue) { self.unread = unread; self.conversationID = conversationID }
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public func entry(_ id: String) -> Entry? { entries[id] }
    /// A read answer is the chat as it is now.
    public mutating func noteRead(_ id: String, _ snapshot: NativeRPCValue) {
        entries[id] = .init(unread: snapshot["unread"], conversationID: snapshot["conversationId"])
    }
    /// A published change: its unread when it carries one; otherwise the chat is read once more when the list asks.
    public mutating func noteChange(_ id: String, _ snapshot: NativeRPCValue) {
        if snapshot["unread"] == .missing { entries[id] = nil } else { noteRead(id, snapshot) }
    }
    public mutating func forget(_ id: String) { entries[id] = nil }
    public var count: Int { entries.count }
}

extension BackendSessionChats {
    public func unreadConversations(project: String? = nil, agent: String? = nil, state: String? = nil) async throws -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        for row in conversations(project: project, agent: agent, state: state) {
            let entry = try await unreadEntry(row.session.id)
            result.append(row.wire.setting("unread", entry.unread).setting("conversationId", entry.conversationID))
        }
        return result
    }
}
