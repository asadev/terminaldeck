/**
 * The pacing engine's runtime: a frame clock, a published snapshot, and the
 * wiring between the interruption watch and the playhead.
 *
 * `pacer.ts` is a reducer and knows nothing about time passing; this is the
 * thing that makes time pass, and it is separated for one reason — everything
 * below is testable with a fake clock and a fake `requestAnimationFrame`, and
 * nothing below needs React. The React binding at the bottom is four lines.
 *
 * ## Frames, not timeouts
 *
 * The clock is `requestAnimationFrame` against a monotonic `now()`, never
 * `setTimeout`. A `setTimeout` keeps counting while the machine is asleep and
 * while the renderer is throttled in a background window, so a tour left open
 * over lunch would come back having advanced through every remaining stop with
 * nobody watching. `rAF` simply stops in a hidden window, which is the
 * behaviour that was wanted, and `MAX_TICK_GAP_MS` in the reducer catches the
 * moment it starts again.
 *
 * ## Measured at 60 Hz, reported at 10
 *
 * The reducer is ticked every frame because the estimate has to be accurate and
 * a scroll has to be noticed in the frame it happens. Subscribers are told at
 * most every `NOTIFY_MS`, because they are React components sitting beside a
 * terminal that is repainting a canvas, and re-rendering a transport bar sixty
 * times a second to move a progress ring by half a degree is work taken
 * directly from the thing the reader is trying to read.
 *
 * A change of *shape* — the status, the stop, the speed, whether the pointer is
 * inside the box — is published immediately, because those are the ones a
 * person is waiting on. Only the smooth countdown is throttled, and the ring's
 * CSS transition covers the gap.
 *
 * The published snapshot is deliberately not the live one. `useSyncExternalStore`
 * calls `getSnapshot` during render and re-renders whenever the answer changes,
 * so handing it a value that moves every frame without a matching notification
 * is how a component ends up rendering in a loop.
 */

import { useSyncExternalStore } from 'react'
import { DEFAULT_SPEED, type ReadingSpeed } from './estimate'
import {
  initialPacerState,
  pacerReducer,
  type PacerEvent,
  type PacerState,
  type PauseReason,
} from './pacer'
import {
  watchForInterruption,
  type InterruptionOptions,
  type InterruptionWatch,
} from './interruption'

/**
 * How often subscribers hear about a countdown that is merely counting down.
 *
 * 100 ms is ten updates a second: fast enough that a seconds-remaining number
 * never looks stuck, slow enough to be a rounding error next to a session
 * streaming output. The ring is drawn with a CSS transition, so it moves
 * continuously between updates rather than stepping.
 */
export const NOTIFY_MS = 100

/**
 * Events that respect the throttle rather than publishing at once.
 *
 * Everything a person did is published the instant it arrives — a pause that
 * shows up 90 ms late is a pause that already lost. These two are not a person.
 *
 * `moved` is the one that matters, and it was a real defect before it was
 * listed here: `attachInterruption` dispatches it on every `scroll` event, and
 * a session streaming output scrolls its pane every frame. Force-publishing on
 * it meant a busy fleet re-rendered the transport sixty times a second — which
 * is exactly the cost the throttle exists to avoid, arriving through the one
 * event that carries no news for the reader at all.
 */
const QUIET: ReadonlySet<PacerEvent['kind']> = new Set(['tick', 'moved'])

export interface PaceEngineOptions {
  /** Monotonic milliseconds. `performance.now` in the app, a counter in tests. */
  now(): number
  /** Schedules one frame. Returns a handle `cancelFrame` understands. */
  requestFrame(callback: () => void): number
  cancelFrame(handle: number): void
  speed?: ReadingSpeed
  notifyEveryMs?: number
}

export interface PaceEngine {
  /** The published state. Stable between notifications, by design. */
  getState(): PacerState
  /** The live state, for a caller that needs the exact instant. Tests, mostly. */
  peek(): PacerState
  dispatch(event: PacerEvent): void
  subscribe(listener: () => void): () => void
  /** Stops the frame loop and drops every subscriber. */
  destroy(): void
}

