import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { createProfile, deleteProfile, profileStatus, resetProfilesCache, slugifyProfileId } from './profiles'

/**
 * The platform half of `profiles.ts`, in its own file so `profiles.test.ts`
 * stays about the precedence chain and the deletion guards.
 *
 * The thing being pinned here is a *claim*, not a mechanism: the module header
 * says two profiles are two logins, and that was established on macOS by
 * reading the Keychain. This checks that the claim is not repeated on a
 * platform where nobody has checked it.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-profiles-win-test-${process.pid}`)

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  return { app: { getPath: () => j(tmp(), `terminaldeck-profiles-win-test-${process.pid}`) } }
})

beforeEach(() => {
  rmSync(USER_DATA, { recursive: true, force: true })
  mkdirSync(USER_DATA, { recursive: true })
  resetProfilesCache()
})

afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

describe('a profile id has to survive a Windows filesystem', () => {
  it('does not hand back an MS-DOS device name', () => {
    // `mkdir con` fails on Windows with EINVAL. The comment above this function
    // has always promised "nothing Windows reserves"; until the port, only the
    // separators and dots were actually handled.
    expect(slugifyProfileId('CON')).toBe('con-profile')
    expect(slugifyProfileId('aux')).toBe('aux-profile')
    expect(slugifyProfileId('LPT1')).toBe('lpt1-profile')
    expect(slugifyProfileId('nul')).toBe('nul-profile')
  })

  it('leaves names that merely start with one alone', () => {
    // Only the exact names are reserved — `console` and `communications` are
    // ordinary directories, and mangling them would be a second bug.
    expect(slugifyProfileId('console')).toBe('console')
    expect(slugifyProfileId('Com10')).toBe('com10')
    expect(slugifyProfileId('Aux Work')).toBe('aux-work')
  })

  it('is applied on every platform, because the state file travels', () => {
    // The id is written into profiles.json and the directory is created from
    // it. A file written on a Mac gets opened on a PC.
    expect(slugifyProfileId('prn')).toBe('prn-profile')
  })
})

describe('what a profile claims about its login', () => {
  it('claims a separate login on macOS, where the Keychain was checked', () => {
    const profile = createProfile('Work')
    const status = profileStatus(profile, 'darwin')
    expect(status.isolation.isolated).toBe(true)
    expect(status.isolation.store).toBe('macos-keychain')
  })

  it('does not claim one on Windows', () => {
    const profile = createProfile('Work')
    const status = profileStatus(profile, 'win32')
    expect(status.isolation.isolated).toBe(false)
    expect(status.isolation.store).toBe('unknown')
    expect(status.isolation.note).toMatch(/unverified on Windows/)
  })

  it('claims one on any platform once the credential is in the directory', () => {
    const profile = createProfile('Work')
    writeFileSync(join(profile.configDir, '.credentials.json'), '{}')
    expect(profileStatus(profile, 'win32').isolation).toMatchObject({
      isolated: true,
      store: 'config-directory',
    })
  })

  it('still reports the fields the picker already reads', () => {
    // Additive change: `exists` and `initialized` are what `ProfilePicker`
    // parses today, and adding a field must not move them.
    const profile = createProfile('Work')
    expect(profileStatus(profile, 'darwin')).toMatchObject({
      id: profile.id,
      exists: true,
      initialized: false,
      configDir: profile.configDir,
    })
  })
})

describe('what deleting a profile does to its login', () => {
  it('keeps the login on macOS, where it is in the Keychain', () => {
    const profile = createProfile('Work')
    expect(deleteProfile(profile.id, { deleteFiles: true }, 'darwin')).toEqual({
      removed: true,
      filesDeleted: true,
      credentialsRetained: true,
    })
  })

  it('does not claim the login was kept when it was inside the deleted directory', () => {
    // The dishonest version of this returns `credentialsRetained: true`
    // unconditionally, so a Windows user is told their login survived a
    // deletion that took it.
    const profile = createProfile('Work')
    writeFileSync(join(profile.configDir, '.credentials.json'), '{}')
    expect(deleteProfile(profile.id, { deleteFiles: true }, 'win32')).toEqual({
      removed: true,
      filesDeleted: true,
      credentialsRetained: false,
    })
  })

  it('still keeps the login on macOS when a credentials file happens to be there', () => {
    // `~/.claude/.credentials.json` is a normal thing to find on macOS, and the
    // Keychain entry survives the directory either way. Answering `false` here
    // would be a wrong answer about the one platform that was actually checked.
    const profile = createProfile('Work')
    writeFileSync(join(profile.configDir, '.credentials.json'), '{}')
    expect(deleteProfile(profile.id, { deleteFiles: true }, 'darwin').credentialsRetained).toBe(true)
  })

  it('keeps the login whenever the files were left alone', () => {
    const profile = createProfile('Work')
    writeFileSync(join(profile.configDir, '.credentials.json'), '{}')
    expect(deleteProfile(profile.id, {}, 'win32').credentialsRetained).toBe(true)
  })
})
