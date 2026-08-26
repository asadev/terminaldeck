import { isNavigationAllowed } from './browser-url'
import {
  MAX_PAGE_HEIGHT,
  MAX_PAGE_WIDTH,
  MAX_TOUCH_POINTS,
  MAX_WATCH_QUALITY,
  MAX_WATCH_WIDTH,
  MIN_PAGE_HEIGHT,
  MIN_PAGE_WIDTH,
  MIN_WATCH_QUALITY,
  MIN_WATCH_WIDTH,
} from './remote/protocol'

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
 * ## Back and forward, and the argument check that bought them — 2026-08-25
 *
 * `Page.navigateToHistoryEntry` was on the CDP deny-list for a reason that was
 * true as far as it went: it names an `entryId` rather than an address, so
 * `isNavigationAllowed` — which on this transport is *"the only guard there is"*
 * — had nothing to screen. The cost was that a phone driving a server's browser
 * had a working Reload and two buttons that answered *"this server's browser
 * cannot go back"*.
 *
 * It is allow-listed now, in a pair with `Page.getNavigationHistory`, and the
 * pairing is the argument. {@link screenHistoryEntry} verifies that the frame
 * names **one** entry by a non-negative integer id and carries **nothing else**
 * — in particular no `url`, since a `navigateToHistoryEntry` allowed to carry
 * one would be `Page.navigate` under a name nobody screens. What it cannot
 * verify is where that entry goes, or that it exists: an entry id is an index
 * into one target's own history, and this module is a pure function with no
 * target and no memory. So that half is done where it can be —
 * `HeadlessDriveHost.historyMove` reads the history for that target, takes the
 * neighbour in the direction asked for, and puts **its URL** through
 * `isNavigationAllowed` before naming its id. The address is screened by the
 * same function that screens a typed one; the id is only ever read back, never
 * composed, which is the same by-construction property `screenEvaluate` rests on
 * for the isolated world.
 *
 * The desktop refuses both and loses nothing — `navigateToHistoryEntry` by name
 * on its deny-list, `getNavigationHistory` by being on neither of its tables,
 * which is the default. Its back and forward are `webContents.navigationHistory`,
 * an Electron API rather than a protocol call, exactly as its reads and its
 * screenshots are.
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

/**
 * Which channel is carrying the command, and therefore which table screens it.
 *
 * `electron` is the desktop: the driver holds a `WebContents` and reads through
 * `executeJavaScriptInIsolatedWorld` and screenshots through `capturePage()`,
 * so the protocol it sends is tiny and the allow-list below is tiny with it.
 * `cdp` is the headless server: there is no Electron and no renderer, the
 * `--remote-debugging-pipe` is the only door, and so the reads, the screenshot,
 * the navigation and the target lifecycle all have to travel the protocol —
 * which is what {@link CDP_ALLOWED_METHODS} adds, each addition bought with an
 * argument check rather than a widening. The axis is passed rather than sensed,
 * so the module stays a pure function of its inputs and a test drives both
 * transports without a browser of either kind.
 */
export type Transport = 'electron' | 'cdp'

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
  /*
   * Touch, for the watch-and-drive path (wave-3). A phone watching a page here
   * sends genuine multi-touch gestures — a pinch, a two-finger scroll — and this
   * is where they land; a single tap still goes through `dispatchMouseEvent`
   * above, which needs no touch handler on the page and is the more reliable
   * path. SAFETY: the arguments carry only coordinates — no url, no path — and
   * the point count is bounded in {@link screenCommand}'s screencast branch, so
   * an unbounded `touchPoints` from a peer cannot become an unbounded array
   * dispatched into Chromium. Refused during `human` by the baton like every
   * other input.
   */
  'Input.dispatchTouchEvent',
  // Where the page is scrolled to, so a click can be aimed at viewport
  // coordinates after the element has been scrolled into view.
  'Page.getLayoutMetrics',
  /*
   * Screencast — the live view a phone or a second desktop watches over the
   * wire (wave-3). All three inherit into {@link CDP_ALLOWED_METHODS} through the
   * spread below, so the desktop's `WebContentsView` cast and the headless CDP
   * target both stream through one gate.
   *
   *  - `Page.startScreencast` is a READ (pixels leave the page), so it is refused
   *    during `human` by the baton in {@link screenCommand} — which is why the
   *    handover mask also stops the cast at the source before the baton flips.
   *    Its arguments carry a format, a quality, a width and a source-rate cap,
   *    each of which is a capability the feature bounds rather than a value the
   *    caller may choose freely — so they are argument-checked in the screencast
   *    branch: `jpeg` only (a PNG of a photo blows the relay's 96 KiB ceiling),
   *    quality and width inside the MIN/MAX the protocol sizes to that ceiling,
   *    a bounded height and a source rate of at least one.
   *  - `Page.stopScreencast` carries no capability in its arguments; it is here
   *    because the cast must be stoppable slightly *before* the baton flips to
   *    human (see the handover mask), while sends are still permitted, the same
   *    ordering the network suspend uses.
   *  - `Page.screencastFrameAck` carries only a `sessionId`; harmless, but it is
   *    a send, so during `human` it is refused too — the host stops acking, CDP
   *    stops producing, which is a correct secondary brake on the pixels.
   */
  'Page.startScreencast',
  'Page.stopScreencast',
  'Page.screencastFrameAck',
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

