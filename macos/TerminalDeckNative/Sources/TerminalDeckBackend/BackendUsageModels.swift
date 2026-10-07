import Foundation
import TerminalDeckNativeCore

public struct BackendUsageAccount: Sendable, Equatable {
    public let provider: String
    public let id: String?
    public let name: String?
    public let configDirectory: String?
    public init(provider: String, id: String?, name: String?, configDirectory: String?) { self.provider = provider; self.id = id; self.name = name; self.configDirectory = configDirectory }
    public var key: String { "\(provider)/\(id ?? configDirectory ?? "system")" }
    public var wireValue: NativeRPCValue { BackendUsageIO.object([("provider", .string(provider)), ("id", BackendUsageIO.string(id)), ("name", BackendUsageIO.string(name)), ("configDir", BackendUsageIO.string(configDirectory))]) }
}
public enum BackendUsageWindow: String, Sendable { case fiveHour = "five-hour", weekly, monthly, other }
public enum BackendUsageAmount: Sendable, Equatable {
    case reported(fraction: Double), notReported
    public static func percent(_ percent: Double?) -> Self { guard let percent, percent.isFinite, (0...999).contains(percent) else { return .notReported }; return .reported(fraction: percent / 100) }
    public var wireValue: NativeRPCValue { switch self { case .reported(let fraction): return BackendUsageIO.object([("kind", .string("reported")), ("fraction", .number(fraction))]); case .notReported: return BackendUsageIO.object([("kind", .string("not-reported"))]) } }
}
public enum BackendUsageReset: Sendable, Equatable {
    case at(Double), described(String), notReported
    public static func epoch(_ value: Double?) -> Self { guard let value, value.isFinite, value > 0 else { return .notReported }; return .at((value < 1_000_000_000_000 ? value * 1000 : value).rounded()) }
    public var wireValue: NativeRPCValue { switch self { case .at(let at): return BackendUsageIO.object([("kind", .string("at")), ("at", .number(at))]); case .described(let text): return BackendUsageIO.object([("kind", .string("described")), ("text", .string(text))]); case .notReported: return BackendUsageIO.object([("kind", .string("not-reported"))]) } }
}
public struct BackendUsageReading: Sendable {
    public let id: String
    public let account: BackendUsageAccount
    public let window: BackendUsageWindow
    public let windowMinutes: Double?
    public let label: String
    public let used: BackendUsageAmount
    public let resets: BackendUsageReset
    public let observedAt: Double
    public let reportedAt: Double
    public let source: String
    public init(account: BackendUsageAccount, window: BackendUsageWindow, qualifier: String? = nil, windowMinutes: Double?, label: String,
                used: BackendUsageAmount, resets: BackendUsageReset, observedAt: Double, reportedAt: Double, source: String) {
        id = "\(account.key)/\(window.rawValue)\(qualifier.map { ":\($0)" } ?? "")"; self.account = account; self.window = window; self.windowMinutes = windowMinutes
        self.label = label; self.used = used; self.resets = resets; self.observedAt = observedAt; self.reportedAt = reportedAt; self.source = source
    }
    public var wireValue: NativeRPCValue { BackendUsageIO.object([("id", .string(id)), ("account", account.wireValue), ("window", .string(window.rawValue)), ("windowMinutes", BackendUsageIO.number(windowMinutes)), ("label", .string(label)), ("used", used.wireValue), ("resets", resets.wireValue), ("observedAt", .number(observedAt)), ("reportedAt", .number(reportedAt)), ("source", .string(source))]) }
    public func freshness(now: Double) -> (expired: Bool, stale: Bool, drawable: Bool, age: Double) {
        let expired: Bool = { if case .at(let at) = resets { return at <= now }; return false }()
        let nominal = windowMinutes ?? (window == .fiveHour ? 300 : window == .weekly ? 10_080 : window == .monthly ? 43_200 : 0)
        let age = max(0, now - reportedAt), stale = nominal > 0 && age > nominal * 60_000 / 12
        let reported: Bool = { if case .reported = used { return true }; return false }()
        return (expired, stale, reported && !expired && !stale, age)
    }
    public static func window(minutes: Double?) -> BackendUsageWindow { switch minutes { case 300: return .fiveHour; case 10_080: return .weekly; case 43_200: return .monthly; default: return .other } }
}
public struct BackendUsageReport: Sendable {
    public let sessionID: String?
    public let account: BackendUsageAccount?
    public let readings: [BackendUsageReading]
    public let reason: String?
    public let assembledAt: Double
    public init(sessionID: String?, account: BackendUsageAccount?, readings: [BackendUsageReading], reason: String?, assembledAt: Double) {
        self.sessionID = sessionID; self.account = account; self.readings = readings; self.reason = readings.isEmpty ? reason : nil; self.assembledAt = assembledAt
    }
    public var wireValue: NativeRPCValue { BackendUsageIO.object([("sessionId", BackendUsageIO.string(sessionID)), ("account", account?.wireValue ?? .null), ("readings", .array(readings.map(\.wireValue))), ("reason", BackendUsageIO.string(reason)), ("assembledAt", .number(assembledAt))]) }
}
public struct BackendUsagePlanLimit: Sendable, Equatable {
    public let id: String, label: String, scope: String
    public let percent: Double?
    public let resetsAt: String?
    public var wireValue: NativeRPCValue { BackendUsageIO.object([("id", .string(id)), ("label", .string(label)), ("scope", .string(scope)), ("percent", BackendUsageIO.number(percent)), ("resetsAt", BackendUsageIO.string(resetsAt))]) }
    static func identify(_ label: String) -> (id: String, scope: String) {
        let lower = label.lowercased()
        for model in ["opus", "sonnet", "haiku", "fable", "mythos"] where lower.contains(model) && (lower.contains("week") || lower.contains("limit")) { return ("week:\(model)", "week") }
        if lower.contains("week") { return ("week", "week") }
        if lower.contains("session") || lower.contains("5-hour") || lower.contains("five-hour") { return ("session", "session") }
        if lower.contains("credit") { return ("other:usage-credit", "other") }
        let slug = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ("other:\(slug)", "other")
    }
    static func make(_ label: String, percent: Double?, resetsAt: String?) -> Self {
        let identity = identify(label); return Self(id: identity.id, label: label, scope: identity.scope, percent: percent.flatMap { (0...999).contains($0) ? $0 : nil }, resetsAt: resetsAt)
    }
    func reading(account: BackendUsageAccount, observedAt: Double, reportedAt: Double, source: String, apiReset: Bool = false) -> BackendUsageReading {
        let window: BackendUsageWindow = scope == "session" ? .fiveHour : scope == "week" ? .weekly : .other
        let qualifier = id.contains(":") ? String(id.split(separator: ":", maxSplits: 1)[1]) : nil
        var reset: BackendUsageReset = resetsAt.map(BackendUsageReset.described) ?? .notReported
        if apiReset, let resetsAt { let epoch = BackendUsageIO.timestamp(.string(resetsAt)); reset = epoch > 0 ? .at(epoch) : .notReported }
        return BackendUsageReading(account: account, window: window, qualifier: qualifier, windowMinutes: nil, label: label, used: .percent(percent), resets: reset, observedAt: observedAt, reportedAt: reportedAt, source: source)
    }
}

