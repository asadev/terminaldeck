import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The palette, checked as a set of claims rather than admired as a swatch.
 *
 * Three things kept going wrong with colour in this repository, and all three
 * are the same bug wearing different clothes: a value that is *described*
 * correctly in a comment and *written* incorrectly in the code.
 *
 *   1. **Copies drift.** A CSS variable cannot be read from the main process,
 *      from a preload script injected into a guest page, or from xterm's
 *      canvas. So four colours are copied by hand into TypeScript. Every one of
 *      them was stale: `browser-preload.ts` outlined elements in `#8588f2`
 *      through two accent changes even though the comment directly above it
 *      says "if the accent in tokens.css changes, change it here too";
 *      `TerminalView.tsx` carried `#0e0f13`/`#8588f2` fallbacks from a palette
 *      that no longer existed; `main/index.ts` painted the pre-paint window
 *      `#0e0f13` against a canvas of `#1c1b19`, so every launch flashed the
 *      wrong dark. A comment asking a human to remember is not a mechanism.
 *      This file is the mechanism.
 *
 *   2. **Contrast claims go unchecked.** The previous sheet said "each one
 *      clears 4.5:1 on paper" next to three colours that only cleared it
 *      against pure white and dropped to 3.7:1 in the sidebar, which is where
 *      SetupSection and SearchPanel actually set them as text. A number in a
 *      comment is an assertion; assert it.
 *
 *   3. **"Neutral grey" is not a feeling.** The dark theme was reported as
 *      looking faintly orange. It was: `#1c1b19` runs three levels of red past
 *      blue and the tints were `rgba(255, 250, 240, …)`. Nobody could see that
 *      in a diff, and everybody could see it on a 1440px screen. r = g = b is
 *      checkable, so it is checked.
 *
 * Everything below reads the real files. If a value changes, this test fails
 * and names which claim stopped being true.
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

/**
 * Source with comment bodies removed.
 *
 * Load-bearing, not tidiness: the prose in `tokens.css` quotes the retired
 * colours by hex so the next reader knows what was replaced and why. Without
 * this, the "no retired colour survives" check below would trip on its own
 * explanation.
 */
const stripComments = (text: string): string =>
  text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')

/**
 * The declarations inside one CSS rule, by custom-property name.
 *
 * The block ends at the first `}` in column zero. That is enough because no
 * rule in this sheet nests, and the only parentheses that appear inside a value
 * belong to `rgba()` and `linear-gradient()`, neither of which carries a brace.
 */
function cssVars(css: string, selector: RegExp): Map<string, string> {
  const match = selector.exec(css)
  if (!match) throw new Error(`no rule matching ${selector} — did the sheet get restructured?`)
  const open = css.indexOf('{', match.index)
  const close = css.indexOf('\n}', open)
  const body = stripComments(css.slice(open + 1, close))
  const out = new Map<string, string>()
  for (const decl of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) {
    out.set(decl[1], decl[2].trim())
  }
  return out
}

