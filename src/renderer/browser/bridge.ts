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
}

/** Mirrors `LabelSource` in `src/main/selector.ts`. */
export type LabelSource = 'text' | 'value' | 'aria-label' | 'alt' | 'placeholder' | 'title' | 'none'

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
  browserSessionInfo(): Promise<BrowserSessionInfo>
  browserCookies(): Promise<CookieDomain[]>
  browserClearCookies(domain?: string): Promise<{ removed: number }>
  /** Every origin actually cleared — a bare domain has both an http and an https one. */
  browserClearStorage(domain?: string): Promise<{ origins: string[] }>
  browserClearCache(): Promise<void>
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

/** Which of them `window.pawl` is not offering. Empty means fully wired. */
export function missingBridgeMethods(host: unknown): string[] {
  if (typeof host !== 'object' || host === null) return [...BRIDGE_METHODS]
  const record = host as Record<string, unknown>
  return BRIDGE_METHODS.filter((method) => typeof record[method] !== 'function')
}

/**
 * Read `window.pawl` defensively.
 *
 * The workspace is wired into the preload separately from being rendered, so it
 * has to explain itself rather than crash when it mounts against a bridge that
 * does not have its methods yet. Tests render to static markup, where there is
 * no window at all.
 */
export function resolveBrowserBridge(): BrowserBridge | null {
  if (typeof window === 'undefined') return null
  const host = (window as unknown as { pawl?: unknown }).pawl
  if (!host || missingBridgeMethods(host).length > 0) return null
  return host as BrowserBridge
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