/* ------------------------------------------------ the tables, for the pipe -- */

/**
 * The same decisions, retold for the transport that has no Electron under it.
 *
 * On the desktop the driver reads a page through
 * `executeJavaScriptInIsolatedWorld` and screenshots it through `capturePage()`
 * — both Electron APIs, not protocol calls — so the electron tables above can
 * DENY `Runtime.evaluate`, `Page.captureScreenshot` and the whole `Target.*`
 * domain and lose nothing. On a headless server there is no Electron and no
 * renderer: the `--remote-debugging-pipe` is the only door, so the reads, the
 * screenshot, the navigation and the target lifecycle all have to travel the
 * protocol. This second table says yes to exactly those, and to nothing the
 * desktop would not also have wanted, and every new "yes" that carries a
 * capability in its arguments — navigate, evaluate, download, create-target,
 * cookie-read — is bought with an argument check in {@link screenCommand}
 * rather than a shrug. A method absent from both tables is refused by default:
 * the same allow-list-first discipline as the desktop.
 */
export const CDP_ALLOWED_METHODS: readonly string[] = [
  // Everything the desktop channel sends travels the pipe unchanged.
  ...ALLOWED_METHODS,
  /*
   * Navigation is the ONLY door on the server — there is no `loadURL`, because
   * there is no `WebContents`. It is still argument-checked by
   * `isNavigationAllowed` (via `NAVIGATING_METHODS`), which is the whole of the
   * `file://` protection here, exactly as the header describes for the desktop:
   * a browser-initiated navigate walks past `will-navigate`, so this check is
   * not belt-and-braces, it is the only guard there is.
   *
   * `Page.navigateToHistoryEntry` sits beside it now, with the pair of entries
   * below, and {@link screenHistoryEntry} says exactly what buying it cost.
   */
  'Page.navigate',
  /*
   * Back and forward, which a server could not do at all until 2026-08-25.
   *
   * `Page.navigateToHistoryEntry` was on the deny-list with a true reason — it
   * names an `entryId` rather than an address, so `isNavigationAllowed` has
   * nothing to screen — and the consequence was that a phone driving a server's
   * browser had Reload and two buttons that answered *"this server's browser
   * cannot go back"*. Two of the three controls on every browser toolbar ever
   * made.
   *
   * The pair is what makes it safe, and they are allow-listed together on
   * purpose: `Page.getNavigationHistory` is the only place an entry id can come
   * from, and it hands back the entry's **address** with it. The caller
   * (`HeadlessDriveHost.historyMove`) reads the history, takes the neighbour in
   * the direction asked for, screens *its URL* through the same
   * `isNavigationAllowed` a typed address passes, and only then names the id.
   * So the guard screens what it always screened — where the page is about to
   * be — and {@link screenHistoryEntry} screens the frame itself. Neither is
   * sufficient alone, which is why both are here.
   *
   * `Page.getNavigationHistory` is a read of one target's own entry list: the
   * addresses this app navigated it to, which the phone is already showing in
   * its window list. It carries no arguments and so needs no argument check.
   */
  'Page.getNavigationHistory',
  'Page.navigateToHistoryEntry',
  /*
   * Reading the page. An isolated world, made once per frame, then evaluation
   * inside it — never the main world, enforced by {@link screenEvaluate}. The
   * desktop's "no path from a model's string to page JS" property is upheld by
   * the seam contract: only `browser-drive-script.ts` strings reach the driver's
   * one isolated-world call, and its arguments are JSON.
   */
  'Page.createIsolatedWorld',
  'Runtime.evaluate',
  'Runtime.callFunctionOn',
  /*
   * The screenshot, over the wire. It was never denied on the desktop, only
   * unneeded — `capturePage()` did it, and `Page.captureScreenshot` was measured
   * to hang forever on a non-composited `WebContentsView`. A headless target
   * always composites, so the hang cannot happen here and this is the read path.
   */
  'Page.captureScreenshot',
  /*
   * The target and context lifecycle. Denied on the desktop because "a tab is
   * created and closed by a person, through the app" — but on a server there is
   * no person and no tab strip, and the DriveHost IS the tab authority. Targets
   * and contexts are made only inside the host's own named contexts and torn
   * down only by the host lifecycle; `Target.createTarget`'s URL is screened by
   * {@link screenCreateTarget}.
   */
  'Target.createTarget',
  'Target.closeTarget',
  'Target.attachToTarget',
  'Target.setAutoAttach',
  'Target.createBrowserContext',
  'Target.disposeBrowserContext',
  /*
   * Downloads, into the host's own directory and no other. Denied on the desktop
   * because the caller could name the directory — the concrete escalation from
   * "drive a page" to "write files anywhere". Here {@link screenDownloadBehavior}
   * pins `behavior:'allowAndName'` and requires the path to equal the
   * host-configured downloads dir, which the app supplies and the agent never
   * does.
   */
  'Browser.setDownloadBehavior',
  /*
   * Host preload delivery. There is no preload mechanism over CDP, so the guest
   * preload is delivered as a script that runs before every document, plus one
   * host-named binding. The script is the repository's own preload and the
   * binding name is fixed by the host — the same construction guarantee as the
   * evaluation path, not an open door to arbitrary injection.
   */
  'Page.addScriptToEvaluateOnNewDocument',
  'Runtime.addBinding',
  /*
   * The one genuine relaxation over the desktop deny-list: a SINGLE URL's
   * cookies, read to replay onto one asset request so a server scrape fetches
   * the logged-in copy rather than the logged-out one — "the jar is the whole
   * point of this browser". Scoped to exactly one http(s) URL in
   * {@link screenCommand}; the whole-jar `Network.getAllCookies` and the
   * context-wide `Storage.getCookies` stay on the deny-list below.
   */
  'Network.getCookies',
  /*
   * The viewport, and this is the one entry on this list whose desktop refusal is
   * about a **person** rather than about a power.
   *
   * `DENIED_METHODS` refuses `Emulation.setDeviceMetricsOverride` for every
   * caller on the Electron transport with one line — *"Changes the viewport under
   * a person who may be reading the page"* — and that line is exactly right for
   * the thing it is about. A `WebContentsView` on the desktop is a window on
   * somebody's screen. They may be halfway down it, mid-form, mid-sentence.
   * Reflowing it from a phone in another room is the app acting on its own, which
   * is the whole class of behaviour this file exists to make impossible.
   *
   * **A headless host has no such person.** There is no screen, no window, no
   * keyboard and nobody looking: the only thing that ever sees one of these pages
   * is a phone, over a screencast, and the viewport is the size of the hole that
   * phone is going to draw the picture into. Refusing here does not protect
   * anybody — it guarantees the page is laid out at a width nobody chose, which
   * is the defect:
   *
   * > *"it is too zoom, it's bigger than the normal view of the website whatever
   * > website we are browsing so keep it on 100 percent like a normal view of any
   * > website like proper normal dimensions."*
   *
   * So the entry moves for the headless transport **only**, and it stays on
   * `DENIED_METHODS` above so the desktop is unchanged; the two tables are read
   * by `transport` and `browser-cdp.test.ts` asserts each pair is disjoint. Like
   * every other "yes" over here that carries a capability in its arguments, it is
   * bought with an argument check rather than a shrug — {@link screenDeviceMetrics}
   * pins it to a plain viewport of a sane size and refuses every other power the
   * method carries: no mobile emulation, no fictional display, and no scale
   * factor other than one.
   *
   * `Emulation.clearDeviceMetricsOverride` is deliberately **not** here. Nothing
   * in this app calls it — a second `setDeviceMetricsOverride` replaces the first
   * — and this file's own rule about `Fetch.getResponseBody` applies unchanged:
   * *"A power that is not needed is a power that stays off."*
   */
  'Emulation.setDeviceMetricsOverride',
]