const TOKENS = read('src/renderer/styles/tokens.css')
const LIGHT = cssVars(TOKENS, /^:root,\s*\n\[data-theme='light'\]\s*\{/m)
const DARK = cssVars(TOKENS, /^\[data-theme='dark'\]\s*\{/m)

/** A theme, plus the name to print when one of its values is the problem. */
const THEMES: ReadonlyArray<readonly [string, Map<string, string>]> = [
  ['light', LIGHT],
  ['dark', DARK],
]

/* ------------------------------------------------------------------ colour */

type Rgb = readonly [number, number, number]

function rgb(value: string): Rgb {
  const hex = /^#([0-9a-f]{6})$/i.exec(value.trim())
  if (hex) {
    const n = parseInt(hex[1], 16)
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
  }
  const fn = /^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)/i.exec(value.trim())
  if (fn) return [Number(fn[1]), Number(fn[2]), Number(fn[3])]
  throw new Error(`not a colour this test can read: ${value}`)
}

/** WCAG 2.x relative luminance. */
function luminance(colour: Rgb): number {
  const channel = (c: number): number => {
    const s = c / 255
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(colour[0]) + 0.7152 * channel(colour[1]) + 0.0722 * channel(colour[2])
}

/** WCAG 2.x contrast ratio, 1–21. AA for body text is 4.5. */
function contrast(a: string, b: string): number {
  const la = luminance(rgb(a))
  const lb = luminance(rgb(b))
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

/** Hue in degrees. Only meaningful for a colour with some saturation. */
function hue(colour: Rgb): number {
  const [r, g, b] = colour.map((c) => c / 255)
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  if (max === min) return 0
  const d = max - min
  const h =
    max === r ? ((g - b) / d + (g < b ? 6 : 0)) : max === g ? (b - r) / d + 2 : (r - g) / d + 4
  return h * 60
}

const get = (theme: Map<string, string>, name: string): string => {
  const value = theme.get(name)
  if (value === undefined) throw new Error(`${name} is missing from the sheet`)
  return value
}

/** Every surface a piece of text can land on, in one theme. */
const SURFACES = ['--bg-primary', '--bg-secondary', '--bg-tertiary', '--bg-sunken'] as const

/* ------------------------------------------------------- neutrality of grey */

describe('the greys are grey', () => {
  /**
   * Named surfaces and inks. Not the accent and not the status ramp — those
   * are meant to have a hue.
   */
  const NEUTRAL = [
    '--bg-primary',
    '--bg-secondary',
    '--bg-tertiary',
    '--bg-sunken',
    '--text-primary',
    '--text-secondary',
    '--text-muted',
    '--status-idle',
    '--tab-active',
    '--tab-inactive',
    '--bg-hover',
    '--bg-active',
    '--fill-quaternary',
    '--fill-tertiary',
    '--fill-secondary',
    '--border',
    '--border-subtle',
    '--border-strong',
    '--material-bg',
    '--material-bg-strong',
    '--material-hairline',
    '--terminal-bg',
    '--terminal-fg',
  ] as const

  for (const [name, theme] of THEMES) {
    for (const token of NEUTRAL) {
      it(`${name} ${token} has r = g = b`, () => {
        const [r, g, b] = rgb(get(theme, token))
        // Exact, not "close enough". The warm palette was only three levels
        // off neutral and it was visible across a full window, so a tolerance
        // here would permit precisely the bug this checks for.
        expect({ token, r, g, b }).toEqual({ token, r, g: r, b: r })
      })
    }
  }
})

/* ---------------------------------------------------------------- contrast */

describe('body text clears WCAG AA', () => {
  for (const [name, theme] of THEMES) {
    for (const ink of ['--text-primary', '--text-secondary', '--text-muted'] as const) {
      for (const surface of SURFACES) {
        it(`${name} ${ink} on ${surface}`, () => {
          expect(contrast(get(theme, ink), get(theme, surface))).toBeGreaterThanOrEqual(4.5)
        })
      }
    }
  }

  /**
   * The tiers have to be visibly apart, not merely all legible. Brief §3 asks
   * for a brighter title over a dimmer description, and that reads as a
   * hierarchy only if the two inks differ — three greys that all pass AA can
   * still be indistinguishable from each other.
   */
  for (const [name, theme] of THEMES) {
    it(`${name} title and description are separable`, () => {
      expect(contrast(get(theme, '--text-primary'), get(theme, '--text-secondary'))).toBeGreaterThan(
        1.8,
      )
    })
  }
})

describe('the accent clears WCAG AA', () => {
  for (const [name, theme] of THEMES) {
    for (const surface of SURFACES) {
      it(`${name} --accent is readable as text on ${surface}`, () => {
        expect(contrast(get(theme, '--accent'), get(theme, surface))).toBeGreaterThanOrEqual(4.5)
      })
    }

    /**
     * The whole accent ramp, because a button does not stop needing a readable
     * label while the pointer is over it. `--accent-press` is the step that had
     * no coverage anywhere: a first attempt at it in the dark theme darkened
     * the blue, which dropped the ink on a pressed button to 4.4:1.
     */
    for (const step of ['--accent', '--accent-dim', '--accent-press'] as const) {
      it(`${name} --accent-fg is readable on ${step}`, () => {
        expect(contrast(get(theme, '--accent-fg'), get(theme, step))).toBeGreaterThanOrEqual(4.5)
      })
    }
  }
})

describe('the status ramp clears WCAG AA on every surface of its theme', () => {
  const STATUS = [
    '--status-working',
    '--status-waiting',
    '--status-input',
    '--status-completed',
    '--status-idle',
    '--color-info',
    '--color-warning',
    '--color-critical',
    '--color-positive',
  ] as const

  for (const [name, theme] of THEMES) {
    for (const token of STATUS) {
      it(`${name} ${token}`, () => {
        // On every surface, not just the lightest. These are set as `color:` in
        // SetupSection.css, GitHubPanel.css and SearchPanel.css, and the panes
        // they appear in are not always the canvas.
        for (const surface of SURFACES) {
          expect({
            token,
            surface,
            ratio: contrast(get(theme, token), get(theme, surface)) >= 4.5,
          }).toEqual({ token, surface, ratio: true })
        }
      })
    }

    it(`${name} --text-onaccent is readable on the destructive button`, () => {
      // CloseSessionConfirm.css is the only user, and the one it has is the
      // button that throws away a running session.
      expect(
        contrast(get(theme, '--text-onaccent'), get(theme, '--color-critical')),
      ).toBeGreaterThanOrEqual(4.5)
    })
  }

  /**
   * `--badge-fg` is not in the list above because it is not measured against
   * the theme's surfaces — a count badge (`.sb-badge` in `shell.css`) is
   * always drawn on `--color-critical`, so that fill is the only background it
   * ever has. It gets its own check rather than an exemption.
   *
   * It was white in both appearances for a while, on the reasoning that
   * Apple's red count badges are white. Apple's red is dark enough to carry
   * white; the dark theme's is a light coral, and white on it measured about
   * 2.4:1 — a number a two-digit count does not survive. So the two themes now
   * disagree on purpose: white ink on the light theme's darker red, near-black
   * ink on the dark theme's brighter one.
   *
   * That disagreement is the thing most likely to be "tidied" back into a
   * single value by someone who sees two spellings of the same token and
   * assumes one is a mistake, which is why the direction is asserted and not
   * just the ratio: on each theme the badge ink is the *opposite* end of the
   * scale from that theme's own paper.
   */
  for (const [name, theme] of THEMES) {
    it(`${name} --badge-fg is readable on the count badge's fill`, () => {
      expect(
        contrast(get(theme, '--badge-fg'), get(theme, '--color-critical')),
      ).toBeGreaterThanOrEqual(4.5)
    })

    it(`${name} --badge-fg is ink for a bright fill, not a copy of the theme`, () => {
      // Light theme: dark paper-ink everywhere else, white on the badge.
      // Dark theme: light ink everywhere else, near-black on the badge.
      const badge = luminance(rgb(get(theme, '--badge-fg')))
      const body = luminance(rgb(get(theme, '--text-primary')))
      expect(name === 'light' ? badge > body : badge < body).toBe(true)
    })
  }

  it('--badge-fg is checked here rather than folded into the surface sweep', () => {
    // Guards the comment above: if someone adds it to STATUS it starts being
    // measured against surfaces it is never drawn on, and either fails for the
    // wrong reason or forces the real check out.
    expect(STATUS).not.toContain('--badge-fg')
  })
})

/* ------------------------------------------------------- the accent is ours */

describe('the accent is the application icon, not an invention', () => {
  const ICON = read('build/art/icon.mjs')
  const stop = (name: string): string => {
    const match = new RegExp(`${name}: hex\\('(#[0-9a-f]{6})'\\)`, 'i').exec(ICON)
    if (!match) throw new Error(`${name} is no longer declared in build/art/icon.mjs`)
    return match[1]
  }

  it('the dark accent is the icon spine, byte for byte', () => {
    // The point of taking it from the icon at all is that the Dock tile and the
    // window agree. An approximation would defeat that, so this is equality.
    expect(get(DARK, '--accent').toLowerCase()).toBe(stop('spineTop').toLowerCase())
  })

  it('the light accent is the same hue, darkened until it is readable', () => {
    const light = rgb(get(LIGHT, '--accent'))
    // Same hue line as the icon's lower stop — within a degree or two, which is
    // as close as an integer RGB triple can be held.
    expect(Math.abs(hue(light) - hue(rgb(stop('spineBottom'))))).toBeLessThan(3)
    // And genuinely darker, which is the only reason it is not simply the stop.
    expect(luminance(light)).toBeLessThan(luminance(rgb(stop('spineBottom'))))
  })

  it('the ramp moves one way per theme', () => {
    // Light darkens on hover and darkens further on press; dark brightens both
    // times, the way macOS tinted controls do. A ramp that reverses direction
    // mid-way reads as a glitch rather than a press.
    const l = (theme: Map<string, string>, n: string): number => luminance(rgb(get(theme, n)))
    expect(l(LIGHT, '--accent')).toBeGreaterThan(l(LIGHT, '--accent-dim'))
    expect(l(LIGHT, '--accent-dim')).toBeGreaterThan(l(LIGHT, '--accent-press'))
    expect(l(DARK, '--accent')).toBeLessThan(l(DARK, '--accent-dim'))
    expect(l(DARK, '--accent-dim')).toBeLessThan(l(DARK, '--accent-press'))
  })
})

/* ------------------------------------------- the hand-copied colours agree */

describe('every colour copied out of the sheet still matches it', () => {
  /**
   * Each of these is a place that cannot read a CSS variable. The comment at
   * every one of them asks the next person to keep it in step; every one of
   * them had already fallen out of step by the time this test was written.
   */
  const first = (rel: string, pattern: RegExp): string => {
    const match = pattern.exec(read(rel))
    if (!match) throw new Error(`${rel} no longer contains ${pattern} — has it been rewritten?`)
    return match[1].toLowerCase()
  }

  const darkBg = get(DARK, '--bg-primary').toLowerCase()
  const darkAccent = get(DARK, '--accent').toLowerCase()

  it('the window paints its pre-paint frame in the dark canvas colour', () => {
    // Otherwise launching, and every fast drag of a window edge, flashes a
    // colour the app never uses.
    expect(first('src/main/index.ts', /backgroundColor:\s*'(#[0-9a-f]{6})'/i)).toBe(darkBg)
  })

  it('the element picker highlights in the accent', () => {
    expect(first('src/main/browser-preload.ts', /HIGHLIGHT_BORDER = '(#[0-9a-f]{6})'/i)).toBe(
      darkAccent,
    )
  })

  it("xterm's fallbacks are the dark theme, not an older palette", () => {
    const term = 'src/renderer/components/TerminalView.tsx'
    expect(first(term, /token\('--terminal-bg',\s*'(#[0-9a-f]{6})'\)/i)).toBe(darkBg)
    expect(first(term, /token\('--terminal-fg',\s*'(#[0-9a-f]{6})'\)/i)).toBe(
      get(DARK, '--text-primary').toLowerCase(),
    )
    expect(first(term, /token\('--accent',\s*'(#[0-9a-f]{6})'\)/i)).toBe(darkAccent)
  })

  /**
   * The terminal's paper is its own token so the light theme can give the
   * session a surface that is not the chrome's — a white terminal on a white
   * toolbar is not a terminal, it is an empty document. In the *dark* theme
   * there is nothing to separate, so the two must stay identical, and they are
   * written as literal hex rather than as `var()` because the sweep above reads
   * these declarations as text. Two copies need a mechanism, so here it is.
   */
  it('the dark terminal is the dark canvas, written twice and checked once', () => {
    expect(get(DARK, '--terminal-bg').toLowerCase()).toBe(get(DARK, '--bg-primary').toLowerCase())
    expect(get(DARK, '--terminal-fg').toLowerCase()).toBe(get(DARK, '--text-primary').toLowerCase())
  })

  it('the light terminal is a surface of its own, and carries its ink', () => {
    const paper = get(LIGHT, '--terminal-bg')
    const ink = get(LIGHT, '--terminal-fg')
    expect(paper.toLowerCase(), 'a light terminal on the chrome white is not a terminal').not.toBe(
      get(LIGHT, '--bg-primary').toLowerCase(),
    )
    // Comfortably past AA: a terminal's whole promise is that the characters
    // are exact, so its ink is held to a higher bar than the app's body copy.
    expect(contrast(ink, paper)).toBeGreaterThan(7)
  })

  it('the phone client wears the same blue as the desktop', () => {
    // pwa/ is a separate document with its own sheet — there is no import path
    // between them, so this is the only thing holding the two in agreement.
    const pwa = cssVars(read('pwa/src/styles.css'), /^:root\s*\{/m)
    expect(get(pwa, '--accent').toLowerCase()).toBe(darkAccent)
    expect(get(pwa, '--accent-fg').toLowerCase()).toBe(get(DARK, '--accent-fg').toLowerCase())
    for (const token of ['--status-working', '--status-waiting', '--status-input'] as const) {
      expect(get(pwa, token).toLowerCase()).toBe(get(DARK, token).toLowerCase())
    }
  })

  it("the phone terminal selects in the accent, and leaves ANSI alone", () => {
    // Only the selection. `blue` and `brightBlue` in that table are ANSI slots
    // — a shell printing a blue prompt must not come out brand coloured — so
    // they are deliberately not checked against the accent.
    const rgbOf = (value: string): string => rgb(value).join(',')
    const selection = first(
      'pwa/src/terminal.ts',
      /selectionBackground: 'rgba\(([0-9]+, *[0-9]+, *[0-9]+), *[0-9.]+\)'/,
    )
    expect(rgbOf(`rgb(${selection})`)).toBe(rgbOf(darkAccent))
  })
})

/* --------------------------------------------------- no retired colour left */

describe('no retired accent survives anywhere', () => {
  /**
   * Asad's reason for moving off orange was that `#d97757` is Anthropic's own
   * brand colour and the product should not wear it. That is a claim about
   * every file, not about `tokens.css`, and the two stale copies found while
   * making the change are exactly why it is checked file by file rather than
   * assumed from the token sheet.
   */
  const RETIRED = [
    '#d97757', // Anthropic's orange, the previous dark accent
    '#b4552f', // its light-theme clay
    '#97431f',
    '#e28d71',
    '#c04a12', // --status-input, one shade off the same orange
    '#ef8b58',
    '#8588f2', // the purple-blue two palettes ago
    '#0e0f13', // and its near-black
    'rgba(30, 27, 22', // the warm shadow ink
    'rgba(58, 53, 45', // the warm light-theme fill ink
    'rgba(255, 250, 240', // the warm dark-theme tint
  ]

  /**
   * Not `pwa/src/terminal.ts`: it still contains `#529cca` as its ANSI `blue`,
   * which is correct and must stay. Its one brand colour — the selection — is
   * checked by name above instead.
   */
  const FILES = [
    'src/renderer/styles/tokens.css',
    'src/renderer/styles/app.css',
    'src/renderer/components/TerminalView.tsx',
    'src/renderer/settings/SettingsWindow.css',
    'src/main/index.ts',
    'src/main/browser-preload.ts',
    'pwa/src/styles.css',
  ]

  for (const file of FILES) {
    it(file, () => {
      // Comments are stripped first: the sheet quotes the retired values on
      // purpose, so that the next reader knows what was replaced and why.
      const code = stripComments(read(file)).toLowerCase()
      for (const colour of RETIRED) {
        expect({ file, colour, present: code.includes(colour) }).toEqual({
          file,
          colour,
          present: false,
        })
      }
    })
  }
})
