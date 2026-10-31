import Foundation

// The Session inspector (`components/SessionInspector.tsx`, `session-transcript.ts`):
// what a session's transcript says — requests, tokens, tools, context — read over
// `insights:session` (a transcript) or `insights:latest` (a folder's newest), with
// the transcript chosen from `insights:list` the way the page chooses it.

public struct TokenUsage: Equatable, Sendable {
    public let input, output, cacheWrite5m, cacheWrite1h, cacheRead: Double
    static func decode(_ raw: Any?) -> TokenUsage {
        let r = raw as? [String: Any] ?? [:]
        func n(_ k: String) -> Double { TerminalJSON.number(r[k]) ?? 0 }
        return TokenUsage(input: n("input"), output: n("output"), cacheWrite5m: n("cacheWrite5m"), cacheWrite1h: n("cacheWrite1h"), cacheRead: n("cacheRead"))
    }
    /// Every prompt token, cache reads and writes included.
    public var prompt: Double { input + cacheRead + cacheWrite5m + cacheWrite1h }
    public var total: Double { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

public struct TimelineEntry: Equatable, Sendable, Identifiable {
    public let index: Int
    public let key: String
    public let at: Double
    public let streamMs: Double
    public let sinceLastMs: Double
    public let model: String
    public let fast: Bool
    public let promptTokens: Double
    public let outputTokens: Double
    public let totalTokens: Double
    public let contextPercent: Double?
    public let isSidechain: Bool
    public let stopReason: String?
    public let tools: [String]
    public var id: String { "\(key)-\(index)" }

    static func decode(_ raw: Any) -> TimelineEntry? {
        guard let r = raw as? [String: Any] else { return nil }
        func n(_ k: String) -> Double { TerminalJSON.number(r[k]) ?? 0 }
        return TimelineEntry(index: Int(n("index")), key: r["key"] as? String ?? "", at: n("at"), streamMs: n("streamMs"),
                             sinceLastMs: n("sinceLastMs"), model: r["model"] as? String ?? "unknown",
                             fast: r["speed"] as? String == "fast", promptTokens: n("promptTokens"), outputTokens: n("outputTokens"),
                             totalTokens: n("totalTokens"), contextPercent: TerminalJSON.number(r["contextPercent"]),
                             isSidechain: TerminalJSON.bool(r["isSidechain"]) == true, stopReason: r["stopReason"] as? String,
                             tools: (r["tools"] as? [Any] ?? []).compactMap { $0 as? String })
    }
}

public struct ToolStat: Equatable, Sendable, Identifiable {
    public let name: String
    public let server: String?
    public let calls, failures, timedCalls: Double
    public let totalMs, maxMs, avgMs, share: Double
    public var id: String { name }
}

public struct ModelStat: Equatable, Sendable, Identifiable {
    public let model: String
    public let requests: Double
    public let promptTokens, outputTokens, share: Double
    public var id: String { model }
}

public struct CompactionMarker: Equatable, Sendable {
    public let at: Double
    public let afterRequest: Int
    public let preTokens, postTokens, reclaimedTokens: Double
    public let trigger: String
    public let durationMs: Double
}

public struct ContextPoint: Equatable, Sendable {
    public let index: Int
    public let at: Double
    public let tokens: Double
    public let percent: Double
    public init(index: Int, at: Double, tokens: Double, percent: Double) {
        self.index = index
        self.at = at
        self.tokens = tokens
        self.percent = percent
    }
}

public struct ContextUsage: Equatable, Sendable {
    public let tokens, window, percent, remaining: Double
    public let level: String
}

public struct BloatWarning: Equatable, Sendable, Identifiable {
    public let kind: String
    public let level: String
    public let message: String
    public var id: String { kind }
}

public struct SessionInsights: Equatable, Sendable {
    public let sessionId: String
    public let transcriptPath: String
    public let startedAt: Double
    public let durationMs: Double
    public let generatingMs: Double
    public let toolMs: Double
    public let requests: Double
    public let timeline: [TimelineEntry]
    public let omittedRequests: Double
    public let heaviest: [TimelineEntry]
    public let tools: [ToolStat]
    public let toolCalls: Double
    public let toolFailures: Double
    public let models: [ModelStat]
    public let usage: TokenUsage
    public let cacheHitRate: Double
    public let context: ContextUsage?
    public let contextSeries: [ContextPoint]
    public let compactions: [CompactionMarker]
    public let warnings: [BloatWarning]
    public let preContextTokens: Double
    public let generatedAt: Double

    public static func decode(_ raw: Any?) -> SessionInsights? {
        guard let r = raw as? [String: Any] else { return nil }
        func n(_ k: String) -> Double { TerminalJSON.number(r[k]) ?? 0 }
        func list(_ k: String) -> [[String: Any]] { (r[k] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        func num(_ d: [String: Any], _ k: String) -> Double { TerminalJSON.number(d[k]) ?? 0 }
        let context = (r["context"] as? [String: Any]).map {
            ContextUsage(tokens: num($0, "tokens"), window: num($0, "window"), percent: num($0, "percent"),
                         remaining: num($0, "remaining"), level: $0["level"] as? String ?? "ok")
        }
        return SessionInsights(
            sessionId: r["sessionId"] as? String ?? "", transcriptPath: r["transcriptPath"] as? String ?? "",
            startedAt: n("startedAt"), durationMs: n("durationMs"), generatingMs: n("generatingMs"), toolMs: n("toolMs"),
            requests: n("requests"),
            timeline: (r["timeline"] as? [Any] ?? []).compactMap(TimelineEntry.decode),
            omittedRequests: n("omittedRequests"),
            heaviest: (r["heaviest"] as? [Any] ?? []).compactMap(TimelineEntry.decode),
            tools: list("tools").map {
                ToolStat(name: $0["name"] as? String ?? "", server: $0["server"] as? String, calls: num($0, "calls"),
                         failures: num($0, "failures"), timedCalls: num($0, "timedCalls"), totalMs: num($0, "totalMs"),
                         maxMs: num($0, "maxMs"), avgMs: num($0, "avgMs"), share: num($0, "share"))
            },
            toolCalls: n("toolCalls"), toolFailures: n("toolFailures"),
            models: list("models").map {
                ModelStat(model: $0["model"] as? String ?? "unknown", requests: num($0, "requests"),
                          promptTokens: num($0, "promptTokens"), outputTokens: num($0, "outputTokens"), share: num($0, "share"))
            },
            usage: .decode(r["usage"]), cacheHitRate: n("cacheHitRate"), context: context,
            contextSeries: list("contextSeries").map {
                ContextPoint(index: Int(num($0, "index")), at: num($0, "at"), tokens: num($0, "tokens"), percent: num($0, "percent"))
            },
            compactions: list("compactions").map {
                CompactionMarker(at: num($0, "at"), afterRequest: Int(num($0, "afterRequest")), preTokens: num($0, "preTokens"),
                                 postTokens: num($0, "postTokens"), reclaimedTokens: num($0, "reclaimedTokens"),
                                 trigger: $0["trigger"] as? String ?? "", durationMs: num($0, "durationMs"))
            },
            warnings: list("warnings").map {
                BloatWarning(kind: $0["kind"] as? String ?? "", level: $0["level"] as? String ?? "warning", message: $0["message"] as? String ?? "")
            },
            preContextTokens: n("preContextTokens"), generatedAt: n("generatedAt"))
    }

    /// The timeline shows dates once the session spans more than a day.
    public var dated: Bool { durationMs > InsightsFormat.dayMs }
}

/// The inspector's number formats (`formatTokens`, `formatDuration`, `formatClock`, `formatPercent`, …).
public enum InsightsFormat {
    public static let dayMs: Double = 24 * 60 * 60 * 1000

    public static func tokens(_ value: Double) -> String {
        let abs = Swift.abs(value)
        func trim(_ text: String) -> String {
            text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        if abs >= 999_950_000 { return trim(String(format: "%.2f", value / 1_000_000_000)) + "B" }
        if abs >= 999_950 { return trim(String(format: "%.2f", value / 1_000_000)) + "M" }
        if abs >= 1000 {
            return String(format: "%.1f", value / 1000).replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression) + "k"
        }
        return String(Int(value.rounded()))
    }

    public static func duration(_ ms: Double) -> String {
        guard ms.isFinite, ms > 0 else { return "—" }
        if ms < 1000 { return "\(Int(ms.rounded()))ms" }
        let seconds = ms / 1000
        if seconds < 60 { return seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes < 60 { return "\(minutes)m \(Int(seconds.truncatingRemainder(dividingBy: 60).rounded()))s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public static func percent(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", value)
    }

    public static func clock(_ at: Double, withDate: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard at != 0 else { return "—" }
        let date = Date(timeIntervalSince1970: at / 1000)
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate("HHmmss")
        guard withDate else { return time.string(from: date) }
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)) \(time.string(from: date))"
    }

    /// `shortToolName`: an MCP tool by its own name.
    public static func toolName(_ name: String) -> String {
        guard let range = name.range(of: #"^mcp__.+?__(.+)$"#, options: .regularExpression),
              let marker = name.range(of: "__", range: name.index(name.startIndex, offsetBy: 5)..<range.upperBound) else { return name }
        return String(name[marker.upperBound...])
    }

    public static func modelName(_ model: String) -> String {
        if model == "<synthetic>" { return "local only" }
        if model == "unknown" { return "unidentified" }
        return model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    public static func modelHint(_ model: String) -> String? {
        if model == "<synthetic>" { return "Interrupts and API errors the CLI wrote locally. No model ran, and they carry no tokens." }
        if model == "unknown" { return "Tokens the request recorded without naming a model." }
        return nil
    }

    /// `levelOf`: ok under 70, warning under 90, critical from 90.
    public static func level(_ percent: Double) -> String {
        percent >= 90 ? "critical" : percent >= 70 ? "warning" : "ok"
    }

    /// `downsample`: at most `target` points, each bucket keeping its peak.
    public static func downsample(_ points: [ContextPoint], target: Int) -> [ContextPoint] {
        guard points.count > target, target > 0 else { return points }
        let size = Double(points.count) / Double(target)
        var out: [ContextPoint] = []
        for i in 0..<target {
            let from = Int((Double(i) * size).rounded(.down))
            let to = min(points.count, Int((Double(i + 1) * size).rounded(.down)))
            guard from < points.count else { continue }
            var peak = points[from]
            if from + 1 < to {
                for candidate in points[(from + 1)..<to] where candidate.percent > peak.percent { peak = candidate }
            }
            out.append(peak)
        }
        return out
    }

    static let axisLadder: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 20, 30, 40, 50, 60, 80, 100]

    /// `axisMax`: the first ladder step at least 15% above the peak.
    public static func axisMax(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        let wanted = peak * 1.15
        return axisLadder.first { $0 >= wanted } ?? 100
    }

    public static func axisLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))%" : String(format: "%.1f%%", rounded)
    }

    /// `describeSource`: the dialog's line — which transcript, and since when.
    public static func source(title: String?, insights: SessionInsights?, attribution: String?) -> String? {
        let head = title.map { "\($0) — " } ?? ""
        guard let insights else { return title.map { "\($0) — from its transcript" } }
        let short = String(insights.sessionId.prefix(8))
        let lead: String
        switch attribution {
        case "resumed": lead = "continued transcript \(short)"
        case "project": lead = "newest transcript in this folder, \(short)"
        default: lead = "transcript \(short)"
        }
        return "\(head)\(lead), started \(clock(insights.startedAt, withDate: true))"
    }
}

/// Which transcript is a session's (`attributeTranscript`): `TranscriptFile` is shared, declared in DashboardData.swift.

public struct SessionScope: Equatable, Sendable {
    public let startedAt: Double
    public let resumed: Bool
    public let agentSessionId: String?
    public init(startedAt: Double, resumed: Bool, agentSessionId: String?) {
        self.startedAt = startedAt
        self.resumed = resumed
        self.agentSessionId = agentSessionId
    }
}

public enum TranscriptVerdict: Equatable, Sendable {
    case none
    case choice(path: String, sessionId: String, attribution: String)
    case ambiguous(candidates: Int, competing: Int)

