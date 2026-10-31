import { describe, expect, it } from 'vitest'
import {
  CAPTION_KEEP_PX,
  MIN_CLUSTER_PX,
  chooseLayout,
  clampWidth,
  drawnWidth,
  roomFor,
  type BarShape,
  type ClusterLayout,
  type LayoutNeeds,
} from './control-room'

/**
 * The session controls, pinned by geometry.
 *
 * ## What went wrong, and why a class name could not have caught it
 *
 * The cluster folded below **900px of enclosing `<header>` width** — one number
 * for the window's toolbar and for a guest pane's bar both. At a 1020pt window
 * the toolbar is 756px, the four expanded chips took their fixed 479, and the
 * session's heading was left **34 pixels**, which drew as `S…`. In a split, a
 * 740px pane bar sat under the same rule and its chips overprinted each other
 * into `UnLltnkoawn/Ultracode`. Dragging the divider to the window's edge put
 * the pane's close button 69 pixels past the end of its own bar.
 *
 * Every one of those is a *measurement* being wrong, and none of them changes
 * which elements are on screen or what they are called. A test that asserted
 * `data-folded` was present would have passed throughout, because the attribute
 * was doing exactly what it was told — by a rule reading the wrong box. So this
 * file asserts pixels.
 *
 * ## Where the numbers come from
 *
 * The fixtures below are the real `BarShape` the app builds, read out of the
 * running renderer at each width with the same walk `measureRoom` performs, and
 * written down here unchanged. They are not invented, and they are not round.
 */

/** One measured bar, and what the app was actually drawing in it. */
interface Fixture {
  what: string
  shape: BarShape
  /** What the running app chose at this width, for the assertions to agree with. */
  drew: ClusterLayout
}

/**
 * What the row wanted at the moment these were captured.
 *
 * Read off the chips themselves: five of them expanded — usage, model, effort,
 * fast mode, connectors — and two folded, the usage reading and the summary.
 * The app re-measures these continuously (`naturalWidth`) because they move
 * with the values inside them; here they are frozen so the arithmetic can be
 * checked against a fixed board.
 */
const NEEDS: LayoutNeeds = { full: 615, folded: 357 }

const WINDOW_1440: Fixture = {
  what: 'window toolbar, 1440pt window',
  drew: 'full',
  shape: {
    inner: 1148,
    gaps: 20,
    items: [
      // mode switch — a control, so it keeps all 181 of itself
      { width: 181, wants: 181, givesWay: false, floor: 0 },
      // the heading, the folder and the account, together
      { width: 271, wants: 271, givesWay: true, floor: 0 },
      // the drag region, which wants nothing and keeps its 16px minimum
      { width: 61, wants: 16, givesWay: true, floor: 16 },
    ],
  },
}

const WINDOW_1360: Fixture = {
  what: 'window toolbar, 1360pt window',
  drew: 'folded',
  shape: {
    inner: 1068,
    gaps: 20,
    items: [
      { width: 181, wants: 181, givesWay: false, floor: 0 },
      { width: 271, wants: 271, givesWay: true, floor: 0 },
      // The drag region is 239 wide here and 61 at 1440 — it is the box that
      // absorbs whatever the fold gave back, and the reason it cannot be
      // allowed to *want* what it currently has. See the invariance test below.
      { width: 239, wants: 16, givesWay: true, floor: 16 },
    ],
  },
}

const WINDOW_1020: Fixture = {
  what: 'window toolbar, 1020pt window',
  drew: 'folded',
  shape: {
    inner: 728,
    gaps: 20,
    items: [
      { width: 181, wants: 181, givesWay: false, floor: 0 },
      { width: 240, wants: 241, givesWay: true, floor: 0 },
      { width: 16, wants: 16, givesWay: true, floor: 16 },
    ],
  },
}

const WINDOW_720: Fixture = {
  what: "window toolbar, 720pt window — the app's own minimum",
  drew: 'folded',
  shape: {
    inner: 524,
    gaps: 20,
    items: [
      { width: 181, wants: 181, givesWay: false, floor: 0 },
      { width: 240, wants: 241, givesWay: true, floor: 0 },
      { width: 16, wants: 16, givesWay: true, floor: 16 },
    ],
  },
}

const PANE_1012: Fixture = {
  what: 'guest pane bar, divider near the window edge — 1012px of bar',
  drew: 'full',
  shape: {
    inner: 996,
    gaps: 32,
    items: [
      { width: 7, wants: 7, givesWay: false, floor: 0 },
      { width: 69, wants: 69, givesWay: true, floor: 0 },
      { width: 162, wants: 162, givesWay: true, floor: 0 },
      { width: 20, wants: 20, givesWay: false, floor: 0 },
    ],
  },
}

