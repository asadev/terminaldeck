# Clients worker handoff: GitHub, custom agents, community projection

Owner: clients/github_agents. Parent: clients. Evidence: 6 October 2026, 16:30 Dubai (12:30 UTC), source/static review only. Local files; nothing wired into the running app. No builds, tests, app starts, live-data access, credential reads, git operations or network requests were performed.

## Stable scoped checklist

1. 🟢 `github.ts` source port written; static comparison completed.
2. 🟢 `github-auth.ts` source port written; static comparison completed.
3. 🟢 `github-repos.ts` source port written; static comparison completed.
4. 🟢 `github-app.ts` source port written; static comparison completed.
5. 🟢 `custom-agents.ts` source port written; static comparison completed.
6. 🟢 `community-view.ts` source port written; static comparison completed.

Total scoped modules: 6. Written/static-reviewed: 6; in progress: 0; blocked: 0; queued: 0. Runtime-verified modules: 0. Integration and combined gate are pending outside this worker's file ownership. Tests: 38 written, 0 run, across four new files.

## Module mapping

| TypeScript module | New Swift files and types | Behavior covered |
|---|---|---|
| `src/main/github.ts` | `BackendGitHubRules.swift` (`BackendGitHubRules`, `BackendGitHubCache`), `BackendGitHubService.swift` (`BackendGitHubService`, `BackendGitHubChannels`) | Local remote config/URL/default resolution, branch/detached reads, distinct failure classifier, secret scrubbing before 4,000 UTF-16 detail limit, PR/issue mapping, exact gh arguments/field lists, 1–100 limits, 60s/15s cache TTLs, 200-entry bound, concurrent join and stale-writer prevention, panel IPC |
| `src/main/github-auth.ts` | `BackendGitHubAuthenticator.swift` (`BackendGitHubAuthenticator`), `BackendGitHubTransport.swift` (`BackendGitHubHTTPFetching`, `BackendGitHubToolRunning`, concrete native adapters and private auth-detail redactor) | Environment → stored → gh precedence, stripped gh probe env, one host-owned authenticator, identity/access caches, parallel identity/access and repo/branch, cancellable device polling with first wait/slow_down, local expiry, disconnect outcomes, unchanged credential schema, exact-match secrets and internal git credentials |
| `src/main/github-repos.ts` | `BackendGitHubRepositories.swift` (`BackendGitHubRepositories`) | Public/enterprise roots, first-page account listing, first GitHub App installation listing with no account fallback, real lower-bound pagination, selected/all grant reporting, independent repository errors, token-scrubbed details |
| `src/main/github-app.ts` | `BackendGitHubTransport.swift` (`BackendGitHubAppRegistration`) | Shipping public client ID/slug, exact override env names, blank override fallback, absent registration refusal, host-specific installation URL; no borrowed OAuth client or scope request |
| `src/main/custom-agents.ts` | `BackendCustomAgents.swift` (`BackendCustomAgentsRules`, `BackendCustomAgentsStore`, `BackendCustomAgentsChannels`) | Shared splitter reused, revalidation and login-PATH executable lookup, duplicate labels/IDs, 32-agent cap, 256Ki UTF-16 load ceiling, atomic commit-after-write, version-1 JSON, restored entries, targeted removal, withdrawn unmeasured capabilities |
| `src/main/community-view.ts` | `BackendCommunityProjection.swift` (`BackendCommunityProjection`, `BackendCommunityNativeProbe`, supplier protocols, `BackendCommunityChannels`) | Flattened StoreView/StoreItemView projection, measured runtimes/agents, exact notes, publisher-host URLs, repository push dates/counts, no invented ratings/offsite/trigger, derived MCP command/variable names, same landing-path table, withdrawal messages, kept/stale failures. Included small `store-install-ipc.ts` channel/readChoice adapter around a supplied real installer. |

Supporting shared TS custom-agent validation was ported where no backend equivalent existed; existing `NewSessionAddAgent.splitArgs`, `NewSessionCustomAgent.isCustom`, `NewSessionProviders.customLoginsNote`, `CodingAICatalog`, `NativeRPCValue`, `NativeChannelRegistry`, `BackendNativeProviders.Binary/lookup`, `BackendDevProcessExecutor` and `BackendAccountFiles.writeAtomic` are reused. No parallel versions of those native types were created.

Windows `PATHEXT`, `where.exe`, cmd.exe/WSL launch branches and Windows secret-file ACLs: not applicable on Mac. Portable drive-letter strings remain accepted by the stored custom-agent grammar; real Mac lookup refuses them. General community extension metadata remains readable in the projection, while Chrome extension execution/installation is retired by Asad's Chrome removal; `NativeCommunityDepartment` already removes extension rows and the installer supplier must refuse that retired path.

