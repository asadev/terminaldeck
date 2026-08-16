import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The claims `shell.css` makes that only the operating system can see.
 *
 * A stylesheet is normally reviewed by looking at it. Two of the things this one
 * now says cannot be looked at from here at all:
 *
 *   1. **`-webkit-app-region`.** It has no visual effect whatsoever — it decides
 *      whether a press on a pixel moves the window or reaches the control under
 *      it. A screenshot of a broken drag region is identical to a screenshot of
 *      a working one, and with the OS title bar now gone on Windows there is no
 *      other handle anywhere on the window: get this wrong and the window cannot
 *      be moved at all, or the mode switch cannot be clicked at all.
 *
 *   2. **The reserve for the window buttons.** Windows draws them over the page
 *      in the top-right of our own bar, and every rule that used to measure from
 *      the macOS traffic lights on the *left* has to have a counterpart that
 *      does not.
 *
 * Neither can be reached from `chrome-render.test.tsx` either, because both live
 * in the stylesheet rather than in the markup. So the sheet is read as text, the
 * way `styles/tokens.test.ts` reads the palette.
 */

const HERE = __dirname
const read = (name: string): string => readFileSync(join(HERE, name), 'utf8')

const SHELL = read('shell.css')
const MODE_SWITCH = read('ModeSwitch.css')
const TOOLBAR_TSX = read('WindowToolbar.tsx')

/**
 * Source with comment bodies removed.
 *
 * Load-bearing here, not tidiness: the prose in this sheet quotes the pixel
 * reserves it is explaining — "82px for the lights, plus the button and its
 * gap" — so the sweep for rules that still measure from the traffic lights
 * would otherwise trip on its own explanation.
 */
const stripComments = (css: string): string => css.replace(/\/\*[\s\S]*?\*\//g, '')

/**
 * The body of one top-level rule.
 *
 * Rules in these sheets start in column zero and close with a `}` in column
 * zero, and none of them nest — so anchoring on the column is what keeps this
 * from matching an indented copy inside a `@media` block, which is a different
 * rule with a different job.
 */
function ruleBody(css: string, selector: string): string | null {
  const opening = `\n${selector} {\n`
  const start = css.indexOf(opening)
  if (start === -1) return null
  const from = start + opening.length
  const end = css.indexOf('\n}', from)
  return css.slice(from, end === -1 ? undefined : end)
}

/** The same, for a rule the test would be meaningless without. */
function requireRule(css: string, selector: string): string {
  const body = ruleBody(css, selector)
  expect(body, `no \`${selector}\` rule — has the shell been rewritten?`).not.toBeNull()
  return body ?? ''
}

/**
 * What a selector says about dragging, or undefined if it says nothing.
 *
 * Undefined for a class with no rule at all as well, which is a real case: a
 * button carries several classes and only one of them is expected to be the one
 * that decides this.
 */
function appRegion(css: string, selector: string): string | undefined {
  return /-webkit-app-region:\s*([\w-]+)/.exec(ruleBody(css, selector) ?? '')?.[1]
}

describe('the bar moves the window, and every control on it does not', () => {
  it('makes the whole toolbar a drag region', () => {
    /*
     * The one that has to be true first. On Windows the OS strip is gone, so
     * this bar is the only place left to grab the window by; on macOS it is
     * what the title bar used to be. A drag region is a rectangle covering
     * every pixel inside it, which is why this single declaration is enough for
     * the heading, the subtitle and the empty space — and why every control
     * below has to subtract itself back out.
     */
    expect(appRegion(SHELL, '.toolbar')).toBe('drag')
  })

  for (const [sheet, selector] of [
    // The two slots `WindowToolbar` renders other people's components into.
    // Opting the slot out rather than each child is what makes it impossible
    // for a caller to add a control that moves the window.
    [SHELL, '.toolbar-actions'],
    [SHELL, '.toolbar-chips'],
    // The reveal button, which is positioned out of the flow inside the lead.
    [SHELL, '.toolbar-btn'],
    // And the control that sits directly beside the OS's close button.
    [MODE_SWITCH, '.mode-switch'],
  ] as const) {
    it(`${selector} opts out of it`, () => {
      expect(
        appRegion(sheet, selector),
        `${selector} sits on a bar that drags the window. Without \`no-drag\` a press on it ` +
          'moves the window instead of doing what the control says it does, and nothing on ' +
          'screen looks any different.',
      ).toBe('no-drag')
    })
  }

  it('leaves the heading draggable, which is where people grab a window', () => {
    // `.toolbar-lead` used to be `no-drag` wholesale. Everything interactive
    // inside it opts out for itself, so all that did was take the drag away
    // from the title text — the one part of a title bar everybody reaches for.
    expect(appRegion(SHELL, '.toolbar-lead')).toBeUndefined()
  })

  it('has a button in the toolbar for every no-drag rule it relies on', () => {
    /*
     * The mechanical half. Anything with an `onClick` inside the header has to
     * land in a region that opts out, and the two ways to get that wrong are to
     * add a button with a new class or to move an existing one out of a slot.
     * Every class this component puts on a `<button>` is checked against the
     * sheet, so a new one fails here rather than on somebody's Windows machine.
     */
    const buttons = [...TOOLBAR_TSX.matchAll(/<button[\s\S]*?className="([^"]+)"/g)].map(
      (match) => match[1].split(/\s+/),
    )
    expect(
      buttons.length,
      'no buttons found in WindowToolbar.tsx — has it changed shape?',
    ).toBeGreaterThan(0)
    // One of a button's classes has to carry the opt-out, not all of them: the
    // reveal button is `toolbar-btn toolbar-reveal`, where the first says what
    // it is and the second only says where it sits.
    const dragging = buttons
      .filter((classes) => !classes.some((name) => appRegion(SHELL, `.${name}`) === 'no-drag'))
      .map((classes) => classes.join(' '))
    expect(dragging, 'these toolbar buttons are inside the drag region').toEqual([])
  })
})

