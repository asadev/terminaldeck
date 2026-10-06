import Foundation

/// AI readiness, the native screen's pure half — the Swift reading of the logic
/// in `src/renderer/components/ReadinessPanel.tsx` and `readiness-dismissed.ts`,
/// rule for rule, so the native page grades, sorts and words a project exactly as
/// the web page did. The report comes from `readiness:scan`; a fix runs through
/// `readiness:fix`.

public enum ReadinessStatus: String, Sendable, Equatable {
    case pass, warn, fail, skip
}

public enum ReadinessBand: String, Sendable, Equatable {
    case strong, fair, weak, atRisk = "at-risk"
}

public struct ReadinessFix: Equatable, Sendable {
    public var id: String
    public var label: String
    public var description: String
    public var touches: [String]
    public var destructive: Bool

    public init(id: String, label: String, description: String = "", touches: [String] = [], destructive: Bool = false) {
        self.id = id
        self.label = label
        self.description = description
        self.touches = touches
        self.destructive = destructive
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String else { return nil }
        self.init(id: id, label: row["label"] as? String ?? id, description: row["description"] as? String ?? "",
                  touches: DeviceJSON.strings(row["touches"]), destructive: row["destructive"] as? Bool ?? false)
    }
}

public struct ReadinessCheck: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var status: ReadinessStatus
    public var weight: Double
    public var detail: String
    public var fix: ReadinessFix?
    /// Failing it caps the whole score.
    public var gate: Bool
    /// A file in the project the row can open, or nil.
    public var opens: String?

    public init(id: String, title: String = "", status: ReadinessStatus, weight: Double = 1, detail: String = "",
                fix: ReadinessFix? = nil, gate: Bool = false, opens: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.weight = weight
        self.detail = detail
        self.fix = fix
        self.gate = gate
        self.opens = opens
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String else { return nil }
        self.init(id: id, title: row["title"] as? String ?? "",
                  status: ReadinessStatus(rawValue: row["status"] as? String ?? "") ?? .skip,
                  weight: DeviceJSON.number(row["weight"]), detail: row["detail"] as? String ?? "",
                  fix: ReadinessFix(json: row["fix"]), gate: row["gate"] as? Bool ?? false,
                  opens: (row["opens"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The instructions row and the score, as one agent would see this project.
public struct ReadinessForAgent: Equatable, Sendable, Identifiable {
    public var agent: String
    public var label: String
    public var file: String
    public var check: ReadinessCheck
    public var score: Int
    public var band: ReadinessBand
    public var cappedBy: String?
    public var id: String { agent }

    public init(agent: String, label: String, file: String, check: ReadinessCheck, score: Int, band: ReadinessBand, cappedBy: String? = nil) {
        self.agent = agent
        self.label = label
        self.file = file
        self.check = check
        self.score = score
        self.band = band
        self.cappedBy = cappedBy
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let agent = row["agent"] as? String, let check = ReadinessCheck(json: row["check"]) else { return nil }
        self.init(agent: agent, label: row["label"] as? String ?? agent, file: row["file"] as? String ?? "", check: check,
                  score: Int(DeviceJSON.number(row["score"])), band: ReadinessBand(rawValue: row["band"] as? String ?? "") ?? .weak,
                  cappedBy: row["cappedBy"] as? String)
    }
}

public struct ReadinessReport: Equatable, Sendable {
    public var projectPath: String
    public var score: Int
    public var band: ReadinessBand
    public var checks: [ReadinessCheck]
    public var cappedBy: String?
    public var agents: [ReadinessForAgent]
    public var scannedAt: String

    public init(projectPath: String = "", score: Int, band: ReadinessBand, checks: [ReadinessCheck], cappedBy: String? = nil,
                agents: [ReadinessForAgent] = [], scannedAt: String = "") {
        self.projectPath = projectPath
        self.score = score
        self.band = band
        self.checks = checks
        self.cappedBy = cappedBy
        self.agents = agents
        self.scannedAt = scannedAt
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let checks = row["checks"] as? [Any] else { return nil }
        self.init(projectPath: row["projectPath"] as? String ?? "", score: Int(DeviceJSON.number(row["score"])),
                  band: ReadinessBand(rawValue: row["band"] as? String ?? "") ?? .weak,
                  checks: checks.compactMap(ReadinessCheck.init(json:)), cappedBy: row["cappedBy"] as? String,
                  agents: (row["agents"] as? [Any] ?? []).compactMap(ReadinessForAgent.init(json:)),
                  scannedAt: row["scannedAt"] as? String ?? "")
    }
}

public struct ReadinessFixResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var changed: [String]

    public init(ok: Bool, message: String, changed: [String] = []) {
        self.ok = ok
        self.message = message
        self.changed = changed
    }

    public init(json: Any?) {
        let row = json as? [String: Any] ?? [:]
        self.init(ok: row["ok"] as? Bool ?? false, message: row["message"] as? String ?? "", changed: DeviceJSON.strings(row["changed"]))
    }
}

/// What the page shows for one choice of agent: the rows, and the score that goes with them.
public struct ReadinessView: Equatable, Sendable {
    public var checks: [ReadinessCheck]
    public var score: Int
    public var band: ReadinessBand
    public var cappedBy: String?
    public var agent: ReadinessForAgent?
}

public enum ReadinessRules {
    public enum Action: Equatable, Sendable { case fix, open, none }

    /// A passing row offers nothing; a fix when there is one; otherwise the file, when it can be opened.
    public static func action(for check: ReadinessCheck, canOpen: Bool) -> Action {
        if check.status == .pass { return .none }
        if check.fix != nil { return .fix }
        return canOpen && check.opens != nil ? .open : .none
    }

    /// The project's own answer, or one agent's: its instructions row and its score swapped in together.
    public static func view(of report: ReadinessReport, agent: String?) -> ReadinessView {
        guard let agent, let picked = report.agents.first(where: { $0.agent == agent }) else {
            return ReadinessView(checks: report.checks, score: report.score, band: report.band, cappedBy: report.cappedBy, agent: nil)
        }
        return ReadinessView(checks: report.checks.map { $0.id == picked.check.id ? picked.check : $0 },
                             score: picked.score, band: picked.band, cappedBy: picked.cappedBy, agent: picked)
    }

    /// `63 out of 100 — 3 of 9 applicable checks passing, weighted · 1 not applicable here.`
    public static func headline(score: Int, passing: Int, applicable: Int, skipped: Int) -> String {
        let counted = "\(score) out of 100 — \(passing) of \(applicable) applicable check\(applicable == 1 ? "" : "s") passing, weighted"
        return skipped == 0 ? "\(counted)." : "\(counted) · \(skipped) not applicable here."
    }

    public static func bandWords(_ band: ReadinessBand) -> String {
        switch band {
        case .strong: "Ready"
        case .fair: "Workable"
        case .weak: "Rough"
        case .atRisk: "At risk"
        }
    }

    public static func statusWords(_ status: ReadinessStatus) -> String {
        switch status {
        case .pass: "Passing"
        case .warn: "Warning"
        case .fail: "Failing"
        case .skip: "Not applicable"
        }
    }

    public static func glyph(_ status: ReadinessStatus) -> String {
        switch status {
        case .pass: "✓"
        case .warn: "!"
        case .fail: "✕"
        case .skip: "–"
        }
    }

    /// Failures, then warnings, then passes, then skips — with an unclean gate above
    /// every other failure — and heavier checks first within each. A stable sort.
    public static func sorted(_ checks: [ReadinessCheck]) -> [ReadinessCheck] {
        func rank(_ check: ReadinessCheck) -> Int {
            if check.gate && (check.status == .fail || check.status == .warn) { return -1 }
            switch check.status {
            case .fail: return 0
            case .warn: return 1
            case .pass: return 2
            case .skip: return 3
            }
        }
        return checks.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            if a.element.weight != b.element.weight { return a.element.weight > b.element.weight }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `1 check hidden` / `3 checks hidden`.
    public static func hiddenWords(_ hidden: Int) -> String {
        hidden == 1 ? "1 check hidden" : "\(hidden) checks hidden"
    }

    /// The score ring's filled share, clamped to the ring.
    public static func ringFraction(_ score: Int) -> Double {
        Double(max(0, min(100, score))) / 100
    }

    /// `AI readiness score 63 out of 100 — Rough`
    public static func ringLabel(score: Int, band: ReadinessBand) -> String {
        "AI readiness score \(score) out of 100 — \(bandWords(band))"
    }

    /// A `file://` URL a system opener accepts, for a path in the project — `fileUrlFor`.
    public static func fileURL(projectPath: String, relPath: String) -> String {
        var base = projectPath.replacingOccurrences(of: "\\", with: "/")
        while base.hasSuffix("/") { base.removeLast() }
        var rest = relPath.replacingOccurrences(of: "\\", with: "/")
        while rest.hasPrefix("/") { rest.removeFirst() }
        let joined = "\(base)/\(rest)"
        let absolute = joined.hasPrefix("/") ? joined : "/\(joined)"
        // `encodeURI`'s set, then the two characters it leaves alone that are legal in a filename.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ";,/?:@&=+$-_.!~*'()#")
        let encoded = (absolute.addingPercentEncoding(withAllowedCharacters: allowed) ?? absolute)
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: "?", with: "%3F")
        return "file://\(encoded)"
    }
}

/// Rows put away on the readiness page, per project (or machine-wide), as the page
/// keeps them under `readiness.dismissed.v1`. Values only: the screen stores the map.
public enum ReadinessDismissed {
    public typealias Map = [String: [String]]

    public static let key = "readiness.dismissed.v1"
    /// Machine-wide rows (a stale agent CLI) are filed here, away from any project.
    public static let machineScope = "*machine*"

    /// Anything that is not the map it expected reads as empty.
    public static func parse(_ raw: String?) -> Map {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: Map = [:]
        for (key, value) in object where key != "__proto__" {
            guard let list = value as? [Any] else { continue }
            let ids = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !ids.isEmpty { out[key] = ids }
        }
        return out
    }

    public static func serialize(_ map: Map) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func ids(_ map: Map, scope: String) -> [String] { map[scope] ?? [] }

    public static func isDismissed(_ map: Map, scope: String, id: String) -> Bool {
        ids(map, scope: scope).contains(id)
    }

    public static func dismiss(_ map: Map, scope: String, id: String) -> Map {
        if isDismissed(map, scope: scope, id: id) { return map }
        var next = map
        next[scope] = ids(map, scope: scope) + [id]
        return next
    }

    public static func restore(_ map: Map, scope: String, id: String) -> Map {
        let kept = ids(map, scope: scope).filter { $0 != id }
        var next = map
        next[scope] = kept.isEmpty ? nil : kept
        return next
    }

    public static func restoreAll(_ map: Map, scope: String) -> Map {
        guard !ids(map, scope: scope).isEmpty else { return map }
        var next = map
        next[scope] = nil
        return next
    }
}
