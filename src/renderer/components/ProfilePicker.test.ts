import { afterEach, describe, expect, it } from 'vitest'
import {
  isolationNotice,
  normalizeProjectKey,
  parseInitialized,
  parseProfile,
  parseSnapshot,
  profileBadges,
  profileBridge,
  projectDefaultFor,
  type ProfileView,
  type SnapshotView,
} from './ProfilePicker'

/**
 * Everything crossing the bridge arrives as `unknown`, so these are the tests
 * that matter for this component: a malformed record must be dropped rather
 * than rendered as a nameless row that starts a session under nobody knows
 * which account.
 *
 * The component itself is not rendered here — this project has no DOM
 * environment installed, so renderer tests cover exported logic only.
 */

function view(overrides: Partial<ProfileView> = {}): ProfileView {
  return {
    id: 'work',
    name: 'Work',
    configDir: '/u/Library/Application Support/pawl/profiles/work',
    system: false,
    color: '--accent',
    lastUsedAt: null,
    ...overrides,
  }
}

function snapshot(overrides: Partial<SnapshotView> = {}): SnapshotView {
  return { profiles: [], defaultProfileId: null, projectDefaults: {}, ...overrides }
}

describe('parseProfile', () => {
  it('accepts a well-formed record', () => {
    expect(parseProfile({ id: 'work', name: 'Work', configDir: '/tmp/work', system: false })).toEqual(
      view({ configDir: '/tmp/work' }),
    )
  })

  it('rejects records missing the fields a row needs', () => {
    expect(parseProfile(null)).toBeNull()
    expect(parseProfile('work')).toBeNull()
    expect(parseProfile({ name: 'Work', configDir: '/tmp' })).toBeNull()
    expect(parseProfile({ id: 'work', configDir: '/tmp' })).toBeNull()
    expect(parseProfile({ id: 'work', name: 'Work' })).toBeNull()
    expect(parseProfile({ id: '', name: 'Work', configDir: '/tmp' })).toBeNull()
  })

  it('falls back to the accent token for a colour it cannot use', () => {
    // The value is interpolated into `var(...)`, so anything that is not a
    // custom property name would produce invalid CSS rather than a wrong hue.
    expect(parseProfile({ id: 'a', name: 'A', configDir: '/t', color: 'red' })?.color).toBe('--accent')
    expect(parseProfile({ id: 'a', name: 'A', configDir: '/t', color: '#ff0000' })?.color).toBe('--accent')
    expect(parseProfile({ id: 'a', name: 'A', configDir: '/t', color: '--status-completed' })?.color).toBe(
      '--status-completed',
    )
  })
})

describe('parseSnapshot', () => {
  it('drops malformed profiles but keeps the rest', () => {
    const parsed = parseSnapshot({
      profiles: [{ id: 'a', name: 'A', configDir: '/t' }, null, { name: 'broken' }],
      defaultProfileId: 'a',
      projectDefaults: { '/w/app': 'a', '/w/other': 7 },
    })

    expect(parsed.profiles.map((p) => p.id)).toEqual(['a'])
    expect(parsed.defaultProfileId).toBe('a')
    expect(parsed.projectDefaults).toEqual({ '/w/app': 'a' })
  })

  it('survives a response of the wrong shape entirely', () => {
    expect(parseSnapshot(undefined)).toEqual(snapshot())
    expect(parseSnapshot('nope')).toEqual(snapshot())
    expect(parseSnapshot({ profiles: 'nope' })).toEqual(snapshot())
  })
})

describe('parseInitialized', () => {
  it('claims initialized only on an explicit true', () => {
    expect(parseInitialized({ initialized: true })).toBe(true)
    expect(parseInitialized({ initialized: 'yes' })).toBe(false)
    expect(parseInitialized(null)).toBe(false)
  })
})

describe('profileBadges', () => {
  const system = view({ id: 'system', name: 'Default', system: true })

  it('marks the system profile as default while no global default is set', () => {
    expect(profileBadges(system, snapshot(), null, undefined)).toEqual(['Default'])
  })

  it('moves the default badge once a global default exists', () => {
    const state = snapshot({ defaultProfileId: 'work' })
    expect(profileBadges(system, state, null, undefined)).toEqual([])
    expect(profileBadges(view(), state, null, undefined)).toEqual(['Default'])
  })

  it('marks the project default, which can differ from the global one', () => {
    const state = snapshot({ defaultProfileId: 'personal' })
    expect(profileBadges(view(), state, 'work', undefined)).toEqual(['This project'])
  })

  it('shows both badges when one profile is each', () => {
    const state = snapshot({ defaultProfileId: 'work' })
    expect(profileBadges(view(), state, 'work', undefined)).toEqual(['This project', 'Default'])
  })

  it('flags an unused profile only when the status is actually known', () => {
    expect(profileBadges(view(), snapshot(), null, false)).toContain('Never used')
    // undefined means the status call failed — claiming "never used" then would
    // be inventing a fact about the user's account.
    expect(profileBadges(view(), snapshot(), null, undefined)).not.toContain('Never used')
    expect(profileBadges(view(), snapshot(), null, true)).not.toContain('Never used')
  })

  it('never calls the user own install unused', () => {
    expect(profileBadges(system, snapshot(), null, false)).not.toContain('Never used')
  })
})

