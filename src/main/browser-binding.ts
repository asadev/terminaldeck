/**
 * Which browser windows belong to which session — the single authority.
 *
 * ## What this is for
 *
 * Asad, 2026-08-19, twice in one sitting:
 *
 * > *"when i ask any session to open a website or link they should open in app
 * > the browser we built so they know where we are and what we are talking
 * > about"*
 *
 * > *"currently if i click on a link i opens in outsider browser of the pc too"*
 *
 * Both sentences are about the same missing fact: a session and a browser
 * window are not related to each other anywhere in this app, so a URL leaving a
 * session has nowhere of its own to land and he has no word for the page he is
 * looking at. This module is that relation. A window attached to a session
 * carries a number — `B1`, `B2` — which is a fact about *that session*, so
 * "look at B2" means something to the agent he is talking to.
 *
 * ## Why the store is here and not in the renderer
 *
 * Two consumers force it, and neither of them can wait for a renderer:
 *
 *  - The shim's `POST /open` arrives in the **main** process, from a `curl` an
 *    agent's own shell is blocked on. Asking a renderer that may be mid-reload
 *    would turn a 40ms answer into a hang inside somebody's turn.
 *  - The hook answer is composed **synchronously**, inside an HTTP response the
 *    agent is stopped dead waiting for. `hook-server.ts` says so at its own
 *    handler and that ordering is load-bearing.
 *
 * Remote settles it beyond argument: `src/headless/host.ts` runs the same
 * session machinery with no renderer at all.
 *
 * The renderer holds no second copy. It reads a pushed view — building a second
 * map is how the pane bar and the browser's own picker come to disagree about
 * the same relation.
 *
 * ## Why the key is the shell tab id
 *
 * `browser:<epoch-ms>:<seq>`, minted in `App.tsx`'s `newBrowserTab`. Three
 * other ids were candidates and all three are wrong for this:
 *
 *  - The main-process `randomUUID()` in `browser-tab.ts` is per **page**, and it
 *    is destroyed and re-minted when the isolation switch closes and reopens the
 *    view. Keyed on that, a window would silently lose its number the first time
 *    somebody pressed Isolated.
 *  - The workspace's internal `tab-N` key in `renderer/browser/tabs.ts` names a
 *    strip that is never drawn, so it is invisible to the person being asked to
 *    say "B2".
 *  - A fourth id minted here would be a fourth id to keep in step with the other
 *    three.
 *
 * The shell tab id is the only handle that is one-to-one with what a person
 * calls a browser window and that lasts the window's whole life. Main does not
 * mint it, so the renderer registers it — see {@link attach}.
 *
 * ## What is deliberately not here
 *
 * No persistence of any kind. A binding written to disk points, on the next
 * launch, at a window that does not exist and a pty that does not exist — which
 * is exactly the ghost-id failure `renderer/shell/workspace-strip.ts` documents
 * at length, where twelve dead ids at a time left a strip that looked empty and
 * refused to accept anything with no way for the user to see why. A renderer
 * reload is the same event in miniature and is handled the same way; see
 * {@link hostReset}.
 *
 * No Electron import beyond nothing at all: this module is a map and some
 * arithmetic, so it is testable without a window.
 */

import { BRAND } from '../shared/brand'

/* ------------------------------------------------------------------ types -- */

/** One browser window, attached to one session. */
export interface BoundWindow {
  /**
   * The number a person says out loud — the `2` in `B2`.
   *
   * Per session, allocated on attach, and **never reused**. See
   * {@link SessionBinding.next} for why that matters more here than it looks.
   */
  n: number
  /** The renderer's shell tab id — `browser:<epoch-ms>:<seq>`. */
  browserTabId: string
  /**
   * The main-process view id this window is currently showing, or null before
   * the renderer has told us.
   *
   * Held separately from the tab id because it is the id `browser:navigate`
   * takes, and because it is the one that is re-minted underneath a window that
   * has not moved — the isolation switch closes the view and opens another. The
   * number and the identity ride on the tab id; only the ability to steer the
   * page rides on this.
   */
  viewId: string | null
  /**
   * Last known, for the hook answer and the tooltip. Reported by the window,
   * never invented — an empty string means the window has not said yet, and
   * every reader must print nothing rather than a guess.
   */
  url: string
  title: string
  /**
   * Which machine is actually serving the page in this window.
   *
   * Empty for this computer. Asad's rule for the whole feature, in his words:
   * *"we always need a truth. So we will not know the truth if we remove from
   * inside where it is exactly running. So just be sure we always be able to
   * see the truth."* A window can be attached to a session on his PC while the
   * page in it is served by the Mac, and the reverse; those are different facts
   * and neither one may be inferred from the other. So the session's machine
   * stays on {@link SessionBinding.machineId} and this is the window's own.
   *
   * Reported by the window, never derived. The reach tunnel rewrites a remote
   * address into a `localhost` port on *this* machine, so the URL is exactly
   * the thing that cannot answer this question.
   */
  hostMachineId: string
  /** What that machine is called, for a menu. Empty when it is this computer. */
  hostMachineName: string
}

