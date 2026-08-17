import { describe, expect, it } from 'vitest'
import {
  INTERRUPTIONS,
  MOVEMENTS,
  PACE_CONTROL_ATTR,
  TRANSPORT_KEYS,
  isPaceControlTarget,
  isTransportKey,
  watchForInterruption,
  type EventSource,
  type WatchedEvent,
} from './interruption'
import type { PauseReason } from './pacer'

/**
 * The interruption watch, exercised without a DOM.
 *
 * This repository has no jsdom, deliberately — `finish.test.ts` and
 * `tokens.test.ts` both say so — and the temptation with a module full of
 * `addEventListener` calls is to leave it untested and check it by clicking
 * around. That would leave the single most load-bearing promise in the whole
 * pacing engine ("touching anything stops it") as the one part with no pinned
 * behaviour, which is exactly backwards.
 *
 * So the watch takes a structural `EventSource` rather than a `Window`, and the
 * fake below is eleven lines. Every claim here is about a listener existing, a
 * listener being registered in the capture phase, or a listener firing the right
 * callback — and all three are things a refactor silently breaks.
 */

/* ------------------------------------------------------------- the fakes -- */

interface Registration {
  type: string
  listener: (event: WatchedEvent) => void
  capture: boolean
  passive: boolean
}

class FakeSource implements EventSource {
  readonly registered: Registration[] = []

  addEventListener(
    type: string,
    listener: (event: WatchedEvent) => void,
    options?: { capture?: boolean; passive?: boolean },
  ): void {
    this.registered.push({
      type,
      listener,
      capture: options?.capture === true,
      passive: options?.passive === true,
    })
  }

  removeEventListener(type: string, listener: (event: WatchedEvent) => void): void {
    const at = this.registered.findIndex(
      (entry) => entry.type === type && entry.listener === listener,
    )
    if (at >= 0) this.registered.splice(at, 1)
  }

  fire(type: string, event: Partial<WatchedEvent> = {}): void {
    for (const entry of [...this.registered]) {
      if (entry.type === type) entry.listener({ type, ...event })
    }
  }
}

interface Harness {
  window: FakeSource
  document: FakeSource
  interruptions: Array<{ reason: PauseReason; at: number }>
  moves: number[]
  hidden: boolean
  stop(): void
}

function harness(
  overrides: {
    isOwnControl?: (target: unknown) => boolean
    hasSelection?: () => boolean
  } = {},
): Harness {
  const win = new FakeSource()
  const doc = new FakeSource()
  const state: Harness = {
    window: win,
    document: doc,
    interruptions: [],
    moves: [],
    hidden: false,
    stop: () => {},
  }
  let clock = 1_000
  const watch = watchForInterruption({
    window: win,
    document: doc,
    now: () => (clock += 1),
    isOwnControl: overrides.isOwnControl ?? (() => false),
    isCommandKey: isTransportKey,
    isHidden: () => state.hidden,
    ...(overrides.hasSelection === undefined ? {} : { hasSelection: overrides.hasSelection }),
    onInterrupt: (reason, at) => state.interruptions.push({ reason, at }),
    onSurfaceMoved: (at) => state.moves.push(at),
  })
  state.stop = watch.stop
  return state
}

/* ------------------------------------------------- two measured defects -- */

/**
 * Both of these were found by driving a real tour on a real window, and both
 * made the whole feature look broken on its first frame: the bar read *"Paused —
 * you selected some text"* and then *"Paused — you left the window"* about a
 * window that was plainly in front, before a single box had been drawn.
 *
 * Neither is visible in a diff and neither would ever fail a typecheck. They are
 * the same shape of mistake twice — an event that is *nearly* the thing you want
 * — and they are pinned separately because the two fixes are unrelated.
 */
