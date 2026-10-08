# Safari workers, scraping, capture and assets handoff

Status: 13 new Swift source files written on 6 October 2026. Local only. No build, test, typecheck,
lint, runtime launch, dependency install or live-data read was performed. This
lane is not verified behavior or a completed browser/migration claim.

Ownership: this lane added only the files below. Existing Swift/TypeScript files,
phone code, Node/Linux/server code, production app installs and data were untouched.

## New files and responsibilities

Backend target:

1. `BackendBrowserScrapingSupport.swift`: authenticated caller identity, injected
   authorization contract, explicit root/path confinement, symlink refusal,
   bounded record I/O and streaming SHA-256 of real asset files.
2. `BackendBrowserWorkers.swift`: profile membership persisted in
   `browser-workers.json`; 16-worker limit; stable worker names; default profile
   never enrolled; paced, fair leases held only in memory; 30-second pace ceiling,
   120-second default/600-second maximum lease; holder checked on renew/release;
   cancellation frees a pending reservation; unregister retains profile/logins.
3. `BackendBrowserScrapingStore.swift`: compatible `browser-scraping.json`
   settings; capture folders with `capture.jsonl`, bounded bodies and
   `capture-summary.json`; profile-owned `scrape/runs/<run>/profile`,
   `ledger.jsonl`, `coverage.jsonl`; block sidecars and optional safe PNGs;
   measured statuses preserve null/unmeasured and open-capture semantics.
4. `BackendBrowserScrapingAssets.swift`: sequential bounded asset batches;
   combined then individual rendition rewrites, original fallback; verified
   resume, raw byte writes, real file hashing, immutable run/profile ownership,
   coverage verdicts and observed batch tallies. It requires real transport and
   destination grants; those dependencies are not themselves implemented by the
   backend actor.
5. `BackendBrowserNetworkCapture.swift`: explicit bound-tab capture lifecycle,
   generation protection, observer drain at stop, per-resource authorization,
   metadata manifests and truthful WebKit limitations. Stored settings fill
   only unnamed options. No interception is pretended.
6. `BackendBrowserWorkersLiftRequests.swift`: bounded, deduplicated in-memory
   ask inbox; attended/local filing; human-only decline/approve; a nil transfer
   adapter retains approval requests with an explicit unavailable result.
7. `BackendBrowserScrapingRPC.swift`: real NativeChannelRegistry factory,
   owner-targeted status/inbox events, tool dispatch and session disconnect.
   With sessionLift supplied, all worker list/mutation/tool/config/status paths
   query its current caller-authorized view and project real pending queues into
   each worker. Lift summaries/canSeedStorage/seedTiming are taken from that
   current service response; the stale no-service limitation is removed.
8. `BackendBrowserScrapingMCP.swift`: real MCP tool definitions and handlers,
   canonical/wire aliases, schemas and mandatory dynamic action-tier gate.
9. `BackendBrowserScrapingRendition.swift`: source type/status/minimum byte and
   known-length comparison decisions; explicit native width/height/byte-ratio
   checks; unknown measurements remain unknown and fallback is real.
10. `BackendBrowserScrapingRegex.swift`: bounded RegExp/replace and total-pattern
    execution through the system JavaScriptCore framework. No DOM, network,
    filesystem, host callbacks, Node or Chromium. Exact source g/i/m/s/u/y and
    standard replacement tokens, including `$11920`, named captures, literal
    dollars and match/prefix/suffix expansion. Inputs are function arguments.

App target:

11. `NativeSafariCaptureBridge.swift`: explicitly supplied WKWebView observer;
   isolated-world document-start scripts for resource timing, frame origin
   checks, bounded delivery queue, real callback drain, honest diagnostics,
   block-toggle-controlled evidence. Safe snapshot is mandatory and has no raw fallback.
