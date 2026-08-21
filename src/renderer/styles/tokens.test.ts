import { readdirSync, readFileSync } from 'node:fs'
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

/**
 * HSV saturation. Unchanged by a scale toward black, which is the point.
 *
 * At module scope because two derivations in this file are the same
 * derivation — the terminal's sixteen and the four binding colours are both a
 * dark value walked down one factor — and a second copy is how the two would
 * come to disagree about what "the same colour, darker" means.
 */
function saturation(colour: Rgb): number {
  const [r, g, b] = colour.map((c) => c / 255)
  const max = Math.max(r, g, b)
  return max === 0 ? 0 : (max - Math.min(r, g, b)) / max
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

    /*
     * The delete button under a pointer: red fill, white letters, both themes.
     *
     * Asad specified it twice and both times the same way — *"when I hover on
     * the delete it will have the white text and red color"* — and the pair
     * exists because one token could not be both. Asserted as *white*, not
     * merely as readable: the shipped bug satisfied the contrast rule with
     * near-black ink on a coral fill, which is exactly the reading this test
     * has to be able to fail.
     */
    it(`${name} the destructive fill is red under white ink`, () => {
      expect(get(theme, '--critical-fill-ink')).toBe('#ffffff')
      expect(
        contrast(get(theme, '--critical-fill-ink'), get(theme, '--critical-fill')),
      ).toBeGreaterThanOrEqual(4.5)
    })

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

/* ------------------------------------------------- the binding colours */

/**
 * The four colours a session's browser windows are marked with.
 *
 * They are new tokens rather than four the sheet already had, and the argument
 * for that rests on a fact about this file's own contents — so the fact is
 * asserted here rather than left in a comment. If somebody ever splits
 * `--color-info` from `--status-working`, the sheet gains a hue, and whoever
 * does it should be told that the paragraph in `tokens.css` justifying these
 * four has stopped being true.
 */
describe('the binding colours are four the sheet did not already have', () => {
  /** Pairs that are the *same hex under two names* in both theme blocks. */
  const ALIASES = [
    ['--color-info', '--status-working'],
    ['--color-warning', '--status-waiting'],
    ['--color-positive', '--status-completed'],
  ] as const

  for (const [name, theme] of THEMES) {
    for (const [a, b] of ALIASES) {
      it(`${name} ${a} is still the same colour as ${b}`, () => {
        expect(get(theme, a).toLowerCase()).toBe(get(theme, b).toLowerCase())
      })
    }
  }

  const BINDS = ['--bind-1', '--bind-2', '--bind-3', '--bind-4'] as const

  for (const [name, theme] of THEMES) {
    for (const token of BINDS) {
      it(`${name} ${token} clears AA on every surface of its theme`, () => {
        // Every surface, like the status ramp above: a chip is drawn on the
        // strip, on the rail and on a pane bar, which between them are three
        // different grounds, and the token has to be legible as ink too.
        for (const surface of SURFACES) {
          expect({
            token,
            surface,
            ratio: contrast(get(theme, token), get(theme, surface)) >= 4.5,
          }).toEqual({ token, surface, ratio: true })
        }
      })
    }

    it(`${name} --bind-fg is readable on all four chips`, () => {
      // `--badge-fg`'s rule, one shape along: a fill this bright takes the ink
      // from the opposite end of the theme, and the direction flips between the
      // two appearances. White on the dark chips measures about 2.4:1, which no
      // two-character chip survives.
      for (const token of BINDS) {
        expect({
          token,
          ok: contrast(get(theme, '--bind-fg'), get(theme, token)) >= 4.5,
        }).toEqual({ token, ok: true })
      }
    })

    it(`${name} --bind-fg is ink for a bright fill, not a copy of the theme`, () => {
      const chip = luminance(rgb(get(theme, '--bind-fg')))
      const body = luminance(rgb(get(theme, '--text-primary')))
      expect(name === 'light' ? chip > body : chip < body).toBe(true)
    })

    /**
     * Two hue-steps clear of the two colours that mean something urgent.
     *
     * The same separation rule the sheet already applies between
     * `--status-input` and `--status-waiting` — "a rust two hue-steps away…so
     * the two dots stay tellable apart at 7px", which is 19° on those values.
     * A binding is a benign fact about where a page opens; it must not be
     * mistaken for the app's one "act now" colour or for its primary action.
     */
    for (const token of BINDS) {
      for (const rival of ['--accent', '--status-input'] as const) {
        it(`${name} ${token} is not ${rival}'s hue`, () => {
          let apart = Math.abs(hue(rgb(get(theme, token))) - hue(rgb(get(theme, rival))))
          if (apart > 180) apart = 360 - apart
          expect({ token, rival, apart: apart >= 19 }).toEqual({ token, rival, apart: true })
        })
      }
    }
  }

  /**
   * The four are tellable apart from each other, which is the whole job.
   *
   * Four colours that each clear the checks above and sit 5° from one another
   * would pass everything else in this file and be useless on screen.
   */
  it('keeps the four apart from each other in both themes', () => {
    for (const [name, theme] of THEMES) {
      const hues = BINDS.map((token) => hue(rgb(get(theme, token))))
      for (let i = 0; i < hues.length; i += 1) {
        for (let j = i + 1; j < hues.length; j += 1) {
          let apart = Math.abs(hues[i] - hues[j])
          if (apart > 180) apart = 360 - apart
          expect({ theme: name, pair: [BINDS[i], BINDS[j]], ok: apart >= 40 }).toEqual({
            theme: name,
            pair: [BINDS[i], BINDS[j]],
            ok: true,
          })
        }
      }
    }
  })

  /**
   * The light four are the dark four walked down, not a second palette.
   *
   * The same derivation the terminal's sixteen are held to a few hundred lines
   * below: one scale factor across all three channels, which preserves hue and
   * HSV saturation and moves only lightness. A palette picked twice by eye would
   * drift on one or the other, and drifting means the violet session is a
   * different violet depending on the appearance.
   */
  it('walks each light binding colour down its own hue line', () => {
    for (const token of BINDS) {
      const l = rgb(get(LIGHT, token))
      const d = rgb(get(DARK, token))
      let drift = Math.abs(hue(l) - hue(d))
      if (drift > 180) drift = 360 - drift
      expect({ token, ok: drift < 2 }).toEqual({ token, ok: true })
      expect({ token, ok: Math.abs(saturation(l) - saturation(d)) < 0.01 }).toEqual({
        token,
        ok: true,
      })
      expect({ token, ok: luminance(l) <= luminance(d) }).toEqual({ token, ok: true })
    }
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

  /**
   * The selected tab is painted the surface it opens onto, and that surface is
   * the terminal's paper.
   *
   * This is the same class of bug as the copies above, except that the two
   * copies are both in this sheet. `--tab-active` was `#ffffff` — a hand-written
   * `--bg-primary` — and `--bg-primary` *is* `--terminal-bg` in the dark theme,
   * so the strip's Chrome-shaped tab, the session bar under it and the session
   * itself all matched there and the arrangement looked deliberate. In the light
   * theme the terminal is a recessed paper and the chrome is white, so the same
   * three surfaces were two colours, and the bar in the middle belonged to
   * neither: *"on dark mode it is actually the same, which I like. But on light
   * mode it is pure white, and inside the terminal itself it is a little bit
   * different, like kind of grey."*
   *
   * Asserted as equality between the two tokens rather than against a literal,
   * because the claim is not "the tab is #e8e8e8" — it is "the tab is whatever
   * the session under it is". Three sheets read `--tab-active` for exactly that
   * reason (`WorkspaceTabStrip.css`, `shell.css`, `BrowserWorkspace.css`), and
   * `shell.test.ts` checks that they still name the token rather than a colour
   * that currently equals it.
   */
  it('the selected tab is the surface it opens onto, in both appearances', () => {
    for (const [name, theme] of THEMES) {
      expect(get(theme, '--tab-active').toLowerCase(), name).toBe(
        get(theme, '--terminal-bg').toLowerCase(),
      )
    }
  })

  /**
   * And the strip it is cut out of is still not that surface.
   *
   * The other half of the instruction, and the one a fix for the seam above
   * could easily have run over: *"but the top header where we see the windows
   * is different, which is good, which I don't want to change."* The strip
   * wears `--material-bg`; if that ever equals the tab, the tab stops being a
   * cut-out and the top band stops being a band.
   *
   * Only the dark theme can be compared as a colour — the light `--material-bg`
   * is an rgba over the app's own gradient, so what it composites to is a
   * question for a screenshot and not for this file. `rgb()` reads its three
   * channels, which is enough to say the two are not the same grey.
   */
  it('the tab strip is still a different surface from the tab', () => {
    for (const [name, theme] of THEMES) {
      expect(rgb(get(theme, '--material-bg')), name).not.toEqual(rgb(get(theme, '--tab-active')))
    }
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

/* ----------------------------------------------------------- the ANSI set */

/**
 * The sixteen colours a program actually prints in, held to the same standard
 * as everything above.
 *
 * This is the part of the palette that had no mechanism at all, and it had none
 * because it had no *values*: `terminalTheme()` handed xterm a background, a
 * foreground, a cursor and a selection, and left the sixteen to whatever
 * `@xterm/xterm` ships. In the dark theme that was harmless — the emulator's
 * Tango defaults were drawn for a near-black ground and `--terminal-bg` is one.
 * In the light theme it was the whole of the appearance being wrong: the same
 * dark-ground set on `#e8e8e8` paper measured 2.05:1 for yellow, 1.32:1 for
 * bright green and 1.01:1 for bright yellow, which is a program colouring its
 * output and the window printing nothing.
 *
 * So the numbers below are the point. A palette is the one part of a design
 * where "looks fine" is a genuinely unreliable instrument: bright yellow on
 * paper looked like nothing at all, which reads as "no output" rather than as
 * "bad colour", and the fault therefore survived every time anyone looked at
 * the window. A ratio does not survive it.
 */
describe('the terminal renders sixteen colours this app chose', () => {
  /** Token name, and the `ITheme` key it is handed to xterm as. */
  const ANSI: ReadonlyArray<readonly [string, string]> = [
    ['--ansi-black', 'black'],
    ['--ansi-red', 'red'],
    ['--ansi-green', 'green'],
    ['--ansi-yellow', 'yellow'],
    ['--ansi-blue', 'blue'],
    ['--ansi-magenta', 'magenta'],
    ['--ansi-cyan', 'cyan'],
    ['--ansi-white', 'white'],
    ['--ansi-bright-black', 'brightBlack'],
    ['--ansi-bright-red', 'brightRed'],
    ['--ansi-bright-green', 'brightGreen'],
    ['--ansi-bright-yellow', 'brightYellow'],
    ['--ansi-bright-blue', 'brightBlue'],
    ['--ansi-bright-magenta', 'brightMagenta'],
    ['--ansi-bright-cyan', 'brightCyan'],
    ['--ansi-bright-white', 'brightWhite'],
  ]

  /**
   * The two ends of the ramp, by wire number.
   *
   * White and bright white are excluded from every readability check below,
   * and the exclusion is the honest part of this palette rather than a hole in
   * the test. An ANSI colour is used as a *background* as often as a
   * foreground — darkening these two would turn `ESC[47m` from a highlight
   * into a black band — so on paper they stay near-white and are unreadable as
   * text, at 1.19:1 and 1.05:1. Every light terminal scheme in use makes the
   * same trade. What a program that wants the ordinary foreground says is
   * `ESC[39m`, which is `--terminal-fg` and is checked above at better than
   * 7:1.
   */
  const WHITE = 7
  const BRIGHT_WHITE = 15

  /** Straight-line distance in sRGB. A crude metric, and enough to catch two
   *  slots that have landed on the same colour. */
  const apart = (a: Rgb, b: Rgb): number =>
    Math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)

  const light = (index: number): string => get(LIGHT, ANSI[index][0])
  const dark = (index: number): string => get(DARK, ANSI[index][0])

  it('declares all sixteen in both appearances', () => {
    for (const [token] of ANSI) {
      expect({ token, light: LIGHT.has(token), dark: DARK.has(token) }).toEqual({
        token,
        light: true,
        dark: true,
      })
    }
  })

  /**
   * The dark set is what the app has always rendered, pinned as literals.
   *
   * These are `@xterm/xterm`'s own defaults, which is what a session in this
   * window looked like before the sheet declared anything. Writing them down
   * changes nothing on screen and that is the claim being made: the light
   * theme got a palette, the dark theme kept the one it had. Pinned by value
   * rather than read back out of `node_modules`, because the emulator's
   * default is no longer what this app renders — it is only where these came
   * from — and a test that followed the dependency would turn an upstream
   * retune into a silent change of the product's own colours.
   */
  it('keeps the dark sixteen exactly as the app has always rendered them', () => {
    expect(ANSI.map(([token]) => get(DARK, token).toLowerCase())).toEqual([
      '#2e3436',
      '#cc0000',
      '#4e9a06',
      '#c4a000',
      '#3465a4',
      '#75507b',
      '#06989a',
      '#d3d7cf',
      '#555753',
      '#ef2929',
      '#8ae234',
      '#fce94f',
      '#729fcf',
      '#ad7fa8',
      '#34e2e2',
      '#eeeeec',
    ])
  })

  /**
   * Every one of them actually reaches the emulator.
   *
   * The defect this whole section exists for was not a wrong colour, it was
   * sixteen colours that were never passed — so the check that matters most is
   * the plumbing one, and it is the one a reviewer looking at a swatch cannot
   * make. Each slot has to be named in `terminalTheme()`, read from its token,
   * and carry the dark theme's own value as the fallback for the boot where
   * the sheet has not been applied yet.
   */
  it('hands xterm every one of them, with the dark theme as the fallback', () => {
    const source = read('src/renderer/components/TerminalView.tsx')
    for (const [token, slot] of ANSI) {
      const pattern = new RegExp(`\\b${slot}: token\\('${token}', *'(#[0-9a-f]{6})'\\)`, 'i')
      const match = pattern.exec(source)
      expect(match, `${slot} is not handed to xterm from ${token}`).not.toBeNull()
      expect(match![1].toLowerCase(), `${slot}'s fallback has drifted from the dark theme`).toBe(
        get(DARK, token).toLowerCase(),
      )
    }
  })

  /**
   * The light sixteen are the dark sixteen walked down, not a second palette.
   *
   * The transform is a scale of all three channels toward black by one factor,
   * which in arithmetic preserves hue and HSV saturation exactly and moves
   * only value. Both are asserted because both are what makes this a *derived*
   * set: a palette picked by eye would drift on one or the other, and drifting
   * means red stops being the red the dark theme shows.
   *
   * Two degrees rather than zero, and a hundredth of saturation rather than
   * nothing, because the channels are eight-bit and the factor is not. Thirteen
   * of the sixteen land dead on; the worst is bright magenta at 1.72°, which is
   * rounding — it is the palest and least saturated of the nine that move, so
   * half a level on a channel is a wider angle there than anywhere else.
   */
  it('walks each light colour down its own hue line', () => {
    for (let i = 0; i < ANSI.length; i += 1) {
      const l = rgb(light(i))
      const d = rgb(dark(i))
      if (saturation(d) < 0.02) continue // a grey has no hue to preserve
      let drift = Math.abs(hue(l) - hue(d))
      if (drift > 180) drift = 360 - drift
      expect({ slot: ANSI[i][1], ok: drift < 2 }).toEqual({ slot: ANSI[i][1], ok: true })
      expect({ slot: ANSI[i][1], ok: Math.abs(saturation(l) - saturation(d)) < 0.01 }).toEqual({
        slot: ANSI[i][1],
        ok: true,
      })
    }
  })

  it('never walks a light colour upward', () => {
    // Down or nowhere. Red, blue and magenta already clear AA on this paper, so
    // three of the sixteen are byte identical in both appearances — that is the
    // derivation being honest rather than a copy-paste slip, and it is asserted
    // as "not lighter" rather than "darker" so it stays true.
    for (let i = 0; i < ANSI.length; i += 1) {
      expect({
        slot: ANSI[i][1],
        ok: luminance(rgb(light(i))) <= luminance(rgb(dark(i))),
      }).toEqual({ slot: ANSI[i][1], ok: true })
    }
  })

  /**
   * The normal eight are readable as text on the light terminal's paper.
   *
   * AA, the same bar the rest of this sheet is held to. They were derived
   * against 4.6:1 rather than 4.5 to leave the eight-bit rounding somewhere to
   * land; the assertion is the standard's number, because that is the claim —
   * the extra tenth is headroom, not a promise.
   */
  it('clears AA for every normal colour on the light paper', () => {
    const paper = get(LIGHT, '--terminal-bg')
    for (let i = 0; i < 8; i += 1) {
      if (i === WHITE) continue
      const ratio = contrast(light(i), paper)
      expect({ slot: ANSI[i][1], ok: ratio >= 4.5, ratio: Number(ratio.toFixed(2)) }).toEqual({
        slot: ANSI[i][1],
        ok: true,
        ratio: Number(ratio.toFixed(2)),
      })
    }
  })

  /**
   * And the chromatic brights clear AAA, deliberately higher.
   *
   * On a dark ground "bright" means further from the ground, i.e. lighter; on
   * paper the same idea is darker. Give both ends the same target and they
   * collapse onto each other — at a shared 4.6:1, green lands on #3b7405 and
   * bright green on #46721a, eleven levels apart in red and twenty-one in blue,
   * which a diff draws as one colour. So the brights are walked further, and
   * the separation that buys is asserted below rather than assumed.
   *
   * Bright black is not in this range: it keeps its place on the ramp as the
   * dim grey a TUI draws its comments and box-drawing in, and darkening it to
   * 7:1 would have taken it past black and inverted the pair.
   */
  it('clears AAA for every chromatic bright colour on the light paper', () => {
    const paper = get(LIGHT, '--terminal-bg')
    for (let i = 9; i < 15; i += 1) {
      const ratio = contrast(light(i), paper)
      expect({ slot: ANSI[i][1], ok: ratio >= 7, ratio: Number(ratio.toFixed(2)) }).toEqual({
        slot: ANSI[i][1],
        ok: true,
        ratio: Number(ratio.toFixed(2)),
      })
    }
  })

  it('keeps black and bright black in their places, and in that order', () => {
    // Both already clear on paper — 10.32:1 and 5.96:1 — so neither moves, and
    // the pair must not invert: bright black is the *lighter* of the two, which
    // is what makes it the quiet one.
    expect(light(0).toLowerCase()).toBe(dark(0).toLowerCase())
    expect(light(8).toLowerCase()).toBe(dark(8).toLowerCase())
    for (const [name, theme] of THEMES) {
      const paper = get(theme, '--terminal-bg')
      expect(contrast(get(theme, '--ansi-bright-black'), paper), name).toBeGreaterThan(
        name === 'light' ? 4.5 : 2,
      )
      expect(
        luminance(rgb(get(theme, '--ansi-black'))) <
          luminance(rgb(get(theme, '--ansi-bright-black'))),
        name,
      ).toBe(true)
    }
  })

  /**
   * White and bright white are the same in both appearances, on purpose.
   *
   * See the note on `WHITE` above: these two are backgrounds as often as they
   * are foregrounds, so on paper they stay near-white and are not readable as
   * text. This asserts the *decision* rather than a ratio — if someone darkens
   * them to make `ESC[37m` readable, this fails and points them at the trade
   * they are about to make on the other side of it.
   */
  it('leaves white and bright white alone in both appearances', () => {
    for (const i of [WHITE, BRIGHT_WHITE]) {
      expect(light(i).toLowerCase(), ANSI[i][1]).toBe(dark(i).toLowerCase())
    }
  })

  it('keeps normal and bright tellable apart on paper', () => {
    // The other half of the two-target rule. Six chromatic pairs; black and
    // white are the ends of the ramp and are argued about above.
    for (let i = 1; i < 7; i += 1) {
      const distance = apart(rgb(light(i)), rgb(light(i + 8)))
      expect({ slot: ANSI[i][1], ok: distance > 25 }).toEqual({ slot: ANSI[i][1], ok: true })
    }
  })

  /**
   * The phone renders the same sixteen.
   *
   * Same class of problem as the accent check above, and worse in kind: the
   * phone's emulator is SwiftTerm, whose own default palette is Apple
   * Terminal's rather than Tango's, so one session used to have two colour
   * schemes depending on which screen it was read on — a #3465a4 blue on the
   * Mac and a #492ee1 blue on the phone. There is no import path between a
   * stylesheet and a Swift file, so this is the only thing holding them
   * together, and the direction is deliberate: the desktop declares, the phone
   * mirrors.
   */
  it('the phone mirrors the desktop set, in both appearances', () => {
    const swift = read('ios/TerminalDeck/App/Theme.swift')
    const header = 'static let ansi: [Duo] = ['
    const start = swift.indexOf(header)
    expect(
      start,
      'Ink.ansi is no longer a literal table — has Theme.swift been restructured?',
    ).toBeGreaterThan(-1)
    // From past the header's own `[Duo] = [`, or the slice ends on the bracket
    // in the type rather than on the one that closes the table.
    const open = start + header.length
    const table = swift.slice(open, swift.indexOf(']', open))
    const rows = [
      ...table.matchAll(/Duo\(light: Shade\(0x([0-9a-f]{6})\), dark: Shade\(0x([0-9a-f]{6})\)\)/gi),
    ]
    expect(rows.length, 'the phone no longer declares sixteen ANSI colours').toBe(ANSI.length)
    for (let i = 0; i < ANSI.length; i += 1) {
      expect(`#${rows[i][1].toLowerCase()}`, `${ANSI[i][1]} light`).toBe(light(i).toLowerCase())
      expect(`#${rows[i][2].toLowerCase()}`, `${ANSI[i][1]} dark`).toBe(dark(i).toLowerCase())
    }
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

/* ------------------------------------------------------------ flat chrome */

/**
 * The dark theme's chrome is one colour, top to bottom.
 *
 * The sidebar and the toolbar are `--material-bg` painted with
 * `--material-sheen`, over the app's own radial gradient. In the dark theme
 * those three composited to a 23-level ramp down the height of the rail —
 * *"lighter at the top, near-black by the footer"* — while the light theme was
 * already flat, because a white sheen over near-white paper composites to
 * near-white paper.
 *
 * Two claims, because either one alone leaves the surface almost flat, which
 * reads as a rendering fault rather than as a choice: the fill is opaque, so
 * nothing shows through it, and the sheen paints nothing on top of it.
 */
describe('the dark chrome is flat', () => {
  const dark = THEMES.find(([name]) => name === 'dark')?.[1]
  const light = THEMES.find(([name]) => name === 'light')?.[1]

  it('paints the rail and the toolbar with an opaque fill', () => {
    // Translucent, and the app's `radial-gradient(… --bg-secondary … --bg-sunken)`
    // shows through it — which is half of the ramp on its own.
    expect(get(dark!, '--material-bg')).not.toMatch(/rgba|transparent/)
  })

  it('paints no gradient over it', () => {
    expect(get(dark!, '--material-sheen')).toBe('none')
  })

  it('leaves the light theme exactly as it was', () => {
    // A dark-only regression gets a dark-only fix. The light sheen is what
    // makes a white dialog read as glass over white paper.
    expect(get(light!, '--material-sheen')).toContain('linear-gradient')
    expect(get(light!, '--material-bg')).toContain('rgba')
  })

  it('keeps the chrome distinguishable from the canvas without a line', () => {
    // Separate with space, then with a tint, and only then with a line. The
    // rail is a tint above the canvas; if the two ever meet, the only thing
    // left marking the edge is a hairline, which is the outcome the brief
    // spends a paragraph avoiding.
    expect(get(dark!, '--material-bg')).not.toBe(get(dark!, '--bg-primary'))
  })
})

/* --------------------------------------------------------- visible selection */

/**
 * You can see which row is selected.
 *
 * In the dark theme you could not. `--bg-active` was `rgba(255,255,255,0.095)`,
 * which over the settings rail composites to about twenty levels of separation
 * — a number that sounds like something and looks, at 3× zoom on the real
 * screen, like a gap in the list where the current section should be. Every
 * selected row in the window uses this one token, so all of them were equally
 * faint: the sidebar's session, the file tree, the git row, the palette.
 *
 * Measured as a composite rather than as an alpha, because the alpha on its own
 * says nothing — 0.095 white is invisible on one surface and loud on another.
 * What matters is the step it makes on the surface it is actually painted on.
 *
 * The numeric floor is asserted for the **dark** theme only, and that is not
 * the test going easy on the other one. A light selection *darkens* paper, and
 * the same absolute step is far more visible going down from near-white than
 * going up from near-black — which is exactly why this was a dark-only fault
 * and why holding the light theme to a dark theme's number would force a
 * selection nobody asked for. What the light theme is held to is the thing that
 * would actually be a bug there: that its selection darkens at all.
 */
describe('the selected row is visible on the surface it sits on', () => {
  /** `rgba(r, g, b, a)` over an opaque base, as an opaque colour. */
  const over = (tint: string, base: string): number => {
    const parts = /rgba?\(([^)]+)\)/.exec(tint)
    if (!parts) throw new Error(`${tint} is not an rgba() value`)
    const [r, , , a = '1'] = parts[1].split(',').map((piece) => piece.trim())
    const alpha = Number(a)
    const [br] = rgb(base)
    return Math.round(Number(r) * alpha + br * (1 - alpha))
  }

  /** The chrome each theme actually paints a selected row on: `--material-bg`. */
  const RAIL: Record<string, string> = { light: '#fafafa', dark: '#212121' }

  const dark = THEMES.find(([name]) => name === 'dark')?.[1]
  const light = THEMES.find(([name]) => name === 'light')?.[1]

  it('dark selection is at least 24 levels off the rail', () => {
    const step = Math.abs(over(get(dark!, '--bg-active'), RAIL.dark) - rgb(RAIL.dark)[0])
    // 0.095 gave 21. The regression is a number just short of visible, so the
    // floor is written as a number rather than as "looks fine".
    expect({ step, ok: step >= 24 }).toEqual({ step, ok: true })
  })

  it('dark selection is clearly stronger than dark hover', () => {
    // Otherwise the pointer alone looks like the selection, which is the other
    // half of "you cannot tell where you are".
    const selected = over(get(dark!, '--bg-active'), RAIL.dark)
    const hovered = over(get(dark!, '--bg-hover'), RAIL.dark)
    expect({ apart: selected - hovered >= 12 }).toEqual({ apart: true })
  })

  it('light selection darkens the paper, and is stronger than its own hover', () => {
    const rail = rgb(RAIL.light)[0]
    const selected = over(get(light!, '--bg-active'), RAIL.light)
    const hovered = over(get(light!, '--bg-hover'), RAIL.light)
    expect(selected).toBeLessThan(rail)
    expect(selected).toBeLessThan(hovered)
  })
})

/* --------------------------------------------------------------- type scale */

/**
 * The type ladder, checked as claims for the same reason the palette above is.
 *
 * This file's prologue is about colour and its argument is not: *a value that is
 * described correctly in a comment and written incorrectly in the code*. A size
 * fails that way as readily as a hex does, and it fails wider — every screen in
 * this app is drawn on ten numbers, so a size that lands in the wrong place is
 * not one screen looking odd, it is the chrome and the terminal disagreeing
 * about how big the product is.
 *
 * ## What is being pinned, and why
 *
 * Asad, 2026-08-21, with Settings → Appearance open at 14: *"at least this much
 * of size like we have inside, I want to increase app for everything, for
 * overall the application also, a little bit, not too much, but a little bit."*
 *
 * Three claims in that sentence, one test each. The chrome must be **at least**
 * the size of the terminal text, or the complaint stands. It must be larger
 * **everywhere**, which means the ladder moved as a ladder rather than body
 * being lifted into title3's lap. And it must not be the *terminal* that moved
 * — that number is a person's own setting and it is nowhere in this sheet.
 *
 * The fourth test keeps the answer to "where is the knob" true: the whole
 * renderer draws type from these ten tokens, so the next notch is one edit
 * rather than an archaeology of one screen at a time.
 */
describe('the app type scale reaches the terminal it sits around', () => {
  /** The rungs, largest first, as the sheet writes them. */
  const LADDER = [
    '--t-largetitle',
    '--t-title1',
    '--t-title2',
    '--t-title3',
    '--t-headline',
    '--t-body',
    '--t-callout',
    '--t-subhead',
    '--t-footnote',
    '--t-caption',
  ] as const

  /**
   * The shared `:root`, which is where type lives.
   *
   * Sizes are not a theme — the light and dark rules carry colour only — so this
   * is deliberately not read through `THEMES` like everything above it. The bare
   * `:root {` is the shared block; the sheet's first rule is `:root,` with the
   * light theme beside it, which this pattern does not match.
   */
  const SHARED = cssVars(TOKENS, /^:root \{/m)

  /** One rung, in pixels. */
  const px = (token: string): number => {
    const raw = SHARED.get(token)
    if (raw === undefined) throw new Error(`${token} is not in the shared :root any more`)
    const match = /^([\d.]+)px$/.exec(raw)
    if (!match) throw new Error(`${token} is ${raw}, which this test cannot measure`)
    return Number(match[1])
  }

  /** Every stylesheet the renderer ships, so the inventory below cannot be partial. */
  const cssFiles = (): string[] => {
    const out: string[] = []
    const walk = (dir: string): void => {
      for (const entry of readdirSync(join(ROOT, dir), { withFileTypes: true })) {
        const rel = `${dir}/${entry.name}`
        if (entry.isDirectory()) walk(rel)
        else if (entry.name.endsWith('.css')) out.push(rel)
      }
    }
    walk('src/renderer')
    return out.sort()
  }

  it('sets body at least as large as an untouched terminal', () => {
    /*
     * The default is read out of `TerminalView.tsx` as text rather than
     * imported, because importing it pulls xterm into a run that has no DOM. It
     * is the number the window actually builds xterm with.
     */
    const terminal = /DEFAULT_TERMINAL_FONT_SIZE = (\d+)/.exec(
      read('src/renderer/components/TerminalView.tsx'),
    )
    expect(terminal, 'TerminalView no longer states a default font size').not.toBeNull()
    expect(px('--t-body')).toBeGreaterThanOrEqual(Number(terminal![1]))
    /*
     * And it is 14 specifically, which is the size on screen in the frame he
     * stopped on. Clearing the 13px default alone would leave the chrome smaller
     * than the terminal on his own machine, which is the whole complaint.
     */
    expect(px('--t-body')).toBe(14)
  })

  it('moved the whole ladder, not just the rung he pointed at', () => {
    /*
     * *"for everything, for overall the application also."* Lifting body alone
     * would put a heading and the line beneath it at one size on every settings
     * page, so each rung sits one notch above the HIG number it used to hold —
     * 26/22/17/15/13/13/12/11.5/11/10.5 — at the same 14/13 proportion.
     */
    expect(LADDER.map(px)).toEqual([28, 24, 18, 16, 14, 14, 13, 12.5, 12, 11.5])

    /*
     * And by the rule the sheet states, rather than by ten numbers somebody
     * typed: each rung is its old size × 14/13, rounded to the nearest whole
     * pixel from title3 up and to the nearest half below it — which is the grid
     * the old ladder already sat on. Written out so the *next* notch can be
     * taken the same way and checked the same way.
     */
    const WAS = [26, 22, 17, 15, 13, 13, 12, 11.5, 11, 10.5]
    const derived = WAS.map((size, index) => {
      const scaled = (size * 14) / 13
      return index <= 3 ? Math.round(scaled) : Math.round(scaled * 2) / 2
    })
    expect(LADDER.map(px)).toEqual(derived)
  })

  it('keeps the ladder a ladder, with no two rungs crossed', () => {
    // A scale is a set of relations, and this is what a partial edit trips on:
    // one screen patched, one token nudged, two rungs now equal or inverted.
    const sizes = LADDER.map(px)
    for (let i = 1; i < sizes.length; i += 1) {
      expect({ rung: LADDER[i], ordered: sizes[i] <= sizes[i - 1] }).toEqual({
        rung: LADDER[i],
        ordered: true,
      })
    }
    // Headline and body are one size at two weights, in the HIG and here.
    expect(px('--t-headline')).toBe(px('--t-body'))
  })

  it('leaves the terminal’s own size alone, because it is somebody’s setting', () => {
    /*
     * The two knobs are separate and stay separate: this sheet dresses the
     * chrome, and `appearance.terminalFontSize` is a number a person chose for
     * the text inside their sessions. He was not asking for the 14 to change; he
     * was asking for everything around it to catch up.
     */
    const entry =
      /id: 'appearance\.terminalFontSize'[\s\S]*?\n {2}\}/.exec(
        read('src/renderer/settings/settings-schema.ts'),
      )?.[0] ?? ''
    expect(entry, 'the terminal font size setting has changed shape').not.toBe('')
    expect(entry).toContain('default: 13')
    expect(read('src/renderer/components/TerminalView.tsx')).toContain(
      'DEFAULT_TERMINAL_FONT_SIZE = 13',
    )
    /*
     * And no terminal reads a chrome rung. If one ever did, changing the app's
     * scale would silently resize somebody's shell — which is the one outcome
     * this whole pass had to avoid.
     */
    for (const file of [
      'src/renderer/components/TerminalView.tsx',
      'src/renderer/machines/RemoteTerminal.tsx',
      'src/renderer/machines/servers/ServerTerminal.tsx',
    ]) {
      expect(read(file), `${file} reads a chrome type token`).not.toMatch(/--t-[a-z]/)
    }
  })

  it('draws the whole renderer from those ten tokens, so the next notch is one edit', () => {
    /*
     * The reason a scale change is ten lines rather than a survey. Every
     * `font-size` in the renderer either names a rung or is one of the five
     * below, and each of those is a size measured against something that is
     * *not* the ladder — a fixed circle, or the line it sits inside.
     *
     * Kept as an inventory rather than a ban, in the same spirit as
     * `verbatim.css`: the right answer to a literal is nearly always a rung, and
     * the way to keep that true is to make adding one to this list a deliberate
     * act with a line of reasoning beside it.
     *
     * It caught two the first time it ran. `.servers-setup-heading` read
     * `font-size: var(--text-sm)` and `.readiness-touches` read
     * `var(--t-caption-2)`, and neither token has ever existed in this app. An
     * undefined custom property is not an error, it is an invalid value at
     * computed-value time — so both declarations did nothing, both rows took
     * whatever they inherited, and both looked close enough to deliberate that
     * nobody had noticed. That is the exact failure mode this file's prologue is
     * about, in a size rather than a colour.
     *
     * Which is also why the check is `var(--t-…)` by name rather than "is it a
     * `var()`": a variable that does not resolve is indistinguishable from a
     * missing declaration on screen, and a spelling test is the only thing that
     * separates them.
     */
    const ALLOWED = new Map<string, string>([
      ['src/renderer/styles/app.css:10px', 'the binding chip, sized to a 15px chip'],
      [
        'src/renderer/browser/BrowserWorkspace.css:10px',
        'the profile initial, sized to an 18px circle',
      ],
      [
        'src/renderer/browser/BrowserWorkspace.css:9px',
        'the downloads badge, sized to the 13px pill it sits in',
      ],
      ['src/renderer/shell/shell.css:0.92em', 'a nested line, a shade under its parent'],
      ['src/renderer/components/ChatView.css:0.86em', 'code inside a chat line'],
      ['src/renderer/settings/SettingsWindow.css:inherit', 'a control taking the row it is on'],
    ])
    const stray: string[] = []
    for (const file of cssFiles()) {
      for (const decl of stripComments(read(file)).matchAll(/font-size:\s*([^;]+);/g)) {
        const value = decl[1].trim()
        if (/^var\(--t-[a-z0-9]+\)$/.test(value)) continue
        if (ALLOWED.has(`${file}:${value}`)) continue
        stray.push(`${file}: font-size: ${value}`)
      }
    }
    expect(stray).toEqual([])
  })
})
