/**
 * Whether the copilot can rewrite its own audit log, asked of a real
 * `sandbox-exec`.
 *
 * ## Why this file exists separately from `copilot-writable-boundary.test.ts`
 *
 * That file proves the routines fence. This one proves the log fence, and the
 * two are the same *class* of hole found in the same folder for the same
 * reason, but they are not the same fact and a reader chasing one should not
 * have to read past the other.
 *
 * The hole: `log/actions.jsonl` was scaffolded inside `<userData>/copilot/`,
 * which is the one directory in the copilot's confinement plan it may write to.
 * `deck-control` writes every tool call there, `copilot-home.ts` writes the
 * lifecycle rows there, and `deck-control:activity` reads it back into the
 * Activity pane a person opens to see what their assistant has been doing. With
 * the file inside the boundary, the audited party could append rows that never
 * happened, edit rows that did, truncate the file to nothing, or delete it —
 * with `Write`, or with one `>` in a shell it already has. The only fence in
 * front of any of that was a paragraph in its own `CLAUDE.md` asking it not to.
 *
 * An audit log the audited party can rewrite is not an audit log. So the file
 * moved to `<userData>/copilot-log/`, outside every writable path in
 * `copilotPlan`, and the copilot's own appends became the `log.note` tool —
 * which turns an append from a shell redirect into a call that is tiered,
 * budgeted, timed and attributed. See `copilot-home.ts` for the whole argument.
 *
 * ## Why an assertion in a test file was not enough
 *
 * `copilot-home.test.ts` pins the path with a string comparison, which is worth
 * having because it fails first and fails fast. It is not evidence. It would
 * pass identically if `sandbox-exec` were ignoring the profile, if the plan
 * collapsed `<userData>` into a writable root, if a `PATH` entry widened a read
 * root across it, or if realpath resolution meant the profile named a directory
 * the process never opens. Each of those has happened at least once in this
 * repository's confinement work, and only the filesystem can settle them.
 *
 * So every case below runs the actual command against the actual profile the
 * copilot is launched with. The first two must *succeed* — a sandbox that
 * cannot run `/bin/echo`, or a copilot that cannot write its own memory, would
 * make every refusal underneath meaningless — and the log file, its rolled
 * generation and the directory holding them all exist before anything is
 * attempted, so that `No such file or directory` can never masquerade as a
 * denial.
 *
 * ## Why it is not opt-in
 *
 * Same argument `escapes.test.ts` makes: CI for this project is macOS-only by
 * policy, this needs nothing but the machine it runs on, and a security proof
 * behind an environment variable is a proof nobody runs. It skips on other
 * platforms because there is no Seatbelt there to test.
 */

import { execFile } from 'node:child_process'
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { confinedEnv, deviceHomesRoot } from './confine'
import type { ConfinementPlan } from './confine/plan'
import { within } from './confine/plan'
import { SANDBOX_EXEC, seatbeltProfile } from './confine/seatbelt'
import { copilotPaths, legacyLogDir, type CopilotPaths } from './copilot-home'
import { COPILOT_HOME_KEY, copilotPlan } from './copilot-session'

const onMac = process.platform === 'darwin'

interface Ran {
  code: number
  stdout: string
  stderr: string
}

let root = ''
let userData = ''
let accountHome = ''
let deviceHome = ''
let paths: CopilotPaths
let plan: ConfinementPlan
let profile = ''

/** The one row that was in the log before any attempt below. */
const EXISTING_ROW = '{"at":"2026-08-17T01:00:00.000Z","action":"session.started"}\n'

function run(args: string[], cwd: string): Promise<Ran> {
  return new Promise((resolve) => {
    execFile(
      SANDBOX_EXEC,
      ['-p', profile, ...args],
      { cwd, timeout: 20_000, encoding: 'utf8', env: { ...process.env, ...confinedEnv(deviceHome) } },
      (error, stdout, stderr) => {
        const code =
          error && typeof (error as { code?: unknown }).code === 'number'
            ? (error as { code: number }).code
            : error
              ? 1
              : 0
        resolve({ code, stdout, stderr })
      },
    )
  })
}

