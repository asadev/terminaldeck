import { describe, expect, it } from 'vitest'
import { stopDwellMs, type PacedStop } from './estimate'
import { NOTIFY_MS, attachInterruption, createPaceEngine, type PaceEngine } from './usePacer'
import { isTransportKey, type EventSource, type WatchedEvent } from './interruption'

/**
 * The frame loop, driven by a clock that only these tests move.
 *
 * Nothing here waits. There are no real frames, no `setTimeout`, and no
 * sleeping — a suite that has to wait a second to prove a pause is a suite
 * nobody runs, and this project has a standing rule against manufacturing load
 * to test timing at all.
 *
 * Three claims are worth the file on their own, and none of them can be seen by
 * looking at the screen:
 *
 *  1. **Frames are only burned while something counts.** A paused tour asks for
 *     nothing, which matters because a paused tour is sitting over a fleet of
 *     terminals repainting canvases.
 *  2. **The published snapshot is stable between notifications.** `useSyncExternalStore`
 *     calls `getSnapshot` during render and re-renders when the answer changes;
 *     handing it the live state, which moves every frame, is how a component
 *     ends up rendering in a loop.
 *  3. **Anything a person did is published immediately**, whatever the throttle
 *     says. A pause that shows up 90 ms late is a pause that already lost.
 */

/* ------------------------------------------------------------- the clock -- */

class FakeFrames {
  now = 0
  private queue = new Map<number, () => void>()
  private next = 1

  request = (callback: () => void): number => {
    const handle = this.next
    this.next += 1
    this.queue.set(handle, callback)
    return handle
  }

  cancel = (handle: number): void => {
    this.queue.delete(handle)
  }

  get pending(): number {
    return this.queue.size
  }

  /** Runs whatever frames are queued, advancing the clock by `step` each time. */
  run(frames: number, step = 16): void {
    for (let index = 0; index < frames; index += 1) {
      const entries = [...this.queue.entries()]
      if (entries.length === 0) return
      this.now += step
      this.queue.clear()
      for (const [, callback] of entries) callback()
    }
  }
}

const PROSE =
  'The migration ran twice against the same database, so two of the tables now hold ' +
  'duplicate rows and the session has stopped to ask what you want done about it.'

const STOPS: readonly PacedStop[] = [
  { quote: PROSE, note: 'It is waiting on you.' },
  { quote: PROSE, note: 'And then this happened.' },
]

const DWELL = stopDwellMs(STOPS[0], { pace: 'steady', scale: 1 })

interface Rig {
  frames: FakeFrames
  engine: PaceEngine
  notifications: number
}

function rig(notifyEveryMs = NOTIFY_MS): Rig {
  const frames = new FakeFrames()
  const engine = createPaceEngine({
    now: () => frames.now,
    requestFrame: frames.request,
    cancelFrame: frames.cancel,
    notifyEveryMs,
  })
  const state: Rig = { frames, engine, notifications: 0 }
  engine.subscribe(() => {
    state.notifications += 1
  })
  return state
}

/* --------------------------------------------------------------- frames -- */

describe('when the engine asks for frames', () => {
  it('asks for none at all until a tour starts', () => {
    const test = rig()
    expect(test.frames.pending).toBe(0)
  })

  it('asks for them while a stop is counting down', () => {
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    expect(test.frames.pending).toBe(1)
    test.frames.run(1)
    expect(test.frames.pending).toBe(1)
  })

  it('asks for none while paused', () => {
    /*
     * Not a loop that wakes up and returns — none. A paused tour is a tour
     * sitting over a fleet of sessions each painting a terminal, and the whole
     * point of pausing was to give the reader the machine back.
     */
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    test.engine.dispatch({ kind: 'pause', at: 0, reason: 'scrolled' })
    expect(test.frames.pending).toBe(0)

    test.engine.dispatch({ kind: 'resume', at: 0 })
    expect(test.frames.pending).toBe(1)
  })

  it('asks for none while holding, and none once finished', () => {
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: [{ quote: PROSE.repeat(4), note: '' }] })
    expect(test.engine.peek().status).toBe('holding')
    expect(test.frames.pending).toBe(0)

    test.engine.dispatch({ kind: 'stop', at: 0 })
    expect(test.frames.pending).toBe(0)
  })

  it('drops the frame and every subscriber when it is destroyed', () => {
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    test.engine.destroy()
    expect(test.frames.pending).toBe(0)

    const before = test.notifications
    test.engine.dispatch({ kind: 'next', at: 0 })
    expect(test.notifications).toBe(before)
  })
})

/* ------------------------------------------------------------- publishing -- */

