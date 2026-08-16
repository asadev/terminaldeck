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

/**
 * Every line ending collapsed to `\n`, whatever the checkout happened to write.
 *
 * Worth writing down at length, because as a bare `.replace` it reads like
 * tidiness and it is not: it is the whole of a bug that cost a CI run.
 *
 * Git decides line endings at *checkout*, not in the repository, and it decides
 * them with whatever the installer configured. Git for Windows ships
 * `core.autocrlf=true` and the `windows-latest` runner inherits it, so from one
 * identical commit this file reads `\r\n` there and `\n` on every machine the
 * tests were written on. Everything below parses CSS by hand — a Node test has
 * no CSS parser and does not want one for this — and hand-written parsing is
 * exactly where that difference stops being invisible. `\n${selector} {\n` is a
 * needle that a CRLF sheet does not contain *anywhere*, so `ruleBody` answered
 * `null` for every rule in the file at once and seven assertions failed with
 * `undefined` against values that are plainly there in the sheet.
 *
 * The part worth knowing before writing the next parser of this kind: `^` and
 * `$` are *not* the hazard. JavaScript counts a bare `\r` as a line terminator,
 * so a `/m` anchor already lands in the right place on a CRLF file. Only a
 * *literal* `\n` is the trap — as an `indexOf` needle, or spelled out inside a
 * pattern. Both shapes appear below, which is why this is applied at the top of
 * each parser rather than trusted to the one call that reads the disk.
 *
 * `\r\n?` rather than `\r\n` so that a lone `\r` collapses as well. Nothing
 * produces classic-Mac endings any more, but a parser that quietly mangles them
 * is a worse answer than one that costs a single character to make total.
 */
const lf = (text: string): string => text.replace(/\r\n?/g, '\n')

/** A sheet or a component, in the line endings the rest of this file assumes. */
const read = (name: string): string => lf(readFileSync(join(HERE, name), 'utf8'))

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
function ruleBody(sheet: string, selector: string): string | null {
  // Normalised here rather than only where the file is read, so the function is
  // correct for any string handed to it. That is not defensiveness for its own
  // sake — it is what lets the CRLF block at the bottom of this file exercise
  // *this* parser with Windows input instead of a second copy of it that could
  // drift, and so what makes the Windows failure reproducible on a Mac.
  const css = lf(sheet)
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

/**
 * Every selector on the bar that has to subtract itself from the drag region,
 * and the sheet each one is written in.
 *
 * At module scope because two describes below consume it: the one that checks
 * the declaration is present, and the one that checks it is still *findable*
 * when the sheet arrives with Windows line endings. Anything added here is
 * covered by both without anyone having to remember to add it in two places —
 * which matters, because the second list is the one a reader would forget.
 */
const NO_DRAG = [
  // The two slots `WindowToolbar` renders other people's components into.
  // Opting the slot out rather than each child is what makes it impossible
  // for a caller to add a control that moves the window.
  [SHELL, '.toolbar-actions'],
  [SHELL, '.toolbar-chips'],
  // The reveal button, which is positioned out of the flow inside the lead.
  [SHELL, '.toolbar-btn'],
  // And the control that sits directly beside the OS's close button.
  [MODE_SWITCH, '.mode-switch'],
] as const

/**
 * Every top-level rule in a sheet, as `[selector, body]`.
 *
 * The same column-zero reading `ruleBody` makes, done in bulk: a rule's
 * selector starts the line and its `}` closes one, and nothing in these sheets
 * nests, so an indented copy inside a `@media` block is correctly skipped.
 *
 * Split out of the sweep it serves so that it can be run against CRLF input
 * directly. That is not decoration either — under `\r\n` this pattern matched
 * *zero* rules out of a hundred and forty-seven, and a sweep over an empty list
 * finds no offenders and passes. So on Windows this check was not failing, it
 * was reporting success while looking at nothing, which is the more expensive
 * of the two outcomes and the one nobody goes looking for.
 */
function topLevelRules(sheet: string): Array<readonly [string, string]> {
  return [...lf(sheet).matchAll(/^([^\s@}][^\n]*) \{\n([\s\S]*?)\n\}/gm)].map(
    (match) => [match[1], match[2]] as const,
  )
}

/** The pixel gutters that exist only because macOS puts three lights there. */
const LIGHTS_RESERVE = /\b(82px|118px)\b/

/**
 * Rules that hold room for the traffic lights with no Windows counterpart.
 *
 * Takes the sheet as an argument for the same reason as everything else here:
 * the CRLF block has to be able to ask it the question with Windows input.
 */
