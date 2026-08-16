/**
 * The Linux tests that try to get out.
 *
 * ## Why these are not unit tests
 *
 * `linux.test.ts` checks that the plan is right, which is worth doing and
 * proves nothing about whether the kernel holds. This project has already
 * shipped a subsystem where 3,628 passing tests sat on top of a handshake that
 * threw inside a silent catch in the runtime that mattered, and the lesson
 * written down at the time was to prove things from the side that cannot be
 * fooled. For a filesystem boundary that side is the filesystem: write a file
 * outside the folder, ask a real `unshare` to read it with the real generated
 * argument list, and look at what comes back.
 *
 * It is not a hypothetical here either. Building this module, four things
 * passed inspection and failed measurement:
 *
 *  1. A **relative** path walked straight out of the boundary, through the
 *     working directory the launcher had set before the namespace existed,
 *     while `pwd`, `/proc/self/cwd` and `cd .. && ls` all looked right.
 *  2. A descriptor the launcher left open was a path out that no mount covers.
 *  3. Without a PID namespace, a confined session killed a process of the
 *     account's outside the boundary — and `kill -TERM -1` from inside took
 *     down the login session that had launched it.
 *  4. A Windows `.exe` inside the granted folder still ran, through WSL interop,
 *     with `WSL_INTEROP` unset. Covering `/run/WSL` is what stops it.
 *
 * Every one of those looks like a passing test if you only ask the shell.
 *
 * ## Where this runs
 *
 * On Linux, and it skips everywhere else because there is no namespace to test
 * — which `confine/index.ts` says out loud rather than papering over. CI for
 * this project is macOS-only by policy, so **this file does not run in CI**.
 * It was run on a real Ubuntu 24.04 under WSL2 while the module was written,
 * and it is what a Linux desktop or the headless host runs `npm test` against.
 *
 * A machine that cannot make a user namespace at all — a distribution with
 * AppArmor's `kernel.apparmor_restrict_unprivileged_userns` switched on — is
 * a real answer rather than a skip: the first case below asserts that the proof
 * says so plainly, and the rest are gated on the machine having said yes. A
 * boundary that quietly stops being tested is how the thing it protects quietly
 * stops being protected.
 */

import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { confineSpawn, planFor, proveConfinement, realResolver } from './index'
import { confinedEnv, type ConfinementPlan } from './plan'

const onLinux = process.platform === 'linux'

/** The secret that must never come back out of the namespace. */
const SECRET = 'canary-linux-8b41c7e2-do-not-leak'

/**
 * The interrupt, written as an escape rather than as the byte itself.
 *
 * A literal control character in a source file is one careless editor away from
 * being stripped, and if it were, the pty case would stop pressing Ctrl-C while
 * still passing for the wrong reason: `MARK-INT` would arrive after the sleep
 * rather than instead of it, and nobody would notice for thirty seconds.
 */
const CTRL_C = '\u0003'

let root = ''
let granted = ''
let elsewhere = ''
let otherDevice = ''
let deviceHome = ''
let guestGit = ''
let helperDir = ''
let helper = ''
let otherGuest = ''
let plan: ConfinementPlan
/** A process of this account's, outside the boundary, for the signal cases. */
let victim: ChildProcess | null = null
/** Every probe's answer, from one confined session. Empty when it never ran. */
let seen = new Map<string, string>()
let proofDetail = ''
let confinable = false

function run(command: string, args: string[], cwd: string): Promise<{ code: number; out: string }> {
  return new Promise((resolve) => {
    execFile(
      command,
      args,
      {
        cwd,
        timeout: 60_000,
        encoding: 'utf8',
        maxBuffer: 4 << 20,
        env: { ...process.env, ...confinedEnv(deviceHome) },
      },
      (error, stdout, stderr) => {
        const code =
          error && typeof (error as { code?: unknown }).code === 'number'
            ? (error as { code: number }).code
            : error
              ? 1
              : 0
        resolve({ code, out: `${stdout}${stderr}` })
      },
    )
  })
}

