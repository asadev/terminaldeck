import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  canonicalProjectKey,
  createProfile,
  deleteProfile,
  findProfile,
  getState,
  isManagedConfigDir,
  isProtectedDir,
  listProfiles,
  markProfileUsed,
  normalizeProfileName,
  profileStatus,
  profileTranscriptDir,
  PROFILE_COLORS,
  renameProfile,
  resetProfilesCache,
  resolveProfile,
  resolveProfileId,
  sanitizeState,
  sessionEnv,
  setGlobalDefault,
  setProjectDefault,
  slugifyProfileId,
  supportsProfiles,
  systemProfile,
  uniqueProfileId,
  SYSTEM_PROFILE_ID,
  type Profile,
  type ProfilesState,
} from './profiles'

/**
 * The precedence chain is the part worth testing hardest: it decides which
 * account a session runs as, and getting it wrong means work commits land on a
 * personal login. Every level is also tested for the *stale* case — a deleted
 * profile must fall through rather than throw or resolve to nothing.
 *
 * The other half is deletion. `~/.claude` is the user's real install and this
 * module must never be able to remove it, however mangled its state file gets.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-profiles-test-${process.pid}`)

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return { app: { getPath: () => j(tmp(), `terminaldeck-profiles-test-${process.pid}`) } }
})

beforeEach(() => {
  rmSync(USER_DATA, { recursive: true, force: true })
  mkdirSync(USER_DATA, { recursive: true })
  resetProfilesCache()
})

afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

/* ----------------------------------------------------------- pure state -- */

function profile(id: string, overrides: Partial<Profile> = {}): Profile {
  return {
    id,
    name: id,
    configDir: join(USER_DATA, 'profiles', id),
    system: false,
    color: PROFILE_COLORS[0],
    createdAt: 1,
    lastUsedAt: null,
    ...overrides,
  }
}

function state(overrides: Partial<ProfilesState> = {}): ProfilesState {
  return {
    version: 1,
    profiles: [profile('work'), profile('personal')],
    defaultProfileId: null,
    projectDefaults: {},
    ...overrides,
  }
}

describe('resolution precedence', () => {
  it('prefers the session choice over both defaults', () => {
    const s = state({
      defaultProfileId: 'personal',
      projectDefaults: { [canonicalProjectKey('/w/app')]: 'personal' },
    })
    expect(resolveProfileId(s, { sessionProfileId: 'work', projectPath: '/w/app' })).toBe('work')
  })

  it('prefers the project default over the global one', () => {
    const s = state({
      defaultProfileId: 'personal',
      projectDefaults: { [canonicalProjectKey('/w/app')]: 'work' },
    })
    expect(resolveProfileId(s, { projectPath: '/w/app' })).toBe('work')
  })

  it('uses the global default when the project has none', () => {
    const s = state({ defaultProfileId: 'personal' })
    expect(resolveProfileId(s, { projectPath: '/w/other' })).toBe('personal')
  })

  it('falls back to the system profile when nothing is configured', () => {
    expect(resolveProfileId(state())).toBe(SYSTEM_PROFILE_ID)
    expect(resolveProfileId(state(), { projectPath: '/w/app' })).toBe(SYSTEM_PROFILE_ID)
  })

  it('falls through a session id whose profile has been deleted', () => {
    const s = state({
      defaultProfileId: 'personal',
      projectDefaults: { [canonicalProjectKey('/w/app')]: 'work' },
    })
    expect(resolveProfileId(s, { sessionProfileId: 'gone', projectPath: '/w/app' })).toBe('work')
  })

  it('falls through a project default whose profile has been deleted', () => {
    const s = state({
      defaultProfileId: 'personal',
      projectDefaults: { [canonicalProjectKey('/w/app')]: 'gone' },
    })
    expect(resolveProfileId(s, { projectPath: '/w/app' })).toBe('personal')
  })

  it('falls through a global default whose profile has been deleted', () => {
    const s = state({ defaultProfileId: 'gone' })
    expect(resolveProfileId(s, { projectPath: '/w/app' })).toBe(SYSTEM_PROFILE_ID)
  })

  it('matches a project default however the path was written', () => {
    const s = state({ projectDefaults: { [canonicalProjectKey('/w/app')]: 'work' } })
    expect(resolveProfileId(s, { projectPath: '/w/app/' })).toBe('work')
    expect(resolveProfileId(s, { projectPath: '/w/app/../app' })).toBe('work')
  })

  it('treats an empty or null session choice as no choice', () => {
    const s = state({ defaultProfileId: 'personal' })
    expect(resolveProfileId(s, { sessionProfileId: '' })).toBe('personal')
    expect(resolveProfileId(s, { sessionProfileId: null })).toBe('personal')
  })

  it('lets the system profile be selected explicitly at any level', () => {
    const s = state({ defaultProfileId: 'personal' })
    expect(resolveProfileId(s, { sessionProfileId: SYSTEM_PROFILE_ID })).toBe(SYSTEM_PROFILE_ID)
  })

  it('resolves to a whole profile, system included', () => {
    const s = state({ defaultProfileId: 'work' })
    expect(resolveProfile(s).id).toBe('work')
    expect(resolveProfile(state()).system).toBe(true)
  })
})

