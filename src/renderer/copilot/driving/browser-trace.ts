/**
 * What the copilot is doing to a web page, made readable — from the app's own
 * record of what it actually did.
 *
 * Asad, 2026-08-17, in one sentence that is the whole requirement:
 *
 *   > *"Asked to scrape, it goes, shows the page and how it is scraping, then
 *   > returns with the result."*
 *
 * ## Why this is a panel and not an overlay on the page
 *
 * Because the page cannot be drawn on. A browser page in this app is a native
 * `WebContentsView`, composited **above** the entire renderer, so no HTML reaches
 * it — not with a larger `z-index`, not through a portal, not from a new stacking
 * context. `focus-target.ts` carries the essay and says it has been rediscovered
 * twice. The scan's dot field is a canvas in the renderer, so while a browser
 * page is what the copilot is working on, the field has nothing it can cover and
 * a box drawn "around the element" would be a box drawn behind the page.
 *
 * There are two ways to hide that and both were refused. **Parking the page**
 * (`setVisible(false)`) makes the thing you are meant to be watching disappear.
 * **Photographing it and animating over the photograph** is worse: it looks
 * exactly like a live page and is not one, so a person watching a frozen picture
 * of a form would have no way to know the click they can see has already gone
 * somewhere else. The instruction was explicit — *do not fake it with a
 * screenshot animation pretending to be live* — and it is the same rule the rest
 * of this feature runs on: nothing on screen may claim something the code cannot
 * do.
 *
 * So the showing is **the driver's own account of itself, beside the page**: the
 * address it is on, the element it resolved, and how much it took. Everything
 * below is a fact this app recorded because it happened, and none of it is
 * embellished.
 *
 * ## Where the facts come from, and why nothing new had to be built
 *
 * Two streams that already existed and had no reader between them:
 *
 *  1. **`deck-control:action`** — every tool call, as it is written to
 *     `actions.jsonl`. It carries the tool's own `detail` line, its `outcome`,
 *     and a `result` summary the tool chose: `browser.open` records the url and
 *     the title it settled on, `browser.step` records the verb, the selector and
 *     **the label of the element it actually resolved**, `browser.read` records
 *     how many characters and how many elements came back. The preload has
 *     exposed this as `onCopilotAction` since the copilot shipped and — checked
 *     on 2026-08-18 — nothing in the window subscribed to it.
 *  2. **`browser:drive-state`** — the drive's own live line, `step`, written in
 *     the present tense with the element's own label (`clicking “Sign in”`) and
 *     the url the page is on. That one is drawn today as a banner over the page,
 *     which is the right place for *"an agent is driving this"* and the wrong
 *     shape for *"here is what it has done so far"*.
 *
 * The first is a history and the second is a now, which is exactly the two halves
 * of watching something work.
 *
 * ## Why the narrowing lives in its own file
 *
 * It is pure, it has edges worth driving directly, and it reads values that
 * crossed the bridge as `unknown` — the house rule. A row that came out of an
 * append-only log written by a different process is not a shape to trust: this
 * turns whatever arrived into either one honest row or nothing at all.
 */

/* -------------------------------------------------------------- the shapes -- */

/** The tools whose calls this shows. Anything else is not about a page. */
const BROWSER_TOOL = /^browser\./

/**
 * One thing the driver did, as a person would describe it.
 *
 * Deliberately flat strings rather than a union per tool. The panel prints three
 * lines — what, where, what came of it — for every kind of step, and a shape per
 * verb would push the "which fields does this one have" question into the
 * component. Empty means "this call had nothing to say there", which renders as
 * nothing rather than as a blank label.
 */
export interface DriveStep {
  /** The action row's own id, unique per call. The list's React key. */
  id: string
  /** Milliseconds since the epoch, from the log's ISO stamp. 0 if unparseable. */
  at: number
  /** `open`, `read`, `step`, `screenshot`, `handover` — the tool without its prefix. */
  verb: string
  /** The one line the tool wrote about the call, which is what the log shows. */
  detail: string
  /** The page it was on, when the result named one. */
  url: string
  /** The element it actually resolved — its label if it had one, else its selector. */
  element: string
  /** What it came back with: "1,240 characters", "18 elements". */
  took: string
  /** `ok`, `refused` or `error`. Anything unrecognised is treated as an error. */
  outcome: 'ok' | 'refused' | 'error'
  /** The refusal or failure sentence, when there was one. */
  error: string
}

