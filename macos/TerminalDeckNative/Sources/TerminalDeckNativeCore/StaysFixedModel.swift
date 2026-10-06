import Foundation

// Stays Fixed, as the page reads it: the types and readers of
// src/renderer/staysfixed/bridge.ts and the wording of model.ts, ported one for
// one. Every reader fills a missing field with its empty value rather than failing.

public enum FixedVerdict: String, Equatable, Sendable {
    case clean, differences, notCompared = "not-compared", couldNotRun = "could-not-run"
}

public enum FixedTone: String, Equatable, Sendable {
    case positive, warning, critical, muted
}

public struct FixedChange: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case changed, appeared, vanished }
    public var what: String
    public var before: String?
    public var after: String?
    public var kind: Kind
    public init(what: String, before: String?, after: String?, kind: Kind) {
        self.what = what; self.before = before; self.after = after; self.kind = kind
    }
}

public struct FixedDifference: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var needsPerson: Bool
    public var needsPersonWhy: String
    public var count: Int
    public var changes: [FixedChange]
    public var more: Int
}

public struct FixedPicture: Equatable, Sendable {
    public var journey: String
    /// `data:image/png;base64,…`, or nil when that side was not kept.
    public var before: String?
    public var after: String?
}

public struct FixedResultGap: Equatable, Sendable {
    public var what: String
    public var why: String
    public var unlockedBy: String
}

public struct FixedResults: Equatable, Sendable {
    public var runId: String
    public var at: String
    public var durationMs: Double
    public var verdict: FixedVerdict
    public var headline: String
    public var against: String?
    public var checked: String
    public var differences: [FixedDifference]
    public var unchanged: String
    public var notChecked: String?
    public var unsteady: Double
    public var detail: String
    public var gaps: [FixedResultGap]
    public var pictures: [String: [FixedPicture]]
}

public struct FixedProgress: Equatable, Sendable {
    /// Milliseconds since 1970.
    public var startedAt: Double
    public var step: String
    public var steps: Double
    public var by: String
    public init(startedAt: Double, step: String, steps: Double, by: String) {
        self.startedAt = startedAt; self.step = step; self.steps = steps; self.by = by
    }
}

public struct FixedGuard: Equatable, Sendable {
    public var name: String
    public var because: String
}

public struct FixedReference: Equatable, Sendable {
    public var name: String
    public var setAt: String
    public var forced: Bool
    public init(name: String, setAt: String, forced: Bool) {
        self.name = name; self.setAt = setAt; self.forced = forced
    }
}

public struct StaysFixedStatus: Equatable, Sendable {
    public var projectPath: String
    public var available: Bool
    public var unavailable: String?
    public var versionNote: String
    public var setUp: Bool
    public var configFile: String?
    public var git: Bool
    public var agents: Bool
    public var guards: [FixedGuard]
    public var guardProblem: String?
    public var reference: FixedReference?
    public var last: FixedResults?
    public var running: FixedProgress?
}

public struct FixedGap: Equatable, Sendable {
    public var name: String
    public var what: String
    public var why: String
    public var fix: String
    public var byPerson: Bool
    public var unlocks: String
}

public struct FixedReadiness: Equatable, Sendable {
    public var ready: [String]
    public var gaps: [FixedGap]
    public var notHere: [String]
    public var summary: String
    public var git: Bool?
}

public struct FixedSetupOutcome: Equatable, Sendable {
    public var ok: Bool
    public var wrote: [String]
    public var problem: String?
}

public struct FixedMarkOutcome: Equatable, Sendable {
    public enum RefusedFor: String, Equatable, Sendable { case differences, unchecked }
    public var ok: Bool
    public var marked: Bool
    public var already: Bool
    public var refused: String?
    public var refusedFor: RefusedFor?
    public var summary: String
    public init(ok: Bool, marked: Bool, already: Bool, refused: String?, refusedFor: RefusedFor?, summary: String) {
        self.ok = ok; self.marked = marked; self.already = already
        self.refused = refused; self.refusedFor = refusedFor; self.summary = summary
    }
}

// MARK: - Readers (bridge.ts)

