import Foundation
import TerminalDeckNativeCore

/// Port of src/main/browser-asset-fetch.ts and browser-download-names.ts: write
/// each asset to disk byte for byte (never transformed), through a .part file
/// renamed into place, rewrite candidates tried best-first, recorded in the
/// shared ledger. URLs inside sentences are credential-scrubbed; the URL data
/// fields (key columns) keep the caller's own URL, exactly as the TypeScript does.

enum BackendS4AssetsNames {
    static let maximumVariants = 100
    private static func replace(_ text: String, _ pattern: String, _ with: String) -> String {
        text.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }
    /// downloadName(): control chars out, separators to spaces, reserved chars out,
    /// whitespace collapsed, leading/trailing dots and spaces stripped, 120 max.
    static func downloadName(_ suggested: String) -> String {
        var flat = replace(suggested, "[\\u0000-\\u001f\\u007f]", "")
        flat = replace(flat, "[\\\\/]", " ")
        flat = replace(flat, "[:*?\"<>|]", "")
        flat = replace(flat, "\\s+", " ").trimmingCharacters(in: .whitespacesAndNewlines)
        flat = replace(flat, "^[. ]+", "")
        flat = replace(flat, "[. ]+$", "")
        if flat.isEmpty { return "download" }
        let units = Array(flat.utf16)
        return units.count > 120 ? String(decoding: units.prefix(120), as: UTF16.self) : flat
    }
    /// freeDownloadPath(): first free "name", "stem (2).ext", ... then a timestamp.
    static func freeDownloadPath(dir: String, suggested: String, exists: (String) -> Bool, taken: Set<String>) -> String {
        let name = downloadName(suggested)
        let nsName = name as NSString
        let dot = nsName.range(of: ".", options: .backwards).location
        let stem = dot != NSNotFound && dot > 0 ? nsName.substring(to: dot) : name
        let ext = dot != NSNotFound && dot > 0 ? nsName.substring(from: dot) : ""
        for n in 1...maximumVariants {
            let candidate = (dir as NSString).appendingPathComponent(n == 1 ? name : "\(stem) (\(n))\(ext)")
            if !exists(candidate) && !taken.contains(candidate) { return candidate }
        }
        return (dir as NSString).appendingPathComponent("\(stem) (\(Int(Date().timeIntervalSince1970 * 1000)))\(ext)")
    }
    /// nameFor(): Content-Disposition filename first, then the last path segment.
    static func nameFor(url: String, disposition: String) -> String {
        if let found = disposition.range(of: #"filename\*?=(?:UTF-8'')?"?([^";]+)"?"#, options: [.regularExpression, .caseInsensitive]) {
            let piece = String(disposition[found])
            if let value = piece.range(of: #"=(?:UTF-8'')?"?"#, options: [.regularExpression, .caseInsensitive]) {
                var raw = String(piece[value.upperBound...])
                while raw.hasSuffix("\"") { raw.removeLast() }
                let named = downloadName(raw.removingPercentEncoding ?? raw)
                if named != "download" { return named }
            }
        }
        var last = ""
        if let components = URLComponents(string: url), components.scheme != nil {
            last = components.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }.last ?? ""
            last = last.removingPercentEncoding ?? last
        }
        return downloadName(last)
    }
    static func partPath(dir: String, url: String) -> String {
        (dir as NSString).appendingPathComponent(String(BackendS4AssetsFiles.sha256Hex(url).prefix(16)) + ".part")
    }
    static func inside(dir: String, path: String) -> Bool {
        let root = URL(fileURLWithPath: dir).standardizedFileURL.path, target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

struct BackendS4AssetsAttempt: Sendable {
    let url: String, ruleId: String, ok: Bool, status: Int?, bytes: Int?, reason: String
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("url", .string(url)), ("ruleId", .string(ruleId)), ("ok", .bool(ok)), ("status", status.map(BackendS4AssetsObject.number) ?? .null),
                                    ("bytes", bytes.map(BackendS4AssetsObject.number) ?? .null), ("reason", .string(reason))])
    }
}

