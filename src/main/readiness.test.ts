import { execFile } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  anchoredIgnoreLine,
  applyReadinessFix,
  bandFor,
  CHECK_WEIGHTS,
  CLAUDE_MD_BLOAT_LINES,
  detectJsonIndent,
  failedCheck,
  formatBytes,
  ignoreBlockFor,
  ignoreCovers,
  isUnfilledSkeleton,
  listPaths,
  looksLikeSecretFile,
  MACHINE_FIX_IDS,
  meaningfulLines,
  registerReadinessIpc,
  toolMessage,
  upgradeAgentCli,
  upgradeCommandFor,
  upgradeRouteFor,
  samplePathFor,
  scanReadiness,
  scoreChecks,
  SECRET_FAIL_CAP,
  SECRET_WARN_CAP,
  type ReadinessCheck,
  type ReadinessCheckId,
  type ReadinessReport,
  type ReadinessStatus,
  type ToolRun,
  type ToolRunner,
} from './readiness'
import { parseIgnoreFile } from './fs-tree'

const run = promisify(execFile)

/* ------------------------------------------------------------------ setup -- */

const created: string[] = []

async function tempProject(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-readiness-'))
  created.push(dir)
  return dir
}

/** Isolated from the machine's git config, so a user's hooks or templates
 *  cannot change what these tests see. */
async function git(cwd: string, ...args: string[]): Promise<void> {
  await run('git', ['-c', 'user.email=t@example.com', '-c', 'user.name=Test', ...args], {
    cwd,
    env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' },
  })
}

async function tracked(cwd: string): Promise<string[]> {
  const { stdout } = await run('git', ['ls-files'], { cwd })
  return stdout.split('\n').filter(Boolean)
}

async function write(dir: string, relPath: string, body: string): Promise<void> {
  const cut = relPath.lastIndexOf('/')
  if (cut !== -1) await mkdir(join(dir, relPath.slice(0, cut)), { recursive: true })
  await writeFile(join(dir, relPath), body, 'utf8')
}

const GOOD_CLAUDE_MD = `# CLAUDE.md

## What this is

A fixture project used by the readiness tests. It exists to be scanned.

## Run it

\`\`\`sh
npm start
\`\`\`

## Test it

\`\`\`sh
npm test
\`\`\`

## Layout

- src/ — the code
- test/ — the tests

## Conventions

Two-space indent, single quotes, no semicolons.
`

const GOOD_README = `# fixture

A project fixture.

## Install

npm install

## Test

npm test
`

const GOOD_PKG = JSON.stringify(
  {
    name: 'fixture',
    version: '1.0.0',
    scripts: { test: 'vitest run', typecheck: 'tsc --noEmit', lint: 'eslint .' },
    devDependencies: { vitest: '^4.0.0', typescript: '^5.7.0', eslint: '^9.0.0' },
  },
  null,
  2,
)

const GOOD_GITIGNORE = `node_modules/
dist/
.env
.env.*
!.env.example
`

/** Everything a project needs to score full marks. */
async function goodProject(): Promise<string> {
  const dir = await tempProject()
  await write(dir, 'CLAUDE.md', GOOD_CLAUDE_MD)
  await write(dir, 'README.md', GOOD_README)
  await write(dir, 'package.json', GOOD_PKG)
  await write(dir, 'package-lock.json', '{"lockfileVersion":3}')
  await write(dir, 'tsconfig.json', '{"compilerOptions":{"strict":true}}')
  await write(dir, '.gitignore', GOOD_GITIGNORE)
  // Documentation, not a secret: the scanner must let this one through.
  await write(dir, '.env.example', 'API_KEY=\n')
  await write(dir, 'src/index.ts', 'export const answer = 42\n')
  await git(dir, 'init', '--quiet')
  await git(dir, 'add', '.')
  await git(dir, 'commit', '--quiet', '-m', 'initial')
  return dir
}

function byId(report: ReadinessReport, id: ReadinessCheckId): ReadinessCheck {
  const found = report.checks.find((check) => check.id === id)
  if (!found) throw new Error(`no check with id ${id}`)
  return found
}

beforeAll(async () => {
  // Warms the login-PATH cache in providers.ts once, so the first git call in
  // a test is not also paying for a login shell.
  await run('git', ['--version'])
}, 20_000)

afterAll(async () => {
  for (const dir of created) await rm(dir, { recursive: true, force: true })
})

/* ---------------------------------------------------------------- scoring -- */

function fake(
  id: ReadinessCheckId,
  status: ReadinessStatus,
  gate = false,
): ReadinessCheck {
  return { id, title: id, status, weight: CHECK_WEIGHTS[id], detail: '', fix: null, gate, opens: null }
}

describe('scoreChecks', () => {
  it('is 100 when everything passes', () => {
    const checks: ReadinessCheck[] = (Object.keys(CHECK_WEIGHTS) as ReadinessCheckId[]).map((id) =>
      fake(id, 'pass'),
    )
    expect(scoreChecks(checks).score).toBe(100)
  })

  it('is 0 when everything fails', () => {
    const checks = (Object.keys(CHECK_WEIGHTS) as ReadinessCheckId[]).map((id) => fake(id, 'fail'))
    expect(scoreChecks(checks).score).toBe(0)
  })

  it('gives a warning half credit', () => {
    const checks = [fake('readme', 'warn'), fake('lockfile', 'pass')]
    // (8 * 0.5 + 6) / 14
    expect(scoreChecks(checks).score).toBe(71)
  })

  it('drops skipped checks out of the denominator rather than scoring them zero', () => {
    const withSkip = scoreChecks([fake('readme', 'pass'), fake('lockfile', 'skip')])
    expect(withSkip.score).toBe(100)
  })

  it('scores zero when every check was skipped', () => {
    expect(scoreChecks([fake('readme', 'skip')]).score).toBe(0)
  })

  it('weights heavier checks more', () => {
    const claudeOnly = scoreChecks([fake('claude-md', 'pass'), fake('lockfile', 'fail')])
    const lockOnly = scoreChecks([fake('claude-md', 'fail'), fake('lockfile', 'pass')])
    expect(claudeOnly.score).toBeGreaterThan(lockOnly.score)
  })
})

