/**
 * The tests that try to get out.
 *
 * ## Why these are not unit tests
 *
 * Everything in `seatbelt.test.ts` checks that a string contains a rule, which
 * is worth doing and proves nothing about whether the rule holds. This project
 * has already shipped a subsystem where 3,628 passing tests sat on top of a
 * handshake that threw inside a silent catch in the runtime that mattered; the
 * lesson written down at the time was to prove things from the side that cannot
 * be fooled. For a filesystem boundary that side is the filesystem: write a file
 * outside the folder, ask a real `sandbox-exec` to read it with the real
 * generated profile, and look at what comes back.
 *
 * So every case here runs the actual command. A test that passes because
 * nothing ran at all is the failure mode to fear, which is why the first case is
 * the one that must *succeed* — if the sandbox cannot run `/bin/echo` then every
 * refusal below is meaningless and this file says so first.
 *
 * ## Why they are not opt-in
 *
 * `relay-live.test.ts` is opt-in because it needs the internet. These need
 * nothing but the machine they are running on, CI for this project is macOS-only
 * by policy, and a security boundary whose proof is behind an environment
 * variable is a proof nobody runs. They skip on other platforms because there is
 * no confinement there to test — which `confine/index.ts` says out loud rather
 * than papering over.
 */

import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { confinedEnv, planFor, proveConfinement, realResolver } from './index'
import type { ConfinementPlan } from './plan'
import { SANDBOX_EXEC, seatbeltProfile } from './seatbelt'

const onMac = process.platform === 'darwin'

interface Ran {
  code: number
  stdout: string
  stderr: string
}

let root = ''
let granted = ''
let elsewhere = ''
let otherDevice = ''
let deviceHome = ''
let plan: ConfinementPlan
let profile = ''

/** The secret that must never come back out of the sandbox. */
const SECRET = 'canary-4f2b91d7e0a5-do-not-leak'

/**
 * Run something the way the spawn path would.
 *
 * The environment is not decoration here. `HOME` has to point inside the
 * boundary or half of these cases fail for the wrong reason: `git --version`
 * with an unreadable home prints nothing to stdout and a `fatal: unable to
 * access '…/.gitconfig'` to stderr, which would read as "the tools are broken
 * under confinement" when what is actually broken is the test. Production sets
 * exactly these two variables — see `confinedEnv`.
 */
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

/** Run a shell line inside the sandbox, from the granted folder. */
function sh(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], granted)
}