12. `NativeSafariCaptureAssetFetch.swift`: real bounded/cancellable native HTTP
    transport using only the supplied profile's live WKWebsiteDataStore cookies;
    ephemeral URLSession, no shared jar/cache, manual redirects with fresh origin
    grants, response cookies returned to that exact store, HTTPS downgrade refusal.
    HEAD falls back after 403/405/501/network failure/missing length to bounded
    range GET with an 8-second deadline including redirects. Header-only range
    reads cancel the body immediately. Explicit dimension probes read at most a
    256 KiB prefix. Public asset scope uses no cookies and creates no store.
13. `NativeSafariCaptureAssetQuality.swift`: real ImageIO container metadata and
    safe SVG intrinsic dimension parsing. No pixel decoding/rewrite/output. Unknown
    prefix dimensions, SVG percentages and viewBox-only coordinates stay unknown.

All constructors are inert. They do not discover app roots, read credentials,
create sessions/stores, start services, install global hooks or make directories.
Disk/network work begins only with explicit operation calls.

## Source contract inventory

| Existing module(s) | Native disposition |
|---|---|
| `browser-workers.ts`, `browser-worker-pool.ts` | Membership and paced/fair/cancellable lease mechanisms written; profile creation/listing/live pages must be wired to root's real profile/runtime services. No claim that worker pages or fleets have been launched. |
| `browser-workers-ipc.ts` | Core list/ensure/register/unregister/pace and inbox surfaces written. Worker responses now compose current service.view(caller): real held summaries, queued origins/key counts per visible worker, canSeedStorage and exact live-page seed timing. Direct lift/inject/forget route to the supplied profiles lane's BackendBrowserSessionLiftChannels without duplicate registration; absent service keeps false/explicit unavailable. Guest seed/transfer internals belong to that lane. |
| `browser-lift-requests.ts`, `deck-control/lift-ask-tool.ts` | Ask/decline/deduplication/local attendance boundaries written. Inbox.transfer matches the profiles lane's real BackendBrowserSessionLift.approveRequest API; absent service keeps approval pending with no fake writes. |
| `browser-scrape-settings.ts`, `browser-scrape-paths.ts`, `browser-scrape-status.ts`, `browser-scraping-ipc.ts` | Compatible settings/file roots/fleet fields, outcomes `{ok,message,count}`, persisted run ownership and measured null states written. Requires injected reveal, grant and event routing. |
| `browser-capture-store.ts` | Bounded durable capture entries, bodies, summaries and incomplete/empty facts written. Not every response/body is observable. |
| `browser-network.ts` | Metadata lifecycle only. WebKit public APIs do not provide CDP Network/Fetch events, request pause/continue/fulfill, original HTTP byte buffers or getResponseBody parity. Unsupported rule requests are rejected. |
| `browser-capture-script.ts`, `browser-fetch-rules.ts` | Rules remain saved/readable; aliases normalized. No dynamic image-size placeholder fulfillment, transparent GIF/media/script/font substitutes, CSS box/srcset sizing or truthful interception counters. `counts` is null, never zero fabricated. |
| `browser-asset-session.ts`, `browser-asset-session-cdp.ts` | Native exact-profile HTTP cookie transport and a cookie-free public scope written. No CDP asset-session fallback. Native bytes are explicit new requests, not bodies recovered from WebKit's private cache/traffic. |
| `browser-asset-fetch.ts` | Resume/hash, probe selection then degrade-only GET fallback, type/minimum/quality checks, complete-byte/truncation checks, atomic staging and approved ledger-file repair written. Source tally asked/fetched/upgraded/fellBack/skipped/failed/bytes/ledgerWasWrong is measured. Remote destination delivery and arbitrarily large streaming assets are not supplied. 64 MiB per-asset ceiling is explicit. |
| `browser-asset-rendition.ts`, `browser-asset-probe.ts` | Combined/individual/original ordering, HEAD/ranged GET, source text-vs-binary extension guard, minBytes and source known-length comparison written. Unknown lengths do not invent a comparison; comparedBytes stays false. Native optional minWidth/minHeight/minByteRatio/requireLargerDimensions use real ImageIO/SVG metadata and refuse missing required measurements. Probe refusal does not discard the original. |
| `browser-asset-ledger.ts`, `browser-asset-digest.ts` | Real file SHA-256, length verification, resume/refetch, digest expectation and append-only records written. Build-time repository byte-writer/transform scanning from asset-digest is not ported. No byte transform is performed by this lane. |
| `browser-asset-coverage.ts` | Explicit/custom/three source generic shapes, structural thousands separators, disagreement->unknown, complete/short/over/unknown and durable checks written. Source first-match i/m/s/u/y semantics use isolated JavaScriptCore; invalid expressions record unknown rather than false completeness. No match/metadata is simulated. |
| `browser-block-watch.ts`, `browser-block-capture.ts`, `browser-block-shelf.ts`, block toggle channels in `browser-drive-ipc.ts` | HTTP/challenge URL/short-body/navigation-failure signals, 60-second cooldown, evidence sidecars and privacy-safe screenshot hook written. Source default-on/opt-out toggle is shared; legacy booleans fill unset newer answers. assets.blocks aggregates only caller-granted profiles AND page origins, reports filtered total/off profiles/empty reasons and scrubs credential URL params. Existing navigation delegate, shelf UI/render/reveal/delete still need integration. Unowned legacy-root evidence is excluded until ownership can be established. |
| `deck-control/worker-tools.ts`, `browser-scraping-tools.ts`, `browser-network-tool.ts`, `asset-tools.ts`, `asset-tool-names.ts` | Real tool factories/dispatch and canonical+wire IDs written. Source consent/action logs/budgets/session binding and per-machine trust are mandatory injected gates, not claimed as implemented by this lane. |

