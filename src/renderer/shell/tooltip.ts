/**
 * The tooltip layer's decisions, with no DOM of its own.
 *
 * ## Why the app has a tooltip layer at all
 *
 * Every hover label in this window was a native `title=`, and a native tooltip
 * is the one piece of chrome the design brief cannot reach. It is drawn by the
 * OS: it ignores the theme, ignores the type scale, ignores the accent, appears
 * after a delay nobody chose, and on a dark window arrives as a pale yellow box
 * in a font this app does not use. "Apple in the chrome" is not a thing you can
 * ask a native tooltip for.
 *
 * ## Why replacing it is riskier than it looks
 *
 * Suppressing the native tooltip means removing the `title` attribute while the
 * pointer is over the element — there is no other way; a browser has no "do not
 * show the tooltip" switch. And `title` is not only a tooltip. It is a fallback
 * *accessible name*: for an icon-only button with no text and no `aria-label`,
 * `title` is the only thing a screen reader has to say. Strip it blindly and
 * the button becomes "button".
 *
 * So the strip is conditional, and that condition is what most of this file is.
 * An element that already has a name of its own — `aria-label`, an
 * `aria-labelledby`, an `alt`, or visible text — loses nothing when `title`
 * goes, because the accessible-name algorithm was never using `title` for it in
 * the first place. An element with none of those is *named* by its `title`, and
 * for the time the attribute is away it is handed the identical string as an
 * `aria-label`, which is taken back when the title returns. The name a screen
 * reader computes is the same string throughout, in both cases.
 *
 * ## No DOM in the tests
 *
 * This project has no jsdom (deliberately — see `dialog-render.test.tsx`), so
 * everything here is either arithmetic on plain rectangles or works through
 * {@link Tipped}, a hand-written slice of `Element` that a real `HTMLElement`
 * satisfies and a nine-line test fake also satisfies. The layer in
 * `Tooltips.tsx` is then thin enough to read in one sitting.
 */

import { MODIFIER_LABELS } from '../keymap'

/**
 * The slice of an element this module reads and writes.
 *
 * A real `HTMLElement` satisfies it without an adapter, which is the point: the
 * production call sites pass elements straight in, so the fake in the tests is
 * standing in for the same surface the app uses rather than for a wrapper.
 */
export interface Tipped {
  getAttribute(name: string): string | null
  setAttribute(name: string, value: string): void
  removeAttribute(name: string): void
  readonly textContent: string | null
  /**
   * Element children, walked to find out how much of `textContent` an
   * accessible name would actually count. See {@link hasContentName} — this
   * field exists because the first version of that decision was wrong in the
   * app, not in theory.
   *
   * Recursive on purpose: a child is a `Tipped` too, and a real `Element`
   * satisfies the whole shape including its `HTMLCollection`.
   */
  readonly children: ArrayLike<Tipped>
}

/** Whitespace removed, so two strings can be compared for the same *characters*. */
const squeeze = (text: string): string => text.replace(/\s+/g, '')

/**
 * Text inside `el` that the accessible-name algorithm throws away.
 *
 * Recursion stops at an `aria-hidden` element: everything under it is hidden
 * too, and continuing would count a nested one twice — which subtracts more
 * than is there and makes a control with real text look empty.
 */
function hiddenText(el: Tipped): string {
  if (el.getAttribute('aria-hidden') === 'true') return el.textContent ?? ''
  let out = ''
  const kids = el.children
  for (let i = 0; i < kids.length; i++) {
    const kid: Tipped | undefined = kids[i]
    if (kid !== undefined) out += hiddenText(kid)
  }
  return out
}

/**
 * Does this element's own content give it a name — any name at all?
 *
 * A question, not a string, because the answer is only ever used as a yes/no
 * and reconstructing the *exact* name from content would mean reimplementing a
 * spec (text nodes, `::before`, nested labels) to no benefit.
 *
 * Not `textContent`, and that distinction is the whole reason this exists.
 * `textContent` was the first version of it and it was wrong in the app rather
 * than in theory: the icon buttons in this window are
 *
 *     <button title="Reload MCP servers"><span aria-hidden="true">↻</span></button>
 *
 * and `textContent` answers `"↻"` — non-empty, so the layer concluded the
 * button had a name of its own, stripped `title` and lent it nothing. Chromium
 * disagrees, correctly: `aria-hidden` content is excluded from the name, so the
 * real accessible name fell to the empty string for as long as the pointer
 * rested on it. Caught by rendering the app, planting that exact button and
 * asking the browser over CDP what it computed, which is the only source that
 * answers the question actually being asked.
 *
 * So: is any of the text *not* hidden. Compared with whitespace squeezed out,
 * because the newlines JSX leaves between tags belong to the button and not to
 * the glyph, and `"\n  ↻\n" !== "↻"` would put the bug straight back.
 */
