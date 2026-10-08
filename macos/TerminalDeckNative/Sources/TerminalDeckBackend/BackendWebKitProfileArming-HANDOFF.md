# WebKit profile arming, background and watch seam

6 October 2026. Local source only. No existing file was edited. No build, tests, typecheck, lint, launch, CLI probe, dependency install, production data read, release or install ran. Compilation and behavior remain unverified.

## New source

| File | Implements |
| --- | --- |
| `BackendWebKitProfileArming.swift` | Strict source-rule planner, person-arming decision, per-tab serialized event lifecycle, yield/reclaim/close, retained network cleanup, block camera and measured metadata coverage |
| `BackendWebKitProfileArmingWatch.swift` | Current-grant watch sessions, one JPEG in flight, ACK/dirty-bit backpressure, curtain/take/untake, eight host-held frame geometries, guarded input mapping, owner/guest privacy enforcement |
| `../TerminalDeckNative/NativeSafariProfileArming.swift` | Real public WKContentRuleList compile/add/remove on an explicit page/store; existing-delegate lifecycle seam; source background-color behavior |
| `../TerminalDeckNative/NativeSafariProfileArmingWatch.swift` | Isolated main-frame DOM invalidation observer; bounded native JPEG conversion; stable viewport measurement; required guest privacy PNG input; real authorized owner/taker WK snapshot branch |

Read/mapped: `browser-profile-arm.ts`, `browser-watch.ts`, `browser-background.ts`, `browser-headless-control.ts`, `browser-fetch-rules.ts` and relevant scraping settings. There is no source `browser-profile-watch.ts`; the watch contract is `browser-watch.ts`. Linux/server Node/headless control remains unchanged. No Chrome/CDP fallback was added.

## Profile rules: exact supported subset

| Source resource policy | WebKit mapping |
| --- | --- |
| allow/unset for all seven kinds | Normal browser behavior; no installed rule list |
| image:block | Content-rule `image` block |
| media:block | Content-rule `media` block |
| font:block | Content-rule `font` block |
| stylesheet:block | Content-rule `style-sheet` block |
| script:block | Content-rule `script` block |
| xhr:block or fetch:block | Explicit unsupported error; no broader `raw` rule substituted |
| fulfill, including old `cheap` alias | Explicit unsupported error; no HTTP response body synthesized |
| arbitrary rewrite/fulfill body/unknown kind/action | Refused by strict parsing; not passed into a raw content-rule compiler |

The source top document remains unaddressable. Each block list is limited by `if-top-url` to the exact HTTP(S) top-page origin, including port; HTTP(S) resource URLs alone match. Browser request/fulfill counters remain unknown, not invented. A content blocker is not a CDP Fetch interception transport. The adapter owns only its specific rule object/cache identifier and never calls remove-all on content rules, scripts or another profile store. A stale compile/removed grant cannot install a rule list after teardown. Public WebKit compiler rejection is surfaced.

## Profile lifecycle integration

