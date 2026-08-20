/**
 * How much of a bar a cluster of controls is allowed to take, and which of its
 * layouts fits in that.
 *
 * ## The bug this replaces
 *
 * The session controls used to fold below **900px of enclosing `<header>`
 * width**, one number for both of the places they are mounted. Two things were
 * wrong with that, and they pull in opposite directions.
 *
 * The first is that a bar's width is not the cluster's room. The window's
 * toolbar also carries the session's name, its folder, its account, a drag
 * region and the mode switch, and the only one of those that gives way is the
 * name. So a session called `Session 1` and a session called
 * `Update Claude Code terminal to new…` produce the same 1176px bar and
 * radically different amounts of space beside the chips — and at a 756px bar
 * the four expanded chips took their fixed 479px and left the heading **34
 * pixels**, which drew as `S…`. Measured in the running app, both numbers.
 *
 * The second is that a guest pane's bar is a different animal. It is a fraction
 * of the window wide — 568px at an even split of a 1440pt window, and 124px if
 * the divider is dragged over — so a 900px rule folds it *always*, including
 * when a pane is 1000px wide and has room for everything. One threshold cannot
 * describe both bars because the two bars do not carry the same things.
 *
 * ## What is measured instead
 *
 * The room the cluster actually has, computed from the bar it is actually in,
 * per mount. Everything on that bar between the cluster and the bar's own edges
 * is reduced to the width it keeps:
 *
 *  - a **control** never gives way (`flex-shrink: 0` — the mode switch, a
 *    pane's close button), so it keeps what it occupies;
 *  - a **caption** gives way (the heading, the folder, the account), so it
 *    keeps the smaller of what it wants and {@link CAPTION_KEEP_PX}.
 *
 * That second line is the whole of *"the give must come from the controls, not
 * the title"*. The heading is handed its share **before** the cluster is
 * offered anything, so the cluster folds while the title is still whole rather
 * than after the title has been eaten. It is not a CSS `min-width` floor on the
 * heading, which would only have decided that the mode switch goes off the
 * window edge instead — the floor lives here, in the decision about which
 * layout to draw, where paying for it costs a chip rather than a control.
 *
 * ## Why this does not oscillate
 *
 * A fold that measures the space *left over* is a loop: fold, the leftover
 * grows, unfold, the leftover shrinks, fold. Every term above is deliberately
 * independent of how wide the cluster currently is — the bar's own width, its
 * paddings and gaps, the widths of things that cannot shrink, and the content
 * widths of things that can. None of them moves when the cluster folds, so the
 * answer is the same before and after and there is no second step.
 * {@link SETTLE_PX} is there for sub-pixel and font-loading jitter, not for the
 * loop, which is closed by construction.
 */

/** Which arrangement of the cluster is being drawn. */
export type ClusterLayout = 'full' | 'folded'

/**
 * The two answers to "how wide may this cluster be", which are not the same
 * question.
 */
export interface ClusterRoom {
  /**
   * Room while every caption on the bar keeps its protected share.
   *
   * This is what decides the layout. It can be negative, which simply means the
   * bar cannot honour the captions and the cluster both.
   */
  room: number
  /**
   * Room before something that never gives way is pushed off the end of the
   * bar.
   *
   * This is the hard limit, and it is a different number because a caption
   * *will* give way — it just should not have to. Dragging a split divider
   * until a pane is 124px wide leaves about fifty pixels here, and fifty pixels
   * is what the cluster gets: the alternative is drawing over the close button,
   * and closing a pane is the one thing a pane's bar must always be able to do.
   */
  hardRoom: number
}

/** What each of the cluster's arrangements needs, measured from the real chips. */
export interface LayoutNeeds {
  /** Every control on the bar as its own chip. */
  full: number
  /** One summary chip. */
  folded: number
}

/** One thing on the bar that is not the cluster, reduced to what it keeps. */
export interface BarItem {
  /** What it occupies right now. */
  width: number
  /** The widest its own contents would like to be. */
  wants: number
  /**
   * Whether it gives way when the bar runs out of room.
   *
   * A caption does; a control does not. Read from `flex-shrink` rather than
   * from a class name, so a bar that grows a new control does the right thing
   * without this file being told about it.
   */
  givesWay: boolean
  /** The width it will not go below whatever happens — its CSS `min-width`. */
  floor: number
}

/** A bar, as far as this calculation is concerned. */
export interface BarShape {
  /** The bar's content box, with every padding between it and the cluster gone. */
  inner: number
  /** Every gap between the cluster and the bar's edges, added up. */
  gaps: number
  /** Everything on the bar that is not the cluster. */
  items: BarItem[]
}