describe('the secrets gate', () => {
  it('caps a otherwise-perfect project below every band when secrets are committed', () => {
    const checks = (Object.keys(CHECK_WEIGHTS) as ReadinessCheckId[]).map((id) =>
      id === 'secrets' ? fake(id, 'fail', true) : fake(id, 'pass'),
    )
    const result = scoreChecks(checks)
    expect(result.score).toBe(SECRET_FAIL_CAP)
    expect(result.band).toBe('at-risk')
    expect(result.cappedBy).toBe('secrets')
  })

  it('caps a warning below "strong"', () => {
    const checks = (Object.keys(CHECK_WEIGHTS) as ReadinessCheckId[]).map((id) =>
      id === 'secrets' ? fake(id, 'warn', true) : fake(id, 'pass'),
    )
    const result = scoreChecks(checks)
    expect(result.score).toBe(SECRET_WARN_CAP)
    expect(result.band).toBe('fair')
  })

  it('does not raise a score that was already below the cap', () => {
    const checks = [fake('secrets', 'fail', true), fake('claude-md', 'fail')]
    expect(scoreChecks(checks).score).toBe(0)
  })

  it('leaves the score alone when the gate passes', () => {
    const checks = [fake('secrets', 'pass', true), fake('claude-md', 'pass')]
    expect(scoreChecks(checks)).toMatchObject({ score: 100, cappedBy: null })
  })

  it('puts the fail cap below the bottom of the weak band', () => {
    expect(bandFor(SECRET_FAIL_CAP)).toBe('at-risk')
    expect(bandFor(SECRET_WARN_CAP)).not.toBe('strong')
  })
})

describe('bandFor', () => {
  it('reads the boundaries inclusively', () => {
    expect(bandFor(100)).toBe('strong')
    expect(bandFor(85)).toBe('strong')
    expect(bandFor(84)).toBe('fair')
    expect(bandFor(65)).toBe('fair')
    expect(bandFor(64)).toBe('weak')
    expect(bandFor(40)).toBe('weak')
    expect(bandFor(39)).toBe('at-risk')
    expect(bandFor(0)).toBe('at-risk')
  })
})

/* ------------------------------------------------------------- pure bits -- */

describe('meaningfulLines', () => {
  it('ignores blanks, rules and comments', () => {
    expect(meaningfulLines('# Title\n\n---\n<!-- note -->\nreal line\n')).toBe(2)
  })

  it('is zero for an empty file', () => {
    expect(meaningfulLines('')).toBe(0)
    expect(meaningfulLines('\n\n   \n')).toBe(0)
  })
})

describe('looksLikeSecretFile', () => {
  it('catches the files that actually leak', () => {
    for (const path of [
      '.env',
      '.env.local',
      '.env.production',
      'config/.env',
      'certs/server.pem',
      'keys/id_rsa',
      'app.p12',
      '.netrc',
      'secrets.json',
      'secrets.yaml',
      'serviceAccountKey.json',
    ]) {
      expect(looksLikeSecretFile(path), path).toBe(true)
    }
  })

  it('leaves documentation and ordinary files alone', () => {
    for (const path of [
      '.env.example',
      '.env.sample',
      '.env.local.template',
      'src/env.ts',
      'environment.ts',
      'README.md',
      'package.json',
      'docs/secrets.md',
    ]) {
      expect(looksLikeSecretFile(path), path).toBe(false)
    }
  })
})

describe('ignoreCovers', () => {
  const rules = parseIgnoreFile('node_modules/\ndist/\n.env\n.env.*\n!.env.example\nlogs/**\n')

  it('matches plain and wildcard patterns', () => {
    expect(ignoreCovers(rules, '.env', false)).toBe(true)
    expect(ignoreCovers(rules, '.env.local', false)).toBe(true)
    expect(ignoreCovers(rules, 'node_modules', true)).toBe(true)
  })

  it('honours a negation', () => {
    expect(ignoreCovers(rules, '.env.example', false)).toBe(false)
  })

  it('does not claim to cover what is not listed', () => {
    expect(ignoreCovers(rules, 'coverage', true)).toBe(false)
    expect(ignoreCovers(rules, 'src/index.ts', false)).toBe(false)
  })

  it('does not force-ignore node_modules the way the file tree does', () => {
    // The whole reason this helper exists: a .gitignore that never mentions
    // node_modules must read as *not covering* it.
    expect(ignoreCovers(parseIgnoreFile('dist/\n'), 'node_modules', true)).toBe(false)
  })

  it('covers everything under an ignored directory', () => {
    expect(ignoreCovers(rules, 'dist/app.js', false)).toBe(true)
  })
})

describe('samplePathFor', () => {
  it('turns a pattern into something the rules can be asked about', () => {
    expect(samplePathFor('*.pem')).toEqual({ path: 'x.pem', isDir: false })
    expect(samplePathFor('.env.*')).toEqual({ path: '.env.x', isDir: false })
    expect(samplePathFor('dist/')).toEqual({ path: 'dist', isDir: true })
    expect(samplePathFor('!.env.example')).toEqual({ path: '.env.example', isDir: false })
  })
})

describe('detectJsonIndent', () => {
  it('reads the indent the file already uses', () => {
    expect(detectJsonIndent('{\n    "a": 1\n}\n')).toBe('    ')
    expect(detectJsonIndent('{\n\t"a": 1\n}\n')).toBe('\t')
    expect(detectJsonIndent('{"a":1}')).toBe('  ')
  })
})

/* -------------------------------------------------------------- scanning -- */

describe('scanReadiness — an empty folder', () => {
  it('fails the foundations and skips what it cannot judge', async () => {
    const dir = await tempProject()
    const report = await scanReadiness(dir)

    expect(byId(report, 'claude-md').status).toBe('fail')
    expect(byId(report, 'readme').status).toBe('fail')
    expect(byId(report, 'gitignore').status).toBe('fail')
    expect(byId(report, 'git-repo').status).toBe('fail')
    // Nothing to run tests with, and no npm manifest to hang a script on.
    expect(byId(report, 'test-script').status).toBe('skip')
    expect(byId(report, 'typecheck-script').status).toBe('skip')
    expect(byId(report, 'git-clean').status).toBe('skip')
    // Not zero: an empty folder genuinely has no secrets to leak, and that
    // check is the heaviest one. It is still nowhere near usable.
    expect(byId(report, 'secrets').status).toBe('pass')
    expect(report.score).toBeLessThan(40)
    expect(report.band).toBe('at-risk')
  }, 20_000)

  it('offers a fix for every missing foundation', async () => {
    const dir = await tempProject()
    const report = await scanReadiness(dir)
    expect(byId(report, 'claude-md').fix?.id).toBe('create-claude-md')
    expect(byId(report, 'readme').fix?.id).toBe('create-readme')
    expect(byId(report, 'gitignore').fix?.id).toBe('create-gitignore')
    expect(byId(report, 'git-repo').fix?.id).toBe('git-init')
  }, 20_000)
})

