import { describe, expect, it } from 'vitest'
import {
  DEFAULT_COLS,
  DEFAULT_ROWS,
  fallbackProfileId,
  firstAvailableProvider,
  initialSessionTitle,
  MAX_REMEMBERED_PROJECTS,
  normalizeFirstPrompt,
  parseStartMemory,
  projectDefaultsFor,
  rememberStart,
  resolveStart,
  titleFromFirstPrompt,
  type SpawnRequest,
  type StartContext,
  type StartMemory,
  type StartProfile,
  type StartProvider,
  type StartResolution,
} from './session-start'
import type { ProviderId } from '@shared/types'

/**
 * The whole point of this module is that the interesting decisions are not
 * visible on screen: which of three remembered defaults wins, and what happens
 * when the answer to that has since been uninstalled. So they are exercised
 * directly, with the all-unavailable case treated as a first-class outcome
 * rather than an edge.
 */

const KNOWN: readonly ProviderId[] = ['claude', 'codex', 'gemini', 'shell']

function provider(id: ProviderId, overrides: Partial<StartProvider> = {}): StartProvider {
  const labels: Record<ProviderId, string> = {
    claude: 'Claude Code',
    codex: 'Codex CLI',
    gemini: 'Gemini CLI',
    shell: 'Shell',
  }
  return {
    id,
    label: labels[id],
    available: true,
    canResume: id === 'claude' || id === 'codex',
    supportsProfiles: id === 'claude',
    ...overrides,
  }
}

const PROFILES: StartProfile[] = [
  { id: 'system', name: 'Default', system: true },
  { id: 'work', name: 'Work' },
]

function context(overrides: Partial<StartContext> = {}): StartContext {
  return {
    providers: [provider('claude'), provider('codex'), provider('gemini'), provider('shell')],
    profiles: PROFILES,
    ...overrides,
  }
}

/** Narrow a resolution to the success case, failing loudly if it is not one. */
function ok(resolution: StartResolution): { request: SpawnRequest; notices: StartResolution['notices'] } {
  if (!resolution.ok) throw new Error(`expected a resolved start, got ${resolution.problem.code}`)
  return { request: resolution.request, notices: resolution.notices }
}

describe('resolveStart — the project', () => {
  it('refuses to start without a folder', () => {
    const resolution = resolveStart(context(), { projectPath: null })
    expect(resolution.ok).toBe(false)
    if (!resolution.ok) expect(resolution.problem.code).toBe('no-project')
  })

  it('treats a whitespace-only path as no path', () => {
    const resolution = resolveStart(context(), { projectPath: '   ' })
    expect(resolution.ok).toBe(false)
  })

  it('trims the path it was handed rather than spawning into " /w/app"', () => {
    expect(ok(resolveStart(context(), { projectPath: ' /w/app ' })).request.cwd).toBe('/w/app')
  })
})

describe('resolveStart — provider precedence', () => {
  const memory: StartMemory = { '/w/app': { provider: 'codex' } }

  it('prefers this session’s choice over everything remembered', () => {
    const resolution = resolveStart(context({ memory, defaultProvider: 'gemini' }), {
      projectPath: '/w/app',
      provider: 'claude',
    })
    expect(ok(resolution).request.provider).toBe('claude')
  })

  it('falls back to the project’s remembered provider', () => {
    const resolution = resolveStart(context({ memory, defaultProvider: 'gemini' }), {
      projectPath: '/w/app',
    })
    expect(ok(resolution).request.provider).toBe('codex')
  })

  it('falls back to the global default when the project has no memory', () => {
    const resolution = resolveStart(context({ memory, defaultProvider: 'gemini' }), {
      projectPath: '/w/other',
    })
    expect(ok(resolution).request.provider).toBe('gemini')
  })

  it('falls back to the first installed provider when nothing was asked for', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app' })
    expect(ok(resolution).request.provider).toBe('claude')
  })

  it('matches a remembered path however it was written', () => {
    const resolution = resolveStart(context({ memory }), { projectPath: '/w//app/' })
    expect(ok(resolution).request.provider).toBe('codex')
  })
})

