/**
 * Everything the client compiles from is in the upload, or this fails.
 *
 * ## The failure this exists to stop
 *
 * `app.terminaldeck.dev` builds on Vercel with the Root Directory set to `pwa`,
 * from an upload that `/.vercelignore` allowlists: the whole working tree is
 * 2.7 GB, nearly all of it `ios/`, `android/` and `release/`, and it also holds
 * a live control-socket token in `host.json` that has no business on somebody
 * else's build machine. So the deployment names what goes, rather than naming
 * what stays.
 *
 * An allowlist has one failure mode and the first deploy of this client hit it
 * twice in a row. `pwa/src/` does not compile from `pwa/` alone — it reaches
 * across to `src/shared/` for the sealed channel and the pairing formats, to
 * `src/main/remote/protocol.ts` for the wire protocol, and to
 * `src/renderer/assets/fonts/` for the two faces the stylesheet declares. Every
 * one of those crossings is deliberate and is there so the browser does not run
 * a second copy of something the rest of the product already has. Every one of
 * them also has to be named in the ignore file, and on this Mac the build
 * succeeds whether they are or not, because the files are simply *there*.
 *
 * So the check runs here, in the suite, rather than being discovered as a red
 * build with a Rollup stack trace in it.
 *
 * ## What it models, and what it does not
 *
 * It walks the client's own module graph — relative imports from
 * `pwa/src/main.ts` outwards, plus `url(…)` in any stylesheet it reaches — and
 * asks of every file whether `/.vercelignore` names a path that covers it.
 *
 * It does **not** reimplement gitignore. It reads the `!`-prefixed lines, which
 * are the only thing that puts a file in the upload, and treats each as a
 * covering prefix. That is exact for a file this walk found, because a file is
 * uploaded only if some `!` line covers it — but it would not notice a pattern
 * added later that re-ignores something more deeply. If that ever happens the
 * Vercel build fails loudly and never promotes, which is the backstop this test
 * exists to make unnecessary rather than to replace.
 *
 * Bare specifiers are skipped on purpose: `@xterm/*`, `@noble/*` and `buffer`
 * arrive from `pwa/node_modules`, which Vercel installs itself from
 * `pwa/package-lock.json` and which the upload deliberately excludes.
 */

import { readFileSync, existsSync, statSync } from 'node:fs'
import { dirname, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const repo = fileURLToPath(new URL('../..', import.meta.url))
const entry = resolve(repo, 'pwa/src/main.ts')

/** The paths `/.vercelignore` puts back into the upload, repo-relative. */
function allowlist(): string[] {
  return readFileSync(resolve(repo, '.vercelignore'), 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('!/'))
    .map((line) => line.slice(2))
}

/**
 * A relative specifier turned into the file on disk it means.
 *
 * TypeScript sources are written without extensions and Vite adds them back, so
 * the candidates are tried in the order the bundler would. `null` for anything
 * that is not there — the caller reports it, because a missing import is a
 * different failure from an unuploaded one and the two must not be confused.
 */
function fileFor(specifier: string, importer: string): string | null {
  const base = resolve(dirname(importer), specifier)
  for (const candidate of [base, `${base}.ts`, `${base}.js`, `${base}/index.ts`]) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate
  }
  return null
}

/** Every file the client's own sources reach, entry included. */
function graph(): string[] {
  const seen = new Set<string>()
  const queue = [entry]
  while (queue.length > 0) {
    const file = queue.pop() as string
    if (seen.has(file)) continue
    seen.add(file)
    if (!/\.(ts|css)$/.test(file)) continue
    const source = readFileSync(file, 'utf8')
    const specifiers = [
      // `import … from '…'`, `import '…'`, and `export … from '…'`.
      ...source.matchAll(/(?:from|import)\s*['"]([^'"]+)['"]/g),
      // `url('…')` in a stylesheet. This is the one that carries the fonts, and
      // the one no amount of reading the TypeScript would have found.
      ...source.matchAll(/url\(\s*['"]?([^'")]+)['"]?\s*\)/g),
    ].map((match) => match[1])

    for (const specifier of specifiers) {
      if (!specifier.startsWith('.')) continue
      const found = fileFor(specifier, file)
      expect(found, `${relative(repo, file)} imports ${specifier}, which is not on disk`).not.toBeNull()
      queue.push(found as string)
    }
  }
  return [...seen]
}

describe('the files app.terminaldeck.dev is built from', () => {
  it('are all inside what /.vercelignore uploads', () => {
    const allowed = allowlist()
    const missing = graph()
      // `/` on every platform, because the thing being compared is a
      // `.vercelignore` line — and that file uses forward slashes wherever it is
      // read from. `relative()` follows the host instead, so on Windows every
      // path arrived as `pwa\src\backoff.ts`, matched no prefix, and this
      // assertion reported all 24 files as missing from a list that already
      // named them. It failed only on the runner that builds the Windows
      // installer, about a file that Vercel reads on Linux.
      .map((file) => relative(repo, file).split(sep).join('/'))
      .filter((path) => !allowed.some((prefix) => path === prefix || path.startsWith(`${prefix}/`)))
      .sort()

    expect(
      missing,
      'these are compiled into the client and would not reach the build machine — ' +
        'name them in /.vercelignore, the way src/main/remote/protocol.ts is',
    ).toEqual([])
  })

  it('cross out of pwa/ only where the product has one implementation to share', () => {
    // Not a rule against reaching across — the reaching is the point, and
    // `pwa/vite.config.ts` and `endpoint.ts` both argue for it. This is a
    // fixture: it makes a new crossing something somebody has to write down,
    // rather than something that appears in a bundle. Adding to this list is a
    // fine thing to do; doing it without noticing is not.
    const crossings = graph()
      // Same separator fold as above, and for the same reason: this list is
      // written with `/` because that is how the paths appear everywhere they
      // matter — the ignore file, the imports, the repository.
      .map((file) => relative(repo, file).split(sep).join('/'))
      .filter((path) => !path.startsWith('pwa/'))
      .sort()

    expect(crossings).toEqual([
      'src/main/remote/protocol.ts',
      'src/renderer/assets/fonts/hanken-grotesk.woff2',
      'src/renderer/assets/fonts/jetbrains-mono.woff2',
      'src/shared/brand.ts',
      'src/shared/pairing-link.ts',
      'src/shared/relay-wire.ts',
      // The playhead for the copilot's scan, and the clearest case this fixture
      // has for the rule it exists to enforce. Its own header says it lives in
      // `shared/` *because* three surfaces have to run one copy of it — the
      // desktop renderer, the main process's tour tool and this client — and a
      // second implementation here is how two clients come to disagree about
      // what a scan is. So the crossing is deliberate and this line is where
      // that was written down.
      'src/shared/scan.ts',
      'src/shared/sealed.ts',
      'src/shared/short-code.ts',
    ])
  })
})