## Registered surfaces

18 channel names are factory-registered:

- `browser-worker:list`, `ensure`, `register`, `unregister`, `pace`
- `browser-worker:lift-requests`, `lift-answer`
- `browser-worker:lift`, `inject`, `forget-lift` (real supplied lift dispatch;
  explicit unavailable if service was not passed)
- `browser-scraping:config`, `config-set`, `status`, `capture-clear`,
  `capture-reveal`, `ledger-clear`
- `browser:block-capture`, `browser:block-capture-set` backed by the same
  checks.screenshotOnBlock value, with source default true when unset.
  The legacy `isolated` toggle is local native-app only and creates no profile
  or website store. Non-isolated IDs use the real authorized profile resolver.

Push event names: `browser-scraping:changed`, `browser-worker:lift-request`.
Values are sent only to the authenticated watching owner; revoked watchers are
removed. Factories register invoke handlers only, so no ephemeral subscription
tokens are discarded. Consumers that use registry.subscribe/onSend must retain
their NativeRPCSubscription tokens.

10 MCP canonical IDs (wire names replace `.` with `_`): `browser.workers`,
`browser.worker`, `browser.lift_request`, `browser.scraping`, `browser.network`,
`assets.rendition`, `assets.ledger`, `assets.coverage`, `assets.fetch`,
`assets.blocks`. `browser.lift_request` files only an ask. `browser.network`
advertises partial metadata only. Tool registration does not start an MCP server.

## Exact integration steps

1. Supply one explicit app-owned data root. Construct shared workers/store/inbox/
   assets/network and one `BackendBrowserScrapingRPC`. Do not instantiate a
   second WebKit profile store or use the helper process to own website data.
2. Wire `BackendBrowserWorkerHooks.profiles/createProfile/pages` to root's real
   profile/runtime services. Return only caller-granted profiles and pages.
   Populate WorkerProfile.partition with the existing profile's actual partition
   identifier (otherwise it remains null, not a fabricated value).
3. Supply the mandatory `BackendBrowserScrapingAuthorize` closure. Enforce current
   caller/session/machine/tool/tier/profile and exact origin grants, action log,
   budgets, attendance and the runtime's human/agent baton. Do not trust a tool's
   `sessionId`, profile name, destination or fabricated caller kind.
4. Resolve profiles using the actual active profile/default semantics; ambiguous
   names must fail. Asset `directory/file` closures must use the existing approved
   local destination/file service, including security-scoped bookmark lifetime.
   No wildcard filesystem grants or implicit home-directory destinations.
