/**
 * The scan's runtime: a frame clock, a published snapshot, and the wiring
 * between the interruption watch and the playhead.
 *
 * `shared/scan.ts` is a reducer and knows nothing about time passing; this is
 * the thing that makes time pass. The split is what lets every timing rule in
 * driving mode be checked against a counter rather than against a screenshot.
 *
 * ## Frames, not timeouts
 *
 * The clock is `requestAnimationFrame` against a monotonic `now()`, never
 * `setTimeout`. A `setTimeout` keeps counting while the machine is asleep and
 * while the renderer is throttled in a background window, so a scan left running
 * as the lid closed would come back having walked the whole fleet with nobody
 * watching. `rAF` simply stops in a hidden window, which is the behaviour that
 * was wanted, and `MAX_TICK_GAP_MS` in the reducer catches the moment it starts
 * again.
 *
 * ## What is not here any more
 *
 * The notification throttle. The old pacing engine ticked at 60 Hz and published
 * at 10, because subscribers were drawing a progress ring whose only job was to
 * creep round — sixty re-renders a second to move it half a degree, next to a
 * terminal repainting a canvas. There is no ring now, and there is nothing else
 * in the panel that changes between stops: at 260 ms a stop, a *shape* change
 * happens about four times a second, and everything else the reducer touches is
 * invisible. So the engine publishes on shape changes only, and the throttle,
 * its constant and its exception list are gone rather than tuned to zero.
 */

import { useSyncExternalStore } from 'react'
import {
  initialScanState,
  scanReducer,
  type PauseReason,
  type ScanEvent,
  type ScanState,
} from '../../../shared/scan'
import {
  watchForInterruption,
  type InterruptionOptions,
  type InterruptionWatch,
} from './interruption'

export interface ScanEngineOptions {
  /** Monotonic milliseconds. `performance.now` in the app, a counter in tests. */
  now(): number
  /** Schedules one frame. Returns a handle `cancelFrame` understands. */
  requestFrame(callback: () => void): number
  cancelFrame(handle: number): void
}

export interface ScanEngine {
  /** The published state — stable between notifications, by design. */
  getState(): ScanState
  /** The live state, for a caller that needs the exact instant. */
  peek(): ScanState
  dispatch(event: ScanEvent): void
  subscribe(listener: () => void): () => void
  /** Stops the frame loop and drops every subscriber. */
  destroy(): void
}

export function createScanEngine(options: ScanEngineOptions): ScanEngine {
  let live = initialScanState()
  let published = live
  let frame: number | null = null
  let destroyed = false
  const listeners = new Set<() => void>()

  /**
   * What a watcher is actually waiting on.
   *
   * `elapsedMs` and `lastTickAt` are deliberately absent — they change every
   * frame and nothing on screen is drawn from them. `seen` is present because it
   * is the trace filling up, which is the one thing in the panel that moves.
   *
   * The published snapshot is deliberately not the live one:
   * `useSyncExternalStore` calls `getSnapshot` during render and re-renders
   * whenever the answer changes, so handing it a value that moves every frame
   * without a matching notification is how a component renders in a loop.
   */
  const shapeChanged = (before: ScanState, after: ScanState): boolean =>
    before.status !== after.status ||
    before.index !== after.index ||
    before.count !== after.count ||
    before.pausedBy !== after.pausedBy ||
    before.arrivals !== after.arrivals ||
    before.seen !== after.seen

  const publish = (): void => {
    published = live
    for (const listener of listeners) listener()
  }

  const commit = (next: ScanState): void => {
    if (next === live) return
    const before = live
    live = next
    if (shapeChanged(before, next)) publish()
  }

  /**
   * Frames are burned only while something is actually counting.
   *
   * A held scan asks for no frames at all — not a loop that wakes up and
   * returns. That matters here more than in most apps: a held scan is a scan
   * sitting over a fleet of sessions each painting a terminal, and the whole
   * point of holding was to give the machine back.
   */
  const wantsFrames = (state: ScanState): boolean =>
    state.status === 'scanning' || state.status === 'travelling'

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
    commit(scanReducer(live, { kind: 'tick', at: options.now() }))
    syncLoop()
  }

  return {
    getState: () => published,
    peek: () => live,
    dispatch(event: ScanEvent) {
      if (destroyed) return
      commit(scanReducer(live, event))
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
 * One line of mapping, kept here rather than at the call site so the decision
 * inside it is written down once: an interruption becomes a `pause`, and there
 * is nothing else it can become. The old engine also had to translate "the
 * surface moved" into a hold on advancing, because a reader mid-scroll must not
 * be moved out from under; a watcher is not mid-anything, so that half is gone.
 */
export function attachInterruption(
  engine: ScanEngine,
  options: Omit<InterruptionOptions, 'onInterrupt'>,
): InterruptionWatch {
  return watchForInterruption({
    ...options,
    onInterrupt: (reason: PauseReason, at: number) => engine.dispatch({ kind: 'pause', reason, at }),
  })
}

/**
 * The engine wired to the real window's clock.
 *
 * Kept apart from `createScanEngine` so every test runs against a counter rather
 * than a wall clock. The engine is real and the clock is injected, not the other
 * way round.
 */
export function browserScanEngine(): ScanEngine {
  return createScanEngine({
    now: () => performance.now(),
    requestFrame: (callback) => requestAnimationFrame(() => callback()),
    cancelFrame: (handle) => cancelAnimationFrame(handle),
  })
}

/** Subscribe a component to an engine. The whole React surface of this module. */
export function useScan(engine: ScanEngine): ScanState {
  return useSyncExternalStore(engine.subscribe, engine.getState, engine.getState)
}
