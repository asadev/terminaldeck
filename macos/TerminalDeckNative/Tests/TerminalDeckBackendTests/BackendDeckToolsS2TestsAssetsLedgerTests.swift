import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// asset-tools.test.ts: the grant, assets.rendition, assets.ledger and
/// assets.coverage. Map: macos/night/S2-Assets.md. Fixtures:
/// BackendDeckToolsS2TestsAssetsFixtures.swift.
final class BackendDeckToolsS2TestsAssetsLedgerTests: XCTestCase {
    private typealias A = S2Assets

    // MARK: the grant

    func testL144EveryAssetToolIsOnTheOrdinarySessionGrant() throws {
        let catalogued = try BackendDeckToolsCatalogue.entries().filter { $0.module == "asset-tools" }.map { $0.spec.id }
        XCTAssertEqual(Set(catalogued), ["assets.rendition", "assets.ledger", "assets.fetch", "assets.coverage", "assets.blocks"])
        for name in BackendDeckToolsAssets.toolNames {
            XCTAssertTrue(BackendOrdinarySessionToolGrant.names.contains(name), "\(name) is not on the session grant")
        }
        for id in catalogued { XCTAssertTrue(BackendDeckToolsAssets.toolNames.contains(id), id) }
    }

    func testL153PairedDeviceIsRefusedAtEveryOneOfTheFive() async throws {
        let rig = try S2AssetsRig.make(kind: "remote"); defer { rig.dispose() }
        let calls: [(String, NativeRPCValue)] = [
            ("assets.rendition", A.o([("url", .string("https://x.test/a.jpg"))])),
            ("assets.ledger", A.o([("runId", .string("r")), ("op", .string("summary"))])),
            ("assets.fetch", A.o([("runId", .string("r")), ("dir", .string("/tmp/x")), ("urls", .array([.string("https://x.test/a.jpg")]))])),
            ("assets.coverage", A.o([("runId", .string("r")), ("op", .string("summary"))])),
            ("assets.blocks", .object([])),
        ]
        for (tool, args) in calls {
            let answer = await rig.call(tool, args)
            XCTAssertTrue(answer.isError, tool)
            XCTAssertEqual(A.refusal(answer), "not-granted", tool)
            XCTAssertTrue(A.error(answer).contains("paired device"), "\(tool): \(A.error(answer))")
        }
        let touched = await rig.domain.touched, authorized = await rig.runtime.authorized
        XCTAssertEqual(touched, 0); XCTAssertTrue(authorized.isEmpty)
    }