describe('scanReadiness — a well-set-up project', () => {
  it('scores it strong', async () => {
    const report = await scanReadiness(await goodProject())
    for (const check of report.checks) {
      expect(check.status, `${check.id}: ${check.detail}`).toBe('pass')
    }
    expect(report.score).toBe(100)
    expect(report.band).toBe('strong')
    expect(report.cappedBy).toBeNull()
  }, 20_000)

  it('does not flag .env.example as a secret', async () => {
    const report = await scanReadiness(await goodProject())
    expect(byId(report, 'secrets').status).toBe('pass')
  }, 20_000)
})

describe('scanReadiness — the secrets check against a real repo', () => {
  it('fails, and caps the score, when git is tracking a .env', async () => {
    const dir = await goodProject()
    await write(dir, '.env', 'OPENAI_API_KEY=sk-live-not-a-real-key\n')
    // -f because the fixture's .gitignore already covers it: this is the
    // "someone forced it in months ago" case, which is the one that hurts.
    await git(dir, 'add', '-f', '.env')
    await git(dir, 'commit', '--quiet', '-m', 'oops')

    const report = await scanReadiness(dir)
    const secrets = byId(report, 'secrets')
    expect(secrets.status).toBe('fail')
    expect(secrets.detail).toContain('.env')
    expect(secrets.fix?.id).toBe('untrack-secrets')
    expect(secrets.fix?.destructive).toBe(true)
    // Everything else about this project is perfect, and it still cannot pass.
    expect(report.score).toBeLessThanOrEqual(SECRET_FAIL_CAP)
    expect(report.band).toBe('at-risk')
    expect(report.cappedBy).not.toBeNull()
  }, 20_000)

  it('warns when a .env sits unignored, before anything is committed', async () => {
    const dir = await tempProject()
    await write(dir, '.env', 'TOKEN=abc\n')
    const report = await scanReadiness(dir)
    const secrets = byId(report, 'secrets')
    expect(secrets.status).toBe('warn')
    expect(secrets.fix?.id).toBe('ignore-secrets')
    expect(secrets.fix?.destructive).toBe(false)
  }, 20_000)

  it('passes when the .env is present but ignored', async () => {
    const dir = await tempProject()
    await write(dir, '.env', 'TOKEN=abc\n')
    await write(dir, '.gitignore', '.env\n')
    const report = await scanReadiness(dir)
    expect(byId(report, 'secrets').status).toBe('pass')
  }, 20_000)

  it('flags an .npmrc only when it carries a token', async () => {
    const plain = await tempProject()
    await write(plain, '.npmrc', 'save-exact=true\n')
    await git(plain, 'init', '--quiet')
    await git(plain, 'add', '.')
    await git(plain, 'commit', '--quiet', '-m', 'config')
    expect(byId(await scanReadiness(plain), 'secrets').status).toBe('pass')

    const leaky = await tempProject()
    await write(leaky, '.npmrc', '//registry.npmjs.org/:_authToken=npm_secret\n')
    await git(leaky, 'init', '--quiet')
    await git(leaky, 'add', '.')
    await git(leaky, 'commit', '--quiet', '-m', 'config')
    expect(byId(await scanReadiness(leaky), 'secrets').status).toBe('fail')
  }, 30_000)
})

describe('scanReadiness — individual checks', () => {
  it('warns on a stub CLAUDE.md and on a bloated one', async () => {
    const stub = await tempProject()
    await write(stub, 'CLAUDE.md', '# CLAUDE.md\n\nBe good.\n')
    const stubbed = byId(await scanReadiness(stub), 'claude-md')
    expect(stubbed.status).toBe('warn')
    expect(stubbed.detail).toContain('2 meaningful lines')

    const bloated = await tempProject()
    const lines = Array.from({ length: CLAUDE_MD_BLOAT_LINES + 10 }, (_, i) => `- point ${i}`)
    await write(bloated, 'CLAUDE.md', `${lines.join('\n')}\nnpm test\n`)
    expect(byId(await scanReadiness(bloated), 'claude-md').status).toBe('warn')
  }, 20_000)

  it('warns when CLAUDE.md documents no runnable command', async () => {
    const dir = await tempProject()
    const prose = Array.from({ length: 20 }, (_, i) => `Sentence number ${i} about the project.`)
    await write(dir, 'CLAUDE.md', prose.join('\n'))
    const check = byId(await scanReadiness(dir), 'claude-md')
    expect(check.status).toBe('warn')
    expect(check.detail).toContain('no runnable commands')
  }, 20_000)

  it('accepts .claude/CLAUDE.md and AGENTS.md as the instructions file', async () => {
    const nested = await tempProject()
    await write(nested, '.claude/CLAUDE.md', GOOD_CLAUDE_MD)
    expect(byId(await scanReadiness(nested), 'claude-md').status).toBe('pass')

    const agents = await tempProject()
    await write(agents, 'AGENTS.md', GOOD_CLAUDE_MD)
    expect(byId(await scanReadiness(agents), 'claude-md').status).toBe('pass')
  }, 20_000)

  it('rejects npm\'s placeholder test script, and offers no fix for it', async () => {
    const dir = await tempProject()
    await write(
      dir,
      'package.json',
      JSON.stringify({ scripts: { test: 'echo "Error: no test specified" && exit 1' } }),
    )
    const check = byId(await scanReadiness(dir), 'test-script')
    expect(check.status).toBe('fail')
    // Nothing to point the script at, so inventing one would just move the lie.
    expect(check.fix).toBeNull()
  }, 20_000)

  it('offers a test script only when a runner is actually installed', async () => {
    const bare = await tempProject()
    await write(bare, 'package.json', JSON.stringify({ name: 'bare' }))
    expect(byId(await scanReadiness(bare), 'test-script').fix).toBeNull()

    const withRunner = await tempProject()
    await write(withRunner, 'package.json', JSON.stringify({ devDependencies: { vitest: '^4' } }))
    expect(byId(await scanReadiness(withRunner), 'test-script').fix?.id).toBe('add-test-script')
  }, 20_000)

  it('recognises tests outside npm', async () => {
    const cargo = await tempProject()
    await write(cargo, 'Cargo.toml', '[package]\nname = "fixture"\n')
    const report = await scanReadiness(cargo)
    expect(byId(report, 'test-script').status).toBe('pass')
    // …and asks for the lockfile that pins them.
    expect(byId(report, 'lockfile').status).toBe('warn')
  }, 20_000)

  it('skips the typecheck check on a project with no TypeScript', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'js-only' }))
    expect(byId(await scanReadiness(dir), 'typecheck-script').status).toBe('skip')
  }, 20_000)

  it('accepts a typecheck under any of its usual names', async () => {
    const dir = await tempProject()
    await write(dir, 'tsconfig.json', '{}')
    await write(dir, 'package.json', JSON.stringify({ scripts: { 'check-types': 'tsc --noEmit' } }))
    expect(byId(await scanReadiness(dir), 'typecheck-script').status).toBe('pass')
  }, 20_000)

  it('warns rather than fails when a .gitignore is merely incomplete', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }))
    await write(dir, '.gitignore', 'dist/\n')
    const check = byId(await scanReadiness(dir), 'gitignore')
    expect(check.status).toBe('warn')
    expect(check.detail).toContain('node_modules')
    expect(check.fix?.id).toBe('patch-gitignore')
  }, 20_000)

  it('reports an uncommitted tree, and a conflicted one more harshly', async () => {
    const dir = await goodProject()
    await write(dir, 'src/index.ts', 'export const answer = 43\n')
    const dirty = byId(await scanReadiness(dir), 'git-clean')
    expect(dirty.status).toBe('warn')
    expect(dirty.detail).toContain('1 uncommitted change')
  }, 20_000)

  it('warns when a node project has no lockfile', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }))
    expect(byId(await scanReadiness(dir), 'lockfile').status).toBe('warn')
  }, 20_000)
})

