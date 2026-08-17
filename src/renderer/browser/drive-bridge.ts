/**
 * The renderer's half of the copilot driving a page.
 *
 * Small on purpose. The drive lives entirely in the main process — the renderer
 * never resolves a selector, never sends a click and never sees a page's
 * contents — so what is here is three things: mirrors of the two shapes that
 * cross the bridge, a way to tell whether the preload has these channels at
 * all, and the rule that stops two browser panels answering the same request.
 *
 * The types are mirrors rather than imports for the reason `bridge.ts` states
 * at length: the renderer's tsconfig does not include `src/main`, and this repo
 * lets feature types cross as `unknown` rather than duplicating them into
 * `shared/types.ts` where the two sides quietly drift instead of loudly
 * disagreeing. Each one names the module it mirrors.
 */

/** Mirrors `DriveState` in `src/main/browser-cdp.ts`. */
export type DriveState = 'idle' | 'agent' | 'human'

/** Mirrors `DriveStatus` in `src/main/browser-drive.ts`. */
export interface DriveStatus {
  state: DriveState
  tabId: string | null
  /** Present tense, the element's own label: `clicking “Sign in”`. Empty between steps. */
  step: string
  /** The agent's sentence, already clamped and stripped of control characters in main. */
  prompt: string
  url: string
}

export const IDLE_DRIVE: DriveStatus = {
  state: 'idle',
  tabId: null,
  step: '',
  prompt: '',
  url: '',
}

/** Mirrors the request `browser-drive-ipc.ts` pushes on `browser:drive-open`. */
export interface DriveOpenRequest {
  id: string
  url: string
  isolate: boolean
}

/** The preload methods this feature needs, all of which may be absent. */
export interface DriveApi {
  onBrowserDriveOpen?(cb: (request: unknown) => void): () => void
  browserDriveOpened?(id: string, tabId: string | null): void
  browserDriveStatus?(): Promise<unknown>
  onBrowserDriveState?(cb: (status: unknown) => void): () => void
  browserDriveResume?(carryOn: boolean): void
}

export function resolveDriveApi(host?: unknown): DriveApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  // Copied method by method rather than handed over whole, so a preload that is
  // older than this file contributes the methods it has and nothing else — the
  // same shape `resolveIsolationApi` uses, and the reason `driveAvailable`
  // below can be a single honest answer instead of five `typeof` checks at
  // every call site.
  for (const name of [
    'onBrowserDriveOpen',
    'browserDriveOpened',
    'browserDriveStatus',
    'onBrowserDriveState',
    'browserDriveResume',
  ]) {
    const value = record[name]
    if (typeof value === 'function') api[name] = (value as (...args: never[]) => unknown).bind(source)
  }
  return api as DriveApi
}

/**
 * Is the drive wired in this build?
 *
 * All five or none: a banner that can be drawn but not answered is worse than
 * no banner, because it is a page the person has been told to act on with no
 * way to say they are finished. The same bargain `isolationAvailable` makes.
 */
export function driveAvailable(api: DriveApi): boolean {
  return (
    typeof api.onBrowserDriveOpen === 'function' &&
    typeof api.browserDriveOpened === 'function' &&
    typeof api.browserDriveStatus === 'function' &&
    typeof api.onBrowserDriveState === 'function' &&
    typeof api.browserDriveResume === 'function'
  )
}

/**
 * A request from the main process, validated before anything acts on it.
 *
 * It comes from this app's own main process rather than from a page, so this is
 * not a trust boundary — it is the same discipline every other `unknown` on this
 * side gets, and it is what makes an older main process (or a newer one) a
 * no-op rather than a crash in an effect.
 */
export function readDriveOpen(raw: unknown): DriveOpenRequest | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  if (typeof value.id !== 'string' || value.id === '') return null
  if (typeof value.url !== 'string' || value.url === '') return null
  return { id: value.id, url: value.url, isolate: value.isolate === true }
}

/** The same, for the status push. */
export function readDriveStatus(raw: unknown): DriveStatus | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const state = value.state
  if (state !== 'idle' && state !== 'agent' && state !== 'human') return null
  return {
    state,
    tabId: typeof value.tabId === 'string' ? value.tabId : null,
    step: typeof value.step === 'string' ? value.step : '',
    prompt: typeof value.prompt === 'string' ? value.prompt : '',
    url: typeof value.url === 'string' ? value.url : '',
  }
}

/* ------------------------------------------------------------- the claim -- */

/**
 * Which open-requests have already been taken, for the life of this document.
 *
 * A browser page is a row in the sidebar, so several `BrowserWorkspace`
 * components can be mounted at once — and the push from the main process
 * reaches every one of them. Without this, one `browser.open` call would open a
 * tab in *each* panel, and the main process would use the first reply and leave
 * the rest as pages nobody asked for, in panels nobody was looking at.
 *
 * A module-level set works because every panel is in the same JavaScript
 * context; there is no ordering to get wrong, because `claimDriveOpen` is
 * synchronous and the effects that call it run one after another on one thread.
 *
 * It is never pruned. Ids are UUIDs, one per `browser.open`, and the budget in
 * `control.ts` caps those at 240 a minute across every tool — a session long
 * enough for this to matter would have to be running for weeks, and a reload
 * empties it. A timer to clean it up would be more machinery than the leak.
 */
const claimed = new Set<string>()

/** True for the first caller with this id, false for every one after. */
export function claimDriveOpen(id: string): boolean {
  if (claimed.has(id)) return false
  claimed.add(id)
  return true
}

/** For tests, which must not see each other's claims. */
export function resetDriveClaimsForTests(): void {
  claimed.clear()
}

/* ------------------------------------------------------------ the wording -- */

/**
 * What the chip in the toolbar says.
 *
 * It lives in the app's own chrome and not over the page, for the reason
 * `overlay-watch.ts` is the standing essay on: nothing HTML can be drawn above
 * a `WebContentsView`, and *"you cannot fix this with CSS"*. Putting it in the
 * toolbar row also means the page's rectangle never changes, so the site being
 * driven never reflows because a banner appeared.
 */
export function driveChipText(status: DriveStatus): string {
  if (status.state === 'human') return 'Your turn'
  if (status.state !== 'agent') return ''
  return status.step === '' ? 'Copilot is driving' : `Copilot is ${status.step}`
}
