import Foundation
import TerminalDeckNativeCore

public enum BackendDeckCoreAttention {
    public static let order = ["blocked": 0, "done": 1, "quiet": 2, "running": 3]
    public static func status(exitCode: Int?, live: String?) -> String {
        exitCode == nil ? (live ?? "idle") : "exited"
    }
    public static func view(status: String, statusSince: Double?, exitCode: Int?, now: Double) -> NativeRPCValue {
        let pair: (String, String)
        switch status {
        case "input": pair = ("blocked", "question-unanswered")
        case "working": pair = ("running", "output-streaming")
        case "waiting": pair = ("quiet", "prompt-ready")
        case "completed": pair = ("done", "turn-finished")
        case "exited": pair = ("done", exitCode != nil && exitCode != 0 ? "process-failed" : "process-exited")
        default: pair = ("quiet", "no-output")
        }
        return .object([.init("attention", .string(pair.0)), .init("attentionReason", .string(pair.1)),
            .init("attentionForMs", statusSince.map { .number(max(0, now - $0)) } ?? .null),
            .init("statusSource", .string(exitCode == nil ? "screen" : "exit-code"))])
    }
    public static func precedes(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        let x = order[a["attention"].string ?? "quiet"] ?? 2
        let y = order[b["attention"].string ?? "quiet"] ?? 2
        return x == y ? (a["attentionForMs"].number ?? -1) > (b["attentionForMs"].number ?? -1) : x < y
    }
}

/// Reuses the existing native transcript assessor, correcting only source
/// wording and its first-seen tie rule without a second transcript parser.
public enum BackendDeckCoreProgress {
    public static let windowCalls = 30, repeatWarning = 10, repeatCritical = 20, failureWarning = 5
    public static func assess(_ transcript: BackendCostTranscript?) -> NativeRPCValue {
        var value = BackendInsightsProgress.assess(transcript)
        guard let transcript else {
            return value.setting("unknownReason", .string("This session keeps no transcript, so there is nothing to read its behaviour from."))
        }
        guard !transcript.toolTrail.isEmpty else { return value }
        var findings = (value["findings"].elements ?? []).filter {
            !["compaction-echo", "no-writes"].contains($0["signal"].string ?? "")
        }.map { entry -> NativeRPCValue in
            if entry["signal"].string == "repeated-tool", let count = entry["count"].number, count >= 20 {
                return entry.setting("detail", .string("\(entry["tool"].string ?? "") has been called \(Int(count)) times in the last \(Int(value["examined"].number ?? 0)) tool calls — it is nearly all this session is doing."))
            }
            return entry
        }
        if let at = transcript.compactions.last?["at"].number {
            let before = Array(transcript.toolTrail.filter { $0.at > 0 && $0.at <= at }.suffix(30))
            let after = transcript.toolTrail.filter { $0.at > at }.prefix(3)
            var counts: [String: Int] = [:], names: [String] = []
            for call in before {
                if counts[call.name] == nil { names.append(call.name) }
                counts[call.name, default: 0] += 1
            }
            var dominant: String?, best = 0
            for name in names where counts[name, default: 0] > best { dominant = name; best = counts[name, default: 0] }
            if let dominant, after.contains(where: { $0.name == dominant }) {
                findings.append(.object([.init("signal", .string("compaction-echo")), .init("tool", .string(dominant)),
                    .init("detail", .string("The session compacted and went straight back to \(dominant), which is what filled the context.")), .init("count", .null)]))
            }
        }
        let repeating = !findings.isEmpty, writes = value["writes"].number ?? 0
        if repeating && writes == 0 {
            findings.append(.object([.init("signal", .string("no-writes")), .init("tool", .null),
                .init("detail", .string("Nothing has been written to a file in the last \(Int(value["examined"].number ?? 0)) tool calls.")), .init("count", .null)]))
        }
        value = value.setting("findings", .array(findings))
        return value.setting("verdict", .string(!repeating ? "ok" : writes == 0 ? "looping" : "suspect"))
    }
    public static func sentence(_ report: NativeRPCValue) -> String {
        let details = (report["findings"].elements ?? []).compactMap { $0["detail"].string }
        switch report["verdict"].string {
        case "ok":
            let writes = Int(report["writes"].number ?? 0)
            return "Making progress — \(writes) file write\(writes == 1 ? "" : "s") in the last \(Int(report["examined"].number ?? 0)) tool calls."
        case "suspect": return BackendDeckCoreCatalogueRules.trim("Repeating itself, but still writing files. " + (details.first ?? ""))
        case "looping": return BackendDeckCoreCatalogueRules.trim("Looks stuck. " + details.joined(separator: " "))
        default: return report["unknownReason"].string ?? "Nothing to read."
        }
    }
}