/** Every window attached to one session, plus what the session is owed. */
export interface SessionBinding {
  sessionId: string
  /** Empty string for a session on this machine; a machine id for a paired one. */
  machineId: string
  /** Ordered by {@link BoundWindow.n}, ascending. */
  windows: BoundWindow[]
  /** 0–3, an index into `--bind-1 … --bind-4`. */
  colour: number
  /**
   * The last number handed out. The next window takes `++next`.
   *
   * ## Never reused while the session holds a window
   *
   * `renderer/shell/workspace-tabs.ts` already threw ordinals out as identity
   * once — *"an ordinal is not a fact about a session. It is a fact about a
   * list: close the first of the two and the second silently becomes (1)."*
   * That was cosmetic for a sidebar row. Here it is the whole feature: a
   * renumbered window makes an agent point confidently at the wrong page, and
   * it does it *within* a turn, before anything gets a chance to restate the
   * list. So closing `B1` leaves `B2` called `B2`, and while `B2` is still
   * attached the next window is `B3`.
   *
   * ## And back to zero the moment the list is empty
   *
   * The rule above used to run unconditionally, and it produced this: attach a
   * window, detach it, attach it again, attach a second, and the session's two
   * windows are called `B4` and `B5`. Four ordinary presses. Asad asked for a
   * vocabulary he can say out loud — *"I open this in your browser and check B2,
   * B1… So it should know it's B2 and B1s"* — and after his first detach his
   * vocabulary and the app's disagree for the life of the session.
   *
   * Nothing is protected by that. The no-reuse rule exists so a stale `B1` in an
   * agent's head cannot silently come to mean a different page *while the page
   * it named is still on screen beside it*. With the list empty there is no such
   * page: every window this session ever held has been detached or closed, so
   * there is nothing left for a stale reference to collide with, and calling the
   * first window of an empty session `B4` is not conservative — it is just a
   * wrong name.
   *
   * So the restart happens at allocation ({@link restartNumbering}) rather than
   * at detach, which is what makes it safe: a number that has been *printed* to
   * an agent but whose window has not arrived yet — {@link reserve} — holds the
   * restart off until it lands or expires.
   */
  next: number
  /**
   * True once the pty is gone.
   *
   * The rows are **kept**. `renderer/browser/agent-target.ts` makes the same
   * argument about a dead session in its picker: the stale entry is what lets
   * the window say *why* instead of going quietly blank. Nothing can arrive
   * from a dead pty, so keeping the row costs nothing and explains the page
   * still on screen.
   */
  ended: boolean
}

/** What {@link resolve} decided to do with a URL. */
export type OpenPlan =
  /** Navigate this window; it is the lowest-numbered one this session holds. */
  | { kind: 'navigate'; window: BoundWindow }
  /** This session has no window; open one and attach it. */
  | { kind: 'new' }
  /**
   * Not ours to place. `reason` is a sentence, because every refusal in this
   * feature is printed at a person or at an agent and "false" is not something
   * either of them can act on.
   */
  | { kind: 'system'; reason: string }

/** The renderer's read-only copy. Shaped for a push, not for a query. */
export interface BindingView {
  sessions: SessionBinding[]
}

type Listener = (view: BindingView) => void

/* ---------------------------------------------------------------- the map -- */

/**
 * Keyed `<machineId>\0<sessionId>`.
 *
 * A machine id is part of the key rather than a field to search on because two
 * machines may hand out the same session id and there is nothing stopping them:
 * ids are minted per host. The separator is a NUL because it cannot occur in
 * either half.
 */
const bindings = new Map<string, SessionBinding>()

/** Every window, by shell tab id, so a tab id resolves without a scan. */
const windowOwner = new Map<string, string>()

/**
 * Sessions whose window list has changed since the agent was last told.
 *
 * ## Why a set and not a push
 *
 * Asad, watching an agent that had just had two windows attached to it:
 *
 * > *"First of all, it should automatically right away get a context. Whenever I
 * > just connect, it should get a context… It should get a message, either if
 * > possible then in the background, otherwise a small prompt maybe."*
 *
 * There is no channel from this process into a running agent's turn except the
 * one the agent itself opens: its hook command, which blocks on our HTTP
 * response and reads `additionalContext` out of it. Nothing here can *push*.
 * What it can do is have the answer already waiting the next time the agent
 * knocks — and `PostToolUse` knocks after every tool call, which is seconds
 * rather than a turn. So an attach marks the session here, and the next hook
 * event of any context-carrying kind drains it.
 *
 * Nothing is typed into the terminal. He has objected to that three times and
 * this is the whole reason the mechanism looks like this rather than like a
 * write to the pty.
 *
 * ## What "right away" can and cannot mean, stated plainly
 *
 * A CLI sitting at an empty prompt is not running. It has no turn to inject
 * into, it will not call a hook until it is spoken to, and the only way to make
 * it read something *now* is to type into his terminal — which is the one thing
 * he has ruled out repeatedly, most recently on watching an account switch put a
 * line into his own message: *"See, what the fuck is this? This came in my
 * message automatically."*
 *
 * So the guarantee this mechanism actually makes is the strongest one available
 * without typing, and it is worth stating exactly:
 *
 *  - **Working when he connects** — the agent is told at its very next tool
 *    call, which is seconds, mid-turn, through {@link takeAnnouncement}.
 *  - **Idle when he connects** — the agent is told as part of his next prompt,
 *    *before* the model sees the prompt, through {@link hookContext}. It cannot
 *    answer a question about its browser windows without having been told first,
 *    which is the observable half of what he asked for.
 *
 * The gap is the stretch in between, where an idle agent has not been asked
 * anything: nothing is delivered there, and nothing is delivered there because
 * nothing is listening.
 *
 * **Marked on attach and detach only.** Not on navigation: a page moving from
 * one URL to the next is already carried by the standing context on his next
 * prompt, and marking it here would put a paragraph into the agent's turn every
 * time a page in a window he is not looking at redirected.
 */