5. Construct `NativeSafariCaptureAssetFetch(store:authorize:)` with the real
   app-owned live WebKit store resolver. Forward AssetHooks.fetch to its
   fetch(caller:profileID:url:method:maximumBytes:) method. This is the supplied
   native transport; do not route to the older data bridge's 16 MiB bounded fetch
   while advertising the new 64 MiB bound. Its automatic response-cookie writes
   also need the explicit `assets.fetch.cookie-response` grant.
   Wire mandatory AssetHooks.probe to native probe(caller:profileID:url:dimensions:).
   Native probe uses `assets.probe.transport` exact-origin grants, 8-second deadline,
   header cancellation and bounded prefix metadata; a closure returning nil is
   not a native probe implementation. Resolve an omitted asset profileId to
   BackendBrowserAssetHooks.publicProfileID (`public`), permit its origin scope,
   and keep it out of the real website profile catalog. This marker carries no
   cookies and does not call the WebKit store resolver. Supply actual granted
   profile IDs for authenticated requests. Repair replacement additionally needs
   `assets.fetch.replace` write authorization for the exact ledger path.
6. Construct and retain one NativeSafariCaptureBridge per actual browser tab.
   Feed the exact tab/profile identity; FrameAuthorize must check both the
   originating frame's origin and requested resource URL, plus current baton.
   Supply safeSnapshot that calls runtime.privacySnapshotPNG(tabID) and returns
   its bytes directly, after verifying exact current view/owner/profile authority.
   No disk read is required. Password/token fields and entire unreadable child
   frames must be masked; human takeover must refuse. No raw WK snapshot fallback.
7. NetworkHooks.target must resolve the source session/window binding via root's
   BackendBrowserBindings, including ownership and machine checks. NetworkHooks.
   observe explicitly calls bridge.start and returns its stop+diagnostics handle.
   No arbitrary tab lookup, controller sharing or singleton default store.
8. Forward real navigation delegate finish/fail/status into bridge.recordBlock
   only for an authorized caller while the effective block toggle is on
   (source default true; preserved legacy opt-out). Do not replace root's
   navigation delegate. Call bridge.detach on tab close and network.disconnect on
   caller teardown. Stop drains accepted callbacks; a closed tab has an empty,
   honest final URL and explicit tabClosed status.
   On close/profile change/human takeover/revocation, call network.cleanup(
   tabID:profileID:ownerHolder:reason:) with retained trusted identity. Reasons:
   tabClosed/profileChanged/humanTakeover/grantsRevoked/callerDisconnected/appShutdown.
   This calls the observation's mandatory retire closure, drains delivery without
   new DOM reads, and writes summary termination metadata. Success requires BOTH
   observer stop and summary write. Failure retains the run for retry and reports
   observerStopped/summaryWritten/retainedForRetry in error details. Never expose
   this lifecycle cleanup as an arbitrary-tab incoming tool.
9. Wire workers/store/inbox changed callbacks to rpc.publishChanged(on:profile:).
   Invoke rpc.register(on:ownerID:) once during the exclusive integration pass.
   Forward RPC disconnect with the same trusted identity used for lease holders
   to releaseAll/network/inbox; also call registry.removeOwner for its listeners.
10. Invoke BackendBrowserScrapingMCP.install(on:rpc:authorizeCall:). The mandatory
    authorizeCall must check CURRENT source action tier before returning a trusted
    caller. Static MCP base tier cannot authorize scraping.set/clear/workers/pace
    or ledger.record. It must distinguish local and paired-device provenance,
    since BackendMCPCallContext.machineID alone does not prove caller kind.
