import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '../../shared/types'
import { MemoryService } from '../memory/service'
import type { DiscoverInput } from '../memory/spaces'
import type { ToolContext } from './catalogue'
import { memoryTools, type MemoryToolDeps } from './memory-tools'
import { SESSION_TOOLS, ELSEWHERE_TOOLS } from './session-tools'
import { contextFor, fakeSurface, session, toolNamed } from './sessions-lane.fixture'
import { ALL_TIERS, Refused, type Caller } from './surface'

/**
 * Whose memory each caller reaches. Every store is a temp folder laid out like
 * the real ones; nothing here reads a real `~/.claude` or `~/.codex`.
 */

let dir: string
let service: MemoryService

function write(path: string, text: string): void {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, text)
}

function conversation(folder: string, cwd: string): void {
  write(join(folder, 'c.jsonl'), `${JSON.stringify({ type: 'user', cwd })}\n`)
}

/** `/work/alpha` and `/work/gamma` with memory, `/work/beta` linked to alpha's, Codex, Hoot, alpha's knowledge. */
function lay(): { input: DiscoverInput; claude: string; codex: string } {
  const claude = join(dir, 'claude')
  const projects = join(claude, 'projects')
  write(join(projects, '-work-alpha', 'memory', 'MEMORY.md'), '- [Rules](rules.md)\n')
  write(join(projects, '-work-alpha', 'memory', 'rules.md'), '---\nname: rules\n---\nAlpha ships on Fridays. See [[missing]].\n')
  conversation(join(projects, '-work-alpha'), '/work/alpha')
  mkdirSync(join(projects, '-work-beta'), { recursive: true })
  symlinkSync(join(projects, '-work-alpha', 'memory'), join(projects, '-work-beta', 'memory'))
  conversation(join(projects, '-work-beta'), '/work/beta')
  write(join(projects, '-work-gamma', 'memory', 'secret.md'), 'Gamma keeps the launch code word: zebra.\n')
  conversation(join(projects, '-work-gamma'), '/work/gamma')

  const codex = join(dir, 'codex')
  write(join(codex, 'memories', 'memory_summary.md'), 'Codex remembers Fridays too.\n')
  const hootMemory = join(dir, 'userData', 'copilot', 'memory')
  write(join(hootMemory, 'pref.md'), 'Hoot plans on Fridays.\n')
  write(join(dir, 'userData', 'knowledge', 'k', 'project.json'), JSON.stringify({ project: '/work/alpha' }))
  write(join(dir, 'userData', 'knowledge', 'k', 'k1.md'), '---\nkind: decision\n---\nAlpha decided Fridays.\n')
  return {
    claude,
    codex,
    input: {
      stores: [
        { provider: 'claude', configDir: claude, name: 'Own' },
        { provider: 'codex', configDir: codex, name: 'Codex' },
      ],
      hootMemory,
      userData: join(dir, 'userData'),
    },
  }
}

function setup(sessions: SessionMeta[]) {
  const laid = lay()
  service = new MemoryService({ sources: () => laid.input, trash: async () => {} })
  const deps: MemoryToolDeps = {
    memory: () => service,
    storeOf: (meta) => (meta.provider === 'claude' ? laid.claude : meta.provider === 'codex' ? laid.codex : null),
  }
  const { state, surface } = fakeSurface()
  state.sessions = sessions
  state.projects = [{ path: '/work/alpha', lastOpenedAt: 1 }]
  const tools = memoryTools(deps)
  const as = (caller: Caller): ToolContext => ({ ...contextFor(surface), caller })
  return {
    search: toolNamed(tools, 'memory.search'),
    read: toolNamed(tools, 'memory.read'),
    as,
    sessionCaller: (id: string, machineId = ''): ToolContext => as({ kind: 'session', sessionId: id, machineId, tiers: ALL_TIERS }),
    local: contextFor(surface),
  }
}

type SearchValue = { scope: string; results: Array<{ path: string; memory: string }>; spaces: Array<{ label: string; sharedWith?: string[] }> }

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-memory-tools-')))
})

afterEach(async () => {
  await service?.close()
  rmSync(dir, { recursive: true, force: true })
})