const unannounced = new Set<string>()

const listeners = new Set<Listener>()

function keyOf(sessionId: string, machineId: string): string {
  return `${machineId}\u0000${sessionId}`
}

/**
 * How many binding colours there are, and the ceiling this feature states
 * rather than hides.
 *
 * Four sessions can be told apart by colour at a glance. The fifth repeats one,
 * and from there the **number** and the tooltip carry it — which they have to
 * anyway, because `StatusDot`'s own header is right that "colour alone never
 * carries the meaning".
 */
export const BIND_COLOURS = 4

/**
 * The colour slot for a new binding: the one in least use, lowest index first.
 *
 * Round-robin by occupancy rather than by a counter, so closing one session and
 * opening another reuses the freed colour instead of marching through all four
 * and coming back to a colour that is still on screen.
 */
function nextColour(): number {
  const used = new Array<number>(BIND_COLOURS).fill(0)
  for (const binding of bindings.values()) used[binding.colour % BIND_COLOURS] += 1
  let best = 0
  for (let i = 1; i < BIND_COLOURS; i += 1) if (used[i] < used[best]) best = i
  return best
}

/**
 * When each session last had a number handed out by {@link reserve} that no
 * window has claimed yet, by binding key.
 *
 * ## What it is guarding
 *
 * `reserve` prints `B2` at an agent *before* the window exists — the shim is
 * holding a connection open while the renderer builds the tab. In that gap the
 * session's window list can be empty while a number is already spoken for, and
 * {@link restartNumbering} must not hand the same number to something else: two
 * windows called `B2` is the one failure the whole allocation scheme exists to
 * make impossible.
 *
 * ## Why a timestamp and not a count
 *
 * A counter incremented here and decremented on the claim leaks the day a
 * reservation is never claimed — the renderer refused, the window was closed
 * before it registered — and a leaked counter would silently switch the restart
 * off for that session forever. A timestamp cannot leak: it simply goes stale.
 * {@link RESERVATION_TTL_MS} is comfortably past the point the caller has given
 * up waiting, so a reservation that is still young is one that can still land.
 */
const reservedAt = new Map<string, number>()

/**
 * How long a printed-but-unclaimed number is treated as spoken for.
 *
 * `browser-binding-ipc.ts` gives the renderer 2s to open a window and answer,
 * and `browser-route.ts` claims the number immediately afterwards. Five times
 * that, so the guard outlives every real round trip and no wedged one outlives
 * the session.
 */
const RESERVATION_TTL_MS = 10_000

/**
 * Start this session's numbering again at `B1`, when it is safe to.
 *
 * Two conditions, both necessary. The window list must be empty — see
 * {@link SessionBinding.next} for why an empty list is the only moment a
 * restart takes nothing away from anybody. And no number may be in flight, or
 * the restart would re-hand a number an agent has already been told.
 */
function restartNumbering(binding: SessionBinding, key: string): void {
  if (binding.windows.length > 0) return
  const at = reservedAt.get(key)
  if (at !== undefined && Date.now() - at < RESERVATION_TTL_MS) return
  binding.next = 0
}

/** The binding for a session, creating it on first attach and not before. */
function ensure(sessionId: string, machineId: string): SessionBinding {
  const key = keyOf(sessionId, machineId)
  const found = bindings.get(key)
  if (found) return found
  const made: SessionBinding = {
    sessionId,
    machineId,
    windows: [],
    colour: nextColour(),
    next: 0,
    ended: false,
  }
  bindings.set(key, made)
  return made
}

/* ------------------------------------------------------------ the view push -- */

function snapshot(): BindingView {
  return {
    sessions: [...bindings.values()].map((binding) => ({
      ...binding,
      windows: binding.windows.map((window) => ({ ...window })),
    })),
  }
}

/**
 * Tell everyone watching.
 *
 * Called at the end of every mutation rather than by the mutators' callers, so
 * that a new operation added later cannot be the one that forgets. A listener
 * that throws is absorbed: the push is a courtesy to a window, and a renderer
 * that has gone away must not be able to take a hook answer down with it.
 */
function publish(): void {
  const view = snapshot()
  for (const listener of listeners) {
    try {
      listener(view)
    } catch {
      // A subscriber's problem is not this map's problem.
    }
  }
}

/** Watch the relation. Returns the unsubscribe. */
export function subscribe(listener: Listener): () => void {
  listeners.add(listener)
  listener(snapshot())
  return () => {
    listeners.delete(listener)
  }
}

/** The whole relation, for a renderer that has just come up. */
export function view(): BindingView {
  return snapshot()
}

/* ------------------------------------------------------------- attachment -- */

export interface AttachInput {
  sessionId: string
  /** Empty or absent for a session on this machine. */
  machineId?: string
  /** The renderer's shell tab id. */
  browserTabId: string
  viewId?: string | null
  url?: string
  title?: string
  /** Where the page is really served from. See {@link BoundWindow.hostMachineId}. */
  hostMachineId?: string
  hostMachineName?: string
}