describe('an event that is nearly the thing, but is not', () => {
  it('does not read a collapsed selection as somebody selecting text', () => {
    /*
     * `selectionchange` says a selection *changed*, not that a person made one.
     * Moving keyboard focus collapses the document selection and fires it — and
     * the driving panel takes focus the moment it opens, so that Space is the
     * pause key rather than a space typed into whichever pty had the keyboard.
     */
    const rig = harness({ hasSelection: () => false })
    rig.document.fire('selectionchange')
    expect(rig.interruptions).toHaveLength(0)
  })

  it('still pauses for a real selection', () => {
    const rig = harness({ hasSelection: () => true })
    rig.document.fire('selectionchange')
    expect(rig.interruptions[0].reason).toBe('selected')
  })

  it('pauses when it cannot tell, because the cost of a spare pause is one key', () => {
    const rig = harness()
    rig.document.fire('selectionchange')
    expect(rig.interruptions[0].reason).toBe('selected')
  })

  it('does not read an element losing focus as the reader leaving the window', () => {
    /*
     * `blur` does not bubble, which is why every listener here is registered in
     * the capture phase — and capture is what made this wrong: a capture-phase
     * listener on `window` sees the blur of every descendant on its way down. An
     * xterm textarea losing focus is not a person leaving.
     */
    const rig = harness()
    rig.window.fire('blur', { target: { id: 'a textarea' } })
    expect(rig.interruptions).toHaveLength(0)
  })

  it('pauses when the window itself blurs', () => {
    const rig = harness()
    rig.window.fire('blur', { target: rig.window })
    expect(rig.interruptions[0].reason).toBe('left-window')
  })

  it('pauses on a blur with no target, so the watch stays drivable without a DOM', () => {
    const rig = harness()
    rig.window.fire('blur')
    expect(rig.interruptions[0].reason).toBe('left-window')
  })
})

/* -------------------------------------------------------------- the set -- */

describe('the set of things that count as the reader doing something', () => {
  it('is the five that cover every way a person touches this window', () => {
    /*
     * Declared as data and asserted as a set, because a listener quietly dropped
     * in a refactor is invisible in a diff and produces a tour that keeps moving
     * while somebody is reading — the failure Asad named before anything else.
     *
     * `wheel` is the one that would be missed: reading long output means
     * scrolling, and scrolling never involves a click, so `pointerdown` alone
     * would leave the single most common interaction undetected.
     */
    expect(INTERRUPTIONS.map((entry) => entry.type)).toEqual([
      'wheel',
      'pointerdown',
      'touchstart',
      'keydown',
      'blur',
    ])
    expect(MOVEMENTS).toEqual(['scroll', 'touchmove'])
  })

  it('registers every one of them, in the capture phase', () => {
    /*
     * Capture is load-bearing twice over. `scroll` does not bubble, so a
     * bubble-phase listener on the window never hears about a scroll inside a
     * pane at all. And a pause has to land *before* whatever the click was going
     * to do, because the dim is `pointer-events: none` and the click still
     * happens — clicking a session row during a tour switches to that session
     * *and* pauses, which is what "take over" means.
     */
    const test = harness()
    const types = test.window.registered.map((entry) => entry.type)
    for (const { type } of INTERRUPTIONS) expect(types).toContain(type)
    for (const type of MOVEMENTS) expect(types).toContain(type)
    expect(test.window.registered.every((entry) => entry.capture)).toBe(true)
    expect(test.document.registered.every((entry) => entry.capture)).toBe(true)
  })

  it('never blocks the gesture it is listening to', () => {
    // Passive throughout: nothing here calls preventDefault, and a non-passive
    // wheel listener makes the browser wait for this handler before it scrolls.
    // The reader's scroll must happen; the tour only needs to know about it.
    const test = harness()
    expect(test.window.registered.every((entry) => entry.passive)).toBe(true)
  })
})

/* ------------------------------------------------------------- behaviour -- */

describe('a person doing something', () => {
  it('pauses on a scroll, and reports the movement as well', () => {
    /*
     * A wheel event is two facts at once — somebody did something, and the
     * screen is now moving. Reporting only the pause would let the tour advance
     * the moment it resumed, in the middle of a fling.
     */
    const test = harness()
    test.window.fire('wheel')
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['scrolled'])
    expect(test.moves).toHaveLength(1)
  })

  it('pauses on a click, a tap, a key and losing the window', () => {
    const test = harness()
    test.window.fire('pointerdown')
    test.window.fire('touchstart')
    test.window.fire('keydown', { key: 'j' })
    test.window.fire('blur')
    expect(test.interruptions.map((entry) => entry.reason)).toEqual([
      'clicked',
      'clicked',
      'typed',
      'left-window',
    ])
  })

  it('pauses when text is selected', () => {
    // Selecting is reading with a finger on the page, and on a trackpad a
    // shift-click or a double-click's word grab can land here with no pointer
    // event of its own first.
    const test = harness()
    test.document.fire('selectionchange')
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['selected'])
  })

  it('pauses when the window is hidden and does nothing when it comes back', () => {
    /*
     * The event carries no direction, so the state is read at the moment it
     * fires. Becoming visible again must not resume: coming back to a window
     * whose screen is already moving is the worst frame of the whole feature.
     */
    const test = harness()
    test.hidden = true
    test.document.fire('visibilitychange')
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['hidden'])

    test.hidden = false
    test.document.fire('visibilitychange')
    expect(test.interruptions).toHaveLength(1)
  })

  it('stamps every interruption with the clock, not with whenever it was handled', () => {
    const test = harness()
    test.window.fire('pointerdown')
    expect(test.interruptions[0].at).toBeGreaterThan(1_000)
  })
})

