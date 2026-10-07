import Foundation
import TerminalDeckNativeCore

/// Narrow source-domain seams. Safari supplies these from its existing
/// BackendBrowserScrapingAssets/Store/Rendition/Regex owners. The ledger object
/// must be shared per (mode, path), as the source keeps one live tally per run.
public protocol BackendDeckToolsAssetLedger: Sendable {
    func decide(url: String, expectDigest: String?) async throws -> NativeRPCValue
    func record(_ entry: NativeRPCValue) async throws -> NativeRPCValue
    func verify() async throws -> NativeRPCValue
    func tally() async throws -> NativeRPCValue
    func summary() async throws -> String
}
public protocol BackendDeckToolsAssetDomain: Sendable {
    func userData() async throws -> String
    func validateProfile(_ profile: String?) async throws
    func runOwner(_ run: String) async throws -> String?
    func settings(_ profile: String?) async throws -> NativeRPCValue
    func noteRunProfile(_ run: String, profile: String) async throws
    func rendition(_ arguments: NativeRPCValue) async throws -> NativeRPCValue
    func ledger(run: String, mode: String) async throws -> any BackendDeckToolsAssetLedger
    func fingerprint(path: String) async throws -> NativeRPCValue
    func fetch(_ arguments: NativeRPCValue, ledger: any BackendDeckToolsAssetLedger) async throws -> NativeRPCValue
    func noteAssetBatch(profile: String, tally: NativeRPCValue) async throws
    func statedTotal(text: String, pattern: String?, flags: String?) async throws -> NativeRPCValue?
    func compareCoverage(_ arguments: NativeRPCValue) async throws -> NativeRPCValue
    func readCoverage(run: String) async throws -> [NativeRPCValue]
    func recordCoverage(run: String, check: NativeRPCValue) async throws -> Bool
    func blocks() async throws -> [NativeRPCValue]
    func blockCaptureOff() async throws -> [String]
}
/// Missing source-compatible domain operations always fail loudly. These
/// defaults let Safari adopt its existing operations incrementally without
/// fabricated zero counts, empty files or a second browser store.
public extension BackendDeckToolsAssetDomain {
    func userData() async throws -> String { throw BackendDeckToolsSupport.unavailable("asset data root") }
    func validateProfile(_ profile: String?) async throws { throw BackendDeckToolsSupport.unavailable("asset profile validation") }
    func runOwner(_ run: String) async throws -> String? { throw BackendDeckToolsSupport.unavailable("asset run ownership") }
    func settings(_ profile: String?) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("asset profile settings") }
    func noteRunProfile(_ run: String, profile: String) async throws { throw BackendDeckToolsSupport.unavailable("asset run attribution") }
    func rendition(_ arguments: NativeRPCValue) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("asset rendition") }
    func ledger(run: String, mode: String) async throws -> any BackendDeckToolsAssetLedger { throw BackendDeckToolsSupport.unavailable("source-compatible asset ledger") }
    func fingerprint(path: String) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("asset file fingerprint") }
    func fetch(_ arguments: NativeRPCValue, ledger: any BackendDeckToolsAssetLedger) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("source-compatible asset fetch batch") }
    func noteAssetBatch(profile: String, tally: NativeRPCValue) async throws { throw BackendDeckToolsSupport.unavailable("asset batch attribution") }
    func statedTotal(text: String, pattern: String?, flags: String?) async throws -> NativeRPCValue? { throw BackendDeckToolsSupport.unavailable("page stated total") }
    func compareCoverage(_ arguments: NativeRPCValue) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("asset coverage comparison") }
    func readCoverage(run: String) async throws -> [NativeRPCValue] { throw BackendDeckToolsSupport.unavailable("asset coverage records") }
    func recordCoverage(run: String, check: NativeRPCValue) async throws -> Bool { throw BackendDeckToolsSupport.unavailable("asset coverage write") }
    func blocks() async throws -> [NativeRPCValue] { throw BackendDeckToolsSupport.unavailable("asset block evidence") }
    func blockCaptureOff() async throws -> [String] { throw BackendDeckToolsSupport.unavailable("asset block camera settings") }
}
public protocol BackendDeckToolsAssetRuntime: Sendable {
    func now() -> Double
    func callerKind(_ caller: BackendMCPCallContext) async throws -> String
    func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws
    func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws
}
public extension BackendDeckToolsAssetRuntime {
    func now() -> Double { Date().timeIntervalSince1970 * 1000 }
}