private func obj(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func arr(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func str(_ value: Any?, _ fallback: String = "") -> String { value as? String ?? fallback }
private func strOrNil(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
}
private func num(_ value: Any?) -> Double {
    guard let n = value as? NSNumber, !(value is Bool), n.doubleValue.isFinite else { return 0 }
    return n.doubleValue
}
private func flag(_ value: Any?) -> Bool { (value as? Bool) == true }

public enum StaysFixedWire {
    public static let status = "staysfixed:status"
    public static let readiness = "staysfixed:readiness"
    public static let setup = "staysfixed:setup"
    public static let check = "staysfixed:check"
    public static let stop = "staysfixed:stop"
    public static let results = "staysfixed:results"
    public static let markGood = "staysfixed:mark-good"
    public static let agents = "staysfixed:agents"
    /// Event: `(projectPath)` when anything about a project's checks changed.
    public static let changed = "staysfixed:changed"

    public static func results(_ value: Any?) -> FixedResults? {
        let v = obj(value)
        if v.isEmpty { return nil }
        var pictures: [String: [FixedPicture]] = [:]
        for (id, list) in obj(v["pictures"]) {
            pictures[id] = arr(list).map(obj).map {
                FixedPicture(journey: str($0["journey"]), before: strOrNil($0["before"]), after: strOrNil($0["after"]))
            }
        }
        return FixedResults(
            runId: str(v["runId"]),
            at: str(v["at"]),
            durationMs: num(v["durationMs"]),
            verdict: FixedVerdict(rawValue: str(v["verdict"])) ?? .couldNotRun,
            headline: str(v["headline"]),
            against: strOrNil(v["against"]),
            checked: str(v["checked"]),
            differences: arr(v["differences"]).map(obj).map { d in
                FixedDifference(
                    id: str(d["id"]),
                    title: str(d["title"]),
                    needsPerson: flag(d["needsPerson"]),
                    needsPersonWhy: str(d["needsPersonWhy"]),
                    count: max(1, Int(num(d["count"]))),
                    changes: arr(d["changes"]).map(obj).map { c in
                        let kind = FixedChange.Kind(rawValue: str(c["kind"]))
                        return FixedChange(what: str(c["what"]), before: strOrNil(c["before"]), after: strOrNil(c["after"]),
                                           kind: kind == .appeared || kind == .vanished ? kind! : .changed)
                    },
                    more: Int(num(d["more"])))
            },
            unchanged: str(v["unchanged"]),
            notChecked: strOrNil(v["notChecked"]),
            unsteady: num(v["unsteady"]),
            detail: str(v["detail"]),
            gaps: arr(v["gaps"]).map(obj).map {
                FixedResultGap(what: str($0["what"]), why: str($0["why"]), unlockedBy: str($0["unlockedBy"]))
            },
            pictures: pictures)
    }

    public static func progress(_ value: Any?) -> FixedProgress? {
        let v = obj(value)
        if v.isEmpty { return nil }
        return FixedProgress(startedAt: num(v["startedAt"]), step: str(v["step"]), steps: num(v["steps"]), by: str(v["by"], "you"))
    }

    public static func status(_ value: Any?, projectPath: String) -> StaysFixedStatus {
        let v = obj(value)
        let reference = obj(v["reference"])
        return StaysFixedStatus(
            projectPath: str(v["projectPath"], projectPath),
            available: flag(v["available"]),
            unavailable: strOrNil(v["unavailable"]),
            versionNote: str(v["versionNote"]),
            setUp: flag(v["setUp"]),
            configFile: strOrNil(v["configFile"]),
            git: (v["git"] as? Bool) != false,
            agents: flag(v["agents"]),
            guards: arr(v["guards"]).map(obj).map { FixedGuard(name: str($0["name"]), because: str($0["because"])) }
                .filter { !$0.name.isEmpty },
            guardProblem: strOrNil(v["guardProblem"]),
            reference: reference.isEmpty ? nil
                : FixedReference(name: str(reference["name"], "a build"), setAt: str(reference["setAt"]), forced: flag(reference["forced"])),
            last: results(v["last"]),
            running: progress(v["running"]))
    }

    public static func readiness(_ value: Any?) -> (readiness: FixedReadiness?, message: String?) {
        let v = obj(value)
        if !flag(v["ok"]) { return (nil, str(v["message"], "This could not be worked out.")) }
        let r = obj(v["readiness"])
        return (FixedReadiness(
            ready: arr(r["ready"]).map { str($0) }.filter { !$0.isEmpty },
            gaps: arr(r["gaps"]).map(obj).map {
                FixedGap(name: str($0["name"]), what: str($0["what"]), why: str($0["why"]), fix: str($0["fix"]),
                         byPerson: flag($0["byPerson"]), unlocks: str($0["unlocks"]))
            },
            notHere: arr(r["notHere"]).map { str($0) }.filter { !$0.isEmpty },
            summary: str(r["summary"]),
            git: r["git"] as? Bool), nil)
    }

    public static func setup(_ value: Any?) -> FixedSetupOutcome {
        let v = obj(value)
        let ok = flag(v["ok"])
        return FixedSetupOutcome(ok: ok, wrote: arr(v["wrote"]).map { str($0) }.filter { !$0.isEmpty },
                                 problem: strOrNil(v["problem"]) ?? (ok ? nil : "Set up did not finish."))
    }

    public static func mark(_ value: Any?) -> FixedMarkOutcome {
        let v = obj(value)
        return FixedMarkOutcome(ok: flag(v["ok"]), marked: flag(v["marked"]), already: flag(v["already"]),
                                refused: strOrNil(v["refused"]),
                                refusedFor: FixedMarkOutcome.RefusedFor(rawValue: str(v["refusedFor"])),
                                summary: str(v["summary"], "It could not be marked."))
    }

    public static func check(_ value: Any?) -> (results: FixedResults?, message: String?) {
        let v = obj(value)
        if flag(v["ok"]) { return (results(v["results"]), nil) }
        return (nil, str(v["message"], "The check could not start."))
    }
}

// MARK: - Wording (model.ts)

public enum StaysFixedRules {
    public static let name = "Stays Fixed"
    /// `STAYS_FIXED_AGENTS` (src/shared/stays-fixed.ts) by their catalogue labels.
    public static let agentLabels = ["Claude Code", "Codex CLI", "Gemini CLI"]

    public static func listWords(_ items: [String]) -> String {
        if items.count <= 1 { return items.first ?? "" }
        return "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
    }

    public static func agentNames() -> String { listWords(agentLabels) }

    public static func verdictTone(_ verdict: FixedVerdict?) -> FixedTone {
        switch verdict {
        case .clean: return .positive
        case .differences: return .warning
        case .couldNotRun: return .critical
        default: return .muted
        }
    }

    /// An ISO date as milliseconds since 1970, or nil — `Date.parse`.
    public static func parse(_ text: String) -> Double? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? plain.date(from: text) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    public static func markedSinceLastCheck(_ status: StaysFixedStatus) -> Bool {
        guard let last = status.last, let reference = status.reference,
              let marked = parse(reference.setAt), let checked = parse(last.at) else { return false }
        return marked >= checked
    }

    public static func headline(_ status: StaysFixedStatus) -> String {
        if status.running != nil { return "Checking…" }
        guard let last = status.last else { return "Not checked yet." }
        if markedSinceLastCheck(status) {
            if last.verdict == .differences { return "Marked as good, with these differences as the new normal." }
            if last.verdict == .notCompared { return "Ready. Run a check after your next change." }
        }
        return last.headline
    }

    public static func statusTone(_ status: StaysFixedStatus) -> FixedTone {
        if status.running != nil { return .muted }
        let verdict = status.last?.verdict
        if (verdict == .differences || verdict == .notCompared) && markedSinceLastCheck(status) { return .positive }
        return verdictTone(verdict)
    }

    public static func subline(_ status: StaysFixedStatus, now: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let last = status.last, status.running == nil, let at = parse(last.at), at > 0 {
            parts.append("Checked \(ArtifactRules.relativeTime(at, now: now, locale: locale, timeZone: timeZone))")
        }
        if let reference = status.reference {
            let when = parse(reference.setAt).flatMap { $0 > 0 ? $0 : nil }
                .map { ", marked \(ArtifactRules.relativeTime($0, now: now, locale: locale, timeZone: timeZone))" } ?? ""
            parts.append("Good build: \(reference.name)\(when)")
        } else {
            parts.append("No build is marked as good yet")
        }
        return parts.joined(separator: " · ")
    }

    public static func elapsed(_ ms: Double) -> String {
        let seconds = max(0, Int((ms / 1000).rounded(.down)))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    public static func startedBy(_ progress: FixedProgress) -> String {
        progress.by == "you" || progress.by.isEmpty ? "You started this check" : "\(progress.by) started this check"
    }

    public static func pictures(_ results: FixedResults, _ id: String) -> [FixedPicture] { results.pictures[id] ?? [] }

    public static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? "\(one)s"))"
    }

    public static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The tone of a mark answer's note (`MarkNote`).
    public static func markTone(_ mark: FixedMarkOutcome) -> FixedTone {
        if mark.marked || mark.already { return .positive }
        return mark.refusedFor == .differences ? .warning : .muted
    }

    /// The image bytes of a `data:image/…;base64,…` picture.
    public static func pictureData(_ url: String?) -> Data? {
        guard let url, url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }
}