/**
 * Refused under CDP too, whatever the allow-list says.
 *
 * The desktop deny-list minus the entries a server legitimately needs, and
 * nothing added back that a server does not. The reasons that still hold, in one
 * breath: closing the browser is the instability he described; the whole-jar and
 * context-wide cookie reads are the literal credentials; a caller-named download
 * path writes files anywhere; `setFileInputFiles` reads his disk into a website;
 * the permission grants re-arm camera and microphone; `setExtraHTTPHeaders`
 * composes what his logged-in session sends; and response-stage interception and
 * HTTP auth are the larger powers the header refuses by construction. The
 * entries that LEFT this list relative to the desktop — navigate, evaluate,
 * capture, the target lifecycle, the host download behaviour, the single-URL
 * cookie read, the viewport override — each moved to {@link CDP_ALLOWED_METHODS}
 * with an argument check, never a bare allow.
 *
 * The viewport override is the newest of those and the only one whose desktop
 * refusal was never about a *power*: it is about a person at a screen, and a
 * headless host has none. Its entry in the allow-list above carries the whole
 * argument.
 */
export const CDP_DENIED_METHODS: readonly string[] = [
  'Browser.close',
  /*
   * The credentials, in bulk. `Network.getCookies` for one URL is allowed above;
   * these two are the whole jar and the whole context, which is the dump.
   */
  'Network.getAllCookies',
  'Storage.getCookies',
  'Storage.getStorageKeyForFrame',
  'Storage.clearDataForOrigin',
  'Storage.getUsageAndQuota',
  /* The deprecated, caller-named download door; the screened one is allowed. */
  'Page.setDownloadBehavior',
  'DOM.setFileInputFiles',
  'Browser.grantPermissions',
  'Browser.setPermission',
  'Browser.resetPermissions',
  'Page.bringToFront',
  'Browser.setWindowBounds',
  'Page.printToPDF',
  'Page.setInterceptFileChooserDialog',
  'Fetch.continueWithAuth',
  'Fetch.getResponseBody',
  'Network.setRequestInterception',
  'Network.setExtraHTTPHeaders',
  'Runtime.compileScript',
]

const CDP_ALLOWED = new Set(CDP_ALLOWED_METHODS)
const CDP_DENIED = new Set(CDP_DENIED_METHODS)

/**
 * Methods whose arguments carry a destination.
 *
 * Screened even though it is denied outright on the desktop, because the denial
 * and the URL check answer different questions and only one of them survives
 * somebody widening the allow-list. A reviewer removing `Page.navigate` from
 * {@link DENIED_METHODS} must still land in a world where `file:///etc/passwd`
 * is refused.
 *
 * `Page.navigateToHistoryEntry` used to be in this set and no longer is, and
 * that is not a relaxation: it never carried a `url`, so being here meant it was
 * refused for having no address rather than screened for having a bad one. It
 * has its own check — {@link screenHistoryEntry} — which is a different
 * question asked of a different argument.
 */
