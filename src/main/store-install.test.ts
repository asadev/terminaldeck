import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { readInstallBlock, type ManifestAgent, type StoreKind, type StoreTier } from '../shared/store-manifest'
import { tarGz, type TarEntry } from './store-archive.fixture'
import type { StoreIndex, StoreRow } from './store-index'
import {
  agentHome,
  agentHomes,
  createStoreInstaller,
  itemFolderName,
  itemsDir,
  ledgerPath,
  mcpAddArgs,
  mcpRemoveArgs,
  plannedTargets,
  readLedger,
  setRoutineFolder,
  stripBlock,
  type InstallChoice,
  type StoreInstaller,
} from './store-install'

/**
 * What an install writes, and what a Remove takes back.
 *
 * Every test here runs against a temporary `userData` and a temporary home, so
 * nothing touches the copies of Claude Code, Codex or the Gemini CLI on the
 * machine running it — the rule this repository already follows for the browser
 * profiles and the agent config directories. Nothing here spawns a real command
 * line tool either: the two writers that would are injected, and what they were
 * asked to run is asserted as argv, which is the only part of it that can be
 * wrong in a way a person would not see.
 */

const COMMIT = 'a'.repeat(40)

let userData = ''
let home = ''

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'td-store-data-'))
  home = mkdtempSync(join(tmpdir(), 'td-store-home-'))
})

afterEach(() => {
  rmSync(userData, { recursive: true, force: true })
  rmSync(home, { recursive: true, force: true })
})

/* ------------------------------------------------------------- the fixtures -- */

interface ItemOptions {
  kind: StoreKind
  install: Record<string, unknown>
  extra?: readonly TarEntry[]
  agents?: readonly ManifestAgent[]
  version?: string
  /** What the *row* claims, when the point of the test is that it disagrees. */
  rowVersion?: string
  rowKind?: StoreKind
  rowTier?: StoreTier
  rowInstall?: Record<string, unknown>
}

function manifestFor(options: ItemOptions): string {
  return JSON.stringify({
    terminaldeck: 1,
    publisher: 'pub',
    id: 'thing',
    kind: options.kind,
    name: 'A Thing',
    summary: 'One honest line about the thing.',
    version: options.version ?? '1.0.0',
    licence: 'MIT',
    category: 'utility',
    tags: ['thing'],
    agents: options.agents ?? ['claude', 'codex', 'gemini'],
    platforms: ['darwin', 'win32', 'linux'],
    delivery: 'repo',
    pricing: { model: 'free', note: null, url: null },
    licenceEnv: null,
    links: { repo: 'https://github.com/pub/thing', home: null, docs: null },
    needs: [],
    install: options.install,
  })
}

/** An archive and the catalogue row that pins it, agreeing unless told not to. */
function makeItem(options: ItemOptions): { archive: Buffer; row: StoreRow } {
  const manifest = manifestFor(options)
  const entries: TarEntry[] = [
    { name: 'thing-abc/terminaldeck.json', body: manifest },
    ...(options.extra ?? []).map((entry) => ({ ...entry, name: `thing-abc/${entry.name}` })),
  ]
  const archive = tarGz(entries)
  const agents = options.agents ?? (['claude', 'codex', 'gemini'] as const)
  const rowKind = options.rowKind ?? options.kind
  const parsedInstall = readInstallBlock(rowKind, options.rowInstall ?? options.install, agents)
  if (!parsedInstall.ok) throw new Error(`fixture install block is not valid: ${parsedInstall.why}`)

  const row: StoreRow = {
    id: 'pub/thing',
    publisher: 'pub',
    listedBy: 'pub',
    kind: rowKind,
    name: 'A Thing',
    summary: 'One honest line about the thing.',
    version: options.rowVersion ?? options.version ?? '1.0.0',
    licence: 'MIT',
    category: 'utility',
    tags: ['thing'],
    agents: [...agents],
    platforms: ['darwin', 'win32', 'linux'],
    tier: options.rowTier ?? 1,
    needs: [],
    cost: 'free',
    costNote: null,
    delivery: 'repo',
    source: { repo: 'https://github.com/pub/thing', commit: COMMIT, path: '.', host: 'github.com' },
    artifact: {
      url: 'https://codeload.github.com/pub/thing/tar.gz/a',
      sha256: createHash('sha256').update(archive).digest('hex'),
      bytes: archive.byteLength,
      files: 2,
      unpacked: 1024,
    },
    install: parsedInstall.install,
    network: [],
    publishedAt: '2026-08-01T00:00:00.000Z',
    updatedAt: '2026-08-01T00:00:00.000Z',
  }
  return { archive, row }
}