describe('resolveStart — provider fallbacks', () => {
  const partly = [
    provider('claude', { available: false }),
    provider('codex', { available: false }),
    provider('gemini'),
    provider('shell'),
  ]

  it('steps past an uninstalled choice and says that it did', () => {
    const resolution = resolveStart(context({ providers: partly }), {
      projectPath: '/w/app',
      provider: 'claude',
    })
    const { request, notices } = ok(resolution)
    expect(request.provider).toBe('gemini')
    expect(notices.map((n) => n.code)).toContain('provider-substituted')
    // The message has to name what is missing, or it explains nothing.
    expect(notices[0].message).toContain('Claude Code')
  })

  it('reports the highest-precedence denial, not the last one', () => {
    const resolution = resolveStart(
      context({ providers: partly, memory: { '/w/app': { provider: 'codex' } } }),
      { projectPath: '/w/app', provider: 'claude' },
    )
    expect(ok(resolution).notices[0].message).toContain('Claude Code')
  })

  it('says nothing when the fallback is what was asked for anyway', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app', provider: 'claude' })
    expect(ok(resolution).notices).toEqual([])
  })

  it('ignores a provider id that is not in the catalogue at all', () => {
    // Written by a future version, or a typo hand-edited into storage. There is
    // nothing honest to say about it, so it must not produce a notice.
    const resolution = resolveStart(context(), {
      projectPath: '/w/app',
      provider: 'kimi' as ProviderId,
    })
    const { request, notices } = ok(resolution)
    expect(request.provider).toBe('claude')
    expect(notices).toEqual([])
  })

  it('cannot start when every provider is missing', () => {
    const resolution = resolveStart(
      context({ providers: KNOWN.map((id) => provider(id, { available: false })) }),
      { projectPath: '/w/app', provider: 'claude' },
    )
    expect(resolution.ok).toBe(false)
    if (!resolution.ok) {
      expect(resolution.problem.code).toBe('no-provider')
      expect(resolution.problem.message).toContain('PATH')
    }
  })

  it('cannot start when the catalogue is empty', () => {
    const resolution = resolveStart(context({ providers: [] }), { projectPath: '/w/app' })
    expect(resolution.ok).toBe(false)
  })
})

describe('resolveStart — resume', () => {
  it('is off unless asked for', () => {
    expect(ok(resolveStart(context(), { projectPath: '/w/app' })).request.resume).toBe(false)
  })

  it('honours the request when the agent can resume', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app', resume: true })
    expect(ok(resolution).request.resume).toBe(true)
  })

  it('is remembered per project', () => {
    const resolution = resolveStart(context({ memory: { '/w/app': { resume: true } } }), {
      projectPath: '/w/app',
    })
    expect(ok(resolution).request.resume).toBe(true)
  })

  it('lets this session turn off what the project remembered', () => {
    const resolution = resolveStart(context({ memory: { '/w/app': { resume: true } } }), {
      projectPath: '/w/app',
      resume: false,
    })
    expect(ok(resolution).request.resume).toBe(false)
  })

  it('drops the flag for an agent with no resume command, and says so', () => {
    const resolution = resolveStart(context(), {
      projectPath: '/w/app',
      provider: 'gemini',
      resume: true,
    })
    const { request, notices } = ok(resolution)
    expect(request.resume).toBe(false)
    expect(notices.map((n) => n.code)).toEqual(['resume-unsupported'])
  })

  it('drops it silently when it was never asked for', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app', provider: 'shell' })
    expect(ok(resolution).notices).toEqual([])
  })
})

