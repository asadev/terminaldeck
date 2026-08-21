/**
 * The renderer's view of the browser workspace's IPC surface.
 *
 * Every type here is a *mirror* of one in `src/main`, not an import: the
 * renderer's tsconfig does not include `src/main`, and this repo deliberately
 * lets feature types cross the bridge as `unknown` rather than duplicating them
 * into `shared/types.ts`, where the two sides quietly drift apart instead of
 * loudly disagreeing. The trade is that these declarations have to be kept
 * honest by hand — so each one names the module it mirrors.
 */

/* ---------------------------------------------------- mirrors of src/main -- */

/** Mirrors `BrowserTabState` in `src/main/browser-tab.ts`. */
export interface BrowserTabState {
  id: string
  url: string
  label: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
  inspecting: boolean
  error: string | null
  /**
   * True while Chromium's own error document is what the view holds.
   *
   * Not the same question as `error !== null`, and the panel reads this one
   * rather than that one: a blocked pop-up sets a message over a page that is
   * still perfectly readable, while a refused connection sets a message over a
   * red exclamation mark. Only the second may hide the native view and put the
   * start page there instead.
   */
  failed: boolean
}

/** Mirrors `LabelSource` in `src/main/selector.ts`. */
export type LabelSource = 'text' | 'value' | 'aria-label' | 'alt' | 'placeholder' | 'title' | 'none'

/** Mirrors `CaptureRect` in `src/main/browser-tab.ts`. */
export interface CaptureRect {
  x: number
  y: number
  width: number
  height: number
}

/** Mirrors `BrowserCapture` in `src/main/browser-tab.ts`. */
export interface BrowserCapture {
  selector: string
  tag: string
  label: string
  labelSource: LabelSource
  url: string
  attributes: Record<string, string>
  /** The composed single-line context, already sanitised by the main process. */
  context: string
  /**
   * The page as it looked at the instant of the click, as a `data:` image.
   *
   * Painted on the page's own rectangle while the capture popup is open. The
   * popup is HTML and the page is a native view composited above the renderer,
   * so opening the popup necessarily hides the page; without this the website
   * appears to vanish the moment you click it. Empty when the main process
   * could not take one, or when it predates the field.
   */
  pageImage: string
  /**
   * Where the element sat inside the page when it was clicked, in CSS pixels.
   *
   * The capture popup is placed against it. Null when the page reported nothing
   * usable — and null is also what an older main process sends, which is why
   * `popup-anchor.ts` has a defined answer for it rather than a crash.
   */
  rect: CaptureRect | null
}

export interface Bounds {
  x: number
  y: number
  width: number
  height: number
}

/** Mirrors `RecordedStep` in `src/main/browser-steps.ts`. */
export interface RecordedStep {
  kind: 'navigate' | 'click' | 'type' | 'select' | 'check' | 'press' | 'submit'
  selector: string
  label: string
  tag: string
  value: string
  redacted: boolean
  key: string
  checked: boolean
  url: string
  at: number
}

/** Mirrors `RecordingState` in `src/main/browser-view.ts`. */
export interface RecordingState {
  recording: boolean
  steps: RecordedStep[]
  text: string
  line: string
  truncated: boolean
}

/** Mirrors `LoadProgress` in `src/main/browser-view.ts`. */
export interface LoadProgress {
  phase: 'idle' | 'navigating' | 'loading' | 'done'
  fraction: number
}

/** Mirrors `ScreenshotResult` in `src/main/browser-view.ts`. */
export interface ScreenshotResult {
  path: string
  width: number
  height: number
  /**
   * The shot as a `data:image/png` URL, resized to something a popup can draw.
   *
   * Empty when the main process could not encode one, and empty from any main
   * process written before the field existed. The popup shows the path and the
   * send box either way — a screenshot the user cannot see is a filename, which
   * is exactly what this screen used to be.
   */
  preview: string
  /**
   * The page this is a picture of, when the sender knew it.
   *
   * Present on a frame the user marked up in draw mode and absent on a plain
   * capture, and the difference is what the picture is *for*. A marked frame is
   * evidence in a bug report — *"we can send it to the agent like this"* — and a
   * picture of a bug with no address on it is one an agent cannot act on: it
   * cannot open the page, cannot reproduce it, cannot tell which of three dev
   * servers it is looking at.
   */
  url?: string
  /**
   * How many marks are on it, when it was drawn on.
   *
   * Said out loud to the agent rather than left for it to notice, because a red
   * circle in a screenshot is easy to read as part of the site. One number is
   * enough: it tells the agent the marks exist and are the user's, and the
   * picture says everything else.
   */
  marks?: number
}