/**
 * The most a caption is allowed to reserve before the cluster starts paying.
 *
 * A session can be named anything, and without a ceiling one long enough would
 * fold the cluster in a window with a thousand pixels to spare. 320px is about
 * thirty-six characters of the heading face at `--t-title3`, measured in the
 * app — past that a name is not being read at a glance anyway, and the rest of
 * it is in the heading's own tooltip.
 */
export const CAPTION_KEEP_PX = 320

/**
 * The band a measurement has to cross before the layout changes back.
 *
 * Not hysteresis in the usual sense — the room does not move when the cluster
 * folds, so there is no loop to damp. This is for the pixel either side: a
 * web font finishing its load, a device-pixel-ratio change, a rounded value
 * landing on the threshold. Without it a bar parked exactly at the boundary
 * flickers between the two layouts on every unrelated re-render.
 */
export const SETTLE_PX = 8

/**
 * What each item on the bar keeps, and therefore what is left for the cluster.
 *
 * Two passes over the same list. The soft pass gives every caption its
 * protected share, which is the answer the layout is chosen on; the hard pass
 * gives captions nothing at all, which is the answer that says how far the
 * cluster may spread before it starts covering a control.
 */
export function roomFor(bar: BarShape): ClusterRoom {
  let taken = 0
  let fixed = 0
  for (const item of bar.items) {
    if (item.givesWay) {
      taken += Math.max(item.floor, Math.min(item.wants, CAPTION_KEEP_PX))
      fixed += item.floor
    } else {
      taken += item.width
      fixed += item.width
    }
  }
  return {
    room: bar.inner - bar.gaps - taken,
    hardRoom: bar.inner - bar.gaps - fixed,
  }
}

/**
 * Which arrangement to draw.
 *
 * The full row when there is room for the full row, and the folded chip
 * otherwise. `was` is only read to place {@link SETTLE_PX} on the side the
 * layout is currently on, so a bar resting on the threshold stays where it is
 * instead of alternating.
 */
export function chooseLayout(room: ClusterRoom, needs: LayoutNeeds, was: ClusterLayout): ClusterLayout {
  const enough = was === 'full' ? needs.full : needs.full + SETTLE_PX
  return room.room >= enough ? 'full' : 'folded'
}

/**
 * The narrowest the cluster is ever squeezed to before it stops being squeezed.
 *
 * Enough for the caret and a couple of characters — which is what it was always
 * supposed to be, and 56 was not it. Measured in the running app on 2026-08-18
 * at a 720px window, which is this app's own `minWidth` and therefore a size a
 * person can really be at: the cluster was floored here at 56, the reading took
 * 29 of it and the gap took 2, and the controls chip was left with 25 — its own
 * padding and its caret exactly, and not one pixel for a character. It drew a
 * bare chevron with 106 pixels of model and effort behind it, painted fully
 * transparent. Zero of the couple of characters this constant exists to
 * guarantee.
 *
 * 106 is the arithmetic done properly, in the same tier: the reading at its
 * tight width is 35, the gap is 2, and the chip carrying `Opus 5` and its caret
 * is 69 — 31 of chrome around a value measured at 38.2. So the narrowest window
 * this app permits now shows the model, whole, which is what `summaryDetail`
 * calls `model` and what Asad asked for in as many words: *"just Opus 5 with
 * drop down is good enough."*
 *
 * The 50 pixels come from the caption beside it, and that is the right pocket to
 * take them from. A session name is a caption with a tooltip and an ellipsis
 * already in it; the chip is a control, and this constant's own note two
 * functions down says what it is for — *"so that a session named at essay length
 * cannot squeeze the controls out of existence"*. A session named at essay
 * length is exactly what had happened.
 *
 * It cannot cost a control anywhere, because {@link clampWidth} takes the
 * minimum of this and `hardRoom` — the room left before something that never
 * gives way is covered. A 124px guest pane offers about fifty and still gets
 * fifty; raising this changes nothing there.
 */
export const MIN_CLUSTER_PX = 106

