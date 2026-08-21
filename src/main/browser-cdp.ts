import { isNavigationAllowed } from './browser-url'

/**
 * The one door between the driver and Chromium's debugging protocol.
 *
 * Everything in this file is a *decision*, and every decision is a pure
 * function over strings so it can be driven from a test with no Electron
 * around it. `browser-driver.ts` is the only caller; it holds the
 * `WebContents` and does the sending, and it is not allowed to send anything
 * this file has not screened.
 *
 * ## Why the app's own debugging port is never opened
 *
 * `DRIVABLE-BROWSER.md` §2.1 makes the argument at length and it is not
 * repeated here, but the short form belongs where the code is:
 *
 *  - Chromium's `--remote-debugging-port` has **no authentication of any
 *    kind**. Every other local surface in this app is a token in a 0600 file,
 *    and `deck-control/server.ts` states the guarantee that buys — *another
 *    user cannot, another process running as this user can*. Opening the port
 *    demotes that to "another user can", silently, for everybody.
 *  - The app's **own renderer** is a target on that port, and it holds the
 *    preload bridge. One `Runtime.evaluate` there reaches `window.deck` and
 *    therefore every `ipcMain` handler: start a session, write settings, read
 *    a transcript, enumerate paired devices. `deck-control/control.ts` says of
 *    itself that *"there is no lower door"*. That would be one.
 *  - It cannot be switched on without a relaunch — the flag must precede
 *    `app.whenReady()` — for a feature whose whole selling point is that
 *    nothing restarts.
 *
 * So there is no port and no socket. The upstream is `webContents.debugger`,
 * which is an in-process message channel to one WebContents that this process
 * already holds a reference to. Nothing outside this process can reach it, so
 * there is nothing to authenticate and nothing to scan for.
 *
 * ## Allow-list first, deny-list second, and why both
 *
 * The design document specifies a deny-list, because it assumed Playwright
 * would be on the wire and Playwright needs most of the protocol. The engine
 * that shipped is this repository's own driver (see `browser-driver.ts`), which
 * sends a dozen methods and no more — so the primary gate here is an
 * **allow-list**, which is strictly stronger: a protocol domain nobody thought
 * about is refused by default rather than by having been remembered.
 *
 * The deny-list ships anyway, and it is not decoration. It is the thing that
 * still holds if somebody later widens the allow-list — swapping in Playwright
 * is the obvious reason — and it is the list a reviewer can read against §2.4
 * of the design. A method in both tables is refused; the deny check runs
 * second precisely so that a future edit to the allow-list cannot quietly
 * unlock `Page.setDownloadBehavior` by adding `Page.*`.
 *
 * ## What request interception is now for — 2026-08-21
 *
 * The deny-list used to carry the whole `Fetch` domain, with this reason: *"how
 * an agent ends up reading `Authorization` headers off somebody's logged-in
 * session. Nobody asked for it and §8 of the design says not to build it."*
 * Both halves of that have changed, and the entry is not removed quietly.
 *
 * Somebody did ask for it, with numbers. A real property scrape lost **16,498
 * floor plans** — not to being blocked, but to its own tooling *blocking images
 * to go faster*, which stopped every lazy-loader on the page and so stopped the
 * real image URLs from ever being written into the DOM. The fix is not to allow
 * the images through; it is to **answer the request cheaply** — hand the page a
 * valid, correctly-sized, transparent image out of this process, spend no
 * bandwidth, and let the loader advance. `Fetch.enable` plus
 * `Fetch.fulfillRequest` is the only mechanism Chromium has for that.
 * `Network.getResponseBody` is the second half: the data on a modern page is in
 * the JSON the page fetched for itself, not in its HTML.
 *
 * The `Authorization` argument still stands, and it is answered by construction
 * rather than by refusal. A `Fetch.requestPaused` event carries the request's
 * headers; `browser-network.ts` reads the URL and the resource type off it and
 * **nothing else**, records neither, and `browser-network.test.ts` asserts the
 * absence in the source rather than trusting it. No request header reaches a
 * capture file, a tool result or the action log.
 *
 * What is refused here instead is the part of the domain that would *write*:
 *
 *  - `Fetch.enable { handleAuthRequests: true }` — the door to
 *    `Fetch.continueWithAuth`, which composes a username and a password and
 *    sends them to a site. Refused at the argument, and `continueWithAuth`
 *    stays on the deny-list, so neither half exists without the other.
 *  - `requestStage: 'Response'` — response-stage interception, which is a
 *    strictly larger power than pausing a request, and is not what any of this
 *    needs.
 *  - An interception pattern naming `Document`, which would let a rule empty
 *    the page it was pointed at.
 *  - A fulfilled response carrying any header outside a five-name list. This is
 *    the sharp one: `Fetch.fulfillRequest` writes a response **into his
 *    session**, so `set-cookie` on one is this app minting a cookie in a jar he
 *    is signed into, and `location` is it redirecting him. An allow-list of
 *    header names is what makes "answer an image cheaply" unable to be anything
 *    else.
 *
 * ## The finding that makes the navigation re-check load-bearing
 *
 * `browser-tab.ts` refuses `file:`, `javascript:` and every non-http scheme by
 * preventing `will-navigate`, `will-frame-navigate` and `will-redirect`. Those
 * events fire for navigations the **renderer** starts.
 *
 * A CDP `Page.navigate` is a **browser-initiated** navigation and does not
 * fire them. This was measured on this machine rather than reasoned about —
 * Electron 41.10.5 / Chromium 146.0.7680.216, a `WebContentsView` in a
 * persistent partition with a `will-navigate` handler installed that calls
 * `preventDefault()` on everything:
 *
 *     Page.navigate → { frameId: …, isDownload: false, loaderId: … }
 *     will-navigate handlers that ran: none
 *     webContents.getURL() afterwards: "file:///etc/passwd"
 *
 * The guard did not fire and the read of the user's disk succeeded. So the
 * check below is not belt-and-braces behind an existing guard; for a
 * browser-initiated navigation it is **the only guard there is**. That is why
 * `Page.navigate` is absent from the allow-list, present in the deny-list, and
 * *additionally* argument-checked: three independent refusals, because the
 * consequence of getting it wrong is a website reading `file:///Users/…`.
 */

