import { describe, expect, it } from 'vitest'
import {
  conversationLine,
  isDefaultLogin,
  loginHint,
  loginLine,
  loginOptionLabel,
  matchProjects,
  olderConversationsLine,
  parseConversations,
  parseRecentProjects,
  parseSignIn,
  projectShortlist,
  readStartMemory,
  shortSessionId,
  toStartProviders,
  transcriptsAreReadable,
  withProject,
  writeStartMemory,
  type RecentProject,
} from './NewSessionDialog'
import { buildProviderRows } from './ProviderPicker'
import type { ProfileView, SnapshotView } from './ProfilePicker'
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

/* ------------------------------------------ which conversation is continued -- */

/**
 * The Conversation section's honesty.
 *
 * The row used to read "Picks up the most recent session in this folder",
 * which restates the flag and answers nothing — his question, in his words,
 * was *"which conversation will it bring?"*. These pin the answer, and pin the
 * two cases where the honest answer is to say less rather than to guess.
 */
const HOUR = 3_600_000
const NOW = 1_760_000_000_000

describe('parseConversations', () => {
  it('names the transcripts, newest written first', () => {
    const list = parseConversations([
      { sessionId: 'a3f19c74-1111-2222-3333-444455556666', modifiedAt: NOW - HOUR, bytes: 900 },
      { sessionId: 'bb0d5e21-1111-2222-3333-444455556666', modifiedAt: NOW - 5 * HOUR, bytes: 40 },
    ])
    expect(list.map((c) => shortSessionId(c.sessionId))).toEqual(['a3f19c74', 'bb0d5e21'])
  })

  it('re-sorts rather than trusting the order it was handed', () => {
    const list = parseConversations([
      { sessionId: 'old', modifiedAt: 1, bytes: 5 },
      { sessionId: 'new', modifiedAt: 9, bytes: 5 },
    ])
    expect(list[0].sessionId).toBe('new')
  })

  it('drops an empty transcript, because --continue at one kills the tab', () => {
    /*
     * The CLI opens a transcript before it has a turn to put in it, so a
     * zero-byte file is a session that started and said nothing.
     * `newestConversation` in main/transcript.ts skips them for exactly this
     * reason; naming one here would name a conversation the resume will not
     * land on.
     */
    const list = parseConversations([
      { sessionId: 'empty', modifiedAt: NOW, bytes: 0 },
      { sessionId: 'real', modifiedAt: NOW - HOUR, bytes: 120 },
    ])
    expect(list.map((c) => c.sessionId)).toEqual(['real'])
  })

  it('survives a bridge that answered with something other than a list', () => {
    expect(parseConversations(null)).toEqual([])
    expect(parseConversations([{ sessionId: 3 }, null, 'x', {}])).toEqual([])
  })
})

describe('conversationLine', () => {
  it('says when, and which', () => {
    const list = parseConversations([
      { sessionId: 'a3f19c74-dead-beef-cafe-000000000000', modifiedAt: NOW - 2 * HOUR, bytes: 12 },
    ])
    expect(conversationLine(list, NOW)).toBe('2h ago · a3f19c74')
  })

  it('says nothing at all when there is no conversation to name', () => {
    expect(conversationLine([], NOW)).toBeNull()
  })
})

describe('olderConversationsLine', () => {
  it('accounts for the ones the resume will not reach', () => {
    const many = parseConversations(
      ['a', 'b', 'c', 'd'].map((id, i) => ({ sessionId: id, modifiedAt: NOW - i, bytes: 10 })),
    )
    expect(olderConversationsLine(many)).toBe('3 older conversations here. Resume always takes the newest.')
  })

  it('reads as English for exactly one', () => {
    const two = parseConversations([
      { sessionId: 'a', modifiedAt: 2, bytes: 1 },
      { sessionId: 'b', modifiedAt: 1, bytes: 1 },
    ])
    expect(olderConversationsLine(two)).toContain('1 older conversation here')
  })

  it('stays quiet when there is nothing to explain', () => {
    // A folder with one conversation has no picker to miss, and a sentence
    // about the alternatives when there are none is a line for nothing.
    expect(olderConversationsLine(parseConversations([{ sessionId: 'a', modifiedAt: 1, bytes: 1 }]))).toBeNull()
    expect(olderConversationsLine([])).toBeNull()
  })
})