public enum BackendUsagePlanParser {
    public struct Parsed: Sendable { public let limits: [BackendUsagePlanLimit]; public let source: String; public let message: String? }
    public static func billing(screen: String) -> String? {
        for line in screen.components(separatedBy: "\n") {
            guard let match = BackendUsageIO.matches("\\bwith\\s+\\S+(?:\\s+effort)?\\s*·\\s*([^·│]+?)\\s*(?:·|│|$)", line).first,
                  let label = BackendUsageIO.group(match, 1, line)?.trimmingCharacters(in: .whitespaces) else { continue }
            if !BackendUsageIO.matches("^Claude (Max|Pro|Team|Enterprise)$", label).isEmpty { return "subscription" }
            if ["Claude API", "API Usage Billing", "Bedrock", "Bedrock Mantle", "Vertex AI", "Gateway", "Foundry"].contains(label) { return "api" }
        }
        return nil
    }
    public static func parse(screen: String) -> Parsed? {
        let clean = screen.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let heading = "^Current\\s+(session|week)\\b(?:\\s*\\(([^)]*)\\))?\\s*$"
        var limits: [BackendUsagePlanLimit] = [], seen = Set<String>()
        for index in lines.indices {
            guard let found = BackendUsageIO.matches(heading, lines[index], insensitive: true).first else { continue }
            let scope = BackendUsageIO.group(found, 1, lines[index]) ?? "session", qualifier = BackendUsageIO.group(found, 2, lines[index]) ?? ""
            let label = "Current \(scope)\(qualifier.isEmpty ? "" : " (\(qualifier))")"
            var percent: Double?, reset: String?, cursor = index
            for next in (index + 1)..<min(lines.count, index + 5) {
                if !BackendUsageIO.matches(heading, lines[next], insensitive: true).isEmpty { break }
                if let match = BackendUsageIO.matches("(\\d{1,3})%\\s+used\\b", lines[next], insensitive: true).first { percent = BackendUsageIO.group(match, 1, lines[next]).flatMap(Double.init); cursor = next; break }
            }
            guard percent != nil else { continue }
            if cursor + 1 < lines.count { for next in (cursor + 1)..<min(lines.count, cursor + 5) {
                if !BackendUsageIO.matches(heading, lines[next], insensitive: true).isEmpty { break }
                if let match = BackendUsageIO.matches("^Resets\\b\\s*(.*)$", lines[next], insensitive: true).first { reset = BackendUsageIO.group(match, 1, lines[next]); break }
            } }
            let row = BackendUsagePlanLimit.make(label, percent: percent, resetsAt: reset)
            if seen.insert(row.id).inserted { limits.append(row) }
        }
        if !limits.isEmpty { return Parsed(limits: limits, source: "usage-panel", message: nil) }
        func valid(_ label: String) -> Bool { !BackendUsageIO.matches("\\blimits?\\b", label, insensitive: true).isEmpty && !BackendUsageIO.matches("\\b(session|weekly|week|5-hour|five-hour|opus|sonnet|haiku|fable|mythos|credits?)\\b", label, insensitive: true).isEmpty }
        for line in lines.reversed() {
            if let match = BackendUsageIO.matches("you['’]ve used\\s+(\\d{1,3})%\\s+of your\\s+(.+)$", line, insensitive: true).first,
               let rest = BackendUsageIO.group(match, 2, line) {
                let parts = rest.components(separatedBy: .init(charactersIn: "·"))
                let cut = rest.range(of: "\\bresets\\b", options: [.regularExpression, .caseInsensitive])
                let label = String(cut.map { rest[..<$0.lowerBound] } ?? Substring(parts[0])).trimmingCharacters(in: CharacterSet(charactersIn: " ·,;:-"))
                if valid(label) { return Parsed(limits: [.make(label, percent: BackendUsageIO.group(match, 1, line).flatMap(Double.init), resetsAt: cut.map { String(rest[$0.upperBound...]).trimmingCharacters(in: .whitespaces) })], source: "warning", message: line) }
            }
            for pattern in ["^\\W*your\\s+(.+?)\\s+resets\\s+(.+)$", "(?:approaching|you['’]re close to your|you['’]ve hit your)\\s+(.+)$"] {
                if let match = BackendUsageIO.matches(pattern, line, insensitive: true).first, let label = BackendUsageIO.group(match, 1, line), valid(label) {
                    return Parsed(limits: [.make(label, percent: nil, resetsAt: BackendUsageIO.group(match, 2, line))], source: "warning", message: line)
                }
            }
        }
        return nil
    }
    public static func utilization(_ raw: NativeRPCValue, subscription: String?) -> [BackendUsagePlanLimit] {
        guard raw.fields != nil else { return [] }
        var rows: [BackendUsagePlanLimit] = []
        let named = [("five_hour", "Current session"), ("seven_day", "Current week (all models)"), ("seven_day_sonnet", "Current week (Sonnet only)")]
        for (key, title) in named {
            if key == "seven_day_sonnet", let subscription, !["max", "team"].contains(subscription) { continue }
            guard let percent = raw[key]["utilization"].number else { continue }
            rows.append(.make(title, percent: percent, resetsAt: raw[key]["resets_at"].string))
        }
        for row in raw["limits"].elements ?? [] where row["kind"].string == "weekly_scoped" {
            guard let model = row["scope"]["model"]["display_name"].string, !model.isEmpty, let percent = row["percent"].number else { continue }
            rows.append(.make("Current week (\(model))", percent: percent, resetsAt: row["resets_at"].string))
        }
        var unique: [String: BackendUsagePlanLimit] = [:]; for row in rows { unique[row.id] = row }; return unique.values.sorted { $0.id < $1.id }
    }
}
