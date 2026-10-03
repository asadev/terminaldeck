import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { IpcMain } from 'electron'
import type { SessionMeta } from '../../shared/types'
import { installPaths, resetPaths } from '../platform/paths'
import {
  createProfile,
  deleteProfile,
  getState,
  keptUnavailable,
  profileKeptBy,
  profilesSnapshot,
  profileStatus,
  registerProfilesIpc,
  resetProfilesCache,
  sessionEnv,
  systemProfile,
  type Profile,
} from '../profiles'
import { keptSignIn, readSignIn } from '../profiles-signin'
import { probeUsage } from '../usage-probe'
import { accountTools } from '../deck-control/account-tools'
import type { ToolContext } from '../deck-control/catalogue'
import { switchRefusal } from '../session-switch'
import type { SavedSession } from '../session-restore'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import type { VaultCipher } from './store'
import { VAULT_SOCKET_ENV, VAULT_TICKET_ENV } from './keychain-shim'
import { currentAccountVault, UNAVAILABLE_SENTENCE, vaultPath, vaultSignedIn } from './runtime'
import { answerShim, type VaultServerDeps } from './server'
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

async function wire(cipher: VaultCipher = fakeCipher()): Promise<AccountVaultHandle> {
  const wired = await wireRaw(cipher)
  if (wired === null) throw new Error('the vault did not start')
  handle = wired
  return wired
}

async function wireRaw(cipher: VaultCipher): Promise<AccountVaultHandle | null> {
  const fake = join(root, 'fake-security')
  writeFileSync(fake, '#!/bin/sh\nexit 44\n')
  chmodSync(fake, 0o755)
  return wireAccountVault({
    userDataDir: root,
    cipher,
    platform: 'darwin',
    realSecurity: fake,
    home: root,
    // Watchers are driven by the Codex keeper's own tests; here they would only
    // be a live handle left open at the end of the run.
    watch: () => () => undefined,
    inUse: () => false,
  })
}

/** A lookup for one account's login, spelled with that account's own directory hash. */
function find(ticket: string, configDir: string): Buffer {
  const suffix = createHash('sha256').update(configDir).digest('hex').slice(0, 8)
  return Buffer.from(
    [ticket, '6', 'find-generic-password', '-a', 'me', '-w', '-s', `Claude Code-credentials-${suffix}`, ''].join('\0'),
  )
}

