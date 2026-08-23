import { readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every `var(--…)` the renderer writes names a property something defines.
 *
 * The bug this exists to end has been shipped at least ten times. Somebody
 * writes `color: var(--text-tertiary)` — a plausible name, in a repository that
 * really does have `--fill-tertiary` — and CSS does not complain. An undefined
 * custom property is not a parse error; it is an **invalid value at
 * computed-value time**, which means the cascade picks the declaration and
 * *then* throws the value away. An inherited property such as `color` falls
 * back to the parent's; a non-inherited one such as `animation` resets to its
 * initial value. Either way the element draws something reasonable, so the
 * screen looks finished and the declaration is decoration.
 *
 * What that has actually cost, all of it found by the sweep this file closes:
 *
 *   - `.cc-tool.dc-live`, the microphone while it is recording, asked for
 *     `--status-error` and `--ease-standard`. Neither exists. The tint died,
 *     the `color-mix()` died with its argument and left the button
 *     transparent, and the `animation` shorthand reset to `none` — so the
 *     pulse never ran either. The recording state drew *nothing*, and the one
 *     control where a person's next question is "is it still on" answered it
 *     by not changing.
 *   - `.settings-rail-btn` carries the comment "deliberately quieter than a
 *     nav item" directly above the line that was supposed to make it quieter.
 *     It inherited `--text-secondary`, which is precisely what a nav item
 *     wears, so the sentence had been false since it was written.
 *   - `TransferNote.tsx` reached for `--chrome-solid` and `--text` in an
 *     inline style and got its own fallbacks — a dark chip with light ink —
 *     in both themes, so the paste refusal drew itself inverted on a light
 *     screen for as long as it has existed.
 *
 * `tokens.test.ts` catches this shape for `font-size` alone, by insisting the
 * value match `var(--t-…)` by name. That check found the first two phantoms and
 * could not have found the other eight, because they were colours and curves.
 * This one is the general form: collect every name the renderer *defines*,
 * collect every name it *reads*, and subtract.
 *
 * The five names in ALLOWLIST below are read from CSS and written from
 * JavaScript, which is legitimate — a value only the running layout knows
 * cannot be a token. But an allowlist is an excuse, and an unchecked excuse
 * outlives its reason: delete the module that publishes `--sheet-room` and the
 * stylesheet quietly goes back to its fallback with this file still nodding
 * along. So each entry is verified against the source that writes it, and the
 * list is checked from both ends — nothing stale, nothing spare.
 */

const ROOT = resolve(__dirname, '..', '..', '..')
const read = (rel: string): string => readFileSync(join(ROOT, rel), 'utf8')

/**
 * Source with comment bodies blanked, keeping every newline.
 *
 * Load-bearing twice over. The stylesheets in this repository quote the
 * phantoms they used to contain — that is the point of the notes left beside
 * each fix — so a scan that read comments would rediscover its own history and
 * fail forever. And blanking rather than deleting keeps byte offsets intact, so
 * the line numbers this test prints are the line numbers in the file.
 */
const blankComments = (text: string): string =>
  text.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '))

const lineOf = (text: string, index: number): number => text.slice(0, index).split('\n').length

/** Every file the renderer ships with the given extension, tests excluded. */
function rendererFiles(...extensions: readonly string[]): string[] {
  const out: string[] = []
  const walk = (dir: string): void => {
    for (const entry of readdirSync(join(ROOT, dir), { withFileTypes: true })) {
      const rel = `${dir}/${entry.name}`
      if (entry.isDirectory()) walk(rel)
      else if (extensions.some((ext) => entry.name.endsWith(ext)) && !/\.test\.[tj]sx?$/.test(entry.name)) {
        out.push(rel)
      }
    }
  }
  walk('src/renderer')
  return out.sort()
}

const CSS_FILES = rendererFiles('.css')
const TS_FILES = rendererFiles('.ts', '.tsx')

/** Every custom property the renderer's stylesheets define. */
function definedNames(): Set<string> {
  const out = new Set<string>()
  for (const file of CSS_FILES) {
    for (const decl of blankComments(read(file)).matchAll(/(--[A-Za-z0-9_-]+)\s*:/g)) out.add(decl[1])
  }
  return out
}

type Reference = { readonly name: string; readonly where: string }

/**
 * Every custom property the renderer *reads*, in stylesheets and in the inline
 * styles that components hand to React.
 *
 * The `.tsx` half is not thoroughness for its own sake: two of the ten phantoms
 * lived there, and a check that stopped at `.css` would have declared the sweep
 * finished with `TransferNote` still drawing the wrong way round.
 */
function references(): Reference[] {
  const out: Reference[] = []
  for (const file of [...CSS_FILES, ...TS_FILES]) {
    const source = blankComments(read(file))
    for (const use of source.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)/g)) {
      out.push({ name: use[1], where: `${file}:${lineOf(source, use.index ?? 0)}` })
    }
  }
  return out
}

/**
 * Names a stylesheet reads and only JavaScript writes, each with the reason it
 * cannot be a token. Every one is a measurement — a depth, or the pixels left
 * between an element and an edge — that exists only once the layout is real.
 *
 * Adding to this list is deliberate, and the test below makes it expensive
 * enough to stay that way.
 */