const NAVIGATING_METHODS = new Set(['Page.navigate'])

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

/* ---------------------------------------------- the CDP argument checkers -- */

/**
 * A context identifier that is actually present.
 *
 * A number is present when it is finite (a real execution-context id); a string
 * when it is non-empty (a `uniqueContextId` or an `objectId`). Everything else —
 * `undefined`, `null`, `''`, `NaN` — is absent, and absence is the main world.
 */
function namesAContext(value: unknown): boolean {
  if (typeof value === 'number') return Number.isFinite(value)
  if (typeof value === 'string') return value.length > 0
  return false
}

/**
 * `Runtime.evaluate` / `Runtime.callFunctionOn`, which must never touch the main
 * world.
 *
 * The main world is where the page's own scripts and its `window` live, and it
 * is the DEFAULT: an evaluation with no context named runs there. So the check
 * is not "which world" but "a world was named at all" — require an isolated
 * context id and the main world is refused by the same stroke. The id must name
 * a world made by `Page.createIsolatedWorld`; that it does is upheld by the seam
 * contract (the driver memoises exactly that id and reaches this call from
 * nowhere else), which is the same by-construction guarantee the desktop's
 * `executeJavaScriptInIsolatedWorld` gives — this is its protocol spelling.
 *
 * `Runtime.evaluate` names its world with `contextId` or `uniqueContextId`.
 * `Runtime.callFunctionOn` names it with `executionContextId`, `uniqueContextId`
 * or an `objectId` (a handle that already lives in a world). Each method is held
 * to the identifiers it actually accepts, so an `objectId` smuggled onto an
 * `evaluate` — which Chromium would ignore, dropping the call back to the main
 * world — does not pass.
 */
function screenEvaluate(method: string, params: Record<string, unknown>): Screening {
  const named =
    method === 'Runtime.callFunctionOn'
      ? namesAContext(params.executionContextId) ||
        namesAContext(params.uniqueContextId) ||
        namesAContext(params.objectId)
      : namesAContext(params.contextId) || namesAContext(params.uniqueContextId)
  if (!named) {
    return {
      ok: false,
      reason:
        'a page may only be evaluated inside an isolated world named by its context id, never the main ' +
        'world where the page’s own scripts and window live',
    }
  }
  return { ok: true }
}

/**
 * `Browser.setDownloadBehavior`, whose whole danger is the directory.
 *
 * The desktop denied this outright because the caller could name where the file
 * lands — "write files anywhere". Here it is allowed, and the escalation is
 * closed by pinning both arguments in the screening rather than trusting the
 * caller: the behaviour must be `allowAndName` (accept and keep the download,
 * the only mode the ledger understands) and the path must equal the
 * host-configured downloads directory, which the app supplies and the agent
 * never does. With no configured directory there is nothing to pin the path to,
 * so the call is refused rather than defaulted — the same discipline
 * `platform/paths.ts` takes when nothing installed a path.
 */
function screenDownloadBehavior(
  params: Record<string, unknown>,
  downloadsDir: string | undefined,
): Screening {
  if (typeof downloadsDir !== 'string' || downloadsDir.length === 0) {
    return {
      ok: false,
      reason: 'this host has no configured downloads directory, so a download behaviour cannot be pinned to one',
    }
  }
  if (params.behavior !== 'allowAndName') {
    return {
      ok: false,
      reason: "downloads are only ever accepted with behavior 'allowAndName', so the ledger keeps every file",
    }
  }
  if (params.downloadPath !== downloadsDir) {
    return {
      ok: false,
      reason: 'a download may only be written to this host’s downloads directory, which the app supplies rather than the caller',
    }
  }
  return { ok: true }
}

/**
 * `Page.navigateToHistoryEntry`, whose argument is not an address.
 *
 * ## What this check verifies
 *
 *  - The call names **one** entry, by an `entryId` that is a non-negative
 *    integer — the shape CDP's own `NavigationEntry.id` has. A missing, negative
 *    or fractional id is not an entry Chromium would find, so it is a caller
 *    that composed the frame rather than one that read it.
 *  - The call carries **nothing else**. That is the sharp half. `Page.navigate`
 *    is refused on the desktop and argument-checked on the server because a URL
 *    in a browser-initiated navigation walks past `will-navigate` — measured —
 *    and a `navigateToHistoryEntry` that was allowed to carry a `url` would be
 *    that same call under a name nobody screens. There is no spelling of this
 *    frame that reaches an address.
 *
 * ## What it still cannot verify, and what covers that instead
 *
 * It cannot say **where entry 4 goes**, or even whether entry 4 exists. An entry
 * id is an index into one target's own history: it means nothing to another
 * target, it is not stable across a navigation, and this function is a pure
 * screen over a method name and a bag of arguments with no target, no history
 * and no memory. Any check pretending otherwise would be a check that reads
 * true and holds nothing.
 *
 * So the part this cannot do is done where it *can* be done, one layer out, and
 * this method is on the allow-list because that layer exists:
 * `HeadlessDriveHost.historyMove` reads `Page.getNavigationHistory` for that
 * target, takes the neighbouring entry in the direction asked for, and puts its
 * **URL** through `isNavigationAllowed` before naming its id. The address is
 * screened by the same function that screens a typed one; the id is never
 * composed, only read back. A caller that named an id of its own would be
 * sending a frame no code in this repository constructs — which is the property
 * a reviewer can grep for, and the same by-construction argument
 * {@link screenEvaluate} rests on for the isolated world.
 */
