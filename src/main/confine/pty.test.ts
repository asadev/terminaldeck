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

/**
 * How long {@link terminal} will wait for the shell it started to actually die.
 *
 * A ceiling, not a sleep — the wait ends the instant `onExit` fires, which on
 * this machine is a few milliseconds. It exists so that a shell which refuses to
 * go leaves a slow test rather than a hung suite.
 */
const EXIT_GRACE_MS = 5_000

/**
 * The shell the last {@link terminal} call started, and whether it has been reaped.
 *
 * Module-level so a case can assert on it, which is the only way to pin the wait
 * inside `terminal` from outside: the process itself is a local, and a helper
 * that quietly stopped waiting would otherwise surface only as the intermittent
 * teardown failure described on `afterAll`.
 */
let lastShell: { pid: number; exited: boolean } | null = null

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

/**
 * Delete the tree the confined shells ran in.
 *
 * This threw `ENOTEMPTY` under a full-suite run — never on its own, and never
 * three times in a row — and the leftover was always the same single file:
 * `device-home/.zsh_history`. That is the whole diagnosis. `confinedEnv` points
 * `HOME` at `device-home`, a login shell writes its history **as it exits**, and
 * `terminal` used to call `proc.kill()` and return on the next line. So the
 * shell was still dying while this ran: `rmSync` emptied the directory, zsh
 * wrote its history back into it, and the `rmdir` that follows found it
 * occupied.
 *
 * The fix is in `terminal` — it now waits for the process to be reaped — and it
 * belongs there rather than here, because "the shell is still running after the
 * helper returned" is also wrong for the *next* case in the file, which starts a
 * second shell inside the same boundary. Retrying the delete would have hidden
 * that half of it. `waits for the shell it started to actually exit` below is
 * what fails if the wait is ever taken back out.
 */
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
/**
 * Drive a confined login shell and return everything it printed.
 *
 * Each step is `[what to type, how long to wait]`, and the wait is a CEILING
 * rather than a sleep: an optional third element is what the step is waiting
 * FOR, and the moment it appears the step is done. A fixed sleep passes on a
 * fast machine and fails on a slow one — which is exactly what happened, on
 * the CI runner, to the case checking that `node` still works inside the
 * boundary. It captured the echoed command and none of the answer, and read as
 * "the confinement broke node" when the truth was "2.5 seconds was not enough
 * on a shared runner".
 */
