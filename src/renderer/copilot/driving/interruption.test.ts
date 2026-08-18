import { describe, expect, it } from 'vitest'
import {
  DRIVE_CONTROL_ATTR,
  INTERRUPTIONS,
  TRANSPORT_KEYS,
  isDriveControlTarget,
  isTransportKey,
  watchForInterruption,
  type EventSource,
  type WatchedEvent,
} from './interruption'
import type { PauseReason } from '../../../shared/scan'

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
      'touchmove',
      'pointerdown',
      'touchstart',
      'keydown',
      'blur',
    ])
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
  it('stops on a scroll, and on a finger still on the glass', () => {
    /*
     * `touchmove` is here rather than in a second "the screen is moving" table,
     * which is where it used to live. That table answered a question the paced
     * read-along had — *may I advance yet?* — and the scan does not: nobody is
     * reading during it. What is left of `touchmove` is the only thing it ever
     * said about a **person**, which is that one of them is dragging the screen.
     */
    const test = harness()
    test.window.fire('wheel')
    test.window.fire('touchmove')
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['scrolled', 'scrolled'])
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
  it('never listens for scroll at all, because it cannot say who caused one', () => {
    /*
     * The distinction this module was built around, and the reason the listener
     * is *gone* rather than filtered. A `scroll` event does not say who caused
     * it: the scan's own travel fires one, a live session appending output
     * fires one, and a trackpad fires one. It was listened for as *movement* —
     * never a pause, only a reason to hold off advancing until the pane settled,
     * which mattered because advancing out from under a reader loses their
     * place.
     *
     * There is no place to lose during a scan. So the event carries nothing
     * anybody acts on, and a listener kept "just in case" on an event that fires
     * every frame of every streaming session is the most expensive kind of dead
     * code there is.
     */
    const test = harness()
    expect(test.window.registered.map((entry) => entry.type)).not.toContain('scroll')
    test.window.fire('scroll')
    expect(test.interruptions).toHaveLength(0)
  })

  it('does not treat the transport’s own keys as somebody typing', () => {
    const test = harness()
    for (const key of TRANSPORT_KEYS) test.window.fire('keydown', { key })
    expect(test.interruptions).toHaveLength(0)

    test.window.fire('keydown', { key: 'ArrowDown' })
    expect(test.interruptions.map((entry) => entry.reason)).toEqual(['typed'])
  })

  it('does not treat a press on the panel’s own controls as an interruption', () => {
    // Pressing → is the one gesture that unambiguously means "I am done with
    // this one". Making it stop everything would be perverse. The same exemption
    // is what lets the panel's chat box be typed into while a scan plays —
    // asking the copilot something is not taking the screen back.
    const test = harness({ isOwnControl: (target) => target === 'next-button' })
    test.window.fire('pointerdown', { target: 'next-button' })
    test.window.fire('wheel', { target: 'next-button' })
    expect(test.interruptions).toHaveLength(0)
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
    const inside = { closest: (selector: string) => (selector.includes(DRIVE_CONTROL_ATTR) ? {} : null) }
    const outside = { closest: () => null }
    expect(isDriveControlTarget(inside)).toBe(true)
    expect(isDriveControlTarget(outside)).toBe(false)
  })

  it('answers no for anything it cannot ask', () => {
    /*
     * The safe answer. The worst case of a false no is a pause the reader did
     * not need; the worst case of a false yes is the tour ignoring a real click,
     * which is the failure this whole module exists to prevent.
     */
    expect(isDriveControlTarget(null)).toBe(false)
    expect(isDriveControlTarget(undefined)).toBe(false)
    expect(isDriveControlTarget('window')).toBe(false)
    expect(isDriveControlTarget({})).toBe(false)
  })
})