/** Mirrors `CookieSummary` in `src/main/browser-session.ts`. Note: no value. */
export interface CookieSummary {
  name: string
  domain: string
  path: string
  secure: boolean
  httpOnly: boolean
  session: boolean
  expiresAt: number | null
  valueBytes: number
}

/** Mirrors `CookieDomain` in `src/main/browser-session.ts`. */
export interface CookieDomain {
  domain: string
  cookies: CookieSummary[]
  persistent: number
}

/** Mirrors `BrowserSessionInfo` in `src/main/browser-session.ts`. */
export interface BrowserSessionInfo {
  partition: string
  persistent: boolean
  storagePath: string
  storageExists: boolean
  cookieCount: number
  domainCount: number
  cacheBytes: number
}

/* ------------------------------------------------------------------ bridge -- */

export interface BrowserBridge {
  /* browser-tab.ts */
  browserCreate(options: {
    url?: string
    bounds?: Bounds
    visible?: boolean
    /**
     * A key from `browserIsolationKey()` puts this tab on a partition of its
     * own — see `isolation-bridge.ts`. Omitted, the tab joins the shared
     * session every other tab uses.
     */
    isolationKey?: string
    /**
     * Open this tab in a **worker profile's** cookie jar.
     *
     * Only a profile registered as a worker — `browser-workers.ts` refuses every
     * other id, including a real profile of his own, so this cannot be pointed
     * at the jar holding his bank login. Omitted, the tab joins whichever
     * profile is switched on, which is what every tab in the app has always
     * done.
     *
     * It has to be decided here rather than applied afterwards for the reason
     * `isolationKey` does: a `WebContentsView`'s session is fixed when it is
     * constructed and cannot be swapped.
     */
    profileId?: string
    /**
     * The app's content canvas, as a hex colour, for a view with no page in it.
     *
     * Sent rather than decided in the main process for the same reason
     * `recordingAccent()` is: `tokens.css` is the only place a colour is
     * allowed to be written, and the main process cannot read a stylesheet.
     * `browser-background.ts` validates it and explains why a *loaded* page
     * still gets white.
     */
    background?: string
  }): Promise<BrowserTabState>
  browserNavigate(id: string, url: string): Promise<BrowserTabState>
  browserBack(id: string): Promise<BrowserTabState>
  browserForward(id: string): Promise<BrowserTabState>
  browserReload(id: string): Promise<BrowserTabState>
  browserStop(id: string): Promise<BrowserTabState>
  browserInspect(id: string, on: boolean): Promise<BrowserTabState>
  browserClose(id: string): Promise<void>
  browserBounds(id: string, bounds: Bounds): void
  browserVisible(id: string, visible: boolean): void
  onBrowserState(cb: (state: BrowserTabState) => void): () => void
  onBrowserElement(cb: (id: string, capture: BrowserCapture) => void): () => void

  /* browser-view.ts */
  browserClaim(id: string): Promise<{ ok: boolean; reason?: string }>
  browserRelease(id: string): Promise<void>
  /** `null` reads the current factor without changing it. */
  browserZoom(id: string, factor: number | null): Promise<number>
  browserDevtools(id: string): Promise<boolean>
  browserScreenshot(id: string): Promise<ScreenshotResult>
  browserRevealScreenshot(path: string): Promise<void>
  browserUserAgent(id: string, ua: string | null): Promise<string>
  browserRecord(id: string, options: { on: boolean; accent?: string }): Promise<RecordingState>
  browserRecordClear(id: string): Promise<RecordingState>
  onBrowserProgress(cb: (id: string, progress: LoadProgress) => void): () => void
  onBrowserRecording(cb: (id: string, state: RecordingState) => void): () => void

  /* browser-session.ts */
  /*
   * All five take the profile to answer about, and all five default to the one
   * that is switched on when it is left out.
   *
   * That argument is E7. Without it only the active partition could be asked
   * anything, so a profile menu could print a name and a tick and nothing else
   * — *"there is nothing that we can see in each profile."* See
   * `profileSession` in `src/main/browser-session.ts`.
   */
  browserSessionInfo(profileId?: string): Promise<BrowserSessionInfo>
  browserCookies(profileId?: string): Promise<CookieDomain[]>
  browserClearCookies(domain?: string, profileId?: string): Promise<{ removed: number }>
  /** Every origin actually cleared — a bare domain has both an http and an https one. */
  browserClearStorage(domain?: string, profileId?: string): Promise<{ origins: string[] }>
  browserClearCache(profileId?: string): Promise<void>
}

