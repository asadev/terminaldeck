import { describe, expect, it } from 'vitest'
import { profileIsolation } from './credential-store'

describe('whether two profiles are really two logins', () => {
  it('claims it on macOS, where it was checked', () => {
    const answer = profileIsolation('darwin', false)
    expect(answer.isolated).toBe(true)
    expect(answer.store).toBe('macos-keychain')
    expect(answer.note).toMatch(/Keychain/)
  })

  it('does not claim it on Windows', () => {
    // The important assertion in this file. Repeating the macOS sentence on a
    // platform where nothing was checked is the failure mode: the picker would
    // promise separate logins it cannot deliver, and the user finds out by
    // committing from the wrong account.
    const answer = profileIsolation('win32', false)
    expect(answer.isolated).toBe(false)
    expect(answer.store).toBe('unknown')
    expect(answer.note).toMatch(/unverified on Windows/)
    expect(answer.note).not.toMatch(/Keychain/)
  })

  it('does not claim it on Linux either, and names the platform', () => {
    const answer = profileIsolation('linux', false)
    expect(answer.isolated).toBe(false)
    expect(answer.note).toMatch(/unverified on linux/)
  })

  it('settles the question where nothing was verified, once the credential is in the directory', () => {
    // This is observable rather than assumed: the file is inside the directory
    // the profile already isolates, so the login goes with it.
    for (const platform of ['win32', 'linux'] as const) {
      const answer = profileIsolation(platform, true)
      expect(answer.isolated, platform).toBe(true)
      expect(answer.store, platform).toBe('config-directory')
      // And it says the other half of that truth: deleting the files signs out.
      expect(answer.note, platform).toMatch(/does sign it out/)
    }
  })

  it('does not let that observation overrule what was checked on macOS', () => {
    // `~/.claude/.credentials.json` is ordinary on macOS — `prerequisites.ts`
    // reads it before it reads the Keychain — so treating its presence as proof
    // would tell a Mac user that deleting a profile signed it out while the
    // Keychain entry the CLI actually uses is untouched, and would make
    // `deleteProfile` answer `credentialsRetained: false` for a login that was
    // retained. The verified answer wins over the inferred one.
    const answer = profileIsolation('darwin', true)
    expect(answer.store).toBe('macos-keychain')
    expect(answer.note).toMatch(/does not sign it out/)
  })

  it('always says something a person can read', () => {
    for (const platform of ['darwin', 'win32', 'linux'] as const) {
      for (const inDir of [true, false]) {
        const note = profileIsolation(platform, inDir).note
        expect(note.length, `${platform}/${inDir}`).toBeGreaterThan(60)
        expect(note.trim().endsWith('.'), `${platform}/${inDir}`).toBe(true)
      }
    }
  })
})