/* -------------------------------------------------------------- the state -- */

/**
 * Who is holding the page.
 *
 * One page, one baton. The whole of the handover in `DRIVABLE-BROWSER.md` §3 is
 * this three-valued field and the rule that `human` refuses **reads as well as
 * writes** — because a screenshot taken while somebody is typing a password is
 * the leak, and you cannot redact what was never produced.
 */
export type DriveState = 'idle' | 'agent' | 'human'

/* ------------------------------------------------------------ the tables -- */

/**
 * Everything the driver is allowed to send, and nothing else.
 *
 * Kept small deliberately. Reading the page does not appear here at all —
 * `browser-driver.ts` reads through `executeJavaScriptInIsolatedWorld`, which
 * is an Electron API rather than a protocol call, so `Runtime.evaluate` and
 * the whole `DOM.*` domain are simply not needed. Screenshots go through
 * `webContents.capturePage()` for the same reason, and for a second one:
 * `Page.captureScreenshot` was measured on Electron 41 to **never resolve** on
 * a `WebContentsView` that is not composited, where `capturePage()` returns a
 * correct 800×600 image in the same state. A protocol call that hangs forever
 * is worse than one that fails, and this feature exists because the current
 * arrangement is unstable.
 *
 * What is left is input dispatch, plus the three enables that make the input
 * domain live. `Input.*` is here rather than `webContents.sendInputEvent()`
 * for one specific reason: `sendInputEvent` requires the window to be focused
 * (`electron.d.ts:18068`), and CDP input does not. That single difference is
 * what makes "watch it work, then go and do something else in another tab"
 * possible at all — verified here, with the window explicitly blurred:
 *
 *     win.isFocused() === false
 *     Input.insertText  → the field's value became "asad"
 *     Input.dispatchMouseEvent ×2 → the button's click handler ran
 */
