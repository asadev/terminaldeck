import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixtures for the asset-tools.test.ts port (lane S2).
///
/// The five asset tools are driven through the real source tool layer
/// (`BackendDeckToolsAssets.definitions`) behind the real schema gate
/// (`BackendDeckCoreCatalogueSchema.check`), the way the TypeScript drives them
/// through `DeckControl`. No source-compatible `BackendDeckToolsAssetDomain`
/// exists yet (deck-tools-HANDOFF.md "Asset adapter requirements" 1-4), so the
/// domain here is a recording fake. Where a real native primitive exists it is
/// used instead of a stand-in: file fingerprints (`BackendBrowserScrapingIO`),
/// coverage pattern reading (`BackendBrowserScrapingRegex`), block verdicts
/// (`BackendBrowserScrapingStore.blockVerdict`). No network, no real clock.
enum S2Assets {
    static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    static let clock: Double = 1_700_000_000_000

    static func value(_ reply: BackendMCPToolReply) -> NativeRPCValue { reply.structuredContent ?? .missing }
    static func error(_ reply: BackendMCPToolReply) -> String { reply.structuredContent?["error"].string ?? "" }
    static func refusal(_ reply: BackendMCPToolReply) -> String? { reply.structuredContent?["refusal"].string }

    static func rule(_ id: String, _ match: String, _ replace: String) -> NativeRPCValue {
        o([("id", .string(id)), ("match", .string(match)), ("replace", .string(replace))])
    }
    /// A source RenditionChoice, the shape `assets.rendition` requires back.
    static func rendition(url: String, original: String, ruleId: String, upgraded: Bool, fellBack: Bool,
                          reachable: Bool = true) -> NativeRPCValue {
        let attempt = o([("url", .string(url)), ("ruleId", .string(ruleId)), ("ok", .bool(reachable)), ("reason", .string("")),
                         ("status", .number(200)), ("bytes", .number(400_000)), ("private", .string("domain-only"))])
        return o([("url", .string(url)), ("ruleId", .string(ruleId)), ("upgraded", .bool(upgraded)), ("fellBack", .bool(fellBack)),
                  ("reachable", .bool(reachable)), ("comparedBytes", .bool(true)), ("originalUrl", .string(original)),
                  ("line", .string("rendition line")), ("attempts", .array([attempt]))])
    }
    static func tally(asked: Double = 1, fetched: Double = 0, skipped: Double = 0, failed: Double = 0, bytes: Double = 0) -> NativeRPCValue {
        o([("asked", .number(asked)), ("fetched", .number(fetched)), ("upgraded", .number(0)), ("fellBack", .number(0)),
           ("skipped", .number(skipped)), ("failed", .number(failed)), ("bytes", .number(bytes)), ("ledgerWasWrong", .number(0))])
    }
    static func row(url: String, outcome: String, path: String, digest: String, bytes: Double, line: String) -> NativeRPCValue {
        o([("url", .string(url)), ("outcome", .string(outcome)), ("fetchedUrl", .string(outcome == "failed" ? "" : url)),
           ("ruleId", .string("")), ("path", .string(path)), ("bytes", .number(bytes)), ("digest", .string(digest)),
           ("reason", .string("")), ("line", .string(line)), ("ledgerWasWrong", .bool(false)),
           ("attempts", .array([])), ("probed", .array([]))])
    }
    static func batch(dir: String, line: String, tally: NativeRPCValue, rows: [NativeRPCValue]) -> NativeRPCValue {
        o([("dir", .string(dir)), ("line", .string(line)), ("tally", tally), ("results", .array(rows))])
    }
}

