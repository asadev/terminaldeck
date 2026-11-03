import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// tour.test.ts, every Mac-applicable case. Evidence gathering is faked;
/// production parse/validate/importance/quote/record functions make the verdicts.
final class BackendDeckToolsRootPortTourTests: XCTestCase {
    private typealias S = BackendDeckToolsRootPortTourSupport
    private func check(_ stops: [NativeRPCValue], evidence: S.Evidence = .init()) async throws -> BackendDeckToolsTour.Validated { try await S.checked(stops, evidence: evidence) }
    func testThirteenthStopRefusesWithLimitAndReason() {
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan(Array(repeating: S.stop(), count: 13)))) {
            let text = $0.localizedDescription; XCTAssertTrue(text.contains("12")); XCTAssertTrue(text.contains("13")); XCTAssertTrue(text.contains("refused rather than trimmed"))
        }
    }
    func testExactlyTwelveStopsAreAccepted() throws { XCTAssertEqual(try BackendDeckToolsTour.parse(S.plan(Array(repeating: S.stop(), count: 12)))["stops"].elements?.count, 12) }
    func testQuoteBudgetIsSixHundredCharacters() { XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([S.stop(quote: String(repeating: "x", count: 601))]))) { XCTAssertTrue($0.localizedDescription.contains("600")) } }
    func testNoteBudgetIsOneHundredSixtyCharacters() { XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([S.stop(note: String(repeating: "x", count: 161))]))) { XCTAssertTrue($0.localizedDescription.contains("160")) } }
    func testEmptyTourIsRefused() { XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([]))) { XCTAssertTrue($0.localizedDescription.contains("stops must be a non-empty array")) } }
    func testUnknownReasonNamesCheckedReasons() { XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([S.stop(why: "looks-bad")]))) { XCTAssertTrue($0.localizedDescription.contains("blocked-on-you")) } }
    func testAnchorMustBeBringableOntoScreen() {
        let stop = S.o([("kind", .string("anchor")), ("at", .string("session-row")), ("sessionId", .string("s1")), ("note", .string("n")), ("why", .string("files-changed"))])
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([stop]))) { XCTAssertTrue($0.localizedDescription.contains("git-file")) }
    }
    func testQuoteNeverOnTerminalIsDropped() async throws {
        let value = try await check([S.stop()], evidence: .init(screen: "everything is fine"))
        XCTAssertEqual(value.plan["stops"].elements?.count, 0); XCTAssertEqual(value.dropped.first?["why"], .string("quote-not-found"))
    }
    func testRealTerminalQuoteSurvives() async throws {
        let value = try await check([S.stop()], evidence: .init(screen: "running\nthe build failed\n"))
        XCTAssertEqual(value.plan["stops"].elements?.count, 1); XCTAssertTrue(value.dropped.isEmpty)
    }
    func testColoredTerminalQuoteSurvives() async throws {
        let value = try await check([S.stop()], evidence: .init(screen: "\u{1b}[31mthe build failed\u{1b}[m\n"))
        XCTAssertEqual(value.plan["stops"].elements?.count, 1)
    }
    func testContradictedReasonDropsWithActualAttention() async throws {
        let value = try await check([S.stop(why: "blocked-on-you")])
        XCTAssertEqual(value.dropped.first?["why"], .string("reason-unsupported")); XCTAssertTrue(value.dropped.first?["detail"].string?.contains("quiet") == true)
    }
    func testSupportedFilesChangedReasonSurvives() async throws { let value = try await check([S.stop()]); XCTAssertEqual(value.plan["stops"].elements?.count, 1) }
    func testNoGitChangesDropsFilesChanged() async throws {
        let value = try await check([S.stop()], evidence: .init(changed: [])); XCTAssertEqual(value.dropped.first?["why"], .string("reason-unsupported"))
    }
    func testGoneSessionIsDistinctDrop() async throws {
        let value = try await check([S.stop(session: "ghost")]); XCTAssertEqual(value.dropped.first?["why"], .string("session-gone"))
    }
    func testGitAnchorMustNameActualChangedPath() async throws {
        let stop = S.o([("kind", .string("anchor")), ("at", .string("git-file")), ("path", .string("never-touched.ts")), ("sessionId", .string("s1")), ("note", .string("n")), ("why", .string("files-changed"))])
        let value = try await check([stop]); XCTAssertEqual(value.dropped.first?["why"], .string("quote-not-found"))
    }
    func testMessageStopRefusedBecauseChatModeRemoved() {
        let stop = S.stop().setting("kind", .string("message")).setting("messageId", .string("agent:m1"))
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(S.plan([stop]))) { XCTAssertTrue($0.localizedDescription.lowercased().contains("chat mode has been removed")) }
    }
    func testOneDecisionPerSessionAllowed() async throws {
        let value = try await check([S.stop(why: "decision")], evidence: .init(changed: [])); XCTAssertEqual(value.plan["stops"].elements?.count, 1)
    }
    func testSecondDecisionIsDroppedAsBudget() async throws {
        let value = try await check([S.stop(note: "a", why: "decision"), S.stop(note: "b", why: "decision")], evidence: .init(changed: []))
        XCTAssertEqual(value.plan["stops"].elements?.count, 1); XCTAssertEqual(value.dropped.first?["why"], .string("over-budget"))
    }
    func testDecisionStillNeedsVerbatimQuote() async throws {
        let value = try await check([S.stop(quote: "nobody printed this", why: "decision")], evidence: .init(changed: [])); XCTAssertEqual(value.plan["stops"].elements?.count, 0)
    }
    func testRecordHasCheckedQuoteDropsAndReplayTargetBeforeShowing() async throws {
        let value = try await check([S.stop(), S.stop(quote: "never printed")]); let record = BackendDeckToolsTour.openRecord(value, at: 5000)
        XCTAssertEqual(record["startedAt"], .number(5000)); XCTAssertEqual(record["endedAt"], .null)
        let row = record["stops"].elements!.first!
        XCTAssertEqual(row["shownAt"], .null); XCTAssertEqual(row["quote"], .string("the build failed")); XCTAssertEqual(row["kind"], .string("screen")); XCTAssertEqual(row["cwd"], .string("/work/api")); XCTAssertEqual(row["sessionTitle"], .string("api")); XCTAssertEqual(record["dropped"].elements?.count, 1)
    }
    func testFreshTourIDForEachPlan() throws {
        let first = try BackendDeckToolsTour.parse(S.plan([S.stop()])), second = try BackendDeckToolsTour.parse(S.plan([S.stop()]))
        XCTAssertNotEqual(first["id"], second["id"]); XCTAssertNotNil(first["id"].string?.range(of: #"^tour_[0-9]+_[0-9a-f]{8}$"#, options: .regularExpression))
    }
    func testQuestionAndHeadlineKeptVerbatim() throws {
        let raw = S.plan([S.stop()]).setting("question", .string("what happened while I was away?")).setting("headline", .string("One thing needs you."))
        let value = try BackendDeckToolsTour.parse(raw); XCTAssertEqual(value["question"], raw["question"]); XCTAssertEqual(value["headline"], raw["headline"])
    }
}