beforeAll(() => {
  if (!onMac) return
  root = realpathSync(mkdtempSync(join(tmpdir(), 'confine-escapes-')))
  granted = join(root, 'granted')
  elsewhere = join(root, 'elsewhere')
  otherDevice = join(root, 'other-device-folder')
  deviceHome = join(root, 'device-home')
  mkdirSync(granted, { recursive: true })
  mkdirSync(elsewhere, { recursive: true })
  mkdirSync(otherDevice, { recursive: true })
  mkdirSync(join(deviceHome, 'tmp'), { recursive: true })

  writeFileSync(join(elsewhere, 'secret.txt'), SECRET)
  writeFileSync(join(otherDevice, 'secret.txt'), SECRET)
  writeFileSync(join(granted, 'mine.txt'), 'mine')
  // A symlink inside the folder pointing out of it. The obvious way past a
  // path-prefix rule, and the reason the rule has to be applied to the resolved
  // path rather than the one that was typed.
  symlinkSync(elsewhere, join(granted, 'link-out'))
  symlinkSync(homedir(), join(granted, 'link-home'))

  plan = planFor({
    folder: granted,
    device: { home: deviceHome, writable: [], files: [] },
    accountHome: homedir(),
    path: process.env.PATH ?? '/usr/bin:/bin',
    platform: 'darwin',
    resolver: realResolver,
  })
  profile = seatbeltProfile(plan)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe.skipIf(!onMac)('a confined session, run for real', () => {
  it('runs at all — without this every refusal below means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  it('can read and write inside its own folder', async () => {
    const ran = await sh('cat mine.txt && echo written > new.txt && cat new.txt')
    expect(ran.stdout).toContain('mine')
    expect(ran.stdout).toContain('written')
  })

  it('cannot list the folder above it', async () => {
    const ran = await sh('cd .. && ls')
    expect(ran.stdout).not.toContain('elsewhere')
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot read a file elsewhere by absolute path', async () => {
    const ran = await sh(`cat ${JSON.stringify(join(elsewhere, 'secret.txt'))}`)
    expect(ran.stdout).not.toContain(SECRET)
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot follow a symlink out of the folder', async () => {
    const ran = await sh('cat link-out/secret.txt')
    expect(ran.stdout).not.toContain(SECRET)
  })

  it('cannot write through a symlink out of the folder', async () => {
    const ran = await sh('echo pwned > link-out/pwned.txt')
    expect(ran.code).not.toBe(0)
  })

  it('cannot reach another device\'s granted folder', async () => {
    // Two devices, two grants, and neither may read the other's. The plan holds
    // one folder, so the second is outside it exactly like any other directory.
    const ran = await sh(`cat ${JSON.stringify(join(otherDevice, 'secret.txt'))}`)
    expect(ran.stdout).not.toContain(SECRET)
  })

  it('cannot list the account\'s home directory', async () => {
    const ran = await sh(`ls ${JSON.stringify(homedir())}`)
    expect(ran.code).not.toBe(0)
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot follow a symlink to the account\'s home directory', async () => {
    const ran = await sh('ls link-home')
    expect(ran.code).not.toBe(0)
  })

  it('cannot read the git and gh credentials the environment redirect only hid', async () => {
    // `git-guest.ts` redirects git and `gh` by environment, which changes what
    // they do *by default*. A determined shell was always able to read the files
    // directly and copy what it found — that gap is what this closes, so it is
    // checked at the file level rather than by running git.
    for (const path of ['.gitconfig', '.config/gh/hosts.yml', '.ssh']) {
      const ran = await sh(`cat ${JSON.stringify(join(homedir(), path))} 2>&1; ls ${JSON.stringify(join(homedir(), path))}`)
      expect(ran.stdout).not.toMatch(/ghp_|gho_|github_pat_/)
      expect(`${ran.stdout}${ran.stderr}`).toMatch(/not permitted|No such file/i)
    }
  })

  it('cannot reach the login keychain, where the agent CLI keeps its token', async () => {
    const ran = await sh(`ls ${JSON.stringify(join(homedir(), 'Library/Keychains'))}`)
    expect(ran.code).not.toBe(0)
  })

  it('cannot write outside the folder', async () => {
    for (const target of ['/tmp/terminaldeck-escape-probe', join(homedir(), 'terminaldeck-escape-probe')]) {
      const ran = await sh(`echo x > ${JSON.stringify(target)}`)
      expect(ran.code).not.toBe(0)
    }
  })

  it('holds for a grandchild as firmly as for the shell', async () => {
    const target = JSON.stringify(join(elsewhere, 'secret.txt'))
    const ran = await sh(`/bin/sh -c '/bin/sh -c "cat ${target}"'`)
    expect(ran.stdout).not.toContain(SECRET)
  })

  it('cannot be loosened from inside', async () => {
    const ran = await sh(
      `${SANDBOX_EXEC} -p '(version 1)(allow default)' /bin/cat ${JSON.stringify(join(elsewhere, 'secret.txt'))}`,
    )
    expect(ran.stdout).not.toContain(SECRET)
    expect(ran.stderr).toMatch(/sandbox_apply|not permitted/i)
  })

  it('cannot ask another program to read the file for it', async () => {
    // The classic Seatbelt escape: hand the job to something outside the
    // sandbox. `osascript`'s `do shell script` forks in-sandbox, so it is
    // refused; an AppleEvent to a running app cannot resolve the app at all
    // because LaunchServices is closed to it.
    const target = join(elsewhere, 'secret.txt')
    const viaShell = await sh(`/usr/bin/osascript -e 'do shell script "cat ${target}"'`)
    expect(viaShell.stdout).not.toContain(SECRET)
    const viaEvent = await sh(`/usr/bin/osascript -e 'tell application "Finder" to get name of home'`)
    expect(viaEvent.code).not.toBe(0)
  })

  it('cannot escalate through a setuid binary', async () => {
    const ran = await sh('sudo -n true')
    expect(ran.code).not.toBe(0)
  })

  it('still has the tools, which live outside the folder', async () => {
    // Rule five: a confinement that breaks node or git is not usable. Both are
    // outside the granted folder by construction and must stay reachable.
    const node = await sh('command -v node >/dev/null 2>&1 && node -e "console.log(6*7)" || echo skipped')
    expect(node.stdout.trim()).toMatch(/^(42|skipped)$/)
    const git = await sh('git --version')
    expect(git.stdout).toMatch(/^git version/)
    // And the shim noise is gone: without the xcrun cache rule every git command
    // prints two permission errors before doing its job.
    expect(git.stderr).not.toMatch(/xcrun_db/)
  })

  it('proves itself against a canary before a session is allowed to start', async () => {
    const proof = await proveConfinement(plan, 'darwin')
    expect(proof).toEqual({ ok: true, detail: '' })
  })

  it('fails the proof when the plan does not confine anything', async () => {
    // The check that the check works: a plan whose readable list contains the
    // temporary directory the canary is written to cannot fail, and answering
    // "confined" on the strength of a test that cannot fail is worse than
    // answering "unknown".
    const wide: ConfinementPlan = {
      ...plan,
      readable: [...plan.readable, realpathSync(tmpdir())],
    }
    const proof = await proveConfinement(wide, 'darwin')
    expect(proof.ok).toBe(false)
  })
})
