import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_PARTITION,
  DEFAULT_PROFILE_ID,
  PROFILE_PARTITION_PREFIX,
  clearProfileStorage,
  electronProfileDir,
  headlessProfileDir,
  isProfileId,
  ownProfileStorage,
  partitionDirName,
  partitionForProfile,
  readStoredProfiles,
  resetProfileStorageForTests,
} from './browser-profile-storage'

/**
 * Where a profile's bytes are, and the answer a clear is allowed to give.
 *
 * This file exists because of one line. `browserProfilesFor` in
 * `remote/server.ts` emptied a profile by rebuilding its directory from the
 * partition string — `join(stateDir, 'browser', partition)` — a path neither
 * host has ever written to, and `rm(..., { force: true })` treats a missing path
 * as a success. So the phone was answered with a fresh profile list, the screen
 * redrew as though it had worked, and every cookie and every signed-in session
 * was still there.
 *
 * The tests below are therefore not about a helper. They are about the two
 * things that let that ship: a path stated twice, and a clear that reported on
 * the call it made rather than on the state it left behind.
 */

const PROFILE = '7f2a1c94-3d8e-4b21-9a55-0c6d1e83f4b7'

let userData = ''

beforeEach(() => {
  resetProfileStorageForTests()
  userData = mkdtempSync(join(tmpdir(), 'td-profile-storage-'))
})

afterEach(() => {
  resetProfileStorageForTests()
  // The `held` test takes the write bit off a directory; put it back or the
  // temporary tree cannot be removed.
  const partitions = join(userData, 'Partitions')
  if (existsSync(partitions)) chmodSync(partitions, 0o755)
  rmSync(userData, { recursive: true, force: true })
})

/* --------------------------------------------------------------- the ids -- */

describe('what a profile id may be', () => {
  it('is the literal default or a UUID, and nothing else', () => {
    expect(isProfileId(DEFAULT_PROFILE_ID)).toBe(true)
    expect(isProfileId(PROFILE)).toBe(true)
    for (const value of ['', 'work', '../../etc', 'default/../x', 'DEFAULT', PROFILE.toUpperCase(), 7, null]) {
      expect(isProfileId(value), String(value)).toBe(false)
    }
  })

  it('never lets a separator reach a path segment', () => {
    // The check that matters, said the way it is used: an id becomes the last
    // segment of a `--user-data-dir` and a partition name becomes the last
    // segment of a delete.
    expect(partitionForProfile('../../etc')).toBeNull()
    expect(partitionDirName('persist:../../etc')).toBe('')
    expect(partitionDirName('persist:a/b')).toBe('')
    expect(partitionDirName('persist:..')).toBe('')
  })

  it('says the same three strings `browser-profiles.ts` does', () => {
    /*
     * That module is the desktop's and reaches Electron on its first line, so it
     * cannot be imported into this one — `remote/server.ts` is inside the
     * headless bundle's import graph and `seam.test.ts` walks it. Two independent
     * statements of one truth, checked against each other in the source, is the
     * arrangement `browser-cdp.test.ts` already keeps between the CDP screen and
     * the fetch rules; the alternative is two spellings of the string that
     * decides which cookie jar somebody's window opens in.
     */
    const desktop = readFileSync(join(__dirname, 'browser-profiles.ts'), 'utf8')
    expect(desktop).toContain(`export const DEFAULT_PROFILE_ID = '${DEFAULT_PROFILE_ID}'`)
    expect(desktop).toContain(`export const DEFAULT_PARTITION = '${DEFAULT_PARTITION}'`)
    expect(desktop).toContain(`export const PROFILE_PARTITION_PREFIX = '${PROFILE_PARTITION_PREFIX}'`)
    expect(partitionForProfile(PROFILE)).toBe(`${PROFILE_PARTITION_PREFIX}${PROFILE}`)
  })
})

/* ------------------------------------------------------------- the paths -- */

describe('where a profile’s bytes are', () => {
  it('puts an Electron partition where Electron puts it', () => {
    // `<userData>/Partitions/<name>`, which `browser-session.ts` states in as
    // many words and which was verified against this app's own `userData` on a
    // Mac — `Partitions/terminaldeck-browser`, with no `browser/` directory
    // anywhere near it.
    expect(electronProfileDir(userData, DEFAULT_PARTITION)).toBe(
      join(userData, 'Partitions', 'terminaldeck-browser'),
    )
    expect(electronProfileDir(userData, `${PROFILE_PARTITION_PREFIX}${PROFILE}`)).toBe(
      join(userData, 'Partitions', `terminaldeck-browser-${PROFILE}`),
    )
  })

  it('puts a headless profile where the headless host launches Chromium', () => {
    expect(headlessProfileDir(userData, DEFAULT_PROFILE_ID)).toBe(join(userData, 'Partitions', 'default'))
    expect(headlessProfileDir(userData, PROFILE)).toBe(join(userData, 'Partitions', PROFILE))
  })
})