/**
 * Every method the workspace calls, so a half-wired bridge is caught at mount
 * with a list rather than at the first click with a TypeError.
 *
 * `satisfies` keeps the names honest against the interface; the test checks the
 * list is complete. This mattered before and will again: the preload is wired
 * separately from this file, and the failure mode of a missing method is a
 * button that looks fine and throws.
 */
export const BRIDGE_METHODS = [
  'browserCreate',
  'browserNavigate',
  'browserBack',
  'browserForward',
  'browserReload',
  'browserStop',
  'browserInspect',
  'browserClose',
  'browserBounds',
  'browserVisible',
  'onBrowserState',
  'onBrowserElement',
  'browserClaim',
  'browserRelease',
  'browserZoom',
  'browserDevtools',
  'browserScreenshot',
  'browserRevealScreenshot',
  'browserUserAgent',
  'browserRecord',
  'browserRecordClear',
  'onBrowserProgress',
  'onBrowserRecording',
  'browserSessionInfo',
  'browserCookies',
  'browserClearCookies',
  'browserClearStorage',
  'browserClearCache',
] as const satisfies readonly (keyof BrowserBridge)[]

/** Which of them `window.deck` is not offering. Empty means fully wired. */
export function missingBridgeMethods(host: unknown): string[] {
  if (typeof host !== 'object' || host === null) return [...BRIDGE_METHODS]
  const record = host as Record<string, unknown>
  return BRIDGE_METHODS.filter((method) => typeof record[method] !== 'function')
}

/**
 * Read `window.deck` defensively.
 *
 * The workspace is wired into the preload separately from being rendered, so it
 * has to explain itself rather than crash when it mounts against a bridge that
 * does not have its methods yet. Tests render to static markup, where there is
 * no window at all.
 */
export function resolveBrowserBridge(): BrowserBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { deck?: unknown }).deck
  if (!host || missingBridgeMethods(host).length > 0) return null
  return host as BrowserBridge
}

/**
 * What went wrong, as the sentence the main process wrote.
 *
 * Everything here crosses `ipcRenderer.invoke`, and Electron rejects a failed
 * invoke with the handler's message wrapped in its own:
 *
 *     Error invoking remote method 'browser-view:frame': Error: The page has to
 *     be on screen to capture it.
 *
 * The panel prints that straight into its notice band, so a plain precondition —
 * one the main process is careful to phrase as a sentence for exactly this
 * reason — reaches the user wearing a channel name and the word Error twice.
 * This peels off the two prefixes Electron added and leaves the sentence.
 *
 * The class prefix is only stripped when the invoke prefix was there, so a
 * message that legitimately begins "Error: " on its way from somewhere else is
 * left alone. Anything unrecognised comes back untouched: a wrapped message is
 * still far better than a swallowed one.
 */
const INVOKE_PREFIX = /^Error invoking remote method '[^']*':\s*/
const ERROR_CLASS_PREFIX = /^[A-Za-z]*Error:\s*/

export function humanError(cause: unknown): string {
  const raw = cause instanceof Error ? cause.message : String(cause)
  const unwrapped = raw.replace(INVOKE_PREFIX, '')
  if (unwrapped === raw) return raw
  return unwrapped.replace(ERROR_CLASS_PREFIX, '') || raw
}

/**
 * The accent the in-page recording badge is drawn in.
 *
 * Read out of `tokens.css` at the moment it is needed rather than hardcoded:
 * the guest page is a different document and cannot see the app's stylesheet, so
 * the value has to travel — and the main process checks it is a colour before
 * it goes anywhere near an untrusted page's inline style.
 */
export function recordingAccent(): string {
  if (typeof window === 'undefined' || typeof getComputedStyle !== 'function') return ''
  return getComputedStyle(document.documentElement).getPropertyValue('--color-critical').trim()
}

/**
 * The app's content canvas, for a browser view that has nothing in it.
 *
 * Same mechanism as {@link recordingAccent} and for the same reason: a native
 * view is painted by the main process, which has no stylesheet, so a colour that
 * must match the app has to travel across the bridge. `--bg-primary` because
 * that is the token `.bw-stage` itself wears — the native rectangle and the
 * React rectangle underneath it are the same surface as far as the user is
 * concerned, and reading the same token is what keeps them from disagreeing when
 * the palette is edited.
 *
 * Empty when there is no window, which is every test that renders to markup;
 * `browser-background.ts` treats that as "nothing usable was sent".
 */
export function appCanvasColor(): string {
  if (typeof window === 'undefined' || typeof getComputedStyle !== 'function') return ''
  return getComputedStyle(document.documentElement).getPropertyValue('--bg-primary').trim()
}
