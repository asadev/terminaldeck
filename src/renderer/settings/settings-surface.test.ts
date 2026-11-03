import { readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Settings is one surface, and it stays one surface.
 *
 * The sheet used to be three greys stacked on each other: a rail on
 * `--bg-secondary`, a pane behind the content on `--bg-primary`, and a rounded
 * card of `--bg-secondary` sitting on that pane holding every row. In the dark
 * theme the card was the lightest of the three, which is why it read as a
 * window floating inside the dialog. Asad, on the Notifications pane: *"Settings
 * page needs to show the same colour inside the selected box, also selected
 * section, also in the background, as the side panel — not a kind of window
 * thing like terminal."*
 *
 * Flattening a surface is easy to do and easy to half-undo, because every
 * individual re-tint looks reasonable on its own: one card for a notice, one
 * fill for a list, one pill for the selected row, and the sheet is three greys
 * again. So the claims are pinned here rather than trusted to the next reader
 * of the stylesheet:
 *
 *   - the rail and the pane are painted with the same token, and only those two
 *     things paint a surface at all;
 *   - the selected section is not a fill — it is the accent, which cannot go
 *     grey-on-grey the way the old pill did;
 *   - the accent it uses is legible on the surface it now sits directly on, in
 *     both themes;
 *   - and the spacing that replaced the card still groups: more room above a
 *     heading than between two rows, less below it than between two rows.
 *
 * Everything below reads the real stylesheets. CSS never reaches a DOM in these
 * tests — jsdom does not apply it — so the sheet is parsed as text, the same
 * way `tokens.test.ts` checks the palette.
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

/**
 * Comments out. Load-bearing rather than tidy: the header of
 * `SettingsWindow.css` explains what the flattening replaced, and quotes
 * `--bg-secondary` and `--bg-active` by name while doing it. Counting
 * occurrences without this would count the explanation.
 */
const stripComments = (text: string): string => text.replace(/\/\*[\s\S]*?\*\//g, '')

const SETTINGS = stripComments(read('src/renderer/settings/SettingsWindow.css'))
const MODAL = stripComments(read('src/renderer/components/Modal.css'))
const TOKENS = stripComments(read('src/renderer/styles/tokens.css'))

interface Rule {
  selector: string
  body: string
  /** True for a rule that only applies under an at-rule — `@media`, mostly. */
  conditional: boolean
}

/**
 * Every rule in a sheet, flattened.
 *
 * Brace-counting rather than a regex, because the selectors this file has to
 * find are the multi-line `:is(…) + :is(…)` runs and a regex over those is
 * write-only. An at-rule is recursed into rather than returned, and what came
 * out of one is flagged: `.settings-panel` is declared twice, once for the
 * sheet and once for the narrow layout, and a check that means "the pane" has
 * to be able to say which of the two it means.
 */
function rules(css: string, conditional = false): Rule[] {
  const out: Rule[] = []
  let depth = 0
  let open = 0
  let selectorStart = 0
  for (let i = 0; i < css.length; i++) {
    if (css[i] === '{') {
      if (depth === 0) open = i
      depth += 1
    } else if (css[i] === '}') {
      depth -= 1
      if (depth === 0) {
        const selector = css.slice(selectorStart, open).trim()
        const body = css.slice(open + 1, i)
        if (selector.startsWith('@')) out.push(...rules(body, true))
        else out.push({ selector, body, conditional })
        selectorStart = i + 1
      }
    }
  }
  return out
}

const SETTINGS_ALL = rules(SETTINGS)
const SETTINGS_RULES = SETTINGS_ALL.filter((rule) => !rule.conditional)
const MODAL_RULES = rules(MODAL).filter((rule) => !rule.conditional)

/** The one rule whose selector satisfies `match`. Ambiguity is a failure, not a pick. */
function only(all: Rule[], match: (selector: string) => boolean, what: string): Rule {
  const found = all.filter((rule) => match(rule.selector))
  expect(found.map((rule) => rule.selector), `${what}: expected exactly one rule`).toHaveLength(1)
  return found[0]
}

/** The last value a property is given inside one rule. */
function decl(rule: Rule, property: string): string {
  const found = [...rule.body.matchAll(new RegExp(`(?:^|;|\\{)\\s*${property}\\s*:\\s*([^;]+)`, 'g'))]
  expect(found.length, `${rule.selector} declares ${property}`).toBeGreaterThan(0)
  return found[found.length - 1][1].trim()
}

/* ------------------------------------------------------------- one surface */

describe('the settings sheet is one surface', () => {
  const rail = only(
    SETTINGS_RULES,
    (selector) => selector === '.settings-rail',
    'the rail',
  )
  const pane = only(
    SETTINGS_RULES,
    (selector) => selector === '.settings-panel',
    'the pane',
  )

  it('paints the rail and the pane with the same token', () => {
    expect(decl(rail, 'background')).toBe('var(--bg-secondary)')
    expect(decl(pane, 'background')).toBe(decl(rail, 'background'))
  })

  it('paints the sheet header and footer with it too', () => {
    // Modal.css owns the band above and below the two columns. If it ever
    // stops agreeing with them the sheet is banded again, which is the same
    // defect one step out.
    for (const part of ['header', 'footer']) {
      const band = only(
        MODAL_RULES,
        (selector) => selector === `.modal-panel[data-size='xl'] > .modal-${part}`,
        `the sheet ${part}`,
      )
      expect(decl(band, 'background'), part).toBe('var(--bg-secondary)')
    }
  })

  it('paints nothing else on that surface', () => {
    /*
     * Two, and only two: the rail and the pane.
     *
     * This is the assertion that actually holds the flattening in place. Every
     * card that was removed — the run of rows, the tool lists, the notice, the
     * code block — was `background: var(--bg-secondary)`, and each one would be
     * a defensible thing to add back on its own. A third occurrence of this
     * declaration in this file means one of them came back.
     */
    const painted = SETTINGS.match(/background:\s*var\(--bg-secondary\)/g) ?? []
    expect(painted).toHaveLength(2)
  })

  it('leaves the rows with no fill and no inset', () => {
    // Flush left, so the labels line up with the headings and the pane's own
    // title. An inset from a fill that no longer exists is an orphan indent.
    const row = only(SETTINGS_RULES, (selector) => selector === '.settings-row', 'a row')
    expect(decl(row, 'padding')).toBe('0')
    expect(row.body).not.toMatch(/background\s*:/)
  })
})

/* --------------------------------------------- and the sections drawn on it */

/**
 * A section's own stylesheet is the other half of the sheet, and the half that
 * survived the flattening pass unread.
 *
 * `SetupSection.css` painted its hook blocks `--bg-secondary` while the pane
 * was still `--bg-primary`, which was correct at the time and became invisible
 * the moment the pane moved to `--bg-secondary`: three blocks, each with a
 * heading, a path, ten event chips and three buttons, drawn in exactly the
 * colour of the page they sit on. Nothing in the file was wrong — the ground
 * had moved under it.
 *
 * That is the failure this pins. On a flat sheet, a surface token is never the
 * answer for something that has *appeared*: it names a colour, so it can come
 * to name the same colour as its background, and it needs a second rule per
 * theme to keep from doing so. A `--fill-*` is defined as a lift off whatever
 * is behind it and cannot make that mistake.
 */
describe('a section drawn on that surface never repaints it', () => {
  const files = readdirSync(join(ROOT, 'src/renderer/settings/sections'))
    .filter((name) => name.endsWith('.css'))
    .map((name) => [name, stripComments(read(`src/renderer/settings/sections/${name}`))] as const)

  it('has section stylesheets to check', () => {
    expect(files.length).toBeGreaterThan(0)
  })

  it.each(files)('%s paints backgrounds with fills, not with surfaces', (_name, css) => {
    expect(css.match(/background:\s*var\(--bg-[a-z]+\)/g) ?? []).toEqual([])
  })

  it('gives each hook block a fill of its own, so the blocks have edges', () => {
    const setup = stripComments(read('src/renderer/settings/sections/SetupSection.css'))
    const block = only(rules(setup), (selector) => selector === '.setup-hooks', 'a hook block')
    expect(decl(block, 'background')).toBe('var(--fill-tertiary)')
  })
})

/* ------------------------------------------------- selection without a fill */

describe('the selected section is unmistakable on a flat rail', () => {
  const selected = only(
    SETTINGS_RULES,
    (selector) => selector === ".settings-nav-item[aria-selected='true']",
    'the selected nav item',
  )
  const marker = only(
    SETTINGS_RULES,
    (selector) => selector === ".settings-nav-item[aria-selected='true']::before",
    'the selected marker',
  )

  it('is not a fill', () => {
    // The whole point. A lighter pill on a flat rail is the last stacked grey
    // in the window, and it is also the one that was already reported as
    // invisible in the dark theme.
    expect(decl(selected, 'background')).toBe('transparent')
    expect(SETTINGS).not.toContain('--bg-active')
  })

  it('is the accent, in the accent, with a mark beside it', () => {
    expect(decl(selected, 'color')).toBe('var(--accent)')
    expect(decl(selected, 'font-weight')).toBe('var(--w-semibold)')
    expect(decl(marker, 'background')).toBe('var(--accent)')
  })

  it('turns with the rail when the rail turns', () => {
    // Below 760px the rail is a strip along the top, and a capsule against the
    // left edge of a horizontal tab points at the gap between two tabs rather
    // than at either of them.
    const strip = only(
      SETTINGS_ALL.filter((rule) => rule.conditional),
      (selector) => selector === ".settings-nav-item[aria-selected='true']::before",
      'the selected marker in the narrow layout',
    )
    expect(decl(strip, 'height')).toBe('2px')
    expect(decl(strip, 'width')).toBe('auto')
  })

  it('hovering something else never outshouts it', () => {
    // A grey pill under the cursor is fine; a grey pill under the row you are
    // already on hands back the box that was removed, intermittently.
    const hover = only(
      SETTINGS_RULES,
      (selector) => selector.startsWith('.settings-nav-item:hover'),
      'the nav hover',
    )
    expect(hover.selector).toContain(":not([aria-selected='true'])")
  })
})

/* --------------------------------------------------- and it can be read */

describe('the accent is legible on the surface it now sits on', () => {
  /**
   * The old pill was a level: white at 14% over whatever grey was underneath.
   * That is why raising its alpha kept being the fix and kept needing to be the
   * fix. The accent is a hue, so the only thing that can break it is the accent
   * or the surface moving — which is exactly what this measures, in both
   * themes, against the surface the rail is actually painted with.
   */
  const value = (theme: RegExp, token: string): string => {
    const block = theme.exec(TOKENS)
    if (!block) throw new Error(`no ${theme} block in tokens.css`)
    const body = TOKENS.slice(TOKENS.indexOf('{', block.index), TOKENS.indexOf('\n}', block.index))
    const found = new RegExp(`${token}\\s*:\\s*([^;]+);`).exec(body)
    if (!found) throw new Error(`no ${token} in ${theme}`)
    return found[1].trim()
  }

  const channels = (hex: string): number[] => {
    const clean = hex.replace('#', '')
    return [0, 2, 4].map((at) => parseInt(clean.slice(at, at + 2), 16) / 255)
  }

  const luminance = (hex: string): number => {
    const [r, g, b] = channels(hex).map((c) =>
      c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4,
    )
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  const contrast = (a: string, b: string): number => {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
    return (hi + 0.05) / (lo + 0.05)
  }

  const THEMES: ReadonlyArray<readonly [string, RegExp]> = [
    ['light', /^:root,\s*\n\[data-theme='light'\]\s*\{/m],
    ['dark', /^\[data-theme='dark'\]\s*\{/m],
  ]

  for (const [name, block] of THEMES) {
    it(`clears AA as the selected label in the ${name} theme`, () => {
      const ratio = contrast(value(block, '--accent'), value(block, '--bg-secondary'))
      expect({ theme: name, ratio: Math.round(ratio * 10) / 10 }).toEqual({
        theme: name,
        ratio: expect.any(Number),
      })
      expect(ratio, `${name}: --accent on --bg-secondary`).toBeGreaterThanOrEqual(4.5)
    })
  }
})

/* -------------------------------------------------- space does the grouping */

describe('spacing groups the rows now that the card does not', () => {
  /**
   * Three gaps, and their order is the whole mechanism: a heading has to be
   * further from the group above it than its rows are from each other, and
   * nearer to its own first row than they are. Get that order wrong and a
   * heading floats between two groups belonging to neither, which is what a
   * flat pane looks like when it fails.
   */
  const spacing = (): Map<string, number> => {
    // Scanned over the whole sheet rather than out of one block: the spacing
    // scale is declared once, in the shared `:root`, and that is not the *last*
    // `:root` in the file — the reduced-motion override is.
    const out = new Map<string, number>()
    for (const found of TOKENS.matchAll(/(--sp-[a-z0-9]+)\s*:\s*(\d+)px;/g)) {
      out.set(found[1], Number(found[2]))
    }
    expect(out.size, 'the spacing scale was found').toBeGreaterThan(6)
    return out
  }

  const SP = spacing()
  const px = (value: string): number => {
    const token = /var\((--sp-[a-z0-9]+)\)/.exec(value)
    if (!token) return Number(value.replace('px', ''))
    const size = SP.get(token[1])
    if (size === undefined) throw new Error(`unknown spacing token ${token[1]}`)
    return size
  }

  const aboveHeading = px(
    decl(only(SETTINGS_RULES, (s) => s === '.settings-group', 'a group'), 'margin-top'),
  )
  const belowHeading = px(
    decl(
      only(SETTINGS_RULES, (s) => s === '.settings-group-title', 'a group heading'),
      'margin',
    )
      .split(/\s+/)
      .slice(-1)[0],
  )
  const betweenRows = px(
    decl(
      only(
        SETTINGS_RULES,
        (s) => s.includes('+ :is(') && s.includes('.settings-item') && !s.includes('data-density'),
        'the gap between two rows',
      ),
      'margin-top',
    ),
  )
  const betweenEntries = px(
    decl(
      only(
        SETTINGS_RULES,
        (s) => s.includes('.settings-paths) > * + *') && !s.includes('data-density'),
        'the gap between two list entries',
      ),
      'margin-top',
    ),
  )

  it('puts more room above a heading than between two rows', () => {
    expect({ aboveHeading, betweenRows }).toEqual({
      aboveHeading: expect.any(Number),
      betweenRows: expect.any(Number),
    })
    expect(aboveHeading).toBeGreaterThan(betweenRows)
  })

  it('binds a heading to the rows under it', () => {
    expect(belowHeading).toBeLessThan(betweenRows)
  })

  it('keeps one rhythm for rows and for list entries', () => {
    // A section that mixes a run of rows with a list of paths — Agents, Advanced
    // — must not change tempo halfway down.
    expect(betweenEntries).toBe(betweenRows)
  })
})

/* ------------------------------------------------- nothing runs off the pane */

/**
 * Two rules that only fail once somebody's own data is longer than the mock's.
 *
 * Both were found by rendering the packaged app against a scratch profile on
 * 2026-08-22 rather than by reading this sheet, and both are invisible until the
 * content grows: a pane with two short servers and a one-word value looks
 * finished. The pins are here, beside the rest of this sheet's claims, because
 * the failure is a *layout* one and jsdom applies no layout — the same argument
 * the header of this file makes for reading the stylesheet as text.
 */
describe('the pane holds its own width', () => {
  const scope = only(SETTINGS_RULES, (selector) => selector === '.settings-scope', 'the pill row')
  const value = only(SETTINGS_RULES, (selector) => selector === '.settings-value', 'a stated value')

  it('wraps the pill row instead of pushing the pane sideways', () => {
    /*
     * Measured before the fix, with five servers of ordinary length in the
     * Servers pane: the run was 720px wide inside a 709px column, the last pill
     * sat past the pane's right margin, and the whole panel reported
     * `scrollWidth` 844 against `clientWidth` 833 — a horizontal scrollbar in
     * Settings. `width: fit-content` cannot cause that on its own; the absence
     * of a wrap and of a cap is what does.
     */
    expect(decl(scope, 'flex-wrap')).toBe('wrap')
    expect(decl(scope, 'max-width')).toBe('100%')
  })

  it('lets a stated value be two lines rather than one that overflows', () => {
    // `height` would clip. Servers puts whole sentences through this class —
    // "A key, sealed by this computer and never shown on any screen." — and a
    // fixed height means the second line is drawn over the row beneath.
    expect(value.body).not.toMatch(/(?:^|;|\{)\s*height\s*:/)
    expect(decl(value, 'min-height')).toBe('var(--control-h)')
    expect(decl(value, 'text-align')).toBe('right')
  })

  it('makes the value give ground before the label does', () => {
    /*
     * `.settings-row-control` refuses to shrink, which is right for a control
     * with a size of its own and wrong for a sentence: at an 820px window —
     * legal, the app's minimum is 720 — **Kept on this computer** broke into
     * three lines with its ⓘ orphaned on a fourth while the sentence beside it
     * sat on one.
     */
    const control = only(
      SETTINGS_RULES,
      (selector) => selector === '.settings-row-control:has(> .settings-value)',
      'a row whose control is a stated value',
    )
    expect(Number(decl(control, 'flex-shrink'))).toBeGreaterThanOrEqual(2)
    expect(decl(control, 'min-width')).toBe('0')
  })
})
