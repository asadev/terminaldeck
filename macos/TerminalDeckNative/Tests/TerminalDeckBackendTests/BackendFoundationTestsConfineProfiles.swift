import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendFoundationTestsConfineProfiles: XCTestCase {
    private func plan(projects: [String] = []) -> BackendMacConfinement.Plan {
        .init(folder: "/Users/asad/Projects/app", home: "/app-storage/device-home/abc",
              writable: ["/Users/asad/Projects/app", "/app-storage/device-home/abc"],
              readable: ["/usr", "/System"] + projects,
              readableFiles: ["/app-storage/guest-git/askpass.sh"], readOnlyProjects: projects)
    }
    private func profile(projects: [String] = []) -> String { BackendMacConfinement.profile(plan(projects: projects)) }
    // seatbelt.test.ts:17
    func testSeatbeltStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(BackendMacConfinement.seatbeltString("/a/q\"uote"), #""/a/q\"uote""#)
        XCTAssertEqual(BackendMacConfinement.seatbeltString("C:\\work"), #""C:\\work""#)
    }
    // seatbelt.test.ts:25
    func testSeatbeltEscapesBackslashBeforeQuote() { XCTAssertEqual(BackendMacConfinement.seatbeltString("a\\\"b"), #""a\\\"b""#) }
    // seatbelt.test.ts:31
    func testSeatbeltLeavesOrdinaryPathAlone() { XCTAssertEqual(BackendMacConfinement.seatbeltString("/Users/asad/Projects/app"), "\"/Users/asad/Projects/app\"") }
    // seatbelt.test.ts:39
    func testProfileDeniesDefaultBeforeFirstAllow() throws {
        let text = profile(), deny = try XCTUnwrap(text.range(of: "(deny default)")), allow = try XCTUnwrap(text.range(of: "(allow "))
        XCTAssertLessThan(deny.lowerBound, allow.lowerBound)
    }
    // seatbelt.test.ts:46
    func testRootDirectoryHasLiteralReadGrant() { XCTAssertTrue(profile().contains("(allow file-read* (literal \"/\"))")) }
    // seatbelt.test.ts:53
    func testGrantedProjectHasReadAndWrite() { XCTAssertTrue(profile().contains("(allow file-read* file-write* (subpath \"/Users/asad/Projects/app\"))")) }
    // seatbelt.test.ts:57
    func testSystemRootsAreReadOnly() {
        XCTAssertTrue(profile().contains("(allow file-read* (subpath \"/usr\"))"))
        XCTAssertFalse(profile().contains("(allow file-read* file-write* (subpath \"/usr\"))"))
    }
    // seatbelt.test.ts:62
    func testHelperIsLiteralFileRatherThanDirectory() {
        XCTAssertTrue(profile().contains("(allow file-read* (literal \"/app-storage/guest-git/askpass.sh\"))"))
        XCTAssertFalse(profile().contains("\"/app-storage/guest-git\")"))
    }
    // seatbelt.test.ts:67
    func testDelegationMachServicesAreDeniedAfterBlanketAllow() throws {
        let text = profile()
        for service in ["com.apple.coreservices.appleevents", "com.apple.coreservices.launchservicesd", "com.apple.SecurityServer"] { XCTAssertTrue(text.contains("(global-name \"" + service + "\")")) }
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "(allow mach-lookup)")).lowerBound, try XCTUnwrap(text.range(of: "(deny mach-lookup")).lowerBound)
    }
    // seatbelt.test.ts:79
    func testOnlyOwnProcessesCanBeInspected() { XCTAssertTrue(profile().contains("(allow process-info* (target self))")); XCTAssertFalse(profile().contains("(allow process-info*)\n")) }
    // seatbelt.test.ts:84
    func testXcodeShimCacheIsNamedWithoutOpeningTempDirectory() { XCTAssertTrue(profile().contains("xcrun_db")); XCTAssertFalse(profile().contains("(subpath \"/private/var/folders")) }
    // seatbelt.test.ts:93
    func testSubpathsComeOnlyFromPlanAndDeviceNodes() throws {
        let regex = try NSRegularExpression(pattern: #"\(subpath "([^"]+)"\)"#), text = profile(), permitted = Set(plan().writable + plan().readable + ["/dev"])
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: text)); XCTAssertTrue(permitted.contains(String(text[range])))
        }
    }
    // seatbelt.test.ts:122 and secrets.test.ts:55
    func testAllCredentialDeniesFollowDirectoryGrantsAndPrecedeExceptions() throws {
        let text = profile(projects: ["/Users/asad/Projects/one"])
        let deny = try XCTUnwrap(text.range(of: "(deny file-read* (regex")), exception = try XCTUnwrap(text.range(of: "(allow file-read* (regex")), lastGrant = try XCTUnwrap(text.range(of: "(allow file-read* file-write* (subpath", options: .backwards))
        XCTAssertGreaterThan(deny.lowerBound, lastGrant.lowerBound)
        let lastDeny = try XCTUnwrap(text.range(of: "(deny file-read* (regex", options: .backwards))
        XCTAssertLessThan(lastDeny.lowerBound, exception.lowerBound)
    }
    // seatbelt.test.ts:133
    func testTemplateExceptionFollowsDotenvDeny() throws {
        let text = profile(projects: ["/Users/asad/Projects/one"])
        XCTAssertGreaterThan(try XCTUnwrap(text.range(of: "(allow file-read* (regex")).lowerBound, try XCTUnwrap(text.range(of: "(deny file-read* (regex")).lowerBound)
    }
    // seatbelt.test.ts:139
    func testCredentialRegexesHaveSingleEscapes() {
        let text = profile(projects: ["/Users/asad/Projects/one"])
        XCTAssertTrue(text.contains(#"\.env"#)); XCTAssertFalse(text.contains(#"\\.env"#))
    }
    // seatbelt.test.ts:153
    func testReadOnlyProjectProfileNeverGrantsWrite() {
        let text = profile(projects: ["/Users/asad/Projects/one"])
        XCTAssertTrue(text.contains("(allow file-read* (subpath \"/Users/asad/Projects/one\"))"))
        XCTAssertFalse(text.contains("(allow file-read* file-write* (subpath \"/Users/asad/Projects/one\"))"))
    }
    // seatbelt.test.ts:158 and secrets.test.ts:69
    func testNoProjectMeansNoCredentialRegexes() { XCTAssertFalse(profile().contains("(deny file-read* (regex")) }
    // secrets.test.ts:33 via actual launch regex serialization.
    func testRegexEscapesFolderMetacharacters() { XCTAssertTrue(profile(projects: ["/Users/a/app (v2)+x"]).contains(#"^/Users/a/app \(v2\)\+x(/.*)?/"#)) }
    // secrets.test.ts:39
    func testRegexEscapesDotSoSiblingCannotMatch() { XCTAssertTrue(profile(projects: ["/a/b.c"]).contains(#"^/a/b\.c(/.*)?/"#)) }
    // secrets.test.ts:43
    func testRegexQuotesBecomeSafeOvermatchingWildcard() { XCTAssertTrue(profile(projects: ["/a/q\"uote"]).contains("^/a/q.uote(/.*)?/")) }
    // secrets.test.ts:60
    func testEveryCredentialRuleIsAnchoredToOneProject() {
        let lines = profile(projects: ["/p/one", "/p/two"]).components(separatedBy: .newlines).filter { $0.contains("(regex #\"^") && ($0.hasPrefix("(deny file-read*") || $0.hasPrefix("(allow file-read* (regex")) }
        XCTAssertFalse(lines.isEmpty)
        for line in lines { XCTAssertTrue(line.contains("(regex #\"^/p/"), line) }
    }
    // secrets.test.ts:64. Exact source catalogue currently has eleven shapes.
    // Its public names/why metadata is still absent and separately recorded.
    func testEveryProjectGetsAllElevenCredentialDenies() {
        let lines = profile(projects: ["/p/one", "/p/two"]).components(separatedBy: .newlines).filter { $0.hasPrefix("(deny file-read* (regex") }
        XCTAssertEqual(lines.count, 22)
    }
}
