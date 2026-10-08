# Native session lift follow-up

Local source written on 6 October 2026. No builds, tests, typechecks, lint, runtime launches, CLI probes, actual cookie/auth reads, Keychain access or installs were performed. Existing worker/scraping/native-tab files were not edited. The only earlier lane file changed was this lane's own `BackendBrowserProfiles.swift`, at the coordinator's explicit request, to prevent profile recreation during deletion.

## New source and coverage

- `BackendBrowserSessionLift.swift`: typed native endpoint/source/target identities, frozen consent scope, action authorization, caller-bound lift metadata, direct lift/inject/forget bodies, worker-ask transfer hook, counts-only reports and source channel routing.
- `Sources/TerminalDeckNative/NativeSafariSessionLift.swift`: actual public `WKHTTPCookieStore` read/set/readback; private in-memory cookie/storage lifts; isolated-world main-frame storage export/seed; live-document nonce checks; one-shot queued seeds; expiry, holder/permit revocation, cancellation-aware cookie callback deadlines and target serialization.

Mapped contracts: `src/main/browser-session-lift.ts`, the lift/inject/ask/forget portion of `browser-workers-ipc.ts`, and `browser-seed-preload.ts`. The existing `BackendBrowserWorkersLiftRequests.swift` hook is reused. No new direct MCP credential-transfer tool was added: `browser.lift_request` still only files an ask which the person must answer.

Direct lift IDs hold data for at most 15 minutes. Queued seeds hold data for at most one hour, further limited by the consent/grant expiry. Native values are never persisted, included in source files, sent to React/EngineBridge/remote transport/MCP, or logged. Returned lift summaries contain cookie names/counts and storage counts only. Source stores are read, never cleared or mutated.

## Exact integration APIs

Create `NativeSafariSessionLift(changed:seedOutcome:)` in the native app owner. Its constructor is inert. Register actual existing app-owned persistent stores with `bindProfile(profileID:name:store:sessionID:)`; register each live regular view with `bindPage(_:tabID:profileID:)`; call `didCommit(_:tabID:)` from the existing WKNavigationDelegate, and `unbindPage`/`unbindProfile` before page/profile replacement or clear. Never construct an independent `WKWebsiteDataStore` in a helper to supply this service. Binding the same store under two profile IDs is refused.

`source(tabID:)` returns a typed snapshot for one visible owned source page. `source(profileID:)` refuses unless exactly one source page is visible. An inbox approval must show/select that page; it must not silently choose another site in that profile. `target(profileID:origin:tabID:)` resolves an actual registered native store, optionally narrowed to one visible committed document. Raw request fields never construct an endpoint, grant or WebKit object.

Supply `makeHooks(source:targets:approve:)` with the trusted caller/session/profile/window resolvers. Every resolver must call fresh `BackendBrowserProfiles.requireProfile`, in addition to `state.resolve`, so cached metadata cannot reopen a profile being cleared. Targets must be current registered workers visible to the caller. Pass the returned hooks to:

```swift
BackendBrowserSessionLift(hooks: hooks, authorize: actualScrapingAuthorize, changed: actualChanged)
```

The `approve` callback receives the exact source page/origin/profile/session and frozen target list. It must verify an attended local native-app caller and the person's answer to that scope, including the target conflict policy. Return `BackendBrowserSessionLiftPermit` with:

- the authenticated `caller.holder`, exact source and exact ordered target list;
- a fresh transfer-scoped `BackendMCPCancellation` which observes request cancellation, caller disconnect and source/target grant revocation;
- `ownerAnswered: true` only for the concrete native UI approval;
- a finite expiry, at most the intended grant lifetime;
- `stillPermitted` which reads current authority, and `authorizeUse(target)` which rechecks source/target profile, session, tab, origin and device grants on every use. Future queued storage use supplies its actual live tab/document to this callback.

Never derive permission from a raw `machineId`/`sessionId` field. Use the coordinator's trusted `BackendBrowserService.resolveSession`/`resolveProfile` seam and actual native ownership tables. Direct lift/inject reject ordinary session, paired-device, remote and unattended callers. A worker's request is an ask, not an approval.

If the person selects a newly minted worker during the original lift lifetime, `inject` obtains a fresh native approval for the expanded exact target list and uses the hook `reapprove(id, permit)`. This preserves the source's ability to put a held session into a new worker without reading the source again. Reapproval never extends the original snapshot's expiry. Existing targets continue under their current approval without a new per-worker dialog; `authorizeUse` is a grant check, not a repeated consent prompt.

Route the existing scraper's three unsupported invoke cases to:

```swift
BackendBrowserSessionLiftChannels.invoke(
    channel, arguments: args, context: context,
    service: liftService, workersView: actualWorkerView
)
```

It handles exactly `browser-worker:lift` (`{viewId}`), `browser-worker:inject` (`{liftId, profileIds?}`) and `browser-worker:forget-lift` (lift ID string), with the source channel shapes. **Do not register those names twice.** `BackendBrowserScrapingRPC` already owns their registration and must delegate its cases instead. `lift`/`inject` failure bodies return `ok: false, reason` with safe messages; counts and queued outcomes remain explicit.

