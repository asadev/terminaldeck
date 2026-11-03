import Foundation
import TerminalDeckNativeCore

/// Pure readers for the exact 0.15.0 CLI/last-check formats, returning the wire
/// shapes StaysFixedModel and the shared fixed tools already consume.
public enum BackendStaysFixedRead {
    public static func text(_ v: NativeRPCValue, _ fallback: String = "") -> String { v.string ?? fallback }
    public static func list(_ v: NativeRPCValue) -> [NativeRPCValue] { v.elements ?? [] }
    public static func number(_ v: NativeRPCValue, _ fallback: Double = 0) -> Double { v.number ?? fallback }
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func nullable(_ text: String?) -> NativeRPCValue { text.map(NativeRPCValue.string) ?? .null }
    static func plural(_ n: Double, _ one: String) -> String { "\(format(n)) \(one)\(n == 1 ? "" : "s")" }
    static func format(_ n: Double) -> String { n.rounded(.towardZero) == n ? String(format: "%.0f", n) : String(n) }
    public static func valueText(_ v: NativeRPCValue, full: Bool = false) -> NativeRPCValue {
        guard !v.isNullish else { return .null }; let value = v.string ?? v.compact, size = value.utf16.count
        if full || size <= 400 { return .string(value) }
        let prefix = String(decoding: Array(value.utf16.prefix(400)), as: UTF16.self)
        return .string(prefix + "… (\(size - 400) more characters)")
    }
    public static func plainTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\t", with: " ").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func buildName(_ v: NativeRPCValue) -> String {
        if !text(v["version"]).isEmpty { return text(v["version"]) }
        if !text(v["gitSha"]).isEmpty { return String(text(v["gitSha"]).prefix(7)) }
        return text(v["id"], "this build")
    }
    public static func fileSafe(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return clean.isEmpty ? "checkpoint" : clean
    }
    public static func notChecked(_ coverage: NativeRPCValue, doors: Double) -> NativeRPCValue {
        let gaps = Double(list(coverage["gaps"]).count), doors = max(0, doors)
        if gaps == 0 && doors == 0 { return .null }
        var parts: [String] = []
        if doors > 0 { parts.append("\(plural(doors, "way")) into it \(doors == 1 ? "was" : "were") never walked") }
        if gaps > 0 { parts.append("\(plural(gaps, "other thing")) \(gaps == 1 ? "was" : "were") not looked at") }
        return .string("Not everything was checked: \(parts.joined(separator: ", and ")). The full report lists each one.")
    }
    public static func difference(_ f: NativeRPCValue, full: Bool) -> NativeRPCValue {
        let all = list(f["differences"]), shown = full ? all : Array(all.prefix(6))
        let person = f["sealed"].bool == true || f["unwaivable"].bool == true
        var journeys: [String] = []; for d in all { let j = text(d["journey"]); if !j.isEmpty && !journeys.contains(j) { journeys.append(j) } }
        let reason = [text(f["unwaivableWhy"]), text(f["sealedBy"]["why"]), "A person has to look at this one."].first { !$0.isEmpty }!
        return object([("id", .string(text(f["id"]))), ("title", .string(plainTitle(text(f["title"], "Something changed.")))), ("needsPerson", .bool(person)), ("needsPersonWhy", .string(person ? reason : "")), ("count", .number(max(max(number(f["count"], Double(all.count)), Double(all.count)), 1))), ("changes", .array(shown.map { d in
            let kind = text(d["kind"]), what = text(d["describe"]).isEmpty ? text(d["path"]) : text(d["describe"])
            return object([("what", .string(what)), ("before", valueText(d["reference"], full: full)), ("after", valueText(d["candidate"], full: full)), ("kind", .string(["appeared", "vanished"].contains(kind) ? kind : "changed"))])
        })), ("more", .number(Double(max(0, all.count - shown.count)))), ("journeys", .array(journeys.map(NativeRPCValue.string)))])
    }
    public static func results(_ raw: NativeRPCValue, at: String? = nil, full: Bool = false) -> NativeRPCValue {
        let coverage = raw["coverage"], reference = raw["reference"], candidate = raw["candidate"]
        let gaps = list(coverage["gaps"]).map { object([("what", .string(text($0["what"]))), ("why", .string(text($0["why"]))), ("unlockedBy", .string(text($0["unlockedBy"])))] ) }.filter { !text($0["what"]).isEmpty }
        var result = object([("runId", .string(text(raw["runId"]))), ("at", .string(text(raw["startedAt"], at ?? "1970-01-01T00:00:00.000Z"))), ("durationMs", .number(number(raw["durationMs"]))), ("against", text(reference["id"]).isEmpty ? .null : .string(buildName(reference))), ("checked", .string(buildName(candidate))), ("detail", .string(text(raw["summary"]))), ("gaps", .array(gaps))])
        if !text(raw["error"]["message"]).isEmpty || raw["blocked"].bool == true {
            let why = [text(raw["error"]["message"]), text(list(coverage["gaps"]).first?["why"] ?? .missing), text(raw["summary"]), "The check could not run."].first { !$0.isEmpty }!
            let hint = text(raw["error"]["hint"])
            return result.merging(object([("verdict", .string("could-not-run")), ("headline", .string(why + (hint.isEmpty ? "" : " " + hint))), ("differences", .array([])), ("unchanged", .string("")), ("notChecked", .null), ("unsteady", .number(0))]))
        }
        let differences = list(raw["findings"]).map { difference($0, full: full) }, shown = differences.reduce(0) { $0 + number($1["count"]) }
        let paths = number(coverage["paths"]), unsteady = list(raw["newlyUnstable"]).count
        let notCompared = text(reference["id"]).isEmpty || raw["comparedNothing"].string != nil
        let verdict: String, headline: String
        if notCompared {
            verdict = "not-compared"; headline = text(reference["id"]).isEmpty ? "Nothing to compare against yet. Mark this build as good to start." : "Nothing was compared: the good build never walked these steps. Mark this build as good to start."
        } else if differences.isEmpty && unsteady == 0 { verdict = "clean"; headline = "Nothing that worked has changed." }
        else {
            verdict = "differences"; var parts: [String] = []
            if !differences.isEmpty { parts.append(plural(Double(differences.count), "difference") + " nobody asked for") }
            if unsteady > 0 { parts.append(plural(Double(unsteady), "thing") + " that used to give one answer and now gives two") }
            headline = parts.joined(separator: ", and ") + "."
        }
        let unchanged = notCompared || paths == 0 ? "" : differences.isEmpty ? "All \(plural(paths, "thing")) it looked at \(paths == 1 ? "is" : "are") unchanged." : "Everything else it looked at — \(plural(max(0, paths - shown), "thing")) — is unchanged."
        result = result.merging(object([("verdict", .string(verdict)), ("headline", .string(headline)), ("differences", .array(differences)), ("unchanged", .string(unchanged)), ("notChecked", notChecked(coverage, doors: number(raw["doorsNeverOpened"]))), ("unsteady", .number(Double(unsteady)))]))
        return result
    }
    static func gap(_ name: String, _ need: NativeRPCValue, person: Bool? = nil) -> NativeRPCValue {
        object([("name", .string(name)), ("what", .string(text(need["what"]))), ("why", .string(text(need["why"]))), ("fix", .string(text(need["fix"]))), ("byPerson", .bool(person ?? (need["automatic"].bool == false || ["a person", "you"].contains(text(need["who"]))))), ("unlocks", .string(text(need["unlocks"])))] )
    }
    static func shipStep(_ need: NativeRPCValue) -> Bool { text(need["fix"]).contains("staysfixed ship") }
    public static func readiness(_ raw: NativeRPCValue, plan: Bool) -> NativeRPCValue {
        let source = plan ? raw["plan"] : raw
        var ready: [String] = [], gaps: [NativeRPCValue] = [], notHere: [String] = []
        for surface in list(source[plan ? "readiness" : "surfaces"]) {
            let name = plan ? text(surface["product"], text(surface["kind"])) : text(surface["name"], text(surface["id"]))
            let state = text(surface["state"]), needs = list(surface["needs"]).filter { !shipStep($0) }
            if state == "ready" { ready.append(name) }
            else if state == "not possible here" { notHere.append(name) }
            if plan || (state != "ready" && state != "not possible here") {
                gaps += needs.map { gap(name, $0, person: $0["automatic"].bool == false || state == "only a person can do this") }
                if !plan && needs.isEmpty { ready.append(name) }
            }
        }
        if plan {
            let seen = Set(gaps.map { text($0["what"]) + "|" + text($0["fix"]) })
            for need in list(source["needs"]["person"]) where !shipStep(need) && !seen.contains(text(need["what"]) + "|" + text(need["fix"])) { gaps.append(gap("this project", need, person: true)) }
        } else if raw["project"]["isGitRepo"].bool == false {
            gaps.insert(object([("name", .string("this folder")), ("what", .string("a git repository")), ("why", .string("Stays Fixed puts an old build back with git to compare against it, and refuses a folder with no git rather than compare against a guess.")), ("fix", .string("git init")), ("byPerson", .bool(false)), ("unlocks", .string("Every check in this folder."))]), at: 0)
        }
        return object([("ready", .array(ready.map(NativeRPCValue.string))), ("gaps", .array(gaps)), ("notHere", .array(notHere.map(NativeRPCValue.string))), ("summary", .string(text(source["covers"]["short"]))), ("git", plan ? .null : raw["project"]["isGitRepo"].bool.map(NativeRPCValue.bool) ?? .null)])
    }
    public static func setup(_ raw: NativeRPCValue, roots: [String], failure: String?) -> NativeRPCValue {
        if raw.fields?.isEmpty != false, let failure { return object([("ok", .bool(false)), ("wrote", .array([])), ("problem", .string(failure)), ("readiness", .null)]) }
        let problems = list(raw["problems"]).map { $0.string ?? text($0["message"], text($0["what"])) }.filter { !$0.isEmpty }
        let wrote = list(raw["written"]).compactMap(\.string).filter { !$0.isEmpty }.map { path in
            if let root = roots.first(where: { path.hasPrefix($0 + "/") }) { return String(path.dropFirst(root.count + 1)) }; return path
        }
        let engineError = raw["error"].string ?? text(raw["error"]["message"], text(raw["message"]))
        let hint = text(raw["error"]["hint"], text(raw["hint"]))
        // Legacy captured successful payloads may omit ok. The live service
        // requires ok == true; an explicit error or failed run is never ready.
        let ok = raw["ok"].bool != false && raw["error"].isNullish && problems.isEmpty && failure == nil
        let detail = !problems.isEmpty ? problems.joined(separator: " ") : !engineError.isEmpty ? engineError : failure ?? "Set up did not finish."
        let problem = [detail, hint, "Try setup again. If settings were saved, use Finish setup."].filter { !$0.isEmpty }.joined(separator: " ")
        return object([("ok", .bool(ok)), ("wrote", .array(wrote.map(NativeRPCValue.string))), ("problem", ok ? .null : .string(problem)), ("readiness", !ok || raw["plan"].fields?.isEmpty != false ? .null : readiness(raw, plan: true))])
    }
    public static func mark(_ raw: NativeRPCValue, failure: String?) -> NativeRPCValue {
        if raw.fields?.isEmpty != false { return object([("ok", .bool(false)), ("marked", .bool(false)), ("already", .bool(false)), ("refused", .null), ("refusedFor", .null), ("summary", .string(failure ?? "It could not be marked."))]) }
        let decision = raw["decision"], state = text(decision["state"]), marked = raw["cut"].bool == true, already = raw["unchanged"].bool == true || state == "already-the-reference"
        let refused = marked || already ? "" : (text(raw["refused"]).isEmpty ? text(decision["refusal"]) : text(raw["refused"]))
        let for_ = refused.isEmpty ? nil : state == "broken" ? "differences" : "unchecked"
        let summary: String
        if marked { summary = "Marked as good. Every check from now on compares against this build." }
        else if already { summary = "This build is already the one marked as good." }
        else if for_ == "differences" { let n = number(decision["findings"]); summary = "The last check found \(n > 0 ? plural(n, "difference") : "differences") nobody asked for. Marking this build as good makes \(n == 1 ? "it" : "them") the new normal." }
        else if state == "blocked" { summary = "The last check of this build could not run. Run a check first, then mark it as good." }
        else if state == "nothing-observed" { summary = "The last check of this build looked at nothing. Run a check first, then mark it as good." }
        else { summary = "This build has not been checked yet. Run a check first, then mark it as good." }
        return object([("ok", .bool(raw["ok"].bool != false)), ("marked", .bool(marked)), ("already", .bool(already)), ("refused", refused.isEmpty ? .null : .string(refused)), ("refusedFor", nullable(for_)), ("summary", .string(summary))])
    }
    public static func description(_ raw: NativeRPCValue) -> NativeRPCValue {
        let ref = raw["reference"], id = text(ref["buildId"])
        return object([("product", text(raw["product"]).isEmpty ? .null : raw["product"]), ("guards", .array(list(raw["guards"]).map { object([("name", .string(text($0["name"]))), ("because", .string(text($0["because"]))), ("file", .string(text($0["file"])))] ) }.filter { !text($0["name"]).isEmpty })), ("guardProblem", text(raw["guardProblem"]).isEmpty ? .null : raw["guardProblem"]), ("reference", id.isEmpty ? .null : object([("buildId", .string(id)), ("name", .string(buildName(ref.setting("id", .string(id))))), ("setAt", .string(text(ref["setAt"]))), ("setBy", .string(text(ref["setBy"]))), ("forced", .bool(ref["forced"].bool == true))]))])
    }
    public static func lastRun(_ bytes: String, full: Bool = false) -> (NativeRPCValue, NativeRPCValue)? {
        guard let record = try? NativeRPCValue.parseJSON(Data(bytes.utf8)) else { return nil }
        let raw = record["result"].string.flatMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) } ?? record["result"]
        guard raw.fields?.isEmpty == false else { return nil }; return (results(raw, at: record["at"].string, full: full), raw)
    }
    public static func pictures(_ difference: NativeRPCValue, files: [String], candidate: String, reference: String?) -> [(String, String?, String?)] {
        list(difference["journeys"]).compactMap(\.string).prefix(2).compactMap { journey in
            let tag = "-" + fileSafe(journey) + "-"
            func of(_ build: String) -> [String] { files.filter { $0.hasSuffix(".png") && $0.hasPrefix(fileSafe(build) + "-") && $0.contains(tag) }.sorted() }
            let mine = of(candidate), after = mine.first { $0.hasPrefix(fileSafe(candidate) + "-a-") } ?? mine.first
            let before = reference != nil && reference != candidate ? of(reference!).first : nil
            return after == nil && before == nil ? nil : (journey, before, after)
        }
    }
}
