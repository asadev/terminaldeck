import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/**
 * Both palettes of the browser client, checked as claims rather than admired as
 * swatches.
 *
 * `src/renderer/styles/tokens.test.ts` does this for the desktop and explains
 * why at length; this is the same mechanism for the sheet the desktop cannot
 * see. It exists because light mode arrived here with four copies of one
 * palette in three files — the stylesheet's media query, the stylesheet's
 * `[data-theme='light']` rule, xterm's colour object, and the `theme-color`
 * meta — and every one of them is a colour that has to agree with the others and
 * cannot import them.
 *
 * Three kinds of claim:
 *
 *  1. **The copies agree.** The two light blocks are one palette written twice
 *     (CSS cannot say "these two selectors, one of them only inside a media
 *     query"), and the terminal's paper is written once in CSS and once in
 *     TypeScript.
 *  2. **Text is readable.** Every ink over every surface, in both appearances.
 *     The failure this catches is the one that makes a light theme look broken:
 *     values carried over from the dark palette that measure 1.4:1 on paper.
 *  3. **The terminal changes with the page.** The sixteen ANSI slots are a real
 *     light ramp and not the dark one on a pale ground — a black terminal in a
 *     white window is the specific thing this feature is judged on.
 */

const read = (rel: string): string => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')

const STYLES = read('../src/styles.css')
const TERMINAL = read('../src/terminal.ts')
const THEME = read('../src/theme.ts')

/** Source with comment bodies removed, so a quoted old value cannot be read as live. */
const stripComments = (text: string): string =>
  text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')

/**
 * The custom properties declared by the first rule matching `selector`.
 *
 * The block ends at the first `}` at the start of a line *or* indented by two
 * spaces, which covers both the top-level rules and the one nested inside the
 * `prefers-color-scheme` query. No rule in this sheet nests further, and the
 * only parentheses in a value belong to `rgba()` and `env()`.
 */
function cssVars(selector: RegExp): Map<string, string> {
  const match = selector.exec(STYLES)
  if (!match) throw new Error(`no rule matching ${selector} — has the sheet been restructured?`)
  const open = STYLES.indexOf('{', match.index)
  const close = STYLES.indexOf('\n  }', open) === -1 ? STYLES.indexOf('\n}', open) : Math.min(...[STYLES.indexOf('\n  }', open), STYLES.indexOf('\n}', open)].filter((at) => at > open))
  const body = stripComments(STYLES.slice(open + 1, close))
  const out = new Map<string, string>()
  for (const decl of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) out.set(decl[1], decl[2].trim())
  return out
}

