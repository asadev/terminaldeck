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
 * The tab strip's sheet, read from the folder next door.
 *
 * It is in `browser/` for a reason recorded at the top of `WorkspaceTabStrip.tsx`
 * — six agents were editing one tree and `shell/` belonged to somebody else —
 * and nothing about it is browser-specific. Since 2026-08-17 it is the window's
 * *top band*: it holds the macOS traffic lights when the rail is away, it is
 * what you drag the window by, and while a browser page fills the pane it is the
 * only chrome on screen. Every claim below that this file was written to guard
 * therefore applies to it, and it is swept here rather than in a second copy of
 * this machinery.
 */
const STRIP = lf(readFileSync(join(HERE, '..', 'browser', 'WorkspaceTabStrip.css'), 'utf8'))
const STRIP_TSX = lf(readFileSync(join(HERE, '..', 'browser', 'WorkspaceTabStrip.tsx'), 'utf8'))
/**
 * The browser panel's sheet, read here for one reason only.
 *
 * "The selected tab and the thing under it are one surface" is a claim about
 * three sheets, not one — the strip fills the tab, `shell.css` fills the session
 * bar, and this fills the panel that takes the session bar's place when the tab
 * holds a page instead of a terminal. Split across three test files the claim
 * would be three unrelated assertions about three greys, and the seam it exists
 * to catch is precisely the one that appears when one of them moves. So it is
 * checked in one place, beside the shape it belongs to.
 */
const BROWSER = lf(readFileSync(join(HERE, '..', 'browser', 'BrowserWorkspace.css'), 'utf8'))

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
  // The strip's own: a tab, the face you press to switch to it, and the copy
  // of the reveal button this bar draws while it is the top band. A press on
  // any of them that moved the window instead would be indistinguishable in a
  // screenshot from one that worked.
  [STRIP, '.strip-tab'],
  [STRIP, '.strip-tab-face'],
  [STRIP, '.strip-reveal'],
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

