import Foundation
import TerminalDeckNativeCore

/// The source-compatible asset domain behind the deck-control asset tools
/// (BackendDeckToolsAssetDomain), porting what asset-tools.ts delegates to:
/// browser-asset-ledger/-coverage/-rendition/-fetch/-probe, the run-owner file of
/// browser-scrape-status.ts, browser-scrape-paths.ts, readBlocksUnder and
/// blockCaptureOff. Files live exactly where the TypeScript put them
/// (`<userData>/scrape/runs/<safeRunId>/{ledger.jsonl,coverage.jsonl,profile}`,
/// `<userData>/scrape/blocks/**/blocks.jsonl`), so existing data stays readable.
/// Reuses BackendBrowserScrapingStore for profile settings and batch counts and
/// BackendBrowserScrapingRegex for JavaScript regex semantics; it does not
/// create a second browser, store or ledger.
public final class BackendS4AssetsDomain: BackendDeckToolsAssetDomain, @unchecked Sendable {
    private let root: URL
    private let transport: any BackendS4AssetsTransport
    private let profileExists: @Sendable (String) async -> Bool
    private let settingsFor: @Sendable (String) async throws -> NativeRPCValue
    private let batchNoted: @Sendable (String, NativeRPCValue) async -> Void
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var ledgers: [String: BackendS4AssetsLedger] = [:]

