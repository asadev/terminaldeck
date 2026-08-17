/**
 * The records fence, asked of a real `sandbox-exec`.
 *
 * ## What this file has to prove, and why both halves matter equally
 *
 * The fence replaced a jail. So there are two ways for it to be wrong and only
 * one of them looks like a security bug:
 *
 *  - **Too weak** — the copilot can still write the routines or the log, and the
 *    Activity pane is a record its subject can compose.
 *  - **Too strong** — the fence has quietly become a jail again, and the copilot
 *    is back to being less capable than an ordinary session: signed out because
 *    the keychain is closed, unable to read the person's code, unable to write.
 *
 * Every other confinement test in this directory only guards against the first.
 * This one guards against both, and the "it is not a jail" cases below are the
 * ones that would catch a future change re-tightening the profile — including
 * the single line that would do it, `(deny default)` in place of
 * `(allow default)`.
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
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { SANDBOX_EXEC } from './seatbelt'
import {
  buildRecordsFence,
  proveRecordsFence,
  recordsFenceKind,
  recordsFenceList,
  recordsFencePaths,
  recordsFenceProfile,
  recordsFenceUnavailable,
  type RecordsFencePaths,
} from './records'

const onMac = process.platform === 'darwin'

interface Ran {
  code: number
  stdout: string
  stderr: string
}

let root = ''
let userData = ''
let paths: RecordsFencePaths
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

function sh(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], root)
}

/** The one row that was in the log before any attempt below. */
const EXISTING_ROW = '{"at":"2026-08-17T01:00:00.000Z","action":"session.started"}\n'

function logOnDisk(): string {
  try {
    return readFileSync(join(paths.log, 'actions.jsonl'), 'utf8')
  } catch {
    return ''
  }
}