/* ------------------------------------------------------------- sanitize -- */

describe('sanitizeState', () => {
  it('returns an empty state for junk', () => {
    expect(sanitizeState(null).profiles).toEqual([])
    expect(sanitizeState('nope').profiles).toEqual([])
    expect(sanitizeState({ profiles: 'no' }).profiles).toEqual([])
  })

  it('refuses a persisted profile claiming to be the system one', () => {
    const raw = { profiles: [{ ...profile(SYSTEM_PROFILE_ID) }, profile('work')] }
    const clean = sanitizeState(raw)
    expect(clean.profiles.map((p) => p.id)).toEqual(['work'])
  })

  it('never trusts a persisted `system: true` flag', () => {
    const clean = sanitizeState({ profiles: [profile('work', { system: true })] })
    expect(clean.profiles[0].system).toBe(false)
  })

  it('drops defaults pointing at profiles that no longer exist', () => {
    const clean = sanitizeState({
      profiles: [profile('work')],
      defaultProfileId: 'gone',
      projectDefaults: { '/w/app': 'gone', '/w/other': 'work' },
    })
    expect(clean.defaultProfileId).toBeNull()
    expect(clean.projectDefaults).toEqual({ [canonicalProjectKey('/w/other')]: 'work' })
  })

  it('keeps the system id as a legal default target', () => {
    const clean = sanitizeState({ profiles: [], defaultProfileId: SYSTEM_PROFILE_ID })
    expect(clean.defaultProfileId).toBe(SYSTEM_PROFILE_ID)
  })

  it('canonicalises project keys on load', () => {
    const clean = sanitizeState({
      profiles: [profile('work')],
      projectDefaults: { '/w/app/': 'work' },
    })
    expect(Object.keys(clean.projectDefaults)).toEqual([canonicalProjectKey('/w/app')])
  })

  it('drops duplicate ids rather than shadowing one with the other', () => {
    const clean = sanitizeState({ profiles: [profile('work'), profile('work', { name: 'Other' })] })
    expect(clean.profiles).toHaveLength(1)
  })
})

/* ------------------------------------------------------------------ env -- */