interface Harness {
  store: StoreInstaller
  /** Every argv handed to an agent's own command line tool, in order. */
  ran: Array<{ agent: ManifestAgent; argv: string[] }>
  claude: Array<{ verb: 'add' | 'remove'; request: Record<string, unknown> }>
}

function harness(
  row: StoreRow,
  archive: Buffer,
  options: { revoked?: StoreIndex['revoked']; agentFails?: ManifestAgent; served?: Buffer } = {},
): Harness {
  const index: StoreIndex = {
    v: 1,
    serial: 1,
    issuedAt: '2026-08-20T00:00:00.000Z',
    expiresAt: null,
    generator: 'test',
    truncated: false,
    items: [row],
    revoked: options.revoked ?? [],
  }
  const ran: Harness['ran'] = []
  const claude: Harness['claude'] = []

  const store = createStoreInstaller({
    userData: () => userData,
    base: () => 'http://127.0.0.1:8933',
    env: {},
    home: () => home,
    now: () => new Date('2026-08-29T00:00:00.000Z'),
    fetchArtifact: async () => ({ ok: true, bytes: options.served ?? archive, message: '' }),
    runAgent: async (agent, argv) => {
      ran.push({ agent, argv: [...argv] })
      return options.agentFails === agent ? { ok: false, message: `${agent} said no` } : { ok: true, message: '' }
    },
    claudeMcp: {
      add: async (raw) => {
        claude.push({ verb: 'add', request: raw as Record<string, unknown> })
        return options.agentFails === 'claude' ? { ok: false, message: 'claude said no' } : { ok: true, message: '' }
      },
      remove: async (raw) => {
        claude.push({ verb: 'remove', request: raw as Record<string, unknown> })
        return { ok: true, message: '' }
      },
    },
    loadIndex: async () => ({
      ok: true,
      index,
      from: 'store',
      at: '2026-08-29T00:00:00.000Z',
      stale: null,
      because: null,
    }),
  })
  return { store, ran, claude }
}

const SKILL = `---
name: a-thing
description: A thing.
---

Do the thing.
`

function skillItem(extra: readonly TarEntry[] = [], options: Partial<ItemOptions> = {}): ReturnType<typeof makeItem> {
  return makeItem({
    kind: 'skill',
    install: { dir: 'skill' },
    extra: [{ name: 'skill/SKILL.md', body: SKILL }, ...extra],
    ...options,
  })
}

/* ------------------------------------------------------------------ tests -- */

describe('where each agent keeps its configuration', () => {
  it('reads the two variables that name a directory as directories', () => {
    expect(agentHome('claude', { CLAUDE_CONFIG_DIR: '/x/claude' }, '/home')).toBe('/x/claude')
    expect(agentHome('codex', { CODEX_HOME: '/x/codex' }, '/home')).toBe('/x/codex')
  })

  it('reads the one that names a parent as a parent, because that is what it is', () => {
    // Measured: `GEMINI_CLI_HOME=<dir> gemini skills install …` writes to
    // `<dir>/.gemini/skills`, not to `<dir>/skills`.
    expect(agentHome('gemini', { GEMINI_CLI_HOME: '/x/g' }, '/home')).toBe('/x/g/.gemini')
    expect(agentHome('gemini', {}, '/home')).toBe('/home/.gemini')
  })

  it('falls back to the documented defaults', () => {
    expect(agentHomes({}, '/home')).toEqual({
      claude: '/home/.claude',
      codex: '/home/.codex',
      gemini: '/home/.gemini',
    })
  })
})

