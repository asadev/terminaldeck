import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { IpcMain } from 'electron'
import type { SessionMeta } from '../../shared/types'
import { installPaths, resetPaths } from '../platform/paths'
import {
  createProfile,
  deleteProfile,
  getState,
  profileKeptBy,
  registerProfilesIpc,
  resetProfilesCache,
  sessionEnv,
  systemProfile,
  type Profile,
} from '../profiles'
import { keptSignIn } from '../profiles-signin'
import { switchRefusal } from '../session-switch'
import type { SavedSession } from '../session-restore'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './keychain-shim'
import { currentAccountVault, vaultPath, vaultSignedIn } from './runtime'
import { answerShim } from './server'
import { wireAccountVault, type AccountVaultHandle } from './wire'

/**
 * The vault as the rest of the app meets it: through `profiles.ts`, the switch
 * and the sign-in check. Everything runs against a scratch data folder, a fake
 * cipher and a fake `security` — the login keychain is never reached, because
 * the "real" command the shim falls back to is a script in the scratch folder.
 */

const ON_WINDOWS = process.platform === 'win32'
const SLOT = 'keychain:Claude Code-credentials'
const SECRET = 'VERY-SECRET-TOKEN-VALUE'

let root = ''
let handle: AccountVaultHandle | null = null

async function wire(): Promise<AccountVaultHandle> {
  const fake = join(root, 'fake-security')
  writeFileSync(fake, '#!/bin/sh\nexit 44\n')
  chmodSync(fake, 0o755)
  const wired = await wireAccountVault({
    userDataDir: root,
    cipher: fakeCipher(),
    platform: 'darwin',
    realSecurity: fake,
    home: root,
    // Watchers are driven by the Codex keeper's own tests; here they would only
    // be a live handle left open at the end of the run.
    watch: () => () => undefined,
  })
  if (wired === null) throw new Error('the vault did not start')
  handle = wired
  return wired
}

function find(ticket: string): Buffer {
  return Buffer.from(
    [ticket, '6', 'find-generic-password', '-a', 'me', '-w', '-s', 'Claude Code-credentials-1234abcd', ''].join('\0'),
  )
}

beforeEach(() => {
  // Short, because the vault's socket lives under it and `sun_path` is 104 bytes.
  root = mkdtempSync('/tmp/tdvp-')
  resetPaths()
  installPaths({ userData: () => root, home: () => root, downloads: () => root, appRoot: () => root })
  resetProfilesCache()
})

afterEach(async () => {
  await handle?.dispose()
  handle = null
  resetPaths()
  resetProfilesCache()
  rmSync(root, { recursive: true, force: true })
})