describe('sessionEnv', () => {
  it('isolates a custom profile with CLAUDE_CONFIG_DIR', () => {
    const p = profile('work')
    expect(sessionEnv(p, 'claude')).toEqual({ CLAUDE_CONFIG_DIR: p.configDir })
  })

  it('sets nothing for the system profile', () => {
    // Not an oversight. Verified against the real CLI: with
    // CLAUDE_CONFIG_DIR=$HOME/.claude it looks for ~/.claude/.claude.json,
    // while a default install keeps its config at ~/.claude.json — so setting
    // the variable to its own default path breaks the user's normal login.
    expect(sessionEnv(systemProfile(), 'claude')).toEqual({})
  })

  it('sets nothing for providers whose config variable is unverified', () => {
    const p = profile('work')
    expect(sessionEnv(p, 'codex')).toEqual({})
    expect(sessionEnv(p, 'gemini')).toEqual({})
    expect(sessionEnv(p, 'shell')).toEqual({})
  })

  it('reports which providers can be isolated at all', () => {
    expect(supportsProfiles('claude')).toBe(true)
    expect(supportsProfiles('codex')).toBe(false)
    expect(supportsProfiles('shell')).toBe(false)
  })
})

describe('profileTranscriptDir', () => {
  it('points at the profile config dir, not the default install', () => {
    const p = profile('work')
    const dir = profileTranscriptDir(p, '/Users/asad/Projects/terminaldeck')
    // Claude Code writes transcripts to <configDir>/projects/<encoded-cwd>,
    // so a profiled session's cost data is not under ~/.claude at all.
    expect(dir).toBe(join(p.configDir, 'projects', '-Users-asad-Projects-terminaldeck'))
  })
})

/* --------------------------------------------------------------- naming -- */

describe('naming', () => {
  it('slugs a name into something safe to use as a directory', () => {
    expect(slugifyProfileId('Work Account')).toBe('work-account')
    expect(slugifyProfileId('  Personal  ')).toBe('personal')
    expect(slugifyProfileId('../../etc')).toBe('etc')
  })

  it('never slugs to an empty directory name', () => {
    // '' would resolve to the profiles root itself, which a delete would then
    // be handed.
    expect(slugifyProfileId('!!!')).toBe('profile')
    expect(slugifyProfileId('')).toBe('profile')
  })

  it('uniquifies a taken id and never hands back the system id', () => {
    expect(uniqueProfileId('work', new Set(['work']))).toBe('work-2')
    expect(uniqueProfileId('work', new Set(['work', 'work-2']))).toBe('work-3')
    expect(uniqueProfileId(SYSTEM_PROFILE_ID, new Set())).toBe(`${SYSTEM_PROFILE_ID}-2`)
  })

  it('trims and collapses whitespace, and rejects empty or overlong names', () => {
    expect(normalizeProfileName('  Work   Account ')).toBe('Work Account')
    expect(() => normalizeProfileName('   ')).toThrow(/needs a name/)
    expect(() => normalizeProfileName('x'.repeat(61))).toThrow(/60 characters/)
    expect(() => normalizeProfileName(42)).toThrow(/needs a name/)
  })

  it('strips control and bidi characters from a name', () => {
    // Regression: NUL is not whitespace, so it survived both trim() and \s+,
    // and a bidi override let a name render in the picker as something other
    // than what it is. The picker's one job is to show honestly which account
    // is selected, so the name must be what it appears to be.
    expect(normalizeProfileName('Work\u0000Account')).toBe('Work Account')
    expect(normalizeProfileName('Work \u202Egro.exe')).toBe('Work gro.exe')
    expect(normalizeProfileName('a\u200Bb')).toBe('a b')
    expect(normalizeProfileName('Work\nAccount')).toBe('Work Account')
    expect(() => normalizeProfileName('\u0000\u202E')).toThrow(/needs a name/)
    // Ordinary non-ASCII is left alone — plenty of people name things in it.
    expect(normalizeProfileName('Работа')).toBe('Работа')
  })
})

/* ------------------------------------------------------------- deletion -- */