describe('installing a skill', () => {
  it('writes the folder for the two agents that read one', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)

    const result = await store.install('pub/thing', { agents: ['claude', 'gemini'] })
    expect(result.ok, result.message).toBe(true)

    for (const dir of ['.claude', '.gemini']) {
      const skill = join(home, dir, 'skills', 'pub.thing', 'SKILL.md')
      expect(existsSync(skill), skill).toBe(true)
      expect(readFileSync(skill, 'utf8')).toBe(SKILL)
    }
  })

  it('names the folder in the standing instructions of the agent with no skills folder', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['codex'] })

    const agentsFile = readFileSync(join(home, '.codex', 'AGENTS.md'), 'utf8')
    expect(agentsFile).toContain('terminaldeck-store pub.thing')
    expect(agentsFile).toContain(join(home, '.codex', 'skills', 'pub.thing', 'SKILL.md'))
  })

  it('keeps a copy of its own, and records every path it wrote', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude'] })

    const [record] = readLedger(userData)
    expect(record.id).toBe('pub/thing')
    expect(record.root).toBe(join(itemsDir(userData), 'pub.thing'))
    expect(record.writes.map((write) => write.path)).toContain(
      join(home, '.claude', 'skills', 'pub.thing', 'SKILL.md'),
    )
    expect(existsSync(join(record.root, 'skill', 'SKILL.md'))).toBe(true)
  })

  it('refuses a skill with no SKILL.md rather than writing an empty folder', async () => {
    const { archive, row } = makeItem({
      kind: 'skill',
      install: { dir: 'skill' },
      extra: [{ name: 'skill/notes.md', body: 'nothing useful' }],
    })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('SKILL.md')
    expect(existsSync(join(home, '.claude', 'skills', 'pub.thing'))).toBe(false)
  })

  it('refuses to write over a folder somebody already has there', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    const target = join(home, '.claude', 'skills', 'pub.thing')
    mkdirSync(target, { recursive: true })
    writeFileSync(join(target, 'SKILL.md'), 'mine, not yours')

    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(readFileSync(join(target, 'SKILL.md'), 'utf8')).toBe('mine, not yours')
  })
})

