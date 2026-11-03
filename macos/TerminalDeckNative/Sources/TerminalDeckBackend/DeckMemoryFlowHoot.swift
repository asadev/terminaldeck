import Foundation
import TerminalDeckNativeCore

/// Turns Hoot's own event stream (the same events its chat page draws) into diary pieces
/// and a turn-end signal. Pure: feed it events in order. Streaming text is gathered and a
/// message is written once, whole, when it is complete; nothing is written twice.
public struct DeckMemoryFlowHootReader: Sendable {
    public struct Output: Sendable, Equatable {
        public var pieces: [Piece] = []
        /// Hoot finished its answer and stopped (or was stopped) and is not working any more.
        public var turnEnded = false
        /// Everything up to this event is in `pieces` (now or earlier): safe to remember.
        public var cursor = 0
        /// Hoot is asking the person something right now.
        public var waiting: String?
        public var busy = false
    }
    public struct Piece: Sendable, Equatable {
        public var piece: DeckMemoryFlowPiece
        public var turn: String
        public var provider: String
        /// Where a message that the person did not type came from: "task", "routine", "dev-test". "" = nothing was said about it.
        public var source = ""
        /// The task this row belongs to, when Hoot is answering IN a task (its turn id starts with "task:").
        public var job: String? { DeckMemoryFlowHootReader.job(ofTurn: turn) }
    }
    /// "task:<task id>:<uuid>" → the task id. A task turn has no message from the person at all.
    public static func job(ofTurn turn: String) -> String? {
        guard turn.hasPrefix("task:"), let end = turn.lastIndex(of: ":"), end > turn.index(turn.startIndex, offsetBy: 4) else { return nil }
        let id = String(turn[turn.index(turn.startIndex, offsetBy: 5)..<end])
        return id.isEmpty ? nil : id
    }
    private struct Open: Sendable {
        var role: DeckMemoryDiaryRole
        var text: String
        var name: String
        var input: NativeRPCValue
        var at: Double
        var turn: String
        var provider: String
        var firstSequence: Int
        var key: String
        /// A whole text has been seen for it (not only streamed pieces).
        var whole = false
    }
    public private(set) var conversation: String
    private var open: [String: Open] = [:]
    private var order: [String] = []
    /// Messages of the current turn already written, so a later block of one gets its own key.
    private var written = Set<String>()
    private var pendingTurnEnd = false
    private var last = 0
    private var asking: [String: String] = [:]

    public init(conversation: String, cursor: Int = 0) { self.conversation = conversation; last = cursor }
    /// The last event taken in. Reading on from here never repeats one.
    public var position: Int { last }