const ALLOWLIST = new Map<string, string>([
  ['--depth', 'a tree row’s nesting level, counted while the tree is walked'],
  ['--menu-room', 'the height left under an open settings menu, measured on open'],
  ['--sc-room', 'the width the session-control cluster is allowed, measured on resize'],
  ['--sheet-room', 'the height left above a sheet, measured when it opens'],
  ['--window-controls-inset', 'the space the traffic lights occupy, which only the OS knows'],
])

/** `'--x'`, `"--x"` or `` `--x` ``, escaped for use inside a larger pattern. */
const quoted = (name: string): string => `['"\`]${name.replace(/-/g, '\\-')}['"\`]`

/**
 * Where, if anywhere, JavaScript writes `name` onto an element.
 *
 * Three shapes are accepted because all three are in use here, and each is a
 * real write rather than a mention:
 *
 *   1. `el.style.setProperty('--menu-room', …)` — the literal, in the call.
 *   2. `const WINDOW_CONTROLS_INSET = '--window-controls-inset'`, passed to a
 *      `setProperty` somewhere in the renderer. Followed across files, because
 *      the constant and its caller need not share one.
 *   3. `style={{ '--depth': String(depth) }}` — an object-literal key, in a
 *      file that hands objects to React as styles. The second half matters:
 *      without it a type declaration or a lookup table would pass as a write.
 */
function writersOf(name: string): string[] {
  const literal = quoted(name)
  const found: string[] = []
  const everything = TS_FILES.map((file) => blankComments(read(file))).join('\n')
  for (const file of TS_FILES) {
    const source = blankComments(read(file))
    if (new RegExp(`setProperty\\(\\s*${literal}`).test(source)) found.push(`${file} (setProperty)`)
    for (const bound of source.matchAll(
      new RegExp(`\\b(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*(?::[^=\\n]+)?=\\s*${literal}`, 'g'),
    )) {
      const ident = bound[1]
      if (new RegExp(`setProperty\\(\\s*${ident}\\b`).test(everything)) found.push(`${file} (${ident})`)
    }
    if (new RegExp(`${literal}\\s*:`).test(source) && /CSSProperties|style=\{/.test(source)) {
      found.push(`${file} (inline style)`)
    }
  }
  return found
}

describe('custom properties', () => {
  it('never reads a name nothing defines', () => {
    /*
     * The whole check, in three lines. Anything printed here is a declaration
     * that is being thrown away after the cascade has already chosen it —
     * either a typo, or a token somebody deleted out from under a stylesheet.
     * If the name really is published by JavaScript, it belongs in ALLOWLIST
     * with a sentence saying what it measures, and the two tests after this one
     * will hold you to that sentence.
     */
    const defined = definedNames()
    const phantom = references()
      .filter((use) => !defined.has(use.name) && !ALLOWLIST.has(use.name))
      .map((use) => `${use.where}: var(${use.name})`)
    expect(phantom).toEqual([])
  })

  it('proves every allowlisted name is still written from JavaScript', () => {
    /*
     * The half of an allowlist that normally rots. Each of these is excused on
     * the grounds that a script publishes it at runtime; delete the script and
     * the excuse becomes a permanent hole, with the stylesheet silently back on
     * its fallback and this file still passing. So the claim is re-derived from
     * the source on every run rather than trusted.
     */
    const unwritten = [...ALLOWLIST.keys()].filter((name) => writersOf(name).length === 0)
    expect(unwritten).toEqual([])
  })

  it('keeps the allowlist to names that are still read, and still absent', () => {
    /*
     * The other two ways an entry goes stale, both of which end with a line of
     * excuse outliving the thing it excused:
     *
     *   - nothing reads it any more, so it is dead weight that will be read as
     *     precedent by whoever adds the next one;
     *   - a stylesheet has since defined it for real, in which case it is an
     *     ordinary token and the general check above should be guarding it.
     */
    const reads = new Set(references().map((use) => use.name))
    const defined = definedNames()
    expect({
      unread: [...ALLOWLIST.keys()].filter((name) => !reads.has(name)),
      nowRealTokens: [...ALLOWLIST.keys()].filter((name) => defined.has(name)),
    }).toEqual({ unread: [], nowRealTokens: [] })
  })

  it('scans the stylesheets it claims to scan', () => {
    /*
     * A guard on the walker, not on the palette. Every check in this file is a
     * subtraction over a list of files; if `rendererFiles` ever returned an
     * empty list — a moved directory, a renamed extension — all four tests
     * would pass by finding nothing, which is the failure mode a sweep like
     * this is least able to notice about itself.
     */
    expect(CSS_FILES.length).toBeGreaterThan(50)
    expect(TS_FILES.length).toBeGreaterThan(50)
    expect(CSS_FILES).toContain('src/renderer/styles/tokens.css')
    expect(CSS_FILES.filter((file) => file.includes('.test.'))).toEqual([])
    expect(references().length).toBeGreaterThan(500)
    expect(definedNames().size).toBeGreaterThan(150)
  })
})
