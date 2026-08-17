import { describe, expect, it } from 'vitest'
import { modeChanges, modeHint, toggleMode, type BrowserMode, type BrowserModes } from './modes'

/**
 * The flow recorder recorded nothing, and this is why.
 *
 * On 2026-08-16 the Flow counter sat at `Flow (1)` — the opening `Go <url>` and
 * nothing after it — across roughly forty clicks in the page, while the in-page
 * RECORDING badge showed the whole time and the panel snapped back to the
 * Element tab on every click. Inspect and Record were both switched on, which
 * the toolbar allowed; the inspector swallows every click by design and the
 * recorder ignores every event while the inspector's overlay exists, also by
 * design. Nothing was broken. Nothing was possible either.
 *
 * These hold the exclusion down. If someone deletes it, the recorder goes back
 * to lying about recording, which is a state no test can see from the outside.
 *
 * Draw was added to the same rule rather than beside it. A canvas over the page
 * parks the native view, so a page in draw mode receives no input at all — a
 * Draw that could be on alongside Record would recreate this exact bug one
 * release after it was fixed.
 */

const MODES: BrowserMode[] = ['inspect', 'record', 'draw']
const OFF: BrowserModes = { inspecting: false, recording: false, drawing: false }

/** Every combination of the three flags — the whole state space, all eight. */
function everyState(): BrowserModes[] {
  const states: BrowserModes[] = []
  for (const inspecting of [false, true]) {
    for (const recording of [false, true]) {
      for (const drawing of [false, true]) states.push({ inspecting, recording, drawing })
    }
  }
  return states
}

function howManyOn(modes: BrowserModes): number {
  return [modes.inspecting, modes.recording, modes.drawing].filter(Boolean).length
}

describe('the page modes are never both on', () => {
  it('turning on Record turns Inspect off', () => {
    expect(toggleMode({ ...OFF, inspecting: true }, 'record')).toEqual({
      inspecting: false,
      recording: true,
      drawing: false,
    })
  })

  it('turning on Inspect turns Record off', () => {
    expect(toggleMode({ ...OFF, recording: true }, 'inspect')).toEqual({
      inspecting: true,
      recording: false,
      drawing: false,
    })
  })

  it('turning on Draw turns off whichever of the other two was on', () => {
    // A drawn-on page is parked behind a canvas: it cannot be clicked, so it
    // cannot be inspected and there is nothing left for the recorder to hear.
    expect(toggleMode({ ...OFF, recording: true }, 'draw')).toEqual({
      inspecting: false,
      recording: false,
      drawing: true,
    })
    expect(toggleMode({ ...OFF, inspecting: true }, 'draw')).toEqual({
      inspecting: false,
      recording: false,
      drawing: true,
    })
  })

  it('turning on Inspect or Record leaves Draw off', () => {
    expect(toggleMode({ ...OFF, drawing: true }, 'record').drawing).toBe(false)
    expect(toggleMode({ ...OFF, drawing: true }, 'inspect').drawing).toBe(false)
  })

  it('cannot reach a state with two on, from any state it can be in', () => {
    // Inductive, and that is the whole claim: start anywhere legal, press
    // anything, and the result is still legal. So a session that starts with
    // everything off — which is how a tab opens — can never arrive at two.
    for (const state of everyState().filter((entry) => howManyOn(entry) <= 1)) {
      for (const mode of MODES) {
        const next = toggleMode(state, mode)
        expect(
          howManyOn(next),
          `${mode} from ${JSON.stringify(state)} left ${JSON.stringify(next)}`,
        ).toBeLessThanOrEqual(1)
      }
    }
  })

  it('never turns a mode on as a side effect of turning one off', () => {
    // The other half of the induction: an *off* leaves the rest untouched, so it
    // cannot add a mode even when handed a state this rule says is impossible.
    for (const state of everyState()) {
      for (const mode of MODES) {
        const next = toggleMode(state, mode)
        expect(howManyOn(next), `${mode} from ${JSON.stringify(state)}`).toBeLessThanOrEqual(
          Math.max(1, howManyOn(state)),
        )
      }
    }
  })

  it('turning one off leaves the others alone', () => {
    // Stop on the recorder must not switch inspection on, and there is no state
    // where that is what anybody meant.
    expect(toggleMode({ ...OFF, recording: true }, 'record')).toEqual(OFF)
    expect(toggleMode({ ...OFF, inspecting: true }, 'inspect')).toEqual(OFF)
    expect(toggleMode({ ...OFF, drawing: true }, 'draw')).toEqual(OFF)
  })
})

describe('modeChanges', () => {
  it('names both sides when one mode displaces the other', () => {
    expect(
      modeChanges({ ...OFF, inspecting: true }, { ...OFF, recording: true }),
    ).toEqual({ inspect: false, record: true })
  })

  it('asks for nothing that has not changed', () => {
    // Each of these is an IPC round trip to a guest page. Turning Record on
    // while nothing was inspecting should not also send a redundant
    // `browserInspect(false)`.
    expect(modeChanges(OFF, { ...OFF, recording: true })).toEqual({ record: true })
  })

  it('reports the draw side, which is the one with no guest to tell', () => {
    expect(modeChanges({ ...OFF, drawing: true }, { ...OFF, inspecting: true })).toEqual({
      inspect: true,
      draw: false,
    })
  })

  it('is empty when nothing moved', () => {
    const state = { ...OFF, inspecting: true }
    expect(modeChanges(state, state)).toEqual({})
  })
})

/**
 * *"Only one instruction strip on screen at a time."*
 *
 * There were two: a line under the toolbar and the bottom panel's "Turn on
 * Inspect, then click something in the page to capture its selector", which told
 * him to do the thing he was already doing. Adding a third mode is a third
 * chance to get that wrong, so the sentence is decided here — once, from the
 * mode state — and the exclusion above is what makes "two at once" unrepresentable.
 */
describe('the instruction strip', () => {
  it('says one thing at most, in every state there is', () => {
    for (const state of everyState()) {
      for (const hasCapture of [false, true]) {
        expect(modeHint(state, { hasCapture }).split('\n')).toHaveLength(1)
      }
    }
  })

  it('is silent when no mode is on', () => {
    expect(modeHint(OFF, { hasCapture: false })).toBe('')
  })

  it('tells you to click while inspecting, and stops once something is captured', () => {
    const inspecting = { ...OFF, inspecting: true }
    expect(modeHint(inspecting, { hasCapture: false })).toContain('Click any element')
    // The popup is the instruction at that point, and the page is about to be
    // replaced by it — so nothing on screen moves when the line goes.
    expect(modeHint(inspecting, { hasCapture: true })).toBe('')
  })

  it('keeps the drawing sentence for the whole of draw mode', () => {
    /*
     * Found by looking, not by reasoning. The line sits above the stage, so
     * taking it away makes the stage taller — and in draw mode the stage is
     * holding a photograph of the page under the pointer. An earlier version
     * dropped this line on the first mark and the frozen page jumped up by a
     * line of text between the first stroke and the second.
     */
    const drawing = { ...OFF, drawing: true }
    expect(modeHint(drawing, { hasCapture: false })).toContain('Drag on the page')
    expect(modeHint(drawing, { hasCapture: true })).toContain('Drag on the page')
  })

  it('says nothing about capturing while drawing, even with a stale capture around', () => {
    // The two would otherwise both be true at once — a capture outlives the
    // inspect mode that made it — and that is the two-strips bug again.
    expect(modeHint({ ...OFF, drawing: true }, { hasCapture: true })).toContain('Drag on the page')
  })
})