/**
 * The width the cluster is allowed to draw at — published as `--sc-room`.
 *
 * Two clamps, and the order between them is the answer to *"who gives way"*.
 *
 * The **first** is {@link ClusterRoom.room}: the cluster may not spread into the
 * share the bar's captions were promised. That is what makes the give come from
 * the controls rather than from the title. Measured at a 760pt window: the
 * folded row wants 357px and the room is 107, so it is held at 107 and the
 * session's name keeps every character it had — instead of the name collapsing
 * to 34 pixels while the chips sat at their natural width, which is what the
 * bar did before.
 *
 * The **second** is {@link ClusterRoom.hardRoom}, and it wins: a caption losing
 * characters is a nuisance, a covered close button is a pane you cannot shut.
 * It only bites where the bar is narrower than its own controls, which a split
 * divider dragged to the window's edge genuinely produces.
 *
 * {@link MIN_CLUSTER_PX} sits between them so that a session named at essay
 * length cannot squeeze the controls out of existence.
 */
export function clampWidth(room: ClusterRoom): number {
  return Math.max(0, Math.min(room.hardRoom, Math.max(room.room, MIN_CLUSTER_PX)))
}

/**
 * What the chosen layout will actually occupy, once the clamp is applied.
 *
 * This is the number a geometry test compares against the bar, and it is the
 * whole guarantee that nothing overlaps: whatever a layout wants, it is never
 * drawn wider than the room that exists.
 */
export function drawnWidth(room: ClusterRoom, needs: LayoutNeeds, layout: ClusterLayout): number {
  const wanted = layout === 'full' ? needs.full : needs.folded
  return Math.min(wanted, clampWidth(room))
}

/* -------------------------------------------------------------------------- *
 * Reading the numbers above off a real bar.
 *
 * Everything below touches the DOM and therefore runs only in the app; the
 * arithmetic it feeds is above, where a test can reach it. That split is
 * deliberate — this project's tests have no layout engine, so a test that
 * asserted on elements would be asserting on nothing, while the numbers these
 * functions produce are exactly the ones a test can be handed.
 * -------------------------------------------------------------------------- */

