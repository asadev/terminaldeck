import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every stylesheet closes what it opens.
 *
 * ## Why this is worth a file of its own
 *
 * On 2026-08-21 four rules in `browser/BrowserWorkspace.css` were left open by a
 * merge that joined two branches' additions to the same region by concatenating
 * them — each rule kept its selector and its first declaration or two, and the
 * next branch's rule began where its `}` should have been.
 *
 * CSS has no error to report for that. The parser folds everything after an
 * unclosed brace into the rule it never left, so **the whole rest of the bundle
 * stops applying**: the app opened with no sidebar background, `<li>` bullets on
 * the navigation, browser-default headings and a window transparent to whatever
 * was behind it. Every one of 13,457 tests passed while it did.
 *
 * The four missing braces were visible in the built bundle as a count — 3,163
 * `{` against 3,159 `}` — which is all this file checks. It is the cheapest
 * possible test for the most expensive class of failure this codebase has: one
 * that no unit test can see and only a screenshot can.
 *
 * Comments are blanked rather than removed so a brace inside prose — and this
 * repository's stylesheets are full of prose — is not counted as code.
 */
function sheets(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...sheets(path))
    else if (entry.name.endsWith('.css')) out.push(path)
  }
  return out
}

/** The source with every comment replaced by spaces of the same length. */
function code(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '))
}

const RENDERER = join(__dirname, '..')
const FILES = sheets(RENDERER)

describe('every stylesheet closes what it opens', () => {
  it('finds the stylesheets, and is not quietly checking nothing', () => {
    expect(FILES.length, 'no stylesheets found — has the renderer moved?').toBeGreaterThan(20)
  })

  for (const file of FILES) {
    const name = file.slice(RENDERER.length + 1)
    it(`${name} balances its braces`, () => {
      const source = code(readFileSync(file, 'utf8'))
      const opened = (source.match(/\{/g) ?? []).length
      const closed = (source.match(/\}/g) ?? []).length
      expect(
        opened - closed,
        `${name} leaves ${opened - closed} rule(s) open. Everything after the first ` +
          'one stops applying, and nothing else in this suite can see that.',
      ).toBe(0)
    })
  }

  it('never closes a rule that was not opened', () => {
    const offenders: string[] = []
    for (const file of FILES) {
      let depth = 0
      for (const ch of code(readFileSync(file, 'utf8'))) {
        if (ch === '{') depth += 1
        else if (ch === '}') depth -= 1
        if (depth < 0) {
          offenders.push(file.slice(RENDERER.length + 1))
          break
        }
      }
    }
    expect(offenders).toEqual([])
  })
})
