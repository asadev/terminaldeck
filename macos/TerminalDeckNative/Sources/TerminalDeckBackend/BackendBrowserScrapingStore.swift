import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserCaptureBounds: Sendable {
    public let maxBodyBytes: Int
    public let maxTotalBytes: Int
    public let maxEntries: Int
    public init(limits: NativeRPCValue = .object([])) {
        maxBodyBytes = BackendBrowserScrapingIO.integer(limits["maxBodyBytes"], default: 2 * 1_024 * 1_024, min: 1, max: 64 * 1_024 * 1_024)
        maxTotalBytes = BackendBrowserScrapingIO.integer(limits["maxTotalBytes"], default: 256 * 1_024 * 1_024, min: 1, max: 4 * 1_024 * 1_024 * 1_024)
        maxEntries = BackendBrowserScrapingIO.integer(limits["maxEntries"], default: 20_000, min: 1, max: 200_000)
    }
}

/// An observed response is not a claim that every response was observed. Missing
/// status/size/body remain missing until the legacy manifest needs its 0 marker.
public struct BackendBrowserNetworkResponse: Sendable {
    public let url: URL
    public let method: String?
    public let kind: String
    public let status: Int?
    public let mimeType: String?
    public let bytes: Int?
    public let headers: [String: String]
    public let body: Data?
    public let bodyFailure: String?
    public let source: String
    public init(url: URL, method: String? = nil, kind: String, status: Int? = nil,
                mimeType: String? = nil, bytes: Int? = nil, headers: [String: String] = [:], body: Data? = nil,
                bodyFailure: String? = nil, source: String) {
        self.url = url; self.method = method; self.kind = kind; self.status = status; self.mimeType = mimeType
        self.bytes = bytes; self.headers = headers; self.body = body; self.bodyFailure = bodyFailure; self.source = source
    }
}

