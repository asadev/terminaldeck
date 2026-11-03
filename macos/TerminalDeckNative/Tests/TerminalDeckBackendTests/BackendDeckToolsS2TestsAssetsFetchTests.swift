import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// asset-tools.test.ts: assets.fetch, assets.blocks and "what the profile
/// stored". Map: macos/night/S2-Assets.md. Fixtures:
/// BackendDeckToolsS2TestsAssetsFixtures.swift.
final class BackendDeckToolsS2TestsAssetsFetchTests: XCTestCase {
    private typealias A = S2Assets
    private static let plan = "http://127.0.0.1:9/plan.jpg"
    private static let bytes = "a floor plan, 1920px, and every byte of it"

    private func fetched(_ rig: S2AssetsRig) -> NativeRPCValue {
        let digest = BackendBrowserScrapingIO.digest(Data(Self.bytes.utf8)), size = Double(Self.bytes.utf8.count)
        return A.batch(dir: rig.files, line: "1 of 1 fetched.", tally: A.tally(fetched: 1, bytes: size),
                       rows: [A.row(url: Self.plan, outcome: "fetched", path: rig.files + "/plan.jpg", digest: digest, bytes: size, line: "Fetched.")])
    }
    private func fetch(_ rig: S2AssetsRig, run: String, _ extra: [(String, NativeRPCValue)] = [],
                       tiers: Set<BackendMCPTier> = [.read, .act, .alter]) async -> BackendMCPToolReply {
        let base: [(String, NativeRPCValue)] = [("runId", .string(run)), ("dir", .string(rig.files)), ("urls", .array([.string(Self.plan)]))]
        return await rig.call("assets.fetch", A.o(base + extra), tiers: tiers)
    }

    // MARK: assets.fetch

    func testL395FetchedFileComesBackWithItsDigestAndTheSecondCallIsASkipOffTheSameLedger() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let digest = BackendBrowserScrapingIO.digest(Data(Self.bytes.utf8)), path = rig.files + "/plan.jpg"
        await rig.domain.script(batch: fetched(rig))
        await rig.domain.script(batch: A.batch(dir: rig.files, line: "1 already on disk.", tally: A.tally(skipped: 1),
            rows: [A.row(url: Self.plan, outcome: "skipped", path: path, digest: digest, bytes: Double(Self.bytes.utf8.count), line: "Already on disk.")]))
        let first = await fetch(rig, run: "portal")
        XCTAssertFalse(first.isError, A.error(first))
        let value = A.value(first)
        XCTAssertEqual(value["tally"]["fetched"], .number(1)); XCTAssertEqual(value["tally"]["failed"], .number(0))
        XCTAssertEqual(value["empty"], .bool(false))
        let row = value["results"].elements?.first ?? .missing
        XCTAssertEqual(row["outcome"], .string("fetched")); XCTAssertEqual(row["fetchedUrl"], .string(Self.plan))
        XCTAssertEqual(row["path"], .string(path)); XCTAssertEqual(row["digest"], .string(digest))
        XCTAssertEqual(value["runId"], .string("portal")); XCTAssertEqual(value["mode"], .string("resume"))
        XCTAssertEqual(value["ledger"], .string(rig.runFolder("portal") + "/ledger.jsonl"))
        XCTAssertEqual(value["guarantee"], .string(BackendDeckToolsAssets.guarantee))

        let againReply = await fetch(rig, run: "portal"), again = A.value(againReply)
        XCTAssertEqual(again["tally"]["skipped"], .number(1))
        XCTAssertEqual(again["empty"], .bool(true))
        let reason = again["emptyReason"].string ?? ""
        XCTAssertTrue(reason.contains("already on"), reason); XCTAssertTrue(reason.contains("refetch"), reason)