function screenHistoryEntryParams(params: Record<string, unknown>): Screening {
  const entryId = params.entryId
  if (typeof entryId !== 'number' || !Number.isInteger(entryId) || entryId < 0) {
    return {
      ok: false,
      reason: 'a history move must name one entry of the page’s own history, by its id',
    }
  }
  for (const key of Object.keys(params)) {
    if (key === 'entryId') continue
    return {
      ok: false,
      reason: `a history move carries an entry id and nothing else; ${key} is refused`,
    }
  }
  return { ok: true }
}

/**
 * The same check, for the one caller that has to make it before this module
 * ever sees the frame.
 *
 * `HeadlessDriveHost.historyMove` sends `Page.navigateToHistoryEntry` on its own
 * transport — it is the tab authority rather than the driver, the same way it
 * sends `Target.createTarget` — so without this it would be composing a frame
 * against a rule stated somewhere else. Exported so the rule has one statement
 * and two callers, exactly as `isNavigationAllowed` is shared between
 * `screenCommand` and `browser-driven-cdp.ts`'s navigation door.
 */
export function screenHistoryEntry(params: Record<string, unknown>): Screening {
  return screenHistoryEntryParams(params)
}

/**
 * `Target.createTarget`, which opens a page at a URL.
 *
 * A new target starts at a URL, and a URL is a `file://` reach exactly as a
 * navigation is — so it is screened by the same allow-list, `isNavigationAllowed`,
 * which permits http, https and `about:blank` (the ordinary first page) and
 * nothing else. The target and browser-context lifecycle is otherwise the
 * host's to run; what a caller could smuggle in is the opening address, and this
 * is where that is refused.
 */
function screenCreateTarget(params: Record<string, unknown>): Screening {
  if (!isNavigationAllowed(params.url)) {
    return {
      ok: false,
      reason: 'a new page may only be opened at an http or https address, or about:blank',
    }
  }
  return { ok: true }
}

/**
 * The tallest screencast image this host will produce, in pixels.
 *
 * A width past {@link MAX_WATCH_WIDTH} is bytes no phone can show and a JPEG that
 * will not fit the frame cap — the protocol clamps it and this refuses it. Height
 * has no protocol clamp because the viewer never asks for one; the driver leaves
 * `maxHeight` off and CDP scales height to the width. But `startScreencast`
 * *accepts* a height, so a caller could name one, and an unbounded one is the
 * same runaway a width would be. Bounded here, generously — a tall page at
 * `MAX_WATCH_WIDTH` is still under this — so a caller that sets one has to set a
 * sane one.
 */
const MAX_SCREENCAST_HEIGHT = 4096

/**
 * `Page.startScreencast`, argument by argument.
 *
 * Every value here is a capability the feature bounds rather than one the caller
 * chooses freely, so each is screened rather than trusted — the same discipline
 * the navigation URL and the fetch pattern get. The driver already clamps these
 * into range from a viewer's request (`readWatch` in `protocol.ts`), so a call
 * that reaches here out of range is not a viewer on an odd screen but a caller
 * that skipped the clamp, and it is refused rather than silently corrected.
 *
 *  - `format` must be `jpeg`. CDP's own default is `png`, and a PNG of a content
 *    page is megabytes — it blows the relay's 96 KiB payload ceiling that
 *    {@link MAX_WATCH_WIDTH}/{@link MAX_WATCH_QUALITY} are sized under. So the
 *    format is required and pinned rather than defaulted.
 *  - `quality` must be an integer in [{@link MIN_WATCH_QUALITY}, {@link
 *    MAX_WATCH_QUALITY}] — the JPEG quality the frame cap is sized around.
 *  - `maxWidth` must be an integer in [{@link MIN_WATCH_WIDTH}, {@link
 *    MAX_WATCH_WIDTH}] — the image width the frame cap is sized around.
 *  - `maxHeight`, if present, must be a positive integer no larger than
 *    {@link MAX_SCREENCAST_HEIGHT}.
 *  - `everyNthFrame`, if present, must be an integer of at least one — a
 *    source-rate cap, never a rate multiplier.
 */