async function terminal(
  steps: ReadonlyArray<readonly [string, number] | readonly [string, number, RegExp]>,
): Promise<string> {
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

  // Recorded before the first keystroke so that a case which fails mid-script
  // still leaves the shell's fate observable rather than leaving `lastShell`
  // pointing at the previous call's process.
  const shell = { pid: proc.pid, exited: false }
  lastShell = shell
  proc.onExit(() => {
    shell.exited = true
  })

  /*
   * Wait for the shell to exist before typing at it.
   *
   * `pty.spawn` returns as soon as the process is created, not when zsh is
   * ready to read — and every step below writes immediately. On this Mac the
   * gap is invisible; on a shared CI runner it is not, and a keystroke written
   * into a shell that has not started yet is simply lost. The symptom is this
   * test's own failure mode: the capture holds the echoed command and none of
   * its output, which reads as "the confinement broke git" when the truth is
   * that git was never asked.
   *
   * **Any byte is not enough, and believing it was cost two release builds.**
   * The first version of this waited for `out !== ''` and then typed. A login
   * zsh does not print its prompt in one write: it emits terminal setup, then
   * sources its startup files, then draws the prompt — and it is not reading
   * until the last of those. On this Mac the whole sequence is one chunk and the
   * distinction never appears. On a shared runner it is several, and a keystroke
   * written after the first chunk lands while zsh is still sourcing, where it is
   * simply dropped.
   *
   * The failure that proves it, from CI on 2026-08-17 — 30 seconds of capture
   * holding two prompts and no echo of the command at all:
   *
   *     "%                    runner@iad20-…-66368FA23B21 granted % "
   *
   * That is not a slow `git --version`; git was never asked. Raising the ceiling
   * again would have been treating a lost keystroke as a late one, and the
   * comment on that step already says the numbers are not tuned timeouts.
   *
   * So wait for the shell to go **quiet** instead of to make a noise: at least
   * one byte, and then a stretch with nothing new. A shell that has stopped
   * printing has finished drawing its prompt and is in `read`. Both bounds are
   * ceilings, not sleeps — a fast machine leaves as soon as the quiet arrives.
   */
  const QUIET_MS = 300
  const ready = Date.now() + 10_000
  let lastLength = -1
  let quietSince = Number.POSITIVE_INFINITY
  while (!shell.exited && Date.now() < ready) {
    if (out.length !== lastLength) {
      lastLength = out.length
      // Only start counting quiet once something has actually been printed;
      // the silence *before* the shell starts looks identical to the silence
      // after it is ready, and only one of them means it can read.
      quietSince = out === '' ? Number.POSITIVE_INFINITY : Date.now()
    } else if (Date.now() - quietSince >= QUIET_MS) {
      break
    }
    await new Promise((resolve) => setTimeout(resolve, 25))
  }

  for (const step of steps) {
    const [text, wait] = step
    const until = step.length === 3 ? step[2] : null
    proc.write(text)
    if (until === null) {
      await new Promise((resolve) => setTimeout(resolve, wait))
      continue
    }
    const deadline = Date.now() + wait
    while (!until.test(out) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
  }
  try {
    proc.kill()
  } catch {
    /* already gone */
  }

  /*
   * Wait for it to actually be gone, not merely for the signal to be sent.
   *
   * `kill()` returns as soon as the signal is delivered, and a login shell has
   * work left to do after that — zsh writes `$HOME/.zsh_history` on its way out,
   * into the very directory `afterAll` is about to remove. Returning here while
   * that was in flight is what produced the intermittent `ENOTEMPTY`; see the
   * note on `afterAll` for the full diagnosis.
   *
   * A ceiling rather than an unbounded wait, so that a shell wedged in an
   * uninterruptible state costs five seconds instead of the whole run. Falling
   * through with `exited` still false is deliberate and is not silent: the case
   * that asserts on it fails, which is the right way to find out that a confined
   * shell would not die.
   */
  const deadline = Date.now() + EXIT_GRACE_MS
  while (!shell.exited && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10))
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
    // 15s ceiling, satisfied the instant 42 appears — see `terminal`.
    const seen = await terminal([
      ['git --version && node -e "console.log(6*7)"\r', 30_000, /42/],
    ])
    expect(seen).toMatch(/git version/)
    expect(seen).toContain('42')
    // 45s, raised with the ceiling above after this failed a release build on a
    // `macos-latest` runner. Neither number is a tuned timeout: the step ends
    // the instant `42` appears, so a fast machine is unaffected and a slow one
    // gets the same answer later.
  }, 45_000)

  /**
   * The helper waits for the shell it started to actually exit.
   *
   * Not housekeeping. `confinedEnv` puts `HOME` inside the temporary tree, and a
   * login shell writes its history file **during** its exit — so a helper that
   * returns on the line after `kill()` leaves a process writing into a directory
   * that `afterAll` is already deleting. That is a one-in-several-runs
   * `ENOTEMPTY` in teardown: green on its own, red under a loaded full-suite run,
   * and pointing at `rmSync` rather than at the shell.
   *
   * Asserted on `exited` rather than on the directory's contents, because the
   * absence of a file is exactly the thing a race answers differently each time.
   * `exited` is set from `onExit`, which node-pty fires after it has reaped the
   * process, so this is false the instant somebody takes the wait back out and
   * true only when there is genuinely nothing left running.
   */
  it('waits for the shell it started to actually exit', async () => {
    await terminal([['echo MARK-ALIVE\r', 500, /MARK-ALIVE/]])
    expect(lastShell).not.toBeNull()
    expect(
      lastShell?.exited,
      'terminal() returned while its confined shell was still alive — it will write its ' +
        'history into the tree afterAll is deleting',
    ).toBe(true)
  }, 20_000)
})