describe('deletion safety', () => {
  it('recognises only directories this app created', () => {
    const root = join(USER_DATA, 'profiles')
    expect(isManagedConfigDir(join(root, 'work'), root)).toBe(true)
    expect(isManagedConfigDir(join(root, 'work', 'nested'), root)).toBe(true)
    expect(isManagedConfigDir(root, root)).toBe(false)
    expect(isManagedConfigDir(join(homedir(), '.claude'), root)).toBe(false)
    expect(isManagedConfigDir(join(root, '..', 'boards'), root)).toBe(false)
    expect(isManagedConfigDir('relative/path', root)).toBe(false)
    expect(isManagedConfigDir('', root)).toBe(false)
  })

  it('treats the home directory and the real claude config as untouchable', () => {
    expect(isProtectedDir(homedir())).toBe(true)
    expect(isProtectedDir(join(homedir(), '.claude'))).toBe(true)
    expect(isProtectedDir('/')).toBe(true)
    expect(isProtectedDir(join(USER_DATA, 'profiles', 'work'))).toBe(false)
  })

  it('refuses to delete the system profile', () => {
    expect(() => deleteProfile(SYSTEM_PROFILE_ID)).toThrow(/cannot be deleted/)
    expect(listProfiles().some((p) => p.system)).toBe(true)
  })

  it('removes a managed directory when asked', () => {
    const created = createProfile('Work')
    expect(existsSync(created.configDir)).toBe(true)
    const result = deleteProfile(created.id, { deleteFiles: true })
    expect(result.filesDeleted).toBe(true)
    expect(existsSync(created.configDir)).toBe(false)
  })

  it('leaves an adopted directory alone even when asked to delete it', () => {
    // The user pointed a profile at a config dir they already had. Removing it
    // would destroy data this app never created.
    const adopted = join(USER_DATA, 'pre-existing-claude')
    mkdirSync(adopted, { recursive: true })
    writeFileSync(join(adopted, '.claude.json'), '{}', 'utf8')

    const created = createProfile('Adopted', { configDir: adopted })
    const result = deleteProfile(created.id, { deleteFiles: true })

    expect(result.removed).toBe(true)
    expect(result.filesDeleted).toBe(false)
    expect(existsSync(join(adopted, '.claude.json'))).toBe(true)
  })

  it('keeps the directory by default', () => {
    const created = createProfile('Work')
    deleteProfile(created.id)
    expect(existsSync(created.configDir)).toBe(true)
  })

  it('reports that the login survives the profile', () => {
    // Credentials are in the OS keychain, keyed off the config dir path — not
    // in the directory — so deleting files does not sign the profile out.
    const created = createProfile('Work')
    expect(deleteProfile(created.id, { deleteFiles: true }).credentialsRetained).toBe(true)
  })

  it('clears every default that pointed at the deleted profile', () => {
    const created = createProfile('Work')
    setGlobalDefault(created.id)
    setProjectDefault('/w/app', created.id)

    deleteProfile(created.id)
    const after = getState()

    expect(after.defaultProfileId).toBeNull()
    expect(after.projectDefaults).toEqual({})
    expect(resolveProfileId(after, { projectPath: '/w/app' })).toBe(SYSTEM_PROFILE_ID)
  })
})

/* ------------------------------------------------------------------ crud -- */