/**
 * Attach a browser window to a session, and hand back the window it became.
 *
 * A window already attached somewhere else **moves**. That is deliberate and it
 * is the same decision the menu draws: a window bound to another session is
 * listed, wearing that session's mark, and choosing it moves it. Refusing, or
 * listing it greyed with no explanation, is the *"a screen that quietly shows a
 * subset"* failure `agent-target.ts` exists to stop.
 *
 * Re-attaching a window to the session it is already on is a no-op that keeps
 * its number, so a re-registration after a reload does not renumber anything.
 */
export function attach(input: AttachInput): BoundWindow {
  const machineId = input.machineId ?? ''
  const binding = ensure(input.sessionId, machineId)

  const previousKey = windowOwner.get(input.browserTabId)
  if (previousKey !== undefined && previousKey !== keyOf(input.sessionId, machineId)) {
    detachFrom(previousKey, input.browserTabId)
  }

  const existing = binding.windows.find((window) => window.browserTabId === input.browserTabId)
  if (existing) {
    if (input.viewId !== undefined) existing.viewId = input.viewId
    if (input.url !== undefined) existing.url = input.url
    if (input.title !== undefined) existing.title = input.title
    if (input.hostMachineId !== undefined) existing.hostMachineId = input.hostMachineId
    if (input.hostMachineName !== undefined) existing.hostMachineName = input.hostMachineName
    windowOwner.set(input.browserTabId, keyOf(input.sessionId, machineId))
    publish()
    return existing
  }

  // An empty session starts again at `B1`. See {@link restartNumbering}.
  restartNumbering(binding, keyOf(input.sessionId, machineId))
  binding.next += 1
  const made: BoundWindow = {
    n: binding.next,
    browserTabId: input.browserTabId,
    viewId: input.viewId ?? null,
    url: input.url ?? '',
    title: input.title ?? '',
    hostMachineId: input.hostMachineId ?? '',
    hostMachineName: input.hostMachineName ?? '',
  }
  binding.windows.push(made)
  binding.windows.sort((a, b) => a.n - b.n)
  windowOwner.set(input.browserTabId, keyOf(input.sessionId, machineId))
  unannounced.add(keyOf(input.sessionId, machineId))
  publish()
  return made
}

function detachFrom(key: string, browserTabId: string): void {
  const binding = bindings.get(key)
  if (!binding) return
  const before = binding.windows.length
  binding.windows = binding.windows.filter((window) => window.browserTabId !== browserTabId)
  // Losing a window is as much a change of the agent's surroundings as gaining
  // one, and the more urgent of the two: an agent still holding `B2` will
  // otherwise steer a page that is no longer its to steer.
  if (binding.windows.length !== before) unannounced.add(key)
  // The binding row itself stays, even at zero windows, and `next` stays with
  // it. That is what makes attach-detach-attach produce `B2` rather than a
  // second `B1` pointing somewhere else.
}

/**
 * Detach a window from whatever session holds it. The page stays open — this is
 * the ✕ in the menu, which is a different verb from the strip's ✕ two inches
 * away, and both of them have to say which one they are.
 */
export function detach(browserTabId: string): void {
  const key = windowOwner.get(browserTabId)
  if (key === undefined) return
  windowOwner.delete(browserTabId)
  detachFrom(key, browserTabId)
  publish()
}

/** A window that is genuinely gone. Same bookkeeping; the number is not freed. */
export function windowClosed(browserTabId: string): void {
  detach(browserTabId)
}

/**
 * A window reporting where it is and what it is called.
 *
 * Only ever called with what the window said about itself. Nothing here fills a
 * blank in: an unnamed page prints as its URL and a page with neither prints as
 * neither, because the alternative is a hook answer telling an agent a title
 * that no page ever had.
 */
export function windowMoved(
  browserTabId: string,
  update: {
    viewId?: string | null
    url?: string
    title?: string
    hostMachineId?: string
    hostMachineName?: string
  },
): void {
  const key = windowOwner.get(browserTabId)
  if (key === undefined) return
  const binding = bindings.get(key)
  const window = binding?.windows.find((entry) => entry.browserTabId === browserTabId)
  if (!window) return
  if (update.viewId !== undefined) window.viewId = update.viewId
  if (update.url !== undefined) window.url = update.url
  if (update.title !== undefined) window.title = update.title
  if (update.hostMachineId !== undefined) window.hostMachineId = update.hostMachineId
  if (update.hostMachineName !== undefined) window.hostMachineName = update.hostMachineName
  publish()
}

/* -------------------------------------------------------------- lifecycle -- */

/**
 * The session's process ended. Its windows stay, marked.
 *
 * Deliberately not the same event as removal, and the app already tells them
 * apart everywhere else: a process that ends by itself keeps its tab and its
 * scrollback because reading what it printed is the reason that tab is still
 * worth having, and the page it left open is part of what it printed.
 */
export function sessionExited(sessionId: string, machineId = ''): void {
  const binding = bindings.get(keyOf(sessionId, machineId))
  if (!binding || binding.ended) return
  binding.ended = true
  publish()
}