        let calls = await rig.domain.fetchCalls, ledgers = await rig.domain.fetchLedgers
        XCTAssertEqual(calls.first?["dir"], .string(rig.files)); XCTAssertEqual(calls.first?["urls"], .array([.string(Self.plan)]))
        XCTAssertEqual(ledgers.count, 2); XCTAssertNotNil(ledgers.first ?? nil); XCTAssertEqual(ledgers.first, ledgers.last)
    }

    func testL433BatchThatFetchedNothingIsNotReportedAsAnEmptyAnswer() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let missing = "http://127.0.0.1:9/missing.jpg"
        await rig.domain.script(batch: A.batch(dir: rig.files,
            line: "Nothing was fetched: all 1 of them failed. This is not an empty result, it is a failed one.",
            tally: A.tally(failed: 1), rows: [A.row(url: missing, outcome: "failed", path: "", digest: "", bytes: 0, line: "HTTP 404.")]))
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("portal")), ("dir", .string(rig.files)), ("urls", .array([.string(missing)]))]))
        let value = A.value(answer)
        XCTAssertEqual(value["tally"]["failed"], .number(1))
        XCTAssertEqual(value["empty"], .bool(false))
        XCTAssertEqual(value["emptyReason"], .string(""))
        XCTAssertTrue(value["line"].string?.contains("not an empty result") == true)
    }

    func testL455RelativeFolderIsRefusedRatherThanWrittenSomewhereNobodyChose() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("portal")), ("dir", .string("downloads")), ("urls", .array([.string(Self.plan)]))]))
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted")
        XCTAssertTrue(A.error(answer).contains("absolute"), A.error(answer))
        let touched = await rig.domain.touched
        XCTAssertEqual(touched, 0)
    }

    func testL465FetchRefusesAnythingThatIsNotAnHTTPAddress() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        for bad in ["file:///etc/passwd", "data:image/png;base64,AAAA", "javascript:1"] {
            let answer = await rig.call("assets.fetch", A.o([("runId", .string("p")), ("dir", .string(rig.files)), ("urls", .array([.string(bad)]))]))
            XCTAssertTrue(answer.isError, bad)
            XCTAssertTrue(A.error(answer).contains("http"), "\(bad): \(A.error(answer))")
        }
        let calls = await rig.domain.fetchCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testL473EmptyListIsRefusedRatherThanACleanRunOverNothing() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("p")), ("dir", .string(rig.files)), ("urls", .array([]))]))
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(A.error(answer).contains("nothing to fetch"), A.error(answer))
    }

    /// TypeScript `mayFetchAs` turns ANY throw from `open(profileId)` into a
    /// `not-permitted` refusal. The fake throws a plain error, as the TypeScript
    /// fake does. Expected red until BackendDeckToolsAssets wraps
    /// validateProfile failures (macos/NIGHT-REQUESTS.md, S2-Assets).
    func testL479NotAProfileIsRefusedAtTheDoorInsteadOfFetchingWithoutCookies() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await fetch(rig, run: "p", [("profileId", .string("../../etc"))])
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted", "a profile that is not one must be a refusal, not an error")
        XCTAssertTrue(A.error(answer).contains("not a profile"), A.error(answer))
        let calls = await rig.domain.fetchCalls, authorized = await rig.runtime.authorized
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(authorized.isEmpty)
    }

    func testL497FetchesOutOfTheProfileItWasGiven() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(batch: fetched(rig))
        let answer = await fetch(rig, run: "p", [("profileId", .string("default"))])
        XCTAssertFalse(answer.isError, A.error(answer))
        let calls = await rig.domain.fetchCalls, validated = await rig.domain.validated, noted = await rig.domain.notedBatches
        XCTAssertEqual(calls.first?["profileId"], .string("default"))
        XCTAssertEqual(validated, ["default"]); XCTAssertEqual(noted, ["default"])
    }

    func testL507PresignedSignatureIsKeptOutOfTheLog() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let signed = "http://127.0.0.1:9/plan.jpg?X-Amz-Signature=deadbeef&keep=this"
        await rig.domain.script(batch: fetched(rig))
        _ = await rig.call("assets.fetch", A.o([("runId", .string("p")), ("dir", .string(rig.files)), ("urls", .array([.string(signed)]))]))
        let authorized = await rig.runtime.authorized, summaries = await rig.runtime.completedSummaries
        XCTAssertEqual(authorized.count, 1)
        let logged = (authorized.first?.arguments.compact ?? "") + (authorized.first?.summary ?? "") + summaries.map(\.compact).joined()
        XCTAssertFalse(logged.contains("deadbeef"), logged)
        XCTAssertTrue(logged.contains("keep=this"), logged)
        // The request itself still carries the signature it needs.
        let calls = await rig.domain.fetchCalls
        XCTAssertEqual(calls.first?["urls"], .array([.string(signed)]))
    }

    func testL519CallerThatMayReadButNotActIsRefused() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await fetch(rig, run: "p", tiers: [.read])
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-granted")
        let calls = await rig.domain.fetchCalls, authorized = await rig.runtime.authorized
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(authorized.isEmpty)
    }

    // MARK: assets.blocks

    func testL529ListsWhatTheBrowserPhotographedByItself() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let evidence = A.o([("requestedUrl", .string("https://portal.test/listings")), ("finalUrl", .string("https://portal.test/listings")),
                            ("httpStatus", .number(429)), ("statusText", .string("Too Many Requests")), ("title", .string("Slow down")),
                            ("text", .string("rate limit exceeded")), ("failed", .null)])
        let verdict = try XCTUnwrap(BackendBrowserScrapingStore.blockVerdict(evidence))
        let folder = rig.userData + "/scrape/blocks"
        await rig.domain.script(blocks: [A.o([("at", .number(5)), ("evidence", evidence), ("verdict", verdict),
                                              ("path", .string(folder + "/5.png")), ("sidecar", .string(folder + "/5.json")), ("note", .string(""))])])
        let answer = await rig.call("assets.blocks", .object([]))
        XCTAssertFalse(answer.isError, A.error(answer))
        let value = A.value(answer)
        XCTAssertEqual(value["total"], .number(1))
        let shot = value["shots"].elements?.first ?? .missing
        XCTAssertEqual(shot["httpStatus"], .number(429))
        XCTAssertGreaterThan(shot["signals"].elements?.count ?? 0, 0)
        XCTAssertEqual(shot["url"], .string("https://portal.test/listings"))
        XCTAssertEqual(shot["screenshot"], .string(folder + "/5.png"))
    }

    func testL554EmptyListIsAnAnswerWhenNothingHasBeenBlocked() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.blocks", .object([]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["total"], .number(0))
        XCTAssertEqual(A.value(answer)["folder"], .string(rig.userData + "/scrape/blocks"))
        XCTAssertEqual(A.value(answer)["empty"], .bool(true))
    }

    // MARK: what the profile stored

    func testL590StoredUpgradeRewritesOnlyACallThatNamedNoRules() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let small = "https://x.test/i/small/a.jpg", big = "https://x.test/i/big/a.jpg"
        await rig.domain.store("default", A.o([("assets", A.o([("upgrade", A.o([("on", .bool(true)), ("from", .string("/small/")), ("to", .string("/big/"))]))]))]))
        await rig.domain.script(rendition: A.rendition(url: big, original: small, ruleId: "upgrade", upgraded: true, fellBack: false))
        await rig.domain.script(rendition: A.rendition(url: small, original: small, ruleId: "", upgraded: false, fellBack: false))
        let answer = await rig.call("assets.rendition", A.o([("url", .string(small)), ("profileId", .string("default"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["url"], .string(big)); XCTAssertEqual(A.value(answer)["upgraded"], .bool(true))
        var calls = await rig.domain.renditionCalls
        let stored = A.o([("id", .string("upgrade")), ("match", .string("/small/")), ("replace", .string("/big/")), ("flags", .string("g"))])
        XCTAssertEqual(calls.first?["rules"], .array([stored]))
        // The rule the profile's pair became really rewrites the URL to the big copy.
        XCTAssertEqual(try BackendBrowserScrapingRegex.replace(small, pattern: "/small/", replacement: "/big/", flags: "g"), big)

        let named = await rig.call("assets.rendition", A.o([("url", .string(small)), ("profileId", .string("default")), ("rules", .array([]))]))
        XCTAssertEqual(A.value(named)["url"], .string(small)); XCTAssertEqual(A.value(named)["upgraded"], .bool(false))
        calls = await rig.domain.renditionCalls
        XCTAssertEqual(calls.last?["rules"], .array([]))
    }

    func testL614StoredLedgerModeFillsASilenceAndNeverOverridesANamedMode() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.store("default", A.o([("assets", A.o([("ledger", A.o([("on", .bool(true)), ("refetch", .bool(true))]))]))]))
        await rig.domain.script(batch: fetched(rig)); await rig.domain.script(batch: fetched(rig))
        let silent = await fetch(rig, run: "stored-mode", [("profileId", .string("default"))])
        XCTAssertFalse(silent.isError, A.error(silent))
        XCTAssertEqual(A.value(silent)["mode"], .string("refetch"))
        let named = await fetch(rig, run: "named-mode", [("profileId", .string("default")), ("mode", .string("resume"))])
        XCTAssertEqual(A.value(named)["mode"], .string("resume"))
        let requests = await rig.domain.ledgerRequests, calls = await rig.domain.fetchCalls
        XCTAssertEqual(requests, ["stored-mode|refetch", "named-mode|resume"])
        XCTAssertEqual(calls.map { $0["mode"] }, [.string("refetch"), .string("resume")])
    }

    func testL636StoredModeReachesTheLedgerThroughTheRunsOwnerAlone() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.store("default", A.o([("assets", A.o([("ledger", A.o([("on", .bool(true)), ("refetch", .bool(true))]))]))]))
        await rig.domain.script(batch: fetched(rig))
        _ = await fetch(rig, run: "owned", [("profileId", .string("default"))])
        await rig.domain.ledgerNamed(run: "owned", mode: "refetch").script(decision: A.o([("action", .string("fetch")),
            ("reason", .string("refetch-requested")), ("ledgerWasWrong", .bool(false))]))
        let answer = await rig.call("assets.ledger", A.o([("runId", .string("owned")), ("op", .string("decide")), ("url", .string(Self.plan))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["mode"], .string("refetch"))
        XCTAssertEqual(A.value(answer)["action"], .string("fetch"))
        let owners = await rig.domain.ownersAsked
        XCTAssertTrue(owners.contains("owned"))
    }

    func testL657RunIsFiledUnderItsProfileForThePanel() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(batch: fetched(rig))
        let answer = await fetch(rig, run: "filed", [("profileId", .string("default"))])
        XCTAssertFalse(answer.isError, A.error(answer))
        let owner = await rig.domain.owner(of: "filed")
        XCTAssertEqual(owner, "default")
    }

    func testL668CoverageReadsTheTotalWithThePatternItsRunsProfileStored() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.store("default", A.o([("checks", A.o([("coverage", A.o([("on", .bool(true)), ("pattern", .string("of ([\\d,]+) plans"))]))]))]))
        await rig.domain.script(batch: fetched(rig))
        await rig.domain.script(verdict: A.o([("verdict", .string("short")), ("missing", .number(16_198))]))
        _ = await fetch(rig, run: "checked", [("profileId", .string("default"))])
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("checked")), ("captured", .number(300)),
                                                            ("text", .string("Showing 1–24 of 16,498 plans"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["stated"], .number(16_498))
        XCTAssertEqual(A.value(answer)["verdict"], .string("short"))
        XCTAssertEqual(A.value(answer)["statedFrom"], .string("text"))
        let stated = await rig.domain.statedCalls
        XCTAssertEqual(stated.last?.pattern, "of ([\\d,]+) plans")
    }

    func testL690CoveragePatternIsLeftAloneWhileTheSwitchIsOff() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let text = "This development lists 16,498 plans.", pattern = "lists ([\\d,]+) plans"
        await rig.domain.store("default", A.o([("checks", A.o([("coverage", A.o([("on", .bool(false)), ("pattern", .string(pattern))]))]))]))
        await rig.domain.script(batch: fetched(rig))
        await rig.domain.script(verdict: A.o([("verdict", .string("unknown")), ("loud", .bool(true)), ("missing", .null)]))
        _ = await fetch(rig, run: "unchecked", [("profileId", .string("default"))])
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("unchecked")), ("captured", .number(300)), ("text", .string(text))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["stated"], .null)
        let stated = await rig.domain.statedCalls
        XCTAssertEqual(stated.count, 1); XCTAssertNil(stated.last?.pattern)
        // Only the stored pattern could have read this line; it was not used.
        XCTAssertEqual(try BackendBrowserScrapingRegex.firstCapture(text, pattern: pattern, flags: ""), "16,498")
    }
}