    /// - profileExists: true for a profile this browser actually has (the TS `deps.open`).
    public init(userData: URL, transport: any BackendS4AssetsTransport,
                profileExists: @escaping @Sendable (String) async -> Bool,
                settings: @escaping @Sendable (String) async throws -> NativeRPCValue,
                noteBatch: @escaping @Sendable (String, NativeRPCValue) async -> Void,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }) {
        root = userData; self.transport = transport; self.profileExists = profileExists
        settingsFor = settings; batchNoted = noteBatch; clock = now
    }
    /// The production wiring: profile settings and the per-profile batch tally come
    /// from the existing scraping store.
    public convenience init(userData: URL, store: BackendBrowserScrapingStore, transport: any BackendS4AssetsTransport,
                            profileExists: @escaping @Sendable (String) async -> Bool) {
        self.init(userData: userData, transport: transport, profileExists: profileExists,
                  settings: { try await store.config($0) }, noteBatch: { await store.noteBatch($0, tally: $1) })
    }

    // MARK: paths (browser-scrape-paths.ts)
    private func runFolder(_ run: String) -> String {
        root.appendingPathComponent("scrape/runs/" + BackendDeckToolsAssets.safeRunID(run), isDirectory: true).path
    }
    private func ledgerPath(_ run: String) -> String { runFolder(run) + "/ledger.jsonl" }
    private func coveragePath(_ run: String) -> String { runFolder(run) + "/coverage.jsonl" }
    private func ownerPath(_ run: String) -> String { runFolder(run) + "/profile" }

    public func userData() async throws -> String { root.path }

    public func validateProfile(_ profile: String?) async throws {
        guard let profile, !profile.isEmpty else { return }
        if await profileExists(profile) { return }
        throw NativeRPCError(code: "not-permitted", message: "\(profile) is not a profile in this browser. Fetching it without one would use nobody's cookies, which is how a run comes home with sixty thousand logged-out copies.")
    }

    // MARK: run owner (browser-scrape-status.ts runOwnerOf / noteRunProfile)
    public func runOwner(_ run: String) async throws -> String? {
        guard let data = FileManager.default.contents(atPath: ownerPath(run)), let text = String(data: data, encoding: .utf8) else { return nil }
        let owner = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }
    public func noteRunProfile(_ run: String, profile: String) async throws {
        if run.isEmpty || profile.isEmpty { return }
        let path = ownerPath(run)
        // Bookkeeping, never a reason to fail the call: a write that cannot happen is skipped.
        if let data = FileManager.default.contents(atPath: path), String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == profile { return }
        do {
            try FileManager.default.createDirectory(atPath: runFolder(run), withIntermediateDirectories: true)
            try Data((profile + "\n").utf8).write(to: URL(fileURLWithPath: path))
        } catch {}
    }

    public func settings(_ profile: String?) async throws -> NativeRPCValue {
        guard let profile, !profile.isEmpty else { return .object([]) }
        return try await settingsFor(profile)
    }

    // MARK: rendition
    public func rendition(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let url = arguments["url"].string, !url.isEmpty else { throw NativeRPCError.invalidArguments("url is required") }
        let profile = arguments["profileId"].string.flatMap { $0.isEmpty ? nil : $0 }
        let transport = self.transport
        let choice = await BackendS4AssetsRendition.choose(url: url, rules: BackendS4AssetsRule.read(arguments["rules"]),
            probe: { candidate in await transport.probe(url: candidate, profile: profile, timeoutMilliseconds: BackendS4AssetsRendition.probeTimeoutMilliseconds) },
            options: BackendS4AssetsRenditionOptions(arguments))
        return choice.value
    }

    // MARK: ledger (one live object per mode and path, as the tool kept it)
    public func ledger(run: String, mode: String) async throws -> any BackendDeckToolsAssetLedger {
        let path = ledgerPath(run), selected = mode == "refetch" ? "refetch" : "resume", key = selected + "\u{0}" + path
        let clock = self.clock
        return lock.withLock { () -> BackendS4AssetsLedger in
            if let held = ledgers[key] { return held }
            let made = BackendS4AssetsLedger(path: path, mode: selected, now: clock)
            ledgers[key] = made; return made
        }
    }
    public func fingerprint(path: String) async throws -> NativeRPCValue {
        guard let found = BackendS4AssetsFiles.fingerprint(path) else { throw NativeRPCError(code: "not-found", message: "no readable file there") }
        return BackendS4AssetsObject.make([("bytes", BackendS4AssetsObject.number(found.bytes)), ("digest", .string(found.digest))])
    }

    // MARK: fetch
    public func fetch(_ arguments: NativeRPCValue, ledger: any BackendDeckToolsAssetLedger) async throws -> NativeRPCValue {
        guard let urls = arguments["urls"].elements?.compactMap(\.string), let dir = arguments["dir"].string else {
            throw NativeRPCError.invalidArguments("urls and dir are required")
        }
        let profile = arguments["profileId"].string.flatMap { $0.isEmpty ? nil : $0 }
        return try await BackendS4AssetsFetch.fetchAssets(urls: urls, dir: dir, rules: BackendS4AssetsRule.read(arguments["rules"]), transport: transport,
                                                          profile: profile, ledger: ledger, options: BackendS4AssetsRenditionOptions(arguments))
    }
    public func noteAssetBatch(profile: String, tally: NativeRPCValue) async throws {
        if profile.isEmpty { return }
        await batchNoted(profile, tally)
    }

    // MARK: coverage
    public func statedTotal(text: String, pattern: String?, flags: String?) async throws -> NativeRPCValue? {
        BackendS4AssetsCoverage.statedTotal(text: text, pattern: pattern, flags: flags)
    }
    public func compareCoverage(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        BackendS4AssetsCoverage.compare(arguments, defaultNow: clock())
    }
    public func readCoverage(run: String) async throws -> [NativeRPCValue] { BackendS4AssetsCoverage.read(path: coveragePath(run)) }
    public func recordCoverage(run: String, check: NativeRPCValue) async throws -> Bool { BackendS4AssetsCoverage.record(path: coveragePath(run), check: check) }

    // MARK: blocks (readBlocksUnder + blockCaptureOff)
    private func readBlocks(_ folder: URL) -> [NativeRPCValue] {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("blocks.jsonl").path), let text = String(data: data, encoding: .utf8) else { return [] }
        var shots: [NativeRPCValue] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let parsed = try? NativeRPCValue.parseJSON(Data(trimmed.utf8)), parsed.fields != nil, parsed["at"].number != nil { shots.append(parsed) }
        }
        return shots
    }
    /// The root and one level of folders beneath it, oldest first. The root is read
    /// too, as in the source: rows written before the per-profile split are evidence.
    /// (Known privacy difference flagged for the Safari owner: the source has no
    /// per-caller origin filter here either.)
    public func blocks() async throws -> [NativeRPCValue] {
        let base = root.appendingPathComponent("scrape/blocks", isDirectory: true)
        var shots = readBlocks(base)
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue { shots += readBlocks(child) }
        }
        return shots.sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }
    }
    /// Profiles whose block camera is switched off: the newer per-profile setting,
    /// else the former `scrape/block-capture.json` switch.
    public func blockCaptureOff() async throws -> [String] {
        var answers: [String: Bool] = [:]
        if let data = FileManager.default.contents(atPath: root.appendingPathComponent("scrape/block-capture.json").path),
           let legacy = try? NativeRPCValue.parseJSON(data) {
            for field in legacy.fields ?? [] { if let on = field.value.bool { answers[field.key] = on } }
        }
        if let data = FileManager.default.contents(atPath: root.appendingPathComponent("browser-scraping.json").path),
           let profiles = (try? NativeRPCValue.parseJSON(data))?["profiles"] {
            for field in profiles.fields ?? [] { if let on = field.value["checks"]["screenshotOnBlock"].bool { answers[field.key] = on } }
        }
        return answers.filter { !$0.value }.map(\.key).sorted()
    }
}
