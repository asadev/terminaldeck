/**
 * Find-in-page and print — the half of the preload that is allowed to be
 * missing.
 *
 * Same bargain as `draw-bridge.ts`, restated because getting it wrong is a
 * bricked panel: `resolveBrowserBridge` returns null — and the workspace draws
 * "The browser is not connected" — when anything in `BRIDGE_METHODS` is absent.
 * Adding these names there would blank the whole browser on every build whose
 * preload had not caught up, including the running one. So they resolve to a
 * `Partial` here, and every control asks {@link findAvailable} or
 * {@link printAvailable} before it offers itself — a find bar whose invokes are
 * missing is a control that looks like it works and does not, which is the
 * standing rule this panel is built around.
 *
 * The two validators live here too because both channels cross an `unknown`
 * seam from the main process, and the workspace must never act on a shape it
 * did not check.
 */

/** Mirrors `GuestChord` in `src/main/browser-view.ts`. */
export type PageChord =
  | 'find'
  | 'find-close'
  | 'find-next'
  | 'find-prev'
  | 'zoom-in'
  | 'zoom-out'
  | 'zoom-reset'
  | 'print'

const CHORDS: readonly PageChord[] = [
  'find',
  'find-close',
  'find-next',
  'find-prev',
  'zoom-in',
  'zoom-out',
  'zoom-reset',
  'print',
]

/** A chord off the wire, or null for anything the main process never sends. */
export function parseChord(value: unknown): PageChord | null {
  return typeof value === 'string' && (CHORDS as readonly string[]).includes(value)
    ? (value as PageChord)
    : null
}

/** What Chromium counted, mirrored from the `browser:find` push. */
export interface FindCount {
  /** Position of the active match, 1-based. 0 while there are none. */
  ordinal: number
  matches: number
}

export function parseFindCount(value: unknown): FindCount | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  const ordinal = record.ordinal
  const matches = record.matches
  if (typeof ordinal !== 'number' || !Number.isFinite(ordinal)) return null
  if (typeof matches !== 'number' || !Number.isFinite(matches)) return null
  return { ordinal: Math.max(0, Math.floor(ordinal)), matches: Math.max(0, Math.floor(matches)) }
}

/** Mirrors the find/print channels `registerBrowserViewIpc` registers. */
export interface FindBridgeMethods {
  /**
   * Run the query. `first: true` begins a new session (the text changed);
   * `forward: false` steps backwards. An empty query ends the session and
   * clears the highlights.
   */
  browserFind(id: string, query: string, options?: { forward?: boolean; first?: boolean }): Promise<void>
  /** Close the session. `keep: 'keep'` leaves the found text selected. */
  browserFindStop(id: string, keep?: 'clear' | 'keep'): Promise<void>
  /** The system print dialog for this page. Rejects with a sentence. */
  browserPrint(id: string): Promise<void>
  /** Match counts, keyed by the main-process view id. */
  onBrowserFind(cb: (id: string, count: unknown) => void): () => void
  /** Chords pressed inside a focused page, keyed the same way. */
  onBrowserChord(cb: (id: string, chord: unknown) => void): () => void
}

export type FindApi = Partial<FindBridgeMethods>

const FIND_METHODS: ReadonlyArray<keyof FindBridgeMethods> = [
  'browserFind',
  'browserFindStop',
  'browserPrint',
  'onBrowserFind',
  'onBrowserChord',
]

/**
 * Pick whichever of them the preload actually exposes. Calls go through the
 * host object rather than being torn off it — a detached method loses `this`
 * and fails at the first keystroke instead of at mount.
 */
export function resolveFindApi(host?: unknown): FindApi {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}

  const record = source as Record<string, unknown>
  const api: Record<string, unknown> = {}
  for (const name of FIND_METHODS) {
    if (typeof record[name] !== 'function') continue
    api[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return api as FindApi
}

/**
 * True only with every piece the bar depends on: the query invoke, the stop
 * that clears Chromium's highlights, and the count subscription. Without the
 * count the bar would find things and report nothing, which reads as broken;
 * without the stop, closing the bar strands orange marks on the page. The
 * chord subscription is deliberately not required — ⌘F from the app's own
 * chrome still opens the bar on a preload that predates the channel.
 */
export function findAvailable(api: FindApi): api is FindApi &
  Pick<FindBridgeMethods, 'browserFind' | 'browserFindStop' | 'onBrowserFind'> {
  return (
    typeof api.browserFind === 'function' &&
    typeof api.browserFindStop === 'function' &&
    typeof api.onBrowserFind === 'function'
  )
}

/** One method, one row: the menu draws Print exactly when this answers. */
export function printAvailable(api: FindApi): api is FindApi & Pick<FindBridgeMethods, 'browserPrint'> {
  return typeof api.browserPrint === 'function'
}

/**
 * Which of this panel's tabs a pushed chord or count may act on — or null.
 *
 * The two refusals are the two obvious failure modes, and both were named in
 * the lane brief rather than imagined: an id this panel never opened (it
 * belongs to another browser panel in a split, or to nothing) must not draw a
 * find bar here, and an id that is one of ours but *not the page in front* must
 * not either — a bar captioned with one page's match count over a different
 * page is the find bar over the wrong pane. Chords can only originate in a
 * focused page, and a focused page is the active tab, so refusing the rest
 * costs nothing real.
 */
export function chordTarget(
  tabs: ReadonlyArray<{ key: string; id: string | null }>,
  activeKey: string,
  viewId: string,
): string | null {
  if (viewId === '') return null
  const tab = tabs.find((candidate) => candidate.id === viewId)
  if (!tab) return null
  return tab.key === activeKey ? tab.key : null
}

/**
 * The same chords, read from the app's own DOM — the toolbar, the address bar,
 * the strips — where a keydown still bubbles to the workspace root. The other
 * half of the routing: `guestChord` in `src/main/browser-view.ts` answers for a
 * focused page, this answers for the chrome around it, and terminals answer for
 * themselves through `terminalChord` before anything bubbles. Print is absent
 * on purpose: with the renderer focused, ⌘P belongs to Quick Open's menu
 * accelerator, which fires before the DOM ever sees the key.
 */
export function workspaceChord(event: {
  key: string
  metaKey?: boolean
  ctrlKey?: boolean
  shiftKey?: boolean
  altKey?: boolean
}): PageChord | null {
  if (event.altKey) return null
  const mod = Boolean(event.metaKey) || Boolean(event.ctrlKey)
  if (!mod) return null
  const key = event.key.toLowerCase()
  if (key === 'f' && !event.shiftKey) return 'find'
  if (key === '=' || key === '+') return 'zoom-in'
  if (key === '-') return 'zoom-out'
  if (key === '0' && !event.shiftKey) return 'zoom-reset'
  return null
}

/**
 * The sentence beside the find field.
 *
 * Empty until there is a query — a count of nothing about nothing is noise —
 * and "No matches" rather than "0/0", because the number pair reads as an
 * answer and zero-of-zero is the absence of one.
 */
export function matchLabel(query: string, count: FindCount | null): string {
  if (query === '' || count === null) return ''
  if (count.matches === 0) return 'No matches'
  return `${count.ordinal}/${count.matches}`
}
