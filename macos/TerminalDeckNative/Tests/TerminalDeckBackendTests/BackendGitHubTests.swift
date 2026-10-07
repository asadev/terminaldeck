import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor
final class BackendGitHubTests: XCTestCase {
    func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    func testRegistrationAndOverrides() {
        XCTAssertEqual(BackendGitHubAppRegistration.shipping.clientID, "Iv23limkNV4N6mChRl60")
        XCTAssertEqual(BackendGitHubAppRegistration.shipping.installURL(), "https://github.com/apps/terminal-deck/installations/new")
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [BackendGitHubAppRegistration.clientIDEnvironment: " " ]), .shipping)
        XCTAssertEqual(BackendGitHubAppRegistration.resolve(environment: [BackendGitHubAppRegistration.slugEnvironment: "orphan"], built: .absent), .absent)
        XCTAssertNil(BackendGitHubAppRegistration(clientID: "id", slug: "../evil").installURL())
        XCTAssertEqual(BackendGitHubAppRegistration(clientID: "id", slug: "DECK").installURL(host: "git.acme.co"), "https://git.acme.co/apps/deck/installations/new")
    }
    func testURLAndLocalConfigParsing() {
        for value in ["https://x-access-token:secret@github.com/Owner/RePo.git", "git@github.com:Owner/RePo.git", "ssh://git@github.com:443/Owner/RePo.git/"] {
            let parsed = BackendGitHubRules.parseRemoteURL(value)
            XCTAssertEqual(parsed?["host"].string, "github.com"); XCTAssertEqual(parsed?["owner"].string, "Owner"); XCTAssertEqual(parsed?["name"].string, "RePo")
        }
        for invalid in ["", "../local", "https://github.com/../repo", "https://github.com/-owner/repo", "https://github.com/o/r/extra", "https://github.com/o/"] { XCTAssertNil(BackendGitHubRules.parseRemoteURL(invalid)) }
        let config = BackendGitHubRules.parseRemoteConfig("remote.my.fork.url https://github.com/o/a.url b\nremote.origin.gh-resolved base\nremote.my.fork.url https://github.com/ignored/r\nremote.origin.url git@github.com:o/r.git")
        XCTAssertEqual(config.count, 2); XCTAssertEqual(config[0].name, "my.fork"); XCTAssertEqual(config[0].url, "https://github.com/o/a.url b"); XCTAssertEqual(config[1].resolved, "base")
        XCTAssertTrue(BackendGitHubRules.parseRemoteConfig("remote.orphan.gh-resolved base").isEmpty)
    }
    func testRemotePreferenceAndEnterpriseHost() {
        let entries = [BackendGitHubRules.Remote(name: "origin", url: "https://github.com/me/fork.git"), .init(name: "upstream", url: "https://github.com/them/base.git")]
        XCTAssertEqual(BackendGitHubRules.pickRepo(entries)?["remote"].string, "upstream")
        let explicit = BackendGitHubRules.pickRepo([.init(name: "origin", url: "https://git.acme.co/me/fork.git", resolved: "git.acme.co/them/orig")], hosts: ["github.com", "git.acme.co"])
        XCTAssertEqual(explicit?["url"].string, "https://git.acme.co/them/orig")
        let refused = BackendGitHubRules.pickRepo([.init(name: "origin", url: "https://github.com/me/fork.git", resolved: "evil.example/them/orig")])
        XCTAssertEqual(refused?["nameWithOwner"].string, "me/fork")
        XCTAssertTrue(BackendGitHubRules.isGitHubHost("ssh.github.com")); XCTAssertFalse(BackendGitHubRules.isGitHubHost("github.com.evil.test"))
    }
    func testClassifierKeepsDifferentFixes() {
        let cases: [(String, String)] = [("To get started with GitHub CLI", "not-authenticated"), ("HTTP 401: Bad credentials", "auth-expired"), ("proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused", "network-down"), ("API rate limit exceeded (HTTP 403)", "rate-limited"), ("You need at least read:packages scope (HTTP 403)", "missing-scope"), ("repository has disabled issues", "issues-disabled"), ("HTTP 404 Not Found", "repo-not-found"), ("Resource not accessible by integration (HTTP 403)", "no-access"), ("not a git repository", "not-a-repo")]
        for (text, kind) in cases { XCTAssertEqual(BackendGitHubRules.classify(text: text)["kind"].string, kind) }
        XCTAssertEqual(BackendGitHubRules.classify(text: "", missing: true)["kind"].string, "gh-missing")
        XCTAssertEqual(BackendGitHubRules.classify(text: "HTTP 401", timedOut: true)["kind"].string, "timeout")
        XCTAssertEqual(BackendGitHubRules.classify(text: "at least read:packages scope")["action"].string, "gh auth refresh -h github.com -s read:packages")
        XCTAssertEqual(BackendGitHubRules.classify(text: "not a git repository")["action"], .null)
    }
    func testRedactsBeforeTruncating() {
        let token = "0123456789abcdef0123456789abcdef01234567"
        let text = String(repeating: ".", count: 3_980) + "https://user:token@github.com/o/r " + token + String(repeating: "!", count: 1000)
        let failure = BackendGitHubRules.failure("error", "Failed", detail: text, secrets: [token])
        XCTAssertFalse(failure.compact.contains(token)); XCTAssertFalse(failure.compact.contains("user:token")); XCTAssertTrue(failure["detail"].string?.contains("more characters") == true)
        XCTAssertEqual(BackendGitHubRules.redactURL("https://token@github.com/a/b"), "https://***@github.com/a/b")
        XCTAssertEqual(BackendGitHubRules.redactURL("git@github.com:a/b"), "git@github.com:a/b")
    }
    func testMappingAndLimits() throws {
        let pull = try json(#"{"number":1,"url":"https://github.com/a/b/pull/1","state":"CLOSED","mergedAt":"2026-01-01","isDraft":true,"reviewDecision":"CHANGES_REQUESTED","labels":[{"name":"x","color":"red;bad"}]}"#)
        let mapped = BackendGitHubRules.mapRow(pull, pulls: true)
        XCTAssertEqual(mapped?["badge"].string, "merged"); XCTAssertEqual(mapped?["draft"].bool, true); XCTAssertEqual(mapped?["review"].string, "changes-requested"); XCTAssertEqual(mapped?["labels"].elements?.first?["color"].string, "8b949e")
        XCTAssertNil(BackendGitHubRules.mapRow(.object([]), pulls: true))
        let issue = BackendGitHubRules.mapRow(try json(#"{"number":2,"url":"https://x","state":"CLOSED","stateReason":"NOT_PLANNED","assignees":[{"name":"unknown"},{"login":"asd"}]}"#), pulls: false)
        XCTAssertEqual(issue?["reason"].string, "not-planned"); XCTAssertEqual(issue?["assignees"], .array([.string("asd")]))
        XCTAssertEqual(BackendGitHubRules.clampLimit(.number(7.9)), 7); XCTAssertEqual(BackendGitHubRules.clampLimit(.number(-10)), 1); XCTAssertEqual(BackendGitHubRules.clampLimit(.number(1000)), 100); XCTAssertEqual(BackendGitHubRules.clampLimit(.string("40")), 20)
        let repo = BackendGitHubRules.ref(host: "git.acme.co", owner: "a", name: "b", remote: "origin")
        XCTAssertTrue(BackendGitHubRules.listArgs(repo: repo, limit: 20, pulls: true).contains("git.acme.co/a/b"))
        XCTAssertFalse(BackendGitHubRules.listArgs(repo: repo, limit: 20, pulls: false).joined().contains("comments"))
    }
    func testPaginationIsAnHonestLowerBound() throws {
        let link = #"<https://api.github.com/user/repos?affiliation=owner,collaborator&page=2>; rel="next", <https://api.github.com/user/repos?affiliation=owner,collaborator&page=14>; rel="last""#
        XCTAssertEqual(BackendGitHubRepositories.lastPage(link), 14)
        XCTAssertEqual(BackendGitHubRepositories.atLeast(rows: 2, perPage: 2, last: 14), 27)
        XCTAssertNil(BackendGitHubRepositories.lastPage(nil))
        let row = BackendGitHubRepositories.mapRepo(try json(#"{"full_name":"a/b","permissions":{"push":true}}"#))
        XCTAssertEqual(row?["url"].string, "https://github.com/a/b"); XCTAssertEqual(row?["canPush"].bool, true)
        XCTAssertNil(BackendGitHubRepositories.mapRepo(try json(#"{"full_name":"trailing/"}"#)))
    }
    func testInstallationFailureNeverFallsBackToAccountEndpoint() async {
        let http = BackendGitHubFixtureHTTP { _ in .init(status: 403, body: "Resource not accessible") }
        let value = await BackendGitHubRepositories.read(token: "fixture-only-token", host: "github.com", kind: "github-app", http: http)
        let calls = await http.calls()
        XCTAssertEqual(value["kind"].string, "no-access"); XCTAssertEqual(calls.map(\.url), [BackendGitHubRepositories.installationsURL("github.com")])
    }
    func testInstallationCountAndSelection() async {
        let http = BackendGitHubFixtureHTTP { call in call.url.contains("/repositories?") ? .init(status: 200, body: #"{"total_count":2,"repositories":[{"full_name":"a/b"}]}"#) : .init(status: 200, body: #"{"installations":[{"id":42,"repository_selection":"selected"}]}"#) }
        let value = await BackendGitHubRepositories.read(token: "fixture-only-token", host: "github.com", kind: "github-app", http: http)
        XCTAssertEqual(value["atLeast"].number, 2); XCTAssertEqual(value["truncated"].bool, true); XCTAssertEqual(value["selection"].string, "selected")
    }
    func testAccountFailureScrubsCLISecretAndRateReset() async {
        let token = "gho_fixtureToken1234567890123456789"
        let http = BackendGitHubFixtureHTTP { _ in .init(status: 403, body: "rate limit \(token)", headers: ["X-Ratelimit-Remaining": "0", "X-Ratelimit-Reset": "1500"]) }
        let value = await BackendGitHubRepositories.read(token: token, host: "github.com", http: http, secrets: [token], now: { 0 })
        XCTAssertEqual(value["kind"].string, "rate-limited"); XCTAssertTrue(value["message"].string?.contains("25 minutes") == true); XCTAssertFalse(value.compact.contains(token))
    }
    func testCacheJoinClearAndNewestWriter() async throws {
        let cache = BackendGitHubCache(now: { 0 }), gate = BackendGitHubTestGate()
        let old = Task { try await cache.through("k", load: { await gate.wait(); return .string("old") }, ttl: { _ in 60_000 }) }
        await gate.started()
        let newest = try await cache.through("k", refresh: true, load: { .string("new") }, ttl: { _ in 60_000 })
        XCTAssertEqual(newest, .string("new")); await gate.release(); _ = try await old.value
        let kept = try await cache.through("k", load: { .string("unused") }, ttl: { _ in 60_000 })
        XCTAssertEqual(kept, .string("new")); await cache.clear(prefix: "k")
        let cleared = try await cache.through("k", load: { .string("clear") }, ttl: { _ in 60_000 }); XCTAssertEqual(cleared, .string("clear"))
    }
    func testCacheBoundsAndExpiry() async throws {
        let cache = BackendGitHubCache(now: { 1 })
        for index in 0...200 { _ = try await cache.through("\(index)", load: { .number(Double(index)) }, ttl: { _ in 60_000 }) }
        let first = try await cache.through("0", load: { .string("evicted") }, ttl: { _ in 60_000 }); XCTAssertEqual(first, .string("evicted"))
        _ = try await cache.through("dead", load: { .string("old") }, ttl: { _ in 0 })
        let expired = try await cache.through("dead", load: { .string("new") }, ttl: { _ in 1 }); XCTAssertEqual(expired, .string("new"))
    }
}

actor BackendGitHubFixtureHTTP: BackendGitHubHTTPFetching {
    struct Call: Sendable { let url: String; let method: String; let headers: [String: String]; let body: String? }
    private var seen: [Call] = []
    private let answer: @Sendable (Call) throws -> BackendGitHubHTTPResponse
    init(_ answer: @escaping @Sendable (Call) throws -> BackendGitHubHTTPResponse) { self.answer = answer }
    func calls() -> [Call] { seen }
    func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        let call = Call(url: url, method: method, headers: headers, body: body); seen.append(call); return try answer(call)
    }
}
actor BackendGitHubTestGate {
    private var continuation: CheckedContinuation<Void, Never>?, entered = false
    private var starting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let observers = starting; starting.removeAll(); for observer in observers { observer.resume() }
        await withCheckedContinuation { continuation = $0 }
    }
    func started() async { if entered { return }; await withCheckedContinuation { starting.append($0) } }
    func release() { continuation?.resume(); continuation = nil }
}
