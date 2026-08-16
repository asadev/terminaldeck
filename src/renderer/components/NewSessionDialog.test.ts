import { describe, expect, it } from 'vitest'
import {
  matchProjects,
  parseRecentProjects,
  projectShortlist,
  readStartMemory,
  toStartProviders,
  withProject,
  writeStartMemory,
  type RecentProject,
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
      { path: '/Users/apple/Projects/terminaldeck', lastOpenedAt: 2 },
      { path: '/Users/apple/Projects/mookhayo', lastOpenedAt: 5 },
    ])
    expect(projects.map((p) => p.name)).toEqual(['mookhayo', 'terminaldeck'])
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

  it('marks the isolatable agents, matching the profiles rule', () => {
    // Codex joined the list when `CODEX_HOME` was measured moving a login;
    // Gemini stays off it because its variable moves the settings and leaves
    // the token in one shared keychain entry. `provider-accounts.ts` holds both
    // measurements, and `isolationNotice` reads the same catalogue this does,
    // so there is one answer rather than two that agree by coincidence.
    const isolatable = toStartProviders(rows)
      .filter((provider) => provider.supportsProfiles)
      .map((provider) => provider.id)
    expect(isolatable).toEqual(['claude', 'codex'])
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

/* ----------------------------------------------- finding a folder to run in -- */

/**
 * The Project section, once somebody has more folders than the shortlist holds.
 *
 * Pinned here rather than in `dialog-render.test.tsx` because the project list
 * arrives in an effect and effects do not run under `react-dom/server`: a
 * rendered dialog sees an empty list whatever the store contains, so the
 * nine-projects case has no other place it can be held.
 */
function projectsNamed(...names: string[]): RecentProject[] {
  return names.map((name, index) => ({
    path: `/Users/apple/Projects/${name}`,
    name,
    lastOpenedAt: names.length - index,
  }))
}

const MANY = projectsNamed(
  'terminaldeck',
  'science-locus',
  'mookhayo',
  'engineerings-pk',
  'asadiqbal-ai',
  'luxury-fleet',
  'vfs-sentinel',
  'odysseus',
  'hermes',
)

describe('matchProjects', () => {
  it('finds a folder by its name', () => {
    expect(matchProjects(MANY, 'hermes').map((p) => p.name)).toEqual(['hermes'])
  })

  it('finds folders by where they live', () => {
    // The other half of the question a list of paths is asked: everything under
    // one parent, rather than one folder by name.
    expect(matchProjects(MANY, '/Users/apple/Projects/')).toHaveLength(MANY.length)
  })

  it('does not care about case, or about the spaces around what was typed', () => {
    expect(matchProjects(MANY, '  MOOKHAYO ').map((p) => p.name)).toEqual(['mookhayo'])
  })

  it('is the whole list until something is typed', () => {
    expect(matchProjects(MANY, '')).toHaveLength(MANY.length)
    expect(matchProjects(MANY, '   ')).toHaveLength(MANY.length)
  })

  it('is empty when nothing matches, rather than falling back to everything', () => {
    // A filter that quietly shows the whole list on a miss is one that makes
    // somebody start a session in the wrong folder.
    expect(matchProjects(MANY, 'zzz')).toEqual([])
  })
})

describe('projectShortlist', () => {
  it('draws no filter while the whole list is on screen', () => {
    const eight = MANY.slice(0, 8)
    const list = projectShortlist(eight, '')
    expect(list.filtering).toBe(false)
    expect(list.shown).toHaveLength(8)
    expect(list.hidden).toBe(0)
  })

  it('offers one at the first project the cap can hide', () => {
    /*
     * Nine is the number that matters: the list stops at eight, so from here on
     * a folder somebody has open can be missing from this panel with nothing on
     * screen saying so, and Browse — a system dialog for folders the app has
     * never seen — was the only way to reach it.
     */
    const list = projectShortlist(MANY, '')
    expect(list.filtering).toBe(true)
    expect(list.shown).toHaveLength(8)
    expect(list.hidden).toBe(1)
  })

  it('searches the whole list, not the eight rows already visible', () => {
    // `hermes` is ninth. Before the filter existed it could not be picked here
    // at all.
    const list = projectShortlist(MANY, 'hermes')
    expect(list.shown.map((p) => p.name)).toEqual(['hermes'])
    expect(list.hidden).toBe(0)
  })

  it('never reports a negative number of hidden folders', () => {
    expect(projectShortlist(MANY, 'zzz').hidden).toBe(0)
  })
})