Construct the existing ask inbox with:

```swift
transfer: { caller, savedAsk in
    try await liftService.approveRequest(caller, request: savedAsk)
}
```

`approveRequest` resolves the source and saved target profiles anew, applies the real native consent/grants, captures/injects, forgets the temporary lift immediately, and returns the number of workers with **verified new cookie or storage writes**. Preserved/already-matching cookies and queued keys alone do not count as injected workers. A storage-only request can therefore remain pending until a visible target page receives its seed; do not report it completed just because keys were queued. The existing inbox's zero-count behavior keeps the ask pending. Native `seedOutcome` supplies actual write counts so the UI can display the later result; linking that result to an inbox completion is an explicit integration decision, not implemented in the other worker's actor here.

Merge `liftService.view(caller)` into current worker/scraping views. Map its `queued` rows by `profileId` into the existing per-worker `queued` field, and replace the old hardcoded empty `lifts`, false `canSeedStorage` and unwired lift limitation only when this real adapter is assembled. Seed timing text must remain visible: values may arrive after the site's boot code and may require reload.

After a worker page commits/finishes **or becomes visible**, call `adapter.applyQueuedSeed(tabID:)`. It consumes the seed before delivery, validates the new exact live document and current grant, injects only into that main frame, and returns counts; it never returns entries/values. No hidden page is created and no origin-wide script contains live tokens. A profile with multiple visible same-origin pages needs explicit tab selection for immediate writes; otherwise its seed remains queued for the selected exact page. Reuse existing change/event infrastructure rather than polling for pages.

On disconnect call `liftService.disconnect(holder:)`; this also calls the native hook `revokeHolder`, so queued seeds are dropped even after their source lift was forgotten. On individual scope revocation call native `revoke(permitID)` or cancel its transfer-scoped signal. Rebinding a profile/store/session invalidates its endpoint and all affected private lifts/seeds. Call `adapter.shutdown()` during owner teardown.

## Conflicts, checks and limits

- `preserveTarget` keeps any existing cookie with the same normalized domain/path/name and preserves existing storage keys. `replaceMatching` requires explicit consent and changes only those matching keys. Neither policy clears unrelated destination cookies/storage. Identical existing data is counted separately from new writes.
- Original cookie objects are copied through public WebKit, preserving the attributes exposed by `HTTPCookie`. Readback verifies name/domain/path/value, leading-dot domain scope, Secure, HttpOnly, session lifetime, exposed SameSite and expiry. Expired cookies and surfaced partitioned-cookie indicators are refused and counted.
- WebKit has no public atomic cookie compare-and-set or multi-cookie transaction. The adapter serializes its own writes, checks existing destination cookies before each set and verifies afterward; another active page/network writer can still race the public cookie-store API. `preserveTarget` cannot claim a transaction-level conflict guarantee against independent concurrent page writes. The native worker/lease integration should keep destinations idle during transfer when that guarantee is required.
- WebKit cookie callbacks expose no rejection error, so completion alone is not counted as a write. Readback is required. Reads/writes have a ten-second callback deadline, and task cancellation releases the wait. An already-submitted WebKit write can complete after cancellation/deadline; rollback and zero side effects are not claimed. Revocation stops subsequent operations and drops held credentials; it does not delete previously copied site state from destination profiles.
- The native lift accepts at most 5000 eligible cookies and 4 MiB of cookie fields; exceeding that refuses the lift rather than silently taking part of the cookie session. Storage follows the source's 200-key/256-KiB limit per store and reports truncation. Only actual eligible source host/domain cookies are retained; local/session storage is bound to the exact scheme/host/port origin.
- Public `HTTPCookie` does not expose every WebKit partition key or opaque browser attribute. Surfaced partitioned indicators are refused, but full partitioned-cookie parity cannot be proved from this API. No attributes, paths, byte counts or successful website sign-ins are fabricated.
- A site may bind a session to other browser/device/server state. Verified cookie/storage copying is not verification that the website accepted the sign-in. Reports explicitly carry `signInVerified: false`.
- Storage is supported only through the exact visible top-level live page. Pre-boot delivery, arbitrary background origins, iframe seeding, IndexedDB/service-worker/database cloning, another browser's cookies, and remote-host credential transport are not implemented. The mapped source itself moves only cookies and local/session storage; there is no Node/Chromium fallback.

## Earlier profile deletion correction

`BackendBrowserProfiles` now marks an ID retiring before awaiting the real WebKit clear callback. Fresh `state.resolve` (id/name/active), `requireProfile`, activation, history/password profile checks reject it during the clear. Closing the metadata store while a deletion is in progress is refused, preventing close/reopen from dropping that guard. The retirement is cleared after successful metadata removal or a failed clear. Native page creation must still call the fresh guard; an old snapshot cannot enforce current authority on its own. The coordinator's `NativeSafariProfiles` retains ownership of the actual tab/download stop and WebKit data/cookie checks.

Next step is exclusive source wiring above, followed by the coordinator's single combined compile/test/behavior/visual pass. These additions are source-only and do not establish runtime parity or complete the browser migration.
