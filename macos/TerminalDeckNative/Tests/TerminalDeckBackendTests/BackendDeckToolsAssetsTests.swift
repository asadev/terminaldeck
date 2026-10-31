import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsAssetsTests: XCTestCase {
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    func testBatchCapAndAddresses() throws {
        XCTAssertEqual(try BackendDeckToolsAssets.urls(o([("urls", .array([.string("https://x.test/a.jpg")]))])), ["https://x.test/a.jpg"])
        XCTAssertThrowsError(try BackendDeckToolsAssets.urls(o([("urls", .array(Array(repeating: .string("https://x.test/a.jpg"), count: 201)))])))
        XCTAssertThrowsError(try BackendDeckToolsAssets.urls(o([("urls", .array([.string("file:///etc/passwd")]))])))
        XCTAssertThrowsError(try BackendDeckToolsAssets.urls(o([("urls", .array([]))])))
    }
    func testSecretsInSingularAndPluralURLsAreRedacted() {
        let value = BackendDeckToolsAssets.redact(o([("url", .string("https://x.test/a?token=secret&w=1920")), ("urls", .array([.string("https://x.test/b?X-Amz-Signature=secret2&keep=yes")]))]))
        XCTAssertFalse(value.compact.contains("secret")); XCTAssertTrue(value.compact.contains("1920")); XCTAssertTrue(value.compact.contains("keep=yes"))
        XCTAssertEqual(BackendDeckToolsAssets.scrubURL("https://x.test/a.jpg"), "https://x.test/a.jpg")
    }
    func testNoEvidenceCannotBeComplete() {
        let summary = BackendDeckToolsAssets.coverageSummary([])
        XCTAssertEqual(summary["ok"], .bool(false)); XCTAssertTrue(summary["line"].string!.contains("No coverage check"))
        let unknown = BackendDeckToolsAssets.coverageSummary([o([("verdict", .string("unknown"))])])
        XCTAssertEqual(unknown["ok"], .bool(false)); XCTAssertEqual(unknown["unknown"], .number(1))
    }
    func testFailedBatchIsAProducedFindingAndResumeIsEmpty() {
        XCTAssertEqual(BackendDeckToolsAssets.empty(.object([]), produced: 1, reason: ""), o([("empty", .bool(false)), ("emptyReason", .string(""))]))
        XCTAssertEqual(BackendDeckToolsAssets.empty(.object([]), produced: 0, reason: "already verified")["emptyReason"], .string("already verified"))
    }
    func testRulesNameTheDuplicateAndKeepSourceLimits() {
        let rule = o([("id", .string("same")), ("match", .string("/small/")), ("replace", .string("/big/"))])
        XCTAssertThrowsError(try BackendDeckToolsAssets.readRules(.array([rule, rule]))) { XCTAssertEqual(($0 as? NativeRPCError)?.message, "two rules are called same") }
        XCTAssertThrowsError(try BackendDeckToolsAssets.readRules(.array(Array(repeating: rule, count: 21))))
    }
    func testBothAssetNameSpellingsAreGranted() {
        XCTAssertEqual(BackendDeckToolsAssets.toolNames.count, 10)
        XCTAssertTrue(BackendDeckToolsAssets.toolNames.contains("assets_fetch")); XCTAssertTrue(BackendDeckToolsAssets.toolNames.contains("assets.fetch"))
    }
    func testRunFolderCannotEchoTraversal() {
        XCTAssertEqual(BackendDeckToolsAssets.safeRunID("../../outside"), "outside")
        XCTAssertEqual(BackendDeckToolsAssets.safeRunID("...---"), "run")
        XCTAssertEqual(BackendDeckToolsAssets.safeRunID("run/😀"), "run---")
    }
    struct Ledger: BackendDeckToolsAssetLedger {
        func decide(url: String, expectDigest: String?) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused ledger decide") }
        func record(_ entry: NativeRPCValue) async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused ledger record") }
        func verify() async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused ledger verify") }
        func tally() async throws -> NativeRPCValue { throw BackendDeckToolsSupport.unavailable("unused ledger tally") }
        func summary() async throws -> String { throw BackendDeckToolsSupport.unavailable("unused ledger summary") }
    }
    actor Domain: BackendDeckToolsAssetDomain {
        var fetchedArguments: NativeRPCValue = .missing, coverageArguments: NativeRPCValue = .missing
        func userData() async throws -> String { "/test/state" }
        func validateProfile(_ profile: String?) async throws {}
        func runOwner(_ run: String) async throws -> String? { nil }
        func settings(_ profile: String?) async throws -> NativeRPCValue {
            let upgrade = NativeRPCValue.object([.init("on", .bool(true)), .init("from", .string("?w=498")), .init("to", .string("$1920"))])
            return BackendDeckToolsSupport.object([("assets", .object([.init("upgrade", upgrade)]))])
        }
        func ledger(run: String, mode: String) async throws -> any BackendDeckToolsAssetLedger { Ledger() }
        func fetch(_ arguments: NativeRPCValue, ledger: any BackendDeckToolsAssetLedger) async throws -> NativeRPCValue {
            fetchedArguments = arguments
            let tally = BackendDeckToolsSupport.object([("asked", .number(1)), ("fetched", .number(1)), ("upgraded", .number(0)), ("fellBack", .number(0)), ("skipped", .number(0)), ("failed", .number(0)), ("bytes", .number(10)), ("ledgerWasWrong", .number(0))])
            let row = BackendDeckToolsSupport.object([("url", .string("https://x.test/a")), ("outcome", .string("fetched")),
                ("fetchedUrl", .string("https://x.test/a")), ("ruleId", .string("")), ("path", .string("/test/files/a")),
                ("bytes", .number(10)), ("digest", .string("sha256:fixture")), ("reason", .string("")), ("line", .string("Fetched.")),
                ("ledgerWasWrong", .bool(false)), ("attempts", .array([])), ("probed", .array([])), ("secret", .string("row-private"))])
            return BackendDeckToolsSupport.object([("dir", .string("/test/files")), ("line", .string("1 of 1 fetched")), ("tally", tally), ("secret", .string("domain-private")), ("results", .array([row]))])
        }
        func compareCoverage(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
            coverageArguments = arguments
            return BackendDeckToolsSupport.object([("verdict", .string("complete")), ("stated", arguments["stated"]), ("captured", arguments["captured"]), ("missing", .number(0)), ("at", arguments["now"])])
        }
        func recordCoverage(run: String, check: NativeRPCValue) async throws -> Bool { true }
    }
    struct Runtime: BackendDeckToolsAssetRuntime {
        func now() -> Double { 42 }
        func callerKind(_ caller: BackendMCPCallContext) async throws -> String { "local" }
        func authorize(_ caller: BackendMCPCallContext, tool: String, tier: BackendMCPTier, summary: String, arguments: NativeRPCValue) async throws {}
        func completed(_ caller: BackendMCPCallContext, tool: String, summary: NativeRPCValue) async throws {}
    }
    private func context() -> BackendMCPCallContext { .init(sessionID: "test", machineID: "", projectRoot: nil, attended: true, allowedTools: ["assets.fetch", "assets.coverage"], allowedTiers: [.read, .act, .alter], cancellation: .init()) }
    func testFetchResolvesStoredOptionsAndKeepsDomainPrivateFieldsOut() async throws {
        let domain = Domain(), definitions = try BackendDeckToolsAssets.definitions(domain: domain, runtime: Runtime())
        let fetch = definitions.first { $0.spec.id == "assets.fetch" }!
        let reply = try await fetch.handler(context(), o([("runId", .string("r")), ("dir", .string("/test/files")), ("urls", .array([.string("https://x.test/a")])), ("minBytes", .number(-2.8)), ("requireLarger", .bool(false))]))
        XCTAssertFalse(reply.isError)
        let arguments = await domain.fetchedArguments, rule = arguments["rules"].elements!.first!
        XCTAssertEqual(rule["id"], .string("upgrade")); XCTAssertEqual(rule["match"], .string("\\?w=498")); XCTAssertEqual(rule["replace"], .string("$$1920"))
        XCTAssertEqual(arguments["minBytes"], .number(0)); XCTAssertEqual(arguments["requireLarger"], .bool(false))
        XCTAssertFalse(reply.structuredContent!.compact.contains("private"))
    }
    func testCoverageReceivesSourceURLAndCallClock() async throws {
        let domain = Domain(), definitions = try BackendDeckToolsAssets.definitions(domain: domain, runtime: Runtime())
        let coverage = definitions.first { $0.spec.id == "assets.coverage" }!
        let reply = try await coverage.handler(context(), o([("runId", .string("r")), ("captured", .number(1)), ("stated", .number(1)), ("pageUrl", .string("https://x.test/a?token=secret"))]))
        XCTAssertFalse(reply.isError)
        let arguments = await domain.coverageArguments
        XCTAssertEqual(arguments["now"], .number(42)); XCTAssertEqual(arguments["pageUrl"], .missing)
        XCTAssertFalse(arguments["url"].string!.contains("secret"))
    }
    func testMalformedResultRowsAreUnavailableRatherThanEmptySuccess() {
        let tally = o([("asked", .number(1)), ("fetched", .number(1)), ("upgraded", .number(0)), ("fellBack", .number(0)), ("skipped", .number(0)), ("failed", .number(0)), ("bytes", .number(10)), ("ledgerWasWrong", .number(0))])
        let batch = o([("dir", .string("/test/files")), ("line", .string("1 fetched")), ("tally", tally), ("results", .array([.null]))])
        XCTAssertThrowsError(try BackendDeckToolsAssets.fetchValue(batch, run: "r", mode: "resume", folder: "/test/state/scrape/runs/r"))
    }
}
