# GitHub, custom-agent and community test map

Source evidence: 6 October 2026. Owner: clients/github_agents. Local source inventory and static review only. No Swift/compiler/build/test runner, CLI probe, app or network request was executed by these tests. This map is the standing-tests-port supplement to `BackendGitHub-HANDOFF.md`; the parent aggregates it without changing other workers' files.

## Counts

| TypeScript file | Cases | Ported | Skipped |
|---|---:|---:|---:|
| `src/main/github.test.ts` | 100 | 100 | 0 |
| `src/main/github-auth.test.ts` | 52 | 51 | 1 |
| `src/main/github-repos.test.ts` | 20 | 20 | 0 |
| `src/main/github-app.test.ts` | 14 | 14 | 0 |
| `src/main/custom-agents.test.ts` | 27 | 22 | 5 |
| `src/main/community-view.test.ts` | 26 | 26 | 0 |
| **Total** | **239** | **233** | **6** |

Written: 87 new XCTest methods in eight parity files plus one shared fake-support file. Run: 0. Existing first-batch tests remain in `BackendGitHubTests.swift` (12), `BackendGitHubAuthenticatorTests.swift` (11), `BackendCustomAgentsTests.swift` (8), `BackendCommunityProjectionTests.swift` (7). Their overlapping grouped checks were read before this pass; the new parity methods make all portable TS expectations explicit, including full payload fields and exact source fixtures. Grouping several related TS cases under one Swift method does not change the 239-case inventory.

## Test map

| TS test file | New Swift test files | Status |
|---|---|---|
| `github.test.ts` | `BackendGitHubParityRules.swift`, `BackendGitHubParityCache.swift`, `BackendGitHubParityService.swift` | 100 ported |
| `github-auth.test.ts` | `BackendGitHubParityAuth.swift`, `BackendGitHubParityService.swift` | 51 ported; 1 Windows-only skip |
| `github-repos.test.ts` | `BackendGitHubParityRepositories.swift` | 20 ported |
| `github-app.test.ts` | `BackendGitHubParityApp.swift` | 14 ported |
| `custom-agents.test.ts` | `BackendCustomAgentsParity.swift` | 22 ported; 5 Windows-only skips |
| `community-view.test.ts` | `BackendCommunityParity.swift` | 26 ported |

All Swift paths are under `macos/TerminalDeckNative/Tests/TerminalDeckBackendTests/`. `BackendGitHubParitySupport.swift` supplies recorded HTTP/argv fakes, a fake clock, continuation latches, and a cancellation-aware controllable sleeper. There are no timer sleeps, spinning waits or real subprocesses. Owned temporary executable-bit fixtures exercise POSIX presence and native custom-agent launch planning without running any executable or inspecting installed CLIs.

The one performance assertion is the source's bounded 800 KB URL-redaction regression: `<2 seconds`, using a stopwatch for the combined performance gate. The parent explicitly authorized retaining that honest stopwatch assertion; faking elapsed time would be vacuous. It is one bounded operation, not a CPU busy loop, and was not run.

Adaptations: native registrar coverage asserts the same eight invoke names plus clear-cache send, with the five auth channels checked as a subset because Swift composes one shared authenticator. The removed notification feature is checked through the declared native channel surface and the overview's exact fields/argv, since Swift cannot reflect exported enum function names like JS Object.keys. Branch/repository cases use fake git stdout/stderr against owned empty folders instead of git init/commit/checkout. Existing launcher resolves a command to its owned fixture path before spawn; the test pins the same fresh/resume argv. The Windows half of custom-agents.test.ts:449 is not applicable; its Mac half is ported. Portable Windows path/argument validation remains ported with a fake lookup.

Known integration follow-up: add the BackendTests SwiftPM target before the combined gate. The parent authorized replacing the worker's own older cache/cancel wait fixtures after `git ls-files` confirmed all three affected files are untracked. Both waits now use continuations; no spin loop or real sleep remains in those worker fixtures. `BackendCommunityNativeProbe` now accepts login-PATH/binary-resolver closures for deterministic tests while retaining its concrete providers-based initializer for the app. Case294 exercises that actual native probe against owned executable-bit files and a fake binary resolver. All six skips below are Windows-only boundaries, never unimplemented portable expectations.