const PANE_568: Fixture = {
  what: 'guest pane bar, even split of a 1440pt window — 568px of bar',
  drew: 'folded',
  shape: {
    inner: 552,
    gaps: 32,
    items: [
      { width: 7, wants: 7, givesWay: false, floor: 0 },
      { width: 69, wants: 69, givesWay: true, floor: 0 },
      { width: 162, wants: 162, givesWay: true, floor: 0 },
      { width: 20, wants: 20, givesWay: false, floor: 0 },
    ],
  },
}

const PANE_124: Fixture = {
  what: 'guest pane bar at its narrowest — 124px of bar',
  drew: 'folded',
  shape: {
    inner: 108,
    gaps: 32,
    items: [
      { width: 7, wants: 7, givesWay: false, floor: 0 },
      { width: 8, wants: 69, givesWay: true, floor: 0 },
      { width: 0, wants: 76, givesWay: true, floor: 0 },
      { width: 20, wants: 20, givesWay: false, floor: 0 },
    ],
  },
}

const EVERY: Fixture[] = [
  WINDOW_1440,
  WINDOW_1360,
  WINDOW_1020,
  WINDOW_720,
  PANE_1012,
  PANE_568,
  PANE_124,
]

/** The width the cluster ends up occupying, given what the app chose to draw. */
function drawn(fixture: Fixture): number {
  return drawnWidth(roomFor(fixture.shape), NEEDS, fixture.drew)
}

/** What is left for the bar's captions once the cluster has taken its width. */
function captionRoom(fixture: Fixture, clusterWidth: number): number {
  const kept = fixture.shape.items.reduce(
    (total, item) => total + (item.givesWay ? item.floor : item.width),
    0,
  )
  return fixture.shape.inner - fixture.shape.gaps - kept - clusterWidth
}

describe('nothing on the bar is ever drawn over', () => {
  it.each(EVERY)('$what', (fixture) => {
    /*
     * The invariant, stated as arithmetic: what the cluster draws, plus every
     * control that will not give way, plus the gaps between them, fits inside
     * the bar. If this holds there is nowhere for an overlap to come from —
     * which is the whole of what the screenshots were showing.
     */
    const width = drawn(fixture)
    const controls = fixture.shape.items
      .filter((item) => !item.givesWay)
      .reduce((total, item) => total + item.width, 0)
    expect(width + controls + fixture.shape.gaps).toBeLessThanOrEqual(fixture.shape.inner)
  })

  it('leaves a guest pane its close button at the narrowest the divider goes', () => {
    /*
     * Measured before this arithmetic existed: at a 124px pane bar the folded
     * chip kept its natural 118px, and the close button's right edge landed at
     * x=1501 against a bar ending at x=1432 — sixty-nine pixels outside, clipped
     * away by the pane, unclickable. Closing a pane is the one thing a pane's
     * bar must always be able to do.
     */
    const width = drawn(PANE_124)
    const dot = 7
    const close = 20
    expect(width + dot + close + PANE_124.shape.gaps).toBeLessThanOrEqual(PANE_124.shape.inner)
    expect(width).toBeGreaterThan(0)
  })
})

describe('one threshold cannot serve both bars', () => {
  it('draws the full row in a 1012px pane and folds it in a 1096px toolbar', () => {
    /*
     * This is the old rule's obituary, and it needs no history to read: here is
     * a **narrower** bar that fits the whole row and a **wider** one that does
     * not. No single number compared against a bar's width can produce both
     * answers, because the two bars carry different things — the toolbar spends
     * 181px on the mode switch and 271 on the window's heading, the pane spends
     * 20 on a close button and 231 on a name, a folder and a login.
     */
    expect(PANE_1012.shape.inner).toBeLessThan(WINDOW_1360.shape.inner)
    expect(chooseLayout(roomFor(PANE_1012.shape), NEEDS, 'folded')).toBe('full')
    expect(chooseLayout(roomFor(WINDOW_1360.shape), NEEDS, 'full')).toBe('folded')
  })

  it.each(EVERY)('agrees with what the app drew in $what', (fixture) => {
    expect(chooseLayout(roomFor(fixture.shape), NEEDS, fixture.drew)).toBe(fixture.drew)
  })

  it('cannot be reproduced by any threshold on the bar’s own width', () => {
    /*
     * The proof, rather than the anecdote. Every threshold from nothing to
     * wider than any bar in the set is tried, and none of them sorts these
     * seven bars the way they have to be sorted. Restoring a `FOLD_BELOW_PX`
     * of any value whatsoever fails this.
     */
    const bars = EVERY.map((fixture) => ({ width: fixture.shape.inner, want: fixture.drew }))
    for (let threshold = 0; threshold <= 1400; threshold += 1) {
      const sorts = bars.every((bar) => (bar.width >= threshold ? 'full' : 'folded') === bar.want)
      expect(sorts, `a threshold of ${threshold}px`).toBe(false)
    }
  })
})