public actor BackendBrowserScrapingStore {
    public let paths: BackendBrowserScrapingPaths
    private let changed: @Sendable (String) async -> Void
    private var settings: NativeRPCValue?
    private struct Capture: Sendable {
        let profile: String; let id: String; let directory: URL; let startURL: String; let started: Double
        let bounds: BackendBrowserCaptureBounds; let bodyKinds: Set<String>; let visibility: String
        var counts: [String: Int] = ["entries": 0, "bodies": 0, "lost": 0, "tooLarge": 0, "overBudget": 0,
                                    "unfinished": 0, "failed": 0, "notRequested": 0, "bytes": 0]
        var overflow = 0; var denied = 0
    }
    private var captures: [UUID: Capture] = [:]
    private var batches: [String: [String: Int]] = [:]
    private var blockAt: [String: Double] = [:]
    public init(dataRoot: URL, changed: @escaping @Sendable (String) async -> Void) {
        paths = .init(dataRoot: dataRoot); self.changed = changed
    }
    public static var emptySettings: NativeRPCValue {
        .object([.init("requests", .object([])), .init("capture", .object([.init("on", .null), .init("keepMB", .null)])),
            .init("assets", .object([.init("upgrade", .object([.init("on", .null), .init("from", .string("")), .init("to", .string(""))])),
                                    .init("ledger", .object([.init("on", .null), .init("refetch", .null)]))])),
            .init("checks", .object([.init("coverage", .object([.init("on", .null), .init("pattern", .string(""))])), .init("screenshotOnBlock", .null)]))])
    }
    private func loadSettings() throws {
        guard settings == nil else { return }
        let url = try paths.checked(paths.dataRoot.appendingPathComponent("browser-scraping.json"))
        if FileManager.default.fileExists(atPath: url.path) {
            settings = try NativeRPCValue.parseJSON(BackendBrowserScrapingIO.read(url, maxBytes: 4_194_304))["profiles"].requireObject("scraping profiles")
        } else { settings = .object([]) }
        // Read the former block toggle into this SAME settings object only
        // where the newer checkbox has no answer. Never maintain a second live
        // store, rewrite the legacy file or create a website profile for it.
        let legacy = try paths.checked(paths.dataRoot.appendingPathComponent("scrape/block-capture.json"))
        if FileManager.default.fileExists(atPath: legacy.path) {
            let raw = try NativeRPCValue.parseJSON(BackendBrowserScrapingIO.read(legacy, maxBytes: 1_048_576))
            for field in raw.fields ?? [] where field.value.bool != nil {
                guard (try? BackendBrowserScrapingPaths.component(field.key)) != nil else { continue }
                let prior = settings![field.key]
                if prior["checks"]["screenshotOnBlock"].isNullish {
                    settings = settings!.setting(field.key, Self.deepMerge(prior, .object([.init("checks", .object([.init("screenshotOnBlock", field.value)]))])))
                }
            }
        }
    }
    public func config(_ profile: String) throws -> NativeRPCValue {
        _ = try BackendBrowserScrapingPaths.component(profile); try loadSettings()
        let value = Self.deepMerge(Self.emptySettings, settings?[profile] ?? .missing)
        return value.setting("capture", value["capture"].setting("directory", .string(try paths.capture(profile).path)))
            .setting("capabilities", .object([.init("metadataCapture", .bool(true)), .init("allResponseBodies", .bool(false)),
                .init("requestInterception", .bool(false)), .init("placeholderFulfillment", .bool(false)),
                .init("limitation", .string("WebKit resource timing observes a subset of completed resources. It cannot expose all response bodies or pause/fulfill HTTP requests."))]))
    }
    public func blockCapture(_ profile: String) throws -> Bool { try config(profile)["checks"]["screenshotOnBlock"].bool ?? true }
    private static func deepMerge(_ current: NativeRPCValue, _ patch: NativeRPCValue) -> NativeRPCValue {
        var result = current
        for field in patch.fields ?? [] {
            result = result.setting(field.key, field.value.fields == nil ? field.value : deepMerge(result[field.key], field.value))
        }
        return result
    }
    public func setConfig(_ profile: String, patch: NativeRPCValue) async throws -> NativeRPCValue {
        _ = try BackendBrowserScrapingPaths.component(profile); try loadSettings(); _ = try patch.requireObject("scraping patch")
        for field in patch.fields ?? [] where !["requests", "capture", "assets", "checks"].contains(field.key) {
            throw BackendBrowserScrapingError.invalid("Unknown scraping setting: \(field.key).")
        }
        let current = Self.deepMerge(Self.emptySettings, settings?[profile] ?? .missing)
        var next = Self.deepMerge(current, patch)
        let kinds = Set(["image", "media", "font", "stylesheet", "script", "xhr", "fetch"])
        var requests = NativeRPCValue.object([])
        for field in next["requests"].fields ?? [] {
            guard kinds.contains(field.key) else { throw BackendBrowserScrapingError.invalid("Unknown request kind: \(field.key).") }
            if field.value.isNullish { continue }
            let action = field.value.string == "cheap" ? "fulfill" : field.value.string
            guard let action, ["allow", "block", "fulfill"].contains(action) else { throw BackendBrowserScrapingError.invalid("Request actions are allow, block or fulfill.") }
            requests = requests.setting(field.key, .string(action))
        }
        next = next.setting("requests", requests)
        for path in [["capture", "on"], ["assets", "upgrade", "on"], ["assets", "ledger", "on"], ["assets", "ledger", "refetch"], ["checks", "coverage", "on"], ["checks", "screenshotOnBlock"]] {
            let value = path.reduce(next) { $0[$1] }
            guard value.isNullish || value.bool != nil else { throw BackendBrowserScrapingError.invalid(path.joined(separator: ".") + " must be boolean or null.") }
        }
        if !next["capture"]["keepMB"].isNullish {
            let number = BackendBrowserScrapingIO.integer(next["capture"]["keepMB"], default: 256, min: 1, max: 4_096)
            next = next.setting("capture", next["capture"].setting("keepMB", .number(Double(number))))
        }
        for text in [next["assets"]["upgrade"]["from"], next["assets"]["upgrade"]["to"], next["checks"]["coverage"]["pattern"]] {
            guard let value = text.string, value.count <= 512 else { throw BackendBrowserScrapingError.invalid("Rewrite and coverage patterns must be strings of at most 512 characters.") }
        }
        let pattern = next["checks"]["coverage"]["pattern"].string ?? ""
        if !pattern.isEmpty { try BackendBrowserScrapingRegex.validate(pattern) }
        let previous = settings!
        settings = previous.setting(profile, next)
        do {
            try BackendBrowserScrapingIO.write(.object([.init("version", .number(1)), .init("profiles", settings!)]),
                                              to: paths.dataRoot.appendingPathComponent("browser-scraping.json"), paths: paths)
        } catch { settings = previous; throw error }
        await changed(profile); return try config(profile)
    }
    public func ownRun(_ runID: String, profile: String) throws -> URL {
        let directory = try paths.run(runID), ownerURL = try paths.checked(directory.appendingPathComponent("profile"), createParent: true)
        _ = try BackendBrowserScrapingPaths.component(profile)
        if FileManager.default.fileExists(atPath: ownerURL.path) {
            let prior = String(data: try BackendBrowserScrapingIO.read(ownerURL, maxBytes: 1_024), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard prior == profile else { throw BackendBrowserScrapingError.denied("This scraping run belongs to a different profile.") }
        } else { try Data((profile + "\n").utf8).write(to: ownerURL, options: .withoutOverwriting) }
        return directory
    }
    public func runs(_ profile: String) throws -> [URL] {
        _ = try BackendBrowserScrapingPaths.component(profile)
        let root = try paths.checked(paths.dataRoot.appendingPathComponent("scrape/runs", isDirectory: true))
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { directory in
            _ = try paths.checked(directory)
            guard let data = try? BackendBrowserScrapingIO.read(directory.appendingPathComponent("profile"), maxBytes: 1_024),
                  let owner = String(data: data, encoding: .utf8) else { return false }
            return owner.trimmingCharacters(in: .whitespacesAndNewlines) == profile
        }
    }
    public func startCapture(profile: String, runID: String, pageURL: String, bounds: BackendBrowserCaptureBounds,
                             bodyKinds: Set<String>, visibility: String) throws -> UUID {
        let directory = try paths.checked(paths.capture(profile, runID))
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NativeRPCError(code: "capture-exists", message: "Use a new capture run ID; an existing manifest is never overwritten.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        captures[id] = Capture(profile: profile, id: runID, directory: directory, startURL: pageURL,
                               started: BackendBrowserScrapingIO.now(), bounds: bounds, bodyKinds: bodyKinds, visibility: visibility)
        return id
    }
    public func denyObservation(_ captureID: UUID) { if captures[captureID] != nil { captures[captureID]!.denied += 1 } }
    public func record(_ captureID: UUID, response: BackendBrowserNetworkResponse) throws {
        guard var run = captures[captureID] else { throw NativeRPCError(code: "capture-closed", message: "This capture is closed.") }
        guard run.counts["entries", default: 0] < run.bounds.maxEntries else { run.overflow += 1; captures[captureID] = run; return }
        let sequence = run.counts["entries", default: 0] + 1
        var bodyState = "not-requested", bodyPath = "", message = ""
        if run.bodyKinds.contains(response.kind) {
            if let body = response.body {
                if body.count > run.bounds.maxBodyBytes { bodyState = "too-large"; message = "Response exceeds the per-body bound of \(run.bounds.maxBodyBytes) bytes." }
                else if run.counts["bytes", default: 0] + body.count > run.bounds.maxTotalBytes { bodyState = "over-budget"; message = "Capture reached its total byte budget of \(run.bounds.maxTotalBytes)." }
                else {
                    bodyPath = "bodies/\(sequence).body"
                    let file = try paths.checked(run.directory.appendingPathComponent(bodyPath), createParent: true)
                    try body.write(to: file, options: .withoutOverwriting)
                    bodyState = "saved"; run.counts["bytes", default: 0] += body.count
                }
            } else { bodyState = "lost"; message = response.bodyFailure ?? "WebKit did not expose this response body through a public API." }
        }
        let safeHeaders = Set(["content-type", "content-length", "content-disposition", "content-encoding", "content-range", "etag", "last-modified", "link", "x-total-count", "x-total-results"])
        let headers = response.headers.compactMap { key, value -> NativeRPCValue.Field? in
            safeHeaders.contains(key.lowercased()) ? .init(key.lowercased(), .string(String(value.prefix(400)))) : nil
        }
        let entry = NativeRPCValue.object([.init("n", .number(Double(sequence))), .init("url", .string(response.url.absoluteString)),
            .init("method", .string(response.method ?? "")), .init("kind", .string(response.kind)),
            .init("status", .number(Double(response.status ?? 0))), .init("mimeType", .string(response.mimeType ?? "")),
            .init("bytes", .number(Double(response.body?.count ?? response.bytes ?? 0))), .init("bodyState", .string(bodyState)),
            .init("bodyPath", .string(bodyPath)), .init("headers", .object(headers)), .init("message", .string(message)),
            .init("at", .number(BackendBrowserScrapingIO.now())), .init("observationSource", .string(response.source)),
            .init("statusMeasured", .bool(response.status != nil)), .init("bytesMeasured", .bool(response.body != nil || response.bytes != nil))])
        do { try BackendBrowserScrapingIO.append(entry, to: run.directory.appendingPathComponent("capture.jsonl"), paths: paths) }
        catch {
            // A written body without a manifest is not a recorded success.
            if !bodyPath.isEmpty { try? FileManager.default.removeItem(at: run.directory.appendingPathComponent(bodyPath)) }
            throw error
        }
        run.counts["entries", default: 0] += 1
        let countKey = ["saved": "bodies", "too-large": "tooLarge", "over-budget": "overBudget", "lost": "lost", "not-requested": "notRequested"][bodyState] ?? "failed"
        run.counts[countKey, default: 0] += 1; captures[captureID] = run
    }
    private func captureValue(_ run: Capture, endURL: String, title: String, ended: Double?) -> NativeRPCValue {
        let dropped = run.counts["lost", default: 0] + run.counts["tooLarge", default: 0] + run.counts["overBudget", default: 0] + run.overflow
        var shortfalls: [String] = []
        if dropped > 0 { shortfalls.append("\(dropped) observations lacked bodies or exceeded the capture bounds.") }
        if run.denied > 0 { shortfalls.append("\(run.denied) observations were excluded by origin/profile grants.") }
        if run.visibility != "explicit-fetch" { shortfalls.append("WebKit resource timing is partial metadata; full traffic and response bodies are not exposed.") }
        let empty = run.counts["entries", default: 0] == 0
        var value = NativeRPCValue.object(run.counts.keys.sorted().map { .init($0, .number(Double(run.counts[$0]!))) })
        value = value.merging(.object([.init("dir", .string(run.directory.path)), .init("manifest", .string(run.directory.appendingPathComponent("capture.jsonl").path)),
            .init("page", .object([.init("armedUrl", .string(run.startURL)), .init("stoppedUrl", .string(endURL)), .init("title", .string(title))])),
            .init("startedAt", .number(run.started)), .init("endedAt", ended.map(NativeRPCValue.number) ?? .null),
            .init("incomplete", .bool(!shortfalls.isEmpty)), .init("shortfall", .string(shortfalls.joined(separator: " "))),
            .init("empty", .bool(empty)), .init("emptyReason", .string(empty ? "No resources were observed during this capture. Load a page after arming; unobservable traffic is not counted." : "")),
            .init("dropped", .number(Double(run.overflow))), .init("excludedByGrants", .number(Double(run.denied))),
            .init("visibility", .string(run.visibility)), .init("unobserved", .null)]))
        return value
    }
    public func captureSnapshot(_ id: UUID) throws -> NativeRPCValue {
        guard let run = captures[id] else { throw NativeRPCError(code: "capture-closed", message: "This capture is closed.") }
        return captureValue(run, endURL: "", title: "", ended: nil)
    }
    public func stopCapture(_ id: UUID, pageURL: String, title: String, termination: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        guard let run = captures[id] else { throw NativeRPCError(code: "capture-closed", message: "There is no capture to stop.") }
        var value = captureValue(run, endURL: pageURL, title: title, ended: BackendBrowserScrapingIO.now())
        for field in termination.fields ?? [] where ["retiredBecause", "tabClosed", "revoked", "finalMetadataRead"].contains(field.key) {
            value = value.setting(field.key, field.value)
        }
        try BackendBrowserScrapingIO.write(value, to: run.directory.appendingPathComponent("capture-summary.json"), paths: paths)
        captures[id] = nil; await changed(run.profile); return value
    }
    public func status(_ profile: String, workers: NativeRPCValue) throws -> NativeRPCValue {
        let captureRoot = try paths.checked(paths.capture(profile)), runFolders = FileManager.default.fileExists(atPath: captureRoot.path)
            ? try FileManager.default.contentsOfDirectory(at: captureRoot, includingPropertiesForKeys: nil) : []
        var capturesValue: NativeRPCValue = .null, recorded = 0.0, bytes = 0.0, dropped = 0.0, open = false, reasons: [String] = []
        for directory in runFolders {
            _ = try paths.checked(directory)
            let summaryURL = directory.appendingPathComponent("capture-summary.json")
            guard let data = try? BackendBrowserScrapingIO.read(summaryURL, maxBytes: 1_048_576), let summary = try? NativeRPCValue.parseJSON(data) else { open = true; continue }
            recorded += summary["entries"].number ?? 0; bytes += summary["bytes"].number ?? 0
            dropped += (summary["lost"].number ?? 0) + (summary["tooLarge"].number ?? 0) + (summary["overBudget"].number ?? 0) + (summary["dropped"].number ?? 0)
            if let reason = summary["shortfall"].string, !reason.isEmpty { reasons.append(reason) }
        }
        if !runFolders.isEmpty {
            capturesValue = .object([.init("recorded", open ? .null : .number(recorded)), .init("bytes", open ? .null : .number(bytes)),
                .init("dropped", open ? .null : .number(dropped)), .init("droppedReason", .string(reasons.joined(separator: " "))), .init("scope", .string("observed WebKit metadata only"))])
        }
        var ledgerEntries: Int? = nil, lastCheck: NativeRPCValue = .null
        for run in try runs(profile) {
            if let rows = try? BackendBrowserScrapingIO.lines(run.appendingPathComponent("ledger.jsonl")) {
                ledgerEntries = (ledgerEntries ?? 0) + Set(rows.compactMap { $0["url"].string }).count
            }
            for check in (try? BackendBrowserScrapingIO.lines(run.appendingPathComponent("coverage.jsonl"))) ?? [] {
                if (check["at"].number ?? 0) > (lastCheck["at"].number ?? 0) { lastCheck = check }
            }
        }
        let batch = batches[profile]
        var assetFacts: NativeRPCValue = .null
        if batch != nil || ledgerEntries != nil {
            assetFacts = .object(["fetched", "upgraded", "fellBack", "skipped"].map { .init($0, batch?[$0].map { .number(Double($0)) } ?? .null) })
                .setting("ledgerEntries", ledgerEntries.map { .number(Double($0)) } ?? .null)
        }
        let rows = workers["workers"].elements ?? []
        return .object([.init("workers", .array(rows.map { row in .object([.init("id", row["profileId"]), .init("profileId", row["profileId"]),
            .init("state", .string(row["busy"].bool == true ? "busy" : "idle")), .init("requests", .null),
            .init("lastAt", (row["lastReleasedAt"].number ?? 0) == 0 ? .null : row["lastReleasedAt"])]) })),
            .init("capture", capturesValue), .init("assets", assetFacts), .init("lastCheck", lastCheck == .null ? .null :
                .object([.init("url", lastCheck["url"]), .init("stated", lastCheck["stated"]), .init("got", lastCheck["captured"]), .init("at", lastCheck["at"])]))])
    }
    public func noteBatch(_ profile: String, tally: NativeRPCValue) async {
        var prior = batches[profile] ?? ["fetched": 0, "upgraded": 0, "fellBack": 0, "skipped": 0]
        for key in prior.keys { prior[key, default: 0] += Int(tally[key].number ?? 0) }
        batches[profile] = prior; await changed(profile)
    }
    public func clearCapture(_ profile: String) async throws -> NativeRPCValue {
        guard !captures.values.contains(where: { $0.profile == profile }) else { throw NativeRPCError(code: "capture-active", message: "Stop this profile's active captures before clearing them.") }
        let root = try paths.checked(paths.capture(profile)); var removed = 0
        if FileManager.default.fileExists(atPath: root.path) {
            for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                _ = try paths.checked(directory); try FileManager.default.removeItem(at: directory); removed += 1
            }
        }
        await changed(profile)
        return .object([.init("ok", .bool(true)), .init("count", .number(Double(removed))), .init("cleared", .number(Double(removed))),
            .init("message", .string(removed == 0 ? "There was nothing captured for this profile." : "\(removed) capture runs cleared.")), .init("empty", .bool(removed == 0))])
    }
    public func clearLedgers(_ profile: String) async throws -> NativeRPCValue {
        var removed = 0
        for run in try runs(profile) {
            let ledger = try paths.checked(run.appendingPathComponent("ledger.jsonl"))
            if FileManager.default.fileExists(atPath: ledger.path) { try FileManager.default.removeItem(at: ledger); removed += 1 }
        }
        batches[profile] = nil; await changed(profile)
        return .object([.init("ok", .bool(true)), .init("count", .number(Double(removed))), .init("cleared", .number(Double(removed))),
            .init("message", .string(removed == 0 ? "This profile has no ledger to empty." : "\(removed) ledgers emptied. Asset files remain in place.")),
            .init("assetsDeleted", .bool(false)), .init("empty", .bool(removed == 0))])
    }
    public func appendRun(_ runID: String, profile: String, file: String, value: NativeRPCValue) throws {
        guard ["ledger.jsonl", "coverage.jsonl"].contains(file) else { throw BackendBrowserScrapingError.invalid("Unknown run record.") }
        try BackendBrowserScrapingIO.append(value, to: ownRun(runID, profile: profile).appendingPathComponent(file), paths: paths)
    }
    public func readRun(_ runID: String, profile: String, file: String) throws -> [NativeRPCValue] {
        guard ["ledger.jsonl", "coverage.jsonl"].contains(file) else { throw BackendBrowserScrapingError.invalid("Unknown run record.") }
        let url = try paths.checked(ownRun(runID, profile: profile).appendingPathComponent(file))
        return FileManager.default.fileExists(atPath: url.path) ? try BackendBrowserScrapingIO.lines(url) : []
    }
    /// The caller already authorized the page and profile before taking a shot.
    /// Never solve challenges or write a screenshot into another profile.
    public func recordBlock(profile: String, evidence: NativeRPCValue, png: Data?, note: String) async throws -> NativeRPCValue? {
        let now = BackendBrowserScrapingIO.now()
        guard now - (blockAt[profile] ?? 0) >= 60_000 else { return nil }
        guard let verdict = Self.blockVerdict(evidence) else { return nil }
        let root = try paths.blocks(profile), id = UUID().uuidString
        let sidecar = try paths.checked(root.appendingPathComponent(id + ".json"), createParent: true)
        var picture = "", failure = note
        if let png {
            guard png.count <= 32 * 1_024 * 1_024 else { throw BackendBrowserScrapingError.invalid("Block screenshot exceeds 32 MiB.") }
            let destination = try paths.checked(root.appendingPathComponent(id + ".png"), createParent: true)
            try png.write(to: destination, options: .withoutOverwriting); picture = destination.path
        } else if failure.isEmpty { failure = "WebKit could not take a screenshot." }
        let value = NativeRPCValue.object([.init("at", .number(now)), .init("path", .string(picture)), .init("sidecar", .string(sidecar.path)),
            .init("evidence", evidence), .init("verdict", verdict), .init("note", .string(failure))])
        try BackendBrowserScrapingIO.write(value, to: sidecar, paths: paths)
        try BackendBrowserScrapingIO.append(value, to: root.appendingPathComponent("blocks.jsonl"), paths: paths)
        blockAt[profile] = now; await changed(profile); return value
    }
    public static func blockVerdict(_ evidence: NativeRPCValue) -> NativeRPCValue? {
        let status = Int(evidence["httpStatus"].number ?? 0), url = ((evidence["finalUrl"].string ?? "") + " " + (evidence["requestedUrl"].string ?? "")).lowercased()
        let text = (evidence["text"].string ?? "").lowercased()
        let markers = ["verify you are human", "are you a robot", "unusual traffic", "rate limit exceeded", "access denied", "checking your browser", "enable javascript and cookies to continue", "select all squares", "was made by a human", "i am not a robot", "complete the following challenge"]
        let urlMarkers = ["/cdn-cgi/challenge-platform/", "__cf_chl", "challenges.cloudflare.com", "/_incapsula_resource", "/_sec/cp_challenge", "geo.captcha-delivery.com", "/px/captcha", "/distil_r_captcha", "/recaptcha/api2/"]
        let reason: String?
        if !evidence["failed"].isNullish, let code = evidence["failed"]["code"].number, code != 0 {
            reason = "Navigation failed: " + (evidence["failed"]["description"].string ?? String(Int(code)))
        }
        else if [401, 403, 407, 429, 451, 503].contains(status) { reason = "HTTP \(status)" }
        else if let marker = urlMarkers.first(where: { url.contains($0) }) { reason = "Challenge URL contains \(marker)." }
        else if (evidence["textLength"].number ?? Double(text.count)) <= 2_000,
                let marker = markers.first(where: { text.contains($0) }) { reason = "Page text contains \(marker)." }
        else { reason = nil }
        return reason.map { .object([.init("blocked", .bool(true)), .init("signals", .array([.string($0)])), .init("reason", .string($0)), .init("source", .string("observed-page"))]) }
    }
    public func blocks(_ profile: String, limit: Int, since: Double) throws -> NativeRPCValue {
        let rows = try blockRecords(profile)
        return .object([.init("blocks", .array(Array(rows.filter { ($0["at"].number ?? 0) >= since }.sorted { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }.prefix(max(1, min(limit, 200))))))])
    }
    /// Facades must authorize the profile and each record's page origin before
    /// exposing these private sidecars. Unassigned legacy-root rows are absent.
    public func blockRecords(_ profile: String) throws -> [NativeRPCValue] {
        let file = try paths.checked(paths.blocks(profile).appendingPathComponent("blocks.jsonl"))
        return FileManager.default.fileExists(atPath: file.path) ? try BackendBrowserScrapingIO.lines(file) : []
    }
}
