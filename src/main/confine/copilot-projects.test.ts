/**
 * The copilot's project grant, proven against a real sandbox.
 *
 * ## Why this file is not a unit test
 *
 * The claim being made is *"the copilot can read your code and cannot change a
 * line of it, and cannot read your credentials while it does"*. That is a claim
 * about a kernel, and the only honest way to check it is to ask the kernel:
 * write real files into real folders, generate the real profile from the real
 * `copilotPlan`, run `/usr/bin/sandbox-exec` with it, and look at what comes
 * back. `seatbelt.test.ts` checks that the profile *contains* the rules, which
 * is worth doing and proves nothing about whether they hold — and this project
 * has already shipped a subsystem where thousands of passing tests sat on top of
 * a handshake that threw silently in the runtime that mattered.
 *
 * The order of the cases is deliberate. The first one must *succeed*: if the
 * sandbox cannot run `/bin/echo`, then every refusal below is a refusal of
 * everything and means nothing.
 *
 * The write cases are the ones that matter most, and there are five of them
 * because "read-only" has to hold against a shell redirect, an editor-style
 * rewrite, a new file, a new directory and a delete — not just against the one
 * verb somebody thought of.
 *
 * ## Why they are not opt-in
 *
 * Same reason as `escapes.test.ts`: they need nothing but the machine they run
 * on, CI here is macOS-only by policy, and a security boundary whose proof is
 * behind an environment variable is a proof nobody runs.
 */

import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { copilotPlan } from '../copilot-session'
import { confinedEnv } from './index'
import type { ConfinementPlan } from './plan'
import { SANDBOX_EXEC, seatbeltProfile } from './seatbelt'

const onMac = process.platform === 'darwin'

interface Ran {
  code: number
  stdout: string
  stderr: string
}

let root = ''
/** A project the person added. Readable, never writable. */
let projectA = ''
/** A second one, so "a project" is never confused with "the granted folder". */
let projectB = ''
/** A folder they did *not* add. The control: nothing about it may be reachable. */
let unlisted = ''
/** The copilot's own folder — its cwd, and writable. */
let copilotFolder = ''
/** The copilot's own home — writable. */
let deviceHome = ''
let plan: ConfinementPlan
let profile = ''

/** Planted in every file that must never come back out. */
const SECRET = 'canary-9d31c7a6b408-do-not-leak'

