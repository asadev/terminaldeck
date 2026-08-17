/**
 * Noticing that the reader is doing something, in the same frame they do it.
 *
 * The pacing engine's whole promise is that touching anything stops the tour.
 * That promise is only as good as the set of events listened for, so the set is
 * declared as data below rather than scattered through a wiring function — a
 * listener quietly dropped in a refactor is invisible in a diff and produces a
 * tour that keeps moving while somebody is trying to read, which is the exact
 * failure Asad named first.
 *
 * ## Two questions, not one
 *
 * There is a real distinction here that is easy to collapse and expensive to
 * get wrong:
 *
 * 1. **Did the reader do something?** → pause, immediately, and stay paused.
 * 2. **Is the thing on screen still moving?** → do not advance yet, but do not
 *    pause either.
 *
 * They need different events because they have different sources. A `scroll`
 * event does not say who caused it: the tour's own `scrollIntoView` fires one,
 * a live session appending output fires one, and a reader's trackpad fires one.
 * Listening for `scroll` and pausing on it would make the tour pause itself the
 * instant it moved to a stop, and would freeze permanently on any session that
 * is still printing.
 *
 * So: **`wheel` and `touchmove` are the human**, because nothing in the app
 * synthesises them; **`scroll` is the motion**, whoever caused it. The first
 * pauses. The second only blocks the advance until things settle. That split is
 * what makes "never advance while the user is mid-scroll" implementable without
 * also making "the tour scrolls to a stop" impossible.
 *
 * ## Capture phase, and why it is load-bearing
 *
 * Every listener is registered with `capture: true`, for two separate reasons.
 *
 * `scroll` **does not bubble**. A capture-phase listener on `window` still sees
 * it, because the capture phase travels down from the window to the target
 * before the target's own handlers run, and that is the only way to hear about
 * a scroll inside a pane without attaching a listener to every pane.
 *
 * And a pause has to land *before* whatever the click was going to do. The dim
 * over the app is `pointer-events: none` — driving is a highlight, not a modal
 * — so clicking a session row during a tour switches to that session **and**
 * pauses. That is what "take over" means, and it needs no separate gesture.
 *
 * ## What deliberately does not interrupt
 *
 * The transport's own controls, and the keys they answer to. Pressing Next is
 * the one gesture that unambiguously means "I have finished with this"; making
 * it pause would be perverse, and `pacer.ts` explains at length why the learned
 * speed and the Skim offer both depend on it not doing so. Both exclusions are
 * predicates supplied by the caller, so this module never has to know what the
 * transport is made of or which keys the keymap gave it.
 */

import type { PauseReason } from './pacer'

/**
 * The parts of a DOM event this module reads.
 *
 * A structural subset rather than `Event`, so the whole watch can be driven
 * from a plain object in a test. This repository has no DOM in its tests
 * deliberately — `finish.test.ts` says so — and an interruption watch that
 * could only be exercised inside a browser would be the one piece of the
 * pacing engine with no pinned behaviour at all.
 */
export interface WatchedEvent {
  readonly type: string
  readonly target?: unknown
  readonly key?: string
}

/** The parts of `window` / `document` this module uses. */
export interface EventSource {
  addEventListener(
    type: string,
    listener: (event: WatchedEvent) => void,
    options?: { capture?: boolean; passive?: boolean },
  ): void
  removeEventListener(
    type: string,
    listener: (event: WatchedEvent) => void,
    options?: { capture?: boolean },
  ): void
}