describe('taking it off again', () => {
  it('removes exactly what it wrote and nothing else', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude', 'gemini'] })

    const mine = join(home, '.claude', 'skills', 'mine-by-hand')
    mkdirSync(mine, { recursive: true })
    writeFileSync(join(mine, 'SKILL.md'), 'hand written')

    const removed = await store.remove('pub/thing')
    expect(removed.ok, removed.message).toBe(true)
    expect(existsSync(join(home, '.claude', 'skills', 'pub.thing'))).toBe(false)
    expect(existsSync(join(home, '.gemini', 'skills', 'pub.thing'))).toBe(false)
    expect(existsSync(join(itemsDir(userData), 'pub.thing'))).toBe(false)
    expect(readLedger(userData)).toEqual([])
    // The folder next door is untouched, and so is the skills folder itself.
    expect(readFileSync(join(mine, 'SKILL.md'), 'utf8')).toBe('hand written')
  })

  it('takes its own block out of a file it did not write, leaving the rest byte for byte', async () => {
    const before = '# My own notes\n\nSomething I wrote.\n'
    mkdirSync(join(home, '.codex'), { recursive: true })
    writeFileSync(join(home, '.codex', 'AGENTS.md'), before)

    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['codex'] })
    expect(readFileSync(join(home, '.codex', 'AGENTS.md'), 'utf8')).not.toBe(before)

    await store.remove('pub/thing')
    expect(readFileSync(join(home, '.codex', 'AGENTS.md'), 'utf8')).toBe(before)
  })

  it('says so when something could not be taken back, and keeps that one on the list', async () => {
    const { archive, row } = makeItem({
      kind: 'mcp',
      install: { runtime: 'node', package: 'thing-server', args: [], inputs: [], token: 'thing-server' },
      rowTier: 3,
    })
    const failing = harness(row, archive)
    await failing.store.install('pub/thing', { agents: ['codex'] })

    // A second store over the same directory, whose agent runner refuses.
    const stubborn = createStoreInstaller({
      userData: () => userData,
      base: () => 'http://127.0.0.1:8933',
      env: {},
      home: () => home,
      fetchArtifact: async () => ({ ok: true, bytes: archive, message: '' }),
      runAgent: async () => ({ ok: false, message: 'the tool is not installed' }),
      loadIndex: async () => ({
        ok: true,
        index: {
          v: 1,
          serial: 1,
          issuedAt: '2026-08-20T00:00:00.000Z',
          expiresAt: null,
          generator: 'test',
          truncated: false,
          items: [row],
          revoked: [],
        },
        from: 'store',
        at: '2026-08-29T00:00:00.000Z',
        stale: null,
        because: null,
      }),
    })
    const removed = await stubborn.remove('pub/thing')
    expect(removed.ok).toBe(false)
    expect(removed.message).toContain('not installed')
    expect(readLedger(userData)).toHaveLength(1)
  })
})

describe('what is refused before a byte is written', () => {
  it('refuses a download whose fingerprint does not match', async () => {
    const { archive, row } = skillItem()
    const other = tarGz([{ name: 'thing-abc/terminaldeck.json', body: '{}' }])
    const { store } = harness(row, archive, { served: other })

    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('does not match the fingerprint')
    expect(existsSync(join(itemsDir(userData), 'pub.thing'))).toBe(false)
  })

  it('refuses a download of the wrong length before it hashes anything', async () => {
    const { archive, row } = skillItem()
    const short = { ...row, artifact: { ...row.artifact!, bytes: row.artifact!.bytes + 10 } }
    const { store } = harness(short, archive)
    expect((await store.install('pub/thing', { agents: ['claude'] })).ok).toBe(false)
  })

  it('refuses an archive whose manifest is for another version than the row', async () => {
    const { archive, row } = skillItem([], { version: '1.0.0', rowVersion: '2.0.0' })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('2.0.0')
  })

  it('refuses an archive that reaches further than the row said', async () => {
    const { archive, row } = skillItem([{ name: 'skill/do.sh', body: '#!/bin/sh\necho hi\n' }], { rowTier: 1 })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('skill/do.sh')
    expect(existsSync(join(home, '.claude', 'skills', 'pub.thing'))).toBe(false)
  })

  it('installs happily when the row over-stated what it would do', async () => {
    const { archive, row } = skillItem([], { rowTier: 3 })
    const { store } = harness(row, archive)
    expect((await store.install('pub/thing', { agents: ['claude'] })).ok).toBe(true)
  })

  it('refuses an archive carrying a name that climbs out of its folder', async () => {
    const { row } = skillItem()
    const escaping = tarGz([{ name: '../../.claude/settings.json', body: '{}' }])
    const pinned = {
      ...row,
      artifact: {
        ...row.artifact!,
        sha256: createHash('sha256').update(escaping).digest('hex'),
        bytes: escaping.byteLength,
      },
    }
    const { store } = harness(pinned, escaping)
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('will not write')
  })

  it('refuses something the catalogue has withdrawn', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive, {
      revoked: [{ id: 'pub/thing', version: '*', reason: 'it was taking screenshots' }],
    })
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('screenshots')
  })

  it('refuses a kind this version does not install, by name', async () => {
    const { archive, row } = makeItem({
      kind: 'hooks',
      install: { script: 'hook.mjs', events: ['SessionStart'], runtime: 'node' },
      agents: ['claude'],
      extra: [{ name: 'hook.mjs', body: 'export default 1\n' }],
      rowTier: 3,
    })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', { agents: ['claude'] })
    expect(result.ok).toBe(false)
    expect(result.message).toContain('Hooks')
  })

  it('refuses a second install of something already here', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude'] })
    const again = await store.install('pub/thing', { agents: ['claude'] })
    expect(again.ok).toBe(false)
    expect(again.message).toContain('already installed')
  })

  it('leaves nothing behind when the second agent refuses', async () => {
    const { archive, row } = makeItem({
      kind: 'mcp',
      install: { runtime: 'node', package: 'thing-server', args: [], inputs: [], token: 'thing-server' },
      rowTier: 3,
    })
    const { store, claude, ran } = harness(row, archive, { agentFails: 'gemini' })
    const result = await store.install('pub/thing', { agents: ['claude', 'gemini'] })

    expect(result.ok).toBe(false)
    expect(readLedger(userData)).toEqual([])
    expect(existsSync(join(itemsDir(userData), 'pub.thing'))).toBe(false)
    // The one that succeeded was taken back out again.
    expect(claude.map((call) => call.verb)).toEqual(['add', 'remove'])
    expect(ran.map((call) => call.argv[1])).toEqual(['add'])
  })
})

