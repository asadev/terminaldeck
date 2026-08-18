import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { placeNote } from './HoverNote'

/**
 * Where the ⓘ's popup lands, and the three ways it used to be able to land
 * somewhere useless.
 *
 * Asad, 2026-08-17: *"the ⓘ dot shows its detail on hover, as a popup — not by
 * expanding the pane downward."* A popup earns that over a disclosure only if it
 * is readable wherever the dot happens to be, and the dots on Settings → Copilot
 * are at the top of the pane, at the bottom of it, and inside a modal dialog
 * that can sit anywhere on screen.
 *
 * The placement is a pure function for exactly that reason: this project has no
 * DOM in its test setup, so a box positioned inside a layout effect could only
 * ever be checked by looking at it — and "looking at it" would mean scrolling to
 * a dot near the window's edge and hoping. Every rule below is a case that
 * produces a half-visible paragraph if it is dropped.
 */

const VIEW = { width: 1280, height: 800 }
const BOX = { width: 360, height: 120 }
const dot = (left: number, top: number) => ({ left, top, width: 16, height: 16 })

describe('where the popup goes', () => {
  it('sits under the dot, centred on it, when there is room', () => {
    const at = placeNote(dot(600, 200), BOX, VIEW)
    expect(at.side).toBe('below')
    // 200 + 16 + 8
    expect(at.top).toBe(224)
    // centred: 600 + 8 − 180
    expect(at.left).toBe(428)
  })

  it('flips above the dot rather than running off the bottom', () => {
    /*
     * The case that matters most, because the pane's own ⓘ dots are on group
     * headings and the last two of them are near the bottom of a scrolled panel.
     * A box that opened downwards there would be a paragraph whose second half
     * is off-screen, under a control that promised to explain something.
     */
    const at = placeNote(dot(600, 760), BOX, VIEW)
    expect(at.side).toBe('above')
    // 760 − 120 − 8
    expect(at.top).toBe(632)
  })

  it('stays below when there is room for it in neither direction', () => {
    // Nothing fits, so it takes the direction that keeps the *first* line on
    // screen: scrolling to the rest of a paragraph is recoverable, a paragraph
    // that begins above the top of the window is not.
    const at = placeNote(dot(600, 300), { width: 360, height: 900 }, VIEW)
    expect(at.side).toBe('below')
    expect(at.top).toBeGreaterThanOrEqual(8)
  })

  it('is pulled back inside the window at both edges', () => {
    expect(placeNote(dot(4, 200), BOX, VIEW).left).toBe(8)
    // 1280 − 360 − 8
    expect(placeNote(dot(1270, 200), BOX, VIEW).left).toBe(912)
  })

  it('keeps the left edge when the window is narrower than the box', () => {
    // A clamp written the other way round pushes the box left until its first
    // word is off-screen, which is worse than an overflowing right edge: the
    // right edge can be read by widening the window, the left cannot be read at
    // all.
    const at = placeNote(dot(100, 200), BOX, { width: 300, height: 800 })
    expect(at.left).toBe(8)
  })
})

describe('what the component deliberately does not do', () => {
  const SOURCE = readFileSync(join(__dirname, 'HoverNote.tsx'), 'utf8')

  it('never sets a `title`, so the app’s tooltip layer does not draw it too', () => {
    /*
     * `shell/Tooltips.tsx` turns every `title` in this renderer into the app's
     * own bubble by delegation. Putting the paragraph there would have been
     * three lines of code and two defects: that bubble is capped at 320px and
     * one line of `--t-subhead`, which is right for "Close (⌘W)" and useless for
     * forty words — and it would fight this popup for the same anchor, so one
     * hover would open two boxes.
     */
    expect(SOURCE).not.toMatch(/\btitle=/)
  })

  it('is reachable without a pointer', () => {
    // Hover alone is a dead control for a touch screen, a trackpad tap and a
    // keyboard. Focus opens it, a click pins it, Escape closes it, and the
    // paragraph is the button's accessible description either way.
    expect(SOURCE).toContain('onFocus')
    expect(SOURCE).toContain('aria-describedby')
    expect(SOURCE).toContain("event.key === 'Escape'")
    expect(SOURCE).toContain('setPinned')
  })

  it('closes on a scroll rather than floating over an unrelated row', () => {
    // It is placed once and does not chase its anchor, so a popup left open
    // through a scroll would be a paragraph hanging over something else. The
    // listener is captured because a scroll inside the settings panel does not
    // bubble to the document.
    expect(SOURCE).toContain("document.addEventListener('scroll', onScroll, true)")
  })
})