## Required composition and exact registrations

Construct these once after exclusive ownership transfer from Node, using the app's selected data directory (`TD_NATIVE_DATA_DIR` for the combined gate; production remains `~/Library/Application Support/terminaldeck`). Never construct another credential owner for git or remote devices.

```swift
let tools = BackendGitHubNativeTools(home: home, loginPath: { try await providers.loginPath() })
let cache = BackendGitHubCache()
let github = BackendGitHubService(environment: inheritedEnvironment, tools: tools, cache: cache)
let auth = try BackendGitHubAuthenticator(
    dataDirectory: dataRoot, environment: inheritedEnvironment, tools: tools,
    resolveRepo: { await github.resolveRepo($0) },
    resolveBranch: { await github.readBranch($0) },
    onAuthChanged: { await cache.clear() })
let githubClearSubscription = try await BackendGitHubChannels.register(
    registry: registry, ownerID: ownerID, service: github, auth: auth)
let customAgents = try BackendCustomAgentsStore(
    dataDirectory: dataRoot,
    lookup: BackendCustomAgentsStore.nativeLookup(loginPath: { try await providers.loginPath() }))
_ = try await BackendCustomAgentsChannels.register(registry: registry, ownerID: ownerID, store: customAgents)
let probe = BackendCommunityNativeProbe(providers: providers)
_ = try await BackendCommunityChannels.register(
    registry: registry, ownerID: ownerID, store: communityInstaller,
    userData: dataRoot.path, probe: probe, emptyHomes: realAgentHomes)
```

Retain `githubClearSubscription` for the app lifetime. Without retention the existing subscription type cancels in deinit. On shutdown call `await auth.shutdown()` and cancel that subscription; shutdown does not delete credentials. Supply `auth.gitCredential()`, `auth.toolToken()` and `auth.scrubSecrets(_:)` only internally to the Git/remote-host tool environment and credential adapters. Those secrets are never UI values or channels. `BackendGitHubChannels.register` names the same authenticator on the service; there is no module-global duplicate singleton.

Invoke channels (14): `github:overview(cwd, options)`, `github:refresh(cwd, options)`, `github:repo(cwd)`, `github:auth-status(cwd?)`, `github:auth-connect()`, `github:auth-await(cwd?)`, `github:auth-cancel(cwd?)`, `github:auth-disconnect(cwd?)`, `agents:list()`, `agents:add(draft)`, `agents:remove(id)`, `community:list()`, `community:install(id, choice)`, `community:remove(id)`. Send channel (1): `github:clear-cache()`. No new event channels. No MCP tools were registered here: the deck-tools owner can call the same service/auth/projection functions when composing its existing GitHub/community tools, retaining its own caller grants/action-log policy.

Tracked edits for the integration worker, not performed here:

- `macos/TerminalDeckNative/Package.swift`: add `.testTarget(name: "TerminalDeckBackendTests", dependencies: ["TerminalDeckBackend", "TerminalDeckNativeCore"])`; this test directory did not exist at assignment start. Include the four new prefix test files in the one combined test gate.
- (7 Oct: `NativeStateIPCService` and `native-state:call` were removed with the Node engine; the Store is owned by `NativeStateService` and every domain registers on the composition root's registry.) Historical: `NativeStateIPCService.swift`: its registry is private and currently accepts only the 14 Store methods. Expose/compose the shared domain registry through the native backend root, install the three registrations above after providers are assembled, retain their owners/subscription, and expose invoke/send for the explicitly registered domain channel names with a native-app context. Do not route them through `native-state:call`, whose payload is a Store method.
- `macos/TerminalDeckNative/Sources/TerminalDeckNative/EngineBridge.swift`: route the listed `github:*`, `agents:*` and `community:*` channel names to that native dispatcher for both normal and ordered invokes and sends. Preserve `NativeRPCValue` JSON boundaries. Current code still sends every channel to the Node `/__td` bridge; writing these ports alone does not replace it.
- `macos/TerminalDeckNative/Sources/TerminalDeckNative/AppModel.swift`: retain the one constructed client graph alongside provider/account/session owners, after the current Store ownership preflight, and stop the graph during drain. Transfer ownership of `github/auth.json` and `custom-agents.json` before enabling writes so Node and native do not both write them.
- `macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendNativeProviders.swift`: its existing private `customAgents()` independently reads this same compatible file. Replace that parser with `BackendCustomAgentsRules.parseAgents` or the shared store snapshot for exact disk-entry parity, while keeping session-time executable relookup and removal's current no-kill behavior. Its present parser refuses a file with more than 32 rows instead of taking the first 32 valid rows, and uses byte/Swift Character limits where TS uses UTF-16 length. Physical Windows command execution remains unavailable on a Mac.
- Real community installer composition: implement `BackendCommunityStoreProviding` from the signed native Store installer. Use `BackendCommunityProjection.plannedTargets` as the install-sheet table or ensure the installer has the identical table. Do not substitute a bare list that drops signature/tier/ledger decisions.
- Git/remote graph: share `auth` with the native HTTPS Git credential supplier and remote host GitHub feature factory. The remote-server host/MCP factories and grant enforcement are separate workers' wiring; do not bypass them by exposing panel channels to paired devices.

## Protocol suppliers

| Protocol / injected operation | Concrete supplier or required owner |
|---|---|
| `BackendGitHubHTTPFetching` | Included `BackendGitHubURLSessionHTTP` (ephemeral, no cookies/credential store, HTTPS); fake fixture HTTP for tests |
| `BackendGitHubToolRunning` | Included `BackendGitHubNativeTools`, using existing `BackendDevProcessExecutor`; integration supplies shared providers' login PATH and actual home |
| Auth repo/branch resolvers and auth-change callback | `BackendGitHubService` and shared `BackendGitHubCache`, exact construction above |
| Custom-agent command lookup | Included `BackendCustomAgentsStore.nativeLookup`, integration supplies providers' login PATH; no unknown CLI version launch |
| `BackendCommunityMachineProbing` | Included `BackendCommunityNativeProbe`, using existing `BackendNativeProviders` |
| `BackendCommunityStoreProviding` | Native signed community catalogue/installer owner must supply `view`, `install`, `remove`. No concrete native installer was present in the files read. Missing supplier returns `The community store is not available in this build.` with `ok:false` or `problem`; never empty success. |

## Known limits and pending gate

- No compile, test, UI, native HTTP, subprocess, live credential or end-to-end GitHub installation result is claimed. All 38 tests are written only. Original TS notes also mark installation endpoint fixtures as not live-verified.
- Shared subprocess execution bounds stdout/stderr together. The native adapter additionally rejects either finished stream above its original per-stream ceiling, but early termination occurs at the shared aggregate ceiling. A single overlarge stream can therefore run up to the combined limit before rejection; integration can extend the shared executor with separate stream limits if exact early kill timing is required. Auth uses 1 MB/stream, overview/git 8 MB/stream.
- Auth stores the unchanged `version`, `host`, `token`, `login`, `scopes`, `obtainedAt`, `expiresAt`, `clientKind` keys in `github/auth.json`; custom agents use `version:1`, `agents`, same row keys, two-space JSON and final newline. Restricted atomic writes reuse the existing native secret-file writer. Exact serialized fixtures must be checked in the combined gate, especially JSON Unicode escaping across the native encoder.
- Expired-credential deletion and Disconnect return a visible failure if the file cannot be deleted. TS swallowed deletion failures and claimed removal. This deliberate native correctness guard prevents false successful disconnection; no successful-path shape changed.
- Device polls preserve source behavior: no independent request deadline (`timeoutMilliseconds:0`), but task cancellation aborts transport; code expiry is checked before each poll. Identity/repo/device-code requests retain 15s limits. Panel `auth-await` should invoke the actor directly or use a transport deadline covering the whole code lifetime; the current EngineBridge's 30s silent-request limit is shorter than the device flow.
- Local inherited environment is supplied once to the graph. Reconstruct/reconfigure that graph if app code changes its launch environment later; source Node `process.env` is mutable, while Swift's supplied environment snapshot is intentionally explicit.
- Community runtime presence is an executable lookup on the shared measured login PATH. No installations, downloads, launches or credentials are touched by constructing any of these client services. The community installer remains a real dependency, not a new fake store.

Tests: `BackendGitHubTests.swift` (12), `BackendGitHubAuthenticatorTests.swift` (11), `BackendCustomAgentsTests.swift` (8), `BackendCommunityProjectionTests.swift` (7). Static source review corrected regex case sensitivity, broad identity folding, JS-style blank rate headers, output-ceiling checks and actor reentry after custom-agent lookup. Parent independently reviews these files before aggregate handoff.

Read-only peer review supplied to parent: plugin process numeric Double-to-Int traps and possible queued-read/termination ordering loss; plugin folder hashing Unicode sort must use JS UTF-16 order; UTF-16 string-slice parity suggestions. No parent files edited.
