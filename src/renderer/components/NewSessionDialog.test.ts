import { describe, expect, it } from 'vitest'
import {
  parseRecentProjects,
  readStartMemory,
  toStartProviders,
  withProject,
  writeStartMemory,
} from './NewSessionDialog'
import { buildProviderRows } from './ProviderPicker'
import { START_MEMORY_KEY } from '../session-start'
import type { ProviderId } from '@shared/types'

/**
 * The dialog's edges: what it reads off the bridge, and what it writes to
 * storage. Everything in between is `session-start`, which is tested on its
 * own — this file only checks that the adapters between them do not lie.
 */

const KNOWN: readonly ProviderId[] = ['claude', 'codex', 'gemini', 'shell']

function fakeStorage(initial: Record<string, string> = {}): Storage {
  const data = new Map(Object.entries(initial))
  return {
    get length() {
      return data.size
    },
    clear: () => data.clear(),
    getItem: (key: string) => data.get(key) ?? null,
    key: (index: number) => [...data.keys()][index] ?? null,
    removeItem: (key: string) => {
      data.delete(key)
    },
    setItem: (key: string, value: string) => {
      data.set(key, value)
    },
  }
}

/** A store that has been disabled by policy — every call throws. */
function hostileStorage(): Storage {
  const boom = (): never => {
    throw new Error('storage disabled')
  }
  return {
    get length(): number {
      return boom()
    },
    clear: boom,
    getItem: boom,
    key: boom,
    removeItem: boom,
    setItem: boom,
  }
}

describe('parseRecentProjects', () => {
  it('turns the stored list into rows with folder names', () => {
    const projects = parseRecentProjects([
      { path: '/Users/apple/Projects/pawl', lastOpenedAt: 2 },
      { path: '/Users/apple/Projects/mookhayo', lastOpenedAt: 5 },
    ])
    expect(projects.map((p) => p.name)).toEqual(['mookhayo', 'pawl'])
  })

  it('puts the most recently opened first', () => {
    const projects = parseRecentProjects([
      { path: '/a', lastOpenedAt: 1 },
      { path: '/b', lastOpenedAt: 9 },
    ])
    expect(projects[0].path).toBe('/b')
  })

  it('treats a missing timestamp as oldest rather than dropping the project', () => {
    const projects = parseRecentProjects([{ path: '/a' }, { path: '/b', lastOpenedAt: 1 }])
    expect(projects.map((p) => p.path)).toEqual(['/b', '/a'])
  })

  it('drops entries with no usable path', () => {
    expect(parseRecentProjects([{ path: '' }, { path: 3 }, null, 'x'])).toEqual([])
  })

  it('de-duplicates the same folder', () => {
    const projects = parseRecentProjects([
      { path: '/a', lastOpenedAt: 1 },
      { path: '/a', lastOpenedAt: 2 },
    ])
    expect(projects).toHaveLength(1)
  })

  it('survives a bridge that answered with something other than a list', () => {
    expect(parseRecentProjects(null)).toEqual([])
    expect(parseRecentProjects({ projects: [] })).toEqual([])
  })
})

describe('withProject', () => {
  it('puts a browsed folder at the top', () => {
    const next = withProject([{ path: '/a', name: 'a', lastOpenedAt: 9 }], '/b')
    expect(next.map((p) => p.path)).toEqual(['/b', '/a'])
  })

  it('moves an existing folder up rather than duplicating it', () => {
    const next = withProject(
      [
        { path: '/a', name: 'a', lastOpenedAt: 9 },
        { path: '/b', name: 'b', lastOpenedAt: 1 },
      ],
      '/b',
    )
    expect(next.map((p) => p.path)).toEqual(['/b', '/a'])
  })
})

describe('toStartProviders', () => {
  const rows = buildProviderRows({ claude: true, codex: true, gemini: false, shell: true })

  it('marks only Claude as isolatable, matching the profiles rule', () => {
    const isolatable = toStartProviders(rows)
      .filter((provider) => provider.supportsProfiles)
      .map((provider) => provider.id)
    expect(isolatable).toEqual(['claude'])
  })

  it('carries availability through from detection', () => {
    const byId = new Map(toStartProviders(rows).map((provider) => [provider.id, provider]))
    expect(byId.get('gemini')?.available).toBe(false)
    expect(byId.get('codex')?.available).toBe(true)
  })

  it('carries the resume capability through', () => {
    const resumable = toStartProviders(rows)
      .filter((provider) => provider.canResume)
      .map((provider) => provider.id)
    expect(resumable).toEqual(['claude', 'codex'])
  })

  it('keeps a label for every row, since notices name the agent', () => {
    for (const provider of toStartProviders(rows)) expect(provider.label).not.toBe('')
  })
})

describe('start memory', () => {
  it('round-trips through storage', () => {
    const storage = fakeStorage()
    writeStartMemory({ '/w/app': { provider: 'codex', resume: true } }, storage)
    expect(readStartMemory(KNOWN, storage)).toEqual({
      '/w/app': { provider: 'codex', resume: true },
    })
  })

  it('reads nothing from an empty store', () => {
    expect(readStartMemory(KNOWN, fakeStorage())).toEqual({})
  })

  it('survives a blob that is not JSON', () => {
    expect(readStartMemory(KNOWN, fakeStorage({ [START_MEMORY_KEY]: '{oops' }))).toEqual({})
  })

  it('survives a store that throws on every call', () => {
    expect(readStartMemory(KNOWN, hostileStorage())).toEqual({})
    expect(() => writeStartMemory({ '/w/app': {} }, hostileStorage())).not.toThrow()
  })

  it('does nothing at all when there is no store', () => {
    expect(readStartMemory(KNOWN, null)).toEqual({})
    expect(() => writeStartMemory({ '/w/app': {} }, null)).not.toThrow()
  })

  it('drops a remembered provider this build does not know', () => {
    const storage = fakeStorage({
      [START_MEMORY_KEY]: JSON.stringify({ '/w/app': { provider: 'kimi', resume: true } }),
    })
    expect(readStartMemory(KNOWN, storage)).toEqual({ '/w/app': { resume: true } })
  })
})