/**
 * One confined session, asked everything at once.
 *
 * One session rather than one per question, because each one builds a dozen
 * mounts and because the interesting failures are about a *session*, not about
 * a command. Each line prints `key<TAB>answer`, so a probe that fails leaves an
 * empty answer rather than shifting every later assertion by one line.
 */
function battery(): string {
  const say = (key: string, body: string): string => `printf '%s\\t%s\\n' ${key} "$(${body} 2>&1 | tr '\\n' ' ')"`
  const victimPid = victim?.pid ?? 0
  return [
    `printf 'alive\\talive\\n'`,
    say('own-read', 'cat mine.txt'),
    say('own-write', 'echo written > new.txt && cat new.txt'),
    say('uid', 'id -u'),
    say('cwd', 'pwd'),
    // The escape that would have shipped: a relative path, from the working
    // directory the launcher set before the namespace existed.
    say('relative-sibling', 'cat ../other-device-folder/secret.txt'),
    say('relative-home', 'cat ../.terminaldeck-escape-canary'),
    say('absolute-elsewhere', `cat ${JSON.stringify(join(elsewhere, 'secret.txt'))}`),
    say('other-device', `cat ${JSON.stringify(join(otherDevice, 'secret.txt'))}`),
    say('other-guest-identity', `cat ${JSON.stringify(join(otherGuest, 'identity'))}`),
    say('helper-file', `cat ${JSON.stringify(helper)}`),
    say('helper-folder', `ls ${JSON.stringify(helperDir)}`),
    say('symlink-home', 'ls link-home'),
    say('home-root', 'ls /home'),
    say('tmp', 'ls -A /tmp'),
    say('mnt', 'ls /mnt'),
    say('mnt-c', 'ls /mnt/c'),
    say('run-wsl', 'ls -A /run/WSL'),
    say('interop', 'printf %s "${WSL_INTEROP:-unset}"'),
    say('agent-sock', 'printf %s "${SSH_AUTH_SOCK:-unset}"'),
    say('umount', 'umount /home'),
    say('after-umount', `cat ${JSON.stringify(join(elsewhere, 'secret.txt'))}`),
    say('nested-userns', 'unshare --user --map-root-user id'),
    say('caps', 'capsh --print | grep -m1 ^Current'),
    say('write-outside', `echo x > ${JSON.stringify(join(elsewhere, 'pwned.txt'))} && echo WROTE`),
    say('proc-outside', `cat /proc/${process.pid}/environ`),
    say('fd-three', 'ls /proc/self/fd/3/'),
    say('fd-nine', 'ls /proc/self/fd/9/'),
    say('kill-outside', `kill -TERM ${victimPid}`),
    say('stage-left', 'ls -d /tmp/.terminaldeck-confine-*'),
    say('resolv', 'head -c 20 /etc/resolv.conf'),
    say('dns', 'getent hosts localhost'),
    say('git', 'git --version'),
    say('node', 'node -e "console.log(6*7)"'),
  ].join('\n')
}