describe('resolveStart — profile', () => {
  it('prefers this session’s choice', () => {
    const resolution = resolveStart(context({ defaultProfileId: 'system' }), {
      projectPath: '/w/app',
      profileId: 'work',
    })
    expect(ok(resolution).request.profileId).toBe('work')
  })

  it('falls back to the project’s remembered profile', () => {
    const resolution = resolveStart(
      context({ memory: { '/w/app': { profileId: 'work' } }, defaultProfileId: 'system' }),
      { projectPath: '/w/app' },
    )
    expect(ok(resolution).request.profileId).toBe('work')
  })

  it('falls back to the resolved global default', () => {
    const resolution = resolveStart(context({ defaultProfileId: 'work' }), { projectPath: '/w/app' })
    expect(ok(resolution).request.profileId).toBe('work')
  })

  it('ends on the system profile when nothing else resolves', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app' })
    expect(ok(resolution).request.profileId).toBe('system')
  })

  it('falls through a profile that has since been deleted', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app', profileId: 'gone' })
    const { request, notices } = ok(resolution)
    expect(request.profileId).toBe('system')
    expect(notices.map((n) => n.code)).toEqual(['profile-missing'])
  })

  it('carries no profile for an agent that cannot be isolated', () => {
    const resolution = resolveStart(context(), {
      projectPath: '/w/app',
      provider: 'codex',
      profileId: 'work',
    })
    const { request, notices } = ok(resolution)
    // Null, not 'work': claiming a profile applied when nothing was redirected
    // is the exact lie the profiles feature exists to prevent.
    expect(request.profileId).toBeNull()
    expect(notices.map((n) => n.code)).toEqual(['profile-not-applicable'])
  })

  it('says nothing about profiles when none was asked for', () => {
    const resolution = resolveStart(context(), { projectPath: '/w/app', provider: 'shell' })
    expect(ok(resolution).notices).toEqual([])
  })

  it('resolves to nothing when there are no profiles at all', () => {
    const resolution = resolveStart(context({ profiles: [] }), { projectPath: '/w/app' })
    expect(ok(resolution).request.profileId).toBeNull()
  })

  it('does not promise a default login when the chain ended on nothing', () => {
    const resolution = resolveStart(context({ profiles: [] }), {
      projectPath: '/w/app',
      profileId: 'gone',
    })
    const { request, notices } = ok(resolution)
    expect(request.profileId).toBeNull()
    expect(notices.map((n) => n.code)).toEqual(['profile-missing'])
    // Naming a fallback that was not applied is the one thing this notice
    // cannot do — it exists to say what actually happened.
    expect(notices[0].message).not.toContain('using the default login')
  })
})

describe('resolveStart — geometry and prompt', () => {
  it('uses the app’s default terminal size', () => {
    const { request } = ok(resolveStart(context(), { projectPath: '/w/app' }))
    expect([request.cols, request.rows]).toEqual([DEFAULT_COLS, DEFAULT_ROWS])
  })

  it('takes the caller’s size when it has measured one', () => {
    const { request } = ok(resolveStart(context({ cols: 160, rows: 48 }), { projectPath: '/w/app' }))
    expect([request.cols, request.rows]).toEqual([160, 48])
  })

  it('carries an empty prompt as an empty string, never undefined', () => {
    const { request } = ok(resolveStart(context(), { projectPath: '/w/app' }))
    expect(request.firstPrompt).toBe('')
    expect(request.title).toBeNull()
  })

  it('titles the session from the prompt it will send', () => {
    const { request } = ok(
      resolveStart(context(), { projectPath: '/w/app', firstPrompt: 'Fix the login redirect loop' }),
    )
    expect(request.title).toBe('Fix the login redirect loop')
  })
})

describe('normalizeFirstPrompt', () => {
  it('collapses line breaks, because Enter is submit in an agent TUI', () => {
    expect(normalizeFirstPrompt('first line\nsecond line')).toBe('first line second line')
  })

  it('strips escape sequences rather than sending them to the terminal', () => {
    expect(normalizeFirstPrompt('hello\u001b[31mworld')).toBe('hello[31mworld')
  })

  it('strips tabs, which are completion rather than text', () => {
    expect(normalizeFirstPrompt('run\tthe tests')).toBe('runthe tests')
  })

  it('trims and collapses runs of whitespace', () => {
    expect(normalizeFirstPrompt('  ship   it  ')).toBe('ship it')
  })

  it('leaves an empty prompt empty', () => {
    expect(normalizeFirstPrompt('\r\n \t')).toBe('')
  })
})

describe('titleFromFirstPrompt', () => {
  it('uses the prompt as written when it fits', () => {
    expect(titleFromFirstPrompt('Add a retry to the upload')).toBe('Add a retry to the upload')
  })

  it('cuts a long prompt on a word boundary', () => {
    const title = titleFromFirstPrompt(
      'Rewrite the deployment pipeline so that staging and production share one manifest',
    )
    expect(title).not.toBeNull()
    expect(title?.length).toBeLessThanOrEqual(40)
    expect(title?.endsWith('…')).toBe(true)
  })

  it('refuses a slash command — the folder name says more', () => {
    expect(titleFromFirstPrompt('/model opus')).toBeNull()
  })

  it('refuses something too short to mean anything', () => {
    expect(titleFromFirstPrompt('hi')).toBeNull()
  })

  it('honours a narrower budget', () => {
    expect(titleFromFirstPrompt('Fix the login redirect loop', 12)?.length).toBeLessThanOrEqual(12)
  })
})