describe('an MCP server, whose command this app writes', () => {
  const install = {
    runtime: 'node',
    package: '@pub/thing-server',
    args: ['--root', '${input:ROOT}'],
    inputs: [
      { key: 'ROOT', label: 'Folder', hint: 'Which folder to read', kind: 'path', into: 'arg', required: true },
      { key: 'THING_KEY', label: 'API key', hint: 'From the dashboard', kind: 'secret', into: 'env', required: false },
    ],
    token: '@pub/thing-server',
  }

  it('builds the command out of the runtime and the package, never out of the row', async () => {
    const { archive, row } = makeItem({ kind: 'mcp', install, rowTier: 3 })
    const { store, claude, ran } = harness(row, archive)
    const choice: InstallChoice = { agents: ['claude', 'codex', 'gemini'], values: { ROOT: '/tmp/here' } }
    const result = await store.install('pub/thing', choice)
    expect(result.ok, result.message).toBe(true)

    expect(claude[0].request).toMatchObject({
      name: 'pub-thing',
      scope: 'user',
      transport: 'stdio',
      command: 'npx -y @pub/thing-server --root "/tmp/here"',
    })
    expect(ran.map((call) => [call.agent, ...call.argv])).toEqual([
      ['codex', 'mcp', 'add', 'pub-thing', '--', 'npx', '-y', '@pub/thing-server', '--root', '/tmp/here'],
      [
        'gemini',
        'mcp',
        'add',
        '-s',
        'user',
        '-t',
        'stdio',
        'pub-thing',
        'npx',
        '-y',
        '@pub/thing-server',
        '--root',
        '/tmp/here',
      ],
    ])
  })

  it('refuses when a required value was not given, rather than running a half-built command', async () => {
    const { archive, row } = makeItem({ kind: 'mcp', install, rowTier: 3 })
    const { store, ran } = harness(row, archive)
    const result = await store.install('pub/thing', { agents: ['claude'], values: {} })
    expect(result.ok).toBe(false)
    expect(ran).toEqual([])
  })

  it('asks each tool to remove the same name it was asked to add', async () => {
    const { archive, row } = makeItem({ kind: 'mcp', install, rowTier: 3 })
    const { store, claude, ran } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude', 'codex'], values: { ROOT: '/tmp/here' } })
    const removed = await store.remove('pub/thing')

    expect(removed.ok, removed.message).toBe(true)
    expect(claude.at(-1)).toEqual({ verb: 'remove', request: { name: 'pub-thing', scope: 'user', projectPath: null } })
    expect(ran.at(-1)).toEqual({ agent: 'codex', argv: ['mcp', 'remove', 'pub-thing'] })
  })

  it('pins the argv each command line tool actually takes', () => {
    expect(mcpAddArgs('codex', 'n', ['npx', '-y', 'p'], ['K=v'])).toEqual([
      'mcp',
      'add',
      'n',
      '--env',
      'K=v',
      '--',
      'npx',
      '-y',
      'p',
    ])
    // The scope flag is not optional here: without it this one writes the
    // server against whatever folder the app happens to be running in.
    expect(mcpAddArgs('gemini', 'n', ['npx'], [])).toEqual(['mcp', 'add', '-s', 'user', '-t', 'stdio', 'n', 'npx'])
    expect(mcpRemoveArgs('gemini', 'n')).toEqual(['mcp', 'remove', '-s', 'user', 'n'])
    expect(mcpRemoveArgs('codex', 'n')).toEqual(['mcp', 'remove', 'n'])
  })
})

