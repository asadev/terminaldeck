import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  composite,
  contrast,
  dimmedContrast,
  DIM_MAX_LUMINANCE_KEPT,
  DIM_MIN_CONTRAST,
  DIM_MIN_FOCUS_CONTRAST,
  DIM_MIN_LUMINANCE_KEPT,
  luminance,
  luminanceKept,
  parseRgba,
} from './dim-budget'

/**
 * The dim, held to both ends of its budget against the real stylesheet.
 *
 * The requirement has two halves that pull in opposite directions and only one
 * of them is obvious:
 *
 *  - the surroundings must go **dull**, or there is no focus;
 *  - the surroundings must stay **readable**, because "dim is emphasis, not
 *    censorship" — somebody who stops to read the dimmed part still can.
 *
 * A test that only checked contrast would pass forever at an alpha of 0.02,
 * which is the fix a well-meaning person makes when a contrast assertion fails.
 * A test that only checked darkness would pass at 0.8, which erases the window.
 * Both are asserted, so the pair is a range and the range is narrow.
 *
 * It reads `tokens.css` rather than a constant, which is the mechanism
 * `styles/tokens.test.ts` already established for this repository after four
 * hand-copied colours went stale: "a comment asking a human to remember is not
 * a mechanism."
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const TOKENS = readFileSync(resolve(ROOT, 'src/renderer/styles/tokens.css'), 'utf8')

const stripComments = (text: string): string => text.replace(/\/\*[\s\S]*?\*\//g, '')

function cssVars(selector: RegExp): Map<string, string> {
  const match = selector.exec(TOKENS)
  if (!match) throw new Error(`no rule matching ${selector} — did the sheet get restructured?`)
  const open = TOKENS.indexOf('{', match.index)
  const close = TOKENS.indexOf('\n}', open)
  const body = stripComments(TOKENS.slice(open + 1, close))
  const out = new Map<string, string>()
  for (const decl of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) out.set(decl[1], decl[2].trim())
  return out
}

const THEMES = [
  ['light', cssVars(/^:root,\s*\n\[data-theme='light'\]\s*\{/m)],
  ['dark', cssVars(/^\[data-theme='dark'\]\s*\{/m)],
] as const

const get = (theme: Map<string, string>, name: string): string => {
  const value = theme.get(name)
  if (value === undefined) throw new Error(`${name} is missing from the sheet`)
  return value
}

/**
 * Every surface a piece of text lands on, paired with the quietest ink the
 * sheet guarantees on it.
 *
 * `--text-muted` and not `--terminal-fg`, and that is the correction this file
 * makes to the design note it was built from. That note names the terminal as
 * "the worst pairing in the window" and budgets the scrim against it. The
 * terminal is very nearly the *best* pairing: it starts at 15:1 in both themes.
 * `--text-muted` on the chrome — a sidebar section label, a timestamp in the
 * chat view — starts at 4.7:1 and is what actually disappears first. Budgeting
 * against the terminal permits a scrim that erases every quiet label in the
 * window while the numbers look healthy.
 */
const SURFACES = ['--bg-primary', '--bg-secondary', '--bg-tertiary', '--bg-sunken'] as const

describe('the scrim leaves the surroundings readable', () => {
  for (const [name, theme] of THEMES) {
    const scrim = get(theme, '--drive-dim')

    for (const surface of SURFACES) {
      it(`${name}: muted text on ${surface} still resolves under the scrim`, () => {
        const ratio = dimmedContrast(get(theme, '--text-muted'), get(theme, surface), scrim)
        expect({ surface, ratio: ratio >= DIM_MIN_CONTRAST }).toEqual({ surface, ratio: true })
      })
    }

    /*
     * The terminal is held higher than the rest, because terminal output is
     * what a tour's evidence is made of. A reader whose eye slides one line
     * above the box should be reading at least as well as they read the app's
     * own body copy.
     */
    it(`${name}: dimmed terminal text still clears AA body text`, () => {
      const ratio = dimmedContrast(get(theme, '--terminal-fg'), get(theme, '--terminal-bg'), scrim)
      expect(ratio).toBeGreaterThanOrEqual(DIM_MIN_FOCUS_CONTRAST)
    })
  }
})

