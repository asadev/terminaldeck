/**
 * The drive's live status, narrowed, and the address it is on.
 *
 * ## What this used to be, and what took its place
 *
 * Until 2026-08-21 it was also the reader for the copilot's **action trace** —
 * one row per `browser.*` call, off `deck-control:action` — because the panel in
 * the rail was a log of what the driver had done. Asad drove with that panel and
 * said what the column is for instead:
 *
 *   > *"it is not actually for the updates. It is actually for the chatting to
 *   > Copilot, because we are now in a different page and we cannot go there. I
 *   > want to chat here while it is scrapping."*
 *
 * So the panel is now the connected session's own conversation
 * (`CopilotRailPanel`), and the trace half of this file went with the panel that
 * drew it rather than being left here for nobody — a narrowing function with no
 * reader is a claim about a feature that no longer exists. The log itself is
 * untouched: `actions.jsonl` still records every call, Settings → Copilot still
 * shows it, and `TourRecap` still reads the same stream.
 *
 * ## What is left, and why it is still its own file
 *
 * `browser:drive-state` — the drive's own status, published by
 * `src/main/browser-drive.ts`: which tab it holds, what it is doing to it in the
 * present tense, and the address it is on. Two readers, and they want different
 * halves of it: the banner over the page draws the sentence, and the rail's
 * panel uses the tab to answer *is the page in front the page being driven*.
 *
 * It is pure, it has edges worth driving directly, and it reads a value that
 * crossed the bridge as `unknown` — the house rule. A status published by
 * another process is not a shape to trust: this turns whatever arrived into
 * either one honest reading or nothing at all.
 */

/* -------------------------------------------------------------- the shapes -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/* ----------------------------------------------------------- the live line -- */

/** Mirrors `DriveStatus` in `src/main/browser-drive.ts`. That file is canonical. */
export interface DriveNow {
  state: 'idle' | 'agent' | 'human'
  /**
   * The tab the drive holds, which is also **the identity of this errand**.
   *
   * There is exactly one, by design — `browser-tools.ts` has no `tabId`
   * anywhere, and calling open again navigates the same tab — so it is the
   * closest thing to "which scrape is this" that exists, and it is what "put
   * this panel away for the page it is on" is keyed on.
   */
  tabId: string
  /** Present tense, the element's own label: `clicking “Sign in”`. Empty between steps. */
  step: string
  url: string
}

export function driveNowOf(raw: unknown): DriveNow | null {
  const status = record(raw)
  if (status === null) return null
  const state = status.state
  if (state !== 'idle' && state !== 'agent' && state !== 'human') return null
  return { state, tabId: text(status.tabId), step: text(status.step), url: text(status.url) }
}

/**
 * The address, short enough to sit on one line of a narrow panel.
 *
 * Host and path, with the scheme and any `www.` dropped — the two parts of a URL
 * that are always the same and never the answer. The query string goes too, and
 * that is worth stating rather than assuming: a query is where a session token
 * ends up, and this panel is on screen while somebody may be recording it.
 * Anything that does not parse is returned untouched rather than blanked, because
 * an unparseable string is still the only thing anybody can be told.
 */
export function shortUrl(url: string): string {
  if (url === '') return ''
  try {
    const parsed = new URL(url)
    const host = parsed.host.replace(/^www\./, '')
    const path = parsed.pathname === '/' ? '' : parsed.pathname
    return `${host}${path}`
  } catch {
    return url
  }
}