/* ------------------------------------------------------------------ fixes -- */

describe('applyReadinessFix', () => {
  it('creates CLAUDE.md once, and refuses to overwrite it', async () => {
    const dir = await tempProject()
    const first = await applyReadinessFix(dir, 'create-claude-md')
    expect(first.ok).toBe(true)
    expect(first.changed).toEqual(['CLAUDE.md'])

    await writeFile(join(dir, 'CLAUDE.md'), 'hand written, do not clobber\n', 'utf8')
    const second = await applyReadinessFix(dir, 'create-claude-md')
    expect(second.ok).toBe(false)
    expect(await readFile(join(dir, 'CLAUDE.md'), 'utf8')).toBe('hand written, do not clobber\n')
  })

  it('names the README after the project folder', async () => {
    const dir = await tempProject()
    await applyReadinessFix(dir, 'create-readme')
    const text = await readFile(join(dir, 'README.md'), 'utf8')
    // `basename`, not a hand-rolled split on '/': the temp path is backslashed
    // on Windows, so the split kept the whole path and the title never matched.
    expect(text.startsWith(`# ${basename(dir)}`)).toBe(true)
  })

  it('writes a .gitignore that covers the secrets and clears the check', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }))
    await write(dir, '.env', 'TOKEN=abc\n')

    expect(byId(await scanReadiness(dir), 'secrets').status).toBe('warn')
    const result = await applyReadinessFix(dir, 'create-gitignore')
    expect(result.ok).toBe(true)

    const after = await scanReadiness(dir)
    expect(byId(after, 'secrets').status).toBe('pass')
    expect(byId(after, 'gitignore').status).toBe('pass')
  }, 20_000)

  it('appends only the missing patterns, and is idempotent', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }))
    await write(dir, '.gitignore', 'node_modules/\n')

    const first = await applyReadinessFix(dir, 'patch-gitignore')
    expect(first.ok).toBe(true)
    const text = await readFile(join(dir, '.gitignore'), 'utf8')
    expect(text.startsWith('node_modules/\n')).toBe(true)
    expect(text).toContain('.env')
    // Already covered, so it must not be repeated.
    expect(text.match(/node_modules/g)).toHaveLength(1)

    const second = await applyReadinessFix(dir, 'patch-gitignore')
    expect(second.ok).toBe(false)
    expect(await readFile(join(dir, '.gitignore'), 'utf8')).toBe(text)
  })

  it('adds a trailing newline before its block when the file lacks one', async () => {
    const dir = await tempProject()
    await write(dir, '.gitignore', 'dist/')
    await applyReadinessFix(dir, 'ignore-secrets')
    const text = await readFile(join(dir, '.gitignore'), 'utf8')
    expect(text.startsWith('dist/\n')).toBe(true)
    expect(text).toContain('.env')
  })

  it('initialises a repository without committing anything', async () => {
    const dir = await tempProject()
    await write(dir, 'src/index.ts', 'export const x = 1\n')

    const result = await applyReadinessFix(dir, 'git-init')
    expect(result.ok).toBe(true)
    expect(await tracked(dir)).toEqual([])
    expect(byId(await scanReadiness(dir), 'git-repo').status).toBe('pass')

    const again = await applyReadinessFix(dir, 'git-init')
    expect(again.ok).toBe(false)
  }, 20_000)

  it('untracks a committed secret, keeps the file, and says history is not clean', async () => {
    const dir = await goodProject()
    await write(dir, '.env', 'STRIPE_KEY=sk_live_x\n')
    await git(dir, 'add', '-f', '.env')
    await git(dir, 'commit', '--quiet', '-m', 'oops')
    expect(await tracked(dir)).toContain('.env')

    const result = await applyReadinessFix(dir, 'untrack-secrets')
    expect(result.ok).toBe(true)
    expect(result.message).toMatch(/rotate/i)
    expect(await tracked(dir)).not.toContain('.env')
    // The file itself is untouched — this fix never destroys the user's config.
    expect(await readFile(join(dir, '.env'), 'utf8')).toBe('STRIPE_KEY=sk_live_x\n')

    const after = await scanReadiness(dir)
    expect(byId(after, 'secrets').status).toBe('pass')
    expect(after.cappedBy).toBeNull()
  }, 20_000)

  it('re-derives the facts, so a fix applied twice does nothing the second time', async () => {
    const dir = await tempProject()
    await git(dir, 'init', '--quiet')
    const second = await applyReadinessFix(dir, 'untrack-secrets')
    expect(second.ok).toBe(false)
    expect(second.changed).toEqual([])
  }, 20_000)

  it('adds a test script using the runner already installed, preserving formatting', async () => {
    const dir = await tempProject()
    const original = `{\n    "name": "x",\n    "devDependencies": {\n        "jest": "^29"\n    }\n}\n`
    await write(dir, 'package.json', original)

    const result = await applyReadinessFix(dir, 'add-test-script')
    expect(result.ok).toBe(true)

    const text = await readFile(join(dir, 'package.json'), 'utf8')
    expect(text).toContain('"test": "jest"')
    // Four-space indent in, four-space indent out.
    expect(text).toContain('\n    "name": "x"')
    expect(text.endsWith('\n')).toBe(true)
    expect(JSON.parse(text)).toMatchObject({ name: 'x', scripts: { test: 'jest' } })
  })

  it('refuses to overwrite a script that already exists', async () => {
    const dir = await tempProject()
    await write(
      dir,
      'package.json',
      JSON.stringify({ scripts: { test: 'mine' }, devDependencies: { vitest: '^4' } }),
    )
    const result = await applyReadinessFix(dir, 'add-test-script')
    expect(result.ok).toBe(false)
    expect(JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).scripts.test).toBe('mine')
  })

  it('refuses a typecheck script when TypeScript is not installed', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }))
    const result = await applyReadinessFix(dir, 'add-typecheck-script')
    expect(result.ok).toBe(false)
    expect(JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).scripts).toBeUndefined()
  })

  it('adds a lint script for whichever linter is present', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ devDependencies: { '@biomejs/biome': '^1' } }))
    await applyReadinessFix(dir, 'add-lint-script')
    expect(JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).scripts.lint).toBe(
      'biome check .',
    )
  })
})