export const ALLOWED_METHODS: readonly string[] = [
  // Turning the domains on. `Page.enable` on a WebContentsView that has never
  // had a document **hangs and never answers** — measured; the first spike
  // written against this deadlocked there. `browser-driver.ts` loads
  // `about:blank` before attaching for that reason.
  'Page.enable',
  'Runtime.enable',
  // Input, which is the entire reason this channel exists.
  'Input.dispatchMouseEvent',
  'Input.dispatchKeyEvent',
  'Input.insertText',
  // Where the page is scrolled to, so a click can be aimed at viewport
  // coordinates after the element has been scrolled into view.
  'Page.getLayoutMetrics',
  /*
   * Request control and passive capture — the two halves of harvesting, added
   * 2026-08-21. See "What request interception is now for" below, which is the
   * argument for moving these across; this list is the smallest set that
   * implements it.
   *
   * `Fetch.enable` is additionally argument-checked, twice, and the fulfil is
   * checked a third time — see {@link screenCommand}. The powers this pair
   * would otherwise carry, HTTP authentication and response-stage interception,
   * are refused at the arguments rather than left to a comment.
   */
  'Fetch.enable',
  'Fetch.disable',
  'Fetch.continueRequest',
  'Fetch.fulfillRequest',
  'Fetch.failRequest',
  'Network.enable',
  'Network.disable',
  'Network.getResponseBody',
]

/**
 * Refused for every caller at every time, whatever the allow-list says.
 *
 * This is §2.4 of the design, transcribed. Each entry is a capability that
 * would turn "drive a page" into something else, and the reason is stated so
 * that anybody proposing to remove one has to argue with the reason rather
 * than with the list.
 */
export const DENIED_METHODS: readonly string[] = [
  /*
   * Closing things.
   *
   * `browser.close()` in a `finally` is the single most common cause of the
   * instability Asad described — *"it goes back many times, turns off"*. A tab
   * here is created and closed by a person, through the app, and the driver
   * has no vocabulary for ending one.
   */
  'Browser.close',
  'Target.closeTarget',
  'Target.createTarget',
  /*
   * Cookie jars this app did not make, which nothing would ever clean up.
   */
  'Target.createBrowserContext',
  'Target.disposeBrowserContext',
  /*
   * The credentials themselves.
   *
   * `browser-session.ts` goes to deliberate length to keep cookie *values* out
   * of the renderer — its words are *"those values are session tokens, the
   * literal credentials"*. Each of these hands them over in one call.
   */
  'Network.getAllCookies',
  'Network.getCookies',
  'Storage.getCookies',
  'Storage.getStorageKeyForFrame',
  'Storage.clearDataForOrigin',
  'Storage.getUsageAndQuota',
  /*
   * Downloads. A person clicking a link now gets one — `browser-downloads.ts`
   * takes `will-download` on both guest sessions and writes into one folder that
   * was chosen in the app. These two are still refused, and the distinction is
   * the whole point: they let *the caller* name the directory, which is a
   * concrete escalation from "drive a page" to "write files anywhere", and the
   * caller here is an agent rather than the person at the keyboard.
   */
  'Page.setDownloadBehavior',
  'Browser.setDownloadBehavior',
  /** Reads his disk into a website. */
  'DOM.setFileInputFiles',
  /*
   * Permissions the guest session handler refuses — camera, microphone,
   * clipboard, notifications — with no UI anywhere to ask. These re-grant them.
   */
  'Browser.grantPermissions',
  'Browser.setPermission',
  'Browser.resetPermissions',
  /** Focus and window geometry belong to the person, not to the driver. */
  'Page.bringToFront',
  'Browser.setWindowBounds',
  /** Writes a file; opens a native dialog over the app. */
  'Page.printToPDF',
  'Page.setInterceptFileChooserDialog',
  /*
   * The half of request interception that stays refused.
   *
   * The other half moved to the allow-list on 2026-08-21 and the argument for
   * it is in the header. These four did not, and each is refused for its own
   * reason rather than by association:
   *
   *  - `Fetch.continueWithAuth` answers an HTTP authentication challenge — a
   *    username and a password, composed by the caller, sent to a site. That is
   *    signing in on somebody's behalf, which is what `browser.handover` exists
   *    to refuse to do. It is also why `Fetch.enable { handleAuthRequests: true }`
   *    is refused at the arguments: turning it on with no way to answer would
   *    deadlock every authentication prompt on the page.
   *  - `Fetch.getResponseBody` reads a body at the *response* interception
   *    stage, which is a stage nothing here uses — capture reads finished
   *    bodies through the `Network` domain instead. A power that is not needed
   *    is a power that stays off; see the note on `Runtime.evaluate` below for
   *    the same argument made at greater length.
   *  - `Network.setRequestInterception` is the deprecated predecessor of
   *    `Fetch`, with no patterns and therefore no way to narrow what it pauses.
   *  - `Network.setExtraHTTPHeaders` writes headers onto every request the page
   *    makes, in his logged-in session. Reading what a page sends is one thing;
   *    composing what it sends is another, and nothing in harvesting needs it.
   */
  'Fetch.continueWithAuth',
  'Fetch.getResponseBody',
  'Network.setRequestInterception',
  'Network.setExtraHTTPHeaders',
  /** Changes the viewport under a person who may be reading the page. */
  'Emulation.setDeviceMetricsOverride',
  /*
   * Navigation. Denied *and* absent from the allow-list *and* argument-checked
   * below — see the header. A browser-initiated navigation walks past
   * `will-navigate`, which was measured rather than assumed, so this is the
   * only place a `file://` can be refused.
   */
  'Page.navigate',
  'Page.navigateToHistoryEntry',
  /*
   * Arbitrary evaluation on the wire.
   *
   * Not because the driver would misuse it — it is main-process code — but
   * because its presence is what would make a `browser.eval` tool a two-line
   * change one day. Reading happens through
   * `executeJavaScriptInIsolatedWorld` with a script this repository wrote;
   * there is no path from a model's string to a page's JavaScript, and this
   * entry is what keeps that true by construction rather than by intent.
   */
  'Runtime.evaluate',
  'Runtime.callFunctionOn',
  'Runtime.compileScript',
  'Page.addScriptToEvaluateOnNewDocument',
]