export function hasContentName(el: Tipped): boolean {
  const all = el.textContent ?? ''
  if (all.trim() === '') return false
  return squeeze(all) !== squeeze(hiddenText(el))
}

/**
 * Would this tooltip tell the reader anything the control is not already
 * saying?
 *
 * Six rows of the sidebar answered no. Hovering "Alerts" popped a bubble
 * reading exactly "Alerts", over the top of the "Machines" row underneath it —
 * so the hover cost the reader the row they were about to click and gave them a
 * word they had just read. Every view without a keyboard chord was in that
 * state, because the title was `panel.command ? tip(label, command) : label`
 * and the second branch is the label itself.
 *
 * The comparison ignores whitespace, for the reason {@link hasContentName}
 * gives, and ignores `aria-hidden` content, so a button whose visible text is a
 * glyph plus a word is judged on the word.
 *
 * `clipped` is the exception that keeps this honest: a label cut off by an
 * ellipsis is *not* already on screen, and the tooltip is the only way to read
 * it. Measuring that needs a live layout, so the layer passes the answer in
 * rather than this file reaching for a DOM it deliberately does not have.
 */
export function saysSomethingNew(title: string, el: Tipped, clipped: boolean): boolean {
  if (clipped) return true
  const all = el.textContent ?? ''
  const visible = squeeze(all).replace(squeeze(hiddenText(el)), '')
  if (visible === '') return true
  return squeeze(title) !== visible
}

/**
 * A title taken off an element, and what has to be undone to give it back.
 *
 * `aria` is the half that is easy to lose: when this module supplies the
 * accessible name it must also take it away again, or a `title` that later
 * changes would be shadowed forever by a stale `aria-label` nobody can see in
 * the source.
 */
export interface HeldTitle {
  readonly text: string
  /** True when this module added the `aria-label` and owes the element its removal. */
  readonly aria: boolean
}

/**
 * Does this element have an accessible name that does not come from `title`?
 *
 * The accessible-name algorithm consults `aria-labelledby`, then `aria-label`,
 * then the element's own content (or `alt`, for an image), and only then falls
 * back to `title`. So the question "is it safe to remove the title" is exactly
 * "does one of the earlier sources answer".
 *
 * Blank is not an answer: `aria-label=""` and a button holding nothing but an
 * `aria-hidden` glyph both compute to the empty name, which is the icon-only
 * case wearing a disguise. The second of those is what {@link hasContentName}
 * is for, and it is not a hypothetical — see the note there.
 */
export function hasOwnAccessibleName(el: Tipped): boolean {
  const labelledBy = el.getAttribute('aria-labelledby')
  if (labelledBy !== null && labelledBy.trim() !== '') return true
  const label = el.getAttribute('aria-label')
  if (label !== null && label.trim() !== '') return true
  const alt = el.getAttribute('alt')
  if (alt !== null && alt.trim() !== '') return true
  return hasContentName(el)
}

/**
 * Take the `title` off an element so the OS cannot draw its own tooltip, and
 * hand back what is needed to put it exactly as it was.
 *
 * Answers `null` for an element with no title, or with a blank one — a blank
 * title is not a tooltip, and showing an empty bubble for it would be a hover
 * state that promises nothing.
 */
export function holdTitle(el: Tipped): HeldTitle | null {
  const text = el.getAttribute('title')
  if (text === null || text.trim() === '') return null

  // Read *before* the attribute is removed. `textContent` does not depend on it,
  // but `hasOwnAccessibleName` is the decision about a state that is about to
  // stop existing, and asking after the fact is how this kind of code acquires
  // an ordering bug that only shows up for one element in the app.
  const aria = !hasOwnAccessibleName(el)
  el.removeAttribute('title')
  if (aria) el.setAttribute('aria-label', text)
  return { text, aria }
}

/**
 * Put the title back, and undo the borrowed name.
 *
 * Called from the layer's cleanup as well as from its hide path, because React
 * will not do it: the element's `title` prop has not changed between renders,
 * so React's diff sees nothing to write and the attribute stays gone until this
 * runs. An unmounted element is a no-op that costs two attribute writes.
 */
export function releaseTitle(el: Tipped, held: HeldTitle): void {
  el.setAttribute('title', held.text)
  if (held.aria) el.removeAttribute('aria-label')
}