describe('a session reads its own memory and nothing else', () => {
  it('finds its own folder’s notes', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    const value = (await t.search.run({ query: 'fridays' }, t.sessionCaller('a'))).value as SearchValue
    expect(value.results.map((hit) => hit.path)).toEqual(['rules.md'])
    expect(value.spaces.map((space) => space.label)).toEqual(['alpha'])
  })

  it('cannot find another project’s memory, by search or by path', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    const value = (await t.search.run({ query: 'zebra' }, t.sessionCaller('a'))).value as SearchValue
    expect(value.results).toEqual([])
    await expect(t.read.run({ path: '../-work-gamma/memory/secret.md' }, t.sessionCaller('a'))).rejects.toThrow()
    await expect(t.read.run({ path: 'secret.md' }, t.sessionCaller('a'))).rejects.toThrow(/no longer there/)
  })

  it('may not name a project to widen what it reads', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    await expect(t.search.run({ query: 'zebra', project: '/work/gamma' }, t.sessionCaller('a'))).rejects.toBeInstanceOf(Refused)
  })

  it('is told when the memory it reads is shared with another folder through an existing link', async () => {
    const t = setup([session({ id: 'b', cwd: '/work/beta' })])
    const value = (await t.search.run({ query: 'fridays' }, t.sessionCaller('b'))).value as SearchValue
    expect(value.results.map((hit) => hit.path)).toEqual(['rules.md'])
    expect(value.spaces[0].sharedWith).toEqual(['/work/beta'])
    expect(value.scope).toMatch(/shared/)
  })

  it('reads one note with its links, the links that reach nothing, and what links to it', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    const value = (await t.read.run({ path: 'rules.md' }, t.sessionCaller('a'))).value as Record<string, unknown>
    expect(value).toMatchObject({ path: 'rules.md', title: 'rules', linksTo: [], linksToNothing: ['missing'], linkedFrom: ['MEMORY.md'] })
  })

  it('lists its notes when no path is given', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    const value = (await t.read.run({}, t.sessionCaller('a'))).value as { memories: Array<{ notes: Array<{ path: string }> }> }
    expect(value.memories).toHaveLength(1)
    expect(value.memories[0].notes.map((note) => note.path).sort()).toEqual(['MEMORY.md', 'rules.md'])
  })

  it('a Codex session reads Codex’s memory, not Claude’s', async () => {
    const t = setup([session({ id: 'x', cwd: '/work/alpha', provider: 'codex' })])
    const value = (await t.search.run({ query: 'fridays' }, t.sessionCaller('x'))).value as SearchValue
    expect(value.results.map((hit) => hit.path)).toEqual(['memory_summary.md'])
  })

  it('a folder with no memory yet answers empty, and says so', async () => {
    const t = setup([session({ id: 'n', cwd: '/work/new' })])
    const value = (await t.search.run({ query: 'fridays' }, t.sessionCaller('n'))).value as SearchValue
    expect(value.results).toEqual([])
    expect(value.scope).toMatch(/No memory has been kept/)
  })

  it('refuses a session on another computer and a token with no session behind it', async () => {
    const t = setup([session({ id: 'a', cwd: '/work/alpha' })])
    await expect(t.search.run({ query: 'fridays' }, t.sessionCaller('a', 'machine-2'))).rejects.toBeInstanceOf(Refused)
    await expect(t.search.run({ query: 'fridays' }, t.sessionCaller('ghost'))).rejects.toBeInstanceOf(Refused)
  })
})

describe('Hoot reads its own, and a project it names for planning', () => {
  it('reads only its own memory unless it names a project', async () => {
    const t = setup([])
    const own = (await t.search.run({ query: 'fridays' }, t.local)).value as SearchValue
    expect(own.results.map((hit) => hit.path)).toEqual(['pref.md'])
  })

  it('adds an open project’s memory and knowledge when it names one', async () => {
    const t = setup([])
    const value = (await t.search.run({ query: 'fridays', project: '/work/alpha' }, t.local)).value as SearchValue
    expect(new Set(value.results.map((hit) => hit.path))).toEqual(new Set(['pref.md', 'rules.md', 'k1.md']))
    expect(value.results.map((hit) => hit.path)).not.toContain('secret.md')
  })

  it('cannot name a folder this app does not have open', async () => {
    const t = setup([])
    await expect(t.search.run({ query: 'zebra', project: '/work/gamma' }, t.local)).rejects.toBeInstanceOf(Refused)
  })

  it('must say which memory when it reads a path with several in scope', async () => {
    const t = setup([])
    await expect(t.read.run({ path: 'rules.md', project: '/work/alpha' }, t.local)).rejects.toThrow(/pass space/)
  })
})

describe('nobody else', () => {
  it('refuses an AI app on a key and a paired device', async () => {
    const t = setup([])
    for (const caller of [
      { kind: 'key', keyId: 'k', tiers: ALL_TIERS },
      { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS },
    ] as Caller[]) {
      await expect(t.search.run({ query: 'fridays' }, t.as(caller))).rejects.toBeInstanceOf(Refused)
    }
  })

  it('is granted to a session here, read-only, and not to one on another computer', () => {
    const tools = memoryTools({ memory: () => null, storeOf: () => null })
    for (const tool of tools) {
      expect(tool.tier).toBe('read')
      expect(tool.audience).toBe('copilot')
      expect(SESSION_TOOLS.has(tool.id) && SESSION_TOOLS.has(tool.wire)).toBe(true)
      expect(ELSEWHERE_TOOLS.has(tool.id) || ELSEWHERE_TOOLS.has(tool.wire)).toBe(false)
    }
  })
})