public struct BackendDeckCoreFleetContext: Sendable {
    public let medianTokens: Double?
    public let sample: Int
    public init(medianTokens: Double?, sample: Int) { self.medianTokens = medianTokens; self.sample = sample }
    public static let none = Self(medianTokens: nil, sample: 0)
    public static func make(_ totals: [Double?]) -> Self {
        let counted = totals.compactMap { $0 }.filter { $0 > 0 }.sorted()
        guard !counted.isEmpty else { return .none }
        let mid = counted.count / 2
        return Self(medianTokens: counted.count % 2 == 1 ? counted[mid] : (counted[mid - 1] + counted[mid]) / 2, sample: counted.count)
    }
}

public enum BackendDeckCoreImportance {
    public static let priority = ["blocked-on-you", "failed", "looping", "tool-failing", "expensive", "question-asked", "compacted", "finished", "files-changed", "decision"]
    public static let uncheckedReasons: Set<String> = ["decision"]
    public static let heavyMinSample = 5, heavyMultiple = 3.0, heavyMinTokens = 1_000_000.0
    public static func supports(_ why: String, input: NativeRPCValue, fleet: BackendDeckCoreFleetContext = .none) -> Bool {
        let progress = input["progress"]
        switch why {
        case "blocked-on-you": return input["attention"].string == "blocked"
        case "failed": return input["attentionReason"].string == "process-failed"
        case "finished": return input["attention"].string == "done"
        case "looping": return progress["verdict"].string == "looping"
        case "tool-failing": return progress["findings"].elements?.contains { $0["signal"].string == "repeated-failure" } == true
        case "compacted": return (progress["compactions"].number ?? 0) > 0
        case "expensive":
            guard let tokens = input["totalTokens"].number, let median = fleet.medianTokens, median > 0,
                  fleet.sample >= heavyMinSample, tokens >= heavyMinTokens else { return false }
            return tokens / median >= heavyMultiple
        case "files-changed": return (input["changedFiles"].number ?? 0) > 0
        case "question-asked": return input["lastMessage"].string.map { BackendDeckCoreCatalogueRules.trim($0).hasSuffix("?") } == true
        case "decision": return true
        default: return false
        }
    }
    public static func reasons(_ input: NativeRPCValue, fleet: BackendDeckCoreFleetContext = .none) -> [NativeRPCValue] {
        priority.filter { $0 != "decision" && supports($0, input: input, fleet: fleet) }.map { why in
            .object([.init("why", .string(why)), .init("detail", .string(detail(why, input: input, fleet: fleet)))])
        }
    }
    private static func detail(_ why: String, input: NativeRPCValue, fleet: BackendDeckCoreFleetContext) -> String {
        switch why {
        case "blocked-on-you": return "A question is on screen and nothing will happen until it is answered."
        case "failed": return "The process exited \(input["exitCode"].number.map { String(Int($0)) } ?? "(unknown)")."
        case "finished": return input["attentionReason"].string == "process-exited" ? "The process exited cleanly." : "The agent reported its turn finished."
        case "looping", "tool-failing":
            return input["progress"]["findings"].elements?.first(where: { why != "tool-failing" || $0["signal"].string == "repeated-failure" })?["detail"].string ?? "Repeating itself with nothing landing on disk."
        case "compacted":
            let n = Int(input["progress"]["compactions"].number ?? 0)
            return "The context filled and was summarised away \(n) time\(n == 1 ? "" : "s") in the part of the transcript that was read."
        case "expensive":
            guard let tokens = input["totalTokens"].number, let median = fleet.medianTokens, median > 0 else { return "Spending far above the rest of the fleet." }
            return "Moved \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tokens / median))× the median tokens of the \(fleet.sample) sessions it was compared against."
        case "files-changed":
            let n = Int(input["changedFiles"].number ?? 0)
            return "\(n) uncommitted file\(n == 1 ? "" : "s") in its folder."
        case "question-asked": return "The last thing it said was a question."
        default: return "A choice worth knowing about."
        }
    }
    public static func loopSeverity(_ progress: NativeRPCValue?) -> Int {
        Int(progress?["findings"].elements?.compactMap { $0["count"].number }.max() ?? 0)
    }
    public static func isCriticalLoop(_ progress: NativeRPCValue?) -> Bool { loopSeverity(progress) >= 20 }
}