export interface InterruptionOptions {
  window: EventSource
  /** Where `selectionchange` and `visibilitychange` live. Optional for tests. */
  document?: EventSource
  now(): number
  /** True when the event came from the transport — a command, not an interruption. */
  isOwnControl(target: unknown): boolean
  /** True for a key the transport owns. Those are dispatched, not treated as typing. */
  isCommandKey(key: string): boolean
  /** Read when `visibilitychange` fires, because the event carries no state. */
  isHidden?(): boolean
  /**
   * Is there actually a selection, read when `selectionchange` fires?
   *
   * The event says a selection *changed*, which is not the same as a person
   * having selected something — and the difference was a defect that made the
   * whole feature look broken on the first frame. Moving keyboard focus
   * collapses the document selection and fires this; the driving panel takes
   * focus the moment it opens (so that Space is the pause key rather than a
   * space typed into somebody's terminal); so every tour paused itself before it
   * had drawn a single box, with the bar reading *"Paused — you selected some
   * text"* about a selection that did not exist.
   *
   * A collapsed selection is not reading with a finger on the page. Absent means
   * "cannot tell", which is treated as a real selection — the safe direction,
   * because the cost of a pause nobody asked for is one keypress and the cost of
   * ignoring one they did is the tour moving while they are reading.
   */
  hasSelection?(): boolean
  onInterrupt(reason: PauseReason, at: number): void
  /** The driven surface moved. Blocks advancing until it settles; never pauses. */
  onSurfaceMoved(at: number): void
}

export interface InterruptionWatch {
  stop(): void
}

/**
 * Events that mean a person did something, and what to call it.
 *
 * Declared as a table so a test can assert the whole set. Every entry is here
 * because of a specific way a reader signals they are not finished:
 *
 * - `wheel` — the trackpad. The single most likely one, and the reason
 *   `pointerdown` alone is not enough: reading long output means scrolling, and
 *   scrolling never involves a click.
 * - `pointerdown` — clicking anything at all, including the thing being
 *   pointed at. Not `click`: `pointerdown` fires the moment the finger lands,
 *   which is a whole gesture earlier.
 * - `touchstart` — the same on a touchscreen. Windows laptops have them.
 * - `keydown` — any key that is not the transport's. Typing into a session
 *   during a tour is somebody taking over.
 * - `blur` — focus left the window entirely. They are looking at something
 *   else, and the tour must not still be moving when they come back.
 */
export const INTERRUPTIONS: readonly { type: string; reason: PauseReason }[] = [
  { type: 'wheel', reason: 'scrolled' },
  { type: 'pointerdown', reason: 'clicked' },
  { type: 'touchstart', reason: 'clicked' },
  { type: 'keydown', reason: 'typed' },
  { type: 'blur', reason: 'left-window' },
]

/**
 * Events that mean the screen is moving, whoever moved it.
 *
 * `scroll` covers every pane in the window through the capture phase, and
 * `touchmove` is a drag in progress on a touchscreen — a finger still on the
 * glass is a scroll that has not finished, even between two `scroll` events.
 */
export const MOVEMENTS: readonly string[] = ['scroll', 'touchmove']

/**
 * Watch a window for anything that means the reader is not finished.
 *
 * Returns the teardown. Call it when the tour ends: a watch that outlives its
 * tour pauses a tour that no longer exists, and — worse on this app — keeps a
 * capture-phase `wheel` listener on the window for the rest of the session.
 */
