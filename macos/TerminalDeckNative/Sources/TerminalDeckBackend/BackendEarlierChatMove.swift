import Foundation
import TerminalDeckNativeCore

/// A fork uses its live source's owner; ordinary New Chat choices keep their existing routing.
/// Only backend code sets this scope, and the chat owner still verifies that it owns the named source.
public enum BackendChatForkLaunchScope {
    @TaskLocal public static var sourceID: String?
}

/// The transfer is gated by the source's current receipt; saved words never stand in for AI message IDs.
public enum BackendEarlierChatMove {
    public static func requireIdle(_ snapshot: NativeRPCValue) throws {
        guard snapshot["busy"].bool != true, snapshot["foreground"].bool != true,
              snapshot["pending"].elements?.isEmpty != false,
              snapshot["queuedMessages"].elements?.isEmpty != false,
              (snapshot["queuedCount"].number ?? 0) == 0,
              !(snapshot["children"].elements ?? []).contains(where: ChatChildTasks.running) else {
            throw NativeRPCError(code: "busy", message: "Wait for this AI and its background work to finish before moving its conversation.")
        }
    }
    public static func requireUnchanged(_ before: NativeRPCValue, _ after: NativeRPCValue) throws {
        try requireIdle(after)
        guard before["sequence"] == after["sequence"], before["conversationId"] == after["conversationId"],
              before["providerConversationId"] == after["providerConversationId"] else {
            throw NativeRPCError(code: "conflict", message: "This conversation changed while its history was being checked. Nothing moved.")
        }
    }
    private static func canMove(_ snapshot: NativeRPCValue) -> Bool {
        snapshot["historyAccountConfirmed"].bool != false && snapshot["readOnly"].bool != true && snapshot["job"].fields == nil
            && snapshot["provider"].string != "gemini"
            && snapshot["providerConversationId"].string?.isEmpty == false
            && (try? requireIdle(snapshot)) != nil
    }
    /// Fork here copies carried history, so its offers must be judged on the whole journal, not on one page of it.
    public static func offersCarriedHistory(_ snapshot: NativeRPCValue) -> Bool {
        snapshot["messageActions"].elements == nil && ["claude", "codex", "gemini"].contains(snapshot["provider"].string ?? "")
            && snapshot["historyAccountConfirmed"].bool != false && !canMove(snapshot)
    }
    /// `journalRows`: the carried-history rows of the whole journal (`BackendChatMessageActions.historyRows`); nil reads the page's events.
    public static func offeringActions(_ snapshot: NativeRPCValue, journalRows: [NativeRPCValue]? = nil) -> NativeRPCValue {
        guard snapshot["messageActions"].elements == nil,
              ["claude", "codex", "gemini"].contains(snapshot["provider"].string ?? "") else { return snapshot }
        let accountKnown = snapshot["historyAccountConfirmed"].bool != false
        let canMove = Self.canMove(snapshot)
        let carried = journalRows ?? BackendChatMessageActions.historyRows((snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) })
        let claude = snapshot["provider"].string == "claude"
        let rows = (snapshot["events"].elements ?? []).compactMap { row -> NativeRPCValue? in
            guard let event = try? HootChatEvent(wire: row), [.user, .message].contains(event.record.kind) else { return nil }
            return .object([.init("sequence", .number(Double(event.sequence))),
                .init("rowId", .string(event.turnID + ":" + (event.record.messageID.isEmpty ? event.id : event.record.messageID))),
                .init("rewind", .bool(canMove && event.record.kind == .user)), .init("fork", .bool(accountKnown && (canMove ? (claude || event.record.kind == .message) : carried.contains { $0["sequence"].number == Double(event.sequence) && $0["fork"].bool == true })))])
        }
        return snapshot.setting("messageActions", .array(rows)).setting("earlierEngine", .bool(true))
    }
    static func codexTurns(_ events: [HootChatEvent], thread: NativeRPCValue, conversation: String, cwd: String) throws -> [String: String] {
        guard thread["id"].string == conversation, thread["cwd"].string == cwd, let turns = thread["turns"].elements else {
            throw NativeRPCError(code: "unavailable", message: "Codex could not confirm this saved conversation and its message boundaries. Nothing moved.")
        }
        var items: [String: String] = [:], result: [String: String] = [:]
        let known = Set(turns.compactMap { $0["id"].string })
        for turn in turns {
            guard let id = turn["id"].string else { continue }
            for item in turn["items"].elements ?? [] { if let message = item["id"].string { items[message] = id } }
        }
        for event in events {
            if let id = items[event.record.messageID] { result[event.turnID] = id }
            if event.record.kind == .completed, let id = event.record.value["id"].string, known.contains(id) { result[event.turnID] = id }
        }
        return result
    }
}