describe.skipIf(ON_WINDOWS)('accounts the app keeps the login of', () => {
  it('a new account is kept by the app from its first moment', async () => {
    await wire()
    const work = createProfile('work@example.com')
    expect(work.credentials).toBe('app')
    expect(profileKeptBy(work)).toBe('app')
    // Persisted, so a restart does not quietly read the keychain for it.
    resetProfilesCache()
    expect(getState().profiles[0]?.credentials).toBe('app')
  })

  it('without a vault nothing changes: no field, no ticket, the agent keeps the login', () => {
    const work = createProfile('work@example.com')
    expect(work.credentials).toBeUndefined()
    expect(profileKeptBy(work)).toBe('agent')
    expect(sessionEnv(work, 'claude')).toEqual({ CLAUDE_CONFIG_DIR: work.configDir })
  })

  it('a session on a kept account gets the vault and its own ticket; the machine\'s own install never does', async () => {
    const wired = await wire()
    const one = createProfile('one@example.com')
    const two = createProfile('two@example.com')
    const a = sessionEnv(one, 'claude')
    const b = sessionEnv(two, 'claude')
    expect(a[VAULT_SOCKET_ENV]).toBe(wired.runtime.socketPath)
    expect(a[VAULT_TICKET_ENV]).toMatch(/^[0-9a-f]{48}$/)
    expect(a[VAULT_TICKET_ENV]).not.toBe(b[VAULT_TICKET_ENV])
    expect(sessionEnv(systemProfile(), 'claude')).toEqual({})
    // The wrong agent gets neither the directory nor the ticket.
    expect(sessionEnv(one, 'codex')).toEqual({})

    // And the shim goes first on that session's PATH, and on no other.
    expect(vaultPath('/usr/bin:/bin', a).split(':')[0]).toBe(wired.runtime.shimDir)
    expect(vaultPath('/usr/bin:/bin', {})).toBe('/usr/bin:/bin')
  })

  it('two sessions on two accounts read two logins, and switching one leaves the other alone', async () => {
    const wired = await wire()
    const one = createProfile('one@example.com')
    const two = createProfile('two@example.com')
    const { vault } = wired.runtime
    vault.put(one.id, 'claude', SLOT, claudeLogin('ONE'), 'sign-in')
    vault.put(two.id, 'claude', SLOT, claudeLogin('TWO'), 'sign-in')
    const deps = {
      vault,
      tickets: wired.runtime.tickets,
      providerOf: () => 'claude' as const,
      adopting: () => false,
      markKept: () => undefined,
    }
    const sessionA = sessionEnv(one, 'claude')[VAULT_TICKET_ENV] ?? ''
    const sessionB = sessionEnv(two, 'claude')[VAULT_TICKET_ENV] ?? ''
    expect(answerShim(find(sessionA), deps)).toMatchObject({ answer: { stdout: claudeLogin('ONE') } })
    expect(answerShim(find(sessionB), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    // Session A is switched to `two`: it is restarted with `two`'s environment.
    const switched = sessionEnv(two, 'claude')[VAULT_TICKET_ENV] ?? ''
    expect(answerShim(find(switched), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    // B never noticed, and `one` is still signed in for anybody on it.
    expect(answerShim(find(sessionB), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    expect(vault.has(one.id)).toBe(true)
  })

  it('an account made before the vault moves across instead of signing out', async () => {
    // Made while no vault existed — the shape every account on disk today has.
    const old = createProfile('old@example.com')
    expect(old.credentials).toBeUndefined()
    await wire()
    expect(profileKeptBy(old)).toBe('adopting')
    expect(sessionEnv(old, 'claude')[VAULT_TICKET_ENV]).toBeDefined()
    // The vault cannot say yet whether it is signed in — its login is still
    // where the agent put it — so the sign-in check asks the agent, as before.
    expect(vaultSignedIn(old, true)).toBeNull()
    expect(keptSignIn(old, 'claude')).toBeNull()
  })

  it('deleting an account deletes its kept login and stops answering for it', async () => {
    const wired = await wire()
    const gone = createProfile('gone@example.com')
    wired.runtime.vault.put(gone.id, 'claude', SLOT, claudeLogin(SECRET), 'sign-in')
    const ticket = sessionEnv(gone, 'claude')[VAULT_TICKET_ENV] ?? ''
    const result = deleteProfile(gone.id, { deleteFiles: true })
    expect(result.credentialsRetained).toBe(false)
    expect(wired.runtime.vault.has(gone.id)).toBe(false)
    expect(readFileSync(wired.runtime.vault.path, 'utf8')).not.toContain(SECRET)
    const deps = {
      vault: wired.runtime.vault,
      tickets: wired.runtime.tickets,
      providerOf: () => 'claude' as const,
      adopting: () => false,
      markKept: () => undefined,
    }
    expect(answerShim(find(ticket), deps)).toMatchObject({ answer: { code: 44 } })
  })

  it('an account re-made under a deleted one\'s name starts signed out, not as the old login', async () => {
    const wired = await wire()
    const first = createProfile('same@example.com')
    wired.runtime.vault.put(first.id, 'claude', SLOT, claudeLogin('OLD'), 'sign-in')
    deleteProfile(first.id, { deleteFiles: true })
    const again = createProfile('same@example.com')
    expect(again.id).toBe(first.id)
    expect(again.credentials).toBe('app')
    expect(vaultSignedIn(again, true)).toBe(false)
  })

  it('a Codex account is followed from the moment it is made, and its file goes at quit', async () => {
    const wired = await wire()
    const codex = createProfile('codex@example.com', { provider: 'codex' })
    expect(profileKeptBy(codex)).toBe('app')
    expect(wired.runtime.codex?.following()).toContain(codex.id)
    writeFileSync(join(codex.configDir, 'auth.json'), JSON.stringify({ tokens: { access_token: 'at-X' } }))
    wired.runtime.codex?.capture(codex)
    expect(wired.runtime.vault.has(codex.id)).toBe(true)
    await wired.dispose()
    handle = null
    expect(existsSync(join(codex.configDir, 'auth.json'))).toBe(false)
    expect(currentAccountVault()).toBeNull()
    // With the vault gone, sessions are exactly as before.
    expect(sessionEnv(codex, 'codex')).toEqual({ CODEX_HOME: codex.configDir })
  })

  it('answers "signed in, as whom" for a kept login without running anything', async () => {
    const wired = await wire()
    const work = createProfile('typed-name')
    expect(keptSignIn(work, 'claude')).toMatchObject({ state: 'signed-out', command: '' })
    wired.runtime.vault.put(work.id, 'claude', SLOT, claudeLogin('A', 'max'), 'sign-in')
    mkdirSync(work.configDir, { recursive: true })
    writeFileSync(
      join(work.configDir, '.claude.json'),
      JSON.stringify({ oauthAccount: { emailAddress: 'real@example.com', organizationName: 'Org' } }),
    )
    expect(keptSignIn(work, 'claude')).toMatchObject({
      state: 'signed-in',
      account: 'real@example.com',
      plan: 'max',
      detail: 'Signed in as real@example.com · max',
    })
  })

  it('refuses to switch a session to a kept account that has no login, before anything is stopped', async () => {
    await wire()
    const empty = createProfile('empty@example.com')
    const meta = { id: 's1', provider: 'claude', exitCode: null, profileId: 'system' } as unknown as SessionMeta
    const saved = { cwd: '/tmp', provider: 'claude' } as unknown as SavedSession
    const refusal = switchRefusal({ meta, saved, target: empty, targetSignedIn: vaultSignedIn(empty, true) })
    expect(refusal).toContain('is not signed in yet')
    // Signed in, it goes ahead.
    currentAccountVault()?.vault.put(empty.id, 'claude', SLOT, claudeLogin('A'), 'sign-in')
    expect(switchRefusal({ meta, saved, target: empty, targetSignedIn: vaultSignedIn(empty, true) })).toBeNull()
  })

  it('nothing the window can ask for ever carries a kept login', async () => {
    const wired = await wire()
    const work = createProfile('work@example.com')
    const codex = createProfile('codex@example.com', { provider: 'codex' })
    wired.runtime.vault.put(work.id, 'claude', SLOT, claudeLogin(SECRET), 'sign-in')
    wired.runtime.vault.put(codex.id, 'codex', 'file:auth.json', JSON.stringify({ tokens: { access_token: SECRET } }), 'sign-in')

    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    const ipc = { handle: (channel: string, fn: (...args: unknown[]) => unknown) => handlers.set(channel, fn) }
    registerProfilesIpc(ipc as unknown as IpcMain)
    const answers = [
      await handlers.get('profiles:list')?.({}, undefined),
      await handlers.get('profiles:list')?.({}, 'codex'),
      await handlers.get('profiles:status')?.({}, work.id),
      await handlers.get('profiles:resolve')?.({}, { sessionProfileId: work.id }),
      keptSignIn(work as Profile, 'claude'),
    ]
    const text = JSON.stringify(answers)
    expect(text).not.toContain(SECRET)
    expect(text).not.toContain('sk-ant')
    expect(text).not.toContain(VAULT_TICKET_ENV)
    // The list says the login is kept, and that it is signed in.
    const listed = answers[0] as { vault: Record<string, { keptBy: string; signedIn: boolean | null }> }
    expect(listed.vault[work.id]).toMatchObject({ keptBy: 'app', signedIn: true })
    expect(listed.vault.system).toMatchObject({ keptBy: 'agent', signedIn: null })
  })
})
