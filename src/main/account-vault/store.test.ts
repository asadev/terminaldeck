import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { claudeLogin, fakeCipher } from './fake-cipher.fixture'
import { AccountVault, NO_SECURE_STORE, VAULT_FILE, VAULT_LOCKED } from './store'

/**
 * The vault against `fakeCipher` — see the fixture for why its ciphertext is a
 * fair stand-in for `safeStorage`'s.
 */

const ON_WINDOWS = process.platform === 'win32'

let dir = ''
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-vault-store-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('the vault keeps logins encrypted', () => {
  it('round-trips a login through the disk without ever writing the plaintext', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    const login = claudeLogin('ACCOUNT-ONE')
    expect(vault.put('work', 'claude', 'keychain:Claude Code-credentials', login, 'sign-in').ok).toBe(true)

    const onDisk = readFileSync(join(dir, VAULT_FILE), 'utf8')
    expect(onDisk).not.toContain('ACCOUNT-ONE')
    expect(onDisk).not.toContain('accessToken')

    // A fresh vault over the same file reads it back.
    const again = new AccountVault({ dir, cipher: fakeCipher() })
    expect(again.read('work', 'keychain:Claude Code-credentials')).toBe(login)
    expect(again.has('work')).toBe(true)
  })

  it.skipIf(ON_WINDOWS)('writes the file owner-only, atomically, with no temp file left behind', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    vault.put('work', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    expect(statSync(join(dir, VAULT_FILE)).mode & 0o777).toBe(0o600)
    expect(statSync(dir).mode & 0o777).toBe(0o700)
    expect(readdirSync(dir).filter((name) => name.endsWith('.tmp'))).toEqual([])
  })

  it('holds any number of accounts, for every agent, each with its own login', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    for (let i = 0; i < 40; i++) {
      vault.put(`claude-${i}`, 'claude', 'keychain:Claude Code-credentials', claudeLogin(`C${i}`), 'sign-in')
      vault.put(`codex-${i}`, 'codex', 'file:auth.json', JSON.stringify({ tokens: { access_token: `X${i}` } }), 'sign-in')
    }
    const again = new AccountVault({ dir, cipher: fakeCipher() })
    expect(again.summaries()).toHaveLength(80)
    expect(again.read('claude-17', 'keychain:Claude Code-credentials')).toBe(claudeLogin('C17'))
    expect(again.read('codex-39', 'file:auth.json')).toContain('X39')
    // One account's slot never answers for another's.
    expect(again.read('claude-17', 'file:auth.json')).toBeNull()
  })

  it('a refresh replaces the value, and writing the same value again touches nothing', () => {
    let now = 1_000
    let writes = 0
    const vault = new AccountVault({
      dir,
      cipher: fakeCipher(),
      now: () => now,
      writeFile: (d, f, c) => {
        writes += 1
        writeFileSync(f, c)
        void d
      },
    })
    vault.put('work', 'claude', 'keychain:Claude Code-credentials', claudeLogin('OLD'), 'sign-in')
    now = 2_000
    const same = vault.put('work', 'claude', 'keychain:Claude Code-credentials', claudeLogin('OLD'), 'refresh')
    expect(same).toEqual({ ok: true, changed: false, message: '' })
    expect(writes).toBe(1)

    now = 3_000
    vault.put('work', 'claude', 'keychain:Claude Code-credentials', claudeLogin('NEW'), 'refresh')
    expect(writes).toBe(2)
    expect(vault.read('work', 'keychain:Claude Code-credentials')).toBe(claudeLogin('NEW'))
    const summary = vault.summary('work')
    expect(summary?.capturedAt).toBe(1_000)
    expect(summary?.updatedAt).toBe(3_000)
    expect(summary?.lastSource).toBe('refresh')
  })

  it('forget deletes every secret the account had, from memory and from disk', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    vault.put('gone', 'claude', 'keychain:Claude Code-credentials', claudeLogin('GONE'), 'sign-in')
    vault.put('gone', 'claude', 'keychain:Claude Code', 'sk-ant-api03-GONE', 'typed')
    vault.put('kept', 'claude', 'keychain:Claude Code-credentials', claudeLogin('KEPT'), 'sign-in')

    expect(vault.forget('gone').ok).toBe(true)
    expect(vault.has('gone')).toBe(false)
    expect(vault.read('gone', 'keychain:Claude Code')).toBeNull()

    // Decrypt the file by hand: the deleted account's values are not in it at all.
    const blob = Buffer.from(readFileSync(join(dir, VAULT_FILE), 'utf8'), 'base64')
    const plain = fakeCipher().decrypt(blob)
    expect(plain).not.toContain('GONE')
    expect(plain).toContain('KEPT')
  })

  it('drop removes one slot and the account with it when nothing is left', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    vault.drop('a', 'keychain:Claude Code-credentials')
    expect(vault.has('a')).toBe(false)
    expect(vault.summary('a')).toBeNull()
  })

  it('refuses to save anything when there is no secure store, and writes no file', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher({ available: false }) })
    const result = vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    expect(result.ok).toBe(false)
    expect(result.message).toBe(NO_SECURE_STORE)
    expect(existsSync(join(dir, VAULT_FILE))).toBe(false)
  })

  /*
   * Review finding 4. Before: a vault that would not *decrypt* — a denied or
   * locked keychain, or a dev build reading a release build's file — was read
   * as empty, and the next sign-in renamed it to `.unreadable-*`, losing every
   * login in it. A file that will not decrypt is somebody's logins behind a key
   * that is not here right now; only a file that decrypts and will not parse is
   * damaged, and only that one is set aside.
   */
  it('leaves a vault that will not decrypt exactly as it is, refuses writes, and tries again', () => {
    const original = Buffer.from('a vault from another build of the app').toString('base64')
    writeFileSync(join(dir, VAULT_FILE), original)
    const vault = new AccountVault({ dir, cipher: fakeCipher(), now: () => 42 })
    expect(vault.summaries()).toEqual([])
    const write = vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    expect(write.ok).toBe(false)
    expect(readFileSync(join(dir, VAULT_FILE), 'utf8')).toBe(original)
    expect(existsSync(join(dir, `${VAULT_FILE}.unreadable-42`))).toBe(false)
    expect(write.message).toBe(VAULT_LOCKED)
    expect(vault.state()).toBe('locked')
    // Not cached: once the key is back, the same vault opens.
    let decrypts = 0
    const counting = fakeCipher()
    const watched = new AccountVault({
      dir,
      cipher: { ...counting, decrypt: (blob) => { decrypts += 1; return counting.decrypt(blob) } },
    })
    expect(watched.open()).toBe('locked')
    expect(watched.open()).toBe('locked')
    expect(decrypts).toBe(2)
  })

  it('sets aside a vault that decrypts but will not parse, instead of overwriting it', () => {
    writeFileSync(join(dir, VAULT_FILE), fakeCipher().encrypt('{ this is not json').toString('base64'))
    const vault = new AccountVault({ dir, cipher: fakeCipher(), now: () => 42 })
    expect(vault.open()).toBe('ready')
    expect(vault.summaries()).toEqual([])
    vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    expect(existsSync(join(dir, `${VAULT_FILE}.unreadable-42`))).toBe(true)
    expect(new AccountVault({ dir, cipher: fakeCipher() }).has('a')).toBe(true)
  })

  it('reports an encryption failure as a failed save, not as anything else', () => {
    const cipher = fakeCipher()
    const vault = new AccountVault({
      dir,
      cipher: { ...cipher, encrypt: () => { throw new Error('keychain said no') } },
    })
    const write = vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    expect(write.ok).toBe(false)
    expect(write.message).toContain('keychain said no')
  })

  /*
   * Review finding 8. Before: a delete whose save failed left the login live in
   * memory while the account was reported deleted.
   */
  it('forgets an account in memory even when the disk refuses, and says the save failed', () => {
    let fail = false
    const vault = new AccountVault({
      dir,
      cipher: fakeCipher(),
      writeFile: (d, f, c) => {
        if (fail) throw new Error('disk full')
        writeFileSync(f, c)
        void d
      },
    })
    vault.put('gone', 'claude', 'keychain:Claude Code-credentials', claudeLogin('GONE'), 'sign-in')
    fail = true
    const result = vault.forget('gone')
    expect(result.ok).toBe(false)
    expect(result.message).toContain('disk full')
    expect(vault.has('gone')).toBe(false)
    expect(vault.read('gone', 'keychain:Claude Code-credentials')).toBeNull()
  })

  it('refuses slot names it did not choose, so nothing odd reaches a log or a file name', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    expect(vault.put('a', 'claude', '../../etc/passwd', 'x', 'sign-in').ok).toBe(false)
    expect(vault.put('a', 'claude', 'keychain:a/b', 'x', 'sign-in').ok).toBe(false)
    expect(vault.read('a', '../x')).toBeNull()
  })

  it('a summary names slots, times and the plan — never a value', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('SECRET-VALUE', 'pro'), 'sign-in')
    const summary = vault.summary('a')
    expect(summary?.plan).toBe('pro')
    expect(summary?.slots).toEqual(['keychain:Claude Code-credentials'])
    expect(JSON.stringify(vault.summaries())).not.toContain('SECRET-VALUE')
    expect(JSON.stringify(vault.summaries())).not.toContain('sk-ant')
  })

  it('tells listeners which account changed, and nothing about what it changed to', () => {
    const vault = new AccountVault({ dir, cipher: fakeCipher() })
    const heard: unknown[] = []
    vault.onChange((...args) => heard.push(args))
    vault.put('a', 'claude', 'keychain:Claude Code-credentials', claudeLogin('A'), 'sign-in')
    vault.forget('a')
    expect(heard).toEqual([['a'], ['a']])
  })
})