describe('initialSessionTitle', () => {
  function request(overrides: Partial<SpawnRequest> = {}): SpawnRequest {
    return {
      cwd: '/Users/apple/Projects/pawl',
      provider: 'claude',
      resume: false,
      profileId: 'system',
      cols: DEFAULT_COLS,
      rows: DEFAULT_ROWS,
      firstPrompt: '',
      title: null,
      ...overrides,
    }
  }

  it('reports the prompt as the source when there is one', () => {
    expect(initialSessionTitle(request({ title: 'Fix the flaky test' }))).toEqual({
      title: 'Fix the flaky test',
      source: 'prompt',
    })
  })

  it('falls back to the folder name, exactly as the tab bar already does', () => {
    expect(initialSessionTitle(request())).toEqual({ title: 'pawl', source: 'folder' })
  })

  it('never hands back a blank label for a session with no cwd', () => {
    expect(initialSessionTitle(request({ cwd: '' })).title).not.toBe('')
  })
})

describe('parseStartMemory', () => {
  it('reads a stored JSON string', () => {
    const memory = parseStartMemory(
      JSON.stringify({ '/w/app': { provider: 'codex', profileId: 'work', resume: true } }),
      KNOWN,
    )
    expect(memory['/w/app']).toEqual({ provider: 'codex', profileId: 'work', resume: true })
  })

  it('survives a blob that is not JSON at all', () => {
    expect(parseStartMemory('{not json', KNOWN)).toEqual({})
  })

  it('survives a null, an array and a number', () => {
    expect(parseStartMemory(null, KNOWN)).toEqual({})
    expect(parseStartMemory([1, 2], KNOWN)).toEqual({})
    expect(parseStartMemory(7, KNOWN)).toEqual({})
  })

  it('drops a provider it does not have in the catalogue', () => {
    const memory = parseStartMemory({ '/w/app': { provider: 'kimi', resume: true } }, KNOWN)
    expect(memory['/w/app']).toEqual({ resume: true })
  })

  it('drops fields of the wrong type instead of the whole entry', () => {
    const memory = parseStartMemory({ '/w/app': { profileId: 12, resume: 'yes' } }, KNOWN)
    expect(memory['/w/app']).toEqual({})
  })

  it('skips a blank key', () => {
    expect(parseStartMemory({ '': { resume: true } }, KNOWN)).toEqual({})
  })

  // The blob is whatever is in localStorage — devtools-editable, and corruptible.
  // `JSON.parse` produces a real own `__proto__` property, so a plain
  // `memory[key] = entry` hit the setter and swapped the prototype of the map
  // being built: the entry vanished, and every unrelated property lookup on the
  // result started answering out of the stored object instead.
  it('stores a __proto__ key as an own property rather than the prototype', () => {
    const memory = parseStartMemory('{"__proto__":{"provider":"codex","resume":true}}', KNOWN)
    expect(Object.getPrototypeOf(memory)).toBe(Object.prototype)
    expect(Object.hasOwn(memory, '__proto__')).toBe(true)
    // Nothing leaks onto an unrelated lookup.
    expect((memory as Record<string, unknown>).provider).toBeUndefined()
  })

  it('does not let a __proto__ entry answer for another project', () => {
    const memory = parseStartMemory('{"__proto__":{"provider":"codex"}}', KNOWN)
    expect(projectDefaultsFor(memory, '/w/app')).toEqual({})
    expect(ok(resolveStart(context({ memory }), { projectPath: '/w/app' })).request.provider).toBe(
      'claude',
    )
  })
})

describe('projectDefaultsFor', () => {
  const memory: StartMemory = { '/w/app': { provider: 'codex' } }

  it('finds an exact hit', () => {
    expect(projectDefaultsFor(memory, '/w/app').provider).toBe('codex')
  })

  it('finds a path spelled differently', () => {
    expect(projectDefaultsFor(memory, '/w/lib/../app/').provider).toBe('codex')
  })

  it('returns nothing for an unknown project', () => {
    expect(projectDefaultsFor(memory, '/w/other')).toEqual({})
  })

  it('does not read a project called __proto__ off the prototype chain', () => {
    expect(projectDefaultsFor({}, '__proto__')).toEqual({})
  })

  it('is safe with no memory at all', () => {
    expect(projectDefaultsFor(undefined, '/w/app')).toEqual({})
  })
})