/** The app has let go of the session entirely. Rows dropped, colour released. */
export function sessionRemoved(sessionId: string, machineId = ''): void {
  const key = keyOf(sessionId, machineId)
  const binding = bindings.get(key)
  if (!binding) return
  for (const window of binding.windows) windowOwner.delete(window.browserTabId)
  bindings.delete(key)
  // Nothing left to tell, and nobody left to tell it to.
  unannounced.delete(key)
  reservedAt.delete(key)
  publish()
}

/**
 * The renderer that owned every one of these windows has been replaced —
 * ⌘R, a dev rebuild, a recovered crash.
 *
 * Every browser window really is gone: the tab list is plain React state and
 * `browser-tab.ts` destroys the views on `hostDocumentReplaced`. So every
 * binding for that host is dropped, and the sessions survive with nothing
 * attached — which is a true sentence the next hook answer can say, where
 * "persist it and hope" would be a false one.
 */
export function hostReset(): void {
  if (bindings.size === 0) return
  bindings.clear()
  windowOwner.clear()
  unannounced.clear()
  reservedAt.clear()
  publish()
}

/* ---------------------------------------------------------------- reading -- */

export function bindingFor(sessionId: string, machineId = ''): SessionBinding | null {
  return bindings.get(keyOf(sessionId, machineId)) ?? null
}

/** The session a window is attached to, for the menu's "attached elsewhere" row. */
export function ownerOf(browserTabId: string): SessionBinding | null {
  const key = windowOwner.get(browserTabId)
  if (key === undefined) return null
  return bindings.get(key) ?? null
}

/**
 * Where a URL from this session should go.
 *
 * **Lowest-numbered, not most-recent.** A hidden "current window" cannot be
 * stated truthfully in one line, and this answer can: *"`open` goes to B1
 * unless you detach it."* It is also the only one that stays predictable
 * without consulting something invisible — he can be looking at B1, and a
 * most-recent rule would put the next page behind him in B2.
 *
 * `newWindow` is the explicit ask. The *situational* half of his rule — reuse
 * unless the page has unfinished work — is not decided here, because the only
 * honest signal for it is the page's own `beforeunload` and only the window
 * knows that. See `openInBoundWindow` in `src/main/index.ts`, which asks the
 * page and mints a new window when the page says no.
 */
export function resolve(
  sessionId: string | null,
  machineId = '',
  options: { newWindow?: boolean; known?: boolean } = {},
): OpenPlan {
  if (!sessionId) {
    return {
      kind: 'system',
      reason: 'No Terminal Deck session here — opened in your default browser.',
    }
  }
  const binding = bindings.get(keyOf(sessionId, machineId))
  if (!binding) {
    /*
     * A session this app started, that simply has no window yet, gets one.
     * An id this app has never heard of does not.
     *
     * The two look identical from inside this map — neither has a row — and
     * telling them apart is what keeps the feature both useful and honest. The
     * first `open` in a fresh session is the common case and must land in the
     * app, or the whole feature does nothing until somebody attaches a window
     * by hand. An id from somewhere else must land nowhere near his browser:
     * the hook is installed globally in `~/.claude/settings.json` and fires for
     * sessions this app never started, and injecting an unattributable URL into
     * a browser holding his logins is not a thing to do on a guess.
     *
     * `known` is answered by the caller, because the list of live sessions
     * belongs to the pty manager and this module is deliberately a map with no
     * dependencies.
     */
    return options.known
      ? { kind: 'new' }
      : {
          kind: 'system',
          reason: 'No Terminal Deck session here — opened in your default browser.',
        }
  }
  if (options.newWindow || binding.windows.length === 0) return { kind: 'new' }
  return { kind: 'navigate', window: binding.windows[0] }
}

/**
 * Reserve the next number for a window that is about to be opened.
 *
 * Split out from {@link attach} because the shim is waiting on an answer while
 * the window is still being created in the renderer, and answering with a
 * number that the attach will later contradict is precisely the "number that
 * might be untrue" his rule forbids. The reservation is the same increment
 * {@link attach} would have done, so the window that arrives takes exactly the
 * number that was printed.
 */
export function reserve(sessionId: string, machineId = ''): number {
  const key = keyOf(sessionId, machineId)
  const binding = ensure(sessionId, machineId)
  // The same restart {@link attach} makes, for the same reason: the first `open`
  // of a session whose windows have all been closed should print `B1`, not `B4`.
  restartNumbering(binding, key)
  binding.next += 1
  // Spoken for from here until the window lands or the reservation goes stale.
  reservedAt.set(key, Date.now())
  return binding.next
}

/**
 * Attach a window to a number already handed out by {@link reserve}.
 *
 * Nothing else in this module lets a caller choose a number, and it must stay
 * that way: two windows with the same `n` is the failure this whole allocation
 * scheme exists to make impossible. A reservation that was never claimed simply
 * leaves a gap, which is the same harmless gap a closed window leaves.
 */