/**
 * At most one element in the window has its title taken, and this owns which.
 *
 * The bubble and the strip are *not* the same lifetime, and conflating them was
 * a real leak. Clicking a button hides the bubble — it should; you have already
 * acted — but if the title went back at the same moment, resting the pointer on
 * the button you just pressed would summon the OS's own tooltip a second later,
 * which is the exact thing this layer exists to prevent. So the title stays
 * taken for as long as the pointer is on the control, and the bubble comes and
 * goes inside that.
 *
 * A closure rather than a bare pair of refs because there is one invariant here
 * worth being able to test on its own: whatever happens, the element that was
 * grabbed gets its attributes back. Grabbing a second element releases the
 * first; releasing twice is a no-op; releasing something never grabbed is a
 * no-op. `tooltip.test.ts` drives those directly.
 */
export interface TitleHold<T extends Tipped> {
  /** The element whose title is currently taken, or null. */
  element(): T | null
  /** The taken text, or null. */
  text(): string | null
  /** Take this element's title, releasing any previous one. False if it has none. */
  grab(el: T): boolean
  /** Give it back. Safe to call at any time, any number of times. */
  release(): void
}

export function titleHold<T extends Tipped>(): TitleHold<T> {
  let current: { el: T; held: HeldTitle } | null = null

  const release = (): void => {
    if (current === null) return
    releaseTitle(current.el, current.held)
    current = null
  }

  return {
    element: () => current?.el ?? null,
    text: () => current?.held.text ?? null,
    release,
    grab: (el) => {
      release()
      const held = holdTitle(el)
      if (held === null) return false
      current = { el, held }
      return true
    },
  }
}

/**
 * A tooltip's text, split into the label and the keyboard chord `tip()` appends.
 *
 * `tip('New session', 'session.new')` produces `New session (⌘T)`, and a native
 * tooltip can only render that as one grey sentence. Split, the chord can be set
 * the way Apple sets one — dimmer, off to the side — so the eye reads the label
 * first and the shortcut second.
 *
 * The shape is checked rather than assumed, because plenty of titles here are
 * not commands: `title={project.path}` is a path, and a folder genuinely called
 * `renderer (old)` must not have its last word demoted to a keycap. Two things
 * have to be true. The tail holds no whitespace — `formatChord` never emits any,
 * so `(Shift the grid)` is prose — and it holds a modifier, asked of
 * `MODIFIER_LABELS` rather than of a hand-written list, because a ⌘ written in
 * this file would be a ⌘ printed on Windows.
 */
const CHORD_TAIL = /\s+\(([^()\s]{1,16})\)$/

export function splitChord(text: string): { label: string; chord: string | null } {
  const match = CHORD_TAIL.exec(text)
  if (match === null) return { label: text, chord: null }
  const tail = match[1]
  if (!MODIFIER_LABELS.some((modifier) => tail.includes(modifier))) return { label: text, chord: null }
  return { label: text.slice(0, match.index), chord: tail }
}

/**
 * Is this label a bare filesystem path?
 *
 * "Terminal in the content, Apple in the chrome" applies inside a tooltip too:
 * `/Users/apple/Projects/terminaldeck` is *data*, the characters are exact and
 * countable, and it belongs in mono. `Close this pane` is chrome and does not.
 * A tooltip that mixed the two rules within one line would look like a bug, so
 * the test is all-or-nothing — the whole label is a path, or none of it is.
 *
 * Deliberately narrow. A sentence that merely mentions a path (`/etc — not
 * offered`) contains a space and stays in the UI face, which is the right
 * answer: it is a sentence.
 */
export function pathLike(label: string): boolean {
  if (label.length < 2 || /\s/.test(label)) return false
  return label.startsWith('/') || label.startsWith('~/') || /^[A-Za-z]:[\\/]/.test(label)
}

/** A box in viewport coordinates. `DOMRect` satisfies it. */
export interface Rect {
  readonly left: number
  readonly top: number
  readonly width: number
  readonly height: number
}

/** How big something is. */
export interface Size {
  readonly width: number
  readonly height: number
}

/** Where the bubble goes, and which way its shape points. */
export interface Placed {
  readonly left: number
  readonly top: number
  readonly side: 'above' | 'below'
}

/** Between the bubble and its anchor. */
const GAP = 6
/** Between the bubble and the window's edges. Never smaller than this. */
const EDGE = 8

/** Do two boxes share any area? Touching edges do not count. */
function boxesMeet(a: Rect, b: Rect): boolean {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return false
  return (
    a.left < b.left + b.width &&
    b.left < a.left + a.width &&
    a.top < b.top + b.height &&
    b.top < a.top + a.height
  )
}

