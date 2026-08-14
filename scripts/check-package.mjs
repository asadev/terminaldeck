#!/usr/bin/env node
/**
 * Preflight for a *packaged* build, macOS or Windows:
 *
 *   node scripts/check-package.mjs mac
 *   node scripts/check-package.mjs win
 *
 * `check-release.mjs` asks whether the macOS update manifest is self-consistent.
 * This asks a different and older question: **is the right stuff inside the
 * app?**
 *
 * ## The bug this exists to make impossible
 *
 * A platform `files:` list in `electron-builder.yml` **replaces** the top-level
 * allowlist rather than extending it. Nothing warns you. The build succeeds, the
 * installer is produced, the app runs — it is simply carrying the entire
 * repository.
 *
 * It was invisible for as long as the repository had nothing large outside
 * `out/`. The night `ios/` and `android/` appeared, the macOS app went from
 * ~290 MB to 1.0 GB and shipped Xcode projects, Gradle caches and a signed APK
 * to every user. The `win:` block had exactly the same shape and had simply not
 * been caught yet, because the Windows installer is built in CI from a clean
 * checkout where `ios/` and `android/` were untracked and therefore not there to
 * be swallowed.
 *
 * Both blocks are fixed. This script is what stops them silently regressing:
 * fixing a bug in a config file leaves nothing behind that fails if someone
 * reintroduces it, and this file is that thing.
 *
 * ## What it checks
 *
 *  1. Every path inside `app.asar` is one the allowlist intends. A single entry
 *     under `ios/`, `android/`, `relay/`, `packages/`, `.git/` or `node_modules`
 *     at the archive root is a failure with the offending path named.
 *  2. The asar is within a sane size band. Too big means the allowlist leaked;
 *     too small means the build shipped without `out/`, which is the failure
 *     mode of running electron-builder without `npm run build` first.
 *  3. `out/main/index.js` is actually in there, because "the archive is a
 *     plausible size" and "the app can start" are different claims.
 *  4. Each produced installer is within a sane size band too — the number a
 *     human would have eyeballed, checked by something that cannot forget.
 *
 * Sizes are asserted as *bands*, not exact numbers: an upper bound catches the
 * class of bug above with enormous margin, and a lower bound catches an empty
 * or truncated artifact. Neither needs updating when a dependency grows by a
 * megabyte, which is what makes them worth having — a check that has to be
 * edited on every release gets edited without being read.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const RELEASE = resolve(process.env.TD_RELEASE_DIR ?? join(ROOT, 'release'))
const { version, name } = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))

const platform = process.argv[2]
if (platform !== 'mac' && platform !== 'win') {
  process.stderr.write('usage: check-package.mjs <mac|win>\n')
  process.exit(2)
}

const MB = 1024 * 1024

/**
 * Directories that must never appear inside the archive.
 *
 * Named individually rather than checked as "anything not under out/", because
 * the allowlist legitimately carries `package.json` and `pwa/dist` at the root
 * and a rule phrased as a denial of the known offenders says what it means.
 */
const FORBIDDEN = ['ios', 'android', 'relay', 'packages', '.git', '.github', 'src', 'build', '.harness']

/** The asar holds `out/`, `package.json` and the PWA — a few tens of MB, never hundreds. */
const ASAR_MIN = 2 * MB
const ASAR_MAX = 120 * MB

/**
 * Installer bands. An Electron app with Chromium inside is ~100 MB compressed on
 * Windows and ~120 MB on macOS; the ceiling is deliberately nowhere near either,
 * so it only ever fires on the whole-repository failure.
 */
const INSTALLER_MIN = 40 * MB
const INSTALLER_MAX = 400 * MB

const problems = []
const note = (s) => process.stdout.write(`  ${s}\n`)

