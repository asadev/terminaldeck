import Foundation

// The usage reading on a session's bar (`shell/UsageBar.tsx`, `usage-bar-model.ts`,
// `useUsageBar.ts`, `usage-reach.ts`): the context window as a strip, and the plan
// limits behind a ring, each opening a panel on hover and holding it on a press.

public enum UsageLevel: String, Sendable { case ok, warning, critical }

public enum UsageFormat {
    /// `LIMIT_WARNING_PERCENT` / `LIMIT_CRITICAL_PERCENT`.
    public static func level(_ percent: Double?) -> UsageLevel {
        guard let percent, percent.isFinite else { return .ok }
        return percent >= 90 ? .critical : percent >= 70 ? .warning : .ok
    }

    /// `formatPercent` (usage-model): "<1%" for a sliver, whole numbers otherwise.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// `formatTokens`.
    public static func tokens(_ value: Double) -> String { InsightsFormat.tokens(value) }

    /// `describeAge`.
    public static func age(_ capturedAt: Double, now: Double) -> String {
        guard capturedAt > 0 else { return "" }
        let age = now - capturedAt
        let minute = 60_000.0, hour = 3_600_000.0
        if age < 2 * minute { return "just now" }
        if age < hour { return "\(Int((age / minute).rounded()))m ago" }
        if age < 24 * hour { return "\(Int((age / hour).rounded()))h ago" }
        return "\(Int((age / (24 * hour)).rounded()))d ago"
    }
}

public struct UsageAccountRef: Equatable, Sendable {
    public let provider: String?
    public let id: String?
    public let name: String?

    public init(provider: String?, id: String?, name: String?) {
        self.provider = provider
        self.id = id
        self.name = name
    }
}

public struct UsageWindowReading: Equatable, Sendable, Identifiable {
    public enum Window: String, Sendable { case fiveHour = "five-hour", weekly, monthly, other }
    public enum Reset: Equatable, Sendable { case at(Double), described(String), notReported }
    public let id: String
    public let account: UsageAccountRef
    public let window: Window
    public let windowMinutes: Double?
    public let label: String
    /// The fraction used, nil when not reported.
    public let used: Double?
    public let resets: Reset
    public let observedAt: Double
    public let reportedAt: Double
    public let source: String

    public init(id: String, account: UsageAccountRef = UsageAccountRef(provider: nil, id: nil, name: nil), window: Window,
                windowMinutes: Double? = nil, label: String = "", used: Double?, resets: Reset, observedAt: Double = 0,
                reportedAt: Double = 0, source: String = "claude-usage-api") {
        self.id = id
        self.account = account
        self.window = window
        self.windowMinutes = windowMinutes
        self.label = label
        self.used = used
        self.resets = resets
        self.observedAt = observedAt
        self.reportedAt = reportedAt
        self.source = source
    }

    static let sources: Set<String> = ["claude-usage-panel", "claude-warning", "claude-usage-api", "codex-rollout"]