describe('the give comes from the controls, not the title', () => {
  it('keeps the 1020pt window a readable heading where the old rule left 34px', () => {
    /*
     * The number this replaces, measured in the running app: at 1020pt the bar
     * is 756px, the expanded row took its fixed 479, and the heading was handed
     * **34 pixels** — one glyph and an ellipsis. Folding is what buys the
     * heading back, and the fold happens here because the room is measured
     * *after* the heading has been promised its share.
     */
    const folded = captionRoom(WINDOW_1020, drawn(WINDOW_1020))
    expect(folded).toBeGreaterThanOrEqual(240)

    const unfolded = captionRoom(WINDOW_1020, 479)
    expect(unfolded).toBeLessThan(40)
  })

  it.each(EVERY)('never spends a caption’s promised share on chips: $what', (fixture) => {
    /*
     * Every caption is owed the smaller of what it wants and CAPTION_KEEP_PX,
     * over and above the floor it would have had anyway, and the cluster may
     * not be drawn into that. The cap is what stops a session named at essay
     * length from folding a bar with room to spare.
     *
     * The exception is a bar that cannot honour its captions at all, which is
     * the 124px pane below: there the promise is unpayable and MIN_CLUSTER_PX
     * decides instead. It is an exception with a size — the cluster takes the
     * minimum and not a pixel more — rather than an escape hatch.
     */
    const room = roomFor(fixture.shape)
    const promised = fixture.shape.items
      .filter((item) => item.givesWay)
      .reduce((total, item) => total + Math.min(item.wants, CAPTION_KEEP_PX) - item.floor, 0)
    if (room.room >= MIN_CLUSTER_PX) {
      expect(captionRoom(fixture, drawn(fixture))).toBeGreaterThanOrEqual(promised)
    } else {
      expect(drawn(fixture)).toBeLessThanOrEqual(MIN_CLUSTER_PX)
    }
  })

  it('still leaves a control on a bar whose captions want more than it has', () => {
    // The 124px pane: its name and chips want 145 between them and the bar has
    // 108. The captions cannot all be honoured, and the answer is not to remove
    // the only way in to the session's controls.
    expect(roomFor(PANE_124.shape).room).toBeLessThan(0)
    expect(clampWidth(roomFor(PANE_124.shape))).toBeGreaterThan(0)
    expect(clampWidth(roomFor(WINDOW_720.shape))).toBeGreaterThanOrEqual(MIN_CLUSTER_PX)
  })
})

describe('the fold does not move the ground it is standing on', () => {
  it('gives the same room whether the row is folded or not', () => {
    /*
     * The failure this guards is a loop rather than a wrong number: measure the
     * space *left over*, fold into it, and the leftover grows — so the next
     * measurement unfolds, and the one after that folds again.
     *
     * The two fixtures below are the same toolbar sixty pixels apart, and the
     * only item that differs between them is the drag region: 61px wide with
     * the row expanded, 239px with it folded, because the drag region is what
     * the freed space flows into. Both report the same `wants`, so the room
     * does not swing with the fold — which is what makes watching the cluster's
     * own size safe.
     */
    const expanded = WINDOW_1440.shape.items[2]
    const collapsed = WINDOW_1360.shape.items[2]
    expect(expanded.width).not.toBe(collapsed.width)
    expect(expanded.wants).toBe(collapsed.wants)

    const asFolded: BarShape = {
      ...WINDOW_1440.shape,
      items: WINDOW_1440.shape.items.map((item, index) => (index === 2 ? { ...item, width: 239 } : item)),
    }
    expect(roomFor(asFolded)).toEqual(roomFor(WINDOW_1440.shape))
  })

  it('does not flip back and forth across its own threshold', () => {
    // A bar resting exactly on the boundary answers the same thing twice.
    const onTheLine: BarShape = {
      inner: NEEDS.full + 200,
      gaps: 20,
      items: [{ width: 180, wants: 180, givesWay: false, floor: 0 }],
    }
    const first = chooseLayout(roomFor(onTheLine), NEEDS, 'folded')
    expect(chooseLayout(roomFor(onTheLine), NEEDS, first)).toBe(first)
  })
})

describe('the clamp is the last word', () => {
  it.each(EVERY)('never exceeds the room that exists: $what', (fixture) => {
    const room = roomFor(fixture.shape)
    expect(clampWidth(room)).toBeLessThanOrEqual(room.hardRoom)
    expect(drawnWidth(room, NEEDS, 'full')).toBeLessThanOrEqual(clampWidth(room))
    expect(drawnWidth(room, NEEDS, 'folded')).toBeLessThanOrEqual(clampWidth(room))
  })

  it('hands the full row its whole width whenever the full row was chosen', () => {
    // If a layout is chosen it must not then be squeezed: `room` is the softer
    // of the two limits, so a chosen `full` always fits inside the clamp.
    for (const fixture of EVERY) {
      const room = roomFor(fixture.shape)
      if (chooseLayout(room, NEEDS, 'folded') !== 'full') continue
      expect(drawnWidth(room, NEEDS, 'full'), fixture.what).toBe(NEEDS.full)
    }
  })
})