public enum BackendDeckToolsAssets {
    private static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    public static let toolNames: Set<String> = Set(["assets.rendition", "assets.ledger", "assets.fetch", "assets.coverage", "assets.blocks"].flatMap { [$0, $0.replacingOccurrences(of: ".", with: "_")] })
    public static let guarantee = "A downloaded file is written exactly as the server sent it. Nothing in this app rewrites those bytes. Derivatives are made afterwards, from the original, into a different file — never instead of it."
    /// browser-scrape-paths.ts's on-disk segment, including UTF-16 replacement
    /// and the leading dot/hyphen removal. Never echo a raw traversal as a path.
    public static func safeRunID(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf16)
        let flat = String(decoding: raw.utf16.map { allowed.contains($0) ? $0 : UInt16(45) }, as: UTF16.self)
            .drop(while: { $0 == "." || $0 == "-" })
        return flat.isEmpty ? "run" : String(flat.prefix(80))
    }
    private static func refusal(_ text: String) -> NativeRPCError { .init(code: "not-permitted", message: text) }
    private static func str(_ args: NativeRPCValue, _ key: String) throws -> String {
        do { return try BackendDeckToolsArgs.str(args, key) } catch let error as NativeRPCError { throw refusal(error.message) }
    }
    private static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        do { return try BackendDeckToolsArgs.optStr(args, key) } catch let error as NativeRPCError { throw refusal(error.message) }
    }
    private static func num(_ args: NativeRPCValue, _ key: String) throws -> Double? {
        if args[key].isNullish { return nil }; guard let value = args[key].number else { throw refusal("\(key) must be a number") }; return value
    }
    private static func http(_ args: NativeRPCValue, _ key: String) throws -> String {
        let value = try str(args, key)
        guard value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else { throw refusal("\(key) must be an http or https address") }
        return value
    }
    public static func urls(_ args: NativeRPCValue) throws -> [String] {
        guard let raw = args["urls"].elements else { throw refusal("urls must be a list of addresses") }
        if raw.isEmpty { throw refusal("urls is empty, so there is nothing to fetch") }
        if raw.count > 200 { throw refusal("that is more than 200 urls in one call — split it into batches, which is what the run id is for") }
        return try raw.map { value in
            guard let text = value.string, text.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else { throw refusal("every url must be an http or https address") }
            return text
        }
    }
    public static func scrubURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.scheme != nil else { return raw }
        let credential = Set(["x-amz-signature", "x-amz-security-token", "x-amz-credential", "signature", "sig", "token", "access_token", "key", "apikey", "api_key", "password", "policy", "expires", "hmac", "auth"])
        guard let items = components.queryItems, items.contains(where: { credential.contains($0.name.lowercased()) }) else { return raw }
        // URLSearchParams.set keeps one occurrence, at the first one's position.
        var seen: Set<String> = []
        components.queryItems = items.compactMap { item in
            if credential.contains(item.name.lowercased()) {
                guard seen.insert(item.name).inserted else { return nil }; return .init(name: item.name, value: "…")
            }
            return item
        }
        return components.string ?? raw
    }
    /// asset-tools.ts `mayFetchAs`: any failure to open the named profile is a
    /// `not-permitted` refusal carrying its message, never an internal error.
    private static func mayFetchAs(_ profile: String?, domain: any BackendDeckToolsAssetDomain) async throws {
        do { try await domain.validateProfile(profile) }
        catch { throw refusal((error as? NativeRPCError)?.message ?? error.localizedDescription) }
    }
    /// The four tools asset-tools.ts gives `redactArgs: scrubUrlArgs` (assets.blocks has none).
    public static let redactedToolIDs: Set<String> = ["assets.rendition", "assets.ledger", "assets.coverage", "assets.fetch"]
    /// The central gate writes `policy.redactArgs` output to actions.jsonl. Applied
    /// where every contributed area enters the door (BackendDeckCoreAreaIntegration),
    /// so a presigned URL signature cannot reach the action log whichever
    /// composition supplies the policy; a supplied redactor still runs first.
    public static func withURLRedaction(_ policy: BackendDeckCoreSecurityToolPolicy) -> BackendDeckCoreSecurityToolPolicy {
        guard redactedToolIDs.contains(policy.tool.id) else { return policy }
        let supplied = policy.redactArgs
        return BackendDeckCoreSecurityToolPolicy(tool: policy.tool, aliases: policy.aliases, audience: policy.audience,
            keyRequiresTasks: policy.keyRequiresTasks, spendsDeviceInput: policy.spendsDeviceInput,
            summary: policy.summary, precheck: policy.precheck, precheckAsync: policy.precheckAsync, escalate: policy.escalate,
            ownerMustAnswer: policy.ownerMustAnswer,
            redactArgs: { @Sendable (args: NativeRPCValue) throws -> NativeRPCValue in redact(try supplied?(args) ?? args) },
            run: policy.run)
    }
    public static func redact(_ args: NativeRPCValue) -> NativeRPCValue {
        var out = args
        for key in ["url", "fetchedUrl", "pageUrl"] { if let value = out[key].string { out = out.setting(key, .string(scrubURL(value))) } }
        if let values = out["urls"].elements { out = out.setting("urls", .array(values.map { $0.string.map { .string(scrubURL($0)) } ?? $0 })) }
        return out
    }
    public static func readRules(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        if raw.isNullish { return .array([]) }
        guard let entries = raw.elements else { throw refusal("rules must be a list") }
        if entries.count > 20 { throw refusal("that is more than 20 rules") }
        var seen: Set<String> = []
        return .array(try entries.map { entry in
            guard entry.fields != nil else { throw refusal("every rule must be an object") }
            let id = (entry["id"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), match = entry["match"].string ?? "", replace = entry["replace"].string ?? "", flags = entry["flags"].string ?? ""
            if id.isEmpty { throw refusal("every rule needs an id, so a bad one can be named and withdrawn") }
            if !seen.insert(id).inserted { throw refusal("two rules are called \(id)") }
            if match.isEmpty { throw refusal("rule \(id) has no match") }
            if match.utf16.count > 400 || replace.utf16.count > 400 { throw refusal("rule \(id) is longer than 400 characters") }
            if flags.range(of: #"^[gimsuy]*$"#, options: .regularExpression) == nil { throw refusal("rule \(id) has flags that are not flags") }
            do { _ = try BackendBrowserScrapingRegex.replace("", pattern: match, replacement: "", flags: flags) }
            catch { throw refusal("rule \(id) is not a valid expression: \(error.localizedDescription)") }
            var out = o([("id", .string(id)), ("match", .string(match)), ("replace", .string(replace))]); if !flags.isEmpty { out = out.setting("flags", .string(flags)) }; return out
        })
    }
    public static func empty(_ value: NativeRPCValue, produced: Double, reason: String) -> NativeRPCValue {
        value.setting("empty", .bool(produced <= 0)).setting("emptyReason", .string(produced <= 0 ? reason : ""))
    }
    public static func renditionArguments(_ args: NativeRPCValue, settings: NativeRPCValue) throws -> NativeRPCValue {
        let rules: NativeRPCValue
        if args["rules"].isNullish {
            let upgrade = settings["assets"]["upgrade"], from = upgrade["from"].string ?? ""
            if upgrade["on"].bool == true && !from.isEmpty {
                let syntax = Set(".*+?^${}()|[]\\")
                let match = from.map { syntax.contains($0) ? "\\" + String($0) : String($0) }.joined()
                let replace = (upgrade["to"].string ?? "").replacingOccurrences(of: "$", with: "$$")
                rules = .array([o([("id", .string("upgrade")), ("match", .string(match)), ("replace", .string(replace)), ("flags", .string("g"))])])
            } else { rules = .array([]) }
        } else { rules = try readRules(args["rules"]) }
        var effective = args.setting("rules", rules)
        if let bytes = try num(args, "minBytes") { effective = effective.setting("minBytes", .number(max(0, bytes.rounded(.towardZero)))) }
        else { effective = effective.removing("minBytes") }
        if args["requireLarger"] != .missing { effective = effective.setting("requireLarger", .bool(args["requireLarger"].bool == true)) }
        if let profile = try optStr(args, "profileId") { effective = effective.setting("profileId", .string(profile)) }
        else { effective = effective.removing("profileId") }
        return effective
    }
    public static func fetchValue(_ batch: NativeRPCValue, run: String, mode: String, folder: String) throws -> NativeRPCValue {
        let tally = batch["tally"]
        let countKeys = ["asked", "fetched", "upgraded", "fellBack", "skipped", "failed", "bytes", "ledgerWasWrong"]
        guard countKeys.allSatisfy({ tally[$0].number != nil }), batch["dir"].string != nil,
              batch["line"].string != nil, let results = batch["results"].elements else {
            throw BackendDeckToolsSupport.unavailable("the source-compatible asset batch result")
        }
        let textKeys = ["url", "fetchedUrl", "ruleId", "path", "digest", "reason", "line"]
        guard results.allSatisfy({ row in
            row.fields != nil && textKeys.allSatisfy({ row[$0].string != nil })
                && ["fetched", "fell-back", "skipped", "failed"].contains(row["outcome"].string ?? "")
                && row["bytes"].number != nil && row["ledgerWasWrong"].bool != nil
                && row["attempts"].elements != nil && row["probed"].elements != nil
        }) else { throw BackendDeckToolsSupport.unavailable("the source-compatible asset result rows") }
        let resultKeys = ["url", "outcome", "fetchedUrl", "ruleId", "path", "bytes", "digest", "reason", "line", "ledgerWasWrong", "attempts", "probed"]
        let rows = results.map { row -> NativeRPCValue in
            var value = o(resultKeys.map { ($0, row[$0]) })
            for key in ["attempts", "probed"] {
                if let attempts = row[key].elements { value = value.setting(key, .array(attempts.map(attempt))) }
            }
            return value
        }
        return o([("runId", .string(run)), ("mode", .string(mode)), ("dir", batch["dir"]), ("ledger", .string(folder + "/ledger.jsonl")),
            ("folder", .string(folder)), ("guarantee", .string(guarantee)), ("line", batch["line"]), ("tally", o(countKeys.map { ($0, tally[$0]) })),
            ("results", .array(rows))])
    }
    private static func attempt(_ value: NativeRPCValue) -> NativeRPCValue {
        o(["url", "ruleId", "ok", "reason", "status", "bytes"].map { ($0, value[$0]) })
    }
    private static func emptySummary(_ count: Double) -> NativeRPCValue { o([("empty", .bool(count <= 0))]) }
    private static func mode(_ args: NativeRPCValue, run: String, domain: any BackendDeckToolsAssetDomain) async throws -> String {
        if let typed = try optStr(args, "mode"), ["resume", "refetch"].contains(typed) { return typed }
        let profile: String?
        if let typed = try optStr(args, "profileId") { profile = typed }
        else { profile = try await domain.runOwner(run) }
        let settings = try await domain.settings(profile)
        if settings["assets"]["ledger"]["on"].bool == false || settings["assets"]["ledger"]["refetch"].bool == true { return "refetch" }
        return "resume"
    }
    public static func definitions(domain: any BackendDeckToolsAssetDomain,
                                   runtime: any BackendDeckToolsAssetRuntime) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsCatalogue.entries().filter { $0.module == "asset-tools" }.map { entry in
            BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index) { caller, args in
                await BackendDeckToolsSupport.reply {
                    let (value, summary) = try await call(entry.spec.id, args: args, caller: caller, domain: domain, runtime: runtime)
                    try await runtime.completed(caller, tool: entry.spec.id, summary: summary); return .value(value)
                }
            }
        }
    }
    public static func area(domain: any BackendDeckToolsAssetDomain, runtime: any BackendDeckToolsAssetRuntime) throws -> BackendDeckCoreToolArea {
        try BackendDeckToolsSupport.area(id: "assets", definitions: definitions(domain: domain, runtime: runtime))
    }
    private static func call(_ id: String, args: NativeRPCValue, caller: BackendMCPCallContext,
                             domain: any BackendDeckToolsAssetDomain, runtime: any BackendDeckToolsAssetRuntime) async throws -> (NativeRPCValue, NativeRPCValue) {
        if try await runtime.callerKind(caller) == "remote" { throw NativeRPCError(code: "not-granted", message: "\(id) works on files and folders on this machine, so it only runs for something on it. A paired device cannot call it.") }
        let run = ["assets.ledger", "assets.fetch", "assets.coverage"].contains(id) ? try str(args, "runId") : ""
        let profile = try optStr(args, "profileId"), op = try optStr(args, "op") ?? (id == "assets.coverage" ? "check" : "summary")
        var effective = args, tier: BackendMCPTier = id == "assets.ledger" || id == "assets.blocks" ? .read : .act
        var summaryText = ""
        switch id {
        case "assets.rendition":
            _ = try http(args, "url"); try await mayFetchAs(profile, domain: domain); _ = try readRules(args["rules"])
            summaryText = "Find the best rendition of \(scrubURL(try optStr(args, "url") ?? "?"))"
        case "assets.ledger":
            _ = try str(args, "op")
            if !["decide", "record", "verify", "summary"].contains(op) { throw refusal("op must be decide, record, verify or summary") }
            if let mode = try optStr(args, "mode"), !["resume", "refetch"].contains(mode) { throw refusal("mode must be resume or refetch") }
            if op == "decide" || op == "record" { _ = try str(args, "url") }
            if op == "record" { tier = .act; if try !str(args, "path").hasPrefix("/") { throw refusal("path must be absolute. A relative one would be resolved against a working directory nobody chose, and the ledger would record a file that is not where it says it is.") } }
            summaryText = op == "decide" ? "Ask the \(run) ledger about \(scrubURL(try optStr(args, "url") ?? "?"))" : op == "record" ? "Write \(scrubURL(try optStr(args, "url") ?? "?")) into the \(run) ledger" : op == "verify" ? "Check every file the \(run) ledger claims" : "Read the \(run) ledger's counts"
        case "assets.fetch":
            if try !str(args, "dir").hasPrefix("/") { throw refusal("dir must be absolute. A relative one would be resolved against a working directory nobody chose, and sixty thousand files would land somewhere nobody could find them.") }
            let addresses = try urls(args)
            if let mode = try optStr(args, "mode"), !["resume", "refetch"].contains(mode) { throw refusal("mode must be resume or refetch") }
            _ = try readRules(args["rules"]); try await mayFetchAs(profile, domain: domain)
            let selected = try await mode(args, run: run, domain: domain); effective = effective.setting("mode", .string(selected))
            summaryText = "Fetch \(addresses.count) asset\(addresses.count == 1 ? "" : "s") into \(try optStr(args, "dir") ?? "?") (\(selected))"
        case "assets.coverage":
            if !["check", "summary"].contains(op) { throw refusal("op must be check or summary") }
            if op == "check" {
                guard let captured = try num(args, "captured") else { throw refusal("captured is required — it is half of the comparison") }
                if captured < 0 { throw refusal("captured cannot be negative") }
                if try optStr(args, "text") == nil && num(args, "stated") == nil { throw refusal("give either text from the page, so the stated total can be read out of it, or stated, when you already know it. Without one of the two there is nothing to compare against.") }
            }
            summaryText = op == "summary" ? "Read every coverage check in \(run)" : "Check \(try num(args, "captured").map { NativeRPCValue.number($0).compact } ?? "?") captured against what the page states"
        default: summaryText = "List the block pages the browser photographed"
        }
        guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "This caller is not permitted to use that tool.") }
        try await runtime.authorize(caller, tool: id, tier: tier, summary: summaryText, arguments: redact(args))
        let dataRoot = try await domain.userData(), folder = dataRoot + "/scrape/runs/" + safeRunID(run)
        switch id {
        case "assets.rendition":
            effective = try await renditionArguments(effective, settings: domain.settings(profile))
            let rawChoice = try await domain.rendition(effective)
            guard rawChoice["url"].string != nil, ["reachable", "upgraded", "fellBack", "comparedBytes"].allSatisfy({ rawChoice[$0].bool != nil }), rawChoice["line"].string != nil,
                  let attempts = rawChoice["attempts"].elements else { throw BackendDeckToolsSupport.unavailable("the source-compatible rendition result") }
            let choice = o(["url", "ruleId", "upgraded", "fellBack", "reachable", "comparedBytes", "originalUrl", "line"].map { ($0, rawChoice[$0]) }).setting("attempts", .array(attempts.map(attempt)))
            let produced: Double = choice["reachable"].bool == true ? 1 : 0
            return (empty(choice, produced: produced, reason: "no candidate answered — not the rewrites and not the original, so nothing about this URL has been confirmed. It is still returned and still worth fetching. The host may refuse HEAD requests, or the asset may be behind a login, in which case pass profileId so the probe uses that jar. See attempts for what each candidate said."), o([("upgraded", choice["upgraded"]), ("fellBack", choice["fellBack"]), ("reachable", choice["reachable"]), ("ruleId", choice["ruleId"]), ("tried", .number(Double(choice["attempts"].elements?.count ?? 0)))]).merging(emptySummary(produced)))
        case "assets.ledger":
            let selected = try await mode(args, run: run, domain: domain), ledger = try await domain.ledger(run: run, mode: selected), path = folder + "/ledger.jsonl"
            if op == "decide" {
                let result = try await ledger.decide(url: str(args, "url"), expectDigest: optStr(args, "expectDigest"))
                return (empty(result.setting("mode", .string(selected)).setting("ledger", .string(path)), produced: 1, reason: ""), o([("action", result["action"]), ("reason", result["reason"]), ("ledgerWasWrong", result["ledgerWasWrong"])]).merging(emptySummary(1)))
            }
            if op == "record" {
                let file = try str(args, "path"), url = try str(args, "url"), fingerprint: NativeRPCValue
                do { fingerprint = try await domain.fingerprint(path: file) }
                catch { throw refusal("there is no file at \(file) to record — \(error.localizedDescription)") }
                guard let digest = fingerprint["digest"].string, !digest.isEmpty else { throw refusal("\(file) could not be read to fingerprint it, so it is not being written into the ledger. An entry with no digest is an entry that would be skipped on the next run without anything having checked it.") }
                let entry = try await ledger.record(o([("url", .string(url)), ("fetchedUrl", .string(try optStr(args, "fetchedUrl") ?? url)), ("ruleId", .string(try optStr(args, "ruleId") ?? "")), ("digest", .string(digest)), ("bytes", fingerprint["bytes"]), ("path", .string(file))]))
                return (empty(o([("entry", entry), ("ledger", .string(path)), ("guarantee", .string(guarantee))]), produced: 1, reason: ""), o([("url", .string(scrubURL(url))), ("bytes", fingerprint["bytes"]), ("digest", .string(digest))]).merging(emptySummary(1)))
            }
            if op == "verify" {
                let result = try await ledger.verify(), total = result["total"].number ?? 0
                return (empty(result.setting("ledger", .string(path)), produced: total, reason: "this ledger has no entries, so nothing was checked and this is not a statement about any file. If assets have been downloaded for run \(run), they were never recorded — call this tool with op record after each fetch, or the resume will re-download everything and the verify will go on saying nothing."), o([("total", result["total"]), ("ok", result["ok"]), ("missing", .number(Double(result["missing"].elements?.count ?? 0))), ("corrupt", .number(Double(result["corrupt"].elements?.count ?? 0)))]).merging(emptySummary(total)))
            }
            let tally = try await ledger.tally(), holds = (tally["known"].number ?? 0) + (tally["recorded"].number ?? 0), line = try await ledger.summary()
            return (empty(tally.merging(o([("mode", .string(selected)), ("line", .string(line)), ("ledger", .string(path)), ("folder", .string(folder))])), produced: holds, reason: "nothing has ever been recorded into the \(run) ledger, so these counts are not a picture of a run — they are the picture of a ledger nobody wrote to. A run that is fetching assets and not calling op record gets exactly this, and will re-download all of them next time."), tally.setting("mode", .string(selected)).merging(emptySummary(holds)))
        case "assets.fetch":
            let selected = effective["mode"].string ?? "resume", ledger = try await domain.ledger(run: run, mode: selected)
            effective = try await renditionArguments(effective, settings: domain.settings(profile))
            if let profile { try await domain.noteRunProfile(run, profile: profile) }
            let batch = try await domain.fetch(effective, ledger: ledger)
            let value = try fetchValue(batch, run: run, mode: selected, folder: folder), tally = value["tally"]
            if let profile { try await domain.noteAssetBatch(profile: profile, tally: tally) }
            let produced = (tally["fetched"].number ?? 0) + (tally["failed"].number ?? 0)
            return (empty(value, produced: produced, reason: "Nothing was fetched because there was nothing to fetch: all \(tally["asked"].compact) are already on disk, at the length and digest the ledger recorded. Use mode: refetch if you meant to download them again."), tally.setting("mode", .string(selected)).setting("dir", args["dir"]).merging(emptySummary(produced)))
        case "assets.coverage": return try await coverage(args, run: run, folder: folder, now: runtime.now(), domain: domain)
        default: return try await blocks(args, dataRoot: dataRoot, domain: domain)
        }
    }
    private static func coverage(_ args: NativeRPCValue, run: String, folder: String, now: Double, domain: any BackendDeckToolsAssetDomain) async throws -> (NativeRPCValue, NativeRPCValue) {
        if try optStr(args, "op") == "summary" {
            let checks = try await domain.readCoverage(run: run), totals = coverageSummary(checks)
            let result = empty(totals.setting("checks", .array(checks)).setting("log", .string(folder + "/coverage.jsonl")), produced: Double(checks.count), reason: "no coverage check was made in run \(run), so nothing here says it captured everything it should have. Call this tool with op check, the page text and how many items you got, once per page — a run with no checks is how 7% of a dataset shipped as a complete one.")
            return (result, totals.removing("line").merging(emptySummary(Double(checks.count))))
        }
        let profile: String?
        if let typed = try optStr(args, "profileId") { profile = typed }
        else { profile = try await domain.runOwner(run) }
        let stored = try await domain.settings(profile)
        let typed = try optStr(args, "pattern"), storedPattern = stored["checks"]["coverage"]["on"].bool == true ? stored["checks"]["coverage"]["pattern"].string : nil
        let pattern = typed ?? storedPattern.flatMap { $0.isEmpty ? nil : $0 }
        if let profile { try await domain.noteRunProfile(run, profile: profile) }
        let page = try optStr(args, "text"), reading: NativeRPCValue?
        if let page { reading = try await domain.statedTotal(text: page, pattern: pattern, flags: optStr(args, "flags")) } else { reading = nil }
        let given = try num(args, "stated"), stated = given.map { $0.rounded(.towardZero) } ?? reading?["total"].number
        var comparison = o([("stated", stated.map(NativeRPCValue.number) ?? .null), ("captured", .number(try num(args, "captured") ?? 0)), ("now", .number(now))])
        if let tolerance = try num(args, "tolerance") { comparison = comparison.setting("tolerance", .number(tolerance)) }
        if let what = try optStr(args, "what") { comparison = comparison.setting("what", .string(what)) }
        if let pageURL = try optStr(args, "pageUrl") { comparison = comparison.setting("url", .string(scrubURL(pageURL))) }
        let check = try await domain.compareCoverage(comparison)
        let recorded = try await domain.recordCoverage(run: run, check: check), produced: Double = check["stated"].isNullish ? 0 : 1
        let result = empty(check.merging(o([("statedFrom", .string(given != nil ? "given" : reading == nil ? "nothing" : "text")), ("reading", reading ?? .null), ("recorded", .bool(recorded)), ("log", .string(folder + "/coverage.jsonl"))])), produced: produced, reason: "nothing on this page stated a total, so there was nothing to compare against and this page cannot be called complete — the verdict is unknown, which is not a pass. Give pattern, a regular expression whose first group is the total, or stated when you already know it from somewhere the page does not print.")
        return (result, o([("verdict", check["verdict"]), ("stated", check["stated"]), ("captured", check["captured"]), ("missing", check["missing"]), ("recorded", .bool(recorded))]).merging(emptySummary(produced)))
    }
    public static func coverageSummary(_ checks: [NativeRPCValue]) -> NativeRPCValue {
        func count(_ verdict: String) -> Int { checks.filter { $0["verdict"].string == verdict }.count }
        let short = count("short"), unknown = count("unknown"), over = count("over"), complete = count("complete")
        let ok = !checks.isEmpty && short == 0 && unknown == 0 && over == 0
        let line: String
        if checks.isEmpty { line = "No coverage check was made, so nothing here says this run captured everything it should have." }
        else if ok { line = "\(complete) coverage checks, all of them matching the totals the pages stated." }
        else {
            var parts: [String] = []
            let missing = checks.filter { $0["verdict"].string == "short" }.reduce(0) { $0 + ($1["missing"].number ?? 0) }
            if short > 0 { parts.append("\(short) pages came up short by \(NativeRPCValue.number(missing).compact) items in total") }
            if unknown > 0 { parts.append("\(unknown) pages never stated a total, so they cannot be called complete") }
            if over > 0 { parts.append("\(over) pages yielded more than they state, which usually means duplicates") }
            line = "\(complete) of \(checks.count) coverage checks matched. \(parts.joined(separator: "; "))."
        }
        return o([("ok", .bool(ok)), ("line", .string(line)), ("short", .number(Double(short))), ("unknown", .number(Double(unknown))), ("over", .number(Double(over))), ("complete", .number(Double(complete)))])
    }
    private static func blocks(_ args: NativeRPCValue, dataRoot: String, domain: any BackendDeckToolsAssetDomain) async throws -> (NativeRPCValue, NativeRPCValue) {
        let caught = try await domain.blocks(), since = try num(args, "since"), limitRaw = try num(args, "limit")
        let limit = Int(min(200, max(1, (limitRaw ?? 20).rounded(.towardZero))))
        let all = caught.filter { since == nil || ($0["at"].number ?? 0) >= since! }.sorted { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }
        let shots = all.prefix(limit).map { shot -> NativeRPCValue in
            let evidence = shot["evidence"], url = evidence["finalUrl"].string.flatMap { $0.isEmpty ? nil : $0 } ?? evidence["requestedUrl"].string ?? ""
            return o([("at", shot["at"]), ("url", .string(scrubURL(url))), ("httpStatus", evidence["httpStatus"]), ("title", evidence["title"]), ("signals", shot["verdict"]["signals"]), ("screenshot", shot["path"]), ("evidence", shot["sidecar"]), ("note", shot["note"])])
        }
        let off = try await domain.blockCaptureOff()
        let switchedOff = off.isEmpty ? "" : " The block camera is switched off for \(off.joined(separator: ", ")), so pages driven in \(off.count == 1 ? "that profile" : "those profiles") are not photographed at all."
        let foundNothing: String
        if let since {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            foundNothing = "no page has been photographed refusing us since \(formatter.string(from: Date(timeIntervalSince1970: since / 1000))). " + (caught.isEmpty ? "There are none at all in this folder." : "There are \(caught.count) older ones: drop since to see them.") + switchedOff
        } else { foundNothing = "no page has been photographed refusing us. Either nothing has been blocked, or nothing has been driven through this browser since the app started — an empty folder does not tell the two apart." + switchedOff }
        return (empty(o([("folder", .string(dataRoot + "/scrape/blocks")), ("total", .number(Double(all.count))), ("shots", .array(shots))]), produced: Double(all.count), reason: foundNothing), o([("total", .number(Double(all.count))), ("listed", .number(Double(shots.count)))]).merging(emptySummary(Double(all.count))))
    }
}
