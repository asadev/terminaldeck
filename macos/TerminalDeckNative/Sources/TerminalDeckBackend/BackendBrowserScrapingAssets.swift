import Foundation
import TerminalDeckNativeCore

/// The fetch adapter must use the exact app-owned WebKit profile, apply the
/// caller's origin grant BEFORE each redirect and refuse an oversized body.
/// It may not use a global/shared URLSession cookie store as a substitute.
public struct BackendBrowserAssetResponse: Sendable {
    public let finalURL: URL
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let complete: Bool
    public let image: BackendBrowserAssetImage?
    public init(finalURL: URL, status: Int, headers: [String: String], body: Data, complete: Bool, image: BackendBrowserAssetImage? = nil) {
        self.finalURL = finalURL; self.status = status; self.headers = headers; self.body = body; self.complete = complete
        self.image = image
    }
    public func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

public struct BackendBrowserAssetHooks: Sendable {
    /// Transport/bookkeeping scope only, never a real website profile or store.
    /// Source assets without profileId use public requests with NO login cookies.
    public static let publicProfileID = "public"
    public let resolveProfile: @Sendable (BackendBrowserScrapingCaller, String?) async throws -> String
    public let fetch: @Sendable (BackendBrowserScrapingCaller, String, URL, String, Int) async throws -> BackendBrowserAssetResponse
    public let probe: @Sendable (BackendBrowserScrapingCaller, String, URL, Bool) async throws -> BackendBrowserRenditionProbe?
    /// Return an explicitly granted path; security-scoped bookmarks belong to
    /// the caller's file/download service, not this bookkeeping service.
    public let directory: @Sendable (BackendBrowserScrapingCaller, String) async throws -> URL
    public let file: @Sendable (BackendBrowserScrapingCaller, String) async throws -> URL
    public let authorize: BackendBrowserScrapingAuthorize
    public init(resolveProfile: @escaping @Sendable (BackendBrowserScrapingCaller, String?) async throws -> String,
                fetch: @escaping @Sendable (BackendBrowserScrapingCaller, String, URL, String, Int) async throws -> BackendBrowserAssetResponse,
                probe: @escaping @Sendable (BackendBrowserScrapingCaller, String, URL, Bool) async throws -> BackendBrowserRenditionProbe?,
                directory: @escaping @Sendable (BackendBrowserScrapingCaller, String) async throws -> URL,
                file: @escaping @Sendable (BackendBrowserScrapingCaller, String) async throws -> URL,
                authorize: @escaping BackendBrowserScrapingAuthorize) {
        self.resolveProfile = resolveProfile; self.fetch = fetch; self.probe = probe; self.directory = directory; self.file = file; self.authorize = authorize
    }
}

/// No orchestration/retries/crawling. Each supplied URL is processed once and
/// every failed upgrade falls back to the original. Raw bytes are never resized.
public actor BackendBrowserScrapingAssets {
    public static let bodyLimit = 64 * 1_024 * 1_024
    private let store: BackendBrowserScrapingStore
    private let hooks: BackendBrowserAssetHooks
    private var fetching: Set<String> = []
    public init(store: BackendBrowserScrapingStore, hooks: BackendBrowserAssetHooks) { self.store = store; self.hooks = hooks }

    private func profile(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller, operation: String) async throws -> String {
        guard !caller.remote else { throw BackendBrowserScrapingError.denied("Asset operations work on local files and are not granted to paired devices.") }
        try await hooks.authorize(caller, operation, nil, nil, args)
        let profile = try await hooks.resolveProfile(caller, args["profileId"].string)
        _ = try BackendBrowserScrapingPaths.component(profile)
        try await hooks.authorize(caller, operation, profile, nil, args)
        return profile
    }
    private struct Candidate: Sendable { let url: URL; let ruleID: String }
    private func candidates(_ original: URL, args: NativeRPCValue, profile: String) async throws -> [Candidate] {
        var rules = args["rules"].isNullish ? [] : try args["rules"].requireArray("rendition rules")
        if args["rules"].isNullish {
            let config = try await store.config(profile)
            if config["assets"]["upgrade"]["on"].bool == true,
               let from = config["assets"]["upgrade"]["from"].string, !from.isEmpty,
               let to = config["assets"]["upgrade"]["to"].string {
                rules = [.object([.init("id", .string("profile-rewrite")), .init("pattern", .string(NSRegularExpression.escapedPattern(for: from))),
                    .init("replace", .string(to)), .init("literal", .bool(true)), .init("from", .string(from))])]
            }
        }
        guard rules.count <= 32 else { throw BackendBrowserScrapingError.invalid("At most 32 rendition rules may be supplied.") }
        rules = try rules.map { rule in
            _ = try rule.requireObject("rendition rule")
            let id = try rule["id"].requireString("rendition rule id").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw BackendBrowserScrapingError.invalid("Every rendition rule needs a nonempty ID.") }
            return rule.setting("id", .string(id))
        }
        var result: [Candidate] = [], seen: Set<String> = [], ruleIDs: Set<String> = []
        for rule in rules {
            let id = try rule["id"].requireString("rendition rule id", nonempty: true)
            guard ruleIDs.insert(id).inserted else { throw BackendBrowserScrapingError.invalid("Rendition rule IDs must be unique.") }
        }
        func rewrite(_ source: String, rule: NativeRPCValue) throws -> String {
            let pattern = try (rule["match"].isNullish ? rule["pattern"] : rule["match"]).requireString("rendition match", nonempty: true)
            let replacement = rule["replace"].string ?? rule["replacement"].string ?? ""
            guard pattern.count <= 512, replacement.count <= 512 else { throw BackendBrowserScrapingError.invalid("Rendition patterns are bounded to 512 characters.") }
            let flags = rule["flags"].string ?? ""
            guard Set(flags).isSubset(of: Set("gimsuy")) else { throw BackendBrowserScrapingError.invalid("Rendition rule flags must be source-supported g/i/m/s/u/y.") }
            if rule["literal"].bool == true, let from = rule["from"].string {
                return source.replacingOccurrences(of: from, with: replacement)
            }
            return try BackendBrowserScrapingRendition.replacing(source, pattern: pattern, replacement: replacement, flags: flags)
        }
        if rules.count > 1 {
            var combined = original.absoluteString, used: [String] = []
            for rule in rules {
                let next = try rewrite(combined, rule: rule)
                if next != combined { used.append(rule["id"].string!) }; combined = next
            }
            if used.count > 1 && combined != original.absoluteString {
                result.append(Candidate(url: try BackendBrowserScrapingIO.httpURL(combined), ruleID: used.joined(separator: "+"))); seen.insert(combined)
            }
        }
        for rule in rules {
            let source = original.absoluteString, replaced = try rewrite(source, rule: rule)
            if replaced == source || seen.contains(replaced) { continue }
            let url = try BackendBrowserScrapingIO.httpURL(replaced)
            seen.insert(replaced); result.append(Candidate(url: url, ruleID: rule["id"].string!))
        }
        result.append(Candidate(url: original, ruleID: "")); return result
    }
    private func response(_ url: URL, method: String, profile: String, caller: BackendBrowserScrapingCaller,
                          operation: String, args: NativeRPCValue) async throws -> BackendBrowserAssetResponse {
        try Task.checkCancellation()
        try await hooks.authorize(caller, operation, profile, url, args)
        let response = try await hooks.fetch(caller, profile, url, method, Self.bodyLimit)
        try Task.checkCancellation()
        _ = try BackendBrowserScrapingIO.httpURL(response.finalURL.absoluteString)
        try await hooks.authorize(caller, operation, profile, response.finalURL, args)
        guard response.complete, response.body.count <= Self.bodyLimit else {
            throw NativeRPCError(code: "asset-too-large", message: "The WebKit fetch returned an incomplete body or exceeded the explicit 64 MiB asset limit; no file/ledger success was recorded.")
        }
        if method == "GET", (response.header("content-encoding") ?? "identity").lowercased() == "identity",
           let stated = response.header("content-length").flatMap(Int.init), stated > response.body.count {
            throw NativeRPCError(code: "asset-truncated", message: "Only \(response.body.count) bytes arrived of the \(stated) the server promised.")
        }
        return response
    }
    private func validateQuality(_ args: NativeRPCValue) throws {
        for (name, ceiling) in [("minBytes", Double(Self.bodyLimit)), ("minWidth", 1_000_000_000.0), ("minHeight", 1_000_000_000.0), ("minByteRatio", 1_000_000.0)] where args.has(name) {
            guard let value = args[name].number, value >= 0, value <= ceiling else { throw BackendBrowserScrapingError.invalid("\(name) must be a non-negative number within the native quality bound of \(ceiling).") }
        }
        for name in ["requireLarger", "requireLargerDimensions"] where args.has(name) {
            guard args[name].bool != nil else { throw BackendBrowserScrapingError.invalid("\(name) must be boolean.") }
        }
    }
    private struct Choice: Sendable {
        let index: Int; let reachable: Bool; let fellBack: Bool; let verdict: BackendBrowserScrapingRendition.Verdict
        let original: BackendBrowserRenditionProbe?; let attempts: [NativeRPCValue]
        let probes: [String: BackendBrowserRenditionProbe]
    }
    private func choose(_ original: URL, choices: [Candidate], args: NativeRPCValue, profile: String,
                        caller: BackendBrowserScrapingCaller, operation: String) async throws -> Choice {
        let dimensions = args["minWidth"].number != nil || args["minHeight"].number != nil || args["requireLargerDimensions"].bool == true
        func probe(_ url: URL) async throws -> BackendBrowserRenditionProbe? {
            try Task.checkCancellation(); try await hooks.authorize(caller, operation, profile, url, args)
            let reply = try await hooks.probe(caller, profile, url, dimensions)
            if let reply { try await hooks.authorize(caller, operation, profile, reply.finalURL, args) }
            return reply
        }
        let compare = args["requireLarger"].bool != false || args["minByteRatio"].number != nil || args["requireLargerDimensions"].bool == true
        let needOriginal = compare && choices.contains { !$0.ruleID.isEmpty }
        var originalProbe: BackendBrowserRenditionProbe?, probes: [String: BackendBrowserRenditionProbe] = [:], attempts: [NativeRPCValue] = []
        if needOriginal {
            originalProbe = try await probe(original)
            if let originalProbe { probes[original.absoluteString] = originalProbe }
        }
        for (index, candidate) in choices.enumerated() {
            let isOriginal = candidate.ruleID.isEmpty
            let measured = isOriginal && needOriginal ? originalProbe : try await probe(candidate.url)
            if let measured { probes[candidate.url.absoluteString] = measured }
            let verdict = BackendBrowserScrapingRendition.accepts(url: candidate.url, probe: measured, original: originalProbe, arguments: args, isOriginal: isOriginal)
            attempts.append(verdict.wire.merging(.object([.init("url", .string(candidate.url.absoluteString)), .init("ruleId", .string(candidate.ruleID)),
                .init("status", measured.map { .number(Double($0.status)) } ?? .null), .init("bytes", measured?.bytes.map { .number(Double($0)) } ?? .null),
                .init("probe", measured?.wire ?? .null)])))
            if verdict.ok { return .init(index: index, reachable: true, fellBack: isOriginal && index > 0, verdict: verdict, original: originalProbe, attempts: attempts, probes: probes) }
        }
        // A failed probe never discards the asset. The caller can still GET the
        // whole candidate list when HEAD/range did not produce a usable choice.
        return .init(index: max(0, choices.count - 1), reachable: false, fellBack: choices.count > 1,
                     verdict: .init(ok: false, reason: "No probe held; fetch the original or try the real GET fallbacks.", comparedBytes: false, comparedDimensions: false, byteRatio: nil),
                     original: originalProbe, attempts: attempts, probes: probes)
    }
    public func rendition(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try validateQuality(args)
        let profile = try await profile(args, caller: caller, operation: "assets.rendition")
        let original = try BackendBrowserScrapingIO.httpURL(args["url"].requireString("url", nonempty: true))
        let candidates = try await candidates(original, args: args, profile: profile)
        let choice = try await choose(original, choices: candidates, args: args, profile: profile, caller: caller, operation: "assets.rendition")
        let candidate = candidates[choice.index], upgraded = !candidate.ruleID.isEmpty
        let line = !choice.reachable ? "Nothing answered the probes. The original URL remains available for a real GET."
            : upgraded ? "Upgraded by \(candidate.ruleID)." + (choice.verdict.comparedBytes ? " Its measured length is larger." : " Response lengths were not compared.")
            : choice.fellBack ? "No upgrade held; use the original URL." : "No rewrite changed this URL; use the original."
        return .object([.init("url", .string(candidate.url.absoluteString)), .init("ruleId", .string(candidate.ruleID)), .init("upgraded", .bool(upgraded)),
            .init("fellBack", .bool(choice.fellBack)), .init("reachable", .bool(choice.reachable)), .init("comparedBytes", .bool(choice.verdict.comparedBytes)),
            .init("comparedDimensions", .bool(choice.verdict.comparedDimensions)), .init("byteRatio", choice.verdict.byteRatio.map(NativeRPCValue.number) ?? .null),
            .init("originalUrl", .string(original.absoluteString)), .init("attempts", .array(choice.attempts)), .init("line", .string(line)),
            .init("originalProbe", choice.original?.wire ?? .null), .init("chosenProbe", choice.probes[candidate.url.absoluteString]?.wire ?? .null)])
    }
    private func latestLedger(_ runID: String, profile: String) async throws -> [String: NativeRPCValue] {
        var rows: [String: NativeRPCValue] = [:]
        for row in try await store.readRun(runID, profile: profile, file: "ledger.jsonl") {
            if let key = row["url"].string, row["digest"].string?.hasPrefix("sha256:") == true, row["path"].string != nil { rows[key] = row }
        }
        return rows
    }
    private func decision(_ url: String, row: NativeRPCValue?, args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        if args["mode"].string == "refetch" { return decisionValue("fetch", "refetch-requested", row: row) }
        guard let row else { return decisionValue("fetch", "not-in-ledger", row: nil) }
        if let expected = args["expectDigest"].string, expected != row["digest"].string { return decisionValue("fetch", "digest-not-expected", row: row) }
        let file = try await hooks.file(caller, row["path"].requireString("ledger file", nonempty: true))
        guard FileManager.default.fileExists(atPath: file.path) else { return decisionValue("fetch", "file-missing", row: row) }
        do {
            let fingerprint = try BackendBrowserScrapingIO.fingerprint(file)
            guard Double(fingerprint.bytes) == row["bytes"].number else { return decisionValue("fetch", "wrong-size", row: row) }
            guard fingerprint.digest == row["digest"].string else { return decisionValue("fetch", "wrong-digest", row: row) }
            return decisionValue("skip", "verified", row: row)
        } catch is CancellationError { throw CancellationError() }
        catch { return decisionValue("fetch", "unreadable", row: row) }
    }
    private func decisionValue(_ action: String, _ reason: String, row: NativeRPCValue?) -> NativeRPCValue {
        .object([.init("action", .string(action)), .init("reason", .string(reason)), .init("entry", row ?? .null),
            .init("line", .string(reason == "verified" ? "File length and SHA-256 match the recorded bytes; skip this URL." : "Fetch this URL: " + reason + "."))])
    }
    private func record(runID: String, profile: String, url: String, fetchedURL: String, ruleID: String, file: URL,
                        caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let approved = try await hooks.file(caller, file.path)
        let fingerprint = try BackendBrowserScrapingIO.fingerprint(approved)
        let row = NativeRPCValue.object([.init("url", .string(url)), .init("fetchedUrl", .string(fetchedURL)), .init("ruleId", .string(ruleID)),
            .init("digest", .string(fingerprint.digest)), .init("bytes", .number(Double(fingerprint.bytes))), .init("path", .string(approved.path)), .init("at", .number(BackendBrowserScrapingIO.now()))])
        try await store.appendRun(runID, profile: profile, file: "ledger.jsonl", value: row); return row
    }
    public func ledger(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let operation = args["op"].string ?? "summary"
        guard ["decide", "record", "verify", "summary"].contains(operation) else { throw BackendBrowserScrapingError.invalid("Ledger op is decide, record, verify or summary.") }
        if args.has("mode"), !["resume", "refetch"].contains(args["mode"].string ?? "") { throw BackendBrowserScrapingError.invalid("Ledger mode is resume or refetch.") }
        let profile = try await profile(args, caller: caller, operation: "assets.ledger." + operation)
        let run = try args["runId"].requireString("runId", nonempty: true)
        if operation == "record" {
            let url = try BackendBrowserScrapingIO.httpURL(args["url"].requireString("url", nonempty: true))
            let fetched = try BackendBrowserScrapingIO.httpURL(args["fetchedUrl"].string ?? url.absoluteString)
            try await hooks.authorize(caller, "assets.ledger.record", profile, url, args)
            try await hooks.authorize(caller, "assets.ledger.record", profile, fetched, args)
            let file = try await hooks.file(caller, args["path"].requireString("path", nonempty: true))
            return try await record(runID: run, profile: profile, url: url.absoluteString, fetchedURL: fetched.absoluteString, ruleID: args["ruleId"].string ?? "", file: file, caller: caller)
        }
        let rows = args["mode"].string == "refetch" && operation == "decide" ? [:] : try await latestLedger(run, profile: profile)
        if operation == "decide" {
            let url = try BackendBrowserScrapingIO.httpURL(args["url"].requireString("url", nonempty: true))
            try await hooks.authorize(caller, "assets.ledger.decide", profile, url, args)
            return try await decision(url.absoluteString, row: rows[url.absoluteString], args: args, caller: caller)
        }
        var findings: [NativeRPCValue] = []
        if operation == "verify" {
            for (url, row) in rows.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation(); let resource = try BackendBrowserScrapingIO.httpURL(url)
                try await hooks.authorize(caller, "assets.ledger.verify", profile, resource, args)
                let result = try await decision(url, row: row, args: .object([]), caller: caller)
                findings.append(result.setting("url", .string(url)))
            }
        }
        let verified = findings.filter { $0["reason"].string == "verified" }.count, bad = findings.count - verified
        return .object([.init("runId", .string(run)), .init("entries", .number(Double(rows.count))), .init("verified", operation == "verify" ? .number(Double(verified)) : .null),
            .init("bad", operation == "verify" ? .number(Double(bad)) : .null), .init("complete", .bool(operation == "verify" && bad == 0 && !findings.isEmpty)),
            .init("empty", .bool(rows.isEmpty)), .init("emptyReason", .string(rows.isEmpty ? "This run has no recorded assets." : "")), .init("findings", .array(findings))])
    }
    public func coverage(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        guard ["check", "summary"].contains(args["op"].string ?? "check") else { throw BackendBrowserScrapingError.invalid("Coverage op is check or summary.") }
        let profile = try await profile(args, caller: caller, operation: "assets.coverage"), run = try args["runId"].requireString("runId", nonempty: true)
        if args["op"].string == "summary" {
            let rows = try await store.readRun(run, profile: profile, file: "coverage.jsonl")
            return .object([.init("checks", .array(rows)), .init("complete", .bool(!rows.isEmpty && rows.allSatisfy { $0["verdict"].string == "complete" })), .init("empty", .bool(rows.isEmpty))])
        }
        guard let capturedNumber = args["captured"].number, capturedNumber >= 0, capturedNumber <= 1_000_000_000 else {
            throw BackendBrowserScrapingError.invalid("captured must be a non-negative measured count.")
        }
        var stated = args["stated"].number
        if let stated, stated < 0 || stated > 9_007_199_254_740_991 { throw BackendBrowserScrapingError.invalid("stated must be a non-negative safe integer count.") }
        var totalReason: String?
        if stated == nil {
            let text = args["text"].string ?? ""
            guard text.utf8.count <= 1_048_576 else { throw BackendBrowserScrapingError.invalid("Coverage text exceeds 1 MiB.") }
            let config = try await store.config(profile)
            let storedPattern = config["checks"]["coverage"]["on"].bool == true ? config["checks"]["coverage"]["pattern"].string ?? "" : ""
            let pattern = args["pattern"].string ?? storedPattern
            let patterns = pattern.isEmpty ? [#"\bof\s+([\d][\d.,\u202f\u00a0 ]*\d|\d)\b"#,
                #"\b([\d][\d.,\u202f\u00a0 ]*\d|\d)\s+(?:results?|items?|listings?|records?|entries)\b"#,
                #"\b([\d][\d.,\u202f\u00a0 ]*\d|\d)\s+total\b"#] : [pattern]
            var totals: Set<Double> = []
            let flags = pattern.isEmpty ? "i" : args["flags"].string ?? ""
            for pattern in patterns {
                guard pattern.count <= 512 else { throw BackendBrowserScrapingError.invalid("Coverage pattern exceeds 512 characters.") }
                do {
                    if let captured = try BackendBrowserScrapingRegex.firstCapture(text, pattern: pattern, flags: flags),
                       let number = BackendBrowserScrapingRegex.total(captured) { totals.insert(number) }
                } catch let error as NativeRPCError where error.code == "invalid-arguments" {
                    totalReason = error.message; totals.removeAll(); break
                }
            }
            if totals.count == 1 { stated = totals.first }
        }
        let captured = capturedNumber.rounded(.towardZero), tolerance = max(0, args["tolerance"].number ?? 0).rounded(.towardZero)
        let missing = stated.map { $0.rounded(.towardZero) - captured }
        let verdict = missing.map { $0 > tolerance ? "short" : ($0 < 0 ? "over" : "complete") } ?? "unknown"
        let line: String
        if let stated { line = "\(Int(captured)) captured; the page stated \(Int(stated)). Coverage is \(verdict)." }
        else { line = "\(Int(captured)) captured, but no unambiguous total was found on the page. This run cannot be called complete." + (totalReason.map { " " + $0 } ?? "") }
        let page = args["pageUrl"].string ?? ""
        if !page.isEmpty { try await hooks.authorize(caller, "assets.coverage", profile, BackendBrowserScrapingIO.httpURL(page), args) }
        let value = NativeRPCValue.object([.init("verdict", .string(verdict)), .init("stated", stated.map(NativeRPCValue.number) ?? .null),
            .init("captured", .number(captured)), .init("missing", missing.map(NativeRPCValue.number) ?? .null),
            .init("ratio", stated.flatMap { $0 == 0 ? nil : captured / $0 }.map(NativeRPCValue.number) ?? .null),
            .init("loud", .bool(verdict != "complete")), .init("line", .string(line)), .init("at", .number(BackendBrowserScrapingIO.now())),
            .init("what", .string(args["what"].string ?? "")), .init("url", .string(page))])
        try await store.appendRun(run, profile: profile, file: "coverage.jsonl", value: value); return value
    }
    private func fileName(_ response: BackendBrowserAssetResponse, url: URL) -> String {
        var name = url.lastPathComponent
        if let disposition = response.header("content-disposition"),
           let regex = try? NSRegularExpression(pattern: "filename=\\\"?([^\\\";]+)", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
           let range = Range(match.range(at: 1), in: disposition) { name = String(disposition[range]) }
        name = String(name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }.prefix(120))
        if name.isEmpty || name.hasPrefix(".") { name = "asset" }
        // Different query/rendition URLs cannot overwrite another URL's asset.
        let suffix = BackendBrowserScrapingIO.digest(Data(url.absoluteString.utf8)).dropFirst(7).prefix(12)
        return "\(suffix)-\(name)"
    }
    public func fetch(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try validateQuality(args)
        let profile = try await profile(args, caller: caller, operation: "assets.fetch"), run = try args["runId"].requireString("runId", nonempty: true)
        let config = try await store.config(profile)
        let storedRefetch = config["assets"]["ledger"]["on"].bool == false || config["assets"]["ledger"]["refetch"].bool == true
        let mode = args["mode"].string ?? (storedRefetch ? "refetch" : "resume")
        guard ["resume", "refetch"].contains(mode) else { throw BackendBrowserScrapingError.invalid("Asset mode is resume or refetch.") }
        let effectiveArgs = args.setting("mode", .string(mode))
        let key = profile + ":" + run
        guard !fetching.contains(key) else { throw NativeRPCError(code: "run-busy", message: "A fetch batch for this profile/run is already active.") }
        fetching.insert(key); defer { fetching.remove(key) }
        let directory = try await hooks.directory(caller, args["dir"].requireString("dir", nonempty: true))
        guard directory.isFileURL, directory.path != "/" else { throw BackendBrowserScrapingError.invalid("Use an explicitly granted local asset directory.") }
        try BackendBrowserScrapingPaths.rejectSymlinks(directory)
        let urls = try args["urls"].requireArray("urls")
        guard !urls.isEmpty, urls.count <= 1_000 else { throw BackendBrowserScrapingError.invalid("A batch needs 1...1000 URLs; orchestration belongs outside the browser.") }
        var seen: Set<String> = [], results: [NativeRPCValue] = []
        // Refetch never uses rows for a skip. Read paths only so a deliberate
        // repair replaces its granted old file rather than making photo (2).
        var rows = try await latestLedger(run, profile: profile)
        var tally = ["asked": urls.count, "fetched": 0, "upgraded": 0, "fellBack": 0, "skipped": 0, "failed": 0, "bytes": 0, "ledgerWasWrong": 0]
        for raw in urls {
            try Task.checkCancellation()
            let original = try BackendBrowserScrapingIO.httpURL(raw.requireString("asset URL", nonempty: true))
            try await hooks.authorize(caller, "assets.fetch", profile, original, args)
            if !seen.insert(original.absoluteString).inserted { tally["skipped", default: 0] += 1; results.append(.object([.init("url", .string(original.absoluteString)), .init("outcome", .string("skipped")), .init("reason", .string("duplicate-in-batch"))])); continue }
            let decision = try await decision(original.absoluteString, row: rows[original.absoluteString], args: effectiveArgs, caller: caller)
            if decision["action"].string == "skip" {
                tally["skipped", default: 0] += 1; results.append(decision.setting("url", .string(original.absoluteString)).setting("outcome", .string("skipped"))); continue
            }
            let choices = try await candidates(original, args: args, profile: profile)
            let selection = try await choose(original, choices: choices, args: args, profile: profile, caller: caller, operation: "assets.fetch.probe")
            let from = selection.reachable ? selection.index : 0
            let minimum = max(0, args["minBytes"].number ?? 0).rounded(.towardZero)
            var attempts: [NativeRPCValue] = [], winner: (Int, Candidate, BackendBrowserAssetResponse, BackendBrowserScrapingRendition.Verdict)?
            for (index, choice) in choices.enumerated() where index >= from {
                do {
                    let result = try await response(choice.url, method: "GET", profile: profile, caller: caller, operation: "assets.fetch", args: args)
                    guard (200..<300).contains(result.status), !result.body.isEmpty, Double(result.body.count) >= minimum else {
                        throw NativeRPCError(code: "asset-response", message: "HTTP \(result.status), empty response or body smaller than minBytes.")
                    }
                    let contentType = (result.header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
                    let measured = BackendBrowserRenditionProbe(status: result.status, bytes: result.body.count, contentType: contentType,
                        image: result.image, method: "GET-body", finalURL: result.finalURL)
                    // Source's larger-byte decision is between the probes. GET
                    // checks the actual type, complete/minimum bytes and any
                    // explicitly requested image/ratio quality requirements.
                    let verdict = BackendBrowserScrapingRendition.accepts(url: choice.url, probe: measured, original: selection.original,
                        arguments: args.setting("requireLarger", .bool(false)), isOriginal: choice.ruleID.isEmpty)
                    guard verdict.ok else { throw NativeRPCError(code: "asset-quality", message: verdict.reason) }
                    attempts.append(verdict.wire.merging(.object([.init("url", .string(choice.url.absoluteString)), .init("ruleId", .string(choice.ruleID)),
                        .init("status", .number(Double(result.status))), .init("bytes", .number(Double(result.body.count))), .init("image", measured.wire["image"])])))
                    winner = (index, choice, result, verdict); break
                } catch is CancellationError { throw CancellationError() }
                catch let error as NativeRPCError where error.code == "access-denied" { throw error }
                catch { attempts.append(.object([.init("url", .string(choice.url.absoluteString)), .init("ruleId", .string(choice.ruleID)), .init("ok", .bool(false)), .init("reason", .string(error.localizedDescription)), .init("status", .null), .init("bytes", .null)])) }
            }
            guard let (winnerIndex, choice, response, quality) = winner else {
                tally["failed", default: 0] += 1; results.append(.object([.init("url", .string(original.absoluteString)), .init("outcome", .string("failed")), .init("attempts", .array(attempts)), .init("probed", .array(selection.attempts))])); continue
            }
            try Task.checkCancellation()
            try await hooks.authorize(caller, "assets.fetch.write", profile, response.finalURL, args)
            let currentDirectory = try await hooks.directory(caller, directory.path)
            guard currentDirectory.standardizedFileURL == directory.standardizedFileURL else { throw BackendBrowserScrapingError.denied("The asset destination grant changed during the fetch.") }
            try BackendBrowserScrapingPaths.rejectSymlinks(currentDirectory)
            try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
            var file = currentDirectory.appendingPathComponent(fileName(response, url: original))
            var replacingClaimed = false
            if let claimed = rows[original.absoluteString]?["path"].string {
                let url = URL(fileURLWithPath: claimed).standardizedFileURL
                if url.path.hasPrefix(currentDirectory.standardizedFileURL.path + "/") {
                    let approved = try await hooks.file(caller, claimed)
                    guard approved.standardizedFileURL == url else { throw BackendBrowserScrapingError.denied("The ledger replacement path changed while its grant was checked.") }
                    try await hooks.authorize(caller, "assets.fetch.replace", profile, response.finalURL, args.setting("path", .string(approved.path)))
                    try BackendBrowserScrapingPaths.rejectSymlinks(approved)
                    guard !rows.contains(where: { $0.key != original.absoluteString && $0.value["path"].string == approved.path }) else {
                        throw NativeRPCError(code: "ledger-path-collision", message: "Another asset claims the same file; no replacement was performed.")
                    }
                    file = approved; replacingClaimed = FileManager.default.fileExists(atPath: file.path)
                    if replacingClaimed {
                        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw BackendBrowserScrapingError.denied("A ledger repair may replace only its granted regular asset file.") }
                    }
                }
            }
            if !replacingClaimed, FileManager.default.fileExists(atPath: file.path) { file = currentDirectory.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent) }
            let part = currentDirectory.appendingPathComponent(".td-asset-" + UUID().uuidString + ".part")
            do {
                try response.body.write(to: part, options: .withoutOverwriting)
                try Task.checkCancellation()
                try BackendBrowserScrapingPaths.rejectSymlinks(file)
                if replacingClaimed {
                    _ = try FileManager.default.replaceItemAt(file, withItemAt: part, backupItemName: nil, options: .usingNewMetadataOnly)
                } else { try FileManager.default.moveItem(at: part, to: file) }
                let row = try await record(runID: run, profile: profile, url: original.absoluteString,
                                           fetchedURL: response.finalURL.absoluteString, ruleID: choice.ruleID, file: file, caller: caller)
                rows[original.absoluteString] = row; tally["fetched", default: 0] += 1
                let fellBack = winnerIndex > from || selection.fellBack && choice.ruleID.isEmpty
                if fellBack { tally["fellBack", default: 0] += 1 }
                if !choice.ruleID.isEmpty { tally["upgraded", default: 0] += 1 }
                tally["bytes", default: 0] += response.body.count
                let ledgerWrong = ["file-missing", "wrong-size", "wrong-digest", "unreadable", "digest-not-expected"].contains(decision["reason"].string ?? "")
                if ledgerWrong { tally["ledgerWasWrong", default: 0] += 1 }
                let actuallyComparedBytes = !choice.ruleID.isEmpty && args["requireLarger"].bool != false
                    && selection.probes[choice.url.absoluteString]?.bytes != nil && selection.original?.bytes != nil
                let measured = NativeRPCValue.object([.init("comparedBytes", .bool(actuallyComparedBytes)),
                    .init("comparedDimensions", .bool(quality.comparedDimensions)), .init("byteRatio", quality.byteRatio.map(NativeRPCValue.number) ?? .null)])
                results.append(row.merging(measured).setting("outcome", .string(fellBack ? "fell-back" : "fetched")).setting("attempts", .array(attempts))
                    .setting("probed", .array(selection.attempts)).setting("upgraded", .bool(!choice.ruleID.isEmpty)).setting("fellBack", .bool(fellBack))
                    .setting("ledgerReason", decision["reason"]).setting("ledgerWasWrong", .bool(ledgerWrong))
                    .setting("image", response.image.map { .object([.init("width", .number(Double($0.width))), .init("height", .number(Double($0.height))), .init("format", .string($0.format))]) } ?? .null))
            } catch {
                try? FileManager.default.removeItem(at: part)
                // Preserve a fully written file if ledger I/O failed; report it,
                // so the caller can recover it without fabricating a resume row.
                if error is CancellationError { throw error }
                tally["failed", default: 0] += 1
                results.append(.object([.init("url", .string(original.absoluteString)), .init("outcome", .string("failed")),
                    .init("path", .string(file.path)), .init("message", .string(error.localizedDescription))]))
            }
        }
        let tallyValue = NativeRPCValue.object(tally.keys.sorted().map { .init($0, .number(Double(tally[$0]!))) })
        await store.noteBatch(profile, tally: tallyValue)
        let empty = tally["fetched", default: 0] == 0 && tally["skipped", default: 0] == 0
        return .object([.init("runId", .string(run)), .init("results", .array(results)), .init("tally", tallyValue),
            .init("complete", .bool(tally["failed", default: 0] == 0)), .init("empty", .bool(empty)),
            .init("emptyReason", .string(empty ? "No assets were fetched or verified in the resume ledger. Inspect the attempts." : "")),
            .init("bytesTransformed", .bool(false)), .init("bodyLimit", .number(Double(Self.bodyLimit)))])
    }
}
