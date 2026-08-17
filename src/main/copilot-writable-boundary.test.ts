/**
 * Whether the copilot can author its own next trigger, asked of a real
 * `sandbox-exec` and of the routine engine's own paths.
 *
 * ## What changed under this file, and what did not
 *
 * The protection is the same; the mechanism underneath it is not, and the
 * difference is worth reading before the cases.
 *
 * It used to hold because the copilot was **jailed**: it ran under a
 * `(deny default)` profile whose writable list was two directories, so
 * `<userData>/routines/` was unreachable along with the entire rest of the
 * machine. That jail is gone — it cost the copilot its login, its ability to
 * read the person's code, and its existence on two of three platforms, and
 * `confine/records.ts` carries the whole argument.
 *
 * What holds it now is a **fence**: an `(allow default)` profile with three
 * denies in it. The copilot inside it is an ordinary session — the keychain, the
 * person's home directory, every one of their repositories, writable — and the
 * routine database is not. So the refusals below are unchanged, and the two
 * cases at the top asserting what it *can* do are new and are half the point:
 * they are what would fail if somebody put the jail back.
 *
 * ## What this file proves that `confine/records.test.ts` does not
 *
 * That one proves the mechanism against paths it composes itself. This one
 * proves it against the paths the **routine engine actually uses** —
 * `routinesDirFor` and `runtimeStateFileFor`, imported from the modules that own
 * them — because the original hole was never a broken sandbox. It was a *path*:
 * `routines/` was scaffolded inside the one directory the copilot could write
 * to. `routines/store.ts` is built on "the directory is the database", so a
 * `.md` file appearing there is a routine that really fires on a real trigger,
 * and an agent with `Write` could author its own next trigger with no
 * confirmation asked for. Nothing about Seatbelt was wrong; the folder was on
 * the wrong side of it.
 *
 * That is why {@link recordsFenceAgrees} is asserted here rather than in the
 * fence's own tests. A fence around the right paths and an engine reading a
 * different directory would pass every case in both files and protect nothing.
 *
 * ## Why an assertion in a test file was not enough
 *
 * `store.test.ts` and `copilot-home.test.ts` both pin the path with string
 * comparisons, and those are worth having because they fail first and fail fast.
 * They are not evidence. They would pass identically if `sandbox-exec` were
 * ignoring the profile, if realpath resolution meant the profile named a
 * directory the process never opens, or if a deny had been written above an
 * allow that overrides it. Each of those has happened at least once in this
 * repository's confinement work, and only the filesystem can settle them.
 *
 * ## Why it is not opt-in
 *
 * Same argument `escapes.test.ts` makes: CI for this project is macOS-only by
 * policy, this needs nothing but the machine it runs on, and a security proof
 * behind an environment variable is a proof nobody runs. It skips on other
 * platforms because there is no Seatbelt there to test.
 */

import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  recordsFenceAgrees,
  recordsFencePaths,
  recordsFenceProfile,
  type RecordsFencePaths,
} from './confine/records'
import { SANDBOX_EXEC } from './confine/seatbelt'
import { copilotPaths, type CopilotPaths } from './copilot-home'
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
let paths: CopilotPaths
let fenced: RecordsFencePaths
/** A project the person has open. The copilot writes here now, like any session. */
let project = ''
let profile = ''