function screenScreencast(params: Record<string, unknown>): Screening {
  if (params.format !== 'jpeg') {
    return {
      ok: false,
      reason: 'a screencast is only ever streamed as jpeg; png of a page blows the relay payload ceiling',
    }
  }
  const quality = params.quality
  if (
    typeof quality !== 'number' ||
    !Number.isInteger(quality) ||
    quality < MIN_WATCH_QUALITY ||
    quality > MAX_WATCH_QUALITY
  ) {
    return {
      ok: false,
      reason: `a screencast quality must be an integer between ${MIN_WATCH_QUALITY} and ${MAX_WATCH_QUALITY}`,
    }
  }
  const maxWidth = params.maxWidth
  if (
    typeof maxWidth !== 'number' ||
    !Number.isInteger(maxWidth) ||
    maxWidth < MIN_WATCH_WIDTH ||
    maxWidth > MAX_WATCH_WIDTH
  ) {
    return {
      ok: false,
      reason: `a screencast width must be an integer between ${MIN_WATCH_WIDTH} and ${MAX_WATCH_WIDTH} pixels`,
    }
  }
  const maxHeight = params.maxHeight
  if (maxHeight !== undefined) {
    if (
      typeof maxHeight !== 'number' ||
      !Number.isInteger(maxHeight) ||
      maxHeight <= 0 ||
      maxHeight > MAX_SCREENCAST_HEIGHT
    ) {
      return {
        ok: false,
        reason: `a screencast height, when given, must be a positive integer no larger than ${MAX_SCREENCAST_HEIGHT}`,
      }
    }
  }
  const everyNth = params.everyNthFrame
  if (everyNth !== undefined) {
    if (typeof everyNth !== 'number' || !Number.isInteger(everyNth) || everyNth < 1) {
      return {
        ok: false,
        reason: 'a screencast source-rate cap, when given, must be an integer of at least one',
      }
    }
  }
  return { ok: true }
}

/**
 * `Input.dispatchTouchEvent`, whose only danger is the number of points.
 *
 * The coordinates in `touchPoints` are just numbers dispatched into the page —
 * there is no url and no path to smuggle — but the array arrives from a peer, and
 * an unbounded one is an array somebody else sized landing in Chromium. Bounded
 * to {@link MAX_TOUCH_POINTS}, which is every finger a person has and well past
 * any gesture a page reads. An empty list is allowed: a `touchEnd` carries none.
 */
function screenTouch(params: Record<string, unknown>): Screening {
  const points = params.touchPoints
  if (!Array.isArray(points)) {
    return { ok: false, reason: 'a touch event must carry a list of touch points' }
  }
  if (points.length > MAX_TOUCH_POINTS) {
    return { ok: false, reason: `a touch event may carry at most ${MAX_TOUCH_POINTS} points` }
  }
  return { ok: true }
}

/**
 * `Emulation.setDeviceMetricsOverride`, which is four powers wearing one name.
 *
 * The feature needs exactly one of them: *lay this document out in a rectangle
 * of this many CSS pixels*, so that a phone drawing the picture into a pane of
 * that many points sees the page at 100% — *"like a normal view of any website
 * like proper normal dimensions."* Everything else the method can do is refused
 * here rather than left to a comment, on the rule the whole file follows: a
 * method's name does not say what the call does, and the four powers below are
 * each a different thing from the one that was asked for.
 *
 *  - **`mobile`** switches the target into mobile emulation: a meta-viewport is
 *    honoured, `navigator.userAgentData.mobile` flips, and the page serves its
 *    phone layout. That is a fake with a real cost — it answers *"how wide is
 *    this page"* by showing a **different page** — and it is the exact
 *    substitution `PageWidths` on the phone was written to avoid. Pinned false.
 *  - **`deviceScaleFactor`** oversamples: the layout stays put and the surface
 *    gets bigger, so it is not a size at all, it is a resolution. Pinned to 1, so
 *    one image pixel is one CSS pixel and the arithmetic the viewer does with
 *    `WatchMath.fit` stays honest. It is also the only value at which the
 *    screencast's own `maxWidth` cap means what the phone thinks it means.
 *  - **`screenOrientation`, `screenWidth`, `screenHeight`, `positionX/Y`** lie
 *    to the page about the *display* rather than about the window. Nothing here
 *    needs a fictional screen, and a page reading `screen.width` should read this
 *    machine's truth.
 *  - **A missing or zero width or height** is CDP's own spelling of *turn the
 *    override off*, which is a different verb from *lay it out this wide* and has
 *    no caller. Refused, so that "resize to nothing" can never arrive as a
 *    silently-cleared viewport.
 *
 * The bounds are the wire's own — {@link MIN_PAGE_WIDTH}/{@link MAX_PAGE_WIDTH}
 * and {@link MIN_PAGE_HEIGHT}/{@link MAX_PAGE_HEIGHT}, imported rather than
 * respelled — so the parser that clamps a phone's request and the gate that
 * screens the resulting protocol call cannot drift apart into a range one of
 * them enforces and the other does not.
 */