const ALLOWED = new Set(ALLOWED_METHODS)
const DENIED = new Set(DENIED_METHODS)

/**
 * Methods whose arguments carry a destination.
 *
 * Screened even though both are denied outright, because the denial and the
 * URL check answer different questions and only one of them survives somebody
 * widening the allow-list. A reviewer removing `Page.navigate` from
 * {@link DENIED_METHODS} — which is a reasonable thing to want, the day the
 * driver needs to drive a history entry — must still land in a world where
 * `file:///etc/passwd` is refused.
 */
const NAVIGATING_METHODS = new Set(['Page.navigate', 'Page.navigateToHistoryEntry'])

/**
 * Resource types an interception pattern may name.
 *
 * The seven `browser-fetch-rules.ts` offers, spelled again here rather than
 * imported, and the duplication is deliberate in this one direction: a security
 * gate that reads its vocabulary out of the module it polices can be widened by
 * editing that module. `browser-cdp.test.ts` asserts the two lists agree, so
 * there is one truth and two independent statements of it.
 *
 * `Document` is the absence that matters. A pattern naming it would let a rule
 * block or cheaply answer the page's own HTML, which is a rule that empties the
 * page somebody came to read.
 */
const INTERCEPTABLE_TYPES: ReadonlySet<string> = new Set([
  'Image',
  'Media',
  'Font',
  'Stylesheet',
  'Script',
  'XHR',
  'Fetch',
])

/**
 * Headers a fulfilled response may carry, and nothing else.
 *
 * A fulfilled response is written into the page's session by this process, so
 * every header on it is something this app is saying to his browser. Four of
 * these describe an empty placeholder and the fifth lets a cross-origin `fetch`
 * see it at all. What is not here is the whole reason the list exists:
 * `set-cookie` would mint a cookie in a jar he is signed into, `location` would
 * redirect him, `content-security-policy` would rewrite what the page may do,
 * and `set-cookie` in particular would do it invisibly.
 */
const FULFIL_HEADERS: ReadonlySet<string> = new Set([
  'content-type',
  'content-length',
  'cache-control',
  'access-control-allow-origin',
  'timing-allow-origin',
])

