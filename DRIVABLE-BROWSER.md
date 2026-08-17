# The Drivable Browser

**Status:** design, not built. Written 2026-08-17 against `main` with several agents
mid-flight in `src/main/` and `ios/`. Nothing here is implemented. Every file named below
is named so that whoever builds it finds the existing seam instead of inventing one.

**Reads on top of:** `COPILOT-DESIGN.md` (the copilot is a real session with an MCP server),
`COPILOT-CAPABILITIES.md` (what it is for, and the nine things it must refuse), and
`DRIVING-MODE.md` (the copilot moving the app's own screen). Where this disagrees with
`DRIVING-MODE.md` it is because that document explicitly parked the browser — *"the browser
workspace is not tourable in v1"* — and this is the document that unparks it.

Asad, 2026-08-17:

> *"The browser we use there — I think it will be better if we use Playwright with this
> Chrome. Whatever browser UI we are using, it should drive over Playwright, so whenever I
> say to open something, or in any session for us to drive some pages or do some scraping or
> whatever tasks Claude needs to do in those sessions, it will actually use Playwright
> instead of a browser it cannot drive properly.*
>
> *Usually we have a combination — you are driving your Chromium over your Playwright, and
> whenever I need to do something you give me a Chromium where I can type the password, then
> you work in your Playwright. Or I do my step on the Chromium which is attached to your
> Playwright. It is two separate things we mostly use. If we can combine it here — and it can
> be a properly stable functionality, not the way we do currently. This Chromium with
> Playwright is not that stable, it goes back many times, turns off. If the UI and everything
> stays the same and it performs smoothly, I think this will be the best thing to have."*

**The one-sentence answer to the combination he describes:** the two Chromiums become one
because the drive and the person share a `WebContentsView` in a partition that already
persists — there is no "give me a Chromium", there is a baton, and passing it is a state
change in the main process rather than a second browser.

---

## 0. What was checked before any of this was written

Facts, from this repository and from Electron 41.10.5 on this machine, not from
documentation:

| Claim | How it was checked |
|---|---|
| The built-in browser is Chromium — a `WebContentsView` per tab | `src/main/browser-tab.ts:870` |
| Runtime is Electron **41.10.5**, Chromium **146.0.7680.216**, Node 24.18.0 | ran the bundled binary with `ELECTRON_RUN_AS_NODE=1` |
| **There is no CDP or debugger surface anywhere** | grep for `debugger`, `remote-debugging`, `appendSwitch`, `sendCommand`, `Page.navigate`, `Runtime.evaluate` across `src/` — zero hits outside a test that guards `--user-data-dir` parsing |
| **`deck-control` has no browser tools** | `buildCatalogue()` is 14 tools: `sessions.*` ×6, `projects.list`, `git.diff`, `git.status`, `alerts.list`, `settings.read`, `settings.write`, `log.note`. The only browser entry anywhere is the protected setting `browser.persistSession` |
| Catalogue budget today: **14 tools, 11,786 chars, ~3,368 estimated tokens — 42% of the 8,000 ceiling** | `catalogue.test.ts:186` records the measurement. Six tool slots and ~4,600 tokens of head-room |
| The guest partition `persist:terminaldeck-browser` really persists cookies and localStorage across processes | `browser-session.ts:12` — verified on 41.10.5 by the person who wrote it |
| `capturePage()` fails on a view that is not composited | `browser-tab.ts:1043` — verified, Electron 41 answers *"Current display surface not available for capture"* |
| `webContents.sendInputEvent()` **requires the window to be focused** | `electron.d.ts:18068` |
| `webContents.debugger` **detaches the moment DevTools is opened on that WebContents** | `electron.d.ts:7439` |
| `debugger.sendCommand` and the `message` event both carry a `sessionId` | `electron.d.ts:7484` — nested (OOPIF / worker) sessions are routable |
| `executeJavaScriptInIsolatedWorld` exists on `WebContents` | `electron.d.ts:17684` |
| Downloads are already refused on the shared **and** the isolated guest sessions | `browser-tab.ts:412`, `browser-isolation.ts:90` |
| A password field's `value` is already dropped before anything can reach an agent | `selector.ts:302`; the recorder sends `{secret: true}` and no value, `browser-record-preload.ts:163` |
| ⌘R on the app window destroys **every** browser tab, deliberately | `browser-tab.ts:609` `hostDocumentReplaced` |
| The `deck-control` MCP server refuses any request that carries an `Origin` header | `server.ts:23` — so a driven web page cannot reach the app's own control plane |

So his *"if the current one is exactly like that way then no need to change it"* does not
apply. All of it has to be built.

---

## 1. The verdict

**Hybrid, and the split is not a compromise — it is the only shape that survives both
requirements.**

- **The agent's surface is tools.** Five of them, in `deck-control`, tiered, budgeted,
  gated and logged exactly like the fourteen that already exist. The agent never holds a
  Playwright handle, never writes a selector expression that gets `eval`'d, never opens a
  socket.
- **The engine behind those tools is real Playwright**, running **inside the Electron main
  process**, driving the app's own tabs.
- **Chromium's `--remote-debugging-port` is never opened.** Playwright reaches the tabs
  through a bridge this app writes and owns, whose upstream is `webContents.debugger` and
  whose target table contains browser tabs and nothing else. §2 is why that is not
  optional.

### Why the tool surface is not negotiable

The brief frames this as *"the full Playwright API — which is the thing he is actually
asking for and the thing a hand-rolled tool surface will never match."* Half of that is
right and the half that is wrong matters.

The agent is a CLI with MCP tools. Whatever is underneath, what the model sees on every turn
is a handful of JSON schemas. Auto-waiting, selector engines, frame traversal and network
interception are value to *the code that implements those schemas* — they are not value the
model can spend, because the model cannot express them. Giving the agent Playwright directly
would mean giving it a way to run arbitrary code against a browser holding his live logins,
outside the tier system, outside the budgets, outside `actions.jsonl`. That is a strictly
larger power than any tool in `catalogue.ts`, handed over as a convenience.

So the correct reading of his request is: *the driving should be as good as Playwright's*.
Not: *the agent should be a Playwright script.* Everything below follows from that.

### Why the engine should nevertheless be Playwright

Because the thing he actually complained about is stability, and most of what makes a
hand-rolled driver unstable is the part Playwright already solved: actionability. "Click
this" is not one operation. It is: resolve the selector, wait for the node to be attached,
wait for it to be visible, wait for its bounding box to stop moving between two animation
frames, wait for it to be enabled, hit-test the point to confirm the node actually receives
the event, then dispatch — and retry the whole chain when any step invalidates. A driver
that skips that is a driver that clicks the spinner overlay, or the button one frame before
it moves, and reports success. That is exactly the shape of "it goes back many times".

Re-implementing it is not impossible. Re-implementing it *well* is a library, and this
repository's own rule about not shipping a thing that only looks like it works applies
harder here than anywhere: a flaky driver fails silently, on someone else's site, in a way
no typecheck catches.

### The trade-off being accepted, stated plainly

Playwright cannot be given a message-passing function. Its public API takes a CDP endpoint
URL. So using it at all means standing up a **browser-level CDP endpoint that this app
implements** — enough of `Target.*` and `Browser.getVersion` for `connectOverCDP` to
complete its handshake and enumerate one page. That is real work, it is coupled to a library
we do not control, and it is the single highest-risk item in this design.

### The spike that decides it, and the criterion

**Before writing any tool, spend two days on exactly this:** an Electron main process that
stands up the bridge in §2.3, and a `chromium.connectOverCDP()` that reaches one
`WebContentsView`, navigates it, fills a field, clicks a button and reads text back.

It passes if all four are true:

1. `connectOverCDP` completes and `context.pages()` contains exactly the one drivable tab.
2. `page.click()` / `page.fill()` / `page.textContent()` work with auto-waiting intact —
   verified against a page with a deliberately delayed, animated button.
3. The bridge's implemented surface is **under roughly 400 lines** and does not require
   pinning to a Playwright patch version.
4. Nothing on the app's renderer target is reachable through it (§2.5's test).