function screenDeviceMetrics(params: Record<string, unknown>): Screening {
  const width = params.width
  if (
    typeof width !== 'number' ||
    !Number.isInteger(width) ||
    width < MIN_PAGE_WIDTH ||
    width > MAX_PAGE_WIDTH
  ) {
    return {
      ok: false,
      reason: `a page is laid out at a whole width between ${MIN_PAGE_WIDTH} and ${MAX_PAGE_WIDTH} CSS pixels`,
    }
  }
  const height = params.height
  if (
    typeof height !== 'number' ||
    !Number.isInteger(height) ||
    height < MIN_PAGE_HEIGHT ||
    height > MAX_PAGE_HEIGHT
  ) {
    return {
      ok: false,
      reason: `a page is laid out at a whole height between ${MIN_PAGE_HEIGHT} and ${MAX_PAGE_HEIGHT} CSS pixels`,
    }
  }
  if (params.mobile !== false) {
    return {
      ok: false,
      reason:
        'a viewport is set here to lay a page out at a width, never to put it into mobile emulation — ' +
        'that would answer "how wide is this page" by serving a different page',
    }
  }
  if (params.deviceScaleFactor !== 1) {
    return {
      ok: false,
      reason:
        'a page is laid out at one image pixel per CSS pixel here; a scale factor is a resolution ' +
        'rather than a size, and the viewer measures the picture assuming it is one',
    }
  }
  for (const key of ['screenOrientation', 'screenWidth', 'screenHeight', 'positionX', 'positionY']) {
    if (params[key] !== undefined) {
      return {
        ok: false,
        reason: `a viewport may be sized here but not told a fictional display; ${key} is refused`,
      }
    }
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
 *  2. **The allow-list**, which is the real gate — {@link ALLOWED_METHODS} on
 *     the desktop, {@link CDP_ALLOWED_METHODS} on the server, chosen by
 *     `transport`.
 *  3. **The deny-list**, second so that widening (2) cannot silently unlock (3).
 *  4. **The arguments**, for the methods that carry a destination or a
 *     capability — the navigation URL, the fetch pattern, the fulfilled headers,
 *     and (server only) the evaluation world, the download path, the new
 *     target's URL, the history entry, the single-URL cookie read and the
 *     viewport override.
 *
 * `state` and `transport` are passed rather than read, so the module has no
 * ambient state and a test can drive every value on either transport without an
 * app of either kind. `transport` defaults to `electron`, so every existing
 * caller and every existing test keeps the desktop tables unchanged.
 */
export function screenCommand(input: {
  transport?: Transport
  state: DriveState
  method: unknown
  params?: unknown
  downloadsDir?: string
}): Screening {
  const { state, method } = input
  const transport: Transport = input.transport ?? 'electron'

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

  const allowed = transport === 'cdp' ? CDP_ALLOWED : ALLOWED
  const denied = transport === 'cdp' ? CDP_DENIED : DENIED

  if (!allowed.has(method)) {
    return {
      ok: false,
      reason: `${method} is not one of the commands this app will send to a page`,
    }
  }
  if (denied.has(method)) {
    // Unreachable while the chosen pair of tables is disjoint, which
    // `browser-cdp.test.ts` asserts for both transports. It is here for the edit
    // that makes them overlap.
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
   * The screencast pair that carries a capability in its arguments (wave-3).
   * `Page.startScreencast` names a format, a quality, a width and a source rate;
   * `Input.dispatchTouchEvent` names a list of points. Both are allow-listed on
   * both transports, so unlike the CDP-only checks below these can be reached on
   * the desktop too — the screen is transport-agnostic and so are they.
   * `Page.stopScreencast` and `Page.screencastFrameAck` carry no capability and
   * are not screened here.
   */
  if (method === 'Page.startScreencast') return screenScreencast(params)
  if (method === 'Input.dispatchTouchEvent') return screenTouch(params)
  /*
   * `Fetch.failRequest` is deliberately not screened. Its only argument beyond
   * the id is `errorReason`, every value of which is a way of telling the page
   * the request did not happen — there is no spelling of it that reaches
   * anything outside that page.
   */

  /*
   * The CDP-only argument checks. Every method below is absent from the electron
   * allow-list, so on the desktop it is already refused by the allow-list check
   * above; reaching here therefore means `transport === 'cdp'`, and the checks
   * screen the capability each one carries in its arguments.
   */
  if (method === 'Runtime.evaluate' || method === 'Runtime.callFunctionOn') {
    return screenEvaluate(method, params)
  }
  if (method === 'Browser.setDownloadBehavior') {
    return screenDownloadBehavior(params, input.downloadsDir)
  }
  if (method === 'Target.createTarget') {
    return screenCreateTarget(params)
  }
  if (method === 'Page.navigateToHistoryEntry') {
    return screenHistoryEntryParams(params)
  }
  if (method === 'Emulation.setDeviceMetricsOverride') {
    return screenDeviceMetrics(params)
  }
  if (method === 'Network.getCookies') {
    /*
     * The one genuine relaxation over the desktop deny-list, screened inline
     * with the same URL allow-list the navigation path uses. Exactly one http(s)
     * URL: a read of "the cookie for this image" so a server scrape fetches the
     * logged-in copy, never the whole-jar dump that `Network.getAllCookies`
     * would be. The values it returns are replayed onto one asset request and
     * never written to a capture file, a tool result or the action log — that
     * discipline lives in `browser-asset-session-cdp.ts` and is asserted there,
     * the same way `browser-session.ts` keeps cookie values out of the renderer.
     */
    const urls = params.urls
    if (!Array.isArray(urls) || urls.length !== 1 || !isNavigationAllowed(urls[0])) {
      return {
        ok: false,
        reason: 'cookies may be read for exactly one http or https URL at a time, never the whole jar',
      }
    }
    return { ok: true }
  }

  return { ok: true }
}

/* ------------------------------------------------- the other narrow door -- */

/**
 * The commands the **person** may send while they hold the page.
 *
 * Deliberately not a subset of {@link ALLOWED_METHODS} that a flag unlocks. It
 * is a second list, read by a second function, under the *opposite* condition —
 * see {@link screenPersonCommand} for why that shape rather than a bypass.
 *
 * Two groups, and both of them are here because a person filling in a login form
 * on a phone needs exactly two things: to see the page, and to type into it.
 *
 *  - **The four `Input.*` dispatches** `PageCast` already sends. They are the
 *    typing: a tap, a swipe, a keystroke, a paste. Nothing else in the `Input.`
 *    domain is here — not `Input.setIgnoreInputEvents`, not the drag or
 *    synthesise verbs — because a person's hands are a pointer and a keyboard
 *    and nothing about a real finger needs any of the rest.
 *  - **The three `Page.*screencast*` commands**, which are the seeing, and which
 *    the brief for this door did not ask for. They had to come with it and the
 *    reason is worth writing down rather than discovering again. `curtain()`
 *    stops the screencast at the source *before* the baton flips, so by the time
 *    a person can take the page there is no stream at all; and CDP's screencast
 *    is ack-driven, so even a stream that somehow survived would produce exactly
 *    **one** frame and then wait forever for a `Page.screencastFrameAck` that
 *    the agent's door refuses. A door that let the person type into a page they
 *    cannot see would be a worse thing than no door.
 *
 * What is *not* here is the whole of the point. No navigation, no evaluation, no
 * `Network.*`, no `Fetch.*`, no cookie read, no `Page.captureScreenshot`. The
 * person on the phone is being lent a pointer and a keyboard over a page they
 * are already being shown — never the agent's reach, and never a way to make
 * this door into a second copy of the first one.
 */
export const PERSON_METHODS: readonly string[] = [
  'Input.dispatchMouseEvent',
  'Input.dispatchKeyEvent',
  'Input.dispatchTouchEvent',
  'Input.insertText',
  'Page.startScreencast',
  'Page.stopScreencast',
  'Page.screencastFrameAck',
]

const PERSON = new Set(PERSON_METHODS)

/**
 * May the **person holding this page** send this command right now?
 *
 * The sibling of {@link screenCommand}, and the inverse of it in every clause
 * that matters. That function refuses everything while `state === 'human'`; this
 * one refuses everything **unless** `state === 'human'`. Agent-send refuses while
 * a person has the page; person-send refuses unless a person has it. Two narrow
 * doors, opposite conditions, and neither is a hole in the other.
 *
 * ## Why a second function and not a flag on the first
 *
 * The baton refusal in {@link screenCommand} is a *mechanism* — its own comment
 * argues at length that a policy is a sentence a retry loop does not read, while
 * a channel that returns an error is hit by every retry. A `person: true` flag
 * threaded into that function would turn the mechanism back into a policy: the
 * refusal would then be conditional on an argument, every caller of `send` would
 * be one edit away from passing it, and the grep that today proves the agent
 * cannot reach a page during a handover would stop proving anything.
 *
 * So the agent's screen keeps its unconditional refusal, untouched, and this is
 * a separate door with its own tiny list. A caller can only come through it by
 * calling a differently-named function, which is a thing a reviewer can grep for
 * exactly as they can grep for a raw `page.send`.
 *
 * ## Who is allowed to reach it
 *
 * This function answers *what may be sent*, never *who may send it*. Whether
 * this particular watcher is the person the handover was asked of is decided
 * one layer up, in `PageCast`, which holds the taker; and whether that
 * connection may see the window at all is decided one layer above *that*, in
 * `remote/server.ts`, against the same window-grants axis `browser.watch` rides.
 * Three questions, three layers, and this one is the smallest.
 *
 * `transport` is not a parameter, unlike its sibling. Every method on this list
 * is present in **both** {@link ALLOWED_METHODS} and
 * {@link CDP_ALLOWED_METHODS} — `browser-cdp.test.ts` asserts that — so the list
 * is already a strict subset of what either transport would permit an agent, and
 * a per-transport reading of it could only ever be narrower than the one table
 * that is here.
 */
export function screenPersonCommand(input: {
  state: DriveState
  method: unknown
  params?: unknown
}): Screening {
  const { state, method } = input

  if (typeof method !== 'string' || method.length === 0) {
    return { ok: false, reason: 'a debugger command needs a method name' }
  }

  /*
   * Nobody has been handed this page.
   *
   * First, for the same reason the baton is first in `screenCommand`: it is the
   * only check about a *person* rather than about the call, and a person-send
   * arriving outside a handover is not a bad argument, it is a caller with no
   * standing. It also closes the one race worth naming — a taker whose hand-back
   * has already returned the baton, whose last queued keystroke is still on the
   * wire. That keystroke is refused here rather than typed into a page the agent
   * has resumed driving.
   */
  if (state !== 'human') {
    return {
      ok: false,
      reason:
        'nobody has been handed this page, so there is no person to send this from. Only somebody ' +
        'answering a browser.handover may type into a page this way.',
    }
  }

  if (!PERSON.has(method)) {
    return {
      ok: false,
      reason: `${method} is not one of the commands a person answering a handover may send to a page`,
    }
  }

  const params = (typeof input.params === 'object' && input.params !== null
    ? (input.params as Record<string, unknown>)
    : {})

  // The two on the list that carry a capability in their arguments, screened by
  // the same two functions the agent's door uses. One spelling of each rule.
  if (method === 'Page.startScreencast') return screenScreencast(params)
  if (method === 'Input.dispatchTouchEvent') return screenTouch(params)

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