beforeAll(async () => {
  if (!onLinux) return
  // Under the account's home on purpose: that is where granted folders are, and
  // it is the tree the boundary covers. `/tmp` would work too and would test a
  // different cover.
  root = realpathSync(mkdtempSync(join(homedir(), '.terminaldeck-escape-')))
  granted = join(root, 'granted')
  elsewhere = join(root, 'elsewhere')
  otherDevice = join(root, 'other-device-folder')
  deviceHome = join(root, 'store', 'device-home', 'device-abc')
  helperDir = join(root, 'store', 'guest-git')
  guestGit = join(helperDir, 'device-abc')
  otherGuest = join(helperDir, 'device-zzz')
  for (const dir of [granted, elsewhere, otherDevice, join(deviceHome, 'tmp'), guestGit, otherGuest]) {
    mkdirSync(dir, { recursive: true })
  }
  writeFileSync(join(elsewhere, 'secret.txt'), SECRET)
  writeFileSync(join(otherDevice, 'secret.txt'), SECRET)
  writeFileSync(join(otherGuest, 'identity'), SECRET)
  writeFileSync(join(root, '.terminaldeck-escape-canary'), SECRET)
  writeFileSync(join(granted, 'mine.txt'), 'mine')
  helper = join(helperDir, 'askpass.sh')
  writeFileSync(helper, '#!/bin/sh\necho helper\n', { mode: 0o700 })
  // A symlink inside the folder pointing out of it. The obvious way past a
  // path rule, and here it resolves into the covering tmpfs instead.
  symlinkSync(homedir(), join(granted, 'link-home'))

  plan = planFor({
    folder: granted,
    device: { home: deviceHome, writable: [guestGit], files: [helper] },
    accountHome: homedir(),
    path: process.env.PATH ?? '/usr/bin:/bin',
    platform: 'linux',
    resolver: realResolver,
  })

  const proof = await proveConfinement(plan, 'linux')
  confinable = proof.ok
  proofDetail = proof.detail
  if (!confinable) return

  // A process this account owns, outside the boundary, so the signal cases have
  // something real to aim at.
  victim = spawn('/bin/sleep', ['120'], { stdio: 'ignore' })
  await new Promise((resolve) => setTimeout(resolve, 200))

  const launch = await confineSpawn(plan, '/bin/sh', ['-c', battery()], 'linux')
  // Two descriptors on a directory outside the boundary, opened the way a leaky
  // parent process would leave them, so the script's close is tested.
  const ran = await run(
    '/bin/sh',
    [
      '-c',
      `exec 3<${JSON.stringify(elsewhere)} 9<${JSON.stringify(elsewhere)}; exec "$@"`,
      'leaky-launcher',
      launch.command,
      ...launch.args,
    ],
    granted,
  )
  seen = new Map(
    ran.out
      .split('\n')
      .map((line) => line.split('\t'))
      .filter((parts): parts is [string, string] => parts.length === 2)
      .map(([key, value]) => [key, value.trim()]),
  )
}, 120_000)

