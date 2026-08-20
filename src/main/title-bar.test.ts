import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  OVERLAY_HEIGHT,
  overlayFor,
  resolveAppearance,
  titleBarChrome,
  TRAFFIC_LIGHT_POSITION,
  usesWindowControlsOverlay,
  type Appearance,
} from './title-bar'

/**
 * The window's top edge, pinned for both platforms from one machine.
 *
 * Two different kinds of claim are checked here, and they fail for different
 * reasons:
 *
 *   1. **Shape.** Windows must get a frameless window with a real overlay and
 *      macOS must keep `hiddenInset` exactly as it was. Nobody here can open a
 *      Windows window, so the only thing that can be reviewed is the options
 *      object — which is precisely why `titleBarChrome` takes the platform as a
 *      value instead of reading `process.platform` (see `platform/host.ts`).
 *
 *   2. **Colour.** The overlay strip is painted by the OS, outside the page, so
 *      it cannot read a CSS variable and the two colours are copied by hand into
 *      TypeScript. `styles/tokens.test.ts` exists because every previous copy of
 *      that kind in this repository had silently gone stale — the pre-paint
 *      window colour was two palettes out of date while a comment above it asked
 *      the next person to remember. So this recomputes the toolbar's own recipe
 *      from `tokens.css` and compares. A token change now fails here, naming the
 *      variable that moved, instead of shipping a grey strip beside a bar that
 *      is no longer that grey.
 */

const ROOT = resolve(__dirname, '..', '..')

/**
 * Every line ending collapsed to `\n`, whatever the checkout happened to write.
 *
 * This one line is why the whole file failed to run on Windows, so it gets the
 * explanation rather than a shrug.
 *
 * Git decides line endings at *checkout*, not in the repository. Git for
 * Windows ships `core.autocrlf=true` and the `windows-latest` runner inherits
 * it, so from one identical commit `tokens.css` arrives here with `\r\n` on
 * that machine and `\n` on every machine this test was written on. The rule
 * patterns below spell out a literal `\n` between the two selectors of the
 * light theme, that `\n` cannot match a `\r`, `declarations` threw — and
 * because it is called at module scope to build `THEME`, the throw happened
 * during collection and took all fifteen tests in the file with it. A parse
 * error two lines from the top reads in CI as "the file failed to run", which
 * says nothing about title bars and sends the reader to the wrong place.
 *
 * The part worth carrying to the next parser: `^` and `$` are *not* the hazard.
 * JavaScript counts a bare `\r` as a line terminator, so a `/m` anchor already
 * lands correctly on a CRLF file — `/^\[data-theme='dark'\] \{$/m` matches
 * either way, which is exactly why only *one* of the three rules below broke
 * and the cause looked like something about the light theme. Only a literal
 * `\n`, in a pattern or in an `indexOf` needle, is the trap. Both shapes are
 * used below.
 *
 * `\r\n?` rather than `\r\n` so a lone `\r` collapses too — a character's cost
 * for a helper that is then total rather than nearly total.
 */
const lf = (text: string): string => text.replace(/\r\n?/g, '\n')

const TOKENS = lf(readFileSync(join(ROOT, 'src', 'renderer', 'styles', 'tokens.css'), 'utf8'))

/**
 * The declarations of one rule in `tokens.css`, by custom-property name.
 *
 * The block ends at the first `}` in column zero, which is enough because no
 * rule in that sheet nests — the same reading `styles/tokens.test.ts` makes,
 * for the same reason: this file is compiled by the *main* project, which does
 * not include `src/renderer`, so the sheet can only be read as text.
 *
 * Takes the sheet as an argument rather than closing over `TOKENS`, which it
 * used to do. That is what lets the CRLF block at the end of this file hand
 * Windows input to *this* parser, on this Mac, instead of to a second copy of
 * it that would drift — and a guard that can only fail on a Windows runner is
 * not a guard, it is a red release build an hour later. Patterns passed in may
 * assume `\n`, because the first thing done here is to make that true.
 */