11. RPC init now needs profiles(caller) for block aggregation; enumerate only
    caller-visible real profiles and preserve per-record exact-origin authority.
    Pass optional sessionLift from the profiles lane. Direct 3 lift channels route
    through BackendBrowserSessionLiftChannels.invoke, and inbox.transfer can call
    sessionLift.approveRequest(caller,request:). No registration is duplicated.
    Missing service stays explicit unavailable. MCP scraping.forgetlift additionally
    requires a trusted native-app RPC context; it never fabricates one from a tool.
    Supplying RPC.sessionLift also activates currentWorkerView composition on every
    worker-facing RPC/MCP response, including ensure/register/unregister/pace and
    forget results. BackendBrowserWorkers.applyingTransferState is a pure projection
    of the freshly authorized service view, never a cache or a tool argument.
    It accepts only real lifts/queued arrays and a reported boolean capability,
    filters queues to visible worker profile IDs, and exposes origin/key-count/
    expiry/pending summaries without storage values. The raw Workers actor's base
    view intentionally represents no supplied transfer service; do not use it as
    the final UI view when the RPC has a service. With no service, the original
    false capability and explicit limitation remain. A service read failure fails
    the response rather than substituting fake empty queues or false readiness.
12. Reveal callback must call the authorized native Finder/path service and
    report failure. Do not mark shown until the real callback completed. Keep
    secure transfer nil until the real service is supplied; approval remains pending.
13. JavaScriptCore and ImageIO are system framework imports, not dependencies or
    Node helpers. Source supports exact runtime engine semantics; framework/regex
    unavailability produces explicit errors. No such code was executed in this lane.

## Explicit remaining capabilities and WebKit limits

- Complete request/response stream, arbitrary fetch/XHR bodies, failed/inflight
  timing, service-worker traffic and CDP buffer/capture recovery are unavailable
  through public WKWebView APIs. Current observer sees completed resource timing,
  current main frame, previously discovered live frames and future frame loads.
  Already-loaded unknown child frames may be missed. Cross-origin sizes/status may
  remain unmeasured. Queue drops and excluded grants are counted; unobserved
  traffic is null. A metadata summary is always incomplete for full traffic parity.
- Request blocking/fulfillment, image placeholder sizing, image/CDP dimension
  interception and source paused/fulfilled/stuck/derivedHeight/clamped counters
  are not supplied. Content-rule-list based blocking would be a separate limited
  implementation and must not be represented as full source fulfillment parity.
- Secure lift/storage/seed/held-session lifecycle is owned by the profiles lane.
  This facade now supplies its typed dispatch/inbox composition seams. It does not
  claim that service was injected, ran, or transferred real credentials. With no
  supplied service, direct operations refuse and inbox approval remains pending.
- Automatic profile arming from the profile/tab lifecycle is owned by the arming
  lane and is not connected by these files.
  Explicit network.start honors stored defaults; integration must arm/disarm on
  actual profile/tab/baton changes. Background profile watchdogs, Electron hidden
  worker windows, headless-host/scraping-host creation, scrape orchestration and
  remote worker/asset forwarding are not supplied by this lane. They must remain
  explicit pending capabilities if the broader source runtime exposes them.
- Real downloads/destination cancellation are owned by the downloads lane;
  this asset transport is distinct and has explicit 64 MiB/1000 URL bounds.
  Remote file delivery and assets exceeding the memory cap require the real
  streaming destination/download service before parity can be claimed.
- No public API yields WebKit internal HTTP-cache byte/path accounting, complete
  cached asset response recovery or private network response buffers. None is
  fabricated. Native asset transport makes explicit authenticated requests.
- Source regex flags/tokens, ranged HEAD recovery, content checks and requested
  native dimensions/byte-ratio checks are implemented in source. Remaining limits:
  system JavaScriptCore absence/errors are explicit; image metadata may be missing
  from the 256 KiB prefix; SVG percentages/viewBox-only layouts are unmeasured;
  native ImageIO need not support every file format. Requested unavailable quality
  measurements refuse that candidate and fall back rather than claim an upgrade.
  Source build-time byte-transform audit helpers and block shelf UI wiring are not
  ported here. Unowned legacy-root block evidence cannot be disclosed as belonging
  to a granted profile; ownership/migration is still needed for those old rows.
- The new APIs are not yet wired into app startup/native registry/session MCP,
  profile ownership or navigation events. Injected grant/file/runtime callbacks
  are integration requirements, not proof they exist or have run.

The next step is the root's exclusive composition pass, then the user's one
combined build/test/visual gate. No tests or appearance were verified here.
