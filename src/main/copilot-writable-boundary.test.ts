/**
 * What the copilot can actually write, asked of a real `sandbox-exec`.
 *
 * ## Why this file exists separately from `confine/escapes.test.ts`
 *
 * That file proves the *mechanism*: a generic plan, a generic granted folder, and
 * the classic escapes attempted against it. This one proves the *plan the copilot
 * is actually launched with* — `copilotPlan` in `copilot-session.ts`, built from
 * this install's `<userData>`, with the copilot's own confined home — and it asks
 * one question of it: can the agent reach the files that decide what this app
 * runs on its own?
 *
 * The distinction matters because the mechanism was never in doubt. The hole was
 * a *path*: `routines/` was scaffolded inside `<userData>/copilot/`, which is the
 * one directory in the plan's writable list. `routines/store.ts` is built on
 * "the directory is the database" — a `.md` file appearing there is a routine
 * that really runs on a real trigger — so an agent with the ordinary `Write`
 * tool could author its own next trigger, and the alter-tier confirmation a
 * person is owed before something starts running on its own would never have been
 * asked for. Nothing about Seatbelt was wrong; the folder was on the wrong side
 * of it.
 *
 * ## Why an assertion in a test file was not enough
 *
 * `store.test.ts` and `copilot-home.test.ts` both pin the path with string
 * comparisons, and those are worth having because they fail first and fail fast.
 * They are not evidence. They would pass identically if `sandbox-exec` were
 * ignoring the profile, if the plan collapsed a parent directory over the top of
 * `<userData>`, if a `PATH` entry widened a read root across it, or if realpath
 * resolution meant the profile named a directory the process never opens. Each
 * of those has happened at least once in this repository's confinement work, and
 * only one side can settle them: the filesystem, under the real profile, from
 * inside the real sandbox.
 *
 * So every case below runs the actual command. The first two must *succeed* —
 * a sandbox that cannot run `/bin/echo`, or a copilot that cannot write its own
 * memory, would make every refusal underneath meaningless, and this file says so
 * before it claims anything.
 *
 * ## Why it is not opt-in
 *
 * Same argument `escapes.test.ts` makes: CI for this project is macOS-only by
 * policy, this needs nothing but the machine it runs on, and a security proof
 * behind an environment variable is a proof nobody runs. It skips on other
 * platforms because there is no Seatbelt there to test.
 */

import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { confinedEnv, deviceHomesRoot } from './confine'
import type { ConfinementPlan } from './confine/plan'
import { within } from './confine/plan'
import { SANDBOX_EXEC, seatbeltProfile } from './confine/seatbelt'
import { copilotPaths, type CopilotPaths } from './copilot-home'
import { COPILOT_HOME_KEY, copilotPlan } from './copilot-session'
import { routinesDirFor } from './routines/store'
import { runtimeStateFileFor } from './routines/runtime-state'

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
let routines = ''
let runtimeState = ''
let plan: ConfinementPlan
let profile = ''

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

