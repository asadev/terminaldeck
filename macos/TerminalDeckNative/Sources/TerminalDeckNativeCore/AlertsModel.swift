import Foundation

// The Alerts sheet's model, ported from src/renderer/components/AlertsPanel.tsx:
// the report the page hands over, insight filtering, grouping by severity and the
// one-line summary — same rules, same words.

public enum AlertSeverity: String, Decodable, CaseIterable, Sendable {
    case info, warning, critical

    /// SEVERITY_ORDER: worst first.
    public static let order: [AlertSeverity] = [.critical, .warning, .info]

    /// SEVERITY_HEADING
    public var heading: String {
        switch self {
        case .critical: "Needs you now"
        case .warning: "Worth fixing"
        case .info: "Worth knowing"
        }
    }
}

public struct AlertAction: Decodable, Equatable, Sendable {
    public let kind: String
    public let label: String
    public let target: String?
}

public struct ProjectAlert: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let severity: AlertSeverity
    public let title: String
    public let detail: String
    public let sessionId: String?
    public let at: Double
    public let action: AlertAction?

    public init(id: String, kind: String, severity: AlertSeverity, title: String, detail: String = "",
                sessionId: String? = nil, at: Double = 0, action: AlertAction? = nil) {
        self.id = id; self.kind = kind; self.severity = severity; self.title = title; self.detail = detail
        self.sessionId = sessionId; self.at = at; self.action = action
    }

    /// INSIGHT_ALERT_KINDS: what a session is doing, as opposed to what the project lacks.
    public static let insightKinds: Set<String> = ["context-bloat", "pre-context-bloat", "session-blocked", "heavy-session", "loop"]
    public var isInsight: Bool { Self.insightKinds.contains(kind) }
}

public struct AlertReport: Decodable, Equatable, Sendable {
    public let projectPath: String
    public let alerts: [ProjectAlert]
    public let counts: [String: Int]
    public let worst: AlertSeverity?
    public let scannedAt: Double

    public init(projectPath: String = "", alerts: [ProjectAlert], counts: [String: Int]? = nil, worst: AlertSeverity? = nil, scannedAt: Double = 0) {
        self.projectPath = projectPath
        self.alerts = alerts
        let tally = counts ?? Self.count(alerts)
        self.counts = tally
        self.worst = counts == nil ? AlertSeverity.order.first { tally[$0.rawValue, default: 0] > 0 } : worst
        self.scannedAt = scannedAt
    }

    static func count(_ alerts: [ProjectAlert]) -> [String: Int] {
        var counts = ["info": 0, "warning": 0, "critical": 0]
        for alert in alerts { counts[alert.severity.rawValue, default: 0] += 1 }
        return counts
    }

    public func count(_ severity: AlertSeverity) -> Int { counts[severity.rawValue, default: 0] }

    /// withInsights: without them, the session alerts drop out and the counts follow.
    public func withInsights(_ show: Bool) -> AlertReport {
        if show { return self }
        let kept = alerts.filter { !$0.isInsight }
        if kept.count == alerts.count { return self }
        return AlertReport(projectPath: projectPath, alerts: kept, scannedAt: scannedAt)
    }

    /// groupAlerts: worst first; empty groups left out.
    public var groups: [(severity: AlertSeverity, alerts: [ProjectAlert])] {
        AlertSeverity.order.compactMap { severity in
            let these = alerts.filter { $0.severity == severity }
            return these.isEmpty ? nil : (severity, these)
        }
    }

    /// summarize
    public static func summary(_ report: AlertReport?) -> String {
        guard let report else { return "Checking…" }
        if report.alerts.isEmpty { return "Nothing needs your attention." }
        var parts: [String] = []
        if report.count(.critical) > 0 { parts.append("\(report.count(.critical)) needing you now") }
        if report.count(.warning) > 0 { parts.append("\(report.count(.warning)) worth fixing") }
        if report.count(.info) > 0 { parts.append("\(report.count(.info)) worth knowing") }
        return parts.joined(separator: ", ")
    }
}

/// What the page hands the native Alerts sheet.
public struct AlertsRequest: Decodable, Equatable, Sendable {
    public let projectPath: String?
    public let report: AlertReport?
    public let busy: Bool
    public let error: String?
    public let available: Bool
    public let showInsights: Bool

    enum CodingKeys: String, CodingKey { case projectPath, report, busy, error, available, showInsights }

    public init(projectPath: String? = nil, report: AlertReport? = nil, busy: Bool = false, error: String? = nil,
                available: Bool = true, showInsights: Bool = true) {
        self.projectPath = projectPath; self.report = report; self.busy = busy; self.error = error
        self.available = available; self.showInsights = showInsights
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projectPath: (try? c.decodeIfPresent(String.self, forKey: .projectPath)) ?? nil,
                  report: (try? c.decodeIfPresent(AlertReport.self, forKey: .report)) ?? nil,
                  busy: ((try? c.decodeIfPresent(Bool.self, forKey: .busy)) ?? nil) ?? false,
                  error: (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil,
                  available: ((try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? nil) ?? true,
                  showInsights: ((try? c.decodeIfPresent(Bool.self, forKey: .showInsights)) ?? nil) ?? true)
    }

    /// The report as shown (insights applied once, here).
    public var shown: AlertReport? { report?.withInsights(showInsights) }

    /// No project and nothing to say: "No project open".
    public var noProject: Bool { projectPath == nil && (report?.alerts.isEmpty ?? true) }

    /// All clear: no header, just "Nothing needs your attention".
    public var quiet: Bool { available && (shown?.alerts.isEmpty ?? false) && error == nil }

    /// The header's line: the error, or the summary.
    public var headline: String { error ?? AlertReport.summary(shown) }
}
