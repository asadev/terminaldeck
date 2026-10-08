# Native metrics handoff — 2026-10-06

Status: **implementation written, validation pending**. This lane ran no tests, builds, runtime launches, probes, network calls, Keychain/auth reads, package installations or real-data mutations. Constructors are inert. The single combined gate remains with the main integration owner.

## Source coverage

| Source domain | Native implementation |
| --- | --- |
| `usage-window`, `plan-limit` | `BackendUsageModels`: typed account/window/amount/reset, source IDs, reported vs observed timestamps, stale/expired/drawable, real zero distinct from not-reported, panel/warning/billing parser. Described CLI resets remain verbatim. |
| `codex-usage`, usage half of `context-window` | `BackendUsageCodex`: dated plus archived rollouts, five-day/eight-file rate-limit search, 256 KiB/4 MiB tails, actual `window_minutes`; separate bounded cwd/CLI-ID metadata lookup. No `auth.json` decoration. |
| `usage-probe` | `BackendUsageProbe`: exact `initialize` then `get_usage` stdio control requests, no user message, empty setting sources, strict MCP/no persistence. Native pipes/process group, output/line caps, timeout, cancellation/reap, existing named-account vault probe ticket and security shim. Only explicit refresh runs it. |
| `usage-ipc`, `account-limits`, context reader | `BackendUsageService`: lifecycle/account attribution, source CLI cache with account UUID/TTL checks, account pools, shared refresh, actual screen snapshots with first-seen age, five-minute freshness/no-limits/billing gates using the existing native Store, explicit force reset, bounded cheap context tails, named/inferred/rivals provenance. Event-driven vnode watches and one-shot output debounce. |
| `cost`, `cost-ipc`, transcript usage aggregator | `BackendCostTranscript`, `BackendCostService`: five token classes, shared-request de-duplication across files, sidechain separation, model/window context maths, compaction lower bounds, project cap of 40 carrying transcripts / 400 candidate files / 90 days, real `cost:update` subscriptions. Legacy cost channels contain no dollar/spend arithmetic. |
| `session-insights` | `BackendInsightsService` and shared transcript fold: timing lower bounds, tools/calls/failures, models, cache ratio, newest timeline, overall heaviest requests, peak-preserving context downsample, compactions, warnings. Tool input/result bodies and reasoning are discarded. |
| `session-search` | `BackendSessionSearchService`: literal/phrase/exclusion and guarded regex queries, explicit roles, per-block UTF16 snippets/highlight offsets, ranking, all historical approved project stores, per-owner cancellation, deadline/file/hit/line budgets. No result persistence or query logging. |
| `alerts`, `deck-control/progress` | `BackendAlertsService`, `BackendInsightsProgress`: live blocked receipts separated from historical CLI IDs; context/prefix, provider absence, heavy-token median, metadata-only repeat/failure/no-write/compaction-echo, dirty-tree age/streak. Input failures appear in `coverage`; missing signals are not healthy/zero. |
| `readiness`, setup tools | `BackendReadinessService`, `BackendReadinessTools`: ten weighted checks, per-agent instructions, secrets cap, actual tracked-file/NPM token-presence check without returning values, pure raw ignore rules, re-derived fixes, atomic/create-only writes, only installed dependency scripts, cached-index untracking, actual npm lockfile and measured brew/npm Gemini upgrade route. Existing native Git and provider/process primitives are reused. |
| matching deck-control tools | `BackendUsageMCPTools.register`: **eight** native handlers: `usage.read`, `usage.refresh`, `usage.cost`, `chats.insights`, `sessions.search`, `alerts.list`, `readiness.scan`, `readiness.fix`. Explicit actual consent/action-log/session/machine-scope callbacks; current project/transcript membership checked; search query redacted in action-log inputs; cancellation tears down native work. |
| native channel integration | `BackendUsageRPC`: **19 invoke / 2 send** channel names, one explicit authenticated authorization seam, start/disconnect/stop and existing lifecycle-event fanout. |

## Integration inputs and order

Use the existing authoritative `NativeStateStore`, `BackendAccountLaunchAdapter`, `BackendSessionLifecycleCoordinator`, `BackendProjectService`, `BackendGitService`, `BackendNativeProviders`, and MCP server. Do not create a second Store/account broker/session ledger/PTY owner.

1. Supply `BackendCostScopeProvider(project?, NativeRPCContext) -> NativeTranscriptScope` from actual account-owned transcript directories, bound device homes and current filesystem grants. No renderer-provided account/config directory. `project:nil` must still be caller-scoped for session/all-store reads.
2. Build cost, usage, insights, search, alerts, readiness and the RPC facade. Usage needs the actual model-label catalogue callback. Alerts needs the actual project preferred-provider lookup callback. Readiness needs brand name, actual mutation consent and `BackendReadinessTools` with the existing `BackendDevProcessExecutor`.
3. Register `BackendUsageRPC.invokeChannels/sendChannels` after old metric handlers are disabled. Its authorization callback must validate the requested session/folder/account against the current caller on every call. Machine-wide usage is an owner capability. Push callbacks must target the actual owner and refuse delivery after grants are revoked.
4. Register the eight MCP handlers into the existing server using `BackendUsageToolAccess`. These callbacks must enforce the actual action-log/consent and session grants; they have no permissive defaults. A bound project caller cannot search other projects or nominate another project's transcript.
5. After the whole native Store/session cutover, call `rpc.start()`. Route existing accepted `BackendSessionLifecycleEvent` callbacks through `rpc.noteLifecycleEvent`: created refreshes cost directories; accountChanged invalidates unchanged old account panel text; accepted hook status supplies actual alert/status timestamps. Ordered PTY events are already observed via the same lifecycle actor, never another PTY listener/parser.
6. On window/peer closure call `rpc.disconnect(ownerID:)`; on backend shutdown call `rpc.stop()` before closing dependencies. Stop cancels probes/search/refresh tasks, unregisters lifecycle observers and closes vnode descriptors.

No new SwiftPM dependencies/frameworks are needed beyond the existing Backend/Core target and Foundation/Darwin. `BackendDevProcessExecutor` is the concrete sibling worker's pipe/process-group seam with up to ten-minute cancellation/timeout support.

## Explicit limits for integration/review

- ICU offers no per-match interruption API here. Regex search conservatively refuses repeated groups, backreferences, lookaround and overlapping unbounded repeats, including some patterns the JS source accepted. It returns `unsafe-regex`, not a false empty search.
- Context/rate-limit sources currently supported are Claude and Codex, as in the source domain. Other providers return not-reported. Token/insights formats are the source Claude JSONL formats; no unsupported provider numbers are fabricated.
- Readability/size failures for readiness files are reported as skipped checks (the secrets gate remains warning). This is stricter than the source README path that sometimes took an unreadable file at face value.
- Guest readiness command execution requires the actual enforced guest environment planner; absence refuses the action. Machine-wide CLI upgrades are owner-only. MCP readiness fixes re-scan and accept only currently offered project fixes.
- Process/version/network/credential compatibility, compilation and live watcher behaviour are **not verified** by source inspection. The combined gate must cover these modules with scratch fixtures and controlled seams before native cutover. Do not run real credential/CLI/package-manager jobs as ordinary unit tests.

Dashboard layout, dev-service ownership, artifacts and Safari remain other lanes.