    func testL175CallerWithNoTiersIsRefusedRatherThanRun() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.blocks", .object([]), tiers: [])
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-granted")
        let asked = await rig.domain.blocksAsked, authorized = await rig.runtime.authorized
        XCTAssertEqual(asked, 0); XCTAssertTrue(authorized.isEmpty)
    }

    // MARK: assets.rendition

    func testL183BiggerCopyIsAnsweredWithTheRuleThatFoundIt() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(rendition: A.rendition(url: "https://x.test/i/1920/a.jpg", original: "https://x.test/i/498/a.jpg",
                                                       ruleId: "size", upgraded: true, fellBack: false))
        let answer = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/i/498/a.jpg")),
                                                             ("rules", .array([A.rule("size", "/498/", "/1920/")]))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        let value = A.value(answer)
        XCTAssertEqual(value["url"], .string("https://x.test/i/1920/a.jpg"))
        XCTAssertEqual(value["upgraded"], .bool(true))
        XCTAssertEqual(value["ruleId"], .string("size"))
        XCTAssertEqual(value["empty"], .bool(false))
        // The caller's rule reaches the probe exactly as written; attempts are whitelisted.
        let calls = await rig.domain.renditionCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["url"], .string("https://x.test/i/498/a.jpg"))
        XCTAssertEqual(calls.first?["rules"], .array([A.rule("size", "/498/", "/1920/")]))
        XCTAssertFalse(value.compact.contains("domain-only"))
    }

    func testL198FallsBackToTheOriginalRatherThanAnsweringWithNothing() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let original = "https://x.test/i/498/a.jpg", args = A.o([("url", .string(original)), ("rules", .array([A.rule("size", "/498/", "/1920/")]))])
        await rig.domain.script(rendition: A.rendition(url: original, original: original, ruleId: "", upgraded: false, fellBack: true))
        let answer = await rig.call("assets.rendition", args)
        XCTAssertEqual(A.value(answer)["url"], .string(original))
        XCTAssertEqual(A.value(answer)["fellBack"], .bool(true))
        // Even when no candidate answered, the URL is still the answer, and the
        // empty flag says so rather than the URL going missing.
        await rig.domain.script(rendition: A.rendition(url: original, original: original, ruleId: "", upgraded: false, fellBack: true, reachable: false))
        let silentReply = await rig.call("assets.rendition", args), silent = A.value(silentReply)
        XCTAssertEqual(silent["url"], .string(original))
        XCTAssertEqual(silent["empty"], .bool(true))
        XCTAssertTrue(silent["emptyReason"].string?.contains("It is still returned") == true)
    }

    func testL207RuleThatDoesNotCompileIsRefusedBeforeAnyRequest() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/a.jpg")),
                                                             ("rules", .array([A.rule("bad", "([", "x")]))]))
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted")
        XCTAssertTrue(A.error(answer).hasPrefix("rule bad is not a valid expression"), A.error(answer))
        let calls = await rig.domain.renditionCalls, authorized = await rig.runtime.authorized
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(authorized.isEmpty)
    }

    func testL216RenditionRefusesAnythingThatIsNotAnHTTPAddress() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.rendition", A.o([("url", .string("file:///etc/passwd"))]))
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted")
        let touched = await rig.domain.touched
        XCTAssertEqual(touched, 0)
    }

    // MARK: assets.ledger

    private func record(_ rig: S2AssetsRig, _ path: String, run: String = "run-1") async -> BackendMCPToolReply {
        await rig.call("assets.ledger", A.o([("runId", .string(run)), ("op", .string("record")),
                                             ("url", .string("https://x.test/a.jpg")), ("path", .string(path))]))
    }

    func testL229RecordReadsTheFileItselfAndDecideAnswersFromThatLedger() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.asset("a.jpg", "real bytes")
        let recorded = await record(rig, file.path)
        XCTAssertFalse(recorded.isError, A.error(recorded))
        XCTAssertEqual(A.value(recorded)["entry"]["digest"], .string(file.digest))
        XCTAssertEqual(A.value(recorded)["entry"]["bytes"], .number(10))
        let ledger = await rig.domain.ledgerNamed(run: "run-1", mode: "resume")
        let written = await ledger.recorded
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?["path"], .string(file.path))
        XCTAssertEqual(written.first?["fetchedUrl"], .string("https://x.test/a.jpg"))

        await ledger.script(decision: A.o([("action", .string("skip")), ("reason", .string("verified")), ("ledgerWasWrong", .bool(false))]))
        let decided = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("decide")), ("url", .string("https://x.test/a.jpg"))]))
        XCTAssertEqual(A.value(decided)["action"], .string("skip"))
        XCTAssertEqual(A.value(decided)["reason"], .string("verified"))
        XCTAssertEqual(A.value(decided)["mode"], .string("resume"))
        let asked = await ledger.decided, expected = await ledger.expected, requests = await rig.domain.ledgerRequests
        XCTAssertEqual(asked, ["https://x.test/a.jpg"]); XCTAssertEqual(expected, [nil])
        XCTAssertEqual(requests, ["run-1|resume", "run-1|resume"])
    }

    func testL249DigestIsNeverTakenFromTheCaller() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.asset("a.jpg", "real bytes")
        let answer = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("record")), ("url", .string("https://x.test/a.jpg")),
                                                          ("path", .string(file.path)), ("digest", .string("sha256:whatever-i-say"))]))
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted")
        XCTAssertTrue(A.error(answer).hasPrefix("digest is not an argument this tool takes"), A.error(answer))
        let touched = await rig.domain.touched
        XCTAssertEqual(touched, 0)
    }

    func testL267RecordRefusesAFileThatIsNotThere() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await record(rig, rig.files + "/never-written.jpg")
        XCTAssertTrue(answer.isError)
        XCTAssertEqual(A.refusal(answer), "not-permitted")
        XCTAssertTrue(A.error(answer).contains("there is no file at"), A.error(answer))
        let written = await rig.domain.ledgerNamed(run: "run-1", mode: "resume").recorded
        XCTAssertTrue(written.isEmpty)
    }

    func testL278RecordRefusesARelativePath() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await record(rig, "a.jpg")
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(A.error(answer).contains("must be absolute"), A.error(answer))
        let printed = await rig.domain.fingerprinted, authorized = await rig.runtime.authorized
        XCTAssertTrue(printed.isEmpty); XCTAssertTrue(authorized.isEmpty)
    }

    func testL289LedgerThatWasWrongIsReportedWithItsFetchDecision() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.asset("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        try Data("FAKE BYTES".utf8).write(to: URL(fileURLWithPath: file.path))
        let ledger = await rig.domain.ledgerNamed(run: "run-1", mode: "resume")
        await ledger.script(decision: A.o([("action", .string("fetch")), ("reason", .string("wrong-digest")), ("ledgerWasWrong", .bool(true))]))
        let decided = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("decide")), ("url", .string("https://x.test/a.jpg"))]))
        let value = A.value(decided)
        XCTAssertEqual(value["action"], .string("fetch"))
        XCTAssertEqual(value["reason"], .string("wrong-digest"))
        XCTAssertEqual(value["ledgerWasWrong"], .bool(true))
        let summaries = await rig.runtime.completedSummaries
        XCTAssertEqual(summaries.last?["ledgerWasWrong"], .bool(true))
    }

    func testL308RefetchModeNeverConsultsTheResumeLedger() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.asset("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        let refetch = await rig.domain.ledgerNamed(run: "run-1", mode: "refetch")
        await refetch.script(decision: A.o([("action", .string("fetch")), ("reason", .string("refetch-requested")), ("ledgerWasWrong", .bool(false))]))
        let decided = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("decide")), ("mode", .string("refetch")),
                                                           ("url", .string("https://x.test/a.jpg"))]))
        XCTAssertEqual(A.value(decided)["action"], .string("fetch"))
        XCTAssertEqual(A.value(decided)["reason"], .string("refetch-requested"))
        XCTAssertEqual(A.value(decided)["mode"], .string("refetch"))
        let resumeAsked = await rig.domain.ledgerNamed(run: "run-1", mode: "resume").decided
        XCTAssertTrue(resumeAsked.isEmpty)
    }

    func testL326LedgerIsKeptWhereTheRunCanFindIt() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let args = A.o([("runId", .string("run-1")), ("op", .string("summary"))])
        _ = await rig.call("assets.ledger", args)
        let answer = await rig.call("assets.ledger", args)
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(A.value(answer)["ledger"], .string(rig.runFolder("run-1") + "/ledger.jsonl"))
        XCTAssertEqual(A.value(answer)["folder"], .string(rig.runFolder("run-1")))
        // A ledger nobody wrote to is not the picture of a run.
        XCTAssertEqual(A.value(answer)["empty"], .bool(true))
        XCTAssertTrue(A.value(answer)["emptyReason"].string?.contains("nothing has ever been recorded") == true)
    }

    func testL334VerifyReportsMissingFilesRatherThanACleanRun() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.asset("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        try FileManager.default.removeItem(atPath: file.path)
        await rig.domain.ledgerNamed(run: "run-1", mode: "resume").script(verify: A.o([
            ("total", .number(1)), ("ok", .number(0)), ("missing", .array([.string(file.path)])), ("corrupt", .array([])),
            ("line", .string("1 of 1 ledger entries are missing from disk, so this run is not complete."))]))
        let verdict = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("verify"))]))
        let value = A.value(verdict)
        XCTAssertEqual(value["total"], .number(1)); XCTAssertEqual(value["ok"], .number(0))
        XCTAssertTrue(value["line"].string?.contains("not complete") == true)
        XCTAssertEqual(value["empty"], .bool(false))
        XCTAssertEqual(value["ledger"], .string(rig.runFolder("run-1") + "/ledger.jsonl"))
        let summaries = await rig.runtime.completedSummaries
        XCTAssertEqual(summaries.last?["missing"], .number(1))
    }

    // MARK: assets.coverage

    func testL351PagesOwnTotalIsReadOutOfTheTextAndAShortRunIsShort() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(verdict: A.o([("verdict", .string("short")), ("missing", .number(316))]))
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)),
            ("text", .string("Showing 24 of 340 units")), ("pattern", .string("of\\s+([\\d,]+)\\s+units")), ("what", .string("units"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        let value = A.value(answer)
        XCTAssertEqual(value["verdict"], .string("short")); XCTAssertEqual(value["stated"], .number(340))
        XCTAssertEqual(value["captured"], .number(24)); XCTAssertEqual(value["missing"], .number(316))
        XCTAssertEqual(value["statedFrom"], .string("text"))
        let stated = await rig.domain.statedCalls, comparisons = await rig.domain.comparisons
        XCTAssertEqual(stated.first?.pattern, "of\\s+([\\d,]+)\\s+units")
        XCTAssertEqual(comparisons.first?["stated"], .number(340)); XCTAssertEqual(comparisons.first?["captured"], .number(24))
        XCTAssertEqual(comparisons.first?["what"], .string("units")); XCTAssertEqual(comparisons.first?["now"], .number(S2Assets.clock))
    }

    func testL362NoStatedTotalIsUnknownNotComplete() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(verdict: A.o([("verdict", .string("unknown")), ("loud", .bool(true)), ("missing", .null)]))
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)),
                                                            ("text", .string("A page with no counts on it at all."))]))
        let value = A.value(answer)
        XCTAssertEqual(value["verdict"], .string("unknown")); XCTAssertEqual(value["loud"], .bool(true))
        XCTAssertEqual(value["statedFrom"], .string("nothing"))
        XCTAssertEqual(value["empty"], .bool(true))
        XCTAssertTrue(value["emptyReason"].string?.contains("cannot be called complete") == true)
        let comparisons = await rig.domain.comparisons
        XCTAssertEqual(comparisons.first?["stated"], .null)
    }

    func testL371CheckWithNothingToCompareAgainstIsRefused() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24))]))
        XCTAssertTrue(answer.isError)
        XCTAssertTrue(A.error(answer).contains("nothing to compare against"), A.error(answer))
        let comparisons = await rig.domain.comparisons
        XCTAssertTrue(comparisons.isEmpty)
    }

    func testL377EveryCheckIsWrittenIntoTheRunAndSummarisedAtTheEnd() async throws {
        let rig = try S2AssetsRig.make(); defer { rig.dispose() }
        await rig.domain.script(verdict: A.o([("verdict", .string("short")), ("missing", .number(316))]))
        await rig.domain.script(verdict: A.o([("verdict", .string("complete")), ("missing", .number(0))]))
        _ = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)), ("stated", .number(340))]))
        _ = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(10)), ("stated", .number(10))]))
        let summary = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("op", .string("summary"))]))
        let value = A.value(summary)
        XCTAssertEqual(value["ok"], .bool(false))
        XCTAssertEqual(value["short"], .number(1)); XCTAssertEqual(value["complete"], .number(1))
        XCTAssertEqual(value["log"], .string(rig.runFolder("run-1") + "/coverage.jsonl"))
        XCTAssertEqual(value["checks"].elements?.count, 2)
        XCTAssertTrue(value["line"].string?.contains("1 of 2 coverage checks matched") == true)
        let runs = await rig.domain.recordedRuns
        XCTAssertEqual(runs, ["run-1", "run-1"])
    }
}