/** A shell line inside the sandbox, from the copilot's own working directory. */
function sh(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], paths.root)
}

/** What is in the log right now, read from outside the sandbox. */
function logOnDisk(): string {
  try {
    return readFileSync(paths.actions, 'utf8')
  } catch {
    return ''
  }
}

beforeAll(() => {
  if (!onMac) return
  /*
   * Realpath everything up front, and not for tidiness.
   *
   * `/var` is a symlink to `/private/var` on macOS, so a temporary directory
   * has two names. Seatbelt matches the resolved one — measured, and written up
   * in `plan.ts` — so a test that composed its expectations from the unresolved
   * name would be asking about paths the profile never mentions, and would
   * report a denial that is really a spelling mistake.
   */
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-log-')))
  userData = join(root, 'user-data')
  accountHome = join(root, 'account-home')
  mkdirSync(userData, { recursive: true })
  mkdirSync(accountHome, { recursive: true })

  paths = copilotPaths(userData)
  deviceHome = join(deviceHomesRoot(join(userData, 'remote')), COPILOT_HOME_KEY)

  mkdirSync(paths.memory, { recursive: true })
  mkdirSync(join(deviceHome, 'tmp'), { recursive: true })

  /*
   * The log, its directory and its rolled generation all exist before anything
   * is attempted, with real rows in them.
   *
   * This is the whole difference between a proof and a coincidence. An append
   * into a directory that is not there fails with `No such file or directory`,
   * which would look like a pass and would keep looking like one on the day
   * somebody moved the log back inside the boundary. So the target exists, it
   * has content, and the only thing standing between the sandboxed process and
   * it is the profile.
   */
  mkdirSync(paths.log, { recursive: true })
  writeFileSync(paths.actions, EXISTING_ROW)
  writeFileSync(`${paths.actions}.1`, '{"at":"2026-08-16T01:00:00.000Z","action":"home.created"}\n')

  plan = copilotPlan({
    folder: paths.root,
    home: deviceHome,
    accountHome,
    // A fixed, minimal PATH rather than this machine's, for the reason
    // `copilot-writable-boundary.test.ts` gives: the real one differs per
    // developer and can contain a directory whose prefix widens a read root.
    path: '/usr/bin:/bin:/usr/sbin:/sbin',
    platform: 'darwin',
  })
  profile = seatbeltProfile(plan)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe.skipIf(!onMac)('the copilot, against the log that records it', () => {
  it('runs at all — without this every refusal below means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('can write inside its own folder, which is what it is for', async () => {
    // The other control case. A boundary that refused everything would pass
    // every denial below while being a broken app rather than a safe one.
    const ran = await sh('echo remembered > memory/a-fact.md && cat memory/a-fact.md')
    expect(ran.stdout).toContain('remembered')
    expect(ran.code).toBe(0)
  })

  it('cannot append a row that never happened', async () => {
    /*
     * The forgery this whole change closes, attempted the way an agent would
     * attempt it: an absolute path, a real row in the shape the file uses,
     * appended to a file that is already there.
     */
    const forged = '{"at":"2026-08-17T02:00:00.000Z","action":"tool.settings.write","detail":"nothing to see"}'
    const ran = await sh(`echo ${JSON.stringify(forged)} >> ${JSON.stringify(paths.actions)}`)

    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
    // The message is the diagnosis; the absence is the fact.
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot truncate it, which is the cheapest way to hide an afternoon', async () => {
    // `>` rather than `>>`, and worth its own case: a log that can be emptied
    // is a log whose silence proves nothing. Note that a shell opens the
    // redirect before it runs anything, so this is the shortest possible
    // command that would destroy the file.
    const ran = await sh(`: > ${JSON.stringify(paths.actions)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot delete it', async () => {
    const ran = await sh(`rm -f ${JSON.stringify(paths.actions)}`)
    expect(ran.code).not.toBe(0)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot rewrite the rolled generation either', async () => {
    // `tail()` walks back through `actions.jsonl.1`, so a busy afternoon's
    // history is in the older file. A fence that held for the live file and not
    // for the one behind it would protect the last ten minutes of the story.
    const ran = await sh(`echo forged > ${JSON.stringify(`${paths.actions}.1`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(readFileSync(`${paths.actions}.1`, 'utf8')).toContain('home.created')
  })

  it('cannot even read it', async () => {
    /*
     * Worth its own case rather than folded into the writes.
     *
     * Nothing about the copilot's job needs this — everything it can do is
     * already logged for it, and `log.note` is how it adds a line. What reading
     * would give it is the ability to check *which* of its actions were
     * recorded and how they were worded, which is the first move anybody makes
     * before shaping behaviour around a record. The log also names sessions and
     * quotes what was typed into them, and the copilot has an open network.
     */
    const ran = await sh(`cat ${JSON.stringify(paths.actions)}`)
    expect(ran.stdout).not.toContain('session.started')
    expect(ran.stderr).toMatch(/not permitted|Operation not permitted/i)
  })

  it('cannot make a log directory of its own where there is not one', async () => {
    // The obvious next move after the writes above fail. `mkdir -p` on a path
    // whose parent is unreachable is refused at the first component it cannot
    // create, which is `<userData>` itself.
    const ran = await sh(`mkdir -p ${JSON.stringify(join(root, 'user-data-2', 'copilot-log'))}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
  })

  it('cannot recreate the old writable location and have anything read it', async () => {
    /*
     * The upgrade-path case, and the one a reader is most likely to doubt.
     *
     * `<copilot>/log/` *is* inside the boundary — it is a subdirectory of the
     * copilot's own folder, so of course the copilot can make one and write
     * whatever it likes into it. What matters is that nothing reads it: the
     * only spelling of the log's location is `CopilotPaths.actions`, and the
     * scaffolder empties the legacy directory rather than leaving a second
     * place for rows to be found. So the write succeeds and the file is not the
     * log — which is exactly what should be true, and is worth writing down so
     * nobody later reads the successful `echo` as a hole.
     */
    const ran = await sh('mkdir -p log && echo \'{"action":"invented"}\' > log/actions.jsonl')
    expect(ran.code).toBe(0)

    expect(join(paths.root, 'log')).toBe(legacyLogDir(paths))
    expect(paths.actions.startsWith(`${legacyLogDir(paths)}/`)).toBe(false)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot reach it through a symlink it plants inside its own folder', async () => {
    // The standard way past a path-prefix rule, and the reason `plan.ts`
    // resolves every path: Seatbelt applies the rule to the resolved target, so
    // a link is not a way to borrow the grant on the folder holding it.
    const ran = await sh(
      `ln -s ${JSON.stringify(paths.log)} escape && echo forged >> escape/actions.jsonl`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('holds for a grandchild, which is what a tool call actually is', async () => {
    // Every agent tool runs as a child of the session's shell, and most run as
    // a grandchild of it. A boundary that only held for the first process would
    // be no boundary at all here.
    const ran = await sh(
      `sh -c ${JSON.stringify(`echo forged >> ${paths.actions}`)}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('names nothing under the log directory in its writable or readable lists', () => {
    /*
     * The plan itself, checked the way `plan.ts` argues a plan should be — as
     * an array rather than as a regular expression over a profile.
     *
     * Two directories are writable and both are the copilot's own. Anything
     * else appearing here later is a widening, and this is the assertion that
     * makes somebody justify it.
     */
    expect([...plan.writable].sort()).toEqual([paths.root, deviceHome].sort())
    for (const dir of [...plan.writable, ...plan.readable]) {
      expect(within(paths.log, dir, 'darwin'), dir).toBe(false)
      expect(within(paths.actions, dir, 'darwin'), dir).toBe(false)
    }
  })
})
