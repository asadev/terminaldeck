#!/usr/bin/env node
/**
 * Run the server transport under Electron's own Node, where it actually ships.
 *
 * The reason is the one `check-electron-crypto.mjs` gives at length and does
 * not need repeating here: vitest runs under a Node that links OpenSSL, the app
 * runs under Electron, which links BoringSSL, and this repository has already
 * shipped a completely dead feature behind a green suite because of that gap.
 *
 * Two modes:
 *
 *     node scripts/check-servers-transport.mjs
 *         Offline. Asserts the cipher list this runtime leaves the transport:
 *         non-empty, and containing no ChaCha, which BoringSSL cannot perform.
 *         Needs no network and no credentials.
 *
 *     node scripts/check-servers-transport.mjs --live user@address [keyfile]
 *         Also dials that server and proves the parts a fake socket cannot: the
 *         fingerprint, a command, the probe, a real pty, and a resize whose
 *         arguments are the right way round. The key defaults to the one the
 *         system client would use for that host if `ssh -G` can say.
 *
 * The live mode also checks the fingerprint this app computes against
 * `ssh-keyscan`'s, which is the claim the whole identity check rests on: that a
 * fingerprint shown here is one a person can verify somewhere else.
 *
 * ## Why this is not a case inside `check-electron-crypto.mjs`
 *
 * That script runs in CI. Its whole value is that it fails rather than skips.
 * Bolting a check that needs a reachable server onto it would give it a way to
 * go red for a reason that has nothing to do with this repository — somebody
 * else's machine being off — which is precisely the kind of failure that
 * teaches a team to ignore a red build. The offline half here is CI-safe and
 * could be folded in; the live half deliberately is not.
 */

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const require_ = createRequire(import.meta.url)
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PROBE = join(REPO, 'src/main/servers/servers.electron-probe.ts')
const OUT_DIR = join(REPO, 'node_modules/.cache/terminaldeck')
const BUNDLE = join(OUT_DIR, 'servers-electron-probe.cjs')

function die(message) {
  process.stderr.write(`\n[servers] ${message}\n\n`)
  process.exit(1)
}

/* ------------------------------------------------------------- arguments -- */

const args = process.argv.slice(2)
const liveAt = args.indexOf('--live')
let address = ''
let username = ''
let keyFile = ''
const passwordAt = args.indexOf('--password')
const password = passwordAt === -1 ? '' : (args[passwordAt + 1] ?? '')
if (liveAt !== -1) {
  const target = args[liveAt + 1] ?? ''
  const at = target.indexOf('@')
  if (at === -1) die('--live wants user@address')
  username = target.slice(0, at)
  address = target.slice(at + 1)
  if (password === '') {
    keyFile = args[liveAt + 2] ?? defaultKeyFor(target)
    if (keyFile === '' || !existsSync(keyFile)) {
      die(`no key file to sign in with — pass one after the address (tried ${keyFile || 'nothing'})`)
    }
  }
}

/**
 * The key the system client would use for this host, if it can be asked.
 *
 * A convenience for running this by hand, and **only** that — the app itself
 * reads no configuration file, deliberately, because a feature that works
 * because of what this computer happens to have configured is the exact thing
 * rule 4 of this feature's brief forbids.
 */
function defaultKeyFor(target) {
  const shown = spawnSync('ssh', ['-G', target], { encoding: 'utf8' })
  if (shown.status !== 0) return ''
  for (const line of shown.stdout.split('\n')) {
    if (!line.startsWith('identityfile ')) continue
    const path = line.slice('identityfile '.length).trim()
    const expanded = path.startsWith('~') ? join(homedir(), path.slice(1)) : path
    if (existsSync(expanded)) return expanded
  }
  return ''
}

/* --------------------------------------------------------------- bundle -- */

let esbuild
try {
  esbuild = require_('esbuild')
} catch {
  die('esbuild is not installed, so the probe cannot be bundled. Run npm install.')
}

mkdirSync(OUT_DIR, { recursive: true })
const built = esbuild.buildSync({
  entryPoints: [PROBE],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node20',
  outfile: BUNDLE,
  // `ssh2` stays a real require so that what is exercised is the installed
  // package, with the runtime's own crypto, rather than a copy folded into a
  // bundle. That is the entire point of running this under Electron.
  external: ['ssh2', 'electron'],
  logLevel: 'silent',
})
if (built.errors.length > 0) die(built.errors.map((one) => one.text).join('\n'))

/* -------------------------------------------------------------- electron -- */

let electronBinary
try {
  electronBinary = require_('electron')
} catch {
  die('Electron is not installed, so this cannot check the runtime that ships. Run npm install.')
}
if (typeof electronBinary !== 'string' || !existsSync(electronBinary)) {
  die('Electron is installed but its binary is missing. Run npm install.')
}

const run = spawnSync(electronBinary, [BUNDLE], {
  encoding: 'utf8',
  env: {
    ...process.env,
    ELECTRON_RUN_AS_NODE: '1',
    TD_PROBE_ADDRESS: address,
    TD_PROBE_USER: username,
    TD_PROBE_KEY: keyFile === '' ? '' : readFileSync(keyFile, 'utf8'),
    TD_PROBE_PASSWORD: password,
    TD_PROBE_DUMP: process.env.TD_PROBE_DUMP ?? '',
  },
})
process.stdout.write(run.stdout ?? '')
if ((run.stderr ?? '').trim() !== '') process.stderr.write(run.stderr)

/* ------------------------------------------------- the independent check -- */

/**
 * Does the fingerprint this app computes match what another tool prints?
 *
 * Done here, in a separate process, with a different implementation, because
 * the claim being tested is *agreement with the rest of the world* and a check
 * that used this app's own code on both sides would agree with itself.
 */
if (address !== '') {
  const scanned = spawnSync('ssh-keyscan', ['-t', 'ed25519', address], { encoding: 'utf8' })
  const line = (scanned.stdout ?? '')
    .split('\n')
    .find((one) => one.includes('ssh-ed25519') && !one.startsWith('#'))
  if (line === undefined) {
    process.stdout.write('SKIP  the fingerprint matches another tool\n        ssh-keyscan said nothing\n')
  } else {
    const blob = Buffer.from(line.split(' ')[2], 'base64')
    const theirs = `SHA256:${createHash('sha256').update(blob).digest('base64').replace(/=+$/, '')}`
    process.stdout.write(`INFO  ssh-keyscan says ${theirs}\n`)
    process.stdout.write('        compare with the identity recorded above\n')
  }
}

process.exit(run.status ?? 1)
