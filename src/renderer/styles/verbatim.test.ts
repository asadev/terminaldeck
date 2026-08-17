import { readFileSync, readdirSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Ligatures, pinned — the file viewer must show the characters that are in the
 * file.
 *
 * `--font-mono` resolves to the bundled JetBrains Mono, which welds `<!--` into
 * `←!—`, `-->` into `⟶`, `=>` into `⇒` and `</` into a single glyph with the
 * slash grown into the bracket. The file viewer shipped that way: opening
 * `src/renderer/index.html` in it drew an arrow where the HTML comment opens.
 * The fix is one declaration; the interesting part is making sure the *next*
 * pane gets it too, because the omission was never a decision — every one of
 * the eighty-odd mono rules in this renderer simply never mentioned ligatures.
 *
 * So this file does not hold a hand-written list of "the code panes". It
 * re-derives the list from the stylesheets on every run: every selector that
 * asks for `font-family: var(--font-mono)` has to be covered by
 * `verbatim.css`. Add a pane with mono text and no entry there and this test
 * names the selector and the file it is in. A hand-written list would pass
 * forever while the app grew panes it had never heard of, which is the exact
 * failure mode that produced the bug.
 *
 * Three surfaces cannot be found that way, because they take the font stack
 * from TypeScript rather than CSS, so they are asserted by name below.
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const RENDERER = join(ROOT, 'src', 'renderer')
const read = (abs: string): string => readFileSync(abs, 'utf8')

/**
 * Comments carry example selectors and the odd `font-family` in prose, and the
 * header of `verbatim.css` quotes the very characters this is all about. Strip
 * them before any of the parsing below, or the sheet trips over its own
 * explanation.
 */
const stripComments = (css: string): string => css.replace(/\/\*[\s\S]*?\*\//g, '')

function cssFiles(dir: string): string[] {
  const found: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const abs = join(dir, entry.name)
    if (entry.isDirectory()) found.push(...cssFiles(abs))
    else if (entry.name.endsWith('.css')) found.push(abs)
  }
  return found.sort()
}

interface Rule {
  /** One selector from the comma-separated prelude, whitespace collapsed. */
  selector: string
  body: string
  file: string
}

/**
 * Every rule in a stylesheet, flattened to one entry per selector.
 *
 * A regex is enough here and a parser would be a dependency: none of these
 * sheets nest, `@media` blocks are the only braces that contain other braces,
 * and the scan below only ever looks at innermost blocks — which is what
 * `[^{}]*` matches — so a rule inside a media query is picked up with its own
 * selector, exactly as wanted.
 */
function rules(css: string, file: string): Rule[] {
  const out: Rule[] = []
  for (const match of stripComments(css).matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const prelude = match[1].trim()
    if (prelude.startsWith('@')) continue
    for (const selector of prelude.split(',')) {
      const clean = selector.trim().replace(/\s+/g, ' ')
      if (clean) out.push({ selector: clean, body: match[2], file })
    }
  }
  return out
}

const VERBATIM = join(RENDERER, 'styles', 'verbatim.css')
const verbatimRules = rules(read(VERBATIM), VERBATIM)

/** The selectors `verbatim.css` switches ligatures off for. */
const covered = new Set(
  verbatimRules
    .filter((rule) => /font-variant-ligatures:\s*none/.test(rule.body))
    .map((rule) => rule.selector),
)

/** Every rule in every renderer stylesheet, flattened. Parsed once. */
const allRules = cssFiles(RENDERER).flatMap((file) => rules(read(file), file))

/** Every selector anywhere in the renderer that asks for the mono face. */
const monoRules = allRules.filter((rule) =>
  /font-family:\s*var\(--font-mono\)/.test(rule.body),
)

/**
 * Selectors that qualify a verbatim one — `.foo.is-link`, `.foo:hover`,
 * `#x .foo` — rather than merely starting with the same letters.
 *
 * `.artifact-diff-body` is a different class from `.artifact-diff` and must not
 * match, so the boundary either side excludes the characters a class name is
 * allowed to continue with.
 */
function qualifies(selector: string, verbatim: string): boolean {
  if (selector === verbatim) return false
  const edge = String.raw`[-\w]`
  return new RegExp(`(?<!${edge})${verbatim.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?!${edge})`).test(
    selector,
  )
}

describe('verbatim.css is the whole inventory of mono surfaces', () => {
  it('found the mono rules at all — a broken sweep would pass everything', () => {
    // If the parse or the token name ever changes shape, every assertion below
    // becomes vacuously true. Anchor it: this app is full of monospace text.
    expect(monoRules.length).toBeGreaterThan(50)
    expect(covered.size).toBeGreaterThan(50)
  })

  it.each(monoRules.map((rule) => [relative(ROOT, rule.file), rule.selector, rule] as const))(
    '%s covers %s',
    (_file, _selector, rule) => {
      const self = /font-variant-ligatures:\s*none/.test(rule.body)
      expect(
        covered.has(rule.selector) || self,
        `${rule.selector} sets --font-mono but nothing turns ligatures off for it. ` +
          `Add it to src/renderer/styles/verbatim.css — a mono surface shows machine ` +
          `text, and JetBrains Mono will redraw <!-- --> => != <= === </ /> in it.`,
      ).toBe(true)
    },
  )

  it('turns them off with the property that also covers contextual alternates', () => {
    // `font-feature-settings: 'liga' 0` on its own is not enough: JetBrains
    // Mono hangs most of its arrows off `calt`, and only the high-level
    // property switches that off in the same breath. `none` leaves `rlig`
    // alone, so Arabic and Indic terminal output still shapes.
    const css = stripComments(read(VERBATIM))
    expect(css).toMatch(/font-variant-ligatures:\s*none/)
    expect(css).not.toMatch(/font-variant-ligatures:\s*(?:normal|common-ligatures)/)
  })

  /**
   * The rule can be switched back off from a distance, and once was.
   *
   * `font` is a shorthand: it resets `font-variant-ligatures` along with
   * everything else with a `font-` prefix, whether or not the author was
   * thinking about ligatures. `Dashboard.css` had
   * `.widget-branch-name.is-link { font: inherit }`, two classes against this
   * sheet's one, and it out-specified both the ligature switch *and* the
   * `font-family: var(--font-mono)` on `.widget-branch-name` — the git branch
   * in the overview tile rendered in the UI face, while the same branch drawn
   * as a `<span>` two lines away in the same component rendered in mono.
   *
   * Nobody sees that in a diff, so it is checked here: no rule may set the
   * `font` shorthand on a *qualified* form of a verbatim selector unless it
   * turns ligatures off itself. Descendants are untouched by this — a child
   * with `font: inherit` inherits `none` from the covered parent, which is
   * exactly how `.file-viewer-code` and `.artifact-diff-body` work.
   */
  it('is not undone by a `font` shorthand somewhere more specific', () => {
    const shorthand = allRules.filter(
      (rule) =>
        /(?:^|[;\s])font:\s/.test(rule.body) && !/font-variant-ligatures:\s*none/.test(rule.body),
    )
    const clashes = shorthand.flatMap((rule) =>
      [...covered]
        .filter((verbatim) => qualifies(rule.selector, verbatim))
        .map((verbatim) => `${relative(ROOT, rule.file)}: \`${rule.selector}\` over ${verbatim}`),
    )
    expect(clashes, 'the `font` shorthand resets font-variant-ligatures').toEqual([])
  })

  it('is loaded by the sheet every entry point already imports', () => {
    // main.tsx and the four .harness entries all import styles/app.css, and
    // none of them may be edited by a second agent mid-session.
    expect(stripComments(read(join(RENDERER, 'styles', 'app.css')))).toContain(
      "@import './verbatim.css'",
    )
  })
})

/**
 * The named surfaces, spelled out.
 *
 * The sweep above is the mechanism, but it can only see what CSS declares. A
 * pane that is renamed, or one whose font arrives from JavaScript, would slip
 * through it silently. These are the surfaces whose entire purpose is to quote
 * something the user did not write, listed so that losing one is a failure with
 * a sentence attached rather than a shorter list.
 */
describe('every surface that quotes a file or a process', () => {
  it.each([
    ['the file viewer', '.file-viewer-doc'],
    ['the artifact diff', '.artifact-diff'],
    ['chat code blocks and inline code', '.cv-rich code'],
    ['the debug log pane', '.debug-pre'],
    ['CI failure output', '.gh-failure-detail pre'],
    ['MCP payloads', '.mcp-pre'],
    ['the JSON the user types into an MCP tool', '.mcp-input-json'],
    ['the session inspector transcript', '.si-list-lead'],
    ['a panel error, quoted from the throw', '.panel-error-detail'],
    ['the git diff stat', '.git-stat'],
    ['the terminal', '.xterm-rows'],
    ['the terminal font specimen in Settings', '.settings-font-preview'],
  ])('%s (%s)', (_name, selector) => {
    expect(covered.has(selector)).toBe(true)
  })

  /**
   * The two xterm mounts and the specimen set `fontFamily` on the instance from
   * `--font-mono` in TypeScript, so no CSS rule names the token for them and
   * the sweep is blind to all three. If one of them stops reaching for the
   * token the entry in `verbatim.css` becomes dead weight and should go; if a
   * third mount appears, it needs one too.
   */
  it.each([
    ['components/TerminalView.tsx', '.xterm-rows'],
    ['machines/RemoteTerminal.tsx', '.xterm-rows'],
    ['settings/sections/AppearanceSection.tsx', '.settings-font-preview'],
  ])('%s still takes its face from --font-mono, so %s stays listed', (file, selector) => {
    expect(read(join(RENDERER, ...file.split('/')))).toContain('--font-mono')
    expect(covered.has(selector)).toBe(true)
  })
})

/**
 * xterm is not asked to leave ligatures alone — it is told to.
 *
 * Its DOM renderer happens not to ligate today, but only because it corrects
 * sub-pixel cell drift with a `letter-spacing` on every run and Blink drops
 * ligatures whenever letter-spacing is non-zero. The correction is written
 * only when it differs from the row default (`M !== this.defaultSpacing` in
 * `@xterm/xterm`), so a font and size whose natural advance lands exactly on
 * the cell width would leave a run at zero spacing — and Settings lets the user
 * pick both. Nothing in xterm's own CSS mentions ligatures, which is why this
 * has to be said here.
 */
describe('the terminal cannot start ligating by accident', () => {
  it('has no ligature declaration of its own to rely on', () => {
    const xterm = join(ROOT, 'node_modules', '@xterm', 'xterm', 'css', 'xterm.css')
    expect(stripComments(read(xterm))).not.toMatch(/font-variant-ligatures|font-feature-settings/)
  })

  it('covers both the screen and the row container', () => {
    // The rows carry the text; `.xterm` is the element the font lands on, and
    // covering it means a future renderer that draws somewhere else inside the
    // same host inherits the setting rather than needing a new line here.
    expect(covered.has('.xterm')).toBe(true)
    expect(covered.has('.xterm-rows')).toBe(true)
  })
})