Additional static parity correction: after another read-only `git ls-files` check, the parent authorized fixes only in this worker's untracked GitHubRules/CustomAgents/GitHubTransport files. Repository segments, hostnames, bare binaries, drive-letter prefixes and app slugs now use explicit ASCII classes without Foundation Unicode case folding. Classifier case-insensitive defaults remain as sourced. Remote-URL hosts still lowercase before validation; gh-resolved hosts and app slugs validate before lowercasing, as in TS. Supplemental long-s/Kelvin fixtures pin both refusals and the valid pre-normalized Kelvin remote-host case; Unicode text after a valid ASCII Windows drive remains accepted by the portable grammar. This source review used [ICU's case-folding rules](https://unicode-org.github.io/icu/userguide/strings/regexp.html#case-insensitive-matching), not a runtime probe.

## Per-case mapping

### `src/main/github.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `74` removes userinfo from a remote URL | ported | `BackendGitHubParityRules.testURLCredentialsEveryOccurrenceAndCredentialFreeForms` |
| `80` removes a bare token used as the username | ported | `BackendGitHubParityRules.testURLCredentialsEveryOccurrenceAndCredentialFreeForms` |
| `84` redacts every occurrence in one blob of text | ported | `BackendGitHubParityRules.testURLCredentialsEveryOccurrenceAndCredentialFreeForms` |
| `89` leaves the scp form alone — it carries a username, not a secret | ported | `BackendGitHubParityRules.testURLCredentialsEveryOccurrenceAndCredentialFreeForms` |
| `93` leaves a credential-free URL untouched | ported | `BackendGitHubParityRules.testURLCredentialsEveryOccurrenceAndCredentialFreeForms` |
| `105` stays linear on a large blob with no credentials in it | ported | `BackendGitHubParityRules.testAdversarialBlobAndLateCredentials` |
| `113` still redacts once a real credential appears in a large blob | ported | `BackendGitHubParityRules.testAdversarialBlobAndLateCredentials` |
| `128` caps the raw output it carries | ported | `BackendGitHubParityRules.testDetailCapAndRedactionBeforeCut` |
| `139` redacts before it truncates, so a cut cannot expose the token | ported | `BackendGitHubParityRules.testDetailCapAndRedactionBeforeCut` |
| `150` reads the https form, with and without .git | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `163` reads the scp form that new URL() cannot parse | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `171` reads ssh:// and git:// schemes | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `177` skips credentials when finding the host | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `185` drops the port, which is not part of the repository identity | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `189` tolerates a trailing slash | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `193` keeps a non-GitHub host rather than pretending it is GitHub | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `197` lowercases the host but not the repository name | ported | `BackendGitHubParityRules.testRemoteURLSpellingsCredentialsPortAndCase` |
| `206` refuses paths that are not exactly owner/name | ported | `BackendGitHubParityRules.testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation` |
| `214` handles a local path remote without crashing | ported | `BackendGitHubParityRules.testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation` |
| `223` refuses relative path segments as an owner or name | ported | `BackendGitHubParityRules.testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation` |
| `235` refuses an owner that would read as a command-line flag | ported | `BackendGitHubParityRules.testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation` |
| `239` refuses segments carrying characters GitHub does not allow | ported | `BackendGitHubParityRules.testRemoteURLRejectsUnclearPathsTraversalFlagsAndPunctuation` |
| `249` accepts github.com and its subdomains | ported | `BackendGitHubParityRules.testHostSuffixRequiresADotAndEnterpriseOptIn` |
| `255` rejects a lookalike host | ported | `BackendGitHubParityRules.testHostSuffixRequiresADotAndEnterpriseOptIn` |
| `261` accepts an enterprise host when one is configured | ported | `BackendGitHubParityRules.testHostSuffixRequiresADotAndEnterpriseOptIn` |
| `269` pairs urls with their gh-resolved values | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `284` keeps only the first url of a multi-url remote | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `292` drops a remote that has only a gh-resolved value and no url | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `296` ignores lines that are not remote url or gh-resolved keys | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `303` handles a remote name containing a dot | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `313` does not run past the key when the value itself contains .url | ported | `BackendGitHubParityRules.testRemoteConfigPairsFirstURLOnlyDotsAndUnrelatedKeys` |
| `322` reads the plain owner/repo form gh writes by default | ported | `BackendGitHubParityRules.testResolvedIdentityTwoOrThreePartsAndInvalidForms` |
| `327` reads the host-qualified form | ported | `BackendGitHubParityRules.testResolvedIdentityTwoOrThreePartsAndInvalidForms` |
| `335` refuses anything it cannot read, rather than guessing | ported | `BackendGitHubParityRules.testResolvedIdentityTwoOrThreePartsAndInvalidForms` |
| `350` returns null when no remote points at GitHub | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `354` builds a canonical ref from the parts, not from the raw url | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `366` obeys an explicit gh-resolved owner/repo over the remote url | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `373` prefers the remote marked as base | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `381` falls back to gh’s own remote order: upstream, github, origin | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `392` skips non-GitHub remotes when ranking | ported | `BackendGitHubParityRules.testRepositorySelectionCanonicalDefaultBaseRankingAndFallback` |
| `400` keeps an enterprise host in the ref | ported | `BackendGitHubParityRules.testEnterpriseDefaultAndUnapprovedHostAreNotMangled` |
| `416` reads a host-qualified gh-resolved value without mangling it | ported | `BackendGitHubParityRules.testEnterpriseDefaultAndUnapprovedHostAreNotMangled` |
| `427` ignores a gh-resolved value it cannot parse | ported | `BackendGitHubParityRules.testEnterpriseDefaultAndUnapprovedHostAreNotMangled` |
| `437` refuses a gh-resolved host that is not a GitHub host | ported | `BackendGitHubParityRules.testEnterpriseDefaultAndUnapprovedHostAreNotMangled` |
| `449` reports a missing gh binary from the spawn errno | ported | `BackendGitHubParityRules.testClassifierSpawnTimeoutNetworkAndDisabledIssues` |
| `465` reads a repository with issues switched off as a setting, not an error | ported | `BackendGitHubParityRules.testClassifierSpawnTimeoutNetworkAndDisabledIssues` |
| `474` reports a killed process as a timeout, not a generic failure | ported | `BackendGitHubParityRules.testClassifierSpawnTimeoutNetworkAndDisabledIssues` |
| `479` recognises Go’s transport errors as the network being down | ported | `BackendGitHubParityRules.testClassifierSpawnTimeoutNetworkAndDisabledIssues` |
| `489` separates never-signed-in from an expired token | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `500` gives "not authenticated" and "no GitHub remote" different, actionable text | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `511` separates the three local git problems | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `518` reports a rate limit rather than a permission problem | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `528` names the scope the token is missing, and the command that adds it | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `541` reports a vanished or private repository distinctly from a permission error | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `548` falls back to a plain failure it does not pretend to understand | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `556` redacts credentials out of the detail it keeps | ported | `BackendGitHubParityRules.testClassifierAuthenticationLocalGitRateScopesAccessAndUnknown` |
| `568` reads draft, open and closed from the CLI’s uppercase states | ported | `BackendGitHubParityRules.testPullBadgesAllStatesAndMergedTimestampPrecedence` |
| `580` treats a closed PR with a merge timestamp as merged | ported | `BackendGitHubParityRules.testPullBadgesAllStatesAndMergedTimestampPrecedence` |
| `584` defaults to open when gh reports no state at all | ported | `BackendGitHubParityRules.testPullBadgesAllStatesAndMergedTimestampPrecedence` |
| `608` maps a real gh pr list row | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `628` flags a bot author, as gh reports app/dependabot | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `634` maps every review decision, and null when there is none | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `642` survives a row with a deleted author account | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `650` refuses a label colour that is not six hex digits | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `659` drops a row with no number or url instead of rendering a dead link | ported | `BackendGitHubParityRules.testRealPullRowEveryFieldBotReviewsDeletedAuthorAndColor` |
| `679` maps a real gh issue list row | ported | `BackendGitHubParityRules.testIssueRowReasonsAndMissingAssigneeLogins` |
| `686` reads why a closed issue closed | ported | `BackendGitHubParityRules.testIssueRowReasonsAndMissingAssigneeLogins` |
| `693` ignores assignees with no login rather than rendering blanks | ported | `BackendGitHubParityRules.testIssueRowReasonsAndMissingAssigneeLogins` |
| `701` defaults, floors and clamps whatever arrives over IPC | ported | `BackendGitHubParityRules.testLimitDefaultFloorAndBoundEveryInputShape` |
| `717` serves the second call from cache instead of running the loader again | ported | `BackendGitHubParityCache.testSecondReadAndConcurrentReadsUseOneLoader` |
| `732` collapses concurrent calls for the same key onto one loader | ported | `BackendGitHubParityCache.testSecondReadAndConcurrentReadsUseOneLoader` |
| `753` re-runs the loader once the entry has expired | ported | `BackendGitHubParityCache.testExpiredZeroTtlAndRefreshActuallyRunAgain` |
| `761` bypasses a live entry when refresh is asked for | ported | `BackendGitHubParityCache.testExpiredZeroTtlAndRefreshActuallyRunAgain` |
| `768` lets a failing loader reject without poisoning the key | ported | `BackendGitHubParityCache.testFailedLoaderDoesNotPoisonKey` |
| `775` drops entries on clear | ported | `BackendGitHubParityCache.testWholeClearAndPrefixClearKeepOtherKeys` |
| `784` clears only the keys under a prefix when one is given | ported | `BackendGitHubParityCache.testWholeClearAndPrefixClearKeepOtherKeys` |
| `798` drops in-flight work under the prefix too, not just cached values | ported | `BackendGitHubParityCache.testPrefixClearDisownsInflightAndKeepsFreshResult` |
| `819` lets the newest loader win, not the slowest | ported | `BackendGitHubParityCache.testRefreshNewestLoaderWinsNotSlowestCompletion` |
| `837` evicts the oldest entries instead of growing without bound | ported | `BackendGitHubParityCache.testTwoHundredEntryBoundEvictsOldestAndKeepsRecent` |
| `855` reclaims entries that have expired rather than keeping the corpses | ported | `BackendGitHubParityCache.testExpiredCorpsesCannotEvictLiveEntry` |
| `884` separates two repositories with the same name on different hosts | ported | `BackendGitHubParityRules.testSectionIdentityAndArgvNeverContainCommentsOrNotifications` |
| `890` separates sections, and lists fetched at different limits | ported | `BackendGitHubParityRules.testSectionIdentityAndArgvNeverContainCommentsOrNotifications` |
| `913` passes the repository as one argv element, so no shell is involved | ported | `BackendGitHubParityRules.testSectionIdentityAndArgvNeverContainCommentsOrNotifications` |
| `923` qualifies the repository with its host off github.com | ported | `BackendGitHubParityRules.testSectionIdentityAndArgvNeverContainCommentsOrNotifications` |
| `952` exports nothing that fetches, counts or excuses them | ported | `BackendGitHubParityService.testOverviewHasOnlyPullsIssuesAndNoNotificationRequests` |
| `967` reads GitHub’s wrong-credential-kind refusal as the access problem it now is | ported | `BackendGitHubParityRules.testSectionIdentityAndArgvNeverContainCommentsOrNotifications` |
| `997` rejects a relative path before spawning anything | ported | `BackendGitHubParityService.testRelativeAndGoneFolderRejectedBeforeAnyTool` |
| `1002` reports a folder that no longer exists as such, not as a missing git | ported | `BackendGitHubParityService.testRelativeAndGoneFolderRejectedBeforeAnyTool` |
| `1007` reports a plain folder as not a repository | ported | `BackendGitHubParityService.testPlainFolderHasSourceControlAdviceAndNoAction` |
| `1028` reports a repository with no remotes distinctly from one with no GitHub remote | ported | `BackendGitHubParityService.testNoRemoteAndNonGithubRemoteStayDistinct` |
| `1045` resolves a GitHub remote to a canonical ref | ported | `BackendGitHubParityService.testCanonicalRepoAndTokenInNonGithubRemoteNeverLeaks` |
| `1060` never leaks a token embedded in a remote URL | ported | `BackendGitHubParityService.testCanonicalRepoAndTokenInNonGithubRemoteNeverLeaks` |
| `1093` names the branch of an ordinary checkout | ported | `BackendGitHubParityService.testBranchOrdinaryAndUnbornUseSymbolicRefOnly` |
| `1108` names the branch of a repository with no commits yet | ported | `BackendGitHubParityService.testBranchOrdinaryAndUnbornUseSymbolicRefOnly` |
| `1122` reports a detached HEAD as detached, with the commit it is on | ported | `BackendGitHubParityService.testDetachedHeadUsesSecondCommandAndNonRepoDoesNot` |
| `1139` answers null for a folder that is not a repository | ported | `BackendGitHubParityService.testDetachedHeadUsesSecondCommandAndNonRepoDoesNot` |
| `1148` answers null for a path that is not absolute | ported | `BackendGitHubParityService.testDetachedHeadUsesSecondCommandAndNonRepoDoesNot` |
| `1181` registers every channel the preload bridge calls | ported | `BackendGitHubParityService.testEveryPanelChannelAuthSubsetBadArgumentsAndClearSend` |
| `1198` answers a non-absolute path with a typed failure | ported | `BackendGitHubParityService.testEveryPanelChannelAuthSubsetBadArgumentsAndClearSend` |
| `1211` clears the cache without a folder argument | ported | `BackendGitHubParityService.testEveryPanelChannelAuthSubsetBadArgumentsAndClearSend` |

### `src/main/github-auth.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `257` splits the header GitHub actually sends | ported | `BackendGitHubParityAuth.testScopeParsingAndReportedHeaderWithoutRequestedPermissionJudgement` |
| `267` reports an absent header as no scopes, for the caller to interpret | ported | `BackendGitHubParityAuth.testScopeParsingAndReportedHeaderWithoutRequestedPermissionJudgement` |
| `285` reports what a credential carries without judging it against a request | ported | `BackendGitHubParityAuth.testScopeParsingAndReportedHeaderWithoutRequestedPermissionJudgement` |
| `304` 1. no gh and no credential: connect here, and do not blame the CLI | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `317` 2. gh installed but logged out: both routes offered, neither hidden | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `327` 3. signed in through gh, with whatever scopes that login happens to carry | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `347` 4. signed in, with the folder resolved beside the account | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `356` 5. the folder is not a repository, and that is not a sign-in problem | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `374` 6. the repository has no GitHub remote | ported | `BackendGitHubParityAuth.testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect` |
| `394` gives every state its own sentence | ported | `BackendGitHubParityAuth.testDisconnectedStateSentencesStayDistinct` |
| `439` does not answer a second look from a cached failure | ported | `BackendGitHubParityAuth.testFailedLoginIsRereadAndSuccessfulConnectionCacheIsReal` |
| `465` serves a working connection from the cache rather than re-asking GitHub | ported | `BackendGitHubParityAuth.testFailedLoginIsRereadAndSuccessfulConnectionCacheIsReal` |
| `490` does not cache a connection whose repository list failed | ported | `BackendGitHubParityAuth.testFailedLoginIsRereadAndSuccessfulConnectionCacheIsReal` |
| `514` reports the environment token even when one is stored | ported | `BackendGitHubParityAuth.testEnvironmentWinsStoredCredentialAndCLIIsReused` |
| `530` reuses an existing gh login rather than asking for a second one | ported | `BackendGitHubParityAuth.testEnvironmentWinsStoredCredentialAndCLIIsReused` |
| `543` strips every token variable out of the environment gh is probed with | ported | `BackendGitHubParityAuth.testProbeEnvironmentStripsAllFourTokenVariablesAndPreservesIdentity` |
| `570` gives gh the token it stored, but never overrides one already in the env | ported | `BackendGitHubParityAuth.testEnvironmentWinsStoredCredentialAndCLIIsReused` |
| `646` hands back a code to show before anything is signed in | ported | `BackendGitHubParityAuth.testPromptIsAvailableBeforeSignInAndCancellationLeavesNothing` |
| `675` refuses to start a sign-in a build with no registration cannot finish | ported | `BackendGitHubParityAuth.testNoRegistrationRefusesBeforeNetworkAndNamesBothEscapeRoutes` |
| `687` keeps polling through authorization_pending and stores the token | ported | `BackendGitHubParityAuth.testAuthorizationPendingStorageModeAndSlowDownIntervals` |
| `738` refuses to store a credential this PC would not lock down, and says why | skipped | Windows-only icacls/PC safe-storage refusal; no Windows secret-file writer exists on the Mac. |
| `766` obeys slow_down instead of hammering | ported | `BackendGitHubParityAuth.testAuthorizationPendingStorageModeAndSlowDownIntervals` |
| `809` says the code expired, and says it differently from a refusal | ported | `BackendGitHubParityAuth.testExpiredAndDeclinedFlowsHaveDifferentReasonsAndApp404NamesCheckbox` |
| `851` names the app and the Device Flow checkbox when GitHub will not start a flow | ported | `BackendGitHubParityAuth.testExpiredAndDeclinedFlowsHaveDifferentReasonsAndApp404NamesCheckbox` |
| `863` cancelling leaves nothing behind and nothing signed in | ported | `BackendGitHubParityAuth.testPromptIsAvailableBeforeSignInAndCancellationLeavesNothing` |
| `877` deletes the credential this app stored | ported | `BackendGitHubParityAuth.testStoredDisconnectAndCLIUserLogoutAreRealDifferentOperations` |
| `889` signs the CLI out when the credential is the CLI’s, and says so first | ported | `BackendGitHubParityAuth.testStoredDisconnectAndCLIUserLogoutAreRealDifferentOperations` |
| `920` drops its own expired credential and falls through to gh | ported | `BackendGitHubParityAuth.testExpiredStoredCredentialFallsThroughToWorkingCLI` |
| `953` keeps the token out of every field of a rejected sign-in | ported | `BackendGitHubParityAuth.testRejectedEnvironmentStoredAndCLITokensNeverLeaveStatusOrScrubbedOutput` |
| `973` keeps the stored token out of a status payload | ported | `BackendGitHubParityAuth.testRejectedEnvironmentStoredAndCLITokensNeverLeaveStatusOrScrubbedOutput` |
| `987` strips the live credential out of somebody else’s output | ported | `BackendGitHubParityAuth.testRejectedEnvironmentStoredAndCLITokensNeverLeaveStatusOrScrubbedOutput` |
| `1020` registers every channel the preload bridge calls | ported | `BackendGitHubParityService.testEveryPanelChannelAuthSubsetBadArgumentsAndClearSend` |
| `1046` carries the reason a refused sign-in failed into the next status | ported | `BackendGitHubParityAuth.testFlowReasonSurvivesRegisteredStatusChannel` |
| `1081` names the repositories the credential can reach | ported | `BackendGitHubParityAuth.testAccessSuccessIndependentFailureParallelRequestsAndSeparateCache` |
| `1102` stays connected when the list itself fails | ported | `BackendGitHubParityAuth.testAccessSuccessIndependentFailureParallelRequestsAndSeparateCache` |
| `1126` asks for both at once rather than one after the other | ported | `BackendGitHubParityAuth.testAccessSuccessIndependentFailureParallelRequestsAndSeparateCache` |
| `1144` does not re-ask GitHub for a list it fetched a moment ago | ported | `BackendGitHubParityAuth.testAccessSuccessIndependentFailureParallelRequestsAndSeparateCache` |
| `1158` reports the folder’s branch beside its repository | ported | `BackendGitHubParityAuth.testFolderBranchAndNoFolderHaveExactNullShapes` |
| `1171` has no branch and no repository when no folder was named | ported | `BackendGitHubParityAuth.testFolderBranchAndNoFolderHaveExactNullShapes` |
| `1199` sends a client id and nothing else | ported | `BackendGitHubParityAuth.testConsentBodyShippingAppAndRecordedDevicePrompt` |
| `1224` never sends the GitHub CLI’s client id | ported | `BackendGitHubParityAuth.testConsentBodyShippingAppAndRecordedDevicePrompt` |
| `1242` signs in as this app, in a shipping build | ported | `BackendGitHubParityAuth.testConsentBodyShippingAppAndRecordedDevicePrompt` |
| `1266` reports a build with no registration as unable to sign in here | ported | `BackendGitHubParityAuth.testNoRegistrationRefusesBeforeNetworkAndNamesBothEscapeRoutes` |
| `1308` turns the live registration’s real answer into a prompt | ported | `BackendGitHubParityAuth.testConsentBodyShippingAppAndRecordedDevicePrompt` |
| `1346` asks for no scopes at all, because the app registration holds them | ported | `BackendGitHubParityAuth.testEnvironmentAppOverrideNoScopesAndInstallationLink` |
| `1357` hands the user the install screen where repositories are chosen | ported | `BackendGitHubParityAuth.testEnvironmentAppOverrideNoScopesAndInstallationLink` |
| `1375` treats a token past its stated expiry as expired without asking GitHub | ported | `BackendGitHubParityAuth.testLocalExpiryNoNetworkAndLegacyKindsSurviveUntilRejected` |
| `1434` keeps working, and is still listed through the endpoint it was issued for | ported | `BackendGitHubParityAuth.testLocalExpiryNoNetworkAndLegacyKindsSurviveUntilRejected` |
| `1455` reads a file with no recorded kind as the classic one it is | ported | `BackendGitHubParityAuth.testLocalExpiryNoNetworkAndLegacyKindsSurviveUntilRejected` |
| `1473` is deleted, with a sentence, the moment GitHub rejects it | ported | `BackendGitHubParityAuth.testLocalExpiryNoNetworkAndLegacyKindsSurviveUntilRejected` |
| `1495` records a fresh sign-in as a GitHub App credential | ported | `BackendGitHubParityAuth.testAuthorizationPendingStorageModeAndSlowDownIntervals` |
| `1522` keeps the CLI’s token out of a failed repository listing | ported | `BackendGitHubParityAuth.testRejectedEnvironmentStoredAndCLITokensNeverLeaveStatusOrScrubbedOutput` |

### `src/main/github-repos.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `103` finds the last page in a real header whose URLs contain commas | ported | `BackendGitHubParityRepositories.testRealCommaContainingPaginationHeaderAndBounds` |
| `107` answers null when there is no pagination at all | ported | `BackendGitHubParityRepositories.testRealCommaContainingPaginationHeaderAndBounds` |
| `117` turns a page count into a lower bound, never into a total | ported | `BackendGitHubParityRepositories.testRealCommaContainingPaginationHeaderAndBounds` |
| `125` keeps the six fields the panel shows and drops the kilobyte of URLs | ported | `BackendGitHubParityRepositories.testRealRepositoryAllFieldsAndOrphanRows` |
| `143` refuses a row without a usable owner/name | ported | `BackendGitHubParityRepositories.testRealRepositoryAllFieldsAndOrphanRows` |
| `150` rebuilds a missing web URL rather than rendering a dead row | ported | `BackendGitHubParityRepositories.testRealRepositoryAllFieldsAndOrphanRows` |
| `156` puts an enterprise API under /api/v3 and github.com on api.github.com | ported | `BackendGitHubParityRepositories.testEnterpriseAndExplicitOrganizationEndpoints` |
| `163` asks for organisation repositories explicitly rather than trusting the default | ported | `BackendGitHubParityRepositories.testEnterpriseAndExplicitOrganizationEndpoints` |
| `173` reports one full page as truncated with an honest lower bound | ported | `BackendGitHubParityRepositories.testFullFirstPageHonestLowerBoundAndBearerAuthorization` |
| `195` reports a single short page as the whole list | ported | `BackendGitHubParityRepositories.testShortPageIsWholeList` |
| `202` reads a revoked token as an expired sign-in, not as a broken list | ported | `BackendGitHubParityRepositories.testAccountExpiredRateLimitPlainRefusalMalformedAndSecret` |
| `214` names the rate limit and when it lifts | ported | `BackendGitHubParityRepositories.testAccountExpiredRateLimitPlainRefusalMalformedAndSecret` |
| `227` tells a rate limit apart from a plain refusal | ported | `BackendGitHubParityRepositories.testAccountExpiredRateLimitPlainRefusalMalformedAndSecret` |
| `233` reports an unreachable host rather than throwing across the boundary | ported | `BackendGitHubParityRepositories.testUnreachableHostReturnsTypedFailure` |
| `242` survives a body that is not the array it promised | ported | `BackendGitHubParityRepositories.testAccountExpiredRateLimitPlainRefusalMalformedAndSecret` |
| `254` never carries the token into the failure it hands back | ported | `BackendGitHubParityRepositories.testAccountExpiredRateLimitPlainRefusalMalformedAndSecret` |
| `279` reads the repositories chosen at install time, and says they were chosen | ported | `BackendGitHubParityRepositories.testSelectedInstallationCountAndExactSecondURL` |
| `301` explains an account with no installation instead of showing nothing | ported | `BackendGitHubParityRepositories.testNoInstallationExplainsFixAndNeverFallsBack` |
| `314` never falls back to the whole-account listing when the app listing fails | ported | `BackendGitHubParityRepositories.testNoInstallationExplainsFixAndNeverFallsBack` |
| `322` routes an OAuth credential to the account endpoint instead | ported | `BackendGitHubParityRepositories.testOAuthCredentialUsesAccountEndpoint` |

### `src/main/github-app.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `60` holds the client id that was proven to start a device flow | ported | `BackendGitHubParityApp.testShippingVerifiedClientSlugAndConfiguredState` |
| `74` holds a slug that builds the install screen | ported | `BackendGitHubParityApp.testShippingVerifiedClientSlugAndConfiguredState` |
| `86` makes a shipping build able to sign in with no configuration at all | ported | `BackendGitHubParityApp.testShippingVerifiedClientSlugAndConfiguredState` |
| `98` reports a build with no registration as unconfigured | ported | `BackendGitHubParityApp.testShippingVerifiedClientSlugAndConfiguredState` |
| `113` names both ways into a build that has no registration | ported | `BackendGitHubParityApp.testUnconfiguredReasonAndExactEnvironmentNames` |
| `124` keeps the two override names a fork needs | ported | `BackendGitHubParityApp.testUnconfiguredReasonAndExactEnvironmentNames` |
| `131` takes the client id and slug from the environment | ported | `BackendGitHubParityApp.testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug` |
| `141` overrides the registration compiled into the build | ported | `BackendGitHubParityApp.testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug` |
| `146` trims, and treats whitespace as absent rather than as a client id | ported | `BackendGitHubParityApp.testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug` |
| `170` falls through a blank override to the built-in rather than clearing it | ported | `BackendGitHubParityApp.testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug` |
| `182` ignores a slug with no client id beside it | ported | `BackendGitHubParityApp.testEnvironmentOverridesTrimAndBlankFallbackWithoutOrphanSlug` |
| `191` points at the install screen where repositories are chosen | ported | `BackendGitHubParityApp.testInstallURLHostAndEveryMalformedSlug` |
| `198` stays on the host it was given | ported | `BackendGitHubParityApp.testInstallURLHostAndEveryMalformedSlug` |
| `205` refuses anything that is not a slug | ported | `BackendGitHubParityApp.testInstallURLHostAndEveryMalformedSlug` |

### `src/main/custom-agents.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `54` refuses a command this machine cannot run, and says which command | ported | `BackendCustomAgentsParity.testMissingCommandNeverWritesAndResolvedEvidenceIsStored` |
| `72` records where the command resolved, as the evidence for the entry | ported | `BackendCustomAgentsParity.testMissingCommandNeverWritesAndResolvedEvidenceIsStored` |
| `86` splits arguments the way the form previewed them | ported | `BackendCustomAgentsParity.testQuotedArgsBuiltinAndCustomDuplicateAndCommandLineRefusal` |
| `105` will not take a name a shipped agent already has | ported | `BackendCustomAgentsParity.testQuotedArgsBuiltinAndCustomDuplicateAndCommandLineRefusal` |
| `117` will not take a name another added agent already has | ported | `BackendCustomAgentsParity.testQuotedArgsBuiltinAndCustomDuplicateAndCommandLineRefusal` |
| `127` refuses a command line where a command belongs | ported | `BackendCustomAgentsParity.testQuotedArgsBuiltinAndCustomDuplicateAndCommandLineRefusal` |
| `139` stops at the cap rather than growing a file the app reads at every start | ported | `BackendCustomAgentsParity.testThirtyTwoAgentCap` |
| `187` takes an absolute Windows path, which the backslash ban used to refuse | ported | `BackendCustomAgentsParity.testPortableWindowsPathAndArgumentGrammarUsingFakeLookup` |
| `197` takes a path as an argument, which most Windows arguments are | ported | `BackendCustomAgentsParity.testPortableWindowsPathAndArgumentGrammarUsingFakeLookup` |
| `207` still refuses a UNC path, which is a launch off somebody else’s file server | ported | `BackendCustomAgentsParity.testUncRelativeAndCommandProcessorInstructionsStillRefused` |
| `221` still refuses a relative path with a separator in it | ported | `BackendCustomAgentsParity.testUncRelativeAndCommandProcessorInstructionsStillRefused` |
| `231` still refuses what cmd.exe would read as an instruction | ported | `BackendCustomAgentsParity.testUncRelativeAndCommandProcessorInstructionsStillRefused` |
| `250` goes through cmd.exe and through wsl.exe exactly as a shipped agent does | skipped | Windows-only cmd.exe and WSL launch wrappers; native Mac launch is covered separately. |
| `312` takes a path whose extension PATHEXT names | skipped | Windows-only PATHEXT execution extensions. |
| `319` refuses a file Windows would never run, however readable it is | skipped | Windows-only access(X_OK) fallback semantics. |
| `326` falls back to the four Windows itself falls back to, rather than to anything | skipped | Windows-only default PATHEXT list. |
| `333` reads PATHEXT however the environment spelled it | skipped | Windows-only case-insensitive PATHEXT environment. |
| `340` asks none of this on POSIX, where an extension means nothing | ported | `BackendCustomAgentsParity.testPosixExecutablePresenceUsesOnlyOwnedFixtureFiles` |
| `351` refuses a file with no execute bit on POSIX | ported | `BackendCustomAgentsParity.testPosixExecutablePresenceUsesOnlyOwnedFixtureFiles` |
| `359` survives a restart | ported | `BackendCustomAgentsParity.testRestartDoesNotReprobeAndBadDiskRowIsDroppedAlone` |
| `374` drops one bad entry rather than the whole list | ported | `BackendCustomAgentsParity.testRestartDoesNotReprobeAndBadDiskRowIsDroppedAlone` |
| `400` reads an unreadable file as no agents rather than throwing at launch | ported | `BackendCustomAgentsParity.testUnreadableFileIsEmptyAndRemovalTouchesOnlyRequestedRow` |
| `408` forgets one on request, and only that one | ported | `BackendCustomAgentsParity.testUnreadableFileIsEmptyAndRemovalTouchesOnlyRequestedRow` |
| `422` withdraws every feature nobody has measured, rather than claiming it | ported | `BackendCustomAgentsParity.testCatalogueWithdrawsEveryUnmeasuredFeatureWithEvidence` |
| `449` spawns through the same launcher the shipped agents do | ported | `BackendCustomAgentsParity.testNativeLauncherReadsSameAgentAndNoResumeStaysEmpty` (Mac half; Windows wrapper half not applicable) |
| `469` offers no resume when no resume arguments were given | ported | `BackendCustomAgentsParity.testNativeLauncherReadsSameAgentAndNoResumeStaysEmpty` |
| `483` registers the three channels the preload calls, and no bulk write | ported | `BackendCustomAgentsParity.testExactThreeChannelsNoBulkWriteAndRemoveRejectsBuiltinOrNumber` |

### `src/main/community-view.test.ts`

| TS line and case | Status | Swift method or skip reason |
|---|---|---|
| `89` names a runtime this machine does not have | ported | `BackendCommunityParity.testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds` |
| `93` says nothing about a runtime that is here | ported | `BackendCommunityParity.testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds` |
| `97` never reports runs-scripts as missing, because it is not a thing to install | ported | `BackendCommunityParity.testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds` |
| `101` never reports a key or an account as missing — those are five minutes away | ported | `BackendCommunityParity.testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds` |
| `105` says nothing about local-app, because the row never names which program | ported | `BackendCommunityParity.testMissingRuntimeAndPresentRuntimeButNoHumanOrScriptNeeds` |
| `111` points at the publisher on the host the commit is pinned on | ported | `BackendCommunityParity.testPublisherURLComesFromPinnedHostOrIsAbsent` |
| `115` draws no link at all rather than one to nowhere | ported | `BackendCommunityParity.testPublisherURLComesFromPinnedHostOrIsAbsent` |
| `122` is the sentence this app already prints when an agent is missing | ported | `BackendCommunityParity.testAgentLinesAreMeasuredAndUndefinedIsNotGuessed` |
| `126` is empty for an agent that is here and working | ported | `BackendCommunityParity.testAgentLinesAreMeasuredAndUndefinedIsNotGuessed` |
| `130` is empty rather than a guess when there is no answer at all | ported | `BackendCommunityParity.testAgentLinesAreMeasuredAndUndefinedIsNotGuessed` |
| `138` draws the repository’s own push date, never the listing’s | ported | `BackendCommunityParity.testRepositoryOwnPushDateAndMissingStatsHaveExactFields` |
| `149` draws no date and no counts when the indexer had none | ported | `BackendCommunityParity.testRepositoryOwnPushDateAndMissingStatsHaveExactFields` |
| `156` names the folders for the agents that are here and claimed, and no others | ported | `BackendCommunityParity.testFirstProjectionNamesOwnFolderWithBlankHomesAndClaimedAgentsOnly` |
| `162` composes the mcp command in our own code and never takes one from the row | ported | `BackendCommunityParity.testPythonMcpCommandAndSecretVariableNamesOnly` |
| `177` asks for variable names and never values | ported | `BackendCommunityParity.testPythonMcpCommandAndSecretVariableNamesOnly` |
| `200` carries the withdrawal reason and the state’s own sentence as one string | ported | `BackendCommunityParity.testWithdrawalSentenceDamageReasonInstalledVersionAndNoInventedRatings` |
| `210` leaves the reason empty for anything not withdrawn | ported | `BackendCommunityParity.testWithdrawalSentenceDamageReasonInstalledVersionAndNoInventedRatings` |
| `216` says installed by naming the version on this disk, not by a state word | ported | `BackendCommunityParity.testWithdrawalSentenceDamageReasonInstalledVersionAndNoInventedRatings` |
| `221` invents no rating, because nobody has rated anything yet | ported | `BackendCommunityParity.testWithdrawalSentenceDamageReasonInstalledVersionAndNoInventedRatings` |
| `242` names all three agents whatever is on the machine | ported | `BackendCommunityParity.testWholeViewEveryAgentAndExactRealHomesOnlyForFoundOnes` |
| `249` puts the real homes into the folders an install would write | ported | `BackendCommunityParity.testWholeViewEveryAgentAndExactRealHomesOnlyForFoundOnes` |
| `258` turns null into the empty strings the screen narrows for | ported | `BackendCommunityParity.testWholeViewNullFieldsKeptReasonAndMissingCatalogueError` |
| `266` reports a kept list as kept, with the reason it could not be refreshed | ported | `BackendCommunityParity.testWholeViewNullFieldsKeptReasonAndMissingCatalogueError` |
| `276` turns no catalogue at all into one sentence, never a blank shelf | ported | `BackendCommunityParity.testWholeViewNullFieldsKeptReasonAndMissingCatalogueError` |
| `287` still says something when the main half answered ok with no reason | ported | `BackendCommunityParity.testWholeViewNullFieldsKeptReasonAndMissingCatalogueError` |
| `294` answers about this machine without throwing | ported | `BackendCommunityParity.testNativeProbeContractWithFixturePathAndFakeBinaryResolver` |