describe('crud', () => {
  it('creates a profile with its own directory under userData', () => {
    const created = createProfile('Work Account')
    expect(created.id).toBe('work-account')
    expect(created.configDir).toBe(join(USER_DATA, 'profiles', 'work-account'))
    expect(existsSync(created.configDir)).toBe(true)
    expect(created.system).toBe(false)
  })

  it('lists the system profile first', () => {
    createProfile('Work')
    const listed = listProfiles()
    expect(listed[0].system).toBe(true)
    expect(listed.map((p) => p.name)).toEqual(['Default', 'Work'])
  })

  it('refuses a duplicate name, whatever its case', () => {
    createProfile('Work')
    expect(() => createProfile('work')).toThrow(/already exists/)
    expect(() => createProfile('Default')).toThrow(/already exists/)
  })

  it('gives each profile a distinct colour until the palette runs out', () => {
    const a = createProfile('One')
    const b = createProfile('Two')
    expect(a.color).not.toBe(b.color)
  })

  it('persists across a reload', () => {
    const created = createProfile('Work')
    setProjectDefault('/w/app', created.id)
    resetProfilesCache()

    const reloaded = getState()
    expect(reloaded.profiles.map((p) => p.id)).toEqual([created.id])
    expect(resolveProfileId(reloaded, { projectPath: '/w/app' })).toBe(created.id)
  })

  it('survives a corrupt state file instead of failing to launch', () => {
    writeFileSync(join(USER_DATA, 'profiles.json'), '{ not json', 'utf8')
    resetProfilesCache()
    expect(getState().profiles).toEqual([])
  })

  it('renames, rejecting a clash', () => {
    const created = createProfile('Work')
    createProfile('Personal')
    expect(renameProfile(created.id, 'Day Job').name).toBe('Day Job')
    expect(() => renameProfile(created.id, 'Personal')).toThrow(/already exists/)
    expect(() => renameProfile(SYSTEM_PROFILE_ID, 'Nope')).toThrow(/cannot be renamed/)
  })

  it('keeps the id stable across a rename so project defaults still point at it', () => {
    const created = createProfile('Work')
    setProjectDefault('/w/app', created.id)
    renameProfile(created.id, 'Day Job')
    expect(resolveProfileId(getState(), { projectPath: '/w/app' })).toBe(created.id)
  })

  it('rejects defaults naming a profile that does not exist', () => {
    expect(() => setGlobalDefault('gone')).toThrow(/no profile/)
    expect(() => setProjectDefault('/w/app', 'gone')).toThrow(/no profile/)
    expect(() => setProjectDefault('', null)).toThrow(/project path/)
  })

  it('stores the system default as null so it tracks the fallback', () => {
    setGlobalDefault(SYSTEM_PROFILE_ID)
    expect(getState().defaultProfileId).toBeNull()
  })

  it('clears a project default', () => {
    const created = createProfile('Work')
    setProjectDefault('/w/app', created.id)
    setProjectDefault('/w/app', null)
    expect(getState().projectDefaults).toEqual({})
  })

  it('records last use', () => {
    const created = createProfile('Work')
    expect(created.lastUsedAt).toBeNull()
    markProfileUsed(created.id)
    expect(findProfile(getState(), created.id)?.lastUsedAt).toBeTypeOf('number')
    // A deleted profile is a no-op, not a crash.
    expect(() => markProfileUsed('gone')).not.toThrow()
  })

  it('reports whether a profile has ever been used, without guessing at login', () => {
    const created = createProfile('Work')
    expect(profileStatus(created)).toMatchObject({ exists: true, initialized: false })
    writeFileSync(join(created.configDir, '.claude.json'), '{}', 'utf8')
    expect(profileStatus(created).initialized).toBe(true)
  })

  it('rejects a relative adopted config directory', () => {
    expect(() => createProfile('Bad', { configDir: 'relative' })).toThrow(/absolute/)
  })
})

/* --------------------------------------------------- adopting a directory -- */

describe('adopted config directories', () => {
  it('refuses the user own Claude install', () => {
    // Regression: this used to be allowed, and it is the one configuration the
    // module header warns about — sessionEnv would then export
    // CLAUDE_CONFIG_DIR=$HOME/.claude, which makes the CLI look for
    // ~/.claude/.claude.json while a default install keeps it at ~/.claude.json.
    // Adopting it does not share the login, it breaks it.
    expect(() => createProfile('Mine', { configDir: join(homedir(), '.claude') })).toThrow(
      /your own Claude install/,
    )
    expect(() => createProfile('Home', { configDir: homedir() })).toThrow(/your own Claude install/)
    expect(() => createProfile('Root', { configDir: '/' })).toThrow(/your own Claude install/)
  })

  it('refuses a directory another profile already uses', () => {
    // Same config dir is the same account, so this would put two names in the
    // picker for one login — the confusion the whole feature exists to remove.
    const shared = join(USER_DATA, 'shared-config')
    createProfile('Work', { configDir: shared })
    expect(() => createProfile('Personal', { configDir: shared })).toThrow(
      /"Work" already uses that config directory/,
    )
    expect(() => createProfile('Personal', { configDir: `${shared}/` })).toThrow(/already uses/)
  })

  it('still adopts an ordinary directory the user already had', () => {
    const adopted = join(USER_DATA, 'my-own-claude')
    mkdirSync(adopted, { recursive: true })
    expect(createProfile('Adopted', { configDir: adopted }).configDir).toBe(adopted)
  })
})

