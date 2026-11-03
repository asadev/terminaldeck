import Foundation

// Settings → Scraping: the readers and sentences behind `ScrapingBody`
// (`browser/ScrapingPanel.tsx`), ported from `scraping-bridge.ts` (readers),
// `scraping-adapter.ts` (the worker and store channels turned into the panel's
// shapes), `scraping-view.ts` (every line it prints) and `shared/scrape-limits.ts`.
// Tests: ScrapingTests.swift mirrors scraping-view.test.ts and scraping-bridge.test.ts.

public enum ScrapingLimits {
    public static let maxWorkers = 16
    public static let maxPaceMs = 30_000
    public static let maxKeepMB = 4096
}

public struct ScrapingFleet: Equatable, Sendable {
    public var profileIds: [String]
    public var concurrency: Int?
    public var delayMs: Int?

    public init(profileIds: [String], concurrency: Int? = nil, delayMs: Int? = nil) {
        self.profileIds = profileIds
        self.concurrency = concurrency
        self.delayMs = delayMs
    }
}

public struct ScrapingCaptureConfig: Equatable, Sendable {
    public var on: Bool?
    public var directory: String
    public var keepMB: Int?
}

public struct ScrapingAssetsConfig: Equatable, Sendable {
    public var upgradeOn: Bool?
    public var from: String
    public var to: String
    public var ledgerOn: Bool?
    public var refetch: Bool?
}

public struct ScrapingChecksConfig: Equatable, Sendable {
    public var coverageOn: Bool?
    public var pattern: String
}

public struct ScrapingConfig: Equatable, Sendable {
    public var fleet: ScrapingFleet?
    /// Resource type → allow / block / fulfill (nil: not set).
    public var requests: [String: String?]?
    public var capture: ScrapingCaptureConfig?
    public var assets: ScrapingAssetsConfig?
    public var checks: ScrapingChecksConfig?

    public init(fleet: ScrapingFleet? = nil, requests: [String: String?]? = nil, capture: ScrapingCaptureConfig? = nil,
                assets: ScrapingAssetsConfig? = nil, checks: ScrapingChecksConfig? = nil) {
        self.fleet = fleet
        self.requests = requests
        self.capture = capture
        self.assets = assets
        self.checks = checks
    }
}

public struct ScrapingWorkerState: Equatable, Sendable {
    public var profileId: String
    /// idle, busy, starting or stopped.
    public var state: String
    public var requests: Int?
}

public struct ScrapingStatus: Equatable, Sendable {
    public var workers: [ScrapingWorkerState]
    public var capture: (recorded: Int?, bytes: Int?, dropped: Int?, droppedReason: String)?
    public var assets: (fetched: Int?, upgraded: Int?, fellBack: Int?, skipped: Int?, ledgerEntries: Int?)?
    public var lastCheck: (url: String, stated: Int?, got: Int?, at: Double)?

    public static func == (a: ScrapingStatus, b: ScrapingStatus) -> Bool {
        a.workers == b.workers && a.capture?.recorded == b.capture?.recorded && a.capture?.bytes == b.capture?.bytes
            && a.assets?.fetched == b.assets?.fetched && a.lastCheck?.got == b.lastCheck?.got && a.lastCheck?.stated == b.lastCheck?.stated
    }
}

public struct ScrapingLiftRequest: Equatable, Sendable, Identifiable {
    public var id: String
    public var askedBy: String
    public var fromProfileId: String
    public var intoProfileIds: [String]
    public var reason: String
    public var at: Double
}

public struct ScrapingTool: Equatable, Sendable, Identifiable {
    /// verified, unverified, mismatch or unknown.
    public var id: String
    public var name: String
    public var version: String
    public var publisher: String
    public var reach: [String]
    public var installed: Bool
    public var identity: String
}

public struct ScrapingWorkerRow: Equatable, Sendable, Identifiable {
    public var profileId: String
    public var name: String
    public var avatar: String
    public var enrolled: Bool
    /// idle, busy, starting, stopped or unreported.
    public var state: String
    public var requests: Int?
    public var orphaned: Bool
    public var id: String { profileId }
}

public struct ScrapingProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: String
    public var isDefault: Bool
}

public enum Scraping {
    public static let resourceTypes = ["image", "media", "font", "stylesheet", "script", "xhr", "fetch"]
    public static let requestRules = ["allow", "block", "fulfill"]
    public static let notMeasured = "not measured"
    public static let notConfirmed = "That change was not confirmed, so nothing here claims it was stored."
    public static let fulfillNote = "Block stops the request, so lazy-loading never fires and the page never reveals its real URLs. Fulfill answers it with a correctly-sized transparent placeholder, so it does."
    public static let notEnrolled = "The default profile cannot be a worker — it holds every login from before this feature existed — and a fleet has a limit."