/** Server deps over the real profile list, as `wire.ts` builds them. */
function depsOf(wired: AccountVaultHandle): VaultServerDeps {
  return {
    vault: wired.runtime.vault,
    tickets: wired.runtime.tickets,
    providerOf: () => 'claude',
    configDirOf: (id) => getState().profiles.find((profile) => profile.id === id)?.configDir ?? null,
    adopting: () => false,
    markKept: () => undefined,
  }
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
    expect(work.loginStore).toBe('app')
    expect(profileKeptBy(work)).toBe('app')
    // Persisted, so a restart does not quietly read the keychain for it.
    resetProfilesCache()
    expect(getState().profiles[0]?.loginStore).toBe('app')
  })

  it('without a vault nothing changes: no field, no ticket, the agent keeps the login', () => {
    const work = createProfile('work@example.com')
    expect(work.loginStore).toBeUndefined()
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
    const deps = depsOf(wired)
    const sessionA = sessionEnv(one, 'claude')[VAULT_TICKET_ENV] ?? ''
    const sessionB = sessionEnv(two, 'claude')[VAULT_TICKET_ENV] ?? ''
    expect(answerShim(find(sessionA, one.configDir), deps)).toMatchObject({ answer: { stdout: claudeLogin('ONE') } })
    expect(answerShim(find(sessionB, two.configDir), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    // Session A is switched to `two`: it is restarted with `two`'s environment.
    const switched = sessionEnv(two, 'claude')[VAULT_TICKET_ENV] ?? ''
    expect(answerShim(find(switched, two.configDir), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    // B never noticed, and `one` is still signed in for anybody on it.
    expect(answerShim(find(sessionB, two.configDir), deps)).toMatchObject({ answer: { stdout: claudeLogin('TWO') } })
    expect(vault.has(one.id)).toBe(true)
  })

  it('an account made before the vault moves across instead of signing out', async () => {
    // Made while no vault existed — the shape every account on disk today has.
    const old = createProfile('old@example.com')
    expect(old.loginStore).toBeUndefined()
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
    expect(answerShim(find(ticket, gone.configDir), depsOf(wired))).toMatchObject({ answer: { code: 44 } })
  })

  it('an account re-made under a deleted one\'s name starts signed out, not as the old login', async () => {
    const wired = await wire()
    const first = createProfile('same@example.com')
    wired.runtime.vault.put(first.id, 'claude', SLOT, claudeLogin('OLD'), 'sign-in')
    deleteProfile(first.id, { deleteFiles: true })
    const again = createProfile('same@example.com')
    expect(again.id).toBe(first.id)
    expect(again.loginStore).toBe('app')
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

  /*
   * Review finding 1. Before: removing a Codex account deleted the `auth.json`
   * in its folder whether or not the app kept that login — so removing an
   * account pointed at a folder the person chose deleted their only copy.
   */
  it('never takes away the login file of a Codex account in a folder the person chose', async () => {
    await wire()
    const chosen = join(root, 'my-codex-home')
    mkdirSync(chosen)
    writeFileSync(join(chosen, 'auth.json'), JSON.stringify({ tokens: { access_token: 'MINE' } }))
    const mine = createProfile('mine@example.com', { provider: 'codex', configDir: chosen })
    expect(profileKeptBy(mine)).toBe('agent')
    deleteProfile(mine.id, { deleteFiles: true })
    expect(readFileSync(join(chosen, 'auth.json'), 'utf8')).toContain('MINE')
  })

  /*
   * Review finding 5. Before: with no vault running — the headless host, or a
   * vault that would not unlock — an account the app keeps fell back to
   * `agent`, and the agent quietly read a keychain item the app had stopped
   * keeping up to date.
   */
  it('an account the app keeps is unavailable where no vault runs — refused, never a keychain read', async () => {
    const wired = await wire()
    const work = createProfile('work@example.com')
    await wired.dispose()
    handle = null
    expect(profileKeptBy(work)).toBe('unavailable')
    expect(sessionEnv(work, 'claude')).toEqual({ CLAUDE_CONFIG_DIR: work.configDir })
    expect(keptUnavailable(work)).toBe(UNAVAILABLE_SENTENCE)

    let spawned = false
    const report = await readSignIn(work, {
      path: '/usr/bin',
      exec: async () => {
        spawned = true
        return { stdout: '{"loggedIn":true}', stderr: '', exitCode: 0, killed: false }
      },
    })
    expect(spawned).toBe(false)
    expect(report).toMatchObject({ state: 'unknown', detail: UNAVAILABLE_SENTENCE, command: '' })

    let asked = false
    const usage = await probeUsage(
      { provider: 'claude', id: work.id, name: work.name, configDir: work.configDir },
      {
        path: '/usr/bin',
        ask: async () => {
          asked = true
          return { usage: null, error: null, killed: false }
        },
      },
    )
    expect(asked).toBe(false)
    expect(usage.detail).toBe(UNAVAILABLE_SENTENCE)

    const meta = { id: 's1', provider: 'claude', exitCode: null, profileId: 'system' } as unknown as SessionMeta
    const saved = { cwd: '/tmp', provider: 'claude' } as unknown as SavedSession
    expect(switchRefusal({ meta, saved, target: work, targetUnavailable: keptUnavailable(work) })).toBe(
      UNAVAILABLE_SENTENCE,
    )
  })

  it('a vault that will not unlock is left exactly as it is, and its accounts read unavailable', async () => {
    const wired = await wire()
    const work = createProfile('work@example.com')
    wired.runtime.vault.put(work.id, 'claude', SLOT, claudeLogin(SECRET), 'sign-in')
    const file = wired.runtime.vault.path
    await wired.dispose()
    handle = null
    const before = readFileSync(file)
    const otherBuild = { ...fakeCipher(), decrypt: () => { throw new Error('a different key') } }
    expect(await wireRaw(otherBuild)).toBeNull()
    expect(readFileSync(file)).toEqual(before)
    expect(profileKeptBy(work)).toBe('unavailable')
    // And with the right key it opens, every login still in it.
    const again = await wire()
    expect(again.runtime.vault.read(work.id, SLOT)).toBe(claudeLogin(SECRET))
  })

  /*
   * Review finding 7. Before: a Codex account the app keeps read "signed out"
   * whenever the vault held nothing — including one whose own config keeps its
   * login in the keyring, which never writes the file this app follows.
   */
  it('a Codex account reads "cannot tell" until something has been kept for it', async () => {
    const wired = await wire()
    const codex = createProfile('codex@example.com', { provider: 'codex' })
    expect(vaultSignedIn(codex, true)).toBeNull()
    writeFileSync(join(codex.configDir, 'auth.json'), JSON.stringify({ tokens: { access_token: 'at' } }))
    wired.runtime.codex?.capture(codex)
    expect(vaultSignedIn(codex, true)).toBe(true)
    rmSync(join(codex.configDir, 'auth.json'))
    wired.runtime.codex?.capture(codex)
    expect(vaultSignedIn(codex, true)).toBe(false)
  })

  /*
   * Review finding 9. Before: the shim lived in `<vault>/bin`, and a confined
   * session's plan grants a PATH entry called `bin` *and its parent* — the
   * whole vault folder.
   */
  it('keeps the shim in a folder of its own, outside the vault folder and not called bin', async () => {
    const wired = await wire()
    const shim = wired.runtime.shimDir ?? ''
    expect(shim.startsWith(join(root, 'account-vault') + '/')).toBe(false)
    expect(shim.endsWith('/bin')).toBe(false)
    expect(readdirSync(shim)).toEqual(['security'])
  })

  it('gives a confined session no ticket, so a held device reaches nothing it could not reach before', () => {
    const source = readFileSync(new URL('../host-core.ts', import.meta.url), 'utf8')
    expect(source).toContain('...(confined ? withoutVaultEnv(sessionEnv(profile, provider)) : sessionEnv(profile, provider)),')
  })

  /*
   * The coordinator's extra item. Before: the sign-in and usage probes built
   * their environment straight from `process.env`, so a probe about one account
   * carried a ticket this app had itself inherited from a session it was
   * launched from.
   */
  it('never hands a probe a ticket inherited from whatever launched the app', async () => {
    await wire()
    process.env[VAULT_TICKET_ENV] = 'f'.repeat(48)
    process.env[VAULT_SOCKET_ENV] = '/somewhere/else.sock'
    try {
      let seen: Record<string, string | undefined> = {}
      await readSignIn(systemProfile(), {
        provider: 'claude',
        path: '/usr/bin',
        exec: async (_command, _args, options) => {
          seen = options.env
          return { stdout: '{"loggedIn":false}', stderr: '', exitCode: 0, killed: false }
        },
      })
      expect(seen[VAULT_TICKET_ENV]).toBeUndefined()
      expect(seen[VAULT_SOCKET_ENV]).toBeUndefined()

      let usageEnv: NodeJS.ProcessEnv = {}
      await probeUsage(
        { provider: 'claude', id: 'system', name: null, configDir: null },
        {
          path: '/usr/bin',
          ask: async (_command, _args, options) => {
            usageEnv = options.env
            return { usage: null, error: null, killed: false }
          },
        },
      )
      expect(usageEnv[VAULT_TICKET_ENV]).toBeUndefined()
    } finally {
      delete process.env[VAULT_TICKET_ENV]
      delete process.env[VAULT_SOCKET_ENV]
    }
  })
})

/*
 * The outside door: the MCP account tools an AI in another app is handed. They
 * wrap the same profile functions the window uses, through one deps block in
 * `agents-area-live.ts`, and their results pass through `withoutSecrets` — so
 * what is pinned here is that a kept account reads correctly through them and
 * that nothing in their answers is a login.
 */
describe.skipIf(ON_WINDOWS)('the MCP account tools, over a vault', () => {
  it('show a kept account as kept and signed in, and never carry its login', async () => {
    const wired = await wire()
    const work = createProfile('work@example.com')
    wired.runtime.vault.put(work.id, 'claude', SLOT, claudeLogin(SECRET), 'sign-in')
    const tools = accountTools({
      list: (agent) => profilesSnapshot(agent === 'claude' ? 'claude' : null),
      agents: () => [],
      resolve: () => null,
      find: (id) => {
        const found = getState().profiles.find((profile) => profile.id === id)
        return found ? { id: found.id, name: found.name, provider: found.provider } : null
      },
      status: (id) => profileStatus(getState().profiles.find((profile) => profile.id === id) as Profile),
      signIn: (id) => readSignIn(getState().profiles.find((profile) => profile.id === id) as Profile),
      history: () => ({ state: null, share: '', unshare: '', remove: '' }),
      create: () => null,
      rename: () => null,
      remove: () => null,
      setDefault: () => null,
      setProjectDefault: () => null,
      signOut: async () => ({ ok: true, message: '' }),
      share: () => null,
      unshare: () => null,
    })
    const run = (id: string, args: Record<string, unknown>) =>
      tools.find((tool) => tool.id === id)?.run(args, {} as ToolContext)

    const listed = await run('accounts.list', {})
    const checked = await run('accounts.status', { accountId: work.id })
    const text = JSON.stringify([listed, checked])
    expect(text).not.toContain(SECRET)
    expect(text).not.toContain('sk-ant')
    expect(text).not.toContain(VAULT_TICKET_ENV)
    expect(text).not.toContain('[withheld]')
    const snapshot = (listed?.value as { accounts: { vault: Record<string, { keptBy: string; signedIn: boolean }> } })
      .accounts
    expect(snapshot.vault[work.id]).toMatchObject({ keptBy: 'app', signedIn: true })
    expect((checked?.value as { signIn: { state: string } }).signIn.state).toBe('signed-in')
  })
})