export function attachReserved(input: AttachInput & { n: number }): BoundWindow | null {
  const machineId = input.machineId ?? ''
  const key = keyOf(input.sessionId, machineId)
  const binding = bindings.get(key)
  // Claimed or refused, the reservation is over either way: the number is about
  // to be a real window's, or nothing is ever going to arrive for it.
  reservedAt.delete(key)
  if (!binding) return null
  if (binding.windows.some((window) => window.n === input.n)) return null

  const previousKey = windowOwner.get(input.browserTabId)
  if (previousKey !== undefined) detachFrom(previousKey, input.browserTabId)

  const made: BoundWindow = {
    n: input.n,
    browserTabId: input.browserTabId,
    viewId: input.viewId ?? null,
    url: input.url ?? '',
    title: input.title ?? '',
    hostMachineId: input.hostMachineId ?? '',
    hostMachineName: input.hostMachineName ?? '',
  }
  binding.windows.push(made)
  binding.windows.sort((a, b) => a.n - b.n)
  windowOwner.set(input.browserTabId, keyOf(input.sessionId, machineId))
  unannounced.add(keyOf(input.sessionId, machineId))
  publish()
  return made
}

/** `B1`, `B2` — the one place the word is spelled, so nothing can spell it twice. */
export function slotName(n: number): string {
  return `B${n}`
}

/**
 * The number inside a name somebody says back: `B2`, `b2`, `2`, ` B2 `.
 *
 * The inverse of {@link slotName} and deliberately beside it, so the two
 * spellings of one convention cannot drift. It is lenient about case and about
 * the leading letter because an agent that was handed `B2` will sooner or later
 * say `b2` — and refusing that would be refusing on a technicality something
 * this map can answer exactly.
 *
 * It is *not* lenient about anything else. `B2 (Stripe)`, `window 2` and
 * `browser:1755…:3` all answer null, which is what makes the caller's refusal a
 * single sentence rather than a guess: a name this cannot parse is a name no
 * session has.
 */
export function slotNumber(name: string): number | null {
  const match = /^[bB]?(\d{1,4})$/.exec(name.trim())
  if (!match) return null
  const n = Number(match[1])
  return Number.isInteger(n) && n > 0 ? n : null
}

/**
 * The window a session calls `name`, or null — the whole of the permission
 * check for driving one.
 *
 * ## Why this is the check and not a step before it
 *
 * A verb that can act on a window has to answer one question: *is this window
 * this session's?* Not "does this window exist", which is a different question
 * with a more dangerous answer. Two sessions each hold a `B1`; a window
 * somebody attached to the session next door is a page in **this** app holding
 * **his** logins, and an agent that could reach it by asking for `B1` with a
 * neighbour's id would be reading a page nobody gave it.
 *
 * So the lookup starts from the session and never from the window: a name is
 * resolved *inside* one binding's list, so a window bound elsewhere is not
 * found, is not distinguishable from a window that does not exist, and cannot
 * be probed for by trying names. `ownerOf` exists for the menu, which is drawn
 * for a person who can see the windows anyway; nothing on the tool path may use
 * it.
 *
 * ## Why the machine may be omitted
 *
 * The key is `<machineId>\0<sessionId>` because two machines can mint the same
 * session id — see the map's header. A caller naming a session usually has the
 * id and not the machine, so an omitted `machineId` scans for the id across
 * machines and answers null when two of them hold it. Null rather than a pick:
 * an ambiguous id is exactly the case where guessing means driving somebody
 * else's page, and it cannot happen at all with the uuids every provider mints.
 */
export function windowNamed(
  sessionId: string,
  name: string,
  machineId?: string,
): BoundWindow | null {
  const n = slotNumber(name)
  if (n === null) return null
  const found = windowsOf(sessionId, machineId).filter((window) => window.n === n)
  return found.length === 1 ? found[0] : null
}

/**
 * Every window one session holds, ordered by number.
 *
 * Same machine rule as {@link windowNamed}: an omitted `machineId` answers for
 * the one binding that carries this id, and an empty list when two do.
 */
export function windowsOf(sessionId: string, machineId?: string): BoundWindow[] {
  if (machineId !== undefined) {
    return bindings.get(keyOf(sessionId, machineId))?.windows ?? []
  }
  const matches = [...bindings.values()].filter((binding) => binding.sessionId === sessionId)
  return matches.length === 1 ? matches[0].windows : []
}

/**
 * One window as the line everything that has to name it prints.
 *
 * Exported so the tools an agent calls describe a window in exactly the words
 * the hook answer used, rather than inventing a second spelling of the same
 * fact. See {@link windowLine} for why each part is omitted rather than filled
 * in when the window has not reported it.
 */
export function describeWindow(window: BoundWindow): string {
  return windowLine(window)
}

/**
 * The one instruction in this whole channel, and he asked for it in the same
 * breath as the facts it governs.
 *
 * Asad, 2026-08-20, having asked a session what it knew about this app and been
 * told nothing: *"it should be given, like **it should not tell about Terminal
 * Deck when it is answering**, but it should just keep it with it. So it knows
 * when we ask about it."*
 *
 * Everything else composed here is a statement of fact and deliberately so —
 * the header above `hookContext` argues that a line earns its place only by
 * changing what the agent *does*. This line changes what it does not do, which
 * is the same test. Without it, what an agent makes of a fresh fact about its
 * own surroundings is left entirely to the model, and the thing models reliably
 * do with one is mention it: the first reply of every session opening with
 * "I'm running inside Terminal Deck" is precisely the visible noise he has now
 * ruled out three times, in the one place he cannot turn off.
 *
 * Two clauses, because a flat "never mention this" would be the opposite error.
 * He asked to be able to *ask* — *"so it knows when we ask about it"* — and an
 * agent that opens `B2` and then may not say which window it used has been made
 * useless in order to be quiet.
 */
