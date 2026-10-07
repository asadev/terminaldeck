import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor final class BackendGitHubParityRules: XCTestCase {
    private func remote(_ name: String, _ url: String, _ resolved: String? = nil) -> BackendGitHubRules.Remote { .init(name: name, url: url, resolved: resolved) }
    private func assertObject(_ actual: NativeRPCValue?, _ expected: NativeRPCValue, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("Mapped row missing", file: file, line: line) }
        XCTAssertEqual(Set(actual.fields?.map(\.key) ?? []), Set(expected.fields?.map(\.key) ?? []), file: file, line: line)
        for field in expected.fields ?? [] { XCTAssertEqual(actual[field.key], field.value, field.key, file: file, line: line) }
    }
    func testURLCredentialsEveryOccurrenceAndCredentialFreeForms() {
        for input in ["https://x-access-token:ghp_secret123@github.com/o/r.git", "https://ghp_secret123@github.com/o/r.git"] { XCTAssertEqual(BackendGitHubRules.redactURL(input), "https://***@github.com/o/r.git") }
        XCTAssertEqual(BackendGitHubRules.redactURL("a https://u:p@github.com/o/r b https://x:y@github.com/o/s"), "a https://***@github.com/o/r b https://***@github.com/o/s")
        XCTAssertEqual(BackendGitHubRules.redactURL("git@github.com:owner/repo.git"), "git@github.com:owner/repo.git")
        XCTAssertEqual(BackendGitHubRules.redactURL("https://github.com/owner/repo"), "https://github.com/owner/repo")
    }
    func testAdversarialBlobAndLateCredentials() {
        // Combined performance gate only, never run by this source worker.
        // One bounded source operation is measured honestly, not a spin loop
        // or a fake clock manufacturing the TS <2s performance result.
        let clock = ContinuousClock(); let started = clock.now
        let blob = String(repeating: "x", count: 400_000) + "://" + String(repeating: "y", count: 400_000)
        XCTAssertEqual(BackendGitHubRules.redactURL(blob), blob)
        XCTAssertEqual(BackendGitHubRules.redactURL(String(repeating: "z", count: 800_000)).utf16.count, 800_000)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        let late = String(repeating: "x ", count: 50_000) + "https://user:tok_secret@github.com/o/r", out = BackendGitHubRules.redactURL(late)
        XCTAssertFalse(out.contains("tok_secret")); XCTAssertTrue(out.contains("https://***@github.com/o/r"))
    }
    func testDetailCapAndRedactionBeforeCut() {
        let capped = BackendGitHubRules.classify(text: String(repeating: "boom ", count: 200_000))
        XCTAssertLessThan(capped["detail"].string!.utf16.count, 5_000); XCTAssertTrue(capped["detail"].string!.contains("more characters"))
        let boundary = BackendGitHubRules.classify(text: String(repeating: ".", count: 3_980) + "https://x-access-token:ghp_leakme@github.com/o/r.git")
        XCTAssertFalse(boundary["detail"].string!.contains("ghp_leakme"))
    }
    func testRemoteURLSpellingsCredentialsPortAndCase() throws {
        let identity = try BackendGitHubParityJSON(#"{"host":"github.com","owner":"cli","name":"cli"}"#)
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://github.com/cli/cli.git"), identity)
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://github.com/cli/cli"), identity)
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("git@github.com:owner/repo.git"), try BackendGitHubParityJSON(#"{"host":"github.com","owner":"owner","name":"repo"}"#))
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("ssh://git@github.com/owner/repo.git")?["name"].string, "repo")
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("git://github.com/owner/repo.git")?["owner"].string, "owner")
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://x-access-token:ghp_abc@github.com/owner/repo.git"), try BackendGitHubParityJSON(#"{"host":"github.com","owner":"owner","name":"repo"}"#))
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("ssh://git@ssh.github.com:443/owner/repo.git")?["host"].string, "ssh.github.com")
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://github.com/owner/repo/")?["name"].string, "repo")
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://gitlab.com/group/proj.git")?["host"].string, "gitlab.com")
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://GitHub.com/Owner/RePo.git"), try BackendGitHubParityJSON(#"{"host":"github.com","owner":"Owner","name":"RePo"}"#))
        // Remote URL hosts are lowercased before validation in the source.
        XCTAssertEqual(BackendGitHubRules.parseRemoteURL("https://K.example/owner/repo")?["host"].string, "k.example")
    }
    func testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation() {
        for value in ["https://github.com/owner", "https://github.com/owner/repo/extra", "", "   ", "not a url at all", "/srv/git/repo.git", "https://github.com/../repo", "https://github.com/owner/..", "https://github.com/./repo", "https://github.com/-oProxyCommand/repo", "https://github.com/owner/repo?x=1", "https://github.com/own er/repo", "https://github.com/owner/re;po"] { XCTAssertNil(BackendGitHubRules.parseRemoteURL(value), value) }
        for value in ["https://github.com/ſowner/repo", "https://github.com/Kowner/repo", "https://ſ.example/owner/repo", "ſsh://github.com/owner/repo", "K://github.com/owner/repo"] { XCTAssertNil(BackendGitHubRules.parseRemoteURL(value), value) }
    }
    func testHostSuffixRequiresADotAndEnterpriseOptIn() {
        for host in ["github.com", "ssh.github.com"] { XCTAssertTrue(BackendGitHubRules.isGitHubHost(host)) }
        for host in ["notgithub.com", "github.com.evil.example", "gitlab.com"] { XCTAssertFalse(BackendGitHubRules.isGitHubHost(host)) }
        XCTAssertTrue(BackendGitHubRules.isGitHubHost("git.acme.co", hosts: ["github.com", "git.acme.co"]))
    }
    func testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys() {
        let entries = BackendGitHubRules.parseRemoteConfig("remote.origin.url https://github.com/me/fork.git\nremote.origin.gh-resolved base\nremote.upstream.url https://github.com/them/orig.git")
        XCTAssertEqual(entries, [remote("origin", "https://github.com/me/fork.git", "base"), remote("upstream", "https://github.com/them/orig.git")])
        XCTAssertEqual(BackendGitHubRules.parseRemoteConfig("remote.origin.url https://github.com/o/a.git\nremote.origin.url https://github.com/o/b.git").first?.url, "https://github.com/o/a.git")
        XCTAssertEqual(BackendGitHubRules.parseRemoteConfig("remote.ghost.gh-resolved base"), [])
        XCTAssertEqual(BackendGitHubRules.parseRemoteConfig("remote.origin.fetch +refs/heads/*:refs/remotes/origin/*\ncore.bare false\n"), [])
        XCTAssertEqual(BackendGitHubRules.parseRemoteConfig("remote.my.fork.url https://github.com/o/r.git").first?.name, "my.fork")
        XCTAssertEqual(BackendGitHubRules.parseRemoteConfig("remote.origin.url https://github.com/o/a.url b"), [remote("origin", "https://github.com/o/a.url b")])
    }
    func testResolvedIdentityTwoOrThreePartsAndInvalidForms() throws {
        XCTAssertEqual(BackendGitHubRules.parseResolved("them/orig"), try BackendGitHubParityJSON(#"{"host":null,"owner":"them","name":"orig"}"#))
        XCTAssertEqual(BackendGitHubRules.parseResolved("git.acme.co/them/orig"), try BackendGitHubParityJSON(#"{"host":"git.acme.co","owner":"them","name":"orig"}"#))
        for value in ["", "lonely", "a/b/c/d", "../etc/passwd", "K.example/owner/repo", "ſ.example/owner/repo"] { XCTAssertNil(BackendGitHubRules.parseResolved(value)) }
    }
    func testRepositorySelectionCanonicalDefaultBaseRankingAndFallback() {
        XCTAssertNil(BackendGitHubRules.pickRepo([remote("origin", "https://gitlab.com/g/p.git")]))
        let canonical = BackendGitHubRules.pickRepo([remote("origin", "https://x:y@github.com/cli/cli.git")])!
        XCTAssertEqual(canonical["url"].string, "https://github.com/cli/cli"); XCTAssertEqual(canonical["nameWithOwner"].string, "cli/cli"); XCTAssertEqual(canonical["remote"].string, "origin")
        XCTAssertEqual(BackendGitHubRules.pickRepo([remote("origin", "https://github.com/me/fork.git", "them/orig")])?["nameWithOwner"].string, "them/orig")
        XCTAssertEqual(BackendGitHubRules.pickRepo([remote("origin", "https://github.com/me/fork.git"), remote("other", "https://github.com/them/orig.git", "base")])?["owner"].string, "them")
        let ranked = [remote("origin", "https://github.com/o/origin.git"), remote("github", "https://github.com/o/github.git"), remote("upstream", "https://github.com/o/upstream.git")]
        XCTAssertEqual(BackendGitHubRules.pickRepo(ranked)?["name"].string, "upstream"); XCTAssertEqual(BackendGitHubRules.pickRepo(Array(ranked.prefix(2)))?["name"].string, "github"); XCTAssertEqual(BackendGitHubRules.pickRepo(Array(ranked.prefix(1)))?["name"].string, "origin")
        XCTAssertEqual(BackendGitHubRules.pickRepo([remote("upstream", "https://gitlab.com/g/p.git"), remote("origin", "https://github.com/o/r.git")])?["remote"].string, "origin")
        XCTAssertEqual(BackendGitHubRules.pickRepo([remote("origin", "https://github.com/me/fork.git", "nonsense")])?["nameWithOwner"].string, "me/fork")
    }
    func testEnterpriseDefaultAndUnapprovedHostAreNotMangled() {
        let direct = BackendGitHubRules.pickRepo([remote("origin", "git@git.acme.co:team/app.git")], hosts: ["github.com", "git.acme.co"])!
        XCTAssertEqual(direct["host"].string, "git.acme.co"); XCTAssertEqual(direct["url"].string, "https://git.acme.co/team/app")
        let resolved = BackendGitHubRules.pickRepo([remote("origin", "https://git.acme.co/me/fork.git", "git.acme.co/them/orig")], hosts: ["github.com", "git.acme.co"])!
        XCTAssertEqual(resolved["nameWithOwner"].string, "them/orig"); XCTAssertEqual(resolved["url"].string, "https://git.acme.co/them/orig")
        let refused = BackendGitHubRules.pickRepo([remote("origin", "https://github.com/me/fork.git", "evil.example/them/orig")])!
        XCTAssertEqual(refused["host"].string, "github.com"); XCTAssertEqual(refused["nameWithOwner"].string, "me/fork")
    }
    func testClassifierSpawnTimeoutNetworkAndDisabledIssues() {
        let missing = BackendGitHubRules.classify(text: "spawn gh ENOENT", missing: true)
        XCTAssertEqual(missing["kind"].string, "gh-missing"); XCTAssertTrue(missing["action"].string!.contains("install"))
        let off = BackendGitHubRules.classify(text: "the 'multica-ai/andrej-karpathy-skills' repository has disabled issues")
        XCTAssertEqual(off["kind"].string, "issues-disabled"); XCTAssertEqual(off["action"], .null)
        XCTAssertEqual(BackendGitHubRules.classify(text: "", timedOut: true)["kind"].string, "timeout")
        for text in [#"Post "https://api.github.com/graphql": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused"#, "dial tcp: lookup api.github.com: no such host", #"Get "https://api.github.com": net/http: TLS handshake timeout"#] { XCTAssertEqual(BackendGitHubRules.classify(text: text)["kind"].string, "network-down") }
    }
    func testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown() {
        let never = "To get started with GitHub CLI, please run:  gh auth login", notHub = "none of the git remotes configured for this repository point to a known GitHub host"
        for text in [never, "You are not logged into any GitHub hosts. To log in, run: gh auth login"] { XCTAssertEqual(BackendGitHubRules.classify(text: text)["kind"].string, "not-authenticated") }
        XCTAssertEqual(BackendGitHubRules.classify(text: "HTTP 401: Bad credentials")["kind"].string, "auth-expired")
        let auth = BackendGitHubRules.classify(text: never), remote = BackendGitHubRules.classify(text: notHub)
        XCTAssertNotEqual(auth["kind"], remote["kind"]); XCTAssertNotEqual(auth["message"], remote["message"]); XCTAssertEqual(auth["action"].string, "gh auth login"); XCTAssertTrue(remote["message"].string!.lowercased().contains("remote")); XCTAssertFalse(remote["message"].string!.lowercased().contains("sign"))
        for (text, kind) in [("not a git repository", "not-a-repo"), ("no git remotes found", "no-remote"), (notHub, "no-github-remote"), ("HTTP 403: API rate limit exceeded for user ID 1.", "rate-limited"), ("You have exceeded a secondary rate limit", "rate-limited"), ("HTTP 429: Too Many Requests", "rate-limited"), ("Could not resolve to a Repository with the name 'asadev/gone'", "repo-not-found"), ("HTTP 403: Resource not accessible by integration", "no-access")] { XCTAssertEqual(BackendGitHubRules.classify(text: text)["kind"].string, kind) }
        let scope = BackendGitHubRules.classify(text: "gh: You need at least read:packages scope to list packages. (HTTP 403)")
        XCTAssertEqual(scope["kind"].string, "missing-scope"); XCTAssertTrue(scope["message"].string!.contains("read:packages")); XCTAssertTrue(scope["action"].string!.contains("gh auth refresh"))
        XCTAssertTrue(BackendGitHubRules.classify(text: "error: your authentication token is missing required scopes [read:org]")["action"].string!.contains("read:org"))
        let unknown = BackendGitHubRules.classify(text: "gh: something entirely new went wrong")
        XCTAssertEqual(unknown["kind"].string, "error"); XCTAssertEqual(unknown["action"], .null); XCTAssertTrue(unknown["detail"].string!.contains("something entirely new"))
        let redacted = BackendGitHubRules.classify(text: "fatal: could not read from https://x-access-token:ghp_leak@github.com/o/r.git")
        XCTAssertFalse(redacted["detail"].string!.contains("ghp_leak")); XCTAssertTrue(redacted["detail"].string!.contains("***@github.com"))
    }
    func testPullBadgesAllStatesAndMergedTimestampPrecedence() throws {
        for (text, expected) in [(#"{"state":"OPEN","isDraft":true}"#, "draft"), (#"{"state":"OPEN","isDraft":false}"#, "open"), (#"{"state":"CLOSED"}"#, "closed"), (#"{"state":"MERGED"}"#, "merged"), (#"{"state":"closed","mergedAt":"2026-08-01T00:00:00Z"}"#, "merged"), ("{}", "open")] { XCTAssertEqual(BackendGitHubRules.pullBadge(try BackendGitHubParityJSON(text)), expected) }
    }
    private func pull() throws -> NativeRPCValue { try BackendGitHubParityJSON(#"{"number":14130,"title":"Add support for reading issue field values","url":"https://github.com/cli/cli/pull/14130","state":"OPEN","isDraft":true,"mergedAt":null,"author":{"login":"iulia-b","is_bot":false},"createdAt":"2026-08-11T11:46:52Z","updatedAt":"2026-08-11T14:00:32Z","reviewDecision":"REVIEW_REQUIRED","labels":[{"name":"needs-triage","color":"D6393F"}],"headRefName":"issue-fields/read-field-values","isCrossRepository":true,"additions":744,"deletions":17}"#) }
    func testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor() throws {
        let raw = try pull()
        let expected = try BackendGitHubParityJSON(#"{"number":14130,"title":"Add support for reading issue field values","url":"https://github.com/cli/cli/pull/14130","badge":"draft","draft":true,"author":"iulia-b","authorIsBot":false,"createdAt":"2026-08-11T11:46:52Z","updatedAt":"2026-08-11T14:00:32Z","review":"review-required","labels":[{"name":"needs-triage","color":"D6393F"}],"branch":"issue-fields/read-field-values","fromFork":true,"additions":744,"deletions":17}"#)
        assertObject(BackendGitHubRules.mapRow(raw, pulls: true), expected)
        let bot = BackendGitHubRules.mapRow(raw.setting("author", try BackendGitHubParityJSON(#"{"login":"app/dependabot","is_bot":true}"#)), pulls: true)!
        XCTAssertEqual(bot["author"].string, "app/dependabot"); XCTAssertEqual(bot["authorIsBot"].bool, true)
        for (decision, review) in [("APPROVED", NativeRPCValue.string("approved")), ("CHANGES_REQUESTED", .string("changes-requested")), ("", .null)] { XCTAssertEqual(BackendGitHubRules.mapRow(raw.setting("reviewDecision", .string(decision)), pulls: true)?["review"], review) }
        XCTAssertEqual(BackendGitHubRules.mapRow(raw.setting("author", .null), pulls: true)?["author"], .null)
        let colored = BackendGitHubRules.mapRow(raw.setting("labels", try BackendGitHubParityJSON(#"[{"name":"x","color":"red; background: url(evil)"},{"name":"y","color":"0366d6"}]"#)), pulls: true)!
        XCTAssertEqual(colored["labels"].elements?[0]["color"].string, "8b949e"); XCTAssertEqual(colored["labels"].elements?[1]["color"].string, "0366d6")
        XCTAssertNil(BackendGitHubRules.mapRow(try BackendGitHubParityJSON(#"{"title":"orphan"}"#), pulls: true)); XCTAssertNil(BackendGitHubRules.mapRow(try BackendGitHubParityJSON(#"{"number":1}"#), pulls: true))
    }
    func testIssueRowReasonsAndMissingAssigneeLogins() throws {
        let raw = try BackendGitHubParityJSON(#"{"number":14134,"title":"gh skill publish fails","url":"https://github.com/cli/cli/issues/14134","state":"OPEN","stateReason":"","author":{"login":"totwo2","is_bot":false},"createdAt":"2026-08-12T03:17:42Z","updatedAt":"2026-08-12T03:21:27Z","labels":[{"name":"needs-triage","color":"D6393F"}],"assignees":[{"login":"someone"}]}"#)
        let mapped = BackendGitHubRules.mapRow(raw, pulls: false)!
        XCTAssertEqual(mapped["state"].string, "open"); XCTAssertEqual(mapped["reason"], .null); XCTAssertEqual(mapped["assignees"], .array([.string("someone")]))
        for (reason, expected) in [("NOT_PLANNED", "not-planned"), ("COMPLETED", "completed")] { XCTAssertEqual(BackendGitHubRules.mapRow(raw.setting("state", .string("CLOSED")).setting("stateReason", .string(reason)), pulls: false)?["reason"].string, expected) }
        XCTAssertEqual(BackendGitHubRules.mapRow(raw.setting("assignees", try BackendGitHubParityJSON(#"[{"name":"no login"}]"#)), pulls: false)?["assignees"], .array([]))
    }
    func testLimitDefaultFloorAndBoundEveryInputShape() {
        for (value, expected) in [(NativeRPCValue.missing, 20), (.string("40"), 20), (.number(.nan), 20), (.number(0), 1), (.number(-5), 1), (.number(1e6), 100), (.number(7.9), 7)] { XCTAssertEqual(BackendGitHubRules.clampLimit(value), expected) }
    }
    func testSectionIdentityAndArgvNeverContainCommentsOrNotifications() {
        let publicRepo = BackendGitHubRules.ref(host: "github.com", owner: "cli", name: "cli", remote: "origin"), enterprise = publicRepo.setting("host", .string("git.acme.co"))
        XCTAssertNotEqual(BackendGitHubRules.sectionKey("pulls", repo: publicRepo, limit: 20), BackendGitHubRules.sectionKey("pulls", repo: enterprise, limit: 20))
        XCTAssertNotEqual(BackendGitHubRules.sectionKey("pulls", repo: publicRepo, limit: 20), BackendGitHubRules.sectionKey("issues", repo: publicRepo, limit: 20))
        XCTAssertNotEqual(BackendGitHubRules.sectionKey("pulls", repo: publicRepo, limit: 20), BackendGitHubRules.sectionKey("pulls", repo: publicRepo, limit: 50))
        let args = BackendGitHubRules.listArgs(repo: publicRepo, limit: 20, pulls: true)
        XCTAssertEqual(args[args.firstIndex(of: "-R")! + 1], "cli/cli"); XCTAssertEqual(args[args.firstIndex(of: "--limit")! + 1], "20")
        for pulls in [true, false] { XCTAssertFalse(BackendGitHubRules.listArgs(repo: publicRepo, limit: 5, pulls: pulls).joined().contains("comments")); XCTAssertTrue(BackendGitHubRules.listArgs(repo: enterprise, limit: 20, pulls: pulls).contains("git.acme.co/cli/cli")) }
        XCTAssertFalse(BackendGitHubChannels.channels.contains { $0.lowercased().contains("notification") })
        for text in ["gh: Resource not accessible by integration (HTTP 403)", "gh: Resource not accessible by personal access token (HTTP 403)"] { XCTAssertEqual(BackendGitHubRules.classify(text: text)["kind"].string, "no-access") }
    }
}