/// `throw new Error(...)` in the TypeScript fakes: a plain error, no RPC code.
struct S2AssetsPlainError: Error, LocalizedError, Sendable {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

struct S2AssetsAuthorization: Sendable {
    let tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue
}

struct S2AssetsStatedCall: Sendable {
    let text: String, pattern: String?, flags: String?
}

/// One ledger per (run, mode), shared like the source's per-(mode, path) ledger.
/// Decisions and verify verdicts are scripted: the source decide/verify logic is
/// the missing domain seam, and the tests assert only what the tool layer does
/// with them.
actor S2AssetsLedger: BackendDeckToolsAssetLedger {
    let run: String, mode: String
    private(set) var decided: [String] = []
    private(set) var expected: [String?] = []
    private(set) var recorded: [NativeRPCValue] = []
    private var decisions: [NativeRPCValue] = []
    private var verdict: NativeRPCValue?
    init(run: String, mode: String) { self.run = run; self.mode = mode }
    func script(decision: NativeRPCValue) { decisions.append(decision) }
    func script(verify: NativeRPCValue) { verdict = verify }
    func decide(url: String, expectDigest: String?) async throws -> NativeRPCValue {
        decided.append(url); expected.append(expectDigest)
        guard !decisions.isEmpty else { throw BackendDeckToolsSupport.unavailable("unscripted S2 ledger decision") }
        return decisions.removeFirst()
    }
    func record(_ entry: NativeRPCValue) async throws -> NativeRPCValue { recorded.append(entry); return entry }
    func verify() async throws -> NativeRPCValue {
        guard let verdict else { throw BackendDeckToolsSupport.unavailable("unscripted S2 ledger verify") }
        return verdict
    }
    func tally() async throws -> NativeRPCValue {
        S2Assets.o([("known", .number(0)), ("unreadable", .number(0)), ("skipped", .number(0)), ("fetched", .number(0)),
                    ("ledgerWasWrong", .number(0)), ("recorded", .number(Double(recorded.count)))])
    }
    func summary() async throws -> String { "Ledger \(run): \(recorded.count) recorded." }
}

actor S2AssetsDomain: BackendDeckToolsAssetDomain {
    let root: String
    private var stored: [String: NativeRPCValue] = [:]
    private var owners: [String: String] = [:]
    private var ledgers: [String: S2AssetsLedger] = [:]
    private var renditionReplies: [NativeRPCValue] = []
    private var batches: [NativeRPCValue] = []
    private var verdicts: [NativeRPCValue] = []
    private var checks: [String: [NativeRPCValue]] = [:]
    private var blockRows: [NativeRPCValue] = []
    private(set) var dataRootAsked = 0
    private(set) var ownersAsked: [String] = []
    private(set) var validated: [String?] = []
    private(set) var settingsAsked: [String?] = []
    private(set) var filed: [String] = []
    private(set) var ledgerRequests: [String] = []
    private(set) var fingerprinted: [String] = []
    private(set) var renditionCalls: [NativeRPCValue] = []
    private(set) var fetchCalls: [NativeRPCValue] = []
    private(set) var fetchLedgers: [ObjectIdentifier?] = []
    private(set) var notedBatches: [String] = []
    private(set) var statedCalls: [S2AssetsStatedCall] = []
    private(set) var comparisons: [NativeRPCValue] = []
    private(set) var recordedRuns: [String] = []
    private(set) var blocksAsked = 0

    init(root: String) { self.root = root }

    // Scripting.
    func store(_ profile: String, _ settings: NativeRPCValue) { stored[profile] = settings }
    func script(rendition: NativeRPCValue) { renditionReplies.append(rendition) }
    func script(batch: NativeRPCValue) { batches.append(batch) }
    func script(verdict: NativeRPCValue) { verdicts.append(verdict) }
    func script(blocks: [NativeRPCValue]) { blockRows = blocks }
    func ledgerNamed(run: String, mode: String) -> S2AssetsLedger {
        let key = run + "|" + mode
        if let existing = ledgers[key] { return existing }
        let made = S2AssetsLedger(run: run, mode: mode); ledgers[key] = made; return made
    }
    func owner(of run: String) -> String? { owners[run] }
    func checksIn(_ run: String) -> [NativeRPCValue] { checks[run] ?? [] }
    /// Every domain operation the tool layer reached, summed.
    var touched: Int {
        dataRootAsked + ownersAsked.count + validated.count + settingsAsked.count + filed.count + ledgerRequests.count
            + fingerprinted.count + renditionCalls.count + fetchCalls.count + notedBatches.count + statedCalls.count
            + comparisons.count + recordedRuns.count + blocksAsked
    }

    // BackendDeckToolsAssetDomain.
    func userData() async throws -> String { dataRootAsked += 1; return root }
    /// asset-tools.test.ts `open`: null, '', 'default' and a UUID are profiles;
    /// anything else throws a plain Error naming it.
    func validateProfile(_ profile: String?) async throws {
        validated.append(profile)
        guard let profile, !profile.isEmpty, profile != "default" else { return }
        if profile.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) == nil {
            throw S2AssetsPlainError("\(profile) is not a profile in this browser.")
        }
    }
    func runOwner(_ run: String) async throws -> String? { ownersAsked.append(run); return owners[run] }
    func settings(_ profile: String?) async throws -> NativeRPCValue {
        settingsAsked.append(profile)
        return profile.flatMap { stored[$0] } ?? .object([])
    }
    func noteRunProfile(_ run: String, profile: String) async throws { filed.append(run); owners[run] = profile }
    func rendition(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        renditionCalls.append(arguments)
        guard !renditionReplies.isEmpty else { throw BackendDeckToolsSupport.unavailable("unscripted S2 rendition") }
        return renditionReplies.removeFirst()
    }
    func ledger(run: String, mode: String) async throws -> any BackendDeckToolsAssetLedger {
        ledgerRequests.append(run + "|" + mode)
        return ledgerNamed(run: run, mode: mode)
    }
    /// The native owner's own streaming SHA-256 over the real file.
    func fingerprint(path: String) async throws -> NativeRPCValue {
        fingerprinted.append(path)
        let found = try BackendBrowserScrapingIO.fingerprint(URL(fileURLWithPath: path))
        return S2Assets.o([("digest", .string(found.digest)), ("bytes", .number(Double(found.bytes)))])
    }
    func fetch(_ arguments: NativeRPCValue, ledger: any BackendDeckToolsAssetLedger) async throws -> NativeRPCValue {
        fetchCalls.append(arguments)
        fetchLedgers.append((ledger as? S2AssetsLedger).map { ObjectIdentifier($0) })
        guard !batches.isEmpty else { throw BackendDeckToolsSupport.unavailable("unscripted S2 fetch batch") }
        return batches.removeFirst()
    }
    func noteAssetBatch(profile: String, tally: NativeRPCValue) async throws { notedBatches.append(profile) }
    /// A pattern is read with the native JavaScriptCore reader and number
    /// parser. The source's generic page shapes ("of N", "N results", "N total")
    /// have no source-compatible native reader, so no pattern reads nothing.
    func statedTotal(text: String, pattern: String?, flags: String?) async throws -> NativeRPCValue? {
        statedCalls.append(.init(text: text, pattern: pattern, flags: flags))
        guard let pattern, let captured = try BackendBrowserScrapingRegex.firstCapture(text, pattern: pattern, flags: flags ?? ""),
              let total = BackendBrowserScrapingRegex.total(captured) else { return nil }
        return S2Assets.o([("total", .number(total)), ("match", .string(captured)), ("pattern", .string(pattern))])
    }
    func compareCoverage(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        comparisons.append(arguments)
        guard !verdicts.isEmpty else { throw BackendDeckToolsSupport.unavailable("unscripted S2 coverage verdict") }
        return arguments.merging(verdicts.removeFirst())
    }
    func readCoverage(run: String) async throws -> [NativeRPCValue] { checks[run] ?? [] }
    func recordCoverage(run: String, check: NativeRPCValue) async throws -> Bool {
        recordedRuns.append(run); checks[run, default: []].append(check); return true
    }
    func blocks() async throws -> [NativeRPCValue] { blocksAsked += 1; return blockRows }
    func blockCaptureOff() async throws -> [String] { [] }
}

