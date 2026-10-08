import Foundation
import CoreFoundation

/// Exactly what a person reviews before approving a readiness write. For a
/// created file, before is nil. A command-only change uses action instead.
public struct AIRReadinessFileChange: Equatable, Sendable, Identifiable {
    public var path: String
    public var before: String?
    public var after: String?
    public var action: String?
    public var id: String { path }

    public init(path: String, before: String? = nil, after: String? = nil, action: String? = nil) {
        self.path = path; self.before = before; self.after = after; self.action = action
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let path = row["path"] as? String, !path.isEmpty,
              row["after"] is String || row["action"] is String else { return nil }
        self.init(path: path, before: row["before"] as? String, after: row["after"] as? String,
                  action: row["action"] as? String)
    }
}

/// The backend holds the authoritative preview and binds it to the caller,
/// project, selected agent, check and current file contents. This presentation
/// value is never itself an approval or a mutation capability.
public struct AIRReadinessFixPreview: Equatable, Sendable, Identifiable {
    public var id: String
    public var projectPath: String
    public var checkID: String
    public var agent: String?
    public var fixID: String
    public var title: String
    public var summary: String
    public var changes: [AIRReadinessFileChange]
    public var checkFingerprint: String
    public var createdAt: String
    public var expiresAt: String

    public init(id: String, projectPath: String, checkID: String, agent: String? = nil,
                fixID: String, title: String, summary: String, changes: [AIRReadinessFileChange],
                checkFingerprint: String, createdAt: String, expiresAt: String) {
        self.id = id; self.projectPath = projectPath; self.checkID = checkID; self.agent = agent
        self.fixID = fixID; self.title = title; self.summary = summary; self.changes = changes
        self.checkFingerprint = checkFingerprint; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String,
              let project = row["projectPath"] as? String, let check = row["checkID"] as? String,
              let fix = row["fixID"] as? String, let title = row["title"] as? String,
              let summary = row["summary"] as? String, let rows = row["changes"] as? [Any],
              let fingerprint = row["checkFingerprint"] as? String,
              let created = row["createdAt"] as? String, let expires = row["expiresAt"] as? String else { return nil }
        let changes = rows.compactMap(AIRReadinessFileChange.init(json:))
        guard changes.count == rows.count, !changes.isEmpty, !id.isEmpty, !project.isEmpty,
              !check.isEmpty, !fix.isEmpty, !fingerprint.isEmpty else { return nil }
        self.init(id: id, projectPath: project, checkID: check, agent: row["agent"] as? String,
                  fixID: fix, title: title, summary: summary, changes: changes,
                  checkFingerprint: fingerprint, createdAt: created, expiresAt: expires)
    }
}

/// A write outcome includes the fresh scan, so success is not mistaken for a
/// passing check. Creating starter documentation can still leave work to do.
public struct AIRReadinessFixOutcome: Equatable, Sendable {
    public var result: ReadinessFixResult
    public var report: ReadinessReport

    public init(result: ReadinessFixResult, report: ReadinessReport) {
        self.result = result; self.report = report
    }
    public init?(json: Any?) {
        guard let row = json as? [String: Any], let result = row["result"] as? [String: Any],
              result["ok"] is Bool, let report = ReadinessReport(json: row["report"]) else { return nil }
        self.init(result: ReadinessFixResult(json: result), report: report)
    }
}

/// Counts toward completion, using the selected agent's existing scan. A high
/// weighted score is useful context but does not hide unfinished checks.
public struct AIRReadinessProgress: Equatable, Sendable {
    public var passing: Int
    public var applicable: Int
    public var remaining: Int
    public var skipped: Int
    public var unverified: Int
    public var score: Int
    public var ready: Bool
    public var label: String

    public init(report: ReadinessReport, agent: String? = nil) {
        let view = ReadinessRules.view(of: report, agent: agent)
        passing = view.checks.filter { $0.status == .pass }.count
        applicable = view.checks.filter { $0.status != .skip }.count
        unverified = view.checks.filter(AIRReadinessActions.isUnverified).count
        let unverifiedSkips = view.checks.filter { $0.status == .skip && AIRReadinessActions.isUnverified($0) }.count
        skipped = view.checks.filter { $0.status == .skip }.count - unverifiedSkips
        remaining = applicable - passing + unverifiedSkips
        score = max(0, min(100, view.score))
        ready = applicable > 0 && remaining == 0 && unverified == 0
        if ready {
            label = "Ready · \(passing) of \(applicable) checks passing"
        } else if applicable + unverifiedSkips == 0 {
            label = "No applicable checks · readiness is unverified"
        } else {
            label = "\(passing) of \(applicable + unverifiedSkips) checks passing · \(remaining) to finish"
            if unverified > 0 { label += " · \(unverified) could not be checked" }
        }
        if skipped > 0 { label += " · \(skipped) not applicable" }
    }

    public init?(json: Any?) {
        // RPC numbers arrive as Double; JSONSerialization uses NSNumber.
        // Accept exact whole numbers from either, without accepting booleans.
        func whole(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Int(exactly: number.doubleValue)
        }
        guard let row = json as? [String: Any], let passing = whole(row["passing"]),
              let applicable = whole(row["applicable"]), let remaining = whole(row["remaining"]),
              let skipped = whole(row["skipped"]), let unverified = whole(row["unverified"]),
              let score = whole(row["score"]), let ready = row["ready"] as? Bool,
              let label = row["label"] as? String,
              passing >= 0, applicable >= passing, remaining >= applicable - passing, skipped >= 0, unverified >= 0,
              (0...100).contains(score),
              ready == (applicable > 0 && passing == applicable && remaining == 0 && unverified == 0) else { return nil }
        self.passing = passing; self.applicable = applicable; self.remaining = remaining
        self.skipped = skipped; self.unverified = unverified; self.score = score
        self.ready = ready; self.label = label
    }
}