1. Construct one `BackendWebKitProfileArming(store:network:assets:hooks:)` using the existing actual `BackendBrowserScrapingStore`, `BackendBrowserNetworkCapture` and `BackendBrowserScrapingAssets`. The shared store owns the explicit data root and capture manifests. Constructors are inert. `watch(target:caller:)` is called explicitly for each live real-profile WKWebView, including the actual isolated-profile identity. Caller must be the native app/internal engine, with no session and no remote identity; a tool cannot choose a passive profile owner.
2. Provide all `BackendWebKitProfileArmingHooks` from the real runtime: current authorization, actual baton, trusted network target argument mapping, `NativeSafariProfileArmingRules.apply/remove`, `NativeSafariCaptureBridge.recordBlock`, existing privacy-safe bounded DOM text, and scoped native status publishing. Authorization operations are `browser.profile-arm.watch/navigation/reconcile/rules/capture/camera/coverage/yield/status`. Do not turn this into an unguarded internal-engine escape for remote arguments. Rule/cache cleanup operates only on the adapter's retained owned object and does not need a new permission to remove it.
3. Create one app-owned `WKContentRuleListStore` under the app's explicit authorized root and pass that real store, root, page, tab ID and profile ID into `NativeSafariProfileArmingRules`. Never supply the default/global store. WebKit exposes no public store-URL getter; the runtime that creates the store is responsible for the root association. `apply` rechecks current exact profile/origin grants after compilation; `remove` removes only its retained rule. Cache-cleanup failures are reported while the inactive cache is no longer applied to the page.
4. Create `NativeSafariProfileArming` for the exact live page/caller/profile and call `start()` explicitly. Watch registration returns a closable token even when an invalid saved policy makes the first reconcile fail; its reported state is `failed`, not armed. This prevents losing teardown ownership. All-default settings attach no observer, camera or blocker. Capture must be explicitly true. Camera defaults on only when capture or supported blocking otherwise arms the page; on an otherwise unarmed page it requires explicit true. Coverage requires explicit capture and explicit pattern/check enablement.
5. The existing async navigation decision must **await** `prepareNavigation(url:canvasHex:)` before allowing a main-frame HTTP(S) navigation. Owner-initiated `WKWebView.load` must take the same awaited preparation path. Otherwise asynchronous rule compilation after commit may miss the first script/image requests. The trusted network target resolver must retain the authorized pending navigation URL so the metadata capture starts against the actual approved tab/profile/page; never trust a tool-supplied URL as a binding. Root navigation/UI delegates remain the owners and are not replaced.
6. Forward didCommit to `committed()`. Forward the measured main response status and requested URL plus didFinish/didFail evidence to `settled(requestedURL:httpStatus:error:)`. Unknown HTTP status remains unknown. The camera delegates to `NativeSafariCaptureBridge`, whose snapshot callback must preserve masking/baton/frame grants. It never falls back to an unmasked PNG.
7. Wire actual profile setting writes to `manager.settingsChanged(profileID:)`. The common store `changed` callback also fires while a capture summary closes: **do not synchronously await a new reconcile from inside that callback**, or it can wait on the operation writing that summary. Use the existing event bus or an explicit event task that returns from the store callback immediately, and distinguish setting writes from status changes where possible. No polling/scheduler/automation is introduced.
8. Agent attachment/network arming must **await** `yieldToDrive()` before it can claim the page. This marks held before waiting for pending profile work, removes only the profile blocker and calls `network.cleanup(tabID:profileID:ownerHolder:reason:)` with the retained exact identity and `.humanTakeover`. Reclaim via `freedByDrive()` only after the actual baton reports `.unclaimed`. Agent/human handover is treated as claimed; it does not become a passive person arm. Source `personArmHolds` is represented in status and must not be counted as an agent attachment by autofill/read-ownership code.
9. Actual close/profile change/access revocation calls the lifecycle's close/reconcile barrier. Cleanup uses `.tabClosed`, `.profileChanged`, `.grantsRevoked` as appropriate and does no new page reads. Its success depends on observer retirement/drain **and** capture summary persistence. Failed cleanup retains the run/token for retry and reports `failed`; never start an agent capture on top of an unretired person observer. Retire the old lifecycle before swapping a tab to another profile/store.

Profile metadata capture calls `BackendBrowserNetworkCapture.invoke` with explicit `rules:{}` and `capture:true`: content rules are applied by their real WebKit adapter, and the network owner remains a truthful resource-timing observer. Original `browser.network` interception flags remain false. Coverage counts only observed resource-timing entries since that page's commit, with an explicit metadata/not-items unit; a page stating no unambiguous total writes no coverage row. Body omissions/traffic gaps remain incomplete in the existing store summaries.

## Watch/remote seam integration

`BackendWebKitProfileArmingWatch` is an actual bounded dispatch owner, constructed with one exact target and required live hooks. It has no autonomous frame timer. Use these retained methods from the existing remote host's authenticated window/watch routing:

| Existing protocol operation | New seam |
| --- | --- |
| browser.watch | `watch(caller:window:maxWidth:quality:emit:)` → retained private Token |
| browser.unwatch / connection close | `unwatch(token, caller:)` |
| browser.frame.ack | `acknowledge(token, caller:sequence:)` |
| browser.input | `input(token, caller:sequence:value:)`; strip t/window/seq from value first |
| before human handover | `curtain(prompt)` **before** the real baton flips |
| browser.handover.take / untake | `take` / `untake` with the authenticated retained token |
| after actual handback | `uncurtain()`; the real grant must no longer identify a human taker |
| page navigation / scroll / resize / DOM/input event | `invalidate(target:)` with the actual current page URL/profile |
| page/host teardown | `dispose()` plus native watch bridge `detach()` |