actor S2AssetsRuntime: BackendDeckToolsAssetRuntime {
    let kind: String
    private(set) var authorized: [S2AssetsAuthorization] = []
    private(set) var completedSummaries: [NativeRPCValue] = []
    init(kind: String) { self.kind = kind }
    nonisolated func now() -> Double { S2Assets.clock }
    func callerKind(_ caller: BackendMCPCallContext) async throws -> String { kind }
    func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws {
        authorized.append(.init(tool: tool, tier: tier, summary: summary, arguments: arguments))
    }
    func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {
        completedSummaries.append(summary)
    }
}

struct S2AssetsRig {
    let directory: URL
    let userData: String, files: String
    let domain: S2AssetsDomain, runtime: S2AssetsRuntime
    let definitions: [BackendDeckToolsDefinition]

    /// Real temporary folders, resolved through /var → /private/var so the
    /// native fingerprint's no-symlink rule sees the real path.
    static func make(kind: String = "local") throws -> S2AssetsRig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsS2TestsAssets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw S2AssetsPlainError("no real path for \(base.path)") }
        defer { free(resolved) }
        let real = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let userData = real.appendingPathComponent("data", isDirectory: true), files = real.appendingPathComponent("files", isDirectory: true)
        for folder in [userData, files] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let domain = S2AssetsDomain(root: userData.path), runtime = S2AssetsRuntime(kind: kind)
        return S2AssetsRig(directory: real, userData: userData.path, files: files.path, domain: domain, runtime: runtime,
                           definitions: try BackendDeckToolsAssets.definitions(domain: domain, runtime: runtime))
    }

    /// The schema gate then the source handler, as DeckControl.call does.
    func call(_ id: String, _ args: NativeRPCValue, tiers: Set<BackendMCPTier> = [.read, .act, .alter]) async -> BackendMCPToolReply {
        guard let definition = definitions.first(where: { $0.spec.id == id }) else { return .failure("there is no tool called \(id)") }
        let context = BackendMCPCallContext(sessionID: "s2-assets", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: tiers, cancellation: .init())
        return await BackendDeckToolsSupport.reply {
            try BackendDeckCoreCatalogueSchema.check(tool: definition.spec, arguments: args)
            return try await definition.handler(context, args)
        }
    }

    /// Write a file into the files folder; answers its path and the digest the
    /// native owner gives those bytes (digestOf in the TypeScript).
    func asset(_ name: String, _ contents: String) throws -> (path: String, digest: String) {
        let url = URL(fileURLWithPath: files).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return (url.path, BackendBrowserScrapingIO.digest(Data(contents.utf8)))
    }

    func runFolder(_ run: String) -> String { userData + "/scrape/runs/" + run }

    func dispose() { try? FileManager.default.removeItem(at: directory) }
}
