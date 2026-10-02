import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { UNAVAILABLE_SENTENCE } from './account-vault/runtime'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createProfile, getState, resetProfilesCache } from './profiles'

/**
 * An account whose login this app keeps, started in a process with no vault —
 * the headless host shares `profiles.json` with the desktop and has no
 * `safeStorage`.
 *
 * Review finding 5: before, such an account fell back to "the agent keeps it",
 * so the session started and the agent read whatever keychain item its folder
 * named — a login the app had stopped keeping up to date, or none — without a
 * word. It is refused now, before anything is probed or spawned, with the one
 * sentence every surface uses.
 */

let dir = ''
let core: HostCore

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-kept-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  resetProfilesCache()
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })
})

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  resetProfilesCache()
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

describe('a kept account in a process that cannot reach the vault', () => {
  it('is refused with a sentence, and no session is started', async () => {
    const kept = createProfile('kept@example.com')
    // What `profiles.json` says once the desktop has kept this account's login.
    const record = getState().profiles.find((profile) => profile.id === kept.id)
    if (!record) throw new Error('the account was not made')
    record.credentials = 'app'

    const before = core.ptys.list().length
    await expect(
      core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'claude', profileId: kept.id }),
    ).rejects.toThrow(UNAVAILABLE_SENTENCE)
    expect(core.ptys.list().length).toBe(before)
  })

  it('leaves every other account exactly as it was', async () => {
    const plain = createProfile('plain@example.com')
    expect(plain.credentials).toBeUndefined()
    // A shell needs no agent installed, so this runs on any machine: the point is
    // only that an account the app never kept is not refused.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell', profileId: plain.id })
    expect(meta.id).toBeTruthy()
  })
})