    static func decode(_ raw: Any) -> UsageWindowReading? {
        guard let r = raw as? [String: Any], let id = TerminalJSON.text(r["id"]),
              let source = r["source"] as? String, sources.contains(source) else { return nil }
        let used: Double? = {
            guard let u = r["used"] as? [String: Any], u["state"] as? String == "reported",
                  let f = TerminalJSON.number(u["fraction"]), f >= 0 else { return nil }
            return f
        }()
        let resets: Reset = {
            guard let x = r["resets"] as? [String: Any] else { return .notReported }
            if x["state"] as? String == "at", let at = TerminalJSON.number(x["at"]), at > 0 { return .at(at) }
            if x["state"] as? String == "described",
               let text = (x["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty { return .described(text) }
            return .notReported
        }()
        let observed = TerminalJSON.number(r["observedAt"]) ?? 0
        let reported = TerminalJSON.number(r["reportedAt"]) ?? 0
        return UsageWindowReading(id: id, account: UsageReport.account(r["account"]),
                                  window: (r["window"] as? String).flatMap(Window.init(rawValue:)) ?? .other,
                                  windowMinutes: TerminalJSON.number(r["windowMinutes"]), label: r["label"] as? String ?? "",
                                  used: used, resets: resets, observedAt: observed, reportedAt: reported == 0 ? observed : reported,
                                  source: source)
    }

    /// `shortWindowName`.
    public var short: String {
        switch window {
        case .fiveHour: return "5h"
        case .weekly: return "Week"
        case .monthly: return "30d"
        case .other:
            if let minutes = windowMinutes, minutes > 0 {
                let m = Int(minutes)
                if m % 1440 == 0 { return "\(m / 1440)d" }
                if m % 60 == 0 { return "\(m / 60)h" }
                return "\(m)m"
            }
            return label.isEmpty ? "Limit" : label
        }
    }

    var nominalMinutes: Double? {
        switch window {
        case .fiveHour: return 300
        case .weekly: return 10080
        case .monthly: return 43200
        case .other: return nil
        }
    }
}

public struct UsageReport: Equatable, Sendable {
    public let sessionId: String?
    public let readings: [UsageWindowReading]
    public let reason: String?
    public let account: UsageAccountRef?

    public init(sessionId: String? = nil, readings: [UsageWindowReading], reason: String? = nil, account: UsageAccountRef? = nil) {
        self.sessionId = sessionId
        self.readings = readings
        self.reason = reason
        self.account = account
    }

    /// `readUsageReport`.
    public static func decode(_ raw: Any?) -> UsageReport? {
        guard let r = raw as? [String: Any], let rows = r["readings"] as? [Any] else { return nil }
        return UsageReport(sessionId: TerminalJSON.text(r["sessionId"]), readings: rows.compactMap(UsageWindowReading.decode),
                           reason: TerminalJSON.text(r["reason"]),
                           account: r["account"] is [String: Any] ? account(r["account"]) : nil)
    }

    static func account(_ raw: Any?) -> UsageAccountRef {
        let r = raw as? [String: Any] ?? [:]
        let provider = (r["provider"] as? String).flatMap { ["claude", "codex", "gemini", "shell"].contains($0) || $0.hasPrefix("custom:") ? $0 : nil }
        return UsageAccountRef(provider: provider, id: TerminalJSON.text(r["id"]), name: TerminalJSON.text(r["name"]))
    }

    /// `reportedAccount`: whose limits these are, when the report names someone.
    public var reportedAccount: UsageAccountRef? {
        let ref = readings.first?.account ?? account
        guard let ref, ref.id != nil || ref.name != nil else { return nil }
        return ref
    }
}

/// One window's line (`UsageReadout`).
public struct UsageReadout: Equatable, Sendable {
    public enum State: String, Sendable { case live, aged, expired, noReset = "no-reset", unmeasured }
    public let reading: UsageWindowReading
    public let state: State
    public let bar: Bool
    public let percent: Double?
    public let level: UsageLevel
    public let value: String
    public let reset: String?
    public let age: String
    public let detail: String

    public var name: String { reading.label.isEmpty ? reading.short : reading.label }

    /// The facts under a row with a bar.
    public var facts: String {
        [reset.map { "Renews \($0)" }, age.isEmpty ? nil : "read \(age)"].compactMap { $0 }.joined(separator: " · ")
    }

    /// `usageReadout`. `resetText` formats an instant as the page does (time today, date and time further off).
    public static func of(_ reading: UsageWindowReading, now: Double, format: (Double, Double) -> String = UsageReadout.resetInstant) -> UsageReadout {
        let reset: String? = {
            switch reading.resets {
            case .at(let at): return format(at, now)
            case .described(let text): return text
            case .notReported: return nil
            }
        }()
        let age = UsageFormat.age(reading.reportedAt, now: now)
        if case .at(let at) = reading.resets, at <= now {
            let last = reading.used.map { "Last \(UsageFormat.percent($0 * 100))\(age.isEmpty ? "" : " \(age)")" } ?? ""
            return UsageReadout(reading: reading, state: .expired, bar: false, percent: nil, level: .ok, value: "Not reported",
                                reset: reset, age: age,
                                detail: [last, reset.map { "reset \($0)" } ?? "window reset"].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        guard let fraction = reading.used else {
            return UsageReadout(reading: reading, state: .unmeasured, bar: false, percent: nil, level: .ok, value: "Not reported",
                                reset: reset, age: age, detail: reset.map { "Renews \($0)" } ?? "")
        }
        let percent = fraction * 100
        let shown = UsageFormat.percent(percent)
        guard let reset else {
            return UsageReadout(reading: reading, state: .noReset, bar: true, percent: percent, level: UsageFormat.level(percent),
                                value: shown, reset: nil, age: age,
                                detail: ["\(shown) used", age.isEmpty ? "" : "read \(age)"].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        let minutes = reading.windowMinutes ?? reading.nominalMinutes
        let drifted = minutes.map { now - reading.reportedAt > $0 * 60_000 / 12 } ?? false
        return UsageReadout(reading: reading, state: drifted ? .aged : .live, bar: true, percent: percent,
                            level: UsageFormat.level(percent), value: shown, reset: reset, age: age,
                            detail: ["\(shown) used", "renews \(reset)", age.isEmpty ? "" : "read \(age)"].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// `formatResetInstant`: the time when it is within 18 hours, else the date and the time.
    public static func resetInstant(_ at: Double, _ now: Double) -> String {
        let date = Date(timeIntervalSince1970: at / 1000)
        let time = date.formatted(date: .omitted, time: .shortened)
        if abs(at - now) < 18 * 3_600_000 { return time }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }
}

/// The context window as the agent last wrote it (`ContextReading`).
public struct ContextReading: Equatable, Sendable {
    public enum State: String, Sendable { case ok, nothingYet = "nothing-yet", notReported = "not-reported" }
    public let state: State
    public let tokens: Double?
    public let window: Double?
    public let percent: Double?
    public let windowBasis: String?
    public let model: String?
    public let modelLabel: String?
    public let sessionId: String?
    public let inferred: Bool
    public let rivals: Int
    public let reportedAt: Double

    public init(state: State, tokens: Double?, window: Double?, percent: Double?, windowBasis: String? = nil, model: String? = nil,
                modelLabel: String? = nil, sessionId: String? = nil, inferred: Bool = false, rivals: Int = 0, reportedAt: Double) {
        self.state = state
        self.tokens = tokens
        self.window = window
        self.percent = percent
        self.windowBasis = windowBasis
        self.model = model
        self.modelLabel = modelLabel
        self.sessionId = sessionId
        self.inferred = inferred
        self.rivals = rivals
        self.reportedAt = reportedAt
    }

    /// `readContextReading`.
    public static func decode(_ raw: Any?) -> ContextReading? {
        guard let r = raw as? [String: Any], let state = (r["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        let source = r["source"] as? [String: Any]
        let observed = TerminalJSON.number(r["observedAt"]) ?? 0
        let reported = TerminalJSON.number(r["reportedAt"]) ?? 0
        return ContextReading(state: state, tokens: TerminalJSON.number(r["tokens"]), window: TerminalJSON.number(r["window"]),
                              percent: TerminalJSON.number(r["percent"]),
                              windowBasis: (r["windowBasis"] as? String).flatMap { ["model", "observed", "reported"].contains($0) ? $0 : nil },
                              model: TerminalJSON.text(r["model"]), modelLabel: TerminalJSON.text(r["modelLabel"]),
                              sessionId: TerminalJSON.text(source?["sessionId"]), inferred: source?["chosen"] as? String == "inferred",
                              rivals: TerminalJSON.int(source?["rivals"]) ?? 0, reportedAt: reported == 0 ? observed : reported)
    }

    var counted: Bool { state == .ok && tokens != nil }

    /// `contextIsFresh`: only a figure written just now is shown on the bar.
    public func isFresh(now: Double) -> Bool { counted && UsageFormat.age(reportedAt, now: now) == "just now" }

    /// `contextShare`: the strip's fill, clamped.
    public var share: Double? {
        guard state == .ok, let percent else { return nil }
        return max(0, min(100, percent))
    }

    public var level: UsageLevel { UsageFormat.level(state == .ok ? percent : nil) }

    /// `contextFigure`: "142k", or "142k" without decimals when compact.
    public func figure(compact: Bool = false) -> String? {
        guard counted, let tokens else { return nil }
        let full = UsageFormat.tokens(tokens)
        return compact ? full.replacingOccurrences(of: #"\.\d+(?=[kMB]$)"#, with: "", options: .regularExpression) : full
    }

    /// `contextProvenance`.
    public func provenance(now: Double) -> String {
        var parts: [String] = []
        if let model { parts.append("Model \(model).") }
        if let sessionId {
            let how = inferred ? ", which this app picked as the folder’s most recent conversation rather than being told" : ""
            parts.append("Read from session \(sessionId)\(how).")
        }
        if rivals > 0 {
            parts.append(rivals == 1
                ? "One other conversation was active in this folder at the same time, so this may be that one’s."
                : "\(rivals) other conversations were active in this folder at the same time, so this may be one of theirs.")
        }
        if windowBasis == "observed" {
            parts.append("The window is larger than this app’s table for that model, and was taken from what the transcript proves it held.")
        }
        if windowBasis == "reported" { parts.append("The window is the one the agent reports for itself.") }
        let age = UsageFormat.age(reportedAt, now: now)
        if !age.isEmpty { parts.append("The agent wrote this figure \(age == "just now" ? "just now" : age).") }
        return parts.joined(separator: " ")
    }

    /// `contextPanel`: the used/free split, the facts and where it came from.
    public func panel(now: Double) -> ContextPanel? {
        guard counted, let tokens else { return nil }
        var segments: [ContextPanel.Segment] = []
        if let window, window > 0 {
            let free = max(0, window - tokens)
            segments.append(.init(key: "used", label: "Used", amount: UsageFormat.tokens(tokens),
                                  share: UsageFormat.percent(tokens / window * 100), width: min(100, max(0, tokens / window * 100))))
            if free > 0 {
                segments.append(.init(key: "free", label: "Free", amount: UsageFormat.tokens(free),
                                      share: UsageFormat.percent(free / window * 100), width: min(100, max(0, free / window * 100))))
            }
        }
        var facts: [(String, String)] = []
        if let name = modelLabel ?? model { facts.append(("Model", name)) }
        let age = UsageFormat.age(reportedAt, now: now)
        if !age.isEmpty && age != "just now" { facts.append(("Updated", age)) }
        return ContextPanel(used: UsageFormat.tokens(tokens), window: window.map(UsageFormat.tokens),
                            share: percent.map(UsageFormat.percent), level: UsageFormat.level(percent), segments: segments,
                            facts: facts.map { .init(label: $0.0, value: $0.1) }, provenance: provenance(now: now))
    }

    /// `contextSummary`: the strip's accessible name.
    public func summary(now: Double) -> String? {
        guard let panel = panel(now: now) else { return nil }
        let head = panel.window.map { "Context \(panel.used) of \($0)\(panel.share.map { " (\($0))" } ?? "")" }
            ?? "Context \(panel.used) — no window reported"
        return panel.provenance.isEmpty ? "\(head)." : "\(head). \(panel.provenance)"
    }
}

public struct ContextPanel: Equatable, Sendable {
    public struct Segment: Equatable, Sendable { public let key, label, amount, share: String; public let width: Double }
    public struct Fact: Equatable, Sendable { public let label, value: String }
    public let used: String
    public let window: String?
    public let share: String?
    public let level: UsageLevel
    public let segments: [Segment]
    public let facts: [Fact]
    public let provenance: String

    /// The header row's value: "142k / 1M (14%)".
    public var headline: String { (window.map { "\(used) / \($0)" } ?? used) + (share.map { " (\($0))" } ?? "") }
}

/// The two panels behind the bar's controls (`nextPanelState`): hover opens, a press pins.
public struct UsagePanelState: Equatable, Sendable {
    public enum Panel: Sendable { case context, plan }
    public enum Event: Sendable { case hover(Panel), press(Panel), leave, shut }
    public var open: Panel?
    public var pinned: Bool

    public static let shut = UsagePanelState(open: nil, pinned: false)

    public func next(_ event: Event) -> UsagePanelState {
        switch event {
        case .shut: return .shut
        case .leave: return pinned ? self : .shut
        case .hover(let panel): return pinned ? self : UsagePanelState(open: panel, pinned: false)
        case .press(let panel):
            if open == panel && pinned { return .shut }
            return UsagePanelState(open: panel, pinned: true)
        }
    }

    /// `opensPlan`: opening the plan panel is the refresh.
    public static func opensPlan(_ before: UsagePanelState, _ after: UsagePanelState) -> Bool {
        after.open == .plan && before.open != .plan
    }
}

public enum UsageBarRules {
    /// `REFRESH_WAIT_CAP_MS`.
    public static let refreshCap: Double = 18
    public static let gaveUp = "The check did not come back, so the figures below are the last ones that were read. Opening this again asks once more."
    public static let serverWithheld = "This session is a terminal on a server, which is not running this app. There is no account signed in there to have limits and no transcript here to read a context window from, so nothing is shown rather than this computer’s own figures."
    public static let unwired = "Usage is not wired into this build."

    /// `refreshOutcomeMessage`.
    public static func outcomeMessage(_ outcome: String) -> String {
        switch outcome {
        case "ok": return "Read from Claude Code, in this app’s own process — no session was touched."
        case "cached": return "Read from what Claude Code had already written down — nothing was started."
        case "no-limits", "settled": return "This login has no subscription limits, so there is nothing to read."
        case "signed-out": return "That account is not signed in to Claude Code, so it has no plan limits to report."
        case "no-binary": return "Claude Code could not be started here, so its usage could not be read."
        case "unwatched": return "This session runs a different agent, so it has no Claude limits to read."
        default: return "Claude Code’s usage could not be read just now."
        }
    }

    /// What a refresh answered (`readOutcome`), and whether the answer is a settled stop.
    public static func outcome(_ raw: Any?) -> (outcome: String, detail: String, ok: Bool, settled: Bool, noLimits: Bool) {
        let r = raw as? [String: Any]
        let outcome = r?["outcome"] as? String ?? "unreadable"
        let detail = TerminalJSON.text(r?["detail"]) ?? outcomeMessage(outcome)
        return (outcome, detail, TerminalJSON.bool(r?["ok"]) == true,
                ["no-limits", "settled", "signed-out", "no-binary"].contains(outcome), outcome == "no-limits" || outcome == "settled")
    }

    /// `planStatus`.
    public static func planStatus(unwired: Bool, withheld: String?, noLimits: Bool, blocked: String?, fetching: Bool, reported: Bool) -> String {
        if unwired { return "unwired" }
        if let withheld, !withheld.isEmpty { return "withheld" }
        if noLimits { return "no-limits" }
        if blocked != nil { return "stopped" }
        if fetching { return "reading" }
        return reported ? "reported" : "nothing"
    }

    /// `panelNote`: the ⓘ beside whose limits these are, only when there is no figure to explain.
    public static func panelNote(unwired: Bool, withheld: String?, blocked: String?, failed: Bool, detail: String?, reason: String?, rows: Int) -> String? {
        if unwired { return Self.unwired }
        if let withheld, !withheld.isEmpty { return withheld }
        if let blocked { return blocked }
        if failed, let detail { return detail }
        if rows == 0 { return reason }
        return nil
    }

    /// The plan control's accessible name and the sentence the bar would say.
    public static func title(readouts: [UsageReadout], whose: String, unwired: Bool, withheld: String?, blocked: String?, report: UsageReport?) -> String {
        let nothing = unwired ? Self.unwired
            : withheld ?? blocked ?? (report == nil ? "Asking this session what it has used…" : (report?.reason ?? "Nothing has been reported for this session yet."))
        let sentence = readouts.isEmpty ? nothing : readouts.map(\.detail).joined(separator: " ")
        return whose.isEmpty ? sentence : "\(whose) — \(sentence)"
    }

    /// The window filled furthest, for the ring and its colour.
    public static func worst(_ readouts: [UsageReadout]) -> UsageReadout? {
        readouts.filter { $0.percent != nil }.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }
}