describe('transcriptsAreReadable', () => {
  const system: ProfileView = {
    id: 'system',
    name: 'Default',
    provider: 'claude',
    configDir: '/Users/apple/.claude',
    system: true,
    color: '--accent',
    lastUsedAt: null,
  }
  const work: ProfileView = { ...system, id: 'work', name: 'Work', system: false }

  it('reads the store the enumeration actually looks in', () => {
    expect(transcriptsAreReadable([system, work], 'system')).toBe(true)
    expect(transcriptsAreReadable([system, work], null)).toBe(true)
  })

  it('declines to name a conversation from a store it is not reading', () => {
    /*
     * `insights:list` reads the default config directory. A profile is a
     * different `CLAUDE_CONFIG_DIR`, so its transcripts are somewhere nothing
     * on the bridge can list — and naming "the last conversation" there would
     * be naming one out of the wrong account's history.
     */
    expect(transcriptsAreReadable([system, work], 'work')).toBe(false)
  })

  it('declines for a login the list no longer has', () => {
    expect(transcriptsAreReadable([system], 'deleted')).toBe(false)
  })
})

/* --------------------------------------------------------- whose login it is -- */

/**
 * > *"Login default, instead of just saying default because nobody now knows
 * > which one is default… we can have an email so we know which one is default"*
 */
describe('parseSignIn', () => {
  it('takes the report the probe produced', () => {
    expect(parseSignIn({ state: 'signed-in', account: 'a@b.com', plan: 'max' })).toEqual({
      state: 'signed-in',
      account: 'a@b.com',
      plan: 'max',
    })
  })

  it('refuses a shape it does not recognise rather than inventing a state', () => {
    expect(parseSignIn(null)).toBeNull()
    expect(parseSignIn({ state: 'probably' })).toBeNull()
    expect(parseSignIn({ loggedIn: true })).toBeNull()
  })

  it('treats an empty string as no account, not as an account called ""', () => {
    expect(parseSignIn({ state: 'signed-in', account: '', plan: '' })).toEqual({
      state: 'signed-in',
      account: null,
      plan: null,
    })
  })
})

describe('loginLine', () => {
  it('is the address, which is the whole point of the row', () => {
    expect(loginLine({ state: 'signed-in', account: 'asad@example.com', plan: 'max' })).toBe(
      'asad@example.com · max',
    )
    expect(loginLine({ state: 'signed-in', account: 'asad@example.com', plan: null })).toBe(
      'asad@example.com',
    )
  })

  it('falls back to what the CLI did say for an agent that prints no address', () => {
    // Codex's `login status` prints no email, by design — reading its
    // credential file to decorate a row is a trade this app does not make.
    expect(loginLine({ state: 'signed-in', account: null, plan: 'using ChatGPT' })).toBe(
      'using ChatGPT',
    )
    expect(loginLine({ state: 'signed-in', account: null, plan: null })).toBe('Signed in')
  })

  it('never reports a login it could not read as signed in', () => {
    expect(loginLine({ state: 'unknown', account: null, plan: null })).toBe('Sign-in state unknown')
    expect(loginLine({ state: 'signed-out', account: null, plan: null })).toBe('Not signed in')
  })

  it('says nothing while the probe is still out, or when logins do not apply', () => {
    expect(loginLine(null)).toBeNull()
    expect(loginLine({ state: 'unsupported', account: null, plan: null })).toBeNull()
  })
})

