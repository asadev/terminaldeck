import Foundation
import TerminalDeckNativeCore

/// Source progress.ts thresholds. Metadata is evidence of repetition, never
/// permission to stop a session or proof about a shell command's effects.
public enum BackendInsightsProgress {
    public static func assess(_ transcript: BackendCostTranscript?) -> NativeRPCValue {
        guard let transcript else { return unknown("This session keeps no supported transcript, so there is nothing to read its behaviour from.") }
        let window = Array(transcript.toolTrail.suffix(30))
        guard !window.isEmpty else { return unknown(transcript.truncated ? "No tool calls in the part of the transcript that was read." : "This session has not called a tool yet.") }
        let writing: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit", "StrReplace"]
        var counts: [String: (calls: Int, failures: Int)] = [:], writes = 0, failures = 0
        for call in window { var row = counts[call.name] ?? (0, 0); row.calls += 1; if call.failed == true { row.failures += 1; failures += 1 }; counts[call.name] = row; if writing.contains(call.name) { writes += 1 } }
        var findings: [NativeRPCValue] = []
        func finding(_ signal: String, _ name: String?, _ detail: String, _ count: Int?) -> NativeRPCValue { BackendUsageIO.object([("signal", .string(signal)), ("tool", BackendUsageIO.string(name)), ("detail", .string(detail)), ("count", count.map { .number(Double($0)) } ?? .null)]) }
        for (name, stat) in counts.sorted(by: { $0.value.failures == $1.value.failures ? ($0.value.calls == $1.value.calls ? $0.key < $1.key : $0.value.calls > $1.value.calls) : $0.value.failures > $1.value.failures }) {
            if stat.failures >= 5 { findings.append(finding("repeated-failure", name, "\(name) failed \(stat.failures) times in the last \(window.count) tool calls.", stat.failures)) }
            if stat.calls >= 10 { findings.append(finding("repeated-tool", name, "\(name) accounts for \(stat.calls) of the last \(window.count) tool calls.", stat.calls)) }
        }
        if let at = transcript.compactions.last?["at"].number, at > 0 {
            let before = transcript.toolTrail.filter { $0.at > 0 && $0.at <= at }.suffix(30), after = transcript.toolTrail.filter { $0.at > at }.prefix(3)
            var names: [String: Int] = [:], dominant: String?, best = 0
            for call in before { names[call.name, default: 0] += 1; if names[call.name]! > best { best = names[call.name]!; dominant = call.name } }
            if let dominant, after.contains(where: { $0.name == dominant }) { findings.append(finding("compaction-echo", dominant, "The session compacted and went straight back to \(dominant), which is what filled the context.", nil)) }
        }
        let repeating = !findings.isEmpty
        if repeating && writes == 0 { findings.append(finding("no-writes", nil, "Nothing has been written to a file in the last \(window.count) tool calls.", nil)) }
        let times = window.map(\.at).filter { $0 > 0 }
        return BackendUsageIO.object([("verdict", .string(!repeating ? "ok" : writes == 0 ? "looping" : "suspect")), ("findings", .array(findings)), ("unknownReason", .null), ("examined", .number(Double(window.count))), ("spanMs", times.count >= 2 ? .number(times.max()! - times.min()!) : .null), ("partial", .bool(transcript.truncated)), ("writes", .number(Double(writes))), ("failures", .number(Double(failures))), ("compactions", .number(Double(transcript.compactions.count)))])
    }
    private static func unknown(_ reason: String) -> NativeRPCValue { BackendUsageIO.object([("verdict", .string("unknown")), ("findings", .array([])), ("unknownReason", .string(reason)), ("examined", .number(0)), ("spanMs", .null), ("partial", .bool(false)), ("writes", .number(0)), ("failures", .number(0)), ("compactions", .number(0))]) }
}
