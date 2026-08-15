/**
 * The confinement, through a real terminal.
 *
 * ## Why this exists when `escapes.test.ts` already runs `sandbox-exec`
 *
 * Because that file runs it the way a test runs things — `execFile`, a pipe, no
 * terminal — and the product does not. The product hands a command and an
 * argument list to `node-pty`, which `execvp`s it against a pseudo-terminal, and
 * three things about that arrangement are not exercised by a pipe:
 *
 *  1. **The profile survives the trip.** It travels as a single argument, about
 *     a kilobyte and a half of S-expression with quotes and newlines in it. A
 *     pipe test proves `execFile` can carry that; it says nothing about the path
 *     the app actually uses.
 *  2. **An interactive login shell starts.** `zsh -l` reads startup files, and
 *     inside the boundary the account's own are unreadable. If that were fatal
 *     rather than merely quiet, every session from a device would be a dead tab
 *     — and a dead tab is what this project has shipped twice before while every
 *     test passed.
 *  3. **Job control still works.** Ctrl-C is the single most-used key in a
 *     terminal. The profile allows signals only to the session's own processes,
 *     and whether that is enough for a shell to interrupt its own foreground job
 *     is a question about a pty, answerable only with one.
 *
 * The lesson this project keeps relearning is that a test which cannot run in
 * the product's own runtime is not a test of the product. This is the closest
 * this suite gets to the product's runtime without starting Electron.
 */

import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { confinedEnv, planFor, realResolver } from './index'
import { seatbeltCommand, seatbeltProfile } from './seatbelt'

const onMac = process.platform === 'darwin'

let root = ''
let granted = ''
let deviceHome = ''
let profile = ''

const SECRET = 'pty-canary-8c31aa07-do-not-leak'

/**
 * The interrupt, written as an escape rather than as the byte itself.
 *
 * A literal control character in a source file is one careless editor away from
 * being stripped, and if it were, this test would stop pressing Ctrl-C while
 * still passing for the wrong reason: `MARK-INT` would arrive after the sleep
 * rather than instead of it, and nobody would notice for thirty seconds.
 */
const CTRL_C = '\u0003'

beforeAll(() => {
  if (!onMac) return
  root = realpathSync(mkdtempSync(join(tmpdir(), 'confine-pty-')))
  granted = join(root, 'granted')
  deviceHome = join(root, 'device-home')
  mkdirSync(granted, { recursive: true })
  mkdirSync(join(deviceHome, 'tmp'), { recursive: true })
  writeFileSync(join(root, 'secret.txt'), SECRET)

  profile = seatbeltProfile(
    planFor({
      folder: granted,
      device: { home: deviceHome, writable: [], files: [] },
      accountHome: homedir(),
      path: process.env.PATH ?? '/usr/bin:/bin',
      platform: 'darwin',
      resolver: realResolver,
    }),
  )
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

/**
 * Type a script into a confined login shell and hand back everything it printed.
 *
 * `node-pty` is imported here rather than at the top of the file so that a
 * platform which skips these cases never loads a native addon it has no use for.
 * The waits are wall-clock because a terminal has no other kind of readiness
 * signal: what is being measured is what a person would see on screen, and a
 * person waits too.
 */
async function terminal(steps: ReadonlyArray<readonly [string, number]>): Promise<string> {
  const pty = await import('node-pty')
  const launch = seatbeltCommand(profile, '/bin/zsh', ['-l'])
  const proc = pty.spawn(launch.command, launch.args, {
    name: 'xterm-256color',
    cols: 100,
    rows: 30,
    cwd: granted,
    env: { ...process.env, ...confinedEnv(deviceHome), TERM: 'xterm-256color' },
  })

  let out = ''
  proc.onData((data) => {
    out += data
  })
  for (const [text, wait] of steps) {
    proc.write(text)
    await new Promise((resolve) => setTimeout(resolve, wait))
  }
  try {
    proc.kill()
  } catch {
    /* already gone */
  }
  // Escape sequences would otherwise split a word the assertions are looking
  // for: a shell repaints its prompt with cursor moves between every character
  // it echoes.
  // Written as a unicode escape rather than as the byte itself, for the same
  // reason CTRL_C above is: a literal escape character in a source file is one
  // careless editor away from disappearing, and this expression would then
  // strip any text shaped like `[word]` out of the output it is asserting on.
  return out.replace(/\u001b\[[0-9;?]*[a-zA-Z]/g, '').replace(/\r/g, '')
}

describe.skipIf(!onMac)('a confined session in a real terminal', () => {
  it('starts, refuses the way out, and still interrupts its own job', async () => {
    const seen = await terminal([
      ['echo MARK-ALIVE\r', 500],
      [`cat ${JSON.stringify(join(root, 'secret.txt'))}\r`, 600],
      ['echo written > inside.txt && cat inside.txt\r', 600],
      // Job control. If the shell cannot signal its own foreground job the sleep
      // outlives the Ctrl-C and MARK-INT never arrives in time.
      ['sleep 30\r', 700],
      [CTRL_C, 700],
      ['echo MARK-INT\r', 600],
    ])

    // A login shell started at all, which is the claim a pipe cannot make.
    expect(seen).toContain('MARK-ALIVE')
    // The boundary held for a file one directory above the granted folder.
    expect(seen).not.toContain(SECRET)
    expect(seen).toMatch(/not permitted/i)
    // And the session is still usable inside it.
    expect(seen).toContain('written')
    // Ctrl-C reached the job rather than being swallowed by the sandbox.
    expect(seen).toContain('MARK-INT')
  }, 20_000)

  it('still finds the tools, which live outside the folder', async () => {
    // Rule five: a confinement that breaks node or git is not usable. Both are
    // outside the granted folder by construction, and this is the arrangement
    // they have to work in.
    const seen = await terminal([['git --version && node -e "console.log(6*7)"\r', 2500]])
    expect(seen).toMatch(/git version/)
    expect(seen).toContain('42')
  }, 20_000)
})