export function watchForInterruption(options: InterruptionOptions): InterruptionWatch {
  const bound: Array<{ source: EventSource; type: string; listener: (e: WatchedEvent) => void }> = []

  const listen = (source: EventSource, type: string, listener: (e: WatchedEvent) => void): void => {
    // `passive: true` on the two that support it, because both fire during a
    // gesture and a non-passive listener on `wheel` makes the browser wait for
    // this handler before it scrolls. Nothing here ever calls preventDefault —
    // the reader's scroll must happen; the tour just needs to know about it.
    source.addEventListener(type, listener, { capture: true, passive: true })
    bound.push({ source, type, listener })
  }

  for (const { type, reason } of INTERRUPTIONS) {
    listen(options.window, type, (event) => {
      if (options.isOwnControl(event.target)) return
      if (type === 'keydown' && typeof event.key === 'string' && options.isCommandKey(event.key)) {
        return
      }
      /*
       * Only the *window's* blur means the reader left the window.
       *
       * `blur` does not bubble, which is exactly why every other listener here
       * is registered with `capture: true` — and capture is what made this
       * wrong. A capture-phase listener on `window` sees the blur of every
       * descendant on its way down, so an element merely losing focus inside a
       * window that never lost focus arrived here as "you left".
       *
       * That was not theoretical. The driving panel takes focus the moment it
       * opens, so that Space is the pause key rather than a space typed into
       * whichever pty had the keyboard; that blurs the terminal's textarea;
       * and every tour paused itself on its first frame with the bar reading
       * *"Paused — you left the window"* while the window was plainly in front.
       *
       * A target of `undefined` still counts, so the watch stays drivable from a
       * plain object with no DOM — which is how every timing rule in this
       * feature is tested.
       */
      if (type === 'blur' && event.target !== undefined && event.target !== options.window) {
        return
      }
      // A wheel event is both facts at once: a person did something, and the
      // screen is now moving. Reporting only the pause would let the tour
      // advance the moment it resumed, mid-fling.
      if (type === 'wheel') options.onSurfaceMoved(options.now())
      options.onInterrupt(reason, options.now())
    })
  }

  for (const type of MOVEMENTS) {
    listen(options.window, type, () => {
      options.onSurfaceMoved(options.now())
    })
  }

  const doc = options.document
  if (doc !== undefined) {
    // Selecting text is reading with a finger on the page. It is also the one
    // interruption with no pointer or key of its own on a trackpad — a
    // click-drag fires `pointerdown` first, but extending a selection with
    // shift-click or a double-click's word grab can land here first.
    //
    // A *collapsed* selection is not that, and the event does not distinguish
    // them: a focus change collapses the selection and fires this. See
    // `hasSelection`, which exists because the panel taking focus was making
    // every tour pause on its own first frame.
    listen(doc, 'selectionchange', () => {
      if (options.hasSelection?.() === false) return
      options.onInterrupt('selected', options.now())
    })

    // The event says nothing about which way it went, so the state is read at
    // the moment it fires. Becoming *visible* again must not resume: coming
    // back to a window that is already moving is the worst frame of the whole
    // feature, and DRIVING-MODE.md §8 says the same of window focus.
    listen(doc, 'visibilitychange', () => {
      if (options.isHidden?.() === true) options.onInterrupt('hidden', options.now())
    })
  }

  return {
    stop() {
      for (const { source, type, listener } of bound) {
        source.removeEventListener(type, listener, { capture: true })
      }
      bound.length = 0
    },
  }
}

/**
 * The marker every transport control wears, and the test for it.
 *
 * One attribute rather than a list of class names or a ref comparison, because
 * the question is asked of whatever the event happened to hit — an SVG path
 * inside a button inside the bar — and `closest` is the only cheap way to ask
 * "is this inside our controls" of an arbitrary descendant.
 *
 * Duck-typed rather than `instanceof Element`, so the predicate can be
 * exercised without a DOM. A target with no `closest` is not one of ours, which
 * is the safe answer: the worst case is a pause the reader did not need, and
 * the alternative — treating an unknown target as a control — would silently
 * stop the tour reacting to real clicks.
 */
export const PACE_CONTROL_ATTR = 'data-pace-control'

interface Closest {
  closest(selector: string): unknown
}

export function isPaceControlTarget(target: unknown): boolean {
  if (typeof target !== 'object' || target === null) return false
  const node = target as Partial<Closest>
  if (typeof node.closest !== 'function') return false
  return node.closest(`[${PACE_CONTROL_ATTR}]`) !== null
}

/**
 * The keys the transport owns, as the default `isCommandKey`.
 *
 * Space pauses and resumes, the arrows step, Escape ends the tour. They are
 * listed here rather than in the watch so that whoever wires `keymap.ts` has
 * one place to keep in step with — and so that a build where the chords are not
 * wired yet still does not treat them as somebody typing.
 */
export const TRANSPORT_KEYS: readonly string[] = [' ', 'ArrowLeft', 'ArrowRight', 'Escape']

export function isTransportKey(key: string): boolean {
  return TRANSPORT_KEYS.includes(key)
}
