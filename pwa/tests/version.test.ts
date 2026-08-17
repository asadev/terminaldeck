import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

import config from '../vite.config'

/**
 * The build number on the Settings screen is a real one.
 *
 * The phone has shown its version in Settings since it had a Settings; this
 * client had none anywhere, which is a gap with teeth rather than a missing
 * ornament. A browser updates itself while nobody is watching, can be installed
 * to a home screen, and serves its own shell out of a service-worker cache —
 * and `vite.config.ts` stamps that cache with a content hash *because* shipping
 * an update nobody receives is the expected failure of a PWA. When it happens,
 * the first question is which build you are on.
 *
 * A number that answers that question wrongly is worse than none, so what is
 * pinned here is that it comes from the right place and cannot quietly become a
 * literal, a stale copy, or the string `undefined`.
 *
 * ## Why `src/version.ts` is read as text rather than imported
 *
 * Because importing it here would require declaring `__APP_VERSION__` for the
 * Node-side program, and that declaration would be a lie: Vite substitutes the
 * token in the browser bundle, and under vitest — plain Node, no bundler — it
 * genuinely does not exist. `pwa/tsconfig.node.json` deliberately does not see
 * `src/runtime/build-info.d.ts` for exactly that reason. So the module's own
 * safety net is checked the way `layout.test.ts` and `no-cost.test.ts` check
 * theirs: as the text of a decision that is invisible in a diff and silent in a
 * typecheck.
 */

const here = (rel: string): string => fileURLToPath(new URL(rel, import.meta.url))

const read = (rel: string): string => readFileSync(here(rel), 'utf8')

/** The token Vite replaces, as `define` was handed it. */
function defined(): string {
  const raw = (config.define ?? {})['__APP_VERSION__']
  expect(raw, 'vite.config.ts does not define __APP_VERSION__ at all').toBeDefined()
  // `define` substitutes raw source text, so the value has to be a JSON string
  // literal. Parsing it here is also the check that it is one: an unquoted
  // version would splice a bare identifier into the bundle.
  return JSON.parse(String(raw)) as string
}

describe('the version this client reports', () => {
  it('is the repository version, not this directory\'s own', () => {
    /*
     * The bug this is aimed at is a one-character fix in the wrong direction:
     * `here('package.json')` instead of `here('../package.json')`. Both compile,
     * both produce a plausible semver, and the wrong one reports `0.1.0` — a
     * number nobody has bumped since this client was created and that no release,
     * tag or changelog entry has ever meant.
     */
    const root = JSON.parse(read('../../package.json')) as { version: string }
    expect(defined()).toBe(root.version)
    expect(defined()).toMatch(/^\d+\.\d+\.\d+/)
  })

  it('keeps its own package.json out of it', () => {
    /*
     * Stated as its own expectation rather than folded into the one above,
     * because the two only differ while the numbers differ — and the day
     * somebody "tidies up" by syncing `pwa/package.json` to the root, the check
     * above would still pass while reading the wrong file. This one names the
     * file that must not be the source.
     */
    expect(read('../vite.config.ts')).toContain("here('../package.json')")
  })

  it('survives being read where nothing substituted it', () => {
    /*
     * `__APP_VERSION__` is a token, not a variable: outside a Vite build the
     * identifier does not exist, and reading it bare throws a `ReferenceError`
     * rather than yielding `undefined`. The `typeof` guard is what keeps
     * `version.ts` importable from a plain Node context at all — remove it and
     * the module stops loading in exactly the environment a future test would
     * load it from.
     */
    const source = read('../src/version.ts')
    expect(source).toContain("typeof __APP_VERSION__ === 'string'")
    /*
     * And the fallback is not a plausible version. `'0.0.0'` or `''` would slot
     * into the About row looking like an answer; `'unknown'` says out loud that
     * nobody stamped this build, which is the only honest thing to say when
     * nobody did.
     */
    expect(source).toContain("'unknown'")
    expect(source).not.toMatch(/:\s*string\s*=[^\n]*'0\.0\.0'/)
  })

  it('is drawn on the Settings screen and nowhere invented', () => {
    /*
     * The end of the chain. `main.ts` builds its DOM against a real browser and
     * nothing here can render it, so what is checked is that the About row reads
     * the injected constant rather than carrying a hardcoded string — the
     * failure mode being a version that stays at whatever it said the day it was
     * written, which is indistinguishable from a correct one on screen.
     */
    const main = read('../src/main.ts')
    expect(main).toContain("import { VERSION } from './version'")
    expect(main).toContain("element('p', 'caption', 'About')")
    expect(main).toContain("element('span', 'setting__value setting__value--mono', VERSION)")
  })
})