const DARK = cssVars(/^:root \{/m)
const LIGHT = cssVars(/^:root\[data-theme='light'\] \{/m)
const FIRST_PAINT = cssVars(/^ {2}:root:not\(\[data-theme\]\) \{/m)

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

function contrast(a: string, b: string): number {
  const la = luminance(rgb(a))
  const lb = luminance(rgb(b))
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

const get = (theme: Map<string, string>, name: string): string => {
  const value = theme.get(name)
  if (value === undefined) throw new Error(`${name} is missing from that block`)
  return value
}

const THEMES: ReadonlyArray<readonly [string, Map<string, string>]> = [
  ['dark', DARK],
  ['light', LIGHT],
]

/** Every surface a piece of text lands on in this client. */
const SURFACES = ['--bg-primary', '--bg-secondary', '--bg-tertiary'] as const

/* ------------------------------------------------------------- the copies */

describe('the two light blocks are one palette', () => {
  /*
   * They exist twice because CSS has no way to say "this rule, and also this
   * rule but only inside a media query" with one body. The media-query copy is
   * what paints the first frame on a light machine, before `theme.ts` has
   * stamped anything; the other is the light theme proper and has to beat a dark
   * system when somebody chose light. A drift between them is invisible in a
   * diff and shows up as one colour changing when the page is reloaded.
   */
  it('declares exactly the same tokens', () => {
    expect([...FIRST_PAINT.keys()].sort()).toEqual([...LIGHT.keys()].sort())
  })

  it('declares exactly the same values', () => {
    for (const [token, value] of LIGHT) {
      expect({ token, value: FIRST_PAINT.get(token) }).toEqual({ token, value })
    }
  })

  it('stands down as soon as an appearance has been stamped', () => {
    // `:not([data-theme])`, not `:root` and not `:not([data-theme='light'])`.
    // The first would fight an explicit dark on a light machine and win, which
    // is the whole reason the guard is written this way.
    expect(stripComments(STYLES)).toContain(':root:not([data-theme]) {')
  })
})

describe('every theme carries every token', () => {
  it('defines the light palette for every colour the dark one has', () => {
    // The rule the desktop's sheet states as "both themes are first-class: never
    // define a colour only inside one of them". A token that exists in one theme
    // and not the other is a surface that keeps its old colour when the page
    // flips, which is the sort of thing that only shows up on a screenshot.
    const colours = [...DARK.keys()].filter((token) => /^--(bg|text|accent|border|status|color|terminal)/.test(token))
    for (const token of colours) {
      expect({ token, inLight: LIGHT.has(token) }).toEqual({ token, inLight: true })
    }
  })
})

/* ---------------------------------------------------------------- contrast */

describe('body text clears WCAG AA in both appearances', () => {
  for (const [name, theme] of THEMES) {
    for (const ink of ['--text-primary', '--text-secondary', '--text-muted'] as const) {
      for (const surface of SURFACES) {
        it(`${name} ${ink} on ${surface}`, () => {
          expect(contrast(get(theme, ink), get(theme, surface))).toBeGreaterThanOrEqual(4.5)
        })
      }
    }

    it(`${name} the accent is readable as text, and carries its own ink`, () => {
      for (const surface of SURFACES) {
        expect(contrast(get(theme, '--accent'), get(theme, surface))).toBeGreaterThanOrEqual(4.5)
      }
      // The one primary button on every screen of this client.
      expect(contrast(get(theme, '--accent-fg'), get(theme, '--accent'))).toBeGreaterThanOrEqual(4.5)
    })

    it(`${name} the status ramp stays legible on every surface`, () => {
      for (const token of [
        '--status-working',
        '--status-waiting',
        '--status-input',
        '--status-completed',
        '--status-idle',
        '--color-critical',
      ] as const) {
        for (const surface of SURFACES) {
          expect({
            token,
            surface,
            ok: contrast(get(theme, token), get(theme, surface)) >= 4.5,
          }).toEqual({ token, surface, ok: true })
        }
      }
    })
  }
})

/* ---------------------------------------------------------------- terminal */

/** One `ITheme` object in `terminal.ts`, read as text. */
function terminalTheme(name: string): Map<string, string> {
  const at = TERMINAL.indexOf(`const ${name}: ITheme = {`)
  expect(at, `${name} is no longer declared in terminal.ts`).toBeGreaterThan(-1)
  const body = stripComments(TERMINAL.slice(at, TERMINAL.indexOf('\n}', at)))
  const out = new Map<string, string>()
  for (const entry of body.matchAll(/([A-Za-z]+): '([^']+)'/g)) out.set(entry[1], entry[2])
  return out
}

const DARK_TERM = terminalTheme('DARK_TERMINAL')
const LIGHT_TERM = terminalTheme('LIGHT_TERMINAL')

/** The eight slots a program prints readable text with. `black` is not one. */
const INK = [
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'white',
  'brightRed',
  'brightGreen',
  'brightYellow',
  'brightBlue',
  'brightMagenta',
  'brightCyan',
  'brightWhite',
] as const

describe('the terminal changes with the page', () => {
  const TERMS: ReadonlyArray<readonly [string, Map<string, string>, Map<string, string>]> = [
    ['dark', DARK_TERM, DARK],
    ['light', LIGHT_TERM, LIGHT],
  ]

  for (const [name, term, css] of TERMS) {
    it(`${name} paints the same paper as the stylesheet`, () => {
      // Written twice because a stylesheet and a colour object cannot import each
      // other, and the seam is visible: `.terminal` fills its box with the CSS
      // value and xterm's canvas sits on top with its own.
      expect(get(term, 'background').toLowerCase()).toBe(get(css, '--terminal-bg').toLowerCase())
      expect(get(term, 'foreground').toLowerCase()).toBe(get(css, '--terminal-fg').toLowerCase())
    })

    it(`${name} keeps the ink exact`, () => {
      // Past AA and well past it: a terminal's whole promise is that the
      // characters are exact, so its ink is held to a higher bar than body copy.
      expect(contrast(get(term, 'foreground'), get(term, 'background'))).toBeGreaterThan(7)
      // The cursor is drawn in the ink and cuts its own hole in it.
      expect(get(term, 'cursor').toLowerCase()).toBe(get(term, 'foreground').toLowerCase())
      expect(get(term, 'cursorAccent').toLowerCase()).toBe(get(term, 'background').toLowerCase())
    })

    it(`${name} has sixteen slots that can be read on its own paper`, () => {
      for (const slot of INK) {
        expect({
          slot,
          ok: contrast(get(term, slot), get(term, 'background')) >= 4.5,
        }).toEqual({ slot, ok: true })
      }
      // `brightBlack` is the dim slot a TUI draws borders and comments in. It is
      // deliberately quiet, and it still has to be visible.
      expect(contrast(get(term, 'brightBlack'), get(term, 'background'))).toBeGreaterThanOrEqual(3)
    })
  }

  it('is a real light ramp rather than the dark one on a pale ground', () => {
    // The failure in one assertion: if somebody "adds light mode" by keeping the
    // colour table and swapping the background, every one of these is a pastel
    // measuring about 1.4:1 on paper.
    for (const slot of INK) {
      expect({
        slot,
        differs: get(LIGHT_TERM, slot).toLowerCase() !== get(DARK_TERM, slot).toLowerCase(),
      }).toEqual({ slot, differs: true })
    }
  })

  it('selects in each theme’s own accent', () => {
    const accent = (theme: Map<string, string>): string => rgb(get(theme, '--accent')).join(',')
    expect(rgb(get(DARK_TERM, 'selectionBackground')).join(',')).toBe(accent(DARK))
    expect(rgb(get(LIGHT_TERM, 'selectionBackground')).join(',')).toBe(accent(LIGHT))
  })

  it('declares dark first, because the desktop’s suite reads the first one', () => {
    // `src/renderer/styles/tokens.test.ts` greps this file for the first
    // `selectionBackground` and holds it against the desktop's dark accent. That
    // is a fine check and an invisible ordering dependency, so it is written
    // down here where somebody reordering the file will trip over it.
    expect(TERMINAL.indexOf('DARK_TERMINAL')).toBeLessThan(TERMINAL.indexOf('LIGHT_TERMINAL'))
  })
})

/* -------------------------------------------------------------- the chrome */

describe('the browser’s own chrome follows the page', () => {
  it('paints the address bar in each theme’s canvas', () => {
    // `theme.ts` carries these two as a `Record<Appearance, string>` because a
    // `<meta>` cannot hold a `var()`. Third copy of the same colour, third
    // mechanism holding it in place.
    const table = /THEME_COLOR: Record<Appearance, string> = \{([^}]+)\}/.exec(THEME)
    expect(table, 'THEME_COLOR is no longer declared in theme.ts').not.toBeNull()
    const colours = new Map<string, string>()
    for (const entry of (table as RegExpExecArray)[1].matchAll(/(light|dark): '(#[0-9a-f]{6})'/g)) {
      colours.set(entry[1], entry[2])
    }
    expect(colours.get('dark')?.toLowerCase()).toBe(get(DARK, '--bg-primary').toLowerCase())
    expect(colours.get('light')?.toLowerCase()).toBe(get(LIGHT, '--bg-primary').toLowerCase())
  })

  it('tells the browser both appearances are renderable', () => {
    // `color-scheme: dark` on the document is what leaves the caret, the
    // scrollbars and the form controls dark on a white page.
    expect(read('../index.html')).toContain('content="light dark"')
  })
})
