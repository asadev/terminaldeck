#!/usr/bin/env node
/**
 * Run the sealed channel inside the runtime that actually ships it.
 *
 * `npm test` runs vitest, and vitest runs under whatever `node` is on the path.
 * That Node links OpenSSL. The product links **BoringSSL**, by way of Electron,
 * and BoringSSL has no ChaCha of any kind. So the entire end-to-end encryption
 * feature was dead in the app while 3,600-odd tests stayed green — a suite that
 * never once loaded the runtime it ships on cannot report on it.
 *
 * This script closes that hole. It bundles `sealed.electron-probe.ts` with the
 * repository's own esbuild — the same trick `android/tools/gen-sealed-fixtures.cjs`
 * and `ios/Harness/run.sh` already use, because Node cannot execute the
 * extensionless relative imports in `src/` directly — and executes the bundle
 * under `ELECTRON_RUN_AS_NODE=1`, which is Electron's own Node with Electron's
 * own crypto and no window anywhere near it. It needs no display, so it runs
 * headless in CI exactly as it does here.
 *
 * ## Why it fails instead of skipping
 *
 * A skip is how this bug survived a day. If Electron is not installed the
 * correct answer is a red build with the command to fix it, not a quiet pass
 * that means nothing. The one thing this script must never do is agree that
 * everything is fine because it could not look.
 *
 *   node scripts/check-electron-crypto.mjs
 */

import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const require_ = createRequire(import.meta.url)
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PROBE = join(REPO, 'src/main/remote/sealed.electron-probe.ts')
const OUT_DIR = join(REPO, 'node_modules/.cache/terminaldeck')
const BUNDLE = join(OUT_DIR, 'sealed-electron-probe.cjs')

function die(message) {
  process.stderr.write(`\n[electron-crypto] ${message}\n\n`)
  process.exit(1)
}

/* --------------------------------------------------------------- the scan */

/**
 * Every algorithm named in the Node-side sources, for the probe to check
 * against Electron's own `getCiphers()`/`getHashes()`.
 *
 * The first half of this file guards the bug that happened. This half guards
 * the next one: reach for any primitive BoringSSL lacks, anywhere in
 * `src/main`, `src/shared`, `src/preload` or `relay/src`, and the build goes
 * red with the name of the file that did it — including files nobody has
 * written yet.
 *
 * Comments are stripped by running each file through esbuild rather than by
 * regex, because the first version of this scan flagged `sealed.ts` for a
 * `createCipheriv('chacha20-poly1305', …)` that only ever appeared in a
 * sentence explaining why it no longer calls it. A real parser knows the
 * difference between code and prose; a regex over raw text does not.
 *
 * `*.test.ts` is skipped on purpose. Tests run under plain Node, so a test that
 * reaches for an exotic cipher is not a bug — it is product code that has to
 * survive BoringSSL, and product code is what this scans.
 */
const SOURCE_ROOTS = ['src/main', 'src/shared', 'src/preload', 'relay/src']

