import Foundation
import TerminalDeckNativeCore

/// Message boundaries come from provider receipts, never from a guessed text match.
public enum BackendChatMessageActions {
    public static func historyRows(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        var count = 0, bytes = 0, whole = events.first?.sequence == 1
        return HootChatProjection.snapshotEvents(events).compactMap { event in
            guard [.user, .message].contains(event.record.kind) else { return nil }
            let text = event.record.value["text"].string ?? ""
            count += 1; bytes += text.utf8.count
            whole = whole && text.count <= BackendHootDesk.messageCap
            return .object([.init("sequence", .number(Double(event.sequence))), .init("rewind", .bool(false)),
                .init("fork", .bool(whole && count <= BackendHootHandover.maximumMessages && bytes <= 40_000))])
        }
    }
    public static func rows(_ events: [HootChatEvent], provider: HootChatProvider) -> [NativeRPCValue] {
        var messages: [HootChatEvent] = []
        var firstUsers: [String: Int] = [:], completed: [String: String] = [:], answers: [String: Int] = [:]
        for event in HootChatProjection.snapshotEvents(events) where event.provider == provider {
            if event.record.kind == .completed { completed[event.turnID] = event.record.value["id"].string }
            if event.record.kind == .message, !event.record.messageID.isEmpty, event.record.value["fileRestore"].bool != true { answers[event.turnID] = event.sequence }
            if event.record.kind == .user, firstUsers[event.turnID] == nil { firstUsers[event.turnID] = event.sequence }
            if [.user, .message].contains(event.record.kind) { messages.append(event) }
        }
        let carried = Dictionary(uniqueKeysWithValues: historyRows(events).compactMap { row -> (Double, Bool)? in
            guard let sequence = row["sequence"].number else { return nil }
            return (sequence, row["fork"].bool == true)
        })
        var earlierUser = false, earlierClaudeCheckpoint = false
        return messages.map { message in
            let user = message.record.kind == .user
            let providerTurn = completed[message.turnID]
            let uuid = user ? (UUID(uuidString: message.record.messageID) != nil ? message.record.messageID : message.turnID) : message.record.value["providerMessageId"].string
            let claude = provider == .claude && uuid.flatMap(UUID.init(uuidString:)) != nil
            let codex = provider == .codex && providerTurn?.isEmpty == false && firstUsers[message.turnID] != nil
            // Codex cuts whole turns. A steered prompt or intermediate answer is not a message boundary.
            let fork = (provider == .gemini && carried[Double(message.sequence)] == true) || claude || (codex && !user && !message.record.messageID.isEmpty && answers[message.turnID] == message.sequence)
            let rewind = user && ((claude && (!earlierUser || earlierClaudeCheckpoint)) || (codex && firstUsers[message.turnID] == message.sequence))
            if user { earlierUser = true }
            if !user, claude { earlierClaudeCheckpoint = true }
            return .object([.init("sequence", .number(Double(message.sequence))), .init("rowId", .string(message.turnID + ":" + (message.record.messageID.isEmpty ? message.id : message.record.messageID))), .init("turnId", .string(message.turnID)),
                .init("rewind", .bool(rewind)), .init("fork", .bool(fork)),
                .init("providerMessageId", uuid.map(NativeRPCValue.string) ?? .null),
                .init("providerTurnId", providerTurn.map(NativeRPCValue.string) ?? .null)])
        }
    }

    public static func phoneEvent(_ event: NativeRPCValue, actions: [NativeRPCValue]) -> NativeRPCValue {
        let row = actions.first { $0["sequence"].number == event["sequence"].number }
        let flags = NativeRPCValue.object([.init("rewind", .bool(row?["rewind"].bool == true)), .init("fork", .bool(row?["fork"].bool == true))])
        return event.setting("value", event["value"].setting("historyActions", flags))
    }

    /// An older keeper's rewind rebuilt saved words. It must never answer a new provider-native request.
    public static func requireNativeRewind(_ snapshot: NativeRPCValue, sequence: Int) throws {
        guard let actions = snapshot["messageActions"].elements else {
            throw NativeRPCError(code: "helper-upgrade-required", message: "This running session engine predates provider-native Rewind. Its conversation was kept unchanged.")
        }
        guard snapshot["providerConversationId"].string?.isEmpty == false,
              actions.contains(where: { $0["sequence"].number == Double(sequence) && $0["rewind"].bool == true }) else {
            throw NativeRPCError(code: "unavailable", message: "The AI has no confirmed rewind boundary for that message. Its conversation was kept unchanged.")
        }
    }

    public static func boundary(_ sequence: Int, events: [HootChatEvent], provider: HootChatProvider, action: String) throws -> NativeRPCValue {
        guard let row = rows(events, provider: provider).first(where: { $0["sequence"].number == Double(sequence) }), row[action].bool == true else {
            throw NativeRPCError(code: "unavailable", message: "This AI has no confirmed boundary for that message. Nothing changed.")
        }
        return row
    }
}