function run(args: string[], cwd: string): Promise<Ran> {
  return new Promise((resolve) => {
    execFile(
      SANDBOX_EXEC,
      ['-p', profile, ...args],
      { cwd, timeout: 20_000, encoding: 'utf8' },
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

/** A shell line inside the fence, from the copilot's own working directory. */
function sh(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], paths.root)
}

beforeAll(() => {
  /*
   * No `if (!onMac) return` here, and its removal is the point.
   *
   * It used to be the first line, which left `userData` an empty string and
   * `paths` undefined off macOS — so the one case in this file that is *not*
   * about Seatbelt, the agreement between the fence's spelling of a path and
   * the engine's, threw `Cannot read properties of undefined` on Windows rather
   * than checking anything. A fixture that only exists on one platform quietly
   * turns a platform-independent claim into a platform-independent failure.
   * Everything below is ordinary file work; only the `sandbox-exec` runs need a
   * Mac, and those are the `describe.skipIf` further down.
   */
  /*
   * Realpath everything up front, and not for tidiness.
   *
   * `/var` is a symlink to `/private/var` on macOS, so a temporary directory has
   * two names. Seatbelt matches the resolved one — measured, and written up in
   * `plan.ts` — so a test that composed its expectations from the unresolved
   * name would be asking about paths the profile never mentions, and would
   * report a denial that is really a spelling mistake. The first working version
   * of the records fence was measured against `/tmp/...` and refused nothing at
   * all while looking completely correct.
   */
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-boundary-')))
  userData = join(root, 'user-data')
  project = join(root, 'a-project')
  mkdirSync(userData, { recursive: true })
  mkdirSync(project, { recursive: true })
  writeFileSync(join(project, 'index.ts'), 'export const x = 1\n')

  paths = copilotPaths(userData)
  mkdirSync(paths.memory, { recursive: true })
  mkdirSync(paths.log, { recursive: true })

  /*
   * The routines folder and the state file exist before the attempt, with real
   * content in them.
   *
   * This is the whole difference between a proof and a coincidence. A write into
   * a directory that is not there fails with `No such file or directory`, which
   * would look like a pass and would keep looking like one on the day somebody
   * moved the folder back inside the copilot's reach.
   */
  mkdirSync(routinesDirFor(userData), { recursive: true })
  writeFileSync(join(routinesDirFor(userData), 'existing.md'), '# a routine that is already there\n')
  writeFileSync(runtimeStateFileFor(userData), '{"version":1,"routines":{}}\n')

  fenced = recordsFencePaths(userData)
  profile = recordsFenceProfile(fenced)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe('the fence names the paths the routine engine really uses', () => {
  it('agrees with `routinesDirFor` and `runtimeStateFileFor`, resolved', () => {
    /*
     * The assertion that makes every refusal below mean something. A fence
     * around `<userData>/routines` while the engine read
     * `<userData>/copilot/routines` would pass all of them and protect nothing,
     * and neither module imports the other — deliberately, because a
     * confinement module that imported the routine engine would depend on the
     * thing it fences.
     */
    const local = recordsFencePaths(userData)
    expect(
      recordsFenceAgrees(local, {
        routines: routinesDirFor(userData),
        routineState: runtimeStateFileFor(userData),
        log: paths.log,
      }),
    ).toBe(true)
  })
})

describe.skipIf(!onMac)('the copilot, inside the fence it really runs in', () => {
  it('runs at all — without this every refusal below means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('can write inside its own folder, which is what it is for', async () => {
    // A control case. A profile that refused everything would pass every denial
    // below while being a broken app rather than a safe one.
    const ran = await sh('echo remembered > memory/a-fact.md && cat memory/a-fact.md')
    expect(ran.stdout).toContain('remembered')
    expect(ran.code).toBe(0)
  })

  it('can write in the person’s project, which the jail refused and an ordinary session does not', async () => {
    /*
     * The case that would fail if the jail came back, and the reason it is in
     * this file rather than only in the fence's own.
     *
     * Under the profile this replaced, the person's projects were in the plan's
     * *read* list with no write rule anywhere, so this was `Operation not
     * permitted` — by design, and the design was the problem. The copilot is now
     * an ordinary session, and an ordinary session at this keyboard writes the
     * person's code. What stops it doing so *carelessly* is the consent gate and
     * the tool tiers, which are a different mechanism in a different file.
     */
    const target = join(project, 'index.ts')
    const ran = await sh(`echo '// touched' >> ${JSON.stringify(target)}`)
    expect(ran.code).toBe(0)
    expect(readFileSync(target, 'utf8')).toContain('touched')
  })

  it('cannot write a routine file', async () => {
    /*
     * The escape this whole protection exists for, attempted the way an agent
     * would attempt it: an absolute path, into a directory that exists, holding
     * a routine that is syntactically real.
     */
    const target = join(routinesDirFor(userData), 'self-authored.md')
    const ran = await sh(
      `echo '# Mine\n\nwhen: schedule every 5m\nin: /tmp\n\n---\n\nRun it.' > ${JSON.stringify(target)}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
    // The message is the diagnosis; the absence is the fact.
    expect(existsSync(target)).toBe(false)
  })

  it('cannot make a routines folder of its own somewhere the engine would read', async () => {
    // The obvious next move after the write above fails. The engine reads one
    // directory and only one, so a folder made anywhere else is not a routine
    // store — but the fenced path itself must refuse a `mkdir -p` too, because
    // `(subpath …)` covers the directory as well as its contents.
    const ran = await sh(`mkdir -p ${JSON.stringify(join(routinesDirFor(userData), 'nested'))}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
  })

  it('cannot rewrite the engine state that holds the run budgets', async () => {
    /*
     * `routine-state.json` is where the per-routine ceilings and `pausedReason`
     * are kept, and the engine trusts it on every start. An agent that can write
     * it can zero its own budget and un-pause a routine the engine stopped after
     * five consecutive failures — no tool call, no confirmation, no log row.
     */
    const state = runtimeStateFileFor(userData)
    const ran = await sh(`echo '{"version":1,"routines":{"x":{"runs":0}}}' > ${JSON.stringify(state)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
    expect(readFileSync(state, 'utf8')).toBe('{"version":1,"routines":{}}\n')
  })

  it('cannot reach them through a symlink it plants inside its own folder', async () => {
    // The standard way past a path-prefix rule, and the reason every path here
    // is resolved: Seatbelt applies the rule to the resolved target, so a link
    // is not a way to borrow the permissions of the folder holding it.
    const ran = await sh(
      `ln -sfn ${JSON.stringify(routinesDirFor(userData))} escape && echo '# via a link' > escape/linked.md`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(existsSync(join(routinesDirFor(userData), 'linked.md'))).toBe(false)
  })

  it('holds for a grandchild, which is what a tool call actually is', async () => {
    // Every agent tool runs as a child of the session's shell, and most run as a
    // grandchild of it. A fence that only held for the first process would be no
    // fence at all here.
    const target = join(routinesDirFor(userData), 'grandchild.md')
    const ran = await sh(`sh -c ${JSON.stringify(`echo x > ${target}`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(existsSync(target)).toBe(false)
  })

  it('names nothing but the records in its deny list', () => {
    /*
     * The profile itself, checked as a shape rather than as prose.
     *
     * The denies, and the `(allow default)` that makes this a fence rather than
     * a jail. An unexplained deny appearing here later is the copilot being made
     * stricter than an ordinary session again, and this is the assertion that
     * makes somebody justify it.
     *
     * It was three for most of this fence's life and is five since
     * `COPILOT-REMOTE.md` §0.3. The two that joined are the remote copilot grant
     * and the paired-device trust store, and they are not the copilot being
     * tightened for its own sake: they are the files that decide which phone may
     * drive it, and a store the copilot can write is a permission the copilot
     * grants itself. That is the one justification this assertion is asking for,
     * written where the count changed.
     */
    expect(profile).toContain('(allow default)')
    expect(profile.match(/^\(deny /gm)).toHaveLength(5)
    expect(profile).toContain(fenced.routines)
    expect(profile).toContain(fenced.routineState)
    expect(profile).toContain(fenced.log)
    expect(profile).toContain(fenced.remoteCopilot)
    expect(profile).toContain(fenced.remoteAuth)
    // And the copilot's own folder is not in it: that is where it works.
    expect(profile).not.toContain(`(subpath "${paths.root}")`)
  })
})