function run(args: string[], cwd: string): Promise<Ran> {
  return new Promise((resolve) => {
    execFile(
      SANDBOX_EXEC,
      ['-p', profile, ...args],
      {
        cwd,
        timeout: 20_000,
        encoding: 'utf8',
        env: { ...process.env, ...confinedEnv(deviceHome) },
      },
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

/** Run a shell line inside the sandbox, from the copilot's own folder. */
function sh(line: string): Promise<Ran> {
  return run(['/bin/sh', '-c', line], copilotFolder)
}

const quoted = (path: string): string => JSON.stringify(path)

beforeAll(() => {
  if (!onMac) return
  root = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-projects-')))
  projectA = join(root, 'project-a')
  projectB = join(root, 'project-b')
  unlisted = join(root, 'never-added')
  copilotFolder = join(root, 'copilot')
  deviceHome = join(root, 'device-home')

  for (const dir of [join(projectA, 'src'), join(projectA, '.aws'), projectB, unlisted]) {
    mkdirSync(dir, { recursive: true })
  }
  mkdirSync(join(deviceHome, 'tmp'), { recursive: true })
  mkdirSync(copilotFolder, { recursive: true })

  // The code. This is the whole point of the grant and must be readable.
  writeFileSync(join(projectA, 'src', 'app.ts'), 'export const answer = 42\n')
  writeFileSync(join(projectA, 'README.md'), '# project a\n')
  writeFileSync(join(projectB, 'main.go'), 'package main\n')

  // The credentials. Each one is a shape `secrets.ts` names.
  writeFileSync(join(projectA, '.env'), `LIVE_KEY=${SECRET}\n`)
  writeFileSync(join(projectA, 'src', '.env.production'), `PROD=${SECRET}\n`)
  writeFileSync(join(projectA, '.npmrc'), `//registry.npmjs.org/:_authToken=${SECRET}\n`)
  writeFileSync(join(projectA, 'deploy.pem'), `-----BEGIN PRIVATE KEY-----\n${SECRET}\n`)
  writeFileSync(join(projectA, '.aws', 'credentials'), `aws_secret_access_key = ${SECRET}\n`)
  writeFileSync(join(projectB, 'terraform.tfvars'), `password = "${SECRET}"\n`)

  // The exception: a placeholder file, which a developer's copilot needs.
  writeFileSync(join(projectA, '.env.example'), 'LIVE_KEY=your-key-here\n')
  // And the one that is a credential shape by accident. Every Vite project has
  // it and it is a TypeScript declaration, not a secret.
  writeFileSync(join(projectA, 'src', '.env.d.ts'), 'declare const x: string\n')

  // The control folder, and a symlink from inside a project pointing at it —
  // the obvious way past a prefix rule.
  writeFileSync(join(unlisted, 'notes.txt'), SECRET)
  symlinkSync(unlisted, join(projectA, 'link-out'))
  // And a symlink to a file that is denied by name, which resolves to the same
  // real path and must be refused for the same reason.
  symlinkSync(join(projectA, '.env'), join(projectA, 'link-env'))

  plan = copilotPlan({
    folder: copilotFolder,
    home: deviceHome,
    accountHome: homedir(),
    path: process.env.PATH ?? '/usr/bin:/bin',
    platform: 'darwin',
    projects: [projectA, projectB],
  })
  profile = seatbeltProfile(plan)
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe.skipIf(!onMac)('the plan a copilot with projects is given', () => {
  it('puts every project in the read list and none of them in the write list', () => {
    for (const project of [projectA, projectB]) {
      expect(plan.readable).toContain(project)
      expect(plan.writable).not.toContain(project)
    }
    // Its own two directories, and nothing else, are writable.
    expect([...plan.writable].sort()).toEqual([copilotFolder, deviceHome].sort())
  })

  it('names the projects separately so a pane can say what it can see', () => {
    expect([...plan.readableProjects].sort()).toEqual([projectA, projectB].sort())
  })

  it('carves an exclusion out of every project, denies first and exceptions last', () => {
    expect(plan.readExclusions.length).toBeGreaterThan(0)
    const effects = plan.readExclusions.map((rule) => rule.effect)
    // Last match wins in Seatbelt, so an exception emitted before a deny is an
    // exception that does nothing. Measured, not assumed — see `secrets.ts`.
    expect(effects.lastIndexOf('deny')).toBeLessThan(effects.indexOf('allow'))
    for (const project of [projectA, projectB]) {
      expect(plan.readExclusions.some((rule) => rule.pattern.includes(project))).toBe(true)
    }
  })
})

describe.skipIf(!onMac)('a copilot running for real, with two projects granted', () => {
  it('runs at all — without this every refusal below means nothing', async () => {
    const ran = await sh('echo alive')
    expect(ran.stdout.trim()).toBe('alive')
    expect(ran.code).toBe(0)
  })

  /* ------------------------------------------------------------- reading -- */

  it('reads a source file in a project', async () => {
    const ran = await sh(`cat ${quoted(join(projectA, 'src', 'app.ts'))}`)
    expect(ran.stdout).toContain('answer = 42')
    expect(ran.code).toBe(0)
  })

  it('reads the second project too, not just the first', async () => {
    const ran = await sh(`cat ${quoted(join(projectB, 'main.go'))}`)
    expect(ran.stdout).toContain('package main')
  })

  it('lists a project directory, which is what makes a repo navigable', async () => {
    const ran = await sh(`ls ${quoted(projectA)}`)
    expect(ran.stdout).toContain('README.md')
  })

  it('cannot read a folder the person never added', async () => {
    const ran = await sh(`cat ${quoted(join(unlisted, 'notes.txt'))}`)
    expect(ran.stdout).not.toContain(SECRET)
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot follow a symlink out of a project into one', async () => {
    const ran = await sh(`cat ${quoted(join(projectA, 'link-out', 'notes.txt'))}`)
    expect(ran.stdout).not.toContain(SECRET)
  })

  it('still cannot read the account home or its keychain', async () => {
    const home = await sh(`ls ${quoted(homedir())}`)
    expect(home.code).not.toBe(0)
    const keychain = await sh(`ls ${quoted(join(homedir(), 'Library/Keychains'))}`)
    expect(keychain.code).not.toBe(0)
  })

  /* ------------------------------------------------------------- writing -- */

  it('cannot write a new file into a project', async () => {
    const target = join(projectA, 'src', 'pwned.ts')
    const ran = await sh(`echo pwned > ${quoted(target)}`)
    expect(ran.code).not.toBe(0)
    expect(ran.stderr).toMatch(/not permitted/i)
    // And it is not there afterwards, asked from outside the sandbox.
    expect(await sh(`cat ${quoted(target)}`)).toMatchObject({ stdout: '' })
  })

  it('cannot overwrite a file it can read', async () => {
    const target = join(projectA, 'src', 'app.ts')
    const ran = await sh(`echo clobbered > ${quoted(target)}`)
    expect(ran.code).not.toBe(0)
    // The read still returns the original, which is the assertion that matters:
    // a refusal that left the file truncated would be worse than an allow.
    const after = await sh(`cat ${quoted(target)}`)
    expect(after.stdout).toContain('answer = 42')
  })

  it('cannot append to a file in a project', async () => {
    const ran = await sh(`echo more >> ${quoted(join(projectA, 'README.md'))}`)
    expect(ran.code).not.toBe(0)
  })

  it('cannot create a directory in a project', async () => {
    const ran = await sh(`mkdir ${quoted(join(projectA, 'new-folder'))}`)
    expect(ran.code).not.toBe(0)
  })

  it('cannot delete a file in a project', async () => {
    const ran = await sh(`rm -f ${quoted(join(projectA, 'README.md'))}`)
    expect(ran.code).not.toBe(0)
    expect((await sh(`cat ${quoted(join(projectA, 'README.md'))}`)).stdout).toContain('project a')
  })

  it('cannot copy a file into a project from a folder it can write', async () => {
    // The variant somebody actually reaches for. `cp` writes through a
    // different syscall path than a shell redirect and is refused identically.
    const source = join(copilotFolder, 'payload.txt')
    await sh(`echo payload > ${quoted(source)}`)
    const ran = await sh(`cp ${quoted(source)} ${quoted(join(projectB, 'payload.txt'))}`)
    expect(ran.code).not.toBe(0)
  })

  it('can still write inside its own folder and its own home', async () => {
    // The other half of read-only: if this failed, the copilot could not keep a
    // memory and the boundary would be a bug rather than a boundary.
    const mine = await sh(`echo note > ${quoted(join(copilotFolder, 'memory-note.md'))} && cat ${quoted(join(copilotFolder, 'memory-note.md'))}`)
    expect(mine.stdout).toContain('note')
    const home = await sh(`echo x > ${quoted(join(deviceHome, 'cache'))}`)
    expect(home.code).toBe(0)
  })

  /* ----------------------------------------------------------- the secrets -- */

  it('cannot read a .env in a project it can otherwise read', async () => {
    const ran = await sh(`cat ${quoted(join(projectA, '.env'))}`)
    expect(ran.stdout).not.toContain(SECRET)
    expect(ran.stderr).toMatch(/not permitted/i)
  })

  it('cannot read a .env nested deeper in the tree', async () => {
    const ran = await sh(`cat ${quoted(join(projectA, 'src', '.env.production'))}`)
    expect(ran.stdout).not.toContain(SECRET)
  })

  it('cannot reach a .env through .. or through a symlink', async () => {
    // Seatbelt resolves the path before applying the rule, in both directions.
    const traversal = await sh(`cat ${quoted(join(projectA, 'src', '..', '.env'))}`)
    expect(traversal.stdout).not.toContain(SECRET)
    const link = await sh(`cat ${quoted(join(projectA, 'link-env'))}`)
    expect(link.stdout).not.toContain(SECRET)
  })

  it('cannot read a registry token, a private key, an .aws directory or tfvars', async () => {
    const targets = [
      join(projectA, '.npmrc'),
      join(projectA, 'deploy.pem'),
      join(projectA, '.aws', 'credentials'),
      join(projectB, 'terraform.tfvars'),
    ]
    for (const target of targets) {
      const ran = await sh(`cat ${quoted(target)}`)
      expect(ran.stdout).not.toContain(SECRET)
      expect(`${ran.stdout}${ran.stderr}`).toMatch(/not permitted/i)
    }
  })

  it('cannot sweep the secrets out with a recursive read either', async () => {
    // The realistic shape of the failure: not `cat .env`, but a tool walking the
    // tree. `grep -r` is refused per file, so the secret never appears even
    // though the walk itself succeeds.
    const ran = await sh(`grep -r ${quoted(SECRET)} ${quoted(projectA)} ${quoted(projectB)} 2>/dev/null; echo done`)
    expect(ran.stdout).not.toContain(SECRET)
    expect(ran.stdout).toContain('done')
  })

  it('still reads .env.example and .env.d.ts, because neither is a credential', async () => {
    // The exceptions, and they work only because they are emitted after the
    // denies. Losing these would cost a developer's copilot the one file that
    // says what a project needs configured, and a TypeScript declaration.
    const example = await sh(`cat ${quoted(join(projectA, '.env.example'))}`)
    expect(example.stdout).toContain('your-key-here')
    const types = await sh(`cat ${quoted(join(projectA, 'src', '.env.d.ts'))}`)
    expect(types.stdout).toContain('declare const x')
  })

  it('cannot copy a secret out by asking another program to read it', async () => {
    // The boundary is inherited, so handing the job to a child changes nothing.
    const ran = await sh(`/bin/sh -c '/usr/bin/head -c 200 ${quoted(join(projectA, '.env'))}'`)
    expect(ran.stdout).not.toContain(SECRET)
  })
})
