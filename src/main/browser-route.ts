/**
 * Where one URL from one session goes — the decision, with the two ends of it
 * handed in.
 *
 * ## Why this is its own module
 *
 * Two callers ask exactly the same question and must not be allowed to answer
 * it differently:
 *
 *  - the **shim**, when an agent inside a session runs `open https://…`; and
 *  - the **terminal**, when Asad clicks a URL an agent printed.
 *
 * Those are the two sentences he reported on 2026-08-19 and they are two
 * entrances to the same hole. A second copy of this routing is how one of them
 * would end up in the right window and the other in Safari again, which is the
 * state this feature exists to leave.
 *
 * The Electron parts are parameters rather than imports, so the decision can be
 * exercised without a window: {@link RouteDeps} is a page that can be steered,
 * a renderer that can be asked for a new window, and nothing else.
 *
 * ## The second-link rule, and why it is not a guess
 *
 * Asad, 2026-08-19: *"it depends if the thing is done and saved whatever we
 * started on that window it should save if required it will open new so it will
 * be free will as per the situation."*
 *
 * So: reuse the lowest-numbered attached window **unless that page says it has
 * unfinished work**, and a caller may always ask for a new one outright. The
 * signal is the page's own `beforeunload` — the same declaration that makes a
 * real browser ask "Leave site?" — and nothing else. Never the URL, never the
 * title, never how long ago it was opened. A heuristic here would silently
 * navigate over a half-written form, and the person who lost it would have no
 * way to know what decided that.
 */

import { BRAND } from '../shared/brand'
import {
  attachReserved,
  bindingFor,
  reserve,
  resolve,
  slotName,
  type OpenPlan,
} from './browser-binding'
import type { OpenAnswer } from './hook-server'

/**
 * The little of a `WebContents` this module uses.
 *
 * Structural rather than Electron's own type because that type carries about
 * two hundred overloads of `on`, and the point of naming these four is that a
 * reader can see the entire surface this decision touches. `index.ts` passes a
 * real `WebContents`, which satisfies it.
 */
export interface SteerablePage {
  isDestroyed(): boolean
  loadURL(url: string): Promise<unknown>
  once(event: 'will-prevent-unload', listener: (event: { preventDefault(): void }) => void): unknown
  off(event: 'will-prevent-unload', listener: (event: { preventDefault(): void }) => void): unknown
}

/** What the renderer said when asked to open a window for a URL. */
export type OpenedReply =
  /** It opened one, and this is the shell tab id it minted. */
  | { tabId: string }
  /**
   * It did not, and this is why, in the words to print. The live case is the
   * browser feature being switched off in Features — `App.tsx` already takes
   * exactly that line for a link and says why: *"somebody who has switched the
   * browser off in Features has said what they want."*
   */
  | { refused: string }

export interface RouteDeps {
  /** The page a bound window is currently showing, or null if it has gone. */
  pageFor(viewId: string | null): SteerablePage | null
  /**
   * Whether this app started that session.
   *
   * The gate between "a session of ours with no window yet, which should get
   * one" and "an id from somewhere else, which must not reach his browser at
   * all". The hook and the shim are installed for the whole machine, so the
   * second case is a real one and arrives regularly.
   */
  knowsSession(sessionId: string, machineId: string): boolean
  /** Ask the renderer for a window, pre-numbered so the answer cannot be wrong. */
  openWindow(request: {
    url: string
    sessionId: string
    machineId: string
    n: number
  }): Promise<OpenedReply>
}

/**
 * How long a page is given to declare that it has unfinished work.
 *
 * `beforeunload` runs synchronously in the page before the navigation commits,
 * so this is not a poll and it is not a guess about how long a page "should"
 * take — it is a ceiling on how long the agent's `curl` is made to wait for a
 * page that is not answering. A page whose own handler takes longer than this
 * is navigated, and that is the limit stated rather than hidden: it is far
 * inside the shim's three-second budget and far outside anything a real
 * `beforeunload` does.
 */
const UNFINISHED_WORK_MS = 600

/**
 * Try to put a URL in a page that may not want to give up its document.
 *
 * `will-prevent-unload` is Electron's report that the page's own `beforeunload`
 * asked to stay. Calling `preventDefault()` there is what actually keeps it —
 * without it Electron proceeds and the document is replaced anyway, which would
 * be exactly the silent loss this rule exists to prevent.
 */