/* ---------------------------------------------------------------- reading -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

/**
 * A count with its unit, or nothing.
 *
 * Grouped with `toLocaleString` because the two numbers this prints are a
 * character count and an element count, and a page's text runs to five figures —
 * `12480 characters` is a number somebody has to stop and parse.
 */
function counted(value: unknown, one: string, many: string): string {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return ''
  return `${Math.round(value).toLocaleString()} ${value === 1 ? one : many}`
}

/**
 * What the driver got back, in the words of the tool that got it.
 *
 * One branch per tool because each one summarises itself differently and the
 * differences are the information — a `read` is measured in characters, a `step`
 * in whether it landed, an `open` in what the page turned out to be. A default
 * of "" is honest for `handover`, whose whole result is who has the page, and
 * that is already the `detail` line.
 */
function tookOf(verb: string, result: Record<string, unknown> | null): string {
  if (result === null) return ''
  switch (verb) {
    case 'read': {
      const chars = counted(result.chars ?? result.textChars, 'character', 'characters')
      const elements = counted(result.elements, 'element', 'elements')
      if (chars !== '' && elements !== '') return `${chars} · ${elements}`
      return chars !== '' ? chars : elements
    }
    case 'open':
      return text(result.title)
    case 'step':
      return counted(result.chars, 'character typed', 'characters typed')
    case 'screenshot': {
      const size =
        typeof result.width === 'number' && typeof result.height === 'number'
          ? `${Math.round(result.width)}×${Math.round(result.height)}`
          : ''
      const masked = counted(result.masked, 'field masked', 'fields masked')
      if (size !== '' && masked !== '') return `${size} · ${masked}`
      return size !== '' ? size : masked
    }
    default:
      return ''
  }
}

/**
 * An action-log row as one step, or null because it was not about a page.
 *
 * Null is the ordinary answer: this subscription sees **every** tool call the
 * copilot makes, and most of them are sessions, git and settings. Filtering here
 * rather than in the component keeps the panel from ever holding a row it will
 * not draw.
 *
 * A refused or failed call is kept, and that is deliberate. *"It clicked, and it
 * was refused"* is the most useful line this panel can print — it is the answer
 * to "why did the scrape stop" — and a trace that only showed successes would be
 * a trace that goes quiet exactly when somebody starts watching it.
 */
export function driveStepOf(raw: unknown): DriveStep | null {
  const row = record(raw)
  if (row === null) return null
  const tool = text(row.tool)
  if (!BROWSER_TOOL.test(tool)) return null
  const id = text(row.id)
  if (id === '') return null

  const verb = tool.slice('browser.'.length)
  const result = record(row.result)
  const at = Date.parse(text(row.at))
  const outcome = row.outcome === 'ok' || row.outcome === 'refused' ? row.outcome : 'error'

  return {
    id,
    at: Number.isFinite(at) ? at : 0,
    verb,
    detail: text(row.detail),
    url: text(result?.url),
    /*
     * The label first, and the selector only when there is no label.
     *
     * `browser.step` records both, and they are not the same claim: the selector
     * is what the model asked for and the label is what the driver *found* —
     * the element's own text, read off the page after it resolved. Showing the
     * label is showing that the click landed on the button somebody can see,
     * which is the entire question a person watching this wants answered.
     */
    element: text(result?.label) !== '' ? text(result?.label) : text(result?.selector),
    took: tookOf(verb, result),
    outcome,
    error: text(row.error),
  }
}

/**
 * The trace with one more step on the end, newest last, bounded.
 *
 * Bounded because a long scrape is hundreds of calls and this list lives in a
 * panel two hundred pixels wide; the whole history is in `actions.jsonl` and in
 * Settings → Copilot, which is where a record belongs. Idempotent on the row id
 * for the reason `addSession` gives about `session:created`: a subscription that
 * re-registers, or a main process that ever broadcast more widely, must not turn
 * one call into two lines.
 */
export const MAX_TRACE_STEPS = 60

export function withStep(steps: readonly DriveStep[], next: DriveStep): DriveStep[] {
  if (steps.some((step) => step.id === next.id)) return [...steps]
  const grown = [...steps, next]
  return grown.length <= MAX_TRACE_STEPS ? grown : grown.slice(grown.length - MAX_TRACE_STEPS)
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