It fails if the bridge has to grow protocol emulation to chase Playwright's internals, or if
it only works against one exact Playwright release.

**If it fails, do not force it.** Ship the identical five tools backed by a small in-house
driver written directly on `webContents.debugger` — `Input.dispatchMouseEvent`,
`Input.insertText`, `DOM.querySelector`, `Runtime.callFunctionOn` against a
main-process-authored script — with one honest actionability loop (attached → visible →
box stable across two frames → enabled → hit-test) and a fixed retry budget. It will be
worse than Playwright and better than nothing, it has no third-party coupling, and *the
agent cannot tell the difference*, because the tool schemas are identical either way. That
is the entire reason the tool surface is the seam.

**The fallback's fallback, if the socket in §2.3 is judged unacceptable:** `puppeteer-core`
accepts a custom `transport` object in `ConnectOptions` — `{send, close, onmessage,
onclose}` — which removes the listener entirely. It still needs the same browser-level
`Target.*` emulation, and its waiting is weaker than Playwright's, so it is a second choice
rather than a first. It exists, it is worth knowing about, and it should not be reached for
until the socket has actually been objected to.

---

## 2. Security — and why option (a), as literally described, cannot ship

### 2.1 `--remote-debugging-port` is not a thing this product may open

Not "is risky". May not.

**1. Loopback is not a user boundary.** Every other local surface in this app is guarded by
a token in a 0600 file, and `server.ts:32` states the guarantee that buys, precisely:
another *user* on the machine cannot read it, another *process running as this user* can.
Chromium's DevTools endpoint has **no authentication at all**. On a shared machine — which
is the case this product is being told to survive — a second logged-in user can connect to
`127.0.0.1:<port>` opened by the first. Opening it demotes the app's own stated boundary
from *"another user cannot"* to *"another user can"*, silently, for everyone.

**2. The renderer target is on that port, and it holds the preload bridge.** One
`Runtime.evaluate` in the app's own renderer reaches `window.deck` and therefore the whole
`ipcMain` surface: start a session, write settings, read every transcript, enumerate paired
devices, drive the relay. Every guarantee in `control.ts` — the tier check, the escalation
rules, the budget windows, the consent gate, the row written in a `finally` — is bypassed by
a TCP connection. The dispatcher's own header says *"there is no lower door"*. This would be
one.

**3. A filtering proxy in front of an open port is theatre.** If the port is open, the proxy
is a suggestion: anything that can reach the proxy can reach the port beside it. A filtering
proxy only buys anything when the thing it filters is otherwise unreachable — which is
exactly the design in §2.3, and is why that design has no port at all.

**4. It cannot even be turned on without a relaunch.** `--remote-debugging-port` must be set
before `app.whenReady()`; there is no runtime API. "Enable browser driving" would mean
"restart the app", for a feature whose entire selling point is that nothing restarts.

**5. A per-session ephemeral port does not help.** Ephemeral means unpredictable, not
authenticated. It is the same unguarded socket for as long as it is open, and the whole
point of driving is that it stays open for hours.

