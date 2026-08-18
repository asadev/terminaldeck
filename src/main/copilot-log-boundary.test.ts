/**
 * Whether the copilot can rewrite its own audit log, asked of a real
 * `sandbox-exec` and of the path `copilot-home.ts` actually writes to.
 *
 * ## Why this file exists separately from `copilot-writable-boundary.test.ts`
 *
 * That file proves the routines fence. This one proves the log fence, and the
 * two are the same *class* of hole found in the same folder for the same
 * reason, but they are not the same fact and a reader chasing one should not
 * have to read past the other.
 *
 * The hole: `log/actions.jsonl` was scaffolded inside `<userData>/copilot/`,
 * which back then was the one directory the copilot could write to.
 * `deck-control` writes every tool call there, `copilot-home.ts` writes the
 * lifecycle rows there, and `deck-control:activity` reads it back into the
 * Activity pane a person opens to see what their assistant has been doing. With
 * the file inside the writable folder, the audited party could append rows that
 * never happened, edit rows that did, truncate the file to nothing, or delete it
 * — with `Write`, or with one `>` in a shell it already has. The only fence in
 * front of any of that was a paragraph in its own `CLAUDE.md` asking it not to.
 *
 * An audit log the audited party can rewrite is not an audit log.
 *
 * ## What changed under this file
 *
 * The refusals are identical. What holds them is not.
 *
 * It used to be the jail: the copilot ran under a `(deny default)` profile, and
 * `<userData>/copilot-log/` was simply outside every rule in it — along with the
 * person's home directory, their keychain and their repositories, which is what
 * made the jail too expensive to keep. It is now a **fence**: an
 * `(allow default)` profile with three denies, one of them this directory. The
 * copilot is an ordinary session in every other respect, and this file is still
 * not its to write.
 *
 * The read denial is kept, and it is the one rule here that is about restraint
 * rather than integrity: nothing the copilot does needs this file — every call
 * it makes is written here *for* it, and `log.note` is how it adds a line of its
 * own — while being able to check which of its actions were recorded, and in
 * what words, is the first move anybody makes before shaping behaviour around a
 * record. (The routines fence deliberately went the other way and allows reads;
 * `confine/records.ts` says why the two differ.)
 *
 * ## Why an assertion in a test file was not enough
 *
 * `copilot-home.test.ts` pins the path with a string comparison, which is worth
 * having because it fails first and fails fast. It is not evidence. It would
 * pass identically if `sandbox-exec` were ignoring the profile, if realpath
 * resolution meant the profile named a directory the process never opens, or if
 * the deny had been written where something later overrides it. Each of those
 * has happened at least once in this repository's confinement work, and only the
 * filesystem can settle them.
 *
 * So every case below runs the actual command against the actual profile the
 * copilot is launched with. The first two must *succeed* — a profile that cannot
 * run `/bin/echo`, or a copilot that cannot write its own memory, would make
 * every refusal underneath meaningless — and the log file, its rolled generation
 * and the directory holding them all exist before anything is attempted, so that
 * `No such file or directory` can never masquerade as a denial.
 *
 * ## Why it is not opt-in
 *
 * Same argument `escapes.test.ts` makes: CI for this project is macOS-only by
 * policy, this needs nothing but the machine it runs on, and a security proof
 * behind an environment variable is a proof nobody runs. It skips on other
 * platforms because there is no Seatbelt there to test.
 */

import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, sep } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  recordsFenceAgrees,
  recordsFencePaths,
  recordsFenceProfile,
  type RecordsFencePaths,
} from './confine/records'
import { SANDBOX_EXEC } from './confine/seatbelt'
import { copilotPaths, legacyLogDir, type CopilotPaths } from './copilot-home'
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
/** A folder of the person's own, outside `<userData>`, chosen as the home. */
let chosen = ''
let profile = ''

/** The one row that was in the log before any attempt below. */
const EXISTING_ROW = '{"at":"2026-08-17T01:00:00.000Z","action":"session.started"}\n'

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

/** What is in the log right now, read from outside the fence. */
function logOnDisk(): string {
  try {
    return readFileSync(paths.actions, 'utf8')
  } catch {
    return ''
  }
}