    public static func attribute(_ files: [TranscriptFile], scope: SessionScope?, others: [Double] = []) -> TranscriptVerdict {
        if let declared = scope?.agentSessionId, !declared.isEmpty {
            guard let own = files.first(where: { $0.sessionId == declared }) else { return .none }
            return .choice(path: own.path, sessionId: own.sessionId, attribution: "declared")
        }
        guard !files.isEmpty else { return .none }
        let byWrite = files.sorted { $0.modifiedAt > $1.modifiedAt }
        let newest = byWrite[0]
        guard let scope else { return .choice(path: newest.path, sessionId: newest.sessionId, attribution: "project") }
        if scope.resumed {
            let continued = byWrite.first { $0.createdAt < scope.startedAt } ?? newest
            return .choice(path: continued.path, sessionId: continued.sessionId, attribution: "resumed")
        }
        let candidates = files.filter { $0.createdAt >= scope.startedAt }
        guard !candidates.isEmpty else { return .none }
        let nextStart = others.filter { $0 >= scope.startedAt }.min() ?? .infinity
        let exclusive = candidates.filter { $0.createdAt < nextStart }
        guard let own = exclusive.max(by: { $0.createdAt < $1.createdAt }) else {
            return .ambiguous(candidates: candidates.count, competing: others.filter { $0 >= scope.startedAt }.count)
        }
        return .choice(path: own.path, sessionId: own.sessionId, attribution: "session")
    }
}