beforeAll(() => {
  /*
   * Realpathed up front, and not for tidiness.
   *
   * `/var` is a symlink to `/private/var` on macOS, so a temporary directory has
   * two names, and Seatbelt matches the resolved one. The first working version
   * of this fence was measured against `/tmp/...` and refused *nothing* — every
   * write succeeded, every read succeeded, and the profile looked completely
   * correct. `recordsFencePaths` resolves for this reason; this line is what
   * makes the expectations here agree with it.
   */
  root = realpathSync(mkdtempSync(join(tmpdir(), 'records-fence-')))
  userData = join(root, 'user-data')
  mkdirSync(userData, { recursive: true })

  paths = recordsFencePaths(userData)

  /*
   * Everything the fence names exists, with real content, before anything is
   * attempted.
   *
   * This is the whole difference between a proof and a coincidence. A write into
   * a directory that is not there fails with `No such file or directory`, which
   * would look like a pass and would keep looking like one on the day somebody
   * removed a deny.
   */
  mkdirSync(paths.routines, { recursive: true })
  writeFileSync(join(paths.routines, 'existing.md'), '# a routine that is already there\n')
  writeFileSync(paths.routineState, '{"version":1,"routines":{}}\n')
  mkdirSync(paths.log, { recursive: true })
  writeFileSync(join(paths.log, 'actions.jsonl'), EXISTING_ROW)
  writeFileSync(join(paths.log, 'actions.jsonl.1'), '{"at":"2026-08-16T01:00:00.000Z","action":"home.created"}\n')

  profile = recordsFenceProfile(paths)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe('where the fence is held at all', () => {
  it('is macOS, and every other platform says so in its own sentence', () => {
    /*
     * Deliberately not `confinementKind`, which answers `namespace` on Linux.
     * That mechanism confines by replacing the mount namespace — a jail by
     * construction — and there is no way to express "everything, except these
     * few paths" with it. Answering `seatbelt` for Linux here would ship a
     * jail under the name of a fence.
     */
    expect(recordsFenceKind('darwin')).toBe('seatbelt')
    expect(recordsFenceKind('linux')).toBe('none')
    expect(recordsFenceKind('win32')).toBe('none')
    expect(recordsFenceUnavailable('linux')).not.toBe(recordsFenceUnavailable('win32'))
    for (const platform of ['linux', 'win32'] as const) {
      // The sentence a person reads has to say what is and is not still true —
      // the actions are still recorded, the record is just not held against it.
      expect(recordsFenceUnavailable(platform)).toMatch(/recorded/i)
    }
  })

  it('resolves the parent before joining, so a symlinked userData still fences', () => {
    /*
     * The failure this guards against is invisible: most of the fenced paths do
     * not exist on a fresh install, `realpathSync` throws for those, and a
     * resolver that fell back to the unresolved string would emit a rule naming
     * a path the kernel never sees.
     */
    const linked = join(root, 'linked-user-data')
    if (!existsSync(linked)) {
      // A symlink to the real user-data directory: the same place, spelled the
      // way a person's home directory on a mounted volume would spell it.
      symlinkSync(userData, linked)
    }
    const viaLink = recordsFencePaths(linked)
    expect(viaLink.routines).toBe(paths.routines)
    // The one that does not exist yet is the interesting half.
    const fresh = recordsFencePaths(join(root, 'never-used'))
    expect(fresh.routineState).toBe(join(root, 'never-used', 'routine-state.json'))
  })

  it('names exactly five things and nothing else', () => {
    /*
     * A list rather than a regular expression over the profile, for the reason
     * `plan.ts` argues. Anything appearing here later is a widening of what the
     * copilot is refused, and this is the assertion that makes somebody justify
     * it — the whole point of the change was that the copilot is an ordinary
     * session.
     *
     * It said three until remote copilot access was built, and here is the
     * justification the assertion exists to demand. The two additions are
     * `copilot-link.json` and `remote-auth.json`, and neither is about the
     * copilot's *capability*: they are the store that says which paired devices
     * may drive it, and the store that says which devices exist at all. Leaving
     * them writable would put the pen for a permission in the hand of the party
     * the permission is about, which is the same argument the action log has
     * been making since this fence was three paths long.
     *
     * Both are `file-write*` only. Reading stays allowed, like the routines and
     * unlike the log, because the copilot can already be told which devices hold
     * what through the front door — refusing it a look would be theatre, and the
     * thing worth refusing is the edit.
     */
    expect(recordsFenceList(paths)).toEqual([
      paths.routines,
      paths.routineState,
      paths.log,
      paths.remoteCopilot,
      paths.remoteAuth,
    ])
    expect(profile.match(/\(deny /g)).toHaveLength(5)
  })

  it('resolves the remote stores through their parent, not each on its own', () => {
    /*
     * The same trap the three original paths have, one directory deeper. Neither
     * of these files exists on a fresh install — nobody has granted anything and
     * nobody has paired — so `realpathSync` throws for both, and a resolver that
     * fell back to the unresolved string would emit a Seatbelt `literal` naming
     * a path the kernel never sees. Resolving `<userData>/remote` first and
     * joining onto it is what makes the fallback safe.
     */
    const fresh = recordsFencePaths(join(root, 'never-used'))
    expect(fresh.remoteCopilot).toBe(join(root, 'never-used', 'remote', 'copilot-link.json'))
    expect(fresh.remoteAuth).toBe(join(root, 'never-used', 'remote', 'remote-auth.json'))
  })
})

describe.skipIf(!onMac)('it is not a jail — the half that keeps the copilot capable', () => {
  it('runs at all', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('reaches the login keychain, which is what makes the signed-out first run go away', async () => {
    /*
     * The measurement this whole change rests on.
     *
     * Under the old `(deny default)` profile the keychain is closed — measured,
     * and `CONFINEMENT.md` calls it the biggest leak that profile closed. That
     * is also why the copilot could never be signed in as the person: its login
     * lives there. Under `(allow default)` the same lookup works, so the copilot
     * runs as the account the person is already signed into.
     *
     * `security list-keychains` rather than reading an item: it needs the same
     * Mach service the credential lookup needs (`com.apple.SecurityServer`,
     * which the old profile denies by name) and it cannot prompt, cannot fail
     * for want of a particular item, and reveals nothing.
     */
    const ran = await run(['/usr/bin/security', 'list-keychains'], root)
    expect(ran.code).toBe(0)
    expect(ran.stdout).toMatch(/\.keychain/)
  })

  it('reads the account home — the copilot sees the person’s work now', async () => {
    // Under the jail this was the headline refusal. It is now the headline
    // capability: an assistant that cannot read the code cannot triage a failing
    // test, review a diff, or scope a prompt against what is in the repository.
    const ran = await run(['/bin/ls', homedir()], root)
    expect(ran.code).toBe(0)
    expect(ran.stdout.trim()).not.toBe('')
  })

  it('writes outside the fence, which an ordinary session does and the jail did not', async () => {
    const target = join(root, 'ordinary.txt')
    const ran = await sh(`echo written > ${JSON.stringify(target)}`)
    expect(ran.code).toBe(0)
    expect(readFileSync(target, 'utf8')).toContain('written')
  })

  it('reads the routines it may not write, because refusing them would be theatre', async () => {
    /*
     * A deliberate difference from the profile this replaced, which refused the
     * read as well. That argument — a routine file names a project path and
     * carries a prompt — does not survive a copilot that can read every one of
     * those projects directly, and `routines.list` is a read-tier tool handing
     * it the same bytes through the front door.
     */
    const ran = await sh(`cat ${JSON.stringify(join(paths.routines, 'existing.md'))}`)
    expect(ran.code).toBe(0)
    expect(ran.stdout).toContain('already there')
  })
})

describe.skipIf(!onMac)('and the three things it still cannot do', () => {
  it('cannot write a routine file', async () => {
    // The escape that matters most: `routines/store.ts` is built on "the
    // directory is the database", so a `.md` file appearing here is a routine
    // that really fires. Attempted the way an agent would — an absolute path,
    // into a directory that exists, holding a routine that is syntactically
    // real.
    const target = join(paths.routines, 'self-authored.md')
    const ran = await sh(
      `echo '# Mine\n\nwhen: schedule every 5m\nin: /tmp\n\n---\n\nRun it.' > ${JSON.stringify(target)}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(ran.code).not.toBe(0)
    // The message is the diagnosis; the absence is the fact.
    expect(existsSync(target)).toBe(false)
  })

  it('cannot rewrite the engine state that holds the run budgets', async () => {
    const ran = await sh(`echo '{"version":1,"routines":{}}' > ${JSON.stringify(paths.routineState)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(readFileSync(paths.routineState, 'utf8')).toContain('"version":1')
  })

  it('cannot append a row to the action log that never happened', async () => {
    const forged = '{"at":"2026-08-17T02:00:00.000Z","action":"tool.settings.write","detail":"nothing to see"}'
    const ran = await sh(
      `echo ${JSON.stringify(forged)} >> ${JSON.stringify(join(paths.log, 'actions.jsonl'))}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot truncate it, which is the cheapest way to hide an afternoon', async () => {
    // `>` rather than `>>`: a shell opens the redirect before it runs anything,
    // so this is the shortest command that would destroy the file.
    const ran = await sh(`: > ${JSON.stringify(join(paths.log, 'actions.jsonl'))}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot delete it', async () => {
    const ran = await sh(`rm -f ${JSON.stringify(join(paths.log, 'actions.jsonl'))}`)
    expect(ran.code).not.toBe(0)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot rewrite the rolled generation either', async () => {
    // `tail()` walks back through `actions.jsonl.1`, so a busy afternoon's
    // history is in the older file. A fence holding for the live file and not
    // the one behind it would protect the last ten minutes of the story.
    const rolled = join(paths.log, 'actions.jsonl.1')
    const ran = await sh(`echo forged > ${JSON.stringify(rolled)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(readFileSync(rolled, 'utf8')).toContain('home.created')
  })

  it('cannot even read the log', async () => {
    const ran = await sh(`cat ${JSON.stringify(join(paths.log, 'actions.jsonl'))}`)
    expect(ran.stdout).not.toContain('session.started')
    expect(ran.stderr).toMatch(/not permitted|Operation not permitted/i)
  })
})

describe.skipIf(!onMac)('the ways round it that a shell actually has', () => {
  it('cannot rename the fenced directory out of the way', async () => {
    /*
     * The escape a reader is most likely to doubt, and the reason `(subpath …)`
     * is the right rule rather than a regex over the contents: `(subpath X)`
     * covers X itself, so the directory cannot be moved aside and replaced with
     * a writable one of the same name.
     */
    const ran = await sh(`mv ${JSON.stringify(paths.routines)} ${JSON.stringify(`${paths.routines}-moved`)}`)
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(existsSync(paths.routines)).toBe(true)
    expect(existsSync(`${paths.routines}-moved`)).toBe(false)
  })

  it('cannot remove the fenced directory and rebuild it', async () => {
    const ran = await sh(`rm -rf ${JSON.stringify(paths.routines)}`)
    expect(ran.code).not.toBe(0)
    expect(existsSync(join(paths.routines, 'existing.md'))).toBe(true)
  })

  it('cannot reach them through a symlink it plants outside', async () => {
    // The standard way past a path-prefix rule. Seatbelt applies the rule to the
    // resolved target, so a link is not a way to borrow the permissions of the
    // folder holding it.
    const ran = await sh(
      `ln -sfn ${JSON.stringify(paths.log)} escape && echo forged >> escape/actions.jsonl`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('holds for a grandchild, which is what a tool call actually is', async () => {
    // Every agent tool runs as a child of the session's shell and most run as a
    // grandchild of it. A fence that only held for the first process would be no
    // fence at all here.
    const ran = await sh(
      `sh -c ${JSON.stringify(`echo forged >> ${join(paths.log, 'actions.jsonl')}`)}`,
    )
    expect(ran.stderr).toMatch(/not permitted/i)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('cannot loosen itself with a second sandbox-exec', async () => {
    // Measured in `seatbelt.ts` for the jail and true here for the same reason:
    // `sandbox_apply` refuses to run inside an existing sandbox.
    const ran = await sh(
      `${SANDBOX_EXEC} -p '(version 1)(allow default)' /bin/sh -c ${JSON.stringify(
        `echo forged >> ${join(paths.log, 'actions.jsonl')}`,
      )}`,
    )
    expect(ran.code).not.toBe(0)
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })
})

describe.skipIf(!onMac)('the proof, which is what decides whether it is claimed', () => {
  it('holds on this machine, and says so with nothing left behind', async () => {
    const proof = await proveRecordsFence(paths, 'darwin')
    expect(proof).toEqual({ held: true, detail: '' })
    // The canary the proof writes is named with a random token; nothing of the
    // kind may survive in the folder the Activity pane reads.
    expect(readdirSync(paths.log).filter((name) => name.startsWith('.fence-probe'))).toEqual([])
    expect(logOnDisk()).toBe(EXISTING_ROW)
  })

  it('reports a broken profile rather than calling it held', async () => {
    // A profile under which nothing runs would pass the denial check by failing
    // at everything — the exact shape of false confidence this project has
    // shipped before, and the reason the proof runs `/bin/echo` first.
    const proof = await proveRecordsFence(paths, 'darwin', async () => {
      throw Object.assign(new Error('exit 1'), { stdout: '', stderr: 'sandbox-exec: no' })
    })
    expect(proof.held).toBe(false)
    expect(proof.detail).toContain('would not run a command')
  })

  it('reports a fence that has become a jail rather than calling it held', async () => {
    /*
     * The check nothing else in this repository makes. A profile that refused an
     * ordinary write outside the fence would pass every denial above while being
     * the jail this change removed, and the only symptom would be a copilot that
     * is mysteriously worse at its job.
     *
     * Driven by a runner that echoes the token (so check 1 passes) and writes
     * nothing (so check 2 fails).
     */
    const token = /[0-9a-f]{32}/
    const proof = await proveRecordsFence(paths, 'darwin', async (_command, args) => {
      const line = args.join(' ')
      const found = token.exec(line)
      return { stdout: line.includes('/bin/echo') && found ? found[0] : '', stderr: '' }
    })
    expect(proof.held).toBe(false)
    expect(proof.detail).toContain('stricter than an ordinary session')
  })

  it('answers with a reason instead of a fence off macOS, and never throws', async () => {
    for (const platform of ['linux', 'win32'] as const) {
      const built = await buildRecordsFence({ userData, platform })
      expect(built.fence).toBeNull()
      expect(built.reason).toBe(recordsFenceUnavailable(platform))
    }
  })

  it('wraps a spawn with the profile once it has been proven', async () => {
    const built = await buildRecordsFence({ userData, platform: 'darwin' })
    expect(built.reason).toBeNull()
    const launch = built.fence?.apply('/bin/echo', ['hello'])
    expect(launch?.command).toBe(SANDBOX_EXEC)
    expect(launch?.args[0]).toBe('-p')
    expect(launch?.args.slice(-2)).toEqual(['/bin/echo', 'hello'])
    // The profile travels as an argument rather than in a file, for the reason
    // `seatbelt.ts` gives: a file is replaceable in the moment between being
    // written and being read.
    expect(launch?.args[1]).toContain('(allow default)')
  })
})