function lightsReserveOffenders(sheet: string): string[] {
  const css = stripComments(lf(sheet))
  const offenders: string[] = []
  for (const [selector, body] of topLevelRules(css)) {
    if (!LIGHTS_RESERVE.test(body)) continue
    if (selector.startsWith(':root[data-window-controls]')) continue
    if (!css.includes(`:root[data-window-controls] ${selector} {`)) offenders.push(selector)
  }
  return offenders
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

  for (const [sheet, selector] of NO_DRAG) {
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
    expect(
      lightsReserveOffenders(SHELL),
      'these rules hold room for the macOS traffic lights and say nothing about the platform ' +
        'that has no traffic lights. On Windows that is an empty gap at the top-left of the ' +
        'window with a control adrift in the middle of it.',
    ).toEqual([])
    // And the sweep is looking at something: a sheet that stopped spelling the
    // reserve would pass this vacuously. So would a sheet the sweep could not
    // read at all, which is precisely what CRLF did to it — hence the second
    // check, that rules were found, and the CRLF block at the end of the file.
    expect(LIGHTS_RESERVE.test(stripComments(SHELL))).toBe(true)
    expect(topLevelRules(SHELL).length).toBeGreaterThan(0)
  })
})

describe('the sheet reads the same however git checked it out', () => {
  /*
   * The guard for the class of bug that took this whole file down, run on the
   * machine the file is written on.
   *
   * Everything above reads CSS off disk and parses it by hand, and on a Windows
   * checkout that CSS arrives with `\r\n` line endings — `core.autocrlf=true` is
   * what Git for Windows installs and what the `windows-latest` runner inherits.
   * The parsers were written against `\n`, so on that machine `ruleBody` found
   * no rule at all and seven assertions failed with `undefined` against
   * declarations that are sitting right there in the sheet. The sweep over
   * top-level rules did something worse than fail: it matched zero rules and
   * reported no offenders, passing green while checking nothing.
   *
   * The important thing about this block is *where it runs*. Making the parsers
   * tolerate `\r` fixes the bug; a guard that can only fail on a Windows runner
   * would not be a guard, it would be a notification an hour later, on a red
   * release build, for a developer who has no Windows machine to reproduce it
   * on. So the CRLF sheet is manufactured here from the real one and fed to the
   * real parsers, and this fails on a Mac the moment somebody writes a literal
   * `\n` into one of them again.
   *
   * Each check is written as "CRLF answers what LF answers" rather than against
   * a hardcoded expectation, so it keeps testing line endings and never turns
   * into a second, staler copy of the assertions above it.
   */
  const asWindows = (text: string): string => text.replace(/\n/g, '\r\n')

  it('finds the drag region on a CRLF checkout', () => {
    expect(appRegion(asWindows(SHELL), '.toolbar')).toBe(appRegion(SHELL, '.toolbar'))
    // Not vacuous: the sheet really does say something here, on both readings.
    expect(appRegion(SHELL, '.toolbar')).toBe('drag')
  })

  for (const [sheet, selector] of NO_DRAG) {
    it(`finds ${selector}'s opt-out on a CRLF checkout`, () => {
      expect(appRegion(asWindows(sheet), selector)).toBe(appRegion(sheet, selector))
      expect(appRegion(asWindows(sheet), selector)).toBe('no-drag')
    })
  }

  it('reads a rule body without dragging a carriage return into it', () => {
    /*
     * The second failure mode of the same cause, and the quieter one: a parser
     * can find the rule and still hand back `drag\r`, or a declaration whose
     * trailing token no longer equals the string it is compared against. The
     * `.toolbar` padding assertion is a `toContain` over a body, so a stray
     * `\r` at the end of a line inside it is exactly the shape that would slip
     * through the check above and fail the one that matters.
     */
    const body = requireRule(asWindows(SHELL), '.toolbar')
    expect(body).not.toContain('\r')
    expect(body).toContain('padding-right: calc(var(--sp-3) + var(--window-controls-inset, 0px))')
  })

  it('sweeps the same rules on a CRLF checkout', () => {
    // The one that was passing vacuously. 147 rules against 0 was the real
    // measurement; asserting equality keeps it honest as the sheet grows.
    expect(topLevelRules(asWindows(SHELL))).toEqual(topLevelRules(SHELL))
    expect(lightsReserveOffenders(asWindows(SHELL))).toEqual([])
    expect(topLevelRules(asWindows(SHELL)).length).toBeGreaterThan(0)
  })

  it('parses a hand-written CRLF sheet, independently of the real one', () => {
    /*
     * Deliberately not derived from `shell.css`. Every check above compares the
     * real sheet with itself, which proves the parsers agree — but if the sheet
     * were restructured into a shape neither reading could parse, they would
     * agree on nothing and still pass. Six literal lines with `\r\n` spelled out
     * is the fixed point that cannot rot with the stylesheet.
     */
    const sheet = [
      '/* a sheet, exactly as a Windows checkout hands it over */',
      '.toolbar {',
      '  -webkit-app-region: drag;',
      '}',
      '',
      '.toolbar-btn {',
      '  -webkit-app-region: no-drag;',
      '}',
      '',
    ].join('\r\n')

    expect(appRegion(sheet, '.toolbar')).toBe('drag')
    expect(appRegion(sheet, '.toolbar-btn')).toBe('no-drag')
    expect(appRegion(sheet, '.nothing-here')).toBeUndefined()
    expect(topLevelRules(sheet).map(([selector]) => selector)).toEqual(['.toolbar', '.toolbar-btn'])
    // And a lone `\r`, which `lf` also collapses, so that the total claim the
    // helper makes is the claim that is actually tested.
    expect(appRegion(sheet.replace(/\r\n/g, '\r'), '.toolbar')).toBe('drag')
  })
})
