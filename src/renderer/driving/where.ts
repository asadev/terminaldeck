/**
 * Where the person actually is, read off the window that is drawing it.
 *
 * Asad, 2026-08-17:
 *
 *   > *"If I ask it where I am right now, it should be able to answer — it
 *   > should know which page I am on, what I am looking at."*
 *
 * This is the mechanism for that, and it is deliberately a *mechanism* rather
 * than a line in the copilot's instruction file. A model told "you can see the
 * screen" will answer confidently and be wrong, which is worse than not
 * answering — and this app has shipped that failure before, in a feature that
 * claimed a capability the code did not have.
 *
 * ## Two callers, one answer
 *
 * It is used for two things that would otherwise each grow their own idea of
 * "what is in front", which is how they come to disagree:
 *
 *  1. **The layout rule.** *"On its own page it should not make two split views.
 *     The side panel is not its area."* So the driving panel is not drawn at all
 *     while the copilot's own window is the one on screen, and this is what
 *     answers that.
 *  2. **The `app.where` tool.** The main process reads {@link WHERE_GLOBAL} out
 *     of this window with `executeJavaScript` when the copilot asks. Pull, on
 *     demand, rather than a push on every navigation: the answer is only ever
 *     wanted at the instant it is asked for, and a channel that fired on every
 *     tab change would be a stream of messages nobody reads. It is also the only
 *     shape available without adding an IPC channel, and the preload bridge is
 *     on the list of files a parallel agent may not touch.
 *
 * ## Why it reads the DOM instead of subscribing to the app's state
 *
 * Because the app's state lives in `App.tsx`, which is the one component this
 * module cannot reach: the driving layer is mounted as a *sibling* of `<App/>`
 * (see `DriveLayer.tsx` for the three reasons), so there is no tree to read a
 * context out of, and `App.tsx` is on the parallel-agent forbidden list.
 *
 * That constraint turns out to point at the better answer anyway. What is in the
 * DOM is what is on the screen — it is the thing the person is actually looking
 * at, not a state variable that is supposed to correspond to it. Every selector
 * below reads an element the app already renders for its own reasons, and each
 * one is pinned by a test that fails if the markup it depends on moves.
 */

import { registeredTerminals } from './terminal-registry'

/**
 * The attribute the sidebar's Copilot row wears, and the one it wears while its
 * own window is in front.
 *
 * A named attribute rather than the row's class name, because a class is
 * styling and can be renamed by anybody working on the rail, whereas an
 * attribute with no CSS attached to it is obviously a contract. The same
 * reasoning `focus-target.ts` gives for `data-drive-anchor`.
 */
export const COPILOT_ROW_ATTR = 'data-copilot-row'
export const COPILOT_ACTIVE_ATTR = 'data-copilot-active'

/**
 * The attribute a conversation pane wears, naming the session it is a view of.
 *
 * Declared here and imported by `components/ChatView.tsx` rather than spelled
 * out at both ends. The two spellings drifting apart is not a compile error and
 * not a test failure anywhere else — it is `querySelector` quietly finding
 * nothing, which arrives as *"this app cannot say which session that is"*, a
 * sentence that looks exactly like the shortfall this attribute was added to
 * remove. One export means the rename cannot happen at one end only.
 */
export const CHAT_SESSION_ATTR = 'data-chat-session'

/** Where the answer is left for the main process to read. See the header. */
export const WHERE_GLOBAL = '__terminaldeckWhere'

export interface WhereView {
  /** The heading of whatever window is in front — a session, or a project view. */
  title: string
  /** The session whose pane is on screen, when one is. */
  sessionId: string | null
  /** Terminal or conversation, when a session is in front. */
  pane: 'terminal' | 'chat' | null
  /** True while the copilot's own window is the one being shown. */
  copilotFront: boolean
  /** True while a scan is on screen. */
  driving: boolean
  /** Every session this window currently has a terminal mounted for. */
  openSessions: string[]
}

/**
 * Is the copilot's own window the one in front?
 *
 * The whole of the layout rule, in one predicate. Answered from the rail's
 * pinned row rather than from the tab strip because the copilot is deliberately
 * *not* in the strip's tab list — `Sidebar.tsx` says so — so the row is the only
 * element in the window that knows.
 */
export function copilotIsFrontmost(doc: WhereDom = document): boolean {
  return doc.querySelector(`[${COPILOT_ROW_ATTR}][${COPILOT_ACTIVE_ATTR}]`) !== null
}

/**
 * The same question, as something a component can re-render on.
 *
 * A predicate read during render is only as current as the last render, and that
 * is not good enough here: a scan that is **held** publishes nothing, so a
 * person who folds the copilot back to its own window while the screen is
 * stopped would keep the panel — the copilot beside itself, which is the exact
 * arrangement he objected to twice.
 *
 * A `MutationObserver` on the one attribute rather than a poll, which is his own
 * standing rule and also the cheaper thing by a wide margin: the observer fires
 * when the rail redraws the row and never otherwise, whereas a timer would wake
 * up over a fleet of repainting terminals to ask a question whose answer changes
 * a handful of times a day.
 *
 * Subtree, because the row is deep in the rail and this cannot reach it directly
 * — the driving layer is a sibling of `<App/>`, not a parent. Filtered to the
 * single attribute, so a mutation anywhere else in the document costs one
 * comparison inside the browser and never reaches this callback.
 */