Required hooks are real current grants, snapshot, input, take and holder-scoped untake. `grant` must read live window/profile/exact-origin/device/session grants, own-device status, actual baton and actual human holder. `humanHolder` is the trusted `BackendBrowserScrapingCaller.holder` identity. Unknown devices are guests. `emit` belongs to that authenticated connection and must recheck the endpoint's permission/owner state before putting frame bytes on its socket. This seam does not implement remote trust or a second DeckControl; input dispatch must preserve the existing tier/consent/budget/action-log gate. It never invents a listening server or an always-ready remote capability.

Retain the private Token in the endpoint's connection/window table. It is not decoded from client args. The seam checks caller owner/holder on all token operations. One ordinary JPEG is unacknowledged at once. A dirty bit retains only the newest requested update; host-held geometry has eight entries. A stale ACK cannot free the newer frame. Urgent curtain frames contain no pixels and supersede the outstanding ordinary frame. Frames use the real `browser.frame` shape, bounded to 67 KiB JPEG bytes / source base64 cap. Input coordinates are mapped from the exact named host frame using its scale/pageScale; stale/masked/owner-demoted frames are refused, with no guessed newest-frame fallback. Root input must separately enforce current DOM/actionability/native-key/touch capability and fail unsupported actions rather than report empty success.

Create one `NativeSafariProfileArmingWatchBridge` for the actual WKWebView, profile, authorization, privacy-safe PNG callback and `invalidated` callback. Start it explicitly when the first permitted watcher attaches and stop it at the last. It installs one isolated-world main-frame DOM mutation/scroll/resize/input/load listener, coalesced by requestAnimationFrame only after an event. Root commits/input/native resizing also call invalidate. Existing delegates remain untouched. Stop removes only its handler and cancels accepted invalidation work without executing new page code after grant revocation; its installed script becomes inert/stops on the next event when its handler is absent.

PNG callback rules:

- For a guest, `NativeSafariRuntime.privacySnapshotPNG` may be used while its current grants/baton permit. If `masked > 0`, **withhold the whole frame** and return `.masked` with empty pixels; do not label a painted-over image `.secretFree`. If zero, the runtime must still have proved child-frame/privacy coverage before returning `.secretFree`.
- For a current owner's own device, the new real `ownerPixels(caller:target:grant:)` method supplies a public WKWebView snapshot after the same current grant checks before/after capture, bound to the actual view/URL. It accepts an active human handover only for its actual holder. Return `.owner` only from this verified branch. This enables the owner's sign-in view without weakening the agent's masked snapshot method, which rejects handover pages.
- Root supplies the same current grant provider to `ownerPixels` as the backend watch. Never convert the raw client's own-device bit into a trusted grant. No raw guest snapshot fallback exists. The native bridge checks exact live view/tab/profile/origin, stable geometry, image dimensions/byte bounds, and compresses/resizes privacy-proved pixels with a bounded loop before any socket write.

## Background and explicit limits

`NativeSafariProfileArmingBackground.apply(to:url:canvasHex:)` ports the source's empty/app-canvas versus loaded white page convention. Root supplies the actual existing UI canvas token, validated as #rgb/#rrggbb/#rrggbbaa with alpha discarded. Call before initial paint and on navigation start; theme changes update empty/about pages only. A third-party unstyled HTTP(S) document retains its conventional white base instead of inheriting the dark shell canvas.

Public WebKit does not provide CDP continuous screencast frames or complete network bodies/interception. This watch implementation is explicitly **event-driven snapshots**, not smooth video: canvas-only/CSS animation, video, and visual-only/unobserved child-frame changes may not invalidate the main-frame observer. Full continuous-video parity is unavailable through this seam and must not be advertised. Source `everyNthFrame` has no faithful meaning here; the endpoint must refuse a non-default everyNth request instead of claiming to apply it. Public native touch/native-event details remain the real input dispatcher's responsibility; an unsupported trusted touch/key/action must be refused.

Resource observation excludes some service-worker/failed/unfinished responses and unknown already-loaded frames; response status/size/body stay unknown where WebKit omits them. Content blocking has no observed block/fulfill counters and cannot act as response rewriting or synthetic-placeholder fulfillment. Existing explicit asset-fetch/rendition behavior belongs to the assets lane and is not replaced by a content blocker. The headless server's source DeckControl continues unchanged, with its real unattended refusal and server/session/window grants.

Required remaining work: exclusive root delegate/lifecycle/store/remote endpoint wiring above, current shared policy and privacy/input/taker hook binding, capabilities/UI text distinguishing content blocking/metadata/event snapshots from unsupported fulfillment/full traffic/continuous video, then the user's combined build/test/visual gate. None of those behaviors has been exercised here.
