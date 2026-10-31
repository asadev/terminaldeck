import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { AC_MENU_GAP, AC_MENU_MAX, menuSide } from './menu-side'

/**
 * *"see this window is going out of the frame. This one also going out of the
 * frame."* — 2026-08-20, on the session bar.
 *
 * The two panels he pointed at were both `.ac-menu`, both opened by a chip
 * within 300px of the window's right-hand edge, and both anchored `left: 0`.
 * The vertical half of the same problem had been solved months earlier, which
 * is exactly why the horizontal half survived: the components measure
 * themselves on open, so it looked as though placement was handled.
 *
 * Pinned as arithmetic because there is no layout engine in this suite. What
 * that cannot prove is that the stylesheet then does the right thing with the
 * class, so the last test reads the sheet as text — the same trick the strip's
 * width tests use.
 */
describe('which edge a chip’s menu hangs from', () => {
  /** The Model chip on his 1400px window, read off the frame. */
  const NEAR_THE_EDGE = { left: 1218, right: 1284 }
  const MIDDLE = { left: 420, right: 486 }

  it('opens rightwards from a chip with room, which is most of them', () => {
    expect(menuSide(MIDDLE, 1400)).toBe('left')
  })

  it('opens leftwards from a chip near the window’s right edge', () => {
    // 1218 + 304 + 8 = 1530, which is 130px outside a 1400px window — the
    // defect, in the one number that produced it.
    expect(menuSide(NEAR_THE_EDGE, 1400)).toBe('right')
  })

  it('flips exactly at the point the menu would cross the edge, not before', () => {
    /*
     * A menu that flips early is its own defect: it hangs off the wrong edge of
     * a chip that had room, which reads as a positioning bug. So the boundary
     * is asserted from both sides, one pixel apart.
     */
    const width = 1400
    const lastFitting = width - AC_MENU_MAX - AC_MENU_GAP
    expect(menuSide({ left: lastFitting, right: lastFitting + 66 }, width)).toBe('left')
    expect(menuSide({ left: lastFitting + 1, right: lastFitting + 67 }, width)).toBe('right')
  })

  it('overflows to the right rather than the left when neither side fits', () => {
    /*
     * A window narrower than the menu — a pane dragged very small. Something
     * has to be cut off, and it must not be the left-hand side: that is where
     * the tick column and the first characters of every option are. Cut off on
     * the right and the row is still readable and still pressable.
     */
    expect(menuSide({ left: 40, right: 106 }, 240)).toBe('left')
  })

  it('agrees with the width the stylesheet actually caps the menu at', () => {
    // The constant is a copy of a number in the sheet, because the side has to
    // be decided in the same layout pass that first paints the menu and the
    // menu cannot be measured before it exists. A copy that drifts is a menu
    // that flips at the wrong moment, silently.
    const css = readFileSync(join(__dirname, 'AgentControls.css'), 'utf8')
    const menu = /\.ac-menu \{[\s\S]*?\n\}/.exec(css)?.[0] ?? ''
    expect(menu, '.ac-menu has no rule any more').not.toBe('')
    expect(menu).toContain(`max-width: ${AC_MENU_MAX}px;`)
  })

  it('is used by every component that opens one of these panels', () => {
    /*
     * There are three, and the third is the reason this test exists: the
     * Connectors popup in `shell/SessionControls.tsx` reuses `.ac-menu` and was
     * still opening off the right-hand edge of the glass after the two pickers
     * had been fixed. It was found by sweeping every chip on the cluster
     * against the viewport, which is not something a reader of any one of these
     * files would think to do.
     *
     * So the rule is stated where a fourth one would be caught: anything that
     * emits the class has to have asked which side to open on.
     */
    const roots = [
      ['chat/controls/ControlPicker.tsx', join(__dirname, 'ControlPicker.tsx')],
      ['chat/controls/ControlToggle.tsx', join(__dirname, 'ControlToggle.tsx')],
      ['shell/SessionControls.tsx', join(__dirname, '..', '..', 'shell', 'SessionControls.tsx')],
    ] as const
    for (const [name, path] of roots) {
      const source = readFileSync(path, 'utf8')
      expect(source, `${name} does not draw an .ac-menu any more`).toContain('ac-menu')
      expect(source, `${name} opens an .ac-menu without measuring which side it fits`).toContain(
        'menuSide(',
      )
      expect(source, `${name} never applies the flipped class`).toContain('ac-menu-right')
    }
  })

  it('gives the flipped menu a rule that actually moves it', () => {
    /*
     * `left: 0` is on the base rule, so a `right: 0` on its own would leave the
     * panel stretched between both edges — wider than its cap allows and
     * anchored to neither. Both declarations, or the class does nothing.
     */
    const css = readFileSync(join(__dirname, 'AgentControls.css'), 'utf8')
    const flipped = /\.ac-menu-right \{[\s\S]*?\n\}/.exec(css)?.[0] ?? ''
    expect(flipped, 'no .ac-menu-right rule — the class is inert').not.toBe('')
    expect(flipped).toContain('left: auto;')
    expect(flipped).toContain('right: 0;')
  })
})