### 2.2 What the port is *not* vulnerable to, said precisely

Worth stating because it is the scenario people fear first, and it is genuinely covered:

- Chromium refuses a DevTools WebSocket handshake that carries an `Origin` header unless
  `--remote-allow-origins` matches (Chrome 111+). Every browser sends one. So **a malicious
  page open in the built-in browser cannot connect to the debugger**, even with the port
  open.
- The HTTP JSON endpoints require the `Host` header to be a loopback literal, which refuses
  DNS rebinding, and `/json/new` requires `PUT`, which killed the classic
  `<img src="http://localhost:9222/json/new?url=file:///etc/passwd">` attack.

None of that helps against a local process, or a second local user. That is the threat that
matters here, and it is the one that is not addressed.

### 2.3 What is built instead: `deck-bridge`

A browser-level CDP endpoint **implemented by this app**, whose upstream is
`webContents.debugger` on drivable tabs only.

```
 Playwright (in the main process)
        │  ws://127.0.0.1:<ephemeral>/   Authorization: Bearer <32 random bytes>
        ▼
 browser-cdp.ts ── target table ── deny-list ── navigation re-check
        │
        │  wc.debugger.sendCommand(method, params, sessionId)
        ▼
 the one drivable tab's WebContentsView          the app's renderer:  never attached
```

**The listener.** `127.0.0.1`, port `0`. It starts listening **at the moment the app is
about to dial it** and stops listening **the instant one socket is accepted** — a window of
milliseconds, one accept, ever. The bearer token is 32 bytes from `randomBytes`, compared in
constant time, held in memory only, never written to disk, never in a URL (Playwright's
`connectOverCDP` takes a `headers` option, and a `ws://` endpoint URL skips the
`/json/version` probe, so there is exactly one connection to make). An `Origin` header is
refused outright, as in `server.ts`. The `Host` header must be a loopback literal.

That is stronger than the token file the rest of the app relies on: there is no file to
read, and the socket is not there to be scanned.

**The target table.** Built from the `tabs` map in `browser-tab.ts` — not from
`webContents.getAllWebContents()`. That is the difference between a filter and a structural
impossibility. The bridge holds `WebContents` objects it was handed by the drive module;
there is no code path that could produce the renderer's. Adding one would require somebody
to write a new function whose only purpose is to do that.