function declarations(sheet: string, selector: RegExp): Map<string, string> {
  const tokens = lf(sheet)
  const start = selector.exec(tokens)
  if (!start) throw new Error(`tokens.css has no ${selector} rule — has it been rewritten?`)
  const from = start.index + start[0].length
  const end = tokens.indexOf('\n}', from)
  const body = tokens.slice(from, end === -1 ? undefined : end)
  const out = new Map<string, string>()
  for (const match of body.matchAll(/(--[\w-]+):\s*([^;]+);/g)) {
    out.set(match[1], match[2].trim().replace(/\s+/g, ' '))
  }
  return out
}

/**
 * The three rules read out of the sheet, named once.
 *
 * At module scope so the CRLF block can ask for the same three by the same
 * patterns. A fourth added here is covered there without anybody remembering.
 * Safe to share: none carries `/g` or `/y`, so `exec` keeps no `lastIndex`
 * between callers.
 */
const RULES = {
  light: /^:root,\n\[data-theme='light'\] \{$/m,
  dark: /^\[data-theme='dark'\] \{$/m,
  shared: /^:root \{$/m,
} as const

const THEME: Record<Appearance, Map<string, string>> = {
  light: declarations(TOKENS, RULES.light),
  dark: declarations(TOKENS, RULES.dark),
}
const SHARED = declarations(TOKENS, RULES.shared)

type Rgb = [number, number, number]

function parseColour(value: string): { rgb: Rgb; alpha: number } {
  const hex = /^#([0-9a-f]{6})$/i.exec(value)
  if (hex) {
    const n = Number.parseInt(hex[1], 16)
    return { rgb: [(n >> 16) & 255, (n >> 8) & 255, n & 255], alpha: 1 }
  }
  const rgba = /^rgba?\(\s*([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\s*\)$/.exec(value)
  if (!rgba) throw new Error(`cannot read the colour ${value}`)
  return {
    rgb: [Number(rgba[1]), Number(rgba[2]), Number(rgba[3])],
    alpha: rgba[4] === undefined ? 1 : Number(rgba[4]),
  }
}

const composite = (over: { rgb: Rgb; alpha: number }, under: Rgb): Rgb =>
  under.map((channel, i) => over.rgb[i] * over.alpha + channel * (1 - over.alpha)) as Rgb

const hex = (rgb: Rgb): string =>
  `#${rgb.map((c) => Math.round(c).toString(16).padStart(2, '0')).join('')}`

/**
 * The mean alpha of `--material-sheen` over the height of the bar.
 *
 * The sheen is a vertical gradient and the OS paints the overlay as one flat
 * colour, so there is no value that matches everywhere. Integrating the
 * piecewise-linear gradient and dividing by its length gives the flat colour
 * whose total difference from the gradient is smallest, which is the best a
 * flat strip beside a gradient can do. Written out here as well as in
 * `title-bar.ts` so that a reader can check the arithmetic in the source
 * against an independent implementation of it, rather than against a comment.
 *
 * `none` is a value, not a parse failure, and this is where that had to be
 * said. The dark-flat pass set `--material-sheen: none` — the dark chrome is
 * one colour from top to bottom now, and an opaque `--material-bg` plus no
 * gradient is how it gets there. This function demanded at least two white
 * stops and threw `no white stops in none`, so both of the overlay-colour
 * assertions failed for a reason that named a gradient and pointed nowhere near
 * the appearance change that caused it. A sheen of nothing contributes nothing:
 * mean zero, and the composite below then correctly returns the fill on its own.
 */
function meanSheenAlpha(gradient: string): number {
  if (gradient === 'none') return 0
  const stops = [...gradient.matchAll(/rgba\(255, 255, 255, ([\d.]+)\) ([\d.]+)%/g)].map(
    (match) => [Number(match[2]) / 100, Number(match[1])] as const,
  )
  expect(stops.length, `no white stops in ${gradient}`).toBeGreaterThan(1)
  expect(stops[0][0]).toBe(0)
  expect(stops[stops.length - 1][0]).toBe(1)
  let area = 0
  for (let i = 1; i < stops.length; i++) {
    const [at, alpha] = stops[i]
    const [prevAt, prevAlpha] = stops[i - 1]
    area += ((alpha + prevAlpha) / 2) * (at - prevAt)
  }
  return area
}

/** What `.toolbar` in `shell/shell.css` actually composites to, per theme. */
function toolbarColour(appearance: Appearance): string {
  const theme = THEME[appearance]
  const canvas = parseColour(theme.get('--bg-primary') ?? '').rgb
  const glass = composite(parseColour(theme.get('--material-bg') ?? ''), canvas)
  const sheen = { rgb: [255, 255, 255] as Rgb, alpha: meanSheenAlpha(theme.get('--material-sheen') ?? '') }
  return hex(composite(sheen, glass))
}

/**
 * The body of one top-level rule in one of the shell's stylesheets.
 *
 * Anchored on a `{` at the end of the selector line and a `}` in column zero,
 * because rules in these sheets start in column zero and none of them nest —
 * which is what keeps this from matching an indented copy inside a `@media`
 * block, a different rule with a different job. The same reading
 * `shell/shell.test.ts` makes, for the same reason this file reads `tokens.css`
 * as text: the main project does not compile `src/renderer`.
 */
function ruleBody(sheet: string, selector: string): string {
  const css = lf(sheet)
  const opening = `\n${selector} {\n`
  const start = css.indexOf(opening)
  expect(start, `no \`${selector}\` rule — has the shell been rewritten?`).not.toBe(-1)
  const from = start + opening.length
  const end = css.indexOf('\n}', from)
  return css.slice(from, end === -1 ? undefined : end)
}

describe('the two bars that can be the window top band are painted the same', () => {
  /*
   * The assumption the colour arithmetic rests on, checked instead of assumed.
   *
   * The Windows overlay is a strip in the top-right *of the window*, so what it
   * has to match is whatever band is at the top. With tabs open that is
   * `.strip`; with none it is `.toolbar`. Everything below computes one colour
   * because those two wear one recipe today — and nothing anywhere said so, so
   * a pass that restyled the strip alone would have moved the top band out from
   * under a constant that still matched the other bar and still passed every
   * test in this file.
   *
   * Not a claim that they must always agree. It is a claim that while they do,
   * one colour is enough; the day they stop, this fails first and the overlay
   * needs a rule about which band it is in, not a new hex.
   */
  const SHELL = lf(readFileSync(join(ROOT, 'src', 'renderer', 'shell', 'shell.css'), 'utf8'))
  const STRIP = lf(
    readFileSync(join(ROOT, 'src', 'renderer', 'browser', 'WorkspaceTabStrip.css'), 'utf8'),
  )

  for (const [name, body] of [
    ['.toolbar', ruleBody(SHELL, '.toolbar')],
    ['.strip', ruleBody(STRIP, '.strip')],
  ] as const) {
    it(`${name} is the glass recipe the overlay colour is computed from`, () => {
      expect(
        body,
        `${name} no longer paints \`--material-bg\`. The Windows window buttons are painted a ` +
          'colour composited from that token in title-bar.ts, and the OS paints them outside ' +
          'the page where no stylesheet can reach. Work out which band the overlay is in now.',
      ).toContain('background-color: var(--material-bg)')
      expect(body).toContain('background-image: var(--material-sheen)')
    })

    it(`${name} is exactly as tall as the overlay`, () => {
      // A band shorter than the strip leaves the buttons overhanging onto the
      // content; taller, and they float in a lane of their own. Both are the
      // stacked-strips look this whole feature removed, arriving sideways.
      expect(body).toContain('height: var(--toolbar-h)')
    })
  }

  it('the band one step down is a different colour, and is not where the buttons are', () => {
    /*
     * `.toolbar[data-under-strip]` is `--tab-active`, so that the selected tab,
     * this bar and the session below it are one continuous panel. It measures
     * `rgb(25,25,25)` in the dark theme against the top band's `rgb(33,33,33)`,
     * and it is the bar you land on if you read "the toolbar" without noticing
     * there is a strip above it. Pinned as *different* so that nobody
     * reconciles the overlay to it.
     */
    const under = ruleBody(SHELL, '.toolbar[data-under-strip]')
    expect(under).toContain('background-color: var(--tab-active)')
    expect(under).toContain('background-image: none')
  })
})

describe('the Windows overlay is painted in the colours of the bar it sits in', () => {
  for (const appearance of ['dark', 'light'] as const) {
    it(`${appearance}: the strip is the toolbar's own composite`, () => {
      const overlay = overlayFor('win32', appearance)
      expect(
        overlay?.color,
        `The window buttons are painted ${overlay?.color} while the toolbar beside them ` +
          `composites to ${toolbarColour(appearance)}. The OS paints that strip outside the ` +
          'page, so it cannot read tokens.css — update the copy in title-bar.ts, and the ' +
          'arithmetic in the comment above it.',
      ).toBe(toolbarColour(appearance))
    })

    it(`${appearance}: the symbols are drawn in the ink of the buttons beside them`, () => {
      // `--text-secondary` is what `.toolbar-btn` is set in. Two sets of
      // controls on one bar at two different weights is what makes a bar look
      // assembled rather than designed.
      expect(overlayFor('win32', appearance)?.symbolColor).toBe(
        THEME[appearance].get('--text-secondary'),
      )
    })
  }

  it('is exactly as tall as the toolbar', () => {
    // Disagree and the buttons either float in a band of their own above our
    // bar or overhang its bottom edge onto the content — which is the stacked
    // strips this whole change removes, arriving through a different door.
    expect(`${OVERLAY_HEIGHT}px`).toBe(SHARED.get('--toolbar-h'))
  })

  it('follows the theme rather than the one it launched in', () => {
    // A dark strip on a light header is a visible bug, and the theme can be
    // changed at any moment from Settings.
    expect(overlayFor('win32', 'dark')).not.toEqual(overlayFor('win32', 'light'))
  })
})

describe('each platform gets the top edge its users expect', () => {
  it('macOS is untouched: hidden inset, lights where shell.css expects them', () => {
    /*
     * The traffic lights are load-bearing for the stylesheet: `.sidebar-gutter`
     * pads 82px to clear them and centres its arrow on their centre line, which
     * it computes from y = 12 plus half of the 14px button. Moving either number
     * silently moves a control three pixels off a line nobody can name.
     */
    expect(titleBarChrome('darwin', 'dark')).toEqual({
      titleBarStyle: 'hiddenInset',
      trafficLightPosition: { x: 14, y: 12 },
    })
    expect(TRAFFIC_LIGHT_POSITION).toEqual({ x: 14, y: 12 })
    // Both appearances, because macOS is not told about the theme at all — the
    // lights are the system's and they follow the system.
    expect(titleBarChrome('darwin', 'light')).toEqual(titleBarChrome('darwin', 'dark'))
  })

  it('macOS gets no overlay to set, ever', () => {
    // `setTitleBarOverlay` does not exist on macOS. The null is what the caller
    // guards on, and it has to be the same decision that built the constructor
    // options or the two can disagree about which window it is talking to.
    expect(overlayFor('darwin', 'dark')).toBeNull()
    expect(usesWindowControlsOverlay('darwin')).toBe(false)
  })

  it('Windows loses the OS strip and keeps real window buttons', () => {
    const chrome = titleBarChrome('win32', 'dark')
    // 'hidden', not `frame: false`: the window keeps its resize borders, Aero
    // Snap and the snap-layouts flyout, and Windows keeps drawing the three
    // buttons itself. Hand-drawn HTML buttons have none of that.
    expect(chrome.titleBarStyle).toBe('hidden')
    expect(chrome.titleBarOverlay).toBeTruthy()
    expect(chrome.titleBarOverlay?.height).toBe(OVERLAY_HEIGHT)
    // And nothing macOS-only leaks across: `trafficLightPosition` used to be
    // passed on every platform, which is how nobody noticed Windows was still
    // on the default frame.
    expect(chrome.trafficLightPosition).toBeUndefined()
  })

  it('Linux keeps the system title bar rather than a frameless window nobody has seen', () => {
    // Electron's overlay on Linux depends on the window manager, and there is no
    // Linux machine on this project to look at it on. A frameless window that
    // turns out to have no way to be moved is a worse failure than an extra
    // strip, so this platform is left alone until somebody can run it.
    expect(titleBarChrome('linux', 'dark')).toEqual({ titleBarStyle: 'default' })
    expect(overlayFor('linux', 'dark')).toBeNull()
  })
})

describe('the appearance the overlay is painted for', () => {
  it('takes the explicit choice when there is one', () => {
    expect(resolveAppearance('dark', false)).toBe('dark')
    expect(resolveAppearance('light', true)).toBe('light')
  })

  it('defers to the OS only when the user asked it to', () => {
    expect(resolveAppearance('system', true)).toBe('dark')
    expect(resolveAppearance('system', false)).toBe('light')
  })
})

describe('the window is actually built from this', () => {
  /*
   * The failure this catches is the one that was shipping: a `titleBarStyle`
   * ternary written inline in the constructor, which is a branch that can only
   * be read on the machine that takes it. Everything above is a claim about a
   * function; this is the claim that the function is what the window wears.
   */
  // Normalised like every other file read here. The three checks below are
  // single-line substrings, so CRLF could not break them today — but "today"
  // is doing all the work in that sentence, and the next assertion somebody
  // adds will be the one that spans a line break.
  const INDEX = lf(readFileSync(join(ROOT, 'src', 'main', 'index.ts'), 'utf8'))

  it('spreads the chrome into the BrowserWindow options', () => {
    expect(INDEX).toContain('...titleBarChrome(')
  })

  it('leaves no second opinion about the title bar anywhere in index.ts', () => {
    for (const inline of ['titleBarStyle:', 'trafficLightPosition:', 'titleBarOverlay:']) {
      expect(
        INDEX.includes(inline),
        `index.ts sets ${inline} itself. There is one answer per platform and it lives in ` +
          'title-bar.ts, where both of them can be read from either machine.',
      ).toBe(false)
    }
  })

  it('repaints the overlay when the theme changes', () => {
    // Otherwise the strip keeps the colour it launched in and a light theme has
    // a dark rectangle in its top-right corner until the app is restarted.
    expect(INDEX).toContain('setTitleBarOverlay')
    expect(INDEX).toContain('nativeTheme')
  })

  it('hands the app’s chosen appearance to Chromium, not only to the window', () => {
    /*
     * *"this window should be exactly same color as the application, white … If
     * it is dark, it should be dark."* — 2026-08-20, of the attach menu.
     *
     * That menu is a native `Menu.popup()`, and it has to be: an HTML menu would
     * open behind the `WebContentsView` the browser page is composited into.
     * A native menu takes the *OS* appearance, so the app being light and macOS
     * being dark produced a dark menu over a white window. `themeSource` is the
     * one switch that moves every native surface — menus, message boxes, native
     * scrollbars — onto the app's own choice.
     *
     * Asserted as source text for the reason the whole of this block is: there
     * is no Electron here to run, and the claim is that index.ts *does this at
     * all*, which is exactly what went missing.
     */
    expect(INDEX).toContain('nativeTheme.themeSource')
  })
})

describe('tokens.css reads the same however git checked it out', () => {
  /*
   * The guard for the thing that took this file off the board entirely, run on
   * the machine the file is written on.
   *
   * Everything above depends on `tokens.css` being parsed at import time, and
   * on a Windows checkout that sheet arrives with `\r\n`. The light-theme
   * pattern spells a literal `\n` between its two selectors, so it matched
   * nothing, `declarations` threw during collection, and CI reported the whole
   * file as failing to run — a message that names no test and no colour and
   * points nowhere near the cause.
   *
   * Where this runs is the point. Making the parser tolerate `\r` is the fix;
   * this is what stops the fix quietly coming undone. Without it the next
   * literal `\n` written into a pattern here is green on every developer
   * machine and red only on a Windows runner an hour later, for a developer who
   * has no Windows machine to reproduce it on. So the CRLF sheet is made here
   * out of the real one and fed to the real parser.
   *
   * Each check asks "does CRLF answer what LF answers" rather than restating an
   * expected value, so it keeps testing line endings instead of slowly becoming
   * a staler duplicate of the assertions above.
   */
  const asWindows = (text: string): string => text.replace(/\n/g, '\r\n')
  const CRLF_TOKENS = asWindows(TOKENS)

  for (const name of ['light', 'dark', 'shared'] as const) {
    it(`finds the ${name} rule on a CRLF checkout`, () => {
      expect(declarations(CRLF_TOKENS, RULES[name])).toEqual(declarations(TOKENS, RULES[name]))
      // Not vacuous: two empty maps would also be equal, and a sheet this
      // parser could not read at all would produce exactly that.
      expect(declarations(CRLF_TOKENS, RULES[name]).size).toBeGreaterThan(0)
    })
  }

  it('carries no carriage return into a value', () => {
    /*
     * The second failure mode of the same cause, and the one that would survive
     * the checks above: a parser can find the rule and still hand back
     * `#1c1b19\r`. That is not a crash, it is a colour that no longer equals the
     * string it is compared with — `parseColour` would reject it and the overlay
     * assertions would fail talking about hex digits rather than line endings.
     */
    for (const name of ['light', 'dark', 'shared'] as const) {
      for (const [property, value] of declarations(CRLF_TOKENS, RULES[name])) {
        expect(value, `${property} came back with a carriage return in it`).not.toContain('\r')
      }
    }
  })

  it('computes the same overlay colours from a CRLF sheet', () => {
    /*
     * End to end, because the arithmetic is where a stray `\r` would actually
     * be spent: `meanSheenAlpha` integrates a multi-line gradient value and
     * `parseColour` anchors on `$`, which without `/m` means end-of-input and
     * not "before the line ending". Both are downstream of the map, so this
     * asserts the map is usable and not merely present.
     */
    const fromCrlf = (appearance: Appearance): string => {
      const theme = declarations(CRLF_TOKENS, RULES[appearance])
      const canvas = parseColour(theme.get('--bg-primary') ?? '').rgb
      const glass = composite(parseColour(theme.get('--material-bg') ?? ''), canvas)
      const alpha = meanSheenAlpha(theme.get('--material-sheen') ?? '')
      return hex(composite({ rgb: [255, 255, 255] as Rgb, alpha }, glass))
    }
    for (const appearance of ['dark', 'light'] as const) {
      expect(fromCrlf(appearance)).toBe(toolbarColour(appearance))
      expect(overlayFor('win32', appearance)?.color).toBe(fromCrlf(appearance))
    }
  })

  it('parses a hand-written CRLF rule, independently of the real sheet', () => {
    /*
     * Deliberately not derived from `tokens.css`. Every check above compares the
     * real sheet with itself, which proves the two readings agree — but a sheet
     * restructured into a shape neither reading could parse would make them
     * agree on nothing and pass. Five literal lines with `\r\n` spelled out is
     * the fixed point that cannot rot with the palette.
     */
    const sheet = [
      '/* as a Windows checkout hands it over */',
      ':root,',
      "[data-theme='light'] {",
      '  --bg-primary: #ffffff;',
      '  --material-sheen: linear-gradient(rgba(255, 255, 255, 0.5) 0%, rgba(255, 255, 255, 0) 100%);',
      '}',
      '',
    ].join('\r\n')

    const parsed = declarations(sheet, RULES.light)
    expect(parsed.get('--bg-primary')).toBe('#ffffff')
    expect(meanSheenAlpha(parsed.get('--material-sheen') ?? '')).toBeCloseTo(0.25)
    // And a lone `\r`, which `lf` also collapses, so the helper's whole claim
    // is the claim that is actually tested.
    expect(declarations(sheet.replace(/\r\n/g, '\r'), RULES.light).get('--bg-primary')).toBe('#ffffff')
  })
})