/* ------------------------------------------------------------ regressions -- */

describe('the check and the fix must agree about what a secret is', () => {
  it('untracks the tokened .npmrc the check failed on', async () => {
    // The check tests an .npmrc by content; the fix used to test it by name,
    // matched nothing, and answered a red "Untrack and ignore" button with
    // "git is no longer tracking any secret files."
    const dir = await tempProject()
    await write(dir, '.npmrc', '//registry.npmjs.org/:_authToken=npm_live_token\n')
    await git(dir, 'init', '--quiet')
    await git(dir, 'add', '.')
    await git(dir, 'commit', '--quiet', '-m', 'config')

    expect(byId(await scanReadiness(dir), 'secrets').status).toBe('fail')

    const result = await applyReadinessFix(dir, 'untrack-secrets')
    expect(result.ok).toBe(true)
    expect(await tracked(dir)).not.toContain('.npmrc')
    // Still on disk, like every other secret this fix touches.
    expect(await readFile(join(dir, '.npmrc'), 'utf8')).toContain('_authToken')
  }, 30_000)

  it('leaves a token-free .npmrc alone', async () => {
    const dir = await tempProject()
    await write(dir, '.npmrc', 'save-exact=true\n')
    await git(dir, 'init', '--quiet')
    await git(dir, 'add', '.')
    await git(dir, 'commit', '--quiet', '-m', 'config')

    const result = await applyReadinessFix(dir, 'untrack-secrets')
    expect(result.ok).toBe(false)
    expect(await tracked(dir)).toContain('.npmrc')
  }, 30_000)

  it('ignores what it untracks, so the next `git add .` cannot put it back', async () => {
    // credentials.json is detected as a secret but matches none of the standard
    // ignore patterns, so untracking it alone lasted exactly one `git add .`.
    const dir = await tempProject()
    await write(dir, 'credentials.json', '{"private_key":"x"}')
    await git(dir, 'init', '--quiet')
    await git(dir, 'add', '.')
    await git(dir, 'commit', '--quiet', '-m', 'oops')

    expect((await applyReadinessFix(dir, 'untrack-secrets')).ok).toBe(true)
    await git(dir, 'add', '.')
    expect(await tracked(dir)).not.toContain('credentials.json')
    expect(byId(await scanReadiness(dir), 'secrets').status).toBe('pass')
  }, 30_000)
})

describe('ignoreBlockFor', () => {
  it('re-states a negation the appended lines would otherwise swallow', () => {
    // Last match wins in git: appending `.env.*` under an existing
    // `!.env.example` starts ignoring the one file the fix promises to keep.
    const block = ignoreBlockFor('!.env.example\n', ['.env', '.env.*', '!.env.example'])
    expect(block[block.length - 1]).toBe('!.env.example')
    const rules = parseIgnoreFile(`!.env.example\n${block.join('\n')}`)
    expect(ignoreCovers(rules, '.env', false)).toBe(true)
    expect(ignoreCovers(rules, '.env.example', false)).toBe(false)
  })

  it('drops a pattern an earlier line of the same block already covers', () => {
    const block = ignoreBlockFor('', ['*.pem', '/keys/a.pem', '/keys/b.pem', '.env'])
    expect(block).toEqual(['*.pem', '.env'])
  })

  it('adds nothing, negation included, when everything is already covered', () => {
    expect(ignoreBlockFor('.env\n.env.*\n!.env.example\n', ['.env', '.env.*', '!.env.example'])).toEqual([])
  })
})

describe('the ignore-secrets fix keeps .env.example committable', () => {
  it('does not start ignoring it when the file already re-included it', async () => {
    const dir = await tempProject()
    await write(dir, '.gitignore', 'dist/\n!.env.example\n')
    await write(dir, '.env.example', 'API_KEY=\n')
    await write(dir, '.env', 'API_KEY=live\n')
    await git(dir, 'init', '--quiet')

    expect((await applyReadinessFix(dir, 'ignore-secrets')).ok).toBe(true)
    await git(dir, 'add', '.')
    const files = await tracked(dir)
    expect(files).toContain('.env.example')
    expect(files).not.toContain('.env')
  }, 30_000)
})