/** Test seam: the two tables above, for the cross-check against the rules module. */
export const SCREENED_RESOURCE_TYPES: readonly string[] = [...INTERCEPTABLE_TYPES]
export const SCREENED_FULFIL_HEADERS: readonly string[] = [...FULFIL_HEADERS]

/**
 * `Fetch.enable`, argument by argument.
 *
 * Everything refused here is a capability the *method* carries and the feature
 * does not need. A pattern list that is absent means "pause everything", which
 * includes the document, so it is refused too — narrowing is not an
 * optimisation here, it is how the document stays out of reach.
 */
function screenFetchEnable(params: Record<string, unknown>): Screening {
  if (params.handleAuthRequests === true) {
    return {
      ok: false,
      reason:
        'this app does not answer HTTP authentication challenges on a page. Fetch.continueWithAuth is ' +
        'refused for every caller, so handling them would leave every prompt on the page waiting for ever.',
    }
  }
  const patterns = params.patterns
  if (!Array.isArray(patterns) || patterns.length === 0) {
    return {
      ok: false,
      reason:
        'request interception must name the resource types it applies to. Without patterns it pauses ' +
        'every request in the page, including the document.',
    }
  }
  for (const raw of patterns) {
    const pattern = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const type = pattern.resourceType
    if (typeof type !== 'string' || !INTERCEPTABLE_TYPES.has(type)) {
      return {
        ok: false,
        reason: `${String(type)} is not a resource type this app will intercept`,
      }
    }
    const stage = pattern.requestStage
    if (stage !== undefined && stage !== 'Request') {
      return {
        ok: false,
        reason: 'only the request stage may be intercepted here; response-stage interception is refused',
      }
    }
  }
  return { ok: true }
}

/**
 * `Fetch.continueRequest`, which looks inert and is not.
 *
 * Letting a paused request carry on is the harmless-sounding half of
 * interception, and the method's arguments are anything but: `url`, `method`,
 * `postData` and `headers` all *replace* what the page asked for. A
 * `continueRequest` carrying a `headers` list is this app composing an
 * `Authorization` header on a request in his logged-in session — which is the
 * exact power the deny-list entry for this domain used to be about, reachable
 * through the door that was left open rather than the one that was watched.
 *
 * The driver sends `{ requestId }` and nothing else, so refusing the rest costs
 * it nothing and closes the hole by construction. `interceptResponse` is
 * refused for the same reason `requestStage: 'Response'` is: it is the other
 * spelling of the same escalation.
 */
function screenContinue(params: Record<string, unknown>): Screening {
  for (const key of ['url', 'method', 'postData', 'headers', 'binaryPostData']) {
    if (params[key] !== undefined) {
      return {
        ok: false,
        reason: `a paused request may be let through but not rewritten; ${key} is refused`,
      }
    }
  }
  if (params.interceptResponse === true) {
    return {
      ok: false,
      reason: 'only the request stage may be intercepted here; response-stage interception is refused',
    }
  }
  return { ok: true }
}

/**
 * `Fetch.fulfillRequest`, which is the one call here that writes.
 *
 * The status is bounded to the 2xx range and the headers to {@link
 * FULFIL_HEADERS}, so a fulfilled response can be an empty placeholder and
 * cannot be a redirect, a cookie, or a policy header.
 */
function screenFulfil(params: Record<string, unknown>): Screening {
  const code = params.responseCode
  if (typeof code !== 'number' || !Number.isInteger(code) || code < 200 || code > 299) {
    return {
      ok: false,
      reason: 'a request may only be answered cheaply with a 2xx response',
    }
  }
  const headers = params.responseHeaders
  if (headers !== undefined) {
    if (!Array.isArray(headers)) {
      return { ok: false, reason: 'responseHeaders must be a list of name/value pairs' }
    }
    for (const raw of headers) {
      const header = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
      const name = typeof header.name === 'string' ? header.name.toLowerCase() : ''
      if (!FULFIL_HEADERS.has(name)) {
        return {
          ok: false,
          reason: `a cheaply-answered request may not carry a ${name === '' ? 'nameless' : name} header`,
        }
      }
    }
  }
  if (params.binaryResponseHeaders !== undefined) {
    // The same header block, pre-encoded, which would walk straight past the
    // check above. There is no reason for the driver to send it.
    return { ok: false, reason: 'binaryResponseHeaders is not accepted here' }
  }
  return { ok: true }
}