export function watchCopilotFrontmost(
  onChange: (front: boolean) => void,
  doc: Document = document,
): () => void {
  if (typeof MutationObserver !== 'function') return () => {}
  let last = copilotIsFrontmost(doc)
  onChange(last)
  const observer = new MutationObserver(() => {
    const next = copilotIsFrontmost(doc)
    if (next === last) return
    last = next
    onChange(next)
  })
  observer.observe(doc.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: [COPILOT_ACTIVE_ATTR],
  })
  return () => observer.disconnect()
}

/**
 * The parts of `document` this module reads.
 *
 * A structural subset rather than `Document`, so the whole thing can be driven
 * from a plain object in a test. This repository has no jsdom, deliberately —
 * `finish.test.ts` and `tokens.test.ts` both say so — and a module whose answer
 * decides whether a panel is drawn at all cannot be the one piece with no pinned
 * behaviour. `interruption.ts` takes its `EventSource` the same way and for the
 * same reason.
 */
export interface WhereDom {
  querySelector(selector: string): {
    textContent?: string | null
    offsetParent?: unknown
    getAttribute?(name: string): string | null
  } | null
}

/**
 * What the window is showing, right now.
 *
 * Every field is either present or `null`; nothing here guesses. A window with
 * no session in front answers `sessionId: null` rather than naming the last one
 * it saw, because the difference between "he is looking at Source control" and
 * "he is looking at a session" is the entire value of the answer.
 */
export function describeWhere(doc: WhereDom = document): WhereView {
  const heading = doc.querySelector('h1.toolbar-title')
  const title = heading?.textContent?.trim() ?? ''

  /*
   * The session in front, from the terminal registry rather than from a class.
   *
   * Every mounted `TerminalView` registers itself with its session id and its
   * host element, and the app keeps every open session mounted — hidden with
   * `display: none` — so the pty keeps running whatever is on screen. So the one
   * that is *visible* is the one being looked at, and `offsetParent` is the
   * cheapest true test for that: it is null for an element inside a
   * `display: none` subtree and non-null otherwise.
   */
  let sessionId: string | null = null
  const open: string[] = []
  for (const entry of registeredTerminals()) {
    open.push(entry.id)
    if (sessionId === null && entry.host.offsetParent !== null) sessionId = entry.id
  }

  /*
   * Terminal or conversation, decided by which surface is actually visible.
   *
   * Asked of the DOM the same way and for the same reason.
   *
   * A conversation used to be the one thing this could see but not name:
   * `ChatView`'s root carried no session id, so `pane` said `chat` while
   * `sessionId` stayed null, and `app.where` reported that this app could not
   * say which session was in front of its own window. Naming it from the last
   * terminal that happened to be registered would have been a confident wrong
   * answer — the one failure a tool like this must never have — so the pane was
   * given the id instead, as {@link CHAT_SESSION_ATTR}.
   *
   * **Two queries and not one**, because "a conversation is in front" and "whose
   * conversation" are separate facts and only the first is always knowable. The
   * pane writes the attribute only when it knows which pty it acts on, so a
   * folder holding two live sessions with no id passed in has a visible
   * conversation and no name for it — genuinely ambiguous, and the composer under
   * that same pane refuses to attach a file for exactly the same reason. Folding
   * the two into one selector would have made that case answer `pane: null`,
   * losing a true fact in order to avoid admitting an unknown one.
   *
   * A terminal in front still wins the id, and it has to: the app keeps a
   * session's terminal mounted underneath its conversation, so both can be in the
   * DOM at once and only one of them is on screen.
   */
  const chat = doc.querySelector('.cv-scroll')
  const chatVisible = chat !== null && (chat.offsetParent ?? null) !== null
  const named = doc.querySelector(`.chat-view[${CHAT_SESSION_ATTR}]`)
  const chatSession =
    named !== null && (named.offsetParent ?? null) !== null
      ? named.getAttribute?.(CHAT_SESSION_ATTR) ?? null
      : null
  const pane: WhereView['pane'] =
    sessionId !== null ? 'terminal' : chatVisible ? 'chat' : null

  return {
    title,
    sessionId: sessionId ?? (pane === 'chat' ? chatSession : null),
    pane,
    copilotFront: copilotIsFrontmost(doc),
    driving: doc.querySelector('[data-drive-panel]') !== null,
    openSessions: open,
  }
}

/**
 * Publish the reader on the window object, for the main process to call.
 *
 * A **function**, not a value, and that is the point: `executeJavaScript` runs
 * it at the moment the copilot asks, so the answer is measured then rather than
 * being whatever the last navigation happened to leave behind. A cached value
 * would be a stale answer that looks exactly like a fresh one, which is the
 * worst possible failure for a tool whose whole job is to say what is true right
 * now.
 *
 * It runs in the page's main world, which is where the renderer's own code
 * lives; the preload sits in an isolated world and cannot see this, and neither
 * can any web page in a browser tab — those are separate `WebContentsView`s with
 * their own globals entirely.
 */
export function publishWhere(): () => void {
  const host = globalThis as Record<string, unknown>
  host[WHERE_GLOBAL] = () => describeWhere()
  return () => {
    delete host[WHERE_GLOBAL]
  }
}

/** Narrow whatever `executeJavaScript` handed back. Exported for the main side. */
export function readWhere(value: unknown): WhereView | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Partial<WhereView>
  if (typeof raw.title !== 'string') return null
  return {
    title: raw.title,
    sessionId: typeof raw.sessionId === 'string' ? raw.sessionId : null,
    pane: raw.pane === 'terminal' || raw.pane === 'chat' ? raw.pane : null,
    copilotFront: raw.copilotFront === true,
    driving: raw.driving === true,
    openSessions: Array.isArray(raw.openSessions)
      ? raw.openSessions.filter((id): id is string => typeof id === 'string')
      : [],
  }
}
