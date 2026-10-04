import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { locateEngine } from './engine'
import { StaysFixedService } from './service'

/**
 * The owner's whole loop, end to end, on a real project with the real engine.
 *
 * Set up → check (nothing to compare yet) → mark good → break something → check
 * and see **only** that difference → marking good is refused for it → mark good
 * anyway → check again, clean. Every step goes through `StaysFixedService`, the
 * object the page, the tools and the session launcher all share, and through
 * the real `staysfixed` in `node_modules` — no fake engine, no canned JSON.
 *
 * The project is a two-file command-line greeter in a fresh git repository: the
 * smallest thing that has a printed output a regression can change. Its total
 * line is the regression on purpose — "Total" is money to the engine, so the
 * difference also comes back as one only a person may wave through.
 *
 * The test's own Node stands in for this app's executable, as in
 * `engine.test.ts`; that is what `ELECTRON_RUN_AS_NODE` makes the app.
 */

const posix = process.platform !== 'win32'
let dir = ''
let project = ''
let service: StaysFixedService
const changed: string[] = []

function git(...args: string[]): void {
  execFileSync('git', ['-c', 'user.name=test', '-c', 'user.email=test@example.com', ...args], { cwd: project, stdio: 'ignore' })
}

beforeAll(() => {
  if (!posix) return
  dir = mkdtempSync(join(tmpdir(), 'td-staysfixed-loop-'))
  project = join(dir, 'tiny-greeter')
  execFileSync('mkdir', ['-p', project])
  writeFileSync(
    join(project, 'package.json'),
    JSON.stringify({ name: 'tiny-greeter', version: '1.0.0', private: true, type: 'module', bin: { greet: './greet.js' } }, null, 2),
  )
  writeFileSync(
    join(project, 'greet.js'),
    "#!/usr/bin/env node\nconst name = process.argv[2] ?? 'world'\nconsole.log(`Hello, ${name}!`)\nconsole.log('Total: ' + (10).toFixed(2))\n",
  )
  execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: project })
  git('add', '-A')
  git('commit', '-qm', 'first')
  service = new StaysFixedService({
    userData: join(dir, 'userData'),
    locate: () => locateEngine({ resourcesPath: null, appPath: process.cwd() }),
    executable: process.execPath,
    loginPath: async () => process.env.PATH ?? '/usr/bin:/bin',
    changed: (path) => changed.push(path),
    home: dir,
  })
})

afterAll(() => {
  if (!posix) return
  service.dispose()
  rmSync(dir, { recursive: true, force: true })
})

describe.skipIf(!posix)('the whole loop, on a real project', () => {
  it('starts not set up, with the engine present', async () => {
    const status = await service.status(project)
    expect(status.available).toBe(true)
    expect(status.setUp).toBe(false)
    expect(status.agents).toBe(false)
    expect(status.git).toBe(true)
  })

  it('sets up, writing the settings file, and turns the agents’ switch on', async () => {
    const outcome = await service.setup(project)
    expect(outcome.ok).toBe(true)
    expect(outcome.wrote).toContain('staysfixed.config.js')
    git('add', '-A')
    git('commit', '-qm', 'set up stays fixed')
    const status = await service.status(project)
    expect(status.setUp).toBe(true)
    expect(status.agents).toBe(true)
    expect(status.configFile).toBe('staysfixed.config.js')
  }, 120_000)

  it('runs a first check that honestly compares nothing, and reports its steps while it runs', async () => {
    const before = changed.length
    const results = await service.check(project, 'you')
    expect(results.verdict).toBe('not-compared')
    // A start, at least one engine step, and the finish.
    expect(changed.length - before).toBeGreaterThanOrEqual(3)
    expect(service.progress(project)).toBeNull()
  }, 120_000)

  it('marks that build as good', async () => {
    const outcome = await service.markGood(project, false)
    expect(outcome.marked).toBe(true)
    const status = await service.status(project)
    // The engine's own name for the build: its version, plus "with uncommitted
    // changes" when the check's records left the working tree dirty.
    expect(status.reference?.name).toMatch(/^1\.0\.0/)
  }, 60_000)

  it('sees only the regression somebody introduced, with both values', async () => {
    writeFileSync(join(project, 'greet.js'), readFileSync(join(project, 'greet.js'), 'utf8').replace('toFixed(2)', 'toFixed(1)'))
    const results = await service.check(project, 'Hoot')
    expect(results.verdict).toBe('differences')
    expect(results.differences).toHaveLength(1)
    const [difference] = results.differences
    expect(difference?.changes).toHaveLength(1)
    expect(difference?.changes[0]?.before).toContain('Total: 10.00')
    expect(difference?.changes[0]?.after).toContain('Total: 10.0\n')
    expect(difference?.needsPerson).toBe(true)
    expect(results.unchanged).toMatch(/Everything else it looked at — \d+ things — is unchanged\./)
    // And the page reads the same answer back off the engine's own record.
    expect(service.results(project)?.verdict).toBe('differences')
  }, 120_000)

  it('refuses to mark that build good without being told the differences are wanted', async () => {
    const refused = await service.markGood(project, false)
    expect(refused.marked).toBe(false)
    expect(refused.refusedFor).toBe('differences')
    const anyway = await service.markGood(project, true)
    expect(anyway.marked).toBe(true)
  }, 60_000)

  it('checks clean against the build just marked good', async () => {
    const results = await service.check(project, 'you')
    expect(results.verdict).toBe('clean')
    expect(results.differences).toEqual([])
  }, 120_000)

  it('gives an agent session started anywhere in the project the server, until the switch is turned off', async () => {
    const launch = await service.agentLaunch('claude', join(project))
    expect(launch?.args[0]).toBe('--mcp-config')
    await service.setAgents(project, false)
    expect(await service.agentLaunch('claude', project)).toBeNull()
    await service.setAgents(project, true)
    expect(await service.agentLaunch('codex', project)).not.toBeNull()
  })

  it('joins a check already running instead of starting a second', async () => {
    const first = service.check(project, 'you')
    const second = service.check(project, 'an AI app')
    expect(second).toBe(first)
    await first
  }, 120_000)
})