/* ------------------------------------------------------------ the verdict -- */

export type Screening =
  | { ok: true }
  | { ok: false; reason: string }

/**
 * May this command be sent to this tab right now?
 *
 * Pure, ordered, and every branch is a refusal a test names. The order is the
 * design:
 *
 *  1. **The baton**, first, because it is the only check whose answer is about
 *     a *person* rather than about the call. During `human` the agent is shut
 *     out of reads as well as writes, and a refusal that arrived after the
 *     method check would have to be repeated in every future method table.
 *  2. **The allow-list**, which is the real gate.
 *  3. **The deny-list**, second so that widening (2) cannot silently unlock (3).
 *  4. **The arguments**, for the methods that carry a destination.
 *
 * `state` is passed rather than read, so the module has no ambient state and a
 * test can drive all three values without an app.
 */
export function screenCommand(input: {
  state: DriveState
  method: unknown
  params?: unknown
}): Screening {
  const { state, method } = input

  if (typeof method !== 'string' || method.length === 0) {
    return { ok: false, reason: 'a debugger command needs a method name' }
  }

  /*
   * The person has the page.
   *
   * Refusing here rather than in the tool is the whole enforcement story. A
   * tool that politely declines is a policy, and a policy is a sentence in a
   * file that a retry loop does not read; a channel that returns an error is a
   * mechanism, and every retry hits the mechanism. It refuses reads too — see
   * the note on {@link DriveState}.
   */
  if (state === 'human') {
    return {
      ok: false,
      reason:
        'the person is using this page right now, so nothing may be sent to it — not a click, not a ' +
        'keystroke and not a read. Wait for them to hand it back.',
    }
  }
  if (state === 'idle') {
    return { ok: false, reason: 'nothing is being driven, so there is no page to send this to' }
  }

  if (!ALLOWED.has(method)) {
    return {
      ok: false,
      reason: `${method} is not one of the commands this app will send to a page`,
    }
  }
  if (DENIED.has(method)) {
    // Unreachable while the two tables are disjoint, which `browser-cdp.test.ts`
    // asserts. It is here for the edit that makes them overlap.
    return { ok: false, reason: `${method} is refused for every caller at every time` }
  }

  const params = (typeof input.params === 'object' && input.params !== null
    ? (input.params as Record<string, unknown>)
    : {})

  if (NAVIGATING_METHODS.has(method)) {
    if (!isNavigationAllowed(params.url)) {
      return {
        ok: false,
        reason: 'only http and https addresses can be opened here',
      }
    }
  }

  /*
   * The two interception methods that carry a capability in their arguments.
   *
   * Same shape as the navigation check above and for the same reason: the
   * method name alone does not say what the call does. `Fetch.enable` with an
   * auth flag is a different power from `Fetch.enable` with an image pattern,
   * and `Fetch.fulfillRequest` with a `set-cookie` header is a different power
   * from one with a `content-type`.
   */
  if (method === 'Fetch.enable') return screenFetchEnable(params)
  if (method === 'Fetch.continueRequest') return screenContinue(params)
  if (method === 'Fetch.fulfillRequest') return screenFulfil(params)
  /*
   * `Fetch.failRequest` is deliberately not screened. Its only argument beyond
   * the id is `errorReason`, every value of which is a way of telling the page
   * the request did not happen — there is no spelling of it that reaches
   * anything outside that page.
   */

  return { ok: true }
}

/**
 * Is this a URL the drive may be pointed at?
 *
 * The same allow-list `browser-tab.ts` applies to a typed address, re-exported
 * through this module so that the drive's own navigation path — which is
 * `webContents.loadURL`, *not* `Page.navigate` — is screened by the same
 * function the protocol path is. Two spellings of one rule is how one of them
 * comes to be missing a scheme.
 */
export function isDrivableUrl(url: unknown): boolean {
  return isNavigationAllowed(url) && url !== 'about:blank'
}
