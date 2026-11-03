import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendStaysFixedParityReadTests: XCTestCase {
    func testColdStartAndExactRegressionGoldenFields() {
        let cold = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_cold)
        XCTAssertEqual(cold["verdict"].string, "not-compared")
        XCTAssertTrue(cold["headline"].string?.contains("Nothing to compare against yet") == true)
        XCTAssertEqual(cold["differences"], .array([])); XCTAssertEqual(cold["unchanged"].string, ""); XCTAssertEqual(cold["against"], .null)
        let result = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_regression)
        XCTAssertEqual(result["verdict"].string, "differences"); XCTAssertEqual(result["headline"].string, "1 difference nobody asked for.")
        XCTAssertEqual(result["against"].string, "1.0.0"); XCTAssertEqual(result["differences"].elements?.count, 1)
        let difference = result["differences"].elements![0], change = difference["changes"].elements![0]
        XCTAssertEqual(difference["changes"].elements?.count, 1); XCTAssertTrue(change["what"].string?.contains("printed to the screen") == true)
        XCTAssertEqual(change["before"].string, "Hello, --help!\nTotal: 10.00\n"); XCTAssertEqual(change["after"].string, "Hello, --help!\nTotal: 10.0\n")
        XCTAssertEqual(change["kind"].string, "changed"); XCTAssertEqual(difference["needsPerson"].bool, true)
        XCTAssertTrue(difference["needsPersonWhy"].string?.contains("money") == true); XCTAssertFalse(difference["title"].string?.contains("\\n") == true)
    }
    func testUnchangedCountsCleanHeadlineAndPlainNotCheckedLine() {
        let regression = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_regression)
        XCTAssertEqual(regression["unchanged"].string, "Everything else it looked at — 11 things — is unchanged.")
        XCTAssertEqual(BackendStaysFixedRead.results(BackendStaysFixedFixtures.web_check_regression)["unchanged"].string, "Everything else it looked at — 47 things — is unchanged.")
        let clean = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_clean)
        XCTAssertEqual(clean["verdict"].string, "clean"); XCTAssertEqual(clean["headline"].string, "Nothing that worked has changed.")
        XCTAssertNotNil(clean["unchanged"].string?.range(of: #"^All \d+ things it looked at are unchanged\.$"#, options: .regularExpression))
        XCTAssertTrue(regression["notChecked"].string?.hasPrefix("Not everything was checked:") == true)
        XCTAssertFalse(regression["notChecked"].string?.contains("NOT EVERYTHING") == true)
        XCTAssertEqual(BackendStaysFixedRead.notChecked(.object([.init("gaps", .array([]))]), doors: 0), .null)
    }
    func testRefusalHintAndBlockedSingleGapStayErrorsNotPasses() {
        let refused = BackendStaysFixedRead.results(.object([.init("error", .object([
            .init("message", .string("This folder is not a git repository.")), .init("hint", .string("Run git init."))]))]))
        XCTAssertEqual(refused["verdict"].string, "could-not-run")
        XCTAssertEqual(refused["headline"].string, "This folder is not a git repository. Run git init.")
        let blocked = BackendStaysFixedRead.results(.object([.init("blocked", .bool(true)), .init("reference", .object([.init("id", .string(""))])),
            .init("candidate", .object([.init("id", .string(""))])), .init("findings", .array([])),
            .init("coverage", .object([.init("paths", .number(0)), .init("gaps", .array([.object([
                .init("what", .string("Everything.")), .init("why", .string("No settings file here."))])]))])),
            .init("summary", .string("The check could not be run, so this is not a pass and not a failure. No settings file here."))]))
        XCTAssertEqual(blocked["verdict"].string, "could-not-run"); XCTAssertEqual(blocked["headline"].string, "No settings file here.")
    }
    func testEveryChangeFullReportAndValueBoundsExact() {
        let regression = BackendStaysFixedFixtures.cli_check_regression
        let differences = (0..<10).map { i in NativeRPCValue.object([.init("path", .string("p\(i)")), .init("kind", .string("changed")), .init("reference", .string("a")), .init("candidate", .string("b"))]) }
        let finding = regression["findings"].elements![0].setting("count", .number(10)).setting("differences", .array(differences))
        let many = regression.setting("findings", .array([finding]))
        let short = BackendStaysFixedRead.results(many)["differences"].elements![0]
        XCTAssertEqual(short["changes"].elements?.count, 6); XCTAssertEqual(short["more"].number, 4)
        let full = BackendStaysFixedRead.results(many, full: true)["differences"].elements![0]
        XCTAssertEqual(full["changes"].elements?.count, 10); XCTAssertEqual(full["more"].number, 0)
        let text = String(repeating: "x", count: 425)
        XCTAssertTrue(BackendStaysFixedRead.valueText(.string(text)).string?.hasSuffix("(25 more characters)") == true)
        XCTAssertEqual(BackendStaysFixedRead.valueText(.string(text), full: true).string?.count, 425)
        XCTAssertEqual(BackendStaysFixedRead.valueText(.missing), .null)
        XCTAssertEqual(BackendStaysFixedRead.valueText(.object([.init("a", .number(1))])).string, #"{"a":1}"#)
        XCTAssertEqual(BackendStaysFixedRead.plainTitle("is now \"a\\nb\" where it was \\\"c\\\""), "is now \"a b\" where it was \"c\"")
    }
    func testStringRecordEnvelopeAndMalformedRecord() {
        let envelope = NativeRPCValue.object([.init("at", .string("2026-10-03T23:42:05.690Z")),
            .init("result", .string(BackendStaysFixedFixtures.cli_check_clean.compact))])
        XCTAssertEqual(BackendStaysFixedRead.lastRun(envelope.compact)?.0["verdict"].string, "clean")
        XCTAssertNil(BackendStaysFixedRead.lastRun("not json")); XCTAssertNil(BackendStaysFixedRead.lastRun(#"{"result":"{}"}"#))
    }
    func testOriginalJourneyPictureNamesAndNoScreen() {
        let files = ["git-76e2ab57c913-single-the-front-page-the-front-page-end.png",
            "work-0f72dd0e31b2-a-the-front-page-the-front-page-end.png",
            "work-0f72dd0e31b2-b-the-front-page-the-front-page-end.png",
            "work-0f72dd0e31b2-a--about.html--about.html-end.png"]
        let difference = BackendStaysFixedRead.results(BackendStaysFixedFixtures.web_check_regression)["differences"].elements![0]
        let found = BackendStaysFixedRead.pictures(difference, files: files, candidate: "work-0f72dd0e31b2", reference: "git-76e2ab57c913")
        let front = found.first { $0.0 == "the front page" }, about = found.first { $0.0 == "/about.html" }
        XCTAssertEqual(front?.1, "git-76e2ab57c913-single-the-front-page-the-front-page-end.png")
        XCTAssertEqual(front?.2, "work-0f72dd0e31b2-a-the-front-page-the-front-page-end.png")
        XCTAssertNil(about?.1); XCTAssertEqual(about?.2, "work-0f72dd0e31b2-a--about.html--about.html-end.png")
        XCTAssertEqual(BackendStaysFixedRead.fileSafe("the front page"), "the-front-page")
        XCTAssertEqual(BackendStaysFixedRead.fileSafe("/about.html"), "-about.html")
        let cli = BackendStaysFixedRead.results(BackendStaysFixedFixtures.cli_check_regression)["differences"].elements![0]
        XCTAssertTrue(BackendStaysFixedRead.pictures(cli, files: files, candidate: "work-b63f5e292f71", reference: "git-a54e4cd3e911").isEmpty)
    }
    func testDoctorReadyExactGapNamesFixAndMissingGitFirst() {
        let raw = BackendStaysFixedFixtures.doctor, readiness = BackendStaysFixedRead.readiness(raw, plan: false)
        XCTAssertTrue(readiness["ready"].elements?.contains(.string("web apps and sites")) == true)
        let gaps = readiness["gaps"].elements ?? []
        XCTAssertEqual(gaps.compactMap { $0["name"].string }, ["command-line tools and libraries", "servers and APIs"])
        let server = gaps.first { $0["name"].string == "servers and APIs" }
        XCTAssertEqual(server?["byPerson"].bool, true); XCTAssertTrue(server?["fix"].string?.contains("Docker") == true)
        XCTAssertEqual(gaps.first { $0["name"].string == "command-line tools and libraries" }?["byPerson"].bool, false)
        XCTAssertTrue(readiness["notHere"].elements?.contains(.string("Electron desktop apps")) == true)
        XCTAssertEqual(readiness["git"].bool, true); XCTAssertFalse(readiness["summary"].string?.isEmpty == true)
        let noGit = BackendStaysFixedRead.readiness(raw.setting("project", raw["project"].setting("isGitRepo", .bool(false))), plan: false)
        XCTAssertEqual(noGit["gaps"].elements?.first?["what"].string, "a git repository")
        XCTAssertEqual(noGit["gaps"].elements?.first?["fix"].string, "git init")
    }
    func testPlanHidesShipFixAndSetupWritesRelativeWithExactFailureShape() {
        let raw = BackendStaysFixedFixtures.`init`, readiness = BackendStaysFixedRead.readiness(raw, plan: true)
        XCTAssertEqual(readiness["ready"], .array([.string("the \u{0060}greet\u{0060} command")]))
        XCTAssertFalse((readiness["gaps"].elements ?? []).contains { $0["fix"].string?.contains("staysfixed ship") == true })
        let setup = BackendStaysFixedRead.setup(raw, roots: ["/Users/you/Projects/tiny-greeter"], failure: nil)
        XCTAssertEqual(setup["ok"].bool, true); XCTAssertEqual(setup["wrote"], .array([.string("staysfixed.config.js"), .string(".gitignore")]))
        XCTAssertEqual(setup["readiness"]["ready"], .array([.string("the \u{0060}greet\u{0060} command")]))
        XCTAssertEqual(BackendStaysFixedRead.setup(.object([]), roots: ["/x"], failure: "The engine stopped."),
            .object([.init("ok", .bool(false)), .init("wrote", .array([])), .init("problem", .string("The engine stopped.")), .init("readiness", .null)]))
    }
    func testMarkMovedDifferenceOnlyAnywayUncheckedAndFailure() {
        let cut = BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_cut, failure: nil)
        XCTAssertEqual(cut["marked"].bool, true); XCTAssertEqual(cut["refused"], .null); XCTAssertEqual(cut["refusedFor"], .null)
        XCTAssertEqual(BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_forced, failure: nil)["marked"].bool, true)
        let refused = BackendStaysFixedRead.mark(BackendStaysFixedFixtures.ship_refused, failure: nil)
        XCTAssertEqual(refused["marked"].bool, false); XCTAssertEqual(refused["refusedFor"].string, "differences")
        XCTAssertEqual(refused["summary"].string, "The last check found 1 difference nobody asked for. Marking this build as good makes it the new normal.")
        let unchecked = BackendStaysFixedRead.mark(.object([.init("ok", .bool(true)), .init("cut", .bool(false)),
            .init("decision", .object([.init("state", .string("never-checked"))])), .init("refused", .string("Refusing…"))]), failure: nil)
        XCTAssertEqual(unchecked["refusedFor"].string, "unchecked"); XCTAssertTrue(unchecked["summary"].string?.contains("Run a check first") == true)
        let failed = BackendStaysFixedRead.mark(.object([]), failure: "It took too long.")
        XCTAssertEqual(failed["ok"].bool, false); XCTAssertEqual(failed["summary"].string, "It took too long.")
    }
    func testDescribeGuardLoaderMetadataWithoutExecutingGuard() {
        let raw = NativeRPCValue.object([.init("product", .string("tiny-greeter")),
            .init("guards", .array([.object([.init("name", .string("the total keeps its pennies")),
                .init("because", .string("It printed 10.0 once.")), .init("file", .string("/p/.staysfixed/guards/a.js"))]),
                .object([.init("name", .string(""))])])),
            .init("reference", .object([.init("buildId", .string("git-a54e4cd3e911")), .init("setAt", .string("2026-10-03T23:41:27Z")),
                .init("setBy", .string("staysfixed ship")), .init("version", .string("1.0.0")), .init("forced", .bool(false))]))])
        let description = BackendStaysFixedRead.description(raw)
        XCTAssertEqual(description["guards"].elements?.count, 1)
        XCTAssertEqual(description["guards"].elements?.first?["name"].string, "the total keeps its pennies")
        XCTAssertEqual(description["guards"].elements?.first?["because"].string, "It printed 10.0 once.")
        XCTAssertEqual(description["guards"].elements?.first?["file"].string, "/p/.staysfixed/guards/a.js")
        XCTAssertEqual(description["reference"]["name"].string, "1.0.0")
        XCTAssertEqual(BackendStaysFixedRead.description(.object([]))["reference"], .null)
    }
}