/* ------------------------------------------------------ the state file -- */

const STATE_FILE = () => join(USER_DATA, 'profiles.json')
const backups = () => readdirSync(USER_DATA).filter((name) => name.includes('profiles.json.bak-'))

const REAL_STATE = JSON.stringify({
  version: 1,
  profiles: [
    { id: 'work', name: 'Work', configDir: '/tmp/w' },
    { id: 'personal', name: 'Personal', configDir: '/tmp/p' },
  ],
  defaultProfileId: 'work',
  projectDefaults: { '/repo': 'work' },
})

describe('never destroys the state file', () => {
  it('preserves a corrupt file instead of overwriting it', () => {
    // Regression: a truncated file booted as an empty state, and the first
    // write of the session — markProfileUsed fires on every session spawn —
    // replaced the user's only copy with {"profiles": []}.
    writeFileSync(STATE_FILE(), REAL_STATE.slice(0, -20), 'utf8')
    resetProfilesCache()
    expect(getState().profiles).toEqual([])

    createProfile('New')

    expect(backups()).toHaveLength(1)
    const rescued = readFileSync(join(USER_DATA, backups()[0]), 'utf8')
    expect(rescued).toContain('"Work"')
    expect(rescued).toContain('"Personal"')
  })

  it('preserves a valid file that could not be read', () => {
    // EACCES / EMFILE are not corruption. The file is fine and still holds
    // every profile the user has; only this process could not open it.
    writeFileSync(STATE_FILE(), REAL_STATE, 'utf8')
    chmodSync(STATE_FILE(), 0o000)
    resetProfilesCache()
    expect(getState().profiles).toEqual([])

    chmodSync(STATE_FILE(), 0o644)
    createProfile('New')

    expect(backups()).toHaveLength(1)
    expect(readFileSync(join(USER_DATA, backups()[0]), 'utf8')).toContain('"personal"')
  })

  it('keeps unknown top-level keys written by another version', () => {
    // Regression: persist serialised the in-memory state directly, so every
    // key it did not model was dropped on the next write.
    writeFileSync(
      STATE_FILE(),
      JSON.stringify({
        version: 1,
        profiles: [],
        defaultProfileId: null,
        projectDefaults: {},
        telemetryOptOut: true,
        futureFeature: { keep: 'me' },
      }),
      'utf8',
    )
    resetProfilesCache()
    createProfile('Work')

    const written = JSON.parse(readFileSync(STATE_FILE(), 'utf8'))
    expect(written.telemetryOptOut).toBe(true)
    expect(written.futureFeature).toEqual({ keep: 'me' })
    expect(written.profiles).toHaveLength(1)
  })

  it('backs up a file from a newer version before rewriting it', () => {
    // We can carry its unknown keys across, but not whatever it meant by the
    // keys we do parse, so the original stays recoverable.
    writeFileSync(STATE_FILE(), JSON.stringify({ version: 99, profiles: [] }), 'utf8')
    resetProfilesCache()
    createProfile('Work')
    expect(backups()).toHaveLength(1)
  })

  it('does not manufacture a backup on first run', () => {
    // No file is not a lost file. A backup here would be pure noise in the
    // user's application-support folder.
    expect(existsSync(STATE_FILE())).toBe(false)
    resetProfilesCache()
    createProfile('Work')
    expect(backups()).toEqual([])
  })

  it('backs up once, not on every subsequent write', () => {
    writeFileSync(STATE_FILE(), '{ not json', 'utf8')
    resetProfilesCache()
    createProfile('One')
    createProfile('Two')
    setGlobalDefault(null)
    expect(backups()).toHaveLength(1)
  })
})