    // MARK: Readers

    static func count(_ value: CodingAIJSON) -> Int? {
        guard let number = value.number, number.isFinite, number >= 0, value.bool == nil else { return nil }
        return Int(number.rounded(.down))
    }

    static func flag(_ value: CodingAIJSON) -> Bool? { value.bool }

    public static func profiles(_ raw: CodingAIJSON) -> (profiles: [ScrapingProfile], activeId: String) {
        let rows = (raw["profiles"].array ?? []).compactMap { row -> ScrapingProfile? in
            guard let id = row["id"].string, let name = row["name"].string else { return nil }
            return ScrapingProfile(id: id, name: name, avatar: row["avatar"].string ?? "", isDefault: row["isDefault"].isTrue)
        }
        guard let first = rows.first else { return ([], "") }
        let active = raw["activeId"].string.flatMap { id in rows.contains { $0.id == id } ? id : nil } ?? first.id
        return (rows, active)
    }

    /// `readScrapingConfig`: nil when the answer holds none of the five groups.
    public static func config(_ raw: CodingAIJSON) -> ScrapingConfig? {
        guard raw.isObject else { return nil }
        var config = ScrapingConfig()
        if raw["fleet"].isObject {
            let fleet = raw["fleet"]
            config.fleet = ScrapingFleet(profileIds: (fleet["profileIds"].array ?? []).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } },
                                         concurrency: count(fleet["concurrency"]), delayMs: count(fleet["delayMs"]))
        }
        if raw["requests"].isObject {
            var rules: [String: String?] = [:]
            for type in resourceTypes {
                let rule = raw["requests"][type].string
                rules[type] = rule.flatMap { requestRules.contains($0) ? $0 : nil }
            }
            config.requests = rules
        }
        if raw["capture"].isObject {
            let capture = raw["capture"]
            config.capture = ScrapingCaptureConfig(on: flag(capture["on"]), directory: capture["directory"].string ?? "", keepMB: count(capture["keepMB"]))
        }
        if raw["assets"].isObject {
            let assets = raw["assets"]
            config.assets = ScrapingAssetsConfig(upgradeOn: flag(assets["upgrade"]["on"]), from: assets["upgrade"]["from"].string ?? "",
                                                 to: assets["upgrade"]["to"].string ?? "", ledgerOn: flag(assets["ledger"]["on"]),
                                                 refetch: flag(assets["ledger"]["refetch"]))
        }
        if raw["checks"].isObject {
            config.checks = ScrapingChecksConfig(coverageOn: flag(raw["checks"]["coverage"]["on"]),
                                                 pattern: raw["checks"]["coverage"]["pattern"].string ?? "")
        }
        let empty = config.fleet == nil && config.requests == nil && config.capture == nil && config.assets == nil && config.checks == nil
        return empty ? nil : config
    }

    /// `readScrapingStatus`.
    public static func status(_ raw: CodingAIJSON) -> ScrapingStatus? {
        guard raw.isObject else { return nil }
        let workers = (raw["workers"].array ?? []).compactMap { row -> ScrapingWorkerState? in
            guard let profileId = row["profileId"].string, !profileId.isEmpty else { return nil }
            let state = row["state"].string ?? ""
            return ScrapingWorkerState(profileId: profileId, state: ["idle", "busy", "starting"].contains(state) ? state : "stopped",
                                       requests: count(row["requests"]))
        }
        let capture = raw["capture"]
        let assets = raw["assets"]
        let check = raw["lastCheck"]
        return ScrapingStatus(
            workers: workers,
            capture: capture.isObject ? (count(capture["recorded"]), count(capture["bytes"]), count(capture["dropped"]), capture["droppedReason"].string ?? "") : nil,
            assets: assets.isObject ? (count(assets["fetched"]), count(assets["upgraded"]), count(assets["fellBack"]), count(assets["skipped"]), count(assets["ledgerEntries"])) : nil,
            lastCheck: check.isObject && check["url"].string != nil ? (check["url"].string!, count(check["stated"]), count(check["got"]), Double(count(check["at"]) ?? 0)) : nil)
    }

    /// The worker channels' view (`browser-worker:*`), as the panel's config (`configOf`).
    public static func configFromWorkers(_ raw: CodingAIJSON) -> ScrapingConfig? {
        guard raw.isObject, let workers = raw["workers"].array else { return nil }
        let ids = workers.compactMap { $0["profileId"].string.flatMap { $0.isEmpty ? nil : $0 } }
        return ScrapingConfig(fleet: ScrapingFleet(profileIds: ids, concurrency: Int(raw["pace"]["maxConcurrent"].number ?? 0),
                                                   delayMs: Int(raw["pace"]["minDelayMs"].number ?? 0)))
    }

    public static func liftRequests(_ raw: CodingAIJSON) -> [ScrapingLiftRequest] {
        (raw.array ?? []).compactMap { row in
            guard let id = row["id"].string, !id.isEmpty, let from = row["fromProfileId"].string, !from.isEmpty else { return nil }
            let into = (row["intoProfileIds"].array ?? []).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } }
            guard !into.isEmpty else { return nil }
            return ScrapingLiftRequest(id: id, askedBy: row["askedBy"].string ?? "", fromProfileId: from, intoProfileIds: into,
                                       reason: row["reason"].string ?? "", at: Double(count(row["at"]) ?? 0))
        }
    }

    /// `browser-store:list` → the panel's tool rows (`readStoreListings` + `readToolListings`).
    public static func tools(_ raw: CodingAIJSON) -> [ScrapingTool] {
        var out: [ScrapingTool] = []
        for tool in raw["view"]["tools"].array ?? [] {
            guard let id = tool["id"].string, !id.isEmpty else { continue }
            let state = tool["state"].string ?? ""
            let digest = tool["sha256"].string ?? ""
            let grants = (tool["grants"].array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            let origins = (tool["origins"].array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            var reach = grants.map { $0 == "page-read" ? "Reads the page you point it at" : $0 }
            if !origins.isEmpty { reach.append(origins.contains("*") ? "Runs on any site" : "Runs on \(origins.joined(separator: ", "))") }
            let name = tool["name"].string ?? ""
            out.append(ScrapingTool(id: id, name: name.isEmpty ? id : name, version: tool["version"].string ?? "", publisher: "",
                                    reach: reach, installed: !state.isEmpty && state != "available",
                                    identity: identity(state: state, digest: digest)))
        }
        for id in (raw["orphans"].array ?? []).compactMap(\.string) where !id.isEmpty {
            out.append(ScrapingTool(id: id, name: id, version: "", publisher: "", reach: [], installed: true, identity: "unknown"))
        }
        return out
    }

    static func identity(state: String, digest: String) -> String {
        if state == "installed" || state == "outdated" { return "verified" }
        if state == "damaged" { return "mismatch" }
        return digest.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil ? "verified" : "unverified"
    }

    /// `readOutcome`.
    public static func outcome(_ raw: CodingAIJSON) -> (ok: Bool, message: String, count: Int?) {
        guard raw.isObject else { return (false, "No answer came back, so nothing here is confirmed.", nil) }
        let ok = raw["ok"].isTrue
        let message = raw["message"].string ?? ""
        return (ok, message.isEmpty ? (ok ? "Done." : "It did not say what went wrong.") : message, count(raw["count"]))
    }

    // MARK: Lines (`scraping-view.ts`)

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func countLine(_ value: Int?, _ one: String, _ many: String) -> String {
        guard let value else { return "\(notMeasured) (\(many))" }
        return "\(grouped(value)) \(value == 1 ? one : many)"
    }

    public static func bytesLine(_ value: Int?) -> String {
        guard let value else { return notMeasured }
        return BrowserSettings.bytes(value)
    }

    public static func ruleLabel(_ rule: String) -> String {
        rule == "allow" ? "Allow" : rule == "block" ? "Block" : "Fulfill"
    }

    public static func resourceLabel(_ type: String) -> String {
        switch type {
        case "xhr": return "XHR"
        case "fetch": return "Fetch"
        case "media": return "Media"
        default: return type.prefix(1).uppercased() + type.dropFirst() + "s"
        }
    }

    public static func workerStateLabel(_ state: String) -> String {
        switch state {
        case "busy": return "Busy"
        case "starting": return "Starting"
        case "idle": return "Idle"
        case "stopped": return "Stopped"
        default: return "Not reported"
        }
    }

    public static func workerRows(fleet: ScrapingFleet?, status: ScrapingStatus?, profiles: [ScrapingProfile]) -> [ScrapingWorkerRow] {
        let byProfile = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = Dictionary((status?.workers ?? []).map { ($0.profileId, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [ScrapingWorkerRow] = []
        for id in fleet?.profileIds ?? [] {
            let profile = byProfile[id]
            let worker = live[id]
            rows.append(ScrapingWorkerRow(profileId: id, name: profile?.name ?? id, avatar: profile?.avatar ?? "", enrolled: true,
                                          state: worker?.state ?? "unreported", requests: worker?.requests, orphaned: profile == nil))
        }
        for worker in status?.workers ?? [] where !rows.contains(where: { $0.profileId == worker.profileId }) {
            let profile = byProfile[worker.profileId]
            rows.append(ScrapingWorkerRow(profileId: worker.profileId, name: profile?.name ?? worker.profileId, avatar: profile?.avatar ?? "",
                                          enrolled: false, state: worker.state, requests: worker.requests, orphaned: profile == nil))
        }
        return rows
    }

    public static func fleetLine(_ rows: [ScrapingWorkerRow], measured: Bool) -> String {
        let head = countLine(rows.count, "worker", "workers")
        if !measured { return "\(head) · busy \(notMeasured)" }
        return "\(head) · \(rows.filter { $0.state == "busy" }.count) busy"
    }

    public static func mintPlan(_ typed: String, have: Int) -> (total: Int?, line: String) {
        let digits = typed.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "-" || $0 == "+" }
        guard let wanted = Int(digits), wanted > 0 else { return (nil, "Type how many workers you want in total.") }
        if wanted <= have {
            return (nil, "\(countLine(have, "worker", "workers")) now. This is a total and it only ever adds — type a bigger number to make more.")
        }
        return (wanted, "\(countLine(have, "worker", "workers")) now, so this makes \(wanted - have) more.")
    }

    public static func enrollable(fleet: ScrapingFleet?, profiles: [ScrapingProfile]) -> [ScrapingProfile] {
        let taken = Set(fleet?.profileIds ?? [])
        return profiles.filter { !taken.contains($0.id) }
    }

    public static func liftLine(from: String, into: [String]) -> String {
        let target = into.count == 1 ? into[0] : "\(into.dropLast().joined(separator: ", ")) and \(into.last ?? "")"
        return "Copy the signed-in session from \(from) into \(target)."
    }

    public static func liftRequestLine(askedBy: String, from: String, into: [String]) -> String {
        let who = askedBy.trimmingCharacters(in: .whitespaces).isEmpty ? "Something" : askedBy.trimmingCharacters(in: .whitespaces)
        let what = liftLine(from: from, into: into)
        return "\(who) asked to \(what.prefix(1).lowercased())\(what.dropFirst())"
    }

    /// `coverageVerdict`: tone complete / short / unknown, and the line.
    public static func coverageVerdict(stated: Int?, got: Int?, ran: Bool) -> (tone: String, line: String) {
        guard ran else { return ("unknown", "No check has run.") }
        guard let stated else { return ("unknown", "The page did not state a total the pattern could find.") }
        guard let got else { return ("unknown", "The page stated \(grouped(stated)); nothing counted what was taken.") }
        if got >= stated { return ("complete", "\(grouped(got)) of \(grouped(stated)) stated.") }
        let percent = Int((Double(got) / Double(stated) * 100).rounded(.down))
        return ("short", "\(grouped(got)) of \(grouped(stated)) stated — \(percent)%.")
    }

    public static func droppedLine(dropped: Int?, reason: String, measured: Bool) -> String {
        guard measured, let dropped else { return "Dropped: \(notMeasured)." }
        if dropped == 0 { return "Nothing dropped." }
        let what = countLine(dropped, "response", "responses")
        return reason.isEmpty ? "\(what) dropped." : "\(what) dropped — \(reason)."
    }

    public static func canInstall(_ tool: ScrapingTool) -> Bool { !tool.installed && tool.identity == "verified" }

    public static func installBlockedReason(_ tool: ScrapingTool) -> String {
        if tool.installed || tool.identity == "verified" { return "" }
        if tool.identity == "mismatch" { return "What arrived is not what this listing signed. It will not install." }
        if tool.identity == "unverified" { return "This tool is not signed, so it cannot be installed." }
        return "This build could not check the signature, so it will not install."
    }

    public static func reachLine(_ tool: ScrapingTool) -> String {
        tool.reach.isEmpty ? "It does not declare what it reaches." : tool.reach.joined(separator: " · ")
    }

    /// `scopeLabel`: browser-wide settings, or the profile's own.
    public static func scopeLabel(browserWide: Bool, profileName: String) -> String {
        browserWide ? "This browser" : profileName.isEmpty ? "This profile" : profileName
    }

    /// `profileInitial`: the chosen glyph, else the name's first character.
    public static func initial(_ name: String, avatar: String) -> String {
        let chosen = avatar.trimmingCharacters(in: .whitespaces)
        if let glyph = chosen.first { return String(glyph) }
        return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? ""
    }

    /// What a press on the fleet says afterwards (`storeFleet`'s expectations).
    public static func enrolledNote(name: String, stored ids: [String], id: String) -> String {
        ids.contains(id) ? "" : "\(name) was not enrolled. \(notEnrolled)"
    }

    public static func retiredNote(name: String, stored ids: [String], id: String) -> String {
        ids.contains(id) ? "\(name) is still a worker — the engine did not retire it." : "Retired. Its cookies and whatever a site decided about it are untouched."
    }
}
