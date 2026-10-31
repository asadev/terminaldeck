#!/usr/bin/env node
/**
 * Run one extension inside this app's Electron and print what it actually did.
 *
 * ## Why this is in the repo
 *
 * `browser-extension-catalogue.ts` makes a promise in its header: *"A version
 * here is a version somebody ran. When one is bumped, the release is
 * re-measured and `measured` is rewritten to what was seen."* That promise was
 * kept by hand, with a harness that was thrown away afterwards — which means
 * the next person to bump a version either rebuilds it or quietly carries the
 * old sentence forward. The second one is how a catalogue full of measurements
 * turns into a catalogue full of remembered opinions, and nothing about the
 * file would look any different while it happened.
 *
 * So the harness is here. It is not a test and nothing in CI runs it: it needs
 * a windowing system, it takes ten seconds an extension, and half of what it
 * reports is a judgement a person makes from the output.
 *
 * ## Using it
 *
 * ```
 *   node scripts/measure-extension.mjs <unpacked-folder> [--no-compat]
 * ```
 *
 * Run it **twice** for anything whose verdict is about to change — once plain
 * and once with `--no-compat` — because the interesting number is usually the
 * difference. Without the layer uBlock Origin serves three ads out of three and
 * `hasListeners()` is false; with it, none and true. That difference is what
 * the catalogue's sentences are made of.
 *
 * ## What comes back
 *
 * JSON, on stdout. The fields that decide a verdict:
 *
 *  - `pageProbe` — `{ ad, consent, control }`, whether each request reached the
 *    server. `control` must always be `true`; if it is not, the run is broken
 *    and says nothing about the extension.
 *  - `swConsole` / `bgConsole` — what its background said, including the
 *    exception that stopped it before it started. Most refusals in the
 *    catalogue are one line from here.
 *  - `namespaces` — which `chrome.*` its own extension page can see. Only the
 *    ones it asked for appear, which is Chrome's rule and not a limitation of
 *    this probe.
 *  - `keys` — the **methods** on a handful of those namespaces. This is where
 *    `chrome.tabs.getCurrent is not a function` came from, and no manifest
 *    check could have found it: `tabs` is present and granted, and the method
 *    Bitwarden's whole UI is built on is simply not on it.
 *  - `storageSync` — `works` or the exception. Measured by writing and reading
 *    back, never by looking for the object.
 *  - `rulesets` — what `getEnabledRulesets()` answers. `[]` on an extension
 *    whose blocking is static rulesets means it installs, loads, draws an icon
 *    and blocks nothing.
 *  - `activeTab` — `chrome.tabs.query({ active: true, currentWindow: true })`
 *    from an extension page. It answers `[]` here, which is what three of the
 *    measured extensions die on one line later.
 *  - `videoRate` → `videoRateAfterKey`, `vscController`, `darkStyle` — the
 *    job-specific checks. A key is pressed twice, so a speed controller either
 *    moves the rate or does not.
 *
 * `PROBE_EVAL` in the environment is evaluated inside the extension's own page
 * and returned as `extra`. That is how native messaging was measured: connect
 * to `org.keepassxc.keepassxc_browser`, wait, read `lastError`. It answered
 * *"Access to the native messaging host was disabled by the system
 * administrator"*, and a famous password manager's row got its true sentence.
 *
 * ## The rule this obeys
 *
 * It never touches an install anybody is using. A fresh `--user-data-dir` under
 * the system temp folder, a copy of the extension rather than the original, and
 * both are deleted on the way out.
 */

import { spawn } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const args = process.argv.slice(2)
const folder = args.find((argument) => !argument.startsWith('--'))
const withCompat = !args.includes('--no-compat')

if (folder === undefined) {
  process.stderr.write('usage: node scripts/measure-extension.mjs <unpacked-folder> [--no-compat]\n')
  process.exit(2)
}
const source = resolve(folder)
if (!existsSync(join(source, 'manifest.json'))) {
  process.stderr.write(`${source} has no manifest.json in it\n`)
  process.exit(2)
}

const electron = join(
  here,
  '..',
  'node_modules',
  'electron',
  'dist',
  process.platform === 'darwin' ? 'Electron.app/Contents/MacOS/Electron' : 'electron',
)
if (!existsSync(electron)) {
  process.stderr.write(`no Electron at ${electron} — run npm install first\n`)
  process.exit(2)
}

const scratch = mkdtempSync(join(tmpdir(), 'td-measure-'))
const work = join(scratch, 'extension')
const userData = join(scratch, 'user-data')
const out = join(scratch, 'report.json')
mkdirSync(userData, { recursive: true })
cpSync(source, work, { recursive: true })

/*
 * The compatibility layer is applied the way the store applies it — by running
 * the store's own module — rather than by a copy of it here. A harness with its
 * own idea of what the layer does would measure something this app never ships.
 *
 * It is TypeScript, so it is bundled first with the esbuild that comes with
 * vite. That is a build step in a script, which is not lovely; the alternative
 * is a second implementation of the layer, which is worse.
 */
let compat = null
if (withCompat) {
  const bundle = join(scratch, 'compat.mjs')
  const esbuild = join(here, '..', 'node_modules', '.bin', 'esbuild')
  const built = spawn(
    esbuild,
    [
      join(here, '..', 'src', 'main', 'browser-extension-compat.ts'),
      '--bundle',
      '--platform=node',
      '--format=esm',
      '--external:node:*',
      `--outfile=${bundle}`,
    ],
    { stdio: 'ignore' },
  )
  const code = await new Promise((done) => built.on('exit', done))
  if (code !== 0) {
    process.stderr.write('the compatibility layer could not be bundled\n')
    rmSync(scratch, { recursive: true, force: true })
    process.exit(1)
  }
  const { applyCompat } = await import(bundle)
  compat = applyCompat(work, JSON.parse(readFileSync(join(work, 'manifest.json'), 'utf8')))
}

const port = 8700 + Math.floor(Math.random() * 900)
const child = spawn(electron, [join(here, 'measure-extension'), `--user-data-dir=${userData}`], {
  env: { ...process.env, EXT_DIR: work, OUT_JSON: out, EXT_ID: source, PORT: String(port) },
  stdio: ['ignore', 'ignore', 'pipe'],
})
let stderr = ''
child.stderr.on('data', (chunk) => {
  stderr += String(chunk)
})
const exit = await new Promise((done) => {
  const timer = setTimeout(() => {
    child.kill('SIGKILL')
    done('timed out')
  }, 90_000)
  child.on('exit', (code) => {
    clearTimeout(timer)
    done(code)
  })
})

if (!existsSync(out)) {
  process.stderr.write(`no report was written (exit ${exit})\n${stderr.split('\n').slice(-8).join('\n')}\n`)
  rmSync(scratch, { recursive: true, force: true })
  process.exit(1)
}
const report = JSON.parse(readFileSync(out, 'utf8'))
report.compat = compat
report.compatApplied = withCompat
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
rmSync(scratch, { recursive: true, force: true })
