import Foundation
import TerminalDeckNativeCore

/// Pure task-brief.ts composition. Goals are root-first; the task's surrounding
/// context is capped independently so old notes do not become a transcript.
public enum BackendTaskBriefComposition {
    public static func goals(_ chain: [NativeRPCValue]) -> String {
        guard !chain.isEmpty else { return "" }
        let lines = chain.reversed().enumerated().map { depth, goal in
            let about = goal["description"].string ?? ""
            return String(repeating: "  ", count: depth) + "- **\(oneLine(goal["title"].string ?? "", maximum: 200))** (\(goal["status"].string ?? "unknown"))" + (about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " — " + oneLine(about, maximum: 600))
        }
        return "\n\n## The goal this serves\n\n" + "This task is part of the goal\(chain.count > 1 ? "s below, from the broadest down to the one it serves directly" : " below"). " +
            "Keep the work pointed at it; say so in your summary if something in the task works against it.\n\n" + lines.joined(separator: "\n")
    }
    /// task-brief.ts retrySection: a try after one that did not finish.
    public static func retry(_ task: BackendTaskRecord) -> String {
        let retry = task.value["retry"]; guard !retry.isNullish else { return "" }
        let note = (retry["note"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\n\n## Tried again\n\nThis task was started before and did not finish (try \(Int((retry["count"].number ?? 0)) + 1))." + (note.isEmpty ? "" : "\n\n" + oneLine(note, maximum: 2_000))
    }
    /// agent-briefing.ts stackText: the owner's settings for this agent, as the brief tells them.
    public static func stack(_ agent: NativeRPCValue) -> String {
        typealias C = BackendSharedAgentCapabilities
        let provider = agent["provider"].string, list: (String) -> [String] = { agent[$0].elements?.compactMap(\.string) ?? [] }
        let says: (C.Setting) -> Bool = { C.capabilityFor(provider, setting: $0).support != .unsupported }
        var parts: [String] = []
        if let text = agent["instructions"].string, says(.instructions) { parts.append(text) }
        if says(.toolAdvice) {
            if !list("toolsPreferred").isEmpty { parts.append("Prefer these tools: \(list("toolsPreferred").joined(separator: ", ")).") }
            if !list("toolsAvoided").isEmpty { parts.append("Do not use these tools: \(list("toolsAvoided").joined(separator: ", ")).") }
            if !list("toolsPreferred").isEmpty || !list("toolsAvoided").isEmpty { parts.append("These tool choices are what the owner asked for; your own permission settings still apply.") }
        }
        let skillsOff = agent["skillsOff"].bool == true
        if !list("skills").isEmpty, !skillsOff, says(.skillSelection) { parts.append("Use these skills when they fit: \(list("skills").joined(separator: ", ")). That is a request, not a limit: other skills stay available.") }
        if !list("blockedTools").isEmpty { parts.append("These tools are switched off for you: \(list("blockedTools").joined(separator: ", ")).") }
        if skillsOff { parts.append("Skills are switched off for you.") }
        return parts.isEmpty ? "" : "\n\n## How you work (\(agent["name"].string ?? ""), \(agent["role"].string ?? ""))\n\n" + parts.joined(separator: "\n\n")
    }
    public static func context(_ task: BackendTaskRecord, all: [BackendTaskRecord], names: [String: String]) -> String {
        var parts: [String] = []
        let detail = task.value["detail"], subtasks = (detail["subtasks"].elements ?? []).sorted { ($0["sortOrder"].number ?? 0) < ($1["sortOrder"].number ?? 0) }.prefix(20)
        if !subtasks.isEmpty { parts.append("### Subtasks\n\n" + subtasks.map { "- [\($0["done"].bool == true ? "x" : " ")] \(oneLine($0["title"].string ?? ""))" }.joined(separator: "\n")) }
        let lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }), word = ["blocked_by": "Waits for", "blocks": "Needed by", "linked": "Related to"]
        var links = detail["dependencies"].elements ?? [], seen = Set<String>(), lines: [String] = []
        for other in all where other.id != task.id { for dep in other.value["detail"]["dependencies"].elements ?? [] where dep["otherTaskId"].string == task.id { let kind = dep["kind"].string ?? "linked"; links.append(dep.setting("kind", .string(kind == "blocks" ? "blocked_by" : kind == "blocked_by" ? "blocks" : "linked")).setting("otherTaskId", .string(other.id))) } }
        for link in links { guard lines.count < 12, let otherID = link["otherTaskId"].string, let other = lookup[otherID], let kind = link["kind"].string, seen.insert(kind + ":" + otherID).inserted else { continue }; lines.append("- \(word[kind] ?? kind): \(oneLine(other.value["title"].string ?? "", maximum: 200)) (\(other.value["crmStatus"].string == "Done" ? "done" : other.value["crmStatus"].string ?? "open"))") }
        if !lines.isEmpty { parts.append("### Linked tasks\n\n" + lines.joined(separator: "\n")) }
        let comments = (detail["comments"].elements ?? []).sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }.suffix(8)
        if !comments.isEmpty { parts.append("### Latest comments\n\n" + comments.map { row in let who = row["authorUserId"].string ?? "unknown"; return "- \(names[who] ?? who): \(oneLine(row["body"].string ?? ""))" }.joined(separator: "\n")) }
        let notes = (task.value["notes"].elements ?? []).filter { ["progress", "blocker", "question", "completion", "reply"].contains($0["kind"].string ?? "") }.suffix(8)
        if !notes.isEmpty { parts.append("### Latest notes\n\n" + notes.map { row in let who = row["by"].string ?? "unknown"; return "- \(names[who] ?? who) (\(row["kind"].string ?? "unknown")): \(oneLine(row["text"].string ?? ""))" }.joined(separator: "\n")) }
        guard !parts.isEmpty else { return "" }; let text = parts.joined(separator: "\n\n")
        return "\n\n## Already on this task\n\nWhat people and agents have written and done on it so far, newest last.\n\n" + (text.utf16.count > 6_000 ? utf16Prefix(text, 6_000) + "\n…(the rest is on the task)" : text)
    }
    private static func oneLine(_ raw: String, maximum: Int = 400) -> String {
        let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.utf16.count <= maximum ? text : utf16Prefix(text, maximum) + "…"
    }
    /// JavaScript `slice(0, n)` counts UTF-16 units.
    static func utf16Prefix(_ text: String, _ count: Int) -> String { String(decoding: Array(text.utf16.prefix(count)), as: UTF16.self) }
}