describe('the things that are not the reader', () => {
  it('does not pause on a scroll the tour caused', () => {
    /*
     * The split this module exists for. A `scroll` event does not say who caused
     * it: the tour's own travel fires one, a live session appending output fires
     * one, and the reader's trackpad fires one. If `scroll` paused, the tour
     * would pause itself the instant it moved to a stop and would freeze
     * permanently on any session still printing.
     */
    const test = harness()
    test.window.fire('scroll')
    test.window.fire('touchmove')
    expect(test.interruptions).toHaveLength(0)
    expect(test.moves).toHaveLength(2)
  })

  it('does not treat the transport’s own keys as somebody typing', () => {
    const test = harness()
    for (const key of TRANSPORT_KEYS) test.window.fire('keydown', { key })
    expect(test.interruptions).toHaveLength(0)

    test.window.fire('keydown', { key: 'ArrowDown' })
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['typed'])
  })

  it('does not treat a press on the transport as an interruption', () => {
    // Pressing Next is the one gesture that unambiguously means "I have finished
    // with this". Making it pause would be perverse — and it would break both
    // the learned speed and the Skim offer, which need to watch somebody advance
    // early several times while the tour is still running.
    const test = harness({ isOwnControl: (target) => target === 'next-button' })
    test.window.fire('pointerdown', { target: 'next-button' })
    test.window.fire('wheel', { target: 'next-button' })
    expect(test.interruptions).toHaveLength(0)
    expect(test.moves).toHaveLength(0)
  })
})

describe('tearing the watch down', () => {
  it('removes every listener it added', () => {
    /*
     * A watch that outlives its tour pauses a tour that no longer exists, and
     * leaves a capture-phase wheel listener on the window for the rest of the
     * session — on an app whose whole job is running a dozen agents at once.
     */
    const test = harness()
    expect(test.window.registered.length).toBeGreaterThan(0)
    test.stop()
    expect(test.window.registered).toHaveLength(0)
    expect(test.document.registered).toHaveLength(0)

    test.window.fire('pointerdown')
    expect(test.interruptions).toHaveLength(0)
  })

  it('is safe to stop twice', () => {
    const test = harness()
    test.stop()
    expect(() => test.stop()).not.toThrow()
  })

  it('works with no document at all, for a caller that has none', () => {
    const win = new FakeSource()
    const seen: PauseReason[] = []
    watchForInterruption({
      window: win,
      now: () => 0,
      isOwnControl: () => false,
      isCommandKey: isTransportKey,
      onInterrupt: (reason) => seen.push(reason),
      onSurfaceMoved: () => {},
    })
    win.fire('wheel')
    expect(seen).toEqual(['scrolled'])
  })
})

/* -------------------------------------------------------- the own-control -- */

describe('recognising the transport’s own controls', () => {
  it('asks the target’s ancestors, because the click lands on an icon', () => {
    // The question is asked of whatever the event happened to hit — an SVG path
    // inside a button inside the bar — so `closest` is the only cheap way to ask
    // "is this inside our controls" of an arbitrary descendant.
    const inside = { closest: (selector: string) => (selector.includes(PACE_CONTROL_ATTR) ? {} : null) }
    const outside = { closest: () => null }
    expect(isPaceControlTarget(inside)).toBe(true)
    expect(isPaceControlTarget(outside)).toBe(false)
  })

  it('answers no for anything it cannot ask', () => {
    /*
     * The safe answer. The worst case of a false no is a pause the reader did
     * not need; the worst case of a false yes is the tour ignoring a real click,
     * which is the failure this whole module exists to prevent.
     */
    expect(isPaceControlTarget(null)).toBe(false)
    expect(isPaceControlTarget(undefined)).toBe(false)
    expect(isPaceControlTarget('window')).toBe(false)
    expect(isPaceControlTarget({})).toBe(false)
  })
})
