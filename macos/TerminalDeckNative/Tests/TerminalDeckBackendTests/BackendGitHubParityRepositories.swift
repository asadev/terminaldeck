import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendGitHubParityRepositories: XCTestCase {
    private let token = "gho_16C7e42F292c6912E7710c838347Ae178B4a"
    private let link = #"<https://api.github.com/user/repos?per_page=2&sort=pushed&affiliation=owner%2Ccollaborator%2Corganization_member&page=2>; rel="next", <https://api.github.com/user/repos?per_page=2&sort=pushed&affiliation=owner%2Ccollaborator%2Corganization_member&page=14>; rel="last""#
    private let now = Date(timeIntervalSince1970: 1_786_845_600).timeIntervalSince1970 * 1000
    private func repo() throws -> NativeRPCValue { try BackendGitHubParityJSON(#"{"name":"commander","full_name":"asadev/commander","private":true,"owner":{"login":"asadev"},"html_url":"https://github.com/asadev/commander","description":"Kiwi Commander workspace — Claude Code orchestrator.","fork":false,"language":"PLpgSQL","archived":false,"pushed_at":"2026-08-16T01:30:03Z","default_branch":"main","permissions":{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true}}"#) }
    func testRealCommaContainingPaginationHeaderAndBounds() {
        XCTAssertEqual(BackendGitHubRepositories.lastPage(link), 14)
        XCTAssertNil(BackendGitHubRepositories.lastPage(nil)); XCTAssertNil(BackendGitHubRepositories.lastPage(#"<https://api.github.com/user/repos?page=2>; rel="next""#))
        XCTAssertEqual(BackendGitHubRepositories.atLeast(rows: 2, perPage: 2, last: 14), 27)
        XCTAssertEqual(BackendGitHubRepositories.atLeast(rows: 40, last: nil), 40); XCTAssertEqual(BackendGitHubRepositories.atLeast(rows: 40, last: 1), 40)
    }
    func testRealRepositoryAllFieldsAndOrphanRows() throws {
        let mapped = BackendGitHubRepositories.mapRepo(try repo())!
        let expected = try BackendGitHubParityJSON(#"{"owner":"asadev","name":"commander","nameWithOwner":"asadev/commander","url":"https://github.com/asadev/commander","private":true,"fork":false,"archived":false,"description":"Kiwi Commander workspace — Claude Code orchestrator.","language":"PLpgSQL","defaultBranch":"main","pushedAt":"2026-08-16T01:30:03Z","canPush":true}"#)
        XCTAssertEqual(Set(mapped.fields!.map(\.key)), Set(expected.fields!.map(\.key)))
        for field in expected.fields! { XCTAssertEqual(mapped[field.key], field.value) }
        for full in [nil, "noslash", "/leading", "trailing/"] as [String?] { XCTAssertNil(BackendGitHubRepositories.mapRepo(BackendGitHubParityObject([("full_name", BackendGitHubRules.text(full))]))) }
        XCTAssertEqual(BackendGitHubRepositories.mapRepo(try BackendGitHubParityJSON(#"{"full_name":"a/b"}"#))?["url"].string, "https://github.com/a/b")
    }
    func testEnterpriseAndExplicitOrganizationEndpoints() {
        XCTAssertEqual(BackendGitHubRepositories.apiRoot("github.com"), "https://api.github.com")
        XCTAssertEqual(BackendGitHubRepositories.apiRoot("git.acme.co"), "https://git.acme.co/api/v3")
        let enterprise = BackendGitHubRepositories.accountURL("git.acme.co")
        XCTAssertTrue(enterprise.contains("https://git.acme.co/api/v3/user/repos"))
        let publicURL = BackendGitHubRepositories.accountURL("github.com")
        XCTAssertTrue(publicURL.contains("affiliation=owner,collaborator,organization_member")); XCTAssertTrue(publicURL.contains("sort=pushed")); XCTAssertTrue(publicURL.contains("per_page=100"))
    }
    func testFullFirstPageHonestLowerBoundAndBearerAuthorization() async throws {
        let body = NativeRPCValue.array([try self.repo()]).compact, link = self.link
        let http = BackendGitHubParityHTTP { _ in .init(status: 200, body: body, headers: ["Link": link, "X-RateLimit-Remaining": "4993"]) }
        let clock = BackendGitHubParityClock(now), token = self.token
        let access = await BackendGitHubRepositories.read(token: token, host: "github.com", http: http, secrets: [token], now: { clock.now() }), calls = await http.calls()
        XCTAssertEqual(access["ok"].bool, true); XCTAssertEqual(access["repos"].elements?.map { $0["nameWithOwner"].string }, ["asadev/commander"])
        XCTAssertEqual(access["truncated"].bool, true); XCTAssertEqual(access["atLeast"].number, 1301); XCTAssertEqual(access["source"].string, "account"); XCTAssertEqual(access["selection"], .null); XCTAssertEqual(access["rateRemaining"].number, 4993); XCTAssertEqual(calls.first?.headers["Authorization"], "Bearer \(token)")
    }
    func testShortPageIsWholeList() async throws {
        let body = NativeRPCValue.array([try repo()]).compact, http = BackendGitHubParityHTTP { _ in .init(status: 200, body: body) }
        let access = await BackendGitHubRepositories.read(token: token, host: "github.com", http: http)
        XCTAssertEqual(access["truncated"].bool, false); XCTAssertEqual(access["atLeast"].number, 1)
    }
    func testAccountExpiredRateLimitPlainRefusalMalformedAndSecret() async {
        let clock = BackendGitHubParityClock(now), token = self.token
        let reset = floor(now / 1000) + 25 * 60
        for (response, kind) in [(BackendGitHubHTTPResponse(status: 401, body: #"{"message":"Bad credentials"}"#), "auth-expired"), (.init(status: 403, body: #"{"message":"API rate limit exceeded"}"#, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(format: "%.0f", reset)]), "rate-limited"), (.init(status: 403, body: #"{"message":"Resource not accessible"}"#), "no-access"), (.init(status: 200, body: #"{"message":"nope"}"#), "error"), (.init(status: 500, body: "{\"message\":\"upstream said \(token)\"}"), "error")] {
            let http = BackendGitHubParityHTTP { _ in response }, value = await BackendGitHubRepositories.read(token: token, host: "github.com", http: http, secrets: [token], now: { clock.now() })
            XCTAssertEqual(value["kind"].string, kind); XCTAssertFalse(value.compact.contains(token))
            if kind == "rate-limited" { XCTAssertTrue(value["message"].string!.contains("25 minutes")) }
        }
    }
    func testUnreachableHostReturnsTypedFailure() async {
        let http = BackendGitHubParityHTTP { _ in throw NativeRPCError(code: "ENOTFOUND", message: "getaddrinfo ENOTFOUND api.github.com") }
        let failure = await BackendGitHubRepositories.read(token: token, host: "github.com", http: http)
        XCTAssertEqual(failure["kind"].string, "network-down"); XCTAssertTrue(failure["message"].string!.contains("github.com"))
    }
    func testSelectedInstallationCountAndExactSecondURL() async throws {
        let repo = try self.repo(), clock = BackendGitHubParityClock(now)
        let http = BackendGitHubParityHTTP { call in
            call.url == BackendGitHubRepositories.installationsURL("github.com") ? .init(status: 200, body: #"{"total_count":1,"installations":[{"id":42,"repository_selection":"selected","account":{"login":"asadev"}}]}"#) : .init(status: 200, body: BackendGitHubParityObject([("total_count", .number(2)), ("repositories", .array([repo]))]).compact)
        }
        let access = await BackendGitHubRepositories.read(token: token, host: "github.com", kind: "github-app", http: http, now: { clock.now() }), calls = await http.calls()
        XCTAssertEqual(access["ok"].bool, true); XCTAssertEqual(access["source"].string, "installation"); XCTAssertEqual(access["selection"].string, "selected"); XCTAssertEqual(access["atLeast"].number, 2); XCTAssertEqual(access["truncated"].bool, true)
        XCTAssertEqual(calls[1].url, BackendGitHubRepositories.installationURL("github.com", id: 42))
    }
    func testNoInstallationExplainsFixAndNeverFallsBack() async {
        let none = BackendGitHubParityHTTP { _ in .init(status: 200, body: #"{"total_count":0,"installations":[]}"#) }
        let failure = await BackendGitHubRepositories.read(token: token, host: "github.com", kind: "github-app", http: none)
        XCTAssertEqual(failure["ok"].bool, false); XCTAssertTrue(failure["message"].string!.contains("Install the app"))
        let refused = BackendGitHubParityHTTP { _ in .init(status: 403, body: #"{"message":"Resource not accessible"}"#) }
        let result = await BackendGitHubRepositories.read(token: token, host: "github.com", kind: "github-app", http: refused), calls = await refused.calls()
        XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].url, BackendGitHubRepositories.installationsURL("github.com"))
    }
    func testOAuthCredentialUsesAccountEndpoint() async throws {
        let body = NativeRPCValue.array([try repo()]).compact, http = BackendGitHubParityHTTP { _ in .init(status: 200, body: body) }
        _ = await BackendGitHubRepositories.read(token: token, host: "github.com", kind: "oauth", http: http)
        let calls = await http.calls(); XCTAssertEqual(calls[0].url, BackendGitHubRepositories.accountURL("github.com"))
    }
}
