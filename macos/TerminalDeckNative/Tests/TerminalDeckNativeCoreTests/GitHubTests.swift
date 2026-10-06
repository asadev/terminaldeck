import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native GitHub page's rules, mirroring `GitHubPanel.test.tsx`.
@Suite("GitHub rules")
struct GitHubRulesTests {
    let repos = [
        GitHubRepoSummary(nameWithOwner: "asadev/terminaldeck", name: "terminaldeck", description: "An agent IDE"),
        GitHubRepoSummary(nameWithOwner: "asadev/commander", name: "commander", description: "The orchestrator"),
    ]

    @Test func countsSayWhenTheListHitItsLimit() {
        #expect(GitHubRules.countLabel(20, limit: 20) == "20+")
        #expect(GitHubRules.countLabel(19, limit: 20) == "19")
        #expect(GitHubRules.countLabel(0, limit: 20) == "0")
        #expect(GitHubRules.countLabel(nil, limit: 20) == nil)
    }

    @Test func namesReviewsAndAges() {
        #expect(GitHubRules.reviewLabel("approved") == "Approved")
        #expect(GitHubRules.reviewLabel("changes-requested") == "Changes requested")
        #expect(GitHubRules.reviewLabel("review-required") == "Review required")
        #expect(GitHubRules.reviewLabel(nil) == nil)
        let now = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
        #expect(GitHubRules.formatAge("2026-10-06T11:59:30Z", now: now) == "now")
        #expect(GitHubRules.formatAge("2026-10-06T11:15:00Z", now: now) == "45m")
        #expect(GitHubRules.formatAge("2026-10-06T07:00:00Z", now: now) == "5h")
        #expect(GitHubRules.formatAge("2026-10-03T12:00:00Z", now: now) == "3d")
        #expect(GitHubRules.formatAge("2026-09-01T12:00:00Z", now: now) == "5w")
        #expect(GitHubRules.formatAge("2024-01-01T00:00:00Z", now: now) == "2y")
        #expect(GitHubRules.formatAge("not a date", now: now) == "")
        #expect(GitHubRules.formatAge("2026-10-06T10:59:00.123Z", now: now) == "1h")
    }

    @Test func aFailureShowsItsCommandOnlyWhenItsSentenceDoesNot() {
        let noRemote = GitHubFailure(kind: "no-remote", message: "This repository has no remotes yet.", action: "git remote add origin <url>")
        #expect(GitHubRules.showsAction(noRemote))
        #expect(GitHubRules.explanation(noRemote) == "This repository has no remotes yet. Run git remote add origin <url> in a terminal, then refresh.")
        #expect(!GitHubRules.showsAction(GitHubFailure(kind: "no-remote", message: "x", action: nil)))
        #expect(!GitHubRules.showsAction(GitHubFailure(kind: "gh-missing", message: "Run gh auth login.", action: "gh auth login")))
        #expect(GitHubRules.offersRetry(GitHubFailure(kind: "timeout", message: "")))
        #expect(!GitHubRules.offersRetry(GitHubFailure(kind: "not-a-repo", message: "")))
        #expect(GitHubRules.failureTitle("rate-limited") == "GitHub rate limit reached")
        #expect(GitHubRules.failureTitle("something new") == "GitHub request failed")
    }

    @Test func saysWhereTheSignInComesFrom() {
        #expect(GitHubRules.sourceWord("gh-cli") == "GitHub CLI")
        #expect(GitHubRules.sourceWord(nil) == "not signed in")
        #expect(GitHubRules.sourceSentence("environment", host: "github.com") == "Using the GH_TOKEN set in the environment this app was launched with, on github.com.")
    }

    @Test func theFolderLineNamesTheRepositoryAndBranch() {
        let repo = GitHubFolderRepo.repo(GitHubRepoRef(nameWithOwner: "asadev/terminaldeck"))
        #expect(GitHubRules.folderLine(repo, branch: GitHubBranchRef(name: "main")) == "asadev/terminaldeck · main")
        #expect(GitHubRules.folderLine(repo, branch: GitHubBranchRef(name: nil, detached: true, head: "a1b2c3d")) == "asadev/terminaldeck · detached at a1b2c3d")
        #expect(GitHubRules.folderLine(repo, branch: GitHubBranchRef(name: nil, detached: true)) == "asadev/terminaldeck · detached HEAD")
        #expect(GitHubRules.folderLine(repo, branch: nil) == "asadev/terminaldeck")
        let failure = GitHubFolderRepo.failed(GitHubFailure(kind: "not-a-repo", message: "This folder is not a git repository."))
        #expect(GitHubRules.folderLine(failure, branch: nil) == "This folder is not a git repository.")
        #expect(GitHubRules.folderLine(nil, branch: nil) == nil)
    }

    @Test func theFoldersFailureBelongsToThePageFirst() {
        let notRepo = GitHubFailure(kind: "not-a-repo", message: "x")
        let rate = GitHubFailure(kind: "rate-limited", message: "y")
        let repo = GitHubFolderRepo.repo(GitHubRepoRef(nameWithOwner: "a/b"))
        #expect(GitHubRules.pageFailure(.failed(notRepo), overview: nil) == notRepo)
        #expect(GitHubRules.pageFailure(repo, overview: rate) == rate)
        #expect(GitHubRules.pageFailure(.failed(notRepo), overview: rate) == notRepo)
        #expect(GitHubRules.pageFailure(repo, overview: nil) == nil)
        #expect(GitHubRules.pageFailure(nil, overview: nil) == nil)
    }