    /// `busy`: Hoot's own "still working" flag at the moment these events were read.
    public mutating func take(_ events: [HootChatEvent], busy: Bool) -> Output {
        var output = Output()
        for event in events where event.conversationID == conversation && event.sequence > last {
            last = event.sequence
            let record = event.record, provider = event.provider.rawValue
            let base = "hoot:" + conversation + ":"
            switch record.kind {
            case .user:
                flush(into: &output)
                var text = record.value["text"].string ?? ""
                let attachments = Int(record.value["attachmentCount"].number ?? 0)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments > 0 {
                    text = attachments == 1 ? "[1 attachment]" : "[\(attachments) attachments]"
                }
                guard !text.isEmpty else { continue }
                pendingTurnEnd = false; written.removeAll()
                // A message a routine or a task put into Hoot's chat carries its source; the person's own do not.
                // A builder's test message (the dev copy's test door) is marked "dev-test": it is a tool's, and
                // the helper and the tidy-up leave its whole turn alone.
                // Any other source kind is something the person attached to their own message (a page, a screen, a folder).
                let source = record.value["context"]["source"]["kind"].string ?? ""
                let author: DeckMemoryAuthor = source == DeckMemoryFlowNames.testSource ? .tool
                    : (DeckMemoryFlowNames.appSources.contains(source) ? .app : .person)
                output.pieces.append(.init(piece: .init(role: .user, text: text, at: date(event.at), key: base + event.turnID + ":user", author: author),
                                           turn: event.turnID, provider: provider, source: source))
            case .textDelta, .message:
                let text = record.value["text"].string ?? ""
                if record.value["routing"].fields != nil {
                    // A routing card is re-recorded as its state changes; its words are stored once.
                    guard !text.isEmpty else { continue }
                    flush(into: &output)
                    output.pieces.append(.init(piece: .init(role: .assistant, text: text, at: date(event.at), key: base + record.messageID, author: .orchestrator),
                                               turn: event.turnID, provider: provider))
                    continue
                }
                if record.messageID.isEmpty {
                    // A line the app itself put in the chat ("New conversation with Codex…"). For a task turn it is
                    // the opening row, and what Hoot was really given is the task's whole brief, not the short visible line.
                    let brief = record.value["task"]["brief"].string ?? ""
                    let line = brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : brief
                    guard record.kind == .message, !line.isEmpty else { continue }
                    flush(into: &output)
                    if record.value["task"].fields != nil { pendingTurnEnd = false; written.removeAll() }
                    output.pieces.append(.init(piece: .init(role: .system, text: line, at: date(event.at), key: base + "line:" + String(event.sequence)),
                                               turn: event.turnID, provider: provider))
                    continue
                }
                let id = "m:" + event.turnID + ":" + record.messageID
                let whole = record.kind == .message
                if var item = open[id], !(item.whole && (!whole || !text.hasPrefix(item.text))) {
                    // More of the same message: streamed text adds on, a whole text replaces.
                    item.text = whole ? text : item.text + text
                    item.whole = item.whole || whole
                    open[id] = item
                } else {
                    // A new message (or a new block of the same one) starts: what came before is complete.
                    let again = open[id] != nil
                    flush(into: &output)
                    open[id] = Open(role: .assistant, text: text, name: "", input: .null, at: event.at, turn: event.turnID,
                                    provider: provider, firstSequence: event.sequence,
                                    key: base + event.turnID + ":" + record.messageID + (again || written.contains(id) ? ":" + String(event.sequence) : ""),
                                    whole: whole)
                    order.append(id)
                }
            case .toolCall:
                guard !record.messageID.isEmpty else { continue }
                let id = "t:" + record.messageID
                let name = record.value["name"].string ?? "Tool", input = record.value["input"]
                if var item = open[id] {
                    // The same call arrives again once its arguments are complete.
                    if input.fields?.isEmpty == false { item.input = input }
                    item.name = name; open[id] = item
                } else {
                    flushMessages(into: &output)
                    open[id] = Open(role: .tool, text: "", name: name, input: input, at: event.at, turn: event.turnID, provider: provider,
                                    firstSequence: event.sequence, key: base + "tool:" + record.messageID)
                    order.append(id)
                }
            case .toolResult:
                flush(into: &output)
            case .approval:
                flush(into: &output)
                let name = record.value["name"].string ?? "something"
                asking[record.messageID] = name
                output.pieces.append(.init(piece: .init(role: .event, text: "Hoot asked for permission: " + name, at: date(event.at),
                                                        key: base + "ask:" + record.messageID), turn: event.turnID, provider: provider))
            case .approvalResolved:
                asking[record.messageID] = nil
            case .completed:
                flush(into: &output); pendingTurnEnd = true; asking = [:]
            case .interrupted:
                flush(into: &output); pendingTurnEnd = true; asking = [:]
                output.pieces.append(.init(piece: .init(role: .event, text: "Hoot was stopped before it finished.", at: date(event.at),
                                                        key: base + "stop:" + String(event.sequence)), turn: event.turnID, provider: provider))
            case .error:
                flush(into: &output)
                let text = record.value["text"].string ?? ""
                guard !text.isEmpty else { continue }
                output.pieces.append(.init(piece: .init(role: .event, text: text, at: date(event.at),
                                                        key: base + "error:" + String(event.sequence)), turn: event.turnID, provider: provider))
            case .session:
                continue
            }
        }
        if !busy {
            // Not working any more: what is still gathered is as complete as it will get.
            flush(into: &output)
            if pendingTurnEnd { output.turnEnded = true; pendingTurnEnd = false }
        }
        output.busy = busy
        output.waiting = asking.isEmpty ? nil : "Hoot is waiting for your answer: " + asking.values.sorted().joined(separator: ", ")
        output.cursor = order.compactMap { open[$0]?.firstSequence }.min().map { $0 - 1 } ?? last
        return output
    }

    private mutating func flushMessages(into output: inout Output) {
        let ids = order.filter { open[$0]?.role == .assistant }
        emit(ids, into: &output)
    }
    private mutating func flush(into output: inout Output) { emit(order, into: &output) }
    private mutating func emit(_ ids: [String], into output: inout Output) {
        for id in ids {
            guard let item = open.removeValue(forKey: id) else { continue }
            let text = item.role == .tool ? DeckMemoryFlowTranscripts.toolLine(name: item.name, input: item.input) : item.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if item.role == .assistant { written.insert(id) }
            output.pieces.append(.init(piece: .init(role: item.role, text: text, at: date(item.at), key: item.key,
                                                    author: item.role == .assistant ? .orchestrator : nil),
                                       turn: item.turn, provider: item.provider))
        }
        order.removeAll { open[$0] == nil }
    }
    private func date(_ milliseconds: Double) -> Date? { milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil }
}