beforeAll(() => {
  /*
   * No `if (!onMac) return` here, and its removal is the point.
   *
   * It used to be the first line, which left `userData` an empty string and
   * `paths` undefined off macOS — so the one case in this file that is *not*
   * about Seatbelt, the agreement between the fence's spelling of the log and
   * `copilotPaths().log`, failed on Windows against paths composed from an
   * empty string. That assertion is the thing that makes every refusal below
   * mean something, and it is pure path composition: it should hold on every
   * platform, and now it is checked on every platform. Only the `sandbox-exec`
   * runs need a Mac, and those are the `describe.skipIf` further down.
   */
  /*
   * Realpathed up front, and not for tidiness.
   *
   * `/var` is a symlink to `/private/var` on macOS, so a temporary directory
   * has two names. Seatbelt matches the resolved one — measured, and written up
   * in `plan.ts` — so a test that composed its expectations from the unresolved
   * name would be asking about paths the profile never mentions, and would
   * report a denial that is really a spelling mistake.
   */
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-log-')))
  userData = join(root, 'user-data')
  mkdirSync(userData, { recursive: true })

  paths = copilotPaths(userData)
  mkdirSync(paths.memory, { recursive: true })

  /*
   * A workspace somebody already had, outside `<userData>` entirely — the case
   * the log fence had never been measured from. See the matching block in
   * `copilot-writable-boundary.test.ts` for why "it obviously transfers" is not
   * a thing this directory gets to say.
   */
  chosen = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-log-chosen-')))
  mkdirSync(join(chosen, 'memory'), { recursive: true })

  /*
   * The log, its directory and its rolled generation all exist before anything
   * is attempted, with real rows in them.
   *
   * This is the whole difference between a proof and a coincidence. An append
   * into a directory that is not there fails with `No such file or directory`,
   * which would look like a pass and would keep looking like one on the day
   * somebody moved the log back inside the copilot's reach. So the target
   * exists, it has content, and the only thing standing between the process and
   * it is the profile.
   */
  mkdirSync(paths.log, { recursive: true })
  writeFileSync(paths.actions, EXISTING_ROW)
  writeFileSync(`${paths.actions}.1`, '{"at":"2026-08-16T01:00:00.000Z","action":"home.created"}\n')

  fenced = recordsFencePaths(userData)
  profile = recordsFenceProfile(fenced)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
  if (chosen !== '') rmSync(chosen, { recursive: true, force: true })
})

/** A shell line inside the fence, from a *chosen* working directory. */
function inChosen(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], chosen)
}

describe('the fence names the log this app really writes', () => {
  it('agrees with `copilotPaths().log`, resolved', () => {
    /*
     * The assertion that makes every refusal below mean something. A fence
     * around `<userData>/copilot-log` while `appendCopilotAction` wrote
     * somewhere else would pass all of them and protect nothing — which is
     * exactly the shape of the original defect, where the *path* was wrong and
     * the sandbox was fine.
     */
    const local = recordsFencePaths(userData)
    expect(
      recordsFenceAgrees(local, {
        routines: routinesDirFor(userData),
        routineState: runtimeStateFileFor(userData),
        log: copilotPaths(userData).log,
      }),
    ).toBe(true)
    // And it is not inside the folder the copilot works in, which is the whole
    // move that closed the hole. `sep` rather than a literal slash: with a
    // slash this would answer `false` on Windows for the wrong reason — every
    // path there is spelled with backslashes — and a check that cannot fail is
    // not a check.
    expect(paths.actions.startsWith(`${paths.root}${sep}`)).toBe(false)
  })
})