const DISCRETION = 'Do not mention any of this unless it is asked about or you act on it.'

/**
 * The events that arrive in the **middle** of a turn, in each CLI's spelling.
 *
 * One set rather than a comparison against `'PostToolUse'` written at the call
 * site, because there are now two spellings of the same moment and the caller
 * had one of them hard-coded: Claude calls it `PostToolUse` and Gemini calls it
 * `AfterTool`, and both are "the agent has just finished a tool call and is
 * still working". A mid-turn event answered with the *standing* description
 * instead of the change would repeat the same paragraph at every tool call of
 * every turn, which is the one cost this channel was designed around.
 *
 * `hook-server.ts` decides whether an event is answered at all; this only says
 * which of the two answers it gets.
 */
export const MID_TURN_EVENTS: ReadonlySet<string> = new Set(['PostToolUse', 'AfterTool'])

/**
 * One window, as a line an agent reads: `B2 — Stripe — https://… — on DESKTOP`.
 *
 * Title first because it is what he says out loud. Every part is omitted when
 * the window has not reported it, rather than filled in with a placeholder that
 * reads like a fact — a hook answer naming a page title no page ever had is
 * worse than a short line.
 *
 * The machine is the part that is new, and it is the *whole* point of stating
 * it: a page reached through the tunnel wears a `localhost` address on **this**
 * machine, so an agent reading the URL alone would conclude the opposite of the
 * truth. It is left off entirely for a window on this computer, because "on
 * this computer" is what every other line here already implies.
 */
function windowLine(window: BoundWindow): string {
  const parts = [slotName(window.n), window.title, window.url].filter((part) => part !== '')
  const line = parts.join(' — ')
  return window.hostMachineId === ''
    ? line
    : `${line} — served by ${window.hostMachineName || window.hostMachineId}`
}

/**
 * What has changed about this session's windows since the agent was last told,
 * or null when nothing has.
 *
 * **Draining.** Reading it clears it, so the announcement lands in exactly one
 * turn's context and is never repeated — the standing {@link hookContext} is
 * what carries the same facts from then on, and paying for both on every event
 * would double the cost of the whole channel for no new information.
 *
 * It is deliberately a complete restatement of the list rather than a diff. An
 * agent that missed the previous one — a session that had no tool call between
 * two attaches, a hook that timed out — would otherwise be left holding half a
 * list, and a list is small.
 */
export function takeAnnouncement(sessionId: string, machineId = ''): string | null {
  const key = keyOf(sessionId, machineId)
  if (!unannounced.has(key)) return null
  unannounced.delete(key)
  const binding = bindings.get(key)
  const windows = binding?.windows ?? []
  if (windows.length === 0) {
    return 'No browser window is attached to this session now.'
  }
  return [
    'Browser windows attached to this session (this just changed):',
    ...windows.map(windowLine),
    `"the browser" means ${slotName(windows[0].n)}.`,
    // Here as well as in the standing answer, and for a sharper reason: this
    // one lands *mid-turn*, in the middle of work the agent is already
    // narrating, which is the likeliest moment of all for it to stop and
    // report that something has changed about its browser windows.
    DISCRETION,
  ].join('\n')
}

/** Test seam: is there something waiting to be said? Never drains. */
export function hasAnnouncement(sessionId: string, machineId = ''): boolean {
  return unannounced.has(keyOf(sessionId, machineId))
}

/* ------------------------------------------------------- the hook answer -- */

/** What is true of the session asking, that the map itself cannot know. */
export interface HookContextInput {
  /**
   * Did *this app* start this session?
   *
   * The hook is installed globally in `~/.claude/settings.json`, so it fires for
   * his own terminal `claude` too, and that one is not inside this app and must
   * never be told that it is. The session id header is already most of the
   * answer — only a pty this app started carries the environment variable — but
   * the authoritative list of sessions belongs to the pty manager, and this
   * module is deliberately a map with no dependencies. So the caller answers it,
   * exactly as it already answers {@link resolve}'s `known`.
   */
  known?: boolean
  /**
   * Did this run put its `open` shim on this session's PATH?
   *
   * Gates the one sentence below that describes behaviour rather than state. The
   * shim is what makes `open <url>` land in a window in this app, and
   * `open-shim.ts` writes nothing at all on Windows, or on a Linux box with
   * neither `xdg-open` nor `sensible-browser`. Telling an agent about a route
   * that is not on its PATH is the kind of confident falsehood this whole
   * builder exists to avoid.
   */
  opensInApp?: boolean
  /**
   * The app's map of itself, when this knock is one of the few that carries it.
   *
   * Composed by `app-context.ts`, which also owns *which* events get it — this
   * module is handed the text or nothing, exactly as it is handed `known` and
   * `opensInApp`, and never decides for itself. That is what keeps the budget
   * argument below true: the map rides once per context, everything else here
   * still rides every prompt.
   *
   * Inserted directly under the first line rather than appended, so that "you
   * are inside this app" and "here is where to read more about it" are one
   * thought, and so {@link DISCRETION} stays last.
   */
  map?: string | null
}

