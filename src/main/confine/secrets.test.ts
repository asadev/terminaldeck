/**
 * The credential exclusions, checked as strings and then checked for real.
 *
 * The second half is the important one and it exists because of a bug this
 * exact file was written after. Two of the shapes — `*.pem` and `*.tfvars` —
 * were written as `\.(pem|…)$`, which anchors directly after the `/` that
 * `secretExclusions` puts in front of every fragment, and therefore matched
 * only a file *literally named* `.pem`. They emitted, they parsed, and they
 * denied nothing. Every string assertion about them passed.
 *
 * So the real test below is driven off {@link SECRET_SHAPES} itself: each shape
 * must have an example file, the examples are written into a real folder, and a
 * real `sandbox-exec` is asked to read each one. A shape added without an
 * example fails the coverage test, and a shape whose pattern does not actually
 * bite fails its own case. Neither can be satisfied by writing a plausible
 * regex.
 */

import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { sessionPlan, type PathResolver } from './plan'
import { SANDBOX_EXEC, seatbeltProfile } from './seatbelt'
import { pathAsRegex, SECRET_EXCEPTIONS, SECRET_SHAPES, secretExclusions } from './secrets'

const onMac = process.platform === 'darwin'

/* --------------------------------------------------------------- as strings -- */

describe('pathAsRegex', () => {
  it('escapes the metacharacters a real folder name contains', () => {
    // `~/Projects/app (v2)` is an ordinary folder and every one of those
    // characters means something to a regex engine.
    expect(pathAsRegex('/Users/a/app (v2)+x')).toBe(String.raw`/Users/a/app \(v2\)\+x`)
  })

  it('escapes a dot so a prefix cannot match a sibling', () => {
    expect(pathAsRegex('/a/b.c')).toBe(String.raw`/a/b\.c`)
  })

  it('turns a double quote into the any-character wildcard', () => {
    // Measured: `\"` ends the Seatbelt string literal early and breaks the whole
    // profile; `\x22` is not understood and the rule silently matches nothing.
    // A wildcard over-matches a *deny* by one character, which is the only one
    // of the three that fails in the safe direction.
    expect(pathAsRegex('/a/q"uote')).toBe('/a/q.uote')
  })
})

describe('secretExclusions', () => {
  const rules = secretExclusions(['/p/one', '/p/two'])

  it('emits every deny before any exception, because the last match wins', () => {
    const effects = rules.map((rule) => rule.effect)
    expect(effects.lastIndexOf('deny')).toBeLessThan(effects.indexOf('allow'))
  })

  it('anchors each rule to one project rather than to the filesystem', () => {
    for (const rule of rules) expect(rule.pattern.startsWith('^/p/')).toBe(true)
  })

  it('covers every root with every shape', () => {
    const denies = rules.filter((rule) => rule.effect === 'deny')
    expect(denies).toHaveLength(SECRET_SHAPES.length * 2)
  })

  it('is empty when nothing was granted', () => {
    expect(secretExclusions([])).toEqual([])
  })
})

/* ------------------------------------------------------------- for real -- */

/**
 * One file per shape, and the coverage test below makes this exhaustive.
 *
 * Paths are relative to the granted project. Each is a name a developer would
 * actually have; the point is not to construct something that matches the regex
 * but to write down what the rule is *for* and find out whether it bites.
 */
const EXAMPLES: Record<string, string> = {
  dotenv: '.env.local',
  direnv: '.envrc',
  'registry-auth': '.npmrc',
  'network-auth': '.netrc',
  'stored-credentials': '.git-credentials',
  'ssh-private-key': 'deploy/id_ed25519',
  'private-key-file': 'certs/server.pem',
  'terraform-state': 'infra/terraform.tfvars',
  'cloud-config-dir': '.aws/credentials',
  'secrets-file': 'config/secrets.yaml',
  'service-account': 'service-account-prod.json',
}

/**
 * Files that look close enough to be worth proving are *not* caught.
 *
 * A denylist that quietly eats ordinary source is a denylist somebody switches
 * off, so the cost of each rule is pinned as tightly as its benefit.
 */
const NEAR_MISSES: readonly string[] = [
  '.env.example',
  'src/.env.d.ts',
  'docs/monkey.pem.md',
  'src/environment.ts',
  'src/keyboard.ts',
  'README.md',
]

let root = ''
let project = ''
let copilotFolder = ''
let deviceHome = ''
let profile = ''

const realResolver: PathResolver = {
  real: (path) => {
    try {
      return realpathSync(path)
    } catch {
      return path
    }
  },
  isDirectory: () => true,
}

function read(path: string): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    execFile(
      SANDBOX_EXEC,
      ['-p', profile, '/bin/cat', path],
      { cwd: copilotFolder, timeout: 20_000, encoding: 'utf8' },
      (error, stdout, stderr) => {
        resolve({ code: error ? 1 : 0, stdout, stderr })
      },
    )
  })
}

const SECRET = 'canary-2b7e10f4ac93-do-not-leak'

beforeAll(() => {
  if (!onMac) return
  root = realpathSync(mkdtempSync(join(tmpdir(), 'secret-shapes-')))
  project = join(root, 'project')
  copilotFolder = join(root, 'copilot')
  deviceHome = join(root, 'home')
  mkdirSync(copilotFolder, { recursive: true })
  mkdirSync(deviceHome, { recursive: true })

  for (const relative of [...Object.values(EXAMPLES), ...NEAR_MISSES]) {
    const file = join(project, relative)
    mkdirSync(dirname(file), { recursive: true })
    writeFileSync(file, `${SECRET}\n`)
  }

  profile = seatbeltProfile(
    sessionPlan({
      folder: copilotFolder,
      home: deviceHome,
      accountHome: homedir(),
      path: process.env.PATH ?? '/usr/bin:/bin',
      projects: [project],
      resolver: realResolver,
      platform: 'darwin',
    }),
  )
})

afterAll(() => {
  if (root !== '') rmSync(root, { recursive: true, force: true })
})

describe.skipIf(!onMac)('every named shape, against a real sandbox', () => {
  it('has an example for every shape in the list', () => {
    // The coverage gate. A shape added without one cannot be proven to work, and
    // an unproven deny is the failure mode this whole file exists for.
    expect(Object.keys(EXAMPLES).sort()).toEqual(SECRET_SHAPES.map((s) => s.name).sort())
  })

  it.each(SECRET_SHAPES.map((shape) => [shape.name, EXAMPLES[shape.name] ?? '']))(
    'refuses %s (%s)',
    async (_name, relative) => {
      const ran = await read(join(project, relative))
      expect(ran.stdout).not.toContain(SECRET)
      expect(`${ran.stdout}${ran.stderr}`).toMatch(/not permitted/i)
    },
  )

  it.each(NEAR_MISSES)('still reads %s', async (relative) => {
    const ran = await read(join(project, relative))
    expect(ran.stdout).toContain(SECRET)
  })

  it('names an exception for each thing the near-misses rely on', () => {
    // `.env.example` and `.env.d.ts` are readable only because an allow rule
    // re-opens them after the dotenv deny. If somebody deletes the exceptions,
    // the near-miss cases above fail — this makes the link explicit so the
    // reason survives.
    expect(SECRET_EXCEPTIONS.map((shape) => shape.name)).toContain('dotenv-template')
    expect(SECRET_EXCEPTIONS.map((shape) => shape.name)).toContain('dotenv-types')
  })
})