describe('standing instructions', () => {
  it('writes the file and one marked line in each agent’s own memory file', async () => {
    const { archive, row } = makeItem({
      kind: 'instructions',
      install: { file: 'rules.md' },
      extra: [{ name: 'rules.md', body: '# Rules\n\nBe brief.\n' }],
    })
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude', 'gemini', 'codex'] })

    expect(readFileSync(join(home, '.claude', 'instructions', 'pub.thing.md'), 'utf8')).toContain('Be brief.')
    expect(readFileSync(join(home, '.claude', 'CLAUDE.md'), 'utf8')).toContain('@instructions/pub.thing.md')
    expect(readFileSync(join(home, '.gemini', 'GEMINI.md'), 'utf8')).toContain('@instructions/pub.thing.md')
    // No import syntax to write for this one, so the block names the file.
    expect(readFileSync(join(home, '.codex', 'AGENTS.md'), 'utf8')).toContain(
      join(home, '.codex', 'instructions', 'pub.thing.md'),
    )
  })

  it('takes every one of them back out', async () => {
    const { archive, row } = makeItem({
      kind: 'instructions',
      install: { file: 'rules.md' },
      extra: [{ name: 'rules.md', body: '# Rules\n' }],
    })
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude', 'gemini'] })
    await store.remove('pub/thing')

    expect(existsSync(join(home, '.claude', 'instructions', 'pub.thing.md'))).toBe(false)
    expect(readFileSync(join(home, '.claude', 'CLAUDE.md'), 'utf8')).not.toContain('pub.thing')
  })
})

describe('a routine, which arrives switched off', () => {
  const body = `# Nightly sweep

when: schedule 09:00
in: /somewhere/else

---

Sweep the folder.
`

  it('refuses until somebody says which folder it runs in', async () => {
    const { archive, row } = makeItem({
      kind: 'routine',
      install: { file: 'routine.md' },
      extra: [{ name: 'routine.md', body }],
      rowTier: 2,
    })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', {})
    expect(result.ok).toBe(false)
    expect(result.message).toContain('folder')
  })

  it('writes it into this app’s own routines folder, disarmed, in the chosen folder', async () => {
    const { archive, row } = makeItem({
      kind: 'routine',
      install: { file: 'routine.md' },
      extra: [{ name: 'routine.md', body }],
      rowTier: 2,
    })
    const { store } = harness(row, archive)
    const result = await store.install('pub/thing', { folder: join(home, 'work') })
    expect(result.ok, result.message).toBe(true)

    const written = readFileSync(join(userData, 'routines', 'pub-thing.md'), 'utf8')
    expect(written).toContain('enabled: no')
    expect(written).toContain(`in: ${join(home, 'work')}`)
    expect(written).not.toContain('/somewhere/else')
  })

  it('replaces the folder the file shipped with rather than keeping it', () => {
    const rewritten = setRoutineFolder(body, '/chosen')
    expect(rewritten).toContain('in: /chosen')
    expect(rewritten).not.toContain('/somewhere/else')
    expect(rewritten).toContain('Sweep the folder.')
  })
})