function px(value: string): number {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

/**
 * The widest an element's contents would like to be.
 *
 * `scrollWidth` alone is not that answer. An element with `overflow: visible`
 * reports its own client width no matter how far its text spills, so the
 * heading — a plain block around a clipped `<h1>` — always claims to want
 * exactly what it was given. What actually knows the true width is whichever
 * descendant does the clipping, so this asks each of them and keeps the widest,
 * offset by where it starts.
 *
 * `text-overflow: ellipsis` counts as clipping for the same reason: it is set
 * on the elements whose whole job is to lose characters, and reading only
 * `overflow` would miss one whose overflow is inherited from a parent.
 */
function contentWidth(el: HTMLElement): number {
  const base = el.getBoundingClientRect()
  let widest = Math.max(el.scrollWidth, base.width)
  for (const child of el.querySelectorAll<HTMLElement>('*')) {
    const style = getComputedStyle(child)
    if (style.overflowX === 'visible' && style.textOverflow !== 'ellipsis') continue
    const box = child.getBoundingClientRect()
    widest = Math.max(widest, box.left - base.left + child.scrollWidth)
  }
  return widest
}

function describe(el: HTMLElement): BarItem {
  const style = getComputedStyle(el)
  const floor = px(style.minWidth)
  /*
   * Which of these is a caption and which is a control, read off the box rather
   * than off a class name — so a bar that grows something this file never heard
   * of is still measured correctly.
   *
   * `flex-shrink` alone is not the test, and getting that wrong is what the
   * first version of this did. The mode switch has never declared a shrink
   * factor, so it reports the default `1` and read as a caption that would
   * happily give way — but its automatic minimum size is its own content, so it
   * does not give way at all, and charging it nothing left the folded chip room
   * it did not have. What actually decides is whether the box has been *allowed*
   * below its content: either an explicit `min-width`, or an overflow that is
   * not `visible`, which is the case the flexbox spec gives an automatic minimum
   * of zero.
   */
  const givesWay =
    px(style.flexShrink) > 0 && (style.minWidth !== 'auto' || style.overflowX !== 'visible')
  /*
   * And a box that *grows* wants nothing.
   *
   * The window bar's drag region is empty and has `flex: 1`, so it is as wide as
   * whatever is left over — which means asking it what it wants gets back the
   * free space it is currently sitting on. That answer moves every time the
   * cluster folds, which is the one thing this calculation may not do, and it
   * is why the fold got stuck: folded, the drag region claimed the 357 pixels
   * the chips had just given up, so there was never room to unfold into.
   */
  return {
    width: el.getBoundingClientRect().width,
    wants: px(style.flexGrow) > 0 ? floor : contentWidth(el),
    givesWay,
    floor,
  }
}

/**
 * Walk from the cluster out to the bar, collecting everything it competes with.
 *
 * Out rather than down, because the two mounts nest differently: on the
 * window's toolbar the cluster shares `.toolbar-actions` with the mode switch
 * and that block shares the bar with the heading and the drag region, while in
 * a pane it sits in a slot beside the close button with the pane's own name and
 * chips before it. Walking the ancestry finds both without this file knowing
 * either shape — which is the same reason the bar itself is found as the
 * nearest `<header>`.
 */
export function measureRoom(cluster: HTMLElement, bar: HTMLElement): ClusterRoom {
  const barStyle = getComputedStyle(bar)
  const shape: BarShape = {
    inner: bar.clientWidth - px(barStyle.paddingLeft) - px(barStyle.paddingRight),
    gaps: 0,
    items: [],
  }
  let node: HTMLElement = cluster
  while (node !== bar && node.parentElement) {
    const parent: HTMLElement = node.parentElement
    const style = getComputedStyle(parent)
    /*
     * Everything at this level that is actually laid out beside the cluster.
     *
     * Two kinds of child are not: one that is `display: none`, and one that has
     * been positioned out of the flow — the toolbar's reveal button is
     * `position: absolute` precisely so that it can sit beside the traffic
     * lights without moving anything. Neither is a flex item, so neither takes
     * width and neither opens a gap.
     */
    const laid = [...parent.children].filter((child): child is HTMLElement => {
      if (!(child instanceof HTMLElement)) return false
      const own = getComputedStyle(child)
      return own.display !== 'none' && own.position !== 'absolute' && own.position !== 'fixed'
    })
    /*
     * Gaps are counted from how many items there are, not from how many are
     * charged for. A collapsed caption is zero pixels wide and still has a gap
     * on each side of it, and forgetting that is worth eight pixels a head — in
     * a 124px pane bar that was the whole of the difference between the close
     * button being on the bar and hanging seven pixels off the end of it.
     */
    shape.gaps += px(style.columnGap) * Math.max(0, laid.length - 1)
    for (const sibling of laid) {
      if (sibling !== node) shape.items.push(describe(sibling))
    }
    if (parent !== bar) {
      shape.inner -= px(style.paddingLeft) + px(style.paddingRight)
    }
    node = parent
  }
  return roomFor(shape)
}

/**
 * What the row of chips currently in the DOM takes when nothing is squeezing it.
 *
 * Measured rather than declared, because the answer moves with its own
 * contents: `Opus 5` and `Opus 5 (1M context)` are not the same chip, and a
 * constant written here would be right on the day it was measured and quietly
 * wrong afterwards. The constants in `SessionControls.tsx` are only what to
 * believe until the first honest measurement lands.
 *
 * Null when the row is being squeezed, which is the one state in which the
 * measurement would lie: every chip clips its own overflow, so a squeezed chip
 * is *narrower* than the thing inside it and adding those widths up would say
 * the row is happy in a space it does not fit. Returning nothing keeps the last
 * good figure instead of replacing it with a smaller false one — which matters
 * because that figure is what decides when to unfold, and an under-measured row
 * would unfold into a bar it overflows.
 */
export function naturalWidth(cluster: HTMLElement): number | null {
  /*
   * Controls *and* readings, since 2026-08-19.
   *
   * `.cc-chip` was the whole row for as long as everything in it was a control.
   * The usage element now puts a context figure on the bar that is deliberately
   * not a chip — it is data first, and it is drawn with none of a chip's border,
   * fill or hover. Counting only chips therefore under-measured the row by the
   * width of that figure, which is the one direction this function must never be
   * wrong in: the note below says why an under-measured row is the one that
   * unfolds into a bar it overflows, and it was doing exactly that at the app's
   * minimum window width.
   *
   * `.cc-reading` is the marker for "on this bar, takes room, is not drawn as a
   * chip". It said "is not pressable" until 2026-08-19, when the figure gained a
   * breakdown panel and had to become a real control to be reachable by keyboard
   * — its *appearance* is what this class is about, and that has not changed. It
   * is a class rather than a component's own name so that this file does not
   * have to know which components exist.
   */
  const chips = [...cluster.querySelectorAll<HTMLElement>('.cc-chip, .cc-reading')]
  if (chips.length === 0) return null
  if (chips.some((chip) => chip.scrollWidth > chip.clientWidth + 1)) return null
  const gap = px(getComputedStyle(cluster).columnGap)
  const sum = chips.reduce((total, chip) => total + chip.getBoundingClientRect().width, 0)
  return sum + gap * (chips.length - 1)
}