describe('rememberStart', () => {
  const request: SpawnRequest = {
    cwd: '/w/app/',
    provider: 'codex',
    resume: true,
    profileId: 'work',
    cols: DEFAULT_COLS,
    rows: DEFAULT_ROWS,
    firstPrompt: '',
    title: null,
  }

  it('stores the choice under the normalised path', () => {
    expect(rememberStart({}, request)).toEqual({
      '/w/app': { provider: 'codex', profileId: 'work', resume: true },
    })
  })

  it('replaces an entry stored under a different spelling of the same path', () => {
    const next = rememberStart({ '/w//app': { provider: 'claude' } }, request)
    expect(Object.keys(next)).toEqual(['/w/app'])
  })

  it('leaves other projects alone', () => {
    const next = rememberStart({ '/w/other': { provider: 'claude' } }, request)
    expect(next['/w/other']).toEqual({ provider: 'claude' })
  })

  it('does not mutate the memory it was given', () => {
    const before: StartMemory = {}
    rememberStart(before, request)
    expect(before).toEqual({})
  })

  // Nothing pruned this before, so the blob grew for the life of the install.
  // The cost is not the bytes: `writeStartMemory` swallows a quota error by
  // design, so the first write that overflowed would freeze the memory
  // permanently and every later session would resolve against stale defaults.
  it('stops growing once it has remembered enough projects', () => {
    let memory: StartMemory = {}
    for (let i = 0; i < MAX_REMEMBERED_PROJECTS + 25; i += 1) {
      memory = rememberStart(memory, { ...request, cwd: `/w/app-${i}` })
    }
    expect(Object.keys(memory)).toHaveLength(MAX_REMEMBERED_PROJECTS)
  })

  it('drops the least recently started project, never the newest', () => {
    let memory: StartMemory = {}
    for (let i = 0; i < MAX_REMEMBERED_PROJECTS + 1; i += 1) {
      memory = rememberStart(memory, { ...request, cwd: `/w/app-${i}` })
    }
    expect(Object.hasOwn(memory, '/w/app-0')).toBe(false)
    expect(Object.hasOwn(memory, `/w/app-${MAX_REMEMBERED_PROJECTS}`)).toBe(true)
  })

  it('re-remembering a known project evicts nothing', () => {
    let memory: StartMemory = {}
    for (let i = 0; i < MAX_REMEMBERED_PROJECTS; i += 1) {
      memory = rememberStart(memory, { ...request, cwd: `/w/app-${i}` })
    }
    const again = rememberStart(memory, { ...request, cwd: '/w/app-0' })
    expect(Object.keys(again)).toHaveLength(MAX_REMEMBERED_PROJECTS)
    expect(Object.hasOwn(again, '/w/app-0')).toBe(true)
  })

  it('stores a project literally called __proto__ without touching the prototype', () => {
    const next = rememberStart({}, { ...request, cwd: '__proto__' })
    expect(Object.getPrototypeOf(next)).toBe(Object.prototype)
    expect(Object.hasOwn(next, '__proto__')).toBe(true)
  })

  it('round-trips into a resolution', () => {
    const memory = rememberStart({}, request)
    const resolution = resolveStart(context({ memory }), { projectPath: '/w/app' })
    const { request: next } = ok(resolution)
    expect([next.provider, next.resume, next.profileId]).toEqual(['codex', true, null])
    // codex cannot be isolated, so the remembered profile is honestly dropped.
  })
})

describe('fallbackProfileId and firstAvailableProvider', () => {
  it('prefers the profile flagged as the user’s own install', () => {
    expect(fallbackProfileId([{ id: 'work', name: 'Work' }, ...PROFILES])).toBe('system')
  })

  it('takes the first profile when none is flagged', () => {
    expect(fallbackProfileId([{ id: 'work', name: 'Work' }])).toBe('work')
  })

  it('has nothing to fall back to in an empty list', () => {
    expect(fallbackProfileId([])).toBeNull()
  })

  it('finds the first installed provider in catalogue order', () => {
    const rows = [provider('claude', { available: false }), provider('codex'), provider('shell')]
    expect(firstAvailableProvider(rows)?.id).toBe('codex')
  })

  it('finds nothing when nothing is installed', () => {
    expect(firstAvailableProvider(KNOWN.map((id) => provider(id, { available: false })))).toBeNull()
  })
})