describe('the list a screen draws', () => {
  it('reports an installed item as installed, and an edited copy as damaged', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude'] })

    const first = await store.view()
    expect(first.items[0].state).toBe('installed')

    writeFileSync(join(itemsDir(userData), 'pub.thing', 'skill', 'SKILL.md'), 'edited behind our back')
    const second = await store.view()
    expect(second.items[0].state).toBe('damaged')
    expect(second.items[0].note).toContain('no longer matches')
  })

  it('reports a newer version as outdated', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude'] })

    const later = harness({ ...row, version: '2.0.0' }, archive)
    const view = await later.store.view()
    expect(view.items[0].state).toBe('outdated')
    expect(view.items[0].note).toContain('2.0.0')
  })

  it('still draws something installed that the catalogue no longer lists', async () => {
    const { archive, row } = skillItem()
    const { store } = harness(row, archive)
    await store.install('pub/thing', { agents: ['claude'] })

    const empty = createStoreInstaller({
      userData: () => userData,
      base: () => 'http://127.0.0.1:8933',
      env: {},
      home: () => home,
      loadIndex: async () => ({
        ok: true,
        index: {
          v: 1,
          serial: 2,
          issuedAt: '2026-08-21T00:00:00.000Z',
          expiresAt: null,
          generator: 'test',
          truncated: false,
          items: [],
          revoked: [],
        },
        from: 'store',
        at: '2026-08-29T00:00:00.000Z',
        stale: null,
        because: null,
      }),
    })
    const view = await empty.view()
    expect(view.items).toHaveLength(1)
    expect(view.items[0].state).toBe('withdrawn')
    expect(view.items[0].row.name).toBe('A Thing')
  })

  it('says why there is no list at all rather than drawing an empty shelf', async () => {
    const store = createStoreInstaller({
      userData: () => userData,
      base: () => 'http://127.0.0.1:8933',
      env: {},
      home: () => home,
      loadIndex: async () => ({ ok: false, why: 'the store could not be reached' }),
    })
    const view = await store.view()
    expect(view.ok).toBe(false)
    expect(view.why).toContain('could not be reached')
    expect(view.items).toEqual([])
  })
})

describe('what the sheet says before anything is pressed', () => {
  it('names the real folders, from the same table the installers use', () => {
    const homes = agentHomes({}, '/home')
    const targets = plannedTargets({ kind: 'skill', publisher: 'pub', id: 'pub/thing' }, ['claude', 'codex'], homes, '/data')
    expect(targets).toContain('/home/.claude/skills/pub.thing')
    expect(targets).toContain('/home/.codex/skills/pub.thing')
    expect(targets).toContain('/home/.codex/AGENTS.md')
    expect(targets[0]).toBe(join(itemsDir('/data'), 'pub.thing'))
  })

  it('names the server rather than a folder for an MCP item, because that is what happens', () => {
    const targets = plannedTargets({ kind: 'mcp', publisher: 'pub', id: 'pub/thing' }, ['claude'], agentHomes({}, '/home'), '/data')
    expect(targets.some((line) => line.includes('pub-thing'))).toBe(true)
  })
})

describe('the marked block', () => {
  it('leaves a file with no block of ours exactly as it was', () => {
    expect(stripBlock('# Mine\n\nText.\n', 'pub.thing')).toBe('# Mine\n\nText.\n')
  })

  it('names the folder the same way everywhere', () => {
    expect(itemFolderName('pub', 'thing')).toBe('pub.thing')
    expect(ledgerPath('/data')).toContain('installed.json')
  })
})