/* ------------------------------------------------------------- the clear -- */

describe('clearing a profile', () => {
  it('empties the directory Electron writes, not <stateDir>/browser/<partition>', async () => {
    /*
     * The regression guard, and it is named after the bug because that is what it
     * is: the broken line deleted `<stateDir>/browser/<partition>` and answered
     * as though it had cleared the profile. Both directories exist here, so a
     * version that empties the wrong one passes nothing — the cookie it was
     * supposed to remove is still on disk and the assertion says so.
     */
    const real = electronProfileDir(userData, DEFAULT_PARTITION)
    mkdirSync(real, { recursive: true })
    writeFileSync(join(real, 'Cookies'), 'a session token')
    const oldGuess = join(userData, 'browser', 'terminaldeck-browser')
    mkdirSync(oldGuess, { recursive: true })
    writeFileSync(join(oldGuess, 'nothing'), '')

    const outcome = await clearProfileStorage({
      userData,
      profileId: DEFAULT_PROFILE_ID,
      partition: DEFAULT_PARTITION,
    })

    expect(outcome.state).toBe('cleared')
    expect(existsSync(real)).toBe(false)
    // Untouched, because it was never a place a profile lives.
    expect(existsSync(oldGuess)).toBe(true)
  })

  it('empties a named profile under both spellings of its directory', async () => {
    /*
     * A desktop keys the directory on the partition string and a server keys it
     * on the profile id, and on a machine where `app.getPath('userData')` and the
     * daemon's state directory are the same folder one profile genuinely has
     * bytes under both. "Empty this profile" means empty it, not empty the half
     * this process happens to have launched.
     */
    const electron = electronProfileDir(userData, `${PROFILE_PARTITION_PREFIX}${PROFILE}`)
    const headless = headlessProfileDir(userData, PROFILE)
    for (const dir of [electron, headless]) {
      mkdirSync(dir, { recursive: true })
      writeFileSync(join(dir, 'Cookies'), 'a session token')
    }

    const outcome = await clearProfileStorage({
      userData,
      profileId: PROFILE,
      partition: `${PROFILE_PARTITION_PREFIX}${PROFILE}`,
    })

    expect(outcome.state).toBe('cleared')
    expect(existsSync(electron)).toBe(false)
    expect(existsSync(headless)).toBe(false)
  })

  it('says nothing was there rather than saying it cleared it', async () => {
    /*
     * `rm(..., { force: true })` cannot tell these two apart, and that is exactly
     * how the wrong path went unnoticed for as long as it did. A person who
     * pressed Clear to sign out is owed the difference between *your sign-ins are
     * gone* and *this machine was holding none*.
     */
    const outcome = await clearProfileStorage({
      userData,
      profileId: DEFAULT_PROFILE_ID,
      partition: DEFAULT_PARTITION,
    })
    expect(outcome.state).toBe('empty')
  })

  it('refuses to clear anything for an id this app never minted', async () => {
    const outcome = await clearProfileStorage({
      userData,
      profileId: '../../etc',
      partition: 'persist:../../etc',
    })
    expect(outcome.state).toBe('empty')
    expect(outcome.dirs).toEqual([])
  })

  it('asks whatever is holding the files to let go, and takes its directory over the derived one', async () => {
    // The owner is the process that actually launched the browser; a path
    // derived here is a guess by comparison, and the whole defect was a guess.
    const owned = join(userData, 'elsewhere', 'default')
    mkdirSync(owned, { recursive: true })
    writeFileSync(join(owned, 'Cookies'), 'a session token')
    const released: string[] = []
    ownProfileStorage({
      directoryFor: (id) => (id === DEFAULT_PROFILE_ID ? owned : null),
      release: async (id) => {
        released.push(id)
        return { released: true, why: '' }
      },
    })

    const outcome = await clearProfileStorage({
      userData,
      profileId: DEFAULT_PROFILE_ID,
      partition: DEFAULT_PARTITION,
    })

    expect(released).toEqual([DEFAULT_PROFILE_ID])
    expect(outcome.state).toBe('cleared')
    if (outcome.state === 'cleared') expect(outcome.stopped).toBe(true)
    expect(existsSync(owned)).toBe(false)
  })

  it('removes nothing when the browser will not let go', async () => {
    // A clear over a live Chromium is not a clear on any operating system: the
    // unlink fails on Windows, and on POSIX the running browser writes its
    // in-memory jar back over the gap.
    const dir = headlessProfileDir(userData, DEFAULT_PROFILE_ID)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'Cookies'), 'a session token')
    ownProfileStorage({
      directoryFor: () => dir,
      release: async () => ({ released: false, why: 'its browser had not stopped' }),
    })

    const outcome = await clearProfileStorage({
      userData,
      profileId: DEFAULT_PROFILE_ID,
      partition: DEFAULT_PARTITION,
    })

    expect(outcome.state).toBe('held')
    if (outcome.state === 'held') expect(outcome.why).toContain('had not stopped')
    expect(readFileSync(join(dir, 'Cookies'), 'utf8')).toBe('a session token')
  })

  it('does not call a removal that left files behind a clear', async () => {
    /*
     * The check the broken version had no equivalent of: the disk is looked at
     * **after** the removal, so a removal that reported success while leaving
     * the cookies where they were cannot be reported as a clear.
     *
     * The failure is injected rather than staged on the filesystem. It was
     * staged, with `chmod 0o555` on the parent — and **Windows ignores POSIX
     * mode bits**, so on the Windows runner the files were removed, the outcome
     * was `cleared`, and this failed on a machine where the product was doing
     * exactly the right thing. A removal that silently does nothing is the
     * behaviour under test; which syscall refused is not.
     */
    const dir = headlessProfileDir(userData, DEFAULT_PROFILE_ID)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'Cookies'), 'a session token')

    const outcome = await clearProfileStorage({
      userData,
      profileId: DEFAULT_PROFILE_ID,
      partition: DEFAULT_PARTITION,
      // Answers, removes nothing — a file held open, on any platform.
      remove: async () => undefined,
    })

    expect(outcome.state).toBe('held')
    if (outcome.state === 'held') expect(outcome.why).toContain('still has those files open')
    expect(existsSync(dir)).toBe(true)
  })
})