export function createPaceEngine(options: PaceEngineOptions): PaceEngine {
  const notifyEvery = options.notifyEveryMs ?? NOTIFY_MS
  let live = initialPacerState(options.speed ?? DEFAULT_SPEED)
  let published = live
  let publishedAt = options.now()
  let frame: number | null = null
  let destroyed = false
  const listeners = new Set<() => void>()

  /**
   * Which changes a reader is waiting on, as opposed to watching tick past.
   *
   * `elapsedMs` and `lastTickAt` are deliberately absent: they change every
   * frame and are the whole reason the throttle exists.
   */
  const shapeChanged = (before: PacerState, after: PacerState): boolean =>
    before.status !== after.status ||
    before.index !== after.index ||
    before.speed !== after.speed ||
    before.stops !== after.stops ||
    before.hovering !== after.hovering ||
    before.pausedBy !== after.pausedBy ||
    before.earlyRun !== after.earlyRun

  const publish = (): void => {
    published = live
    publishedAt = options.now()
    for (const listener of listeners) listener()
  }

  const commit = (next: PacerState): void => {
    if (next === live) return
    const before = live
    live = next
    if (shapeChanged(before, next) || options.now() - publishedAt >= notifyEvery) publish()
  }

  /**
   * Frames are burned only while something is actually counting.
   *
   * A paused or holding tour asks for no frames at all — not a loop that wakes
   * up and returns. That matters more here than in most apps: a paused tour is
   * a tour sitting over a fleet of sessions each painting a terminal, and the
   * whole point of pausing was to give the reader the machine back.
   */
  const wantsFrames = (state: PacerState): boolean =>
    state.status === 'playing' || state.status === 'travelling'

  const syncLoop = (): void => {
    if (destroyed) return
    if (wantsFrames(live)) {
      if (frame === null) frame = options.requestFrame(onFrame)
      return
    }
    if (frame !== null) {
      options.cancelFrame(frame)
      frame = null
    }
  }

  function onFrame(): void {
    frame = null
    if (destroyed) return
    commit(pacerReducer(live, { kind: 'tick', at: options.now() }))
    syncLoop()
  }

  return {
    getState: () => published,
    peek: () => live,
    dispatch(event: PacerEvent) {
      if (destroyed) return
      commit(pacerReducer(live, event))
      // Anything a person did is published at once, whatever the throttle says.
      if (!QUIET.has(event.kind) && published !== live) publish()
      syncLoop()
    },
    subscribe(listener: () => void) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    destroy() {
      destroyed = true
      if (frame !== null) options.cancelFrame(frame)
      frame = null
      listeners.clear()
    },
  }
}

/**
 * Point an interruption watch at an engine.
 *
 * Two lines of mapping, kept here rather than at the call site so that the one
 * decision inside it is written down once: an interruption becomes a `pause`
 * and surface movement becomes `moved`, and **`moved` never pauses**. See the
 * long note at the top of `interruption.ts` for why those are two different
 * questions.
 */
export function attachInterruption(
  engine: PaceEngine,
  options: Omit<InterruptionOptions, 'onInterrupt' | 'onSurfaceMoved'>,
): InterruptionWatch {
  return watchForInterruption({
    ...options,
    onInterrupt: (reason: PauseReason, at: number) => engine.dispatch({ kind: 'pause', reason, at }),
    onSurfaceMoved: (at: number) => engine.dispatch({ kind: 'moved', at }),
  })
}

/**
 * The engine wired to the real window's clock.
 *
 * Kept apart from `createPaceEngine` so that every test above runs against a
 * counter rather than a wall clock. `CLAUDE.md`'s note about faking things
 * applies in reverse here: the engine is real and the clock is injected, not
 * the other way round.
 */
export function browserPaceEngine(speed: ReadingSpeed = DEFAULT_SPEED): PaceEngine {
  return createPaceEngine({
    now: () => performance.now(),
    requestFrame: (callback) => requestAnimationFrame(() => callback()),
    cancelFrame: (handle) => cancelAnimationFrame(handle),
    speed,
  })
}

/** Subscribe a component to an engine. The whole React surface of this module. */
export function usePacer(engine: PaceEngine): PacerState {
  return useSyncExternalStore(engine.subscribe, engine.getState, engine.getState)
}