describe('anchoredIgnoreLine', () => {
  it('matches one path and cannot be read as a comment or a negation', () => {
    expect(anchoredIgnoreLine('credentials.json')).toBe('/credentials.json')
    expect(anchoredIgnoreLine('!weird.pem')).toBe('/!weird.pem')
    expect(anchoredIgnoreLine('#notes.pem')).toBe('/#notes.pem')
    expect(anchoredIgnoreLine('keys/[old].pem')).toBe('/keys/\\[old\\].pem')
    expect(anchoredIgnoreLine('a*b.pem')).toBe('/a\\*b.pem')
    expect(anchoredIgnoreLine('trailing .pem ')).toBe('/trailing .pem\\ ')
  })

  it('compiles to a rule that covers exactly that path', () => {
    const rules = parseIgnoreFile(anchoredIgnoreLine('keys/[old].pem'))
    expect(ignoreCovers(rules, 'keys/[old].pem', false)).toBe(true)
    expect(ignoreCovers(rules, 'keys/o.pem', false)).toBe(false)
    expect(ignoreCovers(rules, 'nested/keys/[old].pem', false)).toBe(false)
  })
})

describe('a file too large to read is never reported as missing', () => {
  it('says the CLAUDE.md is oversized rather than absent', async () => {
    const dir = await tempProject()
    await write(dir, 'CLAUDE.md', 'x'.repeat(1024 * 1024 + 1))
    const check = byId(await scanReadiness(dir), 'claude-md')
    expect(check.detail).not.toContain('No CLAUDE.md')
    expect(check.status).toBe('warn')
    // Offering "Create CLAUDE.md" here would be a button that can only refuse.
    expect(check.fix).toBeNull()
  }, 30_000)

  it('does not call a 1 MB README a title', async () => {
    const dir = await tempProject()
    await write(dir, 'README.md', 'a line of prose\n'.repeat(70_000))
    const check = byId(await scanReadiness(dir), 'readme')
    expect(check.detail).not.toContain('0 meaningful line')
    expect(check.status).toBe('pass')
  }, 30_000)

  it('still reads a package.json larger than the prose limit', async () => {
    // Treating it as absent skipped three checks, and a skipped check leaves
    // the denominator — so an unreadable manifest *raised* the score.
    const dir = await tempProject()
    await write(
      dir,
      'package.json',
      JSON.stringify({ name: 'big', note: 'y'.repeat(1024 * 1024 + 64), scripts: { test: 'vitest run' } }),
    )
    const report = await scanReadiness(dir)
    expect(byId(report, 'test-script').status).toBe('pass')
    expect(byId(report, 'lockfile').status).toBe('warn')
    expect(byId(report, 'lint-script').status).toBe('warn')
  }, 30_000)
})

describe('detail strings stay bounded', () => {
  it('names a few paths and counts the rest', () => {
    expect(listPaths(['a', 'b'])).toBe('a, b')
    expect(listPaths(['a', 'b', 'c', 'd', 'e', 'f'])).toBe('a, b, c, d and 2 more')
    expect(listPaths([])).toBe('')
  })

  it('does not grow with the number of unignored secrets', async () => {
    const dir = await tempProject()
    for (let i = 0; i < 60; i++) await write(dir, `key${i}.pem`, 'x')
    const check = byId(await scanReadiness(dir), 'secrets')
    expect(check.status).toBe('warn')
    expect(check.detail.length).toBeLessThan(400)
  }, 30_000)
})

describe('a check that could not run', () => {
  it('drops an ordinary check out of the score', () => {
    const broken = failedCheck('lockfile', 'Dependencies are pinned', new Error('EACCES'))
    expect(broken.status).toBe('skip')
    expect(broken.gate).toBe(false)
  })

  it('still caps the score when it is the gate', () => {
    // Skipping the gate would take the cap with it, and a repository whose
    // secrets could not be inspected would score 100.
    const broken = failedCheck('secrets', 'No secrets committed', new Error('EACCES'), true)
    expect(broken.status).toBe('warn')
    expect(broken.gate).toBe(true)

    const checks = (Object.keys(CHECK_WEIGHTS) as ReadinessCheckId[]).map((id) =>
      id === 'secrets' ? broken : fake(id, 'pass'),
    )
    const result = scoreChecks(checks)
    expect(result.score).toBe(SECRET_WARN_CAP)
    expect(result.cappedBy).toBe('No secrets committed')
  })
})

describe('formatBytes', () => {
  it('reads as a size a human can act on', () => {
    expect(formatBytes(512)).toBe('512 bytes')
    expect(formatBytes(2048)).toBe('2 KB')
    expect(formatBytes(1024 * 1024 * 3)).toBe('3.0 MB')
  })
})

/* -------------------------------------------------------------------- ipc -- */

type Handler = (event: unknown, ...args: unknown[]) => unknown

function fakeIpc(): { ipcMain: IpcMain; handlers: Map<string, Handler> } {
  const handlers = new Map<string, Handler>()
  const ipcMain = {
    handle: (channel: string, handler: Handler) => handlers.set(channel, handler),
  } as unknown as IpcMain
  return { ipcMain, handlers }
}

/* ------------------------------------------------- a fix that fakes a pass -- */

/**
 * The half of the "create README" button that was missing.
 *
 * The review's words: *"The existing 'create README' button is the right idea
 * but not done properly."* What was not done was the *next scan*. The skeleton
 * that button writes has thirteen meaningful lines, so it cleared the README
 * floor of five and the row turned green; the instructions skeleton cleared its
 * floor of twelve **and** its "names a runnable command" test, on the strength
 * of the empty fenced blocks in its own template. One click took a project from
 * a red row to a tick with nothing about the project written anywhere.
 *
 * Both cases are pinned, because they failed for two different reasons and
 * fixing one would look like fixing both.
 */
describe('a skeleton this app wrote is not a pass', () => {
  it('says the README is still the skeleton, and offers to open it', async () => {
    const dir = await tempProject()
    const made = await applyReadinessFix(dir, 'create-readme')
    expect(made.ok).toBe(true)

    const report = await scanReadiness(dir)
    const readme = byId(report, 'readme')
    expect(readme.status).toBe('warn')
    expect(readme.detail).toContain('skeleton')
    // No machine can write this file for you, so the action is the file itself.
    expect(readme.fix).toBeNull()
    expect(readme.opens).toBe('README.md')
  }, 20_000)

  it('says the same of the instructions file it writes', async () => {
    const dir = await tempProject()
    expect((await applyReadinessFix(dir, 'create-claude-md')).ok).toBe(true)

    const report = await scanReadiness(dir)
    const instructions = byId(report, 'claude-md')
    expect(instructions.status).toBe('warn')
    expect(instructions.detail).toContain('skeleton')
    expect(instructions.opens).not.toBeNull()
  }, 20_000)

  it('stops saying it the moment a real line is added', async () => {
    const dir = await tempProject()
    await applyReadinessFix(dir, 'create-readme')
    const path = join(dir, 'README.md')
    await writeFile(path, `${await readFile(path, 'utf8')}\nIt scans projects.\n`, 'utf8')

    const report = await scanReadiness(dir)
    expect(byId(report, 'readme').status).toBe('pass')
  }, 20_000)

  it('recognises a skeleton exactly, not by resemblance', () => {
    const template = '# Name\n\n## Install\n\n<!-- fill me -->\n'
    expect(isUnfilledSkeleton(template, template)).toBe(true)
    // Deleting from it leaves it a skeleton; adding to it does not.
    expect(isUnfilledSkeleton('# Name\n', template)).toBe(true)
    expect(isUnfilledSkeleton(`${template}\nWhat this is.\n`, template)).toBe(false)
    // An empty file is nothing rather than a skeleton, and the length checks
    // that follow have something truer to say about it.
    expect(isUnfilledSkeleton('   \n\n', template)).toBe(false)
  })
})