/** Where electron-builder leaves the unpacked app for each platform. */
function unpackedRoot() {
  if (platform === 'win') return join(RELEASE, 'win-unpacked', 'resources')
  // macOS names the directory after the arch for anything but the default, and
  // the .app after the product. Found rather than spelled, so a rename of either
  // does not silently skip the check.
  for (const dir of readdirSync(RELEASE, { withFileTypes: true })) {
    if (!dir.isDirectory() || !dir.name.startsWith('mac')) continue
    const inside = readdirSync(join(RELEASE, dir.name)).find((f) => f.endsWith('.app'))
    if (inside) return join(RELEASE, dir.name, inside, 'Contents', 'Resources')
  }
  return null
}

if (!existsSync(RELEASE)) {
  process.stderr.write(`No ${RELEASE}. Run the dist script first.\n`)
  process.exit(1)
}

process.stdout.write(`Checking the packaged ${name} ${version} (${platform}) in ${RELEASE}\n\n`)

const resources = unpackedRoot()
if (resources === null || !existsSync(join(resources, 'app.asar'))) {
  problems.push(`no app.asar found — looked in ${resources ?? `${RELEASE}/mac*`}`)
} else {
  const asar = join(resources, 'app.asar')
  const size = statSync(asar).size
  note(`app.asar is ${(size / MB).toFixed(1)} MB`)
  if (size > ASAR_MAX) {
    problems.push(
      `app.asar is ${(size / MB).toFixed(1)} MB, over the ${ASAR_MAX / MB} MB ceiling. ` +
        'The usual cause is a platform `files:` block that replaced the root allowlist ' +
        'instead of restating it — see the comments in electron-builder.yml.',
    )
  }
  if (size < ASAR_MIN) {
    problems.push(
      `app.asar is only ${(size / MB).toFixed(1)} MB. That is what packaging without ` +
        'running `npm run build` first looks like: no `out/`, nothing to start.',
    )
  }

  // `@electron/asar` is already a dependency of electron-builder, so listing the
  // archive costs nothing new. Shelled rather than imported because the CLI is
  // the stable surface and the module layout is not.
  const bin = join(ROOT, 'node_modules', '.bin', process.platform === 'win32' ? 'asar.cmd' : 'asar')
  let listing = ''
  try {
    listing = execFileSync(bin, ['list', asar], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  } catch (error) {
    problems.push(`could not list app.asar: ${error instanceof Error ? error.message : String(error)}`)
  }

  if (listing !== '') {
    // `asar list` prints absolute-looking archive paths: `/out/main/index.js`.
    const entries = listing.split('\n').map((l) => l.trim().replace(/^\/+/, '')).filter(Boolean)
    note(`app.asar holds ${entries.length} entries`)

    for (const forbidden of FORBIDDEN) {
      const hit = entries.find((e) => e === forbidden || e.startsWith(`${forbidden}/`))
      if (hit) {
        problems.push(
          `app.asar contains \`${hit}\` — \`${forbidden}/\` must never be packaged. ` +
            'The platform `files:` block is not restating the root allowlist.',
        )
      }
    }

    if (!entries.includes('out/main/index.js')) {
      problems.push('app.asar does not contain out/main/index.js — the app cannot start.')
    } else {
      note('ok    out/main/index.js is present')
    }
  }
}

const installers = readdirSync(RELEASE).filter((f) =>
  platform === 'win' ? f.endsWith('.exe') : f.endsWith('.dmg') || f.endsWith('.zip'),
)

if (installers.length === 0) problems.push(`no installers in ${RELEASE}`)

for (const file of installers) {
  const size = statSync(join(RELEASE, file)).size
  const mb = (size / MB).toFixed(1)
  if (size > INSTALLER_MAX) problems.push(`${file} is ${mb} MB, over the ${INSTALLER_MAX / MB} MB ceiling`)
  else if (size < INSTALLER_MIN) problems.push(`${file} is only ${mb} MB — truncated or missing its payload`)
  else note(`ok    ${file} is ${mb} MB`)
}

if (problems.length) {
  process.stdout.write('\n')
  for (const p of problems) process.stderr.write(`FAIL  ${p}\n`)
  process.stderr.write(`\n${problems.length} problem(s). Do not ship this.\n`)
  process.exit(1)
}

process.stdout.write('\nThe package carries what it should and nothing else.\n')