export async function navigatePage(
  page: SteerablePage,
  url: string,
): Promise<'navigated' | 'unfinished'> {
  if (page.isDestroyed()) return 'unfinished'

  let unfinished = false
  let stopWaiting = (): void => undefined
  const onPrevent = (event: { preventDefault(): void }): void => {
    event.preventDefault()
    unfinished = true
    stopWaiting()
  }
  page.once('will-prevent-unload', onPrevent)

  // Not awaited: `loadURL` resolves on `did-finish-load`, which is the whole
  // page including its images, and the agent is blocked on this answer. What is
  // waited for is the page's *refusal*, which arrives before the navigation
  // commits or not at all.
  void Promise.resolve(page.loadURL(url)).catch(() => undefined)

  await new Promise<void>((settle) => {
    // Unreferenced so a pending 600ms timer can never be the reason the process
    // will not exit — this runs on every link click for the life of the app.
    const timer = setTimeout(settle, UNFINISHED_WORK_MS)
    timer.unref?.()
    stopWaiting = () => {
      clearTimeout(timer)
      settle()
    }
  })

  page.off('will-prevent-unload', onPrevent)
  return unfinished ? 'unfinished' : 'navigated'
}

/* ------------------------------------------------------------- sentences -- */

const NO_SESSION = `No ${BRAND.name} session here — opened in your default browser.`

function opened(n: number): string {
  return `Opened in ${slotName(n)} — ${BRAND.name}.`
}

function openedNew(n: number): string {
  return `Opened in ${slotName(n)} — ${BRAND.name} (new window, attached to this session).`
}

/* --------------------------------------------------------------- routing -- */

export interface RouteRequest {
  url: string
  sessionId: string | null
  machineId?: string
  /** The caller asked for a window of its own rather than the attached one. */
  newWindow?: boolean
}

/**
 * Put a URL where it belongs and say, in a sentence, where that was.
 *
 * Every branch below ends in one of two places: the URL is in a window and the
 * answer names it, or the answer says the machine should take it. There is no
 * third outcome, and there must never be — the shim exits 0 on `tab`, Claude
 * maps exit 0 to success, and a branch that answered `tab` having opened
 * nothing would be a URL that vanished with the agent believing it arrived.
 */
export async function routeOpen(request: RouteRequest, deps: RouteDeps): Promise<OpenAnswer> {
  const machineId = request.machineId ?? ''
  const plan: OpenPlan = resolve(request.sessionId, machineId, {
    newWindow: request.newWindow,
    known: request.sessionId ? deps.knowsSession(request.sessionId, machineId) : false,
  })

  if (plan.kind === 'system') return { route: 'system', line: plan.reason }

  if (plan.kind === 'navigate') {
    const page = deps.pageFor(plan.window.viewId)
    if (page) {
      const outcome = await navigatePage(page, request.url)
      if (outcome === 'navigated') return { route: 'tab', line: opened(plan.window.n) }
      // The page said it has something to lose, so it keeps it and the URL gets
      // a window of its own. This is his rule read literally: the situation
      // decides, and the page is the only thing that knows the situation.
    }
    // A bound window whose view has gone — the isolation switch mid-flight, a
    // pane being remounted — falls through to the same place. Minting a window
    // is honest; navigating a page that is not there would answer `tab` for a
    // URL nobody can see.
  }

  const sessionId = request.sessionId
  if (!sessionId) return { route: 'system', line: NO_SESSION }

  /*
   * The number is taken *before* the window is asked for.
   *
   * The shim is holding this connection open while the renderer builds the tab,
   * so the answer has to name a number now. Reserving it here is what makes the
   * printed `B2` and the window that arrives the same `B2` — the alternative,
   * answering with a guess and letting the attach pick its own, is the "number
   * that might be untrue" his rule rules out. A reservation nobody claims leaves
   * a gap, which is the same harmless gap a closed window leaves.
   */
  const n = reserve(sessionId, machineId)
  const reply = await deps.openWindow({ url: request.url, sessionId, machineId, n })
  if ('refused' in reply) return { route: 'system', line: reply.refused }

  const bound = attachReserved({
    sessionId,
    machineId,
    browserTabId: reply.tabId,
    url: request.url,
    n,
  })
  if (!bound) {
    // The reservation was already taken, which means something else attached to
    // this session in between. Saying `tab` here would name a number that is not
    // this window's, so the honest answer is the one that cannot be wrong.
    return { route: 'system', line: NO_SESSION }
  }

  const first = bindingFor(sessionId, machineId)?.windows.length === 1
  return { route: 'tab', line: first ? openedNew(bound.n) : opened(bound.n) }
}