    @Test func repositoriesAreSummedFilteredAndExplained() {
        let access = GitHubRepoAccessList(repos: repos, atLeast: 2)
        #expect(GitHubRules.accessSummary(access) == "2 repositories")
        #expect(GitHubRules.accessSummary(GitHubRepoAccessList(repos: [repos[0]], atLeast: 1)) == "1 repository")
        #expect(GitHubRules.accessSummary(GitHubRepoAccessList(repos: repos, atLeast: 120, truncated: true)) == "120+ repositories · showing the 2 most recently pushed")
        #expect(GitHubRules.selectionSentence(access) == nil)
        #expect(GitHubRules.selectionSentence(GitHubRepoAccessList(repos: repos, source: "installation", selection: "all"))?.contains("all your repositories") == true)
        #expect(GitHubRules.selectionSentence(GitHubRepoAccessList(repos: repos, source: "installation", selection: "selected"))?.contains("you selected") == true)
        #expect(GitHubRules.filterRepos(repos, query: "DECK").map(\.name) == ["terminaldeck"])
        #expect(GitHubRules.filterRepos(repos, query: "orchestrator").map(\.name) == ["commander"])
        #expect(GitHubRules.filterRepos(repos, query: "   ").count == 2)
        #expect(GitHubRules.repoCount(.list(GitHubRepoAccessList(repos: repos, atLeast: 120, truncated: true))) == "120+")
    }

    @Test func theDeviceCodeCountsDownAndIsSpelledOut() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(GitHubRules.minutesLeft(expiresAt: 1_000_000 + 60_000, now: now) == 1)
        #expect(GitHubRules.minutesLeft(expiresAt: 1_000_000 - 60_000, now: now) == 0)
        #expect(GitHubRules.expiryLine(minutes: 1) == "The code works for about 1 more minute.")
        #expect(GitHubRules.expiryLine(minutes: 0) == "This code has expired — press Connect again for a new one.")
        #expect(GitHubRules.spelled("AB-12") == "A B - 1 2")
    }

    @Test func readsTheEnginesAnswers() throws {
        let auth = GitHubAuthState(json: [
            "connected": true, "source": "gh-cli", "host": "github.com",
            "identity": ["login": "asadev", "name": "Asad Iqbal", "htmlUrl": "https://github.com/asadev", "avatarUrl": NSNull()],
            "scopes": ["repo", "gist"], "scopesReported": true, "ghInstalled": true, "credentialKind": "oauth", "appConfigured": true,
            "installUrl": NSNull(), "disconnect": "Signs out.", "pending": NSNull(), "failure": NSNull(), "expiredCredentialRemoved": false,
            "repo": ["host": "github.com", "owner": "asadev", "name": "x", "nameWithOwner": "asadev/x", "url": "https://github.com/asadev/x", "remote": "origin"],
            "branch": ["name": "main", "detached": false, "head": NSNull()],
            "access": ["ok": true, "repos": [["nameWithOwner": "asadev/x", "name": "x", "private": true]], "atLeast": 1, "truncated": false, "source": "account", "selection": NSNull()],
        ])
        #expect(auth.connected && auth.login == "asadev" && auth.scopes == ["repo", "gist"] && auth.repo?.ref?.nameWithOwner == "asadev/x")
        #expect(auth.branch?.name == "main" && GitHubRules.repoCount(auth.access) == "1")
        #expect(GitHubAuthState(json: nil).failure?.message == "The GitHub bridge did not answer, so your sign-in could not be checked.")
        let result = GitHubResult(json: [
            "ok": true, "limit": 20,
            "pulls": ["ok": true, "value": [["number": 7, "title": "Fix", "url": "u", "badge": "open", "author": "bot", "authorIsBot": true,
                                             "updatedAt": "2026-10-06T11:00:00Z", "review": "approved", "labels": [["name": "bug", "color": "d73a4a"]],
                                             "fromFork": false, "additions": 3, "deletions": NSNull()]]],
            "issues": ["ok": false, "kind": "issues-disabled", "message": "Issues are turned off.", "action": NSNull(), "detail": ""],
        ])
        guard case .overview(let overview) = result, case .rows(let pulls) = overview.pulls, case .failed(let issues) = overview.issues else {
            Issue.record("expected an overview"); return
        }
        #expect(pulls.first?.number == 7 && pulls.first?.deletions == nil && pulls.first?.labels.first?.name == "bug")
        #expect(issues.kind == "issues-disabled")
        #expect(GitHubRules.labelRGB("d73a4a") != nil && GitHubRules.labelRGB("zz") == nil)
        let copilot = GitHubRules.copilotTool(["tools": [["id": "copilot", "label": "GitHub Copilot", "state": "missing", "url": "https://x"]]])
        #expect(copilot?.label == "GitHub Copilot" && copilot?.state == "missing" && GitHubRules.toolStateLabel("missing") == "Not found")
    }
}