describe('the Windows window buttons get their room', () => {
  it('reserves exactly what was measured, and nothing when there is nothing to reserve', () => {
    // The zero fallback is what keeps every other platform on the padding it
    // had before this existed — the rule resolves to `calc(--sp-3 + 0px)`.
    const toolbar = requireRule(SHELL, '.toolbar')
    expect(toolbar).toContain('padding-right: calc(var(--sp-3) + var(--window-controls-inset, 0px))')
  })

  it('is installed by the toolbar itself', () => {
    // The measurement is published from an effect in this component. Delete it
    // and the custom property is never set, the fallback wins, and the mode
    // switch goes back under the close button.
    expect(TOOLBAR_TSX).toContain('installWindowControls(')
  })

  it('has a counterpart for every rule that reserves room for the traffic lights', () => {
    /*
     * The left-hand half of the same change, and the one that is easy to leave
     * behind: 82px of gutter for the macOS traffic lights, and the 118px that
     * clears them plus the reveal button. On Windows there is nothing on the
     * left at all, so each of those is a hole with a control floating in it.
     *
     * Written as a sweep rather than as three assertions because the failure
     * mode is a *fourth* rule being added later — the sheet already had two
     * places that spell 118px, and the second one was added months after the
     * first.
     */
    const css = stripComments(SHELL)
    const lightsReserve = /\b(82px|118px)\b/
    const offenders: string[] = []
    for (const match of css.matchAll(/^([^\s@}][^\n]*) \{\n([\s\S]*?)\n\}/gm)) {
      const [, selector, body] = match
      if (!lightsReserve.test(body)) continue
      if (selector.startsWith(':root[data-window-controls]')) continue
      if (!css.includes(`:root[data-window-controls] ${selector} {`)) offenders.push(selector)
    }
    expect(
      offenders,
      'these rules hold room for the macOS traffic lights and say nothing about the platform ' +
        'that has no traffic lights. On Windows that is an empty gap at the top-left of the ' +
        'window with a control adrift in the middle of it.',
    ).toEqual([])
    // And the sweep is looking at something: a sheet that stopped spelling the
    // reserve would pass this vacuously.
    expect(lightsReserve.test(css)).toBe(true)
  })
})
