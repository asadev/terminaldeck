import Foundation
import TerminalDeckNativeCore

/// reportOnSession/importanceOf/supports are owned by deck-core. Supply the
/// current report facts once per named session and the same shared judgement
/// used by the report. No model-supplied reason becomes evidence here.
public protocol BackendDeckToolsTourEvidence: Sendable {
    func facts(sessionID: String) async throws -> NativeRPCValue?
    func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool
}

public enum BackendDeckToolsTour {
    public static let reasons = ["blocked-on-you", "failed", "finished", "looping", "tool-failing", "compacted", "expensive", "files-changed", "question-asked", "decision"]
    public struct Validated: Sendable {
        public let plan: NativeRPCValue
        public let dropped: [NativeRPCValue]
        public let titles: NativeRPCValue
        public let folders: NativeRPCValue
        public init(plan: NativeRPCValue, dropped: [NativeRPCValue], titles: NativeRPCValue, folders: NativeRPCValue) {
            self.plan = plan; self.dropped = dropped; self.titles = titles; self.folders = folders
        }
    }
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    private static func refused(_ sentence: String) -> NativeRPCError { .init(code: "not-permitted", message: sentence) }
    private static func budget(_ what: String, _ limit: Int, _ actual: Int, _ unit: String) -> NativeRPCError {
        refused("\(what) is capped at \(limit) \(unit) and this plan has \(actual). The plan was refused rather than trimmed, because a tour cut down by the app is not the tour you wrote and you would have no way to know which part went. Send it again within the limit — splitting a long quote across two stops is usually the right fix.")
    }
    private static func text(_ raw: NativeRPCValue, _ key: String, cap: Int, at: String = "the plan") throws -> String {
        guard let value = raw[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw refused("\(at) needs a non-empty \(key)") }
        if value.utf16.count > cap { throw budget("\(at)'s \(key)", cap, value.utf16.count, "characters") }
        return value
    }
    private static func shown(_ value: NativeRPCValue) -> String { value == .missing ? "undefined" : value.compact }
    /// Keeps the existing core TourStop/TourRecord wire format. These are backend
    /// plan values, not competing UI models; DriveTour.read decodes the offer.
    public static func parse(_ raw: NativeRPCValue, now: Double = Date().timeIntervalSince1970 * 1000,
                             random: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) throws -> NativeRPCValue {
        let question = try text(raw, "question", cap: 400), headline = try text(raw, "headline", cap: 1200)
        guard let list = raw["stops"].elements, !list.isEmpty else { throw refused("stops must be a non-empty array; a tour with nothing to show is not a tour") }
        if list.count > 12 { throw budget("A tour", 12, list.count, "stops") }
        let stops: [NativeRPCValue] = try list.enumerated().map { index, item in
            guard item.fields != nil else { throw refused("stop \(index + 1) is not an object") }
            let at = "stop \(index + 1)", sid = try text(item, "sessionId", cap: 200, at: at), note = try text(item, "note", cap: 160, at: at)
            guard let reason = item["why"].string, reasons.contains(reason) else { throw refused("\(at) has why=\(shown(item["why"])), which is not one of the reasons this app checks. They are: \(reasons.joined(separator: ", ")).") }
            var stop = o([("sessionId", .string(sid)), ("note", .string(note)), ("why", .string(reason))])
            switch item["kind"].string {
            case "message": throw refused("\(at) is a 'message' stop, which pointed at the chat view. Chat mode has been removed; quote the same content from the terminal as a 'screen' stop instead.")
            case "screen": stop = stop.setting("kind", .string("screen")).setting("quote", .string(try text(item, "quote", cap: 600, at: at)))
            case "anchor":
                guard let anchor = item["at"].string, ["git-file", "usage"].contains(anchor) else { throw refused("\(at) is an anchor stop with at=\(shown(item["at"])). Anchors are: git-file, usage.") }
                stop = stop.setting("kind", .string("anchor")).setting("at", .string(anchor))
                if anchor == "git-file" { stop = stop.setting("path", .string(try text(item, "path", cap: 1000, at: at))) }
            default: throw refused("\(at) has kind=\(shown(item["kind"])). A stop is 'screen' (a passage of terminal output) or 'anchor' (a named place in the app's own chrome).")
            }
            return stop
        }
        return o([("v", .number(1)), ("id", .string("tour_\(Int64(now))_\(random.prefix(8))")), ("question", .string(question)), ("headline", .string(headline)), ("stops", .array(stops)), ("askedBy", .string(raw["start"].string == "offer" ? "offer" : "user"))])
    }
    public static func validate(_ plan: NativeRPCValue, evidence: any BackendDeckToolsTourEvidence) async throws -> Validated {
        let stops = plan["stops"].elements ?? []
        var facts: [String: NativeRPCValue] = [:], visited: Set<String> = []
        for stop in stops {
            let sid = stop["sessionId"].string ?? ""
            if visited.insert(sid).inserted, let fact = try await evidence.facts(sessionID: sid) { facts[sid] = fact }
        }
        let tokens = facts.values.compactMap { $0["importance"]["totalTokens"].number }.filter { $0 > 0 }.sorted()
        let median: Double? = tokens.isEmpty ? nil : tokens.count % 2 == 1 ? tokens[tokens.count / 2] : (tokens[tokens.count / 2 - 1] + tokens[tokens.count / 2]) / 2
        var kept: [NativeRPCValue] = [], drops: [NativeRPCValue] = [], decided: Set<String> = []
        var titles = NativeRPCValue.object([]), folders = NativeRPCValue.object([])
        for stop in stops {
            let sid = stop["sessionId"].string ?? "", reason = stop["why"].string ?? "", note = stop["note"].string ?? ""
            let fact = facts[sid], title = fact?["title"].string ?? sid
            func drop(_ why: String, _ detail: String) { drops.append(o([("title", .string("\(title) — \(BackendDeckToolsSupport.slice(note, 0, 60))")), ("why", .string(why)), ("detail", .string(detail))])) }
            guard let fact else { drop("session-gone", "There is no live session with id \(sid) any more."); continue }
            titles = titles.setting(sid, .string(title)); folders = folders.setting(sid, fact["session"]["cwd"])
            if reason == "decision", !decided.insert(sid).inserted { drop("over-budget", "A tour gets one \"decision\" per session, because that is the one reason this app cannot check. This was the second for this session."); continue }
            let input = fact["importance"]
            if !(try await evidence.supports(reason: reason, importance: input, median: median, sample: tokens.count)) {
                drop("reason-unsupported", unsupported(reason, input: input, sample: tokens.count)); continue
            }
            if stop["kind"].string == "anchor" {
                if stop["at"].string == "git-file", !(fact["changed"].elements ?? []).contains(stop["path"]) {
                    drop("quote-not-found", "git does not report \(stop["path"].string ?? "") as changed in \(fact["session"]["cwd"].string ?? "")."); continue
                }
            } else if !QuoteMatch.contains(QuoteMatch.stripAnsi(fact["screen"].string ?? ""), quote: stop["quote"].string ?? "") {
                drop("quote-not-found", "That text is not in what this app still holds of that terminal."); continue
            }
            kept.append(stop)
        }
        return Validated(plan: plan.setting("stops", .array(kept)), dropped: drops, titles: titles, folders: folders)
    }
    private static func unsupported(_ why: String, input: NativeRPCValue, sample: Int) -> String {
        switch why {
        case "blocked-on-you": return "That session is \(input["attention"].string ?? "quiet"), not blocked."
        case "failed": return input["exitCode"].isNullish ? "That session has not exited." : "That session exited \(input["exitCode"].compact), which this app does not classify as a failure."
        case "finished": return "That session is \(input["attention"].string ?? "quiet"), not done."
        case "looping": return "progress.ts reads that session as \(input["progress"]["verdict"].string ?? "unreadable"), not looping."
        case "tool-failing": return "No tool in the window that was read has failed often enough to count."
        case "compacted": return "No compaction in the part of that transcript that was read."
        case "expensive": return sample < 5 ? "\"Expensive\" is a comparison, and only \(sample) of the sessions in this plan have any tokens on them — too few to have a median worth comparing against." : "That session is not spending far enough above the others to count."
        case "files-changed": return "git reports nothing changed in that session’s folder."
        case "question-asked": return "The last thing that session said does not end in a question mark."
        default: return "A decision needs no check."
        }
    }
    public static func openRecord(_ validated: Validated, at: Double, shown: String = "screen") -> NativeRPCValue {
        let plan = validated.plan
        let stops = (plan["stops"].elements ?? []).enumerated().map { index, stop -> NativeRPCValue in
            let sid = stop["sessionId"].string ?? ""
            var row = o([("index", .number(Double(index))), ("sessionId", .string(sid)), ("sessionTitle", validated.titles[sid].string.map(NativeRPCValue.string) ?? .string(sid)), ("kind", stop["kind"]), ("cwd", validated.folders[sid].string.map(NativeRPCValue.string) ?? .string("")), ("why", stop["why"]), ("quote", stop["kind"].string == "anchor" ? .string("") : stop["quote"]), ("note", stop["note"]), ("shownAt", .null), ("dwellMs", .null), ("degraded", .bool(false)), ("degradedWhy", .null)])
            if stop.has("at") { row = row.setting("at", stop["at"]) }; if stop.has("path") { row = row.setting("path", stop["path"]) }
            return row
        }
        return o([("v", .number(1)), ("id", plan["id"]), ("startedAt", .number(at)), ("endedAt", .null), ("askedBy", plan["askedBy"]), ("question", plan["question"]), ("headline", plan["headline"]), ("shown", .string(shown)), ("stops", .array(stops)), ("stoppedAfter", .null), ("dropped", .array(validated.dropped))])
    }
    public static func mergeProgress(_ record: NativeRPCValue, update: NativeRPCValue) -> NativeRPCValue {
        let updates = update["stops"].elements ?? []
        let stops = (record["stops"].elements ?? []).map { original -> NativeRPCValue in
            guard let from = updates.first(where: { $0["index"] == original["index"] }) else { return original }
            return original.setting("shownAt", from["shownAt"].number.map(NativeRPCValue.number) ?? .null)
                .setting("dwellMs", from["dwellMs"].number.map(NativeRPCValue.number) ?? .null)
                .setting("degraded", .bool(from["degraded"].bool == true))
                .setting("degradedWhy", from["degradedWhy"].string.map(NativeRPCValue.string) ?? .null)
        }
        var merged = record.setting("stops", .array(stops)).setting("stoppedAfter", update["stoppedAfter"].number.map(NativeRPCValue.number) ?? .null)
        if update["endedAt"] != .missing { merged = merged.setting("endedAt", update["endedAt"].number.map(NativeRPCValue.number) ?? .null) }
        return merged
    }
}