**What the bridge implements itself** (the root session — this is the spike's scope):

| Method | Answer |
|---|---|
| `Browser.getVersion` | synthesized from `process.versions.chrome` |
| `Target.getTargets`, `Target.getTargetInfo`, `Target.setDiscoverTargets` | the one drivable tab |
| `Target.setAutoAttach` (flatten) | emits `Target.attachedToTarget` for that tab; **`waitForDebuggerOnStart` is forced to `false`** — a target that waits for a debugger our synthetic root never releases is a page that hangs before its first script, which is a hang nobody would diagnose |
| `Target.attachToTarget` / `detachFromTarget` | attach/detach the Electron debugger, mint/retire a sessionId |
| `Target.getBrowserContexts` | one, the guest partition |

**Everything else with a `sessionId`** is forwarded verbatim to
`wc.debugger.sendCommand(method, params, sessionId)`, and every
`debugger.on('message', …, sessionId)` is wrapped and pushed back. Nested sessions from a
page's own auto-attach (OOPIFs, workers) pass through unchanged, because Electron accepts
the nested sessionId on the way back down.

### 2.4 The deny-list, which is at the protocol level and not in the tools

Refused by the bridge for **every** caller at **every** time, with a CDP error. This is
below the tool layer on purpose: a Playwright version bump that starts calling something new
must not be able to widen what the app can do, and an internal retry loop must not be able
to land what a tool declined.

| Denied | Why |
|---|---|
| `Browser.close`, `Target.closeTarget`, `Target.createTarget` | closing the browser is the single biggest cause of the instability he describes (§4). Tabs are created and closed by people, through the app. |
| `Target.createBrowserContext`, `Target.disposeBrowserContext` | a context this app did not make is a cookie jar nothing cleans up |
| `Network.getAllCookies`, `Network.getCookies`, `Storage.getCookies`, `Storage.getStorageKeyForFrame`, `Storage.clearDataForOrigin` | `browser-session.ts` goes to deliberate length to keep cookie *values* out of the renderer — *"those values are session tokens — the literal credentials"*. CDP would hand them over in one call. |
| `Page.setDownloadBehavior`, `Browser.setDownloadBehavior` | `will-download` is prevented on both guest sessions; these two re-enable it and let the caller choose the directory. A concrete escalation from "drive a page" to "write files anywhere". |
| `DOM.setFileInputFiles` | reads his disk into a website |
| `Browser.grantPermissions`, `Browser.setPermission` | the session handler refuses camera, mic, clipboard and notifications with no UI to ask. These re-grant them. |
| `Page.bringToFront`, `Browser.setWindowBounds` | focus and window geometry belong to the person (§3) |
| `Page.printToPDF`, `Page.setInterceptFileChooserDialog` | writes files; opens native dialogs over the app |
| `Fetch.*`, `Network.setRequestInterception` | request interception is how an agent reads `Authorization` headers. Not in v1, and probably not ever (§8). |
| `Emulation.setDeviceMetricsOverride` where it would resize | changes the page's viewport under a person who may be reading it |

**And one argument check rather than a method ban:** `Page.navigate` and
`Page.navigateToHistoryEntry` are re-validated against `isNavigationAllowed()` from
`browser-url.ts`. This is not belt-and-braces. The existing `file://` refusal is wired to
`will-navigate` / `will-frame-navigate` / `will-redirect`, and those fire for
renderer-initiated navigations — a browser-initiated CDP `Page.navigate` is a *different
door*, and walks straight past the guard `browser-tab.ts:721` exists to be. **Verify this
against a real Electron before relying on the re-check being redundant; the re-check ships
either way.**

### 2.5 The test that has to exist, or none of this is true

Three, and they are cheap:

1. **`browser-cdp.renderer.test.ts`** — construct the bridge with a target table containing
   one guest `WebContents`, assert that `Target.getTargets` returns exactly one entry, that
   `Target.attachToTarget` on any other id is refused, and that there is no exported
   function that accepts a `WebContents` from outside the drive registry.
2. **`browser-cdp.deny.test.ts`** — every method in the table above, asserted refused, by
   name, in a list a reviewer can read against the table.
3. **`browser-cdp.navigate.test.ts`** — `Page.navigate` to `file:///etc/passwd`,
   `devtools://`, `chrome://settings` and a `javascript:` URL, all refused.

### 2.6 Residual risk, stated rather than implied

- **A local attacker who can read this process's memory or attach a native debugger to it
  owns the drive.** They also already own the app by every other route, so this adds
  nothing. The token being in memory rather than in a file is what makes that the *only*
  route.
- **The agent can read any page it navigated to, in his logged-in session.** That is the
  feature. The mitigations are that it can only reach a tab it opened itself (§5), that the
  first mutating action on a public origin is confirmed by him (§6), and that every call is
  in `actions.jsonl`.
- **A driven page can detect that it is being driven** — CDP attach is observable by timing
  and by `Runtime` side channels. Not a security problem; a scraping problem, and worth
  knowing before somebody reports it as a bug.
- **`Runtime.evaluate` exists on the wire, because Playwright needs it.** The agent has no
  tool that reaches it (§7). Between the bridge and the model there is a fixed set of five
  schemas and a main-process-authored script; the day somebody adds a sixth tool that takes
  an expression, this whole document is void.

---

## 3. The handover — the part he actually asked for

He described two browsers because that is what the tools force. One where the agent works,
one where he types the password. Here there is one page and a **baton**.

### 3.1 Three states, held in the main process

`src/main/browser-drive.ts` holds one enum per drivable tab:

| State | Who has the page | What the bridge does |
|---|---|---|
| `idle` | nobody | no debugger attached |
| `agent` | the driver | commands pass, subject to §2.4 |
| `human` | the person | **every command for that target is refused**, including reads |

`human` refusing *reads* is the whole enforcement story for the password, and it is worth
being blunt about why it is not just mutations: a screenshot taken while he is typing is the
leak. So during `human` the agent has no `Runtime.evaluate`, no `Page.captureScreenshot`, no
`DOM.getDocument`, no `Network.*`. **You cannot redact what was never produced.**

The refusal happens at the bridge, not in the tool. A tool that politely declines is a
policy; a bridge that returns a CDP error is a mechanism, and Playwright's internal retries
hit the mechanism.

### 3.2 How the agent waits instead of racing

`browser.handover(prompt)`:

1. Flips the tab to `human`.
2. Focuses the window and selects the tab. **This is the one place in the entire feature
   where taking focus is correct** — the app is asking for the person, so putting the
   question where they are looking is the point. Focus never travels the other way: nothing
   the agent does afterwards raises the window, and `Page.bringToFront` is denied at all
   times.
3. Draws the banner (§3.3).
4. **Blocks.** The tool call does not return until he answers or the wait window closes.

Reuse `ConsentBroker` rather than inventing a second waiting mechanism — it already is *"a
real question, put to a real person, that defaults to no"*, with a timeout, a max-pending
cap, `approver-gone` when the window closes and `shutting-down` on quit. Every one of those
is the right behaviour here too.

**The timeout problem, and its answer.** `consent.ts` uses 120 s and `server.ts` says at
length why that must stay well under the MCP client's own tool timeout. Signing into an
Apple ID with 2FA on a phone takes longer than that. So:

- The **state** lives in the main process and is durable: the banner stays up, the baton
  stays with him, for as long as it takes.
- The **tool call** is a bounded window onto that state — default 90 s — and when it expires
  it returns `{ resumed: false, reason: 'still-waiting' }`.
- The agent is told, in the tool's own description, to call `browser.handover` again to keep
  waiting, or to say something to him in the chat. It is not told "failed", because a model
  told a thing failed goes looking for another way to do it — that is the exact lesson
  `refusalSentence('not-permitted-unattended')` was written from.

Nothing resets. He can take four minutes and the fifth call to `browser.handover` picks up
the same live wait.

### 3.3 How he knows, and how he says "done, carry on"

- The browser workspace's **toolbar row** carries a state chip: `Agent driving · clicking
  "Sign in"` / `Your turn`. It is in the app's own chrome, not over the page, because
  `overlay-watch.ts` is the standing essay on why nothing HTML can be drawn above a
  `WebContentsView` — *"you cannot fix this with CSS"* — and because putting it in the
  toolbar means the page's rectangle never changes and the site never reflows.
- In `human` state the chip becomes a bar with the agent's sentence and two buttons:
  **Done, carry on** and **Stop — I'll take it from here**. Cancel is a refusal to the
  agent, not a resume.
- **No keyboard shortcut for Done.** A click, deliberately. `DRIVING-MODE.md` gives Space to
  a tour because a tour is passive; a handover is somebody typing a password, and a
  keystroke is precisely what gets hit by accident mid-password.
- If the window is not focused when the handover starts, post one notification through the
  existing `os-notifications.ts`. One. Not a repeat.

**Taking it back without being asked** — the *"I do my step on the Chromium which is
attached to your Playwright"* case — needs no gesture. Any real interaction with the guest
page while the state is `agent` flips it to `human` immediately, and the agent's next
command is refused with *"the person took over"*. This mirrors `DRIVING-MODE.md` §8's
`pointerdown anywhere → pause`, which is already the house pattern for exactly this.

**The hard part, honestly:** telling his input from the driver's. CDP-dispatched input is
`isTrusted: true` — that is why it works at all — so the page cannot tell them apart, and
neither can a capture-phase listener. Two candidate mechanisms, and the spike decides:

- *Preferred, if it holds:* `webContents.on('input-event')` / `before-input-event` may not
  fire for CDP-dispatched input, since that enters the pipeline at a different point.
  **Verify on real Electron 41.** If true, it is a clean signal with no heuristic in it.
- *Otherwise:* correlate against a short ring of what the driver itself just dispatched —
  match on type, coordinates and a tight time window — and treat **anything that does not
  match as human**. The failure directions are not symmetric: mis-reading a synthetic event
  as human parks the agent and costs a retry; mis-reading a human keystroke as synthetic
  means the agent keeps typing while he does. Default to parking.

### 3.4 What the agent sees of what he did — five mechanisms, not five intentions

The rule: **a password must never enter the agent's transcript, `actions.jsonl`, or a
screenshot the agent reads.** How that is true:

1. **There is no arbitrary-evaluation tool. There never will be.** This is the load-bearing
   one. `browser.read` runs a fixed script this repository wrote, in an **isolated world**
   (`executeJavaScriptInIsolatedWorld`, so the page cannot shadow the functions it uses),
   and its output goes through `parseCapture()` in `selector.ts` before it can reach an
   agent's prompt — the same gate the inspector already passes through. If a later tool ever
   takes a free-form expression, every other line in this section becomes decorative.
2. **The bridge is shut during `human`** (§3.1). The interval is unobservable.
3. **A secret field's value never crosses, in any state.** `selector.ts:302` already drops
   `value` for `input[type=password]`. Extend the same predicate to `autocomplete`
   containing `current-password`, `new-password` or `one-time-code`, and to
   `input[type=file]` — the recorder already treats file inputs as secret for the same
   reason, *"the value is a path on the user's disk"*. `browser.read` reports such a field
   as `{kind: 'input', secret: true}` with no value, so the agent knows it is there and
   knows to hand over.
4. **`browser.step` refuses to type into a secret field, full stop.** Not "should not" — the
   verb is refused with `Refused('not-permitted', …)` naming the handover as the way. The
   agent therefore cannot type a credential even if it somehow had one, which makes the
   handover the *only* path a password can take, which is what he described.
5. **Screenshots are masked in the main process, before the PNG exists anywhere readable.**
   `browser.screenshot` asks the page (isolated world, our script) for the rects of every
   secret field, paints them out on the buffer — `marked-image.ts` already draws on PNGs in
   main — and only then writes the file and returns the path. This matters even though the
   agent is shut out during `human`: a password manager leaves the dots, a one-time-code
   field shows digits in clear, and a "show password" toggle shows the password.
   Screenshots go to the copilot's own folder, never to the person's screenshot directory.

**And the sixth, which is a change to a shared file and has to be handed back as a wiring
instruction rather than made here.** `control.ts` logs `scrubArgs(args)` for every call.
`scrubArgs` redacts by *key name* against `SECRET_KEY`, and `SECRET_KEY` does not match
`value` or `text` — so `browser.step {verb: 'type', value: 'hunter2'}` would land in
`actions.jsonl` verbatim. Blanket-redacting `value` globally is wrong; it is far too common
a key.

The fix is one optional member on `ToolSpec`:

```ts
/**
 * Replace the arguments before they are logged.
 *
 * `scrubArgs` redacts by key name, which is right for a tool whose secrets are
 * *named* like secrets. A page's form field is not: `sessions.send` deliberately
 * logs its `text` so the row says what was typed, and `browser.step` must
 * deliberately not.
 */
redactArgs?(args: Record<string, unknown>): Record<string, unknown>
```

applied in `DeckControl.call` immediately before `scrubArgs`. `browser.step` returns
`{verb, selector, chars: value.length}`. Its `summary()` sentence — which becomes both the
dialog text and the log's `detail` — reads *"Type 14 characters into the password field on
example.com"* and never the characters. The contrast with `sessions.send`, which quotes its
text on purpose, is the point: different call, different rule, and the reason is that a
prompt to an agent is a thing a person needs to be able to read back, and a form value is
not.

**The test, with a sentinel.** A fixture page with `<input type="password">` containing a
known unlikely string. Assert it appears in: no tool result, no `actions.jsonl` row, no
`ToolOutput.summary`, and — by sampling the centre pixel of the field's rect — not in the
screenshot PNG.

---

## 4. Stability — diagnosing "it goes back many times, turns off"

### 4.1 The real causes, and which ones vanish here

| Cause | Status in Terminal Deck |
|---|---|
| **A throwaway Chromium per task.** `chromium.launch()` makes a fresh profile directory; the cookies from the last run are not in it, so every task starts logged out. | **Structurally gone.** There is one partition, `persist:terminaldeck-browser`, and it is the same one his own browsing uses. Verified persistent on 41.10.5. |
| **`browser.close()` in a `finally`.** The tidy-up that takes the session with it. This is the single most common cause of "it turns off". | **Structurally gone, twice over.** `Browser.close` and `Target.closeTarget` are denied at the bridge, and no tool closes a tab. Closing a tab stays a human act. |
| **Non-persistent cookies die when the window goes.** His own note about the Deck Browser says it in those words — Apple's sessions are session cookies, the window must stay open. | **Mostly gone, and the remainder is honest.** The window is the app; it stays open as long as he is working. A quit still ends session cookies, and that is correct behaviour rather than a bug — say so in the UI rather than pretending otherwise. |
| **`launchPersistentContext` against a profile a real Chrome also has open** → `SingletonLock`, or a corrupted profile. | **Not applicable.** The partition belongs to this app alone. |
| **A disconnected CDP session**, usually because the browser process was recycled underneath it. | **Replaced by three specific, nameable causes — see §4.2.** Which is better than one vague one. |
| **Navigation races** — a click that navigates, and the next command aimed at an execution context that no longer exists. | **Partly handled by Playwright, partly by us.** The app already knows, per tab, whether a navigation is in flight: `wireGuestEvents` wires `did-start-navigation`, `did-navigate`, `dom-ready`, `did-stop-loading` and `did-fail-load`. So "has this tab settled" is a main-process fact, not a heuristic, and every tool waits on it rather than on a sleep. |

### 4.2 What still needs designing around

**1. DevTools detaches the debugger.** `electron.d.ts:7439` — opening DevTools on an
attached WebContents terminates the debugging session. `browser-view:devtools` is a button a
person can press, on the tab the agent is driving. Nobody would find this until it happened
in front of a client. Design: while the state is `agent`, `browser-view:devtools` is refused
with a sentence naming the drive; while `human` or `idle`, opening DevTools ends the drive
cleanly and the agent is told why.

**2. ⌘R destroys every tab.** `hostDocumentReplaced` in `browser-tab.ts:609` is deliberate
and correct — a view whose renderer has gone has nobody to position it. It also ends any
drive instantly. The drive must not attempt to survive it: it ends, it writes its row, and
the agent gets a refusal naming the reload. A drive that re-armed itself after a reload
would be a page that starts moving on its own, which `DRIVING-MODE.md` §8 already identifies
as *"the single behaviour that would make somebody uninstall"*.

**3. Guest process crash.** `render-process-gone` already fires per tab and already becomes
a `crash()` with the document replaced by Chromium's error page. The driver detaches on it
and the tool returns a refusal naming the crash rather than timing out.

**4. `waitForDebuggerOnStart`.** Forced false at the bridge (§2.3). If it is ever set true
and `Runtime.runIfWaitingForDebugger` is not sent, the page hangs before its first script
and looks exactly like a slow site.

**5. One drive at a time.** Two agents on one tab is the two-agents-one-worktree problem in
a different costume, and `catalogue.ts` already refuses that shape in
`refuseSecondSessionHere` for exactly the stated reason — *"nothing can tell afterwards
which one made which change"*. One tab, one driver, refused otherwise. In practice this is
free: `COPILOT-CAPABILITIES.md` §3.2 item 5 already means copilot-started sessions get no
`deck-control`, so only the one copilot can drive.

**6. Playwright drifting against Chromium 146.** The ongoing maintenance cost, and the
reason the tool schemas must never be Playwright-shaped. A `playwright-core` bump is a
version bump behind five stable schemas, or it is a product regression. Pin it, and put a
smoke test in CI that drives a local fixture page end to end.

**7. Nothing survives a restart.** Cookies do; the drive does not. On launch there is no
drive and no tab claimed by an agent. Say so rather than silently re-arming.

---

## 5. Which browser, and where

**Recommendation: a visible tab, in the shared persistent partition, that the agent creates
for itself — and never a tab he opened.**

- **The agent cannot name a tab.** There is no `tabId` argument anywhere in §6. It has *one*
  tab, the one `browser.open` gave it, and calling `browser.open` again navigates that same
  tab. This is worth more than it looks: it removes an entire class of "drove the wrong tab"
  failure, it removes the "a scrape hijacked the page I was reading" annoyance completely,
  and it is what makes reads safe at the `read` tier (§6) — the agent can only read pages it
  navigated to itself, so a read discloses nothing it did not already know.
- **Shared partition by default.** This is the whole point of combining his two browsers:
  the drive runs inside his logins. `browser.open({isolate: true})` uses
  `browser-isolation.ts`'s in-memory partition for the case where he explicitly does *not*
  want his cookies going to the site — a scrape of somewhere he happens to be logged into,
  or a second identity on a dev app. Default false.
- **Visible, and selected on creation.** He wants to watch it work.
- **But he may leave it.** Selecting another tab does **not** park the drive. The driven tab
  simply stops being composited and keeps working — `overlay-watch.ts` records that a
  non-composited `WebContentsView` *"keeps running, keeps its scroll position and its DOM"*.
  This is possible only because CDP `Input.*` does not require focus, where
  `sendInputEvent()` explicitly does (`electron.d.ts:18068`). That single API difference is
  what makes "watch it, then go do something else" work at all, and it is a second
  independent reason the driver is CDP-shaped.
- **Never a hidden tab he cannot find.** A tab that exists, is doing things, and does not
  appear in the strip is the same object `catalogue.ts` already refuses for sessions —
  *"a tab you did not open and cannot account for is the thing this app must not produce"*.
- **The tab is marked.** Its chip in the strip says who is driving.
- **Closing it is always available, and ends the drive.** No confirmation, no argument.

**The one honest limitation:** there is no visible cursor. CDP input does not move the OS
pointer, and nothing HTML can be drawn over a `WebContentsView`, so a driven click just
happens. The step text in the toolbar chip (*"clicking Sign in"*) is the only feedback, and
it is enough. Injecting a synthetic cursor element into the page was considered and rejected
— an isolated world shares the DOM, so it *could*, but adding an element to a page you are
also scraping pollutes the thing you came for.

**Verify before building:** whether `Page.captureScreenshot` works on a `WebContentsView`
that is not composited. `capturePage()` demonstrably does not (`browser-tab.ts:1043`). If
CDP has the same limitation, `browser.screenshot` must either briefly select the tab — which
is a focus steal and would need to be declared — or use `Page.startScreencast`. This changes
nothing structural and everything about how one tool feels.

---

## 6. The tool surface

Five tools. Fourteen exist, the count cap is twenty and the token ceiling is 8,000 with
~4,600 free. Five leaves one slot and should land the catalogue around 60% of the ceiling.

**That number is a target, not a claim.** `catalogue.test.ts` measures the assembled payload
and fails on the budget; whoever builds this updates the recorded figure with what it
actually measures, and if five terse tools do not fit, the instruction on
`MAX_CATALOGUE_TOKENS` stands — *disclose progressively, do not raise the number.*

They are contributed through `DeckControlOptions.extraTools`, which exists for exactly this
and whose comment says so: a feature that wants to give the copilot a capability reaches the
copilot *through* the dispatcher rather than beside it, so it is prechecked, tiered,
escalated, budgeted, gated and logged like everything else. Closures capture the drive
module directly; no new `DeckSurface` method is needed until the drive module exists.

| Tool | Wire | Tier | What it does |
|---|---|---|---|
| `browser.open` | `browser_open` | `act` | Point the agent's one tab at a URL, creating it if there is none. `{url, isolate?}`. Returns `{url, title, settled}`. |
| `browser.read` | `browser_read` | `read` | Observe. `{selector?, waitFor?, timeoutMs?}`. With no selector: url, title, and a compact outline of the interactive elements — role, label, selector, `secret` — which is what lets a model act without spending a screenshot. With one: the text at that selector. `waitFor` is what stops the model polling. |
| `browser.step` | `browser_step` | `act` → `alter` | One interaction. `{verb, selector, value?, key?}` where `verb` is `click \| type \| select \| check \| press \| submit`. |
| `browser.screenshot` | `browser_screenshot` | `read` | A masked PNG in the copilot's folder. Returns a path and dimensions, never image bytes. |
| `browser.handover` | `browser_handover` | `act` | Give the page to the person and wait. `{prompt}`. Returns `{resumed, url, title, waitedMs}` and nothing else. |

### The decisions inside that table

**`browser.step` is one tool, not six.** Six near-identical schemas cost roughly six times
the standing tokens of one with an enum, and the standing charge is paid on every turn
whether the tool is called or not. The verb set is not invented for this: it is `StepKind`
from `browser-steps.ts`, the same closed set the flow recorder already emits. That is worth
having on purpose — it means a recorded flow and a driven flow speak one vocabulary, with no
translation layer between them (§8).

**`browser.step` escalates by origin, not by click.** `act` on loopback and private-network
origins — that is a dev server on his own machine and it is the ordinary case. `alter` on
the **first** mutating step against a public origin, which asks him once: *"let the copilot
drive amazon.co.uk?"* Subsequent steps on that same origin are `act` for the rest of that
drive. The grant lapses the moment the tab's origin changes — including by a link click or a
server redirect — because the tab's URL is a main-process fact and does not need the model's
cooperation.

The reason it is not a dialog per click: that is confirmation fatigue, and `consent.ts` is
unambiguous that a gate which fires on everything is a gate nobody reads. The reason it is
not simply `act`: `DRIVING-MODE.md` put driving at `act` because *"nothing driving does
persists"*, and that argument is true of moving the app's own screen and flatly untrue of
driving a website. A click on a real site can send money. One question, at the point where
the answer is actually meaningful, is the right shape.

**`browser.read` and `browser.screenshot` are `read` tier.** They observe a page the agent
navigated to itself, in his logged-in session — which sounds like it should be higher until
you notice that the agent could only have got there by asking, and the asking is the `act`.
If the agent could adopt *his* tabs, both would have to be `alter`. It cannot (§5). This is
the second thing the one-tab rule buys.

**`browser.handover` is `act`, local-only and attended-only.** Both gates are checks in
`control.ts`, not sentences in an instruction file, and both are `DRIVING-MODE.md` §7's
gates applied to a surface with a sharper edge:

- `caller.kind !== 'local'` → `Refused('not-granted', …)`. A paired phone that can make this
  Mac raise a window saying *"type your password"*, inside his own trusted app chrome, is a
  remote phishing primitive with the best possible disguise. A remote `act` grant is a real
  thing somebody might hand out (`surface.ts:92`); this must not ride in on it.
- `attended: false` → `Refused('not-permitted-unattended', …)`. A routine at 03:00 asking a
  sleeping person for a password is the exact failure `surface.ts:174` was written from.

**No `tabId` anywhere.** See §5. It is also the cheapest single token saving in the table.

**No `browser.close`, no `browser.tabs`, no `browser.eval`, no `browser.cookies`.**

---

## 7. What this must never do

Each of these is a mechanism with a home, not a line in a prompt.

**Credentials.** The agent never types into a password, one-time-code or file field
(`browser.step` refuses). It never reads one back (`selector.ts`'s predicate, extended). It
never reads cookies, `localStorage`, `sessionStorage` or IndexedDB — the CDP domains are
denied at the bridge, and there is no tool that could ask. The only path a credential takes
is his own hands, through `browser.handover`, while the agent is shut out entirely.

**A page that can reach the app's own IPC.** The bridge's target table is built from the
browser-tab registry, never from `webContents.getAllWebContents()`, so the renderer that
holds the preload bridge is not merely filtered out — it is not representable. Guarded by
test (1) in §2.5. Separately, a driven page cannot reach the app's control plane over HTTP
either: `server.ts` refuses any request carrying an `Origin` header, and every request from
a page carries one.

**File downloads.** Already prevented on both guest sessions. The bridge additionally denies
`Page.setDownloadBehavior` and `Browser.setDownloadBehavior`, which is the pair that would
turn "drive a page" into "write a file to a directory the agent chose".

**`file://`, and every scheme that is not http(s).** `isNavigationAllowed()` is re-applied
to `Page.navigate` and `Page.navigateToHistoryEntry` at the bridge, because a
browser-initiated navigation does not pass through the `will-navigate` guard that refuses
`file:` today. Also refused: `devtools://`, `chrome://`, `javascript:`.

**The relay.** Driving is local-only, at every one of the five tools and not just the
handover. Nothing that arrives over the relay may open a tab, click a thing, read a page,
take a screenshot or raise a banner on this machine. `Caller.kind` is already carried
through `DeckControl.call` for precisely this class of decision.

**Unattended runs.** No routine drives a browser. What a routine may do is post an alert
offering to — the same `start: 'offer'` shape `DRIVING-MODE.md` §7 settled on.

**Recursion.** A copilot-started session cannot drive, because it does not get `deck-control`
at all (`COPILOT-CAPABILITIES.md` §3.2 item 5). Stated here so nobody "helpfully" widens it
when browser tools make it tempting.

**Driving through a consent dialog.** If a `deck-control:consent-request` arrives while the
state is `agent`, park to `human` and clear the drive's chrome. A permission prompt competing
for attention with a page that is moving on its own is a permission prompt nobody read.

---

## 8. What I would not build, and what is worth building next

**Would not build, now or later:**

- **`browser.eval`, or any tool taking a free-form expression.** It is the one addition that
  makes §3.4 false and §2.6 meaningless. If it is ever proposed, the answer is a new tool
  with a fixed script, not a general one.
- **`--remote-debugging-port`.** §2.1.
- **Request interception and response mocking**, even though Playwright hands them over for
  free. It is a large surface, it is how an agent ends up reading `Authorization` headers,
  and nobody asked for it.
- **A separate "agent profile".** The entire request is that the drive and the person share
  one session. Two profiles would be the two-browser problem rebuilt inside one app.
- **Letting the agent close tabs.** §4.1.
- **A headless or hidden tab pool.** §5.

**Would not build in v1, but should be next:**

- **Replaying a recorded flow.** `browser-steps.ts` already produces a list of steps in the
  exact vocabulary `browser.step` takes, and it already marks the password step
  `redacted: true` with no value. So a replay reaches that step, calls `browser.handover`
  with the recorder's own sentence — *"Type the password into the login form"* — waits for
  him, and carries on. That is his workflow, recorded once and repeatable, and it costs
  almost nothing on top of what is designed here. It is out of v1 only because it needs the
  drive to be boring first.
- **Multiple driving tabs.** Genuinely useful for scraping, and it reopens attribution,
  concurrency and "which one is he watching". After one tab is stable.

---

## 9. Build order, and the four things to verify on real Electron first

**Verify before writing anything.** All four are hours, not days, and every one of them can
invalidate a section above:

1. **Playwright `connectOverCDP` against a hand-rolled browser-level endpoint.** The spike in
   §1, with its four pass criteria. This decides the whole engine question.
2. **Does `Page.captureScreenshot` work on a `WebContentsView` that is not composited?**
   `capturePage()` does not. Decides how `browser.screenshot` behaves when he has switched
   tabs (§5).
3. **Does `webContents.on('input-event')` fire for CDP-dispatched input?** If it does not,
   §3.3's takeover signal is clean. If it does, it is a heuristic and has to default to
   parking.
4. **Does `will-navigate` / `will-redirect` fire for a CDP `Page.navigate`?** Decides whether
   the bridge's navigation re-check is the only guard or the second one. It ships either way.

**Then, in this order:**

1. `browser-drive.ts` — the state machine, the baton, one tab, no CDP at all yet. Testable
   as pure logic, like `shouldComposite`.
2. The banner and the chip in `BrowserWorkspace.tsx`, wired to a stubbed drive. Renderable
   in `.harness/` with no Electron — which `CLAUDE.md` records as *"the only thing that has
   reliably caught the real defects"*.
3. `browser-cdp.ts` — the bridge, with §2.5's three tests written first.
4. The engine behind the `PageDriver` interface: Playwright if the spike passed, the small
   in-house driver if it did not.
5. `deck-control/browser-tools.ts` — the five specs, contributed via `extraTools`, with the
   sentinel-password test.
6. The `redactArgs` hook on `ToolSpec` — a change to `catalogue.ts` and `control.ts`, so it
   is handed back as a wiring instruction under the parallel-work rule rather than made
   inside this feature's own files.

**And the thing to be honest about at every step:** the hard part of this is not driving a
page. It is that the page belongs to two people, and only one of them can be holding it at a
time. Everything in §3 is that problem, and it is the part that will still be being fixed
after the driving works.