/* ------------------------------------------------------------ the roster -- */

describe('the profile list, read off the machine', () => {
  it('gives a machine that has never been asked the one profile every machine has', () => {
    // An empty list reads as *this browser has no profiles*, which is not a
    // thing a browser can be.
    for (const text of [null, '', 'not json at all', '[]', '{"profiles":[]}']) {
      const state = readStoredProfiles(text)
      expect(state.activeId).toBe(DEFAULT_PROFILE_ID)
      expect(state.profiles).toEqual([
        { id: DEFAULT_PROFILE_ID, name: 'Default', avatar: '', partition: DEFAULT_PARTITION },
      ])
    }
  })

  it('derives every partition from the id and drops a row whose id is not one', () => {
    /*
     * The file is on disk and a phone is about to name one of its rows in a
     * recursive delete. A partition carried out of the file would be a partition
     * somebody could write into the file.
     */
    const state = readStoredProfiles(
      JSON.stringify({
        activeId: PROFILE,
        profiles: [
          { id: DEFAULT_PROFILE_ID, name: 'Default', partition: 'persist:../../etc' },
          { id: PROFILE, name: 'Work', avatar: 'W', partition: 'persist:somewhere-else' },
          { id: '../../etc', name: 'Nothing', partition: 'persist:../../etc' },
        ],
      }),
    )
    expect(state.profiles.map((profile) => profile.partition)).toEqual([
      DEFAULT_PARTITION,
      `${PROFILE_PARTITION_PREFIX}${PROFILE}`,
    ])
    expect(state.activeId).toBe(PROFILE)
  })

  it('pulls a dangling active id back to a profile that exists', () => {
    const state = readStoredProfiles(JSON.stringify({ activeId: PROFILE, profiles: [] }))
    expect(state.activeId).toBe(DEFAULT_PROFILE_ID)
  })

  it('flattens a name a screen has to draw on one line', () => {
    const state = readStoredProfiles(
      JSON.stringify({ profiles: [{ id: PROFILE, name: 'Two\nlines\ttabbed  ' }] }),
    )
    expect(state.profiles[1].name).toBe('Two lines tabbed')
  })
})