afterAll(() => {
  victim?.kill('SIGKILL')
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

/** One probe's answer. Fails loudly rather than passing on an absent line. */
function answer(key: string): string {
  const value = seen.get(key)
  expect(value, `the confined session never answered "${key}" — see the session output`).toBeDefined()
  return value ?? ''
}

describe.skipIf(!onLinux)('this machine, asked whether it can confine anything at all', () => {
  it('gives a straight answer with a reason when it cannot', () => {
    // Not a skip. A distribution with AppArmor's userns restriction switched on
    // is a machine where every device session must be refused, and the sentence
    // that refuses it has to name something a person can act on.
    if (confinable) {
      expect(proofDetail).toBe('')
      return
    }
    expect(proofDetail).not.toBe('')
    console.warn(`[confine] this machine cannot hold a session: ${proofDetail}`)
  })
})

describe.skipIf(!onLinux)('a confined Linux session, run for real', () => {
  it('runs at all — without this every refusal below means nothing', () => {
    expect(confinable, `the proof refused this machine: ${proofDetail}`).toBe(true)
    expect(answer('alive')).toBe('alive')
  })

  it('can read and write inside its own folder', () => {
    expect(answer('own-read')).toBe('mine')
    expect(answer('own-write')).toBe('written')
  })

  it('starts in the granted folder, re-entered after the mounts', () => {
    expect(answer('cwd')).toBe(granted)
  })

  it('cannot read a sibling folder through a RELATIVE path', () => {
    // The escape that would have shipped. The working directory the launcher
    // set belongs to the tree that is about to be covered, so until the script
    // re-entered the folder by absolute path this returned the secret while
    // every other check looked perfect.
    expect(answer('relative-sibling')).not.toContain(SECRET)
    expect(answer('relative-home')).not.toContain(SECRET)
  })

  it('cannot read a file elsewhere by absolute path', () => {
    expect(answer('absolute-elsewhere')).not.toContain(SECRET)
  })

  it("cannot reach another device's granted folder", () => {
    expect(answer('other-device')).not.toContain(SECRET)
  })

  it("cannot reach another device's git identity, whose folder holds its own", () => {
    // The helper has to be readable and the directory it lives in must not be,
    // because that directory holds every other device's git identity.
    expect(answer('helper-file')).toContain('helper')
    expect(answer('other-guest-identity')).not.toContain(SECRET)
    expect(answer('helper-folder')).not.toContain('device-zzz')
  })

  it('cannot follow a symlink to the account home', () => {
    expect(answer('symlink-home')).not.toContain('.ssh')
  })

  it('sees only itself under /home, and an empty /tmp', () => {
    // Other accounts on the machine are behind the same cover — measured on a
    // box with three of them, which is the case this asserts against rather
    // than a count that would be vacuously true on a single-user machine.
    expect(answer('tmp')).toBe('')
    const mine = homedir().split('/').filter(Boolean).pop() ?? ''
    let neighbours: string[] = []
    try {
      neighbours = readdirSync('/home').filter((name) => name !== mine)
    } catch {
      neighbours = []
    }
    for (const name of neighbours) expect(answer('home-root')).not.toContain(name)
  })

  it('cannot write outside the folder', () => {
    expect(answer('write-outside')).not.toContain('WROTE')
  })

  it('cannot unmount its way out, which without the capability drop it could', () => {
    expect(answer('umount')).toMatch(/must be superuser|not permitted|not mounted/i)
    expect(answer('after-umount')).not.toContain(SECRET)
    expect(answer('caps')).toMatch(/Current:\s*=\s*$/)
  })

  it('cannot get the capabilities back with a nested user namespace', () => {
    expect(answer('nested-userns')).toMatch(/not permitted|failed/i)
    expect(answer('nested-userns')).not.toMatch(/uid=0/)
  })

  it('cannot read the environment of a process outside the boundary', () => {
    // Closed by the user namespace itself rather than by any mount: credentials
    // in a child user namespace fail ptrace_may_access against a process in the
    // parent one.
    expect(answer('proc-outside')).not.toContain('PATH=')
    expect(answer('proc-outside')).toMatch(/denied|No such/i)
  })

  it('cannot signal a process outside the boundary', () => {
    // Measured before the PID namespace was added: the signal was delivered and
    // the process died, and `kill -TERM -1` took down the whole login session.
    expect(answer('kill-outside')).toMatch(/No such process/i)
    expect(victim?.killed ?? true).toBe(false)
    expect(victim?.exitCode).toBeNull()
  })

  it('has no inherited descriptor to walk out through', () => {
    // Two descriptors on a directory outside the boundary were open when the
    // session started, exactly as a leaky parent would leave them. A mount
    // cannot cover an open descriptor; only closing it can.
    expect(answer('fd-three')).not.toContain('secret.txt')
    expect(answer('fd-nine')).not.toContain('secret.txt')
  })

  it('has no way back to Windows through interop', () => {
    // Both halves, because only one of them does the work: with the variable
    // unset and this directory left alone, a Windows binary inside the granted
    // folder still ran.
    expect(answer('interop')).toBe('unset')
    // Empty on a machine that has them, "no such file" on one that never did.
    expect(answer('run-wsl')).toMatch(/^$|No such file|cannot access/i)
    // Not "/mnt is empty", because it is not: keeping `/etc/resolv.conf`
    // reachable rebuilds `/mnt/wsl` inside the covering tmpfs and binds that one
    // file into it read-only. What must be gone is every Windows drive, which
    // is where the owner's Windows profile and every `.exe` live. This test
    // caught the difference — it was written expecting an empty directory and
    // the session answered `wsl`.
    for (const entry of answer('mnt').split(/\s+/).filter(Boolean)) {
      expect(entry).not.toMatch(/^[a-z]$/i)
    }
    expect(answer('mnt-c')).toMatch(/No such file|cannot access/i)
  })

  it('is not handed the account ssh agent', () => {
    expect(answer('agent-sock')).toBe('unset')
  })

  it('leaves no staging directory behind', () => {
    expect(answer('stage-left')).toMatch(/No such file|cannot access/i)
  })

  it('still has its tools and its network, which live outside the folder', () => {
    // Rule five: a confinement that breaks node or git is not usable. And DNS
    // is part of that — on WSL `/etc/resolv.conf` is a symlink into `/mnt`, so
    // covering the Windows drives took the name servers with it until the plan
    // kept that one file.
    expect(answer('git')).toMatch(/^git version/)
    expect(answer('node')).toBe('42')
    expect(answer('resolv')).not.toMatch(/No such file/i)
    expect(answer('dns')).toContain('localhost')
  })
})

describe.skipIf(!onLinux)('the proof, which runs before every session', () => {
  it('refuses a plan whose canary would land inside the boundary', async () => {
    // A grant on the whole home directory. There would be nothing left to hold
    // the session inside, and the test that is supposed to notice cannot — so
    // the session is refused rather than started on a check that cannot fail.
    const wide = { ...plan, writable: [...plan.writable, homedir()] }
    const proof = await proveConfinement(wide, 'linux')
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/could not fail/)
  })

  it('leaves nothing behind in the account home', async () => {
    const before = await run('/bin/sh', ['-c', 'ls -A ~ | wc -l'], homedir())
    await proveConfinement(plan, 'linux')
    const after = await run('/bin/sh', ['-c', 'ls -A ~ | wc -l'], homedir())
    expect(after.out.trim()).toBe(before.out.trim())
  })
})

/**
 * Job control, through a real terminal.
 *
 * Separate from everything above because it needs `node-pty`, and because what
 * it asks is different in kind: the product does not run sessions through a
 * pipe. Ctrl-C is the most-used key in a terminal, the session is PID 1 of its
 * own namespace, and whether a shell can still interrupt its own foreground job
 * from there is a question about a pty and answerable only with one.
 */
describe.skipIf(!onLinux)('a confined session in a real terminal', () => {
  it('starts, refuses the way out, and still interrupts its own job', async () => {
    expect(confinable, `the proof refused this machine: ${proofDetail}`).toBe(true)
    const pty = await import('node-pty')
    const launch = await confineSpawn(plan, '/bin/bash', ['-l'], 'linux')
    const proc = pty.spawn(launch.command, launch.args, {
      name: 'xterm-256color',
      cols: 100,
      rows: 30,
      cwd: granted,
      env: { ...process.env, ...confinedEnv(deviceHome), TERM: 'xterm-256color' } as Record<string, string>,
    })
    let out = ''
    proc.onData((data) => {
      out += data
    })
    const type = async (text: string, waitMs: number, until?: RegExp): Promise<void> => {
      proc.write(text)
      const deadline = Date.now() + waitMs
      while (Date.now() < deadline) {
        if (until && until.test(out)) return
        await new Promise((resolve) => setTimeout(resolve, 50))
      }
    }
    await type('echo MARK-ALIVE\r', 4000, /MARK-ALIVE/)
    await type(`cat ${JSON.stringify(join(elsewhere, 'secret.txt'))}\r`, 3000, /No such file|denied/)
    await type('echo written > inside.txt && cat inside.txt\r', 3000, /written/)
    await type('sleep 30\r', 1500)
    await type(CTRL_C, 1500)
    await type('echo MARK-INT\r', 4000, /MARK-INT/)
    try {
      proc.kill()
    } catch {
      /* already gone */
    }
    const plain = out.replace(/\[[0-9;?]*[a-zA-Z]/g, '').replace(/\r/g, '')
    expect(plain).toContain('MARK-ALIVE')
    expect(plain).not.toContain(SECRET)
    expect(plain).toContain('written')
    // Ctrl-C reached the job rather than being swallowed by the namespace.
    expect(plain).toContain('MARK-INT')
  }, 40_000)
})
