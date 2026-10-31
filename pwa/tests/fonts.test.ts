import { existsSync } from 'node:fs'
import { readFileSync } from 'node:fs'
import { dirname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

import config, { FONT_DIR } from '../vite.config'

/**
 * The two webfaces reach the browser — in a build *and* on the dev server.
 *
 * ## The bug this exists to stop, which was live and invisible for weeks
 *
 * `src/styles.css` points both `@font-face` rules at `../../src/renderer/assets/
 * fonts/`, one directory above this client's Vite root. That is deliberate: the
 * desktop and this client draw the same product and there is one copy of each
 * face, not two that drift apart.
 *
 * A production build follows those `url()`s without being asked and emits both
 * files into `dist/assets/`. A **dev server** does not: serving a file from
 * outside the root goes through `/@fs/`, and Vite refuses that unless the
 * directory is on `server.fs.allow`. It was not, so both requests answered
 * **403**, `document.fonts` reported `Hanken Grotesk error` and `JetBrains Mono
 * error`, and every screen fell back to `-apple-system` and the system mono.
 *
 * What made it worth a test rather than a one-line fix is *where* it was
 * invisible. Nothing in this suite renders — `main.ts` builds its DOM against a
 * real browser and vitest here has no DOM — so `vite dev` is the only thing that
 * can be looked at, and it is what `.harness/web-drive.mjs` drives and
 * photographs. Every screenshot ever taken of this client, by a person or by the
 * harness, was in a typeface it does not ship. A harness that renders the wrong
 * font is not a slightly weaker check. It is a check that will eventually
 * approve a layout the product cannot draw, and say nothing.
 *
 * ## Why it reads the config rather than starting a server
 *
 * Starting Vite here would make this the slowest file in the suite and would
 * test Vite rather than this repository's decisions. What can go wrong is not
 * that `fs.allow` stops working; it is that somebody moves the fonts, renames
 * the directory, or adds a third face from somewhere new — and each of those is
 * a claim about *paths*, which is exactly what can be checked without a server.
 *
 * So: every `@font-face` url in the stylesheet is resolved the way a browser
 * would resolve it, and each one has to (a) exist on disk and (b) sit inside a
 * directory the dev server is configured to hand out.
 */

const here = (rel: string): string => fileURLToPath(new URL(rel, import.meta.url))

const STYLES = here('../src/styles.css')
const ROOT = here('..')

/** Every `src: url(...)` in the stylesheet, resolved against the stylesheet. */
function faces(): Array<{ family: string; path: string; url: string }> {
  const text = readFileSync(STYLES, 'utf8')
  const found: Array<{ family: string; path: string; url: string }> = []
  for (const block of text.matchAll(/@font-face\s*\{([^}]*)\}/g)) {
    const body = block[1]
    const family = /font-family:\s*'([^']+)'/.exec(body)?.[1] ?? '(unnamed)'
    for (const source of body.matchAll(/url\(\s*'([^']+)'\s*\)/g)) {
      const url = source[1]
      found.push({ family, url, path: resolve(dirname(STYLES), url) })
    }
  }
  return found
}

/** Is `path` inside `directory` — by path segments, not by string prefix. */
function inside(directory: string, path: string): boolean {
  const step = relative(directory, path)
  return step !== '' && !step.startsWith('..') && !step.startsWith(sep)
}

describe('the webfonts this client draws itself in', () => {
  it('declares both faces the product uses', () => {
    // Not a count for its own sake: the pair is the whole typographic system —
    // one text face and one mono — and a third arriving is precisely the change
    // that should come past this file to have its directory allowed.
    expect(faces().map((face) => face.family).sort()).toEqual(['Hanken Grotesk', 'JetBrains Mono'])
  })

  it('points every face at a file that is actually there', () => {
    for (const face of faces()) {
      expect(existsSync(face.path), `${face.family} points at ${face.url}, which is not on disk`).toBe(true)
    }
  })

  it('keeps every face inside a directory the dev server may serve', () => {
    /*
     * The assertion the 403 would have failed, and it reads the *config object*
     * rather than a constant standing in for it. `defineConfig` is an identity
     * function on a plain object, so importing the module is importing the very
     * settings `vite dev` runs on — which means deleting the `FONT_DIR` entry
     * from `server.fs.allow` fails this test, and nothing weaker would. Checking
     * only `FONT_DIR` would have let somebody remove the entry and keep the
     * export, which is precisely the shape of an undone fix.
     */
    const allowed = config.server?.fs?.allow ?? []
    expect(allowed.length, 'server.fs.allow is empty, so Vite falls back to its default root').toBeGreaterThan(0)

    for (const face of faces()) {
      const served = allowed.some((directory) => inside(directory, face.path))
      expect(
        served,
        `${face.family} resolves to ${face.path}, which no entry on server.fs.allow covers — ` +
          'the dev server will answer 403 and the client will silently fall back to a system font',
      ).toBe(true)
    }
  })

  it('does not hand out the whole checkout to get them', () => {
    /*
     * The other half of the same decision, because the easy way to make the test
     * above pass is `allow: ['..']` — and this dev server is bound to `host:
     * true`, so that would put `credentials/`, any `.env` and the harness's host
     * identity one `/@fs/` request away from anybody on the same network. The
     * repository root is named here and refused by name.
     */
    const allowed = config.server?.fs?.allow ?? []
    const repo = resolve(ROOT, '..')
    for (const directory of allowed) {
      expect(
        resolve(directory),
        `server.fs.allow contains ${directory}, which serves the entire checkout over the network`,
      ).not.toBe(repo)
      expect(inside(resolve(directory), repo), `${directory} is above the repository`).toBe(false)
    }
  })

  it('still climbs out of pwa/ rather than keeping a second copy', () => {
    /*
     * The other direction, so this file cannot be satisfied by copying the two
     * woff2 files into `pwa/` and deleting the allow-list entry. That would make
     * the test pass and would reintroduce the thing the shared path exists to
     * prevent: two copies of a typeface, one of which gets updated.
     *
     * `FONT_DIR` is asserted to be outside the Vite root for the same reason —
     * if it ever stops being, this expectation is the thing that says so out
     * loud instead of the arrangement quietly changing meaning.
     */
    expect(inside(ROOT, FONT_DIR)).toBe(false)
    for (const face of faces()) expect(inside(FONT_DIR, face.path)).toBe(true)
  })
})
