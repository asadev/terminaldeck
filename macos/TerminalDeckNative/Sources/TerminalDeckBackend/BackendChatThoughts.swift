import Foundation
import TerminalDeckNativeCore

public enum BackendChatThoughts {
    private struct Span {
        var start: Double
        var measured = false
        var end: Double?
        var parts: [Int: String] = [:]
    }
    public static func summaries(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        var turns: [String: [String: Span]] = [:]
        var completed: [String: Double] = [:]
        for event in events where !event.turnID.hasPrefix("bg:") {
            if [.completed, .interrupted, .error].contains(event.record.kind) { completed[event.turnID] = event.at }
            let value = event.record.value["reasoning"]
            guard event.record.kind == .session, let id = value["id"].string else { continue }
            var span = turns[event.turnID]?[id] ?? Span(start: event.at)
            let part = Int(value["part"].number ?? 0), phase = value["phase"].string ?? ""
            if phase == "start" { span.measured = true }
            if let text = value["text"].string {
                if phase == "delta" { span.parts[part, default: ""] += text }
                else if phase == "full", !text.isEmpty { span.parts = [0: text] }
                else if !text.isEmpty { span.parts[part] = text }
            }
            if phase == "end" || phase == "full" { span.end = span.end ?? event.at }
            turns[event.turnID, default: [:]][id] = span
        }
        return turns.keys.sorted().compactMap { turn in
            let spans = (turns[turn] ?? [:]).values.sorted { $0.start < $1.start }
            let text = spans.flatMap { span in span.parts.keys.sorted().compactMap { span.parts[$0] } }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            let known = spans.contains { $0.measured }
            let milliseconds = spans.filter(\.measured).reduce(0.0) { $0 + max(0, ($1.end ?? completed[turn] ?? $1.start) - $1.start) }
            return .object([.init("turnId", .string(turn)), .init("text", .string(text)),
                .init("seconds", known ? .number((milliseconds / 1000).rounded()) : .null),
                .init("live", .bool(completed[turn] == nil && spans.contains { $0.end == nil }))])
        }
    }
}