describe.skipIf(!onMac)('the copilot, against the log that records it', () => {
  it('runs at all — without this every refusal below means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('can write inside its own folder, which is what it is for', async () => {
    // The other control case. A profile that refused everything would pass
    // every denial below while being a broken app rather than a safe one.
    const ran = await sh('echo remembered > memory/a-fact.md && cat memory/a-fact.md')
    expect(ran.stdout).toContain('remembered')
    expect(ran.code).toBe(0)
  })

  it('cannot append a row that never happened', async () => {
    /*
     * The forgery this protection closes, attempted the way an agent would
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
     * Worth its own case rather than folded into the writes, and it is the one
     * rule in this fence that is about restraint rather than integrity.
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

  it('cannot move the log directory aside and put a writable one in its place', async () => {
    /*
     * The escape a reader is most likely to doubt, and the reason `(subpath …)`
     * is the right rule: it covers the directory itself, so it cannot be
     * renamed out of the way. Everything *around* it in `<userData>` is
     * writable — the copilot is an ordinary session — so without this the fence
     * would be one `mv` deep.
     */
    const ran = await sh(`mv ${JSON.stringify(paths.log)} ${JSON.stringify(`${paths.log}-old`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot recreate the old writable location and have anything read it', async () => {
    /*
     * The upgrade-path case.
     *
     * `<copilot>/log/` is inside the copilot's own working directory, so of
     * course it can make one and write whatever it likes into it — it can write
     * anywhere now. What matters is that nothing reads it: the only spelling of
     * the log's location is `CopilotPaths.actions`, and the scaffolder empties
     * the legacy directory rather than leaving a second place for rows to be
     * found. So the write succeeds and the file is not the log — which is
     * exactly what should be true, and is worth writing down so nobody later
     * reads the successful `echo` as a hole.
     */
    const ran = await sh('mkdir -p log && echo \'{"action":"invented"}\' > log/actions.jsonl')
    expect(ran.code).toBe(0)

    expect(join(paths.root, 'log')).toBe(legacyLogDir(paths))
    expect(paths.actions.startsWith(`${legacyLogDir(paths)}/`)).toBe(false)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot reach it through a symlink it plants inside its own folder', async () => {
    // The standard way past a path-prefix rule, and the reason every path here
    // is resolved: Seatbelt applies the rule to the resolved target, so a link
    // is not a way to borrow the permissions of the folder holding it.
    const ran = await sh(
      `ln -sfn ${JSON.stringify(paths.log)} escape && echo forged >> escape/actions.jsonl`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('holds for a grandchild, which is what a tool call actually is', async () => {
    // Every agent tool runs as a child of the session's shell, and most run as
    // a grandchild of it. A fence that only held for the first process would be
    // no fence at all here.
    const ran = await sh(`sh -c ${JSON.stringify(`echo forged >> ${paths.actions}`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })
})

describe.skipIf(!onMac)('with a home the person chose, outside <userData>', () => {
  /*
   * The log fence, measured from a working directory on the other side of the
   * machine from the file it protects.
   *
   * This was never asked before, because the copilot's folder was always
   * `<userData>/copilot` — a directory inside the same tree as the log. It is
   * the ordinary case now: a person points the copilot at their own workspace,
   * and the process being fenced runs there. The control case comes first, for
   * the same reason it does everywhere else in this file — a profile that
   * refused everything would pass every denial below while being a broken app.
   */

  it('can write in the folder it was pointed at', async () => {
    const ran = await inChosen('echo remembered > memory/a-fact.md && cat memory/a-fact.md')
    expect(ran.stdout).toContain('remembered')
    expect(ran.code).toBe(0)
  })

  it('still cannot append a row that never happened', async () => {
    const forged = '{"at":"2026-08-17T03:00:00.000Z","action":"tool.settings.write"}'
    const ran = await inChosen(`echo ${JSON.stringify(forged)} >> ${JSON.stringify(paths.actions)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('still cannot truncate it, or read it', async () => {
    const wiped = await inChosen(`: > ${JSON.stringify(paths.actions)}`)
    expect(wiped.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)

    const read = await inChosen(`cat ${JSON.stringify(paths.actions)}`)
    expect(read.stdout).not.toContain('session.started')
    expect(read.stderr).toMatch(/not permitted|Operation not permitted/i)
  })

  it('cannot reach it through a symlink planted in the chosen folder', async () => {
    const ran = await inChosen(
      `ln -sfn ${JSON.stringify(paths.log)} escape && echo forged >> escape/actions.jsonl`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('keeps the log under <userData> however the home moves', () => {
    /*
     * The path arithmetic the refusals rest on. `copilotPaths` takes the chosen
     * folder for `root` and ignores it for everything this app keeps *about* the
     * copilot — because a chosen home that could drag the log along with it
     * would be a chosen home that could put the log somewhere the fence does not
     * name, which is not a weaker protection but the absence of one.
     */
    const chosenPaths = copilotPaths(userData, chosen)
    expect(chosenPaths.root).toBe(chosen)
    expect(chosenPaths.actions).toBe(paths.actions)
    expect(chosenPaths.actions.startsWith(`${chosen}${sep}`)).toBe(false)
    // And the copilot's identity did not move into their folder either — the
    // other half of the same rule, and the one this file's sibling proves.
    expect(chosenPaths.instructions.startsWith(`${chosen}${sep}`)).toBe(false)
  })
})