const USES = [
  { pattern: /create(?:Cipher|Decipher)iv\(\s*['"]([^'"]+)['"]/g, kind: 'cipher' },
  { pattern: /createHash\(\s*['"]([^'"]+)['"]/g, kind: 'hash' },
  { pattern: /createHmac\(\s*['"]([^'"]+)['"]/g, kind: 'hash' },
  { pattern: /hkdfSync\(\s*['"]([^'"]+)['"]/g, kind: 'hash' },
]

function* sourceFiles(dir) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) yield* sourceFiles(full)
    else if (/\.tsx?$/.test(entry.name) && !/\.test\.tsx?$/.test(entry.name)) yield full
  }
}

function scanAlgorithms() {
  let transformSync
  try {
    ;({ transformSync } = require_('esbuild'))
  } catch {
    die('esbuild is not installed — run `npm ci`.')
  }

  const found = new Map()
  let scanned = 0

  for (const root of SOURCE_ROOTS) {
    for (const file of sourceFiles(join(REPO, root))) {
      const where = file.slice(REPO.length + 1)
      let code
      try {
        // Comments gone, strings and regex literals intact.
        code = transformSync(readFileSync(file, 'utf8'), {
          loader: file.endsWith('.tsx') ? 'tsx' : 'ts',
          format: 'esm',
        }).code
      } catch (err) {
        die(`${where} does not parse, so it could not be scanned: ${err.message}`)
      }
      scanned += 1
      for (const { pattern, kind } of USES) {
        for (const match of code.matchAll(pattern)) {
          const key = `${kind}:${match[1]}`
          const entry = found.get(key) ?? { kind, name: match[1], where: [] }
          if (!entry.where.includes(where)) entry.where.push(where)
          found.set(key, entry)
        }
      }
    }
  }

  if (scanned === 0) die(`no sources found under ${SOURCE_ROOTS.join(', ')} — this check has gone stale.`)
  if (found.size === 0) {
    die(
      `scanned ${scanned} files and matched no algorithm name at all. ` +
        'The patterns in this file have gone stale and the check is no longer checking anything.',
    )
  }

  process.stdout.write(
    `[electron-crypto] scanned ${scanned} source files, found ${found.size} algorithm names\n`,
  )
  return [...found.values()].sort((a, b) => `${a.kind}:${a.name}`.localeCompare(`${b.kind}:${b.name}`))
}

/* ------------------------------------------------------------------ electron */

// `require('electron')` from Node resolves to the path of the binary, on every
// platform. Reading it this way rather than guessing at `dist/Electron.app/...`
// is what keeps this working on the Windows build.
let electron
try {
  electron = require_('electron')
} catch {
  die('electron is not installed. Run `npm ci` — this check must not be skipped.')
}
if (typeof electron !== 'string' || !existsSync(electron)) {
  die(
    `the electron binary is missing (${String(electron)}). Run \`npm ci\`.\n` +
      'This check fails rather than skipping: a skip here is exactly how a dead cipher shipped.',
  )
}

/* ------------------------------------------------------------------- bundle */

// Bundled through esbuild's JS API rather than by spawning its executable,
// because there is no one path that runs on both platforms. On macOS
// `node_modules/esbuild/bin/esbuild` IS the native Go binary; on Windows it is
// a JS shim and the real thing is `@esbuild/win32-x64/esbuild.exe`, while
// `.bin/esbuild` there is a Git Bash shell script that `CreateProcess` refuses.
// Naming `.bin/esbuild` made this check die with "the probe did not bundle" on
// Windows — the one platform whose BoringSSL it exists to interrogate, and the
// same `.cmd` shim shape as the bug in `providers.ts`, in the tool whose job is
// to stop a broken cipher shipping.
//
// The API is already imported above for the comment-stripping scan, needs no
// subprocess, and behaves identically everywhere.
mkdirSync(OUT_DIR, { recursive: true })
rmSync(BUNDLE, { force: true })

try {
  const { buildSync } = require_('esbuild')
  buildSync({
    entryPoints: [PROBE],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node22',
    // Electron supplies these; bundling them would be wrong and, for `electron`
    // itself, impossible.
    external: ['electron'],
    outfile: BUNDLE,
  })
} catch (err) {
  die(`the probe did not bundle: ${err.message}`)
}

/* ---------------------------------------------------------------------- run */

const algorithms = scanAlgorithms()

process.stdout.write(`[electron-crypto] running the sealed channel under ${electron}\n`)

const run = spawnSync(electron, [BUNDLE], {
  stdio: 'inherit',
  env: {
    ...process.env,
    // Electron's Node, not Electron's browser. No display is opened.
    ELECTRON_RUN_AS_NODE: '1',
    // The probe reads the committed fixtures; it is executing from a bundle in
    // node_modules and cannot find the repository itself.
    TD_REPO_ROOT: REPO,
    // Scanned here, where esbuild lives; checked there, where BoringSSL does.
    TD_ALGORITHMS: JSON.stringify(algorithms),
  },
})

if (run.error) die(`could not start electron: ${run.error.message}`)
if (run.status !== 0) {
  die(
    `the sealed channel FAILED under Electron (exit ${run.status}).\n` +
      'The desktop app is broken even if `vitest` is green — that is the whole reason this check exists.',
  )
}

process.stdout.write('[electron-crypto] the sealed channel works in the runtime that ships it.\n')