/**
 * Where to put the bubble, in viewport coordinates.
 *
 * Below the anchor by default, which is where a pointer is not: a tooltip above
 * the thing you are pointing at is a tooltip under your cursor half the time.
 * It flips above only when there is genuinely no room below *and* more room
 * above — flipping on a window one pixel too short reads as a glitch, and a
 * bubble that is slightly tight at the bottom does not.
 *
 * ## `blind`, and why a tooltip has to know about it
 *
 * Rectangles the renderer's own pixels cannot be seen in. There is exactly one
 * kind in this app and it is not a style problem: a browser page is a
 * `WebContentsView`, a **native child view of the window**, composited above the
 * entire renderer. No `z-index`, no portal and no stacking context puts HTML on
 * top of one — `browser/overlay-watch.ts` is the essay, and it has been
 * rediscovered twice.
 *
 * Measured in the built app on 2026-08-17: the browser toolbar's buttons end
 * 9px above the page and a bubble needs 24, so hovering Cookies put 21 of the
 * bubble's 24 pixels under the page and left a 3px sliver. The module that
 * decides whether to hide the page cannot fix that — hiding a 587×644 website
 * to reveal a hint is the bug it was just stopped from doing — so the fix is
 * here, where the bubble is put somewhere it can be read. It is the same flip
 * this function already does at the bottom of the window, for the same reason:
 * there is no room on that side.
 *
 * The flip only happens when the other side is genuinely clear. A bubble with
 * nowhere good to go keeps the placement it would have had, because moving it
 * somewhere equally invisible would only make it harder to explain.
 *
 * Coordinates are rounded because this is text on glass: a bubble at 41.5px
 * renders every glyph across a half-pixel boundary, which on a non-Retina
 * display is visible as a blurred line and on Retina is visible as a
 * blurred line half the time.
 */
export function placeTip(
  anchor: Rect,
  tip: Size,
  view: Size,
  blind: readonly Rect[] = [],
): Placed {
  const below = anchor.top + anchor.height + GAP
  const above = anchor.top - GAP - tip.height
  const roomBelow = view.height - (below + tip.height) - EDGE
  const roomAbove = above - EDGE

  const centred = anchor.left + anchor.width / 2 - tip.width / 2
  const rightmost = view.width - tip.width - EDGE
  // `Math.max(EDGE, rightmost)` rather than `rightmost`: a bubble wider than
  // the window would otherwise be clamped to a negative left and lose its
  // start, which is the half of a long path you actually need.
  const left = Math.min(Math.max(centred, EDGE), Math.max(EDGE, rightmost))

  // Clamped even on the side that was chosen for having the room: a viewport
  // shorter than the bubble has no good answer, and hanging off the top edge is
  // the one answer that loses the first line of text.
  const clamp = (wanted: number): number =>
    Math.min(Math.max(wanted, EDGE), Math.max(EDGE, view.height - tip.height - EDGE))

  let side: Placed['side'] = roomBelow < 0 && roomAbove > roomBelow ? 'above' : 'below'

  if (blind.length > 0) {
    // Judged on the placement that would actually be used, clamp included — an
    // unclamped `above` can be off the top of the window, and asking whether a
    // box nobody will ever see lands on a page is how this would answer the
    // wrong question in the one case it exists for.
    const boxOn = (at: Placed['side']): Rect => ({
      left,
      top: clamp(at === 'below' ? below : above),
      width: tip.width,
      height: tip.height,
    })
    const covered = (at: Placed['side']): boolean =>
      blind.some((region) => boxesMeet(boxOn(at), region))
    const other: Placed['side'] = side === 'below' ? 'above' : 'below'
    if (covered(side) && !covered(other)) side = other
  }

  const top = clamp(side === 'below' ? below : above)

  return { left: Math.round(left), top: Math.round(top), side }
}

/**
 * How long the pointer must rest before a tooltip appears, and how long after
 * one closes that the next appears instantly.
 *
 * Both numbers are the behaviour of a macOS menu bar rather than a taste call:
 * the first hover waits, and once you are reading labels, moving along a row of
 * controls shows each one immediately. Without the warm window a toolbar becomes
 * a series of half-second waits; with it, sweeping the pointer across the window
 * on the way to somewhere else still shows nothing.
 */
export const OPEN_DELAY_MS = 450
export const WARM_MS = 600

/** Whether a tooltip opening now should skip the delay. */
export function isWarm(closedAt: number | null, now: number): boolean {
  return closedAt !== null && now - closedAt < WARM_MS
}