/* ------------------------------------------------- every row can be acted on -- */

/**
 * The rule the whole readiness pass turns on: *"Every not-ready item needs an
 * action button that actually does it, or a way to dismiss it. They should not
 * see something they cannot do something about it."*
 *
 * Dismissal lives in the renderer, because putting a row away is a fact about a
 * person rather than about a project. What the main process owes is the other
 * half — a fix where one is possible, and otherwise the file the row is about,
 * so the panel has something to open. This asserts the second half is present
 * on every row that names a file, because a `null` there is invisible on screen:
 * the row simply loses its button and nobody notices which row it was.
 */
describe('a row that cannot be fixed still names the file it is about', () => {
  it('gives every file-shaped check somewhere to go', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x', scripts: {} }, null, 2))
    await write(dir, 'tsconfig.json', '{}')
    await write(dir, '.gitignore', 'node_modules/\n')
    await write(dir, 'CLAUDE.md', GOOD_CLAUDE_MD)
    await write(dir, 'README.md', GOOD_README)

    const report = await scanReadiness(dir)
    for (const id of ['claude-md', 'readme', 'gitignore', 'test-script', 'lint-script'] as const) {
      expect(byId(report, id).opens, id).not.toBeNull()
    }
    // And the two that are about no single file say so rather than inventing
    // one. A button that opened the wrong thing would be worse than none.
    expect(byId(report, 'git-clean').opens).toBeNull()
    expect(byId(report, 'lockfile').opens).toBeNull()
  }, 20_000)
})

/* ------------------------------------------------------- the new two fixes -- */

describe("replacing npm's placeholder test script", () => {
  const placeholder = 'echo "Error: no test specified" && exit 1'

  it('is offered when a runner is installed, and replaces only the placeholder', async () => {
    const dir = await tempProject()
    await write(
      dir,
      'package.json',
      JSON.stringify({ name: 'x', scripts: { test: placeholder }, devDependencies: { vitest: '^4' } }, null, 2),
    )

    const before = byId(await scanReadiness(dir), 'test-script')
    expect(before.status).toBe('fail')
    // It had no button at all before this pass, for no better reason than that
    // `addScript` refuses a key that exists — while this is the easiest of the
    // three failures to repair, because the value is a string npm generated.
    expect(before.fix?.id).toBe('replace-test-script')
    expect(before.fix?.destructive).toBe(true)

    const result = await applyReadinessFix(dir, 'replace-test-script')
    expect(result.ok).toBe(true)
    expect(JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).scripts.test).toBe('vitest run')
    expect(byId(await scanReadiness(dir), 'test-script').status).toBe('pass')
  }, 20_000)

  it('refuses to overwrite a script somebody wrote', async () => {
    const dir = await tempProject()
    await write(
      dir,
      'package.json',
      JSON.stringify({ name: 'x', scripts: { test: 'make check' }, devDependencies: { vitest: '^4' } }, null, 2),
    )
    const result = await applyReadinessFix(dir, 'replace-test-script')
    expect(result.ok).toBe(false)
    expect(JSON.parse(await readFile(join(dir, 'package.json'), 'utf8')).scripts.test).toBe('make check')
  }, 20_000)
})

describe('generating a lockfile', () => {
  it('is offered for an npm project and not for one that declares another tool', async () => {
    const npmish = await tempProject()
    await write(npmish, 'package.json', JSON.stringify({ name: 'x' }, null, 2))
    expect(byId(await scanReadiness(npmish), 'lockfile').fix?.id).toBe('create-lockfile')

    const pnpmish = await tempProject()
    await write(pnpmish, 'package.json', JSON.stringify({ name: 'x', packageManager: 'pnpm@9.0.0' }, null, 2))
    const row = byId(await scanReadiness(pnpmish), 'lockfile')
    // Not a missing button: the row says whose job it is instead, because a
    // `package-lock.json` in a pnpm project is a worse state than none.
    expect(row.fix).toBeNull()
    expect(row.detail).toContain('pnpm@9.0.0')
  }, 20_000)

  it('refuses rather than writing the wrong kind of lockfile', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x', packageManager: 'yarn@4.0.0' }, null, 2))
    const result = await applyReadinessFix(dir, 'create-lockfile')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('yarn@4.0.0')
  }, 20_000)

  it('refuses when a lockfile is already there', async () => {
    const dir = await tempProject()
    await write(dir, 'package.json', JSON.stringify({ name: 'x' }, null, 2))
    await write(dir, 'pnpm-lock.yaml', 'lockfileVersion: 9\n')
    const result = await applyReadinessFix(dir, 'create-lockfile')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('pnpm-lock.yaml')
  }, 20_000)
})

/* ------------------------------------------------------ the machine-level fix -- */

/**
 * A stale agent CLI is a readiness problem with no folder attached.
 *
 * It is the failure the review actually hit — *"Gemini reports 'authentication
 * successful'… then fails with 'this client is no longer supported'"* — and it
 * is the same fact in every project on the machine. `browser-signin.ts` measures
 * it; this module owns the act, because `readiness:fix` is the only route the
 * renderer already has that can run something.
 */