describe('the tab strip is the top band, with everything that implies', () => {
  /*
   * All three of a top band's jobs, and none of them is visible in a
   * screenshot of a broken one.
   *
   * The strip moved above the session's bar because he asked for it — "this
   * tabs should be upside, and this session and all this whole bar including
   * chat, split, terminal should be under this" — and the bar underneath is not
   * rendered at all while a browser page fills the pane. So in that state this
   * is the only chrome in the window: if it does not drag, the window cannot be
   * moved; if it does not reserve the lights their room, the first tab sits
   * under the close button; and if it does not draw the reveal control, a
   * pinned-away sidebar cannot be brought back at all.
   */
  it('makes the whole strip a drag region', () => {
    expect(appRegion(STRIP, '.strip')).toBe('drag')
  })

  it('has a no-drag rule for every class the strip puts on a button', () => {
    /*
     * The same mechanical sweep the toolbar gets, over the other sheet. The two
     * ways to break it are to add a button with a new class and to move an
     * existing one out of a rule that opts out.
     *
     * `optsOut` rather than `appRegion` because three of these controls share
     * one rule, and `ruleBody` anchors on an exact selector — it would answer
     * `undefined` for each of the three and the sweep would fail on a sheet that
     * is correct. Splitting the selector list is the honest reading, and it is
     * also what makes a *grouped* rule that quietly loses its declaration fail
     * here rather than on somebody's Windows machine.
     */
    const optsOut = (className: string): boolean =>
      topLevelRules(STRIP).some(
        ([selector, body]) =>
          /-webkit-app-region:\s*no-drag/.test(body) &&
          selector.split(',').some((one) => one.trim() === `.${className}`),
      )

    const classes = new Set(
      [...STRIP_TSX.matchAll(/<button[\s\S]*?className="([^"]+)"/g)].flatMap((match) =>
        match[1].split(/\s+/),
      ),
    )
    expect(
      classes.size,
      'no buttons found in WorkspaceTabStrip.tsx — has it changed shape?',
    ).toBeGreaterThan(0)
    /*
     * The ＋ menu's own rows are exempt, and that is a fact about where they are
     * painted rather than a convenience. Every floating surface in this
     * renderer is portalled into `<body>` — see `chip-menu.ts` — so a menu row
     * is not a descendant of the bar at all and no drag rectangle covers it.
     * They also wear `shell.css`'s shared `.folder-menu-*` classes, which the
     * account chip's menu wears too, so a rule for them in this sheet would be
     * a second owner for somebody else's styling.
     *
     * Written as one named prefix rather than "skip anything this sheet does not
     * style", which would exempt every new button that arrived without CSS —
     * exactly the mistake this sweep exists to catch.
     */
    const dragging = [...classes].filter(
      (name) => !name.startsWith('folder-menu') && !optsOut(name),
    )
    expect(dragging, 'these strip buttons are inside the drag region').toEqual([])
    // And the sweep can see the sheet at all: a parser that matched nothing
    // would report no offenders and pass green, which is what CRLF once did to
    // the block above.
    expect(optsOut('strip-tab-face')).toBe(true)
    expect(optsOut('nothing-of-the-sort')).toBe(false)
  })

  it('reserves the traffic lights their room, and says so for Windows too', () => {
    // 118px is 82 for the lights plus the reveal button and its gap — the same
    // arithmetic the toolbar uses, because it is the same button in the same
    // place, drawn by whichever bar happens to be first.
    expect(requireRule(STRIP, '.strip[data-sidebar-collapsed]')).toContain('padding-left: 118px')
    expect(STRIP).toContain(':root[data-window-controls] .strip[data-sidebar-collapsed] {')
    expect(lightsReserveOffenders(STRIP)).toEqual([])
    // Not vacuous: the sweep is looking at a sheet it can actually parse.
    expect(topLevelRules(STRIP).length).toBeGreaterThan(0)
  })

  it('holds room for the Windows caption buttons on its right', () => {
    // Drawn over the page in the top-right of whatever bar is first, so with
    // the strip on top they land on the last tab rather than on the mode switch.
    expect(requireRule(STRIP, '.strip')).toContain('var(--window-controls-inset, 0px)')
  })

  it('lines up with the rail’s gutter, so the one hairline crosses the window', () => {
    /*
     * The failure recorded on `.sidebar-gutter`: two bars of different heights
     * put the window's single rule across the content and then stopped it dead
     * in mid-air at the rail's edge, which reads as a clipping bug rather than
     * as an edge. Whichever bar is beside the gutter has to be its height and
     * carry its line.
     */
    const strip = requireRule(STRIP, '.strip')
    expect(strip).toContain('height: var(--toolbar-h)')
    expect(strip).toContain('inset 0 -1px 0 var(--border-subtle)')
    expect(requireRule(SHELL, '.sidebar-gutter')).toContain('height: var(--toolbar-h)')
  })

  it('takes the hairline off the bar underneath, rather than drawing a second one', () => {
    // Two rules 48px apart read as two stacked applications — the exact fault
    // `PLAN-0.2.0.md` opens with about the Windows chrome.
    const under = requireRule(SHELL, '.toolbar[data-under-strip]')
    expect(under).toContain('box-shadow: none')
    expect(under).toContain('backdrop-filter: none')
  })

  it('draws the selected tab as one surface with the pane under it', () => {
    /*
     * The Chrome shape, checked as the three claims that make it one rather
     * than as "it has a radius".
     *
     * Asad sent a screenshot of Chrome's tab bar as the reference, and what is
     * in that picture is a selected tab whose bottom edge does not exist: the
     * tab is the page's colour, it reaches the bar's own hairline and paints
     * over it, and two flares at its feet carry that surface out across the
     * gap. Any one of the three on its own is a rounded rectangle floating on a
     * bar, which is exactly what this replaced.
     *
     * Checked here rather than by looking, because all three are invisible in a
     * screenshot the moment one of them is subtly wrong — a tab one pixel short
     * of the bottom, or a flare in an approximation of the bar's colour rather
     * than the page's, reads as "nearly right" and is the whole defect.
     */
    const tab = requireRule(STRIP, '.strip-tab')
    // Top corners only. A radius at the bottom is a gap between the tab and the
    // thing it opens.
    expect(tab).toContain('border-radius: var(--radius-md) var(--radius-md) 0 0')
    expect(tab).toContain('height: var(--strip-tab-h)')
    // Sitting on the bar's bottom edge, which is what lets it cover the
    // hairline `.strip` draws under all of its children.
    expect(requireRule(STRIP, '.strip-rail')).toContain('align-items: flex-end')

    /*
     * The surface the tab opens onto, named by its own token in every sheet
     * that has to meet it.
     *
     * `--tab-active` was `--bg-primary` when this was written, and the bar
     * below said `--bg-primary` too — which was right in the dark theme by
     * accident and wrong in the light one, where the session under that bar is
     * `--terminal-bg`. The token is the claim: whatever the tab is filled with,
     * everything the tab's foot touches is filled with the same thing.
     * `tokens.test.ts` is what holds that value to the terminal's paper; this
     * is what holds the three sheets to the token instead of to a colour that
     * happens to equal it today.
     */
    expect(requireRule(STRIP, '.strip-tab[data-active]')).toContain(
      'background: var(--tab-active)',
    )
    expect(
      requireRule(SHELL, '.toolbar[data-under-strip]'),
      'the bar under the strip must be the same surface the selected tab is',
    ).toContain('background-color: var(--tab-active)')
    expect(
      requireRule(BROWSER, '.bw'),
      'with a browser page in the pane there is no session bar, so this panel is what the tab meets',
    ).toContain('background: var(--tab-active)')
    /*
     * There used to be a second assertion here, on `.bw-bottom`, checking that
     * the panel's two bands were one ground rather than two spellings of it.
     * There is one band now: *"remove everything from the bottom, I need a
     * clear view of the websites — whatever is required should be on the top
     * right corner."* The rule, the class and the markup are all deleted, so
     * the two bands cannot disagree, and asserting on a selector that no longer
     * exists would only have proved the stylesheet still contained a corpse.
     */

    /*
     * The one place that surface is deliberately *not* continued.
     *
     * A page opened from the rail covers the strip's selection — the strip is
     * passed `covered` and stops drawing any tab as selected — so there is no
     * tab above this bar to continue, and `.panel-page` under it sits on the
     * app canvas. Carrying the session's paper across here would move the seam
     * one band down rather than close it, which is a thing a screenshot of the
     * session view cannot show.
     */
    expect(requireRule(SHELL, '.toolbar[data-under-strip][data-page]')).toContain(
      'background-color: var(--bg-primary)',
    )

    // And the flares, in that same colour, cut with a mask rather than filled
    // with an opaque guess at the bar — the bar is glass, and a patch of
    // approximated glass shows the moment there is anything behind the window.
    const skirt = requireRule(
      STRIP,
      '.strip-tab[data-active] .strip-tab-skirt::before,\n.strip-tab[data-active] .strip-tab-skirt::after',
    )
    expect(skirt).toContain('background: var(--tab-active)')
    expect(STRIP).toContain('-webkit-mask-image: radial-gradient(')
    expect(STRIP).toContain('mask-image: radial-gradient(')
  })

  it('leaves one ✕ in this window, so there is no pair to confuse', () => {
    /*
     * The most dangerous thing in this window as of 2026-08-17: two identical ✕
     * glyphs, 260 pixels apart, one of which kills a pty and one of which only
     * takes a tab off this bar. Asad asked for the second — *"it should not
     * delete the session"* — and the moment they diverged, looking the same
     * became a trap. The rail's ✕ answered it with `--color-critical` on hover,
     * which was the only layer of the difference visible before the click.
     *
     * On 2026-08-20 the rail's ✕ stopped existing: it is an entry in the row's ⋯
     * menu now, reading the whole consequence out loud. So the colour rule is
     * gone with the glyph, and what is asserted is the state that made it
     * unnecessary — the strip's ✕ is the only one left, and it is grey, because
     * it is the harmless one.
     */
    expect(SHELL).not.toContain('.sb-close:hover {')
    expect(requireRule(STRIP, '.strip-tab-close:hover')).not.toContain('--color-critical')
    expect(requireRule(STRIP, '.strip-tab-close:hover')).toContain('color: var(--text-primary)')
  })

  it('separates an unselected tab with a tint, and never with a line', () => {
    /*
     * This used to read "leaves an unselected tab flat against the bar", and
     * asserted that the only fill in the row arrived on hover. That was the
     * reference picture read strictly, and Asad overruled it after looking at
     * the result: *"let's make the selected tab pill up there, selected and
     * other tabs' pill, a little bit more white."* An unselected tab measured
     * rgb(33,33,33) on a bar of rgb(33,33,33), so four fifths of the row had no
     * pill under it at all.
     *
     * What survives is the part of the rule that was never about the fill: the
     * separation is a tint and it is still not a line, the tab itself carries
     * no background of its own so nothing paints under the selected tab's, and
     * the selected tab is exempt from the hover because a hover that changed
     * its fill would break the join with the pane while the pointer was there.
     * The shades and the reasoning behind them are pinned in
     * `browser/workspace-strip.test.tsx`, beside the sheet that sets them.
     */
    expect(ruleBody(STRIP, '.strip-tab')).not.toMatch(/^\s*background/m)
    expect(requireRule(STRIP, '.strip-tab:not([data-active])')).toContain('--fill-quaternary')
    expect(requireRule(STRIP, '.strip-tab:hover:not([data-active])')).toContain('--fill-tertiary')
    // A radius is a shape, not a line, so the sweep names the line properties
    // rather than everything that starts with `border`.
    const line = /^\s*border(-(top|right|bottom|left|width|style|color))?:/m
    for (const selector of ['.strip-tab', '.strip-tab:not([data-active])'])
      expect(requireRule(STRIP, selector), `${selector} draws a line`).not.toMatch(line)
  })

  it('keeps the lights’ reserve out of a bar that is no longer the top one', () => {
    /*
     * Both halves of the same claim. The reserve rules have to be spelled with
     * `:not([data-under-strip])` — otherwise a session's title starts 118px in
     * with nothing in the gap — and the Windows counterpart the sweep insists on
     * has to be a character-for-character mirror, or the sweep sees a rule with
     * no partner and fails for a reason nobody would guess from the message.
     */
    expect(SHELL).toContain('.toolbar[data-sidebar-collapsed]:not([data-under-strip]) {')
    expect(SHELL).toContain(
      ':root[data-window-controls] .toolbar[data-sidebar-collapsed]:not([data-under-strip]) {',
    )
    expect(lightsReserveOffenders(SHELL)).toEqual([])
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