describe('loginHint', () => {
  const report = { state: 'signed-in', account: 'app.imatch.ae@gmail.com', plan: 'max' } as const

  it('does not repeat the address the pop-up beside it is already showing', () => {
    // Before the pop-up named the account it said "Default", so this line was
    // the only place the address appeared. Both saying it puts the same
    // twenty-three characters twice on one row.
    expect(loginHint(report, 'app.imatch.ae@gmail.com')).toBe('Signed in · max')
    expect(loginHint({ ...report, plan: null }, 'app.imatch.ae@gmail.com')).toBe('Signed in')
  })

  it('keeps the whole line whenever the pop-up is not showing the address', () => {
    // The pop-up falls back to which install a login is — for an agent that
    // names no address, for a row nobody selected, for an empty list. The
    // address has to be on screen once, and this is the once.
    expect(loginHint(report, 'Your own Claude Code install')).toBe('app.imatch.ae@gmail.com · max')
    expect(loginHint(report, null)).toBe('app.imatch.ae@gmail.com · max')
    expect(loginHint({ state: 'signed-in', account: null, plan: 'using ChatGPT' }, 'Your own Codex CLI install')).toBe(
      'using ChatGPT',
    )
  })

  it('still says nothing while the probe is out, and reports what it could not read', () => {
    expect(loginHint(null, 'anything')).toBeNull()
    expect(loginHint({ state: 'signed-out', account: null, plan: null }, 'Work')).toBe('Not signed in')
    expect(loginHint({ state: 'unknown', account: null, plan: null }, 'Work')).toBe('Sign-in state unknown')
  })
})

describe('loginOptionLabel', () => {
  const system: ProfileView = {
    id: 'system',
    name: 'Default',
    provider: 'claude',
    configDir: '/Users/apple/.claude',
    system: true,
    color: '--accent',
    lastUsedAt: null,
  }
  const codex: ProfileView = { ...system, id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex' }
  const report = { state: 'signed-in', account: 'app.imatch.ae@gmail.com', plan: 'max' } as const

  it('gives the selected login the address the probe came back with', () => {
    // The defect this pins: the pop-up read "Default" directly under a row
    // reading "app.imatch.ae@gmail.com · max" — the generated key beside the
    // answer it is supposed to be an answer to.
    expect(loginOptionLabel(system, 'system', report)).toBe('app.imatch.ae@gmail.com')
  })

  it('does not put that address on any other login', () => {
    // One probe is in flight and it was run for one login. Spreading its answer
    // across the list would name three logins after one account.
    expect(loginOptionLabel(codex, 'system', report)).toBe('Your own Codex CLI install')
  })

  it('never falls back to the generated key, probe or no probe', () => {
    expect(loginOptionLabel(system, 'system', null)).toBe('Your own Claude Code install')
    expect(loginOptionLabel(system, null, null)).not.toMatch(/Default/)
  })
})

describe('isDefaultLogin', () => {
  const system: ProfileView = {
    id: 'system',
    name: 'Default',
    provider: 'claude',
    configDir: '/Users/apple/.claude',
    system: true,
    color: '--accent',
    lastUsedAt: null,
  }
  const work: ProfileView = { ...system, id: 'work', name: 'Work', system: false }
  const snapshot = (defaultProfileId: string | null): SnapshotView => ({
    profiles: [system, work],
    defaultProfileId,
    projectDefaults: {},
  })

  it('knows the one that is set', () => {
    expect(isDefaultLogin(snapshot('work'), work)).toBe(true)
    expect(isDefaultLogin(snapshot('work'), system)).toBe(false)
  })

  it('treats no default at all as the system login, not as nobody', () => {
    // The case that would put a "Make default" button on a login that already
    // is one. `profileBadges` holds the rule and this calls it rather than
    // restating it.
    expect(isDefaultLogin(snapshot(null), system)).toBe(true)
    expect(isDefaultLogin(snapshot(null), work)).toBe(false)
  })

  it('is false when no login is resolved yet', () => {
    expect(isDefaultLogin(snapshot(null), undefined)).toBe(false)
  })
})