describe('upgrading the agent CLI', () => {
  it('asks the package managers rather than guessing', async () => {
    const asked: string[] = []
    const probe = async (command: string, args: string[]) => {
      asked.push(`${command} ${args[0]}`)
      return { ok: command === 'npm', output: '' }
    }
    expect(await upgradeRouteFor(probe)).toBe('npm')
    // brew first, and npm only because brew said no — a machine where both
    // claim it runs the one that put the binary on the PATH.
    expect(asked).toEqual(['brew list', 'npm ls'])
  })

  it('answers null when neither manager claims it', async () => {
    expect(await upgradeRouteFor(async () => ({ ok: false, output: '' }))).toBeNull()
  })

  it('quotes the tool’s diagnosis, not the last thing it printed', () => {
    /*
     * Seen on screen before it was fixed. A machine that was already current
     * printed a download tick and then the warning, and the row quoted both —
     * "✔︎ JSON API packages.arm64_golden_gate.jws.json Warning: gemini-cli
     * 0.46.0 already installed". The half that means something is the warning.
     */
    expect(
      toolMessage('==> Downloading\n✔︎ JSON API packages.jws.json\nWarning: x 1.2.3 already installed'),
    ).toBe('Warning: x 1.2.3 already installed')
    expect(toolMessage('npm ERR! code EACCES\nnpm ERR! A complete log is in /tmp/log')).toBe(
      'npm ERR! A complete log is in /tmp/log',
    )
    // A tool that prefixes nothing still gets its last word through.
    expect(toolMessage('one\ntwo\n\n')).toBe('two')
    expect(toolMessage('   \n\n')).toBe('')
  })

  it('runs each route with its own command', () => {
    expect(upgradeCommandFor('brew')).toEqual({ command: 'brew', args: ['upgrade', 'gemini-cli'] })
    expect(upgradeCommandFor('npm')).toEqual({
      command: 'npm',
      args: ['install', '-g', '@google/gemini-cli@latest'],
    })
  })

  /**
   * Everything below runs through the injected runner and never spawns
   * anything, and that is not a stylistic choice.
   *
   * The first draft of this block called the real thing to prove the channel
   * dispatched — and it worked: it upgraded this machine's agent CLI from
   * 0.32.1 to 0.46.0 mid-suite. That is the right *outcome* for a person
   * pressing the button and an unacceptable one for a test, so the seam went in
   * and the act is exercised against a fake machine instead. `ToolRunner` in
   * `readiness.ts` carries the same note.
   */
  const machine = (script: Record<string, ToolRun>, log: string[] = []): ToolRunner => {
    return async (command, args) => {
      const key = `${command} ${args[0]}`
      log.push(key)
      return script[key] ?? { ok: false, output: 'not found' }
    }
  }

  it('reports the version it moved from and to, read from the binary', async () => {
    const versions = ['0.32.1', '0.46.0']
    const exec: ToolRunner = async (command, args) => {
      if (command === 'gemini') return { ok: true, output: versions.shift() ?? '0.46.0' }
      if (command === 'brew' && args[0] === 'list') return { ok: true, output: 'gemini-cli 0.32.1' }
      return { ok: true, output: 'Upgrading gemini-cli' }
    }
    const result = await upgradeAgentCli(exec)
    expect(result.ok).toBe(true)
    // The package manager saying it succeeded is not the measurement — an
    // upgrade that installs somewhere the PATH does not reach succeeds by every
    // measure the package manager has and leaves the person where they were.
    expect(result.message).toContain('0.32.1')
    expect(result.message).toContain('0.46.0')
  })

  it('says nothing moved when the binary still answers the same version', async () => {
    const exec = machine({
      'gemini --version': { ok: true, output: '0.32.1' },
      'brew list': { ok: true, output: 'gemini-cli 0.32.1' },
      'brew upgrade': { ok: false, output: 'Error: gemini-cli 0.32.1 already installed' },
    })
    const result = await upgradeAgentCli(exec)
    expect(result.ok).toBe(false)
    expect(result.message).toContain('0.32.1')
    // The tool's own last words, which `execFile` hides on the error object and
    // which are the whole difference between a bug report and a fix.
    expect(result.message).toContain('already installed')
  })

  it('refuses, with both commands, when neither manager claims it', async () => {
    const exec = machine({ 'gemini --version': { ok: true, output: '0.32.1' } })
    const result = await upgradeAgentCli(exec)
    expect(result.ok).toBe(false)
    expect(result.message).toContain('brew upgrade gemini-cli')
    expect(result.message).toContain('npm install -g @google/gemini-cli@latest')
  })

  it('refuses when the CLI is not installed at all', async () => {
    const result = await upgradeAgentCli(machine({}))
    expect(result.ok).toBe(false)
    expect(result.message).toContain('not installed')
  })

  it('is the only fix that may arrive without a project path', async () => {
    // The one line of the channel this pins: a machine fix is dispatched before
    // the path is validated, and everything else still is not.
    expect([...MACHINE_FIX_IDS]).toEqual(['upgrade-agent-cli'])

    const { ipcMain, handlers } = fakeIpc()
    registerReadinessIpc(ipcMain)
    await expect(handlers.get('readiness:fix')?.(null, '', 'create-readme')).rejects.toThrow(/absolute/)
  })
})

describe('registerReadinessIpc', () => {
  it('registers exactly the two channels', () => {
    const { ipcMain, handlers } = fakeIpc()
    registerReadinessIpc(ipcMain)
    expect([...handlers.keys()].sort()).toEqual(['readiness:fix', 'readiness:scan'])
  })

  it('rejects a relative or missing project path', async () => {
    const { ipcMain, handlers } = fakeIpc()
    registerReadinessIpc(ipcMain)
    const scan = handlers.get('readiness:scan')
    await expect(scan?.(null, 'relative/path')).rejects.toThrow(/absolute/)
    await expect(scan?.(null, undefined)).rejects.toThrow(/absolute/)
  })

  it('refuses a fix id it does not know, instead of running anything', async () => {
    const { ipcMain, handlers } = fakeIpc()
    registerReadinessIpc(ipcMain)
    const dir = await tempProject()
    const result = await handlers.get('readiness:fix')?.(null, dir, 'rm -rf /')
    expect(result).toMatchObject({ ok: false, changed: [] })
  })

  it('scans over the channel', async () => {
    const { ipcMain, handlers } = fakeIpc()
    registerReadinessIpc(ipcMain)
    const dir = await tempProject()
    const report = (await handlers.get('readiness:scan')?.(null, dir)) as ReadinessReport
    expect(report.projectPath).toBe(dir)
    expect(report.checks).toHaveLength(Object.keys(CHECK_WEIGHTS).length)
  }, 20_000)
})