beforeAll(() => {
  if (!onMac) return
  /*
   * Realpath everything up front, and not for tidiness.
   *
   * `/var` is a symlink to `/private/var` on macOS, so a temporary directory has
   * two names. Seatbelt matches the resolved one — measured, and written up in
   * `plan.ts` — so a test that composed its expectations from the unresolved
   * name would be asking about paths the profile never mentions, and would
   * report a denial that is really a spelling mistake.
   */
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-boundary-')))
  userData = join(root, 'user-data')
  accountHome = join(root, 'account-home')
  mkdirSync(userData, { recursive: true })
  mkdirSync(accountHome, { recursive: true })

  paths = copilotPaths(userData)
  routines = routinesDirFor(userData)
  runtimeState = runtimeStateFileFor(userData)
  deviceHome = join(deviceHomesRoot(join(userData, 'remote')), COPILOT_HOME_KEY)

  mkdirSync(paths.memory, { recursive: true })
  mkdirSync(paths.log, { recursive: true })
  mkdirSync(join(deviceHome, 'tmp'), { recursive: true })

  /*
   * The routines folder and the state file exist before the attempt.
   *
   * This is the whole difference between a proof and a coincidence. A write into
   * a directory that is not there fails with `No such file or directory`, which
   * would look like a pass and would keep looking like one on the day somebody
   * moved the folder back inside the boundary. So the target exists, is a real
   * directory with a real file in it, and the only thing standing between the
   * sandboxed process and it is the profile.
   */
  mkdirSync(routines, { recursive: true })
  writeFileSync(join(routines, 'existing.md'), '# a routine that is already there\n')
  writeFileSync(runtimeState, '{"version":1,"routines":{}}\n')

  plan = copilotPlan({
    folder: paths.root,
    home: deviceHome,
    accountHome,
    // A fixed, minimal PATH rather than this machine's. The real one differs per
    // developer and can contain a directory whose prefix widens a read root;
    // that behaviour belongs to `plan.test.ts`, and letting it vary here would
    // make this file pass or fail for a reason that has nothing to do with the
    // copilot.
    path: '/usr/bin:/bin:/usr/sbin:/sbin',
    platform: 'darwin',
  })
  profile = seatbeltProfile(plan)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe.skipIf(!onMac)('the copilot, inside the boundary it really runs in', () => {
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

  it('cannot write a routine file', async () => {
    /*
     * The escape this whole change closes, attempted the way an agent would
     * attempt it: an absolute path, into a directory that exists, holding a
     * routine that is syntactically real.
     */
    const target = join(routines, 'self-authored.md')
    const ran = await sh(
      `echo '# Mine\n\nwhen: schedule every 5m\nin: /tmp\n\n---\n\nRun it.' > ${JSON.stringify(target)}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
    // And nothing landed. The message is the diagnosis; the absence is the fact.
    const after = await run(['/bin/ls', routines], root)
    expect(after.stdout).not.toContain('self-authored')
  })

  it('cannot make its own routines folder when there is not one', async () => {
    // The obvious next move after the write above fails. `mkdir -p` on a path
    // whose parent is unreachable is refused at the first component it cannot
    // create, which is `<userData>` itself.
    const ran = await sh(`mkdir -p ${JSON.stringify(join(root, 'user-data-2', 'routines'))}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
  })

  it('cannot even read the routines folder', async () => {
    // Worth its own case rather than folded into the write. A routine file names
    // a project path and carries a prompt; being unable to write one and able to
    // read them all would still hand the agent a map of the person's work.
    const ran = await sh(`ls ${JSON.stringify(routines)}`)
    expect(ran.stdout).not.toContain('existing.md')
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot rewrite the engine state that holds the run budgets', async () => {
    /*
     * `routine-state.json` is where the per-routine ceilings and `pausedReason`
     * are kept, and the engine trusts it on every start. An agent that can write
     * it can zero its own budget and un-pause a routine the engine stopped after
     * five consecutive failures — no tool call, no confirmation, no log row.
     */
    const ran = await sh(`echo '{"version":1,"routines":{}}' > ${JSON.stringify(runtimeState)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
  })

  it('cannot reach them through a symlink it plants inside its own folder', async () => {
    // The standard way past a path-prefix rule, and the reason `plan.ts`
    // resolves every path: Seatbelt applies the rule to the resolved target, so
    // a link is not a way to borrow the grant on the folder holding it.
    const ran = await sh(
      `ln -s ${JSON.stringify(routines)} escape && echo '# via a link' > escape/linked.md`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    const after = await run(['/bin/ls', routines], root)
    expect(after.stdout).not.toContain('linked.md')
  })

  it('holds for a grandchild, which is what a tool call actually is', async () => {
    // Every agent tool runs as a child of the session's shell, and most run as a
    // grandchild of it. A boundary that only held for the first process would be
    // no boundary at all here.
    const ran = await sh(`sh -c ${JSON.stringify(`echo x > ${join(routines, 'grandchild.md')}`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    const after = await run(['/bin/ls', routines], root)
    expect(after.stdout).not.toContain('grandchild.md')
  })

  it('names nothing outside the copilot folder in its writable list', () => {
    /*
     * The plan itself, checked the way `plan.ts` argues a plan should be — as an
     * array rather than as a regular expression over a profile.
     *
     * Two directories are writable and both are the copilot's own: the folder it
     * works in and the confined home holding its login and its transcripts.
     * Anything else appearing here later is a widening, and this is the
     * assertion that makes somebody justify it.
     */
    expect([...plan.writable].sort()).toEqual([paths.root, deviceHome].sort())
    for (const dir of plan.writable) {
      expect(within(routines, dir, 'darwin')).toBe(false)
      expect(within(runtimeState, dir, 'darwin')).toBe(false)
      expect(within(userData, dir, 'darwin')).toBe(false)
    }
    for (const dir of plan.readable) {
      expect(within(routines, dir, 'darwin')).toBe(false)
      expect(within(runtimeState, dir, 'darwin')).toBe(false)
    }
  })
})