struct BackendS4AssetsFetchResult: Sendable {
    var url: String, outcome: String, fetchedUrl = "", ruleId = "", upgraded = false, fellBack = false, path = ""
    var bytes = 0, digest = "", reason = "", line = "", ledgerReason = "", ledgerWasWrong = false
    var probed: [BackendS4AssetsRenditionAttempt] = [], attempts: [BackendS4AssetsAttempt] = []
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("url", .string(url)), ("outcome", .string(outcome)), ("fetchedUrl", .string(fetchedUrl)), ("ruleId", .string(ruleId)),
            ("upgraded", .bool(upgraded)), ("fellBack", .bool(fellBack)), ("path", .string(path)), ("bytes", BackendS4AssetsObject.number(bytes)),
            ("digest", .string(digest)), ("reason", .string(reason)), ("line", .string(line)), ("ledgerReason", .string(ledgerReason)),
            ("ledgerWasWrong", .bool(ledgerWasWrong)), ("probed", .array(probed.map(\.value))), ("attempts", .array(attempts.map(\.value)))])
    }
}

enum BackendS4AssetsFetch {
    static let fetchTimeoutMilliseconds = 120_000

    /// Anything an error message echoes of a URL is scrubbed before it is stored in a row.
    private static func hide(_ text: String, _ urls: [String]) -> String {
        urls.reduce(text) { $0.replacingOccurrences(of: $1, with: BackendDeckToolsAssets.scrubURL($1)) }
    }
    private static func drop(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    private struct Outcome: Sendable { let attempt: BackendS4AssetsAttempt; let landed: Bool; let name: String }

    /// fetchCandidate(): one candidate, one GET, body straight to the .part file.
    private static func fetchCandidate(_ candidate: BackendS4AssetsCandidate, transport: any BackendS4AssetsTransport, profile: String?,
                                       partPath: String, minBytes: Int, timeout: Int) async -> Outcome {
        @Sendable func no(_ status: Int?, _ reason: String, _ bytes: Int? = nil) -> Outcome {
            .init(attempt: .init(url: candidate.url, ruleId: candidate.ruleId, ok: false, status: status, bytes: bytes, reason: reason), landed: false, name: "")
        }
        do {
            return try await BackendS4AssetsTimed.run(timeout) { () async throws -> Outcome in
                let response: BackendS4AssetsResponse
                do { response = try await transport.open(url: candidate.url, method: "GET", headers: [:], profile: profile, timeoutMilliseconds: timeout) }
                catch { return no(nil, hide(error.localizedDescription.isEmpty ? "the request failed" : error.localizedDescription, [candidate.url])) }
                let stated = response.header("content-length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
                let type = (response.header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                let verdict = BackendS4AssetsRendition.accepts(candidateUrl: candidate.url, probe: .init(status: response.status, bytes: stated, contentType: type),
                                                               originalProbe: nil, minBytes: Double(minBytes), requireLarger: false)
                if !verdict.ok { response.cancel(); return no(response.status, verdict.reason) }
                guard let body = response.body else { return no(response.status, "the server answered with no body at all") }
                FileManager.default.createFile(atPath: partPath, contents: nil)
                guard let handle = FileHandle(forWritingAtPath: partPath) else { return no(response.status, "the body stopped part-way — the file could not be opened") }
                var written = 0
                do {
                    for try await chunk in body { try handle.write(contentsOf: chunk); written += chunk.count }
                    try handle.close()
                } catch {
                    try? handle.close(); drop(partPath); response.cancel()
                    return no(response.status, "the body stopped part-way — \(hide(error.localizedDescription, [candidate.url]))")
                }
                if written == 0 { drop(partPath); return no(response.status, "the server answered with nothing", 0) }
                if let stated, stated > 0, written < stated { drop(partPath); return no(response.status, "only \(written) bytes of the \(stated) the server promised", written) }
                if minBytes > 0 && written < minBytes { drop(partPath); return no(response.status, "\(written) bytes is below the \(minBytes) this run will accept", written) }
                return .init(attempt: .init(url: candidate.url, ruleId: candidate.ruleId, ok: true, status: response.status, bytes: written, reason: ""),
                             landed: true, name: BackendS4AssetsNames.nameFor(url: candidate.url, disposition: response.header("content-disposition") ?? ""))
            }
        } catch {
            drop(partPath)
            return no(nil, hide(error.localizedDescription, [candidate.url]))
        }
    }

    private static func describeRefusals(_ attempts: [BackendS4AssetsAttempt]) -> String {
        let refused = attempts.filter { !$0.ok }.map { "\($0.ruleId.isEmpty ? "original" : $0.ruleId) — \($0.reason)" }
        return refused.isEmpty ? "no rewrite changed this URL." : refused.joined(separator: "; ")
    }

    /// fetchAsset(): ledger decision, rendition choice, the candidates in order from
    /// the chosen one, rename into place, fingerprint, record.
    static func fetchAsset(url: String, dir: String, rules: [BackendS4AssetsRule], transport: any BackendS4AssetsTransport, profile: String?,
                           ledger: any BackendDeckToolsAssetLedger, options: BackendS4AssetsRenditionOptions, taken: inout Set<String>,
                           timeout: Int = fetchTimeoutMilliseconds) async throws -> BackendS4AssetsFetchResult {
        let shown = BackendDeckToolsAssets.scrubURL(url)
        let decisionValue = try await ledger.decide(url: url, expectDigest: nil)
        let action = decisionValue["action"].string ?? "fetch", reason = decisionValue["reason"].string ?? ""
        let wrong = decisionValue["ledgerWasWrong"].bool ?? false, decisionLine = decisionValue["line"].string ?? ""
        let decidedEntry = BackendS4AssetsLedgerEntry.read(decisionValue["entry"])
        if action == "skip" {
            let entry = decidedEntry
            return .init(url: url, outcome: "skipped", fetchedUrl: entry?.fetchedUrl ?? "", ruleId: entry?.ruleId ?? "", upgraded: !(entry?.ruleId ?? "").isEmpty,
                         fellBack: false, path: entry?.path ?? "", bytes: entry?.bytes ?? 0, digest: entry?.digest ?? "", reason: reason, line: decisionLine,
                         ledgerReason: reason, ledgerWasWrong: false, probed: [], attempts: [])
        }
        func fail(_ why: String, _ attempts: [BackendS4AssetsAttempt], _ probed: [BackendS4AssetsRenditionAttempt]) -> BackendS4AssetsFetchResult {
            .init(url: url, outcome: "failed", reason: why, line: "\(shown) was not fetched: \(why)", ledgerReason: reason, ledgerWasWrong: wrong, probed: probed, attempts: attempts)
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return fail("\(dir) could not be written to — \(error.localizedDescription)", [], []) }
        let choice = await BackendS4AssetsRendition.choose(url: url, rules: rules, probe: { [transport] candidate in
            await transport.probe(url: candidate, profile: profile, timeoutMilliseconds: BackendS4AssetsRendition.probeTimeoutMilliseconds)
        }, options: options)
        let candidates = BackendS4AssetsRendition.candidates(url, rules: rules)
        let from = choice.reachable ? max(0, candidates.firstIndex(where: { $0.url == choice.url }) ?? 0) : 0
        let part = BackendS4AssetsNames.partPath(dir: dir, url: url)
        var attempts: [BackendS4AssetsAttempt] = [], landed: Outcome?
        for candidate in candidates[from...] {
            let outcome = await fetchCandidate(candidate, transport: transport, profile: profile, partPath: part, minBytes: Int(options.minBytes), timeout: timeout)
            attempts.append(outcome.attempt)
            if outcome.landed { landed = outcome; break }
        }
        guard let landed else {
            drop(part)
            let why = attempts.map { "\($0.ruleId.isEmpty ? "original" : $0.ruleId) — \($0.reason)" }.joined(separator: "; ")
            return fail(why.isEmpty ? "there was nothing to try" : why, attempts, choice.attempts)
        }
        let entry = (ledger as? BackendS4AssetsLedger)?.entryFor(url) ?? decidedEntry
        let claimed = entry.flatMap { !$0.path.isEmpty && BackendS4AssetsNames.inside(dir: dir, path: $0.path) ? $0.path : nil } ?? ""
        let finalPath = !claimed.isEmpty ? claimed : BackendS4AssetsNames.freeDownloadPath(dir: dir, suggested: landed.name,
                                                                                         exists: { FileManager.default.fileExists(atPath: $0) }, taken: taken)
        taken.insert(finalPath)
        if Darwin.rename(part, finalPath) != 0 {
            let why = String(cString: strerror(errno))
            drop(part)
            return fail("the bytes arrived and could not be put at \(finalPath) — \(why)", attempts, choice.attempts)
        }
        let digest = BackendS4AssetsFiles.fingerprint(finalPath)?.digest ?? ""
        let bytes = landed.attempt.bytes ?? 0, won = landed.attempt
        let fellBack = won.url != choice.url || choice.fellBack
        if digest.isEmpty {
            let why = "the bytes landed at \(finalPath) and could not be read back to fingerprint them, so nothing was written into the ledger — this asset will be fetched again"
            var result = fail(why, attempts, choice.attempts)
            result.path = finalPath; result.bytes = bytes; result.fetchedUrl = won.url; result.ruleId = won.ruleId; result.line = "\(shown): \(why)."
            return result
        }
        _ = try await ledger.record(BackendS4AssetsObject.make([("url", .string(url)), ("fetchedUrl", .string(won.url)), ("ruleId", .string(won.ruleId)),
                                                                ("digest", .string(digest)), ("bytes", BackendS4AssetsObject.number(bytes)), ("path", .string(finalPath))]))
        let upgraded = !won.ruleId.isEmpty
        let line = upgraded
            ? "Fetched \(bytes) bytes from the \(won.ruleId) rewrite\(fellBack ? ", after a better one did not answer" : "")."
            : (fellBack ? "No upgrade held, so the original URL produced the bytes: \(describeRefusals(attempts))" : "Fetched \(bytes) bytes from the original URL.")
        return .init(url: url, outcome: fellBack ? "fell-back" : "fetched", fetchedUrl: won.url, ruleId: won.ruleId, upgraded: upgraded, fellBack: fellBack,
                     path: finalPath, bytes: bytes, digest: digest, reason: "", line: line, ledgerReason: reason, ledgerWasWrong: wrong, probed: choice.attempts, attempts: attempts)
    }

    static func describeBatch(asked: Int, fetched: Int, upgraded: Int, fellBack: Int, skipped: Int, failed: Int, wrong: Int) -> String {
        var parts = ["\(fetched) of \(asked) fetched"]
        if upgraded > 0 { parts.append("\(upgraded) from a rewrite") }
        if fellBack > 0 { parts.append("\(fellBack) fell back to a lower copy") }
        if skipped > 0 { parts.append("\(skipped) already on disk and verified") }
        if failed > 0 { parts.append("\(failed) failed") }
        if wrong > 0 { parts.append("\(wrong) were fetched because the ledger claimed a file that was missing or did not match — do not read this batch as a resume") }
        return parts.joined(separator: ", ")
    }
    static func emptyReason(asked: Int, fetched: Int, skipped: Int, failed: Int) -> String {
        if fetched > 0 { return "" }
        if asked == 0 { return "No URLs were given, so nothing was fetched." }
        if failed == 0 && skipped == asked {
            return "Nothing was fetched because there was nothing to fetch: all \(asked) are already on disk, at the length and digest the ledger recorded. Use mode: refetch if you meant to download them again."
        }
        if skipped == 0 {
            return "Nothing was fetched: all \(failed) of them failed. This is not an empty result, it is a failed one — read the reason on each row before treating this run as finished."
        }
        return "Nothing was fetched: \(failed) failed and \(skipped) were already on disk. The failures are real and are on the rows."
    }

    /// fetchAssets(): sequential, one shared `taken` set so two names cannot collide.
    static func fetchAssets(urls: [String], dir: String, rules: [BackendS4AssetsRule], transport: any BackendS4AssetsTransport, profile: String?,
                            ledger: any BackendDeckToolsAssetLedger, options: BackendS4AssetsRenditionOptions,
                            timeout: Int = fetchTimeoutMilliseconds) async throws -> NativeRPCValue {
        var results: [BackendS4AssetsFetchResult] = [], taken: Set<String> = []
        for url in urls {
            try Task.checkCancellation()
            results.append(try await fetchAsset(url: url, dir: dir, rules: rules, transport: transport, profile: profile, ledger: ledger,
                                                options: options, taken: &taken, timeout: timeout))
        }
        var fetched = 0, upgraded = 0, fellBack = 0, skipped = 0, failed = 0, bytes = 0, wrong = 0
        for result in results {
            if result.outcome == "skipped" { skipped += 1; continue }
            if result.outcome == "failed" { failed += 1; continue }
            fetched += 1; bytes += result.bytes
            if result.upgraded { upgraded += 1 }
            if result.fellBack { fellBack += 1 }
            if result.ledgerWasWrong { wrong += 1 }
        }
        let n = BackendS4AssetsObject.number
        let tally = BackendS4AssetsObject.make([("asked", n(results.count)), ("fetched", n(fetched)), ("upgraded", n(upgraded)), ("fellBack", n(fellBack)),
                                                ("skipped", n(skipped)), ("failed", n(failed)), ("bytes", n(bytes)), ("ledgerWasWrong", n(wrong))])
        let line = [describeBatch(asked: results.count, fetched: fetched, upgraded: upgraded, fellBack: fellBack, skipped: skipped, failed: failed, wrong: wrong),
                    emptyReason(asked: results.count, fetched: fetched, skipped: skipped, failed: failed)].filter { !$0.isEmpty }.joined(separator: " ")
        return BackendS4AssetsObject.make([("dir", .string(dir)), ("results", .array(results.map(\.value))), ("tally", tally), ("line", .string(line)),
                                           ("guarantee", .string(BackendDeckToolsAssets.guarantee))])
    }
}

/// Adapts the existing Safari fetch hooks (BackendBrowserAssetHooks: the app's own
/// WebKit profile, per-redirect origin grants, 64 MiB ceiling) to the transport.
/// The ceiling is a known native limit, not a change in behaviour: a body over it
/// fails the candidate loudly and nothing is written or recorded.
public struct BackendS4AssetsHooksTransport: BackendS4AssetsTransport {
    private let hooks: BackendBrowserAssetHooks
    private let caller: @Sendable () -> BackendBrowserScrapingCaller
    public init(hooks: BackendBrowserAssetHooks, caller: @escaping @Sendable () -> BackendBrowserScrapingCaller) { self.hooks = hooks; self.caller = caller }

    private func target(_ url: String) throws -> URL {
        guard let value = URL(string: url), ["http", "https"].contains(value.scheme?.lowercased() ?? "") else { throw NativeRPCError.invalidArguments("That is not an http address.") }
        return value
    }
    public func open(url: String, method: String, headers: [String: String], profile: String?, timeoutMilliseconds: Int) async throws -> BackendS4AssetsResponse {
        let who = caller(), address = try target(url), id = try await hooks.resolveProfile(who, profile)
        try await hooks.authorize(who, "assets.fetch", id, address, .object([]))
        let reply = try await hooks.fetch(who, id, address, method, BackendBrowserScrapingAssets.bodyLimit)
        try await hooks.authorize(who, "assets.fetch", id, reply.finalURL, .object([]))
        guard reply.complete, reply.body.count <= BackendBrowserScrapingAssets.bodyLimit else {
            throw NativeRPCError(code: "asset-too-large", message: "the body was incomplete or over the 64 MiB native asset limit")
        }
        let body = reply.body
        let stream = AsyncThrowingStream<Data, Error> { continuation in if !body.isEmpty { continuation.yield(body) }; continuation.finish() }
        return BackendS4AssetsResponse(status: reply.status, headers: reply.headers, body: method == "HEAD" ? nil : stream)
    }
    public func probe(url: String, profile: String?, timeoutMilliseconds: Int) async -> BackendS4AssetsProbe? {
        guard let address = try? target(url) else { return nil }
        let who = caller()
        guard let id = try? await hooks.resolveProfile(who, profile), (try? await hooks.authorize(who, "assets.rendition", id, address, .object([]))) != nil,
              let measured = try? await hooks.probe(who, id, address, false) else { return nil }
        return BackendS4AssetsProbe(status: measured.status, bytes: measured.bytes, contentType: measured.contentType)
    }
}