describe('normalizeProjectKey', () => {
  it('collapses the ways one folder gets written', () => {
    expect(normalizeProjectKey('/w/app')).toBe('/w/app')
    expect(normalizeProjectKey('/w/app/')).toBe('/w/app')
    expect(normalizeProjectKey('/w//app///')).toBe('/w/app')
    expect(normalizeProjectKey('/w/./app')).toBe('/w/app')
    expect(normalizeProjectKey('/w/other/../app')).toBe('/w/app')
  })

  it('does not climb above a root', () => {
    expect(normalizeProjectKey('/..')).toBe('/')
    expect(normalizeProjectKey('/../..')).toBe('/')
    expect(normalizeProjectKey('/w/../../app')).toBe('/app')
  })

  it('keeps a relative path relative rather than inventing a cwd', () => {
    // The renderer has no cwd to resolve against, and guessing one would turn a
    // missing default into a confidently wrong one.
    expect(normalizeProjectKey('w/app')).toBe('w/app')
    expect(normalizeProjectKey('../app')).toBe('../app')
    expect(normalizeProjectKey('')).toBe('')
  })

  it('leaves a Windows path in Windows separators', () => {
    expect(normalizeProjectKey('C:\\w\\app\\')).toBe('C:\\w\\app')
    expect(normalizeProjectKey('\\\\?\\C:\\w')).toBe('\\?\\C:\\w')
  })
})

describe('projectDefaultFor', () => {
  it('finds the default however the path was written', () => {
    // Regression: the main process canonicalises keys with path.resolve and the
    // renderer compared raw strings, so a trailing slash silently dropped the
    // "This project" badge and the dialog claimed the folder had no default.
    const defaults = { '/w/app': 'work' }
    expect(projectDefaultFor(defaults, '/w/app')).toBe('work')
    expect(projectDefaultFor(defaults, '/w/app/')).toBe('work')
    expect(projectDefaultFor(defaults, '/w/other/../app')).toBe('work')
    expect(projectDefaultFor(defaults, '/w//app')).toBe('work')
  })

  it('returns null when the project genuinely has no default', () => {
    expect(projectDefaultFor({ '/w/app': 'work' }, '/w/elsewhere')).toBeNull()
    expect(projectDefaultFor({}, '/w/app')).toBeNull()
    expect(projectDefaultFor({ '/w/app': 'work' }, null)).toBeNull()
    expect(projectDefaultFor({ '/w/app': 'work' }, '')).toBeNull()
  })

  it('does not mistake an inherited property for a stored default', () => {
    // A bare object lookup reaches Object.prototype, and `constructor` would
    // come back as a function rather than a miss.
    expect(projectDefaultFor({}, 'constructor')).toBeNull()
    expect(projectDefaultFor({}, 'toString')).toBeNull()
    expect(projectDefaultFor({}, '__proto__')).toBeNull()
  })
})

describe('isolationNotice', () => {
  it('stays quiet for Claude, which is the only agent profiles apply to', () => {
    expect(isolationNotice('claude')).toBeNull()
    expect(isolationNotice(undefined)).toBeNull()
  })

  it('explains itself for every other agent', () => {
    expect(isolationNotice('shell')).toMatch(/no login to isolate/)
    expect(isolationNotice('codex')).toMatch(/only apply to Claude/)
    expect(isolationNotice('gemini')).toMatch(/only apply to Claude/)
  })
})

describe('profileBridge', () => {
  afterEach(() => {
    delete (globalThis as { pawl?: unknown }).pawl
  })

  it('is null until the preload bridge exposes the profile methods', () => {
    expect(profileBridge()).toBeNull()
    ;(globalThis as { pawl?: unknown }).pawl = {}
    expect(profileBridge()).toBeNull()
  })

  it('is available once listProfiles is wired', () => {
    const api = { listProfiles: () => Promise.resolve({}) }
    ;(globalThis as { pawl?: unknown }).pawl = api
    expect(profileBridge()).toBe(api)
  })
})