describe('the scrim actually dims, and stops short of blacking out', () => {
  for (const [name, theme] of THEMES) {
    const scrim = get(theme, '--drive-dim')

    /*
     * Measured on the *brighter* half of the terminal pair — the ink in a dark
     * theme, the paper in a light one. That is what a reader perceives as
     * dulling; contrast is not, because a scrim moves both ends of a pair at
     * once and can leave the ratio almost unchanged while the whole region
     * visibly darkens.
     */
    const brighter =
      luminance(parseRgba(get(theme, '--terminal-fg')).rgb) >
      luminance(parseRgba(get(theme, '--terminal-bg')).rgb)
        ? '--terminal-fg'
        : '--terminal-bg'

    it(`${name}: the dim is visible`, () => {
      expect(luminanceKept(get(theme, brighter), scrim)).toBeLessThanOrEqual(
        DIM_MAX_LUMINANCE_KEPT,
      )
    })

    it(`${name}: the dim is emphasis, not censorship`, () => {
      expect(luminanceKept(get(theme, brighter), scrim)).toBeGreaterThanOrEqual(
        DIM_MIN_LUMINANCE_KEPT,
      )
    })
  }

  /*
   * The two themes are held to the same apparent dimming.
   *
   * A black scrim multiplies sRGB channels by (1 - alpha) whichever element is
   * the bright one, so equal alphas mean equal dimming — which is why the
   * design note's asymmetric pair (0.22 light, 0.45 dark) was wrong in both
   * directions at once. If a future change gives the two themes different
   * alphas for a real reason, this is the assertion that will make somebody
   * write it down.
   */
  it('both themes dim by the same amount', () => {
    const [, light] = THEMES[0]
    const [, dark] = THEMES[1]
    const lit = luminanceKept('#ffffff', get(light, '--drive-dim'))
    const drk = luminanceKept('#ffffff', get(dark, '--drive-dim'))
    expect(Math.abs(lit - drk)).toBeLessThan(0.02)
  })
})

describe('the scrim is declared for both themes', () => {
  /*
   * `CLAUDE.md`: "Both themes are first-class. Never define a colour only inside
   * [data-theme='dark']." The inverse matters more here — a value declared only
   * in `:root` would be inherited by the dark theme silently, and the dark theme
   * is the one with almost no headroom.
   */
  for (const [name, theme] of THEMES) {
    it(`${name} declares --drive-dim and --drive-ring-glow`, () => {
      expect(theme.get('--drive-dim')).toBeDefined()
      expect(theme.get('--drive-ring-glow')).toBeDefined()
    })

    it(`${name}'s scrim is a neutral black, so it tints nothing`, () => {
      const { rgb } = parseRgba(get(theme, '--drive-dim'))
      expect(rgb).toEqual([0, 0, 0])
    })
  }
})

describe('the colour maths itself', () => {
  it('composites in sRGB, which is what a browser does for a background', () => {
    // Half-alpha black over white is 127.5 per channel, not the linear-light
    // answer of about 188. Getting this wrong would make every figure above
    // optimistic and every one of them wrong in the same direction.
    expect(composite({ rgb: [0, 0, 0], alpha: 0.5 }, [255, 255, 255])).toEqual([
      127.5, 127.5, 127.5,
    ])
  })

  it('agrees with the known contrast of black on white', () => {
    expect(contrast([0, 0, 0], [255, 255, 255])).toBeCloseTo(21, 5)
  })

  it('reads the two notations tokens.css uses, and refuses the rest', () => {
    expect(parseRgba('#3b8fee')).toEqual({ rgb: [59, 143, 238], alpha: 1 })
    expect(parseRgba('rgba(0, 0, 0, 0.26)')).toEqual({ rgb: [0, 0, 0], alpha: 0.26 })
    expect(() => parseRgba('color-mix(in srgb, var(--accent) 62%, transparent)')).toThrow()
  })

  it('keeps everything at alpha zero and nothing at alpha one', () => {
    expect(luminanceKept('#ededed', 'rgba(0, 0, 0, 0)')).toBeCloseTo(1, 6)
    expect(luminanceKept('#ededed', 'rgba(0, 0, 0, 1)')).toBeCloseTo(0, 6)
  })
})
