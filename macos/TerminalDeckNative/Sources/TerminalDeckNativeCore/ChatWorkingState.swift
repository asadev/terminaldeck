import Foundation

/// Only structured provider state can keep this line alive. Silence and old unfinished messages cannot.
public struct ChatWorkingState: Equatable, Sendable {
    public let active: Bool
    public let detail: String
    public let since: Double?
    public static let idle = ChatWorkingState(active: false, detail: "", since: nil)

    /// Status dots need only the live flags, not another decoding of the conversation on each streamed word.
    public static func isActive(_ snapshot: NativeRPCValue) -> Bool {
        guard snapshot["readOnly"].bool != true, snapshot["alive"].bool != false else { return false }
        if snapshot["busy"].bool == true || snapshot["answering"].bool == true { return true }
        let children = snapshot["children"].elements ?? ChatChildTasks.list(
            (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) })
        return children.contains { ChatChildTasks.running($0) || $0["status"].string == "stopping" }
    }

    public static func read(_ snapshot: NativeRPCValue, events: [HootChatEvent]? = nil) -> Self {
        guard snapshot["readOnly"].bool != true, snapshot["alive"].bool != false else { return .idle }
        let events = events ?? (snapshot["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
        let children = snapshot["children"].elements ?? ChatChildTasks.list(events)
        let running = children.filter { ChatChildTasks.running($0) || $0["status"].string == "stopping" }
        guard snapshot["busy"].bool == true || snapshot["answering"].bool == true || !running.isEmpty else { return .idle }
        let user = events.last { $0.record.kind == .user && !$0.turnID.hasPrefix("bg:") }
        let turn = user.map { user in events.filter { $0.turnID == user.turnID } } ?? events
        var openTools: [String: HootChatEvent] = [:]
        for event in turn {
            switch event.record.kind {
            case .toolCall: openTools[event.record.messageID] = event
            case .toolResult: if event.record.value["partial"].bool != true { openTools[event.record.messageID] = nil }
            case .completed, .interrupted: openTools.removeAll()
            default: break
            }
        }
        let detail: String
        if !(snapshot["pending"].elements ?? []).isEmpty { detail = "waiting for you" }
        else if let tool = openTools.values.max(by: { $0.sequence < $1.sequence }) {
            let name = tool.record.value["name"].string ?? ""
            let command = ["Bash", "shell", "exec_command", "commandExecution"].contains(name) || name.hasSuffix("__exec_command") ||
                tool.record.value["input"]["type"].string == "commandExecution"
            detail = command ? "running a command" : "running a tool"
        }
        else if running.contains(where: { $0["kind"].string == "agent" }) { detail = "waiting on an agent" }
        else if !running.isEmpty { detail = "running a background task" }
        else if turn.last?.record.kind == .textDelta || turn.last?.record.kind == .message { detail = "replying" }
        else { detail = "thinking" }
        let finished = turn.contains { [.completed, .interrupted].contains($0.record.kind) }
        let linkedChild = user.map { user in running.contains { $0["turnId"].string == user.turnID } } ?? false
        // A later autonomous turn must never borrow the previous message's clock. Unknown start time stays unknown.
        let at = !finished || linkedChild ? user?.at : nil
        return Self(active: true, detail: detail, since: at.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }
    public func elapsed(at now: Double) -> String? {
        guard let since, now.isFinite else { return nil }
        let seconds = Int(min(Double(Int.max / 2), max(0, (now - since) / 1000)))
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
    public func wire(at now: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue {
        .object([.init("active", .bool(active)), .init("detail", active ? .string(detail) : .null),
            .init("since", since.map(NativeRPCValue.number) ?? .null),
            .init("elapsed", elapsed(at: now).map(NativeRPCValue.string) ?? .null),
            .init("source", .string("provider-events"))])
    }
}