/**
 * What to tell the agent at the start of its turn, or null when there is
 * nothing true to say.
 *
 * ## What he asked for
 *
 * Asad, 2026-08-19: *"force the sessions to carry some context about the
 * application … not by sending a command inside the terminal, but like it
 * automatically knows on the boot … for example saying 'open a new web
 * browser window', so it knows it is inside Terminal Deck and it needs to open
 * inside, not outside. But no visual stuff."* This function is the whole of it:
 * it is composed into an HTTP response the agent is blocked on, so it arrives
 * before the first token of the turn and not one character of it is ever typed
 * into the terminal he is looking at.
 *
 * ## Why it is this short
 *
 * It rides **every** prompt, not just the first, so every word is paid for again
 * on every turn of every session, out of the same context budget the top bar now
 * shows him. So the rule here is not brevity for taste: a line earns its place
 * only by changing what the agent *does*. A version number, a feature list or a
 * sentence of marketing about this app changes nothing and is not here.
 *
 * What is left is three kinds of fact, in the order they are useful:
 *
 *  1. **Where it is.** One line, with the appositive that makes it actionable —
 *     an agent trained before this app existed cannot infer from the name that
 *     the thing it is inside has browser windows of its own, which is precisely
 *     the inference his example depends on.
 *  2. **Which windows are its own**, when it has any. Already carried before
 *     today, and unchanged.
 *  3. **Where a URL goes.** The shim already routes `open <url>` into this app
 *     without being asked, so this states the *consequence* rather than issuing
 *     an instruction: the agent needs to know the page will land beside the
 *     terminal, because that is what makes "open it" the right answer instead of
 *     printing a link for him to click.
 *
 * ## The one thing here that is not paid for every turn
 *
 * {@link HookContextInput.map} — the app's own map of itself, from
 * `app-context.ts`. It is longer than anything above, and it is affordable for
 * exactly one reason: it arrives only on the knocks that build a context rather
 * than on every prompt. This function does not decide that and must not; it is
 * handed the text or it is handed nothing.
 *
 * ## Null is still the common case and still free
 *
 * A session this app did not start gets null, which is the byte-identical
 * `204 No Content` this endpoint has always answered. So the terminal `claude`
 * he runs outside the app is untouched, and the observing-not-steering contract
 * holds everywhere it held yesterday.
 */
export function hookContext(
  sessionId: string | null,
  machineId = '',
  input: HookContextInput = {},
): string | null {
  if (!sessionId) return null
  const binding = bindings.get(keyOf(sessionId, machineId))
  const windows = binding?.windows ?? []
  /*
   * A window attached to this id is proof on its own, and is why `known` is not
   * simply required: the renderer only ever attaches a window to a session this
   * app is running, so a binding with windows in it answers the same question
   * from the other side.
   */
  if (input.known !== true && windows.length === 0) return null

  const lines = [
    `You are running inside ${BRAND.name}, a terminal app with browser windows of its own.`,
  ]

  // Second, and only on the knocks `app-context.ts` chose. See {@link
  // HookContextInput.map}: this is where "and here is the rest of it" belongs,
  // beside the sentence that says where "here" is.
  if (input.map) lines.push(input.map)

  if (windows.length > 0) {
    lines.push('Browser windows attached to this session:')
    // `windowLine` rather than a second spelling of it: the standing answer and
    // the change announcement describe the same windows, and two builders is how
    // one of them comes to name a machine the other does not.
    for (const window of windows) lines.push(windowLine(window))
    /*
     * And the pending announcement is settled here, because this **is** the
     * announcement.
     *
     * This function is answered at the top of a turn and {@link takeAnnouncement}
     * mid-turn, and until now the two did not know about each other. A window
     * attached to an idle session was marked unannounced, the next prompt got
     * this list, and then the agent's first tool call got the same list a second
     * time under *"this just changed"* — one paragraph twice inside one turn, out
     * of the same context budget he watches in the top bar.
     *
     * Only when the list is non-empty, and the asymmetry is the point: a list
     * printed in full is a complete restatement, so there is nothing left to
     * announce. The empty case is a *detach*, which this answer says nothing
     * about — it simply stops mentioning windows — so its announcement is left
     * standing for the mid-turn door, where "no browser window is attached to
     * this session now" is the only thing that will ever tell an agent still
     * holding `B1` that `B1` is gone.
     */
    unannounced.delete(keyOf(sessionId, machineId))
    const first = slotName(windows[0].n)
    /*
     * The naming half is worth its words even where the shim is not installed,
     * because it is what lets him say "look at B2" and be understood; only the
     * routing half is a claim about behaviour, so only that half is gated.
     */
    lines.push(
      input.opensInApp === true
        ? `"the browser" means ${first}. \`open <url>\` goes to ${first} unless you detach it.`
        : `"the browser" means ${first}.`,
    )
  } else if (input.opensInApp === true) {
    lines.push(
      "`open <url>` here opens a browser window in this app, not the machine's browser.",
    )
  }

  // Last, because everything above it is a fact and this is what to do with
  // them. See {@link DISCRETION}.
  lines.push(DISCRETION)

  return lines.join('\n')
}

/** Test seam. Nothing in the app calls this; every real reset is an event. */
export function resetForTests(): void {
  bindings.clear()
  windowOwner.clear()
  unannounced.clear()
  reservedAt.clear()
  listeners.clear()
}