describe('what subscribers are told, and when', () => {
  it('holds a snapshot still between notifications', () => {
    /*
     * The `useSyncExternalStore` contract. `getState` must not move under a
     * component that has not been told anything moved, or React re-renders on
     * every read and never settles.
     */
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    const snapshot = test.engine.getState()
    test.frames.run(3)
    expect(test.engine.getState()).toBe(snapshot)
    expect(test.engine.peek()).not.toBe(snapshot)
  })

  it('does not re-publish a countdown sixty times a second', () => {
    /*
     * The transport sits beside a terminal repainting a canvas. Re-rendering it
     * every frame to move a ring by half a degree is work taken directly from
     * the thing the reader is trying to read.
     */
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    const before = test.notifications
    test.frames.run(5, 16)
    expect(test.notifications).toBe(before)

    test.frames.run(3, 50)
    expect(test.notifications).toBeGreaterThan(before)
  })

  it('publishes anything a person did at once, whatever the throttle says', () => {
    const test = rig(10_000)
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    const before = test.notifications
    test.engine.dispatch({ kind: 'pause', at: 0, reason: 'clicked' })
    expect(test.notifications).toBe(before + 1)
    expect(test.engine.getState().status).toBe('paused')
  })

  it('publishes an automatic advance at once, even mid-throttle', () => {
    // The stop changing is the one thing a reader is actually waiting on, so it
    // never queues behind a throttle interval.
    const test = rig(10_000)
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    const before = test.notifications
    // 100 ms a frame: slow for a frame loop, but well under `MAX_TICK_GAP_MS`,
    // so these are ordinary frames rather than the stall the reducer pauses on.
    test.frames.run(Math.ceil(DWELL / 100) + 2, 100)
    expect(test.engine.getState().index).toBe(1)
    expect(test.notifications).toBeGreaterThan(before)
  })

  it('does not re-publish on every scroll of a session that is still printing', () => {
    /*
     * A real defect before it was fixed. `attachInterruption` dispatches `moved`
     * on every `scroll` event, and a session streaming output scrolls its pane
     * every frame — so force-publishing "anything dispatched" put the cost the
     * throttle exists to avoid straight back in, through the one event that
     * carries no news for the reader at all.
     */
    const test = rig(10_000)
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    const before = test.notifications
    for (let index = 0; index < 60; index += 1) {
      test.engine.dispatch({ kind: 'moved', at: index * 16 })
    }
    expect(test.notifications).toBe(before)
    expect(test.engine.peek().settledAt).toBeGreaterThan(0)
  })

  it('ignores everything after it is destroyed', () => {
    const test = rig()
    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    test.engine.destroy()
    const state = test.engine.getState()
    test.engine.dispatch({ kind: 'next', at: 0 })
    expect(test.engine.getState()).toBe(state)
  })
})

/* ------------------------------------------------------------ integration -- */

describe('the whole loop, from a wheel event to a stopped tour', () => {
  class FakeWindow implements EventSource {
    private readonly listeners: Array<{ type: string; fn: (event: WatchedEvent) => void }> = []

    addEventListener(type: string, fn: (event: WatchedEvent) => void): void {
      this.listeners.push({ type, fn })
    }

    removeEventListener(type: string, fn: (event: WatchedEvent) => void): void {
      const at = this.listeners.findIndex((entry) => entry.type === type && entry.fn === fn)
      if (at >= 0) this.listeners.splice(at, 1)
    }

    get count(): number {
      return this.listeners.length
    }

    fire(type: string, event: Partial<WatchedEvent> = {}): void {
      for (const entry of [...this.listeners]) if (entry.type === type) entry.fn({ type, ...event })
    }
  }

  it('turns a trackpad flick into a paused tour that stays paused', () => {
    const test = rig()
    const win = new FakeWindow()
    const watch = attachInterruption(test.engine, {
      window: win,
      now: () => test.frames.now,
      isOwnControl: () => false,
      isCommandKey: isTransportKey,
    })

    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    test.frames.run(3)
    win.fire('wheel')

    expect(test.engine.getState().status).toBe('paused')
    expect(test.engine.getState().pausedBy).toBe('scrolled')
    expect(test.frames.pending).toBe(0)

    // And it does not creep on afterwards, however long the app is left alone.
    test.frames.now += 10 * 60_000
    expect(test.engine.getState().index).toBe(0)

    watch.stop()
    expect(win.count).toBe(0)
  })

  it('blocks the advance while the pane is still settling, without pausing', () => {
    /*
     * The other half of the split. A scroll the tour caused only stops the
     * advance until things are still; it must never pause, or the tour would
     * pause itself the moment it moved.
     */
    const test = rig()
    const win = new FakeWindow()
    attachInterruption(test.engine, {
      window: win,
      now: () => test.frames.now,
      isOwnControl: () => false,
      isCommandKey: isTransportKey,
    })

    test.engine.dispatch({ kind: 'play', at: 0, stops: STOPS })
    // Run well past the estimate, scrolling the pane every frame the way a live
    // session does while it prints. Frames are 100 ms apart, inside the settle
    // window, so the surface is never still for long enough to advance.
    for (let index = 0; index < Math.ceil(DWELL / 100) + 20; index += 1) {
      test.frames.run(1, 100)
      win.fire('scroll')
    }
    expect(test.engine.getState().status).toBe('playing')
    expect(test.engine.getState().index).toBe(0)

    // Once it stops printing, the advance the reader was owed happens.
    test.frames.run(20, 100)
    expect(test.engine.getState().index).toBe(1)
  })
})
